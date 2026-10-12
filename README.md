<p align="center">
  <img src="assets/zokor.png" alt="zokor" width="240">
</p>

<h1 align="center">zokor</h1>

<p align="center">
  A backend framework for <a href="https://github.com/dolphlabs/slang">slang</a>.
</p>

<p align="center">
  <a href="https://flossafrica.com/m/xlaez?p=zokor"><img src="https://flossafrica.com/badge.svg" alt="Fund my work on FLOSSAfrica"></a>
</p>

zokor exists for one reason: a service should spend its code on what it
does, not on the plumbing every service rewrites — routing, configuration,
error shapes, limits. It is opinionated about the things that go wrong
when each service invents its own: **one error envelope**, **one place
configuration is read**, **one router**.

```slang
import "http";
import "zokor";

gc struct App {
    db: pg.Pool,
    errors: zokor.Registry,
}

fn show_org(c: zokor.Ctx[App]) -> http.Response {
    guard let org = find_org(c.state.db, c.param("id")) else {
        return zokor.respond(c.state.errors, "org.not_found", c.request_id);
    }
    return zokor.ok_json(encode(org));
}

let r = zokor.new_router(app);
r.errors = reg;
r.get("/orgs/:id", show_org);
r.post("/orgs", create_org);
```

Middleware attaches to a **group**, not to every handler:

```slang
r.get("/health", health);            // public

let api = r.group("/api/v1");
api.before(require_token);           // everything below is guarded
api.get("/orgs/:id", show_org);
api.post("/orgs", create_org);

let admin = api.group("/admin");     // nests: /api/v1/admin
admin.before(require_admin);         // and keeps the parent's hooks
admin.delete("/orgs/:id", drop_org);
```

Middleware applies to routes registered **after** it, on that group, and
each route keeps a copy — so adding a hook later cannot silently change
a route that already exists. One route on its own:
`r.guarded(Method.DELETE, "/orgs/:id", drop, [require_admin])`.

A `before` can also **resolve** something for the handler, which is the
point of doing authentication once at the edge:

```slang
fn require_token(c: zokor.Ctx[App]) -> opt[http.Response] {
    guard let user = lookup(c.state.db, c.bearer()) else {
        return some(zokor.respond(c.state.errors, "unauthorized", c.request_id));
    }
    c.set_local("user_id", user.id);     // the handler reads c.local("user_id")
    return none;
}
```

`after` hooks run innermost first (the route's, then the router's), and
they run even when a `before` stopped the request — so a logging hook
cannot be skipped by a short circuit.

Methods are a closed set: `r.get`, `r.post`, `r.put`, `r.patch`,
`r.delete`, `r.head`, `r.options`, `r.trace`, `r.connect`, and
`r.any([zokor.Method.GET, zokor.Method.POST], "/p", h)` for several at
once. A verb the set does not contain answers `501`, not `404`: the
path may well exist.

`Router[S]` is generic over **your** state. A framework cannot know what
your handlers need — a database pool, a config, your services — and
before slang had generics the only way to reach them was to pass each as
its own parameter. A real control plane ended up with a twelve-parameter
`dispatch` that grew with every new service. Here it is one value you
declare, and every handler receives it.

## What is in it

| | |
|---|---|
| `Router[S]`, `Ctx[S]` | every HTTP method, `:params`, `*wildcards`, before/after middleware, automatic `HEAD` and `OPTIONS`, `Allow` on a 405 |
| `Registry`, `respond*` | every HTTP failure code, one JSON envelope, field-level validation errors |
| `load_config`, `require_*` | `.env` then the environment, per-variable validation, **every** problem reported at once |
| `parse_form`, `c.upload` | multipart/form-data: limits, type and extension allowlists, filenames made safe |
| `snake_keys`, `decode_failed`, `checker` | DTOs: wire names, decode errors as field errors, validation |
| `Json`, `parse`, `jobj` | JSON you did not declare: walk it, build it, render it |
| `upgrade`, `receive`, `sio_*` | WebSocket (RFC 6455) and Socket.IO, as a state machine you feed bytes |
| `ok_json`, `created`, … | success responses with the headers they should carry |
| `redis_from_config` | a Redis pool from `REDIS_URL`, optional by default |
| `ServerConfig`, `listen_and_serve_with` | idle/header/body/write timeouts, safe defaults, all overridable |
| `RateLimiter`, `rate_limit` | per-client sliding-window limits: `429`, `Retry-After`, the registered envelope |
| `TokenStore`, `bearer_subject` | opaque bearer tokens: crypto-random, issue/lookup/revoke, optional TTL, safe across tasks |

Every public symbol, one line each: [docs/api.txt](docs/api.txt).

## Configuration

Read once, at startup, into a value you hold. Nothing reads the
environment while serving: a handler that calls `getenv` changes
behaviour without a deploy and cannot be tested without setting process
state.

```slang
let cfg = zokor.load_config();                 // ".env", then the environment
// or: zokor.load_config_from(".env.test")

let port = zokor.require_port(cfg, "PORT");
let dsn  = zokor.require_dsn(cfg, "DATABASE_URL");
let from = zokor.require_email(cfg, "ALERT_FROM");
let mode = zokor.require_one_of(cfg, "MODE", ["dev", "prod"]);

let ready = zokor.check(cfg);
guard let _ok = ready else let e = err_of(ready) {
    println(e);
    exit(1);
}
```

Every problem comes back together, because a service with six unset
variables should say so once instead of failing six times:

```
configuration is not usable (read from .env and the environment):
  SERVICE_NAME is required but not set
  PORT must be a TCP port (1-65535), got '0'
  DATABASE_URL is required but not set
  ALERT_FROM must be an email address, got 'ops@'
  MODE must be one of: dev, prod, got 'staging'
```

Values under a name that looks like a secret (`*_TOKEN`, `*_PASSWORD`,
`*_URL`, `*_KEY`, …) are reported as `(24 characters, hidden)`, because
this text gets logged.

Validators: `require`, `require_int`, `require_range`, `require_port`,
`require_bool`, `require_float`, `require_email`, `require_url`,
`require_dsn`, `require_host`, `require_ipv4`, `require_uuid`,
`require_one_of`, `require_duration`, `require_min_len`,
`require_max_len`, and `optional_url` / `optional_one_of` / `optional_dsn`
for values that must be valid *when set*.

## Redis

Optional the same way any dependency should be: a service with no
`REDIS_URL` builds no pool and opens no connection.

```slang
let cfg = zokor.load_config();
let pr = zokor.redis_from_config(cfg);   // reads REDIS_URL, REDIS_POOL_SIZE
guard let pool = pr else let e = err_of(pr) {
    println(e);       // "REDIS_URL is not set" -- your call whether that's fatal
    exit(1);
}
```

That is the whole of it: a pool from config, nothing more. Everything
past that point is slang's own `redis` package — `redis.acquire`,
`redis.get`/`set`/`hset`/`zadd`/…, transactions, pub/sub, streams,
cluster routing — called directly, the same way any other zokor
service reaches its dependencies. Wrapping the other ~150 functions
here would only be a second place for that API to drift from the one
slang ships.

```slang
let cr = redis.acquire(pool, deadline);
guard let conn = cr else let e = err_of(cr) {
    return zokor.respond(c.state.errors, "unavailable", c.request_id);
}
let r = redis.get(conn, "session:" + token, deadline);
redis.release(pool, conn);
```

## Server timeouts, limits, and shutdown

Safe defaults, not infinite ones: `listen_and_serve` uses them without
asking, and `listen_and_serve_with` takes a `ServerConfig` to change
any of them.

```slang
let sc = zokor.server_config_from(cfg);
// IDLE_TIMEOUT, READ_HEADER_TIMEOUT, READ_BODY_TIMEOUT, WRITE_TIMEOUT,
// MAX_REQUEST_BYTES, MAX_REQUESTS_PER_CONN, SHUTDOWN_TIMEOUT, REQUEST_IDS,
// TRUSTED_PROXIES, PROXY_HEADER, LOG_FORMAT, LOG_LEVEL, LOG_REQUESTS,
// MAX_CONNECTIONS,
// TRUSTED_PROXIES, PROXY_HEADER
spawn zokor.listen_and_serve_with(r, port, sc);
```

Every dynamic request is answered under a **request id**: the client's own
`X-Request-Id` when it is 1-64 characters of `[A-Za-z0-9._-]` (so a
proxy's id threads through your logs), a fresh `req_<32 hex>` otherwise.
It comes back as `X-Request-Id` and in every error envelope, the 500 after
a panicking handler included, and handlers read it as `c.request_id`.
Static routes are fixed bytes and carry none. `REQUEST_IDS=false` (or
`request_ids: false`) turns it off.

`c.client_ip` is **who the request came from**. By default that is the
socket's peer, whatever headers the client sent. Behind a load balancer or
reverse proxy, list it in `TRUSTED_PROXIES` (comma-separated IPv4 addresses
and CIDRs, e.g. `10.0.0.0/8,192.168.1.10`): zokor then reads the proxy's
`X-Forwarded-For` from the right, past every trusted address, and takes the
first one that is not -- so a hop the client wrote itself never wins.
`PROXY_HEADER=forwarded` reads RFC 7239 `Forwarded` instead; only one header
is ever believed, so a client cannot add the one your proxy does not set.
A bad entry (`10.0.0.1/8` has host bits set: did you mean `10.0.0.0/8`?) is
reported by `check(cfg)` with every other problem.

Four separate timeouts, not one, because "how long should this wait"
has different honest answers depending on what a connection is doing:
`idle_timeout` (default 60s) governs waiting for a request to start on
a connection that might legitimately sit open a while; `header_timeout`
(5s) and `body_timeout` (30s) govern a request that has started
arriving and then stalls -- the slow-loris shape a tight window exists
to catch; `write_timeout` (10s) bounds sending the response,
separately, since a client that stopped reading is a different problem
than one that stopped sending.

`max_request_bytes` (default 16KB) refuses an oversized request at
read time -- `431` if the headers alone never complete, `413` if a
declared body is bigger than the buffer -- never a silent drop after
buffering. `max_requests_per_conn` (default 100,000) closes a
connection after it, answering the request that hit the limit
normally first.

`max_connections` (default 10,000, `MAX_CONNECTIONS`) caps open
connections across every acceptor. A connection past it is answered `503`
with `Retry-After: 1` and closed at once, so a load balancer retries
elsewhere instead of waiting in the accept backlog. Refusals are logged at
most once a second. Raise the process's open-file limit (`ulimit -n`) above
the cap. If `accept` fails anyway (out of file descriptors), the loop logs
it once and backs off from 5ms up to 1s instead of spinning. Measured on
Linux at the limit: a full core spinning before, about 2% after.

On `SIGTERM`/`SIGINT`, `listen_and_serve` stops accepting immediately
and gives in-flight connections up to `shutdown_timeout` (default 30s)
to finish on their own before returning anyway -- long enough for
ordinary requests to complete, bounded so one stuck connection cannot
hang a deployment's rollout forever.

A panicking handler answers `500` instead of dropping the connection
or taking the process down -- the handler call runs isolated in its
own task, and the connection closes right after answering rather than
serving more requests on whatever state the panic left behind. The
static fast path (`GET /`, no handler call) never pays for this
isolation, since nothing there can panic in the first place.

## Logging

On by default. Every request gets one record, and the server writes its
own lines too: routes mapped, listening, shutting down, stopped. On a
terminal they look like NestJS's, in colour:

```
[zokor] 51734  - 2026-10-12 18:47:01.123Z     LOG [Router] Mapped {/users/:id, GET} route
[zokor] 51734  - 2026-10-12 18:47:01.124Z     LOG [Server] Listening on :8080 +1ms
[zokor] 51734  - 2026-10-12 18:47:03.551Z     LOG [HTTP] GET /users/:id 200 28B 10.0.0.4 req_1a2b… +0.41ms
[zokor] 51734  - 2026-10-12 18:47:04.002Z    WARN [HTTP] GET /nope 404 124B 10.0.0.4 req_9f3c… +0.16ms
```

Anywhere else, such as a pipe, a file or a container's stdout, each line
is one JSON object, which is what a log shipper wants:

```
{"time":"2026-10-12T18:47:03.551Z","level":"log","pid":51734,"context":"HTTP","msg":"GET /users/:id 200 28B 10.0.0.4 req_1a2b…","method":"GET","route":"/users/:id","status":200,"duration_ms":0.412,"bytes":28,"request_id":"req_1a2b…","client_ip":"10.0.0.4"}
```

| Setting | Values | Default |
|---|---|---|
| `LOG_FORMAT` | `pretty`, `json` | pretty on a terminal, json otherwise |
| `LOG_LEVEL` | `debug`, `log`, `warn`, `error`, `off` | `log` |
| `LOG_REQUESTS` | `true`, `false` | `true` |
| `NO_COLOR` | any value | colour on a terminal |

Settings are read by `server_config_from(cfg)`; plain `listen_and_serve`
uses the defaults. A 4xx is a `warn` record and a 5xx an `error`, so
`LOG_LEVEL=warn` keeps exactly the requests that went wrong. A panicking
handler adds an `error` line with the panic and the request id.

**What is never logged:** query strings, bodies or headers. A matched
request is logged by its route pattern, not its path, so ids in paths stay
out of the log and a dashboard sees one series per route. An unmatched path
is cut to 64 bytes, and control characters, `"` and `\` are
percent-encoded, so a client cannot forge a line or send a terminal
escape.

**It never slows a request down.** The serve loop hands each record to a
bounded queue and moves on, and one task formats and writes the records in
batches. If the queue is ever full, records are dropped and counted, and a
`WARN [Logger] N log records dropped` line says so.

**What it costs.** About 3 extra allocations per request. At saturation,
`GET /users/:id` on a laptop with 32 connections went from about 62k to
about 50k requests per second, with p99 rising from 1.6–3.0ms to
1.9–3.3ms on the runs not hit by thermal throttling. That's 50k JSON
lines a second written to a file. `LOG_REQUESTS=false` removes the cost
and keeps the server's own lines.

**Bring your own.** A `Logger` is a channel plus a level. To ship records
somewhere else, make one with `channel_logger(ch, level, requests)`, put it
in `ServerConfig.logger`, and drain `ch` from your own task.
`new_log_format(pid)` gives you zokor's `json` and `pretty` formats to reuse.
`no_logger()` turns logging off.

## Cookies

```slang
let theme = c.cookie("theme");                    // "" when not sent

let ck = zokor.new_cookie("theme", "dark");        // HttpOnly, Secure, SameSite=Lax, Path=/
ck.max_age = 86400 * 30;
return zokor.set_cookie(resp, ck) ?? resp;         // err names what is wrong
```

- **Safe defaults.** A new cookie is `HttpOnly`, `Secure`, `SameSite=Lax`
  and `Path=/`, with no `Domain`, so it's host-only.
- **Checked before it's sent.** `set_cookie` refuses:
  - a value with a space, quote, comma, `;`, backslash or control byte,
    which could add attributes of its own
  - a bad name
  - a path or domain carrying `;`
  - `SameSite=None` without `Secure`, which browsers drop
  - a `__Host-` or `__Secure-` cookie that breaks its prefix's rules
  - more than 4,096 bytes
- **Reading.** `c.cookie(name)` and `c.cookies()` skip malformed pairs the
  way browsers do, and the first of two same-named cookies wins.
- **Deleting.** `clear_cookie(resp, name, path, domain)` removes a cookie.
- **No `Expires`.** `Max-Age` (seconds, `0` deletes) says the same thing
  to every browser in use.

**Signed cookies** carry an HMAC-SHA256 over their name and value, so a
client can read them but not change them, or move one to another name:

```slang
let keys = zokor.cookie_keys_from(cfg);            // COOKIE_KEYS=newest,older
let ck = zokor.signed_cookie("uid", "42", keys) ?? zokor.new_cookie("uid", "");
let uid = zokor.signed_value(c, "uid", keys) ?? "";  // none when forged
```

The first key signs and every listed key verifies. To rotate, put the new
key first and keep the old one until the cookies it signed have expired;
nobody is logged out. Keys must be at least 32 bytes. Signatures are
compared in constant time. Signed is not encrypted: never put a secret in
a cookie.

## Security headers

On by default, on every response: dynamic, static, errors, and the 500
after a panic.

```
content-security-policy: default-src 'none'; frame-ancestors 'none'
strict-transport-security: max-age=31536000; includeSubDomains
x-content-type-options: nosniff
x-frame-options: DENY
referrer-policy: no-referrer
```

- **CSP.** An API answers JSON, so its CSP allows nothing: a response
  opened in a browser runs no script and can't be framed.
- **HSTS.** Browsers ignore HSTS on plain HTTP, so it's harmless behind a
  proxy that ends TLS, and right when the proxy doesn't.
- **COOP and CORP** are opt-in: `same-origin` CORP breaks legitimate
  cross-origin embeds.
- **Handlers win.** A handler that sets one of these headers with
  `with_header` keeps its own value.

| Setting | Values |
|---|---|
| `SECURITY_HEADERS` | `false` turns them all off |
| `CONTENT_SECURITY_POLICY` | a policy, or `off` |
| `HSTS_MAX_AGE` | seconds; `0` is off |
| `HSTS_INCLUDE_SUBDOMAINS`, `HSTS_PRELOAD` | `true` / `false` |
| `FRAME_OPTIONS` | `DENY`, `SAMEORIGIN`, `off` |
| `REFERRER_POLICY` | any standard policy, or `off` |
| `CROSS_ORIGIN_OPENER_POLICY`, `CROSS_ORIGIN_RESOURCE_POLICY` | the standard values |

`r.security_headers(zokor.security_from(cfg))` applies the settings, and
`zokor.no_security_headers()` turns them off. Bad values are refused with
the fix: an unknown frame option or referrer policy, preload without a
year and subdomains, or a CSP containing a line break. Static routes are
pre-rendered with the headers, so they cost nothing per request there. On
a dynamic response, the five lines add about 10 allocations.

## CORS

Off by default. One call turns it on:

```slang
r.cors(zokor.cors_from(cfg));   // CORS_ORIGINS=https://app.example.com,https://*.example.org
```

or `r.cors(zokor.cors_policy(["https://app.example.com"]))` from code.

| Setting | Meaning | Default |
|---|---|---|
| `CORS_ORIGINS` | exact origins, `https://*.example.com` for subdomains, or `*` alone | none (off) |
| `CORS_METHODS` | allowed methods | `GET, HEAD, POST, PUT, PATCH, DELETE` |
| `CORS_HEADERS` | request headers a page may send | `Content-Type, Authorization, X-Request-Id` |
| `CORS_EXPOSE` | response headers a page may read | `X-Request-Id` |
| `CORS_CREDENTIALS` | allow cookies and `Authorization` | `false` |
| `CORS_MAX_AGE` | seconds a browser may cache a preflight | `600` |

The router applies it, so it isn't one more `before`:
- **Preflights.** A preflight to a path that exists gets a `204` with the
  allowed methods and headers before routing. Neither an auth hook nor a
  route's own `OPTIONS` handler can turn it away, and browsers send
  preflights without credentials.
- **Every response.** Any answer to an allowed origin carries its headers:
  the 404, the 422, a `before`'s 401 and the 500 after a panic. Without
  that, the page sees a CORS error instead of the real one.
- **`Vary: Origin`.** It's sent whenever the answer depends on the origin,
  so a shared cache never hands one origin's answer to another.
- **Other origins.** An origin that isn't allowed gets no CORS headers, and
  the browser withholds the response from the page.

A policy is checked before use, and every problem names the fix:
- an origin with a path or trailing slash, which an `Origin` header never has
- a missing scheme
- upper case
- a wildcard anywhere but a leading `*.`
- `*` together with credentials, which browsers refuse

`https://*.example.com` matches `api.example.com` and `a.b.example.com`,
but never `example.com` or `evilexample.com`. CORS protects users'
browsers, not your server: it is no substitute for authentication.

## Health and readiness

```slang
r.health();                      // GET /healthz and GET /readyz
r.ready_check("db", db_ready);   // what /readyz waits on

fn db_ready(s: App) -> result[int, str] {
    let q = s.db.query("select 1");
    guard let _rows = q else let e = err_of(q) {
        return err(to_str(e));
    }
    return ok(0);
}
```

`/healthz` is liveness: `200 {"status":"ok"}` whenever the process is
serving, and it never touches a dependency, so a database outage cannot
make the orchestrator restart every replica. `/readyz` runs every check at
once and answers `200 {"status":"ok","checks":{"db":"ok"}}`, or `503` with
`"failing"` or `"timeout"` against each check that did not pass. It also
answers `503 shutting_down` once `SIGTERM` arrives, so a load balancer stops
sending traffic before the drain.

- **Bounded.** A probe waits at most 0.9s (`r.ready_timeout(ns)`), inside
  Kubernetes' default 1s probe timeout.
- **Isolated.** A check runs in its own task, so a panic fails that check,
  not the probe. A check still running from an earlier probe is joined,
  not started again, so a hung database costs one task, not one per probe.
- **No leaks.** The body names checks, never errors: a driver's message
  carries hosts and user names. The reason goes to the server's log as a
  `WARN [Health]` line, once each time a check starts failing, changes
  reason or recovers.
- **Out of the way.** The router answers these paths only when no route
  claims them, so your own `/healthz` wins. No `before` runs on them,
  since an auth hook would fail the probes. `r.health_at(live, ready)`
  mounts them elsewhere.

## Errors

Every failure names a code; every code is registered once with its status
and its wording; every response is rendered by the same function. A
client sees one shape:

```json
{"error":{"code":"org.not_found","message":"no such organisation",
          "status":404,"request_id":"req-9"}}
```

```json
{"error":{"code":"validation_failed","message":"some fields are not valid",
          "status":422,
          "fields":[{"field":"email","reason":"must be an email address"}]}}
```

All HTTP failure statuses ship registered (`bad_request` … `network_auth_required`).
Add your own, or reword a built-in:

```slang
zokor.register(reg, "org.not_found", 404, "no such organisation");
zokor.register(reg, "rate_limited", 429, "slow down");
```

A code nobody registered answers **500 and names itself** — the mistake
belongs in your logs, not hidden behind a generic message.

### The shape is a default

That envelope is what you get until you say otherwise. A service with an
existing contract — a different key, `application/problem+json`, whatever
its clients already parse — installs its own renderer and keeps the
registry, the codes and the statuses:

```slang
fn problem_json(v: zokor.ErrorView) -> http.Response {
    let body = "{\"type\":\"about:blank\",\"title\":" + zokor.quote(v.code) +
               ",\"detail\":" + zokor.quote(v.message) +
               ",\"status\":" + to_str(v.status) + "}";
    return zokor.bytes_of(v.status, "application/problem+json", to_bytes(body));
}

zokor.set_renderer(reg, problem_json);
```

`ErrorView` carries the code, the message, the status, the request id and
the field errors — a struct, not a parameter list, so a later addition
does not break renderers people have already written. One renderer per
registry: every failure in a service still comes out the same way, which
is the point of having a registry at all.

## Testing

A request builder and response readers, so a test says what it means
instead of assembling an `http.Request` by hand:

```slang
let resp = r.serve(zokor.request(zokor.Method.POST, "/api/orgs")
    .bearer("token")
    .json_body("{\"name\":\"acme\"}")
    .build());

assert(zokor.resp_status(resp) == 201);
assert(zokor.resp_json(resp).get("id").str_or("") == "org_7");
assert(zokor.resp_error_code(denied) == "unauthorized");
assert(zokor.resp_error_fields(invalid)[0] == "seats");
```

`request`, `get_request`, `.header`, `.bearer`, `.basic`,
`.content_type`, `.json`, `.json_body`, `.body_str`, `.multipart` (with
`upload_part`), and on the way back `resp_status`, `resp_text`,
`resp_header`, `resp_json`, `resp_error_code`, `resp_error_fields`.
It ships in the package because your service's tests need it too.

## JSON

slang already does the part Go does badly: you decode into a struct,
**a missing field is an error rather than a silent zero**, and the
message names the field. No tags, no `interface{}`, no `omitempty`
guessing. zokor adds the four things that are still missing.

**A DTO, decoded and reported.** The wire is camelCase, your struct is
snake_case, and there are no struct tags — so rewrite the keys:

```slang
gc struct CreateOrg { name: str, plan: str, seats: i32, website: opt[str] }

let r: result[CreateOrg, str] = json.decode(zokor.snake_keys(c.body_str()));
guard let dto = r else let e = err_of(r) {
    return zokor.decode_failed(c.state.errors, e, c.request_id);
}
```

`decode_failed` turns slang's own message into the standard envelope
with the **field** named, so a client gets the same shape for a bad type
as for a bad value:

```json
{"error":{"code":"validation_failed","status":422,
          "fields":[{"field":"seats","reason":"expected a number, got a string"}]}}
{"error":{"code":"validation_failed","status":422,
          "fields":[{"field":"plan","reason":"is required"}]}}
```

**Values, checked all at once.** Decoding says a field is a string; it
does not say it is an email between 3 and 40 characters. A `checker`
collects every problem, because a client fixing one field per request is
a client making five requests:

```slang
let v = zokor.checker();
let name  = v.req_str(body, "name", 1, 80);
let email = v.req_email(body, "email");
let role  = v.req_one_of(body, "role", ["admin", "member"]);
let age    = v.opt_int(body, "age", 0, 150, 0);
if v.failed() {
    return zokor.respond_fields(c.state.errors, "validation_failed",
                                v.fields, c.request_id);
}
```

`req_str`, `req_int`, `req_bool`, `req_email`, `req_url`, `req_uuid`,
`req_one_of`, `req_strs`, `req_obj`, `opt_str`, `opt_int`, plus `note`
for a rule of your own and `under("address", inner)` to report a nested
check as `address.city`.

**A shape nobody declared** — a webhook, a passthrough, somebody else's
field. A missing key gives `Null` rather than an error, so a chain never
has to be guarded at every step:

```slang
guard let body = c.json_body() else { ... }

body.get("type").str_or("unknown")
body.path("data.customer.address.city").str_or("nowhere")
body.path("data.items.0.sku").str_or("none")
body.path("data.items").size()
body.has_key("note")          // present, even if null: PATCH semantics
```

**Building a response**, instead of concatenating strings and getting
the quoting wrong:

```slang
zokor.jobj()
    .set_str("id", id)
    .set_int("seats", n)
    .set_opt_str("website", dto.website)     // absent when none
    .set("tags", zokor.jarr().add_str("a").add_str("b"))
    .render()
```

Numbers keep the text they arrived as, so a 64-bit id survives a round
trip; `\uXXXX` escapes and surrogate pairs decode; and the parser
refuses what JSON refuses — a leading zero, a lone surrogate, an
unescaped control character, nesting past 64 deep.

## Uploads

`multipart/form-data` is a format where being lax is a vulnerability:
the client picks the delimiter, names the parts and supplies the
filenames. A handler says what it accepts; anything else comes back as
a registered failure and never reaches it.

```slang
fn upload_avatar(c: zokor.Ctx[App]) -> http.Response {
    let rules = zokor.with_max_file_bytes(
        zokor.uploads_allowing(["image/png", "image/jpeg"]), 1048576);

    let r = c.upload(rules);          // POST/PUT/PATCH only
    guard let form = r else let e = err_of(r) {
        return zokor.respond_with(c.state.errors, e.code, e.detail, c.request_id);
    }
    guard let avatar = zokor.file(form, "avatar") else {
        return zokor.respond(c.state.errors, "validation_failed", c.request_id);
    }

    zokor.value(form, "title");        // the non-file fields
    zokor.files_for(form, "docs");     // <input multiple>
    avatar.filename;                   // safe to use as one path segment
    avatar.raw_filename;               // what the client actually sent
    return zokor.ok_json("{\"bytes\":" + to_str(len(avatar.data)) + "}");
}
```

**Filenames are made safe**: everything before the last `/` or `\` is
dropped, control characters go, a leading dot goes, and a name that is
empty after that becomes `upload`. `../../etc/passwd` arrives as
`passwd`. The name the client sent is kept as `raw_filename` for logs.

**Limits are the caller's**, checked while the body is walked: parts,
files, bytes per file, bytes per field, total bytes, header size,
filename length. Over a size limit is a `413`; a body that is not
well-formed multipart is a `400`; a type or extension that is not
allowed is a `415`.

**Refused rather than guessed at**: a Content-Type that is not
multipart or has no boundary, a boundary that is empty or over 70
characters, a body that stops before its closing delimiter, a part with
no `Content-Disposition` or no name, unterminated or oversized part
headers, and a `Content-Transfer-Encoding` the web does not use. A file
sent with no `Content-Type` is refused unless you turn
`require_content_type` off.

A body arrives whole, so this does not stream: set `max_total_bytes`
for what a service can afford to hold.

## Rate limits and bearer tokens

Both are values in your state, shared by every request and safe to use
from concurrent handlers (each holds a mutex).

```slang
gc struct App {
    errors: zokor.Registry,
    limiter: zokor.RateLimiter,
    tokens: zokor.TokenStore,
}

// 100 requests per client per minute; tokens last a day. Durations
// are int nanoseconds, written out: `60 * 1000000000` overflows in
// slang today (a product of two literals is computed in 32 bits).
let app = App {
    errors: zokor.new_registry(),
    limiter: zokor.new_rate_limiter(100, 60000000000),
    tokens: zokor.new_token_store(86400000000000)
};

fn limit(c: zokor.Ctx[App]) -> opt[http.Response] {
    return zokor.rate_limit(c, c.state.limiter, c.header("x-api-key"));
}

fn auth(c: zokor.Ctx[App]) -> opt[http.Response] {
    guard let user = zokor.bearer_subject(c, c.state.tokens) else {
        return some(zokor.respond(c.state.errors, "unauthorized", c.request_id));
    }
    c.set_local("user", user);
    return none;
}
```

`rate_limit` answers a refused request with the registered
`rate_limited` code (`429`, through your renderer if you set one) and
`Retry-After` in whole seconds; refused requests do not count against
the window. The key is yours to choose (an API key, a user, an
address); an empty key shares one "anonymous" budget. `take_at(key,
now)` takes the clock as a parameter, so tests need no sleeps.

`TokenStore.issue(subject)` returns a 64-hex-character token from
`crypto.rand`; `lookup(token)` gives the subject back (expired tokens
are dropped), `revoke(token)` logs one session out and
`revoke_subject(subject)` all of them. Tokens live in memory: they do
not survive a restart and are not shared between instances.

## WebSocket

A connection is a **state machine, not a socket**: you hand it the bytes
that arrived and it hands back whole messages and the bytes to send.
That is why it is fully testable without a network, and why the same
code serves a raw WebSocket client and a socket.io one.

```slang
let r = zokor.upgrade(c.req, zokor.default_ws());   // the 101
guard let resp = r else let e = err_of(r) {
    return zokor.respond_with(c.state.errors, "bad_request", e, c.request_id);
}

let conn = zokor.new_conn(zokor.default_ws());
// ... once the connection is yours, per chunk of bytes read:
let got = zokor.receive(conn, chunk);
guard let messages = got else let why = err_of(got) {
    write(zokor.close_because(conn, why));          // then hang up
    return;
}
for m in messages {
    if m.kind == zokor.Incoming.Text {
        write(zokor.text_frame("you said: " + m.text));
    }
}
write(zokor.pending(conn));   // pongs and close echoes, taken LAST:
                              // handling a message can add to them
```

Ping/pong and the closing handshake are answered by the connection
itself, because they are protocol rather than application: a service
that only looks at `Text` messages still keeps its clients alive.

**Refused rather than guessed at**, each closing the connection with
1002: an unmasked client frame, a reserved bit or opcode, a fragmented
or oversized control frame, a length that is not minimally encoded, a
continuation with nothing to continue, a new message starting before
the last finished, a text message that is not valid UTF-8, an invalid
close code, and anything over `max_frame_bytes` / `max_message_bytes`.

### Socket.IO

socket.io clients speak Engine.IO inside WebSocket text frames. zokor
speaks that:

```slang
write(zokor.sio_open(conn, session_id, zokor.default_sio()));

let ev = zokor.sio_receive(conn, m);
guard let e = ev else { return; }
if e.kind == zokor.SioKind.Connect {
    write(zokor.sio_connect_ok(conn, e.namespace));
}
if e.kind == zokor.SioKind.Event && e.name == "chat message" {
    write(zokor.sio_emit("/", "chat message", e.args_json));
    if e.ack >= 0 {
        write(zokor.sio_ack(e.namespace, e.ack, "[\"got it\"]"));
    }
}
```

Namespaces, acknowledgements and the Engine.IO keepalive all work; the
keepalive is answered for you. Point the client straight at this
transport:

```js
const socket = io("http://localhost:8080", { transports: ["websocket"] });
```

`examples/chat` is a working chat service on both transports —
handshake, fragments, ping, a protocol violation being closed, and a
socket.io session with acknowledgements — driven by a stand-in client
so you can run it today: `make example-chat`.

**That option is required**, because a socket.io client otherwise opens
an HTTP long-polling session first and upgrades, and polling is a
separate transport zokor does not serve yet. Binary attachments
(`BINARY_EVENT`) are recognised but their attachment frames are not
reassembled yet.

## Layout

```
zokor/            the package your service imports
  router.sl       Router[S], Route[S], Ctx[S]
  errors.sl       Registry, Code, ErrorView, the envelope
  config.sl       Config, load_config, require_*
  respond.sl      success responses
  ids.sl          request and session ids
  json.sl         Json, the checker, DTO helpers
  testkit.sl      the request builder and response readers
  upload.sl       uploads: rules, Form, Upload, safe filenames
  ratelimit.sl    RateLimiter, rate_limit
  tokens.sl       TokenStore, bearer_subject
  ws.sl           WebSocket connections and Socket.IO
  internal/
    path/         split, query parsing, percent-decoding
    envfile/      .env parsing
    validate/     the value rules
    multipart/    the multipart/form-data parser
    ws/           RFC 6455 frames and the handshake
    sio/          Engine.IO and Socket.IO packets
examples/
  hello/          routes, config, errors, DTOs, uploads
  chat/           WebSocket and socket.io
assets/           the logo
todo.md           what is next, checkable
docs/             benchmarks, llms-small.txt (the agent guide: one page,
                every snippet compile-checked by `make snippets`),
                api.txt (every public symbol, generated by gen_api.sh)
.github/          CI: tests, guide snippets, api.txt freshness
```

`internal/` holds the pure parts: no sockets, no clock, no environment.
That is where the tests are cheapest and the hot paths easiest to keep
honest.

## Requirements

slang v0.2.1 or later: zokor needs generic structs and methods, and the
`dir` sub-directory pin.

## Install

In a new project (`slangc new app` writes the `name` and `version`
lines), add the pin to `slang.project`. The whole file:

```
name app
version 0.1.0

pkg zokor git https://github.com/dolphlabs/zokor tag v0.2.0 dir zokor
```

`v0.2.0` is the next release and is not tagged yet. Until it is, pin
`tag v0.1.0 dir src`: the package lived in `src/` before the rename.

Then fetch it, and import it as `import "zokor";`:

```
slangc get
```

`dir zokor` points the pin at the package inside the repository, so the
repository can hold its examples, docs and tests without shipping them
into your build.

## Tests

```
make test
```

`make check` runs the tests, both examples end to end, the agent
guide's snippets (`docs/llms-small.txt`, via `make snippets`), and
`make api-check`, so neither the guide nor the API reference can drift
from the code. CI runs the same against slangc built from slang `dev`.

## Agent guide

An agent writing a service reads slang's `llms-small.txt` then
[docs/llms-small.txt](docs/llms-small.txt): one page, example-first, with
the one way for errors, config, validation, routing and tests, and
recipes for headers, rate limits, bearer tokens, uploads, shared state,
background workers and graceful shutdown. Every snippet in it is a whole
program that compiles and runs; `make snippets` proves it.

[docs/api.txt](docs/api.txt) is the companion: every public symbol, its
signature and one line, small enough to keep in context instead of
reading `zokor/`. It is generated (`make api`, which runs
`docs/gen_api.sh`); CI fails if it is stale.

## Not yet

The full list, ordered and checkable, is [todo.md](todo.md). In short:

- **The serve loop.** `listen_and_serve` turns the WebSocket state
  machine into a running server; timeouts, body limits, graceful
  shutdown, panic recovery and a connection cap are done (see above).
  Still owed: TLS.
- **Middleware**, none of it blocked:
  cookies, JWT and basic auth, ETag/304, compression, static
  files. (A rate limiter and a
  bearer-token store exist; `RateLimit-*` headers and sharding do not.)
- **Enterprise**: Postgres helpers with transactions, migrations,
  metrics, tracing, background jobs, pagination, OpenAPI, and
  `zokor check`, the layout checker.
- **Socket.IO over HTTP long-polling**, so a client needs
  `transports: ["websocket"]`; and binary attachment frames.
- **Speed, measured.** Several parsers here build output by repeated
  concatenation, which is quadratic in slang today; that audit and the
  benchmarks against Go come first in the todo.

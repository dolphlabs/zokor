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
| `load_config`, `require_*` | `.env` plus profiles, startup environment snapshot, per-variable validation, **every** problem reported at once |
| `parse_form`, `c.upload` | multipart/form-data: limits, type and extension allowlists, filenames made safe |
| `snake_keys`, `decode_failed`, `checker` | DTOs: wire names, decode errors as field errors, validation |
| `Json`, `parse`, `jobj` | JSON you did not declare: walk it, build it, render it |
| `upgrade`, `receive`, `sio_*` | WebSocket (RFC 6455) and Socket.IO, as a state machine you feed bytes |
| `ok_json`, `created`, … | success responses with the headers they should carry |
| `files_at`, `r.files(mount)` | static files: traversal-safe, ranges, validators, cache headers |
| `r.compress(compression())` | gzip for clients that accept it, on bodies worth it |
| `r.idempotency(store)` | idempotency keys: a retried POST gets the first answer, in memory or Redis |
| `page_of`, `offset_page`, `cursor_page` | pagination: offset or keyset pages, one envelope, `Link` headers |
| `new_jobs`, `every`, `handle`, `enqueue` | background jobs: cron schedules in a time zone, a retrying in-memory queue |
| `preconditions`, `etag_of`, `r.etags()` | conditional requests: `304 Not Modified`, `412` on a lost update, ETag and Last-Modified |
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
let cfg = zokor.load_config();                 // .env + .env.<profile>, then environment
// or: zokor.load_config_profile("test")
// or: zokor.load_config_from("/etc/app/env")    // one explicit file

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

Profiles are `dev`, `test` and `prod`. `load_config()` selects
`ZOKOR_PROFILE` from the startup environment or base file, defaulting to
`dev`, and
loads `.env` followed by `.env.<profile>` if present. The profile file
wins over the base file; environment values win over both, including
empty values. `load_config_profile("test")` explicitly selects the test
file even if the environment selector says otherwise. `cfg.profile`
is the effective file-selection profile; `cfg.sources` lists the regular
files attempted in precedence order.

Values are captured once: changing the process environment after loading
does not change `get`, `str_or` or the other accessors. For tests and
fakes, `config_from_values(map)` owns a copy of supplied values and reads
no environment. `load_config_from(path)` still loads exactly one file,
with no profile overlay, and captures environment overrides once.

`config_load()` supplies options for `load_config_with(options)`:
`profile` (empty selects the startup selector), `directory` (`.`), and
`max_file_bytes` (1 MiB per file). `load_config_file(path, limit)` is the
single-file variant with a caller-selected bound. Missing files are
optional; directories, NUL bytes, unreadable files and oversized files
are errors. All loading and required-value problems reach `check(cfg)`
together. Profile names cannot select arbitrary paths.

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

## Postgres

slang's `pg` package is the driver. zokor adds what every service writes on
top of it, and nothing that bypasses it:

```slang
let pr = zokor.pg_from_config(cfg);          // DATABASE_URL, DB_POOL_SIZE (10)
guard let db = pr else let e = err_of(pr) { log.error(e); exit(1); }

struct User { id: int, email: str, name: opt[str] }

fn list_users(c: zokor.Ctx[App]) -> http.Response {
    let r: result[[User], str] = zokor.query_all(c.state.db,
        "select id, email, name from users where org = $1",
        [pg.arg_int(c.param_int("org", 0))], until_of(time.mono() + 2000000000));
    guard let users = r else let e = err_of(r) {
        return zokor.db_failure(c.errors, e, c.request_id);
    }
    return zokor.ok_json(json.encode(users));
}
```

- **Rows into structs, by column name.** `query_all`, `query_one` (none
  when there's no row), `conn_query_all` inside a transaction, and
  `rows_as` use slang's compiler-backed `pg.rows_as`, binding column names
  once without rendering intermediate JSON text:
  - integers, floats and numerics become numbers (NaN and infinity become
    strings)
  - booleans stay booleans
  - `json`/`jsonb` decode into nested structs
  - NULL becomes `none`, so use an `opt` field
  - `bytea` reads into `bytes` or a base64 string
  - `timestamptz` and `timestamp` become RFC 3339 strings, so a
    `timez.Time` field reads them (a `timestamp` without a zone as UTC),
    and a `str` field gets the text an API would send
  - text and uuid become strings

  A column your struct doesn't name is ignored. A field the query doesn't
  return must be an `opt`, or the result names the missing field. Invalid
  cell storage and type mismatches return errors with row and field context.
- **Transactions.** `transaction(db, arg, body, deadline)` runs
  `body(conn, arg)` between `BEGIN` and `COMMIT`. An `err`, a failed
  `COMMIT` or a panic in the body rolls back, and the connection goes back
  to the pool every way out. There are no closures, so what the body
  needs comes in as `arg`.
- **Failures in your envelope.** `db_failure(reg, e, rid)` picks the
  status from the SQLSTATE:
  - unique violation: `409 already_exists`
  - foreign key: `409 conflict`
  - not null, check, or a bad value: `422`
  - serialization, deadlock or timeout: `503`
  - anything else: `500`

  The server's message, which names tables, columns and values, never
  reaches the client. `is_unique_violation(e)` is there for the common
  branch.
- **Parameterised queries only.** Every helper takes `$1`-style SQL and
  `pg.Arg` values, and nothing builds SQL from strings. That's the SQL
  injection defence.

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
// MAX_CONNECTIONS, TLS_CERT_FILE, TLS_KEY_FILE, TLS_CLIENT_CA_FILE,
// TLS_HANDSHAKE_TIMEOUT
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

## HTTPS

zokor terminates TLS itself when it is given a certificate, so a service
can serve HTTPS without a proxy in front of it:

```
TLS_CERT_FILE=/etc/certs/api.pem      # the chain, leaf first, PEM
TLS_KEY_FILE=/etc/certs/api-key.pem
TLS_CLIENT_CA_FILE=/etc/certs/ca.pem  # optional: mutual TLS
TLS_HANDSHAKE_TIMEOUT=10s             # optional, the default
```

`server_config_from(cfg)` reads them into `sc.tls` (or set
`sc.tls = zokor.tls_files(cert, key)` by hand), and `listen_and_serve_with`
loads the pair once, before it binds: a missing file or a key that does not
match its certificate stops the server starting, with the setting named,
rather than leaving it listening on a port where every handshake fails.
One file without the other is reported by `check(cfg)`.

Each connection's handshake runs in that connection's own task, under
`TLS_HANDSHAKE_TIMEOUT`, so a client that connects and never speaks holds
one connection slot until then and holds up nobody else. A failed
handshake -- a port scanner, a plaintext request, a browser dropping a
preconnect -- has no request to answer, so it is closed and logged at
`debug`. Past `MAX_CONNECTIONS` a TLS connection is closed without the
plaintext 503, which a TLS client could not read. With
`TLS_CLIENT_CA_FILE`, a client must present a certificate signed by one
of those CAs.

Everything else -- routing, timeouts, keep-alive, WebSockets, logging --
is the same over HTTPS: the serve loop reads and writes the connection
as it does plain TCP. A new certificate takes effect on restart. Behind a
proxy or load balancer that terminates TLS for you, leave these unset and
list it in `TRUSTED_PROXIES`.

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

## Authentication

Three helpers. Each answers "who is this?" and leaves the policy to you.
There are no closures, so keys live in your state and a short `before`
hook passes them in:

```slang
gc struct App { jwt: zokor.JwtAuth, keys: zokor.ApiKeys }
struct Claims { sub: str, role: str, exp: int }

fn require_user(c: zokor.Ctx[App]) -> opt[http.Response] {
    let r: result[Claims, http.Response] = zokor.bearer_claims(c, c.state.jwt);
    guard let claims = r else let deny = err_of(r) { return some(deny); }
    c.set_local("user_id", claims.sub);
    return none;
}
```

**JWTs**, HS256 through [dolphlabs/jwt](https://github.com/dolphlabs/jwt):
- **Configuration.** `jwt_auth_from(cfg)` reads `JWT_SECRETS`
  (comma-separated, newest first, 32+ bytes each), `JWT_AUDIENCE`,
  `JWT_ISSUER` and `JWT_LEEWAY` (seconds of clock skew, default 30).
- **Checks.** `bearer_claims` checks the signature, algorithm and duplicate
  claims, then `exp` (required), `nbf`, and `aud` and `iss` when
  configured. Only then does it decode the payload into your own claims
  type.
- **Failures.** Every failure gets the same `401` with
  `WWW-Authenticate: Bearer error="invalid_token"`.
  `token_problem(token, auth, now)` gives the reason for your logs.
- **Signing and rotation.** `sign_token(claims, auth)` signs with the
  newest secret. A token signed with an older listed secret still
  verifies, so rotation logs nobody out.

**Basic auth:**
- `basic_credentials(c)` returns the user and password, keeping a colon
  inside the password.
- `basic_matches(creds, user, pass)` compares SHA-256 digests in constant
  time, so neither content nor length leaks through timing.
- `basic_denied(c, realm)` asks the browser to log in.

**API keys:**
- `API_KEYS=billing:key1,search:key2`, 24+ bytes each, is read by
  `api_keys_from(cfg)`.
- `api_key_client(c, keys)` reads `X-Api-Key` and returns the client's
  name, so a request can be traced to who sent it.
- Only SHA-256 digests are kept in memory. Every key is compared, in
  constant time.

## Operator injection (MongoDB)

MongoDB reads a key starting with `$` as an operator. A login handler that
passes the body to a query, with a body like
`{"user":"ada","password":{"$ne":""}}`, matches any password. The guard
works like `express-mongo-sanitize` and is opt-in:

```slang
r.mongo_sanitize(zokor.SanitizeMode.REJECT);   // or zokor.sanitize_from(cfg): MONGO_SANITIZE
```

- **What it checks.** Every key of a JSON body, at any depth and inside
  arrays, and every query-parameter name, decoded first so `%24where` is
  `$where`. A key starting with `$` or containing a `.` is refused.
- **`REJECT`** answers `400 bad_request` naming the key, for example
  `body key 'password.$ne'`. No `before` hook and no handler runs.
- **`STRIP`** removes the offending keys and carries on.
- **What it leaves alone.** Values are never touched, so `"$5 off"` is
  fine. A body that isn't JSON, or isn't valid JSON, is left for the
  handler to refuse.
- **Cost.** With the guard on, a JSON body is parsed once more.

**SQL** has no equivalent on purpose. A blacklist rejects `O'Brien` and
still misses real attacks. The defence is parameterised queries, which the
Postgres helpers use exclusively.

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
- **Deleting.** `clear_cookie(resp, name, path, domain)` removes a cookie
  (`Max-Age=0`, and an `Expires` in 1970 for clients that read only that).
- **Lifetime.** `max_age` (seconds; `-1`, the default, is a session
  cookie) is what every browser uses. Set `expires` too, an instant from
  `timez`, for HTTP clients that only read `Expires`; when both are sent
  `Max-Age` wins:

  ```slang
  ck.max_age = 3600;
  ck.expires = some(timez.now().add(timez.HOUR));   // Expires=<HTTP date>
  ```

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

## Conditional requests

A client that already holds the current version gets `304 Not Modified`
and no body; a write made against a version that is no longer current
gets `412` instead of overwriting someone else's change (RFC 9110 §13):

```slang
fn get_doc(c: zokor.Ctx[App]) -> http.Response {
    let doc = load(c);                                 // has .version, .updated_at
    let tag = zokor.etag_of(to_bytes(to_str(doc.version)));
    if let stop = zokor.preconditions(c, tag, some(doc.updated_at)) {
        return stop;                                   // 304, or 412 on a write
    }
    let resp = zokor.ok_json(json.encode(doc));
    return zokor.with_validators(resp, tag, some(doc.updated_at));
}
```

- **One call for reads and writes.** `preconditions` evaluates `If-Match`,
  `If-Unmodified-Since`, `If-None-Match` and `If-Modified-Since` in the
  order RFC 9110 §13.2.2 sets. A PUT that sends back the ETag it read in
  `If-Match` updates only if nobody changed the resource since: optimistic
  concurrency, no lock. Pass `""` as the tag for a resource that does not
  exist yet, and `If-None-Match: *` means "create, never replace".
- **Comparisons as the RFC has them.** `If-Match` compares strongly, so a
  `W/` tag never matches; `If-None-Match` compares weakly. Tag lists,
  `*`, and all three HTTP date forms are read; a date that is not a valid
  HTTP date is ignored, and a malformed tag never matches.
- **`r.etags()`**, opt in: every `200` answer to a GET or HEAD gets an
  ETag hashed from its body, and a matching `If-None-Match` gets a `304`
  that keeps the other headers (`Cache-Control`, `Vary`, …). A response
  with its own ETag is left alone. It hashes every such body, measured in
  process (`bench/conditional`): about 1.5 µs a request at 128 bytes,
  2.7 µs at 1 KB and 20 µs at 16 KB. With nothing turned on, the request
  path costs what it did. For a large body, a version you already have
  (`preconditions`) is far cheaper than hashing the bytes.

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

## Static files

```slang
let mr = zokor.files_at("/assets", "./public");     // err if not a directory
guard let assets = mr else let e = err_of(mr) { println(e); exit(1); }
assets.max_age = 31536000;                          // hashed names: a year
assets.immutable = true;
r.files(assets);
```

A GET or HEAD under the prefix that no route claims is a file from the
directory:

- **Traversal-safe.** An encoded separator (`%2f`, `%5c`), a `..`, `.` or
  dot-file segment (`.env`, `.git`), a backslash or a NUL is a 404, and
  the file's real path, every symlink resolved, must be inside the
  directory's real path or it is a 404 too: a link cannot lead out.
- **Index files.** A directory answers `index.html` (`mount.index`).
- **Validators.** ETag from size and modification time, Last-Modified,
  and `304`/`412` through `preconditions`.
- **Ranges.** One `Range: bytes=` range is a `206` with `Content-Range`
  (`If-Range` honoured); one past the end a `416`; several ranges get the
  whole file, as RFC 9110 allows.
- **Headers.** Content-Type by extension (unknown types are
  `application/octet-stream`, which `nosniff` keeps from being rendered),
  `Cache-Control` from `max_age` (`no-cache` by default: revalidate every
  time, cheap with the validators) and `Accept-Ranges`.

Files are read into memory, up to `max_size` (64 MB), and the read
blocks a worker: serve an app's own assets this way, and put a CDN in
front of large or busy ones.

## Content negotiation and redirects

Compile the representations a handler can serve at startup:

```slang
let made = zokor.new_negotiator(["application/json", "text/html"], zokor.accept_limits());
guard let formats = made else let e = err_of(made) { println(e); exit(1); }
// Keep formats in the router's state. In the handler:
let picked = zokor.negotiate(c, c.state.formats);
guard let media = picked else let bad = err_of(picked) { return bad; }
// Render the selected representation, then return it with media as Content-Type.
```

`negotiate` combines repeated Accept lines, preserving quoted parameters.
It honors q weights, wildcards and parameter specificity: a specific
`q=0` excludes that representation even when a wildcard permits others.
Equal preferences use specificity, client range order, then startup offer
order. An absent header selects the first offer; an empty header or no
acceptable offer produces the registered `not_acceptable` 406. Malformed
or over-limit headers produce `bad_request` 400 with an `Accept` field.
All these responses carry `Vary: Accept`, alongside compression and CORS
fields. `Negotiator.choose` provides selection without a request context.

`accept_limits()` defaults to 8 KB of combined header values, 64 list
members, 32 parameters per range (including q), 32 offers and 1 KB per
offer. Set these before constructing the negotiator. Configure once and
treat its compiled vectors as immutable.

```slang
let response = zokor.redirect_to("/orders/123"); // checked 303, POST/redirect/GET
let rules = zokor.redirect_rules();             // relative references, 8 KB limit
rules.allow_external = true;
let moved = zokor.redirect_checked(307, "https://app.example.com/orders", rules);
```

Checked helpers return a result; they validate 301/302/303/307/308 and
preserve the destination with an empty body. Relative paths, queries and
fragments are accepted. External HTTP(S) URLs require explicit opt-in;
network-path references (`//host`), credentials, raw whitespace, controls,
backslashes and malformed percent escapes are refused. Other bytes must
be percent-encoded. Errors name the field without echoing the destination.
For variable external destinations, the application chooses its permitted
hosts. The existing `redirect(status, location)` remains the raw
constructor for destinations the application already controls.

## Compression

```slang
r.compress(zokor.compression());       // min_size 1 KB, level 1, text-like types
```

A response is gzipped when the client's `Accept-Encoding` allows it (q
values honoured: `gzip;q=0` refuses it), it is a 2xx other than 204/206
to a method other than HEAD, its body is at least `min_size`, its type is
text, JSON, JavaScript, XML, SVG or form data (or ends in `+json`/`+xml`),
and it has no `Content-Encoding` of its own. Every response that could
have been gzipped carries `Vary: Accept-Encoding`; a strong ETag becomes
weak. Level 1 is the default: on API JSON it keeps nearly all of level
5's saving (14 KB: 36 µs to 10% of the size, against 74 µs) for half the
CPU. Static routes are sent as rendered.

**BREACH.** Over TLS, compressing a response that holds a secret next to
input an attacker controls lets them recover the secret from sizes. Keep
pages that mix the two (a CSRF token and reflected search terms) on a
router without compression.

## Idempotency keys

A client that retries a POST after a timeout must not charge twice. With
`Idempotency-Key` (the IETF draft), it gets the first answer instead:

```slang
let store = zokor.idempotency_redis(redis_pool);   // or idempotency_in_memory()
store.scope_local = "user_id";                       // set by your auth `before`
r.idempotency(store);
```

- **Runs once.** A POST or PATCH with the header runs; its answer is kept
  for 24 hours (`store.ttl`). The same request again gets that answer,
  with `Idempotent-Replayed: true`, and the handler does not run.
- **Refuses misuse.** The key again while the first is still running:
  `409`. The key with a different method, path or body: `422`. A key that
  is not 1–255 printable characters: `400`. `store.required = true` makes
  the header mandatory on POST and PATCH.
- **Scoped.** Keys are per method, route and caller (`scope_local` names
  the local your authentication sets), so one user cannot replay
  another's answer.
- **Only final answers.** A 5xx, 408 or 429 is not kept: the next retry
  runs again. Neither is a body over `store.max_body` (1 MB). A handler
  that panics leaves its key "running" for `store.lock_ttl` (30 s).
- **Shared.** The Redis store claims a key with `SET NX PX`, so instances
  behind a balancer agree; if Redis cannot be reached the request is
  refused with 503 rather than risk running twice. The in-memory store is
  for a single instance.

## Pagination

Offset pages (`?limit=20&offset=40`) and keyset pages (`?limit=20&cursor=…`)
answer in the same envelope, so a client reads every list the same way:

```slang
fn list_orders(c: zokor.Ctx[App]) -> http.Response {
    let pr = zokor.page_of(c, 20, 100);            // default 20, at most 100
    guard let p = pr else let bad = err_of(pr) { return bad; }   // 422, named
    let after = zokor.cursor_parts(p);             // [] on the first page
    // WHERE (created, id) < ($1, $2) ORDER BY created DESC, id DESC LIMIT p.fetch()
    let rows = load_orders(c, after, p.fetch());
    return zokor.cursor_page(c, p, rows, order_key);
}

fn order_key(o: Order) -> [str] { return [o.created, to_str(o.id)]; }
```

```json
{"data":[...],"page":{"limit":20,"cursor":"WyIyMDI2...","next":"WyIyMDI2...","total":null}}
```

- **One row past the page.** `p.fetch()` is `limit + 1`: an extra row
  means there is a next page, without a `COUNT(*)`. `offset_page` takes an
  optional total when the handler has one.
- **Links.** A `Link` header (RFC 8288) carries `rel="next"` (and
  `rel="prev"` for offset pages), keeping the request's other query
  parameters.
- **Checked.** `limit` must be 1 to the maximum; `offset` 0 to 1,000,000
  (deeper: use a cursor); not both `offset` and `cursor`; a cursor this
  API did not issue is refused. Each problem is a named field in a 422.
- **Keyset is the one to use on big tables**: the next page is an index
  range, and rows inserted between requests are neither skipped nor
  repeated. A cursor is opaque base64url of the last row's sort key; a
  client can forge one, but only to read another position of a list it
  may read anyway, so authorise the list, and never put a secret in a key.

## Background jobs

Work on a schedule, and work queued to run later, on slang's tasks:

```slang
let jobs = zokor.new_jobs(state);
jobs.logger = sc.logger;
jobs.zone = timez.load_zone("Europe/Berlin") ?? timez.utc_zone();
jobs.every("digest", "0 9 * * MON-FRI", send_digest, 60 * timez.SECOND);
jobs.handle("welcome_email", send_welcome, 5);        // up to 5 attempts
jobs.start();
// ... in a handler:
jobs.enqueue("welcome_email", to_str(user.id), timez.now());
```

A job is `fn(JobCtx[S]) -> result[int, str]`; the context carries the
state, the job's name, a queued job's payload and attempt, when the run
was due, and a `deadline` to pass to every call that can block.

- **Schedules in a time zone.** Five-field cron (names, ranges, steps,
  `@daily` and friends) read on the zone's clocks, so 09:00 in Berlin
  stays 09:00 across daylight-saving changes (slang's `timez`).
- **One run at a time per job.** A scheduled job due while its last run
  is still going skips that turn, with a warning. Missed turns are not
  replayed after downtime, as in cron.
- **Isolated runs.** Each run is its own task: a panic fails that run,
  logged with the job's name, and the scheduler carries on.
- **Retries.** A queued job that returns `err` or panics is retried after
  1 s, 2 s, 4 s ... (capped at an hour) until its attempts run out, then
  logged and dropped.
- **Shutdown.** On SIGTERM the scheduler stops starting runs within a
  quarter second; runs in progress get the server's shutdown drain.
- **In memory.** Queued jobs are lost when the process stops. Work that
  must survive a restart belongs in a table or a Redis list that a
  scheduled job drains.

Tests set `jobs.clock = timez.fixed_clock(...)` and call
`jobs.tick(instant)` and `jobs.wait_runs(timeout)`: no sleeping.

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

- **Refusals.** `rate_limit` answers a refused request with the
  registered `rate_limited` code (`429`, through your renderer if you set
  one) and `Retry-After` in whole seconds. Refused requests don't count
  against the window.
- **Headers on every answer.** Allowed or refused, a response carries
  `RateLimit-Limit`, `RateLimit-Remaining` and `RateLimit-Reset` (seconds
  until the next request frees up), so well-behaved clients can pace
  themselves.
- **Keys.** The key is yours to choose: an API key, a user, an address.
  An empty key shares one "anonymous" budget. `rate_limit_client(c, l)`
  keys on the client's address, resolved through `TRUSTED_PROXIES`, so a
  client can't escape its limit or spend someone else's by sending a
  header.
- **Concurrency.** The limiter is split into 16 shards, each with its own
  lock, so tasks checking different clients don't wait on each other.
  With 8 tasks: 2.0 µs a check, against 17.3 µs with a single lock.
- **Testing.** `take_at(key, now)` and `check_at(key, now)` take the
  clock as a parameter, so tests need no sleeps.

A `before` hook that lets a request through can still add headers to its
answer with `c.add_header(name, value)`: the limiter uses it, and so can
a hook that refreshes a cookie.

`TokenStore.issue(subject)` returns a 64-hex-character token from
`crypto.rand`; `lookup(token)` gives the subject back (expired tokens
are dropped), `revoke(token)` logs one session out and
`revoke_subject(subject)` all of them. Tokens live in memory: they do
not survive a restart and are not shared between instances.

## Migrations

`make cli` builds `bin/zokor`. Run `bin/zokor migrate [directory]` with
`DATABASE_URL` configured; the default directory is `migrations`. Files
are numbered forward-only SQL, for example `001_create_users.sql`.
Versions must be positive and unique; descriptions use ASCII letters,
digits, underscores or hyphens. Files are ordered numerically.

The runner checks every applied filename and SHA-256 checksum, takes a
Postgres transaction advisory lock, and applies the whole pending batch
in one transaction. A failure rolls back SQL and history together. Keep
applied files unchanged and present; add a new file for every change.
SQL can contain multiple statements, comments and dollar-quoted function
bodies. Explicit transaction/session commands and COPY are refused;
nontransactional operations such as CREATE INDEX CONCURRENTLY belong in
a separate operational procedure.

Services can call `load_migrations(dir, migration_limits())` and
`migrate(pool, migrations, deadline)` at startup. File limits are caller
configurable; the CLI reads `MIGRATION_MAX_FILES` (1000),
`MIGRATION_MAX_FILE_BYTES` (1 MiB), `MIGRATION_MAX_TOTAL_BYTES` (16 MiB),
and `MIGRATION_TIMEOUT_SECONDS` (60, maximum 86400). Errors exit nonzero;
success prints the applied count, including zero for an unchanged schema.

## Metrics

Metrics are opt-in: build `new_metrics(metrics_config())`, check its
result, then call `r.metrics(metrics)`. The default endpoint is
`GET /metrics` (HEAD also works), in Prometheus text format 0.0.4. It
answers on a routing miss, so an explicit service route wins; the
built-in scrape skips `before` hooks and does not count itself.

`zokor_http_requests_total` and `zokor_http_request_duration_seconds`
(cumulative histogram buckets, sum and count) label by method, registered
route pattern and status. Client ids and unmatched paths never become
labels: misses use `__unmatched__`, unknown methods use `OTHER`.
`zokor_http_in_flight` covers dispatch and response writing, including
static responses; panics complete as 500. Idle connections are excluded.

`MetricsConfig` chooses the path, `max_series` (1000), `max_custom` (100),
and increasing `buckets_ns`; exposition uses seconds. Configuration errors
name every bad field. Beyond the series cap, completions increment
`zokor_http_observations_dropped_total`; in-flight accounting still ends.
Counters saturate at the largest integer rather than wrapping.

Register service signals with `metrics.counter("jobs_completed_total",
"Completed jobs")` or `metrics.gauge("queue_depth", "Queued jobs")`;
each returns a checked `Metric`. `add(delta)` rejects negative counter
deltas and overflow; `set(value)` is for gauges. Names use Prometheus
ASCII identifiers, with `zokor_` reserved. Registration, updates and
scrapes are concurrency-safe, and the framework reads no environment
while serving.

## Tracing

Tracing is opt-in: check `new_tracer(trace_config())`, then call
`r.tracing(tracer)` at startup. `c.trace()` returns the request's
`TraceContext` (trace id, incoming parent id, current span id, sampled
bit and vendor state). Missing, invalid or duplicate `traceparent`
headers start a fresh trace; malformed `tracestate` is dropped without
changing a valid parent. Limits default to 256 parent bytes, 512 state
bytes and 32 state members, and can be lowered in `TraceConfig`.

Use `c.trace_request(request)` before an `httpc` call. Check its result;
it returns a copy with lowercase W3C headers and a fresh child span,
without changing the original request or headers. For background work,
pass `c.trace()` explicitly and call `trace_request(context, request)`.
No context lives in thread-local storage.

`c.logger(logger)` binds application log lines to the trace and request
id; `traced_logger(logger, context)` does the same for an explicit
context. Server request records and panic lines carry the same trace id.
JSON logs always include `trace_id` (empty outside a trace); pretty logs
append it when present. Framework errors use the request's `c.errors`
registry: the default envelope includes `error.trace_id` when traced,
and custom renderers receive it in `ErrorView.trace_id`. The startup
registry remains shared and is never mutated per request. Use
`trace_registry(registry, context)` for errors outside a handler.

Sampling is propagated as a flag; this feature supplies context and
correlation, without exporting spans. Entropy failures return an error
from propagation helpers and a registered 500 from request dispatch.
Tracing off creates no per-request context, registry or locals map.
Idempotent replays retain the original response body, including its
original error trace id; the replay's request log records the new trace.

## OpenAPI

Build an OpenAPI 3.1.1 document at startup from `r.routes_list()` and
explicit JSON wire schemas. The generator reads no environment, creates
no endpoint, and does no reflection over slang types.

```slang
let api = zokor.new_openapi("Users API", "1.0.0");
api.schema("User", "{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\"}},\"required\":[\"id\"]}");
let op = zokor.api_operation(zokor.Method.GET, "/users/:id");
op.operation_id = "getUser";
push(op.parameters, zokor.api_parameter("id", "path", "integer"));
push(op.responses, zokor.api_response(200, "User"));
push(op.errors, "not_found");
api.operation(op);
let generated = zokor.openapi_document(r.routes_list(), r.errors, api);
// Check generated before saving or serving its JSON text.
```

`ApiOperation` declares an optional `request_schema`, request media type
and required flag, response status/media/schema pairs, parameters, tags,
summary and description. Schema names refer to registered DTOs;
`string`, `integer`, `number`, `boolean`, `object`, `array` and `null`
are inline primitives. `api_ref(name)` builds a reference definition.
Schemas may use local component JSON pointers and recursive references;
the generator preserves composition, formats and examples. It checks
schema structure and references; services should also validate the full
JSON Schema dialect in their contract checks.

`:id` becomes `{id}` with a required string path parameter unless its
metadata supplies another type. Routes without response metadata get a
`default` response labelled as undeclared; success status and shape are
never inferred. Exact duplicate registrations use the first route,
matching the router. Colliding templates, duplicate operations or ids,
unregistered metadata, invalid parameters, unknown schemas and unknown
error codes are reported together. Unsupported `CONNECT` or wildcard
routes must be explicitly excluded with `api.omit(method, pattern)`.
Use the same method to exclude private routes from a published document.

The document includes registered error codes, statuses and messages in
`x-zokor-error-codes`; an operation's `errors` adds responses grouped by
status. Error body contracts are explicit. For the default renderer,
register `api_default_error_schema()` under your chosen name and set
`api.error_schema` to that name. A custom renderer supplies its own schema
and `api.error_media_type`. Without one, error responses make no body
claim. Authentication metadata is not inferred from hooks; services can
extend the generated JSON with their security schemes and requirements.

`api.limits` defaults to 1000 routes, schemas and entries per metadata
collection, 1 MiB per schema, 16 MiB total schema text and metadata text,
schema depth 32 (maximum 64), and 16 MiB of generated JSON. Limits are
caller-selected. Output preserves route registration order and sorts
schema/error names, so map insertion order does not change it.

## WebSocket

A WebSocket route is a handshake handler plus the handlers for what
happens after it. The handshake goes through the router like any request
-- its `before`s run, so authentication, rate limits and CORS apply --
and once the `101` is written the connection belongs to the socket:

```slang
fn chat_open(c: zokor.Ctx[App]) -> http.Response {
    if c.local("user") == "" {                      // set by an auth before
        return zokor.respond(c.errors, "unauthorized", c.request_id);
    }
    let s = c.socket();                              // not yet open
    s.set_local("user", c.local("user"));
    c.state.hub.join_room(s, "lobby");
    return c.accept_ws();                            // the 101; anything else refuses
}

fn chat_message(app: App, s: zokor.Socket, m: zokor.Message) {
    app.hub.to_room("lobby", s.local("user") + ": " + m.text, s.id);
}

fn chat_left(app: App, s: zokor.Socket, code: int, reason: str) { ... }

r.websocket("/chat", chat_open,
            zokor.ws_route(zokor.ws_allowing(["chat"]), chat_message)
                .on_close(chat_left));
```

`s.send_text`, `s.send_binary` and `s.close(code, reason)` work from any
task -- this socket's handler, another connection's, a background job --
and never wait: a send queues the message, and the connection's writer
task puts it on the wire. A **`Hub`** holds sockets by id and in rooms:
`add`, `join_room`, `leave_room`, `broadcast`, `to_room`, `get`, `count`,
`room_size`. A socket leaves every hub it was in when its connection ends.
The hub is in-process; several instances need their own fan-out between
them (Redis pub/sub, say).

Each connection is two tasks: one reads, decodes and calls the handlers in
order, one message at a time; the other writes. What the settings in
`WsRules` bound, and what happens at each:

- **A client that stops reading** fills its queue (`max_queue`, 256
  messages) and is closed instead of holding memory, or the broadcaster,
  hostage.
- **A peer that vanished** without a FIN is pinged after `ping_interval`
  (25s) of silence and closed `pong_timeout` (20s) later.
- **A handler that panics** closes its connection with 1011; every other
  connection carries on. `on_close` runs once however the connection
  ended, with the peer's code, ours, 1002 for a protocol error or 1006
  when the peer vanished.
- **SIGTERM** closes every open socket with 1001 ("server shutting down"),
  so clients reconnect elsewhere, before the drain.
- **Over TLS** (`TLS_CERT_FILE`) the same route serves `wss://`.

Underneath, a connection is a **state machine, not a socket** (`new_conn`,
`receive`, `pending`): bytes in, whole messages and bytes to send out. That
is what the tests drive without a network, and what refuses, with 1002, an
unmasked client frame, a reserved bit or opcode, a fragmented or oversized
control frame, a length that is not minimally encoded, a continuation with
nothing to continue, a new message before the last finished, text that is
not UTF-8, an invalid close code, and anything over `max_frame_bytes` /
`max_message_bytes`. Ping/pong and the closing handshake are answered by
the connection, because they are protocol rather than application.

### Socket.IO

socket.io clients (socket.io-client 3 and 4: Engine.IO v4, Socket.IO v5)
on the same server, with the same handshake handler shape:

```slang
fn on_chat(app: App, s: zokor.Socket, e: zokor.SioEvent) {
    if e.name == "chat message" {
        app.hub.emit_to_room("lobby", e.namespace, "chat message", e.args_json, s.id);
        if e.ack >= 0 {
            s.ack(e.namespace, e.ack, "[\"delivered\"]");    // the client's callback
        }
    }
}

r.socketio("/socket.io/", chat_open,
           zokor.sio_route(on_chat).on_connect(joined).on_disconnect(left));
```

`on_connect(app, s, namespace, auth_json)` accepts a namespace with
`ok(true)` or refuses it with `err(message)`, which the client sees as a
`connect_error`; without one every namespace is accepted. Events for a
namespace the client is not connected to are dropped. `s.emit`,
`s.emit_with_ack` (the answer arrives as an `Ack` event), `s.ack` and
`s.disconnect_ns` send; `hub.emit_all` and `hub.emit_to_room` encode an
event once for every Socket.IO session they reach. A hub can hold
WebSockets and Socket.IO sessions together: `to_room` reaches the first,
`emit_to_room` the second, so a chat open to both calls both.
`on_disconnect(app, s, namespace, reason)` runs once per connected
namespace with socket.io's reasons (`client namespace disconnect`,
`transport close`, `ping timeout`, `server shutting down`, `server error`
for a panicking handler). The Engine.IO heartbeat is run for you on
`route.settings` (`ping_interval_ms`, `ping_timeout_ms`, `max_payload`).

Both of socket.io's transports are served, so a client needs no options:
it starts on **HTTP long-polling** (a GET that waits for packets, a POST
that carries its own) and moves to WebSocket once a probe over it succeeds,
or stays on polling where WebSockets do not get through. The session -- its
id, hubs, namespaces and locals -- is the same `Socket` throughout, and
handlers cannot tell which transport a packet came by. Polling sessions
live between requests: they are capped by `max_polling_sessions` (10,000;
past it the handshake is answered 503), and one heartbeat task per route
pings them and ends those that stop answering. Two GETs or two POSTs at
once for one session end it, as Engine.IO requires. A polling POST is one
HTTP request, so it is bounded by `MAX_REQUEST_BYTES` (16KB by default):
raise it towards `max_payload` if clients send large events over polling.

**Binary attachments** work both ways. An event's attachments arrive in
`e.attachments` (in order; `args_json` holds a placeholder where each
was), and `s.emit_binary(namespace, name, args_json, [data])` /
`hub.emit_binary_to_room(..)` send them: binary frames over WebSocket,
base64 over polling. An event may carry up to `max_attachments` (16).

`examples/chat` is one room for both kinds of client, served for real:
`make example-chat` runs it against stand-in clients, and
`slangc examples/chat/main.sl --run -- serve` serves it on :8080 for a
browser. Checked against socket.io-client 4.7.5 and the `ws` package.

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
  socket.sl       Socket, Hub: a served connection and its rooms
  ws_serve.sl     r.websocket: the handshake and a connection's two tasks
  sio_serve.sl    r.socketio: Engine.IO sessions over the WebSocket
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

slang's `dev` branch until its next release: typed Postgres mapping needs
the compiler-backed `pg.rows_as`. zokor also needs generic structs and methods
and the `dir` sub-directory pin. HTTPS (`TLS_CERT_FILE`) needs `link.tls_accept`
and served WebSocket and Socket.IO routes need `link.split`, both on
slang's `dev` branch until its next release.

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

## Dependencies: ports and fakes

Use a struct of function values, wired once at startup. A service holds
that port and calls it; concrete database or HTTP clients live in adapters.
Slang has no closures, so pass adapter state explicitly rather than hiding
it in globals:

```slang
pub gc struct StockPort[C] {
    context: C,
    lookup: fn(C, str, str) -> result[opt[Stock], str],
}
// A top-level adapter function has the same signature:
// lookup(context, tenant_id, sku). Startup injects its function and context.
```

The application defines the port. Infrastructure imports that definition
and implements it; application code imports domain types and never the
adapter. The bootstrap imports both and connects them. Tenant identity
remains an explicit argument through each call. An optional result
separates a missing record from an unavailable dependency. The HTTP edge
maps failures to registered errors without exposing adapter diagnostics.

[examples/ports/src/main.sl](examples/ports/src/main.sl) is the worked
example: a tenant-scoped stock service, an immutable memory adapter,
a protected route, and startup configuration. `make example-ports` drives
the real router pipeline without opening sockets. It prints an
unauthenticated 401, the seeded stock, and a registered missing-stock 404.
The existing hello/chat examples keep their behavior.

Application fakes live in `fakes_test.sl`, so the compiler excludes them
from service builds. They supply the same function signature with their
own explicit state, return canned success/absence/failure, and record calls.
Tests prove that invalid input never reaches a port, tenant identity is
passed through, another tenant's record is rejected, unauthenticated HTTP
requests cannot invoke the port, and adapter details do not reach clients.
`make test` lists all four example packages; `make check` also runs its
startup wiring.

For generic application services, use small concrete top-level route
functions in the bootstrap to call the generic HTTP helpers. The example
uses this ordinary function-value pattern for registration and gives tests
their own wrappers. Each adapter owns its concurrency rules: the example
copies its seed data once and never mutates it after startup; a mutable
adapter must synchronize its state.

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

- **The serve loop.** `listen_and_serve` serves HTTP, HTTPS, WebSockets
  and Socket.IO; timeouts, body limits, graceful shutdown, panic
  recovery and a connection cap are done (see above).
- **Middleware**, none of it blocked:
  compression, static files. (A rate limiter and a
  bearer-token store exist; `RateLimit-*` headers and sharding do not.)
- **Enterprise**: migrations, metrics, tracing, pagination, OpenAPI, and
  `zokor check`, the layout checker.
- **Speed, measured.** Several parsers here build output by repeated
  concatenation, which is quadratic in slang today; that audit and the
  benchmarks against Go come first in the todo.

## Contributing and licence

zokor is MIT-licensed ([LICENSE](LICENSE)), by Dolph Tech Limited.
[CONTRIBUTING.md](CONTRIBUTING.md) says how to build, test and send a change;
report security problems privately as [SECURITY.md](SECURITY.md) describes;
everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

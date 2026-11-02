# HTTP APIs

> Build HTTP APIs with Zokor routing, middleware, authentication, validation, uploads, rate limits, caching, pagination, and content negotiation.

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

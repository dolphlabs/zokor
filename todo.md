# zokor todo

Work top to bottom, one item at a time, one branch and one PR each. Tick an
item when it has landed **with its tests**; an item that only has code is not
done. `make check` must stay green after every one.

Every item says what it is, what it depends on, and how we know it is done.
Anything marked **[slang]** is a change to the language or its standard
library, made and merged there first.

## Done

- [x] Router: every HTTP method, `:params`, `*wildcards`, automatic `HEAD` and
  `OPTIONS`, `Allow` on a 405, `501` for an unknown verb
- [x] Groups with nested prefixes and middleware, `guarded` for one route,
  `before`/`after` hooks, request-scoped `set_local` / `local`
- [x] Error registry: every HTTP failure status, one envelope, a replaceable
  renderer, field-level errors
- [x] Configuration: `.env` or any path, environment wins, per-variable
  validation, every problem reported at once, secrets masked
- [x] Uploads: multipart parser, limits, type and extension allowlists, safe
  filenames
- [x] WebSocket (RFC 6455) as a sans-io state machine, and Socket.IO
  (Engine.IO v4 / Socket.IO v5) over it
- [x] JSON: `snake_keys` / `camel_keys`, `decode_failed`, `checker`, `Json`
  values and builder
- [x] Test kit: request builder, response readers; request and session ids
- [x] slang: generic structs and methods, `dir` pins, exportable enums,
  `crypto.sha1`
- [x] **[slang] Generic functions** (generics PR 3): `fn first[T](xs: [T]) -> T`,
  unification, expected-type inference, return-only inference through an
  annotated `let`. Merged in slang PR #187 (`dev`). Unblocks
  `new_router(state)`, `c.dto[T]()`, `c.query_as[T]()`, the serve loop's
  spawned task, and `Group`'s `copied_*` helpers, below.

## 0. First: correctness and speed of what already exists

These come before new features, because a framework that is slow on a large
body is not one anyone can put in front of the internet.

- [x] **[slang] A growable byte and string builder.** `import "builder"`:
  `Str` and `Bytes`, plus `strings.join_bytes` for a `[bytes]` already in
  hand. Merged in slang PR #185. What was 2 seconds for 80 KB is now
  linear; see slang's `bench/builder/`.
- [x] **Performance audit of everything on a request path.** Fixed:
  `errors.quote`, `json.parse_string`/`render`, `json.parse_object`/`rekey`
  (duplicate-key detection was O(k^2) per object), `internal/path.percent_decode`,
  `internal/multipart`'s copy, `internal/sio.escape`, `router.match_segs`'s
  wildcard join, and `ws.Conn.receive` (was re-copying its whole buffer on
  every small read, and joining fragments with `+`). Every case that was
  seconds is now single- or double-digit milliseconds; results and method
  in `bench/audit/RESULTS.md`. Not audited: slang's own `http` package.
- [x] **Benchmarks against Go.** hello-world, JSON echo, and a parameterised
  route, the same three in Go's `net/http` and Fiber; `bench/vs-go/`,
  written up in `docs/benchmarks.md`. Result, honestly: zokor is
  currently 3-5x behind Go net/http, because there is no accept loop yet
  (`listen_and_serve`, below) -- not a routing or JSON problem, the same
  gap shows on a bare `GET /`. Re-run once `listen_and_serve` lands; the
  goal of edging Go stands.

## 1. Language prerequisites

- [x] `new_router(state)` and `new_group(router, prefix)` constructors,
  replacing the seven-field `Router[S] { ... }` literal every service
  wrote by hand. `new_group` is a free-function alias of the existing
  `router.group(prefix)` method, for services that want constructor-style
  naming throughout.
- [x] `zokor.dto[T](c)`: decode a body into `T` and report failure through
  `decode_failed`, in one call -- `let r: result[T, http.Response] =
  zokor.dto(c);`. A free function, not a method on `Ctx[S]`: a generic
  method cannot yet declare a type parameter of its own beyond the
  struct's. Needed `Ctx[S]` to carry its own `errors: Registry` (from the
  router, not the app's own state by convention) so the failure response
  can be built without it.
- [x] `zokor.query_as[T](c)`: the same for the query string --
  `internal/path.query_all` plus a value-shape heuristic (`true`/`false`
  and anything `to_int`/`to_float` accept go in unquoted, everything else
  quoted) build a JSON object slang's own `json.decode` then fills `T`
  from, with the same field-level errors as `dto`. Not a full binder --
  slang has no reflection, so there is no way to ask `T` what type each
  field wants -- but it covers str/int/float/bool fields, which is most
  of them.

## 2. The server edge (blocked on generic functions and the serve loop)

Nothing here can be honest until `listen_and_serve` exists, because they are
properties of the server, not of a handler.

- [x] **`listen_and_serve`**: accept loop that only accepts and spawns, one
  task per connection, keep-alive, HTTP/1.1 pipelining left off. `src/serve.sl`,
  on slang's `http.read`/`http.write` over a `link`, so framing (and the
  request-smuggling refusals that come with it) is the stdlib's, not ours.
  Stops accepting on SIGTERM and drains before returning. `examples/hello`
  is now a real server with a real client over a real socket -- the
  stand-in requests are gone -- and `make check` exercises it end to end.
  Needed two slang fixes: `spawn` of a generic function (PR #188), and
  `crypto.rand`'s libcrypto deadlock (PR #189).
  *Still owed:* `examples/chat`'s stand-in requests, which belong to "wire
  WebSocket and Socket.IO into the loop" below; a request id per request,
  blocked on the second half of the `crypto.rand` bug (it is still unsafe
  from a task that parks on socket I/O, so the loop passes ""); and the
  ~0.5% non-2xx rate on the body-reading path, measured in
  `docs/benchmarks.md` and the first thing to fix here.
- [ ] Timeouts: read header, read body, write, idle. Each configurable, each
  with a default that is safe rather than infinite.
- [ ] Limits: max header bytes, max body bytes (refused at read time with
  `413`, not after buffering), max connections, max requests per connection.
- [ ] Graceful shutdown: stop accepting, drain in-flight requests up to a
  deadline, then close. `proc.shutdown_requested()` and `active_tasks()`
  already exist.
- [ ] Panic recovery per request: a panicking handler answers `500` with the
  request id and the server carries on. `spawn` already isolates a task's
  panic; this surfaces it.
- [ ] TLS termination through slang's `net.tls_*`, or a documented decision to
  leave it to a proxy.
- [ ] Wire WebSocket and Socket.IO into the loop: upgrade a connection in
  place, hand it to `receive`, and run the Engine.IO ping timer.
- [ ] Socket.IO over HTTP long-polling, so a client works without
  `transports: ["websocket"]`; and binary attachment frames.

## 3. Middleware every API needs (none of these is blocked)

All are `before` / `after` hooks that attach to a group, so they can be built
now and tested with the test kit.

- [ ] **Client address and trusted proxies.** `X-Forwarded-For` and
  `Forwarded` are only believed from a proxy you name. Rate limiting and
  logging both need this to be right, so it comes first.
- [ ] **CORS**: allowed origins, methods, headers, credentials, max-age,
  correct `Vary: Origin`, and a real preflight answer.
- [ ] **Security headers**: HSTS, `X-Content-Type-Options`, frame options,
  referrer policy, a configurable CSP; on by default, off by choice.
- [ ] **Rate limiter**: token bucket, per key (address, token, tenant),
  sharded so it does not serialise on one mutex, time injected so it is
  testable, `429` with `Retry-After` and `RateLimit-*` headers. Was in the
  v0.1 scope.
- [ ] **Cookies**: parse, set with every attribute, and signed cookies with a
  rotating key.
- [ ] **Auth helpers**: Bearer extraction (exists), Basic, API keys with
  constant-time comparison, and JWT HS256 sign and verify with `exp` /
  `nbf` / `aud` checks. RS256 once slang can verify it.
- [ ] **Conditional requests**: `ETag`, `Last-Modified`, `If-None-Match`,
  `If-Modified-Since`, `304`.
- [ ] **Compression**: gzip through slang's `compress`, honouring
  `Accept-Encoding`, with a size floor and a content-type allowlist so it is
  never applied to something already compressed.
- [ ] **Static files**: traversal-safe (`..`, symlinks, encoded separators),
  `Range` requests, content types, cache headers, index files.
- [ ] **Structured request logging**: one line per request, JSON, with the
  request id, route *pattern* (not path), status, duration and bytes; sampling
  and redaction of configured headers.
- [ ] **Health**: `/healthz` (process is up) and `/readyz` (dependencies are
  reachable), with a way for a service to register its own checks.
- [ ] Wire `new_request_id` in as middleware: honour an incoming
  `X-Request-Id` when it is well-formed, generate one otherwise.
- [ ] Content negotiation (`Accept`) and redirect helpers.

## 4. What makes it enterprise

- [ ] **Postgres helpers**: pool setup from config, transactions
  (`tx.run(fn)` that commits or rolls back), rows into structs, and the
  error shape for a unique violation. Only one package imports `pg`.
- [ ] **Migrations**: ordered, checksummed, applied in a transaction, with an
  advisory lock so two instances do not race, and a `zokor migrate` command.
- [ ] **Metrics**: Prometheus text format at `/metrics`; request count and
  latency histogram by route pattern, in-flight gauge, and hooks for a
  service's own.
- [ ] **Tracing**: W3C `traceparent` in, propagated to outbound calls, and the
  trace id on every log line and error envelope.
- [ ] **Background work**: a scheduler for periodic jobs and a channel-backed
  queue with retry and backoff, on slang's tasks.
- [ ] **Pagination**: offset and cursor forms, with the `Link` header and a
  response envelope that does not change shape between them.
- [ ] **Idempotency keys** for unsafe methods, stored so a retried `POST`
  returns the first answer.
- [ ] **OpenAPI**: generate a document from `routes_list` plus the declared
  DTOs and the error registry.
- [ ] **Config profiles** (`dev`, `test`, `prod`), and `.env.test` selection
  from the profile.
- [ ] **`zokor check`**: the layout checker. Import direction, only the
  database adapter imports `pg`, every package has tests, routes private by
  default, tenant id an explicit parameter. `tyto`'s `AGENTS.md` is the seed
  and the reason this exists.
- [ ] **Ports and fakes**, documented as *the* dependency pattern: a struct of
  `fn` values wired at startup, and a fake for tests. slang has no reflection
  or closures, so this is the answer to what Spring and Nest do with a
  container; it needs a guide and a worked example, not a framework.

## 5. Shipping it

- [ ] **Docs site**, generated from the README, the `src/` signatures and the
  examples, the way slang's `www/build.py` does. Uses `assets/zokor.png`:
  the header, the social card, and a favicon. The source image is 1024 x 1024
  and 358 KB, so produce sized variants (a 64 px favicon, a ~256 px header,
  a 1200 x 630 card) instead of shipping the original everywhere.
- [ ] `LICENSE` (MIT, Dolph Tech Limited, matching slang), `CONTRIBUTING.md`,
  `SECURITY.md` and a code of conduct.
- [ ] CI: `make check` on Linux and macOS against slang's `dev`, until a
  release has generics, then against that release.
- [ ] First tagged release, `v0.1.0`, once slang has a release that includes
  generic structs, methods and `dir` pins. Until then the README's
  Requirements section is the truth.
- [ ] A `slangc new`-style scaffold: `zokor new <name>` producing a service
  with the layout, config, one route and one test.

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

## 0. First: correctness and speed of what already exists

These come before new features, because a framework that is slow on a large
body is not one anyone can put in front of the internet.

- [ ] **[slang] A growable byte and string builder.** Concatenation is
  quadratic: building 80 KB one byte at a time takes **2 seconds** (10 KB is
  21 ms, 40 KB is 326 ms). slang has no builder, so every parser here that
  appends per byte has this cost. `bytes.Builder` / `strings.Builder` with an
  amortised append and a `finish()`, or make `+=` on a local grow in place.
  *Done when:* the same loop is linear, measured.
- [ ] **Performance audit of everything on a request path.** *Suspected, not
  yet measured*, in this order of concern: `json.parse_string` and `render`
  (per-byte and per-item concatenation, so a 1 MB string field is a
  denial of service), `multipart` header and value copying, `percent_decode`,
  `unquote`, `Router.match_segs` wildcard join, `receive` re-copying its
  buffer on every read. Fix by slicing spans between escapes instead of
  copying bytes, and by the builder above. *Done when:* a benchmark for each
  (router match, JSON parse and render of 1 KB / 100 KB / 1 MB, multipart
  parse of 10 MB, WebSocket frames per second) is checked in and none of
  them scales worse than linearly.
- [ ] **Benchmarks against Go.** The goal is to edge Go for backends, so it
  has to be measured: hello-world, JSON echo, and a parameterised route, the
  same three in Go's `net/http` and Fiber. Numbers go in `docs/`, honestly,
  including where zokor loses.

## 1. Language prerequisites

- [ ] **[slang] Generic functions** (generics PR 3): `fn first[T](xs: [T]) -> T`,
  unification, expected-type inference. This unblocks five things below, each
  currently worked around: `new_router(state)`, `c.dto[CreateOrg]()`, typed
  query binding, the serve loop's spawned task, and the `copied_*` helpers on
  `Group`. *Done when:* each workaround is deleted, not left beside its
  replacement.
- [ ] `new_router(state)` and `new_group(...)` constructors, replacing the
  six-field struct literal every service writes today.
- [ ] `c.dto[T]()`: decode a body into `T` and report failure through
  `decode_failed`, in one call.
- [ ] `c.query_as[T]()`: bind the query string into a struct, with the same
  field-level errors.

## 2. The server edge (blocked on generic functions and the serve loop)

Nothing here can be honest until `listen_and_serve` exists, because they are
properties of the server, not of a handler.

- [ ] **`listen_and_serve`**: accept loop that only accepts and spawns, one
  task per connection, keep-alive, HTTP/1.1 pipelining left off. Turns the
  WebSocket state machine into a running server, and deletes the stand-in
  requests from both examples.
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

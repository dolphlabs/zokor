# zokor todo

Work top to bottom, one item at a time, one branch and one PR each. Tick an
item when it has landed **with its tests**; an item that only has code is not
done. `make check` must stay green after every one. Ticked items are cleared
from this file once landed; their write-ups (what was measured, why each
design was chosen) are in the PR descriptions and in git history -- the
file as it stood before this rewrite is `git show e5cdcaaodo.md`.

Every item says what it is, what it depends on, and how we know it is done.
Anything marked **[slang]** is a change to the language or its standard
library, made and merged there first.

## 0. Before anything else

- [x] **CI on every platform slang ships for.** `.github/workflows/ci.yml`
  already runs `make check` (tests, both examples, the guide's programs,
  `api-check`) against slang's `dev` on every PR and push to `main`/`dev`,
  but on Linux x86_64 only. Add linux-arm64 and macOS (Apple Silicon), the
  other two platforms slang's own CI covers, so a platform-specific break
  in zokor or in slang is caught here rather than by a user. Done in
  #42: a matrix over linux-x86_64, linux-arm64 and macos-arm64.

## 1. Operability: you cannot run what you cannot see

- [ ] **Structured request logging, pluggable.** One record per request:
  time, request id, method, route *pattern* (not the path), status,
  duration, bytes, client address. Decided (2026-10-12):
  - **On by default, off from config** (`LOG_REQUESTS=false`, and a
    `ServerConfig` field).
  - **Beautiful by default, NestJS-style**: `[zokor] <pid>  - <time>
    LOG [Router] GET /users/:id 200 +3ms`, coloured on a TTY, plain
    otherwise; **JSON lines** for production (`LOG_FORMAT=json`). Levels
    (`debug`/`log`/`warn`/`error`), with `LOG_LEVEL`.
  - **Not coupled to one implementation**: the router holds a logger value
    -- a struct of `fn` values (slang has no interfaces or closures), so
    a separate logging package can be injected in its place. zokor ships
    the console logger and a no-op one. Startup lines too (routes mapped,
    listening), as Nest prints.
  - Redaction of configured headers; never a secret, token or body.
  Depends on: client address (below), for the address field.
- [ ] **Client address and trusted proxies.** `X-Forwarded-For` and
  `Forwarded` are believed only from proxies listed in
  `TRUSTED_PROXIES` (comma-separated addresses and CIDRs); otherwise the
  socket's peer is the client. `c.client_ip()`. Logging and the rate
  limiter both use it, so a spoofed header can neither hide a client nor
  frame one.
- [x] **Health and readiness**: `/healthz` (the process is up) and
  `/readyz` (dependencies reachable, through checks a service
  registers), with readiness turning false as graceful shutdown starts so
  a load balancer stops sending traffic before the drain. `r.health()`,
  `r.ready_check(name, fn)`. Answered by the router on a miss, so a
  service's own route wins and no `before` runs; checks run concurrently
  in their own tasks, bounded, a running one joined rather than
  restarted. Not unit-tested: the `shutting_down` answer, since
  `proc.shutdown_requested()` cannot be raised inside `slangc test`
  without stopping the run.
- [ ] **Server-wide connection cap**: a `ServerConfig` limit on open
  connections across every acceptor (a shared, concurrency-safe count);
  past it, accept and close at once rather than let idle connections
  exhaust file descriptors.

## 2. Browser-facing APIs

- [ ] **CORS**: allowed origins, methods, headers, credentials, max-age,
  correct `Vary: Origin`, and a real preflight answer.
- [ ] **Security headers**: HSTS, `X-Content-Type-Options`, frame options,
  referrer policy, a configurable CSP; on by default, off by choice.
- [ ] **Cookies**: parse, set with every attribute (`Secure`,
  `HttpOnly`, `SameSite`, `Max-Age`, `Domain`, `Path`), and signed
  cookies with a rotating key.
- [ ] **Input sanitisation against injection**, opt-in and configurable:
  - **NoSQL (Mongo-style operator injection)**, like `express-mongo-sanitize`:
    object keys starting with `$` or containing `.` in JSON bodies and
    query parameters are rejected (400, the default) or stripped, before a
    body reaches a query built for slang's MongoDB driver
    (`dolphlabs/mongo`) or anything else that treats `$` keys as operators.
  - **SQL**: pattern-blacklisting is not a defence -- it rejects
    `O'Brien` and still misses real attacks. The defence is parameterised
    queries only: the Postgres helpers (section 3) expose no string-built
    SQL, and `zokor check` flags SQL assembled by concatenation.
- [ ] **Auth helpers**: Bearer extraction (exists), opaque bearer
  tokens (`TokenStore`, exists, in memory), Basic, API keys with
  constant-time comparison, and JWT through the `dolphlabs/jwt` package
  (HS256, typed claims) rather than a second implementation here: a
  `before` hook that verifies and puts the claims on the request, with
  `exp` / `nbf` / `aud` checks. Password hashing points at
  `dolphlabs/argon` (Argon2id). RS256 once slang can verify it.
- [ ] **Rate limiter, finished**: `RateLimiter`/`rate_limit` exist
  (sliding window, per key, time injected via `take_at`, `429` +
  `Retry-After`). Still owed: sharding, `RateLimit-*` headers, and keying
  on the trusted client address.

## 3. Building real services

- [ ] **Postgres helpers**: pool setup from config, transactions
  (`tx.run(fn)` that commits or rolls back), rows into structs, and the
  error shape for a unique violation. Parameterised queries only; only one
  package imports `pg`.
- [ ] **MongoDB helpers**: a pool from `MONGODB_URI` through
  `dolphlabs/mongo` (optional, like `redis_from_config`), and the error
  shape for a duplicate key, so a service on Mongo gets what a service on
  Postgres does.
- [ ] **[slang] A sufficient `time` package.** Today it has a monotonic
  clock, wall time and sleep. Missing for real services: calendar time
  (date and time of day, time zones from the system tz database), parsing
  and formatting (RFC 3339 / ISO 8601, RFC 1123 for HTTP dates, custom
  layouts), durations with units, date arithmetic (add months, start of
  day) and comparisons. Built on the existing package, with C interop
  (`localtime_r`, `timegm`, `strftime`) where libc already does it
  right. Scoped and agreed in slang before code; several items below need
  it (HTTP dates for conditional requests, cookie expiry, pagination
  cursors, idempotency TTLs).
- [ ] **Pagination**: offset and cursor forms, with the `Link` header and a
  response envelope that does not change shape between them.
- [ ] **Idempotency keys** for unsafe methods, stored so a retried `POST`
  returns the first answer (in memory, or Redis through `redis_from_config`).
- [ ] **Compression**: gzip through slang's `compress`, honouring
  `Accept-Encoding`, with a size floor and a content-type allowlist so it is
  never applied to something already compressed.
- [ ] **Conditional requests**: `ETag`, `Last-Modified`, `If-None-Match`,
  `If-Modified-Since`, `304`.
- [ ] **Static files**: traversal-safe (`..`, symlinks, encoded separators),
  `Range` requests, content types, cache headers, index files.
- [ ] **Migrations**: ordered, checksummed, applied in a transaction, with an
  advisory lock so two instances do not race, and a `zokor migrate` command.
- [ ] **Metrics**: Prometheus text format at `/metrics`; request count and
  latency histogram by route pattern, in-flight gauge, and hooks for a
  service's own.
- [ ] **Tracing**: W3C `traceparent` in, propagated to outbound calls, and the
  trace id on every log line and error envelope.
- [ ] **Background work**: a scheduler for periodic jobs and a channel-backed
  queue with retry and backoff, on slang's tasks.
- [ ] **OpenAPI**: generate a document from `routes_list` plus the declared
  DTOs and the error registry.
- [ ] **Config profiles** (`dev`, `test`, `prod`), and `.env.test` selection
  from the profile.
- [ ] Content negotiation (`Accept`) and redirect helpers.
- [ ] **`zokor check`**: the layout checker. Import direction, only the
  database adapter imports `pg`, no SQL built by concatenation, every
  package has tests, routes private by default, tenant id an explicit
  parameter. `tyto`'s `AGENTS.md` is the seed and the reason this exists.
- [ ] **Ports and fakes**, documented as *the* dependency pattern: a struct of
  `fn` values wired at startup, and a fake for tests. slang has no reflection
  or closures, so this is the answer to what Spring and Nest do with a
  container; it needs a guide and a worked example, not a framework. The
  logger (section 1) is its first instance.

## 4. Realtime and transport

- [ ] TLS termination through slang's `net.tls_*`, or a documented decision to
  leave it to a proxy.
- [ ] Wire WebSocket and Socket.IO into the loop: upgrade a connection in
  place, hand it to `receive`, and run the Engine.IO ping timer. Also
  replaces `examples/chat`'s stand-in requests.
- [ ] Socket.IO over HTTP long-polling, so a client works without
  `transports: ["websocket"]`; and binary attachment frames.

## 5. Shipping it

- [ ] `LICENSE` (MIT, Dolph Tech Limited, matching slang), `CONTRIBUTING.md`,
  `SECURITY.md` and a code of conduct.
- [ ] **Docs site**, generated from the README, the `src/` signatures and the
  examples, the way slang's `www/build.py` does. Uses `assets/zokor.png`:
  the header, the social card, and a favicon. The source image is 1024 x 1024
  and 358 KB, so produce sized variants (a 64 px favicon, a ~256 px header,
  a 1200 x 630 card) instead of shipping the original everywhere.
- [ ] A `slangc new`-style scaffold: `zokor new <name>` producing a service
  with the layout, config, one route and one test.
- [ ] First tagged release, `v0.1.0`, once a slang release includes what
  zokor needs (generics, `dir` pins, `exclude`, and this year's fixes).
  Until then the README's Requirements section is the truth.

## Performance

- [ ] **The rest of the gap to plain slang** (docs/benchmarks.md, "zokor
  against plain slang"). Landed since it was measured: slang's reactor no
  longer nudges on deadline waits (slang #386, ~2 us a request), joined
  spawns wake no idle worker (#387, -14% to -17% CPU at 1-4 clients), the
  read deadlines share one clock read (#35), and extra response headers
  cost 2 allocations instead of 52 (slang #396). Left, by size: the
  per-request task that isolates handler panics (~1.5 us on Linux), and
  `Ctx`/routing (~1-2 us). Needs a fresh measurement on a quiet host
  before more work. Unreproduced: one c=2000 run on Linux collapsed to
  356 rps with a 9 s p99; six runs after it did not.

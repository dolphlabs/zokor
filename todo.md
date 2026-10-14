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

- [x] **Structured request logging, pluggable.** One record per request:
  time, request id, method, route *pattern* (not the path), status,
  duration, bytes, client address; plus the server's own lines (routes
  mapped, listening, shutting down, stopped, panics, readiness changes).
  On by default; NestJS-style colour on a TTY, JSON lines otherwise;
  `LOG_FORMAT`, `LOG_LEVEL` (`off` included), `LOG_REQUESTS`, `NO_COLOR`.
  A `Logger` is a channel plus a level: `channel_logger` hands records to
  another package, `new_log_format` lends it zokor's formats. The serve
  loop never waits: a full queue drops and counts. Cost measured at ~3
  allocations per request, after slang's channel fix (fix/chan-stale-slots:
  an old channel used to promote every value sent through it). Not done:
  redaction of configured headers -- no header is logged at all, so there
  is nothing to redact until one is.
- [x] **Client address and trusted proxies.** `X-Forwarded-For` and
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
- [x] **Server-wide connection cap**: a `ServerConfig` limit on open
  connections across every acceptor (a shared, concurrency-safe count);
  past it, accept and close at once rather than let idle connections
  exhaust file descriptors. `max_connections` / `MAX_CONNECTIONS`, default
  10,000; past it a `503` with `Retry-After: 1`, refusals logged once a
  second. Also fixed: a failed accept (out of file descriptors) was
  retried at once, forever -- a full core on Linux at the limit; it now
  logs once and backs off 5ms -> 1s.

## 2. Browser-facing APIs

- [x] **CORS**: allowed origins, methods, headers, credentials, max-age,
  correct `Vary: Origin`, and a real preflight answer. `r.cors(policy)` /
  `cors_from(cfg)` (`CORS_*`); applied by the router, so preflights skip
  `before`s and every answer, errors and the panic 500 included, carries
  the headers. Static routes stay static for requests without an Origin.
- [x] **Security headers**: HSTS, `X-Content-Type-Options`, frame options,
  referrer policy, a configurable CSP; on by default, off by choice.
  Applied by the router and baked into static renderings (both the
  keep-alive and the close variant); COOP/CORP opt-in. +10 allocations per
  dynamic response (2 per line in http.write's emit, slang-side).
- [x] **Cookies**: parse, set with every attribute (`Secure`,
  `HttpOnly`, `SameSite`, `Max-Age`, `Domain`, `Path`), and signed
  cookies with a rotating key. Safe defaults, every attribute checked
  (`set_cookie` returns err), `Partitioned`, `__Host-`/`__Secure-` rules,
  HMAC-SHA256 over name and value with `COOKIE_KEYS` rotation and a
  constant-time compare. `expires` (an instant from slang's `timez`) is
  written as `Expires` beside `Max-Age`, and `clear_cookie` sends the 1970
  date for clients that read only `Expires`.
- [x] **Input sanitisation against injection**, opt-in and configurable:
  - **NoSQL (Mongo-style operator injection)**, like `express-mongo-sanitize`:
    object keys starting with `$` or containing `.` in JSON bodies and
    query parameters are rejected (400, the default) or stripped, before a
    body reaches a query built for slang's MongoDB driver
    (`dolphlabs/mongo`) or anything else that treats `$` keys as operators.
  - **SQL**: pattern-blacklisting is not a defence -- it rejects
    `O'Brien` and still misses real attacks. The defence is parameterised
    queries only: the Postgres helpers (section 3) expose no string-built
    SQL, and `zokor check` flags SQL assembled by concatenation.
  Done: `r.mongo_sanitize(mode)` / `MONGO_SANITIZE`, applied by the router
  ahead of every hook. Form bodies are not checked: zokor reads them as
  flat strings, never as objects a `$` key could reach. The SQL side
  lands with the Postgres helpers and `zokor check`.
- [x] **Auth helpers**: Bearer extraction (exists), opaque bearer
  tokens (`TokenStore`, exists, in memory), Basic, API keys with
  constant-time comparison, and JWT through the `dolphlabs/jwt` package
  (HS256, typed claims) rather than a second implementation here: a
  `before` hook that verifies and puts the claims on the request, with
  `exp` / `nbf` / `aud` checks. Password hashing points at
  `dolphlabs/argon` (Argon2id). RS256 once slang can verify it.
  Done: `bearer_claims` (jwt v0.1.0, pinned), `jwt_auth_from` (secret
  rotation, aud/iss, leeway), `basic_credentials`/`basic_matches`,
  `api_keys_from`/`api_key_client`. Password hashing is still a pointer to
  dolphlabs/argon, not a helper here.
- [x] **Rate limiter, finished**: `RateLimiter`/`rate_limit` exist
  (sliding window, per key, time injected via `take_at`, `429` +
  `Retry-After`). Still owed: sharding, `RateLimit-*` headers, and keying
  on the trusted client address. Done: 16 shards (8 tasks on distinct
  keys: 17.3 -> 2.0 us a check), `RateLimit-Limit/-Remaining/-Reset` on
  every answer via the new `c.add_header`, `rate_limit_client`. Left for
  later: a shared store (Redis) for limits across instances; each
  process counts on its own.

## 3. Building real services

- [x] **Postgres helpers**: pool setup from config, transactions
  (`tx.run(fn)` that commits or rolls back), rows into structs, and the
  error shape for a unique violation. Parameterised queries only; only one
  package imports `pg`. Done: `pg_from_config`, `query_all`/`query_one`/
  `rows_as` (rows by column name through JSON), `transaction` (rollback on
  err or panic, connection always returned), `db_failure` (SQLSTATE ->
  409/422/503/500, message withheld). Live tests run on Linux CI against
  postgres:16. Not done: retrying serialization failures, and streaming
  large results into structs (use `pg.stream` directly).
- [ ] **Map rows into structs without JSON text.** `rows_as` renders each
  row as JSON and decodes it: 2.2 us a row over reading cells by hand
  (bench/postgres: 1,000 rows 5.3 ms vs 3.0 ms). The rendering, not the
  decode (0.33 us a row), is the cost: reading every cell as text and
  writing it out again. A direct path needs either slang codegen for
  "decode a struct from (name, value) pairs" or a json.decode that takes
  a token stream; worth it only if row-heavy endpoints show it.
- [ ] **MongoDB helpers**: a pool from `MONGODB_URI` through
  `dolphlabs/mongo` (optional, like `redis_from_config`), and the error
  shape for a duplicate key, so a service on Mongo gets what a service on
  Postgres does.
- [x] **[slang] A sufficient `time` package**: slang's `timez` (slang
  #409): calendar time, RFC 3339 / HTTP / RFC 2822 dates, strftime,
  durations, IANA zones from the system tz database, test clocks and
  cron. Pure slang, no C interop.
- [x] **Pagination**: `page_of` reads and checks `limit` with `offset` or
  `cursor` (a 422 naming each bad one); `offset_page` and `cursor_page`
  answer in one envelope (`data`, `page.limit/offset|cursor/next/prev/
  total`) with a `Link` header that keeps the other query parameters.
  `fetch()` asks for one row past the page, so "is there a next" needs no
  count. Keyset cursors are base64url JSON of the row's sort key.
- [x] **Idempotency keys**: `r.idempotency(store)` -- in memory
  (`idempotency_in_memory`, 16 shards, swept) or Redis
  (`idempotency_redis`, `SET NX PX` so instances agree). A POST/PATCH with
  `Idempotency-Key` runs once; a retry gets the kept answer
  (`Idempotent-Replayed: true`), a retry while it runs 409, the key with
  another body 422. Scoped by method, route and `scope_local` (the
  caller). 5xx/408/429 and bodies over `max_body` are not kept; a panic
  frees the key after `lock_ttl`.
- [x] **Compression**: `r.compress(compression())` gzips 2xx bodies of
  at least 1 KB with an allowlisted type (text, JSON, JS, XML, SVG, form,
  +json/+xml) for clients whose Accept-Encoding allows gzip (q values
  read; `gzip;q=0` refuses), adds `Vary: Accept-Encoding` to every
  variant and weakens a strong ETag. Level 1 by default: 14 KB JSON in
  36 us at 10% of its size (level 5: 74 us, 10%). Not done: static
  routes are sent as rendered (pre-compressing them at registration).
- [x] **Conditional requests**: `preconditions` (RFC 9110 13.2.2 order:
  `If-Match`, `If-Unmodified-Since`, `If-None-Match`, `If-Modified-Since`;
  304 for reads, 412 for writes), `etag_of`, `with_validators`, and an
  opt-in `r.etags()` that hashes 200 GET bodies (`bench/conditional`:
  +1.5 us at 128 B, +2.7 us at 1 KB, +20 us at 16 KB; nothing when off).
  Not done: static routes are not tagged; a native fast hash in slang
  would cut the per-byte cost about tenfold (FNV-1a in slang runs at
  1.1 ns/byte).
- [x] **Static files**: `files_at(prefix, dir)` and `r.files(mount)`.
  Traversal-safe (encoded separators, `..`/`.`/dot-file segments,
  backslashes, NULs: 404; the real path, every symlink resolved, must stay
  under the real root); index files; ETag from size and mtime,
  Last-Modified, 304/412; one `Range` (206, 416, If-Range), several get
  the whole file; Content-Type by extension; Cache-Control per mount
  (`max_age`, `immutable`). Needs slang's fs.realpath/fs.fstat. Not done:
  streaming files larger than `max_size` (64 MB), pre-compressed `.gz`
  variants.
- [x] **A HEAD answer says the GET's `Content-Length`** (RFC 9110 9.3.2).
  The routed calls keep the body; the serve loop writes a HEAD answer
  with slang's `http.write_head` (the length, no body); the public
  `serve`/`serve_frame`/`serve_id` still hand back an empty body.
- [x] **Migrations**: `load_migrations` reads bounded `N_description.sql`
  files in numeric order; `migrate` validates immutable SHA-256 history
  and applies the pending batch in one transaction under a Postgres
  advisory lock. `make cli` builds `bin/zokor migrate [directory]`.
  Tests cover replay, changed/missing history, rollback across files,
  concurrent runners, SQL boundaries, file limits and embedded NULs.
- [x] **Metrics**: `new_metrics` (check its result) and `r.metrics`
  opt into Prometheus `/metrics`, request
  counts and cumulative latency histograms by method/pattern/status,
  and an in-flight gauge balanced on static, dynamic and panic paths.
  Bounded series/custom metrics, counter/gauge registration, escaped
  exposition, concurrent updates and a real blocked-handler scrape are
  tested. Default-off probe: +1 startup allocation (64 bytes), none per
  request; 974 -> 1,000.5 ns medians in ABBA x4, inside the run spread.
- [x] **Tracing**: opt-in W3C `traceparent`/`tracestate` parsing, explicit
  request contexts and outbound request copies with child spans. Context
  survives frame fallback, static dispatch and handler panic isolation.
  Request-bound logging and error registries avoid shared mutation;
  custom renderers receive the trace id. Disabled probe (ABBA x4):
  728.5 -> 714.5 ns medians, inside the spread; +2 startup allocations
  (144 bytes), none per request. Idempotent replay bodies retain their
  original trace id, while each replay's log records its new trace.
  No span exporter is included.
- [x] **Background work**: `new_jobs` -- cron schedules read in a time zone
  (timez), one run at a time per job, missed turns not replayed, each run
  its own task (a panic is that run's failure); an in-memory queue with
  per-kind attempts and exponential backoff (1 s doubling, capped at an
  hour); stops starting runs on SIGTERM. Tests drive it with `tick` on a
  fixed clock. Not done: a durable queue (Redis or Postgres) -- queued
  work is lost on restart.
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
- [ ] **Docs site**, generated from the README, the `zokor/` signatures and the
  examples, the way slang's `www/build.py` does. Uses `assets/zokor.png`:
  the header, the social card, and a favicon. The source image is 1024 x 1024
  and 358 KB, so produce sized variants (a 64 px favicon, a ~256 px header,
  a 1200 x 630 card) instead of shipping the original everywhere.
- [ ] A `slangc new`-style scaffold: `zokor new <name>` producing a service
  with the layout, config, one route and one test.
- [ ] Tag `v0.2.0`, the release the README and the guide pin (`v0.1.0`
  was tagged 2026-09-30, before the `src/` -> `zokor/` rename), once a
  slang release includes what zokor needs (generics, `dir` pins,
  `exclude`, and this year's fixes). Until then the README's
  Requirements section is the truth.

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
- [x] **Index the routes instead of scanning them** (route_index.sl).
  Above 16 routes the router keeps a segment trie in step with `routes`
  at registration; a lookup walks the path's literal and `:param`
  children and takes the smallest matching index whose method fits --
  the route a scan in registration order picks (a differential test
  checks 3,200 random requests over random 60-route routers against the
  scan). Static GETs get an exact path map. Measured, ns per request to
  the last of n one-param routes, dev -> index: 64: 4,600-4,900 ->
  2,100-3,000; 128: 8,300 -> 2,900-3,500; 256: 16,800-18,200 ->
  3,200-3,700; 512: 33,900-34,600 -> 3,300-5,200. Three routes (not
  indexed), ABBA x4: medians 1,612 vs 1,646 ns, inside the spread.
  The frame path and the general one now agree on precedence for an
  indexed router (the frame path used to skip general routes).

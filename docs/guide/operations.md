# Operations

> Configure and operate Zokor services with timeouts, graceful shutdown, HTTPS, logging, background jobs, metrics, tracing, and OpenAPI.

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

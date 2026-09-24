# Benchmarks against Go

The todo item this answers: "the goal is to edge Go for backends, so it has
to be measured... numbers go in docs, honestly, including where zokor
loses." This is that measurement, today, and zokor still loses it -- but
by half what it used to. Read past the headline number for why, and what
closes the rest of the gap.

## The result, in one line (wrk, 2026-09-24)

On this machine (MacBook Pro, i5-8279U, 8 logical / 4 physical cores,
`wrk -t4 -c50 -d15s`, keep-alive, 3 rounds, medians):

| Endpoint | zokor (`perf/http-volume`) | Go `net/http` | Go Fiber |
|---|---|---:|---:|
| `GET /` | **~35.4k** req/s | ~101k req/s | ~117k req/s |
| `GET /users/:id` | **~21.5k** req/s | ~96k req/s | ~112k req/s |

Those two cells are STALE -- they were measured with the frame path
doing the framing work twice (a `parse_frame` rescan inside
`read_frame`, plus a `to_bytes` per route in the matchers). A same-app
A/B under `wrk` (dev app + dev slang vs. dev app + volume slang,
`wrk -t4 -c50 -d15s`, 3 rounds) shows what that cost:

| Endpoint | dev (baseline) | volume, double-framing (before fix) | volume, single pass (after fix) |
|---|---|---:|---:|
| `GET /` | ~51-53k | ~30-39k (**slower than dev**) | ~48-50k (parity) |
| `GET /users/:id` | ~32-34k | ~25-29k (**slower than dev**) | ~34k (parity+) |

So the "dropped even" reading was real and the docs above were wrong
to present the 35k/21k cells as a win: the volume branch, as benched,
was slower than `dev` on the same app. The fix (single framing pass,
inline hot method/path compares, slang `4fd5eb7`) restores parity on
`/` and a touch better on `/users/:id`. The table at the top of this
section still needs a full re-run -- it mixes the stale volume binary
against Go, which is not a comparison. Until that re-run lands, read
the A/B above, not the headline cells.

RSS mid-run (30s soak, same load): zokor ~4.5-5.4 MB, Fiber ~6.9 MB,
`net/http` ~14-15 MB. zokor is the lightest server in the matrix by a
clear margin -- the GC pressure the volume work removed shows up here
first. (RSS was measured on the pre-fix binary; the fix only removes
work, but re-confirm it with the re-run.)

The previous `ab` numbers (zokor ~17.8k vs `net/http` ~53.5k, Sept 22)
are superseded by the wrk matrix above: `wrk` with 4 threads drives
roughly twice the load `ab`'s single thread could, and every server
moved up -- the ratios moved with them. What has NOT changed is the
shape: `/users/:id` costs zokor ~40% against `/`, while both Go
servers lose ~5%. That delta is the per-request work still left, and
it is itemised below.

## Where the gap actually is

Same machine, same tool, matched 200-byte bodies, keep-alive, `-c 50`:

| server | req/s |
|---|---:|
| slang, raw socket, no HTTP parsing | **59,392** |
| Go `net/http`, full parsing | 53,559 |
| slang `http.read` / `http.write` | 20,051 |
| zokor (`listen_and_serve` + router + dispatch) | ~17,800 |

Read it top to bottom:

- **slang's socket layer beats Go's whole HTTP server** -- 59.4k against
  53.6k, doing the same I/O for the same bytes. The scheduler, the green
  threads and the language are not what is costing anything here.
- **slang's `http` package costs 66% of that** -- 59.4k down to 20.1k, a 3x
  drop for parsing a request and serialising a response. Go's entire HTTP
  stack costs it so little that `net/http` still lands above slang's *raw*
  socket floor.
- **zokor costs about 11% on top** -- 20.1k to 17.8k for routing, `Ctx[S]`,
  the hooks and the handler. That is the framework's own overhead and it is
  proportionate.

So the number to fix is the third row, and it is in slang, not here.

## What `perf/http-volume` changed (and what it is worth)

The branch this bench ran on (`perf/http-volume` in both repos) cut
per-request allocation volume ~21% in bytes on the alloc probe (3.74 MB
down to 2.97 MB over 2000 requests) via:

- pre-shaped `http.Response` (no header map on the hot path),
- `parse_frame` / `read_frame` frame dispatch (route on wire offsets,
  one head copy, Request built once for the route that runs),
- `strings.bytes_zero` single-alloc sized serialize,
- `serve_frame` exact/`:id` fast paths (no segs list, no params map
  unless the route needs one).

Against the old `ab` baseline that is roughly a **2x throughput win**
on `GET /` (17.5k under `ab` then, ~35k under `wrk` now -- different
tools, so read the ratio inside each tool, not across them). The
remaining ~3x gap to `net/http` (and ~5x on `/users/:id`) is accounted
for, in order, by:

1. **JSON `+` chains and `to_bytes(body)`** -- `user_json` renders via
   string concatenation and the response copies str to bytes. Untouched
   by this branch; the next 5-8 allocs/request.
2. **`Ctx[S]` maps per request** -- `params` and `locals` maps are built
   even when the route binds nothing. The frame path skips `params`
   only for exact routes; `locals` is always allocated.
3. **Per-request `Request`/`Response` structs** -- fresh GC structs where
   Go pools both. Cheap next to the maps, but still per-request.
4. **Header scans that still copy** -- `find_field`/`value_at` allocate
   per lookup; the close decision and content-type reads each cost one.

### What `http.read` spends it on

Per request, on the hot path:

- `parse_headers` allocates a fresh `map[str]str`, then for **each header**
  allocates a bytes slice for the name, a `str` from it, a lowercased copy
  of that, and the same pair again for the value -- roughly five allocations
  per header, all collected. Go interns the common header names and never
  allocates for them.
- `http.read` calls `copy_wire(buf, filled)`, copying the entire buffered
  request into fresh `bytes` before parsing touches it. Go parses in place
  out of its own buffer.
- Every `Request` and `Response` is a fresh `gc struct`. `net/http` pools
  both.

None of that is exotic to fix, and the ceiling above it is already proven:
59.4k on the same box, in the same language, over the same sockets.

## A note on slang's own `bench/http-static`

slang's suite reports **slang 39,857 vs go 38,439** req/s and reads as
"slang edges Go on HTTP". That number does not survive contact with this
one, for two reasons, and both are in the harness rather than the language:

- **slang's entry does no HTTP.** `bench/http/main.sl` does one `recv`, then
  writes a hardcoded response and returns. Go's entry in the same table is
  full `net/http`, parsing every request. The fair counterpart,
  `bench/http/go_raw/main.go`, is written -- same shape, raw socket,
  goroutine per connection -- and appears in no results table.
- **It never tests keep-alive.** Both entries send `Connection: close`, so
  every request pays a fresh TCP connection and the measurement is bounded
  by connection churn, where nothing can distinguish itself. Measured here
  that way, everything converges: slang raw 13,757, Go raw 14,910, Go
  `net/http` 14,133. The differences only appear once a connection is
  reused, which is how every real server runs.

The language claim looks sound -- the raw row above is the evidence for it.
The HTTP claim is measuring connection setup.

## What was measured

Three endpoints, chosen to cover the shapes a real service has:

| Endpoint | What it exercises |
|---|---|
| `GET /` | request/response overhead alone -- no parsing, no encoding |
| `GET /users/:id` | path-segment matching, building a small JSON body |
| `POST /echo` | decoding a body into a declared struct, re-encoding it |

Built three times, identically in shape, in `bench/vs-go/`:

- **`zokor-server/`** -- zokor's own `listen_and_serve`, `Router[S]` and
  `Ctx[S]`, with the same `zokor.dto` decode path a real handler uses.
  The whole file is the three handlers, a router, and one call.
- **`go-net-http/`** -- Go's stdlib, nothing else: `net/http`'s 1.22+
  `ServeMux` with path patterns, `encoding/json`.
- **`go-fiber/`** -- Go Fiber (fasthttp underneath), the framework people
  reach for over `net/http` specifically for speed, which is the
  comparison that actually matters.

All three keep-alive by default (matching Go's), all three answer the same
bodies for the same requests -- checked by hand before any load was applied.

## Methodology

- **Load generator: `ab` (ApacheBench 2.3)**, not `wrk`. This machine had no
  practical path to `wrk`'s build dependencies (the fetch stalled at
  ~30 KB/s; abandoned after several minutes rather than block the
  benchmark on it). `ab` is single-threaded, so at high concurrency
  against a fast server it can itself become the bottleneck -- a real
  limit on the **absolute** numbers below, especially Fiber's, which is
  fast enough to plausibly saturate `ab` itself. It is much less of a
  concern for the **zokor-vs-Go ratio**, which is what this todo item
  asks for, since a client-side ceiling would compress every server
  toward the same number, not favor one.
- **One machine, client and server sharing 8 logical / 4 physical cores**
  (macOS 15.7.7, x86_64), one server running at a time so the three never
  compete with each other for those cores.
- **Duration-based, not count-based**: each run is 15 seconds
  (`ab -t 15`, with a request cap high enough to never be the limit), at
  two concurrency levels, 50 and 200, with `-k` (keep-alive) throughout.
- `bench/vs-go/run.sh` builds and runs all of this; `results_raw.txt` next
  to it is the unedited `ab` output the table below is drawn from.

## Methodology (wrk matrix, Sept 24)

- **Load generator: `wrk 4.2.0`** (`wrk -t4 -c50 -d15s`), replacing the
  `ab` the old matrix used. `wrk`'s 4 threads drive roughly twice the
  load `ab`'s single thread could -- every server moved up, so compare
  ratios inside one tool, never absolutes across tools. Raw output:
  `/tmp/wrk_matrix.txt` (kept with the run; `results_raw.txt` next to
  `run.sh` is the old `ab` output, retained for history).
- **One machine, client and server sharing 8 logical / 4 physical cores**
  (macOS, x86_64 i5-8279U), one server running at a time so the three never
  compete with each other for those cores.
- **Duration-based**: each cell is 15 seconds at concurrency 50,
  keep-alive throughout, 3 rounds; the table reports medians. The
  `/users/42` cell reuses the `/` connection pattern; `POST /echo` was
  not re-run in this matrix (its row below stands until the volume
  branch re-measures it -- the DTO/`+`-chain path is exactly what the
  next branch changes, so measuring it now would date instantly).
- RSS is `ps -o rss` sampled 5/15/25s into a 30s soak at the same load.

## Results (wrk, medians of 3)

| Endpoint | zokor | Go net/http | Go Fiber |
|---|---|---:|---:|
| `GET /` | 35,414 | 100,861 | 117,148 |
| `GET /users/:id` | 21,405 | 96,462 | 112,738 |

Full rounds in `/tmp/wrk_matrix.txt`. Every run had zero socket errors
except one zokor `/users/42` round (23 timeouts, still 21.4k req/s --
same timeout shape the old `ab` matrix showed at higher concurrency,
worth a note, not a verdict: `wrk` timeouts under GC pauses are the
prime suspect, and the RSS soak is the evidence for where to look).

## Previous results (ab, Sept 22 -- superseded, kept for history)

Requests/second (mean), and the p50/p95/p99 latency `ab` reported, in ms:

### Concurrency 50

| Endpoint | zokor | Go net/http | Go Fiber |
|---|---|---|---|
| `GET /` | 17,468 | 50,859 | 63,614 |
| `GET /users/:id` | 14,942 | 51,351 | 63,885 |
| `POST /echo` | 7,760 (625 failed) | 51,318 | 58,770 |

### Concurrency 200

| Endpoint | zokor | Go net/http | Go Fiber |
|---|---|---|---|
| `GET /` | 17,814 | 51,473 | 60,989 |
| `GET /users/:id` | 14,753 | 51,489 | 62,478 |
| `POST /echo` | 7,759 (674 failed) | 49,843 | 58,461 |

Requests/second, mean. Every Go run had zero failures at both levels; both
zokor GET runs did too.

## The POST failures are a bug, not a measurement

`POST /echo` answers about **0.5% of requests with a non-2xx** (625 of
116,497 at c=50; 674 at c=200) and runs at roughly half the throughput of
the GET routes. Both GET routes are clean, so this is specific to the path
that reads a request body and decodes it.

An earlier version of this benchmark, on the hand-rolled accept loop, saw
the same shape at a far lower rate (0.003%), and four separate isolated
repros -- `json.decode` alone, the content-length parsing alone, bytes
concatenation and slicing under forced GC pressure, and the identical load
against Go net/http repeated four times -- all came back clean. It is not
reproducible without real concurrent socket I/O. It is now frequent enough
to chase properly, and it is the first thing to fix on this path: a
framework that drops one request in two hundred is not one anyone can put
in front of the internet, whatever its throughput says.

Until it is fixed, read the POST row as a bug report rather than a
measurement.

## What building this found

The accept loop this benchmark used to carry was replaced by
`listen_and_serve`, and getting there turned up two real bugs outside
zokor:

- **slang: `spawn` could not target a generic function.** `listen_and_serve[S]`
  has to spawn a per-connection handler taking `Router[S]`. Fixed in slang
  PR #188, along with a related gap where an instance first reached from a
  top-level call was never walked by the dry run.
- **slang: `crypto.rand` deadlocks libcrypto.** Two tasks calling it at
  once park every pool worker inside `CRYPTO_THREAD_write_lock` during
  `RAND_bytes`' lazy DRBG construction. slang PR #189 serializes the call,
  which fixes the CPU-bound case. It does **not** fix it from a task that
  also parks on socket I/O: a stock slang `examples/httpd` serve loop that
  generates a random id per request still dies at two concurrent
  connections. That is why `listen_and_serve` passes an empty request id
  for now, and why wiring ids in properly is still a todo item.

## Reproducing this

```
cd bench/vs-go
./run.sh              # builds all three, runs the full matrix, ~5-6 minutes
```

Requires `ab` (ships with macOS; `apache2-utils` on Debian/Ubuntu) and a Go
toolchain with network access (Fiber is fetched via `go get`). Raw output
lands in `bench/vs-go/results_raw.txt`.

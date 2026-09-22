# Benchmarks against Go

The todo item this answers: "the goal is to edge Go for backends, so it has
to be measured... numbers go in docs, honestly, including where zokor
loses." This is that measurement, today, and zokor loses it. Read past the
headline number for why, and what closes the gap.

## The result, in one line

Against the same three endpoints, zokor currently serves **roughly 3x fewer
requests/second than Go's stdlib `net/http`** on the two GET routes, and
**6.6x fewer** on the JSON POST -- which also fails about half a percent of
its requests, an open bug described below. Fiber is further ahead again.

This now measures zokor's own `listen_and_serve`, not a stand-in: the
hand-rolled accept loop this benchmark used to carry is gone. What is left
of the gap is the server edge's first cut against two servers that
represent years of tuning -- no timeouts, no limits, no buffer reuse
between connections, one 16 KB read buffer and one 16 KB arena allocated
per connection. Those are the next todo items, in that order.

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

## Results

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

## Why, specifically

- **Nothing is reused between connections.** Each one allocates its own
  16 KB read wire and 16 KB response arena, and frees them when it ends.
  `fasthttp` (Fiber) is well known for pooling exactly these; `net/http`
  pools too. This is the single biggest lever still untouched.
- **No timeouts, no limits, no tuning.** Every deadline in the loop is
  `until_never()`, and the read buffer is one fixed size. Both are their
  own todo items, and both exist to make the server correct under abuse
  rather than fast -- but the shape they impose is where tuning lands.
- **`GET /` sets the floor.** It does no routing work worth the name and
  no encoding, and still runs at 17.8k against net/http's 51k. So the gap
  is in the connection lifecycle, not in the router, the JSON encoder, or
  `Ctx[S]` dispatch -- the same conclusion the previous, hand-rolled
  version of this benchmark reached, now measured against the real thing.

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

# Benchmarks against Go

The todo item this answers: "the goal is to edge Go for backends, so it has
to be measured... numbers go in docs, honestly, including where zokor
loses." This is that measurement, today, and zokor loses it. Read past the
headline number for why, and what closes the gap.

## The result, in one line

Against the same three endpoints, zokor currently serves **3-5x fewer
requests/second than Go's stdlib `net/http`**, and further behind Fiber.
The reason is not the router, the JSON encoder, or the `Ctx[S]` dispatch
this benchmark actually exercises -- it's that zokor has no accept loop yet
(`listen_and_serve` is still on the todo list). What's under load here is a
bench-only, minimum-effort loop bolted onto slang's raw `net` primitives
for exactly this measurement, next to two servers that represent years of
production tuning. The comparison is honest about that gap, not despite it.

## What was measured

Three endpoints, chosen to cover the shapes a real service has:

| Endpoint | What it exercises |
|---|---|
| `GET /` | request/response overhead alone -- no parsing, no encoding |
| `GET /users/:id` | path-segment matching, building a small JSON body |
| `POST /echo` | decoding a body into a declared struct, re-encoding it |

Built three times, identically in shape, in `bench/vs-go/`:

- **`zokor/`** -- zokor's `Router[S]`/`Ctx[S]`, the same DTO-decode path a
  real handler uses (`json.decode` into `EchoBody`), behind a **bench-only**
  accept loop built from `net.listen`/`net.accept`/`net.recv`/`net.send`
  and `http.parse`/`http.serialize`. Every line of that loop is commented
  as such; it goes away the day `listen_and_serve` lands.
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
| `GET /` | 15,464 (0/1/34) | 52,613 (1/2/2) | 61,666 (1/1/2) |
| `GET /users/:id` | 14,299 (0/1/26) | 51,190 (1/2/2) | 61,993 (1/1/2) |
| `POST /echo` | 12,151 (0/1/24) | 51,214 (1/2/3) | 57,187 (1/1/2) |

### Concurrency 200

| Endpoint | zokor | Go net/http | Go Fiber |
|---|---|---|---|
| `GET /` | 16,075 (0/3/29) | 50,042 (4/5/8) | 60,375 (3/5/6) |
| `GET /users/:id` | 13,584 (0/4/29) | 50,864 (4/5/8) | 60,100 (3/4/6) |
| `POST /echo` | 11,775 (0/6/28) | 49,814 (4/6/9) | 56,860 (3/5/6) |

At c=200: zokor is **3.1-3.7x** Go net/http's request rate behind on `GET`,
**4.2x** behind on `POST /echo`; **3.8-4.8x** behind Fiber across the board.

Latency tells a more specific story than throughput alone: zokor's p50 is
consistently **at or near 0ms** (ab rounds down; the true median is sub-
millisecond) at both concurrency levels -- it isn't struggling to answer a
given request quickly. What it can't do yet is **accept and frame
connections as fast** as Go's epoll-driven, connection-pooled internals;
the gap is in throughput ceiling, not per-request work, and the long p99
tail (24-34ms against Go's 2-9ms) is the same story from the other end --
a request that lands during a burst waits for the accept loop, not for its
own handler.

## Why, specifically

- **No real accept loop.** `listen_and_serve` -- timeouts, limits, a
  tuned per-connection lifecycle -- is still a todo item. What's running
  here is the minimum needed to put real bytes on a real socket for this
  measurement: one `spawn` per connection, one `net.recv` call at a time,
  no buffer reuse across connections. Go's `net/http` and Fiber's
  `fasthttp` are the product of years of exactly this kind of tuning.
- **Every allocation here is fresh.** Each request's framing
  (`net.recv`'s result, `bytes` concatenation while accumulating a
  request, then slicing it apart) allocates and copies; `fasthttp`
  (Fiber) is well known for pooling aggressively to avoid exactly this.
  slang's GC makes this safe; it does not make it free.
- **This is not a routing or JSON problem.** `GET /` -- no routing
  decision beyond the trivial, no encoding -- shows the same ~3.5x gap as
  `POST /echo`, which does both. The floor is set before either runs.

None of this is a defect in `Router[S]`/`Ctx[S]` as such -- it's the
absence of the thing above them. Closing the gap is `listen_and_serve`'s
job, not the router's, which is exactly why it's the next todo item this
one unblocks nothing new for: it was already next.

## A bug this found, fixed, and one still open

Building this benchmark's accept loop surfaced two real issues, both
**in the bench-only loop, not in zokor's `Router`/`Ctx`**:

- **Fixed**: `read_request` discarded any bytes a `net.recv` call
  over-read past one request's end -- harmless for a fresh connection,
  silently corrupting the next request on a **kept-alive** one, whenever
  the kernel handed back a full request's tail together with the next
  request's opening bytes in the same call. Rewritten as `frame_one`,
  which returns the leftover alongside the framed request and carries it
  into the next call on that connection. `bench/vs-go/zokor/main.sl` has
  the full comment.
- **Open**: even after that fix, `POST /echo` under keep-alive at load
  shows a small number of spurious 400s -- 5/182,412 (0.003%) at c=50,
  10/176,636 (0.006%) at c=200 in the run above. Investigated and
  narrowed, not resolved:
  - Not a `json.decode`/`result` concurrency issue: 400,000 concurrent
    decodes of the same body across 200 tasks, no networking, zero
    failures.
  - Not the `content_length_of` string-parsing chain: 1,000,000 concurrent
    calls, same setup, zero failures.
  - Not `bytes` concatenation/slicing under GC pressure: a from-memory
    two-chunk reconstruction of the exact `frame_one` path, 600,000
    iterations across 200 tasks with `SLANG_GC_THRESHOLD_KB=16` forcing
    frequent collection, zero failures.
  - Not present at all without `-k` (74,512 requests, 0 failures), and
    not present on `GET /users/:id` under the identical `-k -c 200` load
    that fails `POST /echo` (118,954 requests, 0 failures) -- so it needs
    the body-read path specifically, not just keep-alive.
  - Not reproducible against Go net/http under the identical load,
    repeated four times (over 1.6M requests, 0 failures) -- ruling out an
    `ab`-side artifact common to any kept-alive server at this
    concurrency.

  Every isolated repro that removed real socket I/O came back clean, which
  points at the interaction between concurrent `net.recv` parking/resuming
  and GC under sustained load specifically -- plausibly related to the
  hazards already tracked in this project's own notes on green-thread
  concurrency (preempt-disable brackets around C calls, the Darwin
  thread-local hazard). Worth its own investigation with a debug/ASan
  runtime build; out of scope for this todo item, and small enough
  (99.994%-99.997% success) not to block it. Flagged here rather than
  hidden, per this doc's own honesty requirement.

## Reproducing this

```
cd bench/vs-go
./run.sh              # builds all three, runs the full matrix, ~5-6 minutes
```

Requires `ab` (ships with macOS; `apache2-utils` on Debian/Ubuntu) and a Go
toolchain with network access (Fiber is fetched via `go get`). Raw output
lands in `bench/vs-go/results_raw.txt`.

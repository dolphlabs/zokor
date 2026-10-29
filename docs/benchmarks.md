# Benchmarks against Go

The todo item this answers: "the goal is to edge Go for backends, so it has
to be measured... numbers go in docs, honestly, including where zokor
loses." The first section is the current measurement. Everything after
it is earlier runs, kept for the record; where they disagree, the first
section wins.

## Five servers on a quiet Linux host (2026-10-15)

### The short version

- **Plain slang sits between Go's two servers.** It uses 13-36% less CPU
  per request than Go `net/http` on every route and at every concurrency.
  It serves more requests per second than `net/http` everywhere except
  `GET /` and `/users/:id` at c=50, where `net/http` is 3-4% ahead. Fiber
  is the fastest server measured: 14-30% less CPU per request than plain
  slang, and 9-41% more requests per second.
- **zokor costs next to nothing on a static route.** On `GET /` it is
  within 7% of plain slang on CPU and rps, and level on latency, at every
  concurrency.
- **On dynamic routes, zokor's defaults are most of its cost.** With the
  request id and the security headers on, as it ships, `GET /users/:id`
  and `POST /echo` take 1.7-2.4x plain slang's CPU per request. Turn
  those two off (`zokor-min`, whose responses are byte-identical to plain
  slang's) and it is 1.2-1.6x. That is below `net/http` at c=50 and
  c=256, and level with it at c=2000.
- **The biggest single cost was in slang, and its fix is in review.** `crypto.rand`,
  which makes the request id, ran OpenSSL under one process-wide mutex.
  It was 17% of zokor's server CPU at c=50, and the lock is where zokor's
  c=2000 tail came from (p99.9 174-186 ms). slang PR #430 reads the
  kernel's generator instead. With it, the same routes use 13-21% less
  CPU, the c=2000 p99.9 is 53-62 ms, and peak RSS at c=2000 drops from 89
  to 32 MiB.
- **slang uses the least memory.** Plain slang peaked at 5-8 MiB up to 256
  connections and about 30 MiB at 2000. zokor (with #430) peaked at 7-10
  and 32 MiB. Go `net/http` peaked at 13-17 and 68-69 MiB, and Fiber at
  8-19 and 41-75 MiB.
- **No collapse.** 216 samples (12 at c=2000 for each server), zero
  timeouts, errors or bad statuses. The one-off c=2000 collapse to 356 rps
  did not come back. The worst single request in the whole run took
  860 ms, in a zokor `GET /` sample at c=50.

### Setup

- **Host:** a 4 vCPU Intel Xeon @ 2.10 GHz VM, Linux 6.18, 16 GB RAM,
  otherwise idle (load average under 1 before the run).
- **Cores:** the server is pinned to CPUs 0-1 and the load generator to
  CPUs 2-3 (`taskset`), so they never compete. Each runtime is sized to
  its two cores: `SLANG_WORKERS=2`, `GOMAXPROCS=2`.
- **Versions:** slang `dev` at `cfdfdc6`, zokor `dev` at `f8a9a21` with this
  harness (`bench/four-way`),
  Go 1.24.7, Fiber v2.52.15.
- **Load generator:** slang's `bench/latgen`, keep-alive, which times every
  request, so the percentiles are exact rather than estimated.
- **Rounds:** 2 s warm-up, then 10 s measured. Every sample starts a fresh
  server. 3 routes x 3 concurrencies (50, 256, 2000) x 6 servers x 4
  rounds. The order rotates each round and reverses every other round.
  Tables are medians of 4.
- **Servers:**
  - `plain slang` is `bench/vs-slang/plain`: stdlib `http` + `json`, routing
    by hand.
  - `zokor` is `bench/vs-go/zokor-server` as it ships, with the logger off.
    Every response also carries an `x-request-id` and five security headers.
  - `zokor-min` is the same binary with `BENCH_MINIMAL=1`, which turns both
    off, so its bytes match plain slang's.
  - `zokor + slang#430` is `zokor` built against slang PR #430.
  - `Go net/http` and `Go Fiber` are `bench/vs-go/go-net-http` and
    `go-fiber`.
- **What each server sends:** a `GET /users/:id` response is 136 bytes for
  Fiber, 137 for net/http (which adds a trailing newline to the JSON), 175
  for plain slang and zokor-min (which add `; charset=utf-8` and
  `Connection: keep-alive`), and 446 for zokor with its defaults.
- **Metrics:**
  - **rps:** completed requests per second.
  - **Latency:** the client-observed p50, p99, p99.9 and max.
  - **Peak RSS:** the server's resident memory, sampled every 0.2 s.
  - **Server CPU per request:** user + sys from `/proc/<pid>/stat` over the
    measured window, divided by requests.
  - **req/s per core:** 1,000,000 / CPU per request. It is the throughput
    one core of this machine would give if the server kept it busy, and is
    the throughput figure to compare servers by.

The same matrix runs with
`LATGEN=... ROUNDS=4 CONNS="50 256 2000" bench/vs-go/run.sh`.

### Why rps and throughput are reported apart

At c=50, the fastest servers kept their two cores only 67-73% busy, and
the load generator was at 56-65% of its own. Neither side was saturated:
with 50 connections each waiting for its answer, rps there measures
round-trip time through two schedulers and the loopback, not what the
server could do. CPU per request does not depend on that, and it held to
within 10% between rounds in nearly every cell. That is why the analysis
below leans on it, and on req/s per core derived from it.

At c=2000, every server's cores were 92-97% busy, so rps there is close
to the server's real capacity on two cores.

### Throughput: requests per second per server core

`1,000,000 / server CPU µs per request`, so higher is better. This is the
capacity number: what each server would do per core if the load kept it
busy.

| server | `/` 50 | `/` 256 | `/` 2000 | `/users/:id` 50 | 256 | 2000 | `/echo` 50 | 256 | 2000 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| plain slang | 76k | 79k | 74k | 74k | 76k | 66k | 72k | 75k | 66k |
| zokor (defaults) | 74k | 78k | 69k | 43k | 41k | 30k | 37k | 38k | 28k |
| zokor-min | 77k | 80k | 70k | 63k | 61k | 46k | 58k | 58k | 42k |
| zokor + slang#430 | 75k | 77k | 69k | 49k | 48k | 35k | 47k | 45k | 32k |
| Go net/http | 66k | 63k | 51k | 62k | 57k | 49k | 52k | 49k | 42k |
| Go Fiber | 106k | 109k | 103k | 100k | 100k | 87k | 84k | 87k | 79k |

- **Static route:** plain slang and every zokor build sit at 69-80k per
  core. Fiber is at 103-109k and `net/http` at 51-66k. zokor's static
  path answers from bytes built at registration, so no framework code runs.
- **Dynamic routes:** plain slang is at 66-76k per core, ahead of
  `net/http` (42-62k) by 19-57% at every point. zokor-min holds 58-63k at
  c=50 and c=256, level with or above `net/http`, and falls to 42-46k at
  c=2000 (see "Why zokor's cost grows with connections"). zokor as it
  ships is at 28-43k, and 32-49k with #430.
- **`net/http` degrades with connections**, losing 19-23% per core between
  c=50 and c=2000. Plain slang loses 3-11% and Fiber 3-13%.

### Requests per second, as measured

| server | `/` 50 | `/` 256 | `/` 2000 | `/users/:id` 50 | 256 | 2000 | `/echo` 50 | 256 | 2000 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| plain slang | 102k | 134k | 137k | 102k | 130k | 121k | 101k | 129k | 121k |
| zokor (defaults) | 99k | 129k | 129k | 77k | 75k | 54k | 66k | 70k | 51k |
| zokor-min | 105k | 134k | 130k | 105k | 113k | 87k | 99k | 107k | 79k |
| zokor + slang#430 | 100k | 125k | 128k | 86k | 90k | 64k | 83k | 83k | 60k |
| Go net/http | 106k | 114k | 99k | 105k | 104k | 94k | 91k | 90k | 81k |
| Go Fiber | 144k | 166k | 191k | 141k | 152k | 163k | 123k | 141k | 151k |

Read the c=50 column with the caveat above: no server was saturated there.
At c=2000 everything was CPU-bound, and the order is:
- `GET /`: Fiber, then plain slang and zokor, then `net/http`.
- dynamic routes: Fiber, then plain slang, then `net/http` and zokor-min
  together (within 10%), then zokor with #430 and zokor as it ships.

### Latency

p99, ms (the 1-in-100 request):

| server | `/` 50 | `/` 256 | `/` 2000 | `/users/:id` 50 | 256 | 2000 | `/echo` 50 | 256 | 2000 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| plain slang | 3.2 | 7.0 | 24.5 | 2.7 | 7.1 | 27.3 | 2.7 | 7.0 | 26.3 |
| zokor (defaults) | 3.0 | 7.1 | 25.3 | 2.0 | 7.4 | 58.0 | 2.4 | 8.2 | 58.5 |
| zokor-min | 2.1 | 6.9 | 24.9 | 1.7 | 6.7 | 31.9 | 1.6 | 6.4 | 37.4 |
| zokor + slang#430 | 2.9 | 7.4 | 25.2 | 2.1 | 7.0 | 42.0 | 2.0 | 7.9 | 47.9 |
| Go net/http | 3.0 | 7.8 | 35.3 | 2.4 | 8.5 | 35.7 | 2.6 | 9.6 | 43.5 |
| Go Fiber | 4.2 | 6.6 | 19.7 | 4.1 | 7.0 | 23.4 | 4.3 | 7.5 | 24.7 |

p99.9, ms (the 1-in-1000):

| server | `/` 50 | `/` 256 | `/` 2000 | `/users/:id` 50 | 256 | 2000 | `/echo` 50 | 256 | 2000 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| plain slang | 5.2 | 9.6 | 30.7 | 5.1 | 10.5 | 34.1 | 5.1 | 10.5 | 31.2 |
| zokor (defaults) | 5.2 | 10.6 | 34.1 | 4.5 | 13.4 | 186.0 | 4.9 | 13.1 | 173.5 |
| zokor-min | 5.1 | 10.1 | 32.2 | 4.7 | 9.7 | 40.7 | 4.4 | 10.1 | 48.7 |
| zokor + slang#430 | 5.2 | 10.7 | 32.3 | 4.5 | 11.0 | 52.8 | 4.4 | 13.6 | 62.2 |
| Go net/http | 5.8 | 11.8 | 48.8 | 5.8 | 13.2 | 46.5 | 6.0 | 14.7 | 61.5 |
| Go Fiber | 5.1 | 10.1 | 25.1 | 5.1 | 10.5 | 32.7 | 5.9 | 11.3 | 31.9 |

- **p50 tracks rps.** With a fixed number of connections each waiting
  for its answer, median latency is roughly connections / rps (Little's
  law), so it ranks the servers exactly as the rps table does. The
  per-route tables below list it.
- **At c=50 the slang servers have the tighter tail.** zokor-min's p99 is
  1.6-2.1 ms and plain slang's 2.7-3.2 ms. Fiber's is 4.1-4.3 ms, the
  worst here, although its median is the best (0.25 ms).
- **At c=2000, zokor as it ships had the worst tail**: p99.9 174-186 ms on
  the dynamic routes, against 31-62 ms for every other server. The
  extra time was spent waiting on `crypto.rand`'s mutex. With #430 it is
  53-62 ms, and zokor-min, which never calls it, is at 41-49 ms, close to
  `net/http`'s 47-62 ms.
- **The worst single request in 216 samples** took 860 ms: one zokor
  `GET /` sample at c=50, a stall in one round that the other three
  rounds (12-13 ms max) do not show.

### Memory: peak RSS, MiB

| server | `/` 50 | `/` 256 | `/` 2000 | `/users/:id` 50 | 256 | 2000 | `/echo` 50 | 256 | 2000 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| plain slang | 5 | 7 | 29 | 5 | 8 | 30 | 5 | 8 | 29 |
| zokor (defaults) | 7 | 9 | 32 | 11 | 19 | 89 | 11 | 20 | 89 |
| zokor-min | 7 | 9 | 32 | 8 | 10 | 32 | 8 | 10 | 32 |
| zokor + slang#430 | 7 | 9 | 32 | 8 | 10 | 32 | 8 | 10 | 32 |
| Go net/http | 13 | 17 | 69 | 13 | 17 | 68 | 14 | 17 | 68 |
| Go Fiber | 8 | 12 | 41 | 14 | 17 | 66 | 14 | 19 | 75 |

- **slang is the lightest.** Plain slang peaks at 5-8 MiB up to 256
  connections and about 30 MiB at 2000. zokor-min, and zokor with #430,
  add 2-3 MiB on top: 32 MiB at 2000 connections. `net/http` peaks at
  13-17 and 68-69 MiB, and Fiber at 8-19 and 41-75 MiB.
- **The old `crypto.rand` path nearly tripled zokor's peak at c=2000**
  (89 MiB, against 32 MiB with #430 on the same code). It called `malloc`
  and `free` for every draw, from whichever OS thread the task was on, and
  the growth goes away when those calls do. glibc's per-thread malloc
  arenas are the likely mechanism, but this was not measured further.

### Every cell

Medians of 4. Server CPU and req/s per core are the throughput figures.

#### `GET /` (static)

| c | server | rps | p50 ms | p99 ms | p99.9 ms | max ms | peak RSS MiB | server CPU µs/req | req/s per core |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 50 | plain slang | 102.4k | 0.38 | 3.2 | 5.2 | 14 | 5 | 13.2 | 76k |
| 50 | zokor (defaults) | 98.5k | 0.39 | 3.0 | 5.2 | 13 | 7 | 13.5 | 74k |
| 50 | zokor-min | 104.8k | 0.38 | 2.1 | 5.1 | 12 | 7 | 12.9 | 77k |
| 50 | zokor + slang#430 | 100.3k | 0.38 | 2.9 | 5.2 | 12 | 7 | 13.3 | 75k |
| 50 | Go net/http | 106.4k | 0.34 | 3.0 | 5.8 | 11 | 13 | 15.1 | 66k |
| 50 | Go Fiber | 144.0k | 0.25 | 4.2 | 5.1 | 22 | 8 | 9.4 | 106k |
| 256 | plain slang | 133.8k | 1.62 | 7.0 | 9.6 | 33 | 7 | 12.6 | 79k |
| 256 | zokor (defaults) | 129.0k | 1.66 | 7.1 | 10.6 | 32 | 9 | 12.8 | 78k |
| 256 | zokor-min | 133.7k | 1.63 | 6.9 | 10.1 | 29 | 9 | 12.6 | 80k |
| 256 | zokor + slang#430 | 125.3k | 1.70 | 7.4 | 10.7 | 25 | 9 | 13.0 | 77k |
| 256 | Go net/http | 114.1k | 1.93 | 7.8 | 11.8 | 26 | 17 | 16.0 | 63k |
| 256 | Go Fiber | 165.7k | 1.27 | 6.6 | 10.1 | 30 | 12 | 9.2 | 109k |
| 2000 | plain slang | 137.3k | 13.90 | 24.5 | 30.7 | 126 | 29 | 13.5 | 74k |
| 2000 | zokor (defaults) | 128.7k | 14.92 | 25.3 | 34.1 | 118 | 32 | 14.4 | 69k |
| 2000 | zokor-min | 130.4k | 14.83 | 24.9 | 32.2 | 112 | 32 | 14.2 | 70k |
| 2000 | zokor + slang#430 | 128.4k | 14.97 | 25.2 | 32.3 | 125 | 32 | 14.5 | 69k |
| 2000 | Go net/http | 98.7k | 18.71 | 35.3 | 48.8 | 127 | 69 | 19.5 | 51k |
| 2000 | Go Fiber | 191.4k | 9.46 | 19.7 | 25.1 | 121 | 41 | 9.7 | 103k |

#### `GET /users/:id`

| c | server | rps | p50 ms | p99 ms | p99.9 ms | max ms | peak RSS MiB | server CPU µs/req | req/s per core |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 50 | plain slang | 101.7k | 0.39 | 2.7 | 5.1 | 22 | 5 | 13.5 | 74k |
| 50 | zokor (defaults) | 77.1k | 0.56 | 2.0 | 4.5 | 12 | 11 | 23.2 | 43k |
| 50 | zokor-min | 104.7k | 0.40 | 1.7 | 4.7 | 14 | 8 | 15.9 | 63k |
| 50 | zokor + slang#430 | 86.0k | 0.49 | 2.1 | 4.5 | 14 | 8 | 20.2 | 49k |
| 50 | Go net/http | 105.0k | 0.35 | 2.4 | 5.8 | 14 | 13 | 16.1 | 62k |
| 50 | Go Fiber | 141.0k | 0.26 | 4.1 | 5.1 | 13 | 14 | 10.0 | 100k |
| 256 | plain slang | 129.8k | 1.68 | 7.1 | 10.5 | 33 | 8 | 13.2 | 76k |
| 256 | zokor (defaults) | 74.7k | 3.31 | 7.4 | 13.4 | 32 | 19 | 24.3 | 41k |
| 256 | zokor-min | 113.2k | 2.08 | 6.7 | 9.7 | 30 | 10 | 16.3 | 61k |
| 256 | zokor + slang#430 | 89.7k | 2.67 | 7.0 | 11.0 | 34 | 10 | 20.8 | 48k |
| 256 | Go net/http | 104.4k | 2.11 | 8.5 | 13.2 | 21 | 17 | 17.4 | 57k |
| 256 | Go Fiber | 151.6k | 1.37 | 7.0 | 10.5 | 24 | 17 | 10.0 | 100k |
| 2000 | plain slang | 121.4k | 15.99 | 27.3 | 34.1 | 116 | 30 | 15.2 | 66k |
| 2000 | zokor (defaults) | 54.0k | 35.80 | 58.0 | 186.0 | 256 | 89 | 33.9 | 30k |
| 2000 | zokor-min | 87.0k | 22.43 | 31.9 | 40.7 | 89 | 32 | 21.6 | 46k |
| 2000 | zokor + slang#430 | 64.4k | 30.16 | 42.0 | 52.8 | 123 | 32 | 29.0 | 35k |
| 2000 | Go net/http | 94.1k | 19.81 | 35.7 | 46.5 | 113 | 68 | 20.6 | 49k |
| 2000 | Go Fiber | 163.1k | 11.31 | 23.4 | 32.7 | 109 | 66 | 11.5 | 87k |

#### `POST /echo`

| c | server | rps | p50 ms | p99 ms | p99.9 ms | max ms | peak RSS MiB | server CPU µs/req | req/s per core |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 50 | plain slang | 100.9k | 0.39 | 2.7 | 5.1 | 11 | 5 | 13.9 | 72k |
| 50 | zokor (defaults) | 66.5k | 0.66 | 2.4 | 4.9 | 15 | 11 | 26.7 | 37k |
| 50 | zokor-min | 98.5k | 0.45 | 1.6 | 4.4 | 17 | 8 | 17.3 | 58k |
| 50 | zokor + slang#430 | 82.9k | 0.52 | 2.0 | 4.4 | 13 | 8 | 21.2 | 47k |
| 50 | Go net/http | 91.4k | 0.41 | 2.6 | 6.0 | 14 | 14 | 19.1 | 52k |
| 50 | Go Fiber | 122.9k | 0.29 | 4.3 | 5.9 | 32 | 14 | 11.9 | 84k |
| 256 | plain slang | 128.9k | 1.71 | 7.0 | 10.5 | 30 | 8 | 13.4 | 75k |
| 256 | zokor (defaults) | 69.5k | 3.32 | 8.2 | 13.1 | 38 | 20 | 26.1 | 38k |
| 256 | zokor-min | 107.1k | 2.25 | 6.4 | 10.1 | 20 | 10 | 17.4 | 58k |
| 256 | zokor + slang#430 | 83.3k | 2.85 | 7.9 | 13.6 | 36 | 10 | 22.3 | 45k |
| 256 | Go net/http | 89.6k | 2.49 | 9.6 | 14.7 | 33 | 17 | 20.4 | 49k |
| 256 | Go Fiber | 140.8k | 1.48 | 7.5 | 11.3 | 24 | 19 | 11.5 | 87k |
| 2000 | plain slang | 121.0k | 15.98 | 26.3 | 31.2 | 98 | 29 | 15.1 | 66k |
| 2000 | zokor (defaults) | 51.3k | 37.69 | 58.5 | 173.5 | 261 | 89 | 35.6 | 28k |
| 2000 | zokor-min | 79.1k | 24.61 | 37.4 | 48.7 | 123 | 32 | 23.5 | 42k |
| 2000 | zokor + slang#430 | 59.8k | 32.71 | 47.9 | 62.2 | 111 | 32 | 31.1 | 32k |
| 2000 | Go net/http | 81.2k | 22.74 | 43.5 | 61.5 | 138 | 68 | 23.6 | 42k |
| 2000 | Go Fiber | 151.4k | 12.49 | 24.7 | 31.9 | 111 | 75 | 12.6 | 79k |

### Where zokor's cost goes

`GET /users/:id`, server CPU µs per request, matrix medians:

| step | c=50 | c=2000 |
|---|---:|---:|
| plain slang | 13.5 | 15.2 |
| + zokor's path (`zokor-min`) | 15.9 (+2.4) | 21.6 (+6.4) |
| + request id and security headers, with #430 | 20.2 (+4.3) | 29.0 (+7.4) |
| + `crypto.rand` as it is on slang `dev` (= zokor as it ships) | 23.2 (+3.0) | 33.9 (+4.9) |

Separate ablation runs at c=50 split the first two steps. Each was the
same harness, 4 rounds, with one thing removed from the build:
- **Panic isolation, ~2.0 µs.** It is the `spawn` + `join_wait` that runs
  each dynamic handler in its own task, so that a panic answers 500
  instead of leaking the connection. Without it, `zokor` went from 23.2
  to 21.1 µs, and `/echo` from 24.6 to 22.8 µs. It also explains zokor's
  extra 0.14 `sched_yield` and 0.15 context switches per request.
- **Read deadlines, ~0.5 µs**, within the noise. slang #386 took the
  reactor nudge out of deadline waits, and this is what is left of it.
- **`Ctx`, routing and response helpers: under half a microsecond.**
  That is what is left of zokor-min's +2.4 after the two above, and it is
  inside the noise.
- **Security headers, ~1.6 µs, and the request id, ~2.3 µs beyond its
  `crypto.rand` draw.** Each was turned off on its own, against the #430
  build. They add 271 bytes to every response. Each extra header line is
  checked for CR/LF and measured, then written twice, once to size the
  buffer and once to fill it. The id is hex-encoded into a `str` and
  joined to its prefix.

So at c=50, zokor's own routing and context cost under half a
microsecond. The rest is features: isolation (2 µs) and the two default
headers (4 µs). Both headers are on by default for good reasons, so the
fix is to make them cheaper, not to turn them off:
- **Security headers:** precompute their bytes at registration, as the
  static path already does.
- **Request id:** keep a per-connection buffer of random bytes, and
  render the id straight into the response.

### Why zokor's cost grows with connections

From c=50 to c=2000, plain slang's CPU per request rises 1.7 µs and
zokor-min's 5.7 µs. `SLANG_GC_STAT` over 8 s of `/users/:id` shows where
much of the difference is:

| per request | plain c=50 | plain c=2000 | zokor-min c=50 | zokor-min c=2000 |
|---|---:|---:|---:|---:|
| minor GC pause (wall) | 0.17 µs | 0.75 µs | 0.30 µs | 1.96 µs |
| of which marking | 0.01 µs | 0.14 µs | 0.06 µs | 1.22 µs |

Both servers walk the same ~2000 parked connection tasks on every minor
collection. Marking takes about 6x as long for zokor-min, so each idle
zokor connection holds far more for the collector to scan. Its parked
frames are deeper: `serve_counted` -> `serve_conn` -> `read_frame`, with
the router, the config, the logger and two arenas in scope.

A pause stops both workers, so this is roughly 2.4 µs of CPU per
request. That is about 60% of the extra growth. The rest was not
attributed in this run.

Making a parked connection cheaper to scan matters more than any per-request
saving once connection counts are high. There are two ways to do it:
- **Smaller root set:** hoist what `serve_conn` keeps live while parked.
- **slang:** skip unchanged parked stacks on a minor collection.

### What is left between slang and Go

Kernel-side counts per request (`perf stat`, `/users/:id`, c=50):

| per request | plain slang | zokor | Go net/http | Go Fiber |
|---|---:|---:|---:|---:|
| `epoll_ctl` | 1.98 | 1.95 | 0 | 0 |
| `epoll_wait` | 0.31 | 0.27 | 0 | 0 |
| `futex` | 0.57 | 0.70 | 0.014 | 0.030 |
| context switches | 0.39 | 0.54 | 0.016 | 0.065 |
| socket reads / writes | 1.99 / 1.00 | 1.97 / 1.00 | 1.99 / 1.00 | 1.99 / 1.00 |

All four servers make the same two reads and one write per request: the
request, then an `EAGAIN`, then the answer. The difference is waking up.
- **Go** polls the network from inside its own scheduler, with each
  socket registered once, edge-triggered. It costs no `epoll_ctl` per
  request and almost no thread handoffs.
- **slang:** a parked task re-arms its socket, which comes to two
  `epoll_ctl` calls per request. A separate reactor thread then wakes a
  worker through a futex, about 0.4 context switches per request.

In the profile, context switches and wakeups (`finish_task_switch` plus
`_raw_spin_unlock_irqrestore` on the futex wake path) are a quarter of
plain slang's samples, about 3.5 µs of its
13.5. That is the same size as the gap to Fiber. Closing it is a slang
reactor change: register once, edge-triggered, and let an idle worker
poll for itself. zokor can do nothing about it.

### What to do next, by size

1. **Merge slang #430** (`crypto.rand`). It is measured above: -13-21%
   CPU on dynamic routes, the c=2000 tail from 186 to 53 ms, and RSS at
   c=2000 from 89 to 32 MiB.
2. **The parked-connection GC root set**, at high connection counts:
   about 2.4 µs a request at c=2000.
3. **The request id and security headers**, at about 4 µs a request
   together: precompute the header bytes, buffer the randomness, and
   render straight to bytes.
4. **Panic isolation**, about 2 µs. It cannot simply go, because slang
   does not unwind a panicked task. A cheaper `spawn` + `join_wait`, or
   unwinding in slang, would remove it.
5. **slang's reactor**, the gap to Fiber: about 3.5 µs a request in
   context switches and `epoll_ctl`, paid by every slang server.

## Earlier measurements

Everything from here down was measured before 2026-10-15, on a busy
macOS laptop or with `ab`/`wrk`. It is kept for the reasoning it
records. Where its numbers disagree with the section above, the section
above is current.

## zokor against plain slang (2026-10-12)

The framework's own cost, isolated: `bench/vs-slang/plain` serves the
same three routes as `bench/vs-go/zokor-server` with stdlib `http` and no
framework, byte-identical responses. `bench/vs-slang/run.sh` runs both in
ABBA order under `latgen` (every request timed), a fresh server per
sample, and records peak RSS and the server's CPU time per request. On a
busy laptop rps swung 2-4x between samples, so the ratios below use CPU
per request, which held within about 5%.

macOS (i5-8279U, c=50, 6 samples each, medians):

| server CPU per request | plain slang | zokor before | zokor after |
|---|---:|---:|---:|
| `GET /` (static) | 29.3 us | 29.4 us | 29.4 us |
| `GET /users/:id` | 30.2 us | 38.2 us | 38.1 us |
| `POST /echo` | 32.0 us | 47.1 us | **43.8 us** |

Allocations per request (exact, `SLANG_GC_STAT` over 20,000 requests):
`/users/:id` plain 13, zokor 20 -> **17**; `/echo` plain 16, zokor 30 ->
**23**. Peak RSS: zokor 5-9 MiB, plain slang 4-8 MiB.

Where the rest goes, from `perf` on Linux (Ubuntu 24.04 container, server
on 4 cores, `/users/:id`, c=50; plain 30 us, zokor 35-36 us):

- **Deadlines, ~1.4-2.3 us.** Every `recv` with a deadline can nudge
  slang's reactor (an eventfd `write` and a reactor wakeup); plain slang
  waits with `until_never()` and never does. Measured by ablation: the
  same build with every deadline `until_never()` saved 2.3 us at c=50 and
  1.4 us at c=500 and c=2000. The deadlines are zokor's slow-loris
  defence and stay; the fix is in slang's reactor.
- **Panic isolation, ~1.5 us** (about 4 us on macOS). Each dynamic
  request runs its handler in a spawned task so a panic answers `500`.
  It cannot simply go: without it a panicking handler's connection task
  dies with its socket open (measured: 20 panics, 20 leaked descriptors
  and 20 hung clients), because slang does not unwind a panicked task.
  `spawn` + `join_wait` alone costs ~2 us of work but up to 5x that in
  kernel time on an 8-worker pool, from waking idle workers.
- **zokor's own path, ~2 us**: `Ctx`, routing, response helpers.

What changed here: a slang `opt` is a heap object even when `none`, so
the `none`s every dynamic request built (its `Ctx` params and locals, and
`match_static`'s miss) are now one shared value per route, and the static
path answers from a `StaticBody` built at registration. `dto`'s key check
keeps container kinds in a bitmask and every open object's keys in one
list instead of three. The `/users/:id` allocations saved did not move
its CPU measurably; the `/echo` saving did (7%).

## Four servers, and the dynamic-route fix (wrk, 2026-09-29)

Same machine (i5-8279U, 8 logical cores), `wrk -t4 --latency`, 10 s runs
after a 2 s warm-up, keep-alive, 3 rounds with the order rotated, medians.
Client and server share the machine and other programs were running, so
read ratios, not absolutes. "Plain slang" is a stdlib `http` + `json`
server doing the same work with no framework.

| req/s, c=50 | plain slang | zokor (before) | Go `net/http` | Go Fiber |
|---|---:|---:|---:|---:|
| `GET /` | 69.3k | 71.5k | 106.1k | 117.5k |
| `GET /users/:id` | 66.7k | 33.7k | 103.2k | 115.1k |
| `POST /echo` | 56.0k | 14.6k | 87.2k | 110.0k |

zokor matched plain slang on the static route and fell to half and a
quarter of it on the other two. `bench/allocs/` pinned it on allocation:
`dto` rewrote every body's keys before decoding it (79 allocations for a
one-field body), and the fixed-shape JSON helpers went through a builder.
After the fix (todo.md, section 0), same harness, the two zokor builds
alternated run by run:

| req/s | zokor before | zokor after | |
|---|---:|---:|---:|
| `GET /` (control) | 84.0k | 81.4k | 0.97x |
| `GET /users/:id` | 51.2k | 67.4k | **1.32x** |
| `POST /echo` | 19.8k | 50.9k | **2.57x** |

(c=50; c=200 is the same shape: 1.00x, 1.35x, 2.61x. Absolute numbers are
higher than the table above because this pair ran on a quieter machine.)
Allocations per request went 52 -> 31 on `/users/:id` and 149 -> 47 on
`/echo`, against 28 and 36 for plain slang.

What is left is slang's, not zokor's. Throughput: slang's `http` path costs
~67 us of CPU per request against Go's 45 and Fiber's 31. Latency: plain
slang's p50 beats Go's (0.3 ms against ~1.1 ms at c=200) but its p99 is
hundreds of milliseconds, with some requests hitting wrk's 2 s timeout, on
every route -- zokor included, and unchanged by this fix. Measured to be
scheduler wakeup stalls, not GC pauses (the longest collection was 5 ms);
it is on slang's next-steps list. Memory: plain slang peaks at 9.2 MB and
zokor at 14.6 MB, against Go `net/http`'s 17.9 MB and Fiber's 13.5 MB
(macOS physical footprint).

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
the same timeout shape the old `ab` matrix showed at higher
concurrency). GC pauses were the prime suspect when this note was
first written. They are ruled out below.

## Where the tail actually comes from

Re-measured (2026-09-27, current `dev` on both sides, generational GC
included) after `perf/http-volume` landed: `GET /` is clean (94.3k
req/s, p99 4.3ms). `GET /users/:id` at the same `-c50` is not (49.4k
req/s, **p99 840ms-1.1s, 6-13 socket timeouts per round**). GC pauses
were the standing suspect (see the note above, and `serve.sl`'s own
former comment on this). They are not it:

```
SLANG_GC_STAT=1, same load: pause_ns_max=2.8ms (major), 7.9ms (minor).
262 major collections, 258 of them under 1.6ms. Nowhere near the
observed tail.
```

Bisected instead by peeling one layer at a time off the same router,
same machine, same load (`wrk -t4 -c50 -d10s`, `/users/:id`-shaped
route each time):

| what's running | p99 |
|---|---:|
| raw `http.read_frame`/`http.write`, no router at all | 13ms |
| zokor router + `Ctx`, exact-match route (no `:id`, no param map) | 48ms |
| + a param-binding route (`:id` matched, map built, handler ignores it) | 147ms |
| + the actual handler (`c.param` + `user_json_bytes` + `ok_json_bytes`) | 840ms |

Monotonic, not a single toggle -- every layer costs a *little* more
CPU per request, and on this machine (MacBook Pro, 4 physical cores,
shared with an active IDE and background processes at the time of
measurement) that's enough to matter. Confirmed directly by varying
concurrency alone, same binary, same route, nothing else changed:

| `-c` | p99 |
|---|---:|
| 8 | 1.2ms |
| 16 | 2.5ms |
| 32 | 30ms |
| 50 | ~900ms |

Throughput is flat from `-c8` on (40-52k req/s throughout) -- this
machine's real service capacity for this path is already reached well
under `-c50`, and everything past that capacity queues instead of
running, which is exactly the shape queueing delay takes near
saturation (not a step function, a cliff). Go's `net/http`/Fiber stay
clean at this same `-c50` on this same machine (p99 7ms / 2.3ms) --
not because they're immune to the same physics, but because their own
per-request cost is lower, so their saturation point sits further out.

**The honest read: this is a real gap (zokor's dynamic-dispatch cost
pulls its own capacity ceiling down further than it should relative to
Go's), surfaced by a benchmark artifact (this specific machine is
under-cored and was under real background load during measurement) --
not a bug to hunt for. The `-c50` timeout numbers above and in every
older table on this page should be read as "this box's ceiling was
exceeded," not "zokor lost throughput it should have had."** Reducing
per-request dispatch cost (the `Ctx` build, the before/after hook
loops that iterate even when empty, the param map) would push the
ceiling out; it would not eliminate the cliff shape itself, which is
inherent to closed-loop load past any server's real capacity.

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

## The POST failures were a bug -- found and fixed, in slang

**Resolved.** `POST /echo` used to answer 0.5-9% of requests with a
non-2xx under real concurrent load (`"unexpected character '?' (at
byte 0)"` from a body that was completely well-formed) -- both GET
routes were always clean, so it was specific to the one path that
decodes a request body into a declared type.

Root-caused by bisecting isolated repros at each layer of the path
this route actually uses (`Ctx.dto[S,T]`, calling `json.decode`
internally): slang's raw socket read, `c.body_str()` alone, and
`snake_keys(c.body_str())` alone all came back clean at 100,000/100,000
requests; a minimal **slang-only** program (no zokor at all) matching
`dto[S,T]`'s exact shape -- two type parameters, one threaded through a
generic struct argument, decoding a `str` field via `json.decode[T]` --
reproduced the identical failure. This was never a zokor bug: the
corruption was already inside `json.decode`'s own generated code, one
level below anything this framework controls.

The actual bug: `json.decode`'s codegen evaluated a non-trivial
`str`-typed argument TWICE (once for `sl_json_parse`'s pointer
argument, again inside `strlen(...)` for its length) -- each embedding
a separate, allocating call with its own nested safepoint bracket. The
first call's result stopped being rooted the instant its own bracket
exited; a GC collection landing during the second embedding's own
safepoint check-in had nothing marking that first result as live, and
could sweep it before `sl_json_parse` ever read the pointer it was
still holding. Fixed in slang PR #228, on `dev` as of this write-up.
Verified there: 600,000/600,000 clean against both a minimal repro and
this repo's own bench server, at the same concurrency that reproduced
6-9% failures before.

Read the POST rows above as historical -- measured against the buggy
slang, before this fix landed -- not as this framework's current
number. A re-run against fixed slang belongs here next.

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
cd slang/bench/latgen && go build -o /tmp/latgen main.go
LATGEN=/tmp/latgen bench/vs-go/run.sh                          # 2 rounds of c=50, 256
LATGEN=/tmp/latgen ROUNDS=4 CONNS="50 256 2000" bench/vs-go/run.sh   # the matrix above, ~50 min
```

Run it from the zokor checkout. It needs `slangc`, Go (Fiber is fetched
with `go build`), `curl`, `python3` and, for core pinning, `taskset`.
Without `taskset`, client and server share every core and the script
says so. `SERVER_CPUS`, `CLIENT_CPUS`, `SERVERS`, `ROUTES` and `DUR`
override the defaults. The samples land in `$BIN/samples.tsv`, and the
medians print at the end. `bench/vs-slang/run.sh` is the two-server ABBA
form of the same measurement.

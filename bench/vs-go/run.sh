#!/bin/bash
# zokor, plain slang, Go net/http and Go Fiber: the same three routes,
# measured the same way, one server at a time.
#
#   LATGEN=/path/to/latgen bench/vs-go/run.sh
#   ROUNDS=4 DUR=10s CONNS="50 256 2000" bench/vs-go/run.sh
#
# Needs slangc (SLANGC), go, and slang's bench/latgen built as LATGEN:
# latgen times every request, so its percentiles are exact. wrk's tail
# is unreliable on this runtime (slang's bench/latgen/README.md).
#
# `zokor` runs with its defaults, which add a request id and five
# security headers to every response. `zokor-min` is the same binary
# with BENCH_MINIMAL=1, which turns both off, so its bytes match plain
# slang's.
#
# How it is fair:
# - Each sample starts a fresh server, so peak RSS is per sample.
# - The server order is rotated each round, and reversed every other
#   round, so drift on the machine lands on every server alike.
# - With taskset, the server gets SERVER_CPUS and the load generator
#   CLIENT_CPUS, so they do not compete for cores. Every runtime is sized to
#   the server's share: SLANG_WORKERS and GOMAXPROCS = the number of
#   server CPUs.
# - Server CPU time per request (user+sys from ps) is the steady number.
#   rps also depends on the client and on whatever else the host runs.
#   `util` is the server's CPU use as a share of its cores. Below ~0.9 the
#   server was waiting on the client, so its rps is a floor.
#   `cutil` is the same share for the load generator: near 1, the client
#   set the rps.
#
# Output: one tab-separated line per sample in $OUT, then the medians.
set -u
cd "$(dirname "$0")/../.."

SLANGC=${SLANGC:-slangc}
LATGEN=${LATGEN:?set LATGEN to a built slang bench/latgen binary}
ROUNDS=${ROUNDS:-4}
DUR=${DUR:-10s}
WARM=${WARM:-2s}
CONNS=${CONNS:-"50 256"}
ROUTES=${ROUTES:-"root user echo"}
SERVERS=${SERVERS:-"plain zokor zokor-min nethttp fiber"}
BIN=${BIN:-$(mktemp -d)}
OUT=${OUT:-$BIN/samples.tsv}
PORT=${PORT:-18190}
SERVER_CPUS=${SERVER_CPUS:-0,1}
CLIENT_CPUS=${CLIENT_CPUS:-2,3}

ncpus=$(echo "$SERVER_CPUS" | tr ',' '\n' | wc -l)
if command -v taskset >/dev/null; then
    on_server="taskset -c $SERVER_CPUS"
    on_client="taskset -c $CLIENT_CPUS"
else
    echo "no taskset: client and server share every core" >&2
    on_server="" on_client=""
    ncpus=$(getconf _NPROCESSORS_ONLN)
fi

if [ -z "${SKIP_BUILD:-}" ]; then
    "$SLANGC" bench/vs-slang/plain/main.sl -o "$BIN/plain" >/dev/null || exit 1
    "$SLANGC" bench/vs-go/zokor-server/main.sl -o "$BIN/zokor" >/dev/null || exit 1
    (cd bench/vs-go/go-net-http && go build -o "$BIN/nethttp" .) || exit 1
    (cd bench/vs-go/go-fiber && go build -o "$BIN/fiber" .) || exit 1
fi

route_args() {
    case $1 in
        root) echo "-path /" ;;
        user) echo "-path /users/42" ;;
        echo) echo "-path /echo -body {\"message\":\"hi\"}" ;;
    esac
}

wait_ready() {
    for _ in $(seq 1 100); do
        curl -s -o /dev/null "http://127.0.0.1:$1/" && return 0
        sleep 0.05
    done
    echo "server on :$1 never became ready" >&2
    return 1
}

cpu_seconds() {
    ps -o cputime= -p "$1" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }'
}

# The server's own clock ticks (utime+stime), finer than ps's seconds.
cpu_ticks() {
    awk '{ print $14 + $15 }' "/proc/$1/stat" 2>/dev/null || echo ""
}

# sample <server> <route> <conns> <round> <pos>
sample() {
    local srv=$1 route=$2 c=$3 round=$4 pos=$5
    local exe=$srv minimal=0
    if [ "$srv" = zokor-min ]; then exe=zokor minimal=1; fi
    BENCH_MINIMAL=$minimal SLANG_WORKERS=$ncpus GOMAXPROCS=$ncpus PORT=$PORT \
        $on_server "$BIN/$exe" >/dev/null 2>&1 &
    local pid=$!
    wait_ready $PORT || { kill $pid; exit 1; }
    # shellcheck disable=SC2046
    $on_client "$LATGEN" -addr 127.0.0.1:$PORT -c "$c" -d "$WARM" $(route_args "$route") >/dev/null 2>&1
    ( while kill -0 $pid 2>/dev/null; do
          ps -o rss= -p $pid 2>/dev/null; sleep 0.2
      done ) >"$BIN/rss.$pid" &
    local sampler=$!
    local t0 s0 t1 s1
    t0=$(cpu_ticks $pid) s0=$(cpu_seconds $pid)
    # shellcheck disable=SC2046
    $on_client "$LATGEN" -addr 127.0.0.1:$PORT -c "$c" -d "$DUR" -expect-status 200 \
        $(route_args "$route") >"$BIN/lat.txt" 2>&1 &
    local lpid=$! lticks=0 now
    # The client's own CPU, read until it exits (to within 0.1 s): at a
    # client util near 1 the load generator, not the server, set the rps.
    while kill -0 $lpid 2>/dev/null; do
        now=$(cpu_ticks $lpid)
        [ -n "$now" ] && lticks=$now
        sleep 0.1
    done
    wait $lpid
    t1=$(cpu_ticks $pid) s1=$(cpu_seconds $pid)
    kill $pid; wait $pid 2>/dev/null
    wait $sampler 2>/dev/null
    local peak
    peak=$(sort -n "$BIN/rss.$pid" | tail -1)
    rm -f "$BIN/rss.$pid"
    local cpu
    if [ -n "$t0" ] && [ -n "$t1" ]; then
        cpu=$(awk -v a="$t0" -v b="$t1" -v hz="$(getconf CLK_TCK)" 'BEGIN { print (b - a) / hz }')
    else
        cpu=$(awk -v a="$s0" -v b="$s1" 'BEGIN { print b - a }')
    fi
    local reqs rps p50 p99 p999 max bad us util secs
    secs=$(echo "$DUR" | sed 's/s$//')
    reqs=$(sed -n 's/^requests=\([0-9]*\).*/\1/p' "$BIN/lat.txt")
    us=$(awk -v c="$cpu" -v n="$reqs" 'BEGIN { printf "%.2f", (n > 0 ? c * 1e6 / n : 0) }')
    util=$(awk -v c="$cpu" -v s="$secs" -v n="$ncpus" 'BEGIN { printf "%.2f", c / s / n }')
    local cn cutil
    cn=$(echo "$CLIENT_CPUS" | tr ',' '\n' | wc -l)
    [ -z "$on_client" ] && cn=$ncpus
    cutil=$(awk -v t="$lticks" -v hz="$(getconf CLK_TCK)" -v s="$secs" -v n="$cn" 'BEGIN { printf "%.2f", t / hz / s / n }')
    rps=$(sed -n 's/.* rps=\([0-9]*\).*/\1/p' "$BIN/lat.txt")
    bad=$(sed -n 's/.*timeouts=\([0-9]*\) errors=\([0-9]*\) bad_statuses=\([0-9]*\).*/\1+\2+\3/p' "$BIN/lat.txt")
    p50=$(sed -n 's/^p50=\([0-9.]*\).*/\1/p' "$BIN/lat.txt")
    p99=$(sed -n 's/.* p99=\([0-9.]*\).*/\1/p' "$BIN/lat.txt")
    p999=$(sed -n 's/.* p99.9=\([0-9.]*\).*/\1/p' "$BIN/lat.txt")
    max=$(sed -n 's/.* max=\([0-9.]*\).*/\1/p' "$BIN/lat.txt")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$route" "$c" "$round" "$pos" "$srv" "$rps" "$p50" "$p99" "$p999" "$max" \
        "$((peak / 1024))" "$us" "$util" "$cutil" | tee -a "$OUT"
    [ "$bad" = "0+0+0" ] || echo "  WARNING: timeouts+errors+bad_statuses=$bad" >&2
}

# The servers rotated by `round`, reversed on even rounds.
order_for() {
    local round=$1
    # shellcheck disable=SC2206
    local s=($SERVERS)
    local n=${#s[@]} out=() i
    for ((i = 0; i < n; i++)); do
        out+=("${s[$(((i + round - 1) % n))]}")
    done
    if [ $((round % 2)) -eq 0 ]; then
        for ((i = n - 1; i >= 0; i--)); do printf '%s ' "${out[$i]}"; done
    else
        printf '%s ' "${out[@]}"
    fi
}

printf 'route\tconns\tround\tpos\tserver\trps\tp50ms\tp99ms\tp999ms\tmaxms\trss_mib\tcpu_us_req\tutil\tclient_util\n' | tee "$OUT"
for route in $ROUTES; do
    for c in $CONNS; do
        for r in $(seq 1 "$ROUNDS"); do
            pos=1
            for s in $(order_for "$r"); do
                sample "$s" "$route" "$c" "$r" $pos
                pos=$((pos + 1))
            done
        done
    done
done

echo
echo "medians of $ROUNDS ($ncpus server CPUs):"
python3 - "$OUT" "$SERVERS" <<'EOF'
import csv, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
servers = sys.argv[2].split()
keys = []
for r in rows:
    k = (r['route'], int(r['conns']))
    if k not in keys:
        keys.append(k)
print(f"{'route':5} {'c':>5} {'server':8} {'rps':>8} {'p50ms':>7} {'p99ms':>8} {'p99.9ms':>8} {'maxms':>8} {'rssMiB':>6} {'cpu_us':>7} {'util':>5} {'cutil':>5}")
for route, c in keys:
    for s in servers:
        sel = [r for r in rows if r['route'] == route and int(r['conns']) == c and r['server'] == s]
        if not sel:
            continue
        med = lambda col: statistics.median(float(r[col]) for r in sel)
        print(f"{route:5} {c:>5} {s:8} {med('rps'):>8.0f} {med('p50ms'):>7.3f} {med('p99ms'):>8.3f} "
              f"{med('p999ms'):>8.3f} {med('maxms'):>8.1f} {med('rss_mib'):>6.0f} {med('cpu_us_req'):>7.2f} {med('util'):>5.2f} {med('client_util'):>5.2f}")
EOF

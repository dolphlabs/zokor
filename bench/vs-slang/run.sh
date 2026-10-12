#!/bin/bash
# zokor against plain slang: the same three routes, byte-identical
# responses, measured in ABBA order so drift on a shared machine hits
# both servers equally. Each sample starts a fresh server, so peak RSS
# is per-sample, not accumulated across runs.
#
#   bench/vs-slang/run.sh                  # defaults below
#   ROUNDS=3 DUR=10s CONNS="50 256" bench/vs-slang/run.sh
#
# Needs: slangc (SLANGC), and slang's bench/latgen built as LATGEN --
# latgen records every request's latency; wrk's tail is unreliable on
# this runtime (see slang's bench/latgen/README.md).
#
# Output: one line per sample in $OUT (tab-separated), then medians.
#
# A and B name the two binaries in $BIN to compare (default plain and
# zokor, built here). With SKIP_BUILD=1, put any two builds there --
# e.g. an experiment against the current zokor.
set -u
cd "$(dirname "$0")/../.."

SLANGC=${SLANGC:-slangc}
LATGEN=${LATGEN:?set LATGEN to a built slang bench/latgen binary}
ROUNDS=${ROUNDS:-3}
DUR=${DUR:-10s}
CONNS=${CONNS:-"50 256"}
ROUTES=${ROUTES:-"root user echo"}
BIN=${BIN:-$(mktemp -d)}
OUT=${OUT:-$BIN/samples.tsv}
PORT=${PORT:-18190}
A=${A:-plain}
B=${B:-zokor}

if [ -z "${SKIP_BUILD:-}" ]; then
    "$SLANGC" bench/vs-slang/plain/main.sl -o "$BIN/plain" >/dev/null || exit 1
    "$SLANGC" bench/vs-go/zokor-server/main.sl -o "$BIN/zokor" >/dev/null || exit 1
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

# sample <server> <route> <conns> <round> <pos>
sample() {
    local srv=$1 route=$2 c=$3 round=$4 pos=$5
    PORT=$PORT "$BIN/$srv" >/dev/null 2>&1 &
    local pid=$!
    wait_ready $PORT || { kill $pid; exit 1; }
    local peak=0
    ( while kill -0 $pid 2>/dev/null; do
          ps -o rss= -p $pid 2>/dev/null; sleep 0.2
      done ) >"$BIN/rss.$pid" &
    local sampler=$!
    # shellcheck disable=SC2046
    "$LATGEN" -addr 127.0.0.1:$PORT -c "$c" -d "$DUR" -expect-status 200 \
        $(route_args "$route") >"$BIN/lat.txt" 2>&1
    # Server CPU (user+sys) per request: steadier than rps on a shared
    # machine, since time the server spends descheduled is not counted.
    local cpu
    cpu=$(ps -o cputime= -p $pid | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; print s }')
    kill $pid; wait $pid 2>/dev/null
    wait $sampler 2>/dev/null
    peak=$(sort -n "$BIN/rss.$pid" | tail -1)
    rm -f "$BIN/rss.$pid"
    local rps p50 p99 p999 bad reqs us
    reqs=$(sed -n 's/^requests=\([0-9]*\).*/\1/p' "$BIN/lat.txt")
    us=$(awk -v c="$cpu" -v n="$reqs" 'BEGIN { printf "%.2f", (n > 0 ? c * 1e6 / n : 0) }')
    rps=$(sed -n 's/.* rps=\([0-9]*\).*/\1/p' "$BIN/lat.txt")
    bad=$(sed -n 's/.*errors=\([0-9]*\) bad_statuses=\([0-9]*\).*/\1+\2/p' "$BIN/lat.txt")
    p50=$(sed -n 's/^p50=\([0-9.]*\).*/\1/p' "$BIN/lat.txt")
    p99=$(sed -n 's/.* p99=\([0-9.]*\).*/\1/p' "$BIN/lat.txt")
    p999=$(sed -n 's/.* p99.9=\([0-9.]*\).*/\1/p' "$BIN/lat.txt")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$route" "$c" "$round" "$pos" "$srv" "$rps" "$p50" "$p99" "$p999" \
        "$((peak / 1024))" "$us" | tee -a "$OUT"
    [ "$bad" = "0+0" ] || echo "  WARNING: errors+bad_statuses=$bad" >&2
}

printf 'route\tconns\tround\tpos\tserver\trps\tp50ms\tp99ms\tp999ms\trss_mib\tcpu_us_req\n' | tee "$OUT"
for route in $ROUTES; do
    for c in $CONNS; do
        for r in $(seq 1 "$ROUNDS"); do
            # ABBA: alternate which server goes first each round.
            if [ $((r % 2)) -eq 1 ]; then order="$A $B $B $A"
            else order="$B $A $A $B"; fi
            pos=1
            for s in $order; do
                sample "$s" "$route" "$c" "$r" $pos
                pos=$((pos + 1))
            done
        done
    done
done

echo
echo "medians ($B / $A):"
python3 - "$OUT" "$A" "$B" <<'EOF'
import csv, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
a, b = sys.argv[2], sys.argv[3]
keys = sorted({(r['route'], int(r['conns'])) for r in rows})
print(f"{'route':6} {'c':>4} | {'rps B/A':>15} {'ratio':>6} | {'p50 B/A':>11} | {'p99 B/A':>13} | {'p99.9 B/A':>13} | {'rss B/A':>9} | {'cpu us/req B/A':>15}")
for route, c in keys:
    def med(srv, col):
        return statistics.median(float(r[col]) for r in rows
                                 if r['route'] == route and int(r['conns']) == c
                                 and r['server'] == srv)
    z, p = med(b, 'rps'), med(a, 'rps')
    print(f"{route:6} {c:>4} | {z:>7.0f}/{p:<7.0f} {z/p:>6.2f} | "
          f"{med(b,'p50ms'):>5.2f}/{med(a,'p50ms'):<5.2f} | "
          f"{med(b,'p99ms'):>6.2f}/{med(a,'p99ms'):<6.2f} | "
          f"{med(b,'p999ms'):>6.2f}/{med(a,'p999ms'):<6.2f} | "
          f"{med(b,'rss_mib'):>4.0f}/{med(a,'rss_mib'):<4.0f} | "
          f"{med(b,'cpu_us_req'):>6.2f}/{med(a,'cpu_us_req'):<6.2f} "
          f"{med(b,'cpu_us_req')/med(a,'cpu_us_req'):>5.2f}x")
EOF

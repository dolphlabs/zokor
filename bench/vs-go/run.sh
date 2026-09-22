#!/bin/bash
# Builds all three bench servers and runs the same ApacheBench (ab) load
# against each, on the same three endpoints, one server at a time (so
# none compete for the machine's cores while being measured). Raw ab
# output goes to results_raw.txt; docs/benchmarks.md is the honest
# write-up of it.
#
# ab, not wrk: this machine has no working internet path to fetch wrk's
# build dependencies in reasonable time. ab is single-threaded, so at
# high concurrency against a fast server it can itself become the
# bottleneck -- see the "methodology" section of docs/benchmarks.md for
# what that does and doesn't mean, and what to rerun with wrk or hey if
# you have it.
#
# Single machine, client and server sharing cores, is the other
# limitation worth reading there before trusting an absolute number.
set -u
cd "$(dirname "$0")"

TIME_LIMIT=15       # seconds per run (ab's -t)
REQ_CAP=2000000      # -n cap; -t stops it long before this is reached
CONNS="50 200"

ZOKOR_PORT=18081
NETHTTP_PORT=18082
FIBER_PORT=18083

OUT=results_raw.txt
: > "$OUT"

wait_ready() {
    local port=$1
    for _ in $(seq 1 100); do
        if curl -s -o /dev/null "http://127.0.0.1:$port/"; then
            return 0
        fi
        sleep 0.1
    done
    echo "server on :$port never became ready" >&2
    return 1
}

bench_one() {
    local name=$1 port=$2
    {
        echo "=== $name ==="
        for c in $CONNS; do
            echo "--- GET / (c=$c) ---"
            ab -k -t $TIME_LIMIT -n $REQ_CAP -c "$c" "http://127.0.0.1:$port/"
            echo "--- GET /users/42 (c=$c) ---"
            ab -k -t $TIME_LIMIT -n $REQ_CAP -c "$c" "http://127.0.0.1:$port/users/42"
            echo "--- POST /echo (c=$c) ---"
            ab -k -t $TIME_LIMIT -n $REQ_CAP -c "$c" -p echo_body.json -T application/json \
                "http://127.0.0.1:$port/echo"
        done
    } | tee -a "$OUT"
}

echo "building..."
(cd zokor-server && /Users/utee/Documents/slang/slangc main.sl -o zokor_bench) || exit 1
(cd go-net-http && go build -o go_net_http_bench .) || exit 1
(cd go-fiber && go build -o go_fiber_bench .) || exit 1

echo "--- zokor ---"
PORT=$ZOKOR_PORT ./zokor-server/zokor_bench > zokor.runlog 2>&1 &
ZPID=$!
wait_ready $ZOKOR_PORT && bench_one "zokor" $ZOKOR_PORT
kill $ZPID 2>/dev/null
wait $ZPID 2>/dev/null

echo "--- go net/http ---"
PORT=$NETHTTP_PORT ./go-net-http/go_net_http_bench > gonethttp.runlog 2>&1 &
GPID=$!
wait_ready $NETHTTP_PORT && bench_one "go-net-http" $NETHTTP_PORT
kill $GPID 2>/dev/null
wait $GPID 2>/dev/null

echo "--- go fiber ---"
PORT=$FIBER_PORT ./go-fiber/go_fiber_bench > gofiber.runlog 2>&1 &
FPID=$!
wait_ready $FIBER_PORT && bench_one "go-fiber" $FIBER_PORT
kill $FPID 2>/dev/null
wait $FPID 2>/dev/null

echo "done. raw results in $OUT"

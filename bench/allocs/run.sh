#!/bin/bash
# Prints allocations and bytes per operation for bench/allocs/main.sl.
# Usage: bench/allocs/run.sh [path/to/slangc]
set -eu
cd "$(dirname "$0")"
SLANGC=${1:-slangc}
"$SLANGC" main.sl -o allocs_probe >/dev/null
N=100000
base_a=0; base_b=0
for op in noop strip_query id_via_bytes id_via_slice builder_new user_json json_encode_user \
          message_json json_decode_echo snake_keys snake_keys_camel; do
    out=$(OP=$op SLANG_GC_STAT=1 ./allocs_probe 2>&1 >/dev/null | grep -m1 'allocs=')
    a=$(echo "$out" | sed 's/.* allocs=\([0-9]*\).*/\1/')
    b=$(echo "$out" | sed 's/.* alloc_bytes=\([0-9]*\).*/\1/')
    if [ "$op" = noop ]; then base_a=$a; base_b=$b; continue; fi
    awk -v op="$op" -v a="$a" -v b="$b" -v ba="$base_a" -v bb="$base_b" -v n="$N" \
        'BEGIN { printf "%-18s %7.1f allocs  %8.0f bytes\n", op, (a-ba)/n, (b-bb)/n }'
done
rm -f allocs_probe

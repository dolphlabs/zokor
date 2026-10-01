#!/bin/sh
# Every ```slang block in docs/llms-small.txt is a whole program and must
# compile and run as shown -- an agent copies them verbatim, so a block
# that drifts teaches every reader the wrong thing. The blocks import the
# package as a service does, `import "zokor";`; this script stages each
# block two levels below the repo root and points that one import at the
# checkout (`import "../../src" as zokor;`), so it tests this tree, not a
# fetched tag, and needs no network.
#
# PORT=8080 is set because the config block asserts it; harmless to the
# others, which never read the environment.
#
# A block that calls `listen_and_serve*` from the main program serves
# until it is told to stop, so it is run for real: built, started on
# SNIP_PORT, polled on /health until it answers, sent SIGTERM, and must
# then exit 0 having printed "drained" -- the graceful-shutdown recipe
# is tested end to end, not just compiled. Needs curl.
set -eu

SLANGC="${SLANGC:-slangc}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOC="$ROOT/docs/llms-small.txt"
STAGE="$ROOT/.snip_check"

if [ ! -f "$DOC" ]; then
    echo "snippets: $DOC not found" >&2
    exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT INT TERM

awk -v stage="$STAGE" '
    /^```slang$/ {
        n++
        dir = sprintf("%s/b%02d", stage, n)
        system("mkdir -p \"" dir "\"")
        out = dir "/main.sl"
        inb = 1
        next
    }
    /^```$/ { if (inb) { close(out); inb = 0 } next }
    inb && $0 == "import \"zokor\";" { print "import \"../../src\" as zokor;" > out; next }
    inb { print > out }
' "$DOC"

count=0
SNIP_PORT="${SNIP_PORT:-18343}"
for b in "$STAGE"/b*; do
    [ -f "$b/main.sl" ] || continue
    count=$((count + 1))
    name=$(basename "$b")
    if grep -q 'listen_and_serve' "$b/main.sl" && ! grep -q 'spawn zokor.listen_and_serve' "$b/main.sl"; then
        if ! "$SLANGC" "$b/main.sl" -o "$b/app" >"$b/out" 2>&1 </dev/null; then
            echo "snippets: $name FAILED to compile"
            tail -5 "$b/out" >&2
            exit 1
        fi
        PORT="$SNIP_PORT" "$b/app" >"$b/out" 2>&1 </dev/null &
        pid=$!
        up=0
        for _ in $(seq 1 100); do
            if curl -fsS "http://127.0.0.1:$SNIP_PORT/health" >/dev/null 2>&1; then up=1; break; fi
            sleep 0.1
        done
        kill -TERM "$pid" 2>/dev/null || true
        rc=0
        wait "$pid" || rc=$?
        if [ "$up" -ne 1 ] || [ "$rc" -ne 0 ] || ! grep -q '^drained$' "$b/out"; then
            echo "snippets: $name FAILED (served=$up exit=$rc after SIGTERM)"
            tail -5 "$b/out" >&2
            exit 1
        fi
        continue
    fi
    if ! PORT=8080 "$SLANGC" "$b/main.sl" --run >"$b/out" 2>&1 </dev/null; then
        echo "snippets: $name FAILED"
        tail -5 "$b/out" >&2
        exit 1
    fi
done

if [ "$count" -eq 0 ]; then
    echo "snippets: no \`\`\`slang blocks found in $DOC" >&2
    exit 1
fi

echo "PASS llms-small.txt snippets ($count)"

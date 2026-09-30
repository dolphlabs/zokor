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
for b in "$STAGE"/b*; do
    [ -f "$b/main.sl" ] || continue
    count=$((count + 1))
    name=$(basename "$b")
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

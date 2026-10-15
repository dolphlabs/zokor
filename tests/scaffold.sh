#!/bin/sh
# `zokor new`, `zokor newcomp`, `zokor add` and `zokor check`, end to end:
# generate projects against THIS checkout of zokor (pinned through a
# throwaway git repo), build them, add a component and check refusals.
#
# SCAFFOLD_TEST_DATABASE_URL, when set, is an empty database the --db pg
# project's live store tests migrate and use; without it they skip.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLANGC=${SLANGC:-slangc}
ZOKOR="$ROOT/bin/zokor"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

fail() { echo "FAIL scaffold: $*" >&2; exit 1; }

expect_refusal() {
    expected=$1
    shift
    code=0
    out=$("$@" 2>&1) || code=$?
    [ "$code" -ne 0 ] || fail "expected a refusal from: $*"
    case "$out" in
        *"$expected"*) ;;
        *) fail "expected '$expected' from '$*', got: $out" ;;
    esac
}

# The package as it is in this working tree, committed into a repository
# of its own so `slangc get` can pin it.
mkdir -p "$WORK/zokor"
cp -R "$ROOT/zokor" "$ROOT/slang.project" "$ROOT/slang.lock" "$WORK/zokor/"
(cd "$WORK/zokor" && git init -q && git add -A &&
 git -c user.name=scaffold -c user.email=scaffold@localhost commit -qm scaffold &&
 git tag scaffold-test)
PIN="--zokor-git file://$WORK/zokor --zokor-tag scaffold-test"

cd "$WORK"
"$ZOKOR" new demo $PIN >/dev/null
cd demo
for f in AGENTS.md Makefile .env.example .gitignore src/main.sl \
         src/platform/config/settings.sl src/platform/config/settings_test.sl; do
    [ -f "$f" ] || fail "zokor new did not write $f"
done
for f in src/notes/server/server.sl src/platform/app/app.sl src/platform/auth/auth.sl \
         migrations/001_notes.sql; do
    [ ! -e "$f" ] || fail "zokor new unexpectedly wrote $f"
done
find src -type f | LC_ALL=C sort >"$WORK/light-files"
cat >"$WORK/expected-light-files" <<'EOF'
src/main.sl
src/platform/config/settings.sl
src/platform/config/settings_test.sl
EOF
cmp -s "$WORK/light-files" "$WORK/expected-light-files" ||
    fail "zokor new wrote files outside startup and platform/config"
[ ! -e migrations ] || fail "zokor new unexpectedly wrote a migrations directory"
grep -q "pkg zokor git file://$WORK/zokor tag scaffold-test dir zokor" slang.project ||
    fail "slang.project does not pin the requested zokor"
grep -q 'import "platform/config" as config;' src/main.sl ||
    fail "zokor new did not wire platform config into src/main.sl"
"$SLANGC" get >/dev/null
make test SLANGC="$SLANGC" >"$WORK/test.log" 2>&1 || { cat "$WORK/test.log"; fail "a new project's tests fail"; }
make build SLANGC="$SLANGC" >/dev/null 2>&1 || fail "a new project does not build"
"$ZOKOR" check >/dev/null || { "$ZOKOR" check; fail "zokor check fails on a light project"; }
expect_refusal "newcomp" "$ZOKOR" add feature orders
[ ! -e src/orders ] || fail "add feature left files in a light project"

cd "$WORK"
expect_refusal "newcomp" "$ZOKOR" new notlight --db pg $PIN
# shellcheck disable=SC2086
"$ZOKOR" newcomp componentdemo $PIN >/dev/null
cd componentdemo
for f in AGENTS.md Makefile .env.example .gitignore src/main.sl \
         src/notes/domain/note.sl src/notes/service/ports.sl src/notes/store/store.sl \
         src/notes/server/server.sl src/platform/app/app.sl; do
    [ -f "$f" ] || fail "zokor newcomp did not write $f"
done
grep -q "pkg zokor git file://$WORK/zokor tag scaffold-test dir zokor" slang.project ||
    fail "slang.project does not pin the requested zokor"
"$SLANGC" get >/dev/null
make test SLANGC="$SLANGC" >"$WORK/test.log" 2>&1 || { cat "$WORK/test.log"; fail "a new component project's tests fail"; }
make build SLANGC="$SLANGC" >/dev/null 2>&1 || fail "a new component project does not build"

"$ZOKOR" add feature orders >/dev/null
grep -q 'orders.mount(r);' src/main.sl || fail "add feature did not mount the routes"
grep -q 'orders: orders.Orders\[orders_store.Store\],' src/platform/app/app.sl ||
    fail "add feature did not add the state field"
make build SLANGC="$SLANGC" >/dev/null 2>&1 || fail "the project does not build after add feature"

"$ZOKOR" add route orders POST /:id/cancel cancel_order >/dev/null
grep -q 'g.post("/:id/cancel", cancel_order);' src/orders/server/server.sl ||
    fail "add route did not register the route"
"$SLANGC" test src/orders/server >"$WORK/test.log" 2>&1 || { cat "$WORK/test.log"; fail "an added route's test fails"; }
grep -q 'test_cancel_order_is_mounted_behind_auth' src/orders/server/server_test.sl ||
    fail "add route wrote no test"
expect_refusal "already registers POST /orders/:id/cancel" "$ZOKOR" add route orders POST /:id/cancel cancel_again
expect_refusal "already has a function cancel_order" "$ZOKOR" add route orders PUT /:id cancel_order
expect_refusal "the method is" "$ZOKOR" add route orders FETCH /x fetch_x
expect_refusal "starts with /" "$ZOKOR" add route orders GET x get_x
expect_refusal "add the feature first" "$ZOKOR" add route nope GET /x get_x

expect_refusal "already exists" "$ZOKOR" add feature orders
expect_refusal "used by the generated code" "$ZOKOR" add feature config
expect_refusal "lowercase" "$ZOKOR" add feature Orders
expect_refusal "entity must differ" "$ZOKOR" add feature stock --entity stock
expect_refusal "already exists" "$ZOKOR" new src
(cd "$WORK" && expect_refusal "no slang.project here" "$ZOKOR" add feature orders)
expect_refusal "service name" "$ZOKOR" new "Bad Name"
expect_refusal "--db is memory" "$ZOKOR" newcomp other --db mysql

# zokor check: clean as generated, and each rule catches its violation.
"$ZOKOR" check >/dev/null || { "$ZOKOR" check; fail "zokor check fails on a generated project"; }
violates() {
    rule=$1 file=$2 text=$3
    cp "$file" "$WORK/saved"
    printf '%s\n' "$text" | cat - "$WORK/saved" >"$file"
    expect_refusal "$file:1: $rule:" "$ZOKOR" check
    cp "$WORK/saved" "$file"
}
violates imports src/orders/server/dto.sl 'import "../store" as orders_store;'
violates imports src/orders/service/service.sl 'import "../../notes/store" as notes_store;'
violates pure src/orders/domain/order.sl 'import "fs";'
violates pg src/orders/server/dto.sl 'import "pg";'
violates config src/orders/service/service.sl 'fn port() -> str { return proc.getenv("PORT"); }'
violates sql src/orders/store/memory.sl 'fn q(id: str) -> str { return "select * from orders where id = " + id; }'
violates tenant src/orders/service/service.sl 'pub fn count() -> int { return 0; }'
cp src/orders/server/server.sl "$WORK/saved"
grep -v require_tenant "$WORK/saved" >src/orders/server/server.sl
expect_refusal "src/orders/server/server.sl:1: auth:" "$ZOKOR" check
cp "$WORK/saved" src/orders/server/server.sl
mkdir -p src/orders/server/extra && echo 'pub fn one() -> int { return 1; }' >src/orders/server/extra/extra.sl
expect_refusal "src/orders/server/extra: tests:" "$ZOKOR" check
rm -r src/orders/server/extra
"$ZOKOR" check --json >"$WORK/check.json" || fail "zokor check --json fails on a clean project"

# --db pg: the adapter switch, the pool, a migration per feature.
cd "$WORK"
# shellcheck disable=SC2086
"$ZOKOR" newcomp pgdemo --db pg $PIN >/dev/null
cd pgdemo
[ -f migrations/001_notes.sql ] || fail "--db pg wrote no migration"
"$ZOKOR" add feature orders >/dev/null
[ -f migrations/002_orders.sql ] || fail "add feature did not number its migration after 001"
"$ZOKOR" check >/dev/null || { "$ZOKOR" check; fail "zokor check fails on a --db pg project"; }
"$SLANGC" get >/dev/null
make build SLANGC="$SLANGC" >"$WORK/build.log" 2>&1 || { grep -E "error" "$WORK/build.log"; fail "a --db pg project does not build"; }
for p in src/notes/store src/orders/server src/platform/db; do
    TEST_DATABASE_URL=${SCAFFOLD_TEST_DATABASE_URL:-} "$SLANGC" test "$p" >"$WORK/test.log" 2>&1 ||
        { cat "$WORK/test.log"; fail "$p fails in a --db pg project"; }
done
if [ -n "${SCAFFOLD_TEST_DATABASE_URL:-}" ]; then
    grep -q 'skip' "$WORK/test.log" && fail "live store tests skipped with a database set"
    msg="with live Postgres"
else
    msg="(live Postgres skipped: SCAFFOLD_TEST_DATABASE_URL is not set)"
fi
echo "PASS zokor new, add feature, add route and check: memory and --db pg projects build and pass $msg"

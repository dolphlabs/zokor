#!/bin/sh
set -eu
unset MIGRATION_MAX_FILES MIGRATION_MAX_FILE_BYTES MIGRATION_MAX_TOTAL_BYTES MIGRATION_TIMEOUT_SECONDS

expect() {
    expected_code=$1
    expected_text=$2
    shift 2
    code=0
    output=$("$@" 2>&1) || code=$?
    if [ "$code" -ne "$expected_code" ]; then
        echo "FAIL CLI: expected exit $expected_code, got $code: $output" >&2
        exit 1
    fi
    case "$output" in
        *"$expected_text"*) ;;
        *) echo "FAIL CLI: expected '$expected_text': $output" >&2; exit 1 ;;
    esac
}

expect 2 'usage:' bin/zokor
expect 2 'usage:' bin/zokor unknown
expect 1 'migrations directory:' bin/zokor migrate testdata/does-not-exist
expect 2 'MIGRATION_MAX_FILES' env MIGRATION_MAX_FILES=bad MIGRATION_TIMEOUT_SECONDS=bad bin/zokor migrate testdata/migrations
expect 1 'max_file_bytes' env MIGRATION_MAX_FILE_BYTES=1 bin/zokor migrate testdata/migrations
expect 1 'NUL' bin/zokor migrate testdata/migrations-nul

if [ -n "${ZOKOR_TEST_DATABASE_URL:-}" ]; then
    expect 0 'applied 2 migrations' env DATABASE_URL="$ZOKOR_TEST_DATABASE_URL" bin/zokor migrate testdata/migrations
    expect 0 'applied 0 migrations' env DATABASE_URL="$ZOKOR_TEST_DATABASE_URL" bin/zokor migrate testdata/migrations
else
    echo 'skip live CLI migrations (ZOKOR_TEST_DATABASE_URL is not set)'
fi
echo 'PASS CLI exits, validation, apply and replay'

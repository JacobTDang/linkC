#!/bin/bash
# Tests scripts/tsan.sh against a fake `swift` on PATH: a ThreadSanitizer report must fail the run
# even when every test passed, a test failure or crash must keep its own exit status, and a clean
# run must pass. Without this, an edit to the report check could stop it working while CI stays
# green, since a green TSan job only ever shows the absence of reports.
# Usage: ./scripts/test-tsan.sh
set -euo pipefail

TSAN="$(cd "$(dirname "$0")" && pwd)/tsan.sh"
SUPPRESSIONS="$(cd "$(dirname "$0")" && pwd)/tsan-suppressions.txt"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The fake prints $FAKE_OUTPUT, records the TSAN_OPTIONS it was given, and exits $FAKE_STATUS.
cat > "$WORK/swift" <<'FAKE'
#!/bin/bash
printf '%s\n' "$TSAN_OPTIONS" > "$FAKE_SEEN"
printf '%s\n' "$FAKE_OUTPUT"
exit "$FAKE_STATUS"
FAKE
chmod +x "$WORK/swift"

FAILED=0
CASES=0

expect() { # expect <name> <wanted exit status> <fake output> <fake exit status>
    CASES=$((CASES + 1))
    local status=0
    PATH="$WORK:$PATH" FAKE_OUTPUT="$3" FAKE_STATUS="$4" FAKE_SEEN="$WORK/seen" \
        "$TSAN" >/dev/null 2>&1 || status=$?
    if [ "$status" -ne "$2" ]; then
        echo "FAIL: $1 — exited $status, wanted $2"
        FAILED=$((FAILED + 1))
    fi
}

REPORT='WARNING: ThreadSanitizer: data race (pid=1234)'

expect "a clean run passes" 0 "Executed 3 tests, with 0 failures" 0
expect "a report with every test passing fails" 1 "$REPORT
Executed 3 tests, with 0 failures" 0
expect "a report alongside a test failure fails" 1 "$REPORT" 1
expect "a test failure keeps its status" 1 "Executed 3 tests, with 1 failure" 1
expect "a crash keeps its status" 139 "Segmentation fault" 139
expect "any other status is passed through" 66 "" 66

CASES=$((CASES + 1))
if [ "$(cat "$WORK/seen")" != "suppressions=$SUPPRESSIONS" ]; then
    echo "FAIL: the suite runs with the suppressions file — got '$(cat "$WORK/seen")'"
    FAILED=$((FAILED + 1))
fi

if [ "$FAILED" -ne 0 ]; then
    echo "$FAILED of $CASES tsan.sh checks failed"
    exit 1
fi
echo "all $CASES tsan.sh checks passed"

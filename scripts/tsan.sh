#!/bin/bash
# Runs the test suite under ThreadSanitizer with known-upstream races suppressed
# (see tsan-suppressions.txt). Any report this prints is a linkC bug — fix it. The script
# fails on a report even when every test passed, and on any test failure.
# The compile-time layer is Swift 6 strict concurrency (always on via Package.swift).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export TSAN_OPTIONS="suppressions=$ROOT/scripts/tsan-suppressions.txt"

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

status=0
swift test --sanitize=thread --package-path "$ROOT" "$@" 2>&1 | tee "$LOG" || status="${PIPESTATUS[0]}"

if grep -q "WARNING: ThreadSanitizer" "$LOG"; then
    echo "tsan: ThreadSanitizer reported a problem (see the report above)" >&2
    exit 1
fi
exit "$status"

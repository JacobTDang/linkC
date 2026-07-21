#!/bin/bash
# Runs the test suite under ThreadSanitizer with known-upstream races suppressed
# (see tsan-suppressions.txt). Any report this prints is a linkC bug — fix it.
# The compile-time layer is Swift 6 strict concurrency (always on via Package.swift).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export TSAN_OPTIONS="suppressions=$ROOT/scripts/tsan-suppressions.txt"
exec swift test --sanitize=thread --package-path "$ROOT" "$@"

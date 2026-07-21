#!/bin/bash
# Renders linkC's app icon and packages it as Assets/linkC.icns (committed). Idempotent:
# re-run any time render-icon.swift changes. Built-in tooling only (swift + iconutil).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$ROOT/Assets/linkC.iconset"
ICNS="$ROOT/Assets/linkC.icns"

mkdir -p "$ROOT/Assets"
rm -rf "$ICONSET"

echo "==> Rendering PNGs"
swift "$ROOT/scripts/render-icon.swift" "$ICONSET"

echo "==> Packaging $ICNS"
iconutil -c icns "$ICONSET" -o "$ICNS"

rm -rf "$ICONSET"   # keep only the committed .icns
echo "==> Done: $ICNS"

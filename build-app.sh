#!/bin/bash
# Builds linkC as a proper .app bundle (menu-bar agent, code-signed so macOS
# notifications work). Output: dist/linkC.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="linkC"
BUNDLE_ID="com.linkc.app"
APP="$ROOT/dist/$NAME.app"
ICNS="$ROOT/Assets/$NAME.icns"

if [[ ! -f "$ICNS" ]]; then
  echo "ERROR: $ICNS not found — run ./scripts/make-icon.sh first (refusing to ship iconless)." >&2
  exit 1
fi

echo "==> Building release binary"
swift build -c release --package-path "$ROOT"
BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/linkc"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp "$ICNS" "$APP/Contents/Resources/$NAME.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIconFile</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code signing (required for notifications)"
# File-provider sync (iCloud Desktop) stamps FinderInfo/xattrs onto the fresh bundle,
# which codesign rejects as "detritus" — strip them right before signing.
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP"
echo "    Launch with:  open \"$APP\""

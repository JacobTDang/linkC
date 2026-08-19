#!/bin/bash
# Builds linkC as a proper .app bundle (menu-bar agent, code-signed so macOS
# notifications work). Output: dist.noindex/linkC.app (.noindex keeps the build artifact
# out of Spotlight — /Applications/linkC.app is the one true app).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="linkC"
BUNDLE_ID="com.linkc.app"
APP="$ROOT/dist.noindex/$NAME.app"
ICNS="$ROOT/Assets/$NAME.icns"

if [[ ! -f "$ICNS" ]]; then
  echo "ERROR: $ICNS not found — run ./scripts/make-icon.sh first (refusing to ship iconless)." >&2
  exit 1
fi

# Stamp real versions so "what am I running?" is answerable in the app.
VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
VERSION="${VERSION:-0.0.0}"
BUILD="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo dev)"

echo "==> Building release binary ($VERSION · $BUILD)"
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
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
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

# --install: copy the fresh bundle into /Applications (the "real app" location — stable
# path for Spotlight, Launchpad, and the launch-at-login registration). Refuses while the
# installed copy is running: overwriting a live app corrupts its running image.
if [[ "${1:-}" == "--install" ]]; then
  if pgrep -f "/Applications/$NAME.app/Contents/MacOS/$NAME" > /dev/null; then
    echo "ERROR: /Applications/$NAME.app is running — quit it first, then re-run with --install." >&2
    exit 1
  fi
  ditto "$APP" "/Applications/$NAME.app"
  # The installed copy learns where fresh builds land, so it can offer
  # "Update ready — Install & restart" when this dist bundle changes. Add always
  # succeeds: the ditto above just replaced the plist with dist's key-less one.
  /usr/libexec/PlistBuddy -c "Add :LinkCSourceDist string $APP" \
    "/Applications/$NAME.app/Contents/Info.plist"
  # Re-sign: the plist edit invalidated the ad-hoc signature.
  codesign --force --deep --sign - "/Applications/$NAME.app"
  echo "==> Installed: /Applications/$NAME.app"
fi

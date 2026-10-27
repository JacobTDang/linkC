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
MCP_BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/linkc-mcp"
CLI_BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/linkc-cli"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp "$MCP_BIN" "$APP/Contents/MacOS/linkc-mcp"
cp "$CLI_BIN" "$APP/Contents/MacOS/linkc-cli"
cp "$ICNS" "$APP/Contents/Resources/$NAME.icns"

mkdir -p "$HOME/.local/bin"
ln -sf "$APP/Contents/MacOS/linkc-mcp" "$HOME/.local/bin/linkc-mcp"
ln -sf "$APP/Contents/MacOS/linkc-cli" "$HOME/.local/bin/linkc"

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
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>com.linkc.terminal</string>
      <key>UTTypeDescription</key><string>linkC terminal</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Signing is required for notifications. macOS ties privacy grants (Screen Recording,
# notifications) to the signature, and an ad-hoc one changes with every build — so sign with
# this Mac's own stable identity when the keychain has it (the in-app updater, UpdateSwap,
# makes the same choice), and say plainly when it doesn't.
SIGN_IDENTITY="linkC Local Signing"
if ! IDENTITIES="$(security find-identity -p codesigning)"; then
  echo "WARNING: security find-identity failed — signing ad-hoc" >&2
  IDENTITIES=""
fi
if [[ "$IDENTITIES" == *"\"$SIGN_IDENTITY\""* ]]; then
  SIGN="$SIGN_IDENTITY"
  echo "==> Code signing with \"$SIGN_IDENTITY\" (privacy grants survive rebuilds)"
else
  SIGN="-"
  echo "WARNING: ad-hoc code signing — no \"$SIGN_IDENTITY\" identity in the keychain, so macOS privacy grants reset with each build. scripts/make-signing-identity.sh makes one." >&2
fi
# File-provider sync (iCloud Desktop) stamps FinderInfo/xattrs onto the fresh bundle,
# which codesign rejects as "detritus" — strip them right before signing.
xattr -cr "$APP"
codesign --force --deep --sign "$SIGN" "$APP"

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
  # Re-sign: the plist edit invalidated the signature. Clean xattrs first —
  # iCloud-synced folders stamp Finder detritus that codesign refuses.
  xattr -cr "/Applications/$NAME.app"
  codesign --force --deep --sign "$SIGN" "/Applications/$NAME.app"
  echo "==> Installed: /Applications/$NAME.app"
fi

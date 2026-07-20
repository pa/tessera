#!/usr/bin/env bash
#
# Build Tessera and assemble a proper .app bundle.
#
# Why a bundle and not just `swift run`: macOS keys the Accessibility (TCC)
# grant to an app's code-signing identity + bundle path. A bare SPM executable
# has no stable bundle identity, so its Accessibility access gets attributed to
# the parent terminal instead — Tessera would never reliably control windows.
# Packaging into a signed .app with a fixed bundle id (pramodh.ayyappan.tessera)
# gives the grant something stable to attach to.
#
# Signing: by default this ad-hoc signs (`-`). Ad-hoc signatures change every
# rebuild, so macOS may re-prompt for Accessibility after each build. To make
# the grant stick across rebuilds, create a self-signed code-signing cert in
# Keychain Access (Certificate Assistant → Create a Certificate → "Code
# Signing") and export its name via CODESIGN_IDENTITY:
#
#     CODESIGN_IDENTITY="Tessera Dev" ./scripts/build-app.sh
#
set -euo pipefail

CONFIG="${CONFIG:-release}"
IDENTITY="${CODESIGN_IDENTITY:--}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/.build/Tessera.app"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN_PATH/Tessera" "$APP/Contents/MacOS/Tessera"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# App icon (shown in Finder / Get Info — Tessera has no Dock icon as an agent).
[ -f "$ROOT/Resources/Tessera.icns" ] && cp "$ROOT/Resources/Tessera.icns" "$APP/Contents/Resources/Tessera.icns"

echo "==> codesign (identity: $IDENTITY)"
# The self-signed identity lives in a dedicated keychain that can re-lock
# between sessions; unlock it so codesign can reach the private key (otherwise
# it fails with errSecInternalComponent). No-op for ad-hoc signing.
if [ "$IDENTITY" != "-" ]; then
    security unlock-keychain -p "tessera-signing" "tessera-signing.keychain" 2>/dev/null || true
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --verbose "$APP" || true

echo ""
echo "Built: $APP"
echo "Run:   open \"$APP\"    (or: \"$APP/Contents/MacOS/Tessera\" to see logs)"
echo ""
echo "First launch: grant Accessibility under System Settings →"
echo "Privacy & Security → Accessibility (the app's menu has a one-click shortcut)."

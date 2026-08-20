#!/bin/bash
# Assemble JBar.app from the SwiftPM release build.
# Usage: scripts/build-app.sh [output-dir]
# Env:   CODESIGN_IDENTITY  (default "-" ad-hoc; set to a self-signed identity to keep TCC grants stable)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build}"
APP="$OUT/JBar.app"
SIGN="${CODESIGN_IDENTITY:--}"
cd "$ROOT"

# Generate the icon if missing (best-effort; the app runs fine without it).
if [ ! -f "$ROOT/Resources/AppIcon.icns" ] && [ -f "$ROOT/scripts/make-icns.sh" ]; then
  bash "$ROOT/scripts/make-icns.sh" || echo "warning: icon generation failed; continuing without AppIcon.icns"
fi

echo "Building release binary…"
swift build -c release --product JBar >/dev/null
BIN="$(swift build -c release --show-bin-path)/JBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --deep --sign "$SIGN" "$APP" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify --verbose=1 "$APP" 2>/dev/null || echo "warning: codesign --verify reported issues (ok for ad-hoc)"
echo "Built: $APP  (signed with '$SIGN')"

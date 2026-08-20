#!/bin/bash
# Build JBar.app and install it. No sudo required (/Applications is admin-group-writable).
# Usage: scripts/install.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bash "$ROOT/scripts/build-app.sh" "$ROOT/build"
SRC="$ROOT/build/JBar.app"

# Quit any running instance so we can replace the bundle.
osascript -e 'tell application "JBar" to quit' >/dev/null 2>&1 || true
pkill -f "JBar.app/Contents/MacOS/JBar" >/dev/null 2>&1 || true
sleep 1

DEST_DIR="/Applications"
if [ ! -w "$DEST_DIR" ]; then
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
  echo "note: /Applications not writable → installing to $DEST_DIR"
fi
DEST="$DEST_DIR/JBar.app"

rm -rf "$DEST"
ditto "$SRC" "$DEST"
# A locally built bundle has no quarantine xattr, but strip it defensively.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

open -a "$DEST"

HOTKEY="$("$DEST/Contents/MacOS/JBar" --print-hotkey 2>/dev/null || echo 'Option+Space')"
cat <<EOF

  JBar installed → $DEST
  Press ${HOTKEY} to open it (also in the menu-bar 🔍).
  Config:    ~/.config/jbar/config.json
  Uninstall: make uninstall   (or scripts/uninstall.sh)

  First search may show macOS "Files and Folders" permission prompts for
  Desktop / Documents / Downloads — allow them so JBar can index file names.
EOF

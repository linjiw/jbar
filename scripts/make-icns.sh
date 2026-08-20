#!/bin/bash
# Build Resources/AppIcon.icns from Resources/icon.png (1024×1024) with sips + iconutil.
# Usage: scripts/make-icns.sh [icon.png] [AppIcon.icns]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PNG="${1:-$ROOT/Resources/icon.png}"
ICNS="${2:-$ROOT/Resources/AppIcon.icns}"
[ -f "$PNG" ] || { echo "make-icns: missing $PNG (run: swift scripts/make-icon.swift $PNG)" >&2; exit 1; }
ICNS_PARENT="$(dirname "$ICNS")"
mkdir -p "$ICNS_PARENT"
ICNS_PARENT="$(cd "$ICNS_PARENT" && pwd -P)"
ICNS="$ICNS_PARENT/$(basename "$ICNS")"
[ ! -d "$ICNS" ] || { echo "make-icns: output is a directory: $ICNS" >&2; exit 1; }

WORK_DIR="$(mktemp -d "$ICNS_PARENT/.jbar-icon.XXXXXXXX")"
SET="$WORK_DIR/AppIcon.iconset"
STAGED_ICNS="$WORK_DIR/AppIcon.icns"
cleanup() {
  if [ "$(dirname "$WORK_DIR")" = "$ICNS_PARENT" ] &&
     [[ "$(basename "$WORK_DIR")" == .jbar-icon.* ]]; then
    rm -rf -- "$WORK_DIR"
  else
    echo "make-icns: refusing unsafe staging cleanup: $WORK_DIR" >&2
  fi
}
trap cleanup EXIT INT TERM HUP
mkdir -p "$SET"
for n in 16 32 128 256 512; do
  sips -z "$n" "$n" "$PNG" --out "$SET/icon_${n}x${n}.png" >/dev/null
  d=$((n * 2))
  sips -z "$d" "$d" "$PNG" --out "$SET/icon_${n}x${n}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$STAGED_ICNS"
[ -s "$STAGED_ICNS" ] || { echo "make-icns: iconutil produced no output" >&2; exit 1; }
mv -f "$STAGED_ICNS" "$ICNS"
echo "wrote $ICNS"

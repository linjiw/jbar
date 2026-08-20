#!/bin/bash
# Build Resources/AppIcon.icns from Resources/icon.png (1024×1024) with sips + iconutil.
# Usage: scripts/make-icns.sh [icon.png] [AppIcon.icns]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PNG="${1:-$ROOT/Resources/icon.png}"
ICNS="${2:-$ROOT/Resources/AppIcon.icns}"
[ -f "$PNG" ] || { echo "make-icns: missing $PNG (run: swift scripts/make-icon.swift $PNG)" >&2; exit 1; }
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for n in 16 32 128 256 512; do
  sips -z "$n" "$n" "$PNG" --out "$SET/icon_${n}x${n}.png" >/dev/null
  d=$((n * 2))
  sips -z "$d" "$d" "$PNG" --out "$SET/icon_${n}x${n}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$ICNS"
rm -rf "$(dirname "$SET")"
echo "wrote $ICNS"

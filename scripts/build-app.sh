#!/bin/bash
# Assemble JBar.app from the SwiftPM release build.
# Usage: scripts/build-app.sh [output-dir]
# Env:   JBAR_ARCHS         (default "arm64 x86_64"; space-separated macOS architectures)
#        CODESIGN_IDENTITY  (default "-" ad-hoc; set to a self-signed identity to keep TCC grants stable)
# Developer ID Application identities automatically enable hardened runtime and a secure timestamp.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build}"
APP="$OUT/JBar.app"
SIGN="${CODESIGN_IDENTITY:--}"
ARCHS_INPUT="${JBAR_ARCHS:-arm64 x86_64}"
read -r -a ARCHS <<< "$ARCHS_INPUT"

if [ "${#ARCHS[@]}" -eq 0 ]; then
  echo "error: JBAR_ARCHS must contain at least one architecture" >&2
  exit 2
fi

SWIFT_ARCH_ARGS=()
for arch in "${ARCHS[@]}"; do
  case "$arch" in
    arm64|x86_64) ;;
    *)
      echo "error: unsupported JBAR_ARCHS entry '$arch' (expected arm64 and/or x86_64)" >&2
      exit 2
      ;;
  esac
  SWIFT_ARCH_ARGS+=(--arch "$arch")
done

is_developer_id_identity() {
  local identity="$1"
  local identities
  local line

  case "$identity" in
    "Developer ID Application:"*) return 0 ;;
    -) return 1 ;;
  esac

  # codesign also accepts certificate hashes and partial names, so resolve those
  # against the keychain before deciding whether timestamping is appropriate.
  identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  while IFS= read -r line; do
    if [[ "$line" == *"$identity"* && "$line" == *"Developer ID Application:"* ]]; then
      return 0
    fi
  done <<< "$identities"
  return 1
}

cd "$ROOT"

# Generate the icon if missing (best-effort; the app runs fine without it).
if [ ! -f "$ROOT/Resources/AppIcon.icns" ] && [ -f "$ROOT/scripts/make-icns.sh" ]; then
  bash "$ROOT/scripts/make-icns.sh" || echo "warning: icon generation failed; continuing without AppIcon.icns"
fi

echo "Building release binary for: ${ARCHS[*]}…"
swift build -c release --product JBar "${SWIFT_ARCH_ARGS[@]}" >/dev/null
BIN="$(swift build -c release "${SWIFT_ARCH_ARGS[@]}" --show-bin-path)/JBar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JBar"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

plutil -lint "$APP/Contents/Info.plist" >/dev/null

ACTUAL_ARCHS="$(lipo -archs "$APP/Contents/MacOS/JBar")"
for arch in "${ARCHS[@]}"; do
  case " $ACTUAL_ARCHS " in
    *" $arch "*) ;;
    *)
      echo "error: built executable is missing requested architecture '$arch' (found: $ACTUAL_ARCHS)" >&2
      exit 1
      ;;
  esac
done

SIGN_ARGS=(--force --deep --sign "$SIGN")
if is_developer_id_identity "$SIGN"; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi

codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Built: $APP  (architectures: $ACTUAL_ARCHS; signed with '$SIGN')"
if is_developer_id_identity "$SIGN"; then
  echo "Next for public distribution: notarize this bundle and staple the notarization ticket."
fi

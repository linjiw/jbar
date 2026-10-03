#!/bin/bash
# Build a standalone Universal 2 CLI archive in a new, explicitly chosen staging directory.
# No installation, network access, credentials or publication are performed.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
if [ "$#" -ne 1 ]; then
  echo "usage: $0 NEW-TEMPORARY-OUTPUT-DIRECTORY" >&2
  exit 64
fi
OUTPUT="$1"
case "$OUTPUT" in
  /*) ;;
  *) echo "error: output must be an absolute path" >&2; exit 64 ;;
esac
if [ -e "$OUTPUT" ] || [ -L "$OUTPUT" ]; then
  echo "error: output already exists; choose a new temporary staging directory" >&2
  exit 64
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: expected a MAJOR.MINOR.PATCH version" >&2
  exit 64
fi

/bin/mkdir -m 0700 "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd -P)"
NAME="JBar-CLI-$VERSION-universal"
STAGE="$OUTPUT/$NAME"
/bin/mkdir -m 0700 "$STAGE"
/bin/mkdir -m 0700 "$STAGE/bin"
SCRATCH="${JBAR_CLI_BUILD_SCRATCH:-$OUTPUT/swift-build}"

swift build --package-path "$ROOT" --scratch-path "$SCRATCH" \
  -c release --product jbar-cli --arch arm64 --arch x86_64 \
  -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete
BIN_DIR="$(swift build --package-path "$ROOT" --scratch-path "$SCRATCH" \
  -c release --arch arm64 --arch x86_64 --show-bin-path)"
/bin/cp "$BIN_DIR/jbar-cli" "$STAGE/bin/jbar-cli"
/bin/chmod 0755 "$STAGE/bin/jbar-cli"
/usr/bin/lipo "$STAGE/bin/jbar-cli" -verify_arch arm64 x86_64
/usr/bin/codesign --force --sign - "$STAGE/bin/jbar-cli"
/usr/bin/codesign --verify --strict "$STAGE/bin/jbar-cli"
"$STAGE/bin/jbar-cli" --help >/dev/null
CLI_VERSION="$("$STAGE/bin/jbar-cli" --version)"
if [ "$CLI_VERSION" != "jbar-cli $VERSION" ]; then
  echo "error: CLI version does not match Resources/Info.plist" >&2
  exit 1
fi
echo "$CLI_VERSION"
if /usr/bin/otool -L "$STAGE/bin/jbar-cli" | /usr/bin/grep -F '/AppKit.framework/' >/dev/null; then
  echo "error: standalone CLI unexpectedly links AppKit" >&2
  exit 1
fi
/bin/cp "$ROOT/LICENSE" "$STAGE/LICENSE"
/bin/cp "$ROOT/docs/CLI.md" "$STAGE/README.md"
/usr/bin/tar -czf "$OUTPUT/$NAME.tar.gz" -C "$OUTPUT" "$NAME"
(cd "$OUTPUT" && /usr/bin/shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
echo "CLI candidate: $OUTPUT/$NAME.tar.gz"
echo "Checksum: $OUTPUT/$NAME.tar.gz.sha256"

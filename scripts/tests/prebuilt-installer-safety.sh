#!/bin/bash
# Exercise the no-toolchain prebuilt installer in an isolated destination.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
INSTALLER="$ROOT/scripts/install-prebuilt.sh"
SOURCE_APP="${JBAR_PREBUILT_INSTALL_SOURCE_APP:-$ROOT/build/JBar.app}"
TEST_PARENT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
TEST_ROOT="$(/usr/bin/mktemp -d "$TEST_PARENT/jbar-prebuilt-install-tests.XXXXXXXX")"
/bin/chmod 700 "$TEST_ROOT"
DEST_DIR="$TEST_ROOT/Applications"
/bin/mkdir -m 700 "$DEST_DIR"

cleanup() {
  if [ "$(dirname "$TEST_ROOT")" = "$TEST_PARENT" ] &&
     [[ "$(basename "$TEST_ROOT")" == jbar-prebuilt-install-tests.* ]] &&
     [ "$(/usr/bin/stat -f '%u:%Lp' "$TEST_ROOT" 2>/dev/null)" = "$(/usr/bin/id -u):700" ]; then
    /usr/bin/find -x "$TEST_ROOT" -depth -mindepth 1 -delete
    /bin/rmdir -- "$TEST_ROOT"
  else
    echo "error: refusing unsafe prebuilt-installer cleanup: $TEST_ROOT" >&2
    exit 1
  fi
}
trap cleanup EXIT INT TERM HUP

[ -x "$INSTALLER" ] || { echo "error: installer is not executable" >&2; exit 1; }
[ -d "$SOURCE_APP" ] && [ ! -L "$SOURCE_APP" ] || {
  echo "error: missing source app: $SOURCE_APP" >&2
  exit 1
}

run_install() {
  JBAR_PREBUILT_INSTALL_TEST_MODE=1 \
  JBAR_PREBUILT_INSTALL_DEST_DIR="$DEST_DIR" \
  JBAR_PREBUILT_INSTALL_TEST_ROOT="$TEST_ROOT" \
    "$INSTALLER" "$SOURCE_APP" --no-launch
}

run_install
[ -d "$DEST_DIR/JBar.app" ] && [ ! -L "$DEST_DIR/JBar.app" ] ||
  { echo "error: first prebuilt install did not activate JBar.app" >&2; exit 1; }
[ -z "$(/usr/bin/find "$DEST_DIR" -maxdepth 1 -name '.jbar-install.*' -print -quit)" ] ||
  { echo "error: first prebuilt install leaked staging state" >&2; exit 1; }

# A second run exercises replacement while keeping the test outside /Applications.
run_install
[ -d "$DEST_DIR/JBar.app" ] && [ ! -L "$DEST_DIR/JBar.app" ] ||
  { echo "error: upgrade prebuilt install did not preserve JBar.app" >&2; exit 1; }
[ -z "$(/usr/bin/find "$DEST_DIR" -maxdepth 1 -name '.jbar-install.*' -print -quit)" ] ||
  { echo "error: upgrade prebuilt install leaked staging state" >&2; exit 1; }

echo "PASS: isolated prebuilt installer first-install and upgrade cases"

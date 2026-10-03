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
  local target="${1:-$DEST_DIR}"
  local fault="${2:-}"
  local source="${3:-$SOURCE_APP}"
  JBAR_PREBUILT_INSTALL_TEST_MODE=1 \
  JBAR_PREBUILT_INSTALL_DEST_DIR="$target" \
  JBAR_PREBUILT_INSTALL_TEST_ROOT="$TEST_ROOT" \
  JBAR_PREBUILT_INSTALL_TEST_FAULT="$fault" \
    "$INSTALLER" "$source" --no-launch
}
fail() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() {
  if run_install "$@" > "$TEST_ROOT/failure.log" 2>&1; then fail "expected installer refusal: $*"; fi
}
assert_no_stage() {
  [ -z "$(/usr/bin/find "$1" -maxdepth 1 -name '.jbar-install.*' -print -quit)" ] || fail "leaked staging: $1"
}
app_id() { /usr/bin/stat -f '%d:%i' "$1/JBar.app"; }

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

# Every fault runs outside /Applications, with process control disabled by test mode.
for fault in after-copy after-activation term-after-activation; do
  target="$TEST_ROOT/first-$fault"
  /bin/mkdir -m 700 "$target"
  expect_failure "$target" "$fault"
  [ ! -e "$target/JBar.app" ] && [ ! -L "$target/JBar.app" ] || fail "failed first install left an active app: $fault"
  assert_no_stage "$target"

  target="$TEST_ROOT/upgrade-$fault"
  /bin/mkdir -m 700 "$target"
  run_install "$target" >/dev/null
  original_id="$(app_id "$target")"
  expect_failure "$target" "$fault"
  [ "$(app_id "$target")" = "$original_id" ] || fail "failed upgrade did not restore original inode: $fault"
  /usr/bin/codesign --verify --deep --strict "$target/JBar.app"
  assert_no_stage "$target"
done

target="$TEST_ROOT/first-race"
/bin/mkdir -m 700 "$target"
expect_failure "$target" first-install-race
[ "$(/bin/cat "$target/JBar.app/unrelated-data")" = unrelated ] || fail "first-install race deleted unrelated data"
[ ! -e "$target/JBar.app/JBar.app" ] || fail "first-install race nested the staged app"
assert_no_stage "$target"

target="$TEST_ROOT/upgrade-mutation"
/bin/mkdir -m 700 "$target"
run_install "$target" >/dev/null
original_id="$(app_id "$target")"
expect_failure "$target" upgrade-mutation
[ "$(/bin/cat "$target/JBar.app/unrelated-data")" = unrelated ] || fail "upgrade race deleted unrelated data"
[ "$(/usr/bin/stat -f '%d:%i' "$target/preserved-existing-app")" = "$original_id" ] || fail "upgrade race deleted displaced original"
assert_no_stage "$target"

target="$TEST_ROOT/replaced-workdir"
/bin/mkdir -m 700 "$target"
run_install "$target" >/dev/null
original_id="$(app_id "$target")"
expect_failure "$target" workdir-replacement
replacement="$(/usr/bin/find "$target" -maxdepth 1 -name '.jbar-install.*' -print -quit)"
[ "$(/bin/cat "$replacement/unrelated-data")" = unrelated ] || fail "cleanup deleted substituted work directory"
[ "$(/usr/bin/stat -f '%d:%i' "$target/preserved-workdir/JBar.app")" = "$original_id" ] || fail "cleanup deleted displaced app after work substitution"
/usr/bin/codesign --verify --deep --strict "$target/JBar.app"
expect_failure "$target"
/usr/bin/grep -q 'prior installation needs manual recovery' "$TEST_ROOT/failure.log" || fail "recovery state was ignored"

target="$TEST_ROOT/killed-upgrade"
/bin/mkdir -m 700 "$target"
run_install "$target" >/dev/null
original_id="$(app_id "$target")"
expect_failure "$target" kill-after-activation
recovery="$(/usr/bin/find "$target" -maxdepth 1 -name '.jbar-install.*' -print -quit)"
[ "$(/usr/bin/stat -f '%d:%i' "$recovery/JBar.app")" = "$original_id" ] || fail "uncatchable interruption lost displaced app"
/usr/bin/codesign --verify --deep --strict "$target/JBar.app"
expect_failure "$target"
/usr/bin/grep -q 'prior installation needs manual recovery' "$TEST_ROOT/failure.log" || fail "killed upgrade recovery was ignored"

target="$TEST_ROOT/symlink-destination"
/bin/mkdir -m 700 "$target" "$TEST_ROOT/unrelated"
echo unrelated > "$TEST_ROOT/unrelated/data"
/bin/ln -s "$TEST_ROOT/unrelated" "$target/JBar.app"
expect_failure "$target"
[ "$(/bin/cat "$TEST_ROOT/unrelated/data")" = unrelated ] || fail "symlink destination altered unrelated data"
[ -L "$target/JBar.app" ] || fail "symlink destination was replaced"
assert_no_stage "$target"

target="$TEST_ROOT/unsafe-source"
/bin/mkdir -m 700 "$target" "$TEST_ROOT/unsafe"
run_install "$target" >/dev/null
original_id="$(app_id "$target")"
/usr/bin/ditto "$SOURCE_APP" "$TEST_ROOT/unsafe/JBar.app"
/bin/chmod 0777 "$TEST_ROOT/unsafe/JBar.app/Contents/MacOS/JBar"
expect_failure "$target" "" "$TEST_ROOT/unsafe/JBar.app"
[ "$(app_id "$target")" = "$original_id" ] || fail "unsafe source replaced installed app"
assert_no_stage "$target"

echo "PASS: isolated prebuilt installer success, rollback, interruption, race, symlink, permissions, and recovery cases"

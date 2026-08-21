#!/bin/bash
# Isolated fail-closed tests for scripts/render-homebrew-cask.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
RENDERER="$ROOT/scripts/render-homebrew-cask.sh"
TEMPLATE="$ROOT/packaging/homebrew/jbar.rb.template"
TEST_PARENT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
TEST_ROOT="$(/usr/bin/mktemp -d "$TEST_PARENT/jbar-cask-tests.XXXXXXXX")"
/bin/chmod 0700 "$TEST_ROOT"
TESTS_RUN=0
WATCHER_PID=""
VERSION=1.2.3
SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

cleanup() {
  if [ -n "$WATCHER_PID" ] && /bin/kill -0 "$WATCHER_PID" 2>/dev/null; then
    /bin/kill -TERM "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
  fi
  if [ "$(dirname "$TEST_ROOT")" = "$TEST_PARENT" ] &&
     [[ "$(basename "$TEST_ROOT")" == jbar-cask-tests.* ]] &&
     [ "$(/usr/bin/stat -f '%u:%Lp' "$TEST_ROOT" 2>/dev/null)" = "$(/usr/bin/id -u):700" ]; then
    /usr/bin/find -x "$TEST_ROOT" -depth -mindepth 1 -delete
    /bin/rmdir -- "$TEST_ROOT"
  else
    echo "error: refusing unsafe Cask-test cleanup: $TEST_ROOT" >&2
  fi
}
trap cleanup EXIT INT TERM HUP

fail() { echo "FAIL: $*" >&2; exit 1; }

assert_acl_free() {
  local path="$1"
  local listing
  listing="$(LC_ALL=C /bin/ls -lde -- "$path")" || fail "cannot inspect ACL: $path"
  [ "$(printf '%s\n' "$listing" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 1 ] ||
    fail "unexpected ACL: $path"
  case "${listing%% *}" in *+*) fail "unexpected ACL marker: $path" ;; esac
}

assert_no_render_state() {
  local parent="$1"
  [ -z "$(/usr/bin/find "$parent" -maxdepth 1 -name '.jbar-cask.*' -print -quit)" ] ||
    fail "Cask staging state leaked in $parent"
}

expect_failure() {
  local name="$1"
  shift
  if "$@" >"$TEST_ROOT/$name.log" 2>&1; then
    fail "$name unexpectedly succeeded"
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

[ -x "$RENDERER" ] || fail "renderer is not executable"
[ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || fail "template is not one regular file"
[ "$(/usr/bin/stat -f '%Lp' "$TEST_ROOT")" = 700 ] || fail "Cask-test root is not mode 0700"
[ "$(/usr/bin/stat -f '%Lp' "$TEMPLATE")" = 644 ] || fail "template is not mode 0644"
assert_acl_free "$TEMPLATE"
TEMPLATE_SHA_BEFORE="$(/usr/bin/shasum -a 256 "$TEMPLATE" | /usr/bin/awk '{print $1}')"
/usr/bin/grep -Fqx "EXPECTED_TEMPLATE_SHA256=$TEMPLATE_SHA_BEFORE" "$RENDERER" ||
  fail "renderer does not pin the exact template SHA-256"
[ "$(/usr/bin/grep -Fo '@VERSION@' "$TEMPLATE" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 1 ] ||
  fail "template must have exactly one version placeholder"
[ "$(/usr/bin/grep -Fo '@SHA256@' "$TEMPLATE" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 1 ] ||
  fail "template must have exactly one SHA-256 placeholder"
[ "$(/usr/bin/grep -Fxc '  depends_on macos: :ventura' "$TEMPLATE")" = 1 ] ||
  fail "template does not use the current minimum-macOS symbol syntax"
[ "$(/usr/bin/grep -Fxc '  app "JBar.app"' "$TEMPLATE")" = 1 ] ||
  fail "template does not install exact JBar.app"

# Happy path: exact stanzas, no placeholders, safe output metadata, and no staging residue.
SUCCESS_DIR="$TEST_ROOT/success"
/bin/mkdir -m 0700 "$SUCCESS_DIR"
SUCCESS_CASK="$SUCCESS_DIR/jbar.rb"
"$RENDERER" "$VERSION" "$SHA256" "$SUCCESS_CASK" > "$TEST_ROOT/success.log"
/usr/bin/ruby -c "$SUCCESS_CASK" >/dev/null
[ "$(/usr/bin/stat -f '%u:%Lp:%l' "$SUCCESS_CASK")" = "$(/usr/bin/id -u):644:1" ] ||
  fail "rendered Cask has unsafe owner, mode, or link count"
assert_acl_free "$SUCCESS_CASK"
[ "$(/usr/bin/grep -Fxc "  version \"$VERSION\"" "$SUCCESS_CASK")" = 1 ] ||
  fail "rendered Cask version stanza is not exact"
[ "$(/usr/bin/grep -Fxc "  sha256 \"$SHA256\"" "$SUCCESS_CASK")" = 1 ] ||
  fail "rendered Cask checksum stanza is not exact"
[ "$(/usr/bin/grep -Fxc '  depends_on macos: :ventura' "$SUCCESS_CASK")" = 1 ] ||
  fail "rendered Cask minimum-macOS stanza is not exact"
[ "$(/usr/bin/grep -Fxc '  app "JBar.app"' "$SUCCESS_CASK")" = 1 ] ||
  fail "rendered Cask application stanza is not exact"
[ "$(/usr/bin/grep -Fxc '  url "https://github.com/linjiw/jbar/releases/download/v#{version}/JBar-#{version}-universal.zip"' "$SUCCESS_CASK")" = 1 ] ||
  fail "rendered Cask URL stanza is not exact"
if /usr/bin/grep -Eq '@(VERSION|SHA256)@' "$SUCCESS_CASK"; then
  fail "rendered Cask retains a release placeholder"
fi
assert_no_render_state "$SUCCESS_DIR"
TESTS_RUN=$((TESTS_RUN + 1))

# Reject malformed release metadata and any output token other than jbar.rb.
/bin/mkdir -m 0700 "$TEST_ROOT/invalid"
expect_failure invalid-version "$RENDERER" 1.2 "$SHA256" "$TEST_ROOT/invalid/jbar.rb"
expect_failure invalid-sha "$RENDERER" "$VERSION" ABCD "$TEST_ROOT/invalid/jbar.rb"
expect_failure wrong-output-name "$RENDERER" "$VERSION" "$SHA256" "$TEST_ROOT/invalid/not-jbar.rb"
[ -z "$(/usr/bin/find "$TEST_ROOT/invalid" -mindepth 1 -print -quit)" ] ||
  fail "invalid arguments created output state"
expect_failure missing-output-parent "$RENDERER" "$VERSION" "$SHA256" \
  "$TEST_ROOT/missing-parent/jbar.rb"
[ ! -e "$TEST_ROOT/missing-parent" ] && [ ! -L "$TEST_ROOT/missing-parent" ] ||
  fail "renderer created a missing output parent"

# Refuse and preserve every existing destination type without following symlinks.
EXISTING_DIR="$TEST_ROOT/existing"
/bin/mkdir -m 0700 "$EXISTING_DIR"
EXISTING_CASK="$EXISTING_DIR/jbar.rb"
printf 'old immutable Cask\n' > "$EXISTING_CASK"
EXISTING_IDENTITY="$(/usr/bin/stat -f '%d:%i:%z' "$EXISTING_CASK")"
expect_failure existing-regular "$RENDERER" "$VERSION" "$SHA256" "$EXISTING_CASK"
[ "$(/usr/bin/stat -f '%d:%i:%z' "$EXISTING_CASK")" = "$EXISTING_IDENTITY" ] ||
  fail "renderer replaced the old Cask"
[ "$(sed -n '1p' "$EXISTING_CASK")" = "old immutable Cask" ] || fail "renderer changed old Cask contents"

SYMLINK_DIR="$TEST_ROOT/symlink"
/bin/mkdir -m 0700 "$SYMLINK_DIR"
SYMLINK_TARGET="$TEST_ROOT/symlink-target"
printf 'do not follow\n' > "$SYMLINK_TARGET"
/bin/ln -s "$SYMLINK_TARGET" "$SYMLINK_DIR/jbar.rb"
expect_failure existing-symlink "$RENDERER" "$VERSION" "$SHA256" "$SYMLINK_DIR/jbar.rb"
[ -L "$SYMLINK_DIR/jbar.rb" ] || fail "renderer replaced the output symlink"
[ "$(sed -n '1p' "$SYMLINK_TARGET")" = "do not follow" ] || fail "renderer followed the output symlink"

DIRECTORY_DIR="$TEST_ROOT/directory"
/bin/mkdir -m 0700 "$DIRECTORY_DIR"
/bin/mkdir "$DIRECTORY_DIR/jbar.rb"
expect_failure existing-directory "$RENDERER" "$VERSION" "$SHA256" "$DIRECTORY_DIR/jbar.rb"
[ -d "$DIRECTORY_DIR/jbar.rb" ] || fail "renderer replaced the output directory"

FIFO_DIR="$TEST_ROOT/fifo"
/bin/mkdir -m 0700 "$FIFO_DIR"
/usr/bin/mkfifo "$FIFO_DIR/jbar.rb"
expect_failure existing-fifo "$RENDERER" "$VERSION" "$SHA256" "$FIFO_DIR/jbar.rb"
[ -p "$FIFO_DIR/jbar.rb" ] || fail "renderer replaced the output FIFO"

# Parent capability policy rejects writable/ACL-bearing directories before creating a stage.
UNSAFE_DIR="$TEST_ROOT/unsafe-parent"
/bin/mkdir -m 0777 "$UNSAFE_DIR"
expect_failure unsafe-parent "$RENDERER" "$VERSION" "$SHA256" "$UNSAFE_DIR/jbar.rb"
[ ! -e "$UNSAFE_DIR/jbar.rb" ] && [ ! -L "$UNSAFE_DIR/jbar.rb" ] ||
  fail "renderer wrote into an unsafe parent"
/bin/chmod 0700 "$UNSAFE_DIR"

ACL_DIR="$TEST_ROOT/acl-parent"
/bin/mkdir -m 0700 "$ACL_DIR"
/bin/chmod +a 'everyone allow read' "$ACL_DIR"
expect_failure acl-parent "$RENDERER" "$VERSION" "$SHA256" "$ACL_DIR/jbar.rb"
[ ! -e "$ACL_DIR/jbar.rb" ] && [ ! -L "$ACL_DIR/jbar.rb" ] ||
  fail "renderer wrote into an ACL-bearing parent"
/bin/chmod -N "$ACL_DIR"

# Failures and TERM at every transaction boundary remove only this transaction's output and stage.
for fault in before_stage_identity after_stage_create after_render after_publish term_after_render term_after_link term_after_publish; do
  FAULT_DIR="$TEST_ROOT/fault-$fault"
  /bin/mkdir -m 0700 "$FAULT_DIR"
  expect_failure "transaction-$fault" env \
    JBAR_CASK_TEST_MODE=1 JBAR_CASK_TEST_FAIL_AT="$fault" \
    "$RENDERER" "$VERSION" "$SHA256" "$FAULT_DIR/jbar.rb"
  [ ! -e "$FAULT_DIR/jbar.rb" ] && [ ! -L "$FAULT_DIR/jbar.rb" ] ||
    fail "$fault left a partially published Cask"
  assert_no_render_state "$FAULT_DIR"
done

# The test-only fault surface is closed in ordinary renderer invocations.
GUARD_DIR="$TEST_ROOT/guard"
/bin/mkdir -m 0700 "$GUARD_DIR"
expect_failure test-override-guard env JBAR_CASK_TEST_FAIL_AT=after_render \
  "$RENDERER" "$VERSION" "$SHA256" "$GUARD_DIR/jbar.rb"
[ ! -e "$GUARD_DIR/jbar.rb" ] && [ ! -L "$GUARD_DIR/jbar.rb" ] ||
  fail "unguarded renderer fault override created output"

# Race a directory into the absent output after staging begins. Exact File.link publication must
# fail without treating that directory as a destination container.
RACE_DIR="$TEST_ROOT/race"
/bin/mkdir -m 0700 "$RACE_DIR"
(
  attempts=0
  while [ -z "$(/usr/bin/find "$RACE_DIR" -maxdepth 1 -name '.jbar-cask.*' -print -quit)" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 2000 ] || exit 70
    /bin/sleep 0.005
  done
  /bin/mkdir "$RACE_DIR/jbar.rb"
) &
WATCHER_PID=$!
expect_failure raced-directory-publication "$RENDERER" "$VERSION" "$SHA256" "$RACE_DIR/jbar.rb"
wait "$WATCHER_PID" || fail "renderer race watcher did not create the output directory"
WATCHER_PID=""
[ -d "$RACE_DIR/jbar.rb" ] || fail "renderer removed the raced output directory"
[ -z "$(/usr/bin/find "$RACE_DIR/jbar.rb" -mindepth 1 -print -quit)" ] ||
  fail "renderer wrote inside the raced output directory"
assert_no_render_state "$RACE_DIR"

# Run altered templates only from an isolated fake repository to exercise placeholder and stanza
# fail-closed checks without ever mutating the checked-in template.
FAKE_ROOT="$TEST_ROOT/fake-placeholder"
/bin/mkdir -p "$FAKE_ROOT/scripts" "$FAKE_ROOT/packaging/homebrew" "$FAKE_ROOT/out"
/bin/chmod 0700 "$FAKE_ROOT/out"
/usr/bin/ditto "$RENDERER" "$FAKE_ROOT/scripts/render-homebrew-cask.sh"
/usr/bin/ditto "$TEMPLATE" "$FAKE_ROOT/packaging/homebrew/jbar.rb.template"
printf '# duplicate @VERSION@\n' >> "$FAKE_ROOT/packaging/homebrew/jbar.rb.template"
FAKE_TEMPLATE_SHA="$(/usr/bin/shasum -a 256 "$FAKE_ROOT/packaging/homebrew/jbar.rb.template" | /usr/bin/awk '{print $1}')"
/usr/bin/sed -i '' "s/EXPECTED_TEMPLATE_SHA256=$TEMPLATE_SHA_BEFORE/EXPECTED_TEMPLATE_SHA256=$FAKE_TEMPLATE_SHA/" \
  "$FAKE_ROOT/scripts/render-homebrew-cask.sh"
expect_failure duplicate-placeholder "$FAKE_ROOT/scripts/render-homebrew-cask.sh" \
  "$VERSION" "$SHA256" "$FAKE_ROOT/out/jbar.rb"
[ ! -e "$FAKE_ROOT/out/jbar.rb" ] || fail "duplicate placeholder produced a Cask"
assert_no_render_state "$FAKE_ROOT/out"

FAKE_ROOT="$TEST_ROOT/fake-stanza"
/bin/mkdir -p "$FAKE_ROOT/scripts" "$FAKE_ROOT/packaging/homebrew" "$FAKE_ROOT/out"
/bin/chmod 0700 "$FAKE_ROOT/out"
/usr/bin/ditto "$RENDERER" "$FAKE_ROOT/scripts/render-homebrew-cask.sh"
/usr/bin/sed 's/depends_on macos: :ventura/depends_on macos: ">= :ventura"/' \
  "$TEMPLATE" > "$FAKE_ROOT/packaging/homebrew/jbar.rb.template"
/bin/chmod 0644 "$FAKE_ROOT/packaging/homebrew/jbar.rb.template"
FAKE_TEMPLATE_SHA="$(/usr/bin/shasum -a 256 "$FAKE_ROOT/packaging/homebrew/jbar.rb.template" | /usr/bin/awk '{print $1}')"
/usr/bin/sed -i '' "s/EXPECTED_TEMPLATE_SHA256=$TEMPLATE_SHA_BEFORE/EXPECTED_TEMPLATE_SHA256=$FAKE_TEMPLATE_SHA/" \
  "$FAKE_ROOT/scripts/render-homebrew-cask.sh"
expect_failure deprecated-macos-stanza "$FAKE_ROOT/scripts/render-homebrew-cask.sh" \
  "$VERSION" "$SHA256" "$FAKE_ROOT/out/jbar.rb"
[ ! -e "$FAKE_ROOT/out/jbar.rb" ] || fail "deprecated minimum-macOS stanza produced a Cask"
assert_no_render_state "$FAKE_ROOT/out"

TEMPLATE_SHA_AFTER="$(/usr/bin/shasum -a 256 "$TEMPLATE" | /usr/bin/awk '{print $1}')"
[ "$TEMPLATE_SHA_AFTER" = "$TEMPLATE_SHA_BEFORE" ] || fail "renderer tests changed the source template"

echo "PASS: $TESTS_RUN isolated Homebrew Cask renderer safety cases"

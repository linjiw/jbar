#!/bin/bash
# Isolated fail-closed tests for scripts/package-app.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
PACKAGER="$ROOT/scripts/package-app.sh"
RENDER_SAFETY="$ROOT/scripts/tests/render-homebrew-cask-safety.sh"
SOURCE_APP="${JBAR_PACKAGE_TEST_SOURCE_APP:-$ROOT/build/JBar.app}"
TEST_PARENT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
TEST_ROOT="$(/usr/bin/mktemp -d "$TEST_PARENT/jbar-package-tests.XXXXXXXX")"
TESTS_RUN=0

cleanup() {
  if [ "$(dirname "$TEST_ROOT")" = "$TEST_PARENT" ] &&
     [[ "$(basename "$TEST_ROOT")" == jbar-package-tests.* ]] &&
     [ "$(/usr/bin/stat -f '%u:%Lp' "$TEST_ROOT" 2>/dev/null)" = "$(/usr/bin/id -u):700" ]; then
    /usr/bin/find -x "$TEST_ROOT" -depth -mindepth 1 -delete
    /bin/rmdir -- "$TEST_ROOT"
  else
    echo "error: refusing unsafe package-test cleanup: $TEST_ROOT" >&2
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

assert_no_package_state() {
  [ -z "$(/usr/bin/find "$TEST_ROOT" -maxdepth 2 -name '.jbar-package.*' -print -quit)" ] ||
    fail "package staging state leaked"
}

expect_failure() {
  local name="$1"
  shift
  if "$@" >"$TEST_ROOT/$name.log" 2>&1; then
    fail "$name unexpectedly succeeded"
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
}

[ -x "$PACKAGER" ] || fail "packager is not executable"
[ -d "$SOURCE_APP" ] || fail "missing source app: $SOURCE_APP"
[ "$(/usr/bin/stat -f '%Lp' "$TEST_ROOT")" = 700 ] || fail "package-test root is not mode 0700"
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP" || fail "source app has an invalid signature"

# The happy path must preserve the wrapper, executable mode, signature, and exact CLI version.
SUCCESS_ZIP="$TEST_ROOT/JBar-成功 universal.zip"
"$PACKAGER" "$SOURCE_APP" "$SUCCESS_ZIP" >"$TEST_ROOT/success.log"
[ -s "$SUCCESS_ZIP" ] || fail "success archive is missing"
/usr/bin/zipinfo -1 "$SUCCESS_ZIP" > "$TEST_ROOT/success.entries"
[ "$(/usr/bin/grep -Fxc 'JBar.app/' "$TEST_ROOT/success.entries")" = 1 ] ||
  fail "ZIP does not contain one exact JBar.app/ root entry"
while IFS= read -r entry; do
  case "$entry" in
    JBar.app/|JBar.app/*|__MACOSX/|__MACOSX/JBar.app/|__MACOSX/JBar.app/*) ;;
    *) fail "ZIP has an unexpected raw entry: $entry" ;;
  esac
done < "$TEST_ROOT/success.entries"
/usr/bin/ditto -x -k "$SUCCESS_ZIP" "$TEST_ROOT/extracted"
[ "$(/usr/bin/find "$TEST_ROOT/extracted" -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 1 ] ||
  fail "archive has more than one extracted top-level entry"
[ -d "$TEST_ROOT/extracted/JBar.app" ] && [ ! -L "$TEST_ROOT/extracted/JBar.app" ] ||
  fail "archive does not have exact top-level JBar.app"
[ -x "$TEST_ROOT/extracted/JBar.app/Contents/MacOS/JBar" ] || fail "archive lost executable mode"
[ "$(/usr/bin/stat -f '%Lp' "$SUCCESS_ZIP")" = 644 ] || fail "published ZIP is not mode 0644"
[ "$(/usr/bin/stat -f '%l' "$SUCCESS_ZIP")" = 1 ] || fail "published ZIP is multiply linked"
assert_acl_free "$SUCCESS_ZIP"
/usr/bin/find -x "$TEST_ROOT/extracted/JBar.app" -type d -print0 |
  while IFS= read -r -d '' entry; do
    [ "$(/usr/bin/stat -f '%Lp' "$entry")" = 755 ] || fail "unsafe directory mode: $entry"
    assert_acl_free "$entry"
  done
/usr/bin/find -x "$TEST_ROOT/extracted/JBar.app" -type f -print0 |
  while IFS= read -r -d '' entry; do
    expected_mode=644
    [ "$entry" = "$TEST_ROOT/extracted/JBar.app/Contents/MacOS/JBar" ] && expected_mode=755
    [ "$(/usr/bin/stat -f '%Lp' "$entry")" = "$expected_mode" ] || fail "unsafe file mode: $entry"
    [ "$(/usr/bin/stat -f '%l' "$entry")" = 1 ] || fail "multiply-linked archive file: $entry"
    assert_acl_free "$entry"
  done
/usr/bin/codesign --verify --deep --strict "$TEST_ROOT/extracted/JBar.app" || fail "archive signature invalid"
SUCCESS_SHA="$(/usr/bin/shasum -a 256 "$SUCCESS_ZIP" | /usr/bin/awk '{print $1}')"
/usr/bin/grep -Fqx "$SUCCESS_SHA  $SUCCESS_ZIP" "$TEST_ROOT/success.log" ||
  fail "packager did not report the published ZIP checksum"
assert_no_package_state
TESTS_RUN=$((TESTS_RUN + 1))

# ditto's metadata path must retain quarantine metadata while ACLs remain forbidden. The final
# Gatekeeper decision still requires the separately signed/notarized external release gate.
QUARANTINE_APP="$TEST_ROOT/quarantine/JBar.app"
/bin/mkdir -p "$(dirname "$QUARANTINE_APP")"
/usr/bin/ditto "$SOURCE_APP" "$QUARANTINE_APP"
/usr/bin/xattr -w com.apple.quarantine '0081;00000000;JBarPackageTest;' \
  "$QUARANTINE_APP/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --verify --deep --strict "$QUARANTINE_APP" ||
  fail "quarantine fixture invalidated signature"
QUARANTINE_ZIP="$TEST_ROOT/quarantine.zip"
"$PACKAGER" "$QUARANTINE_APP" "$QUARANTINE_ZIP" > "$TEST_ROOT/quarantine.log"
/bin/mkdir "$TEST_ROOT/quarantine-extracted"
/usr/bin/ditto -x -k "$QUARANTINE_ZIP" "$TEST_ROOT/quarantine-extracted"
/usr/bin/xattr -p com.apple.quarantine \
  "$TEST_ROOT/quarantine-extracted/JBar.app/Contents/Resources/AppIcon.icns" >/dev/null ||
  fail "archive did not preserve quarantine metadata"
assert_no_package_state
TESTS_RUN=$((TESTS_RUN + 1))

# A post-signature mutation must be rejected.
TAMPERED="$TEST_ROOT/tampered/JBar.app"
/bin/mkdir -p "$(dirname "$TAMPERED")"
/usr/bin/ditto "$SOURCE_APP" "$TAMPERED"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 999999' "$TAMPERED/Contents/Info.plist"
expect_failure tampered-signature "$PACKAGER" "$TAMPERED" "$TEST_ROOT/tampered.zip"

# Even a validly re-signed bundle is rejected when its identity is not JBar's.
WRONG_ID="$TEST_ROOT/wrong-id/JBar.app"
/bin/mkdir -p "$(dirname "$WRONG_ID")"
/usr/bin/ditto "$SOURCE_APP" "$WRONG_ID"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.not-jbar' "$WRONG_ID/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$WRONG_ID" >/dev/null
expect_failure wrong-bundle-id "$PACKAGER" "$WRONG_ID" "$TEST_ROOT/wrong-id.zip"

# A GUI release must remain an APPL bundle even when the altered plist is re-signed.
WRONG_PACKAGE_TYPE="$TEST_ROOT/wrong-package-type/JBar.app"
/bin/mkdir -p "$(dirname "$WRONG_PACKAGE_TYPE")"
/usr/bin/ditto "$SOURCE_APP" "$WRONG_PACKAGE_TYPE"
/usr/libexec/PlistBuddy -c 'Set :CFBundlePackageType BNDL' "$WRONG_PACKAGE_TYPE/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$WRONG_PACKAGE_TYPE" >/dev/null
expect_failure wrong-package-type "$PACKAGER" "$WRONG_PACKAGE_TYPE" "$TEST_ROOT/wrong-package-type.zip"

# The legacy bundle type marker remains part of the exact wrapper contract.
MISSING_PKGINFO="$TEST_ROOT/missing-pkginfo/JBar.app"
/bin/mkdir -p "$(dirname "$MISSING_PKGINFO")"
/usr/bin/ditto "$SOURCE_APP" "$MISSING_PKGINFO"
/bin/rm -- "$MISSING_PKGINFO/Contents/PkgInfo"
/usr/bin/codesign --force --sign - "$MISSING_PKGINFO" >/dev/null
expect_failure missing-pkginfo "$PACKAGER" "$MISSING_PKGINFO" "$TEST_ROOT/missing-pkginfo.zip"

WRONG_PKGINFO="$TEST_ROOT/wrong-pkginfo/JBar.app"
/bin/mkdir -p "$(dirname "$WRONG_PKGINFO")"
/usr/bin/ditto "$SOURCE_APP" "$WRONG_PKGINFO"
printf 'BNDL????' > "$WRONG_PKGINFO/Contents/PkgInfo"
/bin/chmod 0644 "$WRONG_PKGINFO/Contents/PkgInfo"
/usr/bin/codesign --force --sign - "$WRONG_PKGINFO" >/dev/null
expect_failure wrong-pkginfo "$PACKAGER" "$WRONG_PKGINFO" "$TEST_ROOT/wrong-pkginfo.zip"

# The archive contract has an exact wrapper name and cannot silently publish a renamed bundle.
RENAMED_APP="$TEST_ROOT/renamed/Renamed.app"
/bin/mkdir -p "$(dirname "$RENAMED_APP")"
/usr/bin/ditto "$SOURCE_APP" "$RENAMED_APP"
expect_failure renamed-wrapper "$PACKAGER" "$RENAMED_APP" "$TEST_ROOT/renamed.zip"

# Both the plist and every Mach-O slice are fixed at the release floor, macOS 13.0.
WRONG_MIN_OS="$TEST_ROOT/wrong-min-os/JBar.app"
/bin/mkdir -p "$(dirname "$WRONG_MIN_OS")"
/usr/bin/ditto "$SOURCE_APP" "$WRONG_MIN_OS"
/usr/libexec/PlistBuddy -c 'Set :LSMinimumSystemVersion 14.0' "$WRONG_MIN_OS/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$WRONG_MIN_OS" >/dev/null
expect_failure wrong-plist-min-os "$PACKAGER" "$WRONG_MIN_OS" "$TEST_ROOT/wrong-min-os.zip"
expect_failure min-os-override env JBAR_EXPECT_MIN_MACOS=14.0 \
  "$PACKAGER" "$SOURCE_APP" "$TEST_ROOT/min-os-override.zip"

# The bundle must use deterministic safe modes, not merely an executable bit.
UNSAFE_MODE="$TEST_ROOT/unsafe-mode/JBar.app"
/bin/mkdir -p "$(dirname "$UNSAFE_MODE")"
/usr/bin/ditto "$SOURCE_APP" "$UNSAFE_MODE"
/bin/chmod 0777 "$UNSAFE_MODE/Contents/MacOS/JBar"
/usr/bin/codesign --force --sign - "$UNSAFE_MODE" >/dev/null
expect_failure unsafe-executable-mode "$PACKAGER" "$UNSAFE_MODE" "$TEST_ROOT/unsafe-mode.zip"

# ACLs, multiply-linked regular files, and special nodes are outside the release bundle contract.
ACL_APP="$TEST_ROOT/acl/JBar.app"
/bin/mkdir -p "$(dirname "$ACL_APP")"
/usr/bin/ditto "$SOURCE_APP" "$ACL_APP"
/bin/chmod +a 'everyone allow read' "$ACL_APP"
assert_acl_free "$SOURCE_APP"
expect_failure source-acl "$PACKAGER" "$ACL_APP" "$TEST_ROOT/acl.zip"

HARDLINK_APP="$TEST_ROOT/hardlink/JBar.app"
/bin/mkdir -p "$(dirname "$HARDLINK_APP")"
/usr/bin/ditto "$SOURCE_APP" "$HARDLINK_APP"
/bin/ln "$HARDLINK_APP/Contents/Info.plist" "$TEST_ROOT/hardlink-peer"
[ "$(/usr/bin/stat -f '%l' "$HARDLINK_APP/Contents/Info.plist")" = 2 ] ||
  fail "hard-link fixture was not created"
expect_failure source-hardlink "$PACKAGER" "$HARDLINK_APP" "$TEST_ROOT/hardlink.zip"

SPECIAL_APP="$TEST_ROOT/special/JBar.app"
/bin/mkdir -p "$(dirname "$SPECIAL_APP")"
/usr/bin/ditto "$SOURCE_APP" "$SPECIAL_APP"
/usr/bin/mkfifo "$SPECIAL_APP/Contents/Resources/unsafe.fifo"
expect_failure source-special-file "$PACKAGER" "$SPECIAL_APP" "$TEST_ROOT/special.zip"

# Default release packaging requires both Intel and Apple Silicon slices.
THIN="$TEST_ROOT/thin/JBar.app"
/bin/mkdir -p "$(dirname "$THIN")"
/usr/bin/ditto "$SOURCE_APP" "$THIN"
/usr/bin/lipo -thin arm64 "$THIN/Contents/MacOS/JBar" -output "$THIN/Contents/MacOS/JBar.thin"
/bin/mv "$THIN/Contents/MacOS/JBar.thin" "$THIN/Contents/MacOS/JBar"
/bin/chmod +x "$THIN/Contents/MacOS/JBar"
/usr/bin/codesign --force --sign - "$THIN" >/dev/null
expect_failure missing-intel-slice "$PACKAGER" "$THIN" "$TEST_ROOT/thin.zip"

# Symlinked inputs and non-ZIP outputs are rejected before archive creation.
/bin/ln -s "$SOURCE_APP" "$TEST_ROOT/JBar-link.app"
expect_failure symlink-input "$PACKAGER" "$TEST_ROOT/JBar-link.app" "$TEST_ROOT/link.zip"

# JBar has no framework layout that requires internal symlinks. Refuse a signed bundle that could
# recreate links during extraction instead of assuming the archive tool will constrain them.
NESTED_LINK="$TEST_ROOT/nested-link/JBar.app"
/bin/mkdir -p "$(dirname "$NESTED_LINK")"
/usr/bin/ditto "$SOURCE_APP" "$NESTED_LINK"
/bin/ln -s /tmp "$NESTED_LINK/Contents/Resources/unsafe-link"
/usr/bin/codesign --force --sign - "$NESTED_LINK" >/dev/null
expect_failure nested-symlink "$PACKAGER" "$NESTED_LINK" "$TEST_ROOT/nested-link.zip"

expect_failure wrong-extension "$PACKAGER" "$SOURCE_APP" "$TEST_ROOT/not-a-zip.tar"
expect_failure missing-output-parent "$PACKAGER" "$SOURCE_APP" "$TEST_ROOT/missing-parent/output.zip"
[ ! -e "$TEST_ROOT/missing-parent" ] && [ ! -L "$TEST_ROOT/missing-parent" ] ||
  fail "packager created a missing output parent"

# An ad-hoc development bundle cannot pass the opt-in public Developer ID Application requirement.
expect_failure developer-id-required env \
  JBAR_REQUIRE_DEVELOPER_ID=1 JBAR_EXPECTED_TEAM_ID=ABCDEFGHIJ \
  "$PACKAGER" "$SOURCE_APP" "$TEST_ROOT/developer-id.zip"
expect_failure team-id-without-requirement env JBAR_EXPECTED_TEAM_ID=ABCDEFGHIJ \
  "$PACKAGER" "$SOURCE_APP" "$TEST_ROOT/team-id-without-requirement.zip"
expect_failure invalid-developer-id-boolean env JBAR_REQUIRE_DEVELOPER_ID=2 \
  "$PACKAGER" "$SOURCE_APP" "$TEST_ROOT/invalid-developer-id-boolean.zip"

# Publishing never follows or replaces a caller-controlled output symlink.
OUTPUT_SENTINEL="$TEST_ROOT/output-symlink-target"
OUTPUT_LINK="$TEST_ROOT/output-link.zip"
printf 'do not replace\n' > "$OUTPUT_SENTINEL"
/bin/ln -s "$OUTPUT_SENTINEL" "$OUTPUT_LINK"
expect_failure symlink-output "$PACKAGER" "$SOURCE_APP" "$OUTPUT_LINK"
[ -L "$OUTPUT_LINK" ] || fail "packager replaced the output symlink"
[ "$(sed -n '1p' "$OUTPUT_SENTINEL")" = "do not replace" ] || fail "packager changed the output symlink target"

# An existing ordinary artifact is immutable too; no failure path may truncate or replace it.
EXISTING_OUTPUT="$TEST_ROOT/existing.zip"
printf 'previous immutable release\n' > "$EXISTING_OUTPUT"
EXISTING_IDENTITY="$(/usr/bin/stat -f '%d:%i:%z' "$EXISTING_OUTPUT")"
expect_failure existing-output "$PACKAGER" "$SOURCE_APP" "$EXISTING_OUTPUT"
[ "$(/usr/bin/stat -f '%d:%i:%z' "$EXISTING_OUTPUT")" = "$EXISTING_IDENTITY" ] ||
  fail "packager replaced or changed the existing release artifact"
[ "$(sed -n '1p' "$EXISTING_OUTPUT")" = "previous immutable release" ] ||
  fail "packager changed existing release contents"

# Existing non-regular outputs are refused without traversing or removing them.
OUTPUT_DIRECTORY="$TEST_ROOT/output-directory.zip"
/bin/mkdir "$OUTPUT_DIRECTORY"
expect_failure directory-output "$PACKAGER" "$SOURCE_APP" "$OUTPUT_DIRECTORY"
[ -d "$OUTPUT_DIRECTORY" ] && [ ! -e "$OUTPUT_DIRECTORY/archive.zip" ] ||
  fail "packager treated an output directory as a publication container"

OUTPUT_FIFO="$TEST_ROOT/output-fifo.zip"
/usr/bin/mkfifo "$OUTPUT_FIFO"
expect_failure fifo-output "$PACKAGER" "$SOURCE_APP" "$OUTPUT_FIFO"
[ -p "$OUTPUT_FIFO" ] || fail "packager replaced the output FIFO"

# Packaging must not mutate a signed input bundle by accepting an output path inside it.
expect_failure output-inside-app "$PACKAGER" "$SOURCE_APP" "$SOURCE_APP/Contents/forbidden.zip"
[ ! -e "$SOURCE_APP/Contents/forbidden.zip" ] || fail "packager wrote inside the signed source app"
expect_failure missing-parent-inside-app "$PACKAGER" "$SOURCE_APP" \
  "$SOURCE_APP/Contents/forbidden-parent/forbidden.zip"
[ ! -e "$SOURCE_APP/Contents/forbidden-parent" ] && [ ! -L "$SOURCE_APP/Contents/forbidden-parent" ] ||
  fail "packager created an output parent inside the signed source app"
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP" || fail "inside-app refusal changed the source signature"

# Every staging/publication failure, including TERM on each side of link/unlink, rolls back a new
# destination and removes the exact transaction directory.
for fault in before_stage_identity after_stage_create after_archive after_extract after_publish \
  term_after_archive term_after_link term_after_publish; do
  FAULT_OUTPUT="$TEST_ROOT/fault-$fault.zip"
  expect_failure "transaction-$fault" env \
    JBAR_PACKAGE_TEST_MODE=1 JBAR_PACKAGE_TEST_FAIL_AT="$fault" \
    "$PACKAGER" "$SOURCE_APP" "$FAULT_OUTPUT"
  [ ! -e "$FAULT_OUTPUT" ] && [ ! -L "$FAULT_OUTPUT" ] ||
    fail "$fault left a partially published release artifact"
  assert_no_package_state
done

# Reproduce the former mv-to-directory bug: race a directory into the absent output name after the
# private stage exists. Atomic exact-name publication must fail and preserve the raced directory.
RACE_OUTPUT="$TEST_ROOT/raced-output.zip"
(
  attempts=0
  while [ -z "$(/usr/bin/find "$TEST_ROOT" -maxdepth 1 -name '.jbar-package.*' -print -quit)" ]; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 2000 ] || exit 70
    /bin/sleep 0.005
  done
  /bin/mkdir "$RACE_OUTPUT"
) &
RACE_WATCHER=$!
expect_failure raced-directory-publication "$PACKAGER" "$SOURCE_APP" "$RACE_OUTPUT"
wait "$RACE_WATCHER" || fail "race watcher did not create the output directory"
[ -d "$RACE_OUTPUT" ] || fail "packager removed the raced output directory"
[ ! -e "$RACE_OUTPUT/archive.zip" ] || fail "packager nested the archive in the raced directory"
assert_no_package_state

# Failure injection must not be available accidentally in a normal packaging invocation.
GUARDED="$TEST_ROOT/guarded.zip"
expect_failure test-override-guard env JBAR_PACKAGE_TEST_FAIL_AT=after_archive \
  "$PACKAGER" "$SOURCE_APP" "$GUARDED"
[ ! -e "$GUARDED" ] && [ ! -L "$GUARDED" ] || fail "unguarded test override created an output"

[ -x "$RENDER_SAFETY" ] || fail "renderer safety test is not executable"
"$RENDER_SAFETY"

echo "PASS: $TESTS_RUN isolated package safety cases"

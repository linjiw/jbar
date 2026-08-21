#!/bin/bash
# Isolated fail-closed and transactional replacement checks for scripts/build-app.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BUILDER="$ROOT/scripts/build-app.sh"
TEST_PARENT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
TEST_ROOT="$(/usr/bin/mktemp -d "$TEST_PARENT/jbar-build-tests.XXXXXXXX")"
OUT="$TEST_ROOT/输出 目录"

cleanup() {
  if [ "$(dirname "$TEST_ROOT")" = "$TEST_PARENT" ] &&
     [[ "$(basename "$TEST_ROOT")" == jbar-build-tests.* ]]; then
    /bin/rm -rf -- "$TEST_ROOT"
  else
    echo "error: refusing unsafe build-test cleanup: $TEST_ROOT" >&2
  fi
}
trap cleanup EXIT INT TERM HUP

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_developer_id_requirement() {
  # This intentionally matches the literal source-level variable reference.
  # shellcheck disable=SC2016
  local canonical='requirement="identifier \"com.linji.jbar\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""'
  /usr/bin/grep -Fq "$canonical" "$BUILDER" ||
    fail "build trust requirement does not construct the canonical Developer ID Application chain"
  /usr/bin/grep -Fq 'identifier \"com.linji.jbar\" and anchor apple generic' "$BUILDER" ||
    fail "build trust requirement does not bind the bundle identifier to Apple's anchor"
  /usr/bin/grep -Fq 'certificate 1[field.1.2.840.113635.100.6.2.6] exists' "$BUILDER" ||
    fail "build trust requirement lacks the Developer ID intermediate OID"
  /usr/bin/grep -Fq 'certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$BUILDER" ||
    fail "build trust requirement lacks the Developer ID Application leaf OID"
  # shellcheck disable=SC2016
  /usr/bin/grep -Fq 'certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\"' "$BUILDER" ||
    fail "build trust requirement does not bind the expected Team ID"
}
assert_developer_id_requirement
if ! /usr/bin/grep -Fq 'UInt32(RENAME_SWAP)' "$BUILDER" ||
   /usr/bin/grep -Fq 'FileManager.default.replaceItemAt' "$BUILDER"; then
  fail "builder does not use an explicit RENAME_SWAP-only upgrade transaction"
fi
run_builder() {
  local build_number="$1"
  shift
  env JBAR_ARCHS=arm64 JBAR_VERSION=0.1.0 JBAR_BUILD_NUMBER="$build_number" "$@" "$BUILDER" "$OUT"
}
resign_app() {
  /usr/bin/codesign --force --sign - "$1" >/dev/null
}
assert_no_transaction() {
  local output="$1"
  [ -z "$(/usr/bin/find "$output" -maxdepth 1 \( -name '.jbar-build.*' -o -name '.jbar-build-backup.*.app' \) -print -quit)" ] ||
    fail "build leaked staging or backup state in $output"
}

/bin/mkdir -p "$OUT/JBar.app"
printf 'unrelated user data\n' > "$OUT/JBar.app/DO-NOT-DELETE"
if run_builder 1 > "$TEST_ROOT/unrelated.log" 2>&1; then
  fail "builder replaced an unidentified JBar.app directory"
fi
[ -f "$OUT/JBar.app/DO-NOT-DELETE" ] || fail "unidentified output was changed"
[ -z "$(/usr/bin/find "$OUT" -maxdepth 1 -name '.jbar-build.*' -print -quit)" ] ||
  fail "failed build leaked a staging directory"

/bin/rm -rf -- "$OUT/JBar.app"
(umask 000; run_builder 1 > "$TEST_ROOT/first.log")
[ -x "$OUT/JBar.app/Contents/MacOS/JBar" ] || fail "first build did not create an executable app"
[ "$(/usr/bin/lipo -archs "$OUT/JBar.app/Contents/MacOS/JBar")" = "arm64" ] ||
  fail "architecture override was not preserved"
[ "$(/usr/bin/stat -f '%Lp' "$OUT/JBar.app")" = 755 ] ||
  fail "builder did not normalize the app directory to mode 0755"
[ "$(/usr/bin/stat -f '%Lp' "$OUT/JBar.app/Contents/Info.plist")" = 644 ] ||
  fail "builder did not normalize a data file to mode 0644"
[ "$(/usr/bin/stat -f '%Lp' "$OUT/JBar.app/Contents/MacOS/JBar")" = 755 ] ||
  fail "builder did not normalize the executable to mode 0755"
[ -z "$(/usr/bin/find "$OUT/JBar.app" -acl -print -quit)" ] ||
  fail "builder left an ACL on its activated bundle"
[ -z "$(/usr/bin/find "$OUT/JBar.app" -perm +022 -print -quit)" ] ||
  fail "builder left group/world-write permission on its activated bundle"

# An ACL on an existing output is an unsafe mutation surface and is refused,
# even when the sealed code contents still satisfy codesign.
/bin/chmod +a 'everyone deny delete' "$OUT/JBar.app"
if run_builder 2 > "$TEST_ROOT/existing-acl.log" 2>&1; then
  fail "builder replaced an existing output carrying an ACL"
fi
[ -n "$(/usr/bin/find "$OUT/JBar.app" -acl -print -quit)" ] ||
  fail "ACL refusal unexpectedly modified the old bundle"
/bin/chmod -RN "$OUT/JBar.app"

# A plist-identical, validly signed directory is not accepted as an app unless
# its classic package marker is a regular file with the exact eight bytes.
/bin/rm -f -- "$OUT/JBar.app/Contents/PkgInfo"
resign_app "$OUT/JBar.app"
if run_builder 2 > "$TEST_ROOT/missing-pkginfo.log" 2>&1; then
  fail "builder replaced a signed bundle missing Contents/PkgInfo"
fi
[ ! -e "$OUT/JBar.app/Contents/PkgInfo" ] || fail "missing-PkgInfo refusal changed the old bundle"
printf 'BNDL????' > "$OUT/JBar.app/Contents/PkgInfo"
resign_app "$OUT/JBar.app"
if run_builder 2 > "$TEST_ROOT/wrong-pkginfo.log" 2>&1; then
  fail "builder replaced a signed bundle with the wrong Contents/PkgInfo marker"
fi
[ "$(/bin/cat "$OUT/JBar.app/Contents/PkgInfo")" = 'BNDL????' ] ||
  fail "wrong-PkgInfo refusal changed the old bundle"
printf 'APPL????' > "$OUT/JBar.app/Contents/PkgInfo"
resign_app "$OUT/JBar.app"

# A destination created after the absence check must make the exclusive rename
# fail. Rollback identifies only the staged inode, so it cannot move or delete
# the unrelated directory that won the race.
FIRST_RACE_OUT="$TEST_ROOT/first-install-race"
/bin/mkdir -p "$FIRST_RACE_OUT"
if env JBAR_ARCHS=arm64 JBAR_VERSION=0.1.0 JBAR_BUILD_NUMBER=1 \
   JBAR_BUILD_TEST_MODE=1 JBAR_BUILD_TEST_FAIL_AT=after_check_race \
   "$BUILDER" "$FIRST_RACE_OUT" > "$TEST_ROOT/first-install-race.log" 2>&1; then
  fail "first-install after-check race unexpectedly succeeded"
fi
[ "$(sed -n '1p' "$FIRST_RACE_OUT/JBar.app/DO-NOT-DELETE")" = 'unrelated raced destination' ] ||
  fail "builder moved or deleted the destination that won the first-install race"
assert_no_transaction "$FIRST_RACE_OUT"

# SIGKILL/power-loss cannot run a trap. RENAME_SWAP leaves the displaced app in
# the real transaction layout; that workspace is preserved and blocks a new
# build until a human chooses which valid app to recover.
STALE="$OUT/.jbar-build.stale"
/bin/mkdir -m 700 "$STALE"
/usr/bin/ditto "$OUT/JBar.app" "$STALE/JBar.app.new"
if run_builder 2 > "$TEST_ROOT/stale-backup.log" 2>&1; then
  fail "builder ignored stale recovery state"
fi
[ -d "$OUT/JBar.app" ] && [ -d "$STALE/JBar.app.new" ] || fail "stale-transaction refusal changed recovery state"
/bin/mv "$STALE" "$TEST_ROOT/preserved-stale-build-transaction"

printf 'old marker\n' > "$OUT/JBar.app/Contents/Resources/OLD-MARKER"
resign_app "$OUT/JBar.app"

run_builder 2 > "$TEST_ROOT/replacement.log"
[ ! -e "$OUT/JBar.app/Contents/Resources/OLD-MARKER" ] || fail "verified replacement retained the previous bundle"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$OUT/JBar.app/Contents/Info.plist")" = "2" ] ||
  fail "replacement did not activate the newly staged build"
[ -z "$(/usr/bin/find "$OUT" -maxdepth 1 -name '.jbar-build.*' -print -quit)" ] ||
  fail "successful replacement leaked a staging directory or backup"

# Cleanup pins the transaction inode as cwd and deletes only relative entries.
# Replacing or removing its absolute entry must fail cleanup without traversing
# the replacement, while retaining the original transaction for recovery.
printf 'cleanup old marker\n' > "$OUT/JBar.app/Contents/Resources/CLEANUP-OLD-MARKER"
resign_app "$OUT/JBar.app"
if run_builder 2 JBAR_BUILD_TEST_MODE=1 JBAR_BUILD_TEST_FAIL_AT=workdir_replacement \
   > "$TEST_ROOT/workdir-replacement.log" 2>&1; then
  fail "replaced build work-directory cleanup unexpectedly succeeded"
fi
replacement_workdir="$(/usr/bin/find "$OUT" -maxdepth 1 -type d -name '.jbar-build.*' ! -name '*.race-original' -print -quit)"
original_workdir="$(/usr/bin/find "$OUT" -maxdepth 1 -type d -name '.jbar-build.*.race-original' -print -quit)"
[ "$(sed -n '1p' "$replacement_workdir/DO-NOT-DELETE")" = 'unrelated replacement tree' ] ||
  fail "build cleanup traversed or changed the replacement work-directory tree"
[ -f "$original_workdir/JBar.app.new/Contents/Resources/CLEANUP-OLD-MARKER" ] ||
  fail "build cleanup did not retain the original replaced transaction"
[ ! -e "$OUT/JBar.app/Contents/Resources/CLEANUP-OLD-MARKER" ] ||
  fail "work-directory replacement failure rolled back a committed build"
/bin/mv "$replacement_workdir" "$TEST_ROOT/preserved-build-workdir-replacement"
/bin/mv "$original_workdir" "$TEST_ROOT/preserved-build-workdir-original"

printf 'cleanup missing marker\n' > "$OUT/JBar.app/Contents/Resources/CLEANUP-MISSING-MARKER"
resign_app "$OUT/JBar.app"
if run_builder 2 JBAR_BUILD_TEST_MODE=1 JBAR_BUILD_TEST_FAIL_AT=workdir_missing \
   > "$TEST_ROOT/workdir-missing.log" 2>&1; then
  fail "missing build work-directory cleanup unexpectedly succeeded"
fi
missing_original="$(/usr/bin/find "$OUT" -maxdepth 1 -type d -name '.jbar-build.*.race-original' -print -quit)"
[ -n "$missing_original" ] || fail "missing-entry cleanup lost the original build transaction"
[ -f "$missing_original/JBar.app.new/Contents/Resources/CLEANUP-MISSING-MARKER" ] ||
  fail "missing-entry cleanup changed the original build transaction"
[ ! -e "$OUT/JBar.app/Contents/Resources/CLEANUP-MISSING-MARKER" ] ||
  fail "work-directory missing failure rolled back a committed build"
/bin/mv "$missing_original" "$TEST_ROOT/preserved-build-workdir-missing-original"

printf 'rollback marker\n' > "$OUT/JBar.app/Contents/Resources/ROLLBACK-MARKER"
resign_app "$OUT/JBar.app"
if run_builder 3 JBAR_BUILD_TEST_FAIL_AT=after_backup > "$TEST_ROOT/unguarded-injection.log" 2>&1; then
  fail "builder accepted an unguarded failure-injection variable"
fi
[ -f "$OUT/JBar.app/Contents/Resources/ROLLBACK-MARKER" ] || fail "unguarded test override changed the installed bundle"

if run_builder 3 JBAR_BUILD_TEST_MODE=1 JBAR_BUILD_TEST_FAIL_AT=after_swap > "$TEST_ROOT/rollback-swap.log" 2>&1; then
  fail "injected post-swap failure unexpectedly succeeded"
fi
[ -f "$OUT/JBar.app/Contents/Resources/ROLLBACK-MARKER" ] || fail "post-swap failure did not restore the previous bundle"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$OUT/JBar.app/Contents/Info.plist")" = "2" ] ||
  fail "post-swap failure activated the replacement"
[ -z "$(/usr/bin/find "$OUT" -maxdepth 1 -name '.jbar-build.*' -print -quit)" ] ||
  fail "post-swap rollback leaked a transaction"

if run_builder 3 JBAR_BUILD_TEST_MODE=1 JBAR_BUILD_TEST_FAIL_AT=swap_failure > "$TEST_ROOT/swap-failure.log" 2>&1; then
  fail "injected atomic-swap failure unexpectedly succeeded"
fi
[ -f "$OUT/JBar.app/Contents/Resources/ROLLBACK-MARKER" ] ||
  fail "atomic-swap failure did not leave the previous bundle in place"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$OUT/JBar.app/Contents/Info.plist")" = "2" ] ||
  fail "atomic-swap failure changed the active bundle"
assert_no_transaction "$OUT"

if run_builder 3 JBAR_BUILD_TEST_MODE=1 JBAR_BUILD_TEST_FAIL_AT=term_after_swap > "$TEST_ROOT/term-after-swap.log" 2>&1; then
  fail "TERM immediately after atomic swap unexpectedly succeeded"
fi
[ -f "$OUT/JBar.app/Contents/Resources/ROLLBACK-MARKER" ] ||
  fail "TERM immediately after atomic swap did not restore the previous bundle"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$OUT/JBar.app/Contents/Info.plist")" = "2" ] ||
  fail "TERM immediately after atomic swap left the replacement active"
assert_no_transaction "$OUT"

if run_builder 4 JBAR_BUILD_TEST_MODE=1 JBAR_BUILD_TEST_FAIL_AT=after_activate > "$TEST_ROOT/rollback-activate.log" 2>&1; then
  fail "injected post-activation failure unexpectedly succeeded"
fi
[ -f "$OUT/JBar.app/Contents/Resources/ROLLBACK-MARKER" ] || fail "post-activation failure did not restore the previous bundle"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$OUT/JBar.app/Contents/Info.plist")" = "2" ] ||
  fail "post-activation failure left the replacement active"
[ -z "$(/usr/bin/find "$OUT" -maxdepth 1 -name '.jbar-build.*' -print -quit)" ] ||
  fail "post-activation rollback leaked a transaction"

if run_builder 4 JBAR_BUILD_TEST_MODE=1 JBAR_BUILD_TEST_FAIL_AT=term_after_activate > "$TEST_ROOT/rollback-term.log" 2>&1; then
  fail "post-activation TERM unexpectedly succeeded"
fi
[ -f "$OUT/JBar.app/Contents/Resources/ROLLBACK-MARKER" ] || fail "TERM did not restore the previous bundle"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$OUT/JBar.app/Contents/Info.plist")" = "2" ] ||
  fail "TERM left the replacement active"
assert_no_transaction "$OUT"

# The bundle displaced by an upgrade is revalidated after the atomic replace.
# A same-inode mutation after the first check invalidates its signature; the
# builder must restore that exact bundle instead of deleting its backup.
if run_builder 4 JBAR_BUILD_TEST_MODE=1 JBAR_BUILD_TEST_FAIL_AT=after_upgrade_check_mutation \
   > "$TEST_ROOT/upgrade-race-mutation.log" 2>&1; then
  fail "upgrade accepted a destination mutated after its first validation"
fi
[ -f "$OUT/JBar.app/Contents/Resources/RACED-MUTATION" ] ||
  fail "upgrade race rollback did not restore the displaced destination"
[ -f "$OUT/JBar.app/Contents/Resources/ROLLBACK-MARKER" ] ||
  fail "upgrade race rollback lost the previous bundle"
assert_no_transaction "$OUT"
/bin/rm -f -- "$OUT/JBar.app/Contents/Resources/RACED-MUTATION"
resign_app "$OUT/JBar.app"

run_builder 5 > "$TEST_ROOT/replacement-after-rollbacks.log"
[ ! -e "$OUT/JBar.app/Contents/Resources/ROLLBACK-MARKER" ] || fail "successful build retained restored old contents"

/bin/mv "$OUT/JBar.app" "$OUT/real-JBar.app"
/bin/ln -s "real-JBar.app" "$OUT/JBar.app"
if run_builder 6 > "$TEST_ROOT/symlink.log" 2>&1; then
  fail "builder replaced a symbolic-link output"
fi
[ -L "$OUT/JBar.app" ] && [ -x "$OUT/real-JBar.app/Contents/MacOS/JBar" ] ||
  fail "symbolic link or its target was changed"
[ -z "$(/usr/bin/find "$OUT" -maxdepth 1 -name '.jbar-build.*' -print -quit)" ] ||
  fail "symlink refusal leaked a staging directory"

# A valid ad-hoc bundle with a spoofed JBar identifier but no signed build provenance is
# not replaceable by default. The exact migration acknowledgement is accepted once.
/bin/rm -f -- "$OUT/JBar.app"
/bin/mv "$OUT/real-JBar.app" "$OUT/JBar.app"
/usr/libexec/PlistBuddy -c 'Delete :JBarBuildProvenance' "$OUT/JBar.app/Contents/Info.plist"
printf 'legacy marker\n' > "$OUT/JBar.app/Contents/Resources/LEGACY-MARKER"
resign_app "$OUT/JBar.app"
if run_builder 6 > "$TEST_ROOT/legacy-refusal.log" 2>&1; then
  fail "builder replaced a signed legacy/spoofed bundle without acknowledgement"
fi
[ -f "$OUT/JBar.app/Contents/Resources/LEGACY-MARKER" ] || fail "legacy refusal changed the old bundle"
if run_builder 6 JBAR_BUILD_LEGACY_REPLACE_ACK=wrong > "$TEST_ROOT/legacy-wrong-ack.log" 2>&1; then
  fail "builder accepted an inexact legacy acknowledgement"
fi
run_builder 6 JBAR_BUILD_LEGACY_REPLACE_ACK=I_UNDERSTAND_THIS_REPLACES_A_SIGNED_JBAR_APP \
  > "$TEST_ROOT/legacy-migration.log"
[ ! -e "$OUT/JBar.app/Contents/Resources/LEGACY-MARKER" ] || fail "legacy migration did not activate the new app"
[ "$(/usr/libexec/PlistBuddy -c 'Print :JBarBuildProvenance' "$OUT/JBar.app/Contents/Info.plist")" = \
  'scripts/build-app.sh:v1' ] || fail "migrated app lacks signed build provenance"

# A signal after a first-install rename must remove the incomplete new install; the
# pre-activation state flag closes the former mv-to-state assignment window.
FIRST_OUT="$TEST_ROOT/first-install-signal"
/bin/mkdir -p "$FIRST_OUT"
if env JBAR_ARCHS=arm64 JBAR_VERSION=0.1.0 JBAR_BUILD_NUMBER=7 \
   JBAR_BUILD_TEST_MODE=1 JBAR_BUILD_TEST_FAIL_AT=term_after_activate \
   "$BUILDER" "$FIRST_OUT" > "$TEST_ROOT/first-install-term.log" 2>&1; then
  fail "first-install TERM unexpectedly succeeded"
fi
[ ! -e "$FIRST_OUT/JBar.app" ] || fail "first-install TERM left an activated app"
assert_no_transaction "$FIRST_OUT"

echo "PASS: transactional build preserves unrelated/symlink outputs and atomically replaces verified JBar bundles"

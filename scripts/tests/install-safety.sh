#!/bin/bash
# Isolated transaction/fault-injection tests for scripts/install.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
INSTALLER="$ROOT/scripts/install.sh"
SOURCE_APP="${JBAR_INSTALL_TEST_SOURCE_APP:-$ROOT/build/JBar.app}"
TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/jbar-install-safety.XXXXXXXX")"
TESTS_RUN=0
CHILD_PIDS=""

cleanup() {
  local pid
  for pid in $CHILD_PIDS; do
    /bin/kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done
  case "$TEST_ROOT" in
    "${TMPDIR:-/tmp}"/jbar-install-safety.*|/private"${TMPDIR:-/tmp}"/jbar-install-safety.*)
      /bin/chmod -RN "$TEST_ROOT" >/dev/null 2>&1 || true
      /bin/chmod -R u+rwX "$TEST_ROOT" >/dev/null 2>&1 || true
      /bin/rm -rf -- "$TEST_ROOT"
      ;;
    *)
      echo "error: refusing unsafe test cleanup: $TEST_ROOT" >&2
      ;;
  esac
}
trap cleanup EXIT INT TERM HUP

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_developer_id_requirement() {
  # This intentionally matches the literal source-level variable reference.
  # shellcheck disable=SC2016
  local canonical='requirement="identifier \"com.linji.jbar\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""'
  /usr/bin/grep -Fq "$canonical" "$INSTALLER" ||
    fail "installer trust requirement does not construct the canonical Developer ID Application chain"
  /usr/bin/grep -Fq 'identifier \"com.linji.jbar\" and anchor apple generic' "$INSTALLER" ||
    fail "installer trust requirement does not bind the bundle identifier to Apple's anchor"
  /usr/bin/grep -Fq 'certificate 1[field.1.2.840.113635.100.6.2.6] exists' "$INSTALLER" ||
    fail "installer trust requirement lacks the Developer ID intermediate OID"
  /usr/bin/grep -Fq 'certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$INSTALLER" ||
    fail "installer trust requirement lacks the Developer ID Application leaf OID"
  # shellcheck disable=SC2016
  /usr/bin/grep -Fq 'certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\"' "$INSTALLER" ||
    fail "installer trust requirement does not bind the expected Team ID"
}
assert_developer_id_requirement
if ! /usr/bin/grep -Fq 'UInt32(RENAME_SWAP)' "$INSTALLER" ||
   /usr/bin/grep -Fq 'FileManager.default.replaceItemAt' "$INSTALLER"; then
  fail "installer does not use an explicit RENAME_SWAP-only upgrade transaction"
fi

[ -x "$INSTALLER" ] || fail "installer is not executable: $INSTALLER"
[ -d "$SOURCE_APP" ] || fail "build JBar.app first (missing $SOURCE_APP)"
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP" >/dev/null 2>&1 ||
  fail "test source app does not have a valid code signature"

# Keep the caller's build immutable. Tests install a deterministic, provenance-bearing copy.
SOURCE_FIXTURE="$TEST_ROOT/source/JBar.app"
/bin/mkdir -p "$(dirname "$SOURCE_FIXTURE")"
/usr/bin/ditto "$SOURCE_APP" "$SOURCE_FIXTURE"
if /usr/libexec/PlistBuddy -c 'Print :JBarBuildProvenance' "$SOURCE_FIXTURE/Contents/Info.plist" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c 'Set :JBarBuildProvenance scripts/build-app.sh:v1' "$SOURCE_FIXTURE/Contents/Info.plist"
else
  /usr/libexec/PlistBuddy -c 'Add :JBarBuildProvenance string scripts/build-app.sh:v1' "$SOURCE_FIXTURE/Contents/Info.plist"
fi
/usr/bin/codesign --force --sign - "$SOURCE_FIXTURE" >/dev/null
SOURCE_APP="$SOURCE_FIXTURE"

make_old_install() {
  local destination="$1"
  local marker="$2"
  /bin/mkdir -p "$destination"
  /usr/bin/ditto "$SOURCE_APP" "$destination/JBar.app"
  printf '%s\n' "$marker" > "$destination/JBar.app/Contents/Resources/OLD_SENTINEL"
  /usr/bin/codesign --force --sign - "$destination/JBar.app" >/dev/null
}

assert_old_survived() {
  local destination="$1"
  local marker="$2"
  [ -f "$destination/JBar.app/Contents/Resources/OLD_SENTINEL" ] ||
    fail "old sentinel is missing after failure in $marker"
  [ "$(sed -n '1p' "$destination/JBar.app/Contents/Resources/OLD_SENTINEL")" = "$marker" ] ||
    fail "old sentinel changed after failure in $marker"
  if /usr/bin/find "$destination" -maxdepth 1 -name '.jbar-install.*' -print -quit | /usr/bin/grep -q .; then
    fail "transaction directory leaked after failure in $marker"
  fi
  if /usr/bin/find "$destination" -maxdepth 1 -name '.jbar-install-backup.*.app' -print -quit | /usr/bin/grep -q .; then
    fail "backup bundle leaked after failure in $marker"
  fi
}

run_fault_case() {
  local fault="$1"
  local case_root="$TEST_ROOT/fault-$fault"
  local destination="$case_root/应用 程序"
  local marker="old-$fault"
  local log="$case_root/install.log"

  /bin/mkdir -p "$destination"
  make_old_install "$destination" "$marker"
  if JBAR_INSTALL_TEST_MODE=1 \
     JBAR_INSTALL_TEST_ROOT="$TEST_ROOT" \
     JBAR_INSTALL_SOURCE_APP="$SOURCE_APP" \
     JBAR_INSTALL_DEST_DIR="$destination" \
     JBAR_INSTALL_SKIP_PROCESS_CONTROL=1 \
     JBAR_INSTALL_SKIP_LAUNCH=1 \
     JBAR_INSTALL_TEST_FAULT="$fault" \
     "$INSTALLER" >"$log" 2>&1; then
    fail "fault '$fault' unexpectedly succeeded"
  fi
  assert_old_survived "$destination" "$marker"
  TESTS_RUN=$((TESTS_RUN + 1))
}

for fault in \
  before-copy \
  after-copy \
  after-validation \
  after-stop \
  swap-failure \
  before-swap \
  after-swap \
  term-after-swap \
  before-activate-rename \
  after-activate-rename \
  after-activation-validation \
  launch \
  after-launch \
  term-after-activate
do
  run_fault_case "$fault"
done

# Cleanup operates from an inode-verified cwd and never recursively follows the
# absolute work-directory entry. A replaced or missing entry makes the overall
# install fail after activation, while both the committed app and all available
# recovery trees remain untouched.
for fault in workdir-replacement workdir-missing; do
  case_root="$TEST_ROOT/fault-$fault"
  destination="$case_root/应用 程序"
  marker="old-$fault"
  /bin/mkdir -p "$destination"
  make_old_install "$destination" "$marker"
  if JBAR_INSTALL_TEST_MODE=1 \
     JBAR_INSTALL_TEST_ROOT="$TEST_ROOT" \
     JBAR_INSTALL_SOURCE_APP="$SOURCE_APP" \
     JBAR_INSTALL_DEST_DIR="$destination" \
     JBAR_INSTALL_SKIP_PROCESS_CONTROL=1 \
     JBAR_INSTALL_SKIP_LAUNCH=1 \
     JBAR_INSTALL_TEST_FAULT="$fault" \
     "$INSTALLER" >"$case_root/install.log" 2>&1; then
    fail "fault '$fault' unexpectedly succeeded"
  fi
  [ ! -e "$destination/JBar.app/Contents/Resources/OLD_SENTINEL" ] ||
    fail "$fault rolled back the already committed application"
  original_workdir="$(/usr/bin/find "$destination" -maxdepth 1 -type d -name '.jbar-install.*.race-original' -print -quit)"
  [ -n "$original_workdir" ] || fail "$fault lost the original installer transaction"
  [ "$(sed -n '1p' "$original_workdir/JBar.app.new/Contents/Resources/OLD_SENTINEL")" = "$marker" ] ||
    fail "$fault changed the displaced app in the original transaction"
  if [ "$fault" = workdir-replacement ]; then
    replacement_workdir="$(/usr/bin/find "$destination" -maxdepth 1 -type d -name '.jbar-install.*' ! -name '*.race-original' -print -quit)"
    [ -n "$replacement_workdir" ] || fail "workdir replacement tree was removed"
    [ "$(sed -n '1p' "$replacement_workdir/DO-NOT-DELETE")" = 'unrelated replacement tree' ] ||
      fail "installer cleanup traversed or changed the replacement tree"
  else
    [ -z "$(/usr/bin/find "$destination" -maxdepth 1 -name '.jbar-install.*' ! -name '*.race-original' -print -quit)" ] ||
      fail "workdir-missing fault unexpectedly recreated the missing entry"
  fi
  /usr/bin/grep -Fq 'preserving recovery state' "$case_root/install.log" ||
    fail "$fault did not report guarded cleanup failure"
  TESTS_RUN=$((TESTS_RUN + 1))
done

# Untrappable interruption recovery is fail-closed: a real RENAME_SWAP workspace
# blocks a new transaction and both candidate recovery copies remain untouched.
STALE_ROOT="$TEST_ROOT/stale-recovery"
STALE_DEST="$STALE_ROOT/应用 程序"
/bin/mkdir -p "$STALE_DEST"
make_old_install "$STALE_DEST" stale-current
STALE_TRANSACTION="$STALE_DEST/.jbar-install.stale"
/bin/mkdir -m 700 "$STALE_TRANSACTION"
/usr/bin/ditto "$STALE_DEST/JBar.app" "$STALE_TRANSACTION/JBar.app.new"
if JBAR_INSTALL_TEST_MODE=1 \
   JBAR_INSTALL_TEST_ROOT="$TEST_ROOT" \
   JBAR_INSTALL_SOURCE_APP="$SOURCE_APP" \
   JBAR_INSTALL_DEST_DIR="$STALE_DEST" \
   JBAR_INSTALL_SKIP_PROCESS_CONTROL=1 \
   JBAR_INSTALL_SKIP_LAUNCH=1 \
   "$INSTALLER" >"$STALE_ROOT/install.log" 2>&1; then
  fail "installer ignored stale recovery state"
fi
[ -d "$STALE_DEST/JBar.app" ] && [ -d "$STALE_TRANSACTION/JBar.app.new" ] ||
  fail "stale transaction recovery state changed"
TESTS_RUN=$((TESTS_RUN + 1))

# An arbitrary same-named directory is never replaced, even though the staged source is valid.
UNTRUSTED_ROOT="$TEST_ROOT/untrusted-existing"
UNTRUSTED_DEST="$UNTRUSTED_ROOT/应用 程序"
/bin/mkdir -p "$UNTRUSTED_DEST/JBar.app"
printf 'do not delete\n' > "$UNTRUSTED_DEST/JBar.app/USER-DATA"
if JBAR_INSTALL_TEST_MODE=1 \
   JBAR_INSTALL_TEST_ROOT="$TEST_ROOT" \
   JBAR_INSTALL_SOURCE_APP="$SOURCE_APP" \
   JBAR_INSTALL_DEST_DIR="$UNTRUSTED_DEST" \
   JBAR_INSTALL_SKIP_PROCESS_CONTROL=1 \
   JBAR_INSTALL_SKIP_LAUNCH=1 \
   "$INSTALLER" >"$UNTRUSTED_ROOT/install.log" 2>&1; then
  fail "installer replaced an arbitrary same-named directory"
fi
[ -f "$UNTRUSTED_DEST/JBar.app/USER-DATA" ] || fail "untrusted destination was changed"
TESTS_RUN=$((TESTS_RUN + 1))

# Even a freshly re-signed bundle with matching plist/provenance is not a
# replaceable JBar app when Contents/PkgInfo is missing or not exactly APPL????.
for variant in missing wrong; do
  PKGINFO_ROOT="$TEST_ROOT/pkginfo-$variant"
  PKGINFO_DEST="$PKGINFO_ROOT/应用 程序"
  /bin/mkdir -p "$PKGINFO_DEST"
  make_old_install "$PKGINFO_DEST" "pkginfo-$variant"
  if [ "$variant" = missing ]; then
    /bin/rm -f -- "$PKGINFO_DEST/JBar.app/Contents/PkgInfo"
  else
    printf 'BNDL????' > "$PKGINFO_DEST/JBar.app/Contents/PkgInfo"
  fi
  /usr/bin/codesign --force --sign - "$PKGINFO_DEST/JBar.app" >/dev/null
  if JBAR_INSTALL_TEST_MODE=1 \
     JBAR_INSTALL_TEST_ROOT="$TEST_ROOT" \
     JBAR_INSTALL_SOURCE_APP="$SOURCE_APP" \
     JBAR_INSTALL_DEST_DIR="$PKGINFO_DEST" \
     JBAR_INSTALL_SKIP_PROCESS_CONTROL=1 \
     JBAR_INSTALL_SKIP_LAUNCH=1 \
     "$INSTALLER" >"$PKGINFO_ROOT/install.log" 2>&1; then
    fail "installer replaced a signed bundle with $variant Contents/PkgInfo"
  fi
  assert_old_survived "$PKGINFO_DEST" "pkginfo-$variant"
  if [ "$variant" = missing ]; then
    [ ! -e "$PKGINFO_DEST/JBar.app/Contents/PkgInfo" ] ||
      fail "missing-PkgInfo refusal changed the existing bundle"
  else
    [ "$(/bin/cat "$PKGINFO_DEST/JBar.app/Contents/PkgInfo")" = 'BNDL????' ] ||
      fail "wrong-PkgInfo refusal changed the existing bundle"
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
done

# A valid signed development app from before provenance requires the exact one-time migration ack.
LEGACY_ROOT="$TEST_ROOT/legacy-existing"
LEGACY_DEST="$LEGACY_ROOT/应用 程序"
/bin/mkdir -p "$LEGACY_DEST"
make_old_install "$LEGACY_DEST" legacy-existing
/usr/libexec/PlistBuddy -c 'Delete :JBarBuildProvenance' "$LEGACY_DEST/JBar.app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$LEGACY_DEST/JBar.app" >/dev/null
if JBAR_INSTALL_TEST_MODE=1 \
   JBAR_INSTALL_TEST_ROOT="$TEST_ROOT" \
   JBAR_INSTALL_SOURCE_APP="$SOURCE_APP" \
   JBAR_INSTALL_DEST_DIR="$LEGACY_DEST" \
   JBAR_INSTALL_SKIP_PROCESS_CONTROL=1 \
   JBAR_INSTALL_SKIP_LAUNCH=1 \
   "$INSTALLER" >"$LEGACY_ROOT/refusal.log" 2>&1; then
  fail "installer replaced a legacy signed app without acknowledgement"
fi
assert_old_survived "$LEGACY_DEST" legacy-existing
JBAR_INSTALL_TEST_MODE=1 \
JBAR_INSTALL_TEST_ROOT="$TEST_ROOT" \
JBAR_INSTALL_SOURCE_APP="$SOURCE_APP" \
JBAR_INSTALL_DEST_DIR="$LEGACY_DEST" \
JBAR_INSTALL_SKIP_PROCESS_CONTROL=1 \
JBAR_INSTALL_SKIP_LAUNCH=1 \
JBAR_INSTALL_LEGACY_REPLACE_ACK=I_UNDERSTAND_THIS_REPLACES_A_SIGNED_JBAR_APP \
"$INSTALLER" >"$LEGACY_ROOT/migration.log" 2>&1 || fail "explicit legacy migration failed"
[ ! -e "$LEGACY_DEST/JBar.app/Contents/Resources/OLD_SENTINEL" ] || fail "legacy migration retained old app"
TESTS_RUN=$((TESTS_RUN + 1))

# First-install failures and TERM after activation remove only the transaction's new app.
for fault in after-activate-rename after-activation-validation launch term-after-activate; do
  FIRST_ROOT="$TEST_ROOT/first-$fault"
  FIRST_DEST="$FIRST_ROOT/应用 程序"
  /bin/mkdir -p "$FIRST_DEST"
  if JBAR_INSTALL_TEST_MODE=1 \
     JBAR_INSTALL_TEST_ROOT="$TEST_ROOT" \
     JBAR_INSTALL_SOURCE_APP="$SOURCE_APP" \
     JBAR_INSTALL_DEST_DIR="$FIRST_DEST" \
     JBAR_INSTALL_SKIP_PROCESS_CONTROL=1 \
     JBAR_INSTALL_SKIP_LAUNCH=1 \
     JBAR_INSTALL_TEST_FAULT="$fault" \
     "$INSTALLER" >"$FIRST_ROOT/install.log" 2>&1; then
    fail "first-install fault '$fault' unexpectedly succeeded"
  fi
  [ ! -e "$FIRST_DEST/JBar.app" ] || fail "first-install fault '$fault' left an app"
  [ -z "$(/usr/bin/find "$FIRST_DEST" -maxdepth 1 -name '.jbar-install*' -print -quit)" ] ||
    fail "first-install fault '$fault' leaked transaction state"
  TESTS_RUN=$((TESTS_RUN + 1))
done

# A directory created after the first-install absence check must win cleanly:
# exclusive activation fails, and rollback never moves or deletes that raced
# unrelated destination.
FIRST_RACE_ROOT="$TEST_ROOT/first-after-check-race"
FIRST_RACE_DEST="$FIRST_RACE_ROOT/应用 程序"
/bin/mkdir -p "$FIRST_RACE_DEST"
if JBAR_INSTALL_TEST_MODE=1 \
   JBAR_INSTALL_TEST_ROOT="$TEST_ROOT" \
   JBAR_INSTALL_SOURCE_APP="$SOURCE_APP" \
   JBAR_INSTALL_DEST_DIR="$FIRST_RACE_DEST" \
   JBAR_INSTALL_SKIP_PROCESS_CONTROL=1 \
   JBAR_INSTALL_SKIP_LAUNCH=1 \
   JBAR_INSTALL_TEST_FAULT=after-check-race \
   "$INSTALLER" >"$FIRST_RACE_ROOT/install.log" 2>&1; then
  fail "first-install after-check race unexpectedly succeeded"
fi
[ "$(sed -n '1p' "$FIRST_RACE_DEST/JBar.app/DO-NOT-DELETE")" = 'unrelated raced destination' ] ||
  fail "installer moved or deleted the destination that won the first-install race"
[ -z "$(/usr/bin/find "$FIRST_RACE_DEST" -maxdepth 1 -name '.jbar-install*' -print -quit)" ] ||
  fail "first-install race leaked transaction state"
TESTS_RUN=$((TESTS_RUN + 1))

# An existing bundle changed after its first validation is checked again after
# displacement. The invalidated backup must be restored rather than deleted.
UPGRADE_RACE_ROOT="$TEST_ROOT/upgrade-after-check-mutation"
UPGRADE_RACE_DEST="$UPGRADE_RACE_ROOT/应用 程序"
/bin/mkdir -p "$UPGRADE_RACE_DEST"
make_old_install "$UPGRADE_RACE_DEST" upgrade-after-check-mutation
if JBAR_INSTALL_TEST_MODE=1 \
   JBAR_INSTALL_TEST_ROOT="$TEST_ROOT" \
   JBAR_INSTALL_SOURCE_APP="$SOURCE_APP" \
   JBAR_INSTALL_DEST_DIR="$UPGRADE_RACE_DEST" \
   JBAR_INSTALL_SKIP_PROCESS_CONTROL=1 \
   JBAR_INSTALL_SKIP_LAUNCH=1 \
   JBAR_INSTALL_TEST_FAULT=after-upgrade-check-mutation \
   "$INSTALLER" >"$UPGRADE_RACE_ROOT/install.log" 2>&1; then
  fail "upgrade accepted a destination mutated after validation"
fi
[ -f "$UPGRADE_RACE_DEST/JBar.app/Contents/Resources/RACED-MUTATION" ] ||
  fail "upgrade race rollback did not restore the displaced destination"
[ -f "$UPGRADE_RACE_DEST/JBar.app/Contents/Resources/OLD_SENTINEL" ] ||
  fail "upgrade race rollback lost the previous bundle"
[ -z "$(/usr/bin/find "$UPGRADE_RACE_DEST" -maxdepth 1 -name '.jbar-install*' -print -quit)" ] ||
  fail "upgrade race rollback leaked transaction state"
TESTS_RUN=$((TESTS_RUN + 1))

# Staging accepts a valid signed source copy with inherited ACLs/broad modes,
# then removes the ACL and normalizes the installed tree before activation.
PERMISSION_ROOT="$TEST_ROOT/permission-normalization"
PERMISSION_DEST="$PERMISSION_ROOT/应用 程序"
PERMISSION_SOURCE="$PERMISSION_ROOT/source/JBar.app"
/bin/mkdir -p "$PERMISSION_DEST" "$(dirname "$PERMISSION_SOURCE")"
/usr/bin/ditto "$SOURCE_APP" "$PERMISSION_SOURCE"
/bin/chmod 777 "$PERMISSION_SOURCE"
/bin/chmod 666 "$PERMISSION_SOURCE/Contents/Info.plist"
/bin/chmod +a 'everyone deny delete' "$PERMISSION_SOURCE"
/usr/bin/codesign --verify --deep --strict "$PERMISSION_SOURCE" >/dev/null 2>&1 ||
  fail "permission fixture metadata unexpectedly invalidated its code signature"
JBAR_INSTALL_TEST_MODE=1 \
JBAR_INSTALL_TEST_ROOT="$TEST_ROOT" \
JBAR_INSTALL_SOURCE_APP="$PERMISSION_SOURCE" \
JBAR_INSTALL_DEST_DIR="$PERMISSION_DEST" \
JBAR_INSTALL_SKIP_PROCESS_CONTROL=1 \
JBAR_INSTALL_SKIP_LAUNCH=1 \
"$INSTALLER" >"$PERMISSION_ROOT/install.log" 2>&1 ||
  fail "permission-normalization install failed"
[ "$(/usr/bin/stat -f '%Lp' "$PERMISSION_DEST/JBar.app")" = 755 ] ||
  fail "installer did not normalize the app directory to mode 0755"
[ "$(/usr/bin/stat -f '%Lp' "$PERMISSION_DEST/JBar.app/Contents/Info.plist")" = 644 ] ||
  fail "installer did not normalize a data file to mode 0644"
[ "$(/usr/bin/stat -f '%Lp' "$PERMISSION_DEST/JBar.app/Contents/MacOS/JBar")" = 755 ] ||
  fail "installer did not preserve normalized executable permission"
[ -z "$(/usr/bin/find "$PERMISSION_DEST/JBar.app" -acl -print -quit)" ] ||
  fail "installer left an ACL on the installed application"
[ -z "$(/usr/bin/find "$PERMISSION_DEST/JBar.app" -perm +022 -print -quit)" ] ||
  fail "installer left group/world-write permission on the installed application"
TESTS_RUN=$((TESTS_RUN + 1))

# A bundle that was modified after signing must fail validation before the old
# app is stopped or renamed.
INVALID_ROOT="$TEST_ROOT/invalid-signature"
INVALID_DEST="$INVALID_ROOT/应用 程序"
INVALID_SOURCE="$INVALID_ROOT/source/JBar.app"
/bin/mkdir -p "$INVALID_DEST" "$(dirname "$INVALID_SOURCE")"
/usr/bin/ditto "$SOURCE_APP" "$INVALID_SOURCE"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 999-test' "$INVALID_SOURCE/Contents/Info.plist"
make_old_install "$INVALID_DEST" invalid-signature
if JBAR_INSTALL_TEST_MODE=1 \
   JBAR_INSTALL_TEST_ROOT="$TEST_ROOT" \
   JBAR_INSTALL_SOURCE_APP="$INVALID_SOURCE" \
   JBAR_INSTALL_DEST_DIR="$INVALID_DEST" \
   JBAR_INSTALL_SKIP_PROCESS_CONTROL=1 \
   JBAR_INSTALL_SKIP_LAUNCH=1 \
   "$INSTALLER" >"$INVALID_ROOT/install.log" 2>&1; then
  fail "invalid signature unexpectedly installed"
fi
assert_old_survived "$INVALID_DEST" invalid-signature
TESTS_RUN=$((TESTS_RUN + 1))

# Destination symlinks are refused without following or replacing them.
SYMLINK_ROOT="$TEST_ROOT/symlink-destination"
SYMLINK_DEST="$SYMLINK_ROOT/应用 程序"
SYMLINK_TARGET="$SYMLINK_ROOT/real-old.app"
/bin/mkdir -p "$SYMLINK_DEST" "$SYMLINK_TARGET"
printf 'symlink-old\n' > "$SYMLINK_TARGET/OLD_SENTINEL"
/bin/ln -s "$SYMLINK_TARGET" "$SYMLINK_DEST/JBar.app"
if JBAR_INSTALL_TEST_MODE=1 \
   JBAR_INSTALL_TEST_ROOT="$TEST_ROOT" \
   JBAR_INSTALL_SOURCE_APP="$SOURCE_APP" \
   JBAR_INSTALL_DEST_DIR="$SYMLINK_DEST" \
   JBAR_INSTALL_SKIP_PROCESS_CONTROL=1 \
   JBAR_INSTALL_SKIP_LAUNCH=1 \
   "$INSTALLER" >"$SYMLINK_ROOT/install.log" 2>&1; then
  fail "symbolic-link destination unexpectedly installed"
fi
[ "$(sed -n '1p' "$SYMLINK_TARGET/OLD_SENTINEL")" = symlink-old ] ||
  fail "symbolic-link target was changed"
TESTS_RUN=$((TESTS_RUN + 1))

# Test knobs must never redirect a normal development installation.
OVERRIDE_ROOT="$TEST_ROOT/override-guard"
OVERRIDE_DEST="$OVERRIDE_ROOT/应用 程序"
/bin/mkdir -p "$OVERRIDE_DEST"
make_old_install "$OVERRIDE_DEST" override-guard
if JBAR_INSTALL_SOURCE_APP="$SOURCE_APP" \
   JBAR_INSTALL_DEST_DIR="$OVERRIDE_DEST" \
   "$INSTALLER" >"$OVERRIDE_ROOT/install.log" 2>&1; then
  fail "test override unexpectedly worked without test mode"
fi
assert_old_survived "$OVERRIDE_DEST" override-guard
TESTS_RUN=$((TESTS_RUN + 1))

# Even with test mode, mutation targets must remain below the owned mode-0700 declared root.
DECLARED_ROOT="$TEST_ROOT/declared-test-root"
OUTSIDE_DEST="$TEST_ROOT/outside-declared-root/应用 程序"
/bin/mkdir -m 700 "$DECLARED_ROOT"
/bin/mkdir -p "$OUTSIDE_DEST"
make_old_install "$OUTSIDE_DEST" outside-declared-root
if JBAR_INSTALL_TEST_MODE=1 \
   JBAR_INSTALL_TEST_ROOT="$DECLARED_ROOT" \
   JBAR_INSTALL_SOURCE_APP="$SOURCE_APP" \
   JBAR_INSTALL_DEST_DIR="$OUTSIDE_DEST" \
   JBAR_INSTALL_SKIP_PROCESS_CONTROL=1 \
   JBAR_INSTALL_SKIP_LAUNCH=1 \
   "$INSTALLER" >"$TEST_ROOT/outside-root.log" 2>&1; then
  fail "test mode escaped its declared root"
fi
assert_old_survived "$OUTSIDE_DEST" outside-declared-root
TESTS_RUN=$((TESTS_RUN + 1))

# Process shutdown must select the exact installed executable path. A different
# process also named JBar must remain alive.
PROCESS_ROOT="$TEST_ROOT/process-isolation"
PROCESS_DEST="$PROCESS_ROOT/target/应用 程序"
OTHER_APP="$PROCESS_ROOT/unrelated/JBar.app"
/bin/mkdir -p "$PROCESS_DEST" "$OTHER_APP/Contents/MacOS"
make_old_install "$PROCESS_DEST" process-isolation
/usr/bin/xcrun clang -x c -o "$PROCESS_DEST/JBar.app/Contents/MacOS/JBar" - <<'C_SOURCE'
#include <unistd.h>
int main(void) { for (;;) pause(); }
C_SOURCE
/usr/bin/codesign --force --sign - "$PROCESS_DEST/JBar.app" >/dev/null
/usr/bin/ditto "$PROCESS_DEST/JBar.app/Contents/MacOS/JBar" "$OTHER_APP/Contents/MacOS/JBar"
PROCESS_DEST_CANONICAL="$(cd "$PROCESS_DEST" && pwd -P)"
OTHER_APP_CANONICAL="$(cd "$OTHER_APP" && pwd -P)"
"$PROCESS_DEST_CANONICAL/JBar.app/Contents/MacOS/JBar" &
TARGET_PID=$!
CHILD_PIDS="$CHILD_PIDS $TARGET_PID"
"$OTHER_APP_CANONICAL/Contents/MacOS/JBar" &
OTHER_PID=$!
CHILD_PIDS="$CHILD_PIDS $OTHER_PID"
/bin/sleep 0.1
JBAR_INSTALL_TEST_MODE=1 \
JBAR_INSTALL_TEST_ROOT="$TEST_ROOT" \
JBAR_INSTALL_SOURCE_APP="$SOURCE_APP" \
JBAR_INSTALL_DEST_DIR="$PROCESS_DEST" \
JBAR_INSTALL_SKIP_LAUNCH=1 \
"$INSTALLER" >"$PROCESS_ROOT/install.log" 2>&1 || fail "exact-process install case failed"
if /bin/kill -0 "$TARGET_PID" >/dev/null 2>&1; then
  fail "installer left the exact old destination process running"
fi
if ! /bin/kill -0 "$OTHER_PID" >/dev/null 2>&1; then
  fail "installer stopped an unrelated process also named JBar"
fi
/bin/kill "$OTHER_PID" >/dev/null 2>&1 || true
wait "$OTHER_PID" >/dev/null 2>&1 || true
CHILD_PIDS=""
TESTS_RUN=$((TESTS_RUN + 1))

# The success path atomically replaces the old bundle and leaves no transaction
# or backup directories behind.
SUCCESS_ROOT="$TEST_ROOT/success"
SUCCESS_DEST="$SUCCESS_ROOT/应用 程序"
/bin/mkdir -p "$SUCCESS_DEST"
make_old_install "$SUCCESS_DEST" success-old
JBAR_INSTALL_TEST_MODE=1 \
JBAR_INSTALL_TEST_ROOT="$TEST_ROOT" \
JBAR_INSTALL_SOURCE_APP="$SOURCE_APP" \
JBAR_INSTALL_DEST_DIR="$SUCCESS_DEST" \
JBAR_INSTALL_SKIP_PROCESS_CONTROL=1 \
JBAR_INSTALL_SKIP_LAUNCH=1 \
"$INSTALLER" >"$SUCCESS_ROOT/install.log" 2>&1 || fail "success case failed"
[ ! -e "$SUCCESS_DEST/JBar.app/Contents/Resources/OLD_SENTINEL" ] || fail "success case retained the old sentinel"
/usr/bin/codesign --verify --deep --strict "$SUCCESS_DEST/JBar.app" >/dev/null 2>&1 ||
  fail "success case installed an invalid bundle"
if /usr/bin/find "$SUCCESS_DEST" -maxdepth 1 -name '.jbar-install.*' -print -quit | /usr/bin/grep -q .; then
  fail "success case leaked a transaction directory"
fi
TESTS_RUN=$((TESTS_RUN + 1))

if /usr/bin/grep -Eq 'pkill[[:space:]]+-f|xattr[[:space:]]+-dr' "$INSTALLER"; then
  fail "installer contains a forbidden broad process kill or recursive quarantine removal"
fi

echo "PASS: $TESTS_RUN isolated installer safety cases"

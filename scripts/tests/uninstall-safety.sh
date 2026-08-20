#!/bin/bash
# Isolated transaction, identity, process-selection, and purge tests for scripts/uninstall.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
UNINSTALLER="$ROOT/scripts/uninstall.sh"
TEST_PARENT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
TEST_ROOT="$(/usr/bin/mktemp -d "$TEST_PARENT/jbar-uninstall-tests.XXXXXXXX")"
HELPER="$TEST_ROOT/JBar"
TRUSTED_DEV_APP="$TEST_ROOT/trusted/JBar.app"
UNREGISTER_LOG="$TEST_ROOT/unregister-invocations.log"
TESTS_RUN=0
CHILD_PIDS=""

cleanup() {
  local pid
  for pid in $CHILD_PIDS; do /bin/kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; done
  if [ "$(dirname "$TEST_ROOT")" = "$TEST_PARENT" ] &&
     [[ "$(basename "$TEST_ROOT")" == jbar-uninstall-tests.* ]]; then
    /bin/rm -rf -- "$TEST_ROOT"
  else
    echo "error: refusing unsafe uninstall-test cleanup: $TEST_ROOT" >&2
  fi
}
trap cleanup EXIT INT TERM HUP

fail() { echo "FAIL: $*" >&2; exit 1; }

assert_developer_id_requirement() {
  # This intentionally matches the literal source-level variable reference.
  # shellcheck disable=SC2016
  local canonical='requirement="identifier \"com.linji.jbar\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""'
  /usr/bin/grep -Fq "$canonical" "$UNINSTALLER" ||
    fail "uninstall trust requirement does not construct the canonical Developer ID Application chain"
  /usr/bin/grep -Fq 'identifier \"com.linji.jbar\" and anchor apple generic' "$UNINSTALLER" ||
    fail "uninstall trust requirement does not bind the bundle identifier to Apple's anchor"
  /usr/bin/grep -Fq 'certificate 1[field.1.2.840.113635.100.6.2.6] exists' "$UNINSTALLER" ||
    fail "uninstall trust requirement lacks the Developer ID intermediate OID"
  /usr/bin/grep -Fq 'certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$UNINSTALLER" ||
    fail "uninstall trust requirement lacks the Developer ID Application leaf OID"
  # shellcheck disable=SC2016
  /usr/bin/grep -Fq 'certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\"' "$UNINSTALLER" ||
    fail "uninstall trust requirement does not bind the expected Team ID"
}
assert_developer_id_requirement

if /usr/bin/grep -Fq '/usr/bin/xcrun' "$UNINSTALLER"; then
  fail "uninstaller unexpectedly requires Xcode Command Line Tools"
fi
if ! /usr/bin/grep -Fq "ObjC.bindFunction('renameatx_np'" "$UNINSTALLER" ||
   ! /usr/bin/grep -Fq 'const RENAME_EXCL = 0x00000004' "$UNINSTALLER"; then
  fail "uninstaller does not bind the system renameatx_np RENAME_EXCL operation"
fi

/usr/bin/xcrun clang -x c -o "$HELPER" - <<'C_SOURCE'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--unregister-login-item") == 0) {
    const char *log = getenv("JBAR_TEST_UNREGISTER_LOG");
    const char *expected_executable = getenv("JBAR_TEST_EXPECTED_UNREGISTER_EXECUTABLE");
    const char *expected_sentinel = getenv("JBAR_TEST_EXPECTED_UNREGISTER_SENTINEL");
    const char *expected_peer_sentinel = getenv("JBAR_TEST_EXPECTED_UNREGISTER_PEER_SENTINEL");
    const char *peer_check_calls = getenv("JBAR_TEST_UNREGISTER_PEER_CHECK_CALLS");
    const char *registration_marker = getenv("JBAR_TEST_SIMULATED_REGISTRATION_MARKER");
    const char *exit_code = getenv("JBAR_TEST_UNREGISTER_EXIT_CODE");
    const char *fail_on_call = getenv("JBAR_TEST_UNREGISTER_FAIL_ON_CALL");
    long prior_calls = 0;
    if (log != NULL) {
      FILE *existing = fopen(log, "r");
      if (existing != NULL) {
        int ch;
        while ((ch = fgetc(existing)) != EOF) if (ch == '\n') prior_calls++;
        if (fclose(existing) != 0) return 7;
      }
    }
    int check_canonical_sentinels =
      peer_check_calls == NULL || prior_calls < atol(peer_check_calls);
    if (expected_executable != NULL && strcmp(argv[0], expected_executable) != 0) return 4;
    if (expected_sentinel != NULL && check_canonical_sentinels &&
        access(expected_sentinel, F_OK) != 0) return 5;
    if (expected_peer_sentinel != NULL && check_canonical_sentinels &&
        access(expected_peer_sentinel, F_OK) != 0) return 6;
    if (log != NULL) {
      FILE *file = fopen(log, "a");
      if (file == NULL) return 2;
      fprintf(file, "unregister\t%s\n", argv[0]);
      if (fclose(file) != 0) return 3;
    }
    if (registration_marker != NULL && registration_marker[0] != '\0') {
      if (access(registration_marker, F_OK) == 0) {
        if (unlink(registration_marker) != 0) return 8;
      } else {
        FILE *marker = fopen(registration_marker, "w");
        if (marker == NULL || fclose(marker) != 0) return 9;
      }
    }
    if (fail_on_call != NULL && prior_calls + 1 == atol(fail_on_call)) {
      return exit_code == NULL ? 10 : atoi(exit_code);
    }
    if (exit_code != NULL && fail_on_call == NULL) return atoi(exit_code);
    return 0;
  }
  for (;;) pause();
}
C_SOURCE

make_app() {
  local app="$1"
  local bundle_id="${2:-com.linji.jbar}"
  /bin/mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  /bin/cp "$HELPER" "$app/Contents/MacOS/JBar"
  /bin/chmod +x "$app/Contents/MacOS/JBar"
  /usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string JBar' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 0.0.0' "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :JBarBuildProvenance string scripts/build-app.sh:v1' "$app/Contents/Info.plist"
  printf 'APPL????' > "$app/Contents/PkgInfo"
  printf 'sentinel\n' > "$app/Contents/Resources/SENTINEL"
  /usr/bin/codesign --force --sign - "$app" >/dev/null 2>&1
}

run_uninstall() {
  local app="$1"
  local home="$2"
  local trash="$3"
  shift 3
  JBAR_UNINSTALL_TEST_MODE=1 \
  JBAR_UNINSTALL_TEST_ROOT="$TEST_ROOT" \
  JBAR_UNINSTALL_TARGET_APP="$app" \
  JBAR_UNINSTALL_HOME="$home" \
  JBAR_UNINSTALL_TRASH_DIR="$trash" \
  JBAR_UNINSTALL_TRUSTED_DEV_APP="$TRUSTED_DEV_APP" \
  JBAR_UNINSTALL_SKIP_PROCESS_CONTROL=1 \
  JBAR_TEST_UNREGISTER_LOG="$UNREGISTER_LOG" \
  JBAR_TEST_EXPECTED_UNREGISTER_EXECUTABLE="$app/Contents/MacOS/JBar" \
  JBAR_TEST_EXPECTED_UNREGISTER_SENTINEL="$app/Contents/Resources/SENTINEL" \
    "$UNINSTALLER" "$@"
}

make_case() {
  local name="$1"
  local base="$TEST_ROOT/$name"
  /bin/mkdir -p "$base/用户 主目录" "$base/废纸篓" "$base/应用 程序"
  /bin/chmod 700 "$base/废纸篓"
  printf '%s\n' "$base"
}

/bin/mkdir -p "$(dirname "$TRUSTED_DEV_APP")"
make_app "$TRUSTED_DEV_APP"

# Normal removal is recoverable and keeps data by default.
base="$(make_case success)"
app="$base/应用 程序/JBar.app"
make_app "$app"
/bin/mkdir -p "$base/用户 主目录/.config/jbar"
printf 'keep\n' > "$base/用户 主目录/.config/jbar/config.json"
simulated_registration="$base/simulated-reregistered-login-item"
JBAR_TEST_SIMULATED_REGISTRATION_MARKER="$simulated_registration"
export JBAR_TEST_SIMULATED_REGISTRATION_MARKER
run_uninstall "$app" "$base/用户 主目录" "$base/废纸篓" > "$base/log"
unset JBAR_TEST_SIMULATED_REGISTRATION_MARKER
[ ! -e "$app" ] || fail "success case left app installed"
[ -f "$base/用户 主目录/.config/jbar/config.json" ] || fail "default uninstall removed user data"
trashed_app="$(/usr/bin/find "$base/废纸篓" -maxdepth 1 -name 'JBar-*.app' -print -quit)"
[ -f "$trashed_app/Contents/Resources/SENTINEL" ] || fail "success case did not preserve recoverable app"
[ "$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')" = 2 ] ||
  fail "trusted development app did not run both canonical unregister checks"
expected_unregister_log="unregister"$'\t'"$app/Contents/MacOS/JBar"
if [ "$(/usr/bin/tail -n 2 "$UNREGISTER_LOG" | /usr/bin/uniq | /usr/bin/wc -l | /usr/bin/tr -d ' ')" != 1 ] ||
   [ "$(/usr/bin/tail -n 1 "$UNREGISTER_LOG")" != "$expected_unregister_log" ]; then
  fail "trusted development app did not run both unregister checks from the canonical bundle path"
fi
[ ! -e "$simulated_registration" ] ||
  fail "final canonical cleanup did not clear the simulated post-confirmation re-registration"
TESTS_RUN=$((TESTS_RUN + 1))

# When both supported Applications locations contain trusted copies, every
# bundle stays canonical until both ServiceManagement checks have completed.
# The helper checks the peer sentinel on each invocation, so moving the first
# app before invoking the second would make this case fail.
base="$(make_case dual-install)"
app="$base/系统 应用程序/JBar.app"
second_app="$base/用户 应用程序/JBar.app"
/bin/mkdir -p "$(dirname "$app")" "$(dirname "$second_app")"
make_app "$app"
make_app "$second_app"
dual_log="$base/unregister-invocations.log"
JBAR_UNINSTALL_TEST_MODE=1 \
JBAR_UNINSTALL_TEST_ROOT="$TEST_ROOT" \
JBAR_UNINSTALL_TARGET_APP="$app" \
JBAR_UNINSTALL_SECOND_TARGET_APP="$second_app" \
JBAR_UNINSTALL_HOME="$base/用户 主目录" \
JBAR_UNINSTALL_TRASH_DIR="$base/废纸篓" \
JBAR_UNINSTALL_TRUSTED_DEV_APP="$TRUSTED_DEV_APP" \
JBAR_UNINSTALL_SKIP_PROCESS_CONTROL=1 \
JBAR_TEST_UNREGISTER_LOG="$dual_log" \
JBAR_TEST_EXPECTED_UNREGISTER_SENTINEL="$app/Contents/Resources/SENTINEL" \
JBAR_TEST_EXPECTED_UNREGISTER_PEER_SENTINEL="$second_app/Contents/Resources/SENTINEL" \
JBAR_TEST_UNREGISTER_PEER_CHECK_CALLS=2 \
  "$UNINSTALLER" > "$base/log"
[ ! -e "$app" ] && [ ! -e "$second_app" ] || fail "dual install left a canonical app behind"
[ "$(/usr/bin/wc -l < "$dual_log" | /usr/bin/tr -d ' ')" = 4 ] ||
  fail "dual install did not invoke global and final canonical checks for both apps"
expected_first="unregister"$'\t'"$app/Contents/MacOS/JBar"
expected_second="unregister"$'\t'"$second_app/Contents/MacOS/JBar"
[ "$(/usr/bin/sed -n '1p' "$dual_log")" = "$expected_first" ] ||
  fail "dual install first cleanup did not run from its canonical bundle"
[ "$(/usr/bin/sed -n '2p' "$dual_log")" = "$expected_second" ] ||
  fail "dual install second cleanup did not run from its canonical bundle"
[ "$(/usr/bin/sed -n '3p' "$dual_log")" = "$expected_first" ] ||
  fail "dual install first final cleanup did not run from its canonical bundle"
[ "$(/usr/bin/sed -n '4p' "$dual_log")" = "$expected_second" ] ||
  fail "dual install second final cleanup did not run from its canonical bundle"
[ "$(/usr/bin/find "$base/废纸篓" -mindepth 1 -maxdepth 1 -name 'JBar-*.app' | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 2 ] ||
  fail "dual install did not preserve two recoverable Trash apps"
TESTS_RUN=$((TESTS_RUN + 1))

# Without a trusted canonical app, the default path cannot verify an orphaned
# ServiceManagement registration and therefore fails before any purge/mutation.
# Explicit skip preserves a deliberate filesystem-only idempotent path.
base="$(make_case no-installed-app)"
/bin/mkdir -p "$base/用户 主目录/.config/jbar"
printf 'orphaned state\n' > "$base/用户 主目录/.config/jbar/SENTINEL"
if run_uninstall "$base/应用 程序/JBar.app" "$base/用户 主目录" "$base/废纸篓" --purge --yes > "$base/log" 2>&1; then
  fail "no-app cleanup falsely reported verified success"
fi
/usr/bin/grep -Fq 'no trusted canonical JBar.app is available to verify login-item cleanup' "$base/log" ||
  fail "no-app cleanup omitted the fail-closed Login Items diagnostic"
[ -f "$base/用户 主目录/.config/jbar/SENTINEL" ] ||
  fail "no-app refusal moved user state"
[ -z "$(/usr/bin/find "$base/废纸篓" -mindepth 1 -print -quit)" ] ||
  fail "no-app refusal unexpectedly wrote Trash"
run_uninstall "$base/应用 程序/JBar.app" "$base/用户 主目录" "$base/废纸篓" \
  --skip-login-item-cleanup > "$base/skip.log" 2>&1
/usr/bin/grep -Fq 'was not installed in the supported locations' "$base/skip.log" ||
  fail "explicit no-app skip did not report the filesystem-only state"
TESTS_RUN=$((TESTS_RUN + 1))

# A bundle whose sealed resources changed after signing is not trusted enough to execute its CLI
# unregistration hook or remove it as JBar.
base="$(make_case tampered-signature)"
app="$base/应用 程序/JBar.app"
make_app "$app"
printf 'tampered\n' >> "$app/Contents/Resources/SENTINEL"
if run_uninstall "$app" "$base/用户 主目录" "$base/废纸篓" > "$base/log" 2>&1; then
  fail "tampered signature unexpectedly removed"
fi
[ -f "$app/Contents/Resources/SENTINEL" ] || fail "tampered app was changed"
TESTS_RUN=$((TESTS_RUN + 1))

# ACLs and group/world-write modes are refused before the app can be executed or
# moved. Normal installs strip these metadata mutation surfaces at activation.
base="$(make_case unsafe-permissions)"
app="$base/应用 程序/JBar.app"
make_app "$app"
/bin/chmod +a 'everyone deny delete' "$app"
hooks_before="$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')"
if run_uninstall "$app" "$base/用户 主目录" "$base/废纸篓" > "$base/acl.log" 2>&1; then
  fail "app carrying an ACL was unexpectedly executed or removed"
fi
[ -f "$app/Contents/Resources/SENTINEL" ] || fail "ACL refusal changed the installed app"
[ "$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')" = "$hooks_before" ] ||
  fail "ACL-bearing app's unregister hook executed"
/bin/chmod -RN "$app"
/bin/chmod 777 "$app"
if run_uninstall "$app" "$base/用户 主目录" "$base/废纸篓" > "$base/mode.log" 2>&1; then
  fail "group/world-writable app was unexpectedly executed or removed"
fi
[ -f "$app/Contents/Resources/SENTINEL" ] || fail "unsafe-mode refusal changed the installed app"
[ "$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')" = "$hooks_before" ] ||
  fail "unsafe-mode app's unregister hook executed"
TESTS_RUN=$((TESTS_RUN + 1))

# An untrappable interruption can leave the app at its same-volume hidden staging
# name. A later invocation surfaces and preserves it instead of claiming success.
base="$(make_case stale-stage)"
stale="$base/应用 程序/.jbar-uninstall-stale.app"
make_app "$stale"
app="$base/应用 程序/JBar.app"
if run_uninstall "$app" "$base/用户 主目录" "$base/废纸篓" > "$base/log" 2>&1; then
  fail "uninstaller ignored stale staging recovery state"
fi
[ -f "$stale/Contents/Resources/SENTINEL" ] || fail "stale staging recovery copy changed"
TESTS_RUN=$((TESTS_RUN + 1))

# Power loss can also strand any purge target under its own parent. These
# parents are scanned on every invocation (even without --purge), the staged
# inode is preserved, and the diagnostic names its expected recovery path.
for state in ".config/jbar" "Library/Caches/com.linji.jbar" "Library/Application Support/JBar"; do
  case "$state" in
    .config/jbar) state_name=config ;;
    Library/Caches/com.linji.jbar) state_name=cache ;;
    *) state_name=history ;;
  esac
  base="$(make_case "stale-state-$state_name")"
  home="$base/用户 主目录"
  original_state="$home/$state"
  state_parent="$(dirname "$original_state")"
  stale="$state_parent/.jbar-uninstall-stale.app"
  /bin/mkdir -p "$stale"
  printf 'stale state recovery\n' > "$stale/SENTINEL"
  if run_uninstall "$base/应用 程序/JBar.app" "$home" "$base/废纸篓" > "$base/refusal.log" 2>&1; then
    fail "uninstaller ignored stale $state_name staging on a non-purge run"
  fi
  [ "$(sed -n '1p' "$stale/SENTINEL")" = 'stale state recovery' ] ||
    fail "stale $state_name staging was changed"
  /usr/bin/grep -Fq 'requires manual recovery' "$base/refusal.log" ||
    fail "stale $state_name staging did not produce a recovery diagnostic"
  /usr/bin/grep -Fq "expected original: $original_state" "$base/refusal.log" ||
    fail "stale $state_name diagnostic omitted its expected original path"

  # Model the documented manual recovery. Once the guarded stage is moved back,
  # a normal non-purge run succeeds and leaves that recovered state untouched.
  /bin/mv "$stale" "$original_state"
  run_uninstall "$base/应用 程序/JBar.app" "$home" "$base/废纸篓" \
    --skip-login-item-cleanup > "$base/recovered.log"
  [ "$(sed -n '1p' "$original_state/SENTINEL")" = 'stale state recovery' ] ||
    fail "recovered $state_name state was not retained by a non-purge run"
  TESTS_RUN=$((TESTS_RUN + 1))
done

# stage_item canonicalizes a symlinked state parent. Preflight must scan that
# same physical directory without making an ordinary non-purge run reject the
# symlink itself.
base="$(make_case stale-state-symlink-parent)"
home="$base/用户 主目录"
/bin/mkdir -p "$base/physical-config"
/bin/ln -s "$base/physical-config" "$home/.config"
run_uninstall "$base/应用 程序/JBar.app" "$home" "$base/废纸篓" \
  --skip-login-item-cleanup > "$base/no-stale.log"
stale="$base/physical-config/.jbar-uninstall-stale.app"
/bin/mkdir "$stale"
printf 'symlink-parent stale state\n' > "$stale/SENTINEL"
if run_uninstall "$base/应用 程序/JBar.app" "$home" "$base/废纸篓" > "$base/refusal.log" 2>&1; then
  fail "symlinked state parent hid stale staging"
fi
[ "$(sed -n '1p' "$stale/SENTINEL")" = 'symlink-parent stale state' ] ||
  fail "symlink-parent stale staging was changed"
/usr/bin/grep -Fq "expected original: $home/.config/jbar" "$base/refusal.log" ||
  fail "symlink-parent stale diagnostic omitted the logical recovery path"
/bin/mv "$stale" "$base/physical-config/jbar"
run_uninstall "$base/应用 程序/JBar.app" "$home" "$base/废纸篓" \
  --skip-login-item-cleanup > "$base/recovered.log"
[ -f "$home/.config/jbar/SENTINEL" ] || fail "symlink-parent manual recovery was not retained"
TESTS_RUN=$((TESTS_RUN + 1))

# A valid ad-hoc bundle with the right plist/provenance but a different CDHash is not executed.
# The explicit skip flag may move it recoverably only after the user accepts external cleanup.
base="$(make_case forged-adhoc)"
app="$base/应用 程序/JBar.app"
make_app "$app"
printf 'different signed payload\n' > "$app/Contents/Resources/SENTINEL"
/usr/bin/codesign --force --sign - "$app" >/dev/null 2>&1
hooks_before="$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')"
if run_uninstall "$app" "$base/用户 主目录" "$base/废纸篓" > "$base/refusal.log" 2>&1; then
  fail "uninstaller executed/removed an unmatched ad-hoc bundle"
fi
[ -f "$app/Contents/Resources/SENTINEL" ] || fail "unmatched ad-hoc bundle changed on refusal"
[ "$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')" = "$hooks_before" ] ||
  fail "unmatched ad-hoc bundle's unregister hook executed"
run_uninstall "$app" "$base/用户 主目录" "$base/废纸篓" --skip-login-item-cleanup > "$base/skip.log"
[ ! -e "$app" ] || fail "explicit skip did not move unmatched app"
[ "$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')" = "$hooks_before" ] ||
  fail "explicit skip unexpectedly executed the ad-hoc bundle"
TESTS_RUN=$((TESTS_RUN + 1))

# Cross-volume behaviour is fail-closed before the app is renamed. The test hook forces
# the same branch without needing a privileged external volume in CI.
base="$(make_case cross-device)"
app="$base/应用 程序/JBar.app"
make_app "$app"
if JBAR_UNINSTALL_TEST_MODE=1 \
   JBAR_UNINSTALL_TEST_ROOT="$TEST_ROOT" \
   JBAR_UNINSTALL_TARGET_APP="$app" \
   JBAR_UNINSTALL_HOME="$base/用户 主目录" \
   JBAR_UNINSTALL_TRASH_DIR="$base/废纸篓" \
   JBAR_UNINSTALL_TRUSTED_DEV_APP="$TRUSTED_DEV_APP" \
   JBAR_UNINSTALL_SKIP_PROCESS_CONTROL=1 \
   JBAR_UNINSTALL_TEST_FORCE_CROSS_DEVICE=1 \
   "$UNINSTALLER" > "$base/log" 2>&1; then
  fail "forced cross-device Trash move unexpectedly succeeded"
fi
[ -f "$app/Contents/Resources/SENTINEL" ] || fail "cross-device refusal changed app"
[ -z "$(/usr/bin/find "$base/废纸篓" -mindepth 1 -print -quit)" ] || fail "cross-device refusal wrote Trash"
TESTS_RUN=$((TESTS_RUN + 1))

# Once cleanup is attempted, a failure before the child starts is deliberately
# treated as an unknown login-item outcome. No filesystem path may have moved.
for fault in before-unregister term-before-unregister; do
  base="$(make_case "fault-$fault")"
  app="$base/应用 程序/JBar.app"
  home="$base/用户 主目录"
  make_app "$app"
  /bin/mkdir -p "$home/.config/jbar"
  printf 'pre-unregister metadata\n' > "$home/.config/jbar/SENTINEL"
  hooks_before="$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')"
  if JBAR_UNINSTALL_TEST_MODE=1 \
     JBAR_UNINSTALL_TEST_ROOT="$TEST_ROOT" \
     JBAR_UNINSTALL_TARGET_APP="$app" \
     JBAR_UNINSTALL_HOME="$home" \
     JBAR_UNINSTALL_TRASH_DIR="$base/废纸篓" \
     JBAR_UNINSTALL_TRUSTED_DEV_APP="$TRUSTED_DEV_APP" \
     JBAR_UNINSTALL_SKIP_PROCESS_CONTROL=1 \
     JBAR_TEST_UNREGISTER_LOG="$UNREGISTER_LOG" \
     JBAR_UNINSTALL_TEST_FAULT="$fault" \
       "$UNINSTALLER" > "$base/log" 2>&1; then
    fail "$fault unexpectedly succeeded"
  fi
  [ -f "$app/Contents/Resources/SENTINEL" ] || fail "$fault changed the canonical app"
  [ -f "$home/.config/jbar/SENTINEL" ] || fail "$fault changed retained state"
  [ -z "$(/usr/bin/find "$base/废纸篓" -mindepth 1 -print -quit)" ] ||
    fail "$fault wrote Trash before the cleanup child"
  [ "$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')" = "$hooks_before" ] ||
    fail "$fault unexpectedly invoked the unregister child"
  /usr/bin/grep -Fq 'cleanup was attempted but not confirmed' "$base/log" ||
    fail "$fault did not report the conservative unknown login-item outcome"
  TESTS_RUN=$((TESTS_RUN + 1))
done

# A nonzero cleanup child result is fail-closed before any filesystem mutation.
# The hook records that it ran from the canonical bundle, but no success is claimed.
base="$(make_case unregister-failure)"
app="$base/应用 程序/JBar.app"
home="$base/用户 主目录"
make_app "$app"
/bin/mkdir -p "$home/.config/jbar"
printf 'cleanup failure metadata\n' > "$home/.config/jbar/SENTINEL"
hooks_before="$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')"
if JBAR_TEST_UNREGISTER_EXIT_CODE=9 \
   JBAR_UNINSTALL_TEST_MODE=1 \
   JBAR_UNINSTALL_TEST_ROOT="$TEST_ROOT" \
   JBAR_UNINSTALL_TARGET_APP="$app" \
   JBAR_UNINSTALL_HOME="$home" \
   JBAR_UNINSTALL_TRASH_DIR="$base/废纸篓" \
   JBAR_UNINSTALL_TRUSTED_DEV_APP="$TRUSTED_DEV_APP" \
   JBAR_UNINSTALL_SKIP_PROCESS_CONTROL=1 \
   JBAR_TEST_UNREGISTER_LOG="$UNREGISTER_LOG" \
   JBAR_TEST_EXPECTED_UNREGISTER_EXECUTABLE="$app/Contents/MacOS/JBar" \
   JBAR_TEST_EXPECTED_UNREGISTER_SENTINEL="$app/Contents/Resources/SENTINEL" \
     "$UNINSTALLER" > "$base/log" 2>&1; then
  fail "nonzero unregister child unexpectedly succeeded"
fi
[ -f "$app/Contents/Resources/SENTINEL" ] || fail "unregister failure changed the canonical app"
[ -f "$home/.config/jbar/SENTINEL" ] || fail "unregister failure changed retained state"
[ -z "$(/usr/bin/find "$base/废纸篓" -mindepth 1 -print -quit)" ] ||
  fail "unregister failure wrote Trash"
[ "$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')" = "$((hooks_before + 1))" ] ||
  fail "unregister failure did not invoke exactly one canonical child"
/usr/bin/grep -Fq 'cleanup was attempted but not confirmed' "$base/log" ||
  fail "unregister failure did not report an unconfirmed login-item outcome"
TESTS_RUN=$((TESTS_RUN + 1))

# The all-candidate pass can succeed and a simulated re-registration can make
# the final canonical verification fail. Once CONFIRMED is reset, that failure
# must be reported as unknown and must occur before any filesystem mutation.
base="$(make_case final-unregister-failure)"
app="$base/应用 程序/JBar.app"
home="$base/用户 主目录"
case_log="$base/unregister-invocations.log"
make_app "$app"
/bin/mkdir -p "$home/.config/jbar"
printf 'final cleanup failure metadata\n' > "$home/.config/jbar/SENTINEL"
if JBAR_UNINSTALL_TEST_MODE=1 \
   JBAR_UNINSTALL_TEST_ROOT="$TEST_ROOT" \
   JBAR_UNINSTALL_TARGET_APP="$app" \
   JBAR_UNINSTALL_HOME="$home" \
   JBAR_UNINSTALL_TRASH_DIR="$base/废纸篓" \
   JBAR_UNINSTALL_TRUSTED_DEV_APP="$TRUSTED_DEV_APP" \
   JBAR_UNINSTALL_SKIP_PROCESS_CONTROL=1 \
   JBAR_TEST_UNREGISTER_LOG="$case_log" \
   JBAR_TEST_EXPECTED_UNREGISTER_EXECUTABLE="$app/Contents/MacOS/JBar" \
   JBAR_TEST_EXPECTED_UNREGISTER_SENTINEL="$app/Contents/Resources/SENTINEL" \
   JBAR_TEST_UNREGISTER_FAIL_ON_CALL=2 \
   JBAR_TEST_UNREGISTER_EXIT_CODE=9 \
     "$UNINSTALLER" > "$base/log" 2>&1; then
  fail "final unregister failure unexpectedly succeeded"
fi
[ -f "$app/Contents/Resources/SENTINEL" ] ||
  fail "final unregister failure changed the canonical app"
[ -f "$home/.config/jbar/SENTINEL" ] ||
  fail "final unregister failure changed retained state"
[ -z "$(/usr/bin/find "$base/废纸篓" -mindepth 1 -print -quit)" ] ||
  fail "final unregister failure wrote Trash"
[ "$(/usr/bin/wc -l < "$case_log" | /usr/bin/tr -d ' ')" = 2 ] ||
  fail "final unregister failure did not execute two canonical checks"
expected_unregister_log="unregister"$'\t'"$app/Contents/MacOS/JBar"
if [ "$(/usr/bin/uniq "$case_log" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" != 1 ] ||
   [ "$(/usr/bin/tail -n 1 "$case_log")" != "$expected_unregister_log" ]; then
  fail "final unregister failure did not execute both checks from the canonical bundle"
fi
/usr/bin/grep -Fq 'cleanup was attempted but not confirmed' "$base/log" ||
  fail "final unregister failure did not reset the confirmed state"
if /usr/bin/grep -Fq 'Launch at Login was confirmed off' "$base/log"; then
  fail "final unregister failure falsely retained the earlier confirmed state"
fi
TESTS_RUN=$((TESTS_RUN + 1))

# Login-item cleanup now runs from the canonical bundle before any rename. Later
# transaction failures and real TERM delivery restore the original app and leave
# no debris, while accurately reporting that Launch at Login remains off.
for fault in after-stage after-trash term-after-stage term-after-trash; do
  base="$(make_case "fault-$fault")"
  app="$base/应用 程序/JBar.app"
  make_app "$app"
  hooks_before="$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')"
  if JBAR_UNINSTALL_TEST_MODE=1 \
     JBAR_UNINSTALL_TEST_ROOT="$TEST_ROOT" \
     JBAR_UNINSTALL_TARGET_APP="$app" \
     JBAR_UNINSTALL_HOME="$base/用户 主目录" \
     JBAR_UNINSTALL_TRASH_DIR="$base/废纸篓" \
     JBAR_UNINSTALL_TRUSTED_DEV_APP="$TRUSTED_DEV_APP" \
     JBAR_UNINSTALL_SKIP_PROCESS_CONTROL=1 \
     JBAR_TEST_UNREGISTER_LOG="$UNREGISTER_LOG" \
     JBAR_UNINSTALL_TEST_FAULT="$fault" \
       "$UNINSTALLER" > "$base/log" 2>&1; then
    fail "$fault unexpectedly succeeded"
  fi
  [ -f "$app/Contents/Resources/SENTINEL" ] || fail "$fault did not restore original app"
  [ -z "$(/usr/bin/find "$base/废纸篓" -mindepth 1 -print -quit)" ] || fail "$fault leaked Trash item"
  [ -z "$(/usr/bin/find "$base/应用 程序" -maxdepth 1 -name '.jbar-uninstall-*' -print -quit)" ] ||
    fail "$fault leaked staging item"
  [ "$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')" = "$((hooks_before + 2))" ] ||
    fail "$fault did not run both canonical unregister checks before filesystem mutation"
  /usr/bin/grep -Fq 'Launch at Login was confirmed off' "$base/log" ||
    fail "$fault did not explain the non-compensated login-item state"
  TESTS_RUN=$((TESTS_RUN + 1))
done

# If a verified staged/Trash inode is moved away from every recorded rollback
# source, the transaction must report incomplete recovery. It may never infer
# success merely because a source pathname disappeared.
for fault in after-stage-disappearance after-trash-disappearance; do
  base="$(make_case "fault-$fault")"
  app="$base/应用 程序/JBar.app"
  make_app "$app"
  hooks_before="$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')"
  if JBAR_UNINSTALL_TEST_MODE=1 \
     JBAR_UNINSTALL_TEST_ROOT="$TEST_ROOT" \
     JBAR_UNINSTALL_TARGET_APP="$app" \
     JBAR_UNINSTALL_HOME="$base/用户 主目录" \
     JBAR_UNINSTALL_TRASH_DIR="$base/废纸篓" \
     JBAR_UNINSTALL_TRUSTED_DEV_APP="$TRUSTED_DEV_APP" \
     JBAR_UNINSTALL_SKIP_PROCESS_CONTROL=1 \
     JBAR_TEST_UNREGISTER_LOG="$UNREGISTER_LOG" \
     JBAR_UNINSTALL_TEST_FAULT="$fault" \
       "$UNINSTALLER" > "$base/log" 2>&1; then
    fail "$fault unexpectedly succeeded"
  fi
  [ ! -e "$app" ] || fail "$fault unexpectedly recreated the canonical app"
  preserved="$(/usr/bin/find "$base" -name '*.race-moved.app' -print -quit)"
  [ -f "$preserved/Contents/Resources/SENTINEL" ] ||
    fail "$fault did not preserve the externally moved verified inode"
  [ "$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')" = "$((hooks_before + 2))" ] ||
    fail "$fault did not run both canonical unregister checks"
  /usr/bin/grep -Eq 'rollback source is missing|current rollback sources are missing' "$base/log" ||
    fail "$fault did not identify the missing recorded rollback source"
  /usr/bin/grep -Fq 'rollback was incomplete' "$base/log" ||
    fail "$fault falsely reported complete rollback"
  /usr/bin/grep -Fq 'requires manual recovery' "$base/log" ||
    fail "$fault omitted the manual recovery diagnostic"
  TESTS_RUN=$((TESTS_RUN + 1))
done

# If the group-writable parent lets another writer replace the hidden staged
# path after trust validation, rollback must not publish that unknown inode as
# JBar.app. The original verified inode and the substitute both remain visible
# for manual recovery inside this isolated fixture.
base="$(make_case after-stage-substitution)"
app="$base/应用 程序/JBar.app"
make_app "$app"
hooks_before="$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')"
if JBAR_UNINSTALL_TEST_MODE=1 \
   JBAR_UNINSTALL_TEST_ROOT="$TEST_ROOT" \
   JBAR_UNINSTALL_TARGET_APP="$app" \
   JBAR_UNINSTALL_HOME="$base/用户 主目录" \
   JBAR_UNINSTALL_TRASH_DIR="$base/废纸篓" \
   JBAR_UNINSTALL_TRUSTED_DEV_APP="$TRUSTED_DEV_APP" \
   JBAR_UNINSTALL_SKIP_PROCESS_CONTROL=1 \
   JBAR_TEST_UNREGISTER_LOG="$UNREGISTER_LOG" \
   JBAR_UNINSTALL_TEST_FAULT=after-stage-substitution \
     "$UNINSTALLER" > "$base/log" 2>&1; then
  fail "after-stage substitution unexpectedly succeeded"
fi
[ ! -e "$app" ] || fail "unknown staged substitute was restored as JBar.app"
preserved_original="$(/usr/bin/find "$base/应用 程序" -maxdepth 1 -name '.jbar-uninstall-*.race-original.app' -print -quit)"
unknown_stage="$(/usr/bin/find "$base/应用 程序" -maxdepth 1 -name '.jbar-uninstall-*.app' ! -name '*.race-original.app' -print -quit)"
[ -f "$preserved_original/Contents/Resources/SENTINEL" ] ||
  fail "after-stage substitution lost the original verified inode"
[ -f "$unknown_stage/DO-NOT-RESTORE" ] ||
  fail "after-stage substitution did not preserve the unknown inode for inspection"
[ -z "$(/usr/bin/find "$base/废纸篓" -mindepth 1 -print -quit)" ] ||
  fail "after-stage substitution unexpectedly moved an unverified inode to Trash"
[ "$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')" = "$((hooks_before + 2))" ] ||
  fail "after-stage substitute did not run both canonical unregister checks"
/usr/bin/grep -Fq 'current uninstall item is no longer at an expected identity' "$base/log" ||
  fail "after-stage substitution did not report identity-guarded rollback"
/usr/bin/grep -Fq 'Launch at Login was confirmed off' "$base/log" ||
  fail "after-stage substitution did not preserve login-item outcome evidence"
TESTS_RUN=$((TESTS_RUN + 1))

# An unrelated entry that wins the Trash destination race must not hide the
# verified staged inode from rollback. The verified app returns to its original
# path while the unrelated Trash entry remains byte-for-byte untouched.
base="$(make_case before-trash-destination-race)"
app="$base/应用 程序/JBar.app"
make_app "$app"
hooks_before="$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')"
if JBAR_UNINSTALL_TEST_MODE=1 \
   JBAR_UNINSTALL_TEST_ROOT="$TEST_ROOT" \
   JBAR_UNINSTALL_TARGET_APP="$app" \
   JBAR_UNINSTALL_HOME="$base/用户 主目录" \
   JBAR_UNINSTALL_TRASH_DIR="$base/废纸篓" \
   JBAR_UNINSTALL_TRUSTED_DEV_APP="$TRUSTED_DEV_APP" \
   JBAR_UNINSTALL_SKIP_PROCESS_CONTROL=1 \
   JBAR_TEST_UNREGISTER_LOG="$UNREGISTER_LOG" \
   JBAR_UNINSTALL_TEST_FAULT=before-trash-destination-race \
     "$UNINSTALLER" > "$base/log" 2>&1; then
  fail "before-Trash destination race unexpectedly succeeded"
fi
[ -f "$app/Contents/Resources/SENTINEL" ] ||
  fail "verified staged app was not restored after the Trash race"
raced_trash="$(/usr/bin/find "$base/废纸篓" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[ "$(sed -n '1p' "$raced_trash/DO-NOT-DELETE")" = 'unrelated raced Trash entry' ] ||
  fail "unrelated raced Trash entry was changed or removed"
[ -z "$(/usr/bin/find "$base/应用 程序" -maxdepth 1 -name '.jbar-uninstall-*.app' -print -quit)" ] ||
  fail "Trash destination race left the verified app staged"
[ "$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')" = "$((hooks_before + 2))" ] ||
  fail "Trash destination race did not run both canonical unregister checks"
/usr/bin/grep -Fq 'Launch at Login was confirmed off' "$base/log" ||
  fail "Trash destination race did not preserve login-item outcome evidence"
TESTS_RUN=$((TESTS_RUN + 1))

# Purge runs after confirmed login-item cleanup. A failure or TERM still restores
# the exact app and all state, but does not pretend to restore the prior login setting.
for fault in after-purge term-after-purge; do
  base="$(make_case "fault-$fault")"
  app="$base/应用 程序/JBar.app"
  home="$base/用户 主目录"
  make_app "$app"
  for state in ".config/jbar" "Library/Caches/com.linji.jbar" "Library/Application Support/JBar"; do
    /bin/mkdir -p "$home/$state"
    printf 'rollback metadata\n' > "$home/$state/SENTINEL"
  done
  hooks_before="$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')"
  if JBAR_UNINSTALL_TEST_MODE=1 \
     JBAR_UNINSTALL_TEST_ROOT="$TEST_ROOT" \
     JBAR_UNINSTALL_TARGET_APP="$app" \
     JBAR_UNINSTALL_HOME="$home" \
     JBAR_UNINSTALL_TRASH_DIR="$base/废纸篓" \
     JBAR_UNINSTALL_TRUSTED_DEV_APP="$TRUSTED_DEV_APP" \
     JBAR_UNINSTALL_SKIP_PROCESS_CONTROL=1 \
     JBAR_TEST_UNREGISTER_LOG="$UNREGISTER_LOG" \
     JBAR_UNINSTALL_TEST_FAULT="$fault" \
       "$UNINSTALLER" --purge --yes > "$base/log" 2>&1; then
    fail "$fault unexpectedly succeeded"
  fi
  [ -f "$app/Contents/Resources/SENTINEL" ] || fail "$fault did not restore the app"
  for state in ".config/jbar" "Library/Caches/com.linji.jbar" "Library/Application Support/JBar"; do
    [ -f "$home/$state/SENTINEL" ] || fail "$fault did not restore $state"
  done
  [ -z "$(/usr/bin/find "$base/废纸篓" -mindepth 1 -print -quit)" ] ||
    fail "$fault leaked a Trash item after reversible rollback"
  [ "$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')" = "$((hooks_before + 2))" ] ||
    fail "$fault did not run both canonical unregister checks"
  /usr/bin/grep -Fq 'Launch at Login was confirmed off' "$base/log" ||
    fail "$fault did not explain the non-compensated login-item state"
  TESTS_RUN=$((TESTS_RUN + 1))
done

# The post-unregister fault boundary is deliberately before the first rename.
# The app and state therefore remain canonical while Launch at Login is confirmed off.
for fault in after-unregister term-after-unregister; do
  base="$(make_case "fault-$fault")"
  app="$base/应用 程序/JBar.app"
  home="$base/用户 主目录"
  make_app "$app"
  for state in ".config/jbar" "Library/Caches/com.linji.jbar" "Library/Application Support/JBar"; do
    /bin/mkdir -p "$home/$state"
    printf 'committed metadata\n' > "$home/$state/SENTINEL"
  done
  hooks_before="$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')"
  if JBAR_UNINSTALL_TEST_MODE=1 \
     JBAR_UNINSTALL_TEST_ROOT="$TEST_ROOT" \
     JBAR_UNINSTALL_TARGET_APP="$app" \
     JBAR_UNINSTALL_HOME="$home" \
     JBAR_UNINSTALL_TRASH_DIR="$base/废纸篓" \
     JBAR_UNINSTALL_TRUSTED_DEV_APP="$TRUSTED_DEV_APP" \
     JBAR_UNINSTALL_SKIP_PROCESS_CONTROL=1 \
     JBAR_TEST_UNREGISTER_LOG="$UNREGISTER_LOG" \
     JBAR_UNINSTALL_TEST_FAULT="$fault" \
       "$UNINSTALLER" --purge --yes > "$base/log" 2>&1; then
    fail "$fault unexpectedly succeeded"
  fi
  [ -f "$app/Contents/Resources/SENTINEL" ] || fail "$fault did not retain the canonical app"
  for state in ".config/jbar" "Library/Caches/com.linji.jbar" "Library/Application Support/JBar"; do
    [ -f "$home/$state/SENTINEL" ] || fail "$fault did not retain canonical $state"
  done
  [ -z "$(/usr/bin/find "$base/废纸篓" -mindepth 1 -print -quit)" ] ||
    fail "$fault wrote Trash before the post-unregister fault boundary"
  [ "$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')" = "$((hooks_before + 1))" ] ||
    fail "$fault did not cross the tested unregister boundary exactly once"
  [ -z "$(/usr/bin/find "$base/应用 程序" -maxdepth 1 -name '.jbar-uninstall-*' -print -quit)" ] ||
    fail "$fault leaked an app staging item"
  /usr/bin/grep -Fq 'Launch at Login was confirmed off' "$base/log" ||
    fail "$fault did not explain the confirmed login-item outcome"
  TESTS_RUN=$((TESTS_RUN + 1))
done

# Identity and symlink checks refuse unrelated targets without changing them.
base="$(make_case wrong-id)"
app="$base/应用 程序/JBar.app"
make_app "$app" com.example.unrelated
if run_uninstall "$app" "$base/用户 主目录" "$base/废纸篓" > "$base/log" 2>&1; then
  fail "wrong bundle identifier unexpectedly removed"
fi
[ -f "$app/Contents/Resources/SENTINEL" ] || fail "wrong-id app was changed"
TESTS_RUN=$((TESTS_RUN + 1))

for variant in missing wrong; do
  base="$(make_case "pkginfo-$variant")"
  app="$base/应用 程序/JBar.app"
  make_app "$app"
  if [ "$variant" = missing ]; then
    /bin/rm -f -- "$app/Contents/PkgInfo"
  else
    printf 'BNDL????' > "$app/Contents/PkgInfo"
  fi
  /usr/bin/codesign --force --sign - "$app" >/dev/null 2>&1
  hooks_before="$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')"
  if run_uninstall "$app" "$base/用户 主目录" "$base/废纸篓" > "$base/log" 2>&1; then
    fail "$variant Contents/PkgInfo bundle was unexpectedly executed or removed"
  fi
  [ -f "$app/Contents/Resources/SENTINEL" ] ||
    fail "$variant Contents/PkgInfo refusal changed the app"
  [ "$(/usr/bin/wc -l < "$UNREGISTER_LOG" | /usr/bin/tr -d ' ')" = "$hooks_before" ] ||
    fail "$variant Contents/PkgInfo app's unregister hook executed"
  TESTS_RUN=$((TESTS_RUN + 1))
done

base="$(make_case symlink)"
real="$base/real.app"
make_app "$real"
app="$base/应用 程序/JBar.app"
/bin/ln -s "$real" "$app"
if run_uninstall "$app" "$base/用户 主目录" "$base/废纸篓" > "$base/log" 2>&1; then
  fail "symlink app unexpectedly removed"
fi
[ -L "$app" ] && [ -f "$real/Contents/Resources/SENTINEL" ] || fail "symlink or target was changed"
TESTS_RUN=$((TESTS_RUN + 1))

# Purge moves each state directory to Trash instead of irreversibly deleting it.
base="$(make_case purge)"
app="$base/应用 程序/JBar.app"
home="$base/用户 主目录"
make_app "$app"
for state in ".config/jbar" "Library/Caches/com.linji.jbar" "Library/Application Support/JBar"; do
  /bin/mkdir -p "$home/$state"
  printf 'private metadata\n' > "$home/$state/SENTINEL"
done
run_uninstall "$app" "$home" "$base/废纸篓" --purge --yes > "$base/log"
[ ! -e "$app" ] || fail "purge left app"
[ ! -e "$home/.config/jbar" ] || fail "purge left config"
[ ! -e "$home/Library/Caches/com.linji.jbar" ] || fail "purge left cache"
[ ! -e "$home/Library/Application Support/JBar" ] || fail "purge left history"
[ "$(/usr/bin/find "$base/废纸篓" -mindepth 1 -maxdepth 1 -type d | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 4 ] ||
  fail "purge did not create four recoverable Trash items"
TESTS_RUN=$((TESTS_RUN + 1))

# Process shutdown identifies the exact executable path; another JBar process survives.
base="$(make_case process)"
app="$base/应用 程序/JBar.app"
other="$base/other/JBar.app"
make_app "$app"
make_app "$other"
"$app/Contents/MacOS/JBar" & target_pid=$!
CHILD_PIDS="$CHILD_PIDS $target_pid"
"$other/Contents/MacOS/JBar" & other_pid=$!
CHILD_PIDS="$CHILD_PIDS $other_pid"
/bin/sleep 0.1
JBAR_UNINSTALL_TEST_MODE=1 \
JBAR_UNINSTALL_TEST_ROOT="$TEST_ROOT" \
JBAR_UNINSTALL_TARGET_APP="$app" \
JBAR_UNINSTALL_HOME="$base/用户 主目录" \
JBAR_UNINSTALL_TRASH_DIR="$base/废纸篓" \
JBAR_UNINSTALL_TRUSTED_DEV_APP="$TRUSTED_DEV_APP" \
JBAR_TEST_UNREGISTER_LOG="$UNREGISTER_LOG" \
  "$UNINSTALLER" > "$base/log"
if /bin/kill -0 "$target_pid" >/dev/null 2>&1; then fail "exact installed process survived"; fi
if ! /bin/kill -0 "$other_pid" >/dev/null 2>&1; then fail "unrelated same-name process was killed"; fi
/bin/kill "$other_pid" >/dev/null 2>&1 || true
wait "$other_pid" >/dev/null 2>&1 || true
CHILD_PIDS=""
TESTS_RUN=$((TESTS_RUN + 1))

# Test redirects and unknown arguments are rejected before any supported install path is touched.
base="$(make_case override-guard)"
app="$base/应用 程序/JBar.app"
make_app "$app"
if JBAR_UNINSTALL_TARGET_APP="$app" JBAR_UNINSTALL_HOME="$base/用户 主目录" \
   JBAR_UNINSTALL_TRASH_DIR="$base/废纸篓" "$UNINSTALLER" > "$base/log" 2>&1; then
  fail "test overrides worked without test mode"
fi
[ -f "$app/Contents/Resources/SENTINEL" ] || fail "override guard changed app"

declared_root="$TEST_ROOT/declared-root"
/bin/mkdir -m 700 "$declared_root"
if JBAR_UNINSTALL_TEST_MODE=1 \
   JBAR_UNINSTALL_TEST_ROOT="$declared_root" \
   JBAR_UNINSTALL_TARGET_APP="$app" \
   JBAR_UNINSTALL_HOME="$base/用户 主目录" \
   JBAR_UNINSTALL_TRASH_DIR="$base/废纸篓" \
   JBAR_UNINSTALL_TRUSTED_DEV_APP="$TRUSTED_DEV_APP" \
   JBAR_UNINSTALL_SKIP_PROCESS_CONTROL=1 \
   "$UNINSTALLER" > "$base/root-escape.log" 2>&1; then
  fail "uninstall test mode escaped its declared root"
fi
[ -f "$app/Contents/Resources/SENTINEL" ] || fail "root-escape refusal changed app"
if run_uninstall "$app" "$base/用户 主目录" "$base/废纸篓" --unknown > "$base/unknown.log" 2>&1; then
  fail "unknown argument was accepted"
fi
[ -f "$app/Contents/Resources/SENTINEL" ] || fail "unknown argument changed app"
TESTS_RUN=$((TESTS_RUN + 1))

if /usr/bin/grep -Eq 'pkill[[:space:]]+-f|rm[[:space:]]+-rf|xattr[[:space:]]+-dr' "$UNINSTALLER"; then
  fail "uninstaller contains broad kill/delete/quarantine bypass"
fi

echo "PASS: $TESTS_RUN isolated uninstall safety cases"

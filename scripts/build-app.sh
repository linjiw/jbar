#!/bin/bash
# Assemble JBar.app from the SwiftPM release build.
# Usage: scripts/build-app.sh [output-dir]
# Env:   JBAR_ARCHS         (default "arm64 x86_64"; space-separated macOS architectures)
#        JBAR_VERSION       (optional CFBundleShortVersionString, e.g. 1.2.3)
#        JBAR_BUILD_NUMBER  (optional positive integer CFBundleVersion)
#        CODESIGN_IDENTITY  (default "-" ad-hoc; set to a self-signed identity to keep TCC grants stable)
#        JBAR_EXPECTED_TEAM_ID (required before replacing a Developer ID-signed output)
#        JBAR_BUILD_LEGACY_REPLACE_ACK
#          exact one-time acknowledgement for a valid legacy JBar build that predates provenance
# Developer ID Application identities automatically enable hardened runtime and a secure timestamp.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_INPUT="${1:-$ROOT/build}"
SIGN="${CODESIGN_IDENTITY:--}"
ARCHS_INPUT="${JBAR_ARCHS:-arm64 x86_64}"
read -r -a ARCHS <<< "$ARCHS_INPUT"
PLIST_SOURCE="$ROOT/Resources/Info.plist"
DEFAULT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_SOURCE")"
DEFAULT_BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST_SOURCE")"
VERSION="${JBAR_VERSION:-$DEFAULT_VERSION}"
BUILD_NUMBER="${JBAR_BUILD_NUMBER:-$DEFAULT_BUILD_NUMBER}"
TEST_MODE="${JBAR_BUILD_TEST_MODE:-0}"
TEST_FAIL_AT="${JBAR_BUILD_TEST_FAIL_AT:-}"
EXPECTED_TEAM_ID="${JBAR_EXPECTED_TEAM_ID:-}"
LEGACY_REPLACE_ACK="${JBAR_BUILD_LEGACY_REPLACE_ACK:-}"
LEGACY_REPLACE_CONFIRMATION="I_UNDERSTAND_THIS_REPLACES_A_SIGNED_JBAR_APP"
PROVENANCE_KEY="JBarBuildProvenance"
PROVENANCE_VALUE="scripts/build-app.sh:v1"

case "$TEST_MODE" in
  0|1) ;;
  *)
    echo "error: JBAR_BUILD_TEST_MODE must be 0 or 1" >&2
    exit 2
    ;;
esac
if [ -n "$TEST_FAIL_AT" ] && [ "$TEST_MODE" != 1 ]; then
  echo "error: JBAR_BUILD_TEST_FAIL_AT is available only with JBAR_BUILD_TEST_MODE=1" >&2
  exit 2
fi
case "$TEST_FAIL_AT" in
  ""|after_check_race|after_upgrade_check_mutation|swap_failure|after_swap|after_activate|term_after_swap|term_after_activate|workdir_replacement|workdir_missing) ;;
  *)
    echo "error: unsupported JBAR_BUILD_TEST_FAIL_AT value '$TEST_FAIL_AT'" >&2
    exit 2
    ;;
esac
if [ -n "$EXPECTED_TEAM_ID" ] && [[ ! "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "error: JBAR_EXPECTED_TEAM_ID must be a 10-character Apple Team ID" >&2
  exit 2
fi
case "$LEGACY_REPLACE_ACK" in
  ""|"$LEGACY_REPLACE_CONFIRMATION") ;;
  *)
    echo "error: JBAR_BUILD_LEGACY_REPLACE_ACK must equal '$LEGACY_REPLACE_CONFIRMATION'" >&2
    exit 2
    ;;
esac

if [ "${#ARCHS[@]}" -eq 0 ]; then
  echo "error: JBAR_ARCHS must contain at least one architecture" >&2
  exit 2
fi

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "error: JBAR_VERSION must contain two or three numeric components (for example 1.2 or 1.2.3)" >&2
  exit 2
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: JBAR_BUILD_NUMBER must be a positive integer" >&2
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

/bin/mkdir -p "$OUT_INPUT"
OUT="$(cd "$OUT_INPUT" && pwd -P)"
APP="$OUT/JBar.app"
STALE_BACKUP="$(/usr/bin/find "$OUT" -mindepth 1 -maxdepth 1 -name '.jbar-build-backup.*.app' -print -quit)"
[ -z "$STALE_BACKUP" ] || {
  echo "error: refusing to start while a prior build backup needs manual recovery: $STALE_BACKUP" >&2
  exit 1
}
STALE_TRANSACTION="$(/usr/bin/find "$OUT" -mindepth 1 -maxdepth 1 -name '.jbar-build.*' -print -quit)"
[ -z "$STALE_TRANSACTION" ] || {
  echo "error: refusing to start while a prior build transaction needs manual recovery: $STALE_TRANSACTION" >&2
  exit 1
}
WORK_DIR="$(/usr/bin/mktemp -d "$OUT/.jbar-build.XXXXXXXX")"
[ "$(/usr/bin/stat -f '%u:%Lp' "$WORK_DIR")" = "$(/usr/bin/id -u):700" ] || {
  echo "error: build transaction directory is not current-user-owned mode 0700: $WORK_DIR" >&2
  /bin/rmdir "$WORK_DIR" >/dev/null 2>&1 || true
  exit 1
}
WORK_DIR_ID="$(/usr/bin/stat -f '%d:%i' "$WORK_DIR")" || {
  echo "error: could not record build transaction directory identity: $WORK_DIR" >&2
  exit 1
}
STAGED_APP="$WORK_DIR/JBar.app.new"
FAILED_APP="$WORK_DIR/JBar.app.failed"
BUILD_SUCCEEDED=0
ACTIVATION_STARTED=0
HAD_OLD=0
STAGED_ID=""
OLD_ID=""
OLD_READY_FOR_CLEANUP=0
PRESERVE_WORK_DIR=0
WORK_DIR_CLEANED=0

path_exists() { [ -e "$1" ] || [ -L "$1" ]; }

path_identity() {
  [ -e "$1" ] && [ ! -L "$1" ] || return 1
  /usr/bin/stat -f '%d:%i' "$1"
}

path_has_identity() {
  local actual
  actual="$(path_identity "$1" 2>/dev/null || true)"
  [ -n "$actual" ] && [ "$actual" = "$2" ]
}

# rename(2) replaces an existing destination, and `mv source destination-dir`
# nests source inside a directory that appeared after an absence check. macOS's
# RENAME_EXCL makes the same-volume activation itself fail if any path won the
# destination race.
atomic_rename_no_replace() {
  local source="$1"
  local destination="$2"
  /usr/bin/xcrun swift -e 'import Darwin
let arguments = CommandLine.arguments
guard arguments.count == 3 else { exit(64) }
let result = arguments[1].withCString { source in
    arguments[2].withCString { destination in
        renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, UInt32(RENAME_EXCL))
    }
}
if result != 0 {
    perror("renameatx_np")
    exit(1)
}' "$source" "$destination" >/dev/null
}

# Both upgrade paths already exist on the same volume. RENAME_SWAP exchanges
# them in one syscall, avoiding replaceItemAt's failure-recovery side paths.
atomic_swap() {
  local first="$1"
  local second="$2"
  /usr/bin/xcrun swift -e 'import Darwin
let arguments = CommandLine.arguments
guard arguments.count == 3 else { exit(64) }
let result = arguments[1].withCString { first in
    arguments[2].withCString { second in
        renameatx_np(AT_FDCWD, first, AT_FDCWD, second, UInt32(RENAME_SWAP))
    }
}
if result != 0 {
    perror("renameatx_np")
    exit(1)
}' "$first" "$second" >/dev/null
}

perform_upgrade_swap() {
  if [ "$TEST_MODE" = 1 ] && [ "$TEST_FAIL_AT" = swap_failure ]; then
    echo "error: injected atomic-swap failure" >&2
    return 97
  fi
  atomic_swap "$APP" "$STAGED_APP"
}

maybe_inject_failure() {
  if [ "$TEST_MODE" = 1 ] && [ "$TEST_FAIL_AT" = "$1" ]; then
    if [ "$1" = term_after_activate ] || [ "$1" = term_after_swap ]; then
      echo "test: sending TERM at $1" >&2
      /bin/kill -TERM "$$"
      return 143
    fi
    echo "error: injected build failure at $1" >&2
    return 97
  fi
}

maybe_inject_after_check_race() {
  [ "$TEST_MODE" = 1 ] && [ "$TEST_FAIL_AT" = after_check_race ] || return 0
  /bin/mkdir "$APP"
  printf 'unrelated raced destination\n' > "$APP/DO-NOT-DELETE"
  echo "test: created a destination after the first-install absence check" >&2
}

maybe_inject_upgrade_mutation() {
  [ "$TEST_MODE" = 1 ] && [ "$TEST_FAIL_AT" = after_upgrade_check_mutation ] || return 0
  printf 'changed after validation\n' > "$APP/Contents/Resources/RACED-MUTATION"
  echo "test: mutated the existing destination after validation" >&2
}

signature_details() {
  /usr/bin/codesign -d --verbose=4 "$1" 2>&1
}

signature_team_id() {
  signature_details "$1" | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2; exit }'
}

normalize_app_permissions() {
  local app="$1"
  local item
  /bin/chmod -RN "$app"
  /usr/bin/find "$app" -type d -exec /bin/chmod 755 {} +
  while IFS= read -r -d '' item; do
    if [ -x "$item" ]; then
      /bin/chmod 755 "$item"
    else
      /bin/chmod 644 "$item"
    fi
  done < <(/usr/bin/find "$app" -type f -print0)
}

app_permissions_are_safe() {
  local app="$1"
  [ -z "$(/usr/bin/find "$app" -acl -print -quit)" ] || return 1
  [ -z "$(/usr/bin/find "$app" -perm +022 -print -quit)" ] || return 1
}

validate_existing_output() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  local executable="$app/Contents/MacOS/JBar"
  local pkginfo="$app/Contents/PkgInfo"
  local team_id
  local provenance
  local requirement

  [ -d "$app" ] && [ ! -L "$app" ] || return 1
  [ -f "$plist" ] && [ ! -L "$plist" ] || return 1
  [ -f "$executable" ] && [ ! -L "$executable" ] && [ -x "$executable" ] || return 1
  [ -f "$pkginfo" ] && [ ! -L "$pkginfo" ] || return 1
  [ "$(/usr/bin/stat -f '%z' "$pkginfo")" = 8 ] &&
    [ "$(/bin/cat "$pkginfo")" = 'APPL????' ] || return 1
  [ -z "$(/usr/bin/find "$app" ! -type d ! -type f -print -quit)" ] || return 1
  app_permissions_are_safe "$app" || return 1
  /usr/bin/plutil -lint "$plist" >/dev/null || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)" = "com.linji.jbar" ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)" = "JBar" ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$plist" 2>/dev/null || true)" = "APPL" ] || return 1
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 || return 1

  team_id="$(signature_team_id "$app")"
  if [[ "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
    [ -n "$EXPECTED_TEAM_ID" ] && [ "$team_id" = "$EXPECTED_TEAM_ID" ] || {
      echo "error: refusing to replace Developer ID output from unapproved Team '$team_id'" >&2
      return 1
    }
    requirement="identifier \"com.linji.jbar\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""
    /usr/bin/codesign --verify --deep --strict -R="$requirement" "$app" >/dev/null 2>&1 || return 1
    return 0
  fi

  provenance="$(/usr/libexec/PlistBuddy -c "Print :$PROVENANCE_KEY" "$plist" 2>/dev/null || true)"
  if [ "$provenance" = "$PROVENANCE_VALUE" ]; then
    return 0
  fi
  if [ "$LEGACY_REPLACE_ACK" = "$LEGACY_REPLACE_CONFIRMATION" ]; then
    echo "warning: replacing a valid legacy JBar build without provenance by explicit acknowledgement" >&2
    return 0
  fi
  echo "error: existing output is validly signed but lacks JBar build provenance" >&2
  echo "error: move it aside manually, or set JBAR_BUILD_LEGACY_REPLACE_ACK=$LEGACY_REPLACE_CONFIRMATION once" >&2
  return 1
}

safe_cleanup() {
  local cleanup_status=0
  [ "$WORK_DIR_CLEANED" -eq 0 ] || return 0
  if [ "$(dirname "$WORK_DIR")" != "$OUT" ] ||
     [[ "$(basename "$WORK_DIR")" != .jbar-build.* ]]; then
    echo "error: refusing unsafe build staging cleanup: $WORK_DIR" >&2
    return 1
  fi
  # Entering the directory pins its inode as cwd. Verify that pinned inode before
  # deleting only relative descendants, so replacing the absolute entry cannot
  # redirect recursive cleanup into an unrelated tree.
  (
    cd "$WORK_DIR" || exit 1
    [ "$(/usr/bin/stat -f '%d:%i' .)" = "$WORK_DIR_ID" ] || exit 1
    /usr/bin/find -x . -depth -mindepth 1 -delete
    [ "$(/usr/bin/stat -f '%d:%i' .)" = "$WORK_DIR_ID" ] || exit 1
  ) || cleanup_status=$?
  if [ "$cleanup_status" -ne 0 ]; then
    echo "error: build transaction directory is missing, replaced, or could not be cleaned; preserving recovery state: $WORK_DIR" >&2
    return 1
  fi
  path_has_identity "$WORK_DIR" "$WORK_DIR_ID" || {
    echo "error: build transaction entry changed after relative cleanup; refusing absolute removal: $WORK_DIR" >&2
    return 1
  }
  /bin/rmdir "$WORK_DIR" || return 1
  WORK_DIR_CLEANED=1
}

maybe_inject_workdir_cleanup_race() {
  local preserved
  case "$TEST_FAIL_AT" in
    workdir_replacement|workdir_missing) ;;
    *) return 0 ;;
  esac
  preserved="${WORK_DIR}.race-original"
  /bin/mv "$WORK_DIR" "$preserved"
  if [ "$TEST_FAIL_AT" = workdir_replacement ]; then
    /bin/mkdir "$WORK_DIR"
    printf 'unrelated replacement tree\n' > "$WORK_DIR/DO-NOT-DELETE"
  fi
  echo "test: changed the build transaction entry before cleanup ($TEST_FAIL_AT)" >&2
}

prepare_old_for_cleanup() {
  [ "$HAD_OLD" -eq 1 ] || return 0
  if [ "$OLD_READY_FOR_CLEANUP" -eq 1 ] && ! path_exists "$STAGED_APP"; then
    return 0
  fi
  if path_has_identity "$APP" "$STAGED_ID" &&
     path_has_identity "$STAGED_APP" "$OLD_ID" &&
     validate_existing_output "$STAGED_APP"; then
    OLD_READY_FOR_CLEANUP=1
    return 0
  fi
  echo "error: refusing to clean a swapped old bundle whose identity or trust changed" >&2
  PRESERVE_WORK_DIR=1
  return 1
}

rollback_build() {
  local ok=1
  if [ "$HAD_OLD" -eq 1 ] && [ "$ACTIVATION_STARTED" -eq 1 ]; then
    if path_has_identity "$APP" "$STAGED_ID" && path_has_identity "$STAGED_APP" "$OLD_ID"; then
      if ! atomic_swap "$APP" "$STAGED_APP" ||
         ! path_has_identity "$APP" "$OLD_ID" ||
         ! path_has_identity "$STAGED_APP" "$STAGED_ID"; then
        echo "error: could not atomically swap the previous build back into place" >&2
        PRESERVE_WORK_DIR=1
        ok=0
      fi
    elif path_has_identity "$APP" "$OLD_ID" && path_has_identity "$STAGED_APP" "$STAGED_ID"; then
      : # The injected/syscall failure left both pre-swap paths unchanged.
    else
      echo "error: upgrade paths changed outside the transaction; preserving the private workspace" >&2
      PRESERVE_WORK_DIR=1
      ok=0
    fi
  elif [ "$HAD_OLD" -eq 0 ] && [ "$ACTIVATION_STARTED" -eq 1 ] &&
       path_has_identity "$APP" "$STAGED_ID"; then
    if ! atomic_rename_no_replace "$APP" "$FAILED_APP"; then
      echo "error: could not remove the interrupted first build output: $APP" >&2
      ok=0
    fi
  fi
  [ "$ok" -eq 1 ]
}

handle_exit() {
  local status="$1"
  local cleanup_ok=1
  trap - EXIT INT TERM HUP
  set +e
  if [ "$status" -ne 0 ] && [ "$BUILD_SUCCEEDED" -ne 1 ]; then
    rollback_build || cleanup_ok=0
  fi
  if [ "$BUILD_SUCCEEDED" -eq 1 ]; then
    prepare_old_for_cleanup || cleanup_ok=0
  fi
  if [ "$PRESERVE_WORK_DIR" -eq 1 ] ||
     { [ "$HAD_OLD" -eq 1 ] && [ "$BUILD_SUCCEEDED" -eq 1 ] && [ "$OLD_READY_FOR_CLEANUP" -ne 1 ]; }; then
    echo "error: preserving build transaction because it contains uncommitted swapped state: $WORK_DIR" >&2
    cleanup_ok=0
  else
    safe_cleanup || cleanup_ok=0
  fi
  if [ "$cleanup_ok" -ne 1 ] && [ "$status" -eq 0 ]; then status=1; fi
  exit "$status"
}

trap 'handle_exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN" "$STAGED_APP/Contents/MacOS/JBar"
cp "$PLIST_SOURCE" "$STAGED_APP/Contents/Info.plist"
[ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :$PROVENANCE_KEY string $PROVENANCE_VALUE" "$STAGED_APP/Contents/Info.plist"

normalize_app_permissions "$STAGED_APP"
app_permissions_are_safe "$STAGED_APP" || {
  echo "error: staged bundle retains an ACL or group/world-write permission" >&2
  exit 1
}

plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null

ACTUAL_ARCHS="$(lipo -archs "$STAGED_APP/Contents/MacOS/JBar")"
for arch in "${ARCHS[@]}"; do
  case " $ACTUAL_ARCHS " in
    *" $arch "*) ;;
    *)
      echo "error: built executable is missing requested architecture '$arch' (found: $ACTUAL_ARCHS)" >&2
      exit 1
      ;;
  esac
done

SIGN_ARGS=(--force --sign "$SIGN")
if is_developer_id_identity "$SIGN"; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi

codesign "${SIGN_ARGS[@]}" "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
EXECUTABLE_VERSION="$("$STAGED_APP/Contents/MacOS/JBar" --version)"
if [[ "$EXECUTABLE_VERSION" != "JBar $VERSION" && "$EXECUTABLE_VERSION" != "JBar $VERSION ("* ]]; then
  echo "error: executable version does not match staged Info.plist version '$VERSION'" >&2
  exit 1
fi
STAGED_ID="$(path_identity "$STAGED_APP")" || {
  echo "error: could not record the staged bundle identity" >&2
  exit 1
}

# Only replace a directory that identifies itself as JBar. An unrelated or symlinked `JBar.app`
# may contain user data and must never be recursively deleted by a build command.
if path_exists "$APP"; then
  validate_existing_output "$APP" || {
    echo "error: refusing to replace an untrusted or unidentified output: $APP" >&2
    exit 1
  }
  HAD_OLD=1
  OLD_ID="$(path_identity "$APP")" || {
    echo "error: could not record the existing output identity" >&2
    exit 1
  }
  maybe_inject_upgrade_mutation
  ACTIVATION_STARTED=1
  if ! path_has_identity "$APP" "$OLD_ID" ||
     ! path_has_identity "$STAGED_APP" "$STAGED_ID"; then
    echo "error: upgrade paths changed before the atomic swap" >&2
    exit 1
  fi
  perform_upgrade_swap || {
    echo "error: could not atomically swap the verified and existing bundles" >&2
    exit 1
  }
  maybe_inject_failure term_after_swap
  path_has_identity "$APP" "$STAGED_ID" || {
    echo "error: activated output identity changed during the atomic swap" >&2
    exit 1
  }
  path_has_identity "$STAGED_APP" "$OLD_ID" || {
    echo "error: displaced output identity changed during the atomic swap" >&2
    exit 1
  }
  validate_existing_output "$STAGED_APP" || {
    echo "error: displaced output changed after validation; restoring it instead of deleting it" >&2
    exit 1
  }
  maybe_inject_failure after_swap
else
  ACTIVATION_STARTED=1
  maybe_inject_after_check_race
  if ! atomic_rename_no_replace "$STAGED_APP" "$APP"; then
    echo "error: could not exclusively activate the verified bundle; the destination appeared or changed" >&2
    exit 1
  fi
fi
path_has_identity "$APP" "$STAGED_ID" || {
  echo "error: activated output changed before final validation" >&2
  exit 1
}
maybe_inject_failure after_activate
maybe_inject_failure term_after_activate
prepare_old_for_cleanup
BUILD_SUCCEEDED=1
maybe_inject_workdir_cleanup_race
safe_cleanup

echo "Built: $APP  (version: $VERSION ($BUILD_NUMBER); architectures: $ACTUAL_ARCHS; signed with '$SIGN')"
if is_developer_id_identity "$SIGN"; then
  echo "Next for public distribution: notarize this bundle and staple the notarization ticket."
fi

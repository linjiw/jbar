#!/bin/bash
# Safely uninstall JBar by moving verified bundles (and optional state) to Trash.
# Flags: --purge (also trash config/cache/history), --yes (confirm purge non-interactively),
#        --skip-login-item-cleanup (never execute an untrusted/old app; user handles login item).
# Public Developer ID installs require JBAR_EXPECTED_TEAM_ID=<10-character Team ID> until the
# publisher Team ID is pinned as a reviewed product constant. Development CLI execution requires
# an exact CDHash match with this checkout's build/JBar.app; otherwise cleanup is fail-closed.
# Removed items remain recoverable in ~/.Trash until the user empties it.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PURGE=0
ASSUME_YES=0
SKIP_LOGIN_ITEM_CLEANUP=0
TEST_MODE="${JBAR_UNINSTALL_TEST_MODE:-0}"
SKIP_PROCESS_CONTROL="${JBAR_UNINSTALL_SKIP_PROCESS_CONTROL:-0}"
TEST_FAULT="${JBAR_UNINSTALL_TEST_FAULT:-}"
EXPECTED_TEAM_ID="${JBAR_EXPECTED_TEAM_ID:-}"
PROVENANCE_KEY="JBarBuildProvenance"
PROVENANCE_VALUE="scripts/build-app.sh:v1"
FORCE_CROSS_DEVICE="${JBAR_UNINSTALL_TEST_FORCE_CROSS_DEVICE:-0}"

die() { echo "error: $*" >&2; exit 1; }
path_exists() { [ -e "$1" ] || [ -L "$1" ]; }
require_boolean() { case "$2" in 0|1) ;; *) die "$1 must be 0 or 1" ;; esac; }

path_identity() {
  [ -e "$1" ] && [ ! -L "$1" ] || return 1
  /usr/bin/stat -f '%d:%i' "$1"
}

path_has_identity() {
  local actual
  actual="$(path_identity "$1" 2>/dev/null || true)"
  [ -n "$actual" ] && [ "$actual" = "$2" ]
}

atomic_rename_no_replace() {
  local source="$1"
  local destination="$2"
  # Bind macOS renameatx_np directly so RENAME_EXCL is the kernel operation,
  # while JXA keeps uninstall independent of Xcode Command Line Tools.
  /usr/bin/osascript -l JavaScript - "$source" "$destination" >/dev/null <<'JXA'
ObjC.bindFunction('renameatx_np', ['int', ['int', 'char *', 'int', 'char *', 'unsigned int']])
function run(argv) {
  const AT_FDCWD = -2
  const RENAME_EXCL = 0x00000004
  const result = $.renameatx_np(AT_FDCWD, argv[0], AT_FDCWD, argv[1], RENAME_EXCL)
  if (result !== 0) throw new Error('renameatx_np(RENAME_EXCL) failed')
}
JXA
}

for argument in "$@"; do
  case "$argument" in
    --purge) PURGE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --skip-login-item-cleanup) SKIP_LOGIN_ITEM_CLEANUP=1 ;;
    *) die "unknown argument: $argument" ;;
  esac
done
require_boolean JBAR_UNINSTALL_TEST_MODE "$TEST_MODE"
require_boolean JBAR_UNINSTALL_SKIP_PROCESS_CONTROL "$SKIP_PROCESS_CONTROL"
require_boolean JBAR_UNINSTALL_TEST_FORCE_CROSS_DEVICE "$FORCE_CROSS_DEVICE"
if [ -n "$EXPECTED_TEAM_ID" ] && [[ ! "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  die "JBAR_EXPECTED_TEAM_ID must be a 10-character Apple Team ID"
fi
case "$TEST_FAULT" in
  ""|before-unregister|after-unregister|after-stage|after-stage-disappearance|after-stage-substitution|before-trash-destination-race|after-trash|after-trash-disappearance|after-purge|term-before-unregister|term-after-unregister|term-after-stage|term-after-trash|term-after-purge) ;;
  *) die "unsupported JBAR_UNINSTALL_TEST_FAULT value '$TEST_FAULT'" ;;
esac

if [ "$TEST_MODE" -ne 1 ]; then
  if [ -n "${JBAR_UNINSTALL_TARGET_APP:-}" ] ||
     [ -n "${JBAR_UNINSTALL_SECOND_TARGET_APP:-}" ] ||
     [ -n "${JBAR_UNINSTALL_HOME:-}" ] ||
     [ -n "${JBAR_UNINSTALL_TRASH_DIR:-}" ] ||
     [ -n "${JBAR_UNINSTALL_TEST_ROOT:-}" ] ||
     [ -n "${JBAR_UNINSTALL_TRUSTED_DEV_APP:-}" ] ||
     [ "$SKIP_PROCESS_CONTROL" -ne 0 ] ||
     [ "$FORCE_CROSS_DEVICE" -ne 0 ] ||
     [ -n "$TEST_FAULT" ]; then
    die "test overrides require JBAR_UNINSTALL_TEST_MODE=1"
  fi
fi

if [ "$PURGE" -eq 1 ] && [ "$ASSUME_YES" -ne 1 ]; then
  printf 'Also move JBar config, cache, and history to Trash? [y/N] '
  read -r answer
  case "$answer" in
    y|Y) ;;
    *) PURGE=0; echo "Keeping user data." ;;
  esac
fi

if [ "$TEST_MODE" -eq 1 ]; then
  [ -n "${JBAR_UNINSTALL_TARGET_APP:-}" ] || die "JBAR_UNINSTALL_TARGET_APP is required in test mode"
  [ -n "${JBAR_UNINSTALL_HOME:-}" ] || die "JBAR_UNINSTALL_HOME is required in test mode"
  [ -n "${JBAR_UNINSTALL_TRASH_DIR:-}" ] || die "JBAR_UNINSTALL_TRASH_DIR is required in test mode"
  [ -n "${JBAR_UNINSTALL_TEST_ROOT:-}" ] || die "JBAR_UNINSTALL_TEST_ROOT is required in test mode"
  [ -d "$JBAR_UNINSTALL_TEST_ROOT" ] && [ ! -L "$JBAR_UNINSTALL_TEST_ROOT" ] ||
    die "JBAR_UNINSTALL_TEST_ROOT must be a regular directory"
  TEST_ROOT="$(cd "$JBAR_UNINSTALL_TEST_ROOT" && pwd -P)"
  [ "$(/usr/bin/stat -f '%u' "$TEST_ROOT")" = "$(/usr/bin/id -u)" ] ||
    die "JBAR_UNINSTALL_TEST_ROOT must be owned by the current user"
  [ "$(/usr/bin/stat -f '%Lp' "$TEST_ROOT")" = 700 ] ||
    die "JBAR_UNINSTALL_TEST_ROOT must have mode 0700"
  TARGET_APPS=("$JBAR_UNINSTALL_TARGET_APP")
  if [ -n "${JBAR_UNINSTALL_SECOND_TARGET_APP:-}" ]; then
    TARGET_APPS+=("$JBAR_UNINSTALL_SECOND_TARGET_APP")
  fi
  TARGET_HOME="$JBAR_UNINSTALL_HOME"
  TRASH_DIR="$JBAR_UNINSTALL_TRASH_DIR"
  TRUSTED_DEV_APP="${JBAR_UNINSTALL_TRUSTED_DEV_APP:-}"
else
  TARGET_APPS=("/Applications/JBar.app" "$HOME/Applications/JBar.app")
  TARGET_HOME="$HOME"
  TRASH_DIR="$HOME/.Trash"
  TRUSTED_DEV_APP="$ROOT/build/JBar.app"
fi

[ -d "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] || die "home directory is missing or unsafe: $TARGET_HOME"
TARGET_HOME="$(cd "$TARGET_HOME" && pwd -P)"
if [ ! -e "$TRASH_DIR" ]; then /bin/mkdir -m 700 "$TRASH_DIR"; fi
[ -d "$TRASH_DIR" ] && [ ! -L "$TRASH_DIR" ] || die "Trash directory is missing or unsafe: $TRASH_DIR"
TRASH_DIR="$(cd "$TRASH_DIR" && pwd -P)"
[ "$(/usr/bin/stat -f '%u' "$TRASH_DIR")" = "$(/usr/bin/id -u)" ] ||
  die "Trash directory must be owned by the current user"
[ "$(/usr/bin/stat -f '%Lp' "$TRASH_DIR")" = 700 ] ||
  die "Trash directory must have mode 0700"

if [ "$TEST_MODE" -eq 1 ]; then
  case "$TARGET_HOME/" in "$TEST_ROOT"/*) ;; *) die "test home must be inside JBAR_UNINSTALL_TEST_ROOT" ;; esac
  case "$TRASH_DIR/" in "$TEST_ROOT"/*) ;; *) die "test Trash must be inside JBAR_UNINSTALL_TEST_ROOT" ;; esac
  validated_target_apps=()
  for target_app in "${TARGET_APPS[@]}"; do
    target_parent="$(cd "$(dirname "$target_app")" && pwd -P)"
    case "$target_parent/" in "$TEST_ROOT"/*) ;; *) die "test app must be inside JBAR_UNINSTALL_TEST_ROOT" ;; esac
    validated_target_apps+=("$target_parent/$(basename "$target_app")")
  done
  TARGET_APPS=("${validated_target_apps[@]}")
  if [ "${#TARGET_APPS[@]}" -eq 2 ] && [ "${TARGET_APPS[0]}" = "${TARGET_APPS[1]}" ]; then
    die "test app targets must be distinct"
  fi
fi

signature_details() {
  /usr/bin/codesign -d --verbose=4 "$1" 2>&1
}

signature_team_id() {
  signature_details "$1" | /usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2; exit }'
}

signature_cdhash() {
  signature_details "$1" | /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }'
}

app_permissions_are_safe() {
  local app="$1"
  [ -z "$(/usr/bin/find "$app" -acl -print -quit)" ] || return 1
  [ -z "$(/usr/bin/find "$app" -perm +022 -print -quit)" ] || return 1
}

validate_app_static() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  local executable="$app/Contents/MacOS/JBar"
  local pkginfo="$app/Contents/PkgInfo"
  [ -d "$app" ] && [ ! -L "$app" ] || { echo "error: refusing non-directory or symlink app: $app" >&2; return 1; }
  [ -f "$plist" ] && [ ! -L "$plist" ] || { echo "error: refusing app without regular Info.plist: $app" >&2; return 1; }
  [ -f "$executable" ] && [ ! -L "$executable" ] && [ -x "$executable" ] || {
    echo "error: refusing app without regular JBar executable: $app" >&2; return 1;
  }
  [ -f "$pkginfo" ] && [ ! -L "$pkginfo" ] || {
    echo "error: refusing app without regular Contents/PkgInfo: $app" >&2; return 1;
  }
  [ "$(/usr/bin/stat -f '%z' "$pkginfo")" = 8 ] &&
    [ "$(/bin/cat "$pkginfo")" = 'APPL????' ] || {
    echo "error: refusing app with invalid Contents/PkgInfo marker: $app" >&2; return 1;
  }
  /usr/bin/plutil -lint "$plist" >/dev/null || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)" = "com.linji.jbar" ] || {
    echo "error: refusing app with unexpected bundle identifier: $app" >&2; return 1;
  }
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null)" = "JBar" ] || {
    echo "error: refusing app with unexpected bundle executable: $app" >&2; return 1;
  }
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$plist" 2>/dev/null)" = "APPL" ] || {
    echo "error: refusing app with unexpected package type: $app" >&2; return 1;
  }
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1 || {
    echo "error: refusing app with a missing, invalid, or modified code signature: $app" >&2; return 1;
  }
  [ -z "$(/usr/bin/find "$app" ! -type d ! -type f -print -quit)" ] || {
    echo "error: refusing app containing symbolic links or unsupported special files: $app" >&2; return 1;
  }
  app_permissions_are_safe "$app" || {
    echo "error: refusing app containing an ACL or group/world-write permission: $app" >&2; return 1;
  }
}

classify_app_trust() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  local team_id
  local provenance
  local requirement

  validate_app_static "$app" || return 1
  team_id="$(signature_team_id "$app")"
  if [[ "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
    [ -n "$EXPECTED_TEAM_ID" ] || {
      echo "error: refusing Developer ID app until JBAR_EXPECTED_TEAM_ID is configured" >&2
      return 1
    }
    [ "$team_id" = "$EXPECTED_TEAM_ID" ] || {
      echo "error: refusing Developer ID app from unapproved Team '$team_id'" >&2
      return 1
    }
    requirement="identifier \"com.linji.jbar\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""
    /usr/bin/codesign --verify --deep --strict -R="$requirement" "$app" >/dev/null 2>&1 || {
      echo "error: app does not satisfy JBar's Developer ID designated requirement" >&2
      return 1
    }
    printf 'release\n'
    return 0
  fi

  provenance="$(/usr/libexec/PlistBuddy -c "Print :$PROVENANCE_KEY" "$plist" 2>/dev/null || true)"
  [ "$provenance" = "$PROVENANCE_VALUE" ] || {
    echo "error: refusing non-Developer-ID app without signed JBar build provenance" >&2
    return 1
  }
  printf 'development\n'
}

trusted_development_reference_matches() {
  local app="$1"
  local reference="$TRUSTED_DEV_APP"
  local app_hash
  local reference_hash

  [ -n "$reference" ] && [ -d "$reference" ] && [ ! -L "$reference" ] || return 1
  validate_app_static "$reference" >/dev/null 2>&1 || return 1
  [ "$(signature_team_id "$reference")" = "not set" ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c "Print :$PROVENANCE_KEY" "$reference/Contents/Info.plist" 2>/dev/null || true)" = "$PROVENANCE_VALUE" ] || return 1
  app_hash="$(signature_cdhash "$app")"
  reference_hash="$(signature_cdhash "$reference")"
  [ -n "$app_hash" ] && [ "$app_hash" = "$reference_hash" ]
}

ensure_same_trash_device() {
  local item="$1"
  path_exists "$item" || return 0
  if [ "$FORCE_CROSS_DEVICE" -eq 1 ] ||
     [ "$(/usr/bin/stat -f '%d' "$item")" != "$(/usr/bin/stat -f '%d' "$TRASH_DIR")" ]; then
    echo "error: refusing non-atomic cross-volume Trash move for $item" >&2
    echo "error: use Finder to move this item to its volume's Trash" >&2
    return 1
  fi
}

destination_pids() {
  local expected="$1"
  local pid
  local command_path
  while IFS= read -r pid; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    command_path="$(/bin/ps -ww -p "$pid" -o comm= 2>/dev/null || true)"
    command_path="${command_path#"${command_path%%[![:space:]]*}"}"
    command_path="${command_path%"${command_path##*[![:space:]]}"}"
    [ "$command_path" = "$expected" ] && printf '%s\n' "$pid"
  done < <(/usr/bin/pgrep -x JBar 2>/dev/null || true)
}

is_running() { [ -n "$(destination_pids "$1")" ]; }
wait_until_stopped() {
  local executable="$1"
  local attempt=0
  while [ "$attempt" -lt 30 ]; do
    is_running "$executable" || return 0
    /bin/sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

stop_exact_app() {
  local executable="$1"
  local pid
  is_running "$executable" || return 0
  /usr/bin/osascript -l JavaScript - "$executable" >/dev/null 2>&1 <<'JXA' || true
ObjC.import('AppKit')
function run(argv) {
  const expected = argv[0]
  const applications = $.NSWorkspace.sharedWorkspace.runningApplications
  for (let index = 0; index < applications.count; index++) {
    const application = applications.objectAtIndex(index)
    const executableURL = application.executableURL
    if (executableURL && ObjC.unwrap(executableURL.path) === expected) application.terminate
  }
}
JXA
  wait_until_stopped "$executable" && return 0
  while IFS= read -r pid; do [ -n "$pid" ] && /bin/kill -TERM "$pid" 2>/dev/null || true; done \
    < <(destination_pids "$executable")
  wait_until_stopped "$executable" && return 0
  while IFS= read -r pid; do [ -n "$pid" ] && /bin/kill -KILL "$pid" 2>/dev/null || true; done \
    < <(destination_pids "$executable")
  wait_until_stopped "$executable"
}

maybe_fail() {
  local point="$1"
  if [ "$TEST_MODE" -eq 1 ] && [ "$TEST_FAULT" = "$point" ]; then
    case "$point" in
      term-before-unregister|term-after-unregister|term-after-stage|term-after-trash|term-after-purge)
        echo "test: sending TERM at '$point'" >&2
        /bin/kill -TERM "$$"
        return 143
        ;;
    esac
    echo "test: injecting uninstaller failure at '$point'" >&2
    return 97
  fi
}

maybe_inject_stage_substitution() {
  local preserved
  [ "$TEST_MODE" -eq 1 ] && [ "$TEST_FAULT" = after-stage-substitution ] || return 0
  preserved="${CURRENT_STAGED%.app}.race-original.app"
  atomic_rename_no_replace "$CURRENT_STAGED" "$preserved" ||
    die "test could not preserve the pre-substitution staged app"
  /bin/mkdir "$CURRENT_STAGED"
  printf 'unknown staged substitute\n' > "$CURRENT_STAGED/DO-NOT-RESTORE"
  echo "test: substituted the hidden staged path before its Trash move" >&2
}

maybe_inject_stage_disappearance() {
  local preserved
  [ "$TEST_MODE" -eq 1 ] && [ "$TEST_FAULT" = after-stage-disappearance ] || return 0
  preserved="${CURRENT_STAGED%.app}.race-moved.app"
  atomic_rename_no_replace "$CURRENT_STAGED" "$preserved" ||
    die "test could not move the staged app out of the rollback source path"
  echo "test: moved the verified staged inode away from every recorded rollback path" >&2
  die "test: injecting missing staged rollback source"
}

maybe_inject_trash_destination_race() {
  [ "$TEST_MODE" -eq 1 ] && [ "$TEST_FAULT" = before-trash-destination-race ] || return 0
  /bin/mkdir "$CURRENT_TRASHED"
  printf 'unrelated raced Trash entry\n' > "$CURRENT_TRASHED/DO-NOT-DELETE"
  echo "test: created an unrelated Trash destination before the exclusive move" >&2
}

ORIGINALS=()
TRASHED=()
ORIGINAL_IDS=()
CURRENT_ORIGINAL=""
CURRENT_STAGED=""
CURRENT_TRASHED=""
CURRENT_EXPECTED_ID=""
SUCCEEDED=0
LOGIN_ITEM_CLEANUP_STARTED=0
LOGIN_ITEM_CLEANUP_CONFIRMED=0
APP_PATHS=()
APP_IDS=()
APP_TRUSTS=()

restore_one() {
  local original="$1"
  local removed="$2"
  local expected_id="$3"
  if ! path_exists "$removed"; then
    if path_has_identity "$original" "$expected_id"; then
      return 0
    fi
    echo "error: expected rollback source is missing and the original path does not contain the recorded identity: $removed" >&2
    return 1
  fi
  if ! path_has_identity "$removed" "$expected_id"; then
    echo "error: refusing to restore a removed item whose identity changed: $removed" >&2
    return 1
  fi
  if ! atomic_rename_no_replace "$removed" "$original"; then
    echo "error: cannot exclusively restore because the destination exists or changed: $original" >&2
    return 1
  fi
  if ! path_has_identity "$original" "$expected_id"; then
    echo "error: restored path does not contain the recorded identity: $original" >&2
    return 1
  fi
}

rollback() {
  local ok=1
  local index
  if [ -n "$CURRENT_TRASHED" ] &&
     path_has_identity "$CURRENT_TRASHED" "$CURRENT_EXPECTED_ID"; then
    restore_one "$CURRENT_ORIGINAL" "$CURRENT_TRASHED" "$CURRENT_EXPECTED_ID" || ok=0
  elif [ -n "$CURRENT_STAGED" ] &&
       path_has_identity "$CURRENT_STAGED" "$CURRENT_EXPECTED_ID"; then
    restore_one "$CURRENT_ORIGINAL" "$CURRENT_STAGED" "$CURRENT_EXPECTED_ID" || ok=0
  elif { [ -n "$CURRENT_TRASHED" ] && path_exists "$CURRENT_TRASHED"; } ||
       { [ -n "$CURRENT_STAGED" ] && path_exists "$CURRENT_STAGED"; }; then
    echo "error: current uninstall item is no longer at an expected identity" >&2
    ok=0
  elif [ -n "$CURRENT_ORIGINAL" ] &&
       ! path_has_identity "$CURRENT_ORIGINAL" "$CURRENT_EXPECTED_ID"; then
    echo "error: current rollback sources are missing and the original path does not contain the recorded identity: $CURRENT_ORIGINAL" >&2
    ok=0
  fi
  for ((index=${#ORIGINALS[@]} - 1; index >= 0; index--)); do
    restore_one "${ORIGINALS[$index]}" "${TRASHED[$index]}" "${ORIGINAL_IDS[$index]}" || ok=0
  done
  if [ "$ok" -ne 1 ]; then
    echo "error: rollback was incomplete; items remain at guarded staging or Trash paths" >&2
    return 1
  fi
}

on_exit() {
  local status="$1"
  local rollback_ok=1
  trap - EXIT INT TERM HUP
  if [ "$status" -ne 0 ] && [ "$SUCCEEDED" -ne 1 ]; then
    rollback || rollback_ok=0
    if [ "$LOGIN_ITEM_CLEANUP_STARTED" -eq 1 ]; then
      if [ "$LOGIN_ITEM_CLEANUP_CONFIRMED" -eq 1 ]; then
        echo "error: Launch at Login was confirmed off; file moves were rolled back where identity checks allowed, but the prior login-item setting was not automatically restored" >&2
      else
        echo "error: login-item cleanup was attempted but not confirmed; file moves were rolled back where identity checks allowed, and Login Items must be checked manually" >&2
      fi
    fi
    [ "$rollback_ok" -eq 1 ] ||
      echo "error: at least one filesystem item requires manual recovery" >&2
  fi
  exit "$status"
}
trap 'on_exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

stage_item() {
  local original="$1"
  local label="$2"
  local expected_id="${3:-}"
  local parent
  local token
  local staged
  local destination
  local actual_id
  path_exists "$original" || return 0
  actual_id="$(path_identity "$original")" || die "could not record uninstall target identity: $original"
  if [ -n "$expected_id" ] && [ "$actual_id" != "$expected_id" ]; then
    die "uninstall target changed after validation: $original"
  fi
  expected_id="$actual_id"
  parent="$(cd "$(dirname "$original")" && pwd -P)"
  token="$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]')"
  # Preserve the .app suffix so isolation does not also change the bundle's basic
  # shape. The real SMAppService lifecycle is still a physical release gate.
  staged="$parent/.jbar-uninstall-$token.app"
  case "$original" in
    *.app) destination="$TRASH_DIR/${label%.app}-$token.app" ;;
    *) destination="$TRASH_DIR/${label}-$token" ;;
  esac
  [ ! -e "$staged" ] && [ ! -L "$staged" ] || die "temporary uninstall path already exists"
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || die "Trash destination already exists"

  CURRENT_ORIGINAL="$original"
  CURRENT_STAGED="$staged"
  # Record both possible locations before either rename. A signal delivered
  # immediately after rename can therefore still restore the exact item.
  CURRENT_TRASHED="$destination"
  CURRENT_EXPECTED_ID="$expected_id"
  atomic_rename_no_replace "$original" "$staged" ||
    die "could not exclusively stage uninstall target: $original"
  path_has_identity "$staged" "$expected_id" ||
    die "uninstall target changed while entering the staging path"
  maybe_fail after-stage
  maybe_fail term-after-stage
  maybe_inject_stage_disappearance
}

finish_current_trash() {
  local original="$CURRENT_ORIGINAL"
  local staged="$CURRENT_STAGED"
  local destination="$CURRENT_TRASHED"
  local preserved
  [ -n "$original" ] && [ -n "$staged" ] && [ -n "$destination" ] ||
    die "internal uninstall transaction state is incomplete"
  path_has_identity "$staged" "$CURRENT_EXPECTED_ID" ||
    die "staged uninstall target changed before its Trash move"
  ensure_same_trash_device "$staged"
  atomic_rename_no_replace "$staged" "$destination" ||
    die "could not exclusively move uninstall target to Trash: $staged"
  path_has_identity "$destination" "$CURRENT_EXPECTED_ID" ||
    die "uninstall target changed during its Trash move"

  # Transfer ownership from the in-flight slot to the completed rollback arrays
  # while signals are ignored, avoiding a lost/duplicated rollback record.
  trap '' INT TERM HUP
  ORIGINALS+=("$original")
  TRASHED+=("$destination")
  ORIGINAL_IDS+=("$CURRENT_EXPECTED_ID")
  CURRENT_ORIGINAL=""
  CURRENT_STAGED=""
  CURRENT_TRASHED=""
  CURRENT_EXPECTED_ID=""
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  if [ "$TEST_MODE" -eq 1 ] && [ "$TEST_FAULT" = after-trash-disappearance ]; then
    preserved="${destination%.app}.race-moved.app"
    atomic_rename_no_replace "$destination" "$preserved" ||
      die "test could not move the trashed app out of the completed rollback source path"
    echo "test: moved the verified trashed inode away from every recorded rollback path" >&2
    die "test: injecting missing completed rollback source"
  fi
  maybe_fail after-trash
  maybe_fail term-after-trash
  echo "Moved to Trash: $original"
}

trash_item() {
  local original="$1"
  local label="$2"
  path_exists "$original" || return 0
  stage_item "$original" "$label"
  finish_current_trash
}

preflight_stale_stage() {
  local original="$1"
  local kind="$2"
  local logical_parent
  local parent
  local stale
  local stale_id
  local stale_trust

  logical_parent="$(dirname "$original")"
  [ -e "$logical_parent" ] || return 0
  [ -d "$logical_parent" ] ||
    die "cannot safely inspect prior uninstall staging under non-directory parent: $logical_parent"
  # stage_item resolves the physical parent before creating a hidden name. Use
  # the same read-only canonicalization so a legitimate symlinked state parent
  # neither blocks an app-only uninstall nor hides its recovery entry.
  parent="$(cd "$logical_parent" && pwd -P)" ||
    die "cannot resolve prior uninstall staging parent: $logical_parent"
  stale="$(/usr/bin/find "$parent" -mindepth 1 -maxdepth 1 -name '.jbar-uninstall-*.app' -print -quit)"
  [ -z "$stale" ] && return 0
  stale_id="$(path_identity "$stale")" ||
    die "prior uninstall staging is a symbolic link or unreadable and was preserved for manual recovery: $stale (expected original: $original)"

  if [ "$kind" = app ]; then
    if stale_trust="$(classify_app_trust "$stale")"; then
      if [ "$stale_trust" = development ] && ! trusted_development_reference_matches "$stale"; then
        echo "error: prior staged development app no longer matches the trusted local build; preserving it" >&2
      fi
    else
      echo "error: prior staged app failed current identity/trust checks; preserving it" >&2
    fi
  fi
  die "prior uninstall staging requires manual recovery before continuing: $stale (dev:ino $stale_id; expected original: $original)"
}

# A SIGKILL or power loss after the same-volume staging rename cannot run traps.
# Preserve and surface every possible recovery copy rather than silently reporting
# "not installed". State parents are checked on every run, not only with --purge.
for app in "${TARGET_APPS[@]}"; do
  preflight_stale_stage "$app" app
done
preflight_stale_stage "$TARGET_HOME/.config/jbar" state
preflight_stale_stage "$TARGET_HOME/Library/Caches/com.linji.jbar" state
preflight_stale_stage "$TARGET_HOME/Library/Application Support/JBar" state

FOUND_APP=0
for app in "${TARGET_APPS[@]}"; do
  path_exists "$app" || continue
  FOUND_APP=1
  trust_kind="$(classify_app_trust "$app")" || die "installed app did not pass publisher/development trust checks"
  ensure_same_trash_device "$app"
  if [ "$trust_kind" = development ] &&
     [ "$SKIP_LOGIN_ITEM_CLEANUP" -ne 1 ] &&
     ! trusted_development_reference_matches "$app"; then
    die "development app does not match the trusted local build; rebuild it or rerun with --skip-login-item-cleanup after disabling it in System Settings > Login Items"
  fi
done

if [ "$FOUND_APP" -eq 0 ] && [ "$SKIP_LOGIN_ITEM_CLEANUP" -ne 1 ]; then
  die "no trusted canonical JBar.app is available to verify login-item cleanup; no application or data files were moved. Inspect System Settings > General > Login Items, or rerun with --skip-login-item-cleanup after handling it manually"
fi

if [ "$PURGE" -eq 1 ]; then
  ensure_same_trash_device "$TARGET_HOME/.config/jbar"
  ensure_same_trash_device "$TARGET_HOME/Library/Caches/com.linji.jbar"
  ensure_same_trash_device "$TARGET_HOME/Library/Application Support/JBar"
fi

# Stop and pin every trusted app only after all read-only trust/device preflights
# have succeeded. No app or user state has moved yet.
for app in "${TARGET_APPS[@]}"; do
  path_exists "$app" || continue
  executable="$app/Contents/MacOS/JBar"
  trust_before="$(classify_app_trust "$app")" || die "app trust changed before login-item cleanup"
  original_id="$(path_identity "$app")" || die "could not record installed app identity"
  if [ "$SKIP_PROCESS_CONTROL" -ne 1 ]; then
    stop_exact_app "$executable" || die "the exact installed JBar process did not stop"
  fi
  path_has_identity "$app" "$original_id" || die "installed app changed while its process was stopping"
  trust_after="$(classify_app_trust "$app")" || die "installed app failed trust revalidation after stopping"
  [ "$trust_after" = "$trust_before" ] || die "app trust identity changed while its process was stopping"
  if [ "$trust_after" = development ] &&
     [ "$SKIP_LOGIN_ITEM_CLEANUP" -ne 1 ] &&
     ! trusted_development_reference_matches "$app"; then
    die "installed development app no longer matches the trusted local build"
  fi
  APP_PATHS+=("$app")
  APP_IDS+=("$original_id")
  APP_TRUSTS+=("$trust_after")
done

# SMAppService.mainApp identifies the calling main application. Invoke it while
# the exact trusted bundle still occupies its canonical Applications path; Apple
# does not promise that a renamed or relocated Trash bundle represents the same
# service. The CLI returns zero only after observing `.notRegistered`.
if [ "$SKIP_LOGIN_ITEM_CLEANUP" -eq 1 ]; then
  if [ "${#APP_PATHS[@]}" -gt 0 ]; then
    echo "warning: login-item cleanup skipped explicitly; disable JBar in System Settings > Login Items if needed" >&2
  fi
else
  for ((index=0; index<${#APP_PATHS[@]}; index++)); do
    app="${APP_PATHS[$index]}"
    executable="$app/Contents/MacOS/JBar"
    path_has_identity "$app" "${APP_IDS[$index]}" ||
      die "installed app identity changed before login-item cleanup"
    current_trust="$(classify_app_trust "$app")" ||
      die "installed app failed final trust validation before login-item cleanup"
    [ "$current_trust" = "${APP_TRUSTS[$index]}" ] ||
      die "installed app trust identity changed before login-item cleanup"
    if [ "$current_trust" = development ]; then
      trusted_development_reference_matches "$app" ||
        die "installed development app no longer matches the trusted local build"
    fi

    # From this point a signal or API failure can leave the login item changed.
    # File moves remain independently rollback-safe, but registration is never
    # guessed or re-created because user approval cannot be restored exactly.
    LOGIN_ITEM_CLEANUP_STARTED=1
    maybe_fail before-unregister
    maybe_fail term-before-unregister
    "$executable" --unregister-login-item ||
      die "could not verify JBar login-item cleanup while the installed bundle remained in Applications"
    path_has_identity "$app" "${APP_IDS[$index]}" ||
      die "installed app identity changed during login-item cleanup"
    current_trust="$(classify_app_trust "$app")" ||
      die "installed app failed trust validation after login-item cleanup"
    [ "$current_trust" = "${APP_TRUSTS[$index]}" ] ||
      die "installed app trust identity changed during login-item cleanup"
    if [ "$current_trust" = development ]; then
      trusted_development_reference_matches "$app" ||
        die "installed development app changed during login-item cleanup"
    fi
  done
  if [ "${#APP_PATHS[@]}" -gt 0 ]; then
    LOGIN_ITEM_CLEANUP_CONFIRMED=1
    maybe_fail after-unregister
    maybe_fail term-after-unregister
  fi
fi

# Only now begin filesystem mutation. Every move remains inode-guarded and is
# rolled back on failure, even after login-item cleanup; the exit diagnostic
# explicitly states that such a rollback does not re-register the login item.
for ((index=0; index<${#APP_PATHS[@]}; index++)); do
  app="${APP_PATHS[$index]}"
  executable="$app/Contents/MacOS/JBar"
  if [ "$SKIP_LOGIN_ITEM_CLEANUP" -ne 1 ]; then
    LOGIN_ITEM_CLEANUP_CONFIRMED=0
  fi
  # Cleanup disables future login launches, but a user could have manually
  # relaunched JBar while another canonical candidate was being processed.
  # Re-stop the exact executable immediately before its bundle is renamed.
  if [ "$SKIP_PROCESS_CONTROL" -ne 1 ]; then
    stop_exact_app "$executable" || die "the exact installed JBar process restarted before staging and did not stop"
  fi
  path_has_identity "$app" "${APP_IDS[$index]}" ||
    die "installed app changed between login-item cleanup and staging"
  current_trust="$(classify_app_trust "$app")" || die "app trust changed before staging"
  [ "$current_trust" = "${APP_TRUSTS[$index]}" ] ||
    die "app trust identity changed before staging"
  if [ "$current_trust" = development ] && [ "$SKIP_LOGIN_ITEM_CLEANUP" -ne 1 ]; then
    trusted_development_reference_matches "$app" ||
      die "installed development app changed before staging"
  fi
  if [ "$SKIP_LOGIN_ITEM_CLEANUP" -ne 1 ]; then
    # A manual relaunch can apply the persisted launch-at-login preference after
    # the all-candidate confirmation pass. Re-establish and verify the terminal
    # state from this still-canonical bundle immediately before its atomic move.
    "$executable" --unregister-login-item ||
      die "could not re-verify JBar login-item cleanup immediately before staging"
    path_has_identity "$app" "${APP_IDS[$index]}" ||
      die "installed app identity changed during final login-item cleanup"
    current_trust="$(classify_app_trust "$app")" ||
      die "installed app failed trust validation after final login-item cleanup"
    [ "$current_trust" = "${APP_TRUSTS[$index]}" ] ||
      die "installed app trust identity changed during final login-item cleanup"
    if [ "$current_trust" = development ]; then
      trusted_development_reference_matches "$app" ||
        die "installed development app changed during final login-item cleanup"
    fi
    if is_running "$executable"; then
      die "the exact installed JBar process restarted after final login-item cleanup"
    fi
    LOGIN_ITEM_CLEANUP_CONFIRMED=1
  fi
  stage_item "$app" "JBar.app" "${APP_IDS[$index]}"
  staged_app="$CURRENT_STAGED"
  path_has_identity "$staged_app" "${APP_IDS[$index]}" ||
    die "installed app changed between validation and staging"
  staged_trust="$(classify_app_trust "$staged_app")" ||
    die "staged app failed immediate trust revalidation"
  [ "$staged_trust" = "${APP_TRUSTS[$index]}" ] ||
    die "app trust identity changed during uninstall"
  if [ "$staged_trust" = development ] && [ "$SKIP_LOGIN_ITEM_CLEANUP" -ne 1 ]; then
    trusted_development_reference_matches "$staged_app" ||
      die "staged development app no longer matches the trusted local build"
  fi
  maybe_inject_stage_substitution
  maybe_inject_trash_destination_race
  finish_current_trash
done

if [ "$PURGE" -eq 1 ]; then
  trash_item "$TARGET_HOME/.config/jbar" "JBar-config"
  trash_item "$TARGET_HOME/Library/Caches/com.linji.jbar" "JBar-cache"
  trash_item "$TARGET_HOME/Library/Application Support/JBar" "JBar-history"
  maybe_fail after-purge
  maybe_fail term-after-purge
fi

SUCCEEDED=1
if [ "$FOUND_APP" -eq 0 ]; then
  echo "JBar.app was not installed in the supported locations."
fi
if [ "$PURGE" -eq 0 ]; then echo "User config, cache, and history were kept."; fi
echo "Uninstall complete. Removed items remain recoverable in $TRASH_DIR until Trash is emptied."

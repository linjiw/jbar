#!/bin/bash
# DEVELOPMENT-ONLY source installer for JBar.
#
# This script builds the current checkout and installs that local build. It is
# intentionally not a public-release installer: it does not download a release,
# establish publisher trust, remove quarantine, notarize, or bypass Gatekeeper.
# Public distribution must use a separately verified Developer ID + notarized
# artifact.
#
# Usage: scripts/install.sh
#
# Test-only environment (requires JBAR_INSTALL_TEST_MODE=1):
#   JBAR_INSTALL_SOURCE_APP       prebuilt source JBar.app (build is skipped)
#   JBAR_INSTALL_DEST_DIR         isolated destination directory
#   JBAR_INSTALL_TEST_ROOT        owned mode-0700 root containing the destination
#   JBAR_INSTALL_SKIP_PROCESS_CONTROL=1
#   JBAR_INSTALL_SKIP_LAUNCH=1
#   JBAR_INSTALL_TEST_FAULT       named failure point used by the test harness
# Replacement policy:
#   JBAR_EXPECTED_TEAM_ID         required for an existing Developer ID-signed app
#   JBAR_INSTALL_LEGACY_REPLACE_ACK=I_UNDERSTAND_THIS_REPLACES_A_SIGNED_JBAR_APP
#                                one-time migration for a valid pre-provenance dev build
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEST_MODE="${JBAR_INSTALL_TEST_MODE:-0}"
TEST_FAULT="${JBAR_INSTALL_TEST_FAULT:-}"
SKIP_PROCESS_CONTROL="${JBAR_INSTALL_SKIP_PROCESS_CONTROL:-0}"
SKIP_LAUNCH="${JBAR_INSTALL_SKIP_LAUNCH:-0}"
EXPECTED_TEAM_ID="${JBAR_EXPECTED_TEAM_ID:-}"
LEGACY_REPLACE_ACK="${JBAR_INSTALL_LEGACY_REPLACE_ACK:-}"
LEGACY_REPLACE_CONFIRMATION="I_UNDERSTAND_THIS_REPLACES_A_SIGNED_JBAR_APP"
PROVENANCE_KEY="JBarBuildProvenance"
PROVENANCE_VALUE="scripts/build-app.sh:v1"

die() {
  echo "error: $*" >&2
  exit 1
}

path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

path_identity() {
  [ -e "$1" ] && [ ! -L "$1" ] || return 1
  /usr/bin/stat -f '%d:%i' "$1"
}

path_has_identity() {
  local actual
  actual="$(path_identity "$1" 2>/dev/null || true)"
  [ -n "$actual" ] && [ "$actual" = "$2" ]
}

# The destination's nonexistence check and activation are one kernel operation.
# This avoids `mv` nesting the staged app into a directory that won the race.
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

# Upgrade paths both exist on the destination volume. One RENAME_SWAP syscall
# moves the verified app into place and the old app into the private workspace.
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
  if [ "$TEST_MODE" -eq 1 ] && [ "$TEST_FAULT" = swap-failure ]; then
    echo "test: injecting atomic-swap failure" >&2
    return 97
  fi
  atomic_swap "$DEST" "$STAGED"
}

require_boolean() {
  case "$2" in
    0|1) ;;
    *) die "$1 must be 0 or 1" ;;
  esac
}

if [ "$#" -ne 0 ]; then
  die "this development installer takes no arguments"
fi
require_boolean JBAR_INSTALL_TEST_MODE "$TEST_MODE"
require_boolean JBAR_INSTALL_SKIP_PROCESS_CONTROL "$SKIP_PROCESS_CONTROL"
require_boolean JBAR_INSTALL_SKIP_LAUNCH "$SKIP_LAUNCH"

if [ -n "$EXPECTED_TEAM_ID" ] && [[ ! "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  die "JBAR_EXPECTED_TEAM_ID must be a 10-character Apple Team ID"
fi
case "$LEGACY_REPLACE_ACK" in
  ""|"$LEGACY_REPLACE_CONFIRMATION") ;;
  *) die "JBAR_INSTALL_LEGACY_REPLACE_ACK must equal '$LEGACY_REPLACE_CONFIRMATION'" ;;
esac
case "$TEST_FAULT" in
  ""|before-copy|after-copy|after-validation|after-stop|after-check-race|after-upgrade-check-mutation|swap-failure|before-swap|after-swap|before-activate-rename|after-activate-rename|after-activation-validation|launch|after-launch|term-after-swap|term-after-activate|workdir-replacement|workdir-missing) ;;
  *) die "unsupported JBAR_INSTALL_TEST_FAULT value '$TEST_FAULT'" ;;
esac

if [ "$TEST_MODE" -ne 1 ]; then
  if [ -n "${JBAR_INSTALL_SOURCE_APP:-}" ] ||
     [ -n "${JBAR_INSTALL_DEST_DIR:-}" ] ||
     [ -n "${JBAR_INSTALL_TEST_ROOT:-}" ] ||
     [ "$SKIP_PROCESS_CONTROL" -ne 0 ] ||
     [ "$SKIP_LAUNCH" -ne 0 ] ||
     [ -n "$TEST_FAULT" ]; then
    die "test overrides require JBAR_INSTALL_TEST_MODE=1"
  fi
fi

maybe_fail() {
  local point="$1"
  if [ "$TEST_MODE" -eq 1 ] && [ "$TEST_FAULT" = "$point" ]; then
    if [ "$point" = term-after-activate ] || [ "$point" = term-after-swap ]; then
      echo "test: sending TERM at '$point'" >&2
      /bin/kill -TERM "$$"
      return 143
    fi
    echo "test: injecting installer failure at '$point'" >&2
    return 97
  fi
}

maybe_inject_after_check_race() {
  [ "$TEST_MODE" -eq 1 ] && [ "$TEST_FAULT" = after-check-race ] || return 0
  /bin/mkdir "$DEST"
  printf 'unrelated raced destination\n' > "$DEST/DO-NOT-DELETE"
  echo "test: created a destination after the first-install absence check" >&2
}

maybe_inject_upgrade_mutation() {
  [ "$TEST_MODE" -eq 1 ] && [ "$TEST_FAULT" = after-upgrade-check-mutation ] || return 0
  printf 'changed after validation\n' > "$DEST/Contents/Resources/RACED-MUTATION"
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

validate_app_static() {
  local app="$1"
  local allow_permission_normalization="${2:-0}"
  local plist="$app/Contents/Info.plist"
  local executable="$app/Contents/MacOS/JBar"
  local pkginfo="$app/Contents/PkgInfo"
  local bundle_id
  local bundle_executable
  local package_type

  [ -d "$app" ] && [ ! -L "$app" ] || {
    echo "error: staged application is not a regular bundle directory: $app" >&2
    return 1
  }
  [ -f "$plist" ] && [ ! -L "$plist" ] || {
    echo "error: staged application has no regular Info.plist" >&2
    return 1
  }
  [ -f "$executable" ] && [ ! -L "$executable" ] && [ -x "$executable" ] || {
    echo "error: staged application has no executable Contents/MacOS/JBar" >&2
    return 1
  }
  [ -f "$pkginfo" ] && [ ! -L "$pkginfo" ] || {
    echo "error: staged application has no regular Contents/PkgInfo" >&2
    return 1
  }
  [ "$(/usr/bin/stat -f '%z' "$pkginfo")" = 8 ] &&
    [ "$(/bin/cat "$pkginfo")" = 'APPL????' ] || {
    echo "error: staged application has an invalid Contents/PkgInfo marker" >&2
    return 1
  }

  /usr/bin/plutil -lint "$plist" >/dev/null || {
    echo "error: staged Info.plist is invalid" >&2
    return 1
  }
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)" || {
    echo "error: staged Info.plist has no CFBundleIdentifier" >&2
    return 1
  }
  bundle_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null)" || {
    echo "error: staged Info.plist has no CFBundleExecutable" >&2
    return 1
  }
  package_type="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$plist" 2>/dev/null)" || {
    echo "error: staged Info.plist has no CFBundlePackageType" >&2
    return 1
  }
  [ "$bundle_id" = "com.linji.jbar" ] || {
    echo "error: unexpected bundle identifier '$bundle_id'" >&2
    return 1
  }
  [ "$bundle_executable" = "JBar" ] || {
    echo "error: unexpected bundle executable '$bundle_executable'" >&2
    return 1
  }
  [ "$package_type" = "APPL" ] || {
    echo "error: unexpected bundle package type '$package_type'" >&2
    return 1
  }
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" >/dev/null || {
    echo "error: staged application failed strict code-signature validation" >&2
    return 1
  }

  [ -z "$(/usr/bin/find "$app" ! -type d ! -type f -print -quit)" ] || {
    echo "error: application contains symbolic links or unsupported special files" >&2
    return 1
  }
  if [ "$allow_permission_normalization" -ne 1 ] && ! app_permissions_are_safe "$app"; then
    echo "error: application contains an ACL or group/world-write permission" >&2
    return 1
  fi
}

validate_source_app() {
  local app="$1"
  local executable="$app/Contents/MacOS/JBar"
  validate_app_static "$app" || return 1

  # This is a host-compatibility smoke test as well as an executable check. The
  # version command exits before NSApplication starts and does not crawl files.
  "$executable" --version >/dev/null 2>&1 || {
    echo "error: staged executable cannot run on this Mac" >&2
    return 1
  }
}

validate_replaceable_existing() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  local team_id
  local provenance
  local requirement

  validate_app_static "$app" || return 1
  team_id="$(signature_team_id "$app")"
  if [[ "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
    [ -n "$EXPECTED_TEAM_ID" ] && [ "$team_id" = "$EXPECTED_TEAM_ID" ] || {
      echo "error: existing Developer ID app belongs to unapproved Team '$team_id'" >&2
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
    echo "warning: replacing a valid legacy development build by explicit acknowledgement" >&2
    return 0
  fi
  echo "error: existing app is validly signed but has neither an approved Team ID nor JBar build provenance" >&2
  echo "error: move it aside manually, or set JBAR_INSTALL_LEGACY_REPLACE_ACK=$LEGACY_REPLACE_CONFIRMATION once" >&2
  return 1
}

# Print only PIDs whose executable path is exactly the destination binary. This
# deliberately avoids name-wide or command-line-regex process killing.
destination_pids() {
  local expected="$1"
  local pid
  local command_path

  while IFS= read -r pid; do
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    command_path="$(/bin/ps -ww -p "$pid" -o comm= 2>/dev/null || true)"
    command_path="${command_path#"${command_path%%[![:space:]]*}"}"
    command_path="${command_path%"${command_path##*[![:space:]]}"}"
    if [ "$command_path" = "$expected" ]; then
      printf '%s\n' "$pid"
    fi
  done < <(/usr/bin/pgrep -x JBar 2>/dev/null || true)
}

destination_is_running() {
  [ -n "$(destination_pids "$1")" ]
}

wait_until_stopped() {
  local executable="$1"
  local attempt=0
  while [ "$attempt" -lt 30 ]; do
    if ! destination_is_running "$executable"; then
      return 0
    fi
    /bin/sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}

stop_destination_app() {
  local executable="$1"
  local pid

  destination_is_running "$executable" || return 0

  # Ask only the NSRunningApplication at this exact executable path to quit.
  # Addressing the bundle identifier alone could terminate a different checkout.
  /usr/bin/osascript -l JavaScript - "$executable" >/dev/null 2>&1 <<'JXA' || true
ObjC.import('AppKit')
function run(argv) {
  const expected = argv[0]
  const applications = $.NSWorkspace.sharedWorkspace.runningApplications
  for (let index = 0; index < applications.count; index++) {
    const application = applications.objectAtIndex(index)
    const executableURL = application.executableURL
    if (executableURL && ObjC.unwrap(executableURL.path) === expected) {
      application.terminate
    }
  }
}
JXA
  wait_until_stopped "$executable" && return 0

  while IFS= read -r pid; do
    [ -n "$pid" ] && /bin/kill -TERM "$pid" 2>/dev/null || true
  done < <(destination_pids "$executable")
  wait_until_stopped "$executable" && return 0

  while IFS= read -r pid; do
    [ -n "$pid" ] && /bin/kill -KILL "$pid" 2>/dev/null || true
  done < <(destination_pids "$executable")
  wait_until_stopped "$executable" || {
    echo "error: the existing JBar process did not stop" >&2
    return 1
  }
}

SRC=""
if [ "$TEST_MODE" -eq 1 ]; then
  [ -n "${JBAR_INSTALL_SOURCE_APP:-}" ] || die "JBAR_INSTALL_SOURCE_APP is required in test mode"
  [ -n "${JBAR_INSTALL_DEST_DIR:-}" ] || die "JBAR_INSTALL_DEST_DIR is required in test mode"
  [ -n "${JBAR_INSTALL_TEST_ROOT:-}" ] || die "JBAR_INSTALL_TEST_ROOT is required in test mode"
  [ -d "$JBAR_INSTALL_TEST_ROOT" ] && [ ! -L "$JBAR_INSTALL_TEST_ROOT" ] ||
    die "JBAR_INSTALL_TEST_ROOT must be a regular directory"
  TEST_ROOT="$(cd "$JBAR_INSTALL_TEST_ROOT" && pwd -P)"
  [ "$(/usr/bin/stat -f '%u' "$TEST_ROOT")" = "$(/usr/bin/id -u)" ] ||
    die "JBAR_INSTALL_TEST_ROOT must be owned by the current user"
  [ "$(/usr/bin/stat -f '%Lp' "$TEST_ROOT")" = 700 ] ||
    die "JBAR_INSTALL_TEST_ROOT must have mode 0700"
  SRC="$JBAR_INSTALL_SOURCE_APP"
  DEST_DIR="$JBAR_INSTALL_DEST_DIR"
else
  echo "JBar development installer: building and installing this source checkout."
  echo "This path is not a notarized public-release installation."
  JBAR_BUILD_LEGACY_REPLACE_ACK="$LEGACY_REPLACE_ACK" \
    /bin/bash "$ROOT/scripts/build-app.sh" "$ROOT/build"
  SRC="$ROOT/build/JBar.app"

  DEST_DIR="/Applications"
  if [ ! -d "$DEST_DIR" ] || [ ! -w "$DEST_DIR" ]; then
    DEST_DIR="$HOME/Applications"
    /bin/mkdir -p "$DEST_DIR"
    echo "note: /Applications is not writable; installing to $DEST_DIR"
  fi
fi

[ -d "$SRC" ] && [ ! -L "$SRC" ] || die "source application is missing or unsafe: $SRC"
[ -d "$DEST_DIR" ] || die "destination directory does not exist: $DEST_DIR"
[ ! -L "$DEST_DIR" ] || die "destination directory must not be a symbolic link: $DEST_DIR"
[ -w "$DEST_DIR" ] || die "destination directory is not writable: $DEST_DIR"
DEST_DIR="$(cd "$DEST_DIR" && pwd -P)"
if [ "$TEST_MODE" -eq 1 ]; then
  case "$DEST_DIR/" in
    "$TEST_ROOT"/*) ;;
    *) die "test destination must be contained by JBAR_INSTALL_TEST_ROOT" ;;
  esac
fi
DEST="$DEST_DIR/JBar.app"
DEST_EXECUTABLE="$DEST/Contents/MacOS/JBar"
STALE_BACKUP="$(/usr/bin/find "$DEST_DIR" -mindepth 1 -maxdepth 1 -name '.jbar-install-backup.*.app' -print -quit)"
[ -z "$STALE_BACKUP" ] ||
  die "refusing to start while a prior installer backup needs manual recovery: $STALE_BACKUP"
STALE_TRANSACTION="$(/usr/bin/find "$DEST_DIR" -mindepth 1 -maxdepth 1 -name '.jbar-install.*' -print -quit)"
[ -z "$STALE_TRANSACTION" ] ||
  die "refusing to start while a prior installer transaction needs manual recovery: $STALE_TRANSACTION"

if [ -L "$DEST" ]; then
  die "refusing to replace a symbolic-link destination: $DEST"
fi
if path_exists "$DEST" && [ ! -d "$DEST" ]; then
  die "refusing to replace a non-directory destination: $DEST"
fi

WORK_DIR=""
WORK_DIR_ID=""
STAGED=""
FAILED=""
HAD_OLD=0
OLD_WAS_RUNNING=0
STOP_PHASE_STARTED=0
ACTIVATION_STARTED=0
INSTALL_SUCCEEDED=0
STAGED_ID=""
OLD_ID=""
OLD_READY_FOR_CLEANUP=0
PRESERVE_WORK_DIR=0
WORK_DIR_CLEANED=0

safe_cleanup_work_dir() {
  local cleanup_status=0
  [ "$WORK_DIR_CLEANED" -eq 0 ] || return 0
  [ -n "$WORK_DIR" ] || return 0
  [ -n "$WORK_DIR_ID" ] || {
    echo "error: installer transaction identity was not captured; preserving recovery state: $WORK_DIR" >&2
    return 1
  }
  if [ "$(dirname "$WORK_DIR")" != "$DEST_DIR" ] ||
     [[ "$(basename "$WORK_DIR")" != .jbar-install.* ]]; then
    echo "error: refusing unsafe temporary-path cleanup: $WORK_DIR" >&2
    return 1
  fi
  # Pin the directory as cwd and verify that inode before deleting only relative
  # descendants. A replaced absolute entry is therefore never traversed.
  (
    cd "$WORK_DIR" || exit 1
    [ "$(/usr/bin/stat -f '%d:%i' .)" = "$WORK_DIR_ID" ] || exit 1
    /usr/bin/find -x . -depth -mindepth 1 -delete
    [ "$(/usr/bin/stat -f '%d:%i' .)" = "$WORK_DIR_ID" ] || exit 1
  ) || cleanup_status=$?
  if [ "$cleanup_status" -ne 0 ]; then
    echo "error: installer transaction directory is missing, replaced, or could not be cleaned; preserving recovery state: $WORK_DIR" >&2
    return 1
  fi
  path_has_identity "$WORK_DIR" "$WORK_DIR_ID" || {
    echo "error: installer transaction entry changed after relative cleanup; refusing absolute removal: $WORK_DIR" >&2
    return 1
  }
  /bin/rmdir "$WORK_DIR" || return 1
  WORK_DIR_CLEANED=1
}

maybe_inject_workdir_cleanup_race() {
  local preserved
  case "$TEST_FAULT" in
    workdir-replacement|workdir-missing) ;;
    *) return 0 ;;
  esac
  preserved="${WORK_DIR}.race-original"
  /bin/mv "$WORK_DIR" "$preserved"
  if [ "$TEST_FAULT" = workdir-replacement ]; then
    /bin/mkdir "$WORK_DIR"
    printf 'unrelated replacement tree\n' > "$WORK_DIR/DO-NOT-DELETE"
  fi
  echo "test: changed the installer transaction entry before cleanup ($TEST_FAULT)" >&2
}

prepare_old_for_cleanup() {
  [ "$HAD_OLD" -eq 1 ] || return 0
  if [ "$OLD_READY_FOR_CLEANUP" -eq 1 ] && ! path_exists "$STAGED"; then
    return 0
  fi
  if path_has_identity "$DEST" "$STAGED_ID" &&
     path_has_identity "$STAGED" "$OLD_ID" &&
     validate_replaceable_existing "$STAGED"; then
    OLD_READY_FOR_CLEANUP=1
    return 0
  fi
  echo "error: refusing to clean a swapped old app whose identity or trust changed" >&2
  PRESERVE_WORK_DIR=1
  return 1
}

rollback_install() {
  local rollback_ok=1
  local old_at_destination=0

  echo "note: installation failed; restoring the previous JBar.app" >&2

  if [ "$SKIP_PROCESS_CONTROL" -ne 1 ] && [ "$ACTIVATION_STARTED" -eq 1 ] &&
     path_has_identity "$DEST" "$STAGED_ID"; then
    stop_destination_app "$DEST_EXECUTABLE" || rollback_ok=0
  fi

  if [ "$HAD_OLD" -eq 1 ] && [ "$ACTIVATION_STARTED" -eq 1 ]; then
    if path_has_identity "$DEST" "$STAGED_ID" && path_has_identity "$STAGED" "$OLD_ID"; then
      if atomic_swap "$DEST" "$STAGED" &&
         path_has_identity "$DEST" "$OLD_ID" &&
         path_has_identity "$STAGED" "$STAGED_ID"; then
        old_at_destination=1
      else
        echo "error: could not atomically swap the previous application back into place" >&2
        PRESERVE_WORK_DIR=1
        rollback_ok=0
      fi
    elif path_has_identity "$DEST" "$OLD_ID" && path_has_identity "$STAGED" "$STAGED_ID"; then
      old_at_destination=1
    else
      echo "error: installer swap paths changed outside the transaction; preserving the private workspace" >&2
      PRESERVE_WORK_DIR=1
      rollback_ok=0
    fi
  elif [ "$HAD_OLD" -eq 1 ] && path_has_identity "$DEST" "$OLD_ID"; then
    old_at_destination=1
  elif [ "$HAD_OLD" -eq 0 ] && [ "$ACTIVATION_STARTED" -eq 1 ] &&
       path_has_identity "$DEST" "$STAGED_ID"; then
    # A first install failed after activation; move it into the guarded work
    # directory so cleanup removes only the transaction's own files.
    if path_exists "$FAILED" || ! atomic_rename_no_replace "$DEST" "$FAILED"; then
      echo "error: could not remove the failed first installation" >&2
      rollback_ok=0
    fi
  fi

  if [ "$OLD_WAS_RUNNING" -eq 1 ] && [ "$old_at_destination" -eq 1 ] && [ "$SKIP_LAUNCH" -ne 1 ]; then
    /usr/bin/open "$DEST" >/dev/null 2>&1 || {
      echo "warning: the previous application was restored but could not be relaunched" >&2
      rollback_ok=0
    }
  fi

  [ "$rollback_ok" -eq 1 ]
}

handle_exit() {
  local status="$1"
  local cleanup_ok=1

  trap - EXIT INT TERM HUP
  set +e
  if [ "$status" -ne 0 ] && [ "$INSTALL_SUCCEEDED" -ne 1 ] && [ "$STOP_PHASE_STARTED" -eq 1 ]; then
    rollback_install || cleanup_ok=0
  fi

  if [ "$INSTALL_SUCCEEDED" -eq 1 ]; then prepare_old_for_cleanup || cleanup_ok=0; fi

  if [ "$PRESERVE_WORK_DIR" -eq 1 ] ||
     { [ "$HAD_OLD" -eq 1 ] && [ "$INSTALL_SUCCEEDED" -eq 1 ] && [ "$OLD_READY_FOR_CLEANUP" -ne 1 ]; }; then
    echo "error: preserving uncommitted installer swap state; transaction workspace: $WORK_DIR" >&2
    cleanup_ok=0
  else
    safe_cleanup_work_dir || cleanup_ok=0
  fi

  if [ "$cleanup_ok" -ne 1 ] && [ "$status" -eq 0 ]; then
    status=1
  fi
  exit "$status"
}

trap 'handle_exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

WORK_DIR="$(/usr/bin/mktemp -d "$DEST_DIR/.jbar-install.XXXXXXXX")"
[ "$(/usr/bin/stat -f '%u:%Lp' "$WORK_DIR")" = "$(/usr/bin/id -u):700" ] || {
  /bin/rmdir "$WORK_DIR" >/dev/null 2>&1 || true
  die "installer transaction directory is not current-user-owned mode 0700"
}
WORK_DIR_ID="$(path_identity "$WORK_DIR")" ||
  die "could not record installer transaction directory identity"
STAGED="$WORK_DIR/JBar.app.new"
FAILED="$WORK_DIR/JBar.app.failed"

[ "$(/usr/bin/stat -f '%d' "$WORK_DIR")" = "$(/usr/bin/stat -f '%d' "$DEST_DIR")" ] ||
  die "temporary staging directory is not on the destination volume"

maybe_fail before-copy
/usr/bin/ditto "$SRC" "$STAGED"
maybe_fail after-copy
# Validate type, identity, and signature before recursively changing metadata.
# ACLs and overly broad modes are accepted only in this isolated copy, then
# removed before the executable is run or the bundle can be activated.
validate_app_static "$STAGED" 1
normalize_app_permissions "$STAGED"
validate_source_app "$STAGED"
maybe_fail after-validation
STAGED_ID="$(path_identity "$STAGED")" || die "could not record staged application identity"

if path_exists "$DEST"; then
  validate_replaceable_existing "$DEST" ||
    die "refusing to replace an untrusted, unidentified, or unapproved existing JBar.app"
  HAD_OLD=1
  OLD_ID="$(path_identity "$DEST")" || die "could not record existing application identity"
  maybe_inject_upgrade_mutation
fi
if [ "$SKIP_PROCESS_CONTROL" -ne 1 ] && destination_is_running "$DEST_EXECUTABLE"; then
  OLD_WAS_RUNNING=1
fi

# No installed bundle or process is touched before all staged validation above
# has completed successfully.
STOP_PHASE_STARTED=1
if [ "$SKIP_PROCESS_CONTROL" -ne 1 ]; then
  stop_destination_app "$DEST_EXECUTABLE"
fi
maybe_fail after-stop

if [ "$HAD_OLD" -eq 1 ]; then
  maybe_fail before-swap
  maybe_fail before-activate-rename
  ACTIVATION_STARTED=1
  if ! path_has_identity "$DEST" "$OLD_ID" ||
     ! path_has_identity "$STAGED" "$STAGED_ID"; then
    die "installer upgrade paths changed before the atomic swap"
  fi
  perform_upgrade_swap || die "could not atomically swap the verified and existing applications"
  maybe_fail term-after-swap
  path_has_identity "$DEST" "$STAGED_ID" ||
    die "activated application identity changed during the atomic swap"
  path_has_identity "$STAGED" "$OLD_ID" ||
    die "displaced application identity changed during the atomic swap"
  validate_replaceable_existing "$STAGED" ||
    die "displaced application changed after validation; restoring it instead of deleting it"
  maybe_fail after-swap
else
  ACTIVATION_STARTED=1
  maybe_fail before-activate-rename
  maybe_inject_after_check_race
  atomic_rename_no_replace "$STAGED" "$DEST" ||
    die "could not exclusively activate the application; the destination appeared or changed"
fi
path_has_identity "$DEST" "$STAGED_ID" || die "activated application changed before final validation"
maybe_fail after-activate-rename
maybe_fail term-after-activate
validate_app_static "$DEST"
maybe_fail after-activation-validation

maybe_fail launch
if [ "$SKIP_LAUNCH" -ne 1 ]; then
  if ! /usr/bin/open "$DEST"; then
    echo "error: LaunchServices rejected the new application" >&2
    exit 1
  fi
fi
maybe_fail after-launch

if HOTKEY="$("$DEST_EXECUTABLE" --print-hotkey 2>/dev/null)" && [ -n "$HOTKEY" ]; then
  :
else
  HOTKEY='Option+Space'
fi
prepare_old_for_cleanup
INSTALL_SUCCEEDED=1
maybe_inject_workdir_cleanup_race
safe_cleanup_work_dir

cat <<EOF

  JBar development build installed -> $DEST
  Press ${HOTKEY} to open it (also available from the menu bar).
  Config:    ~/.config/jbar/config.json
  Uninstall: make uninstall   (or scripts/uninstall.sh)

  This source-install path preserves Gatekeeper metadata and does not establish
  public-release trust. First search may request Files and Folders permission
  for Desktop, Documents, or Downloads.
EOF

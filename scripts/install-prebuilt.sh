#!/bin/bash
# Install an already verified JBar.app without a compiler or package manager.
#
# This is the shared installer used by the GitHub and npm distribution paths.
# It intentionally accepts only a complete Universal 2 application bundle and
# never removes quarantine or replaces an existing app before the new bundle
# has passed validation.
set -Eeuo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install-prebuilt.sh /path/to/JBar.app [--no-launch]

Installs a verified Universal 2 JBar.app into /Applications or ~/Applications.
EOF
}

APP=""
NO_LAUNCH=0
TEST_MODE="${JBAR_PREBUILT_INSTALL_TEST_MODE:-0}"
TEST_DEST_DIR="${JBAR_PREBUILT_INSTALL_DEST_DIR:-}"
TEST_ROOT="${JBAR_PREBUILT_INSTALL_TEST_ROOT:-}"
for argument in "$@"; do
  case "$argument" in
    --no-launch) NO_LAUNCH=1 ;;
    --help|-h) usage; exit 0 ;;
    -*) die "unknown option: $argument" ;;
    "") die "application path is required" ;;
    *)
      [ -z "$APP" ] || die "only one application path may be provided"
      APP="$argument"
      ;;
  esac
done
[ -n "$APP" ] || { usage >&2; exit 2; }

case "$TEST_MODE" in
  0|1) ;;
  *) die "JBAR_PREBUILT_INSTALL_TEST_MODE must be 0 or 1" ;;
esac
if [ "$TEST_MODE" -eq 0 ] && { [ -n "$TEST_DEST_DIR" ] || [ -n "$TEST_ROOT" ]; }; then
  die "prebuilt installer test overrides require JBAR_PREBUILT_INSTALL_TEST_MODE=1"
fi

[ "$(uname -s)" = "Darwin" ] || die "JBar's prebuilt installer only supports macOS"
command -v codesign >/dev/null 2>&1 || die "codesign is unavailable on this Mac"
command -v ditto >/dev/null 2>&1 || die "ditto is unavailable on this Mac"
command -v lipo >/dev/null 2>&1 || die "lipo is unavailable on this Mac"
command -v open >/dev/null 2>&1 || die "open is unavailable on this Mac"

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$macos_major" =~ ^[0-9]+$ ]] && [ "$macos_major" -ge 13 ] ||
  die "JBar requires macOS 13 Ventura or later"

validate_app() {
  local app="$1"
  local binary="$app/Contents/MacOS/JBar"
  local plist="$app/Contents/Info.plist"
  local pkginfo="$app/Contents/PkgInfo"
  local archs
  local arch_count

  [ "$(basename "$app")" = "JBar.app" ] || return 1
  [ -d "$app" ] && [ ! -L "$app" ] || return 1
  [ -f "$binary" ] && [ ! -L "$binary" ] && [ -x "$binary" ] || return 1
  [ -f "$plist" ] && [ ! -L "$plist" ] || return 1
  [ -f "$pkginfo" ] && [ ! -L "$pkginfo" ] || return 1
  [ "$(cat "$pkginfo")" = "APPL????" ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = "com.linji.jbar" ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")" = "JBar" ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$plist")" = "APPL" ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" = "13.0" ] || return 1
  [ -z "$(find -x "$app" ! -type d ! -type f -print -quit)" ] || return 1

  archs="$(lipo -archs "$binary")" || return 1
  arch_count="$(wc -w <<< "$archs" | tr -d ' ')"
  [ "$arch_count" = "2" ] || return 1
  case " $archs " in *" arm64 "*) ;; *) return 1 ;; esac
  case " $archs " in *" x86_64 "*) ;; *) return 1 ;; esac
  codesign --verify --deep --strict "$app" >/dev/null 2>&1 || return 1
  "$binary" --version >/dev/null 2>&1 || return 1
}

validate_app "$APP" || die "the downloaded JBar.app failed bundle, architecture, signature, or runtime validation"

if [ "$TEST_MODE" -eq 1 ]; then
  [ -n "$TEST_DEST_DIR" ] || die "JBAR_PREBUILT_INSTALL_DEST_DIR is required in test mode"
  [ -n "$TEST_ROOT" ] || die "JBAR_PREBUILT_INSTALL_TEST_ROOT is required in test mode"
  [ -d "$TEST_ROOT" ] && [ ! -L "$TEST_ROOT" ] || die "test root must be a regular directory"
  [ "$(stat -f '%u:%Lp' "$TEST_ROOT")" = "$(id -u):700" ] || die "test root must be owned mode 0700"
  destination_dir="$TEST_DEST_DIR"
  [ -d "$destination_dir" ] && [ ! -L "$destination_dir" ] || die "test destination must be a regular directory"
  case "$destination_dir/" in
    "$TEST_ROOT"/*) ;;
    *) die "test destination must be contained by the test root" ;;
  esac
else
  destination_dir="/Applications"
  if [ ! -d "$destination_dir" ] || [ -L "$destination_dir" ] || [ ! -w "$destination_dir" ]; then
    destination_dir="$HOME/Applications"
    [ -e "$destination_dir" ] && [ ! -L "$destination_dir" ] || mkdir -p "$destination_dir"
  fi
fi
[ -d "$destination_dir" ] && [ ! -L "$destination_dir" ] && [ -w "$destination_dir" ] ||
  die "neither /Applications nor ~/Applications is writable"
destination_dir="$(cd "$destination_dir" && pwd -P)"

destination="$destination_dir/JBar.app"
if [ -L "$destination" ]; then
  die "refusing to replace a symbolic-link destination: $destination"
fi
if [ -e "$destination" ] && [ ! -d "$destination" ]; then
  die "refusing to replace a non-directory destination: $destination"
fi
if [ -d "$destination" ]; then
  validate_app "$destination" || die "refusing to replace an invalid existing JBar.app"
fi

work_dir="$(mktemp -d "$destination_dir/.jbar-install.XXXXXX")" || die "could not create a staging directory"
chmod 700 "$work_dir"
staged="$work_dir/JBar.app"
previous="$work_dir/JBar.previous.app"
failed="$work_dir/JBar.failed.app"
activated=0
had_previous=0
preserve_work_dir=0

cleanup() {
  local status="$1"
  trap - EXIT INT TERM HUP
  set +e

  if [ "$status" -ne 0 ]; then
    if [ "$had_previous" -eq 1 ] && [ -d "$previous" ]; then
      [ ! -e "$destination" ] || mv "$destination" "$failed" || preserve_work_dir=1
      [ "$preserve_work_dir" -eq 1 ] || mv "$previous" "$destination" || preserve_work_dir=1
    elif [ "$activated" -eq 1 ] && [ -d "$destination" ]; then
      mv "$destination" "$failed" || preserve_work_dir=1
    fi
  fi

  if [ "$preserve_work_dir" -eq 1 ]; then
    echo "error: preserving installer recovery state: $work_dir" >&2
  else
    rm -rf -- "$work_dir"
  fi
  exit "$status"
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

ditto "$APP" "$staged" || die "could not stage the application"
validate_app "$staged" || die "staged application failed validation"

if [ -d "$destination" ]; then
  # Ask the exact installed executable to quit before the bundle is swapped.
  # Failure to find a running instance is harmless; a process from another
  # checkout is never targeted by this path-based check.
  for pid in $(pgrep -x JBar 2>/dev/null || true); do
    command_path="$(ps -ww -p "$pid" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ "$command_path" = "$destination/Contents/MacOS/JBar" ]; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    still_running=0
    for pid in $(pgrep -x JBar 2>/dev/null || true); do
      command_path="$(ps -ww -p "$pid" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [ "$command_path" = "$destination/Contents/MacOS/JBar" ] && still_running=1
    done
    [ "$still_running" -eq 0 ] && break
    sleep 0.1
  done
  [ "$still_running" -eq 0 ] || die "the existing JBar process did not stop"

  had_previous=1
  mv "$destination" "$previous" || die "could not stage the existing JBar.app for replacement"
fi

mv "$staged" "$destination" || die "could not activate the new JBar.app"
activated=1
validate_app "$destination" || die "activated application failed final validation"

if [ "$NO_LAUNCH" -eq 0 ]; then
  if ! open "$destination" >/dev/null 2>&1; then
    echo "warning: JBar installed, but macOS did not launch it automatically" >&2
  fi
fi

echo "JBar installed to $destination"
echo "Press Option-Space to open it."

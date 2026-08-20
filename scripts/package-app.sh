#!/bin/bash
# Validate and package JBar.app without losing its wrapper, signature, or macOS metadata.
# Usage: scripts/package-app.sh path/to/JBar.app path/to/JBar-version-universal.zip
# Env: JBAR_EXPECT_ARCHS (default "arm64 x86_64"), JBAR_EXPECT_MIN_MACOS (must be "13.0")
#      JBAR_REQUIRE_DEVELOPER_ID=1 and JBAR_EXPECTED_TEAM_ID=<10-character Team ID>
#      opt into the public-signature requirement. The default remains suitable for the
#      credential-free, ad-hoc release candidate; an ad-hoc ZIP is never a public release.
set -Eeuo pipefail

umask 077

die() {
  echo "error: $*" >&2
  exit 1
}

path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

require_boolean() {
  case "$2" in
    0|1) ;;
    *) die "$1 must be 0 or 1" ;;
  esac
}

path_has_no_acl() {
  local path="$1"
  local listing
  local line_count
  listing="$(LC_ALL=C /bin/ls -lde -- "$path" 2>/dev/null)" || return 1
  line_count="$(printf '%s\n' "$listing" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  [ "$line_count" = 1 ] || return 1
  case "${listing%% *}" in
    *+*) return 1 ;;
  esac
}

capture_directory_identity() {
  local path="$1"
  path_has_no_acl "$path" || return 1
  /usr/bin/ruby - "$path" <<'RUBY'
path = ARGV.fetch(0)
stat = File.lstat(path)
raise "not an owned plain directory" unless
  stat.directory? && !stat.symlink? && stat.uid == Process.euid
raise "directory is writable by group or other" unless (stat.mode & 0o022).zero?
puts [stat.dev, stat.ino, stat.uid, stat.gid, format("%o", stat.mode & 0o7777)].join(":")
RUBY
}

verify_directory_identity() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(capture_directory_identity "$path" 2>/dev/null)" || return 1
  [ "$actual" = "$expected" ]
}

capture_publication_identity() {
  path_has_no_acl "$1" || return 1
  /usr/bin/ruby - "$1" <<'RUBY'
path = ARGV.fetch(0)
stat = File.lstat(path)
raise "not one owned regular file" unless
  stat.file? && !stat.symlink? && stat.uid == Process.euid && stat.nlink == 1 &&
    (stat.mode & 0o7777) == 0o644
puts [stat.dev, stat.ino, stat.uid].join(":")
RUBY
}

verify_publication_identity() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(capture_publication_identity "$path" 2>/dev/null)" || return 1
  [ "$actual" = "$expected" ]
}

verify_cleanup_candidate_identity() {
  local path="$1"
  local expected="$2"
  /usr/bin/ruby - "$path" "$expected" <<'RUBY'
path, expected = ARGV
stat = File.lstat(path)
actual = [stat.dev, stat.ino, stat.uid].join(":")
raise "not the transaction publication" unless
  stat.file? && !stat.symlink? && stat.uid == Process.euid && actual == expected
RUBY
}

validate_bundle_tree_safety() {
  local app="$1"
  local entry
  local owner
  local mode
  local links
  local expected_mode
  local current_uid
  local listing
  local line_count

  current_uid="$(/usr/bin/id -u)"
  while IFS= read -r -d '' entry; do
    case "$entry" in
      *$'\n'*|*$'\r'*)
        echo "error: application contains a newline in a bundle entry name" >&2
        return 1
        ;;
    esac
    [ ! -L "$entry" ] || {
      echo "error: application contains a symbolic link: $entry" >&2
      return 1
    }
    if [ -d "$entry" ]; then
      expected_mode=755
    elif [ -f "$entry" ]; then
      links="$(/usr/bin/stat -f '%l' "$entry")" || return 1
      [ "$links" = 1 ] || {
        echo "error: application contains a multiply-linked file: $entry" >&2
        return 1
      }
      if [ "$entry" = "$app/Contents/MacOS/JBar" ]; then
        expected_mode=755
      else
        expected_mode=644
      fi
    else
      echo "error: application contains an unsupported special file: $entry" >&2
      return 1
    fi

    owner="$(/usr/bin/stat -f '%u' "$entry")" || return 1
    [ "$owner" = "$current_uid" ] || {
      echo "error: application contains an entry not owned by the current user: $entry" >&2
      return 1
    }
    mode="$(/usr/bin/stat -f '%Lp' "$entry")" || return 1
    [ "$mode" = "$expected_mode" ] || {
      echo "error: unsafe application mode '$mode' (expected '$expected_mode'): $entry" >&2
      return 1
    }

    listing="$(LC_ALL=C /bin/ls -lde -- "$entry" 2>/dev/null)" || return 1
    line_count="$(printf '%s\n' "$listing" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    if [ "$line_count" != 1 ]; then
      echo "error: application contains an ACL: $entry" >&2
      return 1
    fi
    case "${listing%% *}" in
      *+*)
        echo "error: application contains an ACL: $entry" >&2
        return 1
        ;;
    esac
  done < <(/usr/bin/find -x "$app" -print0)
}

signature_team_id() {
  /usr/bin/codesign -d --verbose=4 "$1" 2>&1 |
    /usr/bin/awk -F= '$1 == "TeamIdentifier" { print $2; exit }'
}

validate_bundle() {
  local app="$1"
  local plist="$app/Contents/Info.plist"
  local executable="$app/Contents/MacOS/JBar"
  local pkginfo="$app/Contents/PkgInfo"
  local actual_archs
  local arch
  local min_os
  local version
  local team_id
  local requirement
  local current_uid

  [ "$(basename "$app")" = JBar.app ] || {
    echo "error: application wrapper must be named exactly JBar.app" >&2
    return 1
  }
  [ -d "$app" ] && [ ! -L "$app" ] || {
    echo "error: application is not a regular bundle directory: $app" >&2
    return 1
  }
  [ -f "$plist" ] && [ ! -L "$plist" ] || {
    echo "error: application is missing a regular Info.plist" >&2
    return 1
  }
  [ -f "$executable" ] && [ ! -L "$executable" ] && [ -x "$executable" ] || {
    echo "error: application is missing executable Contents/MacOS/JBar" >&2
    return 1
  }
  current_uid="$(/usr/bin/id -u)"
  [ -f "$pkginfo" ] && [ ! -L "$pkginfo" ] &&
    [ "$(/usr/bin/stat -f '%u:%Lp:%l:%z' "$pkginfo" 2>/dev/null)" = "$current_uid:644:1:8" ] &&
    [ "$(/bin/cat "$pkginfo")" = 'APPL????' ] || {
      echo "error: Contents/PkgInfo must be one owned mode-0644 file containing exact APPL????" >&2
      return 1
    }
  validate_bundle_tree_safety "$app" || return 1

  /usr/bin/plutil -lint "$plist" >/dev/null || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)" = \
    com.linji.jbar ] || { echo "error: unexpected bundle identifier" >&2; return 1; }
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null)" = \
    JBar ] || { echo "error: unexpected bundle executable" >&2; return 1; }
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$plist" 2>/dev/null)" = \
    APPL ] || { echo "error: unexpected bundle package type" >&2; return 1; }
  [ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null)" = \
    "$EXPECTED_MIN_MACOS" ] || {
      echo "error: Info.plist minimum macOS does not equal '$EXPECTED_MIN_MACOS'" >&2
      return 1
    }

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app" || return 1
  if [ "$REQUIRE_DEVELOPER_ID" = 1 ]; then
    team_id="$(signature_team_id "$app")"
    [ "$team_id" = "$EXPECTED_TEAM_ID" ] || {
      echo "error: signed application TeamIdentifier '$team_id' does not match '$EXPECTED_TEAM_ID'" >&2
      return 1
    }
    requirement="anchor apple generic and identifier \"com.linji.jbar\" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""
    /usr/bin/codesign --verify --deep --strict -R="$requirement" "$app" >/dev/null 2>&1 || {
      echo "error: application is not signed with the required Developer ID Application identity" >&2
      return 1
    }
  fi

  actual_archs="$(/usr/bin/lipo -archs "$executable")" || return 1
  for arch in "${EXPECTED_ARCHS[@]}"; do
    case " $actual_archs " in
      *" $arch "*) ;;
      *) echo "error: binary is missing '$arch' (found: $actual_archs)" >&2; return 1 ;;
    esac
    min_os="$(/usr/bin/xcrun vtool -show-build -arch "$arch" "$executable" |
      /usr/bin/awk '$1 == "minos" { print $2; exit }')"
    [ "$min_os" = "$EXPECTED_MIN_MACOS" ] || {
      echo "error: $arch minimum macOS is '$min_os', expected '$EXPECTED_MIN_MACOS'" >&2
      return 1
    }
  done

  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null)" || return 1
  [[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || {
    echo "error: invalid CFBundleShortVersionString '$version'" >&2
    return 1
  }
  [ "$("$executable" --version)" = "JBar $version" ] || {
    echo "error: binary and bundle versions disagree" >&2
    return 1
  }
}

validate_archive_entry_topology() {
  local listing="$1"
  local entry
  local saw_app_root=0

  while IFS= read -r entry; do
    case "$entry" in
      JBar.app/) saw_app_root=1 ;;
      JBar.app/*|__MACOSX/|__MACOSX/JBar.app/|__MACOSX/JBar.app/*) ;;
      *)
        echo "error: archive contains an entry outside exact JBar.app metadata topology: $entry" >&2
        return 1
        ;;
    esac
  done < "$listing"
  [ "$saw_app_root" -eq 1 ] || {
    echo "error: archive entry table is missing exact JBar.app/ root" >&2
    return 1
  }
}

maybe_inject_failure() {
  if [ "$TEST_MODE" = 1 ] && [ "$TEST_FAIL_AT" = "$1" ]; then
    case "$1" in
      term_after_archive|term_after_publish)
        echo "test: sending TERM at package point '$1'" >&2
        /bin/kill -TERM "$$"
        return 143
        ;;
    esac
    echo "error: injected package failure at $1" >&2
    return 97
  fi
}

safe_remove_published_output() {
  local path
  [ "$PUBLICATION_STARTED" -eq 1 ] || return 0
  if [ "$CWD_IS_WORK" -eq 1 ]; then
    verify_directory_identity . "$WORK_IDENTITY" || return 1
    verify_directory_identity .. "$PARENT_IDENTITY" || return 1
    path="../$OUTPUT_NAME"
  else
    verify_directory_identity . "$PARENT_IDENTITY" || return 1
    path="./$OUTPUT_NAME"
  fi
  if ! path_exists "$path"; then return 0; fi
  if ! verify_cleanup_candidate_identity "$path" "$PUBLICATION_IDENTITY" 2>/dev/null; then
    # A pre-existing or concurrently-created destination never belongs to this transaction.
    return 0
  fi
  /usr/bin/ruby - "$path" "$PUBLICATION_IDENTITY" <<'RUBY'
path, expected = ARGV
stat = File.lstat(path)
actual = [stat.dev, stat.ino, stat.uid].join(":")
raise "publication identity changed before cleanup" unless
  stat.file? && !stat.symlink? && stat.uid == Process.euid && actual == expected
File.unlink(path)
RUBY
  ! path_exists "$path"
}

safe_cleanup_work_dir() {
  if [ "$WORK_PENDING" -eq 1 ]; then
    [ "$CWD_IS_WORK" -eq 0 ] || return 1
    verify_directory_identity . "$PARENT_IDENTITY" || return 1
    [[ "$WORK_DIR" =~ ^\./\.jbar-package\.[A-Za-z0-9]{8}$ ]] || return 1
    /usr/bin/ruby - "$WORK_DIR" <<'RUBY'
path = ARGV.fetch(0)
stat = File.lstat(path)
raise "not the pending package stage" unless
  stat.directory? && !stat.symlink? && stat.uid == Process.euid
RUBY
    # No package operation runs before pending becomes active, so only an empty directory is eligible.
    /bin/rmdir -- "$WORK_DIR" || return 1
    [ ! -e "$WORK_DIR" ] && [ ! -L "$WORK_DIR" ] || return 1
    WORK_PENDING=0
    return 0
  fi
  [ "$WORK_ACTIVE" -eq 1 ] || return 0
  if [ "$CWD_IS_WORK" -eq 0 ]; then
    verify_directory_identity . "$PARENT_IDENTITY" || return 1
    verify_directory_identity "./$WORK_NAME" "$WORK_IDENTITY" || return 1
    /bin/rmdir -- "./$WORK_NAME" || return 1
    [ ! -e "./$WORK_NAME" ] && [ ! -L "./$WORK_NAME" ] || return 1
    WORK_ACTIVE=0
    return 0
  fi
  verify_directory_identity . "$WORK_IDENTITY" || return 1
  verify_directory_identity .. "$PARENT_IDENTITY" || return 1
  /usr/bin/find -x . -depth -mindepth 1 -delete || return 1
  verify_directory_identity . "$WORK_IDENTITY" || return 1
  cd .. || return 1
  CWD_IS_WORK=0
  verify_directory_identity . "$PARENT_IDENTITY" || return 1
  verify_directory_identity "./$WORK_NAME" "$WORK_IDENTITY" || return 1
  /bin/rmdir -- "./$WORK_NAME" || return 1
  [ ! -e "./$WORK_NAME" ] && [ ! -L "./$WORK_NAME" ] || return 1
  WORK_ACTIVE=0
}

handle_exit() {
  local status="$1"
  local cleanup_ok=1
  trap - EXIT INT TERM HUP
  set +e
  if [ "$status" -ne 0 ] && [ "$PACKAGE_SUCCEEDED" -ne 1 ]; then
    safe_remove_published_output || cleanup_ok=0
  fi
  safe_cleanup_work_dir || cleanup_ok=0
  if [ "$cleanup_ok" -ne 1 ] && [ "$status" -eq 0 ]; then status=1; fi
  exit "$status"
}

[ "$#" -eq 2 ] || die "usage: scripts/package-app.sh path/to/JBar.app output.zip"
APP="$1"
OUTPUT_INPUT="$2"
EXPECTED_ARCHS_INPUT="${JBAR_EXPECT_ARCHS:-arm64 x86_64}"
EXPECTED_MIN_MACOS="${JBAR_EXPECT_MIN_MACOS:-13.0}"
REQUIRE_DEVELOPER_ID="${JBAR_REQUIRE_DEVELOPER_ID:-0}"
EXPECTED_TEAM_ID="${JBAR_EXPECTED_TEAM_ID:-}"
TEST_MODE="${JBAR_PACKAGE_TEST_MODE:-0}"
TEST_FAIL_AT="${JBAR_PACKAGE_TEST_FAIL_AT:-}"
read -r -a EXPECTED_ARCHS <<< "$EXPECTED_ARCHS_INPUT"

WORK_ACTIVE=0
WORK_PENDING=0
CWD_IS_WORK=0
PUBLICATION_STARTED=0
PUBLICATION_IDENTITY=""
PACKAGE_SUCCEEDED=0
WORK_NAME=""
WORK_DIR=""
WORK_IDENTITY=""
PARENT_IDENTITY=""
trap 'handle_exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

require_boolean JBAR_REQUIRE_DEVELOPER_ID "$REQUIRE_DEVELOPER_ID"
require_boolean JBAR_PACKAGE_TEST_MODE "$TEST_MODE"
[[ "$EXPECTED_MIN_MACOS" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "invalid JBAR_EXPECT_MIN_MACOS"
[ "$EXPECTED_MIN_MACOS" = 13.0 ] || die "JBAR_EXPECT_MIN_MACOS must remain 13.0 for JBar releases"
[ "${#EXPECTED_ARCHS[@]}" -gt 0 ] || die "JBAR_EXPECT_ARCHS must not be empty"
for arch in "${EXPECTED_ARCHS[@]}"; do
  case "$arch" in arm64|x86_64) ;; *) die "unsupported expected architecture '$arch'" ;; esac
done
if [ "$REQUIRE_DEVELOPER_ID" = 1 ]; then
  [[ "$EXPECTED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] ||
    die "JBAR_EXPECTED_TEAM_ID must be a 10-character Team ID when Developer ID is required"
elif [ -n "$EXPECTED_TEAM_ID" ]; then
  die "JBAR_EXPECTED_TEAM_ID requires JBAR_REQUIRE_DEVELOPER_ID=1"
fi
[ -z "$TEST_FAIL_AT" ] || [ "$TEST_MODE" = 1 ] ||
  die "JBAR_PACKAGE_TEST_FAIL_AT is available only with JBAR_PACKAGE_TEST_MODE=1"
case "$TEST_FAIL_AT" in
  ""|before_stage_identity|after_stage_create|after_archive|after_extract|after_publish|term_after_archive|term_after_link|term_after_publish) ;;
  *) die "unsupported test failure point '$TEST_FAIL_AT'" ;;
esac

[ -d "$APP" ] && [ ! -L "$APP" ] || die "application is missing or is a symbolic link: $APP"
[ "$(basename "$APP")" = JBar.app ] || die "application wrapper must be named exactly JBar.app"
APP="$(cd "$(dirname "$APP")" && pwd -P)/JBar.app"
[ -z "$(/usr/bin/find -x "$APP" ! -type d ! -type f -print -quit)" ] ||
  die "application contains symbolic links or unsupported special files"
validate_bundle_tree_safety "$APP" || die "application source tree failed safety validation"

[[ "$OUTPUT_INPUT" == *.zip ]] || die "output must end in .zip"
OUTPUT_PARENT_INPUT="$(dirname "$OUTPUT_INPUT")"
[ -d "$OUTPUT_PARENT_INPUT" ] || die "output parent must already exist"
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT_INPUT" && pwd -P)"
OUTPUT_NAME="$(basename "$OUTPUT_INPUT")"
case "$OUTPUT_NAME" in *$'\n'*|*$'\r'*) die "output filename contains a newline" ;; esac
OUTPUT="$OUTPUT_PARENT/$OUTPUT_NAME"
case "$OUTPUT" in "$APP"|"$APP"/*) die "output must not be inside the signed application bundle" ;; esac
path_exists "$OUTPUT" && die "refusing to replace an existing output: $OUTPUT"

PARENT_IDENTITY="$(capture_directory_identity "$OUTPUT_PARENT")" ||
  die "output parent must be ACL-free, owned by the current user, and not group/other writable"
cd "$OUTPUT_PARENT"
verify_directory_identity . "$PARENT_IDENTITY" || die "output parent identity changed"
WORK_PENDING=1
WORK_DIR="$(/usr/bin/mktemp -d "./.jbar-package.XXXXXXXX")" ||
  die "could not create package staging directory"
/bin/chmod 0700 "$WORK_DIR"
maybe_inject_failure before_stage_identity
WORK_NAME="$(basename "$WORK_DIR")"
WORK_IDENTITY="$(capture_directory_identity "$WORK_DIR")" || die "unsafe package staging directory"
WORK_ACTIVE=1
WORK_PENDING=0
verify_directory_identity . "$PARENT_IDENTITY" ||
  die "output parent changed while creating package staging"
maybe_inject_failure after_stage_create
cd "$WORK_DIR"
verify_directory_identity . "$WORK_IDENTITY" || die "package staging identity changed"
verify_directory_identity .. "$PARENT_IDENTITY" || die "output parent identity changed"

CWD_IS_WORK=1

# Copy into the private transaction before trusting or executing any bundle content. All later
# validation and archive creation address this pinned working-directory object, not the caller's path.
/usr/bin/ditto --rsrc --extattr --qtn --noacl "$APP" ./JBar.app
validate_bundle ./JBar.app

/usr/bin/ditto -c -k --rsrc --extattr --qtn --noacl --sequesterRsrc --keepParent \
  ./JBar.app ./archive.zip
[ -s ./archive.zip ] || die "archive was not created"
/bin/chmod 0644 ./archive.zip
/usr/bin/zipinfo -1 ./archive.zip > ./archive.entries
[ -s ./archive.entries ] || die "archive entry table is empty"
validate_archive_entry_topology ./archive.entries
maybe_inject_failure after_archive
maybe_inject_failure term_after_archive

/bin/mkdir ./verify
/usr/bin/ditto -x -k --rsrc --extattr --qtn --noacl ./archive.zip ./verify
maybe_inject_failure after_extract
[ "$(/usr/bin/find ./verify -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 1 ] ||
  die "archive contains an unexpected top-level entry"
[ -d ./verify/JBar.app ] && [ ! -L ./verify/JBar.app ] ||
  die "archive does not contain exact top-level JBar.app"
validate_bundle ./verify/JBar.app

ARCHIVE_SHA256="$(/usr/bin/shasum -a 256 ./archive.zip | /usr/bin/cut -d ' ' -f 1)"
[[ "$ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "could not compute archive SHA-256"
PUBLICATION_IDENTITY="$(capture_publication_identity ./archive.zip)" || die "unsafe staged archive"
PUBLICATION_STARTED=1

# File.link is an exact, atomic no-clobber publication primitive: unlike mv, an existing directory
# is not treated as a container. Both paths are relative to pinned same-volume directory objects.
/usr/bin/ruby - ./archive.zip "../$OUTPUT_NAME" "$PUBLICATION_IDENTITY" \
  "$WORK_IDENTITY" "$PARENT_IDENTITY" "$TEST_MODE" "$TEST_FAIL_AT" <<'RUBY'
source, destination, expected_file, expected_work, expected_parent, test_mode, test_fail_at = ARGV

def directory_identity(path)
  stat = File.lstat(path)
  raise "not an owned plain directory" unless
    stat.directory? && !stat.symlink? && stat.uid == Process.euid && (stat.mode & 0o022).zero?
  [stat.dev, stat.ino, stat.uid, stat.gid, format("%o", stat.mode & 0o7777)].join(":")
end

raise "work identity changed before publication" unless directory_identity(".") == expected_work
raise "parent identity changed before publication" unless directory_identity("..") == expected_parent
source_stat = File.lstat(source)
source_identity = [source_stat.dev, source_stat.ino, source_stat.uid].join(":")
raise "staged archive identity changed" unless
  source_stat.file? && !source_stat.symlink? && source_stat.nlink == 1 &&
    source_identity == expected_file
begin
  File.lstat(destination)
  raise "refusing to replace an existing output"
rescue Errno::ENOENT
end

linked = false
begin
  File.link(source, destination)
  linked = true
  destination_stat = File.lstat(destination)
  raise "published archive identity mismatch" unless
    destination_stat.file? && !destination_stat.symlink? &&
      [destination_stat.dev, destination_stat.ino, destination_stat.uid].join(":") == expected_file
  if test_mode == "1" && test_fail_at == "term_after_link"
    warn "test: terminating package publication after link and before source unlink"
    exit!(143)
  end
  File.unlink(source)
  final_stat = File.lstat(destination)
  raise "published archive did not become a single-link file" unless
    final_stat.file? && !final_stat.symlink? && final_stat.nlink == 1 &&
      [final_stat.dev, final_stat.ino, final_stat.uid].join(":") == expected_file
rescue Exception
  if linked
    begin
      current = File.lstat(destination)
      current_identity = [current.dev, current.ino, current.uid].join(":")
      File.unlink(destination) if current.file? && !current.symlink? && current_identity == expected_file
    rescue Errno::ENOENT
    end
  end
  raise
end
RUBY

maybe_inject_failure after_publish
maybe_inject_failure term_after_publish
verify_publication_identity "../$OUTPUT_NAME" "$PUBLICATION_IDENTITY" ||
  die "published archive identity changed"
safe_cleanup_work_dir || die "could not safely remove package staging"
verify_directory_identity . "$PARENT_IDENTITY" || die "output parent identity changed after publication"
verify_publication_identity "./$OUTPUT_NAME" "$PUBLICATION_IDENTITY" ||
  die "published archive identity changed after cleanup"
[ "$(/usr/bin/shasum -a 256 "./$OUTPUT_NAME" | /usr/bin/cut -d ' ' -f 1)" = "$ARCHIVE_SHA256" ] ||
  die "published archive content changed after publication"
printf '%s  %s\n' "$ARCHIVE_SHA256" "$OUTPUT"
PACKAGE_SUCCEEDED=1

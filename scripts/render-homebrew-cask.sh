#!/bin/bash
# Render the Homebrew Cask shipped beside a notarized GitHub Release.
# Usage: scripts/render-homebrew-cask.sh VERSION SHA256 OUTPUT
# Test-only env: JBAR_CASK_TEST_MODE=1 and JBAR_CASK_TEST_FAIL_AT=<documented point>.
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

capture_regular_file_identity() {
  /usr/bin/ruby - "$1" "$2" <<'RUBY'
path, expected_mode = ARGV
stat = File.lstat(path)
raise "not one owned regular file" unless
  stat.file? && !stat.symlink? && stat.uid == Process.euid && stat.nlink == 1
raise "unexpected file mode" unless (stat.mode & 0o7777) == expected_mode.to_i(8)
puts [stat.dev, stat.ino, stat.uid].join(":")
RUBY
}

verify_regular_file_identity() {
  local path="$1"
  local expected_mode="$2"
  local expected_identity="$3"
  local actual
  actual="$(capture_regular_file_identity "$path" "$expected_mode" 2>/dev/null)" || return 1
  [ "$actual" = "$expected_identity" ]
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

maybe_inject_failure() {
  if [ "$TEST_MODE" = 1 ] && [ "$TEST_FAIL_AT" = "$1" ]; then
    case "$1" in
      term_after_render|term_after_publish)
        echo "test: sending TERM at Cask render point '$1'" >&2
        /bin/kill -TERM "$$"
        return 143
        ;;
    esac
    echo "error: injected Cask render failure at $1" >&2
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
    [[ "$WORK_DIR" =~ ^\./\.jbar-cask\.[A-Za-z0-9]{8}$ ]] || return 1
    /usr/bin/ruby - "$WORK_DIR" <<'RUBY'
path = ARGV.fetch(0)
stat = File.lstat(path)
raise "not the pending Cask stage" unless
  stat.directory? && !stat.symlink? && stat.uid == Process.euid
RUBY
    # No render operation runs before pending becomes active, so only an empty directory is eligible.
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
  if [ "$status" -ne 0 ] && [ "$RENDER_SUCCEEDED" -ne 1 ]; then
    safe_remove_published_output || cleanup_ok=0
  fi
  safe_cleanup_work_dir || cleanup_ok=0
  if [ "$cleanup_ok" -ne 1 ] && [ "$status" -eq 0 ]; then status=1; fi
  exit "$status"
}

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
TEMPLATE="$ROOT/packaging/homebrew/jbar.rb.template"
EXPECTED_TEMPLATE_SHA256=5e562653b06413d04ffbb2b119fdffb2b22e24c1e52c1ba8cd77092ddeca7634
WORK_ACTIVE=0
WORK_PENDING=0
CWD_IS_WORK=0
PUBLICATION_STARTED=0
PUBLICATION_IDENTITY=""
RENDER_SUCCEEDED=0
WORK_DIR=""
trap 'handle_exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

[ "$#" -eq 3 ] || die "usage: scripts/render-homebrew-cask.sh VERSION SHA256 OUTPUT"
VERSION="$1"
SHA256="$2"
OUTPUT_INPUT="$3"
TEST_MODE="${JBAR_CASK_TEST_MODE:-0}"
TEST_FAIL_AT="${JBAR_CASK_TEST_FAIL_AT:-}"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid version"
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || die "invalid SHA-256"
require_boolean JBAR_CASK_TEST_MODE "$TEST_MODE"
[ -z "$TEST_FAIL_AT" ] || [ "$TEST_MODE" = 1 ] ||
  die "JBAR_CASK_TEST_FAIL_AT is available only with JBAR_CASK_TEST_MODE=1"
case "$TEST_FAIL_AT" in
  ""|before_stage_identity|after_stage_create|after_render|after_publish|term_after_render|term_after_link|term_after_publish) ;;
  *) die "unsupported test failure point '$TEST_FAIL_AT'" ;;
esac

[ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || die "Cask template is not a regular file"
path_has_no_acl "$TEMPLATE" || die "Cask template must be ACL-free"
TEMPLATE_IDENTITY="$(capture_regular_file_identity "$TEMPLATE" 644)" ||
  die "Cask template must be one owned, mode-0644 regular file"

OUTPUT_PARENT_INPUT="$(dirname "$OUTPUT_INPUT")"
[ -d "$OUTPUT_PARENT_INPUT" ] || die "output parent must already exist"
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT_INPUT" && pwd -P)"
OUTPUT_NAME="$(basename "$OUTPUT_INPUT")"
[ "$OUTPUT_NAME" = jbar.rb ] || die "output filename must be exactly jbar.rb"
OUTPUT="$OUTPUT_PARENT/$OUTPUT_NAME"
path_exists "$OUTPUT" && die "refusing to replace an existing output: $OUTPUT"

cd "$OUTPUT_PARENT"
PARENT_IDENTITY="$(capture_directory_identity .)" ||
  die "output parent must be ACL-free, owned by the current user, and not group/other writable"
WORK_PENDING=1
WORK_DIR="$(/usr/bin/mktemp -d "./.jbar-cask.XXXXXXXX")" ||
  die "could not create Cask staging directory"
/bin/chmod 0700 "$WORK_DIR"
maybe_inject_failure before_stage_identity
WORK_NAME="$(basename "$WORK_DIR")"
WORK_IDENTITY="$(capture_directory_identity "$WORK_DIR")" ||
  die "unsafe Cask staging directory"
WORK_ACTIVE=1
WORK_PENDING=0
verify_directory_identity . "$PARENT_IDENTITY" ||
  die "output parent changed while creating Cask staging"
maybe_inject_failure after_stage_create
cd "$WORK_DIR"
CWD_IS_WORK=1
verify_directory_identity . "$WORK_IDENTITY" || die "Cask staging identity changed"
verify_directory_identity .. "$PARENT_IDENTITY" || die "output parent identity changed"

# Open both the trusted template and the new private-stage file with O_NOFOLLOW. File::EXCL ensures
# even a same-name object unexpectedly present in the stage is never followed or overwritten.
/usr/bin/ruby - "$TEMPLATE" "$TEMPLATE_IDENTITY" "$EXPECTED_TEMPLATE_SHA256" \
  "$VERSION" "$SHA256" <<'RUBY'
require "digest"
template_path, expected_template, expected_template_sha256, version, sha256 = ARGV
raise "Ruby does not expose O_NOFOLLOW" unless File.const_defined?(:NOFOLLOW)

identity = lambda do |stat|
  [stat.dev, stat.ino, stat.uid].join(":")
end
valid_template = lambda do |stat|
  stat.file? && !stat.symlink? && stat.uid == Process.euid && stat.nlink == 1 &&
    (stat.mode & 0o7777) == 0o644 && identity.call(stat) == expected_template
end

before = File.lstat(template_path)
raise "Cask template identity changed before read" unless valid_template.call(before)
template = nil
File.open(template_path, File::RDONLY | File::NOFOLLOW) do |input|
  opened = input.stat
  raise "opened Cask template identity mismatch" unless valid_template.call(opened)
  template = input.read
  after_read = input.stat
  raise "Cask template changed while read" unless
    identity.call(after_read) == expected_template && after_read.size == opened.size &&
      after_read.mtime == opened.mtime && after_read.ctime == opened.ctime
end
after = File.lstat(template_path)
raise "Cask template identity changed after read" unless valid_template.call(after)
raise "Cask template changed while read" unless
  before.size == after.size && before.mtime == after.mtime && before.ctime == after.ctime
raise "Cask template is not valid UTF-8" unless template.dup.force_encoding(Encoding::UTF_8).valid_encoding?
raise "Cask template contains NUL" if template.include?("\0")
raise "Cask template SHA-256 does not match the renderer provenance contract" unless
  Digest::SHA256.hexdigest(template) == expected_template_sha256
raise "Cask template must contain exactly one @VERSION@ placeholder" unless
  template.scan("@VERSION@").length == 1
raise "Cask template must contain exactly one @SHA256@ placeholder" unless
  template.scan("@SHA256@").length == 1

rendered = template.gsub("@VERSION@", version).gsub("@SHA256@", sha256)
raise "rendered Cask still contains a release placeholder" if rendered.match?(/@(VERSION|SHA256)@/)
raise "rendered Cask must end in one newline" unless rendered.end_with?("\n") && !rendered.end_with?("\n\n")

flags = File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW
File.open("./jbar.rb", flags, 0o600) do |output|
  written = output.write(rendered)
  raise "short Cask write" unless written == rendered.bytesize
  output.flush
  output.fsync
  output.chmod(0o644)
end
RUBY

path_has_no_acl ./jbar.rb || die "rendered Cask contains an ACL"
RENDER_IDENTITY="$(capture_regular_file_identity ./jbar.rb 644)" ||
  die "rendered Cask is not one owned, mode-0644 regular file"
CASK_SHA256="$(/usr/bin/shasum -a 256 ./jbar.rb | /usr/bin/cut -d ' ' -f 1)"
[[ "$CASK_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "could not compute rendered Cask SHA-256"
/usr/bin/ruby -c ./jbar.rb >/dev/null

exact_line_once() {
  local expected="$1"
  [ "$(/usr/bin/grep -Fxc -- "$expected" ./jbar.rb || true)" = 1 ]
}

exact_line_once 'cask "jbar" do' || die "rendered Cask has an invalid token stanza"
exact_line_once "  version \"$VERSION\"" || die "rendered Cask has an invalid version stanza"
exact_line_once "  sha256 \"$SHA256\"" || die "rendered Cask has an invalid SHA-256 stanza"
exact_line_once '  url "https://github.com/linjiw/jbar/releases/download/v#{version}/JBar-#{version}-universal.zip"' ||
  die "rendered Cask has an invalid URL stanza"
exact_line_once '  depends_on macos: :ventura' ||
  die "rendered Cask must require macOS Ventura with the current symbol syntax"
exact_line_once '  app "JBar.app"' || die "rendered Cask must install exact JBar.app"
[ "$(/usr/bin/grep -Ec '^[[:space:]]*uninstall([[:space:]]|$)' ./jbar.rb || true)" = 1 ] ||
  die "rendered Cask must contain exactly one uninstall stanza"
[ "$(/usr/bin/grep -Ec '^[[:space:]]*zap([[:space:]]|$)' ./jbar.rb || true)" = 1 ] ||
  die "rendered Cask must contain exactly one zap stanza"
if /usr/bin/grep -Eq '@(VERSION|SHA256)@' ./jbar.rb; then
  die "rendered Cask still contains a release placeholder"
fi
maybe_inject_failure after_render
maybe_inject_failure term_after_render

PUBLICATION_IDENTITY="$RENDER_IDENTITY"
PUBLICATION_STARTED=1

# A same-volume hard link is an atomic, exact no-clobber publication: unlike mv, a raced directory
# is not treated as a container, and an existing old output is never replaced.
/usr/bin/ruby - ./jbar.rb "../$OUTPUT_NAME" "$PUBLICATION_IDENTITY" \
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
raise "staged Cask identity changed" unless
  source_stat.file? && !source_stat.symlink? && source_stat.nlink == 1 &&
    (source_stat.mode & 0o7777) == 0o644 && source_identity == expected_file
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
  raise "published Cask identity mismatch" unless
    destination_stat.file? && !destination_stat.symlink? &&
      (destination_stat.mode & 0o7777) == 0o644 &&
      [destination_stat.dev, destination_stat.ino, destination_stat.uid].join(":") == expected_file
  if test_mode == "1" && test_fail_at == "term_after_link"
    warn "test: terminating Cask publication after link and before source unlink"
    exit!(143)
  end
  File.unlink(source)
  final_stat = File.lstat(destination)
  raise "published Cask did not become a single-link file" unless
    final_stat.file? && !final_stat.symlink? && final_stat.nlink == 1 &&
      (final_stat.mode & 0o7777) == 0o644 &&
      [final_stat.dev, final_stat.ino, final_stat.uid].join(":") == expected_file
rescue Exception
  if linked
    begin
      current = File.lstat(destination)
      current_identity = [current.dev, current.ino, current.uid].join(":")
      File.unlink(destination) if current.file? && !current.symlink? &&
        current_identity == expected_file
    rescue Errno::ENOENT
    end
  end
  raise
end
RUBY

maybe_inject_failure after_publish
maybe_inject_failure term_after_publish
verify_regular_file_identity "../$OUTPUT_NAME" 644 "$PUBLICATION_IDENTITY" ||
  die "published Cask identity changed"
safe_cleanup_work_dir || die "could not safely remove Cask staging"
verify_directory_identity . "$PARENT_IDENTITY" || die "output parent identity changed after publication"
verify_regular_file_identity "./$OUTPUT_NAME" 644 "$PUBLICATION_IDENTITY" ||
  die "published Cask identity changed after cleanup"
[ "$(/usr/bin/shasum -a 256 "./$OUTPUT_NAME" | /usr/bin/cut -d ' ' -f 1)" = "$CASK_SHA256" ] ||
  die "published Cask content changed after publication"
printf 'Rendered: %s\n' "$OUTPUT"
RENDER_SUCCEEDED=1

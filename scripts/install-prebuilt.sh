#!/bin/bash
# Install a reviewed Universal 2 JBar.app using only macOS system tools.
# Activation uses renamex_np's exclusive/atomic-swap operations. Failed or
# interrupted transactions preserve their recorded app identities for recovery.
set -Eeuo pipefail
umask 077

die() { echo "error: $*" >&2; exit 1; }
path_exists() { [ -e "$1" ] || [ -L "$1" ]; }
identity() {
  [ -e "$1" ] && [ ! -L "$1" ] || return 1
  /usr/bin/stat -f '%d:%i' "$1"
}
has_identity() {
  local actual
  actual="$(identity "$1" 2>/dev/null)" || return 1
  [ "$actual" = "$2" ]
}
usage() { echo "Usage: install-prebuilt.sh /path/to/JBar.app [--no-launch]"; }

# Inspect the central and local ZIP records before ditto can create any paths.
# Public JBar bundles use ordinary single-volume ZIPs with ASCII bundle names.
validate_archive() {
  /usr/bin/ruby - "$1" <<'RUBY'
file = ARGV.fetch(0)
require "zlib"
stat = File.lstat(file)
raise "archive must be one regular file, at most 100 MiB" unless
  stat.file? && !stat.symlink? && stat.nlink == 1 && stat.size.positive? && stat.size <= 104_857_600
data = File.binread(file)
minimum = [0, data.bytesize - 65_557].max
ending = nil
(data.bytesize - 22).downto(minimum) do |offset|
  next unless data.byteslice(offset, 4) == "PK\x05\x06".b
  next unless offset + 22 + data.byteslice(offset + 20, 2).unpack1("v") == data.bytesize
  ending = offset
  break
end
raise "missing ZIP end record" unless ending
disk, directory_disk, disk_count, count, size, offset = data.byteslice(ending + 4, 16).unpack("vvvvVV")
raise "unsupported ZIP disk/count/topology" unless
  disk.zero? && directory_disk.zero? && disk_count == count && count.positive? && count <= 4096 &&
    offset + size == ending

def check_extra(extra)
  cursor = 0
  while cursor < extra.bytesize
    raise "truncated ZIP extra field" unless cursor + 4 <= extra.bytesize
    kind, size = extra.byteslice(cursor, 4).unpack("vv")
    raise "ZIP path override/ZIP64 extra field" if [0x7075, 0x0001].include?(kind)
    cursor += 4 + size
    raise "truncated ZIP extra data" if cursor > extra.bytesize
  end
end

cursor = offset
names = {}
local_offsets = {}
expanded_bytes = 0
count.times do
  raise "invalid ZIP directory record" unless cursor + 46 <= ending && data.byteslice(cursor, 4) == "PK\x01\x02".b
  made_by, _needed, flags, method = data.byteslice(cursor + 4, 8).unpack("vvvv")
  compressed, expanded = data.byteslice(cursor + 20, 8).unpack("VV")
  name_size, extra_size, comment_size, entry_disk = data.byteslice(cursor + 28, 8).unpack("vvvv")
  attributes, local = data.byteslice(cursor + 38, 8).unpack("VV")
  ending_entry = cursor + 46 + name_size + extra_size + comment_size
  raise "invalid or encrypted ZIP entry" unless ending_entry <= ending && entry_disk.zero? && (flags & 1).zero? && [0, 8].include?(method)
  name = data.byteslice(cursor + 46, name_size)
  raise "invalid ZIP path encoding" unless name.ascii_only? && !name.empty? && !name.match?(/[\x00-\x1f\x7f\\]/)
  directory = name.end_with?("/")
  components = (directory ? name[0...-1] : name).split("/", -1)
  raise "unsafe ZIP path components" if components.any? { |part| ["", ".", ".."].include?(part) }
  raise "ZIP entry outside JBar.app topology" unless
    components[0] == "JBar.app" ||
      (components[0] == "__MACOSX" && (components.length == 1 || components[1] == "JBar.app"))
  mode = attributes >> 16
  type = mode & 0xf000
  raise "unsupported ZIP entry type" unless [3, 19].include?(made_by >> 8) &&
    (directory ? type == 0x4000 : type == 0x8000)
  key = components.join("/").downcase
  raise "duplicate ZIP entry" if names.key?(key)
  names[key] = directory
  components[0...-1].each_index do |index|
    parent = components[0..index].join("/").downcase
    raise "ZIP file/directory collision" if names.key?(parent) && !names[parent]
  end
  check_extra(data.byteslice(cursor + 46 + name_size, extra_size))
  raise "invalid ZIP local record" unless local + 30 <= offset && data.byteslice(local, 4) == "PK\x03\x04".b
  local_flags, local_method = data.byteslice(local + 6, 4).unpack("vv")
  local_name_size, local_extra_size = data.byteslice(local + 26, 4).unpack("vv")
  start = local + 30 + local_name_size + local_extra_size
  raise "ZIP local/directory mismatch" unless local_flags == flags && local_method == method &&
    data.byteslice(local + 30, local_name_size) == name && start + compressed <= offset &&
      !local_offsets.key?(local)
  check_extra(data.byteslice(local + 30 + local_name_size, local_extra_size))
  local_offsets[local] = true
  expanded_bytes += expanded
  raise "ZIP expands beyond 512 MiB" if expanded_bytes > 536_870_912
  # Check real output sizes incrementally, so a dishonest directory record
  # cannot turn a checksum-valid compressed payload into an extraction bomb.
  if method.zero?
    raise "ZIP stored size mismatch" unless compressed == expanded
  else
    inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
    begin
      actual = 0
      consumed = 0
      while consumed < compressed
        length = [16_384, compressed - consumed].min
        actual += inflater.inflate(data.byteslice(start + consumed, length)).bytesize
        raise "ZIP actual output exceeds declared limit" if actual > expanded
        consumed += length
      end
      actual += inflater.finish.bytesize
      raise "ZIP deflate size/stream mismatch" unless actual == expanded && inflater.total_in == compressed
    ensure
      inflater.close
    end
  end
  cursor = ending_entry
end
raise "ZIP entry count/size mismatch" unless cursor == ending
raise "missing exact JBar.app root" unless names["jbar.app"] == true
# A child seen before a colliding file must also be rejected.
names.each do |name, directory|
  next if directory
  raise "ZIP file/directory collision" if names.keys.any? { |other| other.start_with?(name + "/") }
end
RUBY
}
if [ "${1:-}" = --validate-archive ]; then
  [ "$#" = 2 ] || die "archive validation requires exactly one path"
  validate_archive "$2" || die "release archive failed pre-extraction safety validation"
  exit 0
fi

APP=""
NO_LAUNCH=0
TEST_MODE="${JBAR_PREBUILT_INSTALL_TEST_MODE:-0}"
TEST_DEST_DIR="${JBAR_PREBUILT_INSTALL_DEST_DIR:-}"
TEST_ROOT="${JBAR_PREBUILT_INSTALL_TEST_ROOT:-}"
TEST_FAULT="${JBAR_PREBUILT_INSTALL_TEST_FAULT:-}"
for argument in "$@"; do
  case "$argument" in
    --no-launch) NO_LAUNCH=1 ;;
    --help|-h) usage; exit 0 ;;
    -*) die "unknown option: $argument" ;;
    "") die "application path is required" ;;
    *) [ -z "$APP" ] || die "only one application path may be provided"; APP="$argument" ;;
  esac
done
[ -n "$APP" ] || { usage >&2; exit 2; }
case "$TEST_MODE" in 0|1) ;; *) die "JBAR_PREBUILT_INSTALL_TEST_MODE must be 0 or 1" ;; esac
if [ "$TEST_MODE" = 0 ] && { [ -n "$TEST_DEST_DIR" ] || [ -n "$TEST_ROOT" ] || [ -n "$TEST_FAULT" ]; }; then
  die "prebuilt installer test overrides require JBAR_PREBUILT_INSTALL_TEST_MODE=1"
fi
case "$TEST_FAULT" in
  ""|after-copy|after-activation|term-after-activation|kill-after-activation|first-install-race|upgrade-mutation|workdir-replacement) ;;
  *) die "unsupported prebuilt installer test fault" ;;
esac
[ "$(/usr/bin/uname -s)" = Darwin ] || die "JBar's prebuilt installer only supports macOS"
for tool in /usr/bin/codesign /usr/bin/ditto /usr/bin/lipo /usr/bin/open /usr/bin/ruby; do
  [ -x "$tool" ] || die "required macOS system tool is unavailable: $tool"
done
macos_major="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)"
[[ "$macos_major" =~ ^[0-9]+$ ]] && [ "$macos_major" -ge 13 ] || die "JBar requires macOS 13 or later"

# macOS supplies Ruby/Fiddle; no compiler, SDK, Homebrew, or downloaded helper is used.
native_rename() {
  /usr/bin/ruby - "$1" "$2" "$3" <<'RUBY'
require "fiddle/import"
module NativeFS
  extend Fiddle::Importer
  dlload "/usr/lib/libSystem.B.dylib"
  extern "int renamex_np(const char *, const char *, unsigned int)"
end
source, destination, operation = ARGV
flags = { "exclusive" => 4, "swap" => 2 }.fetch(operation)
if NativeFS.renamex_np(source, destination, flags) != 0
  raise SystemCallError.new("renamex_np", Fiddle.last_error)
end
RUBY
}

tree_is_safe() {
  /usr/bin/ruby - "$1" <<'RUBY' || return 1
require "find"
root = ARGV.fetch(0)
Find.find(root) do |path|
  stat = File.lstat(path)
  raise "unsafe bundle file type: #{path}" unless stat.directory? || (stat.file? && stat.nlink == 1)
  raise "writable bundle entry: #{path}" unless (stat.mode & 0o022).zero?
end
RUBY
  [ -z "$(/usr/bin/find -x "$1" -acl -print -quit)" ]
}
signature_team() {
  /usr/bin/codesign -dvv "$1" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p'
}
validate_app() {
  local app="$1" smoke="${2:-0}" binary plist archs version
  binary="$app/Contents/MacOS/JBar"
  plist="$app/Contents/Info.plist"
  [ -d "$app" ] && [ ! -L "$app" ] || return 1
  [ -f "$binary" ] && [ ! -L "$binary" ] && [ -x "$binary" ] || return 1
  [ -f "$plist" ] && [ ! -L "$plist" ] || return 1
  [ -f "$app/Contents/PkgInfo" ] && [ ! -L "$app/Contents/PkgInfo" ] || return 1
  [ "$(/usr/bin/stat -f '%z' "$app/Contents/PkgInfo")" = 8 ] || return 1
  [ "$(/bin/cat "$app/Contents/PkgInfo")" = 'APPL????' ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = com.linji.jbar ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")" = JBar ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$plist")" = APPL ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" = 13.0 ] || return 1
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" || return 1
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  tree_is_safe "$app" || return 1
  archs="$(/usr/bin/lipo -archs "$binary")" || return 1
  [ "$(/usr/bin/wc -w <<< "$archs" | /usr/bin/tr -d ' ')" = 2 ] || return 1
  case " $archs " in *" arm64 "*) ;; *) return 1 ;; esac
  case " $archs " in *" x86_64 "*) ;; *) return 1 ;; esac
  /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 || return 1
  if [ "$smoke" = 1 ]; then
    [ "$("$binary" --version)" = "JBar $version" ] || return 1
  fi
}
validate_existing() {
  validate_app "$1" || return 1
  local old_team new_team provenance requirement
  old_team="$(signature_team "$1")"
  if [[ "$old_team" =~ ^[A-Z0-9]{10}$ ]]; then
    new_team="$(signature_team "$STAGED")"
    [ "$new_team" = "$old_team" ] || {
      echo "error: refusing to replace a Developer ID app with a different signing team or an ad-hoc preview" >&2
      return 1
    }
    requirement="identifier \"com.linji.jbar\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$old_team\""
    /usr/bin/codesign --verify --deep --strict -R="$requirement" "$1" >/dev/null 2>&1 || return 1
    /usr/bin/codesign --verify --deep --strict -R="$requirement" "$STAGED" >/dev/null 2>&1 || return 1
  else
    provenance="$(/usr/libexec/PlistBuddy -c 'Print :JBarBuildProvenance' "$1/Contents/Info.plist" 2>/dev/null || true)"
    [ "$provenance" = scripts/build-app.sh:v1 ] || {
      echo "error: existing app lacks reviewed JBar build provenance; move it aside manually" >&2
      return 1
    }
  fi
}

[ -d "$APP" ] && [ ! -L "$APP" ] || die "application is missing or is a symbolic link"
APP="$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"
[ "$(basename "$APP")" = JBar.app ] || die "application wrapper must be named JBar.app"
if [ "$TEST_MODE" = 1 ]; then
  [ -n "$TEST_DEST_DIR" ] && [ -n "$TEST_ROOT" ] || die "prebuilt installer test root and destination are required"
  [ -d "$TEST_ROOT" ] && [ ! -L "$TEST_ROOT" ] || die "test root must be a regular directory"
  [ "$(/usr/bin/stat -f '%u:%Lp' "$TEST_ROOT")" = "$(/usr/bin/id -u):700" ] || die "test root must be owned mode 0700"
  TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
  destination_dir="$TEST_DEST_DIR"
else
  destination_dir=/Applications
  if [ ! -d "$destination_dir" ] || [ -L "$destination_dir" ] || [ ! -w "$destination_dir" ]; then
    destination_dir="$HOME/Applications"
    path_exists "$destination_dir" || /bin/mkdir -m 0755 "$destination_dir"
  fi
fi
[ -d "$destination_dir" ] && [ ! -L "$destination_dir" ] && [ -w "$destination_dir" ] || die "application destination is unavailable"
destination_dir="$(cd "$destination_dir" && pwd -P)"
if [ "$TEST_MODE" = 1 ]; then
  case "$destination_dir/" in "$TEST_ROOT"/*) ;; *) die "test destination must be contained by the physical test root" ;; esac
fi
# Pin all later relative operations to the destination directory object.
cd "$destination_dir"
PARENT_ID="$(identity .)"
DEST=./JBar.app
STALE="$(/usr/bin/find -x . -mindepth 1 -maxdepth 1 -name '.jbar-install.*' -print -quit)"
[ -z "$STALE" ] || die "prior installation needs manual recovery: $destination_dir/$STALE"
WORK="$(/usr/bin/mktemp -d ./.jbar-install.XXXXXXXX)"
[ "$(/usr/bin/stat -f '%u:%Lp' "$WORK")" = "$(/usr/bin/id -u):700" ] || die "unsafe installation staging directory"
WORK_ID="$(identity "$WORK")"
STAGED="$WORK/JBar.app"
STAGED_ID=""
OLD_ID=""
ACTIVATION_STARTED=0
SUCCEEDED=0
PRESERVE=0

cleanup_work() {
  has_identity . "$PARENT_ID" && has_identity "$WORK" "$WORK_ID" || return 1
  [ "$(/usr/bin/stat -f '%u:%Lp' "$WORK")" = "$(/usr/bin/id -u):700" ] || return 1
  cd "$WORK" || return 1
  has_identity . "$WORK_ID" && has_identity .. "$PARENT_ID" || return 1
  /usr/bin/find -x . -depth -mindepth 1 -delete || return 1
  has_identity . "$WORK_ID" && has_identity .. "$PARENT_ID" || return 1
  cd .. || return 1
  has_identity . "$PARENT_ID" && has_identity "$WORK" "$WORK_ID" || return 1
  /bin/rmdir -- "$WORK"
}
rollback() {
  [ "$ACTIVATION_STARTED" = 1 ] || return 0
  has_identity . "$PARENT_ID" && has_identity "$WORK" "$WORK_ID" || return 1
  if [ -n "$OLD_ID" ]; then
    if has_identity "$DEST" "$OLD_ID" && has_identity "$STAGED" "$STAGED_ID"; then return 0; fi
    has_identity "$DEST" "$STAGED_ID" && has_identity "$STAGED" "$OLD_ID" || return 1
    native_rename "$DEST" "$STAGED" swap || return 1
    has_identity "$DEST" "$OLD_ID" && has_identity "$STAGED" "$STAGED_ID"
  elif has_identity "$DEST" "$STAGED_ID"; then
    native_rename "$DEST" "$STAGED" exclusive || return 1
    has_identity "$STAGED" "$STAGED_ID"
  elif has_identity "$STAGED" "$STAGED_ID"; then
    # Exclusive activation failed because another destination won; never move it.
    return 0
  else
    return 1
  fi
}
finish() {
  local status="$1"
  trap - EXIT INT TERM HUP
  set +e
  if [ "$status" -ne 0 ] && [ "$SUCCEEDED" != 1 ]; then rollback || PRESERVE=1; fi
  if [ "$PRESERVE" = 0 ]; then cleanup_work || PRESERVE=1; fi
  if [ "$PRESERVE" = 1 ]; then
    echo "error: preserving installation recovery state: $destination_dir/$WORK" >&2
    [ "$status" -ne 0 ] || status=1
  fi
  exit "$status"
}
trap 'finish $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
fault() {
  [ "$TEST_MODE" = 1 ] && [ "$TEST_FAULT" = "$1" ] || return 0
  if [ "$1" = term-after-activation ]; then /bin/kill -TERM "$$"; fi
  if [ "$1" = kill-after-activation ]; then /bin/kill -KILL "$$"; fi
  die "injected prebuilt installer fault: $1"
}

# Trust and execute only the private copy, never an unpinned caller-owned source path.
/usr/bin/ditto --rsrc --extattr --qtn --noacl "$APP" "$STAGED" || die "could not stage the application"
validate_app "$STAGED" 1 || die "staged application failed bundle, permissions, architecture, signature, or runtime validation"
STAGED_ID="$(identity "$STAGED")"
fault after-copy
if path_exists "$DEST"; then
  validate_existing "$DEST" || die "refusing to replace an untrusted existing JBar.app"
  OLD_ID="$(identity "$DEST")"
  if [ "$TEST_MODE" != 1 ]; then
    for pid in $(/usr/bin/pgrep -x JBar 2>/dev/null || true); do
      command_path="$(/bin/ps -ww -p "$pid" -o comm= 2>/dev/null | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      if [ "$command_path" = "$destination_dir/JBar.app/Contents/MacOS/JBar" ]; then /bin/kill -TERM "$pid" 2>/dev/null || true; fi
    done
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      still_running=0
      for pid in $(/usr/bin/pgrep -x JBar 2>/dev/null || true); do
        command_path="$(/bin/ps -ww -p "$pid" -o comm= 2>/dev/null | /usr/bin/sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ "$command_path" != "$destination_dir/JBar.app/Contents/MacOS/JBar" ] || still_running=1
      done
      [ "$still_running" = 0 ] && break
      /bin/sleep 0.1
    done
    [ "$still_running" = 0 ] || die "the existing JBar process did not stop"
  fi
  if [ "$TEST_MODE" = 1 ] && [ "$TEST_FAULT" = upgrade-mutation ]; then
    /bin/mv "$DEST" ./preserved-existing-app
    /bin/mkdir "$DEST"
    echo unrelated > "$DEST/unrelated-data"
  fi
  has_identity "$DEST" "$OLD_ID" && has_identity "$STAGED" "$STAGED_ID" || die "upgrade identities changed before activation"
  ACTIVATION_STARTED=1
  native_rename "$DEST" "$STAGED" swap || die "could not atomically activate the application"
  has_identity "$DEST" "$STAGED_ID" && has_identity "$STAGED" "$OLD_ID" || die "upgrade identities changed during activation"
  # Do not erase a changed displaced application during cleanup.
  validate_existing "$STAGED" || die "displaced application changed; restoring it"
else
  if [ "$TEST_MODE" = 1 ] && [ "$TEST_FAULT" = first-install-race ]; then
    /bin/mkdir "$DEST"
    echo unrelated > "$DEST/unrelated-data"
  fi
  ACTIVATION_STARTED=1
  native_rename "$STAGED" "$DEST" exclusive || die "exclusive activation failed; destination appeared or changed"
  has_identity "$DEST" "$STAGED_ID" || die "activated application identity changed"
fi
fault after-activation
fault term-after-activation
fault kill-after-activation
validate_app "$DEST" || die "activated application failed final validation"
SUCCEEDED=1
if [ "$TEST_MODE" = 1 ] && [ "$TEST_FAULT" = workdir-replacement ]; then
  /bin/mv "$WORK" ./preserved-workdir
  /bin/mkdir -m 0700 "$WORK"
  echo unrelated > "$WORK/unrelated-data"
fi
cleanup_work || { PRESERVE=1; die "installation staging identity changed; recovery state was preserved"; }
trap - EXIT INT TERM HUP
if [ "$NO_LAUNCH" = 0 ] && ! /usr/bin/open "$destination_dir/JBar.app" >/dev/null 2>&1; then
  echo "warning: JBar installed, but macOS did not launch it automatically" >&2
fi
echo "JBar installed to $destination_dir/JBar.app"
echo "Press Option-Space to open it."

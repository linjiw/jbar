#!/bin/bash
# Collect reproducible, per-process release benchmark evidence. Correctness is gated independently;
# absolute latency remains observational because unrelated/shared machines are not an SLA instrument.
set -euo pipefail

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
REPORT_GATE="$REPO_DIR/scripts/tests/benchmark-report-gate.rb"
MAX_SAMPLES=10000
MAX_ITEMS=2000000
MAX_PROCESSES=20

usage() {
    echo "usage: $0 [positive-sample-count]" >&2
    echo "       $0 --self-test" >&2
}

die_usage() {
    echo "error: $*" >&2
    usage
    exit 2
}

is_decimal_in_range() {
    local value="$1"
    local minimum="$2"
    local maximum="$3"
    case "$value" in
        ''|*[!0-9]*) return 1 ;;
        0|0*) [ "$value" = "0" ] || return 1 ;;
    esac
    [ "$value" -ge "$minimum" ] 2>/dev/null && [ "$value" -le "$maximum" ] 2>/dev/null
}

normalize_fixture_sizes() {
    local raw="$1"
    local token=""
    local normalized=""
    local seen=" "
    local count=0
    local old_ifs="$IFS"

    [ -n "$raw" ] || return 1
    [[ "$raw" =~ ^[[:space:]0-9]+$ ]] || return 1
    set -f
    IFS=$' \t\n'
    for token in $raw; do
        if ! is_decimal_in_range "$token" 1 "$MAX_ITEMS"; then
            IFS="$old_ifs"
            set +f
            return 1
        fi
        case "$seen" in
            *" $token "*)
                IFS="$old_ifs"
                set +f
                return 1
                ;;
        esac
        seen="${seen}${token} "
        if [ -z "$normalized" ]; then
            normalized="$token"
        else
            normalized="$normalized $token"
        fi
        count=$((count + 1))
    done
    IFS="$old_ifs"
    set +f
    [ "$count" -gt 0 ] || return 1
    printf '%s\n' "$normalized"
}

path_has_no_acl() {
    local path="$1"
    local listing=""
    local line_count=""
    listing="$(LC_ALL=C /bin/ls -lde -- "$path" 2>/dev/null)" || return 1
    line_count="$(printf '%s\n' "$listing" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    [ "$line_count" = "1" ] || return 1
    case "${listing%% *}" in
        *+*) return 1 ;;
    esac
    return 0
}

path_ancestors_have_no_acl() {
    local path="$1"
    local component=""
    local cursor="/"
    local old_ifs="$IFS"
    local glob_was_disabled=0
    case "$-" in *f*) glob_was_disabled=1 ;; esac
    path_has_no_acl / || return 1
    set -f
    IFS=/
    for component in ${path#/}; do
        [ -n "$component" ] || continue
        if [ "$cursor" = "/" ]; then
            cursor="/$component"
        else
            cursor="$cursor/$component"
        fi
        if ! path_has_no_acl "$cursor"; then
            IFS="$old_ifs"
            [ "$glob_was_disabled" -eq 1 ] || set +f
            return 1
        fi
    done
    IFS="$old_ifs"
    [ "$glob_was_disabled" -eq 1 ] || set +f
    return 0
}

capture_directory_identity() {
    local path="$1"
    path_has_no_acl "$path" || return 1
    /usr/bin/ruby - "$path" <<'RUBY'
path = ARGV.fetch(0)
stat = File.lstat(path)
raise "not a plain directory" unless stat.directory? && !stat.symlink?
puts [stat.dev, stat.ino, stat.uid, stat.gid, format("%o", stat.mode & 0o7777)].join(":")
RUBY
}

verify_directory_identity() {
    local path="$1"
    local expected="$2"
    local actual=""
    actual="$(capture_directory_identity "$path" 2>/dev/null)" || return 1
    [ "$actual" = "$expected" ]
}

canonical_parent() {
    local requested="$1"
    local canonical=""
    [ -n "$requested" ] && [ "${#requested}" -le 1024 ] || return 1
    case "$requested" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$requested" in
        *$'\n'*|*$'\r'*) return 1 ;;
    esac
    canonical="$(/usr/bin/ruby - "$requested" <<'RUBY'
raw = ARGV.fetch(0)
raise "unsafe parent path" if raw.empty? || raw.bytesize > 1024 || raw.include?("\0") ||
  raw.include?("\n") || raw.include?("\r") || !raw.start_with?("/")
trimmed = raw.sub(%r{/+\z}, "")
trimmed = "/" if trimmed.empty?
expanded = File.expand_path(raw)
raise "non-canonical parent path" unless trimmed == expanded
raise "root is not an allowed parent" if expanded == "/"

cursor = "/"
root_stat = File.lstat(cursor)
raise "unsafe root directory identity" unless root_stat.directory? && !root_stat.symlink? && root_stat.uid.zero?
raise "unsafe writable root directory" unless (root_stat.mode & 0o022).zero?
expanded.split("/").reject(&:empty?).each do |component|
  cursor = cursor == "/" ? "/#{component}" : "#{cursor}/#{component}"
  stat = File.lstat(cursor)
  raise "symbolic-link parent component" if stat.symlink?
  raise "non-directory parent component" unless stat.directory?
  raise "untrusted parent-component owner" unless stat.uid.zero? || stat.uid == Process.euid
  if (stat.mode & 0o022) != 0
    system_tmp_edge = cursor == "/private/tmp" && stat.uid.zero? && (stat.mode & 0o7777) == 0o1777
    raise "replaceable parent component" unless system_tmp_edge
  end
end
raise "parent realpath drift" unless File.realpath(expanded) == expanded

stat = File.lstat(expanded)
mode = stat.mode & 0o7777
private_owner = stat.uid == Process.euid && (mode & 0o022).zero?
system_tmp = expanded == "/private/tmp" && stat.uid.zero? && mode == 0o1777
raise "unsafe shared parent permissions" unless private_owner || system_tmp
raise "parent is not writable and searchable" unless File.writable?(expanded) && File.executable?(expanded)
puts expanded
RUBY
)" || return 1
    path_ancestors_have_no_acl "$canonical" || return 1
    printf '%s\n' "$canonical"
}

verify_parent_identity() {
    local path="$1"
    local expected="$2"
    local canonical=""
    canonical="$(canonical_parent "$path" 2>/dev/null)" || return 1
    [ "$canonical" = "$path" ] || return 1
    verify_directory_identity "$path" "$expected"
}

self_test() {
    is_decimal_in_range 1 1 10000 || return 1
    is_decimal_in_range 10000 1 10000 || return 1
    ! is_decimal_in_range 0 1 10000 || return 1
    ! is_decimal_in_range 01 1 10000 || return 1
    ! is_decimal_in_range '1+1' 1 10000 || return 1
    [ "$(normalize_fixture_sizes '300000 500000 1000000')" = \
      "300000 500000 1000000" ] || return 1
    [ "$(normalize_fixture_sizes $'10000\t20000')" = "10000 20000" ] || return 1
    ! normalize_fixture_sizes '300000 300000' >/dev/null 2>&1 || return 1
    ! normalize_fixture_sizes '10000;id' >/dev/null 2>&1 || return 1
    ! normalize_fixture_sizes '2000001' >/dev/null 2>&1 || return 1
    [ "$(canonical_parent /private/tmp)" = "/private/tmp" ] || return 1
    ! canonical_parent / >/dev/null 2>&1 || return 1
    echo "PASS: benchmark release harness argument and safe-path self-test"
}

if [ "$#" -eq 1 ] && [ "$1" = "--self-test" ]; then
    self_test
    exit 0
fi

INTERNAL_TEST_MODE=0
INTERNAL_TEST_SCENARIO=""
if [ "$#" -eq 2 ] && [ "$1" = "--internal-self-test" ]; then
    [ "${JBAR_BENCHMARK_INTERNAL_SELF_TEST:-0}" = "1" ] ||
        die_usage "internal self-tests require JBAR_BENCHMARK_INTERNAL_SELF_TEST=1"
    INTERNAL_TEST_MODE=1
    INTERNAL_TEST_SCENARIO="$2"
    SAMPLES=1
elif [ "$#" -le 1 ]; then
    SAMPLES="${1:-100}"
else
    die_usage "too many arguments"
fi

is_decimal_in_range "$SAMPLES" 1 "$MAX_SAMPLES" ||
    die_usage "sample count must be an integer in 1...$MAX_SAMPLES without leading zeroes"

PROCESSES="${JBAR_BENCHMARK_PROCESSES:-3}"
REAL_PROCESSES="${JBAR_BENCHMARK_REAL_PROCESSES:-1}"
INCLUDE_REAL="${JBAR_BENCHMARK_INCLUDE_REAL:-0}"
is_decimal_in_range "$PROCESSES" 1 "$MAX_PROCESSES" ||
    die_usage "JBAR_BENCHMARK_PROCESSES must be in 1...$MAX_PROCESSES"
is_decimal_in_range "$REAL_PROCESSES" 1 "$MAX_PROCESSES" ||
    die_usage "JBAR_BENCHMARK_REAL_PROCESSES must be in 1...$MAX_PROCESSES"
case "$INCLUDE_REAL" in
    0|1) ;;
    *) die_usage "JBAR_BENCHMARK_INCLUDE_REAL must be exactly 0 or 1" ;;
esac

RAW_FIXTURE_SIZES="${JBAR_BENCHMARK_SYNTHETIC_SIZES:-300000 500000 1000000}"
FIXTURE_SIZES="$(normalize_fixture_sizes "$RAW_FIXTURE_SIZES")" ||
    die_usage "JBAR_BENCHMARK_SYNTHETIC_SIZES must be a unique whitespace-separated list in 1...$MAX_ITEMS"

if [ ! -f "$REPORT_GATE" ] || [ -L "$REPORT_GATE" ]; then
    echo "error: benchmark report gate is missing or is a symbolic link: $REPORT_GATE" >&2
    exit 1
fi
if [ ! -f "$REPO_DIR/Package.swift" ] || [ -L "$REPO_DIR/Package.swift" ]; then
    echo "error: Package.swift is missing or is a symbolic link" >&2
    exit 1
fi

DEFAULT_PARENT=/private/tmp
[ -d "$DEFAULT_PARENT" ] || DEFAULT_PARENT=/tmp
EVIDENCE_PARENT="$(canonical_parent "${JBAR_BENCHMARK_EVIDENCE_PARENT:-$DEFAULT_PARENT}")" ||
    die_usage "JBAR_BENCHMARK_EVIDENCE_PARENT must be canonical, symlink-free, ACL-free, and either private to the current UID or /private/tmp"
BUILD_PARENT="$(canonical_parent "${JBAR_BENCHMARK_BUILD_PARENT:-$EVIDENCE_PARENT}")" ||
    die_usage "JBAR_BENCHMARK_BUILD_PARENT must be canonical, symlink-free, ACL-free, and either private to the current UID or /private/tmp"
EVIDENCE_PARENT_IDENTITY="$(capture_directory_identity "$EVIDENCE_PARENT")" ||
    die_usage "could not capture the evidence-parent identity"
BUILD_PARENT_IDENTITY="$(capture_directory_identity "$BUILD_PARENT")" ||
    die_usage "could not capture the build-parent identity"

EVIDENCE_DIR="$(/usr/bin/mktemp -d "$EVIDENCE_PARENT/jbar-benchmark-evidence.XXXXXXXX")" || {
    echo "error: could not create the benchmark evidence directory" >&2
    exit 1
}
/bin/chmod 0700 "$EVIDENCE_DIR"
EVIDENCE_DIR="$(cd "$EVIDENCE_DIR" && pwd -P)"
case "$EVIDENCE_DIR" in
    "$EVIDENCE_PARENT"/jbar-benchmark-evidence.*) ;;
    *) echo "error: mktemp returned an unsafe evidence directory" >&2; exit 1 ;;
esac
verify_parent_identity "$EVIDENCE_PARENT" "$EVIDENCE_PARENT_IDENTITY" || {
    echo "error: evidence parent changed while creating the evidence directory" >&2
    exit 1
}
EVIDENCE_DIR_IDENTITY="$(capture_directory_identity "$EVIDENCE_DIR")" || {
    echo "error: evidence directory identity or mode is unsafe: $EVIDENCE_DIR" >&2
    exit 1
}
case "$EVIDENCE_DIR_IDENTITY" in
    *:"$(/usr/bin/id -u)":*:700) ;;
    *) echo "error: evidence directory ownership or mode is unsafe: $EVIDENCE_DIR" >&2; exit 1 ;;
esac

BUILD_ROOT="$(/usr/bin/mktemp -d "$BUILD_PARENT/jbar-benchmark-build.XXXXXXXX")" || {
    echo "error: could not create the isolated SwiftPM scratch directory" >&2
    echo "benchmark evidence retained at: $EVIDENCE_DIR" >&2
    exit 1
}
/bin/chmod 0700 "$BUILD_ROOT"
BUILD_ROOT="$(cd "$BUILD_ROOT" && pwd -P)"
case "$BUILD_ROOT" in
    "$BUILD_PARENT"/jbar-benchmark-build.*) ;;
    *) echo "error: mktemp returned an unsafe build directory" >&2; exit 1 ;;
esac
verify_parent_identity "$BUILD_PARENT" "$BUILD_PARENT_IDENTITY" || {
    echo "error: build parent changed while creating the SwiftPM scratch directory" >&2
    exit 1
}
BUILD_ROOT_IDENTITY="$(capture_directory_identity "$BUILD_ROOT")" || {
    echo "error: SwiftPM scratch directory identity is unsafe: $BUILD_ROOT" >&2
    exit 1
}
case "$BUILD_ROOT_IDENTITY" in
    *:"$(/usr/bin/id -u)":*:700) ;;
    *) echo "error: SwiftPM scratch ownership or mode is unsafe: $BUILD_ROOT" >&2; exit 1 ;;
esac

# Keep the original evidence directory open as this process's working directory. Relative evidence
# I/O therefore continues to address the captured directory object even if a same-EUID process
# renames the publication entry; final success still requires that the absolute entry retain the
# same creation-time identity.
cd "$EVIDENCE_DIR" || {
    echo "error: could not pin the evidence directory as the working directory" >&2
    exit 1
}
EVIDENCE_IO_ROOT="."

FINALIZED=0
FAILURE_REASON=""
BINARY_PATH=""
BINARY_SHA256=""
RETAINED_GATE="$EVIDENCE_IO_ROOT/benchmark-report-gate.rb"
HASH_TEST_ACTION=""
POST_PUBLISH_TEST_ACTION=""
RESULT_POSTCONDITION_TEST_ACTION=""
TERMINAL_IDENTITY_TEST_ACTION=""
RESULT_FILE_IDENTITY=""
CHECKSUM_FILE_IDENTITY=""

write_source_manifest() {
    local destination="$1"
    local temporary="$destination.tmp"
    [ ! -e "$destination" ] && [ ! -L "$destination" ] &&
    [ ! -e "$temporary" ] && [ ! -L "$temporary" ] || return 1
    if ! /usr/bin/ruby - "$REPO_DIR" > "$temporary" <<'RUBY'
require "digest"
require "find"

root = File.realpath(ARGV.fetch(0))

def collect_build_inputs(root)
  relative_paths = ["Package.swift"]
  resolved = File.join(root, "Package.resolved")
  relative_paths << "Package.resolved" if File.exist?(resolved) || File.symlink?(resolved)
  sources = File.join(root, "Sources")
  Find.find(sources) do |path|
    next if path == sources
    relative = path.delete_prefix("#{root}/")
    stat = File.lstat(path)
    if stat.directory? && !stat.symlink?
      next
    elsif !stat.file? || stat.symlink?
      raise "unsupported build input type: #{relative}"
    end
    relative_paths << relative
  end
  relative_paths.sort!
  raise "duplicate build input" unless relative_paths.uniq.length == relative_paths.length
  relative_paths
end

def stable_identity(stat)
  [stat.dev, stat.ino, stat.uid, stat.gid, stat.mode, stat.nlink, stat.size,
   stat.mtime.to_i, stat.mtime.nsec, stat.ctime.to_i, stat.ctime.nsec]
end

relative_paths = collect_build_inputs(root)
relative_paths.each do |relative|
  raise "unsafe build-input name" if relative.include?("\0") || relative.include?("\n") || relative.include?("\r")
  path = File.join(root, relative)
  path_before = File.lstat(path)
  raise "unsupported build input type: #{relative}" unless
    path_before.file? && !path_before.symlink? && path_before.nlink == 1
  flags = File::RDONLY | File::NOFOLLOW
  File.open(path, flags) do |file|
    descriptor_before = file.stat
    raise "unstable build input before hashing: #{relative}" unless
      stable_identity(path_before) == stable_identity(descriptor_before)
    digest = Digest::SHA256.new
    while (chunk = file.read(1_048_576))
      digest << chunk
    end
    descriptor_after = file.stat
    path_after = File.lstat(path)
    raise "build input changed while hashing: #{relative}" unless
      stable_identity(path_before) == stable_identity(descriptor_after) &&
        stable_identity(path_before) == stable_identity(path_after)
    puts "#{digest.hexdigest}  #{relative}"
  end
end
raise "build-input entry set changed while hashing" unless collect_build_inputs(root) == relative_paths
RUBY
    then
        return 1
    fi
    /bin/mv "$temporary" "$destination"
}

write_tool_manifest() {
    local destination="$1"
    local temporary="$destination.tmp"
    [ ! -e "$destination" ] && [ ! -L "$destination" ] &&
    [ ! -e "$temporary" ] && [ ! -L "$temporary" ] || return 1
    if ! /usr/bin/ruby - "$REPO_DIR/scripts/benchmark-release.sh" "$REPORT_GATE" \
         > "$temporary" <<'RUBY'
require "digest"

def stable_identity(stat)
  [stat.dev, stat.ino, stat.uid, stat.gid, stat.mode, stat.nlink, stat.size,
   stat.mtime.to_i, stat.mtime.nsec, stat.ctime.to_i, stat.ctime.nsec]
end

ARGV.each do |path|
  raise "unsafe tooling path" if path.include?("\0") || path.include?("\n") || path.include?("\r")
  path_before = File.lstat(path)
  raise "tooling input is not one regular file: #{path}" unless
    path_before.file? && !path_before.symlink? && path_before.nlink == 1
  File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
    descriptor_before = file.stat
    raise "tooling path/descriptor mismatch before hashing: #{path}" unless
      stable_identity(path_before) == stable_identity(descriptor_before)
    digest = Digest::SHA256.new
    while (chunk = file.read(1_048_576))
      digest << chunk
    end
    descriptor_after = file.stat
    path_after = File.lstat(path)
    raise "tooling input changed while hashing: #{path}" unless
      stable_identity(path_before) == stable_identity(descriptor_after) &&
        stable_identity(path_before) == stable_identity(path_after)
    puts "#{digest.hexdigest}  #{path}"
  end
end
RUBY
    then
        return 1
    fi
    /bin/mv "$temporary" "$destination"
}

safe_remove_build_root() {
    [ -n "$BUILD_ROOT" ] || return 0
    verify_parent_identity "$BUILD_PARENT" "$BUILD_PARENT_IDENTITY" || return 1
    [ "$(dirname "$BUILD_ROOT")" = "$BUILD_PARENT" ] || return 1
    [[ "$(basename "$BUILD_ROOT")" == jbar-benchmark-build.* ]] || return 1
    if [ ! -e "$BUILD_ROOT" ] && [ ! -L "$BUILD_ROOT" ]; then
        # Disappearance is not successful cleanup: the captured inode may have been renamed away.
        return 1
    fi
    verify_directory_identity "$BUILD_ROOT" "$BUILD_ROOT_IDENTITY" || return 1

    # Pin the captured scratch as a subprocess working-directory capability before walking it.
    # If the publication entry is renamed/replaced later, relative deletion remains inside the
    # captured inode. The final path operation is rmdir-only: the residual same-EUID race can at
    # worst remove an empty replacement, never recursively delete a replacement tree.
    (
        cd "$BUILD_ROOT" || exit 1
        verify_directory_identity . "$BUILD_ROOT_IDENTITY" || exit 1
        /usr/bin/find -x . -depth -mindepth 1 -delete || exit 1
        verify_directory_identity . "$BUILD_ROOT_IDENTITY"
    ) || return 1
    verify_parent_identity "$BUILD_PARENT" "$BUILD_PARENT_IDENTITY" || return 1
    verify_directory_identity "$BUILD_ROOT" "$BUILD_ROOT_IDENTITY" || return 1
    /bin/rmdir -- "$BUILD_ROOT" || return 1
    verify_parent_identity "$BUILD_PARENT" "$BUILD_PARENT_IDENTITY" || return 1
    [ ! -e "$BUILD_ROOT" ] && [ ! -L "$BUILD_ROOT" ] || return 1
    BUILD_ROOT=""
    return 0
}

verify_evidence_storage() {
    verify_directory_identity "$EVIDENCE_IO_ROOT" "$EVIDENCE_DIR_IDENTITY"
}

verify_evidence_hierarchy() {
    verify_evidence_storage &&
        verify_parent_identity "$EVIDENCE_PARENT" "$EVIDENCE_PARENT_IDENTITY" &&
        verify_directory_identity "$EVIDENCE_DIR" "$EVIDENCE_DIR_IDENTITY"
}

safe_regular_evidence_file() {
    local path="$1"
    capture_regular_file_identity "$path" >/dev/null 2>&1
}

capture_regular_file_identity() {
    local path="$1"
    /usr/bin/ruby - "$path" <<'RUBY'
stat = File.lstat(ARGV.fetch(0))
raise unless stat.file? && !stat.symlink? && stat.uid == Process.euid && stat.nlink == 1
puts [stat.dev, stat.ino, stat.uid, stat.gid, format("%o", stat.mode & 0o7777)].join(":")
RUBY
}

verify_regular_file_identity() {
    local path="$1"
    local expected="$2"
    local actual=""
    actual="$(capture_regular_file_identity "$path" 2>/dev/null)" || return 1
    [ "$actual" = "$expected" ]
}

remove_published_result() {
    local result="$EVIDENCE_IO_ROOT/result.txt"
    verify_evidence_storage || return 1
    if [ ! -e "$result" ] && [ ! -L "$result" ]; then
        RESULT_FILE_IDENTITY=""
        return 0
    fi
    [ -n "$RESULT_FILE_IDENTITY" ] || return 1
    verify_regular_file_identity "$result" "$RESULT_FILE_IDENTITY" || return 1
    /bin/rm -f -- "$result" || return 1
    [ ! -e "$result" ] && [ ! -L "$result" ] || return 1
    RESULT_FILE_IDENTITY=""
    return 0
}

remove_published_checksum() {
    local checksum="$EVIDENCE_IO_ROOT/SHA256SUMS"
    verify_evidence_storage || return 1
    if [ ! -e "$checksum" ] && [ ! -L "$checksum" ]; then
        CHECKSUM_FILE_IDENTITY=""
        return 0
    fi
    [ -n "$CHECKSUM_FILE_IDENTITY" ] || return 1
    verify_regular_file_identity "$checksum" "$CHECKSUM_FILE_IDENTITY" || return 1
    /bin/rm -f -- "$checksum" || return 1
    [ ! -e "$checksum" ] && [ ! -L "$checksum" ] || return 1
    CHECKSUM_FILE_IDENTITY=""
    return 0
}

write_result_file() {
    local exit_code="$1"
    local result="$2"
    local failure_reason="$3"
    local source_status="$4"
    local tool_status="$5"
    local scratch_status="$6"
    local checksum_status="$7"
    local destination="$EVIDENCE_IO_ROOT/result.txt"
    local temporary="$EVIDENCE_IO_ROOT/.result.txt.tmp"
    local new_identity=""

    verify_evidence_hierarchy || return 1
    [ ! -e "$temporary" ] && [ ! -L "$temporary" ] || return 1
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        if [ -n "$RESULT_FILE_IDENTITY" ]; then
            verify_regular_file_identity "$destination" "$RESULT_FILE_IDENTITY" || return 1
        else
            safe_regular_evidence_file "$destination" || return 1
        fi
    fi
    {
        echo "evidenceFormatVersion=1"
        echo "exitCode=$exit_code"
        echo "result=$result"
        echo "failureReason=$failure_reason"
        echo "sourceManifestAfterStatus=$source_status"
        echo "toolManifestAfterStatus=$tool_status"
        echo "scratchCleanupStatus=$scratch_status"
        echo "checksumManifestStatus=$checksum_status"
        echo "absoluteLatencyThreshold=omitted"
        echo "latencyInterpretation=observational per identified machine; not a product SLA"
        echo "evidenceDirectory=$EVIDENCE_DIR"
    } > "$temporary" || return 1
    /bin/chmod 0600 "$temporary" || return 1
    new_identity="$(capture_regular_file_identity "$temporary" 2>/dev/null)" || return 1
    verify_evidence_hierarchy || return 1
    verify_regular_file_identity "$temporary" "$new_identity" || return 1
    /bin/mv -f -- "$temporary" "$destination" || return 1
    RESULT_FILE_IDENTITY="$new_identity"
    if [ -n "$RESULT_POSTCONDITION_TEST_ACTION" ] &&
       { [ "$INTERNAL_TEST_MODE" -ne 1 ] ||
         [ "$RESULT_POSTCONDITION_TEST_ACTION" != "fail-once" ]; }; then
        return 1
    fi
    if [ "$RESULT_POSTCONDITION_TEST_ACTION" = "fail-once" ]; then
        RESULT_POSTCONDITION_TEST_ACTION=""
        return 1
    fi
    verify_evidence_hierarchy || return 1
    verify_regular_file_identity "$destination" "$RESULT_FILE_IDENTITY"
}

write_sha256_manifest() {
    local temporary="$EVIDENCE_IO_ROOT/.SHA256SUMS.tmp"
    local new_checksum_identity=""
    verify_evidence_hierarchy || return 1
    [ -n "$RESULT_FILE_IDENTITY" ] &&
        verify_regular_file_identity "$EVIDENCE_IO_ROOT/result.txt" "$RESULT_FILE_IDENTITY" || return 1
    [ -z "$CHECKSUM_FILE_IDENTITY" ] || return 1
    [ ! -e "$EVIDENCE_IO_ROOT/SHA256SUMS" ] && [ ! -L "$EVIDENCE_IO_ROOT/SHA256SUMS" ] &&
    [ ! -e "$temporary" ] && [ ! -L "$temporary" ] || return 1
    if ! /usr/bin/ruby - "$EVIDENCE_IO_ROOT" "$EVIDENCE_DIR_IDENTITY" "$HASH_TEST_ACTION" \
         > "$temporary" <<'RUBY'
require "digest"

root = ARGV.fetch(0)
expected_root_identity = ARGV.fetch(1)
test_action = ARGV.fetch(2)

def identity(stat)
  [stat.dev, stat.ino, stat.uid, stat.gid, format("%o", stat.mode & 0o7777)].join(":")
end

def stable_identity(stat)
  [stat.dev, stat.ino, stat.uid, stat.gid, stat.mode, stat.nlink, stat.size,
   stat.mtime.to_i, stat.mtime.nsec, stat.ctime.to_i, stat.ctime.nsec]
end

root_before = File.lstat(root)
raise "evidence root identity changed before hashing" unless
  root_before.directory? && !root_before.symlink? && identity(root_before) == expected_root_identity
resolved_root = File.realpath(root)
raise "evidence root descriptor/realpath identity mismatch" unless
  identity(File.lstat(resolved_root)) == expected_root_identity

excluded = ["SHA256SUMS", ".SHA256SUMS.tmp"]
entries = Dir.children(root).sort.reject { |name| excluded.include?(name) }
entries.each do |name|
  raise "unsafe evidence name" if name.include?("\0") || name.include?("\n") || name.include?("\r")
  path = File.join(root, name)
  path_before = File.lstat(path)
  raise "evidence entry is not one owned regular file: #{name}" unless
    path_before.file? && !path_before.symlink? && path_before.uid == Process.euid && path_before.nlink == 1
  flags = File::RDONLY | File::NOFOLLOW
  File.open(path, flags) do |file|
    descriptor_before = file.stat
    raise "evidence path/descriptor identity mismatch before hashing: #{name}" unless
      stable_identity(path_before) == stable_identity(descriptor_before)

    if name == "hash-race-payload.txt" && !test_action.empty?
      case test_action
      when "replace"
        File.rename(path, "#{path}.replaced-original")
        File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |replacement|
          replacement.write("replacement\n")
          replacement.fsync
        end
      when "change"
        File.open(path, File::WRONLY | File::APPEND | File::NOFOLLOW) do |mutator|
          mutator.write("changed\n")
          mutator.fsync
        end
      else
        raise "unknown internal hash test action"
      end
    end

    digest = Digest::SHA256.new
    while (chunk = file.read(1_048_576))
      digest << chunk
    end
    descriptor_after = file.stat
    path_after = File.lstat(path)
    raise "evidence entry changed while hashing: #{name}" unless
      stable_identity(path_before) == stable_identity(descriptor_after) &&
        stable_identity(path_before) == stable_identity(path_after)
    puts "#{digest.hexdigest}  #{name}"
  end
end

entries_after = Dir.children(root).sort.reject { |name| excluded.include?(name) }
raise "evidence entry set changed while hashing" unless entries_after == entries
root_after = File.lstat(root)
raise "evidence root identity changed while hashing" unless identity(root_after) == expected_root_identity
RUBY
    then
        return 1
    fi
    /bin/chmod 0400 "$temporary" || return 1
    new_checksum_identity="$(capture_regular_file_identity "$temporary" 2>/dev/null)" || return 1
    verify_evidence_hierarchy || return 1
    verify_regular_file_identity "$temporary" "$new_checksum_identity" || return 1
    (
        cd "$EVIDENCE_IO_ROOT" &&
        LC_ALL=C /usr/bin/shasum -a 256 -c .SHA256SUMS.tmp >/dev/null
    ) || return 1
    verify_evidence_hierarchy || return 1
    /bin/mv "$temporary" "$EVIDENCE_IO_ROOT/SHA256SUMS" || return 1
    CHECKSUM_FILE_IDENTITY="$new_checksum_identity"
    if [ -n "$POST_PUBLISH_TEST_ACTION" ] &&
       { [ "$INTERNAL_TEST_MODE" -ne 1 ] || [ "$POST_PUBLISH_TEST_ACTION" != "change-result" ]; }; then
        remove_published_checksum >/dev/null 2>&1 || true
        return 1
    fi
    if [ "$POST_PUBLISH_TEST_ACTION" = "change-result" ]; then
        echo "internal post-publish mutation" >> "$EVIDENCE_IO_ROOT/result.txt" || return 1
        POST_PUBLISH_TEST_ACTION=""
    fi
    if ! verify_evidence_hierarchy ||
       ! (cd "$EVIDENCE_IO_ROOT" &&
           LC_ALL=C /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null) ||
       ! verify_evidence_hierarchy; then
        remove_published_checksum >/dev/null 2>&1 || true
        return 1
    fi
    return 0
}

finalize() {
    local original_status="$1"
    local final_status="$original_status"
    local source_after_status=0
    local tool_after_status=0
    local scratch_status=0
    local checksum_status=0
    local result_status=0
    local fallback_result_status=0
    local checksum_removal_status=0
    local result_removal_status=0
    local publishable=1
    local current_binary_sha=""

    trap - EXIT HUP INT TERM
    set +e
    [ "$FINALIZED" -eq 0 ] || exit "$final_status"
    FINALIZED=1
    if [ "$original_status" -ne 0 ] && [ -z "$FAILURE_REASON" ]; then
        FAILURE_REASON="command exited $original_status before a more specific reason was recorded"
    fi

    if ! verify_evidence_hierarchy; then
        final_status=1
        FAILURE_REASON="${FAILURE_REASON}${FAILURE_REASON:+; }evidence parent or directory identity changed; refused finalization writes"
        safe_remove_build_root >/dev/null 2>&1
        echo "benchmark evidence identity lost at: $EVIDENCE_DIR" >&2
        echo "error: benchmark evidence collection failed: $FAILURE_REASON" >&2
        exit "$final_status"
    fi

    write_source_manifest "$EVIDENCE_IO_ROOT/source-manifest.after.sha256"
    source_after_status=$?
    write_tool_manifest "$EVIDENCE_IO_ROOT/tooling.after.sha256"
    tool_after_status=$?
    if [ "$source_after_status" -ne 0 ] ||
       ! /usr/bin/cmp -s "$EVIDENCE_IO_ROOT/source-manifest.before.sha256" \
                          "$EVIDENCE_IO_ROOT/source-manifest.after.sha256"; then
        final_status=1
        FAILURE_REASON="${FAILURE_REASON}${FAILURE_REASON:+; }build inputs changed or could not be re-hashed"
    fi
    if [ "$tool_after_status" -ne 0 ] ||
       ! /usr/bin/cmp -s "$EVIDENCE_IO_ROOT/tooling.before.sha256" \
                          "$EVIDENCE_IO_ROOT/tooling.after.sha256"; then
        final_status=1
        FAILURE_REASON="${FAILURE_REASON}${FAILURE_REASON:+; }benchmark tooling changed during collection"
    fi
    if [ -n "$BINARY_PATH" ] && [ -f "$BINARY_PATH" ] && [ ! -L "$BINARY_PATH" ]; then
        current_binary_sha="$(/usr/bin/shasum -a 256 "$BINARY_PATH" | /usr/bin/cut -d ' ' -f 1)"
        printf '%s  JBar\n' "$current_binary_sha" > "$EVIDENCE_IO_ROOT/binary.after.sha256"
        if [ "$current_binary_sha" != "$BINARY_SHA256" ]; then
            final_status=1
            FAILURE_REASON="${FAILURE_REASON}${FAILURE_REASON:+; }benchmark binary changed during collection"
        fi
    elif [ -n "$BINARY_PATH" ]; then
        final_status=1
        FAILURE_REASON="${FAILURE_REASON}${FAILURE_REASON:+; }benchmark binary disappeared before finalization"
    fi

    if safe_remove_build_root; then
        echo "isolated SwiftPM scratch removed after exact creation-identity verification" > "$EVIDENCE_IO_ROOT/scratch-cleanup.txt"
    else
        scratch_status=1
        final_status=1
        FAILURE_REASON="${FAILURE_REASON}${FAILURE_REASON:+; }refused unsafe SwiftPM scratch cleanup"
        echo "refused cleanup because the scratch identity was no longer safe" > \
            "$EVIDENCE_IO_ROOT/scratch-cleanup.txt"
    fi

    write_result_file "$final_status" \
        "$([ "$final_status" -eq 0 ] && echo PASS || echo FAIL)" \
        "${FAILURE_REASON:-none}" "$source_after_status" "$tool_after_status" \
        "$scratch_status" "verified-by-finalizer-before-exit"
    result_status=$?
    if [ "$result_status" -ne 0 ]; then
        final_status=1
        FAILURE_REASON="${FAILURE_REASON}${FAILURE_REASON:+; }could not write a stable final result"
        echo "error: could not write a stable benchmark result" >&2
        remove_published_checksum
        checksum_removal_status=$?
        remove_published_result
        result_removal_status=$?
        if [ "$checksum_removal_status" -eq 0 ] && [ "$result_removal_status" -eq 0 ] &&
           verify_evidence_hierarchy; then
            write_result_file 1 FAIL "$FAILURE_REASON" "$source_after_status" \
                "$tool_after_status" "$scratch_status" NOT-CREATED
            fallback_result_status=$?
        else
            fallback_result_status=1
        fi
        if [ "$fallback_result_status" -ne 0 ]; then
            remove_published_result >/dev/null 2>&1 || true
            publishable=0
            echo "error: could not publish a non-contradictory failure result" >&2
        fi
        checksum_status=1
    else
        write_sha256_manifest
        checksum_status=$?
    fi

    if [ "$result_status" -eq 0 ] && [ "$checksum_status" -ne 0 ]; then
        final_status=1
        FAILURE_REASON="${FAILURE_REASON}${FAILURE_REASON:+; }could not create and self-verify the SHA-256 evidence manifest"
        remove_published_checksum
        checksum_removal_status=$?
        if [ "$checksum_removal_status" -eq 0 ]; then
            write_result_file 1 FAIL "$FAILURE_REASON" "$source_after_status" \
                "$tool_after_status" "$scratch_status" FAIL
            fallback_result_status=$?
            if [ "$fallback_result_status" -ne 0 ]; then
                remove_published_result >/dev/null 2>&1 || true
                publishable=0
                echo "error: could not replace the provisional result with an integrity-failure result" >&2
            fi
        else
            FAILURE_REASON="$FAILURE_REASON; could not prove stale SHA256SUMS removal"
            remove_published_result >/dev/null 2>&1 || true
            publishable=0
            echo "error: refused to write an integrity-failure result while SHA256SUMS may remain" >&2
        fi
        echo "error: could not create the SHA-256 evidence manifest" >&2
    fi

    if [ "$INTERNAL_TEST_MODE" -eq 1 ] &&
       [ "$TERMINAL_IDENTITY_TEST_ACTION" = "replace-evidence" ]; then
        local terminal_relocated="${EVIDENCE_DIR}.terminal-captured-internal-test"
        if [ ! -e "$terminal_relocated" ] && [ ! -L "$terminal_relocated" ] &&
           /bin/mv "$EVIDENCE_DIR" "$terminal_relocated" &&
           /bin/mkdir "$EVIDENCE_DIR" && /bin/chmod 0700 "$EVIDENCE_DIR"; then
            echo "replacement must survive" > "$EVIDENCE_DIR/replacement-marker.txt"
            echo "internalTerminalReplacementEvidence=$EVIDENCE_DIR"
            echo "internalTerminalCapturedEvidence=$terminal_relocated"
        else
            publishable=0
        fi
        TERMINAL_IDENTITY_TEST_ACTION=""
    fi

    if [ "$publishable" -eq 1 ] && verify_evidence_hierarchy; then
        echo "benchmark evidence retained at: $EVIDENCE_DIR"
    else
        final_status=1
        FAILURE_REASON="${FAILURE_REASON}${FAILURE_REASON:+; }evidence identity changed after checksum finalization"
        remove_published_checksum >/dev/null 2>&1 || true
        remove_published_result >/dev/null 2>&1 || true
        echo "benchmark evidence identity lost at: $EVIDENCE_DIR" >&2
    fi
    if [ "$final_status" -ne 0 ]; then
        echo "error: benchmark evidence collection failed: ${FAILURE_REASON:-exit $original_status}" >&2
    fi
    exit "$final_status"
}

run_internal_self_test() {
    local relocated=""
    case "$INTERNAL_TEST_SCENARIO" in
        replace-build)
            relocated="${BUILD_ROOT}.captured-internal-test"
            [ ! -e "$relocated" ] && [ ! -L "$relocated" ] || return 1
            /bin/mv "$BUILD_ROOT" "$relocated" || return 1
            /bin/mkdir "$BUILD_ROOT" || return 1
            /bin/chmod 0700 "$BUILD_ROOT" || return 1
            echo "replacement must survive" > "$BUILD_ROOT/replacement-marker.txt"
            echo "internalReplacementBuild=$BUILD_ROOT"
            FAILURE_REASON="internal self-test replaced the build publication entry"
            finalize 1
            ;;
        missing-build)
            relocated="${BUILD_ROOT}.captured-internal-test"
            [ ! -e "$relocated" ] && [ ! -L "$relocated" ] || return 1
            /bin/mv "$BUILD_ROOT" "$relocated" || return 1
            echo "internalMissingBuild=$BUILD_ROOT"
            echo "internalCapturedBuild=$relocated"
            FAILURE_REASON="internal self-test removed the build publication entry"
            finalize 1
            ;;
        replace-evidence)
            relocated="${EVIDENCE_DIR}.captured-internal-test"
            [ ! -e "$relocated" ] && [ ! -L "$relocated" ] || return 1
            /bin/mv "$EVIDENCE_DIR" "$relocated" || return 1
            /bin/mkdir "$EVIDENCE_DIR" || return 1
            /bin/chmod 0700 "$EVIDENCE_DIR" || return 1
            echo "replacement must survive" > "$EVIDENCE_DIR/replacement-marker.txt"
            echo "internalReplacementEvidence=$EVIDENCE_DIR"
            echo "internalCapturedEvidence=$relocated"
            FAILURE_REASON="internal self-test replaced the evidence publication entry"
            finalize 1
            ;;
        hash-replace|hash-change)
            echo "stable payload" > "$EVIDENCE_IO_ROOT/hash-race-payload.txt"
            echo "result=INTERNAL-SELF-TEST" > "$EVIDENCE_IO_ROOT/result.txt"
            RESULT_FILE_IDENTITY="$(capture_regular_file_identity "$EVIDENCE_IO_ROOT/result.txt")" || return 1
            HASH_TEST_ACTION="${INTERNAL_TEST_SCENARIO#hash-}"
            if write_sha256_manifest; then
                echo "error: evidence hash accepted an internal $HASH_TEST_ACTION race" >&2
                return 1
            fi
            safe_remove_build_root || return 1
            echo "PASS: evidence hash rejected an internal $HASH_TEST_ACTION race"
            echo "internalEvidence=$EVIDENCE_DIR"
            return 0
            ;;
        checksum-self-verify)
            echo "stable payload" > "$EVIDENCE_IO_ROOT/checksum-payload.txt"
            echo "result=INTERNAL-SELF-TEST" > "$EVIDENCE_IO_ROOT/result.txt"
            RESULT_FILE_IDENTITY="$(capture_regular_file_identity "$EVIDENCE_IO_ROOT/result.txt")" || return 1
            write_sha256_manifest || return 1
            (
                cd "$EVIDENCE_IO_ROOT" &&
                LC_ALL=C /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null
            ) || return 1
            safe_remove_build_root || return 1
            echo "PASS: evidence checksum manifest self-verified"
            echo "internalEvidence=$EVIDENCE_DIR"
            return 0
            ;;
        checksum-post-publish-failure)
            write_source_manifest "$EVIDENCE_IO_ROOT/source-manifest.before.sha256" || return 1
            write_tool_manifest "$EVIDENCE_IO_ROOT/tooling.before.sha256" || return 1
            POST_PUBLISH_TEST_ACTION="change-result"
            echo "internalEvidence=$EVIDENCE_DIR"
            finalize 0
            ;;
        result-postcondition-failure)
            write_source_manifest "$EVIDENCE_IO_ROOT/source-manifest.before.sha256" || return 1
            write_tool_manifest "$EVIDENCE_IO_ROOT/tooling.before.sha256" || return 1
            RESULT_POSTCONDITION_TEST_ACTION="fail-once"
            echo "internalEvidence=$EVIDENCE_DIR"
            finalize 0
            ;;
        terminal-identity-failure)
            write_source_manifest "$EVIDENCE_IO_ROOT/source-manifest.before.sha256" || return 1
            write_tool_manifest "$EVIDENCE_IO_ROOT/tooling.before.sha256" || return 1
            TERMINAL_IDENTITY_TEST_ACTION="replace-evidence"
            finalize 0
            ;;
        *)
            echo "error: unknown internal self-test scenario: $INTERNAL_TEST_SCENARIO" >&2
            return 2
            ;;
    esac
}

if [ "$INTERNAL_TEST_MODE" -eq 1 ]; then
    run_internal_self_test
    exit $?
fi

trap 'finalize $?' EXIT
trap 'FAILURE_REASON="${FAILURE_REASON}${FAILURE_REASON:+; }received HUP"; exit 129' HUP
trap 'FAILURE_REASON="${FAILURE_REASON}${FAILURE_REASON:+; }received INT"; exit 130' INT
trap 'FAILURE_REASON="${FAILURE_REASON}${FAILURE_REASON:+; }received TERM"; exit 143' TERM

write_source_manifest "$EVIDENCE_IO_ROOT/source-manifest.before.sha256"
write_tool_manifest "$EVIDENCE_IO_ROOT/tooling.before.sha256"
/bin/cp "$REPORT_GATE" "$RETAINED_GATE"
/bin/chmod 0400 "$RETAINED_GATE"
/bin/cp "$REPO_DIR/scripts/benchmark-release.sh" "$EVIDENCE_IO_ROOT/benchmark-release.sh"
/bin/chmod 0400 "$EVIDENCE_IO_ROOT/benchmark-release.sh"
{
    echo "evidenceParentPath=$EVIDENCE_PARENT"
    echo "evidenceParentIdentity=$EVIDENCE_PARENT_IDENTITY"
    echo "evidenceDirectoryPath=$EVIDENCE_DIR"
    echo "evidenceDirectoryIdentity=$EVIDENCE_DIR_IDENTITY"
    echo "buildParentPath=$BUILD_PARENT"
    echo "buildParentIdentity=$BUILD_PARENT_IDENTITY"
    echo "buildScratchPath=$BUILD_ROOT"
    echo "buildScratchIdentity=$BUILD_ROOT_IDENTITY"
} > "$EVIDENCE_IO_ROOT/storage-identities.txt"

if ! SWIFT_BIN="$(/usr/bin/xcrun --find swift 2> "$EVIDENCE_IO_ROOT/toolchain-resolution.stderr.log")"; then
    FAILURE_REASON="xcrun could not resolve the selected Swift compiler"
    exit 1
fi
if ! SWIFT_REALPATH="$(/usr/bin/ruby -e 'puts File.realpath(ARGV.fetch(0))' "$SWIFT_BIN" \
                      2>> "$EVIDENCE_IO_ROOT/toolchain-resolution.stderr.log")"; then
    FAILURE_REASON="the selected Swift compiler has an unresolved link target"
    exit 1
fi
[ -n "$SWIFT_BIN" ] && [ -x "$SWIFT_BIN" ] && [ -f "$SWIFT_BIN" ] &&
[ -n "$SWIFT_REALPATH" ] && [ -x "$SWIFT_REALPATH" ] && [ -f "$SWIFT_REALPATH" ] &&
[ ! -L "$SWIFT_REALPATH" ] || {
    FAILURE_REASON="xcrun did not resolve a Swift compiler with one regular final target"
    exit 1
}

{
    echo "generatedAtUTC=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "repository=$REPO_DIR"
    echo "evidenceDirectory=$EVIDENCE_DIR"
    echo "buildScratch=$BUILD_ROOT"
    echo "swiftExecutable=$SWIFT_BIN"
    echo "swiftResolvedExecutable=$SWIFT_REALPATH"
    echo "rubyExecutable=/usr/bin/ruby"
    echo "shellExecutable=/bin/bash"
    echo "DEVELOPER_DIR=${DEVELOPER_DIR-<unset>}"
    echo "SDKROOT=${SDKROOT-<unset>}"
    echo "TOOLCHAINS=${TOOLCHAINS-<unset>}"
    echo "LANG=${LANG-<unset>}"
    echo "LC_ALL=${LC_ALL-<unset>}"
    echo "uname=$(/usr/bin/uname -a)"
    printf 'arch='; /usr/bin/arch; printf '\n'
    /usr/bin/sw_vers
    /usr/sbin/sysctl -n hw.model machdep.cpu.brand_string hw.ncpu hw.memsize
    /usr/bin/xcodebuild -version
    "$SWIFT_BIN" --version 2>&1
    /usr/bin/ruby -v
    /bin/bash --version | /usr/bin/head -n 1
} > "$EVIDENCE_IO_ROOT/environment.txt"

{
    echo "head=$(/usr/bin/git -C "$REPO_DIR" rev-parse HEAD)"
    echo "branch=$(/usr/bin/git -C "$REPO_DIR" symbolic-ref --short -q HEAD || echo detached)"
    echo "statusPorcelainV1Begin"
    /usr/bin/git -C "$REPO_DIR" status --porcelain=v1 --untracked-files=normal
    echo "statusPorcelainV1End"
} > "$EVIDENCE_IO_ROOT/source-git-identity.txt"

{
    echo "evidenceFormatVersion=1"
    echo "reportSchemaVersion=1"
    echo "workloadVersion=2"
    echo "requestedSamples=$SAMPLES"
    echo "syntheticFixtureSizes=$FIXTURE_SIZES"
    echo "syntheticIndependentProcessesPerSize=$PROCESSES"
    echo "includeIsolatedRealCrawl=$INCLUDE_REAL"
    echo "realIndependentProcesses=$REAL_PROCESSES"
    echo "execution=sequential independent processes from one immutable isolated release binary"
    echo "performanceGate=none across unrelated/shared machines"
    echo "interpretation=latencies are observational evidence for the recorded machine, not a product SLA"
    echo "evidenceStorage=pinned working-directory object plus terminal publication-entry identity check"
    echo "cleanupTrustBoundary=cwd-pinned relative deletion plus rmdir-only publication removal under a private or root-owned sticky parent"
    echo "integrityTrustBoundary=/private/tmp sticky semantics and 0700 children prevent cross-UID replacement; no user process can prevent root or a hostile same-EUID process from tampering after exit"
} > "$EVIDENCE_IO_ROOT/run-plan.txt"

echo "Building one isolated release binary in $BUILD_ROOT"
echo "$SWIFT_BIN build --package-path $REPO_DIR -c release --product JBar --scratch-path $BUILD_ROOT" > \
    "$EVIDENCE_IO_ROOT/build-command.txt"
if ! "$SWIFT_BIN" build --package-path "$REPO_DIR" -c release --product JBar \
     --scratch-path "$BUILD_ROOT" \
     > "$EVIDENCE_IO_ROOT/build.stdout.log" 2> "$EVIDENCE_IO_ROOT/build.stderr.log"; then
    FAILURE_REASON="isolated release build failed"
    exit 1
fi
if ! "$SWIFT_BIN" build --package-path "$REPO_DIR" -c release --product JBar \
     --scratch-path "$BUILD_ROOT" --show-bin-path \
     > "$EVIDENCE_IO_ROOT/build-bin-path.txt" 2>> "$EVIDENCE_IO_ROOT/build.stderr.log"; then
    FAILURE_REASON="could not resolve isolated release binary path"
    exit 1
fi
BIN_DIR="$(/usr/bin/head -n 1 "$EVIDENCE_IO_ROOT/build-bin-path.txt")"
[ "$(/usr/bin/wc -l < "$EVIDENCE_IO_ROOT/build-bin-path.txt" | /usr/bin/tr -d ' ')" = "1" ] || {
    FAILURE_REASON="SwiftPM returned an ambiguous binary directory"
    exit 1
}
case "$BIN_DIR" in
    "$BUILD_ROOT"/*) ;;
    *) FAILURE_REASON="SwiftPM binary directory escaped the isolated scratch"; exit 1 ;;
esac
BINARY_PATH="$BIN_DIR/JBar"
[ -f "$BINARY_PATH" ] && [ ! -L "$BINARY_PATH" ] && [ -x "$BINARY_PATH" ] &&
[ "$(/usr/bin/stat -f '%u' "$BINARY_PATH")" = "$(/usr/bin/id -u)" ] || {
    FAILURE_REASON="isolated release binary identity is unsafe"
    exit 1
}
BINARY_SHA256="$(/usr/bin/shasum -a 256 "$BINARY_PATH" | /usr/bin/cut -d ' ' -f 1)"
printf '%s  JBar\n' "$BINARY_SHA256" > "$EVIDENCE_IO_ROOT/binary.before.sha256"
{
    /usr/bin/file "$BINARY_PATH"
    printf 'architectures='; /usr/bin/lipo -archs "$BINARY_PATH"; printf '\n'
    if /usr/bin/codesign -d --verbose=4 "$BINARY_PATH" 2>&1; then
        echo "codesignInspection=present"
    else
        echo "codesignInspection=absent-or-unreadable"
    fi
} > "$EVIDENCE_IO_ROOT/binary.identity.txt"

run_benchmark() {
    local kind="$1"
    local fixture_items="$2"
    local process_number="$3"
    local label=""
    local report_path=""
    local report_output_path=""
    local stdout_path=""
    local stderr_path=""
    local gate_stdout=""
    local gate_stderr=""
    local status_path=""
    local benchmark_status=0
    local gate_status=0
    local repeat_identity_status=0
    local binary_after=""
    local identity_line=""
    local identity_count=""
    local repeat_identity_path=""
    local expected_identity=""

    if [ "$kind" = "synthetic" ]; then
        label="synthetic-${fixture_items}-process-${process_number}"
    else
        label="isolated-real-process-${process_number}"
    fi
    report_path="$EVIDENCE_IO_ROOT/$label.json"
    # Benchmark.swift intentionally accepts only absolute report paths. The parent has already been
    # constrained to private/sticky storage and terminal identity is mandatory; all harness reads
    # still use the cwd-pinned relative path.
    report_output_path="$EVIDENCE_DIR/$label.json"
    stdout_path="$EVIDENCE_IO_ROOT/$label.stdout.log"
    stderr_path="$EVIDENCE_IO_ROOT/$label.stderr.log"
    gate_stdout="$EVIDENCE_IO_ROOT/$label.gate.stdout.log"
    gate_stderr="$EVIDENCE_IO_ROOT/$label.gate.stderr.log"
    status_path="$EVIDENCE_IO_ROOT/$label.status.txt"
    for path in "$report_path" "$stdout_path" "$stderr_path" "$gate_stdout" \
                "$gate_stderr" "$status_path"; do
        [ ! -e "$path" ] && [ ! -L "$path" ] || {
            FAILURE_REASON="$label would overwrite existing evidence"
            return 1
        }
    done

    echo "Running $label (requested samples=$SAMPLES)"
    set +e
    if [ "$kind" = "synthetic" ]; then
        /usr/bin/env -u JBAR_BENCHMARK_FIXTURE_ITEMS -u JBAR_BENCHMARK_JSON_OUTPUT \
            JBAR_BENCHMARK_FIXTURE_ITEMS="$fixture_items" \
            JBAR_BENCHMARK_JSON_OUTPUT="$report_output_path" \
            "$BINARY_PATH" --benchmark "$SAMPLES" > "$stdout_path" 2> "$stderr_path"
        benchmark_status=$?
    else
        /usr/bin/env -u JBAR_BENCHMARK_FIXTURE_ITEMS -u JBAR_BENCHMARK_JSON_OUTPUT \
            JBAR_BENCHMARK_JSON_OUTPUT="$report_output_path" \
            "$BINARY_PATH" --benchmark "$SAMPLES" > "$stdout_path" 2> "$stderr_path"
        benchmark_status=$?
    fi
    set -e

    binary_after="$(/usr/bin/shasum -a 256 "$BINARY_PATH" | /usr/bin/cut -d ' ' -f 1)"
    if [ "$binary_after" != "$BINARY_SHA256" ]; then
        benchmark_status=125
        FAILURE_REASON="$label observed a changed benchmark binary"
    fi
    if [ "$benchmark_status" -ne 0 ]; then
        {
            echo "kind=$kind"
            echo "fixtureItems=${fixture_items:-none}"
            echo "processNumber=$process_number"
            echo "requestedSamples=$SAMPLES"
            echo "benchmarkExitCode=$benchmark_status"
            echo "reportGateExitCode=not-run"
            echo "repeatIdentityExitCode=not-run"
            echo "binarySha256=$binary_after"
        } > "$status_path"
        FAILURE_REASON="${FAILURE_REASON:-$label benchmark exited $benchmark_status}"
        return 1
    fi

    set +e
    if [ "$kind" = "synthetic" ]; then
        /usr/bin/ruby "$RETAINED_GATE" --expected-samples "$SAMPLES" \
            --expected-fixture-items "$fixture_items" "$report_output_path" \
            > "$gate_stdout" 2> "$gate_stderr"
        gate_status=$?
    else
        /usr/bin/ruby "$RETAINED_GATE" --expected-samples "$SAMPLES" --expect-real \
            "$report_output_path" > "$gate_stdout" 2> "$gate_stderr"
        gate_status=$?
    fi
    set -e
    if [ "$gate_status" -eq 0 ] && [ "$kind" = "synthetic" ]; then
        identity_count="$(/usr/bin/grep -c '^IDENTITY ' "$gate_stdout" || true)"
        identity_line="$(/usr/bin/grep '^IDENTITY ' "$gate_stdout" || true)"
        case "$identity_line" in
            "IDENTITY schemaVersion=1 workloadVersion=2 samples=$SAMPLES corpusKind=deterministic-fixture itemCount=$fixture_items corpusFingerprint=0x"*) ;;
            *) repeat_identity_status=1 ;;
        esac
        [ "$identity_count" = "1" ] || repeat_identity_status=1
        repeat_identity_path="$EVIDENCE_IO_ROOT/synthetic-${fixture_items}.repeat-identity.txt"
        if [ "$repeat_identity_status" -eq 0 ] && [ "$process_number" -eq 1 ]; then
            [ ! -e "$repeat_identity_path" ] && [ ! -L "$repeat_identity_path" ] ||
                repeat_identity_status=1
            if [ "$repeat_identity_status" -eq 0 ]; then
                printf '%s\n' "$identity_line" > "$repeat_identity_path"
            fi
        elif [ "$repeat_identity_status" -eq 0 ]; then
            if [ ! -f "$repeat_identity_path" ] || [ -L "$repeat_identity_path" ]; then
                repeat_identity_status=1
            else
                expected_identity="$(/bin/cat "$repeat_identity_path")"
                [ "$identity_line" = "$expected_identity" ] || repeat_identity_status=1
            fi
        fi
    fi
    {
        echo "kind=$kind"
        echo "fixtureItems=${fixture_items:-none}"
        echo "processNumber=$process_number"
        echo "requestedSamples=$SAMPLES"
        echo "benchmarkExitCode=$benchmark_status"
        echo "reportGateExitCode=$gate_status"
        echo "repeatIdentityExitCode=$repeat_identity_status"
        echo "binarySha256=$binary_after"
    } > "$status_path"
    if [ "$gate_status" -ne 0 ]; then
        FAILURE_REASON="$label failed the independent report gate"
        return 1
    fi
    if [ "$repeat_identity_status" -ne 0 ]; then
        FAILURE_REASON="$label identity differs from another independent process for the same fixture size"
        return 1
    fi
    return 0
}

set -f
for ITEMS in $FIXTURE_SIZES; do
    PROCESS_NUMBER=1
    while [ "$PROCESS_NUMBER" -le "$PROCESSES" ]; do
        run_benchmark synthetic "$ITEMS" "$PROCESS_NUMBER" || exit 1
        PROCESS_NUMBER=$((PROCESS_NUMBER + 1))
    done
done
set +f

if [ "$INCLUDE_REAL" = "1" ]; then
    PROCESS_NUMBER=1
    while [ "$PROCESS_NUMBER" -le "$REAL_PROCESSES" ]; do
        run_benchmark real "" "$PROCESS_NUMBER" || exit 1
        PROCESS_NUMBER=$((PROCESS_NUMBER + 1))
    done
fi

echo "All requested benchmark processes completed and passed the correctness evidence gate."

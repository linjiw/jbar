#!/bin/bash
# Static/argument tests for the release benchmark evidence harness. These tests never invoke SwiftPM.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
HARNESS="$ROOT/scripts/benchmark-release.sh"
GATE="$ROOT/scripts/tests/benchmark-report-gate.rb"
TEST_PARENT="$(cd /private/tmp && pwd -P)"
TEST_ROOT="$(/usr/bin/mktemp -d "$TEST_PARENT/jbar-benchmark-release-tests.XXXXXXXX")"
/bin/chmod 0700 "$TEST_ROOT"
TEST_ROOT_IDENTITY="$(/usr/bin/ruby - "$TEST_ROOT" <<'RUBY'
stat = File.lstat(ARGV.fetch(0))
raise unless stat.directory? && !stat.symlink?
puts [stat.dev, stat.ino, stat.uid, stat.gid, format("%o", stat.mode & 0o7777)].join(":")
RUBY
)"

cleanup() {
    local current_identity=""
    if [ "$(dirname "$TEST_ROOT")" = "$TEST_PARENT" ] &&
       [[ "$(basename "$TEST_ROOT")" == jbar-benchmark-release-tests.* ]] &&
       [ -d "$TEST_ROOT" ] && [ ! -L "$TEST_ROOT" ]; then
        if (
            cd "$TEST_ROOT" || exit 1
            current_identity="$(/usr/bin/ruby -e \
                's=File.lstat("."); puts [s.dev,s.ino,s.uid,s.gid,format("%o",s.mode & 07777)].join(":")')" ||
                exit 1
            [ "$current_identity" = "$TEST_ROOT_IDENTITY" ] || exit 1
            /usr/bin/find -x . -depth -mindepth 1 -delete || exit 1
            current_identity="$(/usr/bin/ruby -e \
                's=File.lstat("."); puts [s.dev,s.ino,s.uid,s.gid,format("%o",s.mode & 07777)].join(":")')" ||
                exit 1
            [ "$current_identity" = "$TEST_ROOT_IDENTITY" ]
        ); then
            current_identity="$(/usr/bin/ruby - "$TEST_ROOT" <<'RUBY'
s = File.lstat(ARGV.fetch(0))
puts [s.dev, s.ino, s.uid, s.gid, format("%o", s.mode & 0o7777)].join(":")
RUBY
)" || current_identity=""
            if [ "$current_identity" = "$TEST_ROOT_IDENTITY" ]; then
                /bin/rmdir -- "$TEST_ROOT" ||
                    echo "error: could not remove empty benchmark-release test root: $TEST_ROOT" >&2
            else
                echo "error: refusing replaced benchmark-release test root: $TEST_ROOT" >&2
            fi
        else
            echo "error: refusing changed benchmark-release test cleanup: $TEST_ROOT" >&2
        fi
    else
        echo "error: refusing unsafe benchmark-release test cleanup: $TEST_ROOT" >&2
    fi
}
trap cleanup EXIT INT TERM HUP

fail() { echo "FAIL: $*" >&2; exit 1; }

expect_usage_rejection() {
    local label="$1"
    shift
    local status=0
    set +e
    "$@" > "$TEST_ROOT/$label.stdout" 2> "$TEST_ROOT/$label.stderr"
    status=$?
    set -e
    [ "$status" -eq 2 ] || fail "$label returned $status instead of usage status 2"
    /usr/bin/grep -F 'usage:' "$TEST_ROOT/$label.stderr" >/dev/null ||
        fail "$label did not print bounded usage"
    [ -z "$(/usr/bin/find "$TEST_ROOT" -maxdepth 1 -name 'jbar-benchmark-evidence.*' -print -quit)" ] ||
        fail "$label created benchmark evidence before rejecting input"
}

run_internal_test() {
    local scenario="$1"
    local expected_status="$2"
    local scenario_parent="$TEST_ROOT/internal-$scenario"
    local status=0
    /bin/mkdir "$scenario_parent"
    /bin/chmod 0700 "$scenario_parent"
    set +e
    /usr/bin/env JBAR_BENCHMARK_INTERNAL_SELF_TEST=1 \
        JBAR_BENCHMARK_EVIDENCE_PARENT="$scenario_parent" \
        JBAR_BENCHMARK_BUILD_PARENT="$scenario_parent" \
        "$HARNESS" --internal-self-test "$scenario" \
        > "$TEST_ROOT/internal-$scenario.stdout" \
        2> "$TEST_ROOT/internal-$scenario.stderr"
    status=$?
    set -e
    [ "$status" -eq "$expected_status" ] ||
        fail "internal $scenario returned $status instead of $expected_status"
}

/bin/bash -n "$HARNESS"
/usr/bin/ruby -c "$GATE" > "$TEST_ROOT/ruby-syntax.stdout"
"$HARNESS" --self-test > "$TEST_ROOT/harness-self-test.stdout"
"$GATE" --self-test > "$TEST_ROOT/gate-self-test.stdout"
/usr/bin/grep -F 'PASS:' "$TEST_ROOT/harness-self-test.stdout" >/dev/null ||
    fail "harness self-test did not pass"
/usr/bin/grep -F 'PASS:' "$TEST_ROOT/gate-self-test.stdout" >/dev/null ||
    fail "report-gate self-test did not pass"

expect_usage_rejection samples-zero "$HARNESS" 0
expect_usage_rejection samples-leading-zero "$HARNESS" 01
expect_usage_rejection samples-injection "$HARNESS" '1;id'
expect_usage_rejection too-many-arguments "$HARNESS" 1 2
expect_usage_rejection process-zero /usr/bin/env JBAR_BENCHMARK_PROCESSES=0 "$HARNESS" 1
expect_usage_rejection real-process-zero /usr/bin/env JBAR_BENCHMARK_REAL_PROCESSES=0 "$HARNESS" 1
expect_usage_rejection real-mode-invalid /usr/bin/env JBAR_BENCHMARK_INCLUDE_REAL=yes "$HARNESS" 1
expect_usage_rejection fixture-duplicate /usr/bin/env \
    'JBAR_BENCHMARK_SYNTHETIC_SIZES=10000 10000' "$HARNESS" 1
expect_usage_rejection fixture-injection /usr/bin/env \
    'JBAR_BENCHMARK_SYNTHETIC_SIZES=10000;id' "$HARNESS" 1
expect_usage_rejection relative-evidence-parent /usr/bin/env \
    'JBAR_BENCHMARK_EVIDENCE_PARENT=relative' "$HARNESS" 1

UNSAFE_PARENT="$TEST_ROOT/unsafe-shared-parent"
/bin/mkdir "$UNSAFE_PARENT"
/bin/chmod 0777 "$UNSAFE_PARENT"
expect_usage_rejection unsafe-shared-parent /usr/bin/env \
    JBAR_BENCHMARK_EVIDENCE_PARENT="$UNSAFE_PARENT" "$HARNESS" 1
[ -z "$(/usr/bin/find "$UNSAFE_PARENT" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
    fail "unsafe shared parent received evidence before rejection"

UNSAFE_ANCESTOR="$TEST_ROOT/unsafe-replaceable-ancestor"
PRIVATE_UNDER_UNSAFE="$UNSAFE_ANCESTOR/private-child"
/bin/mkdir -p "$PRIVATE_UNDER_UNSAFE"
/bin/chmod 0777 "$UNSAFE_ANCESTOR"
/bin/chmod 0700 "$PRIVATE_UNDER_UNSAFE"
expect_usage_rejection unsafe-ancestor /usr/bin/env \
    JBAR_BENCHMARK_EVIDENCE_PARENT="$PRIVATE_UNDER_UNSAFE" "$HARNESS" 1
[ -z "$(/usr/bin/find "$PRIVATE_UNDER_UNSAFE" -mindepth 1 -maxdepth 1 -print -quit)" ] ||
    fail "private child under a replaceable ancestor received evidence"

SAFE_REAL_PARENT="$TEST_ROOT/safe-real-parent"
SYMLINK_PARENT="$TEST_ROOT/symlink-parent"
/bin/mkdir "$SAFE_REAL_PARENT"
/bin/chmod 0700 "$SAFE_REAL_PARENT"
/bin/ln -s "$SAFE_REAL_PARENT" "$SYMLINK_PARENT"
expect_usage_rejection symlink-parent /usr/bin/env \
    JBAR_BENCHMARK_EVIDENCE_PARENT="$SYMLINK_PARENT" "$HARNESS" 1

run_internal_test replace-build 1
REPLACEMENT_BUILD="$(/usr/bin/sed -n 's/^internalReplacementBuild=//p' \
    "$TEST_ROOT/internal-replace-build.stdout")"
[ -n "$REPLACEMENT_BUILD" ] && [ -f "$REPLACEMENT_BUILD/replacement-marker.txt" ] ||
    fail "replacement build directory or marker was deleted"
[ -d "${REPLACEMENT_BUILD}.captured-internal-test" ] ||
    fail "captured build inode was not left separate after replacement"
BUILD_EVIDENCE="$(/usr/bin/sed -n 's/^benchmark evidence retained at: //p' \
    "$TEST_ROOT/internal-replace-build.stdout")"
[ -f "$BUILD_EVIDENCE/result.txt" ] || fail "build-replacement failure result is missing"
/usr/bin/grep -Fx 'exitCode=1' "$BUILD_EVIDENCE/result.txt" >/dev/null ||
    fail "build-replacement result has a contradictory exit code"
/usr/bin/grep -Fx 'result=FAIL' "$BUILD_EVIDENCE/result.txt" >/dev/null ||
    fail "build-replacement result does not fail closed"
/usr/bin/grep -F 'refused unsafe SwiftPM scratch cleanup' "$BUILD_EVIDENCE/result.txt" >/dev/null ||
    fail "build-replacement failure reason is missing"
(
    cd "$BUILD_EVIDENCE" &&
    LC_ALL=C /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null
) || fail "build-replacement failure evidence does not self-verify"

run_internal_test missing-build 1
MISSING_BUILD="$(/usr/bin/sed -n 's/^internalMissingBuild=//p' \
    "$TEST_ROOT/internal-missing-build.stdout")"
CAPTURED_BUILD="$(/usr/bin/sed -n 's/^internalCapturedBuild=//p' \
    "$TEST_ROOT/internal-missing-build.stdout")"
[ ! -e "$MISSING_BUILD" ] && [ ! -L "$MISSING_BUILD" ] ||
    fail "missing-build fixture unexpectedly recreated the publication entry"
[ -d "$CAPTURED_BUILD" ] || fail "renamed-away captured build root was lost"
MISSING_BUILD_EVIDENCE="$(/usr/bin/sed -n 's/^benchmark evidence retained at: //p' \
    "$TEST_ROOT/internal-missing-build.stdout")"
/usr/bin/grep -Fx 'scratchCleanupStatus=1' "$MISSING_BUILD_EVIDENCE/result.txt" >/dev/null ||
    fail "a missing build publication entry was reported as successful cleanup"
/usr/bin/grep -F 'refused unsafe SwiftPM scratch cleanup' \
    "$MISSING_BUILD_EVIDENCE/result.txt" >/dev/null ||
    fail "missing build publication entry lacks the cleanup failure reason"

run_internal_test replace-evidence 1
REPLACEMENT_EVIDENCE="$(/usr/bin/sed -n 's/^internalReplacementEvidence=//p' \
    "$TEST_ROOT/internal-replace-evidence.stdout")"
CAPTURED_EVIDENCE="$(/usr/bin/sed -n 's/^internalCapturedEvidence=//p' \
    "$TEST_ROOT/internal-replace-evidence.stdout")"
[ -f "$REPLACEMENT_EVIDENCE/replacement-marker.txt" ] ||
    fail "replacement evidence directory or marker was deleted"
[ -d "$CAPTURED_EVIDENCE" ] || fail "captured evidence cwd inode was lost"
[ ! -e "$REPLACEMENT_EVIDENCE/result.txt" ] && [ ! -L "$REPLACEMENT_EVIDENCE/result.txt" ] ||
    fail "finalizer wrote through the replaced evidence publication entry"
/usr/bin/grep -F 'evidence parent or directory identity changed' \
    "$TEST_ROOT/internal-replace-evidence.stderr" >/dev/null ||
    fail "evidence replacement did not fail on terminal identity"

run_internal_test hash-replace 0
/usr/bin/grep -F 'PASS: evidence hash rejected an internal replace race' \
    "$TEST_ROOT/internal-hash-replace.stdout" >/dev/null ||
    fail "path replacement during hashing was not rejected"
HASH_REPLACE_EVIDENCE="$(/usr/bin/sed -n 's/^internalEvidence=//p' \
    "$TEST_ROOT/internal-hash-replace.stdout")"
[ ! -e "$HASH_REPLACE_EVIDENCE/SHA256SUMS" ] ||
    fail "replacement-raced hash published a checksum manifest"

run_internal_test hash-change 0
/usr/bin/grep -F 'PASS: evidence hash rejected an internal change race' \
    "$TEST_ROOT/internal-hash-change.stdout" >/dev/null ||
    fail "in-place change during hashing was not rejected"
HASH_CHANGE_EVIDENCE="$(/usr/bin/sed -n 's/^internalEvidence=//p' \
    "$TEST_ROOT/internal-hash-change.stdout")"
[ ! -e "$HASH_CHANGE_EVIDENCE/SHA256SUMS" ] ||
    fail "change-raced hash published a checksum manifest"

run_internal_test checksum-self-verify 0
CHECKSUM_EVIDENCE="$(/usr/bin/sed -n 's/^internalEvidence=//p' \
    "$TEST_ROOT/internal-checksum-self-verify.stdout")"
[ -f "$CHECKSUM_EVIDENCE/SHA256SUMS" ] || fail "checksum self-test manifest is missing"
(
    cd "$CHECKSUM_EVIDENCE" &&
    LC_ALL=C /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null
) || fail "published checksum self-test manifest did not pass shasum -c"

run_internal_test checksum-post-publish-failure 1
POST_PUBLISH_EVIDENCE="$(/usr/bin/sed -n 's/^internalEvidence=//p' \
    "$TEST_ROOT/internal-checksum-post-publish-failure.stdout")"
[ -f "$POST_PUBLISH_EVIDENCE/result.txt" ] ||
    fail "post-publish checksum failure result is missing"
/usr/bin/grep -Fx 'exitCode=1' "$POST_PUBLISH_EVIDENCE/result.txt" >/dev/null ||
    fail "post-publish checksum failure has a contradictory exit code"
/usr/bin/grep -Fx 'result=FAIL' "$POST_PUBLISH_EVIDENCE/result.txt" >/dev/null ||
    fail "post-publish checksum failure retained a PASS result"
/usr/bin/grep -Fx 'checksumManifestStatus=FAIL' "$POST_PUBLISH_EVIDENCE/result.txt" >/dev/null ||
    fail "post-publish checksum failure status is not explicit"
[ ! -e "$POST_PUBLISH_EVIDENCE/SHA256SUMS" ] &&
[ ! -L "$POST_PUBLISH_EVIDENCE/SHA256SUMS" ] ||
    fail "post-publish checksum failure left a stale SHA256SUMS"

run_internal_test result-postcondition-failure 1
RESULT_FAILURE_EVIDENCE="$(/usr/bin/sed -n 's/^internalEvidence=//p' \
    "$TEST_ROOT/internal-result-postcondition-failure.stdout")"
[ -f "$RESULT_FAILURE_EVIDENCE/result.txt" ] ||
    fail "result-postcondition failure did not retain a failure result"
/usr/bin/grep -Fx 'exitCode=1' "$RESULT_FAILURE_EVIDENCE/result.txt" >/dev/null ||
    fail "result-postcondition failure retained exitCode=0"
/usr/bin/grep -Fx 'result=FAIL' "$RESULT_FAILURE_EVIDENCE/result.txt" >/dev/null ||
    fail "result-postcondition failure retained PASS"
/usr/bin/grep -Fx 'checksumManifestStatus=NOT-CREATED' \
    "$RESULT_FAILURE_EVIDENCE/result.txt" >/dev/null ||
    fail "result-postcondition failure incorrectly claims a checksum"
[ ! -e "$RESULT_FAILURE_EVIDENCE/SHA256SUMS" ] &&
[ ! -L "$RESULT_FAILURE_EVIDENCE/SHA256SUMS" ] ||
    fail "result-postcondition failure published SHA256SUMS"

run_internal_test terminal-identity-failure 1
TERMINAL_REPLACEMENT="$(/usr/bin/sed -n 's/^internalTerminalReplacementEvidence=//p' \
    "$TEST_ROOT/internal-terminal-identity-failure.stdout")"
TERMINAL_CAPTURED="$(/usr/bin/sed -n 's/^internalTerminalCapturedEvidence=//p' \
    "$TEST_ROOT/internal-terminal-identity-failure.stdout")"
[ -f "$TERMINAL_REPLACEMENT/replacement-marker.txt" ] ||
    fail "terminal replacement evidence marker was deleted"
[ -d "$TERMINAL_CAPTURED" ] || fail "terminal captured evidence inode was lost"
[ ! -e "$TERMINAL_CAPTURED/SHA256SUMS" ] && [ ! -L "$TERMINAL_CAPTURED/SHA256SUMS" ] ||
    fail "terminal identity failure left a self-verifying checksum"
[ ! -e "$TERMINAL_CAPTURED/result.txt" ] && [ ! -L "$TERMINAL_CAPTURED/result.txt" ] ||
    fail "terminal identity failure left a signed PASS result"
[ ! -e "$TERMINAL_REPLACEMENT/result.txt" ] && [ ! -L "$TERMINAL_REPLACEMENT/result.txt" ] ||
    fail "terminal finalizer wrote result into replacement evidence"

/usr/bin/grep -F 'JBAR_BENCHMARK_PROCESSES:-3' "$HARNESS" >/dev/null ||
    fail "synthetic independent-process default changed"
/usr/bin/grep -F '300000 500000 1000000' "$HARNESS" >/dev/null ||
    fail "publication fixture defaults changed"
/usr/bin/grep -F 'absoluteLatencyThreshold=omitted' "$HARNESS" >/dev/null ||
    fail "shared-machine latency interpretation is missing"

echo "PASS: benchmark release harness rejects unsafe inputs and replacement/hash races without invoking SwiftPM"

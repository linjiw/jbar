#!/bin/bash
# Packaged AppKit lifecycle smoke. The script never intentionally writes the supplied app; its
# before/after manifest covers entry type, mode, owner/group, file size/mtime, path, and file hashes.
# All deliberate bundle mutations happen in a private clone.
# Usage: scripts/tests/appkit-smoke.sh /absolute/path/JBar.app [/absolute/evidence-output-directory]
set -euo pipefail
umask 077

EXPECTED_SOURCE_ID="com.linji.jbar"
DERIVED_ID="com.linji.jbar.appkitsmoke"
DERIVED_EXECUTABLE="JBarAppKitSmoke"
SMOKE_MARKER_KEY="JBarAppKitSmokeVersion"
SMOKE_MARKER_VERSION="1"
MAX_JSON_BYTES=$((64 * 1024))
MAX_PNG_BYTES=$((16 * 1024 * 1024))
MAX_STDOUT_BYTES=$((64 * 1024))
MAX_STDERR_BYTES=$((256 * 1024))
WATCHDOG_SECONDS=25

fail() { echo "FAIL: $*" >&2; exit 1; }

# The supervisor is the app process's direct parent. Until waitpid reaps that exact child, its PID
# cannot be reused, so every TERM/KILL below is tied to a retained child identity rather than a
# kill(0, pid) observation from an unrelated watchdog process.
# Embedded Perl is intentionally a literal; shell expansion would corrupt `$` variables in it.
# shellcheck disable=SC2016
SUPERVISOR_PROGRAM='
use strict;
use warnings;
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use POSIX qw(:sys_wait_h);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

my ($timeout, $grace, $marker, $pid_file, @command) = @ARGV;
if (!defined($timeout) || $timeout !~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/ || $timeout <= 0 ||
    !defined($grace) || $grace !~ /\A(?:\d+(?:\.\d*)?|\.\d+)\z/ || $grace <= 0 ||
    !defined($marker) || !defined($pid_file) || !@command) {
    print STDERR "invalid supervisor arguments\n";
    exit 125;
}

sub monotonic_now { return clock_gettime(CLOCK_MONOTONIC); }

sub decoded_status {
    my ($status) = @_;
    return WEXITSTATUS($status) if WIFEXITED($status);
    return 128 + WTERMSIG($status) if WIFSIGNALED($status);
    return 125;
}

sub poll_child {
    my ($child) = @_;
    my $waited = waitpid($child, WNOHANG);
    my $status = $?;
    return (1, decoded_status($status)) if $waited == $child;
    if ($waited == -1) {
        print STDERR "waitpid lost supervised child $child: $!\n";
        return (-1, 125);
    }
    return (0, 0);
}

sub wait_slice {
    my ($deadline) = @_;
    my $remaining = $deadline - monotonic_now();
    return if $remaining <= 0;
    my $slice = $remaining < 0.01 ? $remaining : 0.01;
    select(undef, undef, undef, $slice);
}

sub terminate_and_reap {
    my ($child, $grace_seconds) = @_;
    kill("TERM", $child);
    my $deadline = monotonic_now() + $grace_seconds;
    while (1) {
        my ($state, $status) = poll_child($child);
        return $status if $state != 0;
        last if monotonic_now() >= $deadline;
        wait_slice($deadline);
    }
    # The child is still ours and still unreaped here. A concurrent exit merely makes it a zombie;
    # it cannot free or recycle this PID before the following exact-child waitpid.
    kill("KILL", $child);
    while (1) {
        my $waited = waitpid($child, 0);
        my $status = $?;
        return decoded_status($status) if $waited == $child;
        next if $waited == -1 && $!{EINTR};
        print STDERR "waitpid could not reap supervised child $child: $!\n";
        return 125;
    }
}

my $requested_exit = 0;
$SIG{INT} = sub { $requested_exit = 130; };
$SIG{TERM} = sub { $requested_exit = 143; };
$SIG{HUP} = sub { $requested_exit = 129; };

my $child = fork();
if (!defined($child)) {
    print STDERR "supervisor fork failed: $!\n";
    exit 125;
}
if ($child == 0) {
    $SIG{INT} = "DEFAULT";
    $SIG{TERM} = "DEFAULT";
    $SIG{HUP} = "DEFAULT";
    {
        no warnings "exec";
        exec { $command[0] } @command;
    }
    print STDERR "supervised exec failed for $command[0]: $!\n";
    POSIX::_exit(127);
}

my $pid_fh;
if (!sysopen($pid_fh, $pid_file, O_WRONLY | O_CREAT | O_EXCL, 0600)) {
    print STDERR "supervisor pid file failed: $!\n";
    terminate_and_reap($child, $grace);
    exit 125;
}
my $pid_ok = print {$pid_fh} "$child\n";
my $close_ok = close($pid_fh);
if (!$pid_ok || !$close_ok) {
    print STDERR "supervisor pid file write failed: $!\n";
    terminate_and_reap($child, $grace);
    exit 125;
}

my $deadline = monotonic_now() + $timeout;
while (1) {
    my ($state, $status) = poll_child($child);
    exit $status if $state == 1;
    exit 125 if $state == -1;
    if ($requested_exit != 0) {
        terminate_and_reap($child, $grace);
        exit $requested_exit;
    }
    if (monotonic_now() >= $deadline) {
        my $marker_fh;
        if (!sysopen($marker_fh, $marker, O_WRONLY | O_CREAT | O_EXCL, 0600)) {
            print STDERR "supervisor timeout marker failed: $!\n";
            terminate_and_reap($child, $grace);
            exit 125;
        }
        my $marker_ok = print {$marker_fh} "timeout child=$child\n";
        my $marker_close_ok = close($marker_fh);
        if (!$marker_ok || !$marker_close_ok) {
            print STDERR "supervisor timeout marker write failed: $!\n";
            terminate_and_reap($child, $grace);
            exit 125;
        }
        terminate_and_reap($child, $grace);
        exit 124;
    }
    wait_slice($deadline);
}
'

# Copy through an exclusively-created private temporary file, then publish with link(2). The final
# destination is never opened for truncation: an existing or concurrently-created name makes the
# hard-link publication fail without modifying that file.
# shellcheck disable=SC2016
EXCLUSIVE_COPY_PROGRAM='
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_WRONLY O_CREAT O_EXCL O_NOFOLLOW :mode);

my ($source, $destination) = @ARGV;
if (!defined($source) || !defined($destination)) {
    print STDERR "invalid exclusive-copy arguments\n";
    exit 1;
}
sysopen(my $input, $source, O_RDONLY | O_NOFOLLOW) or die "exclusive-copy source open: $!\n";
my @source_info = stat($input);
die "exclusive-copy source is not a single-link regular file\n"
    if !@source_info || !S_ISREG($source_info[2]) || $source_info[3] != 1;

my $temporary = "$destination.partial.$$";
sysopen(my $output, $temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
    or die "exclusive-copy temporary create: $!\n";
my $succeeded = 0;
eval {
    my $buffer;
    while (1) {
        my $read = sysread($input, $buffer, 65536);
        die "exclusive-copy read: $!\n" if !defined($read);
        last if $read == 0;
        my $offset = 0;
        while ($offset < $read) {
            my $written = syswrite($output, $buffer, $read - $offset, $offset);
            die "exclusive-copy write: $!\n" if !defined($written) || $written <= 0;
            $offset += $written;
        }
    }
    close($input) or die "exclusive-copy source close: $!\n";
    close($output) or die "exclusive-copy destination close: $!\n";
    link($temporary, $destination) or die "exclusive-copy exclusive publish: $!\n";
    unlink($temporary) or die "exclusive-copy temporary unlink: $!\n";
    my @final_info = lstat($destination);
    die "exclusive-copy final file is unsafe\n"
        if !@final_info || !S_ISREG($final_info[2]) || $final_info[3] != 1 ||
           ($final_info[2] & 0777) != 0600 || $final_info[7] != $source_info[7];
    $succeeded = 1;
};
if (!$succeeded) {
    my $error = $@ || "exclusive-copy failed\n";
    close($input);
    close($output);
    unlink($temporary);
    print STDERR $error;
    exit 1;
}
exit 0;
'

# CrashReporter writes asynchronously after a process exits. Observe the derived executable only,
# require a monotonic quiet interval, and cap the total observation window below two seconds.
# shellcheck disable=SC2016
CRASH_STABILITY_PROGRAM='
use strict;
use warnings;
use Fcntl qw(O_WRONLY O_CREAT O_EXCL :mode);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

my ($directory, $prefix, $output, $maximum, $minimum, $quiet) = @ARGV;
die "invalid crash-stability arguments\n"
    if !defined($quiet) || $maximum !~ /\A\d+(?:\.\d+)?\z/ ||
       $minimum !~ /\A\d+(?:\.\d+)?\z/ || $quiet !~ /\A\d+(?:\.\d+)?\z/ ||
       $maximum <= 0 || $minimum < 0 || $quiet < 0 || $minimum > $maximum;

sub snapshot {
    my ($dir, $name_prefix) = @_;
    return "" if !-d $dir;
    opendir(my $dh, $dir) or die "crash directory open failed: $!\n";
    my @names = sort grep {
        index($_, $name_prefix) == 0 && /\.(?:ips|crash)\z/
    } readdir($dh);
    closedir($dh) or die "crash directory close failed: $!\n";
    die "too many derived crash reports\n" if @names > 1024;
    my $manifest = "";
    for my $name (@names) {
        my $path = "$dir/$name";
        my @info = lstat($path);
        next if !@info || !S_ISREG($info[2]);
        $manifest .= "$path|$info[9]|$info[7]\n";
        die "derived crash manifest is too large\n" if length($manifest) > 1_048_576;
    }
    return $manifest;
}

my $started = clock_gettime(CLOCK_MONOTONIC);
my $deadline = $started + $maximum;
my $last = snapshot($directory, $prefix);
my $last_change = $started;
while (1) {
    my $now = clock_gettime(CLOCK_MONOTONIC);
    last if $now >= $deadline;
    last if $now - $started >= $minimum && $now - $last_change >= $quiet;
    my $remaining = $deadline - $now;
    my $slice = $remaining < 0.05 ? $remaining : 0.05;
    select(undef, undef, undef, $slice) if $slice > 0;
    my $current = snapshot($directory, $prefix);
    if ($current ne $last) {
        $last = $current;
        $last_change = clock_gettime(CLOCK_MONOTONIC);
    }
}

my $output_fh;
sysopen($output_fh, $output, O_WRONLY | O_CREAT | O_EXCL, 0600)
    or die "crash manifest create failed: $!\n";
print {$output_fh} $last or die "crash manifest write failed: $!\n";
close($output_fh) or die "crash manifest close failed: $!\n";
'

# shellcheck disable=SC2016
WAIT_FOR_FILE_PROGRAM='
use strict;
use warnings;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
my ($path, $seconds) = @ARGV;
my $deadline = clock_gettime(CLOCK_MONOTONIC) + $seconds;
while (!-s $path && clock_gettime(CLOCK_MONOTONIC) < $deadline) {
    my $remaining = $deadline - clock_gettime(CLOCK_MONOTONIC);
    my $slice = $remaining < 0.005 ? $remaining : 0.005;
    select(undef, undef, undef, $slice) if $slice > 0;
}
exit(-s $path ? 0 : 1);
'

# shellcheck disable=SC2016
TERM_IGNORE_READY_PROGRAM='
use strict;
use warnings;
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
my ($ready) = @ARGV;
$SIG{TERM} = "IGNORE";
my $ready_fh;
sysopen($ready_fh, $ready, O_WRONLY | O_CREAT | O_EXCL, 0600)
    or die "ready marker create failed: $!\n";
print {$ready_fh} "READY\n" or die "ready marker write failed: $!\n";
close($ready_fh) or die "ready marker close failed: $!\n";
select(undef, undef, undef, 10);
'

clear_and_require_no_acl() {
  local path="$1"
  local acl_matches
  /bin/chmod -N "$path" || fail "could not clear inherited ACL: $path"
  acl_matches="$(/usr/bin/find "$path" -maxdepth 0 -acl -print)" ||
    fail "could not inspect ACL: $path"
  [ -z "$acl_matches" ] || fail "extended ACL remains on private directory: $path"
}

require_acl_free_tree() {
  local path="$1"
  local acl_matches
  acl_matches="$(/usr/bin/find "$path" -acl -print -quit)" || fail "could not inspect ACL tree: $path"
  [ -z "$acl_matches" ] || fail "extended ACL found in private evidence tree: $acl_matches"
}

run_supervisor_self_tests() {
  local self_temp_parent self_root status child_pid
  local self_supervisor_pid="" self_supervisor_active=0
  local unrelated_pid="" unrelated_active=0

  self_temp_parent="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
  self_root="$(/usr/bin/mktemp -d "$self_temp_parent/jbar-supervisor-self-test.XXXXXXXX")"
  /bin/chmod 700 "$self_root"
  case "$self_root" in
    "$self_temp_parent"/jbar-supervisor-self-test.*) ;;
    *) fail "supervisor self-test received an unsafe temporary root" ;;
  esac
  clear_and_require_no_acl "$self_root"
  /bin/chmod 700 "$self_root"

  cleanup_supervisor_self_test() {
    local cleanup_status="$1"
    trap - EXIT INT TERM HUP
    set +e
    if [ "$self_supervisor_active" -eq 1 ] && [ -n "$self_supervisor_pid" ]; then
      /bin/kill -TERM "$self_supervisor_pid" >/dev/null 2>&1
      wait "$self_supervisor_pid" >/dev/null 2>&1
      self_supervisor_active=0
    fi
    if [ "$unrelated_active" -eq 1 ] && [ -n "$unrelated_pid" ]; then
      /bin/kill -TERM "$unrelated_pid" >/dev/null 2>&1
      wait "$unrelated_pid" >/dev/null 2>&1
      unrelated_active=0
    fi
    if [ -d "$self_root" ] && [ ! -L "$self_root" ] &&
       [ "$(dirname "$self_root")" = "$self_temp_parent" ] &&
       [[ "$(basename "$self_root")" == jbar-supervisor-self-test.* ]]; then
      /bin/rm -rf -- "$self_root"
    else
      echo "error: refusing unsafe supervisor self-test cleanup: $self_root" >&2
      [ "$cleanup_status" -ne 0 ] || cleanup_status=1
    fi
    exit "$cleanup_status"
  }
  trap 'cleanup_supervisor_self_test $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  set +e
  /usr/bin/perl -e "$SUPERVISOR_PROGRAM" 2 0.2 "$self_root/exit.marker" "$self_root/exit.pid" \
    /bin/sh -c "exit 23" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -eq 23 ] || fail "supervisor did not propagate child exit 23 (got $status)"
  [ ! -e "$self_root/exit.marker" ] || fail "ordinary exit created a timeout marker"

  set +e
  /usr/bin/perl -e "$SUPERVISOR_PROGRAM" 2 0.2 "$self_root/signal.marker" "$self_root/signal.pid" \
    /bin/sh -c "kill -TERM \$\$" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -eq 143 ] || fail "supervisor did not propagate child SIGTERM (got $status)"
  [ ! -e "$self_root/signal.marker" ] || fail "signalled child created a timeout marker"

  set +e
  /usr/bin/perl -e "$SUPERVISOR_PROGRAM" 0.15 0.15 "$self_root/timeout.marker" "$self_root/timeout.pid" \
    /usr/bin/perl -e "select(undef, undef, undef, 10)" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -eq 124 ] || fail "supervisor timeout status was not 124 (got $status)"
  [ -f "$self_root/timeout.marker" ] && [ ! -L "$self_root/timeout.marker" ] ||
    fail "supervisor timeout marker missing"
  child_pid="$(/usr/bin/sed -n '1p' "$self_root/timeout.pid")"
  case "$child_pid" in *[!0-9]*|'') fail "supervisor timeout PID evidence is invalid" ;; esac
  ! /bin/kill -0 "$child_pid" >/dev/null 2>&1 || fail "timed-out supervised child was not reaped"

  /usr/bin/perl -e "select(undef, undef, undef, 10)" >/dev/null 2>&1 &
  unrelated_pid=$!
  unrelated_active=1

  # The child publishes READY only after installing SIGTERM=IGNORE. Waiting for that handshake
  # ensures this case really exercises the supervisor grace deadline and KILL escalation.
  /usr/bin/perl -e "$SUPERVISOR_PROGRAM" 1 0.15 "$self_root/isolation.marker" "$self_root/isolation.pid" \
    /usr/bin/perl -e "$TERM_IGNORE_READY_PROGRAM" "$self_root/isolation.ready" >/dev/null 2>&1 &
  self_supervisor_pid=$!
  self_supervisor_active=1
  /usr/bin/perl -e "$WAIT_FOR_FILE_PROGRAM" "$self_root/isolation.ready" 0.75 ||
    fail "TERM-ignoring child did not confirm its signal handler"
  [ -f "$self_root/isolation.ready" ] && [ ! -L "$self_root/isolation.ready" ] ||
    fail "TERM-ignore ready marker is unsafe"
  [ "$(/usr/bin/sed -n '1p' "$self_root/isolation.ready")" = READY ] ||
    fail "TERM-ignore ready marker is invalid"
  set +e
  wait "$self_supervisor_pid"
  status=$?
  set -e
  self_supervisor_active=0
  [ "$status" -eq 124 ] || fail "isolation timeout status was not 124 (got $status)"
  child_pid="$(/usr/bin/sed -n '1p' "$self_root/isolation.pid")"
  case "$child_pid" in *[!0-9]*|'') fail "KILL-escalation PID evidence is invalid" ;; esac
  ! /bin/kill -0 "$child_pid" >/dev/null 2>&1 ||
    fail "TERM-ignoring child survived supervisor KILL escalation"
  /bin/kill -0 "$unrelated_pid" >/dev/null 2>&1 || fail "supervisor affected an unrelated process"
  /bin/kill -TERM "$unrelated_pid" >/dev/null 2>&1
  set +e
  wait "$unrelated_pid" >/dev/null 2>&1
  set -e
  unrelated_active=0

  /usr/bin/perl -e "$SUPERVISOR_PROGRAM" 10 0.2 "$self_root/interrupt.marker" "$self_root/interrupt.pid" \
    /usr/bin/perl -e "select(undef, undef, undef, 10)" >/dev/null 2>&1 &
  self_supervisor_pid=$!
  self_supervisor_active=1
  /usr/bin/perl -e "$WAIT_FOR_FILE_PROGRAM" "$self_root/interrupt.pid" 2 ||
    fail "interrupted supervisor did not publish its child PID"
  child_pid="$(/usr/bin/sed -n '1p' "$self_root/interrupt.pid")"
  case "$child_pid" in *[!0-9]*|'') fail "interrupted supervisor PID evidence is invalid" ;; esac
  /bin/kill -TERM "$self_supervisor_pid"
  set +e
  wait "$self_supervisor_pid"
  status=$?
  set -e
  self_supervisor_active=0
  [ "$status" -eq 143 ] || fail "interrupted supervisor status was not 143 (got $status)"
  [ ! -e "$self_root/interrupt.marker" ] || fail "supervisor interruption created a timeout marker"
  ! /bin/kill -0 "$child_pid" >/dev/null 2>&1 || fail "interrupted supervisor left its child alive"

  echo "PASS: 5 supervisor safety cases"
  cleanup_supervisor_self_test 0
}

if [ "$#" -eq 1 ] && [ "$1" = "--self-test-supervisor" ]; then
  run_supervisor_self_tests
  # ShellCheck cannot see that this helper exits via `fail` or returns here when invoked above.
  # shellcheck disable=SC2317
  exit 0
fi

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || {
  echo "usage: $0 /absolute/path/JBar.app [/absolute/evidence-output-directory]" >&2
  exit 2
}

SOURCE_INPUT="$1"
EVIDENCE_OUTPUT_INPUT="${2:-}"
case "$SOURCE_INPUT" in
  /*) ;;
  *) fail "source app path must be absolute" ;;
esac
[ -d "$SOURCE_INPUT" ] && [ ! -L "$SOURCE_INPUT" ] || fail "source app must be a non-symlink directory"
SOURCE_PARENT="$(cd "$(dirname "$SOURCE_INPUT")" && pwd -P)"
SOURCE_APP="$SOURCE_PARENT/$(basename "$SOURCE_INPUT")"
[ -d "$SOURCE_APP" ] && [ ! -L "$SOURCE_APP" ] || fail "source app did not resolve to a safe directory"

TEMP_PARENT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
WORK_ROOT="$(/usr/bin/mktemp -d "$TEMP_PARENT/jbar-appkit-smoke.XXXXXXXX")"
/bin/chmod 700 "$WORK_ROOT"
case "$WORK_ROOT" in
  "$TEMP_PARENT"/jbar-appkit-smoke.*) ;;
  *) fail "mktemp returned an unexpected work root: $WORK_ROOT" ;;
esac

CLONE_APP="$WORK_ROOT/JBarAppKitSmoke.app"
STATE_ROOT="$WORK_ROOT/state"
ISOLATION_ROOT="$WORK_ROOT/isolation"
ISOLATED_HOME="$ISOLATION_ROOT/home"
ISOLATED_CONFIG="$ISOLATION_ROOT/xdg-config"
ISOLATED_TMP="$ISOLATION_ROOT/tmp"
STDOUT_LOG="$WORK_ROOT/stdout.log"
STDERR_LOG="$WORK_ROOT/stderr.log"
CRASH_BEFORE="$WORK_ROOT/crash-before.txt"
CRASH_AFTER="$WORK_ROOT/crash-after.txt"
CRASH_DIFF="$WORK_ROOT/crash-diff.txt"
WATCHDOG_MARKER="$WORK_ROOT/watchdog-fired"
SOURCE_BEFORE="$WORK_ROOT/source-before.txt"
SOURCE_AFTER="$WORK_ROOT/source-after.txt"
EVIDENCE_OUTPUT=""
OUTPUT_CREATED=0
OUTPUT_PUBLISHED=0
APP_PID=""
APP_PID_FILE="$WORK_ROOT/app.pid"
SUPERVISOR_PID=""
SUPERVISOR_ACTIVE=0

safe_remove_work_root() {
  if [ -d "$WORK_ROOT" ] && [ ! -L "$WORK_ROOT" ] &&
     [ "$(dirname "$WORK_ROOT")" = "$TEMP_PARENT" ] &&
     [[ "$(basename "$WORK_ROOT")" == jbar-appkit-smoke.* ]]; then
    /bin/rm -rf -- "$WORK_ROOT"
  else
    echo "error: refusing unsafe AppKit smoke cleanup: $WORK_ROOT" >&2
    return 1
  fi
}

publish_available_evidence() {
  [ "$OUTPUT_CREATED" -eq 1 ] || return 0
  [ "$OUTPUT_PUBLISHED" -eq 0 ] || return 0
  local source
  local destination
  local name
  local publish_failed=0
  for name in evidence.json panel.png clean-termination.marker stdout.log stderr.log crash-diff.txt; do
    case "$name" in
      evidence.json|panel.png|clean-termination.marker) source="$STATE_ROOT/$name" ;;
      stdout.log) source="$STDOUT_LOG" ;;
      stderr.log) source="$STDERR_LOG" ;;
      crash-diff.txt) source="$CRASH_DIFF" ;;
    esac
    destination="$EVIDENCE_OUTPUT/$name"
    if [ -f "$source" ] && [ ! -L "$source" ]; then
      /usr/bin/perl -e "$EXCLUSIVE_COPY_PROGRAM" "$source" "$destination" || publish_failed=1
    fi
  done
  OUTPUT_PUBLISHED=1
  return "$publish_failed"
}

handle_exit() {
  local status="$1"
  local cleanup_failed=0
  trap - EXIT INT TERM HUP
  set +e
  if [ "$SUPERVISOR_ACTIVE" -eq 1 ] && [ -n "$SUPERVISOR_PID" ]; then
    # Never signal the app PID here. The still-unreaped supervisor is the only process allowed to
    # terminate and reap its exact child, including when this script receives INT/TERM/HUP.
    /bin/kill -TERM "$SUPERVISOR_PID" >/dev/null 2>&1
    wait "$SUPERVISOR_PID" >/dev/null 2>&1
    SUPERVISOR_ACTIVE=0
  fi
  publish_available_evidence || cleanup_failed=1
  safe_remove_work_root || cleanup_failed=1
  if [ "$cleanup_failed" -ne 0 ] && [ "$status" -eq 0 ]; then status=1; fi
  exit "$status"
}
trap 'handle_exit $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

clear_and_require_no_acl "$WORK_ROOT"
/bin/chmod 700 "$WORK_ROOT"
[ "$(/usr/bin/stat -f '%Mp%Lp' "$WORK_ROOT")" = 0700 ] || fail "work root mode is not 0700"
[ "$(/usr/bin/stat -f '%u' "$WORK_ROOT")" = "$(/usr/bin/id -u)" ] ||
  fail "work root is not owned by the current user"

if [ -n "$EVIDENCE_OUTPUT_INPUT" ]; then
  case "$EVIDENCE_OUTPUT_INPUT" in
    /*) ;;
    *) fail "evidence output path must be absolute" ;;
  esac
  [ ! -e "$EVIDENCE_OUTPUT_INPUT" ] && [ ! -L "$EVIDENCE_OUTPUT_INPUT" ] ||
    fail "evidence output must not already exist"
  OUTPUT_PARENT="$(cd "$(dirname "$EVIDENCE_OUTPUT_INPUT")" && pwd -P)"
  EVIDENCE_OUTPUT="$OUTPUT_PARENT/$(basename "$EVIDENCE_OUTPUT_INPUT")"
  [ "$EVIDENCE_OUTPUT" = "$EVIDENCE_OUTPUT_INPUT" ] ||
    fail "evidence output path must already be absolute and standardized"
  case "$EVIDENCE_OUTPUT/" in
    "$SOURCE_APP/"*) fail "evidence output must not be inside the signed source app" ;;
  esac
  /bin/mkdir -m 700 "$EVIDENCE_OUTPUT"
  OUTPUT_CREATED=1
  [ -d "$EVIDENCE_OUTPUT" ] && [ ! -L "$EVIDENCE_OUTPUT" ] || fail "could not create safe evidence output"
  clear_and_require_no_acl "$EVIDENCE_OUTPUT"
  /bin/chmod 700 "$EVIDENCE_OUTPUT"
  [ "$(/usr/bin/stat -f '%Mp%Lp' "$EVIDENCE_OUTPUT")" = 0700 ] || fail "evidence output mode is not 0700"
  [ "$(/usr/bin/stat -f '%u' "$EVIDENCE_OUTPUT")" = "$(/usr/bin/id -u)" ] ||
    fail "evidence output is not owned by the current user"
fi

assert_plain_bundle_tree() {
  local app="$1"
  [ -z "$(/usr/bin/find "$app" -type l -print -quit)" ] || fail "bundle contains a symbolic link: $app"
  [ -z "$(/usr/bin/find "$app" ! -type d ! -type f -print -quit)" ] || fail "bundle contains a special file: $app"
  [ -z "$(/usr/bin/find "$app" -type f -links +1 -print -quit)" ] || fail "bundle contains a hard-linked file: $app"
  require_acl_free_tree "$app"
}

bundle_manifest() {
  local app="$1"
  local output="$2"
  # This bounded-to-bundle manifest intentionally covers the fields named in the file header; it
  # does not claim to detect metadata classes that are outside those explicit stat/hash records.
  {
    /usr/bin/find "$app" -type d -exec /usr/bin/stat -f 'D|%Lp|%u|%g|%N' {} \;
    /usr/bin/find "$app" -type f -exec /usr/bin/stat -f 'F|%Lp|%u|%g|%z|%m|%N' {} \;
    /usr/bin/find "$app" -type f -exec /usr/bin/shasum -a 256 {} \;
  } | /usr/bin/sort > "$output"
}

SOURCE_PLIST="$SOURCE_APP/Contents/Info.plist"
SOURCE_EXECUTABLE="$SOURCE_APP/Contents/MacOS/JBar"
[ -f "$SOURCE_PLIST" ] && [ ! -L "$SOURCE_PLIST" ] || fail "source Info.plist is not a regular file"
[ -f "$SOURCE_EXECUTABLE" ] && [ ! -L "$SOURCE_EXECUTABLE" ] && [ -x "$SOURCE_EXECUTABLE" ] ||
  fail "source JBar executable is missing or unsafe"
assert_plain_bundle_tree "$SOURCE_APP"
/usr/bin/plutil -lint "$SOURCE_PLIST" >/dev/null || fail "source Info.plist is invalid"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_PLIST" 2>/dev/null || true)" = "$EXPECTED_SOURCE_ID" ] ||
  fail "source bundle identifier is not $EXPECTED_SOURCE_ID"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SOURCE_PLIST" 2>/dev/null || true)" = JBar ] ||
  fail "source CFBundleExecutable is not JBar"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$SOURCE_PLIST" 2>/dev/null || true)" = APPL ] ||
  fail "source bundle is not APPL"
[ -z "$(/usr/libexec/PlistBuddy -c "Print :$SMOKE_MARKER_KEY" "$SOURCE_PLIST" 2>/dev/null || true)" ] ||
  fail "source bundle already contains the private smoke marker"
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP" >/dev/null 2>&1 || fail "source app signature is invalid"
SOURCE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_PLIST")"
SOURCE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_PLIST")"
bundle_manifest "$SOURCE_APP" "$SOURCE_BEFORE"
SOURCE_VERSION_OUTPUT="$("$SOURCE_EXECUTABLE" --version)"
case "$SOURCE_VERSION_OUTPUT" in
  "JBar $SOURCE_VERSION"|"JBar $SOURCE_VERSION ($SOURCE_BUILD) · "*) ;;
  *) fail "source executable version does not match Info.plist" ;;
esac

/usr/bin/ditto --noqtn "$SOURCE_APP" "$CLONE_APP"
assert_plain_bundle_tree "$CLONE_APP"
CLONE_PLIST="$CLONE_APP/Contents/Info.plist"
CLONE_OLD_EXECUTABLE="$CLONE_APP/Contents/MacOS/JBar"
DERIVED_EXECUTABLE_PATH="$CLONE_APP/Contents/MacOS/$DERIVED_EXECUTABLE"
[ -f "$CLONE_OLD_EXECUTABLE" ] && [ ! -L "$CLONE_OLD_EXECUTABLE" ] || fail "cloned executable is unsafe"
/bin/mv "$CLONE_OLD_EXECUTABLE" "$DERIVED_EXECUTABLE_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DERIVED_ID" "$CLONE_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $DERIVED_EXECUTABLE" "$CLONE_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DERIVED_EXECUTABLE" "$CLONE_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DERIVED_EXECUTABLE" "$CLONE_PLIST"
/usr/libexec/PlistBuddy -c "Add :$SMOKE_MARKER_KEY string $SMOKE_MARKER_VERSION" "$CLONE_PLIST"
/usr/bin/plutil -lint "$CLONE_PLIST" >/dev/null
assert_plain_bundle_tree "$CLONE_APP"
/usr/bin/codesign --force --sign - "$CLONE_APP" >/dev/null 2>&1
/usr/bin/codesign --verify --deep --strict "$CLONE_APP" >/dev/null 2>&1 || fail "derived clone signature is invalid"
assert_plain_bundle_tree "$CLONE_APP"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CLONE_PLIST")" = "$DERIVED_ID" ] ||
  fail "derived bundle identifier mismatch"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$CLONE_PLIST")" = "$DERIVED_EXECUTABLE" ] ||
  fail "derived executable identity mismatch"
[ "$(/usr/libexec/PlistBuddy -c "Print :$SMOKE_MARKER_KEY" "$CLONE_PLIST")" = "$SMOKE_MARKER_VERSION" ] ||
  fail "derived smoke version marker mismatch"
DERIVED_VERSION_OUTPUT="$("$DERIVED_EXECUTABLE_PATH" --version)"
case "$DERIVED_VERSION_OUTPUT" in
  "JBar $SOURCE_VERSION"|"JBar $SOURCE_VERSION ($SOURCE_BUILD) · "*) ;;
  *) fail "derived executable version does not match the verified source" ;;
esac

for directory in "$STATE_ROOT" "$ISOLATION_ROOT" "$ISOLATED_HOME" "$ISOLATED_CONFIG" "$ISOLATED_TMP"; do
  /bin/mkdir -m 700 "$directory"
  [ -d "$directory" ] && [ ! -L "$directory" ] || fail "could not create private directory: $directory"
  clear_and_require_no_acl "$directory"
  /bin/chmod 700 "$directory"
  [ "$(/usr/bin/stat -f '%Mp%Lp' "$directory")" = 0700 ] || fail "private directory mode is not 0700: $directory"
done

DIAGNOSTIC_REPORTS="${HOME}/Library/Logs/DiagnosticReports"
snapshot_smoke_crashes() {
  local output="$1"
  if [ -d "$DIAGNOSTIC_REPORTS" ]; then
    /usr/bin/find "$DIAGNOSTIC_REPORTS" -maxdepth 1 -type f \
      \( -name "$DERIVED_EXECUTABLE*.ips" -o -name "$DERIVED_EXECUTABLE*.crash" \) \
      -exec /usr/bin/stat -f '%N|%m|%z' {} \; | /usr/bin/sort > "$output"
  else
    : > "$output"
  fi
}
snapshot_smoke_crashes "$CRASH_BEFORE"

set +e
/usr/bin/env \
  HOME="$ISOLATED_HOME" \
  CFFIXED_USER_HOME="$ISOLATED_HOME" \
  XDG_CONFIG_HOME="$ISOLATED_CONFIG" \
  TMPDIR="$ISOLATED_TMP" \
  /usr/bin/perl -e "$SUPERVISOR_PROGRAM" "$WATCHDOG_SECONDS" 2 "$WATCHDOG_MARKER" "$APP_PID_FILE" \
  "$DERIVED_EXECUTABLE_PATH" --appkit-smoke "$STATE_ROOT" >"$STDOUT_LOG" 2>"$STDERR_LOG" &
SUPERVISOR_PID=$!
SUPERVISOR_ACTIVE=1
wait "$SUPERVISOR_PID"
APP_STATUS=$?
SUPERVISOR_ACTIVE=0
set -e

[ -f "$APP_PID_FILE" ] && [ ! -L "$APP_PID_FILE" ] || fail "supervisor app PID evidence is missing or unsafe"
[ "$(/usr/bin/stat -f '%Lp' "$APP_PID_FILE")" = 600 ] || fail "supervisor app PID evidence mode is not 0600"
[ "$(/usr/bin/stat -f '%l' "$APP_PID_FILE")" = 1 ] || fail "supervisor app PID evidence is hard-linked"
[ "$(/usr/bin/stat -f '%u' "$APP_PID_FILE")" = "$(/usr/bin/id -u)" ] ||
  fail "supervisor app PID evidence has the wrong owner"
APP_PID="$(/usr/bin/sed -n '1p' "$APP_PID_FILE")"
case "$APP_PID" in *[!0-9]*|'') fail "supervisor app PID evidence is invalid" ;; esac

/usr/bin/perl -e "$CRASH_STABILITY_PROGRAM" \
  "$DIAGNOSTIC_REPORTS" "$DERIVED_EXECUTABLE" "$CRASH_AFTER" 1.8 0.8 0.25 ||
  fail "could not obtain a stable post-exit crash snapshot"
/usr/bin/comm -13 "$CRASH_BEFORE" "$CRASH_AFTER" > "$CRASH_DIFF"
bundle_manifest "$SOURCE_APP" "$SOURCE_AFTER"
/usr/bin/cmp -s "$SOURCE_BEFORE" "$SOURCE_AFTER" || fail "source app changed during smoke"
/usr/bin/codesign --verify --deep --strict "$SOURCE_APP" >/dev/null 2>&1 || fail "source signature changed during smoke"
[ ! -e "$WATCHDOG_MARKER" ] && [ ! -L "$WATCHDOG_MARKER" ] || fail "watchdog terminated AppKit smoke pid $APP_PID"
[ "$APP_STATUS" -eq 0 ] || fail "AppKit smoke exited with status $APP_STATUS"
[ ! -s "$CRASH_DIFF" ] || fail "new $DERIVED_EXECUTABLE crash report detected"

EVIDENCE_JSON="$STATE_ROOT/evidence.json"
PANEL_PNG="$STATE_ROOT/panel.png"
CLEAN_MARKER="$STATE_ROOT/clean-termination.marker"
for file in "$EVIDENCE_JSON" "$PANEL_PNG" "$CLEAN_MARKER" "$STDOUT_LOG" "$STDERR_LOG" "$CRASH_DIFF"; do
  [ -f "$file" ] && [ ! -L "$file" ] || fail "missing or unsafe evidence file: $file"
  [ "$(/usr/bin/stat -f '%Lp' "$file")" = 600 ] || fail "evidence file mode is not 0600: $file"
  [ "$(/usr/bin/stat -f '%l' "$file")" = 1 ] || fail "evidence file is hard-linked: $file"
done
[ -z "$(/usr/bin/find "$STATE_ROOT" ! -type d ! -type f -print -quit)" ] || fail "state root contains links or special files"
UNEXPECTED_STATE_ENTRY="$(/usr/bin/find "$STATE_ROOT" -mindepth 1 -maxdepth 1 \
  ! \( -name evidence.json -o -name panel.png -o -name clean-termination.marker \
       -o -name fixture-first -o -name fixture-second \) -print -quit)"
[ -z "$UNEXPECTED_STATE_ENTRY" ] || fail "unexpected state-root entry: $UNEXPECTED_STATE_ENTRY"
STATE_ENTRY_COUNT="$(/usr/bin/find "$STATE_ROOT" -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[ "$STATE_ENTRY_COUNT" -eq 5 ] || fail "state root does not contain exactly five allowed entries"
for fixture in "$STATE_ROOT/fixture-first" "$STATE_ROOT/fixture-second"; do
  [ -d "$fixture" ] && [ ! -L "$fixture" ] || fail "missing or unsafe fixture directory: $fixture"
  [ "$(/usr/bin/stat -f '%Lp' "$fixture")" = 700 ] || fail "fixture directory mode is not 0700: $fixture"
  [ "$(/usr/bin/stat -f '%u' "$fixture")" = "$(/usr/bin/id -u)" ] ||
    fail "fixture directory has the wrong owner: $fixture"
  [ -z "$(/usr/bin/find "$fixture" -mindepth 1 -print -quit)" ] || fail "fixture directory is not empty: $fixture"
done
JSON_SIZE="$(/usr/bin/stat -f '%z' "$EVIDENCE_JSON")"
PNG_SIZE="$(/usr/bin/stat -f '%z' "$PANEL_PNG")"
STDOUT_SIZE="$(/usr/bin/stat -f '%z' "$STDOUT_LOG")"
STDERR_SIZE="$(/usr/bin/stat -f '%z' "$STDERR_LOG")"
[ "$JSON_SIZE" -gt 0 ] && [ "$JSON_SIZE" -le "$MAX_JSON_BYTES" ] || fail "evidence JSON is not bounded"
[ "$PNG_SIZE" -ge 8 ] && [ "$PNG_SIZE" -le "$MAX_PNG_BYTES" ] || fail "PNG evidence is not bounded"
[ "$STDOUT_SIZE" -le "$MAX_STDOUT_BYTES" ] || fail "stdout evidence exceeds $MAX_STDOUT_BYTES bytes"
[ "$STDERR_SIZE" -le "$MAX_STDERR_BYTES" ] || fail "stderr evidence exceeds $MAX_STDERR_BYTES bytes"
/usr/bin/plutil -convert xml1 -o - "$EVIDENCE_JSON" >/dev/null || fail "evidence JSON is invalid"
[ "$(/usr/bin/plutil -extract schemaVersion raw -o - "$EVIDENCE_JSON")" = 1 ] ||
  fail "evidence schema version mismatch"
[ "$(/usr/bin/plutil -extract status raw -o - "$EVIDENCE_JSON")" = PASS ] || fail "evidence status is not PASS"
[ "$(/usr/bin/plutil -extract bundleIdentifier raw -o - "$EVIDENCE_JSON")" = "$DERIVED_ID" ] ||
  fail "evidence bundle identity mismatch"
[ "$(/usr/bin/plutil -extract executable raw -o - "$EVIDENCE_JSON")" = "$DERIVED_EXECUTABLE" ] ||
  fail "evidence executable identity mismatch"
[ "$(/usr/bin/plutil -extract markerVersion raw -o - "$EVIDENCE_JSON")" = "$SMOKE_MARKER_VERSION" ] ||
  fail "evidence marker version mismatch"
[ "$(/usr/bin/plutil -extract committedQuery raw -o - "$EVIDENCE_JSON")" = ab ] ||
  fail "evidence committed query mismatch"
PROCESS_ARCHITECTURE="$(/usr/bin/plutil -extract processArchitecture raw -o - "$EVIDENCE_JSON")"
case "$PROCESS_ARCHITECTURE" in ''|unknown) fail "evidence process architecture is unknown" ;; esac
[ "$(/usr/bin/plutil -extract exercisedControlKey raw -o - "$EVIDENCE_JSON")" = true ] ||
  fail "Control key evidence missing"
[ "$(/usr/bin/plutil -extract exercisedDeleteKey raw -o - "$EVIDENCE_JSON")" = true ] ||
  fail "Delete key evidence missing"
[ "$(/usr/bin/plutil -extract panelStayedVisibleUntilOpen raw -o - "$EVIDENCE_JSON")" = true ] ||
  fail "panel did not remain visible, key, and text-focused through Control/Delete/Down"
[ "$(/usr/bin/plutil -extract panelHidden raw -o - "$EVIDENCE_JSON")" = true ] || fail "panel did not hide"
RECORDED_PATH="$(/usr/bin/plutil -extract recordedOpenPath raw -o - "$EVIDENCE_JSON")"
EXPECTED_PATH="$(/usr/bin/plutil -extract expectedSecondPath raw -o - "$EVIDENCE_JSON")"
[ "$RECORDED_PATH" = "$EXPECTED_PATH" ] || fail "recorded and expected second-row paths differ"
[ -d "$EXPECTED_PATH" ] && [ ! -L "$EXPECTED_PATH" ] || fail "expected second-row target is unsafe"
EXPECTED_PHYSICAL="$(cd "$EXPECTED_PATH" && pwd -P)"
FIXTURE_PHYSICAL="$(cd "$STATE_ROOT/fixture-second" && pwd -P)"
[ "$EXPECTED_PHYSICAL" = "$FIXTURE_PHYSICAL" ] ||
  fail "Down+Return evidence did not record exactly the second row"
[ "$(/usr/bin/plutil -extract unicodeRows.0 raw -o - "$EVIDENCE_JSON")" = 'ab・兼容测试甲' ] ||
  fail "first Unicode row evidence mismatch"
[ "$(/usr/bin/plutil -extract unicodeRows.1 raw -o - "$EVIDENCE_JSON")" = 'ab・兼容测试乙' ] ||
  fail "second Unicode row evidence mismatch"
KEYBOARD_LIMITATION="$(/usr/bin/plutil -extract scopeLimitations.0 raw -o - "$EVIDENCE_JSON")"
IME_LIMITATION="$(/usr/bin/plutil -extract scopeLimitations.1 raw -o - "$EVIDENCE_JSON")"
WORKSPACE_LIMITATION="$(/usr/bin/plutil -extract scopeLimitations.2 raw -o - "$EVIDENCE_JSON")"
PACKAGE_LIMITATION="$(/usr/bin/plutil -extract scopeLimitations.3 raw -o - "$EVIDENCE_JSON")"
case "$KEYBOARD_LIMITATION" in *"physical keyboard"*"hardware key path"*) ;; *) fail "physical-keyboard limitation missing" ;; esac
case "$IME_LIMITATION" in *"real IME"*"system-language workflow"*) ;; *) fail "IME/system-language limitation missing" ;; esac
case "$WORKSPACE_LIMITATION" in *"without invoking NSWorkspace or LaunchServices"*) ;; *) fail "workspace limitation missing" ;; esac
case "$PACKAGE_LIMITATION" in *"ad-hoc-signed derived clone"*"Gatekeeper"*"notarization"*"LaunchServices"*) ;;
  *) fail "packaging trust limitation missing" ;;
esac
[ "$(/usr/bin/od -An -tx1 -N8 "$PANEL_PNG" | /usr/bin/tr -d ' \n')" = 89504e470d0a1a0a ] ||
  fail "snapshot does not have a PNG signature"
/usr/bin/sips -g pixelWidth -g pixelHeight "$PANEL_PNG" >/dev/null 2>&1 || fail "snapshot dimensions are invalid"
[ "$(/usr/bin/wc -l < "$CLEAN_MARKER" | /usr/bin/tr -d ' ')" = 1 ] || fail "clean marker has unexpected content"
[ "$(/usr/bin/sed -n '1p' "$CLEAN_MARKER")" = PASS ] || fail "clean termination marker is not PASS"
require_acl_free_tree "$WORK_ROOT"

publish_available_evidence || fail "could not publish retained evidence"
if [ -n "$EVIDENCE_OUTPUT" ]; then require_acl_free_tree "$EVIDENCE_OUTPUT"; fi
if [ -n "$EVIDENCE_OUTPUT" ]; then
  echo "PASS: packaged AppKit lifecycle smoke; evidence: $EVIDENCE_OUTPUT"
else
  echo "PASS: packaged AppKit lifecycle smoke"
fi

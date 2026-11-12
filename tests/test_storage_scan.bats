#!/usr/bin/env bats
# X-29: how lyrebird-storage.sh looks at the directories it was configured with.
#
# - A configured directory may itself be a symlink to the real one (a log
#   directory moved to another volume, /var/log -> /var/volatile/log on read-only
#   images): the recording and buffer sites already used `find -H`; the log, temp
#   and MediaMTX-log sites used plain find, which sees only the link.
# - A directory is made absolute when the script loads, so a relative value that
#   starts with "-" cannot be read as a find option.
# - A listing that fails is a counted failure with find's own message, not an
#   empty result: the old `2>/dev/null` made "could not look" read as "nothing
#   to clean".
# - The stale *.tmp cleanup of truncate_large_logs goes through safe_delete.
#
# The real script runs in a child shell whose every directory is private to the
# test (tests/storage_helper.bash).

load scratch_tmpdir
load storage_helper

setup() {
    scratch_setup
    storage_setup
}

teardown() {
    storage_teardown
    scratch_teardown
}

_age() { touch -d "${2:-45 days ago}" "$1"; }

# --- configured directories are absolute ---------------------------------------------

@test "a relative recording directory that starts with a dash is cleaned: 'Cleaned 0' with a 45-day-old file left was the bug [X-29]" {
    mkdir -p "$ST_CWD/-rec/-sub"
    echo data >"$ST_CWD/-rec/old.opus"
    echo data >"$ST_CWD/-rec/-sub/-old.aac"
    echo data >"$ST_CWD/-rec/new.opus"
    echo keep >"$ST_CWD/outside.opus"
    _age "$ST_CWD/-rec/old.opus"
    _age "$ST_CWD/-rec/-sub/-old.aac"
    _age "$ST_CWD/outside.opus"
    ST_ENV=(LYREBIRD_RECORDING_DIR=-rec)
    run storage_run cleanup_recordings
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cleaned 2 recording file(s)"* ]] || { echo "$output"; return 1; }
    [ ! -e "$ST_CWD/-rec/old.opus" ]
    [ ! -e "$ST_CWD/-rec/-sub/-old.aac" ]
    [ -e "$ST_CWD/-rec/new.opus" ]
    [ -e "$ST_CWD/outside.opus" ]                    # the working directory is not the recording directory
    # the same through emergency eviction and status
    echo data >"$ST_CWD/-rec/evict.opus"
    _age "$ST_CWD/-rec/evict.opus" "3 hours ago"
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$ST_CWD/-rec/evict.opus" ]
    run storage_run cmd_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Path: $ST_CWD/-rec"* ]]
    [[ "$output" == *"Files: 1"* ]]
}

@test "relative log, temp and MediaMTX-log directories that start with a dash are cleaned too, and are absolute after loading [X-29]" {
    mkdir -p "$ST_CWD/-logs" "$ST_CWD/-tmp"
    echo data >"$ST_CWD/-logs/old.log"
    echo data >"$ST_CWD/-logs/mediamtx-1.out.1"
    echo data >"$ST_CWD/-tmp/lyrebird-old.tmp"
    _age "$ST_CWD/-logs/old.log" "10 days ago"
    _age "$ST_CWD/-logs/mediamtx-1.out.1" "10 days ago"
    _age "$ST_CWD/-tmp/lyrebird-old.tmp" "3 days ago"
    ST_ENV=(LYREBIRD_LOG_DIR=-logs LYREBIRD_TEMP_DIR=-tmp MEDIAMTX_LOG=-logs/mediamtx.out)
    run storage_run cmd_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$ST_CWD/-logs/old.log" ]
    [ ! -e "$ST_CWD/-logs/mediamtx-1.out.1" ]
    [ ! -e "$ST_CWD/-tmp/lyrebird-old.tmp" ]
    run storage_run eval 'printf "%s\n" "$LOG_DIR" "$TEMP_DIR" "$MEDIAMTX_LOG" "$MEDIAMTX_LOG_DIR"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$ST_CWD/-logs" ]
    [ "${lines[1]}" = "$ST_CWD/-tmp" ]
    [ "${lines[2]}" = "$ST_CWD/-logs/mediamtx.out" ]
    [ "${lines[3]}" = "$ST_CWD/-logs" ]
}

@test "the directory of a MediaMTX log named without a directory is the working directory, not the file name; a file in / has the directory / [X-29]" {
    echo data >"$ST_CWD/mediamtx-1.out.1"
    _age "$ST_CWD/mediamtx-1.out.1" "10 days ago"
    ST_ENV=(MEDIAMTX_LOG=mediamtx.out)
    run storage_run cleanup_logs
    [ "$status" -eq 0 ]
    [ ! -e "$ST_CWD/mediamtx-1.out.1" ]              # pre-fix: the "directory" was the name mediamtx.out
    ST_ENV=(MEDIAMTX_LOG=/mediamtx.out)
    run storage_run eval 'printf "%s\n" "$MEDIAMTX_LOG_DIR"'
    [ "$output" = "/" ]
}

# --- configured directories that are symlinks ------------------------------------

@test "retention and emergency cleanup reach the log directory through a symlink [X-29]" {
    mkdir -p "$ST_ROOT/real-logs"
    echo data >"$ST_ROOT/real-logs/old.log"
    echo data >"$ST_ROOT/real-logs/new.log"
    echo data >"$ST_ROOT/real-logs/rotated.log.1.gz"
    echo data >"$ST_ROOT/real-logs/other.gz"
    _age "$ST_ROOT/real-logs/old.log" "10 days ago"
    ln -s "$ST_ROOT/real-logs" "$ST_ROOT/logs-link"
    ST_ENV=(LYREBIRD_LOG_DIR="$ST_ROOT/logs-link")

    run storage_run cleanup_logs
    [ "$status" -eq 0 ]
    [ ! -e "$ST_ROOT/real-logs/old.log" ]            # pre-fix: found nothing through the link
    [ -e "$ST_ROOT/real-logs/new.log" ]
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$ST_ROOT/real-logs/rotated.log.1.gz" ]
    [ ! -e "$ST_ROOT/real-logs/other.gz" ]
    [ -L "$ST_ROOT/logs-link" ]                      # the link and the directory stay
    [ -d "$ST_ROOT/real-logs" ]
}

@test "temp cleanup reaches the temp directory through a symlink, retention and emergency alike [X-29]" {
    mkdir -p "$ST_ROOT/real-tmp"
    echo data >"$ST_ROOT/real-tmp/lyrebird-old.tmp"
    echo data >"$ST_ROOT/real-tmp/lyrebird-new.tmp"
    echo data >"$ST_ROOT/real-tmp/not-ours.tmp"
    _age "$ST_ROOT/real-tmp/lyrebird-old.tmp" "3 days ago"
    _age "$ST_ROOT/real-tmp/not-ours.tmp" "3 days ago"
    ln -s "$ST_ROOT/real-tmp" "$ST_ROOT/tmp-link"
    ST_ENV=(LYREBIRD_TEMP_DIR="$ST_ROOT/tmp-link")

    run storage_run cleanup_temp
    [ "$status" -eq 0 ]
    [ ! -e "$ST_ROOT/real-tmp/lyrebird-old.tmp" ]
    [ -e "$ST_ROOT/real-tmp/lyrebird-new.tmp" ]
    [ -e "$ST_ROOT/real-tmp/not-ours.tmp" ]          # only lyrebird-* is ours
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$ST_ROOT/real-tmp/lyrebird-new.tmp" ]
    [ -e "$ST_ROOT/real-tmp/not-ours.tmp" ]
}

@test "rotated MediaMTX logs and stale temp files are reached when the MediaMTX log directory is a symlink [X-29]" {
    mkdir -p "$ST_ROOT/real-mtx"
    echo data >"$ST_ROOT/real-mtx/mediamtx.out.1"
    echo data >"$ST_ROOT/real-mtx/mediamtx.out.2.gz"
    echo data >"$ST_ROOT/real-mtx/mediamtx-stale.tmp"
    echo data >"$ST_ROOT/real-mtx/syslog.1.gz"
    _age "$ST_ROOT/real-mtx/mediamtx.out.1" "10 days ago"
    _age "$ST_ROOT/real-mtx/mediamtx-stale.tmp" "10 minutes ago"
    ln -s "$ST_ROOT/real-mtx" "$ST_ROOT/mtx-link"
    ST_ENV=(MEDIAMTX_LOG="$ST_ROOT/mtx-link/mediamtx.out")

    run storage_run cleanup_logs
    [ "$status" -eq 0 ]
    [ ! -e "$ST_ROOT/real-mtx/mediamtx.out.1" ]
    run storage_run truncate_large_logs
    [ "$status" -eq 0 ]
    [ ! -e "$ST_ROOT/real-mtx/mediamtx-stale.tmp" ]
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$ST_ROOT/real-mtx/mediamtx.out.2.gz" ]
    [ -e "$ST_ROOT/real-mtx/syslog.1.gz" ]           # a neighbour that is not ours stays
}

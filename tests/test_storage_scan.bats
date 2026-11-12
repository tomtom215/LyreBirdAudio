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

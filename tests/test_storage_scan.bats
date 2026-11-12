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

# --- a listing that fails is a counted failure --------------------------------------
#
# root reads everything, so these run the real script as uid 65534 over a tree
# that user owns, with one subdirectory of mode 000: find cannot open it.

nobody_setup() {
    command -v setpriv >/dev/null || skip "setpriv is not available"
    [[ "$(id -u)" -eq 0 ]] || skip "needs root to drop to another user"
    NOBODY=65534
    mkdir -p "$ST_ROOT/nobody-copy"
    cp "$PROJECT_ROOT/lyrebird-storage.sh" "$ST_ROOT/nobody-copy/"
    chmod -R a+rX "$ST_ROOT/nobody-copy"
    local d="$ST_ROOT"
    while [[ "$d" != "/" && -n "$d" ]]; do
        if ! setpriv --reuid="$NOBODY" --regid="$NOBODY" --clear-groups test -x "$d"; then
            [[ -O "$d" ]] || skip "cannot make $d traversable for another user"
            chmod o+x "$d"
        fi
        d="$(dirname "$d")"
    done
}

# The tree is handed over to the user, then the locked directories are closed
nobody_lock() {
    chown -R "$NOBODY" "$ST_ROOT" "$ST_BUF"
    chmod 000 "$@"
}

# storage_run as uid 65534, from the copy of the script it can read
storage_run_nobody() {
    (
        cd "$ST_CWD" || exit 99
        setpriv --reuid="$NOBODY" --regid="$NOBODY" --clear-groups \
            env PROJECT_ROOT="$ST_ROOT/nobody-copy" HOME=/nonexistent \
            LYREBIRD_RECORDING_DIR="$ST_REC" LYREBIRD_LOG_DIR="$ST_LOGS" \
            LYREBIRD_TEMP_DIR="$ST_TEMP" LYREBIRD_BUFFER_DIR="$ST_BUF" \
            MEDIAMTX_LOG="$ST_LOGS/mediamtx.out" DRY_RUN=false \
            ${ST_ENV[@]+"${ST_ENV[@]}"} \
            bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-storage.sh"; "$@" 2>&1' _ "$@"
    )
}

@test "a directory find cannot read is a counted failure with find's own message, not an empty result: retention, the directory sweep and the exit status [X-29]" {
    nobody_setup
    mkdir -p "$ST_REC/ok" "$ST_REC/locked"
    echo data >"$ST_REC/ok/old.opus"
    echo data >"$ST_REC/locked/old.opus"
    _age "$ST_REC/ok/old.opus"
    _age "$ST_REC/locked/old.opus"
    nobody_lock "$ST_REC/locked"

    run storage_run_nobody cmd_cleanup
    [ "$status" -eq 3 ] || { echo "$output"; return 1; }      # pre-fix: 0, silently
    [[ "$output" == *"Permission denied"* ]]                   # find's own message is no longer thrown away
    [[ "$output" == *"Cannot list $ST_REC completely: find exited with status 1"* ]]
    [[ "$output" == *"Cannot sweep the empty directories of $ST_REC completely"* ]]
    [[ "$output" == *"directory listing(s) that failed; what could not be listed was not cleaned"* ]]
    [[ "$output" != *"Cleanup completed"* ]]                   # not reported as a clean run
    [[ "$output" == *"Cleaned 1 recording file(s)"* ]]
    [ ! -e "$ST_REC/ok/old.opus" ]                              # what could be reached was still cleaned
}

@test "log and emergency listings that fail are counted too; the readable files are still cleaned [X-29]" {
    nobody_setup
    mkdir -p "$ST_LOGS/locked" "$ST_REC/locked"
    echo data >"$ST_LOGS/old.log"
    echo data >"$ST_LOGS/locked/old.log"
    echo data >"$ST_REC/evict.opus"
    _age "$ST_LOGS/old.log" "10 days ago"
    _age "$ST_LOGS/locked/old.log" "10 days ago"
    _age "$ST_REC/evict.opus" "3 hours ago"
    nobody_lock "$ST_LOGS/locked" "$ST_REC/locked"

    run storage_run_nobody cleanup_logs
    [ "$status" -eq 0 ]
    [[ "$output" == *"Cannot list $ST_LOGS completely"* ]]
    [ ! -e "$ST_LOGS/old.log" ]
    run storage_run_nobody cmd_emergency
    [ "$status" -eq 3 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Cannot list $ST_REC completely"* ]]     # the eviction listing
    [[ "$output" == *"Cannot list $ST_LOGS completely"* ]]    # the rotated-log sweep
    [ ! -e "$ST_REC/evict.opus" ]
}

@test "status over a tree with an unreadable directory prints everything it can and says the counts are incomplete, instead of stopping after its heading [X-29]" {
    nobody_setup
    mkdir -p "$ST_REC/ok" "$ST_REC/locked"
    echo data >"$ST_REC/ok/a.opus"
    echo data >"$ST_REC/locked/b.opus"
    nobody_lock "$ST_REC/locked"

    run storage_run_nobody cmd_status
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }       # pre-fix: 1 after "Recordings:", du under pipefail
    [[ "$output" == *"Path: $ST_REC"* ]]
    [[ "$output" == *"Files: 1"* ]]
    [[ "$output" == *"Permission denied"* ]]
    [[ "$output" == *"(incomplete: part of $ST_REC could not be read"* ]]
    [[ "$output" == *"Retention: 30 days"* ]]
    [[ "$output" == *"Emergency threshold"* ]]                 # the rest of the report is there
}

@test "a configured directory that does not exist has nothing to clean and is not a failure [X-29]" {
    ST_ENV=(LYREBIRD_TEMP_DIR="$ST_ROOT/no-such-tmp" LYREBIRD_RECORDING_DIR="$ST_ROOT/no-such-rec" LYREBIRD_LOG_DIR="$ST_ROOT/no-such-logs" MEDIAMTX_LOG="$ST_ROOT/no-such-mtx/mediamtx.out")
    run storage_run cmd_cleanup
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"Cannot list"* ]]
    run storage_run cmd_emergency
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"Cannot list"* ]]
}

# --- the stale *.tmp cleanup of truncate_large_logs -----------------------------------

# rm that refuses any path containing "stuck" (as an immutable file would)
_shim_rm() {
    mkdir -p "$ST_ROOT/bin"
    cat >"$ST_ROOT/bin/rm" <<'EOF'
#!/bin/bash
rc=0
for p in "$@"; do
    case "$p" in
        --) ;;
        -*) ;;
        *stuck*) echo "rm: cannot remove '$p': Operation not permitted" >&2; rc=1 ;;
        *) /bin/rm -rf -- "$p" || rc=1 ;;
    esac
done
exit $rc
EOF
    chmod +x "$ST_ROOT/bin/rm"
    ST_ENV=(PATH="$ST_ROOT/bin:$PATH")
}

@test "a dry run keeps the empty directories of the recording tree and lists them (it used to remove them, stream directories included) [X-29]" {
    mkdir -p "$ST_REC/stream1/empty" "$ST_REC/stream2"
    echo data >"$ST_REC/stream2/new.opus"
    ST_ENV=(DRY_RUN=true)
    run storage_run cmd_cleanup
    [ "$status" -eq 0 ]
    [ -d "$ST_REC/stream1/empty" ]
    [ -d "$ST_REC/stream1" ]
    [[ "$output" == *"[DRY RUN] Would remove empty directory: $ST_REC/stream1/empty"* ]]
    # and a real run does remove them, the recording directory itself never
    ST_ENV=()
    run storage_run cmd_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$ST_REC/stream1" ]
    [ -d "$ST_REC/stream2" ]
    [ -d "$ST_REC" ]
}

@test "a dry run leaves the stale temp files alone and lists them (it used to delete them) [X-29]" {
    echo data >"$ST_LOGS/mediamtx-stale.tmp"
    echo data >"$ST_LOGS/other-stale.tmp"
    echo data >"$ST_LOGS/fresh.tmp"
    _age "$ST_LOGS/mediamtx-stale.tmp" "10 minutes ago"
    _age "$ST_LOGS/other-stale.tmp" "10 minutes ago"
    ST_ENV=(DRY_RUN=true)
    run storage_run truncate_large_logs
    [ "$status" -eq 0 ]
    [ -e "$ST_LOGS/mediamtx-stale.tmp" ]
    [ -e "$ST_LOGS/other-stale.tmp" ]
    [[ "$output" == *"[DRY RUN] Would delete stale temp: $ST_LOGS/mediamtx-stale.tmp"* ]]
    [[ "$output" == *"[DRY RUN] Would delete stale temp: $ST_LOGS/other-stale.tmp"* ]]
}

@test "a stale temp file that cannot be removed is counted and logged with the reason, the others are removed, and the run exits EXIT_DELETE_FAILED [X-29]" {
    _shim_rm
    echo data >"$ST_LOGS/stuck-stale.tmp"
    echo data >"$ST_LOGS/other-stale.tmp"
    echo data >"$ST_LOGS/fresh.tmp"
    _age "$ST_LOGS/stuck-stale.tmp" "10 minutes ago"
    _age "$ST_LOGS/other-stale.tmp" "10 minutes ago"
    run storage_run cmd_cleanup
    [ "$status" -eq 3 ] || { echo "$output"; return 1; }       # pre-fix: 0, `-delete ... || true`
    [[ "$output" == *"Cannot delete stale temp $ST_LOGS/stuck-stale.tmp: rm: cannot remove"*"Operation not permitted"* ]]
    [[ "$output" == *"Run finished with 1 failed deletion(s)"* ]]
    [[ "$output" == *"Removed 1 stale temp file(s); 1 deletion(s) FAILED"* ]]
    [ -e "$ST_LOGS/stuck-stale.tmp" ]
    [ ! -e "$ST_LOGS/other-stale.tmp" ]
    [ -e "$ST_LOGS/fresh.tmp" ]                                 # younger than 5 minutes: not stale
}

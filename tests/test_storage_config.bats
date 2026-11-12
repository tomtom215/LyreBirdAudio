#!/usr/bin/env bats
# DOC-05: /etc/lyrebird/storage.conf
#
# README.md and docs/components.html tell the operator to configure the storage
# script in /etc/lyrebird/storage.conf with lines such as
#     RECORDING_RETENTION_DAYS=30      # Keep recordings for 30 days
#     RECORDING_DIR="/var/recordings"
# The script never read a file, and its directory variables are LYREBIRD_RECORDING_DIR
# and LYREBIRD_LOG_DIR. It now reads the file (LYREBIRD_STORAGE_CONFIG names another
# one) as DATA, never sourced, and accepts RECORDING_DIR and LOG_DIR as other names
# of the LYREBIRD_ ones in the file.
#
# The real script is sourced in a child shell with a CLEAN environment (env -i), so
# nothing in the caller's environment can stand in for the file. Nothing here lets
# the script act on a directory that is not private to the test: the checks print
# the variables the script ends up with, and the runs of the command line are
# `status` (read-only) or --dry-run.

load scratch_tmpdir
load storage_helper

setup() {
    scratch_setup
    storage_setup
    CONF="$ST_ROOT/storage.conf"
    MARK="$ST_ROOT/pwned"
}

teardown() {
    storage_teardown
    scratch_teardown
}

_age() { touch -d "${2:-45 days ago}" "$1"; }

# conf_eval CODE [ENV=value ...]: source the real script with LYREBIRD_STORAGE_CONFIG
# set to $CONF (override with CONF_ENV), then run CODE; output is stdout + stderr
conf_eval() {
    local code="$1"
    shift
    (
        cd "$ST_CWD" || exit 99
        env -i PATH="$PATH" HOME=/nonexistent PROJECT_ROOT="$PROJECT_ROOT" \
            LYREBIRD_STORAGE_CONFIG="$CONF" LYREBIRD_BUFFER_DIR="$ST_BUF" "$@" \
            bash -c 'source "$PROJECT_ROOT/lyrebird-storage.sh"; trap - EXIT; eval "$1"' _ "$code" 2>&1
    )
}

# The command line in a clean environment; the directories the command could
# touch are private ones
conf_cli() {
    RUN_RC=0
    (
        cd "$ST_CWD" || exit 99
        env -i PATH="$PATH" HOME=/nonexistent LYREBIRD_STORAGE_CONFIG="$CONF" LYREBIRD_BUFFER_DIR="$ST_BUF" \
            LYREBIRD_TEMP_DIR="$ST_TEMP" LYREBIRD_LOG_DIR="$ST_LOGS" MEDIAMTX_LOG="$ST_LOGS/mediamtx.out" \
            "$@" bash "$PROJECT_ROOT/lyrebird-storage.sh" ${CLI_ARGS[@]+"${CLI_ARGS[@]}"} </dev/null >"$ST_ROOT/out" 2>"$ST_ROOT/err"
    ) || RUN_RC=$?
}

_vars='printf "%s|%s|%s|%s|%s|%s|%s\n" "$RECORDING_DIR" "$LOG_DIR" "$RECORDING_RETENTION_DAYS" "$LOG_RETENTION_DAYS" "$DISK_WARNING_PERCENT" "$DISK_CRITICAL_PERCENT" "${CONFIG_FILE_USED:-none}"'

@test "the configuration block of the README and of docs/components.html is read as written: names, quotes, inline comments, RECORDING_DIR and LOG_DIR [DOC-05]" {
    cat >"$CONF" <<EOF
# /etc/lyrebird/storage.conf
# Retention settings
RECORDING_RETENTION_DAYS=12      # Keep recordings for 12 days
LOG_RETENTION_DAYS=3             # Keep logs for 3 days

# Disk thresholds
DISK_WARNING_PERCENT=70          # Warn at 70% usage
DISK_CRITICAL_PERCENT=85         # Critical at 85% usage

# Directories to manage
RECORDING_DIR="$ST_ROOT/recordings"
LOG_DIR="$ST_ROOT/logs-dir"
EOF
    run conf_eval "$_vars"
    [ "$status" -eq 0 ]
    [ "$output" = "$ST_ROOT/recordings|$ST_ROOT/logs-dir|12|3|70|85|$CONF" ] || { echo "$output"; return 1; }
    # and the other spellings of a value
    cat >"$CONF" <<EOF
RECORDING_RETENTION_DAYS='9'
LOG_RETENTION_DAYS="4"   # a comment after a quoted value
DISK_WARNING_PERCENT=60
DISK_CRITICAL_PERCENT=88
LYREBIRD_RECORDING_DIR='$ST_ROOT/with space'
LYREBIRD_LOG_DIR=$ST_ROOT/plain
EOF
    run conf_eval "$_vars"
    [ "$output" = "$ST_ROOT/with space|$ST_ROOT/plain|9|4|60|88|$CONF" ] || { echo "$output"; return 1; }
}

@test "every other setting of the script can be given in the file too, by the name of its environment variable [DOC-05]" {
    cat >"$CONF" <<EOF
DISK_EMERGENCY_PERCENT=97
MIN_FREE_SPACE_MB=123
TEMP_RETENTION_HOURS=5
MAX_LOG_SIZE=2048
LYREBIRD_ACTIVE_SEGMENT_SECONDS=300
LYREBIRD_CLOCK_SANE_EPOCH=1700000000
LYREBIRD_TEMP_DIR=$ST_ROOT/t
LYREBIRD_BUFFER_DIR=$ST_BUF
MEDIAMTX_LOG=$ST_ROOT/m/mediamtx.out
EOF
    run conf_eval 'printf "%s|" "$DISK_EMERGENCY_PERCENT" "$MIN_FREE_SPACE_MB" "$TEMP_RETENTION_HOURS" "$MAX_LOG_SIZE" "$ACTIVE_SEGMENT_SECONDS" "$CLOCK_SANE_EPOCH" "$TEMP_DIR" "$BUFFER_DIR" "$MEDIAMTX_LOG" "$MEDIAMTX_LOG_DIR"'
    [ "$status" -eq 0 ]
    [ "$output" = "97|123|5|2048|300|1700000000|$ST_ROOT/t|$ST_BUF|$ST_ROOT/m/mediamtx.out|$ST_ROOT/m|" ] || { echo "$output"; return 1; }
}

@test "the environment wins over the file, LYREBIRD_ spelling wins over the alias in the file, and RECORDING_DIR / LOG_DIR in the environment are not read [DOC-05]" {
    cat >"$CONF" <<EOF
RECORDING_DIR=$ST_ROOT/alias-first
LYREBIRD_RECORDING_DIR=$ST_ROOT/canonical
LYREBIRD_LOG_DIR=$ST_ROOT/log-canonical
LOG_DIR=$ST_ROOT/log-alias-after
RECORDING_RETENTION_DAYS=5
DISK_WARNING_PERCENT=61
EOF
    # file only: the LYREBIRD_ spelling wins whichever line comes first
    run conf_eval "$_vars"
    [ "$output" = "$ST_ROOT/canonical|$ST_ROOT/log-canonical|5|7|61|90|$CONF" ] || { echo "$output"; return 1; }
    # the environment wins over the file
    run conf_eval "$_vars" LYREBIRD_RECORDING_DIR="$ST_ROOT/from-env" RECORDING_RETENTION_DAYS=9
    [ "$output" = "$ST_ROOT/from-env|$ST_ROOT/log-canonical|9|7|61|90|$CONF" ] || { echo "$output"; return 1; }
    # the alias names are read from the file only: a variable of that name in the
    # environment (set for some other program) does not point the cleanup anywhere
    printf 'RECORDING_RETENTION_DAYS=5\n' >"$CONF"
    run conf_eval "$_vars" RECORDING_DIR="$ST_ROOT/not-ours" LOG_DIR="$ST_ROOT/not-ours-either"
    [ "$output" = "/var/lib/mediamtx-ffmpeg/recordings|/var/log/lyrebird|5|7|80|90|$CONF" ] || { echo "$output"; return 1; }
}

@test "the file is data: command substitutions, assignments, redirections, other commands and unknown keys are reported with their line and never run [DOC-05]" {
    local -a bad=(
        '$(touch MARK)'
        '`touch MARK`'
        'touch MARK'
        'exit 0'
        'RECORDING_DIR=$(touch MARK)'
        'RECORDING_DIR="$(touch MARK)"'
        'RECORDING_DIR=/x;touch MARK'
        'RECORDING_RETENTION_DAYS=5;touch MARK'
        'LOG_DIR=/a b'
        'export LOG_DIR=/x'
        'PATH=/nonexistent/bin'
        'IFS=x'
        'DRY_RUN=true'
        'LD_PRELOAD=/tmp/evil.so'
        'BASH_ENV=/tmp/evil'
        "trap 'touch MARK' EXIT"
        '. /dev/null'
        'source /dev/null'
        'a[$(touch MARK)]=1'
        "RECORDING_RETENTION_DAYS='unterminated"
        'LOG_DIR="unterminated'
        'RECORDING_RETENTION_DAYS=30d'
        'DISK_WARNING_PERCENT='
        'RECORDING_DIR=relative/dir'
        'LOG_RETENTION_DAYS=$((1+1))'
        'RECORDING_DIR="${HOME}/rec"'
        "LOG_RETENTION_DAYS='\$(touch MARK)'"
        "RECORDING_DIR='\$(touch MARK)'"
        'RECORDING_RETENTION_DAYS=5 6'
        'RECORDING_RETENTION_DAY=5'
        'recording_retention_days=5'
        'RECORDING_RETENTION_DAYS =5'
        'echo hi > MARK'
        'RECORDING_RETENTION_DAYS=5 > MARK'
        '{ touch MARK; }'
    )
    local n=${#bad[@]} i line
    {
        for ((i = 0; i < n; i++)); do
            line="${bad[i]//MARK/$MARK}"
            printf '%s\n' "$line"
            if ((i == 5)); then
                printf 'DISK_CRITICAL_PERCENT=77\n'        # a good line among the bad ones
            fi
        done
        # a single-quoted value is a literal, whatever it looks like
        printf "LYREBIRD_LOG_DIR='%s/\$(touch %s)'\n" "$ST_ROOT" "$MARK"
    } >"$CONF"
    run conf_eval 'printf "%s|%s|%s|%s|%s\n" "$DISK_CRITICAL_PERCENT" "$LOG_DIR" "$DRY_RUN" "$CONFIG_PROBLEMS" "$PATH"'
    [ "$status" -eq 0 ]
    [ ! -e "$MARK" ] || { echo "the file was executed"; return 1; }
    # the good lines applied; DRY_RUN and PATH untouched; every bad line counted
    [[ "$output" == *$'\n'"77|$ST_ROOT/\$(touch $MARK)|false|$n|$PATH" ]] || { echo "$output"; return 1; }
    # each bad line is reported with its number (the good line shifted the rest by one)
    for ((i = 0; i < n; i++)); do
        local lineno=$((i + 1))
        if ((i > 5)); then
            lineno=$((i + 2))
        fi
        [[ "$output" == *"storage.conf:${lineno}: "* ]] || { echo "line $lineno not reported: ${bad[i]}"; return 1; }
    done
    # the command line: nothing ran, and the status says the file was not clean
    CLI_ARGS=(status)
    conf_cli
    [ "$RUN_RC" -eq 4 ] || { cat "$ST_ROOT/err"; return 1; }
    [ ! -e "$MARK" ]
    grep -q "Finished, but $n line(s) of $CONF were not accepted and ignored" "$ST_ROOT/err"
    grep -q 'LyreBirdAudio Storage Status' "$ST_ROOT/out"      # status itself ran
}

@test "an unknown key is reported with its file, line and the accepted names; the lines around it apply; exit 4, and 3 for a failed deletion keeps its code [DOC-05]" {
    printf 'LOG_RETENTION_DAYS=2\nRECORDING_RETENTION_DAY=5\nDISK_WARNING_PERCENT=66\n' >"$CONF"
    CLI_ARGS=(status)
    conf_cli
    [ "$RUN_RC" -eq 4 ]
    grep -q "${CONF}:2: RECORDING_RETENTION_DAY: unknown setting (expected: one of LYREBIRD_RECORDING_DIR (alias RECORDING_DIR)" "$ST_ROOT/err"
    grep -q 'Warning threshold: 66%' "$ST_ROOT/out"
    grep -q 'Retention (logs): 2 days' "$ST_ROOT/out"
    grep -q "Config file: $CONF" "$ST_ROOT/out"

    # a failed deletion (3) is the more specific news
    mkdir -p "$ST_ROOT/bin"
    printf '#!/bin/bash\nfor p in "$@"; do case "$p" in -*|--) ;; *) echo "rm: cannot remove $p: Operation not permitted" >&2; exit 1;; esac; done\n' >"$ST_ROOT/bin/rm"
    chmod +x "$ST_ROOT/bin/rm"
    echo data >"$ST_TEMP/lyrebird-old.tmp"
    _age "$ST_TEMP/lyrebird-old.tmp" "3 days ago"
    CLI_ARGS=(cleanup)
    conf_cli PATH="$ST_ROOT/bin:$PATH" LYREBIRD_RECORDING_DIR="$ST_REC"
    [ "$RUN_RC" -eq 3 ] || { cat "$ST_ROOT/err"; return 1; }
}

@test "a file anyone can write, or that belongs to another user, is not read: it decides what is deleted [DOC-05]" {
    printf 'RECORDING_RETENTION_DAYS=5\n' >"$CONF"
    chmod 666 "$CONF"
    run conf_eval "$_vars"
    [ "$status" -eq 0 ]
    [[ "$output" == *"is writable by everyone (mode 666), so it is not read"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"|30|7|80|90|none" ]] || { echo "$output"; return 1; }      # the defaults, the file unread
    chmod 644 "$CONF"
    if [[ "$(id -u)" -eq 0 ]]; then
        chown 65534 "$CONF"
        run conf_eval "$_vars"
        [[ "$output" == *"belongs to user 65534, so it is not read"* ]] || { echo "$output"; return 1; }
        [[ "$output" == *"|30|7|80|90|none" ]]
    fi
    # group-writable and owned by root is accepted (root's own group)
    if [[ "$(id -u)" -eq 0 ]]; then
        chown 0 "$CONF"
        chmod 664 "$CONF"
        run conf_eval "$_vars"
        [[ "$output" == *"|5|7|80|90|$CONF" ]] || { echo "$output"; return 1; }
    fi
}

@test "a missing file named by LYREBIRD_STORAGE_CONFIG is a problem, a missing default file is not, an empty name means no file, and the default is /etc/lyrebird/storage.conf [DOC-05]" {
    CONF="$ST_ROOT/does-not-exist.conf"
    run conf_eval 'printf "%s|%s\n" "$CONFIG_PROBLEMS" "${CONFIG_FILE_USED:-none}"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"does-not-exist.conf: does not exist"* ]]
    [[ "$output" == *$'\n'"1|none" ]] || { echo "$output"; return 1; }
    CONF=""
    run conf_eval 'printf "%s|%s|[%s]\n" "$CONFIG_PROBLEMS" "${CONFIG_FILE_USED:-none}" "$STORAGE_CONFIG_PATH"'
    [ "$output" = "0|none|[]" ]
    # unset: the documented place
    run env -i PATH="$PATH" PROJECT_ROOT="$PROJECT_ROOT" LYREBIRD_BUFFER_DIR="$ST_BUF" \
        bash -c 'source "$PROJECT_ROOT/lyrebird-storage.sh"; trap - EXIT; printf "%s\n" "$STORAGE_CONFIG_PATH"'
    [[ "$output" == *"/etc/lyrebird/storage.conf" ]]
    # a directory or another special file is not a configuration file
    CONF="$ST_ROOT"
    run conf_eval 'printf "%s\n" "$CONFIG_PROBLEMS"'
    [[ "$output" == *"is not a regular file"* ]]
}

@test "a file that is too long, a line that is too long, a BOM and CRLF line endings, and a flood of problems [DOC-05]" {
    # 70 KB
    awk 'BEGIN { for (i = 0; i < 2000; i++) print "# a comment line that makes the file long enough to be refused" }' >"$CONF"
    run conf_eval "$_vars"
    [[ "$output" == *"bytes long, more than the 65536 byte limit"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"|30|7|80|90|none" ]]
    # a line of 5000 characters is reported, a comment of that length is not
    {
        printf 'RECORDING_RETENTION_DAYS=%s\n' "$(printf '1%.0s' $(seq 1 5000))"
        printf '# %s\n' "$(printf 'x%.0s' $(seq 1 5000))"
        printf 'LOG_RETENTION_DAYS=4\n'
    } >"$CONF"
    run conf_eval "$_vars"
    [[ "$output" == *"storage.conf:1: line is 5025 characters long"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"storage.conf:2:"* ]]
    [[ "$output" == *"|30|4|80|90|$CONF" ]]
    # BOM and CRLF, as a file edited on Windows has them
    printf '\xef\xbb\xbfRECORDING_RETENTION_DAYS=8\r\nLOG_RETENTION_DAYS=2\r\n' >"$CONF"
    run conf_eval "$_vars"
    [[ "$output" == *"|8|2|80|90|$CONF" ]] || { echo "$output"; return 1; }
    [[ "$output" != *"storage.conf:"* ]]
    # a flood: reading stops after 100 problems
    awk 'BEGIN { for (i = 0; i < 300; i++) print "nonsense line " i }' >"$CONF"
    run conf_eval 'printf "%s\n" "$CONFIG_PROBLEMS"'
    [[ "$output" == *"stopped reading after 100 problems"* ]]
    [[ "$output" == *$'\n'"100" ]]
}

@test "the file drives a real run: its directories and retention decide what a dry-run cleanup would delete, and status names the file [DOC-05]" {
    mkdir -p "$ST_ROOT/recordings/s1" "$ST_ROOT/logs-dir"
    echo data >"$ST_ROOT/recordings/s1/old.opus"
    echo data >"$ST_ROOT/recordings/s1/middle.opus"
    echo data >"$ST_ROOT/recordings/s1/new.opus"
    echo data >"$ST_ROOT/logs-dir/old.log"
    _age "$ST_ROOT/recordings/s1/old.opus" "40 days ago"
    _age "$ST_ROOT/recordings/s1/middle.opus" "15 days ago"
    _age "$ST_ROOT/recordings/s1/new.opus" "2 days ago"
    _age "$ST_ROOT/logs-dir/old.log" "5 days ago"
    cat >"$CONF" <<EOF
RECORDING_RETENTION_DAYS=10
LOG_RETENTION_DAYS=3
RECORDING_DIR="$ST_ROOT/recordings"
LOG_DIR="$ST_ROOT/logs-dir"
EOF
    CLI_ARGS=(--dry-run cleanup)
    conf_cli LYREBIRD_LOG_DIR= LYREBIRD_STORAGE_CONFIG="$CONF"
    [ "$RUN_RC" -eq 0 ] || { cat "$ST_ROOT/err"; return 1; }
    grep -q "Would delete recording: $ST_ROOT/recordings/s1/old.opus" "$ST_ROOT/err"
    grep -q "Would delete recording: $ST_ROOT/recordings/s1/middle.opus" "$ST_ROOT/err"
    ! grep -q "Would delete recording: $ST_ROOT/recordings/s1/new.opus" "$ST_ROOT/err" || false
    grep -q "Would delete log: $ST_ROOT/logs-dir/old.log" "$ST_ROOT/err"
    CLI_ARGS=(status)
    conf_cli LYREBIRD_LOG_DIR=
    grep -q "Path: $ST_ROOT/recordings" "$ST_ROOT/out"
    grep -q "Config file: $CONF" "$ST_ROOT/out"
    # without a file: none
    CONF=""
    conf_cli
    grep -q 'Config file: none' "$ST_ROOT/out"
}

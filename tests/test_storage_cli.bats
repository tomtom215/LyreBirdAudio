#!/usr/bin/env bats
# DOC-05: the cron lines the documentation gives for lyrebird-storage.sh
#
#     0 3 * * *    lyrebird-storage.sh cleanup --quiet
#     */15 * * * * lyrebird-storage.sh monitor --once
#
# were rejected ("Unknown option", exit 1) on every run: README.md,
# docs/monitoring.html and docs/components.html. The real script runs here as a
# child process, with the arguments exactly as the documentation writes them, over
# private directories (tests/storage_helper.bash); the disk state monitor looks at
# comes from a df shim.
#
# What --quiet means: this script logs to stderr and prints to stdout only for
# `status`. --quiet drops the informational lines and keeps warnings, errors and
# one summary line per run. `monitor` was silent while the disk is fine and still
# is, with or without --quiet.

load scratch_tmpdir
load storage_helper

setup() {
    scratch_setup
    storage_setup
    ST_SHIM="$ST_ROOT/bin"
    mkdir -p "$ST_SHIM"
}

teardown() {
    storage_teardown
    scratch_teardown
}

_age() { touch -d "${2:-45 days ago}" "$1"; }

# df for a 100 GB filesystem with blocks and inodes at $1% (plenty of free space,
# so only the percentages decide)
_shim_df() {
    cat >"$ST_SHIM/df" <<EOF
#!/bin/bash
for a in "\$@"; do
    case "\$a" in
        -*i*) echo "Filesystem Inodes IUsed IFree IUse% Mounted on"
              echo "/dev/root 1000000 $(($1 * 10000)) $(((100 - $1) * 10000)) $1% /"
              exit 0 ;;
    esac
done
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/root 100000000 $(($1 * 1000000)) $(((100 - $1) * 1000000)) $1% /"
EOF
    chmod +x "$ST_SHIM/df"
}

# rm that refuses any path containing "stuck"
_shim_rm() {
    cat >"$ST_SHIM/rm" <<'EOF'
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
    chmod +x "$ST_SHIM/rm"
}

# Run the real script as cron would: a child process, no TTY, stdout to
# $ST_ROOT/out and stderr to $ST_ROOT/err, status in RUN_RC. Extra env
# assignments come first, then the script's arguments after "--".
cli() {
    local -a assignments=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        assignments+=("$1")
        shift
    done
    shift
    RUN_RC=0
    (
        cd "$ST_CWD" || exit 99
        env PATH="$ST_SHIM:$PATH" \
            LYREBIRD_RECORDING_DIR="$ST_REC" LYREBIRD_LOG_DIR="$ST_LOGS" LYREBIRD_TEMP_DIR="$ST_TEMP" \
            LYREBIRD_BUFFER_DIR="$ST_BUF" MEDIAMTX_LOG="$ST_LOGS/mediamtx.out" \
            ${assignments[@]+"${assignments[@]}"} \
            "$BASH" "$PROJECT_ROOT/lyrebird-storage.sh" "$@" </dev/null >"$ST_ROOT/out" 2>"$ST_ROOT/err"
    ) || RUN_RC=$?
}

@test "the documented cron lines run exactly as written and exit 0 on a healthy tree: cleanup --quiet and monitor --once [DOC-05]" {
    _shim_df 40
    echo data >"$ST_REC/old.opus"
    echo data >"$ST_REC/new.opus"
    echo data >"$ST_TEMP/lyrebird-old.tmp"
    _age "$ST_REC/old.opus"
    _age "$ST_TEMP/lyrebird-old.tmp" "3 days ago"

    cli -- cleanup --quiet
    [ "$RUN_RC" -eq 0 ] || { cat "$ST_ROOT/err"; return 1; }      # pre-fix: 1, "Unknown option: --quiet"
    [ ! -e "$ST_REC/old.opus" ]
    [ -e "$ST_REC/new.opus" ]
    [ ! -e "$ST_TEMP/lyrebird-old.tmp" ]

    cli -- monitor --once
    [ "$RUN_RC" -eq 0 ] || { cat "$ST_ROOT/err"; return 1; }      # pre-fix: 1, "Unknown option: --once"
}

@test "cleanup --quiet writes nothing to stdout and one summary line to stderr; without --quiet the steps are logged as before [DOC-05]" {
    echo data >"$ST_REC/old.opus"
    echo data >"$ST_REC/new.opus"
    _age "$ST_REC/old.opus"

    cli -- cleanup --quiet
    [ "$RUN_RC" -eq 0 ]
    [ ! -s "$ST_ROOT/out" ]
    [ "$(wc -l <"$ST_ROOT/err")" -eq 1 ] || { cat "$ST_ROOT/err"; return 1; }
    [[ "$(cat "$ST_ROOT/err")" == *"[INFO] Cleanup completed: removed 1 file(s), 5B freed"* ]]

    echo data >"$ST_REC/old2.opus"
    _age "$ST_REC/old2.opus"
    cli -- cleanup
    [ "$RUN_RC" -eq 0 ]
    [ ! -s "$ST_ROOT/out" ]
    [[ "$(cat "$ST_ROOT/err")" == *"Starting storage cleanup"* ]]
    [[ "$(cat "$ST_ROOT/err")" == *"Cleaning recordings older than 30 days"* ]]
    [[ "$(cat "$ST_ROOT/err")" == *"Cleanup completed: removed 1 file(s), 5B freed"* ]]
}

@test "--quiet keeps errors, warnings and the summary of a failed run, and the exit status [DOC-05]" {
    _shim_rm
    echo data >"$ST_REC/stuck.opus"
    echo data >"$ST_REC/fine.opus"
    _age "$ST_REC/stuck.opus"
    _age "$ST_REC/fine.opus"

    cli -- cleanup --quiet
    [ "$RUN_RC" -eq 3 ]
    [ ! -s "$ST_ROOT/out" ]
    grep -q '\[ERROR\] Cannot delete recording .*stuck.opus: rm: cannot remove .*Operation not permitted' "$ST_ROOT/err"
    grep -q '\[ERROR\] Run finished with 1 failed deletion(s)' "$ST_ROOT/err"
    [[ "$(tail -n 1 "$ST_ROOT/err")" == *"[INFO] Cleanup incomplete: removed 1 file(s), 5B freed; 1 deletion(s) FAILED"* ]]
    ! grep -q 'Starting storage cleanup\|Cleaning recordings' "$ST_ROOT/err" || false

    # a warning survives too: age-based cleanup waits for a sane clock
    cli LYREBIRD_CLOCK_SANE_EPOCH=4102444800 -- cleanup --quiet
    grep -q '\[WARN\] System clock .* predates 4102444800' "$ST_ROOT/err"
    ! grep -q 'Cleaning recordings' "$ST_ROOT/err" || false
}

@test "--dry-run --quiet says what would be removed in its one line and removes nothing [DOC-05]" {
    echo data >"$ST_REC/old.opus"
    _age "$ST_REC/old.opus"
    cli -- --dry-run cleanup --quiet
    [ "$RUN_RC" -eq 0 ]
    [ -e "$ST_REC/old.opus" ]
    [ ! -s "$ST_ROOT/out" ]
    [[ "$(tail -n 1 "$ST_ROOT/err")" == *"Cleanup completed: would remove 1 file(s), 5B freed"* ]]
}

@test "monitor --once prints nothing while the disk is fine, with or without --quiet, and exits 0 [DOC-05]" {
    _shim_df 40
    cli -- monitor --once
    [ "$RUN_RC" -eq 0 ]
    [ ! -s "$ST_ROOT/out" ]
    [ ! -s "$ST_ROOT/err" ] || { cat "$ST_ROOT/err"; return 1; }
    cli -- monitor --once --quiet
    [ "$RUN_RC" -eq 0 ]
    [ ! -s "$ST_ROOT/out" ]
    [ ! -s "$ST_ROOT/err" ]
}

@test "monitor --quiet above a threshold: its warning and one summary line, stdout empty, the cleanup done [DOC-05]" {
    echo data >"$ST_REC/old.opus"
    _age "$ST_REC/old.opus"
    _shim_df 92
    cli -- monitor --quiet
    [ "$RUN_RC" -eq 0 ]
    [ ! -s "$ST_ROOT/out" ]
    [ ! -e "$ST_REC/old.opus" ]
    [ "$(wc -l <"$ST_ROOT/err")" -eq 2 ] || { cat "$ST_ROOT/err"; return 1; }
    grep -q '\[WARN\] CRITICAL: Disk 92% full, inodes 92% used' "$ST_ROOT/err"
    [[ "$(tail -n 1 "$ST_ROOT/err")" == *"[INFO] Monitor: disk 92% used, inodes 92%, "*"MB free (critical): removed 1 file(s), 5B freed"* ]]

    # not quiet: the steps are logged as well
    echo data >"$ST_REC/old2.opus"
    _age "$ST_REC/old2.opus"
    cli -- monitor
    grep -q 'Starting storage cleanup' "$ST_ROOT/err"
    [[ "$(tail -n 1 "$ST_ROOT/err")" == *"(critical): removed 1 file(s)"* ]]
}

@test "monitor --quiet at emergency usage and with an unparseable df ends in its summary line and keeps the exit status [DOC-05]" {
    _shim_rm
    echo data >"$ST_REC/stuck.opus"
    _age "$ST_REC/stuck.opus" "3 hours ago"
    _shim_df 97
    cli -- monitor --quiet
    [ "$RUN_RC" -eq 3 ]
    [ ! -s "$ST_ROOT/out" ]
    grep -q '\[ERROR\] EMERGENCY: Disk 97% full' "$ST_ROOT/err"
    [[ "$(tail -n 1 "$ST_ROOT/err")" == *"(emergency): removed 0 file(s)"*"1 deletion(s) FAILED"* ]]
    # the only INFO-level line is the summary
    [ "$(grep -c '\[INFO\]' "$ST_ROOT/err")" -eq 1 ]

    printf '#!/bin/bash\necho "df: garbage"\n' >"$ST_SHIM/df"
    cli -- monitor --quiet
    grep -q '\[ERROR\] Could not determine disk usage' "$ST_ROOT/err"
    [[ "$(tail -n 1 "$ST_ROOT/err")" == *"Monitor: disk usage of / unknown (df unparseable); standard cleanup only: removed 0 file(s)"* ]]
}

@test "--quiet and --once are accepted only where they mean something; there is no --interval [DOC-05]" {
    local args
    for args in "status --quiet" "emergency --quiet" "cleanup --once" "status --once" "emergency --once"; do
        # shellcheck disable=SC2086
        cli -- $args
        [ "$RUN_RC" -eq 1 ] || { echo "$args: status $RUN_RC"; return 1; }
        grep -q 'applies to .* only' "$ST_ROOT/err" || { echo "$args: $(cat "$ST_ROOT/err")"; return 1; }
    done
    cli -- monitor --interval 300
    [ "$RUN_RC" -eq 1 ]
    grep -q 'Unknown option: --interval' "$ST_ROOT/err"
    # short form and any order
    echo data >"$ST_REC/old.opus"
    _age "$ST_REC/old.opus"
    cli -- -q cleanup
    [ "$RUN_RC" -eq 0 ]
    [ "$(wc -l <"$ST_ROOT/err")" -eq 1 ]
}

@test "--help documents --quiet, --once and the exit status 3 for a failed listing [DOC-05]" {
    cli -- --help
    [ "$RUN_RC" -eq 0 ]
    grep -q -- '-q, --quiet' "$ST_ROOT/out"
    grep -q -- '--once' "$ST_ROOT/out"
    grep -q 'cleanup --quiet' "$ST_ROOT/out"
    grep -q 'monitor --once' "$ST_ROOT/out"
    grep -q 'directory could not be listed' "$ST_ROOT/out"
}

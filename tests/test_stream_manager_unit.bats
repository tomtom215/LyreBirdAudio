#!/usr/bin/env bats
# The systemd unit of lyrebird-stream-manager.sh (register: LB-11, LB-12, X-12;
# decision D12): the one template config/mediamtx-audio.service, the generator
# that renders it (`install`), the settings the unit hands the manager, and the
# cron line `install` writes.
#
# The real script is sourced in a fresh bash for every call and the real
# functions run. systemd-analyze (which loads a unit file with systemd's own
# parser, without a service manager) is the judge of the rendered files.

load scratch_tmpdir

setup() {
    scratch_setup
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
    UN="$TEST_SCRATCH/un"
    mkdir -p "$UN"
    export PROJECT_ROOT UN
    export MEDIAMTX_LOG_FILE="$UN/sm.log" MEDIAMTX_CONFIG_DIR="$UN/cfg" MEDIAMTX_FFMPEG_DIR="$UN/ff"
    export MEDIAMTX_PID_FILE="$UN/mtx.pid" MEDIAMTX_LOCK_FILE="$UN/run.lock"
    SCRIPT="$PROJECT_ROOT/lyrebird-stream-manager.sh"
}

teardown() {
    scratch_teardown
}

# ---------------------------------------------------------------------------
# No faked systemd variable (LB-11)
# ---------------------------------------------------------------------------

@test "lyrebird_under_systemd: the unit's LYREBIRD_UNDER_SYSTEMD, or systemd's own INVOCATION_ID, and nothing else [LB-11]" {
    local value
    for value in 1 true yes; do
        run env -u INVOCATION_ID LYREBIRD_UNDER_SYSTEMD="$value" bash -c 'source "$1" >/dev/null 2>&1; lyrebird_under_systemd' _ "$SCRIPT"
        [ "$status" -eq 0 ]
    done
    for value in 0 false no ""; do
        run env -u INVOCATION_ID LYREBIRD_UNDER_SYSTEMD="$value" bash -c 'source "$1" >/dev/null 2>&1; lyrebird_under_systemd' _ "$SCRIPT"
        [ "$status" -eq 1 ]
    done
    run env -u INVOCATION_ID -u LYREBIRD_UNDER_SYSTEMD bash -c 'source "$1" >/dev/null 2>&1; lyrebird_under_systemd' _ "$SCRIPT"
    [ "$status" -eq 1 ]
    # systemd itself sets INVOCATION_ID (a 32-digit hex id) for every service process; a unit
    # written by an older version of this script set it to the word "systemd" by hand
    run env -u LYREBIRD_UNDER_SYSTEMD INVOCATION_ID=0123456789abcdef0123456789abcdef bash -c 'source "$1" >/dev/null 2>&1; lyrebird_under_systemd' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    run env -u LYREBIRD_UNDER_SYSTEMD INVOCATION_ID=systemd bash -c 'source "$1" >/dev/null 2>&1; lyrebird_under_systemd' _ "$SCRIPT"
    [ "$status" -eq 0 ]
}

# The signal handlers are installed when the script is executed (not sourced) and not under
# systemd. The copy has its final `main "$@"` replaced by a printout of the traps; everything
# before it, the code under test, is the real script.
@test "the manager installs its HUP/USR1 handlers only when it is not run by systemd, and sets no USR2 handler [LB-11, LB-15]" {
    mkdir -p "$UN/copy"
    cp "$PROJECT_ROOT/lyrebird-common.sh" "$UN/copy/"
    sed 's/^    main "\$@"$/    trap -p HUP USR1 USR2/' "$SCRIPT" >"$UN/copy/lyrebird-stream-manager.sh"
    ! cmp -s "$SCRIPT" "$UN/copy/lyrebird-stream-manager.sh"
    run env -u INVOCATION_ID -u LYREBIRD_UNDER_SYSTEMD bash "$UN/copy/lyrebird-stream-manager.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SIGHUP"* && "$output" == *"SIGUSR1"* ]]
    [[ "$output" != *"SIGUSR2"* ]]

    run env -u INVOCATION_ID LYREBIRD_UNDER_SYSTEMD=1 bash "$UN/copy/lyrebird-stream-manager.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # a unit from an older version, which set INVOCATION_ID by hand, behaves as before
    run env -u LYREBIRD_UNDER_SYSTEMD INVOCATION_ID=systemd bash "$UN/copy/lyrebird-stream-manager.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "no code and no shipped unit sets INVOCATION_ID by hand; the logrotate guard asks lyrebird_under_systemd [LB-11]" {
    local f
    for f in setup_mediamtx_logrotate exit_critical_section; do
        run bash -c 'source "$1" >/dev/null 2>&1; declare -f "$2"' _ "$SCRIPT" "$f"
        [ "$status" -eq 0 ]
        [[ "$output" == *"lyrebird_under_systemd"* ]]
        [[ "$output" != *"INVOCATION_ID"* ]]
    done
    run bash -c 'source "$1" >/dev/null 2>&1; declare -f create_systemd_service' _ "$SCRIPT"
    [[ "$output" != *'INVOCATION_ID='* ]]
    run grep -n 'INVOCATION_ID' "$PROJECT_ROOT/config/mediamtx-audio.service" "$PROJECT_ROOT/config/mediamtx.service"
    [ "$status" -ne 0 ]
    # the generated unit tells the manager it is under systemd explicitly
    run bash -c 'source "$1" >/dev/null 2>&1; declare -f create_systemd_service' _ "$SCRIPT"
    [[ "$output" == *'LYREBIRD_UNDER_SYSTEMD=1'* ]]
}

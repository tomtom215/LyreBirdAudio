#!/usr/bin/env bats
# The command line of lyrebird-mic-check.sh (register: X-53).
#
# 1. --restore takes its backup timestamp as an optional argument. With getopt's
#    "restore::" that argument is only given as --restore=VALUE; the script then
#    treated the empty word getopt always emits as an option: both `--restore
#    20251111_123456` (the example in its own --help) and a bare `--restore` ended
#    in "Internal error parsing arguments".
# 2. --help and --version exited 1 with "ALSA proc filesystem not found" on a machine
#    without /proc/asound (a container): the check ran before the arguments were read.
#
# The real script is sourced in a child process and its own parse_arguments / main
# run. alsa_proc_available (the check, a function of the script) is overridden to
# stand in for a machine with or without /proc/asound; nothing else is replaced.

load scratch_tmpdir

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export PROJECT_ROOT TEST_SCRATCH
    CFG="$TEST_SCRATCH/cfg"
    mkdir -p "$CFG"
    export MEDIAMTX_DEVICE_CONFIG="$CFG/audio-devices.conf" MEDIAMTX_CONFIG_DIR="$CFG"
}

teardown() {
    scratch_teardown
}

# parse ARGS...: the result of the real parse_arguments
parse() {
    run bash -c '
        source "$PROJECT_ROOT/lyrebird-mic-check.sh" >/dev/null 2>&1
        set +e
        parse_arguments "$@"
        echo "rc=$? restore=$MODE_RESTORE timestamp=[$RESTORE_TIMESTAMP] card=[$SPECIFIC_CARD]"' _ "$@"
}

@test "--restore VALUE, the form the help shows, and --restore=VALUE both give the timestamp; a bare --restore asks for none [X-53]" {
    parse --restore 20251111_123456
    [ "$output" = "rc=0 restore=true timestamp=[20251111_123456] card=[]" ]
    parse --restore=20251111_123456
    [ "$output" = "rc=0 restore=true timestamp=[20251111_123456] card=[]" ]
    parse --restore
    [ "$output" = "rc=0 restore=true timestamp=[] card=[]" ]
    # the help's own example is one of these
    run bash -c 'source "$PROJECT_ROOT/lyrebird-mic-check.sh" >/dev/null 2>&1; show_usage'
    [[ "$output" == *"--restore 20251111_123456"* ]]
}

@test "--restore still refuses what makes no sense: a second operand, another mode, a card number [X-53]" {
    parse --restore 20251111_123456 2
    [[ "${lines[-1]}" == "rc=1 "* ]]
    parse --restore 20251111_123456 --list-backups
    [[ "${lines[-1]}" == "rc=1 "* ]]
    parse --list-backups 3
    [[ "${lines[-1]}" == "rc=1 "* ]]
    # a card number without --restore is still a card number
    parse 3
    [ "$output" = "rc=0 restore=false timestamp=[] card=[3]" ]
}

# main ARGS...: the real main on a machine that has (AVAIL=0) or lacks (AVAIL=1) /proc/asound;
# the check's calls are recorded in $TEST_SCRATCH/alsa.calls
run_main() {
    local avail="$1"
    shift
    run env AVAIL="$avail" bash -c '
        source "$PROJECT_ROOT/lyrebird-mic-check.sh" >/dev/null 2>&1
        alsa_proc_available() { echo called >>"$TEST_SCRATCH/alsa.calls"; return "$AVAIL"; }
        main "$@"' _ "$@"
}

@test "--help and --version exit 0 on a machine without /proc/asound and never look at the hardware [X-53]" {
    run_main 1 --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: lyrebird-mic-check.sh"* ]]
    [[ "$output" != *"ALSA proc filesystem not found"* ]]
    run_main 1 --version
    [ "$status" -eq 0 ]
    [[ "$output" != *"ALSA proc filesystem not found"* ]]
    [ ! -e "$TEST_SCRATCH/alsa.calls" ]
    # the real command, as a user types it (this machine may or may not have /proc/asound)
    run bash "$PROJECT_ROOT/lyrebird-mic-check.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage: lyrebird-mic-check.sh"* ]]
}

@test "everything that reads the hardware still stops with exit 1 and says why when /proc/asound is missing [X-53]" {
    run_main 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"ALSA proc filesystem not found at /proc/asound"* ]]
    run_main 1 --generate-config
    [ "$status" -eq 1 ]
    run_main 1 not-a-card
    # a wrong argument is reported as one, before anything else
    [ "$status" -eq 1 ]
    [[ "$output" == *"Card number must be numeric"* ]]
}

@test "--restore VALUE restores that backup; a bare --restore offers the list [X-53]" {
    printf 'current\n' >"$CFG/audio-devices.conf"
    printf '# old\nDEVICE_X_SAMPLE_RATE=44100\n' >"$CFG/audio-devices.conf.backup.20260102_030405"
    printf '# other\n' >"$CFG/audio-devices.conf.backup.20260102_030406"
    run bash -c 'printf "y\n" | env AVAIL=0 bash -c "
        source \"\$PROJECT_ROOT/lyrebird-mic-check.sh\" >/dev/null 2>&1
        alsa_proc_available() { return 0; }
        main --restore 20260102_030405"'
    [ "$status" -eq 0 ] || {
        echo "$output"
        false
    }
    [[ "$output" == *"restored successfully from: audio-devices.conf.backup.20260102_030405"* ]]
    [ "$(cat "$CFG/audio-devices.conf")" = "$(printf '# old\nDEVICE_X_SAMPLE_RATE=44100')" ]

    # bare: the interactive list, cancelled with 0
    run bash -c 'printf "0\n" | bash -c "
        source \"\$PROJECT_ROOT/lyrebird-mic-check.sh\" >/dev/null 2>&1
        alsa_proc_available() { return 0; }
        main --restore"'
    [ "$status" -eq 0 ] || {
        echo "$output"
        false
    }
    [[ "$output" == *"Available backups (newest first)"* ]]
    [[ "$output" == *"Restore cancelled by user"* ]]
}

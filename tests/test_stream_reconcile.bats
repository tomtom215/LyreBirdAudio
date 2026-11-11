#!/usr/bin/env bats
# The monitor's restart budget and reconcile of lyrebird-stream-manager.sh
# (register: X-04, LB-07, X-03; decision D5). See tests/manager_stage.bash for
# what is real in these tests and what stands in for hardware, MediaMTX and
# FFmpeg.

load scratch_tmpdir
load manager_stage

setup() {
    scratch_setup
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
    stage_setup
}

teardown() {
    stage_teardown
    scratch_teardown
}

# ---------------------------------------------------------------------------
# X-04: the cron restart budget is charged for restarts that are attempted
# ---------------------------------------------------------------------------

@test "a detected card that ALSA cannot open does not use up the cron restart budget; the restart goes ahead once it can [X-04]" {
    device_add mic1 31
    mediamtx_stub_up
    card_unavailable 31
    export CRON=1 CRON_RESTART_MAX_PER_HOUR=3

    # Ten cron cycles with the card unusable: the stream is reported failed
    # (exit 10) and nothing is restarted
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        stage 'monitor_streams'
        [ "$status" -eq 10 ]
    done
    [[ "$output" == *"ALSA device not available (card 31), skipping restart"* ]]
    [ ! -e "$ST/ff/mic1.pid" ]
    # The old order charged the budget BEFORE the ALSA check: after three cycles
    # it was spent without a single restart attempt
    [ "$(wc -l <"$CRON_RESTART_STATE_DIR/mic1.restarts" 2>/dev/null || echo 0)" -eq 0 ]

    # The card comes back: the stream is restarted, and that is the first
    # restart the budget is charged for
    card_available 31
    stage 'monitor_streams'
    [ "$status" -eq 0 ]
    [ -e "$ST/ff/mic1.pid" ]
    pid_running "$(stream_pid mic1)"
    [ "$(wc -l <"$CRON_RESTART_STATE_DIR/mic1.restarts")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# X-03: no devices is not "stable"
# ---------------------------------------------------------------------------

@test "an empty device list is not stable: the USB wait lasts until its deadline and fails when empty start is disabled [X-03]" {
    export STAGE_STABILIZE=: LYREBIRD_ALLOW_EMPTY_START=false
    stage 'SECONDS=0; rc=0; wait_for_usb_stabilization 6 || rc=$?; echo "rc=$rc elapsed=$SECONDS"'
    # The old guard (-n "$hash") passed for the digest of nothing, so two empty
    # scans counted as a stable subsystem and the wait ended after 4 s with
    # "stable with 0 devices" and rc=0
    [[ "$output" == *"rc=1 elapsed=6"* ]]
    [[ "$output" != *"stable with 0 devices"* ]]
    [[ "$output" == *"No USB audio devices detected after 6 seconds"* ]]
}

@test "with empty start allowed the USB wait still waits for the first device up to its deadline, then proceeds with none [X-03, D5]" {
    export STAGE_STABILIZE=:
    stage 'SECONDS=0; rc=0; wait_for_usb_stabilization 6 || rc=$?; echo "rc=$rc elapsed=$SECONDS"'
    [[ "$output" == *"rc=0 elapsed=6"* ]]
    [[ "$output" != *"stable with 0 devices"* ]]
    [[ "$output" == *"continuing without"* ]]
}

@test "a device that appears during the USB wait is waited for and counted [X-03]" {
    export STAGE_STABILIZE=:
    (
        sleep 1
        device_add mic1 31
    ) 3>&- &
    stage 'rc=0; wait_for_usb_stabilization 10 || rc=$?; echo "rc=$rc"'
    [[ "$output" == *"rc=0"* ]]
    [[ "$output" == *"stable with 1 devices"* ]]
}

# ---------------------------------------------------------------------------
# LB-07 / D5: a node with no device still starts MediaMTX and waits
# ---------------------------------------------------------------------------

@test "start with no USB audio device starts MediaMTX, reports that it is waiting for devices and exits 0 [LB-07, D5]" {
    export STAGE_STABILIZE=:
    stage 'COMMAND=start; install_lifecycle_traps; start_mediamtx'
    # (the real USB wait ran: nothing appeared before its deadline)
    [ "$status" -eq 0 ]
    [[ "$output" == *"waiting for devices"* ]]
    # MediaMTX is up and recorded by identity; there is no stream
    pid_running "$(mediamtx_pid)"
    [ -f "$MEDIAMTX_PID_FILE.id" ]
    ! compgen -G "$ST/ff/*.pid" >/dev/null
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]
}

@test "start with no device and LYREBIRD_ALLOW_EMPTY_START=false keeps the old refusal: exit 6, MediaMTX not started [LB-07, D5]" {
    export LYREBIRD_ALLOW_EMPTY_START=false
    stage 'COMMAND=start; install_lifecycle_traps; start_mediamtx'
    [ "$status" -eq 6 ]
    [[ "$output" == *"No USB audio devices detected"* ]]
    [ ! -e "$MEDIAMTX_PID_FILE" ]
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]
}

@test "a repeated start on a running MediaMTX with no device exits 0, or 6 when empty start is disabled [LB-07, D5]" {
    mediamtx_stub_up
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    [[ "$output" == *"waiting for devices"* ]]
    LYREBIRD_ALLOW_EMPTY_START=false stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 6 ]
    # the running MediaMTX was left alone either way
    pid_running "$(mediamtx_pid)"
}

@test "an invalid LYREBIRD_ALLOW_EMPTY_START is refused before anything is touched [D5]" {
    mediamtx_stub_up
    LYREBIRD_ALLOW_EMPTY_START=perhaps stage 'COMMAND=start; install_lifecycle_traps; start_mediamtx'
    [ "$status" -eq 4 ]
    [[ "$output" == *"Invalid LYREBIRD_ALLOW_EMPTY_START 'perhaps': use true or false"* ]]
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]
    pid_running "$(mediamtx_pid)"
}

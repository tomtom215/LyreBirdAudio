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

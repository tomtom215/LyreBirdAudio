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

# ---------------------------------------------------------------------------
# D5: the monitor reconciles 0 -> 1 -> N devices
# ---------------------------------------------------------------------------

# One monitor cycle (the real monitor_cycle: reconcile, then refresh the status)
monitor_once() {
    stage 'monitor_cycle'
}

@test "the monitor reconciles 0 -> 1 -> N: a node that started empty gets a stream for each device that appears, nothing running is restarted [LB-07, D5]" {
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    local mtx
    mtx="$(mediamtx_pid)"

    # still no device: the monitor waits
    monitor_once
    [ "$status" -eq 0 ]
    [[ "$output" == *"waiting for devices"* ]]
    jq -e '.command == "monitor" and .overall == "waiting_for_devices" and .streams == []' "$LYREBIRD_STATE_DIR/status.json"
    [ ! -e "$ST/ff/mic1.pid" ]

    # 0 -> 1
    device_add mic1 31
    monitor_once
    [ "$status" -eq 0 ]
    pid_running "$(stream_pid mic1)"
    jq -e '.command == "monitor" and .overall == "ok" and (.streams | length) == 1 and .streams[0].path == "mic1" and .streams[0].path_ready == true and .streams[0].bytes_flowing == true' "$LYREBIRD_STATE_DIR/status.json"
    local w1
    w1="$(stream_pid mic1)"

    # 1 -> N
    device_add mic2 32
    monitor_once
    [ "$status" -eq 0 ]
    pid_running "$(stream_pid mic2)"
    jq -e '.overall == "ok" and (.streams | length) == 2 and ([.streams[].path_ready] | all)' "$LYREBIRD_STATE_DIR/status.json"
    # the running MediaMTX and the first stream were left alone throughout
    [ "$(mediamtx_pid)" = "$mtx" ]
    [ "$(stream_pid mic1)" = "$w1" ]
}

@test "a device that is unplugged is not restarted, and comes back when it is plugged in again [D5]" {
    device_add mic1 31
    device_add mic2 32
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    local w1 w2
    w1="$(stream_pid mic1)"
    w2="$(stream_pid mic2)"

    # mic1 is unplugged: its wrapper ends (as the generated wrapper does when its
    # device node is gone) and the monitor has nothing to restart for it
    device_remove 31
    kill -TERM "$w1"
    wait_until '! pid_running '"$w1" 10
    monitor_once
    [ "$status" -eq 0 ]
    [ ! -e "$ST/ff/mic1.pid" ]
    [ "$(stream_pid mic2)" = "$w2" ]
    jq -e '(.streams | length) == 1 and .streams[0].path == "mic2" and .overall == "ok"' "$LYREBIRD_STATE_DIR/status.json"

    # plugged in again
    device_add mic1 31
    monitor_once
    [ "$status" -eq 0 ]
    pid_running "$(stream_pid mic1)"
    [ "$(stream_pid mic1)" != "$w1" ]
    [ "$(stream_pid mic2)" = "$w2" ]
    jq -e '(.streams | length) == 2 and .overall == "ok"' "$LYREBIRD_STATE_DIR/status.json"
}

@test "in multiplex mode the monitor starts the stream again with the new device when one is added, and leaves it alone otherwise [D5]" {
    export STREAM_MODE=multiplex
    device_add mic1 31
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    local w
    w="$(stream_pid all_mics)"
    jq -e '.streams[0].device == "mic1"' "$LYREBIRD_STATE_DIR/status.json"

    # nothing changed: nothing restarts
    monitor_once
    [ "$status" -eq 0 ]
    [ "$(stream_pid all_mics)" = "$w" ]

    # a second microphone: the running wrapper captured one, so it is replaced
    device_add mic2 32
    monitor_once
    [ "$status" -eq 0 ]
    [[ "$output" == *"the set of devices changed - restarting"* ]]
    pid_running "$(stream_pid all_mics)"
    [ "$(stream_pid all_mics)" != "$w" ]
    jq -e '.streams[0].device == "mic1,mic2" and .streams[0].card == "31,32" and .overall == "ok"' "$LYREBIRD_STATE_DIR/status.json"

    # and then it is stable again
    w="$(stream_pid all_mics)"
    monitor_once
    [ "$(stream_pid all_mics)" = "$w" ]
}

@test "with no device the monitor exits 0 (waiting), or 6 when empty start is disabled [D5]" {
    mediamtx_stub_up
    stage 'monitor_streams'
    [ "$status" -eq 0 ]
    LYREBIRD_ALLOW_EMPTY_START=false stage 'monitor_streams'
    [ "$status" -eq 6 ]
}

# ---------------------------------------------------------------------------
# D5: a MediaMTX that is gone comes back when the node is meant to run
# ---------------------------------------------------------------------------

@test "MediaMTX killed while the node is meant to run: the monitor starts it again, its stream publishes again [LB-07, D5]" {
    device_add mic1 31
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    local mtx w
    mtx="$(mediamtx_pid)"
    w="$(stream_pid mic1)"
    kill -KILL "$mtx"
    wait_until '! pid_running '"$mtx" 10

    monitor_once
    [ "$status" -eq 0 ]
    [[ "$output" == *"MediaMTX is not running although the node is meant to run"* ]]
    [[ "$output" == *"MediaMTX was started again"* ]]
    pid_running "$(mediamtx_pid)"
    [ "$(mediamtx_pid)" != "$mtx" ]
    pid_running "$(stream_pid mic1)"
    [ "$(stream_pid mic1)" != "$w" ]
    jq -e '.command == "monitor" and .overall == "ok" and .mediamtx.running == true and .streams[0].path_ready == true' "$LYREBIRD_STATE_DIR/status.json"
    # one restart is charged to the budget
    [ "$(wc -l <"$CRON_RESTART_STATE_DIR/_mediamtx.restarts")" -eq 1 ]
}

@test "a crash loop is bounded: the monitor starts MediaMTX again only CRON_RESTART_MAX_PER_HOUR times an hour [D5]" {
    export CRON_RESTART_MAX_PER_HOUR=2
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    local i mtx
    for i in 1 2; do
        mtx="$(mediamtx_pid)"
        kill -KILL "$mtx"
        wait_until '! pid_running '"$mtx" 10
        monitor_once
        [ "$status" -eq 0 ]
        pid_running "$(mediamtx_pid)"
    done
    # the third time the budget is used up: nothing is started, the monitor says so
    mtx="$(mediamtx_pid)"
    kill -KILL "$mtx"
    wait_until '! pid_running '"$mtx" 10
    monitor_once
    [ "$status" -eq 7 ]
    [[ "$output" == *"restart budget (2/hour) is used up; not starting it"* ]]
    [ ! -e "$MEDIAMTX_PID_FILE" ]
    ! pid_running "$mtx"
    jq -e '.overall == "failed" and .mediamtx.running == false' "$LYREBIRD_STATE_DIR/status.json"
}

@test "an intentionally stopped node is not resurrected, and neither is one that was never started [D5]" {
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    stage 'COMMAND=stop; stop_mediamtx'
    [ "$status" -eq 0 ]
    monitor_once
    [ "$status" -eq 7 ]
    [[ "$output" == *"MediaMTX is not running - skipping stream health check"* ]]
    [ ! -e "$MEDIAMTX_PID_FILE" ]
    [ -z "$(stage_processes)" ]
    jq -e '.overall == "stopped"' "$LYREBIRD_STATE_DIR/status.json"
    # never started (no marker at all)
    rm -f "$LYREBIRD_STATE_DIR/desired-running"
    monitor_once
    [ "$status" -eq 7 ]
    [ -z "$(stage_processes)" ]
}

@test "a restart that fails is reported (exit 7), charged to the budget, and leaves nothing half-started [D5]" {
    device_add mic1 31
    bad_card 31
    export LYREBIRD_START_POLICY=strict
    mediamtx_stub_up
    : >"$LYREBIRD_STATE_DIR/desired-running"
    local mtx
    mtx="$(mediamtx_pid)"
    kill -KILL "$mtx"
    wait_until '! pid_running '"$mtx" 10
    monitor_once
    [ "$status" -eq 7 ]
    [[ "$output" == *"Starting MediaMTX again failed (exit 9)"* ]]
    wait_until '[ -z "$(stage_processes)" ]' 5
    [ -s "$LYREBIRD_STATE_DIR/desired-running" ]
    [ "$(wc -l <"$CRON_RESTART_STATE_DIR/_mediamtx.restarts")" -eq 1 ]
}

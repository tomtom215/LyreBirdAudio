#!/usr/bin/env bats
# Truthful start outcome, status file and policy of lyrebird-stream-manager.sh
# (register: LB-03, X-27; decisions D4, D5). See tests/manager_stage.bash for
# what is real in these tests (the manager, its wrappers, locks, PID files,
# markers, real child processes) and what stands in for hardware, MediaMTX and
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
# The exit trap: the cleanup marker is for interrupted runs, not for failures
# ---------------------------------------------------------------------------

@test "a failed command leaves no cleanup marker and the wrappers of the running stack keep running [new defect, LB-03]" {
    device_add mic1 31
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    local mtx w1
    mtx="$(mediamtx_pid)"
    w1="$(stream_pid mic1)"
    pid_running "$mtx"
    pid_running "$w1"

    # The real script, run as the operator would: it fails (a MediaMTX binary
    # that is not there: exit 3; as a non-root user: exit 1) before it touches
    # anything. The old exit trap left the cleanup marker after ANY non-zero
    # exit, and every wrapper stops at its next loop while the marker exists.
    run env MEDIAMTX_BINARY="$ST/not-installed" bash "$PROJECT_ROOT/lyrebird-stream-manager.sh" start
    [ "$status" -ne 0 ]
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]
    pid_running "$mtx"
    pid_running "$w1"
    [ "$(mediamtx_pid)" = "$mtx" ]
    [ "$(stream_pid mic1)" = "$w1" ]
}

@test "a start terminated by SIGTERM after it launched MediaMTX exits 143, takes down what it started and leaves no marker [new defect]" {
    device_add mic1 31
    stage_bg 'install_lifecycle_traps
COMMAND=start
start_all_ffmpeg_streams() { : >"$ST/in-streams"; while [[ ! -e "$ST/release" ]]; do sleep 0.1; done; }
start_mediamtx'
    wait_until '[[ -e "$ST/in-streams" ]]' 20
    local mtx
    mtx="$(mediamtx_pid)"
    pid_running "$mtx"
    kill -TERM "$STAGE_PID"
    local rc=0
    wait "$STAGE_PID" || rc=$?
    [ "$rc" -eq 143 ]
    # what this run launched is gone, with its record, and no marker is left
    ! pid_running "$mtx"
    [ ! -e "$MEDIAMTX_PID_FILE" ]
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]
}

@test "a start terminated while its teardown fails leaves the cleanup marker, so the next start cleans up [new defect]" {
    device_add mic1 31
    stage_bg 'install_lifecycle_traps
COMMAND=start
stop_recorded_process() { return 1; }
start_all_ffmpeg_streams() { : >"$ST/in-streams"; while [[ ! -e "$ST/release" ]]; do sleep 0.1; done; }
start_mediamtx'
    wait_until '[[ -e "$ST/in-streams" ]]' 20
    kill -TERM "$STAGE_PID"
    local rc=0
    wait "$STAGE_PID" || rc=$?
    [ "$rc" -eq 143 ]
    # MediaMTX could not be taken down: the run is recorded as interrupted
    [ -e "$MEDIAMTX_CLEANUP_MARKER" ]
}

# ---------------------------------------------------------------------------
# The start policy (D4): exit status and what is left running
# ---------------------------------------------------------------------------

# start under policy $1 with the installed stage; leaves status/output of the run
start_with_policy() {
    LYREBIRD_START_POLICY="$1" stage 'COMMAND=start; install_lifecycle_traps; start_mediamtx'
}

# Nothing of this installation runs and nothing is recorded as running. (A
# wrapper that start_ffmpeg_stream stopped for failing its own validation is
# still finishing its signal handler: give it a moment.)
assert_torn_down() {
    wait_until '[ -z "$(stage_processes)" ]' 5
    [ ! -e "$MEDIAMTX_PID_FILE" ]
    ! compgen -G "$ST/ff/*.pid" >/dev/null
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]
}

@test "policy matrix, every stream publishes: degraded and strict both exit 0, state ok [LB-03, D4]" {
    device_add mic1 31
    device_add mic2 32
    start_with_policy degraded
    [ "$status" -eq 0 ]
    jq -e '.overall == "ok" and .policy == "degraded" and ([.streams[].path_ready] | all)' "$LYREBIRD_STATE_DIR/status.json"
    stage 'COMMAND=stop; stop_mediamtx'
    [ "$status" -eq 0 ]

    start_with_policy strict
    [ "$status" -eq 0 ]
    jq -e '.overall == "ok" and .policy == "strict"' "$LYREBIRD_STATE_DIR/status.json"
    pid_running "$(mediamtx_pid)"
}

@test "policy matrix, one stream publishes and one does not: degraded exits 0 with state degraded and names the failure; strict exits 9 and stops everything [LB-03, D4]" {
    device_add mic1 31
    device_add mic2 32
    bad_card 32
    start_with_policy degraded
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] rtsp://stage.invalid:8554/mic1"* ]]
    [[ "$output" == *"[FAIL] rtsp://stage.invalid:8554/mic2"* ]]
    jq -e '.overall == "degraded" and .streams[0].path_ready == true and .streams[1].path_ready == false and (.streams[1].last_error | length > 0)' "$LYREBIRD_STATE_DIR/status.json"
    pid_running "$(mediamtx_pid)"
    pid_running "$(stream_pid mic1)"
    stage 'COMMAND=stop; stop_mediamtx'

    start_with_policy strict
    [ "$status" -eq 9 ]
    [[ "$output" == *"Start failed: 1 of 2 streams are publishing (policy strict)"* ]]
    # what this run started is gone: no half-running stack, no marker
    assert_torn_down
    # and the record says what happened: failed, MediaMTX down, each stream's reason
    jq -e '.overall == "failed" and .policy == "strict" and .mediamtx.running == false' "$LYREBIRD_STATE_DIR/status.json"
    jq -e '.streams[0].last_error | test("stopped again because the start failed under policy .strict.")' "$LYREBIRD_STATE_DIR/status.json"
    jq -e '.streams[1].last_error | length > 0' "$LYREBIRD_STATE_DIR/status.json"
    # the node is still meant to run: the monitor may try again
    [ -s "$LYREBIRD_STATE_DIR/desired-running" ]
}

@test "policy matrix, no stream publishes: degraded and strict both exit 9, everything this run started is stopped [LB-03, D4]" {
    device_add mic1 31
    bad_card 31
    local policy
    for policy in degraded strict; do
        start_with_policy "$policy"
        [ "$status" -eq 9 ]
        [[ "$output" == *"[FAIL] rtsp://stage.invalid:8554/mic1"* ]]
        [[ "$output" == *"Start failed: 0 of 1 streams are publishing (policy $policy)"* ]]
        assert_torn_down
        jq -e '.overall == "failed" and .mediamtx.running == false and .streams[0].path_ready == false and (.streams[0].last_error | length > 0)' "$LYREBIRD_STATE_DIR/status.json"
    done
}

@test "policy matrix, no device: degraded and strict both exit 0, state waiting_for_devices [LB-03, D5]" {
    local policy
    for policy in degraded strict; do
        start_with_policy "$policy"
        [ "$status" -eq 0 ]
        jq -e '.overall == "waiting_for_devices" and .streams == []' "$LYREBIRD_STATE_DIR/status.json"
        stage 'COMMAND=stop; stop_mediamtx'
    done
}

@test "an FFmpeg that runs but never reaches MediaMTX no longer counts as 'started': exit 9, not 'Successfully started all 1/1' [LB-03]" {
    device_add mic1 31
    echo silent >"$ST/api-shape"
    start_with_policy degraded
    [ "$status" -eq 9 ]
    # the launcher's own check passed on the running FFmpeg (the old exit-0 case)...
    grep -q 'Stream mic1 started successfully\|validated via process' "$MEDIAMTX_LOG_FILE"
    # ... the path was never ready in MediaMTX
    [[ "$output" == *"[FAIL] rtsp://stage.invalid:8554/mic1"* ]]
    [[ "$output" == *"nothing is publishing"* ]]
    assert_torn_down
}

@test "multiplex mode follows the policy too: a stream that never publishes exits 9 and stops MediaMTX; a good one exits 0 [LB-03]" {
    export STREAM_MODE=multiplex
    device_add mic1 31
    device_add mic2 32
    start_with_policy degraded
    [ "$status" -eq 0 ]
    jq -e '.stream_mode == "multiplex" and .overall == "ok" and (.streams | length) == 1 and .streams[0].path == "all_mics" and .streams[0].device == "mic1,mic2" and .streams[0].card == "31,32" and .streams[0].bytes_flowing == true' "$LYREBIRD_STATE_DIR/status.json"
    stage 'COMMAND=stop; stop_mediamtx'
    [ "$status" -eq 0 ]

    # a launcher that works but a stream that never reaches MediaMTX: the old
    # multiplex path returned 0 here (validation failure)
    echo silent >"$ST/api-shape"
    start_with_policy degraded
    [ "$status" -eq 9 ]
    [[ "$output" == *"[FAIL] rtsp://stage.invalid:8554/all_mics"* ]]
    assert_torn_down
}

@test "a failed start leaves a healthy stack that was already running untouched: same PIDs, still publishing, no marker [LB-03, LB-01, D4]" {
    device_add mic1 31
    start_with_policy strict
    [ "$status" -eq 0 ]
    local mtx w1
    mtx="$(mediamtx_pid)"
    w1="$(stream_pid mic1)"

    # a second microphone that cannot capture: the repeated start fails under strict
    device_add mic2 32
    bad_card 32
    start_with_policy strict
    [ "$status" -eq 9 ]
    [[ "$output" == *"Start failed: 1 of 2 streams are publishing (policy strict)"* ]]
    [ "$(mediamtx_pid)" = "$mtx" ]
    [ "$(stream_pid mic1)" = "$w1" ]
    pid_running "$mtx"
    pid_running "$w1"
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]
    # the stream that was publishing keeps publishing (the manager did not stop it)
    stage 'show_status --json'
    [[ "$output" == *'"path":"mic1","configured":true,"process_alive":true,"path_ready":true'* ]]
    # no wrapper of the failed attempt is left behind
    [ ! -e "$ST/ff/mic2.pid" ]
}

@test "a device whose /dev/snd control node is missing is reported, not silently skipped: warning, failed stream, last_error [X-27]" {
    device_add mic1 31
    device_add mic2 32
    rm -f "$HW/dev-snd/controlC32"
    start_with_policy degraded
    # the other microphone publishes: degraded
    [ "$status" -eq 0 ]
    [[ "$output" == *"Not starting mic2 (card 32): device node /dev/snd/controlC32 does not exist"* ]]
    [[ "$output" == *"[FAIL] rtsp://stage.invalid:8554/mic2"* ]]
    [[ "$output" == *"Started 1/2 FFmpeg streams. Failed: mic2"* ]]
    jq -e '.overall == "degraded" and .streams[1].configured == false and .streams[1].last_error == "device node /dev/snd/controlC32 does not exist"' "$LYREBIRD_STATE_DIR/status.json"
    # on its own, such a device is a failed start, no longer 'Successfully started all 0/1'
    stage 'COMMAND=stop; stop_mediamtx'
    device_remove 31
    start_with_policy degraded
    [ "$status" -eq 9 ]
    [[ "$output" != *"Successfully started all"* ]]
}

@test "an invalid LYREBIRD_START_POLICY is refused with exit 4 before anything is touched; a running stack and its markers stay as they were [D4]" {
    device_add mic1 31
    start_with_policy degraded
    [ "$status" -eq 0 ]
    local mtx
    mtx="$(mediamtx_pid)"
    start_with_policy sloppy
    [ "$status" -eq 4 ]
    [[ "$output" == *"Invalid LYREBIRD_START_POLICY 'sloppy'"* ]]
    [[ "$output" == *"degraded"* && "$output" == *"strict"* ]]
    [ "$(mediamtx_pid)" = "$mtx" ]
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]
    pid_running "$(stream_pid mic1)"
}

@test "help documents the policy, the empty start, status --json and the complete exit code table [D4, D5]" {
    stage 'show_help'
    [[ "$output" == *"LYREBIRD_START_POLICY"* ]]
    [[ "$output" == *"LYREBIRD_ALLOW_EMPTY_START"* ]]
    [[ "$output" == *"status --json"* ]]
    local code
    for code in "0  - Success" "1  - General error" "2  - Critical resource state" "3  - Missing dependencies" "4  - Configuration error" "5  - Lock acquisition failed" "6  - No USB devices found" "7  - MediaMTX not running" "8  - Another MediaMTX owns the node" "9  - Streams failed" "10 - Stream monitoring degraded" "128+N - Terminated by signal"; do
        [[ "$output" == *"$code"* ]] || {
            echo "exit code table lacks: $code"
            false
        }
    done
}

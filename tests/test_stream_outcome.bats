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

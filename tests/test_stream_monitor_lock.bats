#!/usr/bin/env bats
# The monitor takes the lifecycle lock (register: LB-05 completion, D5).
#
# Real processes hold and contend for the real lock file (flock on
# MEDIAMTX_LOCK_FILE); the monitor is the real monitor_cycle. See
# tests/manager_stage.bash for what stands in for hardware, MediaMTX and FFmpeg.

load scratch_tmpdir
load manager_stage

setup() {
    scratch_setup
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
    stage_setup
    HOLDER=""
}

teardown() {
    [[ -z "${HOLDER:-}" ]] || kill "$HOLDER" 2>/dev/null || true
    stage_teardown
    scratch_teardown
}

# A real manager process that holds the lifecycle lock (acquire_lock records its
# PID and start time) until it is killed: what a start, stop, restart or
# force-stop in progress looks like to the monitor. It waits with a builtin, so
# that no child process inherits the lock descriptor.
hold_lock() {
    rm -f "$ST/holder.ready"
    stage_bg 'acquire_lock 5; : >"$ST/holder.ready"; read -r -t 120 <>"$ST/hold"'
    HOLDER=$STAGE_PID
    wait_until '[[ -e "$ST/holder.ready" ]]' 10
}

release_lock_holder() {
    kill "$HOLDER"
    wait "$HOLDER" 2>/dev/null || true
    HOLDER=""
}

# A running stack whose only stream has lost its wrapper (the monitor would
# restart it), with the old wrapper's PID file still on disk
stack_with_dead_wrapper() {
    device_add mic1 31
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    local w child
    w="$(stream_pid mic1)"
    for child in $(ps -o pid= --ppid "$w"); do
        kill -KILL "$child"
    done
    kill -KILL "$w"
    wait_until '! pid_running '"$w" 10
    DEAD_WRAPPER="$w"
}

@test "while a lifecycle command holds the lock the monitor logs that it is busy and skips its cycle with exit 0, touching nothing [LB-05]" {
    stack_with_dead_wrapper
    stage 'monitor_cycle'
    [ "$status" -eq 0 ]
    local before
    before="$(cat "$LYREBIRD_STATE_DIR/status.json")"
    # (that cycle restarted the stream; kill it again to have work for the next)
    local w child
    w="$(stream_pid mic1)"
    for child in $(ps -o pid= --ppid "$w"); do
        kill -KILL "$child"
    done
    kill -KILL "$w"
    wait_until '! pid_running '"$w" 10

    hold_lock
    SECONDS=0
    stage 'monitor_cycle'
    [ "$status" -eq 0 ]
    # waited about MONITOR_LOCK_TIMEOUT (1 s), not longer
    [ "$SECONDS" -le 8 ]
    [[ "$output" == *"busy, skipping this cycle"* ]]
    [[ "$output" == *"PID $HOLDER (start time"* ]]
    # nothing was touched: the dead wrapper's PID file is still there, no new
    # wrapper was started, the status file is as it was
    [ "$(stream_pid mic1)" = "$w" ]
    ! pid_running "$w"
    [ "$(cat "$LYREBIRD_STATE_DIR/status.json")" = "$before" ]

    # the lock is free again: the same monitor now does its work
    release_lock_holder
    stage 'monitor_cycle'
    [ "$status" -eq 0 ]
    pid_running "$(stream_pid mic1)"
    [ "$(stream_pid mic1)" != "$w" ]
}

@test "a MediaMTX that is gone is not started again by the monitor while a start holds the lock [LB-05, D5]" {
    device_add mic1 31
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    local mtx
    mtx="$(mediamtx_pid)"
    kill -KILL "$mtx"
    wait_until '! pid_running '"$mtx" 10
    hold_lock
    stage 'monitor_cycle'
    [ "$status" -eq 0 ]
    [[ "$output" == *"busy, skipping this cycle"* ]]
    [[ "$output" != *"starting it again"* ]]
    # nothing was started and nothing was charged to the budget
    [ "$(mediamtx_pid)" = "$mtx" ]
    ! pid_running "$mtx"
    [ ! -e "$CRON_RESTART_STATE_DIR/_mediamtx.restarts" ]
}

@test "a monitor cycle in progress holds the lock: a stop that arrives meanwhile is refused (exit 5) instead of overlapping, and goes through afterwards [LB-05]" {
    stack_with_dead_wrapper
    # a restart that takes a while (the real start_ffmpeg_stream is slow too)
    stage_bg 'start_ffmpeg_stream() { : >"$ST/in-restart"; sleep 3; return 1; }
monitor_cycle'
    local monitor=$STAGE_PID
    wait_until '[[ -e "$ST/in-restart" ]]' 10
    stage 'COMMAND=stop; stop_mediamtx'
    [ "$status" -eq 5 ]
    [[ "$output" == *"Refusing to stop: another lifecycle command holds the lock"* ]]
    # (nothing was stopped: MediaMTX is still up)
    pid_running "$(mediamtx_pid)"
    wait "$monitor" || true
    stage 'COMMAND=stop; stop_mediamtx'
    [ "$status" -eq 0 ]
}

@test "the lock is released before the status refresh, which samples the streams for seconds, so a stop never waits for it [LB-05]" {
    device_add mic1 31
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    stage_bg 'status_refresh() { : >"$ST/in-refresh"; sleep 3; }
monitor_cycle'
    local monitor=$STAGE_PID
    wait_until '[[ -e "$ST/in-refresh" ]]' 10
    # the lock can be taken without waiting while the refresh runs
    flock -n "$MEDIAMTX_LOCK_FILE" true
    wait "$monitor"
}

@test "the monitor never removes or replaces the lock file, and a monitor run by the cron line's own lock still takes the lifecycle lock [LB-05, D2]" {
    device_add mic1 31
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    exec 9<"$MEDIAMTX_LOCK_FILE"
    # the cron line holds /run/mediamtx-monitor.lock while it runs the monitor
    local cron_lock="$ST/monitor-cron.lock"
    run flock "$cron_lock" bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"; eval "$STAGE_SEAMS"; eval "$STAGE_STABILIZE"; monitor_cycle'
    [ "$status" -eq 0 ]
    [[ "/proc/$$/fd/9" -ef "$MEDIAMTX_LOCK_FILE" ]]
    exec 9<&-
    # the record in the lock file is the monitor's own: pid and start time
    [[ "$(head -c 64 "$MEDIAMTX_LOCK_FILE")" =~ ^[0-9]+\ [0-9]+\ *$ ]]
}

@test "monitor_streams keeps errexit on when the monitor runs it under the lock, as it had before: a failing command still ends it [LB-05]" {
    # an unguarded failing command inside it must still end it (a `||` around
    # the call would switch errexit off for the whole function), and what it
    # returns is what the monitor returns
    stage 'monitor_streams() { false; echo "continued after a failing command"; }
monitor_cycle'
    [ "$status" -eq 1 ]
    [[ "$output" != *"continued after a failing command"* ]]
    flock -n "$MEDIAMTX_LOCK_FILE" true
}

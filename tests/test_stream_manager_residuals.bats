#!/usr/bin/env bats
# Three small defects found while the manager work was merged (items 8b, 8c and 8d of
# the residual manager work). See tests/manager_stage.bash for what is real in these
# tests (the manager, its wrappers, locks, PID files, markers, real child processes,
# and for 8d the real ffmpeg) and what stands in for hardware, MediaMTX and the
# wrappers' FFmpeg.
#
#   8b  start_ffmpeg_stream stopped the wrapper of a stream that failed its own
#       validation with a bare, non-waiting `kill` and left <stream>.pid.id behind.
#   8c  the multiplex branches of monitor_streams charged the cron restart budget
#       before any ALSA availability check (X-04 fixed that for the individual branches).
#   8d  an individual stream's CHANNELS against its codec (4 channels with opus) was
#       not checked before launch: the wrapper started, FFmpeg refused, and it did so
#       again at every restart.

load scratch_tmpdir
load manager_stage

setup() {
    scratch_setup
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
    MANAGER="$PROJECT_ROOT/lyrebird-stream-manager.sh"
    stage_setup
}

teardown() {
    stage_teardown
    scratch_teardown
}

# ---------------------------------------------------------------------------
# 8b: a stream that fails its own validation is stopped properly
# ---------------------------------------------------------------------------

@test "a stream that fails its own validation is stopped by identity before start_ffmpeg_stream returns: no wrapper, no FFmpeg, no PID file, no start-time record [8b]" {
    device_add mic1 31
    bad_card 31
    stage 'rc=0; start_ffmpeg_stream mic1 31 mic1 || rc=$?; echo "rc=$rc"'
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"Stream mic1 failed validation"* ]]
    # at once, with no waiting for a signal handler to finish: the bare kill returned immediately
    # and the wrapper (asleep in its back-off) ran on for a second or more
    [ -z "$(stage_processes)" ]
    [ ! -e "$ST/ff/mic1.pid" ]
    # the start-time record beside the PID file went with it
    [ ! -e "$ST/ff/mic1.pid.id" ]
    [ ! -e "$ST/ff/mic1.sh" ]
    # the FFmpeg log stays: it is the post-mortem
    [ -e "$ST/ff/mic1.log" ]
}

@test "a wrapper that cannot be stopped after a failed validation keeps its PID file, and the failure is logged [8b]" {
    device_add mic1 31
    bad_card 31
    # Stood in for: the signalling, which does nothing and says the process would not die
    stage 'terminate_process_group() { return 1; }; rc=0; start_ffmpeg_stream mic1 31 mic1 || rc=$?; echo "rc=$rc"'
    [[ "$output" == *"rc=1"* ]]
    # still running, so its record must stay for the next stop or cleanup to find it
    [ -e "$ST/ff/mic1.pid" ]
    [ -e "$ST/ff/mic1.pid.id" ]
    pid_running "$(stream_pid mic1)"
    grep -qF 'could not be stopped after the failed validation; its PID file is kept' "$ST/sm.log"
}

# ---------------------------------------------------------------------------
# 8c: the multiplex monitor checks ALSA before it charges the restart budget
# ---------------------------------------------------------------------------

# a multiplex node: two microphones, the stack started by the real start, then its wrapper killed
multiplex_node_with_dead_wrapper() {
    device_add mic1 31
    device_add mic2 33
    stage 'STREAM_MODE=multiplex; MULTIPLEX_STREAM_NAME=mix; resolve_multiplex_stream_name; COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    local wrapper
    wrapper="$(stream_pid mix)"
    pid_running "$wrapper"
    kill -KILL "$wrapper"
    wait_until '! pid_running '"$wrapper" 10
}

@test "a multiplex stream whose cards ALSA cannot open does not use up the cron restart budget; the restart goes ahead once one can [8c, X-04]" {
    multiplex_node_with_dead_wrapper
    card_unavailable 31
    card_unavailable 33
    export CRON=1 CRON_RESTART_MAX_PER_HOUR=3

    # Six cron cycles with every card unusable: the stream is reported failed (exit 10) and nothing is
    # restarted. The old order charged the budget BEFORE any ALSA check: after three cycles it was
    # spent without a restart attempt, and from then on the log said "restart budget exhausted"
    local i
    for i in 1 2 3 4 5 6; do
        stage 'STREAM_MODE=multiplex; MULTIPLEX_STREAM_NAME=mix; resolve_multiplex_stream_name; monitor_streams'
        [ "$status" -eq 10 ]
    done
    [[ "$output" == *"Multiplex stream mix: ALSA device not available (card 31, 33), skipping restart"* ]]
    [[ "$output" != *"restart budget"* ]]
    [ "$(wc -l <"$CRON_RESTART_STATE_DIR/mix.restarts" 2>/dev/null || echo 0)" -eq 0 ]

    # One card comes back: that is enough for the multiplex stream (the start leaves out the other),
    # and the first restart is the first thing the budget is charged for
    card_available 31
    stage 'STREAM_MODE=multiplex; MULTIPLEX_STREAM_NAME=mix; resolve_multiplex_stream_name; monitor_streams'
    [ "$status" -eq 0 ]
    pid_running "$(stream_pid mix)"
    [ "$(wc -l <"$CRON_RESTART_STATE_DIR/mix.restarts")" -eq 1 ]
}

# The other four places of monitor_streams that charge the budget for the multiplex stream. Each
# gets the same treatment: every card unusable, six cron cycles, nothing charged, nothing restarted.
# MONITOR_MUX is the code every cycle runs.
MONITOR_MUX='STREAM_MODE=multiplex; MULTIPLEX_STREAM_NAME=mix; resolve_multiplex_stream_name; monitor_streams'

assert_multiplex_never_charged() {
    local i
    export CRON=1 CRON_RESTART_MAX_PER_HOUR=3
    for i in 1 2 3 4 5 6; do
        stage "${1:-$MONITOR_MUX}"
        [ "$status" -eq 10 ] || {
            echo "cycle $i: $output"
            false
        }
    done
    [[ "$output" == *"Multiplex stream mix: ALSA device not available"* ]]
    [[ "$output" != *"restart budget"* ]]
    [ ! -e "$CRON_RESTART_STATE_DIR/mix.restarts" ]
}

@test "a multiplex stream with no PID file is not restarted, and the budget is not charged, while no card can be opened [8c, X-04]" {
    multiplex_node_with_dead_wrapper
    rm -f "$ST/ff/mix.pid" "$ST/ff/mix.pid.id"
    card_unavailable 31
    card_unavailable 33
    assert_multiplex_never_charged
    [ ! -e "$ST/ff/mix.pid" ]
}

@test "a multiplex PID file that names a process that is not the wrapper is not acted on, and the budget is not charged, while no card can be opened [8c, X-04]" {
    multiplex_node_with_dead_wrapper
    # a live process that is not the wrapper, recorded as if it were
    sleep 300 &
    local other=$!
    disown "$other"
    echo "$other" >"$ST/ff/mix.pid"
    rm -f "$ST/ff/mix.pid.id"
    card_unavailable 31
    card_unavailable 33
    assert_multiplex_never_charged
    # not signalled either: the stale record is not ours to act on, and the restart was not asked for
    pid_running "$other"
    kill -KILL "$other"
}

@test "a multiplex wrapper that is alive but whose path is stuck is not killed, and the budget is not charged, while no card can be opened [8c, X-04]" {
    device_add mic1 31
    device_add mic2 33
    stage 'STREAM_MODE=multiplex; MULTIPLEX_STREAM_NAME=mix; resolve_multiplex_stream_name; COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    local wrapper
    wrapper="$(stream_pid mix)"
    card_unavailable 31
    card_unavailable 33
    # Stood in for: the API probe, which says the path is not ready (a hung FFmpeg); the strike
    # counting (one strike is enough here) and everything after it are real
    export DEEP_HEALTH_MAX_STRIKES=1
    assert_multiplex_never_charged "probe_stream_ready() { return 1; }; ${MONITOR_MUX}"
    pid_running "$wrapper"
}

@test "a multiplex wrapper that does not have a new device is not restarted, and the budget is not charged, while no card can be opened [8c, X-04]" {
    device_add mic1 31
    device_add mic2 33
    stage 'STREAM_MODE=multiplex; MULTIPLEX_STREAM_NAME=mix; resolve_multiplex_stream_name; COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    local wrapper
    wrapper="$(stream_pid mix)"
    # a third microphone appears, and no card can be opened
    device_add mic3 35
    card_unavailable 31
    card_unavailable 33
    card_unavailable 35
    assert_multiplex_never_charged
    pid_running "$wrapper"
    # once a card can be opened the wrapper is restarted with the new set, and that is charged once
    card_available 35
    stage "$MONITOR_MUX"
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$CRON_RESTART_STATE_DIR/mix.restarts")" -eq 1 ]
    [ "$(cat "$ST/ff/mix.devices")" = "mic1:31,mic2:33,mic3:35," ]
}

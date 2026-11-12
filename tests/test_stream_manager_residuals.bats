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

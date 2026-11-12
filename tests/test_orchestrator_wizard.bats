#!/usr/bin/env bats
# The Quick Setup Wizard of lyrebird-orchestrator.sh (register: LB-21): what it
# says after it has started the streams. It used to print its summary from the
# state it had refreshed BEFORE the start step: a start that worked on a fresh
# node ended in "completed with warnings ... may require a reboot", and a start
# that failed on a node that was already streaming ended in "Your RTSP streams
# are now available!". Real orchestrator, stand-ins for the six delegated
# scripts, on a pseudo-terminal (see tests/orchestrator_helper.bash).

load scratch_tmpdir
load orchestrator_helper

setup() {
    scratch_setup
    orch_setup
    command -v jq >/dev/null || skip "jq is needed"
}

teardown() {
    scratch_teardown
}

# wizard [PREAMBLE]: answer every prompt of the wizard (the first confirmation,
# the USB mapping step, the continuation after it, the final "Press Enter")
wizard() {
    orch_run \
        --step 'Continue with quick setup\? \(y/n\)' 'y' \
        --step 'Continue\? \(y/n\)' 'y' \
        --step 'Continue\? \(y/n\)' 'y' \
        --step 'Press Enter to continue' '\n' \
        "${1:-}
menu_quick_setup"
}

# What the wizard ends with: everything after the diagnostics step
summary() {
    printf '%s' "${output#*Step 4/4}"
}

# ---------------------------------------------------------------------------
# The two stale-state defects
# ---------------------------------------------------------------------------

@test "wizard: a start that works is reported as available streams, not 'completed with warnings' [LB-21]" {
    # A fresh node: nothing ran before the start, so the state the wizard read
    # before it (MediaMTX stopped, no FFmpeg) says "not running"
    orch_doc "$ORCH_DIR/ok.json" ok true "mic1|true|true|" "mic2|true|true|"
    export STUB_DOC_start="$ORCH_DIR/ok.json"
    wizard
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(summary)" == *"[OK] Quick setup complete!"* ]]
    [[ "$(summary)" == *"Your RTSP streams are now available"* ]]
    [[ "$(summary)" == *":8554/mic1"* ]]
    [[ "$(summary)" == *":8554/mic2"* ]]
    [[ "$output" != *"completed with warnings"* ]]
    [[ "$(summary)" != *"reboot"* ]]
}

@test "wizard: a start that failed is not reported as available streams, whatever ran before it [LB-21]" {
    # A re-run: MediaMTX and two FFmpeg processes were running before the start
    # (the state the wizard read in step 2), and this start fails
    export STUB_PGREP_MEDIAMTX=1 STUB_PGREP_FFMPEG=2
    orch_doc "$ORCH_DIR/failed.json" failed false "mic1|false|false|the stream could not be started (see mic1.log)" "mic2|false|false|the stream could not be started (see mic2.log)"
    export STUB_DOC_start="$ORCH_DIR/failed.json" STUB_RC_stream_manager_start=9
    wizard
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(summary)" == *"[ERROR] Quick setup did not finish: no stream is publishing"* ]]
    [[ "$(summary)" == *"[FAIL] mic1: not publishing - the stream could not be started (see mic1.log)"* ]]
    [[ "$(summary)" == *"Next steps"* ]]
    [[ "$output" != *"streams are now available"* ]]
    [[ "$output" != *"Quick setup complete"* ]]
    [[ "$(summary)" != *"rtsp://"* ]]
}

# ---------------------------------------------------------------------------
# The other outcomes
# ---------------------------------------------------------------------------

@test "wizard: a node with no microphone is 'waiting for devices', with what to do, not a failure [LB-21]" {
    orch_doc "$ORCH_DIR/waiting.json" waiting_for_devices true
    export STUB_DOC_start="$ORCH_DIR/waiting.json"
    : >"$ORCH_DIR/cron-file"
    wizard "MONITOR_CRON_FILE='$ORCH_DIR/cron-file'"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(summary)" == *"[OK] Quick setup complete: MediaMTX is running."* ]]
    [[ "$(summary)" == *"No USB microphone is detected yet, so no stream is publishing."* ]]
    [[ "$(summary)" == *"Plug in a USB microphone."* ]]
    [[ "$(summary)" == *"The monitor (cron job $ORCH_DIR/cron-file, every 5 minutes as shipped) starts its stream on its next run."* ]]
    [[ "$output" != *"[ERROR]"* ]]
    [[ "$output" != *"did not finish"* ]]
    [[ "$(summary)" != *"reboot"* ]]
    [[ "$output" != *"completed with warnings"* ]]
}

@test "wizard: one microphone working and one not is reported as degraded, with URLs only for the one that publishes [LB-21]" {
    orch_doc "$ORCH_DIR/degraded.json" degraded true "mic1|true|true|" "mic2|false|false|the stream could not be started (see mic2.log)"
    export STUB_DOC_start="$ORCH_DIR/degraded.json"
    wizard
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(summary)" == *"Quick setup finished, but only 1 of 2 streams are publishing"* ]]
    [[ "$(summary)" == *"[FAIL] mic2: not publishing - the stream could not be started (see mic2.log)"* ]]
    [[ "$(summary)" == *":8554/mic1"* ]]
    [[ "$(summary)" != *"rtsp://"*":8554/mic2"* ]]
    [[ "$(summary)" != *"Quick setup complete"* ]]
}

@test "wizard: the URLs use the configured RTSP port [LB-21]" {
    orch_doc "$ORCH_DIR/ok.json" ok true "mic1|true|true|"
    export STUB_DOC_start="$ORCH_DIR/ok.json" MEDIAMTX_RTSP_PORT=18554
    wizard
    [ "$status" -eq 0 ]
    [[ "$(summary)" == *":18554/mic1"* ]]
    [[ "$(summary)" != *":8554/"* ]]
}

@test "wizard: a start that is refused is reported as such, with its next step [LB-21]" {
    export STUB_RC_stream_manager_start=8
    wizard
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"failed (exit code: 8 - another MediaMTX owns this node"* ]]
    [[ "$(summary)" == *"[ERROR] Quick setup did not finish: the audio streams could not be started"* ]]
    [[ "$(summary)" == *"Stop the other MediaMTX first"* ]]
    [[ "$output" != *"streams are now available"* ]]
}

@test "wizard: success whose state cannot be read is 'not confirmed', judged by the processes found after the start [LB-21]" {
    # exit 0, no status file, no answer to status --json; nothing runs until the
    # start, so a verdict from the state read before it would say "not running"
    export STUB_RC_stream_manager_status_json=1 STUB_PGREP_MEDIAMTX=1 STUB_PGREP_FFMPEG=2 STUB_PGREP_ONLY_AFTER_START=1
    wizard
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$(summary)" == *"Quick setup finished, but the stream state could not be confirmed"* ]]
    [[ "$(summary)" == *"MediaMTX is running and 2 FFmpeg process(es) were found after the start."* ]]
    [[ "$(summary)" == *"rtsp://"*":8554/<stream-name>"* ]]
    [[ "$output" != *"streams are now available"* ]]

    export STUB_PGREP_MEDIAMTX=0 STUB_PGREP_FFMPEG=0
    wizard
    [ "$status" -eq 0 ]
    [[ "$(summary)" == *"the streams are probably not available"* ]]
}

@test "wizard: an already installed MediaMTX (installer exit 7) still continues to the start and its report [LB-21]" {
    export STUB_RC_installer_install=7
    orch_doc "$ORCH_DIR/ok.json" ok true "mic1|true|true|"
    export STUB_DOC_start="$ORCH_DIR/ok.json"
    wizard
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MediaMTX is already installed; continuing with setup"* ]]
    [[ "$(summary)" == *"Your RTSP streams are now available"* ]]
}

@test "wizard: the start's report comes before the diagnostics and the summary after them [LB-21]" {
    orch_doc "$ORCH_DIR/ok.json" ok true "mic1|true|true|"
    export STUB_DOC_start="$ORCH_DIR/ok.json"
    wizard
    [ "$status" -eq 0 ]
    local before_diag="${output%%Step 4/4*}"
    [[ "$before_diag" == *"[OK] All 1 stream(s) are publishing"* ]]
    [[ "$before_diag" != *"Quick setup complete"* ]]
    [[ "$(summary)" == *"Quick setup complete"* ]]
    # the start, then the diagnostics, in this order
    grep -qx 'stream_manager start' "$ORCH_CALLS"
    [ "$(grep -n -x 'stream_manager start' "$ORCH_CALLS" | cut -d: -f1)" -lt "$(grep -n -x 'diagnostics quick' "$ORCH_CALLS" | cut -d: -f1)" ]
}

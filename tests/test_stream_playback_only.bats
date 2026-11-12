#!/usr/bin/env bats
# A USB speaker or DAC (a card with no capture PCM) is not a stream
# (register: X-34; decisions D4, D5). It used to make start_ffmpeg_stream fail, so
# the start summary counted it as a failed stream (a node with one microphone and
# one speaker could never satisfy LYREBIRD_START_POLICY=strict, and `start` logged
# an ERROR for it every time), and the monitor tried to restart it every cycle
# and charged the cron restart budget for it. It is now skipped: one INFO line
# with the reason, listed as skipped in `status` and status.json, and left out of
# the policy and the monitor's counts.
#
# See tests/manager_stage.bash for what is real in these tests (the manager, its
# wrappers, locks, PID files, real child processes) and what stands in for
# hardware, MediaMTX and FFmpeg. device_add_playback plugs in a card that has a
# control node and a playback PCM and no capture PCM.

load scratch_tmpdir
load manager_stage

setup() {
    scratch_setup
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
    stage_setup
    STATUS="$LYREBIRD_STATE_DIR/status.json"
}

teardown() {
    stage_teardown
    scratch_teardown
}

# jq -e on $output: the filter must be true
json_true() {
    jq -e "$1" <<<"$output" >/dev/null
}

@test "one microphone and one speaker satisfy strict policy: the speaker is skipped, not counted as a failed stream [X-34]" {
    device_add mic1 31
    device_add_playback speaker1 32
    LYREBIRD_START_POLICY=strict stage 'COMMAND=start; install_lifecycle_traps; start_mediamtx'
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK] rtsp://stage.invalid:8554/mic1"* ]]
    [[ "$output" == *"[SKIP] speaker1 (card 32): no capture PCM (playback-only card)"* ]]
    [[ "$output" != *"[FAIL]"* ]]
    [[ "$output" == *"All 1 streams are publishing"* ]]
    # no wrapper, no PID file, no start attempt for the speaker
    [ ! -e "$ST/ff/speaker1.sh" ]
    [ ! -e "$ST/ff/speaker1.pid" ]
    pid_running "$(stream_pid mic1)"
    # and nothing about it is an error in the log
    ! grep -F 'speaker1' "$ST/sm.log" | grep -qE '\[(ERROR|FAIL)'
    ! grep -qF 'Failed to start stream for speaker1' "$ST/sm.log"
}

@test "the speaker is logged once per start, at INFO, with the reason [X-34]" {
    device_add mic1 31
    device_add_playback speaker1 32
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    [ "$(grep -cF 'Not streaming speaker1 (card 32): no capture PCM (playback-only card)' "$ST/sm.log")" -eq 1 ]
    grep -F 'Not streaming speaker1' "$ST/sm.log" | grep -q '\[INFO\]'
}

@test "status.json lists the speaker as skipped with its reason; overall and the policy count only the microphone [X-34, D4]" {
    device_add mic1 31
    device_add_playback speaker1 32
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    jq -e '.overall == "ok"' "$STATUS"
    jq -e '.streams | length == 2' "$STATUS"
    jq -e '.streams[] | select(.path == "mic1") | .path_ready == true and .skipped == null and .last_error == null' "$STATUS"
    jq -e '.streams[] | select(.path == "speaker1") | .device == "speaker1" and .card == "32" and .configured == false and .process_alive == false and .path_ready == false and .skipped == true and .last_error == "no capture PCM (playback-only card)"' "$STATUS"

    # status --json computes the same document live
    stage 'status_print_json'
    [ "$status" -eq 0 ]
    json_true '.overall == "ok" and (.streams[] | select(.path == "speaker1") | .skipped == true and .configured == false)'
}

@test "status shows the speaker as skipped with the reason and does not call it a failed stream [X-34]" {
    device_add mic1 31
    device_add_playback speaker1 32
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    stage 'show_status'
    [ "$status" -eq 0 ]
    [[ "$output" == *"speaker1 (card 32)"* ]]
    [[ "$output" == *"Skipped (no capture PCM (playback-only card))"* ]]
    [[ "$output" == *"speaker1: skipped (no capture PCM (playback-only card))"* ]]
    [[ "$output" == *"Overall: ok"* ]]
    # no stream URL and no 'Not running' for it
    [[ "$output" != *"/speaker1"* ]]
}

@test "a node with only a speaker is a node waiting for devices: exit 0, or 6 when empty start is disabled [X-34, D5]" {
    device_add_playback speaker1 32
    stage 'COMMAND=start; install_lifecycle_traps; start_mediamtx'
    [ "$status" -eq 0 ]
    [[ "$output" == *"waiting for devices"* ]]
    jq -e '.overall == "waiting_for_devices" and (.streams | length == 1) and .streams[0].skipped == true' "$STATUS"
    pid_running "$(mediamtx_pid)"
    stage 'COMMAND=stop; stop_mediamtx'
    [ "$status" -eq 0 ]

    LYREBIRD_ALLOW_EMPTY_START=false stage 'COMMAND=start; install_lifecycle_traps; start_mediamtx'
    [ "$status" -eq 6 ]
    [[ "$output" == *"No USB audio device that can capture"* ]]
}

@test "a speaker next to a failing microphone does not hide the failure: strict still exits 9 [X-34, D4]" {
    device_add mic1 31
    bad_card 31
    device_add_playback speaker1 32
    LYREBIRD_START_POLICY=strict stage 'COMMAND=start; install_lifecycle_traps; start_mediamtx'
    [ "$status" -eq 9 ]
    [[ "$output" == *"Start failed: 0 of 1 streams are publishing (policy strict)"* ]]
}

@test "the monitor does not restart the speaker, charges no restart budget for it and reports a healthy node [X-34, X-04]" {
    device_add mic1 31
    device_add_playback speaker1 32
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    export CRON=1 CRON_RESTART_MAX_PER_HOUR=3
    local i
    for i in 1 2 3 4 5; do
        stage 'monitor_streams'
        [ "$status" -eq 0 ] || {
            echo "$output"
            false
        }
    done
    # The old monitor found no PID file for the speaker, charged the budget, tried to start it
    # and reported the stream as failed (exit 10) in every cycle
    [ ! -e "$CRON_RESTART_STATE_DIR/speaker1.restarts" ]
    [ ! -e "$ST/ff/speaker1.pid" ]
    [[ "$output" == *"all 1 streams healthy"* ]]
    [[ "$output" != *"Failed to restart stream speaker1"* ]]
}

@test "the monitor on a node with only a speaker is waiting for devices (exit 0), not degraded [X-34, D5]" {
    device_add_playback speaker1 32
    mediamtx_stub_up
    export CRON=1
    stage 'monitor_streams'
    [ "$status" -eq 0 ]
    [[ "$output" == *"No USB audio device that can capture (1 playback-only card(s) skipped); waiting for devices"* ]]
    [ ! -e "$CRON_RESTART_STATE_DIR/speaker1.restarts" ]
}

@test "when the speaker is replaced by a microphone the monitor starts its stream [X-34, D5]" {
    device_add_playback usbcard 32
    mediamtx_stub_up
    stage 'monitor_streams'
    [ "$status" -eq 0 ]
    [ ! -e "$ST/ff/usbcard.pid" ]
    # the same card, now with a capture PCM
    device_remove 32
    device_add usbcard 32
    stage 'monitor_streams'
    [ "$status" -eq 0 ]
    pid_running "$(stream_pid usbcard)"
}

@test "multiplex mode mixes the microphones only and lists the speaker as skipped [X-34]" {
    device_add mic1 31
    device_add mic2 33
    device_add_playback speaker1 32
    stage 'STREAM_MODE=multiplex; MULTIPLEX_STREAM_NAME=mix; resolve_multiplex_stream_name
        devices=("mic1:31" "speaker1:32" "mic2:33")
        stream_outcome_expect "${devices[@]}"
        for path in "${OUTCOME_PATHS[@]}"; do
            echo "path=$path device=${OUTCOME_DEVICE[$path]} card=${OUTCOME_CARD[$path]} skipped=${OUTCOME_SKIPPED[$path]}"
        done'
    [ "$status" -eq 0 ]
    [[ "$output" == *"path=mix device=mic1,mic2 card=31,33 skipped=false"* ]]
    [[ "$output" == *"path=speaker1 device=speaker1 card=32 skipped=true"* ]]
}

@test "multiplex start passes only the microphones to the multiplex stream and counts one stream [X-34]" {
    device_add mic1 31
    device_add mic2 33
    device_add_playback speaker1 32
    LYREBIRD_START_POLICY=strict stage 'STREAM_MODE=multiplex; MULTIPLEX_STREAM_NAME=mix; resolve_multiplex_stream_name
        COMMAND=start; install_lifecycle_traps; start_mediamtx'
    [ "$status" -eq 0 ] || {
        echo "$output"
        false
    }
    [[ "$output" == *"Starting multiplexed stream (2 devices): mix..."* ]]
    [[ "$output" == *"[OK] rtsp://stage.invalid:8554/mix (multiplexed from 2 devices)"* ]]
    [[ "$output" == *"[SKIP] speaker1 (card 32)"* ]]
    # the wrapper was given two inputs, and the recorded set is the microphones
    grep -qE '^NUM_DEVICES=2$' "$ST/ff/mix.sh"
    [ "$(cat "$ST/ff/mix.devices")" = "mic1:31,mic2:33," ]
}

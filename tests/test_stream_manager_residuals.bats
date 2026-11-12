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

# ---------------------------------------------------------------------------
# 8d: an individual stream's channel count is checked against its codec
# ---------------------------------------------------------------------------

# The real ffmpeg must refuse 4 channels as opus (it does, FFmpeg 6.1.1) and accept them as aac
require_ffmpeg_that_refuses_4ch_opus() {
    command -v ffmpeg >/dev/null || skip "ffmpeg not installed"
    command -v timeout >/dev/null || skip "timeout not installed"
    local base=(timeout 20 ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -t 0.1 -i "anullsrc=channel_layout=4.0:sample_rate=48000" -af "aresample=async=1:first_pts=0")
    "${base[@]}" -c:a aac -b:a 128k -f null - >/dev/null 2>&1 || skip "this ffmpeg has no aac encoder or no lavfi anullsrc"
    if "${base[@]}" -c:a libopus -b:a 128k -application audio -f null - >/dev/null 2>&1; then
        skip "this ffmpeg accepts 4 channels as opus: nothing for the check to refuse"
    fi
}

@test "check_individual_encoding asks FFmpeg: 4 channels as opus is refused with an error naming channels and codec, the counts opus can encode and aac are not [8d]" {
    require_ffmpeg_that_refuses_4ch_opus
    stage '
        for combo in "1 opus" "2 opus" "3 opus" "4 opus" "8 opus" "9 opus" "2 aac" "4 aac" "6 aac" "2 mp3"; do
            read -r ch codec <<<"$combo"
            rc=0; check_individual_encoding mic1 "$ch" 48000 "$codec" 128k || rc=$?
            echo "$ch $codec rc=$rc"
        done'
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 opus rc=0"* ]]
    [[ "$output" == *"2 opus rc=0"* ]]
    [[ "$output" == *"4 opus rc=1"* ]]
    [[ "$output" == *"9 opus rc=1"* ]]
    [[ "$output" == *"2 aac rc=0"* ]]
    [[ "$output" == *"4 aac rc=0"* ]]
    [[ "$output" == *"2 mp3 rc=0"* ]]
    grep -qF 'Stream mic1 not started: FFmpeg cannot encode 4 channels as opus (128k): ' "$ST/sm.log"
    grep -qF 'Set the channel count of this device (DEVICE_<NAME>_CHANNELS) to one that opus can encode, or its codec (DEVICE_<NAME>_CODEC) to aac' "$ST/sm.log"
}

@test "a stream with 4 channels and opus is not started: the error names the channels and the codec and nothing is written or launched [8d]" {
    require_ffmpeg_that_refuses_4ch_opus
    device_add mic1 31
    printf '%s\n' 'DEVICE_MIC1_CHANNELS=4' >"$ST/cfg/audio-devices.conf"
    stage 'rc=0; start_ffmpeg_stream mic1 31 mic1 || rc=$?; echo "rc=$rc"'
    [[ "$output" == *"rc=1"* ]]
    grep -qF 'Stream mic1 not started: FFmpeg cannot encode 4 channels as opus (128k): ' "$ST/sm.log"
    # before the wrapper is written: no script, no PID file, no process, no log
    [ ! -e "$ST/ff/mic1.sh" ]
    [ ! -e "$ST/ff/mic1.pid" ]
    [ -z "$(stage_processes)" ]
    [ ! -e "$ST/ff/mic1.log" ]
}

@test "the same device with 4 channels as aac starts, and so does 2 channels as opus [8d]" {
    require_ffmpeg_that_refuses_4ch_opus
    device_add mic1 31
    printf '%s\n' 'DEVICE_MIC1_CHANNELS=4' 'DEVICE_MIC1_CODEC=aac' >"$ST/cfg/audio-devices.conf"
    stage 'rc=0; start_ffmpeg_stream mic1 31 mic1 || rc=$?; echo "rc=$rc"'
    [[ "$output" == *"rc=0"* ]]
    pid_running "$(stream_pid mic1)"
    ! grep -q 'cannot encode' "$ST/sm.log"
    stage 'COMMAND=stop; stop_mediamtx'
    printf '%s\n' 'DEVICE_MIC1_CHANNELS=2' >"$ST/cfg/audio-devices.conf"
    stage 'rc=0; start_ffmpeg_stream mic1 31 mic1 || rc=$?; echo "rc=$rc"'
    [[ "$output" == *"rc=0"* ]]
    pid_running "$(stream_pid mic1)"
}

@test "a check that cannot be made does not stop the stream: no lavfi, a timeout, no ffmpeg [8d]" {
    # Stood in for: ffmpeg, which says it has no lavfi (then `timeout` reports 124; then neither exists)
    printf '%s\n' '#!/bin/bash' 'echo "Unknown input format: lavfi" >&2' 'exit 1' >"$ST/shim/ffmpeg"
    chmod +x "$ST/shim/ffmpeg"
    stage 'rc=0; check_individual_encoding mic1 4 48000 opus 128k || rc=$?; echo "no lavfi rc=$rc"'
    [[ "$output" == *"no lavfi rc=0"* ]]
    grep -qF 'Could not check whether FFmpeg can encode 4 channels as opus for mic1' "$ST/sm.log"

    printf '%s\n' '#!/bin/bash' 'exit 124' >"$ST/shim/timeout"
    chmod +x "$ST/shim/timeout"
    : >"$ST/sm.log"
    stage 'rc=0; check_individual_encoding mic1 4 48000 opus 128k || rc=$?; echo "timeout rc=$rc"'
    [[ "$output" == *"timeout rc=0"* ]]
    grep -qF 'for mic1 (rc=124); starting it anyway' "$ST/sm.log"

    # no ffmpeg at all (command_exists says so): the check is skipped; the start fails on its own for
    # a missing ffmpeg, and says so
    stage 'COMMAND_CACHE[ffmpeg]=0; rc=0; check_individual_encoding mic1 4 48000 opus 128k || rc=$?; echo "no ffmpeg rc=$rc"'
    [[ "$output" == *"no ffmpeg rc=0"* ]]
}

@test "a question that cannot be put to FFmpeg (a channel count or rate that is not a number, a codec with no encoder arguments) is a check that cannot be made, not a refusal [8d]" {
    # The settings are checked when they are resolved, so this does not happen; the wrapper
    # generator has its own defences for such values (tests/test_stream_wrappers.bats feeds it
    # hostile ones with the validation layer stood in for)
    stage 'rc=0; check_individual_encoding mic1 four 48000 opus 128k || rc=$?; echo "channels rc=$rc"
        rc=0; check_individual_encoding mic1 2 loud opus 128k || rc=$?; echo "rate rc=$rc"
        rc=0; check_individual_encoding mic1 2 48000 flac 128k || rc=$?; echo "codec rc=$rc"'
    [[ "$output" == *"channels rc=0"* ]]
    [[ "$output" == *"rate rc=0"* ]]
    [[ "$output" == *"codec rc=0"* ]]
    ! grep -q 'cannot encode' "$ST/sm.log"
}

@test "the encoder arguments the check uses are the words of the wrapper's own codec arms, for every codec [8d]" {
    # The individual wrapper keeps its own `case "${CODEC}"`; the check runs multiplex_encoder_args.
    # Read the wrapper's arms from the script and compare, so that the two cannot drift apart.
    local codec opts_line expected actual
    for codec in opus aac mp3; do
        opts_line="$(awk -v c="$codec" '
            /case "\$\{CODEC\}" in/ { incase = 1; next }
            incase && /^[[:space:]]*esac/ { incase = 0 }
            incase && $0 ~ "^[[:space:]]*" c "\\)" { arm = 1; next }
            incase && /^[[:space:]]*;;/ { arm = 0 }
            arm && /codec_opts=\(/ { print; exit }
        ' "$MANAGER")"
        [ -n "$opts_line" ] || {
            echo "no codec_opts arm for $codec"
            false
        }
        local codec_opts=() BITRATE=96k
        eval "$opts_line"
        expected="${codec_opts[*]}"
        run bash -c 'source "$1" >/dev/null 2>&1; multiplex_encoder_args "$2" 96k; echo "${MULTIPLEX_ENCODER_ARGS[*]}"' _ "$MANAGER" "$codec"
        actual="$output"
        [ "$actual" = "$expected" ] || {
            echo "$codec: wrapper '$expected', check '$actual'"
            false
        }
    done
}

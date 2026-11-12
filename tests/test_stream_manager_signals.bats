#!/usr/bin/env bats
# Audio level signals in lyrebird-stream-manager.sh (register: LB-14, X-05;
# decision D6): probe_stream_level, track_silence and monitor_signals, and their
# wiring into the monitor command.
#
# The real script is sourced in a fresh bash for every call and the real
# functions run. What stands in:
#   - ffmpeg, a PATH shim that records its arguments and prints a chosen report
#     (the real FFmpeg and a real MediaMTX are in the live test at the end of
#     tests/test_mediamtx_live.bats, driven by tests/signals_e2e.bash);
#   - the clock (_now_monotonic) and the API's ready verdict (probe_stream_ready)
#     where a test needs to move time or to decide readiness.
# The reports the shim prints are the formats the real FFmpeg 6.1.1 printed in
# that live test (volumedetect blocks, "Connection refused", "404 Not Found").

load scratch_tmpdir

setup() {
    scratch_setup
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
    SG="$TEST_SCRATCH/sg"
    mkdir -p "$SG"/{bin,ff,state}
    BG_PIDS=()
    export PROJECT_ROOT SG
    export MEDIAMTX_CONFIG_DIR="$SG/cfg" MEDIAMTX_FFMPEG_DIR="$SG/ff" MEDIAMTX_PID_FILE="$SG/mtx.pid"
    export MEDIAMTX_LOCK_FILE="$SG/run.lock" MEDIAMTX_LOG_FILE="$SG/sm.log" STREAM_MANAGER_LOG_FILE="$SG/sm.log"
    export MEDIAMTX_RESTART_MARKER="$SG/restart.marker" MEDIAMTX_CLEANUP_MARKER="$SG/cleanup.marker"
    export SILENCE_STATE_DIR="$SG/state" CRON_RESTART_STATE_DIR="$SG/cron" DEEP_HEALTH_STATE_DIR="$SG/deep"
    export HEARTBEAT_FILE="$SG/heartbeat" MEDIAMTX_HOST=signals.invalid
    export AUDIO_LEVEL_SAMPLE_DURATION=1 AUDIO_LEVEL_PROBE_GRACE=2 AUDIO_LEVEL_CHECK_INTERVAL=0
    export AUDIO_SILENCE_WARN_DURATION=60 AUDIO_SILENCE_THRESHOLD_DB=-60 AUDIO_LEVEL_CHECK_ENABLED=true

    # ffmpeg: records its arguments, prints $SG/ffmpeg.out on stderr, exits $SG/ffmpeg.rc
    cat >"$SG/bin/ffmpeg" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >>"$SG/ffmpeg.calls"
[[ -f "$SG/ffmpeg.out" ]] && cat "$SG/ffmpeg.out" >&2
exit "$(cat "$SG/ffmpeg.rc" 2>/dev/null || echo 0)"
SHIM
    chmod +x "$SG/bin/ffmpeg"
    export PATH="$SG/bin:$PATH"
}

teardown() {
    local pid
    for pid in "${BG_PIDS[@]:-}"; do
        [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    done
    scratch_teardown
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# A successful measurement as the real ffmpeg prints it: vd MAX MEAN [SAMPLES]
vd() {
    printf '%s\n' \
        "Input #0, rtsp, from 'rtsp://127.0.0.1:8554/x':" \
        "[Parsed_volumedetect_0 @ 0x5586db776040] n_samples: ${3:-193920}" \
        "[Parsed_volumedetect_0 @ 0x5586db776040] mean_volume: $2 dB" \
        "[Parsed_volumedetect_0 @ 0x5586db776040] max_volume: $1 dB" \
        "[Parsed_volumedetect_0 @ 0x5586db776040] histogram_18db: 53928" >"$SG/ffmpeg.out"
    echo 0 >"$SG/ffmpeg.rc"
}

# probe PATH [SECONDS]: probe_stream_level in a fresh process
probe() {
    run bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1; probe_stream_level "$@"' _ "$@"
}

# signals NOW: monitor_signals once, in a fresh process, with the monotonic clock at NOW
# and probe_stream_ready answering $SG/ready.rc (0 = ready, the default)
signals() {
    echo "$1" >"$SG/now"
    run bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        _now_monotonic() { cat "$SG/now"; }
        probe_stream_ready() { return "$(cat "$SG/ready.rc" 2>/dev/null || echo 0)"; }
        monitor_signals
    '
}

# wrapper NAME: a live process and its PID file, which make NAME one of the manager's streams
wrapper() {
    sleep 600 &
    BG_PIDS+=("$!")
    echo "$!" >"$SG/ff/$1.pid"
}

count_log() { grep -c -- "$1" "$SG/sm.log" 2>/dev/null || true; }
probe_calls() {
    [[ -f "$SG/ffmpeg.calls" ]] || {
        echo 0
        return 0
    }
    grep -c . "$SG/ffmpeg.calls" || true
}

# ---------------------------------------------------------------------------
# probe_stream_level: classification
# ---------------------------------------------------------------------------

@test "probe_stream_level: a tone read from the stream is ok and carries max and mean [LB-14]" {
    vd -18.0 -21.2
    probe mic1
    [ "$status" -eq 0 ]
    [ "$output" = "ok -18.0 -21.2" ]
}

@test "probe_stream_level: digital silence (-91.0 dB) is silent [LB-14]" {
    vd -91.0 -91.0
    probe mic1
    [ "$status" -eq 0 ]
    [ "$output" = "silent -91.0 -91.0" ]
}

@test "probe_stream_level: max_volume at the threshold is silent, one tenth above it is ok [LB-14]" {
    vd -60.0 -70.2
    probe mic1
    [ "$output" = "silent -60.0 -70.2" ]
    vd -59.9 -70.2
    probe mic1
    [ "$output" = "ok -59.9 -70.2" ]
    # the threshold is the setting's, not a constant
    vd -59.9 -70.2
    run env AUDIO_SILENCE_THRESHOLD_DB=-50 bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1; probe_stream_level mic1'
    [ "$output" = "silent -59.9 -70.2" ]
}

@test "probe_stream_level: -inf is silent and a decimal comma is read [LB-14]" {
    vd -inf -inf
    probe mic1
    [ "$output" = "silent -inf -inf" ]
    vd "-12,5" "-30,1"
    probe mic1
    [ "$output" = "ok -12,5 -30,1" ]
}

@test "probe_stream_level: the last volumedetect block counts, an earlier n_samples: 0 block carries nothing [LB-14]" {
    printf '%s\n' \
        "Input #0, rtsp, from 'rtsp://127.0.0.1:8554/x':" \
        "[Parsed_volumedetect_0 @ 0x564d66a38b00] n_samples: 0" \
        "[Parsed_volumedetect_0 @ 0x564d66a62040] n_samples: 193920" \
        "[Parsed_volumedetect_0 @ 0x564d66a62040] mean_volume: -71.1 dB" \
        "[Parsed_volumedetect_0 @ 0x564d66a62040] max_volume: -68.0 dB" >"$SG/ffmpeg.out"
    echo 0 >"$SG/ffmpeg.rc"
    probe mic1
    [ "$output" = "silent -68.0 -71.1" ]
}

@test "probe_stream_level: ffmpeg exiting 0 with no report at all is probe_error, not silence and not an abort [LB-14, ported from check_audio_level]" {
    : >"$SG/ffmpeg.out"
    echo 0 >"$SG/ffmpeg.rc"
    run bash -c 'set -euo pipefail; source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1; probe_stream_level mic1; echo "rc=$?"'
    [ "$status" -eq 0 ]
    [[ "$output" == "probe_error - - "* ]]
    [[ "$output" == *"rc=0" ]]
}

@test "probe_stream_level: garbage from a failing ffmpeg is probe_error, and a failing ffmpeg's numbers are never believed as silence [LB-14]" {
    printf '%s\n' "Segmentation garbage ::: not an ffmpeg report" >"$SG/ffmpeg.out"
    echo 3 >"$SG/ffmpeg.rc"
    probe mic1
    [[ "$output" == "probe_error - - ffmpeg exit 3, last line: Segmentation garbage"* ]]
    # a report that looks like silence but came with a failure exit status
    vd -91.0 -91.0
    echo 1 >"$SG/ffmpeg.rc"
    probe mic1
    [[ "$output" == "probe_error - - "* ]]
    [[ "$output" != silent* ]]
}

@test "probe_stream_level: not published, nothing listening and a stuck connect are unreachable; credentials wanted is probe_error [LB-14]" {
    printf '%s\n' \
        "[rtsp @ 0x5576c94ba000] method DESCRIBE failed: 404 Not Found" \
        "[in#0 @ 0x5576c94b9f00] Error opening input: Server returned 404 Not Found" \
        "Error opening input files: Server returned 404 Not Found" >"$SG/ffmpeg.out"
    echo 8 >"$SG/ffmpeg.rc"
    probe mic1
    [[ "$output" == "unreachable - - "* ]]

    printf '%s\n' \
        "[tcp @ 0x55ee0c0a1540] Connection to tcp://127.0.0.1:8554?timeout=0 failed: Connection refused" \
        "Error opening input files: Connection refused" >"$SG/ffmpeg.out"
    echo 145 >"$SG/ffmpeg.rc"
    probe mic1
    [[ "$output" == "unreachable - - "* ]]

    : >"$SG/ffmpeg.out"
    echo 124 >"$SG/ffmpeg.rc"
    probe mic1
    [[ "$output" == "unreachable - - "* ]]

    printf '%s\n' "[rtsp @ 0x1] method DESCRIBE failed: 401 Unauthorized" >"$SG/ffmpeg.out"
    echo 1 >"$SG/ffmpeg.rc"
    probe mic1
    [[ "$output" == "probe_error - - the server wants credentials"* ]]
}

@test "probe_stream_level: a stream that opened but delivered no samples is no_audio_data [LB-14]" {
    printf '%s\n' \
        "Input #0, rtsp, from 'rtsp://127.0.0.1:8554/x':" \
        "  Stream #0:0: Audio: opus, 48000 Hz, stereo, fltp" >"$SG/ffmpeg.out"
    echo 0 >"$SG/ffmpeg.rc"
    probe mic1
    [[ "$output" == "no_audio_data - - "* ]]
    # n_samples: 0 only
    printf '%s\n' \
        "Input #0, rtsp, from 'rtsp://127.0.0.1:8554/x':" \
        "[Parsed_volumedetect_0 @ 0x1] n_samples: 0" >"$SG/ffmpeg.out"
    probe mic1
    [[ "$output" == "no_audio_data - - "* ]]
}

@test "probe_stream_level: without ffmpeg or without timeout it is probe_error and nothing is run [LB-14]" {
    vd -91.0 -91.0
    local tool
    for tool in ffmpeg timeout; do
        # command_exists answers from COMMAND_CACHE: mark the tool absent
        run bash -c '
            source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
            COMMAND_CACHE["$1"]=0
            probe_stream_level mic1' _ "$tool"
        [ "$status" -eq 0 ]
        [ "$output" = "probe_error - - ffmpeg and timeout are both required" ]
        [ ! -e "$SG/ffmpeg.calls" ]
    done
    # and the cache is no fiction: with neither marked, the same call measures
    probe mic1
    [ "$output" = "silent -91.0 -91.0" ]
}

@test "probe_stream_level: an unusable path is probe_error and nothing is run [LB-14]" {
    vd -91.0 -91.0
    probe 'mic1; rm -rf x'
    [[ "$output" == "probe_error - - not a usable stream path"* ]]
    probe ""
    [[ "$output" == "probe_error - - not a usable stream path"* ]]
    probe 'a/b'
    [[ "$output" == "probe_error - - not a usable stream path"* ]]
    [ ! -e "$SG/ffmpeg.calls" ]
}

@test "probe_stream_level: a hanging ffmpeg is killed after the sample plus the grace period, never waited for [LB-14]" {
    printf '#!/bin/bash\nexec sleep 60\n' >"$SG/bin/ffmpeg"
    local t0=$SECONDS
    probe mic1
    local took=$((SECONDS - t0))
    # sample 1 s + grace 2 s (+ the kill escalation): far below the 60 s the shim wanted
    [ "$took" -lt 12 ]
    [[ "$output" == "unreachable - - "* ]]
}

# ---------------------------------------------------------------------------
# probe_stream_level: what it asks FFmpeg to do
# ---------------------------------------------------------------------------

@test "probe_stream_level reads the published stream over RTSP at 127.0.0.1 on MEDIAMTX_RTSP_PORT and opens no ALSA device [LB-14, D6]" {
    vd -18.0 -21.2
    probe mic1
    [ "$output" = "ok -18.0 -21.2" ]
    local call
    call="$(cat "$SG/ffmpeg.calls")"
    [[ "$call" == *"-rtsp_transport tcp"* ]]
    [[ "$call" == *"-i rtsp://127.0.0.1:8554/mic1"* ]]
    [[ "$call" == *"-af volumedetect"* ]]
    [[ "$call" == *"-f null -"* ]]
    [[ "$call" == *"-nostdin"* ]]
    [[ "$call" == *"-t 1 "* ]]
    [[ "$call" != *alsa* && "$call" != *plughw* && "$call" != *hw:* && "$call" != */dev/snd* ]]

    : >"$SG/ffmpeg.calls"
    run env MEDIAMTX_RTSP_PORT=37123 bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1; probe_stream_level mic2 2'
    call="$(cat "$SG/ffmpeg.calls")"
    [[ "$call" == *"-i rtsp://127.0.0.1:37123/mic2"* ]]
    [[ "$call" == *"-t 2 "* ]]
    # a value that is not a port is refused when the manager is loaded (D15: no silent
    # fallback), so no probe is made at all
    : >"$SG/ffmpeg.calls"
    run env MEDIAMTX_RTSP_PORT=abc bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1; probe_stream_level mic2'
    [ "$status" -eq 4 ]
    [ ! -s "$SG/ffmpeg.calls" ]
}

@test "the level-signal functions never refer to an ALSA device, and the old ALSA-opening probe is gone [LB-14, D6]" {
    run bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        for f in _db_to_tenths probe_stream_level _signal_state_read _signal_state_write track_silence monitor_signals; do
            declare -f "$f" >/dev/null || { echo "missing $f"; exit 1; }
            declare -f "$f" | grep -n -i -E "alsa|plughw|hw:|/dev/snd|arecord" && { echo "$f refers to ALSA"; exit 1; }
        done
        # the pattern is real: the wrapper generator does open ALSA
        declare -f start_ffmpeg_stream | grep -q -i "plughw" || { echo "control failed: no ALSA reference found in the wrapper generator"; exit 1; }
        for f in check_audio_level check_all_audio_levels; do
            ! declare -f "$f" >/dev/null || { echo "$f still exists"; exit 1; }
        done
        echo clean'
    [ "$status" -eq 0 ]
    [ "$output" = "clean" ]
}

# ---------------------------------------------------------------------------
# silence episodes (track_silence through monitor_signals)
# ---------------------------------------------------------------------------

@test "monitor_signals: one DEAD MIC per silence episode, raised after AUDIO_SILENCE_WARN_DURATION, cleared by recovery [LB-14, X-05]" {
    export AUDIO_SILENCE_WARN_DURATION=60
    wrapper mic1
    vd -91.0 -91.0
    signals 1000
    [ "$status" -eq 0 ]
    [ "$(count_log 'Silence detected on mic1')" -eq 1 ]
    [ "$(count_log 'DEAD MIC')" -eq 0 ]

    signals 1059 # 59 s: not yet
    [ "$(count_log 'DEAD MIC')" -eq 0 ]
    signals 1060 # 60 s
    [ "$(count_log 'DEAD MIC: mic1 has been silent for 60s')" -eq 1 ]
    signals 1360
    signals 1660
    [ "$(count_log 'DEAD MIC')" -eq 1 ]
    # the episode continues without a new "Silence detected"
    [ "$(count_log 'Silence detected on mic1')" -eq 1 ]

    vd -18.0 -21.2
    signals 1700
    [ "$(count_log 'Audio recovered on mic1 after 700s of silence')" -eq 1 ]
    signals 2000
    [ "$(count_log 'Audio recovered')" -eq 1 ]

    # a new episode alerts again, once
    vd -91.0 -91.0
    signals 2300
    [ "$(count_log 'Silence detected on mic1')" -eq 2 ]
    signals 2360
    signals 2420
    [ "$(count_log 'DEAD MIC')" -eq 2 ]
}

@test "monitor_signals: unreachable, no_audio_data and probe_error neither start, extend, end nor alert an episode [LB-14, X-05]" {
    export AUDIO_SILENCE_WARN_DURATION=60
    wrapper mic1
    # failures alone: nothing starts
    printf '%s\n' "garbage" >"$SG/ffmpeg.out"
    echo 3 >"$SG/ffmpeg.rc"
    local t
    for t in 1000 1100 1200 1300; do signals "$t"; done
    [ "$(count_log 'Silence detected')" -eq 0 ]
    [ "$(count_log 'DEAD MIC')" -eq 0 ]
    [ "$(count_log 'failed, not counted as silence')" -eq 4 ]

    printf '%s\n' "Input #0, rtsp, from 'x':" >"$SG/ffmpeg.out"
    echo 0 >"$SG/ffmpeg.rc"
    for t in 1400 1500; do signals "$t"; done
    [ "$(count_log 'delivered no audio samples')" -eq 2 ]
    [ "$(count_log 'Silence detected')" -eq 0 ]

    # inside an episode they change nothing: it is not ended, not extended, not alerted
    vd -91.0 -91.0
    signals 2000
    [ "$(count_log 'Silence detected on mic1')" -eq 1 ]
    printf '%s\n' "[tcp @ 0x1] Connection to tcp://127.0.0.1:8554?timeout=0 failed: Connection refused" >"$SG/ffmpeg.out"
    echo 145 >"$SG/ffmpeg.rc"
    signals 2050
    printf '%s\n' "garbage" >"$SG/ffmpeg.out"
    echo 3 >"$SG/ffmpeg.rc"
    signals 2100
    [ "$(count_log 'DEAD MIC')" -eq 0 ]
    [ "$(count_log 'Audio recovered')" -eq 0 ]
    # the episode kept its start: the next silent probe is 70 s after it
    vd -91.0 -91.0
    signals 2070
    [ "$(count_log 'DEAD MIC: mic1 has been silent for 70s')" -eq 1 ]
}

@test "monitor_signals: at most one probe per stream and run, skipped inside AUDIO_LEVEL_CHECK_INTERVAL [LB-14]" {
    export AUDIO_LEVEL_CHECK_INTERVAL=240
    wrapper mic1
    wrapper mic2
    vd -18.0 -21.2
    signals 1000
    [ "$(probe_calls)" -eq 2 ]
    signals 1100
    signals 1239
    [ "$(probe_calls)" -eq 2 ]
    signals 1240
    [ "$(probe_calls)" -eq 4 ]
    # a last-probe time in the future (another clock scale) does not suppress probing for ever
    printf '%s\n' "- 0 99999999" >"$SG/state/mic1.state"
    signals 1300
    [ "$(probe_calls)" -eq 5 ]
}

@test "monitor_signals: only streams MediaMTX reports ready and whose wrapper is alive are probed [LB-14]" {
    wrapper mic1
    # a PID file whose process is gone
    echo 999999 >"$SG/ff/gone.pid"
    # not a stream name
    echo $$ >"$SG/ff/not a stream.pid"
    vd -91.0 -91.0
    echo 1 >"$SG/ready.rc"
    signals 1000
    [ "$(probe_calls)" -eq 0 ]
    echo 2 >"$SG/ready.rc"
    signals 1000
    [ "$(probe_calls)" -eq 0 ]
    echo 0 >"$SG/ready.rc"
    signals 1000
    [ "$(probe_calls)" -eq 1 ]
    [[ "$(cat "$SG/ffmpeg.calls")" == *"/mic1 "* ]]
    [ "$status" -eq 0 ]
}

@test "monitor_signals: AUDIO_LEVEL_CHECK_ENABLED=false runs no probe [LB-14]" {
    wrapper mic1
    vd -91.0 -91.0
    run env AUDIO_LEVEL_CHECK_ENABLED=false bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        probe_stream_ready() { return 0; }
        monitor_signals'
    [ "$status" -eq 0 ]
    [ "$(probe_calls)" -eq 0 ]
}

@test "monitor_signals: with the default settings a ready stream is probed (the setting is no longer a no-op) [LB-14, X-05]" {
    wrapper mic1
    vd -91.0 -91.0
    run env -u AUDIO_LEVEL_CHECK_ENABLED -u AUDIO_LEVEL_CHECK_INTERVAL bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        probe_stream_ready() { return 0; }
        monitor_signals'
    [ "$status" -eq 0 ]
    [ "$(probe_calls)" -eq 1 ]
    [ "$(count_log 'Silence detected on mic1')" -eq 1 ]
}

@test "monitor_signals survives a failing tool and an unwritable state directory under set -euo pipefail and returns 0 [LB-14]" {
    wrapper mic1
    printf '%s\n' "garbage" >"$SG/ffmpeg.out"
    echo 3 >"$SG/ffmpeg.rc"
    printf 'x' >"$SG/blocker"
    run env SILENCE_STATE_DIR="$SG/blocker/sub" bash -c '
        set -euo pipefail
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        probe_stream_ready() { return 0; }
        monitor_signals
        echo "rc=$?"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=0" ]]
    [ "$(count_log 'Cannot record the audio level state of mic1')" -eq 1 ]
}

@test "silence tracking does not fire a false DEAD MIC after a forward wall-clock jump [LB-14, ported from check_audio_level; D3 of the July review]" {
    # The first probe records the silence start; then the WALL clock steps +2 h;
    # the second probe must not conclude the mic has been dead for 2 hours.
    wrapper mic1
    vd -91.0 -91.0
    mkdir -p "$SG/jump"
    cat >"$SG/jump/date" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "+%s" ]]; then
    echo $(( $(/bin/date +%s) + 7200 ))
else
    exec /bin/date "$@"
fi
EOF
    chmod +x "$SG/jump/date"
    export AUDIO_SILENCE_WARN_DURATION=6000
    run bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        probe_stream_ready() { return 0; }
        monitor_signals
        export PATH="$SG/jump:$PATH"
        monitor_signals'
    [ "$status" -eq 0 ]
    [ "$(count_log 'Silence detected on mic1')" -eq 1 ]
    [ "$(count_log 'DEAD MIC')" -eq 0 ]
}

@test "silence state from another clock scale (a start in the future) begins a new episode instead of never alerting [LB-14]" {
    wrapper mic1
    vd -91.0 -91.0
    printf '%s\n' "999999 1 -" >"$SG/state/mic1.state"
    signals 5000
    [ "$(count_log 'Silence detected on mic1')" -eq 1 ]
    [ "$(count_log 'DEAD MIC')" -eq 0 ]
    [[ "$(cat "$SG/state/mic1.state")" == "5000 0 5000" ]]
}

# ---------------------------------------------------------------------------
# the monitor command runs the signals step
# ---------------------------------------------------------------------------

# main monitor with every step recording its call; the hardware-independent
# parts of main (argument parsing, the command switch) are the real ones
monitor_order() {
    run bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        check_root() { :; }
        setup_directories() { :; }
        check_all_resources() { echo "resources" >>"$SG/order"; return "${RESOURCES_RC:-0}"; }
        monitor_signals() { echo "signals" >>"$SG/order"; return "${SIGNALS_RC:-0}"; }
        monitor_streams() { echo "streams" >>"$SG/order"; return "${STREAMS_RC:-0}"; }
        main monitor'
}

@test "the monitor command calls monitor_signals once, after the resource check and before the stream check [LB-14, X-05]" {
    monitor_order
    [ "$status" -eq 0 ]
    [ "$(tr '\n' ' ' <"$SG/order")" = "resources signals streams " ]
}

@test "the monitor command still ends with monitor_streams' status, whatever monitor_signals returns, and skips the signals on a critical resource state [LB-14]" {
    : >"$SG/order"
    STREAMS_RC=10 SIGNALS_RC=1 monitor_order
    [ "$status" -eq 10 ]
    [ "$(tr '\n' ' ' <"$SG/order")" = "resources signals streams " ]
    : >"$SG/order"
    RESOURCES_RC=2 monitor_order
    [ "$status" -eq 2 ]
    [ "$(tr '\n' ' ' <"$SG/order")" = "resources " ]
}

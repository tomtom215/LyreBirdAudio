#!/usr/bin/env bats
# End to end on private ports (register: X-19, LB-13, LB-22; decisions D10, D15):
# the real start_mediamtx writes the configuration, starts a real MediaMTX on
# non-default ports, starts the real generated wrapper, which publishes to the
# configured RTSP port, and the real readiness and stream probes see the stream.
#
# Only the hardware is stood in for: there is no USB device (detect_audio_devices
# names one), no /dev/snd node (the wrapper is run with that path pointed at
# /dev/null) and no ALSA capture (a PATH shim turns the wrapper's ffmpeg call
# into the same call with a lavfi sine wave as its input). The wrapper text, its
# launch, the configuration, MediaMTX and the probes are real.
#
# Runs only when LYREBIRD_TEST_MEDIAMTX_BINS names MediaMTX binaries (the
# first one is used); needs curl, ffmpeg, ffprobe and jq.

load scratch_tmpdir
load mediamtx_live_helper

require_live() {
    [[ -n "${LYREBIRD_TEST_MEDIAMTX_BINS:-}" ]] || skip "set LYREBIRD_TEST_MEDIAMTX_BINS to run"
    local tool
    for tool in curl ffmpeg ffprobe jq python3; do
        command -v "$tool" >/dev/null || skip "$tool not installed"
    done
    command -v lsof >/dev/null || command -v ss >/dev/null || skip "neither lsof nor ss is installed"
}

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SM="$PROJECT_ROOT/lyrebird-stream-manager.sh"
    D="$TEST_SCRATCH/d"
    mkdir -p "$D/cfg" "$D/ff" "$D/bin" "$D/wrapbin"
    KILL_PIDS=()
    mtx_ports_setup
}

teardown() {
    local pid
    for pid in "${KILL_PIDS[@]:-}"; do
        [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    done
    mtx_cleanup
    [[ -n "${TEST_SCRATCH:-}" ]] && scratch_teardown
    return 0
}

# The environment of the manager under test: private paths, the private ports,
# and MediaMTX's other listeners moved off their defaults
manager_env() {
    export MEDIAMTX_CONFIG_DIR="$D/cfg" MEDIAMTX_PID_FILE="$D/mtx.pid" MEDIAMTX_FFMPEG_DIR="$D/ff"
    export MEDIAMTX_LOG_FILE="$D/sm.log" STREAM_MANAGER_LOG_FILE="$D/sm.log" MEDIAMTX_LOCK_FILE="$D/run.lock"
    export MEDIAMTX_RESTART_MARKER="$D/restart.marker" MEDIAMTX_CLEANUP_MARKER="$D/cleanup.marker"
    export MEDIAMTX_HOST=127.0.0.1 MEDIAMTX_BINARY="$1"
    export MEDIAMTX_RTSP_PORT="$P_RTSP" MEDIAMTX_API_PORT="$P_API" MEDIAMTX_METRICS_PORT="$P_METRICS"
    export MTX_RTPADDRESS=":${P_RTP}" MTX_RTCPADDRESS=":${P_RTCP}" MTX_RTMPADDRESS=":${P_SPARE1}" MTX_HLSADDRESS=":${P_SPARE2}"
    export MTX_WEBRTCADDRESS=":${P_SPARE3}" MTX_SRTADDRESS=":${P_SPARE5}" MTX_MOQHTTP2ADDRESS=":${P_SPARE6}"
    export MTX_MOQHTTP3ADDRESS=":${P_SPARE6}" MTX_MOQQUICADDRESS=":${P_SPARE7}"
    export DEEP_HEALTH_STATE_DIR="$D/strikes" CRON_RESTART_STATE_DIR="$D/cron"
    export STREAM_STARTUP_DELAY=0 STREAM_VALIDATION_DELAY=1 STREAM_VALIDATION_ATTEMPTS=8 MEDIAMTX_API_TIMEOUT=20
    export LOCK_ACQUISITION_TIMEOUT=2 STOP_LOCK_TIMEOUT=2
}

# `bash` and `ffmpeg` shims (see the header of this file)
install_hardware_stand_ins() {
    cat >"$D/wrapbin/bash" <<'SHIM'
#!/bin/bash
if [[ "${1:-}" == "$MEDIAMTX_FFMPEG_DIR/"*.sh ]]; then
    script="$1"
    shift
    sed -e 's#/dev/snd/pcmC${card_num}D0c#/dev/null#' \
        -e 's#/dev/snd/pcmC${CARD_NUM}D0c#/dev/null#' \
        -e 's#export PATH="/usr/local/sbin#export PATH="'"$STAND_IN_BIN"':/usr/local/sbin#' \
        "$script" >"${script%.sh}.standin"
    exec /bin/bash "${script%.sh}.standin" "$@"
fi
exec /bin/bash "$@"
SHIM
    cat >"$D/bin/ffmpeg" <<'SHIM'
#!/bin/bash
# Run the real ffmpeg on a sine wave wherever the wrapper asked for an ALSA capture
real="$REAL_FFMPEG"
out=(-re)
args=("$@")
n=${#args[@]}
i=0
in_capture=false
while ((i < n)); do
    if [[ "${args[i]}" == -f && "${args[i + 1]:-}" == alsa ]]; then
        out+=(-f lavfi)
        in_capture=true
        i=$((i + 2))
    elif $in_capture && [[ "${args[i]}" == -ar || "${args[i]}" == -ac || "${args[i]}" == -thread_queue_size ]]; then
        # options of the ALSA capture
        i=$((i + 2))
    elif $in_capture && [[ "${args[i]}" == -i ]]; then
        out+=(-i "sine=frequency=440:sample_rate=48000")
        in_capture=false
        i=$((i + 2))
    else
        out+=("${args[i]}")
        i=$((i + 1))
    fi
done
printf '%s\n' "${out[@]}" >"$FFMPEG_CALL"
printf '%s\n' "$$" >"$FFMPEG_CALL.pid"
exec "$real" "${out[@]}"
SHIM
    # Nothing of the host may be touched: the manager's by-name process lookups
    # (pgrep, pkill, which other jobs on a machine can match) find nothing
    local tool
    for tool in pkill pgrep; do
        printf '#!/bin/bash\nexit 1\n' >"$D/bin/$tool"
        chmod +x "$D/bin/$tool"
    done
    chmod +x "$D/wrapbin/bash" "$D/bin/ffmpeg"
    REAL_FFMPEG="$(command -v ffmpeg)"
    export REAL_FFMPEG STAND_IN_BIN="$D/bin" FFMPEG_CALL="$D/ffmpeg.call"
    export PATH="$D/wrapbin:$D/bin:$PATH"
}

# The seams for the hardware only; everything else is the real function
start_manager() {
    bash -c '
        source "$1" >/dev/null 2>&1
        set +e
        detect_audio_devices() { echo "testmic:1"; }
        wait_for_usb_stabilization() { return 0; }
        check_audio_device() { return 0; }
        # start_all_ffmpeg_streams skips a card without /dev/snd/controlC<N>,
        # which a machine without sound hardware does not have: start the one
        # stream it would start, with the real start_ffmpeg_stream
        start_all_ffmpeg_streams() { start_ffmpeg_stream testmic 1 "$(generate_stream_path testmic 1)"; }
        start_mediamtx' _ "$SM"
}

@test "start_mediamtx, a real MediaMTX and the real wrapper work together on non-default ports: the stream is published, readable and seen by the probes [X-19, LB-13, LB-22]" {
    require_live
    local bin
    bin="${LYREBIRD_TEST_MEDIAMTX_BINS%% *}"
    manager_env "$bin"
    install_hardware_stand_ins

    run start_manager
    [ "$status" -eq 0 ] || {
        echo "$output"
        cat "$D/sm.log"
        false
    }
    KILL_PIDS+=("$(<"$D/mtx.pid")")
    local wrapper
    for wrapper in "$D"/ff/*.pid; do
        KILL_PIDS+=("$(<"$wrapper")")
    done
    [[ -s "$FFMPEG_CALL.pid" ]] && KILL_PIDS+=("$(<"$FFMPEG_CALL.pid")")

    # what start printed names the configured port
    [[ "$output" == *"[OK]"*"rtsp://127.0.0.1:${P_RTSP}/"* ]] || {
        echo "$output"
        false
    }
    # the configuration it wrote is the managed one, on the private ports
    [ "$(head -n 1 "$D/cfg/mediamtx.yml")" = "# Managed by LyreBirdAudio" ]
    grep -qx "rtspAddress: :${P_RTSP}" "$D/cfg/mediamtx.yml"
    grep -qx "apiAddress: 127.0.0.1:${P_API}" "$D/cfg/mediamtx.yml"
    # the wrapper publishes to it, not to 8554
    grep -q "^rtsp://127.0.0.1:${P_RTSP}/" "$FFMPEG_CALL"
    ! grep -q ':8554' "$FFMPEG_CALL"

    # the listeners are the configured ones
    local actual
    actual="$(mtx_listeners "$(<"$D/mtx.pid")")"
    grep -qx "tcp 0.0.0.0:${P_RTSP}" <<<"$actual"
    grep -qx "tcp 127.0.0.1:${P_API}" <<<"$actual"
    grep -qx "tcp 127.0.0.1:${P_METRICS}" <<<"$actual"

    # a client reads the stream on that port, and the probes agree it is there
    local stream
    stream="$(bash -c 'source "$1" >/dev/null 2>&1; generate_stream_path testmic 1' _ "$SM")"
    mtx_can_read "rtsp://127.0.0.1:${P_RTSP}/${stream}" || {
        cat "$TEST_SCRATCH/read.err"
        false
    }
    run bash -c 'source "$1" >/dev/null 2>&1; set +e; probe_stream_ready "$2"; echo "rc=$?"' _ "$SM" "$stream"
    [ "${output##*rc=}" = 0 ]

    # and stop removes it all
    local mtx_pid
    mtx_pid="$(<"$D/mtx.pid")"
    run bash -c 'source "$1" >/dev/null 2>&1; set +e; stop_mediamtx' _ "$SM"
    [ "$status" -eq 0 ]
    [ ! -e "$D/mtx.pid" ]
    ! kill -0 "$mtx_pid" 2>/dev/null
}

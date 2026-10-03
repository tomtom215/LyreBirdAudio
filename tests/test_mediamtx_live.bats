#!/usr/bin/env bats
# The stream manager against real MediaMTX binaries.
#
# Runs only when LYREBIRD_TEST_MEDIAMTX_BINS names one or more MediaMTX
# binaries (space-separated); CI downloads checksum-pinned releases. Needs curl
# and ffmpeg, and the ports the generated config uses (8554, 8000, 8001, 9997,
# 9998) free on this machine. For each binary:
#   - the generated mediamtx.yml is accepted and MediaMTX stays up;
#   - no MoQ listener is started (MediaMTX >= 1.19.0 enables one by default);
#   - probe_stream_ready sees a published stream as ready, and as not ready
#     after the publisher stops.

load scratch_tmpdir

# Skips here, not in setup(): a setup() that skips would also skip the
# failing canary test_suite_can_fail.bats appends to every file.
require_live() {
    [[ -n "${LYREBIRD_TEST_MEDIAMTX_BINS:-}" ]] || skip "set LYREBIRD_TEST_MEDIAMTX_BINS to run"
    command -v curl >/dev/null || skip "curl not installed"
    command -v ffmpeg >/dev/null || skip "ffmpeg not installed"
}

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    MTX_PID="" FF_PID=""
}

teardown() {
    stop_pid "${FF_PID:-}"
    stop_pid "${MTX_PID:-}"
    [[ -n "${TEST_SCRATCH:-}" ]] && scratch_teardown
    return 0
}

stop_pid() {
    [[ -n "$1" ]] || return 0
    kill "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}

# sm <bin> <shell code>: run code with the stream manager sourced and pointed
# at <bin> and a private config directory.
sm() {
    env MEDIAMTX_BINARY="$1" MEDIAMTX_CONFIG_DIR="$TEST_SCRATCH/etc-${1//\//_}" \
        MEDIAMTX_HOST=127.0.0.1 \
        bash -c 'source "$1" >/dev/null 2>&1; log() { :; }; eval "$2"' _ \
        "$PROJECT_ROOT/lyrebird-stream-manager.sh" "$2"
}

# start_mediamtx <bin>: generate the config and start MediaMTX with it.
start_mediamtx() {
    local bin="$1" conf i
    conf=$(sm "$bin" 'generate_mediamtx_config >/dev/null 2>&1 && printf %s "$CONFIG_FILE"') || return 1
    (cd "$TEST_SCRATCH" && exec "$bin" "$conf") >"$TEST_SCRATCH/mediamtx.log" 2>&1 &
    MTX_PID=$!
    for i in $(seq 1 50); do
        curl -sf --max-time 1 http://127.0.0.1:9997/v3/paths/list >/dev/null && return 0
        kill -0 "$MTX_PID" 2>/dev/null || break
        sleep 0.2
    done
    echo "MediaMTX did not come up:"
    cat "$TEST_SCRATCH/mediamtx.log"
    return 1
}

publish() {
    local codec=aac
    ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libopus && codec=libopus
    ffmpeg -nostdin -loglevel error -re -f lavfi -i sine=frequency=440:sample_rate=48000 \
        -c:a "$codec" -f rtsp -rtsp_transport tcp "rtsp://127.0.0.1:8554/$1" &
    FF_PID=$!
}

# wait_probe <bin> <path> <expected rc>: probe_stream_ready until it returns rc.
wait_probe() {
    local i rc
    for i in $(seq 1 40); do
        rc=0
        sm "$1" "probe_stream_ready $2" || rc=$?
        [[ "$rc" -eq "$3" ]] && return 0
        sleep 0.25
    done
    echo "probe_stream_ready $2 returned $rc, expected $3"
    return 1
}

@test "generated config runs on each MediaMTX, without MoQ, and readiness probing works" {
    require_live
    local bin version
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        version=$("$bin" --version 2>/dev/null | head -n 1)
        echo "# MediaMTX $version" >&3
        start_mediamtx "$bin"
        sleep 2
        kill -0 "$MTX_PID" 2>/dev/null || { echo "$version exited"; cat "$TEST_SCRATCH/mediamtx.log"; false; }
        if grep -q '\[MoQ\]' "$TEST_SCRATCH/mediamtx.log"; then
            echo "$version started MoQ:"
            grep '\[MoQ\]' "$TEST_SCRATCH/mediamtx.log"
            false
        fi

        publish livetest
        wait_probe "$bin" livetest 0
        stop_pid "$FF_PID"
        FF_PID=""
        wait_probe "$bin" livetest 1

        stop_pid "$MTX_PID"
        MTX_PID=""
    done
}

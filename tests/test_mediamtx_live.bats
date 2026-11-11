#!/usr/bin/env bats
# The stream manager against real MediaMTX binaries.
#
# Runs only when LYREBIRD_TEST_MEDIAMTX_BINS names one or more MediaMTX
# binaries (space-separated); CI downloads checksum-pinned releases. Needs curl
# and ffmpeg. MediaMTX runs on free ports chosen per test, with its other
# listeners moved away (tests/mediamtx_live_helper.bash, decision D15), so no
# default port needs to be free. For each binary:
#   - the generated mediamtx.yml is accepted and MediaMTX stays up;
#   - no MoQ listener is started (MediaMTX >= 1.19.0 enables one by default);
#   - probe_stream_ready sees a published stream as ready, and as not ready
#     after the publisher stops.
# test_mediamtx_config_live.bats, test_mediamtx_api_live.bats and
# test_mediamtx_e2e_ports.bats check the rendered configuration, the probes and
# the whole start path in more detail.

load scratch_tmpdir
load mediamtx_live_helper

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
    mtx_ports_setup
}

teardown() {
    mtx_cleanup
    [[ -n "${TEST_SCRATCH:-}" ]] && scratch_teardown
    return 0
}

# sm <bin> <shell code>: run code with the stream manager sourced and pointed
# at <bin>, a private config directory and this test's ports.
sm() {
    env MEDIAMTX_BINARY="$1" MEDIAMTX_CONFIG_DIR="$TEST_SCRATCH/etc-${1//\//_}" \
        MEDIAMTX_HOST=127.0.0.1 MEDIAMTX_RTSP_PORT="$P_RTSP" MEDIAMTX_API_PORT="$P_API" MEDIAMTX_METRICS_PORT="$P_METRICS" \
        MEDIAMTX_LOG_FILE="$TEST_SCRATCH/sm.log" MEDIAMTX_FFMPEG_DIR="$TEST_SCRATCH/ff" MEDIAMTX_LOCK_FILE="$TEST_SCRATCH/sm.lock" \
        MEDIAMTX_PID_FILE="$TEST_SCRATCH/sm.pid" \
        bash -c 'source "$1" >/dev/null 2>&1; log() { :; }; eval "$2"' _ \
        "$PROJECT_ROOT/lyrebird-stream-manager.sh" "$2"
}

# start_mediamtx <bin>: generate the config and start MediaMTX with it.
start_mediamtx() {
    local bin="$1" conf
    conf=$(sm "$bin" 'generate_mediamtx_config >/dev/null 2>&1 && printf %s "$CONFIG_FILE"') || return 1
    mtx_start "$bin" "$conf"
}

publish() {
    mtx_publish "rtsp://127.0.0.1:${P_RTSP}/$1"
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
        mtx_ports_setup
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
        mtx_unpublish
        wait_probe "$bin" livetest 1

        mtx_stop
    done
}

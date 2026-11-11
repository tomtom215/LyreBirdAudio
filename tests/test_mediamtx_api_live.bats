#!/usr/bin/env bats
# The stream manager's readiness and health probes against real MediaMTX
# binaries (register: LB-13, LB-06).
#
# Runs only when LYREBIRD_TEST_MEDIAMTX_BINS names one or more MediaMTX
# binaries (space-separated; tests/fetch_mediamtx.sh downloads checksum-pinned
# releases). Needs curl, ffmpeg, ffprobe, jq and python3. Every test runs the
# whole list, on free ports with every other MediaMTX listener moved away
# (tests/mediamtx_live_helper.bash), so no default port is bound.
# test_mediamtx_api_probe.bats covers the same functions with every answer a
# server can give; here the answers are the real ones of each version.

load scratch_tmpdir
load mediamtx_live_helper

require_live() {
    [[ -n "${LYREBIRD_TEST_MEDIAMTX_BINS:-}" ]] || skip "set LYREBIRD_TEST_MEDIAMTX_BINS to run"
    local tool
    for tool in curl ffmpeg ffprobe jq python3; do
        command -v "$tool" >/dev/null || skip "$tool not installed"
    done
}

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SM="$PROJECT_ROOT/lyrebird-stream-manager.sh"
    # shellcheck source=../lyrebird-common.sh
    source "$PROJECT_ROOT/lyrebird-common.sh"
    D="$TEST_SCRATCH/d"
    mkdir -p "$D/strikes" "$D/pids" "$D/cron"
    FAKE_WRAPPER_PID=""
    mtx_ports_setup
}

teardown() {
    [[ -n "${FAKE_WRAPPER_PID:-}" ]] && kill -9 "$FAKE_WRAPPER_PID" 2>/dev/null || true
    mtx_cleanup
    [[ -n "${TEST_SCRATCH:-}" ]] && scratch_teardown
    return 0
}

each_binary_begin() {
    echo "# MediaMTX $(mtx_version "$1")" >&3
    mtx_ports_setup
    export MEDIAMTX_HOST=127.0.0.1 MEDIAMTX_API_PORT="$P_API" MEDIAMTX_RTSP_PORT="$P_RTSP" MEDIAMTX_METRICS_PORT="$P_METRICS"
    export MEDIAMTX_LOG_FILE="$D/sm.log" MEDIAMTX_FFMPEG_DIR="$D/pids" MEDIAMTX_PID_FILE="$D/mtx.pid"
    export DEEP_HEALTH_STATE_DIR="$D/strikes" DEEP_HEALTH_MAX_STRIKES=3 CRON_RESTART_STATE_DIR="$D/cron"
    rm -f "$D"/strikes/* "$D"/pids/* "$D"/cron/* "$D/sm.log"
}

# Run CODE with the real stream manager sourced
sm() {
    bash -c 'source "$1" >/dev/null 2>&1; set +e; eval "$2"' _ "$SM" "$1"
}

# Wait until PATH is (or, with "gone", is no longer) listed by the API
wait_path() {
    local want="$1" path="$2" i body
    for ((i = 0; i < 50; i++)); do
        body="$(curl -s --max-time 2 "http://127.0.0.1:${P_API}/v3/paths/get/${path}" 2>/dev/null)"
        if [[ "$want" == ready ]]; then
            [[ "$body" == *'"ready":true'* ]] && return 0
        else
            [[ "$body" == *'path not found'* ]] && return 0
        fi
        sleep 0.2
    done
    return 1
}

@test "on every MediaMTX version the real API is ready, detected as v3, and a stream goes from not ready to ready to not ready [LB-13]" {
    require_live
    local bin rc
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        each_binary_begin "$bin"
        mtx_render "$bin"
        mtx_start "$bin" "$TEST_SCRATCH/mediamtx.yml"

        run env MEDIAMTX_API_TIMEOUT=5 bash -c 'source "$1" >/dev/null 2>&1; set +e; wait_for_mediamtx_ready "$2"' _ "$SM" "$MTX_PID"
        [ "$status" -eq 0 ] || {
            echo "$output"
            false
        }
        [ "$(sm detect_mediamtx_api_version 2>/dev/null)" = "http://127.0.0.1:${P_API}/v3" ]

        # nothing published: MediaMTX answers 404 {"error":"path not found"}
        rc=0
        sm 'probe_stream_ready mic1' || rc=$?
        [ "$rc" -eq 1 ]

        mtx_publish "rtsp://127.0.0.1:${P_RTSP}/mic1"
        wait_path ready mic1
        rc=0
        sm 'probe_stream_ready mic1' || rc=$?
        [ "$rc" -eq 0 ]
        rc=0
        sm 'deep_stream_unhealthy mic1' || rc=$?
        [ "$rc" -eq 1 ]
        [ -z "$(ls -A "$D/strikes")" ]

        # the publisher goes away: three checks later the stream is confirmed stuck
        mtx_unpublish
        wait_path gone mic1
        rc=0
        sm 'probe_stream_ready mic1' || rc=$?
        [ "$rc" -eq 1 ]
        for rc in 1 1 0; do
            local got=0
            sm 'deep_stream_unhealthy mic1' || got=$?
            [ "$got" -eq "$rc" ]
        done
        mtx_stop
    done
}

# The configuration of an operator who turned on authentication the way the
# documentation first showed it, without the password-less local user: the
# manager's own calls to the API are refused with a 401
write_authenticated_config() {
    {
        lyrebird_render_mediamtx_config --mediamtx-version "$(mtx_version "$1")" \
            --rtsp-port "$P_RTSP" --api-port "$P_API" --metrics-port "$P_METRICS"
        cat <<'YAML'

authMethod: internal
authInternalUsers:
  - user: admin
    pass: admin_pw
    permissions:
      - action: publish
      - action: read
      - action: api
YAML
    } >"$TEST_SCRATCH/mediamtx.yml"
}

# A stand-in for a wrapper process, with the PID file monitor_streams looks for
start_fake_wrapper() {
    local stream="$1"
    printf '#!/bin/bash\nsleep 300\n:\n' >"$D/pids/${stream}.sh"
    chmod +x "$D/pids/${stream}.sh"
    bash "$D/pids/${stream}.sh" >/dev/null 2>&1 3>&- &
    FAKE_WRAPPER_PID=$!
    echo "$FAKE_WRAPPER_PID" >"$D/pids/${stream}.pid"
}

@test "behind an authenticated API a healthy publishing stream is not struck and not restarted by the monitor, on every version [LB-13]" {
    require_live
    local bin stream i
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        each_binary_begin "$bin"
        write_authenticated_config "$bin"
        mtx_start "$bin" "$TEST_SCRATCH/mediamtx.yml"
        # the premise: the manager's own, credential-less call is refused
        [ "$(mtx_http_status "http://127.0.0.1:${P_API}/v3/paths/list")" = 401 ]

        stream="$(sm 'generate_stream_path mic1 0')"
        [ -n "$stream" ]
        mtx_publish "rtsp://admin:admin_pw@127.0.0.1:${P_RTSP}/${stream}"
        mtx_wait_path_ready_authenticated "$stream"

        # readiness: MediaMTX is up and says so, with a warning
        run env MEDIAMTX_API_TIMEOUT=5 bash -c 'source "$1" >/dev/null 2>&1; set +e; wait_for_mediamtx_ready "$2"' _ "$SM" "$MTX_PID"
        [ "$status" -eq 0 ]
        grep -q 'its API requires credentials' "$D/sm.log"

        # the probe cannot judge the stream: unknown, never "not ready"
        local rc=0
        sm "probe_stream_ready $stream" || rc=$?
        [ "$rc" -eq 2 ]

        # four monitor runs with a live wrapper: nothing is restarted
        echo "$MTX_PID" >"$D/mtx.pid"
        start_fake_wrapper "$stream"
        for i in 1 2 3 4; do
            run env RESTARTS_LOG="$D/restarts.log" bash -c '
                source "$1" >/dev/null 2>&1
                set +e
                detect_audio_devices() { printf "mic1:0\n"; }
                check_alsa_device_available() { return 0; }
                start_ffmpeg_stream() { echo "restart $1 $2 $3" >>"$RESTARTS_LOG"; return 0; }
                start_ffmpeg_multiplex_stream() { return 0; }
                monitor_streams' _ "$SM"
        done
        [ ! -e "$D/restarts.log" ] || {
            cat "$D/restarts.log"
            false
        }
        kill -0 "$FAKE_WRAPPER_PID"
        [ -z "$(ls -A "$D/strikes")" ]

        mtx_unpublish
        kill -9 "$FAKE_WRAPPER_PID" 2>/dev/null || true
        wait "$FAKE_WRAPPER_PID" 2>/dev/null || true
        FAKE_WRAPPER_PID=""
        mtx_stop
    done
}

# Wait until the stream is published, asking the API as the admin user
mtx_wait_path_ready_authenticated() {
    local i
    for ((i = 0; i < 50; i++)); do
        curl -s --max-time 2 -u admin:admin_pw "http://127.0.0.1:${P_API}/v3/paths/get/$1" 2>/dev/null | grep -q '"ready":true' && return 0
        sleep 0.2
    done
    return 1
}

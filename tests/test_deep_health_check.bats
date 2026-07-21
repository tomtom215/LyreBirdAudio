#!/usr/bin/env bats
# Deep health probe (H9) E2E tests -- hardware-free.
#
# Before this feature, monitor_streams only verified that the wrapper's bash
# PID existed. A wrapper stuck in endless backoff, or supervising a hung
# FFmpeg whose path never publishes, reported "healthy" forever -- a field
# node that looks alive while recording nothing. These tests drive the REAL
# monitor_streams against a live fake wrapper process and a stub MediaMTX API
# (PATH-shim curl) and prove monitor distinguishes healthy / degraded / dead.

setup() {
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"
    DH_TMP="$(mktemp -d)"
    mkdir -p "$DH_TMP/bin" "$DH_TMP/pids" "$DH_TMP/strikes" "$DH_TMP/cron"

    # A fake "MediaMTX" process and a fake live wrapper process. It must be a
    # bash process (read_pid_safe's PID-recycle guard rejects other comms) and
    # all inherited FDs must be closed or bats waits on them and the file hangs.
    # (the trailing ":" stops bash exec-optimizing itself away into comm=sleep)
    bash -c 'sleep 300; :' >/dev/null 2>&1 3>&- &
    FAKE_MTX_PID=$!
    echo "$FAKE_MTX_PID" > "$DH_TMP/mediamtx.pid"
}

teardown() {
    kill "$FAKE_MTX_PID" 2>/dev/null || true
    [[ -n "${FAKE_WRAPPER_PID:-}" ]] && kill "$FAKE_WRAPPER_PID" 2>/dev/null || true
    rm -rf "$DH_TMP" 2>/dev/null || true
}

# Stub API: paths/get/<name> answers with $1; everything else is a valid list.
_write_api() {
    local get_body="$1"
    cat > "$DH_TMP/bin/curl" <<CURLEOF
#!/bin/bash
url="\${!#}"
case "\$url" in
    */paths/get/*) printf '%s' '${get_body}' ;;
    *)             printf '%s' '{"itemCount":0,"items":[]}' ;;
esac
exit 0
CURLEOF
    chmod +x "$DH_TMP/bin/curl"
}

# An API that is down: curl always fails.
_write_dead_api() {
    printf '#!/bin/bash\nexit 7\n' > "$DH_TMP/bin/curl"
    chmod +x "$DH_TMP/bin/curl"
}

# Start a live fake wrapper whose cmdline matches pgrep -f "<dir>/<stream>.sh"
# and write its PID file, exactly as start_ffmpeg_stream would.
_start_fake_wrapper() {
    local stream="$1"
    printf '#!/bin/bash\nsleep 300\n:\n' > "$DH_TMP/pids/${stream}.sh"
    chmod +x "$DH_TMP/pids/${stream}.sh"
    bash "$DH_TMP/pids/${stream}.sh" >/dev/null 2>&1 3>&- &
    FAKE_WRAPPER_PID=$!
    echo "$FAKE_WRAPPER_PID" > "$DH_TMP/pids/${stream}.pid"
}

# Run the REAL monitor_streams once with fakes layered over hardware access.
_run_monitor() {
    env PROJECT_ROOT="$PROJECT_ROOT" PATH="$DH_TMP/bin:$PATH" \
        MEDIAMTX_PID_FILE="$DH_TMP/mediamtx.pid" \
        MEDIAMTX_FFMPEG_DIR="$DH_TMP/pids" \
        MEDIAMTX_LOG_FILE="$DH_TMP/manager.log" \
        MEDIAMTX_API_VERSION=v3 \
        DEEP_HEALTH_STATE_DIR="$DH_TMP/strikes" \
        DEEP_HEALTH_MAX_STRIKES=3 \
        CRON_RESTART_STATE_DIR="$DH_TMP/cron" \
        RESTARTS_LOG="$DH_TMP/restarts.log" \
        bash -c '
            set -euo pipefail
            source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
            detect_audio_devices() { printf "mic1:0\n"; }
            check_alsa_device_available() { return 0; }
            start_ffmpeg_stream() { echo "restart $1 $2 $3" >> "$RESTARTS_LOG"; return 0; }
            start_ffmpeg_multiplex_stream() { return 0; }
            monitor_streams
        '
}

_stream_path_for_mic1() {
    env PROJECT_ROOT="$PROJECT_ROOT" bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        set +e
        generate_stream_path "mic1" "0"
    '
}

@test "monitor restarts a live wrapper whose path stays not-ready for 3 checks [H9]" {
    local stream; stream="$(_stream_path_for_mic1)"
    [ -n "$stream" ]
    _start_fake_wrapper "$stream"
    _write_api '{"name":"mic1","ready":false}'

    # Strikes 1 and 2: no restart yet (protects mid-backoff streams from churn).
    run _run_monitor
    [ ! -f "$DH_TMP/restarts.log" ]
    run _run_monitor
    [ ! -f "$DH_TMP/restarts.log" ]

    # Strike 3: the stream is confirmed stuck -> wrapper killed and restarted.
    run _run_monitor
    [ -f "$DH_TMP/restarts.log" ]
    grep -q "restart mic1 0" "$DH_TMP/restarts.log"
    # The stuck wrapper process must actually be gone.
    ! kill -0 "$FAKE_WRAPPER_PID" 2>/dev/null
}

@test "monitor does NOT restart a wrapper whose path is ready [H9]" {
    local stream; stream="$(_stream_path_for_mic1)"
    _start_fake_wrapper "$stream"
    _write_api '{"name":"mic1","ready":true}'

    for _ in 1 2 3 4; do run _run_monitor; done
    [ ! -f "$DH_TMP/restarts.log" ]
    kill -0 "$FAKE_WRAPPER_PID" 2>/dev/null
}

@test "monitor accepts the NEW field shape (available:true) as healthy [H9]" {
    local stream; stream="$(_stream_path_for_mic1)"
    _start_fake_wrapper "$stream"
    _write_api '{"name":"mic1","available":true}'

    for _ in 1 2 3 4; do run _run_monitor; done
    [ ! -f "$DH_TMP/restarts.log" ]
    kill -0 "$FAKE_WRAPPER_PID" 2>/dev/null
}

@test "an unreachable API never strikes a stream (no churn on API blips) [H9]" {
    local stream; stream="$(_stream_path_for_mic1)"
    _start_fake_wrapper "$stream"
    _write_dead_api

    for _ in 1 2 3 4 5; do run _run_monitor; done
    [ ! -f "$DH_TMP/restarts.log" ]
    kill -0 "$FAKE_WRAPPER_PID" 2>/dev/null
}

@test "a ready probe resets the strike counter (flapping does not accumulate) [H9]" {
    local stream; stream="$(_stream_path_for_mic1)"
    _start_fake_wrapper "$stream"

    # Two strikes...
    _write_api '{"name":"mic1","ready":false}'
    run _run_monitor
    run _run_monitor
    # ...then a healthy probe clears them...
    _write_api '{"name":"mic1","ready":true}'
    run _run_monitor
    # ...so two more strikes still do not reach the threshold of 3.
    _write_api '{"name":"mic1","ready":false}'
    run _run_monitor
    run _run_monitor
    [ ! -f "$DH_TMP/restarts.log" ]
    kill -0 "$FAKE_WRAPPER_PID" 2>/dev/null
}

@test "deep health check can be disabled via DEEP_HEALTH_CHECK_ENABLED=false" {
    local stream; stream="$(_stream_path_for_mic1)"
    _start_fake_wrapper "$stream"
    _write_api '{"name":"mic1","ready":false}'

    for _ in 1 2 3 4; do
        run env PROJECT_ROOT="$PROJECT_ROOT" PATH="$DH_TMP/bin:$PATH" \
            MEDIAMTX_PID_FILE="$DH_TMP/mediamtx.pid" \
            MEDIAMTX_FFMPEG_DIR="$DH_TMP/pids" \
            MEDIAMTX_LOG_FILE="$DH_TMP/manager.log" \
            MEDIAMTX_API_VERSION=v3 \
            DEEP_HEALTH_CHECK_ENABLED=false \
            DEEP_HEALTH_STATE_DIR="$DH_TMP/strikes" \
            CRON_RESTART_STATE_DIR="$DH_TMP/cron" \
            RESTARTS_LOG="$DH_TMP/restarts.log" \
            bash -c '
                set -euo pipefail
                source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
                detect_audio_devices() { printf "mic1:0\n"; }
                check_alsa_device_available() { return 0; }
                start_ffmpeg_stream() { echo "restart" >> "$RESTARTS_LOG"; return 0; }
                start_ffmpeg_multiplex_stream() { return 0; }
                monitor_streams
            '
    done
    [ ! -f "$DH_TMP/restarts.log" ]
}

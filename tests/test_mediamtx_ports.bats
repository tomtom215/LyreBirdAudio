#!/usr/bin/env bats
# MediaMTX ports are configuration (register: X-19; decision D15).
#
# MEDIAMTX_RTSP_PORT, MEDIAMTX_API_PORT and MEDIAMTX_METRICS_PORT (defaults
# 8554, 9997, 9998) must be honoured by every part of the stream manager that
# used to hard-code them: the generated configuration, the port-in-use check,
# the readiness and API probes, the URLs of the generated wrappers and the URLs
# the manager prints. Every test runs the real script and the real functions;
# the only stand-ins are the hardware (USB devices, /dev/snd, ffmpeg) and, for
# the probes, a stub HTTP server on a private port. No default port is bound.

load scratch_tmpdir
load mediamtx_live_helper

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SM="$PROJECT_ROOT/lyrebird-stream-manager.sh"
    D="$TEST_SCRATCH/d"
    mkdir -p "$D/cfg" "$D/ff" "$D/bin"
    HELD_PIDS=()
    mtx_ports_setup

    export MEDIAMTX_CONFIG_DIR="$D/cfg"
    export MEDIAMTX_PID_FILE="$D/mtx.pid"
    export MEDIAMTX_FFMPEG_DIR="$D/ff"
    export MEDIAMTX_LOG_FILE="$D/sm.log" STREAM_MANAGER_LOG_FILE="$D/sm.log"
    export MEDIAMTX_LOCK_FILE="$D/run.lock"
    export MEDIAMTX_RESTART_MARKER="$D/restart.marker"
    export MEDIAMTX_CLEANUP_MARKER="$D/cleanup.marker"
    export MEDIAMTX_HOST=localhost
    export MEDIAMTX_RTSP_PORT="$P_RTSP" MEDIAMTX_API_PORT="$P_API" MEDIAMTX_METRICS_PORT="$P_METRICS"
    export LOCK_ACQUISITION_TIMEOUT=2 STOP_LOCK_TIMEOUT=1
    # The stood-in cards ("testmic" on card 1 and 2) are microphones: each has a capture
    # PCM in a fake ALSA tree. A card without one is a speaker, which the manager skips (X-34).
    mkdir -p "$D/asound/card1/pcm0c" "$D/asound/card2/pcm0c"
    export ASOUND_PROC_ROOT="$D/asound"

    # Nothing of the host may be touched: process lookups and kills are PATH
    # shims that find nothing
    local tool
    for tool in pkill pgrep; do
        printf '#!/bin/bash\nexit 1\n' >"$D/bin/$tool"
        chmod +x "$D/bin/$tool"
    done
    export PATH="$D/bin:$PATH"
}

teardown() {
    local pid
    for pid in "${HELD_PIDS[@]:-}"; do
        [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    done
    mtx_cleanup
    scratch_teardown
}

# Run CODE with the real stream manager sourced (CODE sees its functions)
sm() {
    bash -c 'source "$1" >/dev/null 2>&1; set +e; eval "$2"' _ "$SM" "$1"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

@test "the defaults are MediaMTX's own: 8554, 9997, 9998 [X-19]" {
    run env -u MEDIAMTX_RTSP_PORT -u MEDIAMTX_API_PORT -u MEDIAMTX_METRICS_PORT bash -c '
        source "$1" >/dev/null 2>&1
        echo "$MEDIAMTX_RTSP_PORT $MEDIAMTX_API_PORT $MEDIAMTX_METRICS_PORT"' _ "$SM"
    [ "$status" -eq 0 ]
    [ "$output" = "8554 9997 9998" ]
}

@test "an empty port variable means the default [X-19]" {
    run env MEDIAMTX_RTSP_PORT= MEDIAMTX_API_PORT= MEDIAMTX_METRICS_PORT= bash -c '
        source "$1" >/dev/null 2>&1
        echo "$MEDIAMTX_RTSP_PORT $MEDIAMTX_API_PORT $MEDIAMTX_METRICS_PORT"' _ "$SM"
    [ "$status" -eq 0 ]
    [ "$output" = "8554 9997 9998" ]
}

@test "a port outside 1-65535 or not a plain integer is refused with an error naming the variable [D15]" {
    local var bad
    for var in MEDIAMTX_RTSP_PORT MEDIAMTX_API_PORT MEDIAMTX_METRICS_PORT; do
        for bad in abc 0 65536 99999 100000 -1 +80 0x50 80.5 '80 ' ' 80' '8e3'; do
            run env "$var=$bad" bash "$SM" help
            [ "$status" -eq 4 ] || {
                echo "$var='$bad' exited $status"
                false
            }
            [[ "$output" == *"$var must be an integer from 1 to 65535"* ]] || {
                echo "$var='$bad': $output"
                false
            }
        done
    done
}

@test "the bounds 1 and 65535 and leading zeros are accepted, and leading zeros are not read as octal [D15]" {
    run env MEDIAMTX_RTSP_PORT=1 MEDIAMTX_API_PORT=65535 MEDIAMTX_METRICS_PORT=00099 bash -c '
        source "$1" >/dev/null 2>&1
        echo "$MEDIAMTX_RTSP_PORT $MEDIAMTX_API_PORT $MEDIAMTX_METRICS_PORT"' _ "$SM"
    [ "$status" -eq 0 ]
    [ "$output" = "1 65535 99" ]
    run env MEDIAMTX_RTSP_PORT=08554 bash -c 'source "$1" >/dev/null 2>&1; echo "$MEDIAMTX_RTSP_PORT"' _ "$SM"
    [ "$output" = "8554" ]
}

# ---------------------------------------------------------------------------
# URLs and the generated configuration
# ---------------------------------------------------------------------------

@test "publisher and reader URLs are built from the configured host and RTSP port [X-19]" {
    run sm 'rtsp_publish_url mic1; echo; mediamtx_rtsp_base'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "rtsp://localhost:${P_RTSP}/mic1" ]
    [ "${lines[1]}" = "rtsp://localhost:${P_RTSP}" ]
    run env MEDIAMTX_HOST=192.0.2.9 MEDIAMTX_RTSP_PORT=1935 bash -c 'source "$1" >/dev/null 2>&1; rtsp_publish_url a_b' _ "$SM"
    [ "$output" = "rtsp://192.0.2.9:1935/a_b" ]
}

@test "the generated MediaMTX configuration listens on the configured ports [X-19]" {
    run sm 'generate_mediamtx_config >/dev/null 2>&1; cat "$CONFIG_FILE"'
    [ "$status" -eq 0 ]
    grep -qE "^apiAddress: .*:${P_API}\$" <<<"$output"
    grep -qE "^metricsAddress: .*:${P_METRICS}\$" <<<"$output"
    grep -qE "^rtspAddress: .*:${P_RTSP}\$" <<<"$output"
    # and nothing is left on the defaults
    [[ "$output" != *":8554"* && "$output" != *":9997"* && "$output" != *":9998"* ]]
}

# ---------------------------------------------------------------------------
# The port-in-use check
# ---------------------------------------------------------------------------

# Run the real start_mediamtx with only the hardware stood in for. The stub
# MediaMTX records that it was started and then waits. $1 is shell code run
# after the stand-ins, to replace more of them for one test.
_start_with_stub_mediamtx() {
    export EXTRA_SEAMS="${1:-}"
    make_launchable_mediamtx "$D/bin/mediamtx_proc" "$D"
    export STUB_STARTED="$D/mediamtx.started"
    rm -f "$STUB_STARTED" "$STUB_STARTED.pid"
    MEDIAMTX_BINARY="$STUB_MEDIAMTX_BINARY" BASH_ENV="$STUB_PRELUDE" MEDIAMTX_API_TIMEOUT=2 LYREBIRD_FLOW_SAMPLE_SECONDS=0 run bash -c '
        source "$1" >/dev/null 2>&1
        set +e
        detect_audio_devices() { echo "testmic:1"; }
        wait_for_usb_stabilization() { return 0; }
        wait_for_mediamtx_ready() { return 0; }
        start_all_ffmpeg_streams() { :; }
        validate_stream() { return 0; }
        device_node_exists() { return 0; }
        mediamtx_path_info() { printf "{\"ready\":true,\"bytesReceived\":1}"; }
        eval "$EXTRA_SEAMS"
        start_mediamtx' _ "$SM"
    [[ -f "$STUB_STARTED.pid" ]] && HELD_PIDS+=("$(head -n 1 "$STUB_STARTED.pid")")
    return 0
}

_hold_port() {
    python3 -I -c '
import socket, sys, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", int(sys.argv[1])))
s.listen()
open(sys.argv[2], "w").close()
time.sleep(120)' "$1" "$D/listening" 3>&- &
    LISTENER_PID=$!
    HELD_PIDS+=("$LISTENER_PID")
    local i
    for ((i = 0; i < 50; i++)); do
        [[ -e "$D/listening" ]] && return 0
        sleep 0.1
    done
    return 1
}

@test "start_mediamtx starts when the configured ports are free [X-19]" {
    command -v lsof >/dev/null || command -v ss >/dev/null || skip "neither lsof nor ss is installed"
    _start_with_stub_mediamtx
    [ "$status" -eq 0 ]
    [ -s "$D/mediamtx.started" ]
}

@test "start_mediamtx prints the stream URLs with the configured RTSP port, for individual and multiplex mode [X-19]" {
    command -v lsof >/dev/null || command -v ss >/dev/null || skip "neither lsof nor ss is installed"
    _start_with_stub_mediamtx
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK]"*"rtsp://localhost:${P_RTSP}/"* ]]
    [[ "$output" != *":8554/"* ]]
    kill -9 "$(head -n 1 "$STUB_STARTED.pid")" 2>/dev/null || true
    rm -f "$MEDIAMTX_PID_FILE"
    STREAM_MODE=multiplex MULTIPLEX_STREAM_NAME=studio _start_with_stub_mediamtx 'start_ffmpeg_multiplex_stream() { return 0; }'
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OK]"*"rtsp://localhost:${P_RTSP}/studio (multiplexed from 1 devices)"* ]]
}

@test "start_mediamtx prints the URL of a stream that failed validation with the configured RTSP port [X-19]" {
    command -v lsof >/dev/null || command -v ss >/dev/null || skip "neither lsof nor ss is installed"
    _start_with_stub_mediamtx 'mediamtx_path_info() { return 1; }'
    [[ "$output" == *"[FAIL]"*"rtsp://localhost:${P_RTSP}/"*"(failed"* ]]
    kill -9 "$(head -n 1 "$STUB_STARTED.pid")" 2>/dev/null || true
    rm -f "$MEDIAMTX_PID_FILE"
    STREAM_MODE=multiplex MULTIPLEX_STREAM_NAME=studio _start_with_stub_mediamtx 'mediamtx_path_info() { return 1; }; start_ffmpeg_multiplex_stream() { return 0; }'
    [[ "$output" == *"[FAIL]"*"rtsp://localhost:${P_RTSP}/studio (multiplexed from 1 devices) (failed"* ]]
}

@test "start_mediamtx refuses to start when any of the three configured ports is taken, checked with ss when lsof is absent [X-19]" {
    # A machine without lsof: `ss -tuln` (stood in for by a shim that prints
    # what the real one prints for a listening socket on each port in SS_PORTS)
    cat >"$D/bin/ss" <<'SHIM'
#!/bin/bash
printf 'Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port\n'
for p in $SS_PORTS; do
    printf 'tcp   LISTEN 0      4096         0.0.0.0:%s        0.0.0.0:*\n' "$p"
done
SHIM
    chmod +x "$D/bin/ss"
    export SS_PORTS=""
    local var port
    for var in P_RTSP P_API P_METRICS; do
        port="${!var}"
        rm -f "$D/sm.log" "$D/mediamtx.started"
        SS_PORTS="$port"
        _start_with_stub_mediamtx 'command_exists() { [[ "$1" == lsof ]] && return 1; command -v "$1" >/dev/null 2>&1; }'
        [ "$status" -ne 0 ]
        grep -q "Port ${port} appears to be in use" "$D/sm.log"
        [ ! -e "$D/mediamtx.started" ]
    done
    # the control: with none of the configured ports listed, MediaMTX is started
    SS_PORTS="8554 9997 9998"
    _start_with_stub_mediamtx 'command_exists() { [[ "$1" == lsof ]] && return 1; command -v "$1" >/dev/null 2>&1; }'
    [ "$status" -eq 0 ]
    [ -s "$D/mediamtx.started" ]
}

@test "a client socket that merely has a configured port number as its source port is not a port in use [X-19]" {
    command -v lsof >/dev/null || skip "lsof is not installed"
    local var port
    for var in P_RTSP P_API P_METRICS; do
        port="${!var}"
        rm -f "$D/connected" "$D/sm.log" "$D/mediamtx.started" "$D/mediamtx.started.pid"
        # a listener elsewhere, and a connected client whose local port is the configured one:
        # `lsof -i :PORT` lists it, nothing listens on PORT
        python3 -I -c '
import socket, sys, time
srv = socket.socket(); srv.bind(("127.0.0.1", 0)); srv.listen()
cli = socket.socket(); cli.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
cli.bind(("127.0.0.1", int(sys.argv[1]))); cli.connect(srv.getsockname())
open(sys.argv[2], "w").close()
time.sleep(120)' "$port" "$D/connected" 3>&- &
        LISTENER_PID=$!
        HELD_PIDS+=("$LISTENER_PID")
        local i
        for ((i = 0; i < 50; i++)); do
            [[ -e "$D/connected" ]] && break
            sleep 0.1
        done
        [ -e "$D/connected" ]
        # the premise: lsof does name this port
        lsof -i ":${port}" >/dev/null 2>&1
        _start_with_stub_mediamtx
        [ "$status" -eq 0 ] || {
            echo "$var=$port: a client socket was taken for a listener"
            cat "$D/sm.log"
            false
        }
        [ -s "$D/mediamtx.started" ]
        kill -9 "$(head -n 1 "$D/mediamtx.started.pid")" 2>/dev/null || true
        rm -f "$MEDIAMTX_PID_FILE"
        kill -9 "$LISTENER_PID" 2>/dev/null || true
        wait "$LISTENER_PID" 2>/dev/null || true
    done
}

@test "start_mediamtx refuses to start when any of the three configured ports is taken [X-19]" {
    command -v lsof >/dev/null || command -v ss >/dev/null || skip "neither lsof nor ss is installed"
    local var port
    for var in P_RTSP P_API P_METRICS; do
        port="${!var}"
        rm -f "$D/listening" "$D/sm.log"
        _hold_port "$port"
        _start_with_stub_mediamtx
        [ "$status" -ne 0 ] || {
            echo "$var=$port taken but start_mediamtx returned 0"
            false
        }
        grep -qE "Port ${port} (is already in use|appears to be in use)" "$D/sm.log" || {
            echo "no message about port $port:"
            cat "$D/sm.log"
            false
        }
        [ ! -e "$D/mediamtx.started" ] || {
            echo "MediaMTX was started although $var=$port is taken"
            false
        }
        kill -9 "$LISTENER_PID" 2>/dev/null || true
        wait "$LISTENER_PID" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# Readiness and API probes
# ---------------------------------------------------------------------------

@test "wait_for_mediamtx_ready asks the API on the configured port [X-19]" {
    stub_plan '{"routes":{"/v3/paths/list":{"status":200,"body":"{\"itemCount\":0,\"pageCount\":0,\"items\":[]}"}}}'
    stub_start "$P_API"
    sleep 300 &
    HELD_PIDS+=("$!")
    run env MEDIAMTX_API_TIMEOUT=5 MEDIAMTX_HOST=127.0.0.1 bash -c '
        source "$1" >/dev/null 2>&1
        set +e
        wait_for_mediamtx_ready "$2"' _ "$SM" "${HELD_PIDS[-1]}"
    [ "$status" -eq 0 ]
    grep -q '^GET /v3/paths/list' "$TEST_SCRATCH/stub.log"
}

@test "probe_stream_ready and the API version detection use the configured API port [X-19]" {
    stub_plan '{"routes":{
        "/v3/paths/list":{"status":200,"body":"{\"itemCount\":0,\"pageCount\":0,\"items\":[]}"},
        "/v3/paths/get/mic1":{"status":200,"body":"{\"name\":\"mic1\",\"ready\":true,\"available\":true}"}}}'
    stub_start "$P_API"
    run env MEDIAMTX_HOST=127.0.0.1 bash -c '
        source "$1" >/dev/null 2>&1
        set +e
        probe_stream_ready mic1
        echo "probe rc=$?"
        detect_mediamtx_api_version' _ "$SM"
    [ "$status" -eq 0 ]
    [[ "$output" == *"probe rc=0"* ]]
    [[ "$output" == *"http://127.0.0.1:${P_API}/v3"* ]]
    grep -q '^GET /v3/paths/get/mic1' "$TEST_SCRATCH/stub.log"
}

# ---------------------------------------------------------------------------
# The generated wrappers
# ---------------------------------------------------------------------------

# The wrappers check /dev/snd/pcmC<N>D0c, which a machine without sound
# hardware does not have, and run a real ffmpeg. For these tests `bash` and
# `ffmpeg` on PATH are shims: the first runs the wrapper the manager generated
# with those two hardware dependencies pointed at stand-ins, the second records
# the arguments it was given and waits. The wrapper text and its launch are
# the real ones.
_use_wrapper_hardware_stand_ins() {
    mkdir -p "$D/wrapbin"
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
printf '%s\n' "$@" >"$FFMPEG_ARGS"
printf '%s\n' "$$" >"$FFMPEG_ARGS.pid"
exec sleep 600
SHIM
    chmod +x "$D/wrapbin/bash" "$D/bin/ffmpeg"
    export STAND_IN_BIN="$D/bin" FFMPEG_ARGS="$D/ffmpeg.args"
    export PATH="$D/wrapbin:$PATH"
    # a capture PCM for the stand-in cards: the manager reads a card's capture
    # PCMs from ASOUND_PROC_ROOT and checks their nodes under DEV_SND_ROOT
    local card
    export ASOUND_PROC_ROOT="$D/asound" DEV_SND_ROOT="$D/dev-snd"
    mkdir -p "$ASOUND_PROC_ROOT" "$DEV_SND_ROOT"
    for card in 1 2; do
        mkdir -p "$ASOUND_PROC_ROOT/card${card}/pcm0c"
        echo "0d8c:0014" >"$ASOUND_PROC_ROOT/card${card}/usbid"
        : >"$DEV_SND_ROOT/controlC${card}"
        : >"$DEV_SND_ROOT/pcmC${card}D0c"
    done
}

# Wait for the stub ffmpeg of a wrapper to have run; remember what to kill
_wait_for_ffmpeg_args() {
    local i
    for ((i = 0; i < 100; i++)); do
        [[ -s "$FFMPEG_ARGS" && -s "$FFMPEG_ARGS.pid" ]] && break
        sleep 0.1
    done
    [[ -s "$FFMPEG_ARGS.pid" ]] && HELD_PIDS+=("$(<"$FFMPEG_ARGS.pid")")
    local wrapper
    for wrapper in "$D"/ff/*.pid; do
        [[ -f "$wrapper" ]] && HELD_PIDS+=("$(<"$wrapper")")
    done
    [[ -s "$FFMPEG_ARGS" ]]
}

@test "a per-stream wrapper publishes to the configured RTSP port and carries it in its environment [X-19]" {
    _use_wrapper_hardware_stand_ins
    STREAM_STARTUP_DELAY=0 run bash -c '
        source "$1" >/dev/null 2>&1
        set +e
        check_audio_device() { return 0; }
        validate_stream() { return 0; }
        start_ffmpeg_stream testmic 1 testmic' _ "$SM"
    [ "$status" -eq 0 ]
    _wait_for_ffmpeg_args
    grep -qx "rtsp://localhost:${P_RTSP}/testmic" "$FFMPEG_ARGS"
    grep -Eq "^MEDIAMTX_RTSP_PORT=\"?${P_RTSP}\"?$" "$D/ff/testmic.sh"
}

@test "a per-stream wrapper with local recording publishes to the configured RTSP port [X-19]" {
    _use_wrapper_hardware_stand_ins
    AUDIO_LOCAL_RECORDING=true AUDIO_RECORDING_PATH="$D/rec" STREAM_STARTUP_DELAY=0 run bash -c '
        source "$1" >/dev/null 2>&1
        set +e
        check_audio_device() { return 0; }
        validate_stream() { return 0; }
        start_ffmpeg_stream testmic 1 testmic' _ "$SM"
    [ "$status" -eq 0 ]
    _wait_for_ffmpeg_args
    grep -q "^\[f=rtsp:rtsp_transport=tcp\]rtsp://localhost:${P_RTSP}/testmic|" "$FFMPEG_ARGS"
}

@test "a multiplex wrapper publishes to the configured RTSP port and carries it in its environment [X-19]" {
    _use_wrapper_hardware_stand_ins
    MULTIPLEX_STREAM_NAME=studio run bash -c '
        source "$1" >/dev/null 2>&1
        set +e
        check_audio_device() { return 0; }
        start_ffmpeg_multiplex_stream testmic:1 testmic:2' _ "$SM"
    [ "$status" -eq 0 ]
    _wait_for_ffmpeg_args
    grep -qx "rtsp://localhost:${P_RTSP}/studio" "$FFMPEG_ARGS"
    grep -Eq "^MEDIAMTX_RTSP_PORT=\"?${P_RTSP}\"?$" "$D/ff/studio.sh"
}

# ---------------------------------------------------------------------------
# What the manager tells the operator
# ---------------------------------------------------------------------------

@test "status shows the stream URL with the configured RTSP port [X-19]" {
    run bash -c '
        source "$1" >/dev/null 2>&1
        set +e
        detect_audio_devices() { echo "testmic:1"; }
        show_status' _ "$SM"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Stream: rtsp://localhost:${P_RTSP}/"* ]]
    [[ "$output" != *":8554/"* ]]
}

@test "status shows the multiplex stream URL with the configured RTSP port [X-19]" {
    : >"$D/ff/studio.pid"
    MULTIPLEX_STREAM_NAME=studio run bash -c '
        source "$1" >/dev/null 2>&1
        set +e
        detect_audio_devices() { echo "testmic:1"; }
        read_pid_safe() { printf "%s" "$$"; }
        show_status' _ "$SM"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Stream: rtsp://localhost:${P_RTSP}/studio"* ]]
}

@test "the usage text shows the configured RTSP port in its multiplex examples [X-19]" {
    run bash "$SM" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Output: rtsp://localhost:${P_RTSP}/studio"* ]]
    [[ "$output" != *":8554/"* ]]
}

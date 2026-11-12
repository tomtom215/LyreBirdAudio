#!/usr/bin/env bats
# One name per setting across the scripts (register: X-55; decision D15, ports are configuration).
#
# - The diagnostics read the RTSP port from MEDIAMTX_PORT, a variable nothing else reads;
#   the manager, the installer and the orchestrator read MEDIAMTX_RTSP_PORT.
# - The orchestrator's "View Stream URLs" printed "rtsp://<ip>:8554/" whatever the port.
# - The metrics exporter read the manager's PID and wrapper directory from FFMPEG_PID_DIR,
#   while the manager's variable is MEDIAMTX_FFMPEG_DIR: a node with that moved was
#   scraped as "no streams".
# The real scripts run; private ports (41000-41999) only.

load scratch_tmpdir
load orchestrator_helper

setup() {
    scratch_setup
    orch_setup
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    export PROJECT_ROOT TEST_SCRATCH
}

teardown() {
    scratch_teardown
}

# the diagnostics' RTSP port, after the real script is sourced, with the given environment
diag_port() {
    run env -u MEDIAMTX_RTSP_PORT -u MEDIAMTX_PORT "$@" bash -c '
        source "$PROJECT_ROOT/lyrebird-diagnostics.sh" >/dev/null 2>&1
        echo "port=$MEDIAMTX_PORT"'
}

@test "the diagnostics read the RTSP port from MEDIAMTX_RTSP_PORT; MEDIAMTX_PORT is only the fallback; the default is 8554 [X-55]" {
    diag_port
    [ "$output" = "port=8554" ]
    diag_port MEDIAMTX_RTSP_PORT=41554
    [ "$output" = "port=41554" ]
    diag_port MEDIAMTX_PORT=41555
    [ "$output" = "port=41555" ]
    # both set: the name the rest of the suite reads wins
    diag_port MEDIAMTX_RTSP_PORT=41554 MEDIAMTX_PORT=41555
    [ "$output" = "port=41554" ]
}

@test "the diagnostics' service check looks for MEDIAMTX_RTSP_PORT and says so [X-55]" {
    # a port nothing listens on (an `ss` that lists nothing): the check names the configured
    # port in its verdict
    mkdir -p "$TEST_SCRATCH/shim"
    printf '#!/bin/bash\nexit 0\n' >"$TEST_SCRATCH/shim/ss"
    chmod +x "$TEST_SCRATCH/shim/ss"
    run env -u MEDIAMTX_PORT PATH="$TEST_SCRATCH/shim:$PATH" MEDIAMTX_RTSP_PORT=41554 MEDIAMTX_BINARY="$TEST_SCRATCH/fake-mediamtx" bash -c '
        source "$PROJECT_ROOT/lyrebird-diagnostics.sh" >/dev/null 2>&1
        printf "#!/bin/bash\nexit 0\n" >"$MEDIAMTX_BINARY"
        chmod +x "$MEDIAMTX_BINARY"
        check_mediamtx_service 2>&1'
    [[ "$output" == *"41554"* ]]
    [[ "$output" != *"8554"* ]]
    run env -u MEDIAMTX_PORT MEDIAMTX_RTSP_PORT=abc bash -c '
        source "$PROJECT_ROOT/lyrebird-diagnostics.sh" >/dev/null 2>&1
        check_mediamtx_service 2>&1'
    [[ "$output" == *"Invalid port number: abc"* ]]
}

@test "the orchestrator's View Stream URLs prints the configured RTSP port, and 8554 only by default or for an invalid value [X-55]" {
    export MEDIAMTX_RTSP_PORT=41554
    orch_run --step 'Select option' '5\n' --step 'Press Enter' '\n' --step 'Select option' '0\n' 'menu_streaming'
    [ "$status" -eq 0 ] || {
        echo "$output"
        false
    }
    [[ "$output" == *"Base URL: rtsp://"*":41554/"* ]]
    [[ "$output" != *":8554/"* ]]

    export MEDIAMTX_RTSP_PORT='41554;x'
    orch_run --step 'Select option' '5\n' --step 'Press Enter' '\n' --step 'Select option' '0\n' 'menu_streaming'
    [[ "$output" == *"Base URL: rtsp://"*":8554/"* ]]

    unset MEDIAMTX_RTSP_PORT
    orch_run --step 'Select option' '5\n' --step 'Press Enter' '\n' --step 'Select option' '0\n' 'menu_streaming'
    [[ "$output" == *"Base URL: rtsp://"*":8554/"* ]]
}

# The exporter's own view of the manager's directory, with the given environment
metrics_dir() {
    run env -u FFMPEG_PID_DIR -u MEDIAMTX_FFMPEG_DIR -u MEDIAMTX_RTSP_PORT -u MEDIAMTX_PORT "$@" bash -c '
        source "$PROJECT_ROOT/lyrebird-metrics.sh" >/dev/null 2>&1
        echo "dir=$FFMPEG_PID_DIR rtsp=$MEDIAMTX_RTSP_PORT"'
}

@test "the metrics exporter follows MEDIAMTX_FFMPEG_DIR, the manager's variable; FFMPEG_PID_DIR is the fallback; the default is the manager's [X-55]" {
    metrics_dir
    [ "$output" = "dir=/var/lib/mediamtx-ffmpeg rtsp=8554" ]
    metrics_dir MEDIAMTX_FFMPEG_DIR="$TEST_SCRATCH/mgr"
    [ "$output" = "dir=$TEST_SCRATCH/mgr rtsp=8554" ]
    metrics_dir FFMPEG_PID_DIR="$TEST_SCRATCH/old"
    [ "$output" = "dir=$TEST_SCRATCH/old rtsp=8554" ]
    metrics_dir FFMPEG_PID_DIR="$TEST_SCRATCH/old" MEDIAMTX_FFMPEG_DIR="$TEST_SCRATCH/mgr"
    [ "$output" = "dir=$TEST_SCRATCH/mgr rtsp=8554" ]
    # the same port variable as everything else, MEDIAMTX_PORT the fallback
    metrics_dir MEDIAMTX_RTSP_PORT=41554
    [ "$output" = "dir=/var/lib/mediamtx-ffmpeg rtsp=41554" ]
    metrics_dir MEDIAMTX_PORT=41555
    [ "$output" = "dir=/var/lib/mediamtx-ffmpeg rtsp=41555" ]
    metrics_dir MEDIAMTX_RTSP_PORT=41554 MEDIAMTX_PORT=41555
    [ "$output" = "dir=/var/lib/mediamtx-ffmpeg rtsp=41554" ]
}

@test "a scrape of a node whose manager directory was moved with MEDIAMTX_FFMPEG_DIR sees its streams [X-55]" {
    local mgr="$TEST_SCRATCH/mgr"
    mkdir -p "$mgr"
    # the manager's files for a stream whose wrapper is not running: the exporter must
    # find the PID file in the manager's directory (and so report the stream, as down)
    echo 999999 >"$mgr/mic1.pid"
    echo "999999 1" >"$mgr/mic1.pid.id"
    run env -u FFMPEG_PID_DIR MEDIAMTX_FFMPEG_DIR="$mgr" PID_FILE="$TEST_SCRATCH/mtx.pid" HEARTBEAT_FILE="$TEST_SCRATCH/hb" \
        bash "$PROJECT_ROOT/lyrebird-metrics.sh" --once
    [[ "$output" == *'lyrebird_stream_up{stream="mic1"} 0'* ]] || {
        echo "$output" | grep -i 'stream' | head
        false
    }
    # the exporter's old variable alone still works
    run env -u MEDIAMTX_FFMPEG_DIR FFMPEG_PID_DIR="$mgr" PID_FILE="$TEST_SCRATCH/mtx.pid" HEARTBEAT_FILE="$TEST_SCRATCH/hb" \
        bash "$PROJECT_ROOT/lyrebird-metrics.sh" --once
    [[ "$output" == *'lyrebird_stream_up{stream="mic1"} 0'* ]]
}

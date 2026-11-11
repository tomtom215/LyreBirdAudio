# shellcheck shell=bash
# Shared fixtures for the stream-definition tests (device config, stream names,
# wrappers, capture PCMs, multiplex graph).
#
# Every test runs the REAL lyrebird-stream-manager.sh: `sm` sources it in a child
# bash (its set -euo pipefail must not leak into bats, and a script that kills
# its own shell must not kill the test) and evals the test's code there. Only the
# things that need hardware or a second process are stood in for, and each
# stand-in is named in the test that uses it.
#
# Usage in a test file:
#   load scratch_tmpdir
#   load stream_definition_helper
#   setup()    { sd_setup; }
#   teardown() { sd_teardown; }

# shellcheck disable=SC2034 # SD, PROJECT_ROOT are read by the test files
sd_setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SD="$TEST_SCRATCH/sd"
    mkdir -p "$SD/cfg" "$SD/ff" "$SD/bin" "$SD/rec"
    SD_PIDS_FILE="$SD/stand-in.pids"
    : >"$SD_PIDS_FILE"

    export PROJECT_ROOT SD
    export LB_REAL_SCRIPT="$PROJECT_ROOT/lyrebird-stream-manager.sh"
    # Everything the script writes goes to private paths
    export MEDIAMTX_CONFIG_DIR="$SD/cfg"
    export MEDIAMTX_CONFIG_FILE="$SD/cfg/mediamtx.yml"
    export MEDIAMTX_DEVICE_CONFIG="$SD/cfg/audio-devices.conf"
    export MEDIAMTX_FFMPEG_DIR="$SD/ff"
    export MEDIAMTX_PID_FILE="$SD/mediamtx.pid"
    export MEDIAMTX_LOCK_FILE="$SD/run.lock"
    export STREAM_MANAGER_LOG_FILE="$SD/manager.log"
    export MEDIAMTX_LOG_FILE="$SD/mediamtx.out"
    export MEDIAMTX_RESTART_MARKER="$SD/restart.marker"
    export MEDIAMTX_CLEANUP_MARKER="$SD/cleanup.marker"
    export MEDIAMTX_HOST=127.0.0.1
    export CRON_RESTART_STATE_DIR="$SD/cron"
    export DEEP_HEALTH_STATE_DIR="$SD/deep-health"
    export HEARTBEAT_FILE="$SD/heartbeat"
    export MEM_SAMPLE_FILE="$SD/mem-samples"
    export AUDIO_RECORDING_PATH="$SD/rec"
    export LOCK_ACQUISITION_TIMEOUT=2 STOP_LOCK_TIMEOUT=1
    # Not inherited from the environment of the test run
    unset STREAM_MODE MULTIPLEX_STREAM_NAME MULTIPLEX_FILTER_TYPE MULTIPLEX_NAME_EXPLICIT \
        DEFAULT_SAMPLE_RATE DEFAULT_CHANNELS DEFAULT_CODEC DEFAULT_BITRATE DEFAULT_THREAD_QUEUE \
        AUDIO_LOCAL_RECORDING ASOUND_PROC_ROOT DEV_SND_ROOT

    # Nothing of the host may be touched: process lookups and port probes are
    # PATH shims that only record the call
    local tool
    for tool in pkill pgrep lsof ss; do
        printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s/%s.calls"\nexit 1\n' "$SD" "$tool" >"$SD/bin/$tool"
    done
    chmod +x "$SD/bin/"*
    export PATH="$SD/bin:$PATH"
}

sd_teardown() {
    local pid
    if [[ -n "${SD_PIDS_FILE:-}" && -f "$SD_PIDS_FILE" ]]; then
        while read -r pid; do
            [[ "$pid" =~ ^[0-9]+$ ]] && kill -9 "$pid" 2>/dev/null || true
        done <"$SD_PIDS_FILE"
    fi
    scratch_teardown
}

# Run CODE in a child bash with the real script sourced (errexit, nounset and
# pipefail exactly as in production). stdout and stderr are the code's.
sm() {
    bash -c 'source "$LB_REAL_SCRIPT" || exit 99; eval "$1"' sm "$1"
}

# The same with stderr (the manager's log lines) kept out of the output, in
# $SD/sm.stderr, so that `lines` holds only what the code printed
smq() {
    bash -c 'source "$LB_REAL_SCRIPT" || exit 99; eval "$1"' sm "$1" 2>>"$SD/sm.stderr"
}

# Code to put in front of a test's snippet when it runs start_ffmpeg_stream or
# start_ffmpeg_multiplex_stream. Stands in for: the wrapper process (spawn_detached
# only records the command and idles; the wrapper is written but never run), the
# waits (sleep), the RTSP validation that needs a running MediaMTX (validate_stream)
# and the hardware check (check_audio_device).
SD_SPAWN_STUBS='
sleep() { :; }
spawn_detached() {
    local fd
    for fd in 3 4 5 6 7 8 9; do eval "exec ${fd}>&-"; done
    printf "%s\n" "$*" >>"$SD/spawn.log"
    printf "%s\n" "$BASHPID" >>"$SD/stand-in.pids"
    command sleep 30
}
validate_stream() { return 0; }
check_audio_device() { return 0; }
'

# A line count of FILE matching PATTERN (fixed string), 0 when there is none
sd_count() {
    local n
    n="$(grep -cF -- "$2" "$1" 2>/dev/null)" || n=0
    printf '%s' "$n"
}

# The log lines the manager wrote
sd_log() {
    cat "$STREAM_MANAGER_LOG_FILE" 2>/dev/null || true
}

# --- real MediaMTX in a private network namespace ----------------------------
# The generated mediamtx.yml listens on fixed ports (8554/9997/9998 and, from
# 1.19, none else), so a test that starts a real MediaMTX runs inside
# `unshare --net --pid --fork --mount-proc` with only its own loopback: the
# host's ports are never touched, and every process in the namespace dies when
# the namespace's init (the test's script) exits.

# Skip unless a real MediaMTX binary and a private network namespace are available
sd_require_live() {
    [[ -n "${LYREBIRD_TEST_MEDIAMTX_BINS:-}" ]] || skip "set LYREBIRD_TEST_MEDIAMTX_BINS to run"
    local tool
    for tool in curl ffmpeg python3 unshare jq; do
        command -v "$tool" >/dev/null || skip "$tool not installed"
    done
    unshare --net --pid --fork --mount-proc true 2>/dev/null \
        || skip "network namespaces (unshare --net --pid --fork --mount-proc) are not permitted here"
}

# The oldest and the newest of the MediaMTX binaries to test with
sd_live_bins() {
    local -a bins
    read -r -a bins <<<"$LYREBIRD_TEST_MEDIAMTX_BINS"
    printf '%s\n' "${bins[0]}"
    ((${#bins[@]} > 1)) && printf '%s\n' "${bins[${#bins[@]} - 1]}"
    return 0
}

# Run `bash SCRIPT ARGS...` inside a fresh network namespace, loopback up
sd_ns_run() {
    cat >"$SD/lo_up.py" <<'PY'
import fcntl, socket, struct
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
flags = struct.unpack('16sH14x', fcntl.ioctl(s, 0x8913, struct.pack('16sH14x', b'lo', 0)))[1]
fcntl.ioctl(s, 0x8914, struct.pack('16sH14x', b'lo', flags | 1))
PY
    unshare --net --pid --fork --mount-proc \
        bash -c 'python3 -I "$1" || exit 98; shift; exec bash "$@"' _ "$SD/lo_up.py" "$@"
}

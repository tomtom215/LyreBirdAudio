# shellcheck shell=bash
# A private, hardware-free installation of the REAL stream manager, for tests of
# its start, stop and monitor paths (outcome, status file, reconcile).
#
# What is real: lyrebird-stream-manager.sh (sourced in a fresh bash, every test
# command is a real function), the wrapper scripts it generates and launches,
# the lifecycle lock, the PID files and the markers, real child processes.
# What stands in for what is not available here, and only that:
#
#   hardware   a "device tree" in $HW: $HW/<card> holds the device name,
#              $HW/dev-snd/controlC<card> is its control node. detect_audio_devices,
#              check_audio_device, check_alsa_device_available and
#              device_node_exists read it.
#   MediaMTX   a copy of the bash binary at the configured MediaMTX path that
#              waits (BASH_ENV, for that copy only), and a `curl` shim that answers
#              the API from $API/<stream>.json (404 when the file is absent).
#   FFmpeg     a stub `ffmpeg` first on the wrappers' PATH: it "publishes" by
#              keeping $API/<stream>.json (ready, with a growing inbound byte
#              counter) while it runs, and exits at once for a card listed in
#              $ST/bad-cards, as an FFmpeg that cannot open its capture device does.
#              $ST/api-shape selects the field names it writes: old (1.15: ready,
#              bytesReceived), new (>=1.18: both generations), newonly, or silent
#              (an FFmpeg that runs but never reaches MediaMTX: no path appears).
#
# Usage: in setup() call scratch_setup, then stage_setup; in teardown()
# stage_teardown, then scratch_teardown. Needs PROJECT_ROOT.

stage_setup() {
    ST="$TEST_SCRATCH/st"
    HW="$ST/hw"
    API="$ST/api"
    mkdir -p "$ST/cfg" "$ST/ff" "$ST/bin" "$ST/shim" "$ST/state" "$ST/wrapbin" "$HW/dev-snd" "$API"
    mkfifo "$ST/hold"
    echo new >"$ST/api-shape"
    export ST HW API PROJECT_ROOT

    export MEDIAMTX_CONFIG_DIR="$ST/cfg"
    export MEDIAMTX_PID_FILE="$ST/mtx.pid"
    export MEDIAMTX_FFMPEG_DIR="$ST/ff"
    export MEDIAMTX_LOCK_FILE="$ST/run.lock"
    export MEDIAMTX_LOG_FILE="$ST/sm.log"
    export MEDIAMTX_RESTART_MARKER="$ST/restart.marker"
    export MEDIAMTX_CLEANUP_MARKER="$ST/cleanup.marker"
    export MEDIAMTX_BINARY="$ST/bin/mediamtx"
    export MEDIAMTX_HOST="stage.invalid"
    export MEDIAMTX_API_VERSION=v3
    export LYREBIRD_STATE_DIR="$ST/state"
    export CRON_RESTART_STATE_DIR="$ST/state/cron-restarts"
    export DEEP_HEALTH_STATE_DIR="$ST/state/deep-health"
    export LOCK_ACQUISITION_TIMEOUT=2 STOP_LOCK_TIMEOUT=1 MONITOR_LOCK_TIMEOUT=1
    export STREAM_STARTUP_DELAY=0 STREAM_VALIDATION_DELAY=0 STREAM_VALIDATION_ATTEMPTS=1
    export MEDIAMTX_API_TIMEOUT=5 USB_STABILIZATION_DELAY=1 RESTART_STABILIZATION_DELAY=1
    export LYREBIRD_FLOW_SAMPLE_SECONDS=1
    export INITIAL_RESTART_DELAY=1 MAX_RESTART_DELAY=2
    unset CRON LYREBIRD_START_POLICY LYREBIRD_ALLOW_EMPTY_START LYREBIRD_STATUS_FILE LYREBIRD_DESIRED_MARKER

    # The MediaMTX stand-in: a copy of bash at the configured path, which BASH_ENV
    # (for that copy only) makes wait instead of reading the configuration file
    cp "$(command -v bash)" "$MEDIAMTX_BINARY"
    cat >"$ST/prelude.sh" <<'STUB_EOF'
if [[ "$BASH" == "$MEDIAMTX_BINARY" ]]; then
    exec {stub_fd}<>"$ST/hold"
    read -r -t 300 -u "$stub_fd" || true
    exit 0
fi
STUB_EOF
    export BASH_ENV="$ST/prelude.sh"

    # Port probes see an idle host; curl is the fake MediaMTX API
    printf '#!/bin/bash\nexit 1\n' >"$ST/shim/lsof"
    printf '#!/bin/bash\nexit 0\n' >"$ST/shim/ss"
    cat >"$ST/shim/curl" <<'CURL_EOF'
#!/bin/bash
[[ ! -e "$ST/api-down" ]] || exit 7
url="${!#}"
want_code=false
for arg in "$@"; do
    [[ "$arg" == *'%{http_code}'* ]] && want_code=true
done
case "$url" in
    */paths/get/*)
        name="${url##*/paths/get/}"
        if [[ -f "$API/$name.json" ]]; then
            body="$(cat "$API/$name.json")"
            code=200
        else
            body='{"error":"path not found"}'
            code=404
        fi
        ;;
    *)
        body='{"itemCount":0,"items":[]}'
        code=200
        ;;
esac
printf '%s' "$body"
if [[ "$want_code" == "true" ]]; then
    printf '\n%s' "$code"
fi
exit 0
CURL_EOF

    # FFmpeg stand-in (argv[0] is "ffmpeg", as for the real one)
    cat >"$ST/bin/ffmpeg" <<'FFMPEG_EOF'
#!/bin/bash
if [[ -z "${STUB_FFMPEG_REEXEC:-}" ]]; then
    STUB_FFMPEG_REEXEC=1 exec -a ffmpeg /bin/bash "$0" "$@"
fi
card=""
prev=""
for arg in "$@"; do
    if [[ "$prev" == "-i" && -z "$card" && "$arg" == plughw:* ]]; then
        card="${arg#plughw:}"
        card="${card%%,*}"
    fi
    prev="$arg"
done
url="${!#}"
name="${url##*/}"
if [[ -f "$ST/bad-cards" ]] && grep -qx "$card" "$ST/bad-cards"; then
    echo "ffmpeg: cannot open audio device plughw:${card},0" >&2
    exit 1
fi
shape="$(cat "$ST/api-shape" 2>/dev/null || echo new)"
trap 'rm -f "$API/$name.json"; exit 0' TERM INT
n=0
while :; do
    n=$((n + 1500))
    case "$shape" in
        silent) body="" ;;
        old) body="{\"name\":\"$name\",\"ready\":true,\"bytesReceived\":$n,\"bytesSent\":0}" ;;
        newonly) body="{\"name\":\"$name\",\"available\":true,\"online\":true,\"inboundBytes\":$n}" ;;
        *) body="{\"name\":\"$name\",\"ready\":true,\"available\":true,\"online\":true,\"inboundBytes\":$n,\"bytesReceived\":$n}" ;;
    esac
    if [[ -n "$body" ]]; then
        printf '%s' "$body" >"$API/$name.json.tmp" && mv -f "$API/$name.json.tmp" "$API/$name.json"
    fi
    sleep 0.2
done
FFMPEG_EOF

    # The generated wrapper checks /dev/snd/pcmC<N>D0c and wants a real ffmpeg:
    # `bash` on PATH is a shim that runs the wrapper the manager generated with
    # that path pointed at an existing file and the stub ffmpeg first on PATH.
    # The file is rewritten in place, so the process still runs
    # "<wrapper dir>/<stream>.sh" as argv[1].
    cat >"$ST/wrapbin/bash" <<'SHIM_EOF'
#!/bin/bash
if [[ "${1:-}" == "$ST/ff/"*.sh ]]; then
    script="$1"
    shift
    sed -e 's#/dev/snd/pcmC${card_num}D0c#/dev/null#' \
        -e 's#/dev/snd/pcmC${CARD_NUM}D0c#/dev/null#' \
        -e 's#export PATH="/usr/local/sbin#export PATH="'"$ST"'/bin:/usr/local/sbin#' \
        "$script" >"$script.rewritten"
    cat "$script.rewritten" >"$script"
    rm -f "$script.rewritten"
    exec /bin/bash "$script" "$@"
fi
exec /bin/bash "$@"
SHIM_EOF
    chmod +x "$ST/shim/"* "$ST/bin/ffmpeg" "$ST/wrapbin/bash"
    PATH="$ST/wrapbin:$ST/shim:$PATH"

    # Hardware seams, evaluated after the real script has been sourced
    export STAGE_SEAMS='
detect_audio_devices() {
    local f
    for f in "$HW"/[0-9]*; do
        [[ -f "$f" ]] || continue
        printf "%s:%s\n" "$(<"$f")" "${f##*/}"
    done
}
check_audio_device() { [[ -e "$HW/$1" ]]; }
check_alsa_device_available() { [[ -e "$HW/$1" && ! -e "$HW/busy-$1" ]]; }
device_node_exists() { [[ -e "$HW/dev-snd/controlC$1" ]]; }
'
    export STAGE_STABILIZE='wait_for_usb_stabilization() { return 0; }'
}

# stage_teardown: nothing of this installation outlives the test. Processes are
# found by the private paths in their command line.
stage_teardown() {
    local dir pid
    [[ -n "${ST:-}" ]] || return 0
    for dir in /proc/[0-9]*; do
        pid="${dir#/proc/}"
        [[ "$pid" != "$$" ]] || continue
        if tr '\0' ' ' 2>/dev/null <"$dir/cmdline" | grep -qF -- "$ST/"; then
            builtin kill -KILL "$pid" 2>/dev/null || true
        fi
    done
}

# device_add NAME CARD / device_remove CARD: plug and unplug a microphone
device_add() {
    printf '%s\n' "$1" >"$HW/$2"
    : >"$HW/dev-snd/controlC$2"
}
device_remove() {
    rm -f "$HW/$1" "$HW/dev-snd/controlC$1"
}

# card_unavailable CARD / card_available CARD: the card stays detected but ALSA
# cannot open it (the device is busy, or its node is not usable yet)
card_unavailable() { : >"$HW/busy-$1"; }
card_available() { rm -f "$HW/busy-$1"; }

# bad_card CARD: the capture of this card fails at once (a broken microphone)
bad_card() {
    echo "$1" >>"$ST/bad-cards"
}

# stage CODE: run CODE in a fresh bash that has sourced the real script and the
# hardware seams ($STAGE_STABILIZE can be emptied to run the real USB wait)
stage() {
    run bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"; eval "$STAGE_SEAMS"; eval "$STAGE_STABILIZE"; eval "$1"' _ "$1"
}

# stage_bg CODE: the same in the background; sets STAGE_PID
# shellcheck disable=SC2034  # read by the tests
stage_bg() {
    bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"; eval "$STAGE_SEAMS"; eval "$STAGE_STABILIZE"; eval "$1"' _ "$1" >"$ST/bg.out" 2>&1 3>&- &
    STAGE_PID=$!
}

# wait_until CMD [SECONDS]: wait until the command string succeeds
wait_until() {
    local i
    for ((i = 0; i < ${2:-10} * 20; i++)); do
        eval "$1" && return 0
        sleep 0.05
    done
    echo "timed out waiting for: $1" >&2
    return 1
}

# pid_running PID: alive and not a zombie
pid_running() {
    local state
    state="$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null || true)"
    [[ -n "$state" && "$state" != Z ]]
}

# mediamtx_stub_up: a running MediaMTX stand-in on the configured binary and
# configuration file, recorded in the PID file by the real write_pid_atomic
mediamtx_stub_up() {
    local pid i want
    "$MEDIAMTX_BINARY" "$MEDIAMTX_CONFIG_DIR/mediamtx.yml" </dev/null >/dev/null 2>&1 3>&- &
    pid=$!
    disown "$pid" 2>/dev/null || true
    want="$(readlink -f "$MEDIAMTX_BINARY")"
    for ((i = 0; i < 100; i++)); do
        [[ "$(readlink "/proc/$pid/exe" 2>/dev/null || true)" == "$want" ]] && break
        sleep 0.05
    done
    bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"; write_pid_atomic "$1" "$MEDIAMTX_PID_FILE"' _ "$pid"
}

# stage_processes: the PID of every running process whose command line names
# this installation's private directory (MediaMTX, wrappers, FFmpeg), one per line
stage_processes() {
    local dir pid
    for dir in /proc/[0-9]*; do
        pid="${dir#/proc/}"
        [[ "$pid" != "$$" ]] || continue
        if tr '\0' ' ' 2>/dev/null <"$dir/cmdline" | grep -qF -- "$ST/"; then
            if pid_running "$pid"; then
                echo "$pid"
            fi
        fi
    done
}

# The PID recorded for a stream wrapper / for MediaMTX
stream_pid() { cat "$ST/ff/$1.pid" 2>/dev/null; }
mediamtx_pid() { cat "$ST/mtx.pid" 2>/dev/null; }

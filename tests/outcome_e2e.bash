# shellcheck shell=bash
# The truthful start outcome, the status file and the monitor's reconcile of the
# stream manager against a REAL MediaMTX and real FFmpeg, in a private network
# namespace (tests/test_mediamtx_live.bats runs this file). Same set-up as
# tests/lifecycle_e2e.bash (read its header): run as
#   unshare --net --pid --fork --mount-proc bash tests/outcome_e2e.bash
# as root, with PROJECT_ROOT (the checkout), BIN (a MediaMTX binary) and WORK (an
# empty scratch directory).
#
# What is real: the manager's start_mediamtx / stop_mediamtx / monitor_cycle (each
# command in a fresh process), the config it generates, MediaMTX, the generated
# wrappers, FFmpeg publishing to MediaMTX over RTSP, an FFmpeg reader receiving a
# stream, and the MediaMTX API the outcome is read from (so the inbound byte
# counter's field name is checked on this very binary). What stands in for
# hardware: the USB device list (the file $WORK/devices is the "hub"), the ALSA
# checks, fake /dev/snd/{control,pcm}C* nodes, and an `ffmpeg` first on the
# wrappers' PATH that replaces the ALSA capture input by a tone, or exits at once
# for a card listed in $WORK/bad-cards (a capture device that cannot be opened).
#
# Prints "E2E: ..." progress lines and, on the first violated expectation,
# "E2E-FAIL: ..." and exits 1. Exit 77: the namespace cannot do the overlays.

set -u
fail() {
    echo "E2E-FAIL: $*"
    exit 1
}
note() { echo "E2E: $*"; }

trap '[[ -z "${OWNER:-}" ]] || chown -R "$OWNER" "$WORK" 2>/dev/null' EXIT

# --- loopback up (no `ip` needed) -------------------------------------------
python3 -I - <<'PY' || fail "cannot bring the loopback interface up"
import fcntl, socket, struct
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
flags = struct.unpack('16sH', fcntl.ioctl(s.fileno(), 0x8913, struct.pack('16sH', b'lo', 0)))[1]
fcntl.ioctl(s.fileno(), 0x8914, struct.pack('16sH', b'lo', flags | 1))
PY

REAL_FFMPEG="$(command -v ffmpeg)"
mkdir -p "$WORK/ov"/{dev-up,dev-work,loc-up,loc-work} "$WORK/cfg" "$WORK/ff" "$WORK/state"
: >"$WORK/devices"
: >"$WORK/bad-cards"

# --- hardware stand-ins, visible only inside this mount namespace -------------
mount -t overlay overlay -o "lowerdir=/dev,upperdir=$WORK/ov/dev-up,workdir=$WORK/ov/dev-work" /dev \
    || {
        echo "E2E-SKIP: cannot overlay /dev in this namespace"
        exit 77
    }
mkdir -p /dev/snd
for card in 31 32; do
    : >"/dev/snd/controlC$card"
    : >"/dev/snd/pcmC${card}D0c"
done
mount -t overlay overlay -o "lowerdir=/usr/local,upperdir=$WORK/ov/loc-up,workdir=$WORK/ov/loc-work" /usr/local \
    || {
        echo "E2E-SKIP: cannot overlay /usr/local in this namespace"
        exit 77
    }
mkdir -p /usr/local/sbin
cat >/usr/local/sbin/ffmpeg <<SHIM
#!/bin/bash
# Stand-in for the capture device only: an ALSA input becomes a tone, or fails at
# once for a card in the bad-cards list; the real ffmpeg does everything else
args=()
while ((\$# > 0)); do
    case "\$1" in
        -analyzeduration | -probesize | -rtbufsize | -ar | -ac | -thread_queue_size)
            shift 2
            continue
            ;;
        -f)
            if [[ "\$2" == alsa ]]; then
                args+=(-re -f lavfi)
                shift 2
                continue
            fi
            ;;
        -i)
            if [[ "\$2" == plughw:* ]]; then
                card="\${2#plughw:}"
                card="\${card%%,*}"
                if grep -qx "\$card" "$WORK/bad-cards"; then
                    echo "ffmpeg: cannot open audio device \$2" >&2
                    exit 1
                fi
                args+=(-i "sine=frequency=\$((300 + card * 10)):sample_rate=48000")
                shift 2
                continue
            fi
            ;;
    esac
    args+=("\$1")
    shift
done
exec -a ffmpeg $REAL_FFMPEG "\${args[@]}"
SHIM
chmod +x /usr/local/sbin/ffmpeg

# --- the manager's environment -------------------------------------------------
export MEDIAMTX_BINARY="$BIN" MEDIAMTX_CONFIG_DIR="$WORK/cfg" MEDIAMTX_FFMPEG_DIR="$WORK/ff"
export MEDIAMTX_PID_FILE="$WORK/mtx.pid" MEDIAMTX_LOCK_FILE="$WORK/run.lock" MEDIAMTX_LOG_FILE="$WORK/sm.log"
export MEDIAMTX_RESTART_MARKER="$WORK/restart.marker" MEDIAMTX_CLEANUP_MARKER="$WORK/cleanup.marker"
export STREAM_STARTUP_DELAY=0 STREAM_VALIDATION_DELAY=1 STREAM_VALIDATION_ATTEMPTS=5
export USB_STABILIZATION_DELAY=1 RESTART_STABILIZATION_DELAY=1 MEDIAMTX_API_TIMEOUT=30
export LYREBIRD_STATE_DIR="$WORK/state" LYREBIRD_FLOW_SAMPLE_SECONDS=2
export CRON_RESTART_STATE_DIR="$WORK/state/cron-restarts" DEEP_HEALTH_STATE_DIR="$WORK/state/deep-health"
export MONITOR_LOCK_TIMEOUT=2 INITIAL_RESTART_DELAY=1 MAX_RESTART_DELAY=2
export PROJECT_ROOT WORK
STATUS="$WORK/state/status.json"
# MEDIAMTX_HOST stays "localhost" and the ports the defaults, as on a node

# One command of the real script as a fresh process (as from the command line);
# its seams are hardware only. Output goes to $WORK/mgr.out; the exit status is
# the command's.
mgr() {
    bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh"
        detect_audio_devices() { cat "$WORK/devices"; }
        wait_for_usb_stabilization() { return 0; }
        check_audio_device() { return 0; }
        check_alsa_device_available() { return 0; }
        COMMAND="$1"
        install_lifecycle_traps
        case "$1" in
            start) start_mediamtx ;;
            stop) stop_mediamtx ;;
            monitor) monitor_cycle ;;
            *) "$@" ;;
        esac' _ "$@" >>"$WORK/mgr.out" 2>&1
}

alive() { [[ -d "/proc/$1" ]] && [[ "$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" != Z ]]; }
wait_gone() {
    local i
    for ((i = 0; i < 100; i++)); do
        alive "$1" || return 0
        sleep 0.1
    done
    return 1
}
# processes of this installation (MediaMTX, wrappers, FFmpeg writing the wrapper logs)
leftovers() {
    local dir pid
    for dir in /proc/[0-9]*; do
        pid="${dir#/proc/}"
        [[ "$pid" != "$$" ]] || continue
        if tr '\0' ' ' 2>/dev/null <"$dir/cmdline" | grep -qE "$BIN|$WORK/ff/"; then
            alive "$pid" && echo "$pid"
        fi
    done
}
wait_no_leftovers() {
    local i
    for ((i = 0; i < 100; i++)); do
        [[ -z "$(leftovers)" ]] && return 0
        sleep 0.1
    done
    return 1
}
jqs() { jq -e "$1" "$STATUS" >/dev/null || {
    echo "--- $STATUS:"
    cat "$STATUS"
    fail "status file: expected $1"
}; }
reader_bytes() { stat -c %s "$WORK/reader.ogg" 2>/dev/null || echo 0; }
wait_bytes_grow() {
    local i
    for ((i = 0; i < 150; i++)); do
        (($(reader_bytes) > $1)) && return 0
        sleep 0.1
    done
    return 1
}

# === 1. a broken capture: start fails, the status says failed, MediaMTX is cleaned up
note "1. broken capture"
echo "mic1:31" >"$WORK/devices"
echo 31 >"$WORK/bad-cards"
rc=0
mgr start || rc=$?
[[ $rc -eq 9 ]] || {
    tail -30 "$WORK/mgr.out"
    fail "start with a broken capture exited $rc, expected 9"
}
jqs '.overall == "failed" and .policy == "degraded" and .mediamtx.running == false and .streams[0].path_ready == false and (.streams[0].last_error | length > 0)'
wait_no_leftovers || {
    leftovers
    fail "processes of this installation are left after the failed start"
}
[[ ! -e "$WORK/mtx.pid" && ! -e "$WORK/cleanup.marker" ]] || fail "the failed start left its PID file or the cleanup marker"
note "exit 9, status failed, MediaMTX and the wrapper are gone"

# === 2. one good and one broken device: degraded start exits 0 and names the broken one
note "2. one good and one broken device"
printf 'mic1:31\nmic2:32\n' >"$WORK/devices"
echo 32 >"$WORK/bad-cards"
: >"$WORK/mgr.out"
mgr start || {
    tail -30 "$WORK/mgr.out"
    fail "the degraded start did not exit 0"
}
jqs '.overall == "degraded" and .mediamtx.running == true'
jqs '.streams[0] | .path == "mic1" and .configured == true and .process_alive == true and .path_ready == true and .bytes_flowing == true and .last_error == null'
jqs '.streams[1] | .path == "mic2" and .path_ready == false and .bytes_flowing == false and (.last_error | length > 0)'
note "degraded: mic1 publishes (bytes flowing), mic2 failed: $(jq -r '.streams[1].last_error' "$STATUS")"

# The byte counter field this MediaMTX reports, read from its real API
OBJ="$(curl -s --max-time 3 "http://localhost:9997/v3/paths/get/mic1")"
FIELDS="$(jq -r 'keys | map(select(test("^(inboundBytes|bytesReceived|ready|available)$"))) | join(",")' <<<"$OBJ")"
note "path fields on this MediaMTX: $FIELDS"
[[ "$FIELDS" == *inboundBytes* || "$FIELDS" == *bytesReceived* ]] || fail "this MediaMTX reports neither inboundBytes nor bytesReceived: $OBJ"
B1="$(bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"; mediamtx_json_inbound_bytes "$1"' _ "$OBJ")"
[[ "$B1" =~ ^[0-9]+$ && "$B1" -gt 0 ]] || fail "the manager read no inbound byte counter from the real path object: '$B1' of $OBJ"
sleep 2
B2="$(bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"; o="$(mediamtx_path_info mic1)"; mediamtx_json_inbound_bytes "$o"' _)"
((B2 > B1)) || fail "the counter did not grow on the real binary ($B1 -> $B2)"
note "inbound byte counter grows on the real API: $B1 -> $B2"
mgr stop || fail "stop failed"

# the same devices under strict: not every stream publishes, so the start fails
# and takes down everything it started
: >"$WORK/mgr.out"
rc=0
LYREBIRD_START_POLICY=strict mgr start || rc=$?
[[ $rc -eq 9 ]] || {
    tail -30 "$WORK/mgr.out"
    fail "strict start with one broken device exited $rc, expected 9"
}
jqs '.overall == "failed" and .policy == "strict" and .mediamtx.running == false'
wait_no_leftovers || fail "processes are left after the failed strict start"
[[ ! -e "$WORK/mtx.pid" && ! -e "$WORK/cleanup.marker" ]] || fail "the failed strict start left its PID file or the cleanup marker"
note "strict: exit 9, everything this run started is gone"
mgr stop || fail "stop after the failed strict start failed"

# === 3. hot-plug: start with no device, then the monitor starts a stream for each one that appears
note "3. hot-plug 0 -> 1 -> 2 through the monitor"
: >"$WORK/devices"
: >"$WORK/bad-cards"
: >"$WORK/mgr.out"
mgr start || {
    tail -30 "$WORK/mgr.out"
    fail "start with no device failed"
}
jqs '.overall == "waiting_for_devices" and .mediamtx.running == true and .streams == []'
MTX="$(cat "$WORK/mtx.pid")"
note "no device: exit 0, waiting_for_devices, MediaMTX up (PID $MTX)"
mgr monitor || fail "monitor with no device did not exit 0"

echo "mic1:31" >"$WORK/devices"
mgr monitor || {
    tail -30 "$WORK/mgr.out"
    fail "the monitor cycle after the first device appeared failed"
}
jqs '.command == "monitor" and .overall == "ok" and (.streams | length) == 1 and .streams[0].path == "mic1" and .streams[0].path_ready == true and .streams[0].bytes_flowing == true'
(exec -a ffmpeg "$REAL_FFMPEG" -nostdin -loglevel error -analyzeduration 500000 -probesize 100000 \
    -rtsp_transport tcp -i rtsp://localhost:8554/mic1 -c copy -flush_packets 1 -f ogg \
    "$WORK/reader.ogg" >"$WORK/reader.log" 2>&1) &
READER=$!
wait_bytes_grow 0 || {
    cat "$WORK/reader.log"
    fail "a real RTSP reader received nothing from the stream the monitor started"
}
note "0 -> 1: the monitor started mic1 and a real reader receives it"

W1="$(cat "$WORK/ff/mic1.pid")"
printf 'mic1:31\nmic2:32\n' >"$WORK/devices"
mgr monitor || {
    tail -30 "$WORK/mgr.out"
    fail "the monitor cycle after the second device appeared failed"
}
jqs '.overall == "ok" and (.streams | length) == 2 and ([.streams[].path_ready] | all) and ([.streams[].bytes_flowing] | all)'
[[ "$(cat "$WORK/ff/mic1.pid")" == "$W1" && "$(cat "$WORK/mtx.pid")" == "$MTX" ]] || fail "the monitor restarted what was running"
B="$(reader_bytes)"
wait_bytes_grow "$B" || fail "the reader's stream stopped while the monitor started the second device"
note "1 -> 2: mic2 added, MediaMTX and mic1 untouched, the reader keeps receiving"

# === 4. MediaMTX killed while the node is meant to run: the monitor starts it again
note "4. MediaMTX killed"
kill -KILL "$MTX"
wait_gone "$MTX" || fail "could not kill MediaMTX"
kill "$READER" 2>/dev/null
: >"$WORK/mgr.out"
mgr monitor || {
    tail -40 "$WORK/mgr.out"
    fail "the monitor did not bring MediaMTX back"
}
[[ "$(cat "$WORK/mtx.pid")" != "$MTX" ]] && alive "$(cat "$WORK/mtx.pid")" || fail "MediaMTX is not running again"
jqs '.overall == "ok" and .mediamtx.running == true and (.streams | length) == 2 and ([.streams[].path_ready] | all)'
note "the monitor started MediaMTX again and both streams publish"

mgr stop || fail "the final stop failed"
jqs '.overall == "stopped" and .streams == []'
wait_no_leftovers || fail "processes are left after the final stop"
note "DONE"

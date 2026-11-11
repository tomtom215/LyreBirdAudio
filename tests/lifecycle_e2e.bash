# shellcheck shell=bash
# The stream manager's lifecycle against a REAL MediaMTX and real FFmpeg, in a
# private network namespace (tests/test_mediamtx_live.bats runs this file).
#
# It runs inside
#   unshare --net --pid --fork --mount-proc bash tests/lifecycle_e2e.bash
# as root, so the default ports (8554, 9997, 9998) the manager hard-codes are
# bound in a namespace of their own and the host's are never touched, and every
# process started here dies with the namespace's init.
#
# Environment: PROJECT_ROOT (the checkout), BIN (a MediaMTX binary), WORK (an
# empty scratch directory).
#
# What is real: the manager's start_mediamtx / stop_mediamtx / restart_mediamtx
# (each command in a fresh process, as from the command line), the config the
# manager generates, MediaMTX, the generated wrapper scripts, FFmpeg publishing
# to MediaMTX over RTSP and an FFmpeg reader receiving the stream. What stands in
# for hardware: the USB device list, the ALSA availability check, two fake
# /dev/snd/{control,pcm}C* nodes and an `ffmpeg` first on the wrappers' PATH that
# replaces the ALSA capture input by a tone (an overlay on /dev and /usr/local,
# visible only inside this namespace).
#
# Prints "E2E: ..." progress lines and, on the first violated expectation,
# "E2E-FAIL: ..." and exits 1. Exit 77: the namespace cannot do the overlays.

set -u
fail() {
    echo "E2E-FAIL: $*"
    exit 1
}
note() { echo "E2E: $*"; }

# Files made here belong to whoever started this run (OWNER, "uid:gid"; it only
# differs from root when the run went through sudo)
trap '[[ -z "${OWNER:-}" ]] || chown -R "$OWNER" "$WORK" 2>/dev/null' EXIT

# --- loopback up (no `ip` needed) -------------------------------------------
python3 -I - <<'PY' || fail "cannot bring the loopback interface up"
import fcntl, socket, struct
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
flags = struct.unpack('16sH', fcntl.ioctl(s.fileno(), 0x8913, struct.pack('16sH', b'lo', 0)))[1]
fcntl.ioctl(s.fileno(), 0x8914, struct.pack('16sH', b'lo', flags | 1))
PY

REAL_FFMPEG="$(command -v ffmpeg)"
mkdir -p "$WORK/ov"/{dev-up,dev-work,loc-up,loc-work} "$WORK/cfg" "$WORK/ff"

# --- hardware stand-ins, visible only inside this mount namespace -------------
mount -t overlay overlay -o "lowerdir=/dev,upperdir=$WORK/ov/dev-up,workdir=$WORK/ov/dev-work" /dev \
    || {
        echo "E2E-SKIP: cannot overlay /dev in this namespace"
        exit 77
    }
mkdir -p /dev/snd
: >/dev/snd/controlC31
: >/dev/snd/pcmC31D0c
: >/dev/snd/controlC32
: >/dev/snd/pcmC32D0c
mount -t overlay overlay -o "lowerdir=/usr/local,upperdir=$WORK/ov/loc-up,workdir=$WORK/ov/loc-work" /usr/local \
    || {
        echo "E2E-SKIP: cannot overlay /usr/local in this namespace"
        exit 77
    }
mkdir -p /usr/local/sbin
cat >/usr/local/sbin/ffmpeg <<SHIM
#!/bin/bash
# Stand-in for the capture device only: an ALSA input becomes a tone; the real
# ffmpeg does everything else (encoding, RTSP publishing)
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
export STREAM_MANAGER_LOG_FILE="$WORK/sm.log"
export MEDIAMTX_RESTART_MARKER="$WORK/restart.marker" MEDIAMTX_CLEANUP_MARKER="$WORK/cleanup.marker"
export STREAM_STARTUP_DELAY=0 STREAM_VALIDATION_DELAY=1 STREAM_VALIDATION_ATTEMPTS=5
export USB_STABILIZATION_DELAY=1 RESTART_STABILIZATION_DELAY=1 MEDIAMTX_API_TIMEOUT=30
export PROJECT_ROOT WORK DEVICES="mic1:31 mic2:32"
# MEDIAMTX_HOST stays "localhost", as on a node

# One command of the real script as a fresh process (as from the command line);
# its seams are hardware only
mgr() {
    bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh"
        detect_audio_devices() { printf "%s\n" $DEVICES; }
        wait_for_usb_stabilization() { return 0; }
        check_audio_device() { return 0; }
        COMMAND="$1"
        trap cleanup EXIT INT TERM
        case "$1" in
            start) start_mediamtx ;;
            stop) stop_mediamtx ;;
            restart) restart_mediamtx ;;
            *) "$@" ;;
        esac' _ "$@" >>"$WORK/mgr.out" 2>&1
}

# "<pid>:<start time>" of a process
pidstart() {
    local start
    start="$(sed 's/^.*) //' "/proc/$1/stat" | awk '{print $20}')"
    echo "$1:$start"
}

# "mtx=<pid>:<start> mic1=... mic2=..." as recorded in the PID files
state() {
    local out="" name
    out="mtx=$(pidstart "$(cat "$WORK/mtx.pid")")"
    for name in mic1 mic2; do
        [[ -f "$WORK/ff/$name.pid" ]] && out+=" $name=$(pidstart "$(cat "$WORK/ff/$name.pid")")"
    done
    echo "$out"
}
field() { # field NAME STATE
    local f
    for f in $2; do
        [[ "$f" == "$1="* ]] && echo "${f#*=}"
    done
}

reader_bytes() { stat -c %s "$WORK/reader.ogg" 2>/dev/null || echo 0; }
alive() { [[ -d "/proc/$1" ]] && [[ "$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" != Z ]]; }
wait_gone() {
    local i
    for ((i = 0; i < 100; i++)); do
        alive "$1" || return 0
        sleep 0.1
    done
    return 1
}
# wait until the reader's file is larger than $1 bytes (at most 15 s)
wait_bytes_grow() {
    local i
    for ((i = 0; i < 150; i++)); do
        (($(reader_bytes) > $1)) && return 0
        sleep 0.1
    done
    return 1
}

# --- start 1: the node comes up --------------------------------------------------
note "start 1"
mgr start || {
    cat "$WORK/mgr.out"
    fail "the first start failed"
}
[[ -f "$WORK/mtx.pid" && -f "$WORK/ff/mic1.pid" && -f "$WORK/ff/mic2.pid" ]] || {
    cat "$WORK/mgr.out"
    fail "PID files are missing after the first start"
}
S1="$(state)"
note "state after start 1: $S1"
# A real RTSP reader, started as plain "ffmpeg" (what the old pattern kill matches)
(exec -a ffmpeg "$REAL_FFMPEG" -nostdin -loglevel error -analyzeduration 500000 -probesize 100000 \
    -rtsp_transport tcp -i rtsp://localhost:8554/mic1 -c copy -flush_packets 1 -f ogg \
    "$WORK/reader.ogg" >"$WORK/reader.log" 2>&1) &
READER=$!
wait_bytes_grow 0 || {
    cat "$WORK/reader.log"
    fail "the reader received nothing after the first start"
}
note "the reader receives the stream (mic1)"

# --- starts 2 and 3 on a healthy node: nothing may change ---------------------------
for n in 2 3; do
    note "start $n"
    mgr start || {
        tail -30 "$WORK/mgr.out"
        fail "start $n failed"
    }
    Sn="$(state)"
    [[ "$Sn" == "$S1" ]] || fail "start $n changed the PIDs: before [$S1], after [$Sn]"
    [[ ! -e "$WORK/restart.marker" && ! -e "$WORK/cleanup.marker" ]] || fail "start $n left a marker"
    alive "$READER" || fail "the reader died during start $n"
    Bn="$(reader_bytes)"
    wait_bytes_grow "$Bn" || fail "no bytes flowed after start $n (stuck at $Bn)"
    note "start $n: same PIDs, the reader's bytes went $Bn -> $(reader_bytes)"
done

# --- a dead wrapper is reconciled by the next start -------------------------------------
W2="$(field mic2 "$S1")"
W2="${W2%%:*}"
for c in $(ps -o pid= --ppid "$W2"); do kill -KILL "$c"; done
kill -KILL "$W2"
wait_gone "$W2" || fail "could not kill the wrapper of mic2"
note "killed the wrapper of mic2 ($W2) and its FFmpeg"
mgr start || {
    tail -30 "$WORK/mgr.out"
    fail "the start after the wrapper died failed"
}
S4="$(state)"
note "state after the reconcile: $S4"
[[ "$(field mtx "$S4")" == "$(field mtx "$S1")" ]] || fail "the reconcile restarted MediaMTX"
[[ "$(field mic1 "$S4")" == "$(field mic1 "$S1")" ]] || fail "the reconcile restarted the healthy mic1 wrapper"
N2="$(field mic2 "$S4")"
[[ "${N2%%:*}" != "$W2" ]] || fail "mic2 was not restarted"
alive "${N2%%:*}" || fail "the new mic2 wrapper is not running"
alive "$READER" || fail "the reader (mic1) died during the reconcile"
wait_bytes_grow "$(reader_bytes)" || fail "mic1's bytes stopped flowing during the reconcile"
note "mic2 is back (wrapper ${N2%%:*}); mic1 and MediaMTX were not touched"

# --- stop leaves nothing of this installation, and no FFmpeg orphan -------------------------
MTX="$(field mtx "$S4")"
MTX="${MTX%%:*}"
note "stop"
T0=$SECONDS
mgr stop || {
    tail -30 "$WORK/mgr.out"
    fail "stop failed"
}
note "stop took $((SECONDS - T0)) s for 2 streams and MediaMTX"
alive "$MTX" && fail "MediaMTX survived stop"
[[ ! -e "$WORK/mtx.pid" ]] || fail "the PID file is left after stop"
! compgen -G "$WORK/ff/*.pid" >/dev/null || fail "wrapper PID files are left after stop"
: >"$WORK/mgr.out"
mgr force_stop_mediamtx --kill-all
grep -q "no process of this installation was found" "$WORK/mgr.out" || {
    cat "$WORK/mgr.out"
    fail "something of this installation survived stop"
}
note "stop left nothing behind (no wrapper, FFmpeg or MediaMTX of this installation)"

# --- a MediaMTX this manager did not start: start is refused, nothing is touched ------------------
"$BIN" "$WORK/cfg/mediamtx.yml" >"$WORK/other-mtx.log" 2>&1 &
OTHER=$!
for ((i = 0; i < 100; i++)); do
    curl -s --max-time 1 http://localhost:9997/v3/paths/list >/dev/null && break
    sleep 0.1
done
: >"$WORK/mgr.out"
rc=0
mgr start || rc=$?
[[ $rc -eq 8 ]] || {
    cat "$WORK/mgr.out"
    fail "start beside a MediaMTX it did not start exited $rc, expected 8"
}
grep -q "was not started by this script" "$WORK/mgr.out" || fail "the refusal does not say why"
alive "$OTHER" || fail "the other MediaMTX was killed by the refused start"
[[ ! -e "$WORK/mtx.pid" && ! -e "$WORK/cleanup.marker" ]] || fail "the refused start left state behind"
kill "$OTHER"
wait_gone "$OTHER" || fail "could not stop the other MediaMTX"
note "start was refused with exit 8; the other MediaMTX was left alone"

# --- restart renews everything -----------------------------------------------------------------
mgr start || fail "the start before the restart failed"
S5="$(state)"
mgr restart || {
    tail -40 "$WORK/mgr.out"
    fail "restart failed"
}
S6="$(state)"
[[ "$(field mtx "$S5")" != "$(field mtx "$S6")" ]] || fail "restart kept the old MediaMTX"
[[ "$(field mic1 "$S5")" != "$(field mic1 "$S6")" ]] || fail "restart kept the old mic1 wrapper"
[[ ! -e "$WORK/restart.marker" ]] || fail "restart left its marker behind"
note "restart: [$S5] -> [$S6]"
mgr stop || fail "the final stop failed"
kill "$READER" 2>/dev/null
note "DONE"

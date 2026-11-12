# shellcheck shell=bash
# The stream manager's `reload` against a REAL MediaMTX and real FFmpeg, in a
# private network namespace (tests/test_mediamtx_live.bats runs this file).
#
# It runs inside
#   unshare --net --pid --fork --mount-proc bash tests/reload_e2e.bash
# as root, so the default ports (8554, 9997, 9998) are bound in a namespace of
# their own and the host's are never touched, and every process started here dies
# with the namespace's init. The set-up is the one of tests/lifecycle_e2e.bash:
# real start / reload / stop of the manager (each command in a fresh process),
# the config the manager generates, MediaMTX, the generated wrapper scripts and
# FFmpeg publishing to MediaMTX; only the USB device list, the ALSA availability
# check, two fake /dev/snd nodes and an `ffmpeg` that swaps the ALSA capture
# input for a tone stand in for hardware (overlays visible only in this namespace).
#
# Environment: PROJECT_ROOT, BIN (a MediaMTX binary), WORK (an empty scratch
# directory), OWNER (optional "uid:gid" the files go back to).
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
export MEDIAMTX_PID_FILE="$WORK/mtx.pid" MEDIAMTX_LOCK_FILE="$WORK/run.lock" MEDIAMTX_LOG_FILE="$WORK/sm.log" STREAM_MANAGER_LOG_FILE="$WORK/sm.log"
export MEDIAMTX_RESTART_MARKER="$WORK/restart.marker" MEDIAMTX_CLEANUP_MARKER="$WORK/cleanup.marker"
export STREAM_STARTUP_DELAY=0 STREAM_VALIDATION_DELAY=1 STREAM_VALIDATION_ATTEMPTS=5
export USB_STABILIZATION_DELAY=1 RESTART_STABILIZATION_DELAY=1 MEDIAMTX_API_TIMEOUT=30
export INITIAL_RESTART_DELAY=1
export SILENCE_STATE_DIR="$WORK/silence" CRON_RESTART_STATE_DIR="$WORK/cron" DEEP_HEALTH_STATE_DIR="$WORK/deep"
export PROJECT_ROOT WORK DEVICES="mic1:31 mic2:32"

# One command of the real script as a fresh process (as from the command line)
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
            reload) reload_mediamtx ;;
            *) "$@" ;;
        esac' _ "$@" >>"$WORK/mgr.out" 2>&1
}

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
field() {
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
wait_bytes_grow() {
    local i
    for ((i = 0; i < 150; i++)); do
        (($(reader_bytes) > $1)) && return 0
        sleep 0.1
    done
    return 1
}
# wait_ready NAME: MediaMTX reports the path ready (at most 30 s)
wait_ready() {
    local i
    for ((i = 0; i < 120; i++)); do
        bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"; probe_stream_ready "$1"' _ "$1" >/dev/null 2>&1 && return 0
        sleep 0.25
    done
    return 1
}
# edit the generated configuration the way an older generator version or an
# operator would have left it (atomic replace; MediaMTX applies it by itself)
edit_config() {
    sed -E "$1" "$WORK/cfg/mediamtx.yml" >"$WORK/cfg/mediamtx.yml.edit"
    mv -f "$WORK/cfg/mediamtx.yml.edit" "$WORK/cfg/mediamtx.yml"
}
# run `mgr reload` in the background; sets RELOAD_RC and STALL, the longest time
# the reader's file did not grow while it ran, in tenths of a second
longest_stall() {
    local last stall=0 worst=0 now
    mgr reload &
    local pid=$!
    last="$(reader_bytes)"
    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.1
        now="$(reader_bytes)"
        if ((now > last)); then
            stall=0
        else
            stall=$((stall + 1))
        fi
        ((stall > worst)) && worst=$stall
        last=$now
    done
    RELOAD_RC=0
    wait "$pid" || RELOAD_RC=$?
    STALL=$worst
}

# --- the node is up ---------------------------------------------------------------
note "start"
mgr start || {
    cat "$WORK/mgr.out"
    fail "the first start failed"
}
S1="$(state)"
note "state: $S1"
(exec -a ffmpeg "$REAL_FFMPEG" -nostdin -loglevel error -analyzeduration 500000 -probesize 100000 \
    -rtsp_transport tcp -i rtsp://localhost:8554/mic1 -c copy -flush_packets 1 -f ogg \
    "$WORK/reader.ogg" >"$WORK/reader.log" 2>&1) &
READER=$!
wait_bytes_grow 0 || fail "the reader received nothing"

# --- reload with nothing to change -----------------------------------------------------
: >"$WORK/mgr.out"
longest_stall
[[ "$RELOAD_RC" == 0 ]] || {
    cat "$WORK/mgr.out"
    fail "reload exited $RELOAD_RC on a healthy node"
}
[[ "$(state)" == "$S1" ]] || fail "reload changed the PIDs: before [$S1], after [$(state)]"
grep -q "configuration is unchanged" "$WORK/mgr.out" || {
    cat "$WORK/mgr.out"
    fail "reload did not say the configuration is unchanged"
}
alive "$READER" || fail "the reader died during an unchanged reload"
((STALL < 30)) || fail "the reader's stream stalled for $STALL tenths of a second during an unchanged reload"
note "reload, nothing to change: same PIDs, the reader never stalled more than ${STALL} tenths of a second"

# --- reload that applies a change publishers survive ---------------------------------------
edit_config 's/^hls: no/hls: yes/'
sleep 1.5
alive "$(field mtx "$S1" | cut -d: -f1)" || fail "MediaMTX died when the file changed"
: >"$WORK/mgr.out"
longest_stall
[[ "$RELOAD_RC" == 0 ]] || {
    cat "$WORK/mgr.out"
    fail "reload exited $RELOAD_RC after a configuration change"
}
grep -q "key 'hls' changed: applied live by MediaMTX; connected publishers stay connected" "$WORK/mgr.out" || {
    cat "$WORK/mgr.out"
    fail "reload did not report the changed key and its effect"
}
grep -q "it was not restarted" "$WORK/mgr.out" || fail "reload did not say MediaMTX was not restarted"
grep -q "^hls: no" "$WORK/cfg/mediamtx.yml" || fail "reload did not restore the generated configuration"
[[ "$(state)" == "$S1" ]] || fail "reload with a publisher-safe change changed the PIDs: before [$S1], after [$(state)]"
alive "$READER" || fail "the reader (a publisher-safe change) died"
((STALL < 30)) || fail "the reader's stream stalled for $STALL tenths of a second while a publisher-safe change was applied"
note "reload, hls changed back: applied, same PIDs, the reader never stalled more than ${STALL} tenths of a second"

# --- reload that applies a change that disconnects the publishers ----------------------------
edit_config 's/^logLevel: info/logLevel: warn/'
sleep 2
alive "$(field mtx "$S1" | cut -d: -f1)" || fail "MediaMTX died when logLevel changed"
: >"$WORK/mgr.out"
mgr reload || {
    cat "$WORK/mgr.out"
    fail "reload exited non-zero after a logLevel change"
}
grep -q "key 'logLevel' changed: applied live by MediaMTX, which disconnects every publisher" "$WORK/mgr.out" || {
    cat "$WORK/mgr.out"
    fail "reload did not say that a logLevel change disconnects the publishers"
}
wait_ready mic1 || fail "mic1 did not come back after the publishers were disconnected"
wait_ready mic2 || fail "mic2 did not come back after the publishers were disconnected"
S3="$(state)"
[[ "$(field mtx "$S3")" == "$(field mtx "$S1")" ]] || fail "MediaMTX was restarted"
# (a wrapper whose FFmpeg lost its publisher connection either reconnects it itself or is
# started again by the reload's reconcile step: which one depends on the wrapper
# generation, not on reload, so the wrapper PIDs are not compared here)
note "reload, logLevel changed back: MediaMTX kept its PID and both streams are ready again"

# --- a dead wrapper is started by reload; the healthy one is not touched ----------------------
W2="$(field mic2 "$S3")"
W2="${W2%%:*}"
for c in $(ps -o pid= --ppid "$W2"); do
    kill -KILL "$c"
done
kill -KILL "$W2"
wait_gone "$W2" || fail "could not kill the wrapper of mic2"
: >"$WORK/mgr.out"
mgr reload || {
    cat "$WORK/mgr.out"
    fail "reload exited non-zero with a dead wrapper"
}
S4="$(state)"
[[ "$(field mtx "$S4")" == "$(field mtx "$S3")" && "$(field mic1 "$S4")" == "$(field mic1 "$S3")" ]] || fail "reload touched MediaMTX or the healthy wrapper: [$S4]"
[[ "$(field mic2 "$S4")" != "$(field mic2 "$S3")" ]] || fail "reload did not start a new wrapper for mic2"
alive "$(field mic2 "$S4" | cut -d: -f1)" || fail "the new mic2 wrapper is not running"
note "reload started the dead mic2 wrapper; MediaMTX and mic1 were not touched"

# --- stopped: reload says so and starts nothing -------------------------------------------------
kill "$READER" 2>/dev/null
mgr stop || fail "stop failed"
: >"$WORK/mgr.out"
rc=0
mgr reload || rc=$?
[[ $rc -eq 7 ]] || {
    cat "$WORK/mgr.out"
    fail "reload with MediaMTX stopped exited $rc, expected 7"
}
grep -q "is not running (use start)" "$WORK/mgr.out" || fail "the refusal does not say what to do"
[[ ! -e "$WORK/mtx.pid" ]] || fail "reload started MediaMTX"
! compgen -G "$WORK/ff/*.pid" >/dev/null || fail "reload started a wrapper"
[[ ! -e "$WORK/cleanup.marker" ]] || fail "a refused reload left the cleanup marker (it would stop the wrappers)"
note "reload with MediaMTX stopped: exit 7, nothing started, no marker"

# --- a MediaMTX this manager did not start: reload is refused and changes nothing -------------------
"$BIN" "$WORK/cfg/mediamtx.yml" >"$WORK/other-mtx.log" 2>&1 &
OTHER=$!
for ((i = 0; i < 100; i++)); do
    curl -s --max-time 1 http://localhost:9997/v3/paths/list >/dev/null && break
    sleep 0.1
done
CFG_BEFORE="$(cat "$WORK/cfg/mediamtx.yml")"
: >"$WORK/mgr.out"
rc=0
mgr reload || rc=$?
[[ $rc -eq 8 ]] || {
    cat "$WORK/mgr.out"
    fail "reload beside a MediaMTX it did not start exited $rc, expected 8"
}
alive "$OTHER" || fail "the other MediaMTX was killed by the refused reload"
[[ "$(cat "$WORK/cfg/mediamtx.yml")" == "$CFG_BEFORE" ]] || fail "the refused reload rewrote the configuration"
[[ ! -e "$WORK/cleanup.marker" ]] || fail "the refused reload left the cleanup marker"
kill "$OTHER"
wait_gone "$OTHER" || fail "could not stop the other MediaMTX"
note "reload beside a foreign MediaMTX: exit 8, nothing touched"

# --- what MediaMTX really does per key: the table in mediamtx_reload_effect is measured here ----------
# A bare MediaMTX with a configuration of this file's own (the keys the manager writes), one
# bare FFmpeg publisher per case; the file is replaced atomically as the generator does it.
hot_conf() { # hot_conf [sed-expression]
    cat >"$WORK/hot.yml.new" <<'Y'
logLevel: info
readTimeout: 30s
writeTimeout: 30s
api: yes
apiAddress: :9997
metrics: yes
metricsAddress: :9998
rtsp: yes
rtspAddress: :8554
rtspTransports: [tcp, udp]
rtmp: no
hls: no
webrtc: no
srt: no
paths:
  '~^[a-zA-Z0-9_-]+$':
    source: publisher
    sourceProtocol: automatic
    sourceOnDemand: no
Y
    [[ -z "${1:-}" ]] || sed -i -E "$1" "$WORK/hot.yml.new"
    mv -f "$WORK/hot.yml.new" "$WORK/hot.yml"
}
hot_pub() {
    "$REAL_FFMPEG" -nostdin -loglevel error -re -f lavfi -i "sine=frequency=440:sample_rate=48000" \
        -c:a libopus -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/hot >"$WORK/hot-pub.log" 2>&1 &
    HOT_PUB=$!
    sleep 1.2
}
hot_effect() { bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"; mediamtx_reload_effect "$1"' _ "$1"; }
hot_conf
"$BIN" "$WORK/hot.yml" >"$WORK/hot-mtx.log" 2>&1 &
HOT=$!
for ((i = 0; i < 100; i++)); do
    curl -s --max-time 1 http://127.0.0.1:9997/v3/paths/list >/dev/null && break
    sleep 0.1
done
# key | sed expression that changes it
while IFS='|' read -r key expr; do
    want_phrase="$(hot_effect "$key")"
    case "$want_phrase" in
        *"stay connected"*) want=kept ;;
        *"disconnects every publisher"* | *"are disconnected"*) want=dropped ;;
        *) fail "mediamtx_reload_effect has no verified answer for '$key': $want_phrase" ;;
    esac
    hot_pub
    hot_conf "$expr"
    sleep 1.6
    alive "$HOT" || fail "MediaMTX exited when '$key' changed"
    got=dropped
    alive "$HOT_PUB" && got=kept
    kill "$HOT_PUB" 2>/dev/null
    wait "$HOT_PUB" 2>/dev/null
    [[ "$got" == "$want" ]] || fail "changing '$key': the publisher was $got, mediamtx_reload_effect says it is $want ($want_phrase)"
    # put the key back (a restarted publisher is needed for the next case anyway)
    hot_conf
    sleep 1
    alive "$HOT" || fail "MediaMTX exited when '$key' was changed back"
done <<'KEYS'
api|s/^api: yes/api: no/
apiAddress|s/^apiAddress: :9997/apiAddress: 127.0.0.1:9997/
rtmp|s/^rtmp: no/rtmp: yes/
hls|s/^hls: no/hls: yes/
webrtc|s/^webrtc: no/webrtc: yes/
srt|s/^srt: no/srt: yes/
logLevel|s/^logLevel: info/logLevel: warn/
readTimeout|s/^readTimeout: 30s/readTimeout: 20s/
writeTimeout|s/^writeTimeout: 30s/writeTimeout: 20s/
metrics|s/^metrics: yes/metrics: no/
metricsAddress|s/^metricsAddress: :9998/metricsAddress: 127.0.0.1:9998/
rtsp|s/^rtsp: yes/rtsp: no/
rtspAddress|s/^rtspAddress: :8554/rtspAddress: 0.0.0.0:8554/
rtspTransports|s/^rtspTransports: .*/rtspTransports: [tcp]/
paths|s/sourceProtocol: automatic/sourceProtocol: tcp/
KEYS
note "every key in mediamtx_reload_effect behaved as it says (a publisher kept or dropped), MediaMTX itself was never restarted"

# A path entry that is added leaves the publishers of the others alone
hot_pub
sed -E 's/^paths:/paths:\n  other:\n    source: publisher/' "$WORK/hot.yml" >"$WORK/hot.yml.new"
mv -f "$WORK/hot.yml.new" "$WORK/hot.yml"
sleep 2
alive "$HOT_PUB" || fail "adding a path entry disconnected a publisher of another path"
kill "$HOT_PUB" 2>/dev/null
wait "$HOT_PUB" 2>/dev/null
hot_conf
sleep 1.5

# A configuration MediaMTX cannot load stops MediaMTX: the reason reload only installs what the generator wrote
printf 'logLevel: [broken\n  nonsense: : :\n' >"$WORK/hot.yml.new"
mv -f "$WORK/hot.yml.new" "$WORK/hot.yml"
wait_gone "$HOT" || fail "MediaMTX survived a configuration file it cannot load"
grep -q "reloading configuration (file changed)" "$WORK/hot-mtx.log" || fail "MediaMTX did not log the reload that stopped it"
note "a configuration file MediaMTX cannot load stops MediaMTX (the reason reload installs only generated files)"
note "DONE"

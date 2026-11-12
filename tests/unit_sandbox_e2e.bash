# shellcheck shell=bash
# shellcheck disable=SC2016 # the `bash -c` programs below are single-quoted on purpose: they expand in the child
# Every path the stream manager writes by default, against the file system the
# unit gives it (tests/test_mediamtx_live.bats runs this file).
#
# It runs inside
#   unshare --net --pid --fork --mount-proc bash tests/unit_sandbox_e2e.bash
# as root, so the default ports are bound in a namespace of its own and nothing
# of the host is touched: /etc, /var, /run, /dev and /usr/local are overlays whose
# upper layers live in WORK, and the manager's temporary files go to WORK/tmp.
#
# The manager runs with its DEFAULT paths (/etc/mediamtx, /var/lib/mediamtx-ffmpeg,
# /var/log, /run, /dev/shm/lyrebird-buffer, ...) and the Environment= of the unit
# under test: the real setup_directories, start (real MediaMTX, real wrappers,
# real FFmpeg), monitor (resource check, level signals, stream check), reload,
# restart and stop, each command in a fresh process. Only the hardware is stood
# in for (the USB device list, the ALSA availability check, two fake /dev/snd
# nodes, an `ffmpeg` that swaps the ALSA capture input for a tone).
#
# Environment: PROJECT_ROOT, BIN (a MediaMTX binary), WORK (an empty scratch
# directory), UNIT_FILE (the unit under test), MODE, OWNER (optional "uid:gid").
#   MODE=audit    nothing is protected; every file the manager creates or changes
#                 is listed, and each must be inside a path the unit makes writable
#                 (ReadWritePaths=, StateDirectory=, RuntimeDirectory=, LogsDirectory=,
#                 CacheDirectory=, the private /tmp, and /dev, which ProtectSystem=strict
#                 leaves alone)
#   MODE=strict   emulation of ProtectSystem=strict: every mount of the file
#                 system tree is made read-only except /dev, /proc and /sys, and
#                 only the paths the unit makes writable are opened again; the
#                 whole run must then work, leave its files and print no "Read-only
#                 file system"
# The negative control runs the same flow with the directives of the sample unit this
# change replaces (no /var/lib/mediamtx-ffmpeg among its writable paths) and must fail.
#
# Prints "E2E: ..." lines and, on the first violated expectation, "E2E-FAIL: ..."
# and exits 1. Exit 77: the namespace cannot do the overlays.

set -u
fail() {
    echo "E2E-FAIL: $*"
    exit 1
}
note() { echo "E2E: $*"; }

trap '[[ -z "${OWNER:-}" ]] || chown -R "$OWNER" "$WORK" 2>/dev/null' EXIT

MODE="${MODE:-strict}"
[[ -r "${UNIT_FILE:-}" ]] || fail "UNIT_FILE is not readable"

python3 -I - <<'PY' || fail "cannot bring the loopback interface up"
import fcntl, socket, struct
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
flags = struct.unpack('16sH', fcntl.ioctl(s.fileno(), 0x8913, struct.pack('16sH', b'lo', 0)))[1]
fcntl.ioctl(s.fileno(), 0x8914, struct.pack('16sH', b'lo', flags | 1))
PY

REAL_FFMPEG="$(command -v ffmpeg)"
mkdir -p "$WORK/ov" "$WORK/tmp"

# --- overlays: nothing written here reaches the host -----------------------------------
mount --make-rprivate / || fail "cannot make the mount tree private"
for d in etc var run dev usr-local; do
    mkdir -p "$WORK/ov/$d-up" "$WORK/ov/$d-work"
done
overlay() { # overlay NAME DIR
    mount -t overlay overlay -o "lowerdir=$2,upperdir=$WORK/ov/$1-up,workdir=$WORK/ov/$1-work" "$2"
}
overlay dev /dev || {
    echo "E2E-SKIP: cannot overlay /dev in this namespace"
    exit 77
}
overlay usr-local /usr/local || {
    echo "E2E-SKIP: cannot overlay /usr/local in this namespace"
    exit 77
}
for pair in etc:/etc var:/var run:/run; do
    overlay "${pair%%:*}" "${pair#*:}" || {
        echo "E2E-SKIP: cannot overlay ${pair#*:} in this namespace"
        exit 77
    }
done

# --- hardware stand-ins and the program files of a node ------------------------------------
mkdir -p /dev/snd
: >/dev/snd/controlC31
: >/dev/snd/pcmC31D0c
: >/dev/snd/controlC32
: >/dev/snd/pcmC32D0c
mkdir -p /usr/local/bin /usr/local/sbin
cp "$BIN" /usr/local/bin/mediamtx
cat >/usr/local/sbin/ffmpeg <<SHIM
#!/bin/bash
# Stand-in for the capture device only: an ALSA input becomes a tone; the real
# ffmpeg does everything else (encoding, RTSP publishing, the local recording)
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
chmod +x /usr/local/sbin/ffmpeg /usr/local/bin/mediamtx

# --- what the unit declares ---------------------------------------------------------------
declare -a RW=() CREATE=()
unit_paths() {
    local line name p
    while IFS= read -r line; do
        case "$line" in
            ReadWritePaths=*)
                for p in ${line#ReadWritePaths=}; do
                    if [[ "$p" == -* ]]; then
                        p="${p#-}"
                        [[ -e "$p" ]] || continue
                    fi
                    RW+=("$p")
                done
                ;;
            StateDirectory=*) for name in ${line#StateDirectory=}; do CREATE+=("/var/lib/$name"); done ;;
            RuntimeDirectory=*) for name in ${line#RuntimeDirectory=}; do CREATE+=("/run/$name"); done ;;
            LogsDirectory=*) for name in ${line#LogsDirectory=}; do CREATE+=("/var/log/$name"); done ;;
            CacheDirectory=*) for name in ${line#CacheDirectory=}; do CREATE+=("/var/cache/$name"); done ;;
            ConfigurationDirectory=*) for name in ${line#ConfigurationDirectory=}; do mkdir -p "/etc/$name"; done ;;
            *) ;;
        esac
    done <"$UNIT_FILE"
}
unit_paths
# systemd creates the state, runtime, logs and cache directories before the process starts
# (and they are writable); /etc/mediamtx exists on a node MediaMTX was installed on
mkdir -p /etc/mediamtx
for p in ${CREATE[@]+"${CREATE[@]}"}; do
    mkdir -p "$p"
    RW+=("$p")
done
note "writable according to the unit: ${RW[*]}"

# The unit's Environment= lines, as systemd would hand them to the process
declare -a UNIT_ENV=()
while IFS= read -r line; do
    case "$line" in
        'Environment="'*)
            line="${line#Environment=\"}"
            line="${line%\"}"
            line="$(printf '%s' "$line" | sed -e 's/%%/%/g' -e 's/\\"/"/g' -e 's/\\\\/\\/g')"
            UNIT_ENV+=("$line")
            ;;
        *) ;;
    esac
done <"$UNIT_FILE"

# --- ProtectSystem=strict ----------------------------------------------------------------------
if [[ "$MODE" == strict ]]; then
    # the private /tmp the unit has, and this run's scratch directory (outputs of the harness)
    # (outer paths first: a bind mount of a directory hides the bind mounts made below it earlier)
    declare -a OPEN=()
    mapfile -t OPEN < <(printf '%s\n' /tmp "$WORK" "${RW[@]}" | awk '{print length($0) " " $0}' | sort -n | cut -d' ' -f2- | awk '!seen[$0]++')
    for p in "${OPEN[@]}"; do
        [[ -d "$p" ]] || continue
        mount --bind "$p" "$p" || fail "cannot bind $p"
    done
    # every mount that existed before the binds above, except the API file systems
    mapfile -t MPS < <(awk '{print $5}' /proc/self/mountinfo | grep -v -E '^/(proc|sys|dev)(/|$)' | sort -u)
    for mp in "${MPS[@]}"; do
        mount -o remount,bind,ro "$mp" 2>/dev/null || true
    done
    # the bind mounts made above are separate mounts: they stay writable (their own flags)
    for p in "${OPEN[@]}"; do
        [[ -d "$p" ]] || continue
        mount -o remount,bind,rw "$p" || fail "cannot reopen $p"
    done
    for p in /etc/lyrebird-sandbox-probe /usr/local/lyrebird-sandbox-probe /var/lib/lyrebird-sandbox-probe /lyrebird-sandbox-probe; do
        if touch "$p" 2>/dev/null; then
            rm -f "$p"
            fail "the emulation does not make ${p%/*}/ read-only"
        fi
    done
    for p in "${RW[@]}"; do
        touch "$p/.sandbox-probe" 2>/dev/null || fail "the emulation does not leave $p writable"
        rm -f "$p/.sandbox-probe"
    done
    note "ProtectSystem=strict emulated: / is read-only, /dev /proc /sys and the declared paths are not"
fi
touch "$WORK/marker"
# what the overlays' upper layers hold after the set-up: whatever shows up in them later was
# created, or opened for writing (which copies a file up), by the manager
for d in etc var run dev; do
    (cd "$WORK/ov/$d-up" && find . -mindepth 1 -printf '%P\n' | sort) >"$WORK/upper-before.$d"
done
sleep 1

# --- the manager, with its defaults and the unit's environment -------------------------------------
export PROJECT_ROOT WORK DEVICES="mic1:31 mic2:32"
mgr() {
    env -i "${UNIT_ENV[@]}" TMPDIR="$WORK/tmp" PROJECT_ROOT="$PROJECT_ROOT" DEVICES="$DEVICES" \
        AUDIO_LOCAL_RECORDING=true STREAM_STARTUP_DELAY=0 STREAM_VALIDATION_DELAY=1 STREAM_VALIDATION_ATTEMPTS=5 \
        USB_STABILIZATION_DELAY=1 RESTART_STABILIZATION_DELAY=1 MEDIAMTX_API_TIMEOUT=30 INITIAL_RESTART_DELAY=1 \
        bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh"
        detect_audio_devices() { printf "%s\n" $DEVICES; }
        wait_for_usb_stabilization() { return 0; }
        check_audio_device() { return 0; }
        COMMAND="$1"
        trap cleanup EXIT INT TERM
        cd /var/lib/lyrebird 2>/dev/null || cd /
        case "$1" in
            setup) setup_directories ;;
            start) setup_directories; start_mediamtx ;;
            stop) stop_mediamtx ;;
            restart) restart_mediamtx ;;
            reload) setup_directories; reload_mediamtx ;;
            monitor)
                setup_directories
                check_all_resources || true
                monitor_signals || true
                monitor_streams || true
                ;;
            *) "$@" ;;
        esac' _ "$@" >>"$WORK/mgr.out" 2>&1
}
step() { # step NAME COMMAND: run one manager command, stop at the first failure
    local name="$1"
    shift
    note "$name"
    mgr "$@" || {
        tail -40 "$WORK/mgr.out"
        fail "$name failed"
    }
}

wait_ready() {
    local i
    for ((i = 0; i < 120; i++)); do
        env -i "${UNIT_ENV[@]}" PROJECT_ROOT="$PROJECT_ROOT" bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"; probe_stream_ready "$1"' _ "$1" >/dev/null 2>&1 && return 0
        sleep 0.25
    done
    return 1
}

# the files and directories the manager created or changed since the set-up, appended to written.list
collect_written() {
    local pair up base
    [[ "$MODE" == audit ]] || return 0
    for pair in etc:/etc var:/var run:/run dev:/dev; do
        up="$WORK/ov/${pair%%:*}-up"
        base="${pair#*:}"
        # new in the upper layer (created, or copied up because it was opened for writing) ...
        (cd "$up" && find . -mindepth 1 -printf '%P\n' | sort) | comm -13 "$WORK/upper-before.${pair%%:*}" - | sed "s#^#$base/#" >>"$WORK/written.list"
        # ... or changed since the set-up
        (cd "$up" && find . -type f -newer "$WORK/marker" -printf '%P\n') | sed "s#^#$base/#" >>"$WORK/written.list"
    done
}
: >"$WORK/written.list"

step "start" start
wait_ready mic1 || fail "mic1 is not ready after start"
step "monitor (resource check, level signals, stream check)" monitor
sleep 1
step "second monitor" monitor
step "reload" reload
step "restart" restart
wait_ready mic1 || fail "mic1 is not ready after the restart"
step "monitor after the restart" monitor
collect_written
step "stop" stop
collect_written

if grep -q "Read-only file system" "$WORK/mgr.out"; then
    grep -n "Read-only file system" "$WORK/mgr.out" | head
    fail "the manager hit a read-only file system"
fi

# --- what was written ------------------------------------------------------------------------------------
if [[ "$MODE" == audit ]]; then
    sort -u "$WORK/written.list" -o "$WORK/written.list"
    n=0
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        # /dev is not read-only under ProtectSystem=strict; /tmp is the unit's private one
        [[ "$path" == /dev/* ]] && continue
        ok=false
        for p in "${RW[@]}"; do
            if [[ "$path" == "$p" || "$path" == "$p"/* ]]; then
                ok=true
            fi
            # a parent directory shows up in the upper layer when a path below it is created
            if [[ -d "$path" && "$p" == "$path"/* ]]; then
                ok=true
            fi
        done
        if [[ "$ok" != true ]]; then
            fail "the manager wrote $path, which the unit does not make writable (writable: ${RW[*]})"
        fi
        n=$((n + 1))
    done <"$WORK/written.list"
    ((n > 0)) || fail "no file written: the audit saw nothing"
    note "the manager wrote $n paths, all inside the unit's writable paths"
    sed 's#/[^/]*$##' "$WORK/written.list" | sort | uniq -c | sort -rn | sed 's/^/E2E:   /' | head -30
    # the paths the register names are among them
    for want in /run/mediamtx-audio.pid /run/mediamtx-audio.lock /run/mediamtx-audio.heartbeat \
        /etc/mediamtx/mediamtx.yml /var/log/lyrebird-stream-manager.log /var/lib/mediamtx-ffmpeg/mic1.sh \
        /var/lib/mediamtx-ffmpeg/mic1.log; do
        grep -qxF "$want" "$WORK/written.list" || fail "$want was not written (the audit missed a path)"
    done
    grep -q '^/run/lyrebird/' "$WORK/written.list" || fail "nothing was written under /run/lyrebird"
    grep -q '^/dev/shm/lyrebird-buffer/' "$WORK/written.list" || fail "the local recording was not written to /dev/shm/lyrebird-buffer"
else
    # strict: what has to exist after a run that was allowed to write only what the unit declares
    for want in /run/mediamtx-audio.lock /run/mediamtx-audio.heartbeat /etc/mediamtx/mediamtx.yml \
        /etc/mediamtx/audio-devices.conf /var/log/lyrebird-stream-manager.log \
        /var/lib/mediamtx-ffmpeg/mic1.log /run/lyrebird/silence/mic1.state; do
        [[ -e "$want" ]] || fail "$want does not exist after a run under ProtectSystem=strict"
    done
    ls /dev/shm/lyrebird-buffer/mic1/audio_000.* >/dev/null 2>&1 || fail "no local recording under /dev/shm/lyrebird-buffer"
    note "start, monitor, reload, restart and stop worked with only the declared paths writable, and left their files"
fi
note "DONE"

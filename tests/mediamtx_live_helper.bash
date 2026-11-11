# shellcheck shell=bash
# Helpers for tests that start a real MediaMTX binary (decision D15).
#
# Nothing here binds a default port (8554, 9997, 9998, 8000, 8001, 8890-8893):
# each test gets its own free ports, and every other port MediaMTX could open
# by default (the two UDP ports of RTSP, RTMP, HLS, WebRTC, SRT, MoQ) is moved
# with MediaMTX's own environment overrides to a spare port, so even a
# configuration with a defect cannot take a default port of the machine. Set
# LYREBIRD_TEST_PORT_BASE to pin the ports to BASE..BASE+19 instead (one test
# at a time).
#
# Usage: load mediamtx_live_helper; call mtx_ports_setup in the test, then
# mtx_render / mtx_start / mtx_stop / mtx_publish / ...; call mtx_cleanup in
# teardown. The test must call scratch_setup first (tests/scratch_tmpdir.bash):
# the logs and configuration files go to $TEST_SCRATCH.

MTX_PID=""
PUB_PID=""
STUB_PID=""

# Allocate the ports of this test: P_RTSP P_API P_METRICS (TCP), P_RTP P_RTCP
# (an adjacent UDP pair) and P_SPARE1..P_SPARE8 (TCP numbers, used to move
# MediaMTX's other listeners out of the way).
mtx_ports_setup() {
    local ports
    if [[ -n "${LYREBIRD_TEST_PORT_BASE:-}" ]]; then
        local b=$LYREBIRD_TEST_PORT_BASE
        ports="$b $((b + 1)) $((b + 2)) $((b + 10)) $((b + 11))"
        ports+=" $((b + 3)) $((b + 4)) $((b + 5)) $((b + 6)) $((b + 7)) $((b + 8)) $((b + 9)) $((b + 12))"
    else
        ports="$(
            python3 -I - <<'PY'
import random, socket
held = []
def tcp():
    s = socket.socket(); s.bind(("0.0.0.0", 0)); held.append(s); return s.getsockname()[1]
out = [tcp(), tcp(), tcp()]
while True:
    p = random.randrange(20000, 60000, 2)
    pair = []
    try:
        for q in (p, p + 1):
            u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.bind(("0.0.0.0", q)); pair.append(u)
    except OSError:
        for u in pair: u.close()
        continue
    held.extend(pair)
    out += [p, p + 1]
    break
out += [tcp() for _ in range(8)]
print(*out)
PY
        )"
    fi
    read -r P_RTSP P_API P_METRICS P_RTP P_RTCP P_SPARE1 P_SPARE2 P_SPARE3 P_SPARE4 P_SPARE5 P_SPARE6 P_SPARE7 P_SPARE8 <<<"$ports"
    export P_RTSP P_API P_METRICS P_RTP P_RTCP P_SPARE1 P_SPARE2 P_SPARE3 P_SPARE4 P_SPARE5 P_SPARE6 P_SPARE7 P_SPARE8
}

# The first non-loopback IPv4 address of this machine (what a remote client
# would connect to); fails when there is none.
nonloopback_addr() {
    local a
    for a in $(hostname -I 2>/dev/null); do
        [[ "$a" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$a" != 127.* ]] && {
            printf '%s\n' "$a"
            return 0
        }
    done
    a="$(python3 -I -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.connect(("192.0.2.1", 9))
print(s.getsockname()[0])' 2>/dev/null)" || return 1
    [[ -n "$a" && "$a" != 127.* ]] || return 1
    printf '%s\n' "$a"
}

# mtx_version BIN: the first line of `BIN --version` (e.g. v1.21.1)
mtx_version() {
    "$1" --version 2>/dev/null | head -n 1
}

# mtx_render BIN [renderer options]: render the configuration for BIN's
# version on this test's ports into $TEST_SCRATCH/mediamtx.yml (later options
# override these defaults)
mtx_render() {
    local bin="$1" version
    shift
    version="$(mtx_version "$bin")"
    lyrebird_render_mediamtx_config --mediamtx-version "$version" \
        --rtsp-port "$P_RTSP" --api-port "$P_API" --metrics-port "$P_METRICS" "$@" \
        >"$TEST_SCRATCH/mediamtx.yml"
}

# mtx_start BIN CONFIG [VAR=value ...]: run MediaMTX on CONFIG with all of its
# other listeners moved to this test's spare ports, then wait (at most ~10 s)
# for the TCP port $MTX_WAIT_PORT (default P_API) to accept connections, and
# check that the process is still up a moment later. Sets MTX_PID; the output
# goes to $TEST_SCRATCH/mediamtx.log.
mtx_start() {
    local bin="$1" conf="$2" i up=false
    shift 2
    (cd "$TEST_SCRATCH" && exec env \
        "MTX_RTPADDRESS=:${P_RTP}" "MTX_RTCPADDRESS=:${P_RTCP}" \
        "MTX_RTMPADDRESS=:${P_SPARE1}" "MTX_HLSADDRESS=:${P_SPARE2}" "MTX_WEBRTCADDRESS=:${P_SPARE3}" \
        "MTX_WEBRTCLOCALUDPADDRESS=:${P_SPARE4}" "MTX_SRTADDRESS=:${P_SPARE5}" \
        "MTX_MOQHTTP2ADDRESS=:${P_SPARE6}" "MTX_MOQHTTP3ADDRESS=:${P_SPARE6}" "MTX_MOQQUICADDRESS=:${P_SPARE7}" \
        "$@" "$bin" "$conf") >"$TEST_SCRATCH/mediamtx.log" 2>&1 3>&- &
    MTX_PID=$!
    for ((i = 0; i < 50; i++)); do
        if (exec 4<>"/dev/tcp/127.0.0.1/${MTX_WAIT_PORT:-$P_API}") 2>/dev/null; then
            up=true
            break
        fi
        kill -0 "$MTX_PID" 2>/dev/null || break
        sleep 0.2
    done
    if [[ "$up" == true ]]; then
        sleep 0.5
        kill -0 "$MTX_PID" 2>/dev/null && return 0
    fi
    echo "MediaMTX ($bin) did not come up or did not stay up:"
    cat "$TEST_SCRATCH/mediamtx.log"
    return 1
}

mtx_stop() {
    if [[ -n "$MTX_PID" ]]; then
        kill "$MTX_PID" 2>/dev/null || true
        wait "$MTX_PID" 2>/dev/null || true
        MTX_PID=""
    fi
}

# mtx_listeners PID: one "proto address:port" line per listening TCP socket and
# every UDP socket of the process, sorted. A socket on the IPv6 wildcard
# address (what a dual-stack listener on ":port" is) is listed as 0.0.0.0, so
# the answer does not depend on whether the machine has IPv6.
mtx_listeners() {
    python3 -I - "$1" <<'PY'
import os, sys
pid = sys.argv[1]
inodes = set()
for fd in os.listdir("/proc/%s/fd" % pid):
    try:
        link = os.readlink("/proc/%s/fd/%s" % (pid, fd))
    except OSError:
        continue
    if link.startswith("socket:["):
        inodes.add(link[8:-1])
def addr(hexaddr):
    if len(hexaddr) == 8:
        return ".".join(map(str, bytes.fromhex(hexaddr)[::-1]))
    if hexaddr == "0" * 32:
        return "0.0.0.0"
    return "v6:" + hexaddr
out = set()
for proto, path, state in (("tcp", "/proc/net/tcp", "0A"), ("udp", "/proc/net/udp", None),
                           ("tcp", "/proc/net/tcp6", "0A"), ("udp", "/proc/net/udp6", None)):
    if not os.path.exists(path):
        continue
    for line in open(path).read().splitlines()[1:]:
        c = line.split()
        if c[9] in inodes and (state is None or c[3] == state):
            host, port = c[1].split(":")
            out.add("%s %s:%d" % (proto, addr(host), int(port, 16)))
print("\n".join(sorted(out)))
PY
}

# mtx_publish URL: publish a sine wave to URL in the background (PUB_PID)
mtx_publish() {
    ffmpeg -nostdin -loglevel error -re -f lavfi -i sine=frequency=440:sample_rate=48000 \
        -c:a aac -f rtsp -rtsp_transport tcp "$1" >"$TEST_SCRATCH/publisher.log" 2>&1 3>&- &
    PUB_PID=$!
}

mtx_unpublish() {
    if [[ -n "$PUB_PID" ]]; then
        kill "$PUB_PID" 2>/dev/null || true
        wait "$PUB_PID" 2>/dev/null || true
        PUB_PID=""
    fi
}

# mtx_publish_once URL: publish two seconds of sine to URL and return ffmpeg's
# status (non-zero when MediaMTX refused the publisher); its messages are
# left in $TEST_SCRATCH/publish-once.log
mtx_publish_once() {
    ffmpeg -nostdin -loglevel error -re -f lavfi -t 2 -i sine=frequency=440:sample_rate=48000 \
        -c:a aac -f rtsp -rtsp_transport tcp "$1" >"$TEST_SCRATCH/publish-once.log" 2>&1 3>&-
}

# mtx_can_read URL: can a client read stream URL? (ffprobe finds an audio track)
mtx_can_read() {
    local out
    out="$(timeout 25 ffprobe -v error -rtsp_transport tcp -show_entries stream=codec_name -of csv=p=0 "$1" 2>"$TEST_SCRATCH/read.err")" || return 1
    [[ -n "$out" ]]
}

# mtx_wait_path_ready PATH [SECONDS]: wait until the API (reached from this
# machine) lists PATH as ready
mtx_wait_path_ready() {
    local i limit="${2:-10}"
    for ((i = 0; i < limit * 5; i++)); do
        if curl -s --max-time 2 "http://127.0.0.1:${P_API}/v3/paths/get/$1" 2>/dev/null | grep -q '"ready":true'; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

# mtx_http_status URL [curl args]: the HTTP status, or 000 when there is none
mtx_http_status() {
    local url="$1"
    shift
    curl -s -o /dev/null --max-time 3 -w '%{http_code}' "$@" "$url" 2>/dev/null || true
}

# stub_start PORT: the API stand-in (tests/helpers/mediamtx/http_stub.py) on
# 127.0.0.1:PORT, answering as $TEST_SCRATCH/stub-plan.json says (see the file
# for the format); requests are logged to $TEST_SCRATCH/stub.log
stub_start() {
    local port="$1" i
    rm -f "$TEST_SCRATCH/stub-ready"
    [[ -f "$TEST_SCRATCH/stub-plan.json" ]] || echo '{}' >"$TEST_SCRATCH/stub-plan.json"
    : >"$TEST_SCRATCH/stub.log"
    python3 -I "$PROJECT_ROOT/tests/helpers/mediamtx/http_stub.py" "$port" \
        "$TEST_SCRATCH/stub-plan.json" "$TEST_SCRATCH/stub.log" "$TEST_SCRATCH/stub-ready" 3>&- &
    STUB_PID=$!
    for ((i = 0; i < 50; i++)); do
        [[ -e "$TEST_SCRATCH/stub-ready" ]] && return 0
        sleep 0.1
    done
    echo "stub server did not start"
    return 1
}

# stub_plan JSON: replace the stand-in's answers
stub_plan() {
    printf '%s' "$1" >"$TEST_SCRATCH/stub-plan.json.new"
    mv -f "$TEST_SCRATCH/stub-plan.json.new" "$TEST_SCRATCH/stub-plan.json"
}

stub_stop() {
    if [[ -n "$STUB_PID" ]]; then
        kill "$STUB_PID" 2>/dev/null || true
        wait "$STUB_PID" 2>/dev/null || true
        STUB_PID=""
    fi
}

# Stop everything this helper started (call from teardown)
mtx_cleanup() {
    mtx_unpublish
    mtx_stop
    stub_stop
}

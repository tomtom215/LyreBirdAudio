# shellcheck shell=bash
# Helpers for tests that start a real MediaMTX binary (decision D15).
#
# Nothing here binds a default port (8554, 9997, 9998, 8000, 8001, 8890-8893):
# each test gets its own free ports, and MediaMTX's two UDP ports (RTP/RTCP,
# which the generated configuration leaves at their defaults) are moved with
# MediaMTX's own environment overrides. Set LYREBIRD_TEST_PORT_BASE to pin the
# ports to BASE..BASE+11 instead (one test at a time).
#
# Usage: load mediamtx_live_helper; call mtx_ports_setup in the test, then
# mtx_start / mtx_stop / mtx_publish / ...; call mtx_cleanup in teardown.
#
# The test using these helpers must call scratch_setup first (tests/
# scratch_tmpdir.bash): the logs and configuration files go to $TEST_SCRATCH.

MTX_PID=""
PUB_PID=""
STUB_PID=""

# Allocate the ports of this test: P_RTSP P_API P_METRICS P_RTP P_RTCP and
# three spare TCP ports P_SPARE1..3.
mtx_ports_setup() {
    local ports
    if [[ -n "${LYREBIRD_TEST_PORT_BASE:-}" ]]; then
        local b=$LYREBIRD_TEST_PORT_BASE
        ports="$b $((b + 1)) $((b + 2)) $((b + 10)) $((b + 11)) $((b + 3)) $((b + 4)) $((b + 5))"
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
out += [tcp(), tcp(), tcp()]
print(*out)
PY
        )"
    fi
    read -r P_RTSP P_API P_METRICS P_RTP P_RTCP P_SPARE1 P_SPARE2 P_SPARE3 <<<"$ports"
    export P_RTSP P_API P_METRICS P_RTP P_RTCP P_SPARE1 P_SPARE2 P_SPARE3
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

# mtx_start BIN CONFIG [extra env VAR=value ...]: run MediaMTX on CONFIG with
# its RTP/RTCP ports moved to this test's, then wait (at most ~10 s) until it
# stays up and its API answers (200 or 401) on P_API. Sets MTX_PID; the output
# goes to $TEST_SCRATCH/mediamtx.log.
mtx_start() {
    local bin="$1" conf="$2" i code
    shift 2
    (cd "$TEST_SCRATCH" && exec env "MTX_RTPADDRESS=:${P_RTP}" "MTX_RTCPADDRESS=:${P_RTCP}" "$@" "$bin" "$conf") \
        >"$TEST_SCRATCH/mediamtx.log" 2>&1 3>&- &
    MTX_PID=$!
    for ((i = 0; i < 50; i++)); do
        code="$(curl -s -o /dev/null --max-time 1 -w '%{http_code}' "http://127.0.0.1:${P_API}/v3/paths/list" 2>/dev/null)" || code=000
        [[ "$code" == 200 || "$code" == 401 ]] && return 0
        kill -0 "$MTX_PID" 2>/dev/null || break
        sleep 0.2
    done
    echo "MediaMTX ($bin) did not come up:"
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
# every UDP socket of the process, sorted. IPv6 sockets are listed as v6.
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
    return "v6:" + hexaddr
out = []
for proto, path, state in (("tcp", "/proc/net/tcp", "0A"), ("udp", "/proc/net/udp", None),
                           ("tcp6", "/proc/net/tcp6", "0A"), ("udp6", "/proc/net/udp6", None)):
    if not os.path.exists(path):
        continue
    for line in open(path).read().splitlines()[1:]:
        c = line.split()
        if c[9] in inodes and (state is None or c[3] == state):
            host, port = c[1].split(":")
            out.append("%s %s:%d" % (proto, addr(host), int(port, 16)))
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
    out="$(timeout 10 ffprobe -v error -rtsp_transport tcp -show_entries stream=codec_name -of csv=p=0 "$1" 2>"$TEST_SCRATCH/read.err")" || return 1
    [[ -n "$out" ]]
}

# mtx_wait_path_ready PATH [SECONDS]: wait until the API lists PATH as ready
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

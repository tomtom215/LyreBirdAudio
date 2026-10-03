#!/usr/bin/env bats
# tools/soak/lyrebird-soak-observer.sh: report logic on synthetic logs (always),
# and the reader against real MediaMTX (when LYREBIRD_TEST_MEDIAMTX_BINS is
# set). The observer must also run under bash 3.2 (macOS); set
# LYREBIRD_TEST_BASH32 to a bash 3.2 binary to run these tests with it.

load scratch_tmpdir

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    OBS="$PROJECT_ROOT/tools/soak/lyrebird-soak-observer.sh"
    OBS_BASH="${LYREBIRD_TEST_BASH32:-bash}"
    D="$TEST_SCRATCH/obs"
    mkdir -p "$D"
    SUPERVISORS=()
}

teardown() {
    touch "$TEST_SCRATCH/stop" "$D/stop"
    local p
    for p in "${SUPERVISORS[@]}"; do
        pkill -CONT -P "$p" 2>/dev/null || true
        pkill -P "$p" 2>/dev/null || true
        kill "$p" 2>/dev/null || true
        wait "$p" 2>/dev/null || true
    done
    # Let killed MediaMTX/ffmpeg exit before the next test checks for them.
    local i
    for i in $(seq 1 50); do
        pgrep -x mediamtx >/dev/null || pgrep -f '^ffmpeg.*rtsp://127.0.0.1:8554/' >/dev/null || break
        sleep 0.1
    done
    scratch_teardown
}

obs() { "$OBS_BASH" "$OBS" "$@"; }

# synth STREAMS SECONDS [AWK]: one audio line per stream per second from
# t=1790000000; AWK may set skip=1 to drop a line (t, s, h set) or print extra.
synth() {
    local i
    : >"$D/streams"
    for ((i = 1; i <= $1; i++)); do printf '%d\trtsp://node:8554/mic_%d\n' "$i" "$i" >>"$D/streams"; done
    awk -v n="$1" -v secs="$2" 'BEGIN {
        OFS = "\t"; print "wall", "stream", "event", "value"
        for (x = 0; x <= secs; x++) {
            t = 1790000000 + x
            '"${3:-}"'
            for (s = 1; s <= n; s++) { skip = 0; '"${4:-}"'; if (!skip) print t, s, "audio", x }
        }
    }' >"$D/observer.tsv"
}

report_all_awks() {
    local a out first="" rc rc_first=""
    for a in gawk mawk original-awk "busybox awk"; do
        command -v "${a%% *}" >/dev/null || continue
        mkdir -p "$TEST_SCRATCH/awk"
        printf '#!/bin/sh\nexec %s "$@"\n' "$a" >"$TEST_SCRATCH/awk/awk"
        chmod +x "$TEST_SCRATCH/awk/awk"
        rc=0
        out=$(PATH="$TEST_SCRATCH/awk:$PATH" obs report --dir "$D" "$@" 2>&1) || rc=$?
        if [[ -z "$rc_first" ]]; then
            first="$out" rc_first=$rc
        elif [[ "$out" != "$first" || "$rc" != "$rc_first" ]]; then
            echo "awk '$a' disagrees"
            diff <(echo "$first") <(echo "$out") || true
            return 99
        fi
    done
    printf '%s\n' "$first"
    return "$rc_first"
}

@test "observer report: continuous audio passes, under every awk" {
    synth 2 3600
    run report_all_awks
    [ "$status" -eq 0 ]
    [[ "$output" == *"gaps > 5s: 0 (0 not explained"* ]]
    [[ "$output" == *"RESULT: PASS"* ]]
}

@test "observer report: an unexplained gap fails and is listed with its length" {
    synth 2 3600 '' 'if (s == 2 && x > 1000 && x < 1020) skip = 1'
    run report_all_awks
    [ "$status" -eq 1 ]
    [[ "$output" == *"gaps > 5s: 1 (1 not explained"* ]]
    [[ "$output" == *"  20s"* ]]
    [[ "$output" == *"FAIL   1 unexplained gap(s)"* ]]
    # Shorter than --gap is not a gap.
    run report_all_awks --gap 30
    [ "$status" -eq 0 ]
}

@test "observer report: a gap during a power cut is expected; time to audio is measured and enforced" {
    synth 1 3600 'if (x == 1000) print t, "-", "power_off", "cut 1"; if (x == 1030) print t, "-", "power_on", "cut 1"' \
        'if (x >= 1000 && x < 1090) skip = 1'
    run report_all_awks --boot-deadline 120
    [ "$status" -eq 0 ]
    [[ "$output" == *"stream 1: 60"* ]]
    [[ "$output" == *"PASS   audio back within 120s"* ]]
    run report_all_awks --boot-deadline 30
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL   1 stream restart(s) after power-on took longer than 30s"* ]]
}

@test "observer report: the node's fault windows explain gaps" {
    synth 1 3600 '' 'if (x >= 2000 && x < 2040) skip = 1'
    printf 'wall\tuptime\tboot\telapsed\tevent\tdetail\n' >"$D/node-events.tsv"
    printf '1790002000\t1\tb\t1\tfault_start\tkill-mediamtx pid=1\n' >>"$D/node-events.tsv"
    printf '1790002035\t1\tb\t1\trecovered\tkill-mediamtx seconds=35\n' >>"$D/node-events.tsv"
    run report_all_awks
    [ "$status" -eq 1 ]
    run report_all_awks --node-events "$D/node-events.tsv"
    [ "$status" -eq 0 ]
}

@test "observer report: a stream that never delivers, or goes silent at the end, fails" {
    synth 2 600 '' 'if (s == 2) skip = 1'
    run report_all_awks
    [ "$status" -eq 1 ]
    [[ "$output" == *"never received audio"* ]]
    synth 2 600 '' 'if (s == 2 && x > 500) skip = 1'
    run report_all_awks
    [ "$status" -eq 1 ]
    [[ "$output" == *"100s"* ]]
}

@test "observer: argument errors exit 2 with a reason" {
    run obs run --dir "$D"
    [ "$status" -eq 2 ] && [[ "$output" == *"at least one rtsp:// URL"* ]]
    run obs run --dir "$D" http://x/y
    [ "$status" -eq 2 ] && [[ "$output" == *"not an RTSP URL"* ]]
    run obs run --dir "$D" --power-every 60 rtsp://x/y
    [ "$status" -eq 2 ] && [[ "$output" == *"needs --power-off-cmd"* ]]
    run obs run --dir "$D" --timeout 5s rtsp://x/y
    [ "$status" -eq 2 ] && [[ "$output" == *"not a number"* ]]
    run obs run --power-off-for
    [ "$status" -eq 2 ] && [[ "$output" == *"needs a value"* ]]
    run obs report --dir "$TEST_SCRATCH/none"
    [ "$status" -eq 2 ]
    run obs bogus
    [ "$status" -eq 2 ]
}

# --- live -----------------------------------------------------------------------

supervise() {
    local name="$1"
    shift
    (
        cd "$TEST_SCRATCH" || exit 1
        while [[ ! -e "$TEST_SCRATCH/stop" ]]; do
            "$@" >>"$TEST_SCRATCH/$name.log" 2>&1 || true
            sleep 0.5
        done
    ) 3>&- &
    SUPERVISORS+=($!)
}

live_stack() {
    [[ -n "${LYREBIRD_TEST_MEDIAMTX_BINS:-}" ]] || skip "set LYREBIRD_TEST_MEDIAMTX_BINS to run"
    command -v ffmpeg >/dev/null || skip "ffmpeg not installed"
    if pgrep -x mediamtx >/dev/null || pgrep -f '^ffmpeg.*rtsp://' >/dev/null; then
        skip "MediaMTX or an RTSP ffmpeg is already running here"
    fi
    printf 'logLevel: warn\napi: yes\napiAddress: 127.0.0.1:9997\nrtspAddress: 127.0.0.1:8554\nrtmp: no\nhls: no\nwebrtc: no\nsrt: no\npaths:\n  all_others:\n' >"$TEST_SCRATCH/m.yml"
    supervise mediamtx "${LYREBIRD_TEST_MEDIAMTX_BINS%% *}" "$TEST_SCRATCH/m.yml"
    supervise pub ffmpeg -nostdin -loglevel error -re -f lavfi -i sine=frequency=440:sample_rate=48000 \
        -c:a aac -b:a 64k -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/mic_a
    local i
    for i in $(seq 1 50); do
        curl -s http://127.0.0.1:9997/v3/paths/list 2>/dev/null | grep -q '"ready":true' && return 0
        sleep 0.2
    done
    return 1
}

start_observer() {
    "$OBS_BASH" "$OBS" run --dir "$D" "$@" rtsp://127.0.0.1:8554/mic_a >"$TEST_SCRATCH/obs.log" 2>&1 3>&- &
    OBS_PID=$!
}

stop_observer() {
    touch "$D/stop"
    local i
    for i in $(seq 1 100); do kill -0 "$OBS_PID" 2>/dev/null || break; sleep 0.1; done
    ! kill -0 "$OBS_PID" 2>/dev/null || { echo "observer did not stop"; cat "$TEST_SCRATCH/obs.log"; false; }
}

@test "observer live: a publisher outage is an unexplained gap of about its length" {
    live_stack
    start_observer
    sleep 6
    touch "$TEST_SCRATCH/stop" # supervisors stop restarting
    pkill -f '^ffmpeg .*-f rtsp .*mic_a$'
    sleep 10
    rm -f "$TEST_SCRATCH/stop"
    supervise pub2 ffmpeg -nostdin -loglevel error -re -f lavfi -i sine=frequency=440:sample_rate=48000 \
        -c:a aac -b:a 64k -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/mic_a
    for i in $(seq 1 30); do
        [[ "$(tail -n 1 "$D/observer.tsv" | cut -f3)" == audio && "$(($(date +%s) - $(tail -n 1 "$D/observer.tsv" | cut -f1)))" -le 1 ]] && break
        sleep 0.5
    done
    sleep 3
    stop_observer
    run obs report --dir "$D"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"(1 not explained"* ]]
    len=$(printf '%s\n' "$output" | grep -oE '  [0-9]+s$' | head -n 1 | tr -dc 0-9)
    [ "$len" -ge 9 ] && [ "$len" -le 20 ]
}

@test "observer live: a power cut that leaves dead connections is survived and time to audio measured" {
    live_stack
    local mtx
    mtx=$(pgrep -x mediamtx)
    # SIGSTOP: the node vanishes without closing connections, like a power cut.
    start_observer --timeout 3 --seed 7 --power-every 8 --power-off-for 8 \
        --power-off-cmd "kill -STOP $mtx" --power-on-cmd "kill -CONT $mtx"
    for i in $(seq 1 120); do
        grep -q $'\tpower_on\t' "$D/observer.tsv" 2>/dev/null && break
        sleep 0.5
    done
    sleep 25
    stop_observer
    kill -CONT "$mtx" 2>/dev/null || true
    run obs report --dir "$D" --boot-deadline 30
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" =~ stream\ 1:\ [0-9]+ ]]
    # The cuts show up as gaps, all explained by the power windows.
    [[ "$output" =~ gaps\ \>\ 5s:\ [1-9][0-9]*\ \(0\ not\ explained ]]
    # The reader gave up on the dead connection and reconnected.
    grep -q $'\tdisconnect\t' "$D/observer.tsv"
}

@test "observer: stopping during a power cut switches the power back on first" {
    command -v ffmpeg >/dev/null || skip "ffmpeg not installed"
    "$OBS_BASH" "$OBS" run --dir "$D" --timeout 1 --power-every 1 --power-off-for 60 \
        --power-off-cmd "touch '$TEST_SCRATCH/off'" --power-on-cmd "touch '$TEST_SCRATCH/on'" \
        rtsp://127.0.0.1:1/none >/dev/null 2>&1 3>&- &
    local pid=$! i
    for i in $(seq 1 50); do [ -e "$TEST_SCRATCH/off" ] && break; sleep 0.1; done
    [ -e "$TEST_SCRATCH/off" ] && [ ! -e "$TEST_SCRATCH/on" ]
    kill -TERM "$pid"
    for i in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    ! kill -0 "$pid" 2>/dev/null || false
    [ -e "$TEST_SCRATCH/on" ]
    grep -q $'\tpower_on\t' "$D/observer.tsv"
    grep -q $'\tstop\t' "$D/observer.tsv"
}

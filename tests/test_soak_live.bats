#!/usr/bin/env bats
# tools/soak/lyrebird-soak.sh against real MediaMTX and real ffmpeg.
#
# Runs only when LYREBIRD_TEST_MEDIAMTX_BINS names MediaMTX binaries (see
# tests/fetch_mediamtx.sh); needs ffmpeg, curl and jq, and ports 8554/9997
# free. It kills ffmpeg and MediaMTX processes it finds, so it refuses to run
# if any are already running. /sys and /dev are faked (two mapped mics, as in
# test_soak.bats); /proc is the real one, so time and PIDs are real.
#
# Per binary: supervised MediaMTX and two supervised ffmpeg publishers
# (restart loops, like LyreBirdAudio's wrapper), then
#   1. init sees both streams; a publisher frozen with SIGSTOP is reported as
#      stalled while MediaMTX still lists it, and as down once it drops it;
#   2. a short run with real kill-ffmpeg and kill-mediamtx faults: every fault
#      is recovered and the report passes.

load scratch_tmpdir
load soak_helper

# Skips here, not in setup(): a setup() that skips would also skip the
# failing canary test_suite_can_fail.bats appends to every file.
require_live() {
    [[ -n "${LYREBIRD_TEST_MEDIAMTX_BINS:-}" ]] || skip "set LYREBIRD_TEST_MEDIAMTX_BINS to run"
    local c
    for c in ffmpeg curl jq; do command -v "$c" >/dev/null || skip "$c not installed"; done
    if pgrep -x mediamtx >/dev/null || pgrep -f '^ffmpeg.*rtsp://' >/dev/null; then
        skip "MediaMTX or an RTSP ffmpeg is already running here; this test kills them"
    fi
}

setup() {
    local c
    scratch_setup
    soak_setup
    # Real /proc; stubs only for udevadm (fake cards), systemctl, systemd-run.
    rm -rf "$R/proc"
    ln -s /proc "$R/proc"
    mkdir -p "$TEST_SCRATCH/livebin"
    for c in udevadm systemctl systemd-run timedatectl; do
        ln -s "$PROJECT_ROOT/tests/helpers/soak/bin/$c" "$TEST_SCRATCH/livebin/$c"
    done
    export PATH="$TEST_SCRATCH/livebin:${PATH#"$PROJECT_ROOT/tests/helpers/soak/bin:"}"
    add_card 0 mic-a 1-1 pci-0000:00:14.0-usb-0:1:1.0
    add_card 1 mic-b 1-2 pci-0000:00:14.0-usb-0:2:1.0
    mapper_rule mic-a 1-1 pci-0000:00:14.0-usb-0:1:1.0
    mapper_rule mic-b 1-2 pci-0000:00:14.0-usb-0:2:1.0
    cat >"$TEST_SCRATCH/mediamtx.yml" <<'YML'
logLevel: warn
api: yes
apiAddress: 127.0.0.1:9997
rtspAddress: 127.0.0.1:8554
rtmp: no
hls: no
webrtc: no
srt: no
paths:
  all_others:
YML
    SUPERVISORS=()
}

teardown() {
    [[ -n "${TEST_SCRATCH:-}" ]] || return 0
    touch "$TEST_SCRATCH/stop"
    local p
    for p in "${SUPERVISORS[@]}"; do
        pkill -CONT -P "$p" 2>/dev/null || true
        pkill -P "$p" 2>/dev/null || true
        kill "$p" 2>/dev/null || true
        wait "$p" 2>/dev/null || true
    done
    pkill -f "^ffmpeg .*rtsp://127.0.0.1:8554/mic_" 2>/dev/null || true
    scratch_teardown
}

# supervise NAME CMD...: restart CMD 0.5 s after it exits, until teardown.
# Runs in $TEST_SCRATCH and closes bats' fd 3, or bats would wait for it.
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

start_stack() {
    supervise mediamtx "$1" "$TEST_SCRATCH/mediamtx.yml"
    local i
    for i in $(seq 1 50); do
        curl -sf --max-time 1 http://127.0.0.1:9997/v3/paths/list >/dev/null && break
        sleep 0.2
    done
    for p in mic_a mic_b; do
        supervise "pub-$p" ffmpeg -nostdin -loglevel error -re -f lavfi -i sine=frequency=440:sample_rate=48000 \
            -c:a aac -b:a 64k -f rtsp -rtsp_transport tcp "rtsp://127.0.0.1:8554/$p"
    done
    for i in $(seq 1 50); do
        [[ "$(curl -s http://127.0.0.1:9997/v3/paths/list | jq '[.items[] | select(.ready)] | length')" == 2 ]] && return 0
        sleep 0.2
    done
    echo "streams did not come up"
    return 1
}

# wait_problem PATTERN SECONDS: take samples until the problems match.
wait_problem() {
    local i
    for ((i = 0; i < $2; i++)); do
        soak sample >/dev/null 2>&1 || true
        [[ "$(last_problems)" =~ $1 ]] && return 0
        sleep 1
    done
    echo "never saw /$1/; last problems: $(last_problems)"
    return 1
}

@test "live: stalled and dropped streams are detected; injected faults are recovered and reported" {
    require_live
    local bin version pid
    for bin in $LYREBIRD_TEST_MEDIAMTX_BINS; do
        version=$("$bin" --version | head -n 1)
        echo "# MediaMTX $version" >&3
        rm -rf "$SOAK_DIR" "$TEST_SCRATCH/stop"
        SUPERVISORS=()
        start_stack "$bin"

        run soak init
        [ "$status" -eq 0 ] || { echo "$output"; false; }
        grep -qx $'stream\tmic_a' "$SOAK_DIR/baseline"

        # Freeze mic_a's publisher: connected, but no bytes.
        pid=$(pgrep -f '^ffmpeg .*rtsp://127.0.0.1:8554/mic_a$')
        kill -STOP "$pid"
        wait_problem 'stream-stalled:mic_a' 15
        [[ "$(last_problems)" != *"stream-down:mic_a"* ]]
        # MediaMTX drops the silent session after its read timeout (10 s).
        wait_problem 'stream-down:mic_a' 30
        kill -CONT "$pid"
        kill "$pid"
        # Settle: two more healthy samples after the first before the next scenario.
        wait_problem '^-$' 30
        wait_problem '^-$' 5
        wait_problem '^-$' 5

        # Short soak with real faults.
        rm -rf "$SOAK_DIR"
        export SOAK_FAULTS=kill-ffmpeg,kill-mediamtx SOAK_WARMUP=3 SOAK_FAULT_MIN_GAP=8 SOAK_FAULT_MAX_GAP=12 \
            SOAK_RECOVERY_DEADLINE=40
        run soak init
        [ "$status" -eq 0 ] || { echo "second init: $output"; false; }
        timeout 60 bash "$SOAK" run 2>/dev/null || true
        unset SOAK_FAULTS
        run soak report
        echo "$output" | sed -n '/^Faults:/,$p' >&3
        [ "$status" -eq 0 ] || { echo "$output"; false; }
        [[ "$output" =~ kill-(ffmpeg|mediamtx)\ +injected\ +[1-9] ]]
        ! grep -q $'\tnot_recovered\t' "$SOAK_DIR/events.tsv" || false
        # The kills took effect: every killed MediaMTX PID is replaced in later
        # samples (recovery can be faster than one sample interval).
        awk -F'\t' '
            FNR == NR { if ($5 == "fault_start" && $6 ~ /^kill-mediamtx pid=/) { split($6, w, "[ =]"); killed[w[3]] = $4 }; next }
            FNR == 1 { for (i = 1; i <= NF; i++) c[$i] = i; next }
            { for (p in killed) if ($c["elapsed"] > killed[p] && $c["mtx_pid"] != "-") { if ($c["mtx_pid"] == p) bad[p] = 1; else ok[p] = 1 } }
            END { n = 0; for (p in killed) { n++; if (!(p in ok) || (p in bad)) { print "MediaMTX " p " not replaced"; exit 1 } } if (!n) { print "no kill-mediamtx fault"; exit 1 } }
        ' "$SOAK_DIR/events.tsv" "$SOAK_DIR/samples.tsv"

        touch "$TEST_SCRATCH/stop"
        for pid in "${SUPERVISORS[@]}"; do
            pkill -P "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        done
        pkill -f "^ffmpeg .*rtsp://127.0.0.1:8554/mic_" 2>/dev/null || true
    done
}

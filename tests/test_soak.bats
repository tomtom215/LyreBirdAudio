#!/usr/bin/env bats
# tools/soak/lyrebird-soak.sh against a fake node (tests/soak_helper.bash):
# fake /sys, /proc and /dev under SOAK_ROOT, stub udevadm/curl/pgrep/systemctl/
# systemd-run, and a MediaMTX /v3/paths/list fixture. Time is the fake
# /proc/uptime, moved by the tests.

load scratch_tmpdir
load soak_helper

setup() {
    scratch_setup
    soak_setup
}

teardown() {
    scratch_teardown
}

# --- init and baseline ------------------------------------------------------

@test "init takes names from the mapper rules and streams from the API, and needs a healthy node" {
    standard_node
    run soak init
    [ "$status" -eq 0 ]
    grep -qx $'card\tmic-a\t1-1\tpci-0000:00:14.0-usb-0:1:1.0' "$SOAK_DIR/baseline"
    grep -qx $'card\tmic-b\t1-2\tpci-0000:00:14.0-usb-0:2:1.0' "$SOAK_DIR/baseline"
    grep -qx $'stream\tmic_a' "$SOAK_DIR/baseline"
    grep -qx $'stream\tmic_b' "$SOAK_DIR/baseline"
    grep -qx $'service\tmediamtx-audio' "$SOAK_DIR/baseline"
    [ "$(wc -l <"$SOAK_DIR/samples.tsv")" -eq 3 ]
}

@test "every sample row has one field per header column" {
    standard_node
    soak init >/dev/null 2>&1
    step_n 3
    awk -F'\t' 'NR == 1 {n = NF} NF != n {print "row " NR ": " NF " fields, header " n; bad = 1} END {exit bad}' "$SOAK_DIR/samples.tsv"
}

@test "init refuses a node with a stream down, the API down, or no streams" {
    standard_node
    api_paths mic_a:true:1000 mic_b:false:0
    SOAK_STREAMS="mic_a mic_b" run soak init
    [ "$status" -eq 5 ]
    [[ "$output" == *"stream-down:mic_b"* ]]
    touch "$STUB_DIR/api-down"
    run soak init --force
    [ "$status" -eq 5 ]
    rm "$STUB_DIR/api-down"
    api_paths
    run soak init --force
    [ "$status" -eq 5 ]
    [[ "$output" == *"no live streams"* ]]
}

@test "init will not overwrite an existing run without --force" {
    standard_node
    soak init >/dev/null 2>&1
    run soak init
    [ "$status" -eq 2 ]
    run soak init --force
    [ "$status" -eq 0 ]
}

# --- name checks -----------------------------------------------------------

@test "a card under another name at the mapped USB path is reported as misnamed" {
    standard_node
    soak init >/dev/null 2>&1
    set_card_id 0 Device
    step_n 1
    [[ "$(last_problems)" == *"misnamed:mic-a=Device"* ]]
}

@test "two devices that swapped names are both reported" {
    standard_node
    soak init >/dev/null 2>&1
    set_card_id 0 mic-b
    set_card_id 1 mic-a
    step_n 1
    p=$(last_problems)
    [[ "$p" == *"misnamed:mic-a=mic-b"* && "$p" == *"misnamed:mic-b=mic-a"* ]]
    [[ "$p" == *"swap:mic-a@1-2"* && "$p" == *"swap:mic-b@1-1"* ]]
}

@test "an unplugged device is absent, a wrong symlink is reported" {
    standard_node
    soak init >/dev/null 2>&1
    remove_card 1
    ln -sfn ../../snd/controlC9 "$R/dev/sound/by-id/mic-a"
    step_n 1
    p=$(last_problems)
    [[ "$p" == *"absent:mic-b"* ]]
    [[ "$p" == *"symlink:mic-a"* ]]
}

@test "a vendor/product-only mapping (no port, no path) is checked by name" {
    add_card 0 mic-a 1-1 -
    mapper_rule mic-a any -
    api_paths mic_a:true:1
    soak init >/dev/null 2>&1
    step_n 1
    [ "$(last_problems)" = - ]
    set_card_id 0 other
    step_n 1
    [[ "$(last_problems)" == *"absent:mic-a"* ]]
}

# --- stream checks ---------------------------------------------------------

@test "a stream that disappears from the API is down; one whose bytes stop is stalled after SOAK_STALL_SAMPLES" {
    standard_node
    soak init >/dev/null 2>&1
    api_paths mic_a:true:5000
    step_n 1
    [[ "$(last_problems)" == *"stream-down:mic_b"* ]]
    standard_node_streams_frozen() { api_paths mic_a:true:7000 mic_b:true:7000; }
    standard_node_streams_frozen
    soak_eval step 2>/dev/null # first sample at 7000
    advance 10
    soak_eval step 2>/dev/null # 1 without progress
    advance 10
    soak_eval step 2>/dev/null # 2
    [[ "$(last_problems)" != *stalled* ]]
    advance 10
    soak_eval step 2>/dev/null # 3 = SOAK_STALL_SAMPLES
    [[ "$(last_problems)" == *"stream-stalled:mic_a"* ]]
    advance 10 100
    soak_eval step 2>/dev/null
    [ "$(last_problems)" = - ]
}

@test "a MediaMTX restart (new PID) resets the stall count" {
    standard_node
    soak init >/dev/null 2>&1
    for i in 1 2; do advance 10; soak_eval step 2>/dev/null; done
    fake_proc 200 mediamtx 1000
    echo 200 >"$STUB_DIR/pid.mediamtx"
    advance 10
    soak_eval step 2>/dev/null
    [[ "$(last_problems)" != *stalled* ]]
}

@test "the MediaMTX 1.15 JSON shape (ready/bytesReceived) is understood" {
    standard_node
    api_paths old mic_a:true:1000 mic_b:true:1000
    soak init >/dev/null 2>&1
    step_n 3
    [ "$(last_problems)" = - ]
    api_paths old mic_a:true:1000 mic_b:false:0
    step_n 1
    [[ "$(last_problems)" == *"stream-down:mic_b"* ]]
}

@test "API down and inactive services are problems" {
    standard_node
    soak init >/dev/null 2>&1
    touch "$STUB_DIR/api-down" "$STUB_DIR/inactive.mediamtx-audio"
    step_n 1
    p=$(last_problems)
    [[ "$p" == *api-down* && "$p" == *"service-inactive:mediamtx-audio"* && "$p" == *"stream-down:mic_a"* ]]
}

# --- configuration ---------------------------------------------------------

@test "config file: unknown keys and bad values are refused; the environment wins" {
    standard_node
    printf 'SOAK_INTERVAL=30\n' >"$SOAK_CONFIG"
    run soak_eval 'echo "i=$SOAK_INTERVAL"'
    [[ "$output" == *"i=1"* ]] # SOAK_INTERVAL=1 from the environment
    unset SOAK_INTERVAL
    run soak_eval 'echo "i=$SOAK_INTERVAL"'
    [[ "$output" == *"i=30"* ]]
    printf 'SOAK_BOGUS=1\n' >"$SOAK_CONFIG"
    run soak status
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown key SOAK_BOGUS"* ]]
    printf 'SOAK_NET_IFACE=eth0; reboot\n' >"$SOAK_CONFIG"
    run soak status
    [ "$status" -eq 2 ]
    [[ "$output" == *"invalid SOAK_NET_IFACE"* ]]
    rm "$SOAK_CONFIG"
    SOAK_FAULTS=kill-everything run soak status
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown fault"* ]]
}

# --- faults ----------------------------------------------------------------

@test "usb-replug arms the undo timer before unplugging, undoes it after the hold, and logs recovery" {
    standard_node
    export SOAK_FAULTS=usb-replug SOAK_USB_OFF_SECONDS=20 SOAK_FAULT_MIN_GAP=100000 SOAK_FAULT_MAX_GAP=100000
    soak init >/dev/null 2>&1
    soak_eval 'ST[next_fault]=0'
    # rand(seed 42, usb1) picks the port; watch both authorized files.
    auth0="$R/sys/bus/usb/devices/1-1/authorized" auth1="$R/sys/bus/usb/devices/1-2/authorized"
    export STUB_WATCH="$auth0"
    step_n 1
    grep -q 'fault_start' "$SOAK_DIR/events.tsv"
    port=$(grep fault_start "$SOAK_DIR/events.tsv" | grep -oE 'port=[0-9.-]+' | cut -d= -f2)
    auth="$R/sys/bus/usb/devices/$port/authorized"
    export STUB_WATCH="$auth"
    [ "$(cat "$auth")" = 0 ]
    # The timer was armed while the device was still authorized.
    [ "$port" != 1-1 ] || grep -q "systemd-run watch=1 .*lyrebird-soak-undo-usb" "$STUB_DIR/calls"
    grep -q -- "--on-active=50 " "$STUB_DIR/calls" # hold 20 s + 30 s margin
    [ -f "$SOAK_DIR/restore.d/usb.sh" ]
    step_n 1 # 10 s into the 20 s hold
    [[ "$(last_problems)" == - ]] # fake node: the card does not vanish by itself
    [[ "$(tail -n 1 "$SOAK_DIR/samples.tsv" | cut -f6)" == "usb-replug:holding" ]]
    [ "$(cat "$auth")" = 0 ]
    step_n 1 # 20 s: undone
    [ "$(cat "$auth")" = 1 ]
    [ ! -f "$SOAK_DIR/restore.d/usb.sh" ]
    grep -q "systemctl stop lyrebird-soak-undo-usb.timer" "$STUB_DIR/calls"
    events | grep -q '^fault_end'
    events | grep -qE '^recovered	usb-replug seconds=[0-9]+'
    [ "$auth0" ] && [ "$auth1" ]
}

@test "a fault that is not recovered within the deadline is logged as such, then outages count again" {
    standard_node
    export SOAK_FAULTS=kill-ffmpeg SOAK_DRY_RUN=1 SOAK_RECOVERY_DEADLINE=25
    soak init >/dev/null 2>&1
    fake_proc 300 ffmpeg 5000
    echo 300 >"$STUB_DIR/pid.ffmpeg"
    soak_eval 'ST[next_fault]=0'
    step_n 1
    events | grep -q '^fault_start	kill-ffmpeg pid=300'
    api_paths mic_a:true:1000 # mic_b stays down
    step_n 4
    events | grep -qE '^not_recovered	kill-ffmpeg seconds=3[0-9] deadline=25'
    step_n 1
    [[ "$(tail -n 1 "$SOAK_DIR/samples.tsv" | cut -f6)" == - ]]
}

@test "faults are only injected on a healthy node, after warm-up, and in dry run nothing is touched" {
    standard_node
    export SOAK_FAULTS=kill-mediamtx SOAK_DRY_RUN=1 SOAK_WARMUP=100 SOAK_FAULT_MIN_GAP=1 SOAK_FAULT_MAX_GAP=1
    soak init >/dev/null 2>&1 # first fault due at elapsed 101
    step_n 5 # 50 s < warm-up
    ! events | grep -q fault_start || false
    touch "$STUB_DIR/inactive.mediamtx-audio"
    step_n 6
    ! events | grep -q fault_start || false
    rm "$STUB_DIR/inactive.mediamtx-audio"
    run soak_eval step
    [[ "$output" == *"DRY-RUN: kill -KILL 100"* ]]
    kill -0 $$ # nothing real was signalled
}

@test "the fault schedule is the same for the same seed" {
    standard_node
    export SOAK_FAULTS=kill-mediamtx,restart-udev,udev-trigger SOAK_DRY_RUN=1 SOAK_FAULT_MIN_GAP=20 SOAK_FAULT_MAX_GAP=60
    schedule() {
        rm -rf "$SOAK_DIR"
        set_uptime 1000
        soak init >/dev/null 2>&1
        step_n 40
        events | awk -F'\t' '$1 == "fault_start" {print $2}' | cut -d' ' -f1
        cut -f4,5 "$SOAK_DIR/events.tsv" | awk -F'\t' '$2 == "fault_start" {print $1}'
    }
    a=$(schedule)
    b=$(schedule)
    [ -n "$a" ]
    [ "$a" = "$b" ]
    [ "$(printf '%s\n' "$a" | grep -c '^[a-z]')" -ge 4 ]
    export SOAK_SEED=43
    c=$(schedule)
    [ "$a" != "$c" ]
}

@test "an expected reboot is measured from boot; an unexpected one is logged and undoes leftovers" {
    standard_node
    export SOAK_FAULTS=reboot SOAK_DRY_RUN=1
    soak init >/dev/null 2>&1
    soak_eval 'ST[next_fault]=0'
    run soak_eval step
    [[ "$output" == *"DRY-RUN: systemctl reboot"* ]]
    [[ "$(cat "$SOAK_DIR/state")" == *"phase=rebooting"* ]]
    set_boot boot-b
    set_uptime 45
    soak_eval step 2>/dev/null
    events | grep -q '^fault_end	reboot new_boot'
    events | grep -q '^recovered	reboot seconds=45'

    # Unexpected: new boot with no fault in progress, a fill file left behind.
    printf 'rm -f %q\n' "$R/leftover" >"$SOAK_DIR/restore.d/disk.sh"
    touch "$R/leftover"
    set_boot boot-c
    set_uptime 30
    soak_eval step 2>/dev/null
    events | grep -q '^unexpected_reboot	previous_boot=boot-b'
    [ ! -e "$R/leftover" ]
    events | grep -q '^recovered	unexpected-reboot seconds=30'
}

@test "a reboot that never happens is abandoned after 120 s" {
    standard_node
    export SOAK_FAULTS=hard-reset SOAK_DRY_RUN=1
    soak init >/dev/null 2>&1
    soak_eval 'ST[next_fault]=0'
    run soak_eval step
    [[ "$output" == *"DRY-RUN: tee /proc/sysrq-trigger"* ]]
    step_n 13
    events | grep -q '^fault_failed	hard-reset'
}

@test "clock-jump undo restores wall time from uptime plus the old offset, same boot only" {
    standard_node
    export SOAK_FAULTS=clock-jump SOAK_DRY_RUN=1
    soak init >/dev/null 2>&1
    soak_eval 'ST[next_fault]=0'
    run soak_eval step
    [[ "$output" == *"DRY-RUN: date -s @"* ]]
    body=$(cat "$SOAK_DIR/restore.d/clock.sh")
    [[ "$body" == *"= 'boot-a' ]"* ]]
    [[ "$body" == *'date -s "@$(( $(cut -d. -f1 /proc/uptime) + '* ]]
    sh -n "$SOAK_DIR/restore.d/clock.sh"
}

@test "disk-fill never leaves less than SOAK_DISK_MIN_FREE_MB free" {
    standard_node
    export SOAK_FAULTS=disk-fill SOAK_DRY_RUN=1 SOAK_DISK_FILL_PERCENT=99
    soak init >/dev/null 2>&1
    read -r avail < <(df -Pk "$R/var/lib/mediamtx-ffmpeg" | awk 'NR==2 {print $4}')
    export SOAK_DISK_MIN_FREE_MB=$((avail / 1024 + 10))
    soak_eval 'ST[next_fault]=0'
    step_n 1
    events | grep -q '^fault_skipped	disk-fill'
    export SOAK_DISK_MIN_FREE_MB=0 SOAK_DISK_FILL_PERCENT=1
    soak_eval 'ST[next_fault]=0'
    step_n 1
    # 1% is below current use: nothing to fill either.
    [ "$(events | grep -c '^fault_skipped	disk-fill')" -eq 2 ]
    ! events | grep -q '^fault_start' || false
}

@test "a harness restart in the same boot undoes a fault left half done" {
    standard_node
    soak init >/dev/null 2>&1
    printf 'touch %q\n' "$TEST_SCRATCH/undone" >"$SOAK_DIR/restore.d/net.sh"
    soak_eval 'ST[restore]=net ST[active]=net-down ST[phase]=holding ST[hold_until]=999999'
    bash "$SOAK" run >/dev/null 2>&1 &
    pid=$!
    for _ in $(seq 1 50); do events | grep -q '^recovered' && break; sleep 0.1; done
    kill -TERM "$pid"
    wait "$pid" || true
    [ -e "$TEST_SCRATCH/undone" ]
    # Undone, then measured as a recovery from that moment.
    events | grep -q '^recovered	net-down seconds=0'
}

@test "run stops cleanly on SIGTERM and undoes an active fault; a second run is refused" {
    standard_node
    mkdir -p "$TEST_SCRATCH/bin"
    printf '#!/bin/sh\necho "ip $*" >>"$STUB_DIR/calls"\n' >"$TEST_SCRATCH/bin/ip"
    chmod +x "$TEST_SCRATCH/bin/ip"
    export PATH="$TEST_SCRATCH/bin:$PATH"
    export SOAK_FAULTS=net-down SOAK_NET_IFACE=eth9 SOAK_NET_DOWN_SECONDS=3600
    soak init >/dev/null 2>&1
    soak_eval 'ST[next_fault]=0'
    bash "$SOAK" run >/dev/null 2>&1 &
    pid=$!
    for _ in $(seq 1 50); do grep -q 'ip link set eth9 down' "$STUB_DIR/calls" && break; sleep 0.1; done
    grep -q 'ip link set eth9 down' "$STUB_DIR/calls"
    run soak run
    [ "$status" -eq 1 ]
    [[ "$output" == *"another lyrebird-soak is running"* ]]
    kill -TERM "$pid"
    wait "$pid" || true
    ! kill -0 "$pid" 2>/dev/null || false
    events | grep -q '^harness_stop'
    # Armed before the link went down, undone on stop.
    grep -n 'lyrebird-soak-undo-net\|ip link set eth9' "$STUB_DIR/calls" | cut -d: -f1 | paste -sd' ' >"$TEST_SCRATCH/order"
    awk '{exit !($1 < $2 && $2 < $3)}' "$TEST_SCRATCH/order"
    tail -n 1 <(grep 'ip link' "$STUB_DIR/calls") | grep -q 'ip link set eth9 up'
    [ ! -e "$SOAK_DIR/restore.d/net.sh" ]
}

@test "restore undoes every pending fault" {
    standard_node
    soak init >/dev/null 2>&1
    printf 'touch %q\n' "$TEST_SCRATCH/a" >"$SOAK_DIR/restore.d/usb.sh"
    printf 'touch %q\n' "$TEST_SCRATCH/b" >"$SOAK_DIR/restore.d/net.sh"
    run soak restore
    [ "$status" -eq 0 ]
    [ -e "$TEST_SCRATCH/a" ] && [ -e "$TEST_SCRATCH/b" ]
    [ -z "$(ls -A "$SOAK_DIR/restore.d")" ]
}

# --- report ----------------------------------------------------------------

# synth_run HOURS [AWK-MODIFIER]: write a run of 60 s samples. The modifier is
# awk code run per sample with h (hours since start) and fields f[] set.
synth_run() {
    mkdir -p "$SOAK_DIR"
    printf 'interval=60 warmup=0 stall_samples=3 recovery_deadline=360 reboot_deadline=300\n' >"$SOAK_DIR/environment"
    printf 'wall\tuptime\tboot\telapsed\tevent\tdetail\n' >"$SOAK_DIR/events.tsv"
    awk -v hours="$1" -v cols="$(sed -n 's/^readonly SAMPLE_COLUMNS="\(.*\)"$/\1/p' "$SOAK")" '
        BEGIN {
            OFS = "\t"; n = split(cols, c, " ")
            for (i = 1; i <= n; i++) idx[c[i]] = i
            print cols
            for (t = 0; t <= hours * 3600; t += 60) {
                for (i = 1; i <= n; i++) f[i] = 0
                f[idx["wall"]] = 1790000000 + t; f[idx["uptime"]] = 1000 + t; f[idx["boot"]] = "b1"
                f[idx["elapsed"]] = t; f[idx["healthy"]] = 1; f[idx["fault"]] = "-"; f[idx["problems"]] = "-"
                f[idx["disk_pct"]] = 40; f[idx["inode_pct"]] = 5; f[idx["mem_avail_kb"]] = 500000
                f[idx["mtx_rss_kb"]] = 30000; f[idx["mtx_fds"]] = 40; f[idx["log_kb"]] = 2000
                h = t / 3600
                '"${2:-}"'
                line = f[1]; for (i = 2; i <= n; i++) line = line OFS f[i]
                print line
            }
        }' | tr ' ' '\t' >"$SOAK_DIR/samples.tsv.tmp"
    # Header must be tab separated like the real file.
    { head -n 1 "$SOAK_DIR/samples.tsv.tmp"; tail -n +2 "$SOAK_DIR/samples.tsv.tmp"; } >"$SOAK_DIR/samples.tsv"
    rm -f "$SOAK_DIR/samples.tsv.tmp"
}

# report_all_awks: run the report under every awk available; all must agree.
report_all_awks() {
    local a out first="" rc=0 rc_first=""
    for a in gawk mawk original-awk "busybox awk"; do
        command -v "${a%% *}" >/dev/null || continue
        [[ "$a" == "busybox awk" ]] && { busybox awk 'BEGIN{}' 2>/dev/null || continue; }
        mkdir -p "$TEST_SCRATCH/awk-$$"
        printf '#!/bin/sh\nexec %s "$@"\n' "$a" >"$TEST_SCRATCH/awk-$$/awk"
        chmod +x "$TEST_SCRATCH/awk-$$/awk"
        rc=0
        out=$(PATH="$TEST_SCRATCH/awk-$$:$PATH" bash "$SOAK" report 2>&1) || rc=$?
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

@test "report: a clean 2-day run passes, under every awk" {
    synth_run 48
    run report_all_awks
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESULT: PASS"* ]]
    [[ "$output" == *"PASS          device names held"* ]]
    [[ "$output" == *"none injected"* ]]
}

@test "report: an outage outside fault windows fails; inside a fault window it does not" {
    synth_run 30 'if (h >= 10 && h < 10.1) { f[idx["healthy"]] = 0; f[idx["problems"]] = "stream-down:mic_a" }'
    run report_all_awks
    [ "$status" -eq 1 ]
    [[ "$output" == *"1 outage(s) outside fault windows, 360s in total"* ]]
    [[ "$output" == *"stream-down:mic_a"* ]]
    synth_run 30 'if (h >= 10 && h < 10.1) { f[idx["healthy"]] = 0; f[idx["fault"]] = "kill-mediamtx:recovering" }'
    run report_all_awks
    [ "$status" -eq 0 ]
}

@test "report: a wrong name in 2+ consecutive samples fails, a single transient one does not" {
    synth_run 30 'if (h >= 5 && h < 5.02) { f[idx["healthy"]] = 0; f[idx["fault"]] = "usb-replug:recovering"; f[idx["problems"]] = "misnamed:mic-a=Device" }'
    run report_all_awks
    [[ "$output" == *"FAIL          1 sample(s) with a device under the wrong name"* ]]
    [ "$status" -eq 1 ]
    synth_run 30 'if (h >= 5 && h < 5.01) { f[idx["healthy"]] = 0; f[idx["fault"]] = "usb-replug:recovering"; f[idx["problems"]] = "misnamed:mic-a=Device" }'
    run report_all_awks
    [ "$status" -eq 0 ]
}

@test "report: disk filling within 30 days fails; less than 24 h is not assessed" {
    synth_run 48 'f[idx["disk_pct"]] = 40 + h' # +24 %/day: full in ~0.5 days
    run report_all_awks
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL          disk use rising +24.000%/day"* ]]
    synth_run 10 'f[idx["disk_pct"]] = 40 + h'
    run report_all_awks
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOT ASSESSED  resource trends (10.0 h of data; need 24 h)"* ]]
}

@test "report: falling memory fails, a growing RSS warns, zombies from zero warn" {
    synth_run 48 'f[idx["mem_avail_kb"]] = 500000 - h * 2000; f[idx["mtx_rss_kb"]] = 30000 + h * 100; f[idx["zombies"]] = int(h / 6)'
    run report_all_awks
    [ "$status" -eq 1 ]
    [[ "$output" == *"available memory falling 48000 kB/day"* ]]
    [[ "$output" == *"WARN          MediaMTX RSS growing"* ]]
    [[ "$output" == *"WARN          zombie processes growing"* ]]
}

@test "report: faults, recovery statistics, unexpected reboots and not-recovered faults" {
    synth_run 30
    {
        printf '1790001000\t1\tb1\t1000\tfault_start\tkill-mediamtx pid=1\n'
        printf '1790001030\t1\tb1\t1030\trecovered\tkill-mediamtx seconds=30\n'
        printf '1790002000\t1\tb1\t2000\tfault_start\tkill-mediamtx pid=1\n'
        printf '1790002010\t1\tb1\t2010\trecovered\tkill-mediamtx seconds=10\n'
        printf '1790003000\t1\tb1\t3000\tfault_start\tkill-mediamtx pid=1\n'
        printf '1790003050\t1\tb1\t3050\trecovered\tkill-mediamtx seconds=50\n'
    } >>"$SOAK_DIR/events.tsv"
    run report_all_awks
    [ "$status" -eq 0 ]
    [[ "$output" == *"kill-mediamtx      injected   3  recovered   3  not recovered   0  recovery s: min 10 median 30 max 50"* ]]
    printf '1790004000\t1\tb1\t4000\tfault_start\tusb-replug port=1-1\n' >>"$SOAK_DIR/events.tsv"
    printf '1790004400\t1\tb1\t4400\tnot_recovered\tusb-replug seconds=400 deadline=360 problems=absent:mic-a\n' >>"$SOAK_DIR/events.tsv"
    printf '1790005000\t9\tb2\t5000\tunexpected_reboot\tprevious_boot=b1\n' >>"$SOAK_DIR/events.tsv"
    run report_all_awks
    [ "$status" -eq 1 ]
    [[ "$output" == *"1 fault(s) not recovered within the deadline"* ]]
    [[ "$output" == *"1 reboot(s) the harness did not cause"* ]]
}

@test "report: a sampling gap within one boot is a warning" {
    synth_run 30 'if (h >= 3 && h < 3.5) next_sample_skip = 1'
    # Remove 30 minutes of rows to simulate a frozen harness.
    awk -F'\t' 'NR == 1 || $4 < 10800 || $4 >= 12600' "$SOAK_DIR/samples.tsv" >"$SOAK_DIR/s" && mv "$SOAK_DIR/s" "$SOAK_DIR/samples.tsv"
    run report_all_awks
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARN          1 gap(s) in sampling"* ]]
}

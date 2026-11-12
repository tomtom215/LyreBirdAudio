#!/usr/bin/env bats
# X-30: lyrebird-metrics.sh decides whether MediaMTX and the streams are running
# by process identity, and without sending signals.
#
# Every test runs the REAL script as a child process (--once) against real,
# live processes. The processes the exporter must tell apart are decoys
# (tests/process_decoys.bash): copies of the bash binary run on a script that
# only waits, so their /proc/<pid>/exe, argv and name are whatever the test
# chooses. Nothing here signals a process that is not a decoy: `kill` is a
# guarded function, and pkill/pgrep are shims that act only on decoys (so the
# old `pgrep -f mediamtx` hits decoys, which is how the defect shows, and never
# a real process of the machine the suite runs on).
#
# (b) is tested as another user (setpriv, uid 65534) against processes that
# belong to root, the way a cron job as node_exporter sees the stream manager's
# wrappers; the "cannot tell" case needs /proc mounted with hidepid=1, which is
# done in a private pid and mount namespace and skipped where that is not
# permitted.

load scratch_tmpdir
load process_decoys
load prom_validate

setup() {
    scratch_setup
    decoy_setup
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    BASH_REAL="$(readlink -f "$(command -v bash)")"
    MX="$TEST_SCRATCH/mx"
    mkdir -p "$MX/bin" "$MX/cfg" "$MX/pids" "$MX/other"
    export MEDIAMTX_BINARY="$MX/bin/mediamtx"
    export MEDIAMTX_CONFIG_FILE="$MX/cfg/mediamtx.yml"
    # a node where the exporter reads what the stream manager wrote
    export PID_FILE="$MX/mtx.pid" FFMPEG_PID_DIR="$MX/pids" HEARTBEAT_FILE="$MX/heartbeat"
    HOLD="$MX/hold.sh"
    decoy_bash_copy "$MEDIAMTX_BINARY"
    decoy_hold_script "$HOLD"
    decoy_hold_script "$MEDIAMTX_CONFIG_FILE"
    # an API that answers, so no scrape waits for a refused connection
    mkdir -p "$MX/stubs"
    cat >"$MX/stubs/curl" <<'EOF'
#!/bin/bash
for a in "$@"; do
    case "$a" in *"/v3/info") echo '{"version":"1.19.2","upTime":100}'; exit 0 ;; esac
done
echo '{"itemCount":0,"items":[]}'
EOF
    chmod +x "$MX/stubs/curl"
}

teardown() {
    decoy_teardown
    scratch_teardown
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# Run the real script once as this user. Extra arguments are env assignments.
# Output: $TEST_SCRATCH/out, $TEST_SCRATCH/err, status in RUN_RC.
run_exporter() {
    RUN_RC=0
    env PATH="$MX/stubs:$PATH" "$@" "$BASH" "$PROJECT_ROOT/lyrebird-metrics.sh" --once \
        >"$TEST_SCRATCH/out" 2>"$TEST_SCRATCH/err" || RUN_RC=$?
}

# Value of a sample (full name with labels, as printed) in the last run's output
sample() {
    awk -v n="$1" '{ v = $NF; $NF = ""; sub(/ +$/, "", $0); if ($0 == n) print v }' "$TEST_SCRATCH/out"
}

# The collector_success value of collector $1
collector_ok() {
    sample "lyrebird_collector_success{collector=\"$1\"}"
}

# Record PID $2 for stream/file $1 the way the stream manager does: the PID file
# and "<pid> <starttime>" next to it
record_pid() {
    printf '%s\n' "$2" >"$1"
    printf '%s %s\n' "$2" "$(decoy_starttime "$2")" >"$1.id"
}

# Everything the unprivileged user needs to read: a copy of the script it can
# execute and every directory above the test's files traversable
unpriv_prepare() {
    command -v setpriv >/dev/null || skip "setpriv is not available"
    [[ "$(id -u)" -eq 0 ]] || skip "needs root to drop to another user"
    NOBODY=65534
    mkdir -p "$TEST_SCRATCH/nobody"
    cp "$PROJECT_ROOT/lyrebird-metrics.sh" "$TEST_SCRATCH/nobody/"
    chmod 755 "$TEST_SCRATCH/nobody"
    chmod 644 "$TEST_SCRATCH/nobody/lyrebird-metrics.sh"
    local d="$TEST_SCRATCH"
    while [[ "$d" != "/" ]]; do
        if ! setpriv --reuid="$NOBODY" --regid="$NOBODY" --clear-groups test -x "$d"; then
            [[ -O "$d" ]] || skip "cannot make $d traversable for another user"
            chmod o+x "$d"
        fi
        d="$(dirname "$d")"
    done
    # what the exporter reads: world-readable, as the manager writes its PID files
    chmod -R a+rX "$MX"
}

# Skip unless uid 65534 cannot see into a root process the way production sees
# it: no signals (kill -0 gives EPERM) and no /proc/<pid>/exe
require_foreign_root_process() {
    local pid="$1"
    if setpriv --reuid="$NOBODY" --regid="$NOBODY" --clear-groups bash -c 'kill -0 "$1"' _ "$pid" 2>/dev/null; then
        skip "this user may signal root's processes"
    fi
    if setpriv --reuid="$NOBODY" --regid="$NOBODY" --clear-groups readlink "/proc/$pid/exe" >/dev/null 2>&1; then
        skip "this user can read other users' /proc/<pid>/exe"
    fi
}

# Like run_exporter, but as uid 65534
run_exporter_as_nobody() {
    RUN_RC=0
    setpriv --reuid="$NOBODY" --regid="$NOBODY" --clear-groups \
        env PATH="$MX/stubs:$PATH" HOME=/nonexistent "$@" \
        "$BASH" "$TEST_SCRATCH/nobody/lyrebird-metrics.sh" --once \
        >"$TEST_SCRATCH/out" 2>"$TEST_SCRATCH/err" || RUN_RC=$?
}

# ---------------------------------------------------------------------------
# (b) liveness without signals
# ---------------------------------------------------------------------------

@test "an unprivileged exporter reads a live root-owned wrapper as up, not as down: stream_up, active_streams and stream_manager_up [X-30]" {
    unpriv_prepare
    decoy_spawn wrapper "$BASH_REAL" "$HOLD"
    local pid
    pid="$(decoy_pid wrapper)"
    require_foreign_root_process "$pid"
    record_pid "$FFMPEG_PID_DIR/mic1.pid" "$pid"
    record_pid "$PID_FILE" "$pid"
    chmod -R a+rX "$MX"

    run_exporter_as_nobody
    [ "$(sample 'lyrebird_stream_up{stream="mic1"}')" = "1" ] || { cat "$TEST_SCRATCH/out" "$TEST_SCRATCH/err"; return 1; }
    [ "$(sample lyrebird_active_streams)" = "1" ]
    [ "$(sample lyrebird_stream_manager_up)" = "1" ]
    [ "$(collector_ok streams)" = "1" ]
    [ "$(collector_ok stream_manager)" = "1" ]
}

@test "a PID reused by another process is not the stream: the recorded start time decides, with or without a record [X-30]" {
    decoy_spawn other "$BASH_REAL" "$HOLD"
    local pid start
    pid="$(decoy_pid other)"
    start="$(decoy_starttime "$pid")"
    # recorded for the process that started at another time: this PID has been reused
    printf '%s\n' "$pid" >"$FFMPEG_PID_DIR/reused.pid"
    printf '%s %s\n' "$pid" "$((start + 1))" >"$FFMPEG_PID_DIR/reused.pid.id"
    # recorded correctly
    record_pid "$FFMPEG_PID_DIR/right.pid" "$pid"
    # an older version wrote no record: the process existing is all there is to go by
    printf '%s\n' "$pid" >"$FFMPEG_PID_DIR/legacy.pid"
    # a record about some other PID says nothing about this one
    printf '%s\n' "$pid" >"$FFMPEG_PID_DIR/foreign.pid"
    printf '%s %s\n' "$((pid + 1))" "$start" >"$FFMPEG_PID_DIR/foreign.pid.id"

    run_exporter
    [ "$RUN_RC" -eq 0 ] || { cat "$TEST_SCRATCH/err"; return 1; }
    [ "$(sample 'lyrebird_stream_up{stream="reused"}')" = "0" ]
    [ "$(sample 'lyrebird_stream_up{stream="right"}')" = "1" ]
    [ "$(sample 'lyrebird_stream_up{stream="legacy"}')" = "1" ]
    [ "$(sample 'lyrebird_stream_up{stream="foreign"}')" = "1" ]
    [ "$(sample lyrebird_active_streams)" = "3" ]
}

@test "a wrapper that has exited and waits to be reaped (a zombie) is not up [X-30]" {
    # the child exits at once; its parent (which became `sleep`) never waits for it
    bash -c 'sleep 0.3 & echo $! >"$1"; exec sleep 30' _ "$DECOY_DIR/zpid" </dev/null >/dev/null 2>&1 3>&- &
    local parent=$!
    disown "$parent" 2>/dev/null || true
    echo "ZP $parent $(decoy_starttime "$parent")" >>"$DECOY_REGISTRY"
    local zpid="" state="" i
    for ((i = 0; i < 100; i++)); do
        if [[ -s "$DECOY_DIR/zpid" ]]; then
            zpid="$(cat "$DECOY_DIR/zpid")"
            break
        fi
        sleep 0.05
    done
    [ -n "$zpid" ]
    for ((i = 0; i < 100; i++)); do
        state="$(awk '{print $3}' "/proc/$zpid/stat" 2>/dev/null || true)"
        [[ "$state" == "Z" ]] && break
        sleep 0.05
    done
    [ "$state" = "Z" ]
    printf '%s\n' "$zpid" >"$FFMPEG_PID_DIR/zombie.pid"
    run_exporter
    [ "$(sample 'lyrebird_stream_up{stream="zombie"}')" = "0" ]
    [ "$(sample lyrebird_active_streams)" = "0" ]
}

@test "a process whose /proc entry cannot be read is unknown, not down: its samples are left out and the collectors fail [X-30]" {
    command -v unshare >/dev/null || skip "unshare is not available"
    unshare --pid --fork --mount --propagation private true 2>/dev/null || skip "cannot create a private pid and mount namespace here"
    unpriv_prepare
    # The wrapper is started inside the namespace (its /proc is the one mounted
    # with hidepid=1: another user sees the directory but cannot read in it)
    cat >"$TEST_SCRATCH/ns-driver.sh" <<'EOF'
#!/bin/bash
mount -t proc -o hidepid=1 proc /proc || exit 77
sleep 120 &
pid=$!
printf '%s\n' "$pid" >"$FFMPEG_PID_DIR/mic1.pid"
printf '%s\n' "$pid" >"$PID_FILE"
chmod -R a+rX "$MX"
rc=0
setpriv --reuid=65534 --regid=65534 --clear-groups \
    env PATH="$MX/stubs:$PATH" HOME=/nonexistent \
    bash "$TEST_SCRATCH/nobody/lyrebird-metrics.sh" --once >"$TEST_SCRATCH/out" 2>"$TEST_SCRATCH/err" || rc=$?
kill "$pid"
echo "$rc" >"$TEST_SCRATCH/rc"
EOF
    run env TEST_SCRATCH="$TEST_SCRATCH" MX="$MX" FFMPEG_PID_DIR="$FFMPEG_PID_DIR" PID_FILE="$PID_FILE" \
        unshare --pid --fork --mount --propagation private bash "$TEST_SCRATCH/ns-driver.sh"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(cat "$TEST_SCRATCH/rc")" = "3" ] || { cat "$TEST_SCRATCH/err"; return 1; }
    # not 0, and not 1: absent
    ! grep -q '^lyrebird_stream_up' "$TEST_SCRATCH/out" || false
    ! grep -q '^lyrebird_active_streams' "$TEST_SCRATCH/out" || false
    ! grep -q '^lyrebird_stream_manager_up' "$TEST_SCRATCH/out" || false
    [ "$(collector_ok streams)" = "0" ]
    [ "$(collector_ok stream_manager)" = "0" ]
    [ "$(sample lyrebird_scrape_success)" = "0" ]
    grep -q 'cannot tell whether PID' "$TEST_SCRATCH/err"
    # what could be read is still there
    grep -q '^lyrebird_system_load_1m ' "$TEST_SCRATCH/out"
}

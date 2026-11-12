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

# ---------------------------------------------------------------------------
# (a) MediaMTX is found by identity, not by a name pattern
# ---------------------------------------------------------------------------

# Start this installation's MediaMTX: the configured binary run on the configured
# file, which keeps six extra file descriptors open so that its descriptor count
# differs from that of every look-alike
start_our_mediamtx() {
    cat >"$MEDIAMTX_CONFIG_FILE" <<SCRIPT
exec 9<>$DECOY_DIR/hold
exec 10</dev/null 11</dev/null 12</dev/null 13</dev/null 14</dev/null 15</dev/null
read -r -t 300 -u 9 || true
SCRIPT
    decoy_spawn mtx "$MEDIAMTX_BINARY" "$MEDIAMTX_CONFIG_FILE"
    local i
    for ((i = 0; i < 100; i++)); do
        [[ -e "/proc/$(decoy_pid mtx)/fd/15" ]] && return 0
        sleep 0.05
    done
    echo "the MediaMTX stand-in never opened its descriptors" >&2
    return 1
}

# The number of entries in /proc/PID/fd, as the exporter should count them
fd_count() {
    local fds=(/proc/"$1"/fd/*)
    echo "${#fds[@]}"
}

# A look-alike: a copy of bash at $2 run as argv[0] $3 on the arguments after
spawn_lookalike() {
    local label="$1" exe="$2" argv0="$3"
    shift 3
    decoy_bash_copy "$exe"
    decoy_spawn_as "$label" "$argv0" "$exe" "$@"
}

@test "a process that only has mediamtx in its command line is not MediaMTX: mediamtx_up is 0 and nothing of it is reported [X-30]" {
    spawn_lookalike exporter "$MX/other/mediamtx-exporter" mediamtx-exporter "$HOLD"
    spawn_lookalike tailer "$MX/other/tail" tail "$HOLD" /var/log/mediamtx.log
    run_exporter
    [ "$(sample lyrebird_mediamtx_up)" = "0" ] || { cat "$TEST_SCRATCH/out"; return 1; }
    ! grep -q '^lyrebird_mediamtx_\(memory_bytes\|cpu_percent\|open_fds\|uptime_seconds\)' "$TEST_SCRATCH/out" || false
    [ "$(collector_ok mediamtx)" = "1" ]
}

@test "another installation's MediaMTX (the same binary on another configuration) and an editor on this configuration are not this MediaMTX [X-30]" {
    decoy_hold_script "$MX/other/mediamtx.yml"
    decoy_spawn other "$MEDIAMTX_BINARY" "$MX/other/mediamtx.yml"
    spawn_lookalike editor "$MX/other/vim" vim "$MEDIAMTX_CONFIG_FILE"
    run_exporter
    [ "$(sample lyrebird_mediamtx_up)" = "0" ] || { cat "$TEST_SCRATCH/out"; return 1; }
    ! grep -q '^lyrebird_mediamtx_\(memory_bytes\|cpu_percent\|open_fds\|uptime_seconds\)' "$TEST_SCRATCH/out" || false
    [ "$(collector_ok mediamtx)" = "1" ]
}

@test "the exact-identity MediaMTX is found among look-alikes that started before it, and its own memory, descriptors and uptime are reported [X-30]" {
    spawn_lookalike exporter "$MX/other/mediamtx-exporter" mediamtx-exporter "$HOLD"
    decoy_hold_script "$MX/other/mediamtx.yml"
    decoy_spawn other "$MEDIAMTX_BINARY" "$MX/other/mediamtx.yml"
    start_our_mediamtx
    local pid
    pid="$(decoy_pid mtx)"
    run_exporter
    [ "$RUN_RC" -eq 0 ] || { cat "$TEST_SCRATCH/err"; return 1; }
    [ "$(sample lyrebird_mediamtx_up)" = "1" ]
    # the look-alikes hold 4 descriptors, this one 10
    [ "$(sample lyrebird_mediamtx_open_fds)" = "$(fd_count "$pid")" ]
    [ "$(sample lyrebird_mediamtx_open_fds)" -ge 10 ]
    local rss
    rss="$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status")"
    [ "$(sample lyrebird_mediamtx_memory_bytes)" = "$((rss * 1024))" ]
    [ "$(sample lyrebird_mediamtx_uptime_seconds)" -le 5 ]
}

@test "a stand-alone MediaMTX with no PID file of the manager is found by identity, and a stale PID file does not hide it [X-30]" {
    start_our_mediamtx
    run_exporter
    [ "$(sample lyrebird_mediamtx_up)" = "1" ] || { cat "$TEST_SCRATCH/out"; return 1; }
    # the manager's PID file names a process that is gone
    local gone
    sleep 0 &
    gone=$!
    wait "$gone" || true
    printf '%s\n' "$gone" >"$PID_FILE"
    run_exporter
    [ "$(sample lyrebird_mediamtx_up)" = "1" ]
    [ "$(sample lyrebird_mediamtx_open_fds)" = "$(fd_count "$(decoy_pid mtx)")" ]
}

@test "the manager's PID file names the process and its start-time record vouches for it; a PID file naming a look-alike, or a reused PID, is not trusted [X-30]" {
    spawn_lookalike exporter "$MX/other/mediamtx-exporter" mediamtx-exporter "$HOLD"
    # the PID file names the look-alike, there is no MediaMTX: it is down
    record_pid "$PID_FILE" "$(decoy_pid exporter)"
    run_exporter
    [ "$(sample lyrebird_mediamtx_up)" = "0" ] || { cat "$TEST_SCRATCH/out"; return 1; }

    start_our_mediamtx
    local pid
    pid="$(decoy_pid mtx)"
    # it names the look-alike while MediaMTX runs: the scan finds the real one
    run_exporter
    [ "$(sample lyrebird_mediamtx_up)" = "1" ]
    [ "$(sample lyrebird_mediamtx_open_fds)" = "$(fd_count "$pid")" ]
    # it names MediaMTX with the record of another start time (a reused PID): the
    # process is not the recorded one, and is found by identity all the same
    printf '%s\n' "$pid" >"$PID_FILE"
    printf '%s %s\n' "$pid" "$(($(decoy_starttime "$pid") + 1))" >"$PID_FILE.id"
    run_exporter
    [ "$(sample lyrebird_mediamtx_up)" = "1" ]
    # and named properly
    record_pid "$PID_FILE" "$pid"
    run_exporter
    [ "$(sample lyrebird_mediamtx_up)" = "1" ]
    [ "$(collector_ok mediamtx)" = "1" ]
}

@test "the running MediaMTX is still recognised after an upgrade replaced its binary, and when the binary is configured through a symlink [X-30]" {
    start_our_mediamtx
    # an upgrade: the file at the path is replaced, the running image is now "(deleted)"
    rm -f "$MEDIAMTX_BINARY"
    cp "$BASH_REAL" "$MEDIAMTX_BINARY"
    [[ "$(readlink "/proc/$(decoy_pid mtx)/exe")" == *"(deleted)" ]]
    run_exporter
    [ "$(sample lyrebird_mediamtx_up)" = "1" ] || { cat "$TEST_SCRATCH/out"; return 1; }
    # the configured path is a symlink to the image that runs
    local real="$MX/bin/mediamtx-1.2.3"
    cp "$BASH_REAL" "$real"
    ln -s "$real" "$MX/bin/mediamtx-current"
    decoy_hold_script "$MX/cfg/second.yml"
    decoy_spawn second "$real" "$MX/cfg/second.yml"
    run_exporter MEDIAMTX_BINARY="$MX/bin/mediamtx-current" MEDIAMTX_CONFIG_FILE="$MX/cfg/second.yml"
    [ "$(sample lyrebird_mediamtx_up)" = "1" ] || { cat "$TEST_SCRATCH/out"; return 1; }
}

@test "the exporter reads the manager's variables: the configuration is MEDIAMTX_CONFIG_FILE or MEDIAMTX_CONFIG_DIR/mediamtx.yml, the PID file is PID_FILE, else MEDIAMTX_PID_FILE [X-30]" {
    start_our_mediamtx
    local pid
    pid="$(decoy_pid mtx)"
    # the default configuration file name inside MEDIAMTX_CONFIG_DIR
    run_exporter MEDIAMTX_CONFIG_FILE= MEDIAMTX_CONFIG_DIR="$MX/cfg"
    [ "$(sample lyrebird_mediamtx_up)" = "1" ] || { cat "$TEST_SCRATCH/out"; return 1; }
    run_exporter MEDIAMTX_CONFIG_FILE= MEDIAMTX_CONFIG_DIR="$MX/other"
    [ "$(sample lyrebird_mediamtx_up)" = "0" ]
    # the PID file: the manager's variable when PID_FILE is not set, PID_FILE when both are
    record_pid "$MX/named.pid" "$pid"
    run_exporter PID_FILE= MEDIAMTX_PID_FILE="$MX/named.pid"
    [ "$(sample lyrebird_stream_manager_up)" = "1" ] || { cat "$TEST_SCRATCH/out"; return 1; }
    run_exporter PID_FILE="$MX/absent.pid" MEDIAMTX_PID_FILE="$MX/named.pid"
    [ "$(sample lyrebird_stream_manager_up)" = "0" ]
}

@test "without readlink the executable of a process that runs MediaMTX's configuration cannot be checked: the collector fails visibly and no false lyrebird_mediamtx_up 0 is published [X-30]" {
    # a directory of the tools a scrape needs, minus readlink
    local t src
    mkdir -p "$MX/toolbox"
    for t in date grep awk cat find wc ps df getconf head tr cut basename dirname sleep mktemp mv rm chmod id uname; do
        src="$(command -v "$t" 2>/dev/null)" || continue
        [[ "$src" == /* ]] && ln -sf "$src" "$MX/toolbox/$t"
    done
    cp "$MX/stubs/curl" "$MX/toolbox/curl"
    start_our_mediamtx
    run_exporter PATH="$MX/toolbox"
    ! grep -q '^lyrebird_mediamtx_up' "$TEST_SCRATCH/out" || false
    [ "$(collector_ok mediamtx)" = "0" ]
    [ "$(collector_ok system)" = "1" ]
    [ "$RUN_RC" -eq 3 ]
    grep -q 'cannot tell whether MediaMTX' "$TEST_SCRATCH/err"
    # with a MediaMTX that is not running there is nothing to look at: not a failure
    builtin kill "$(decoy_pid mtx)"
    local i
    for ((i = 0; i < 100; i++)); do
        decoy_alive mtx || break
        sleep 0.05
    done
    run_exporter PATH="$MX/toolbox"
    [ "$(sample lyrebird_mediamtx_up)" = "0" ]
    [ "$(collector_ok mediamtx)" = "1" ]
}

@test "an unprivileged exporter finds the manager's MediaMTX by its PID file and start-time record, and reports its descriptor count as unknown, not 0 [X-30]" {
    unpriv_prepare
    start_our_mediamtx
    local pid
    pid="$(decoy_pid mtx)"
    require_foreign_root_process "$pid"
    record_pid "$PID_FILE" "$pid"
    chmod -R a+rX "$MX"
    run_exporter_as_nobody
    [ "$(sample lyrebird_mediamtx_up)" = "1" ] || { cat "$TEST_SCRATCH/out" "$TEST_SCRATCH/err"; return 1; }
    grep -q '^lyrebird_mediamtx_memory_bytes ' "$TEST_SCRATCH/out"
    grep -q '^lyrebird_mediamtx_uptime_seconds ' "$TEST_SCRATCH/out"
    # root's descriptor table cannot be listed: unknown, not "0"
    ! grep -q '^lyrebird_mediamtx_open_fds' "$TEST_SCRATCH/out" || false
    [ "$(collector_ok mediamtx)" = "0" ]
    [ "$RUN_RC" -eq 3 ]
    grep -q "cannot list /proc/${pid}/fd" "$TEST_SCRATCH/err"
}

@test "an unprivileged exporter cannot tell whether a stand-alone MediaMTX of root runs, and says so; with nothing running that configuration it is a definite 0 [X-30]" {
    unpriv_prepare
    start_our_mediamtx
    local pid
    pid="$(decoy_pid mtx)"
    require_foreign_root_process "$pid"
    # no PID file of the manager, or one without a start-time record: nothing
    # tells root's MediaMTX from a look-alike with the same arguments
    run_exporter_as_nobody
    ! grep -q '^lyrebird_mediamtx_up' "$TEST_SCRATCH/out" || false
    [ "$(collector_ok mediamtx)" = "0" ]
    grep -q 'cannot tell whether MediaMTX' "$TEST_SCRATCH/err"
    printf '%s\n' "$pid" >"$PID_FILE"
    chmod -R a+rX "$MX"
    run_exporter_as_nobody
    ! grep -q '^lyrebird_mediamtx_up' "$TEST_SCRATCH/out" || false
    [ "$(collector_ok mediamtx)" = "0" ]
    # nothing runs this configuration: that is known, with or without privilege
    builtin kill "$pid"
    local i
    for ((i = 0; i < 100; i++)); do
        decoy_alive mtx || break
        sleep 0.05
    done
    rm -f "$PID_FILE"
    run_exporter_as_nobody
    [ "$(sample lyrebird_mediamtx_up)" = "0" ] || { cat "$TEST_SCRATCH/out" "$TEST_SCRATCH/err"; return 1; }
    [ "$(collector_ok mediamtx)" = "1" ]
}

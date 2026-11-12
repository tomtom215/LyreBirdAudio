#!/usr/bin/env bats
# The updater lock (finding U-20, decision D2): a flock(2) lock on a file under
# <git-dir>/lyrebird-updater/ that is never removed or truncated, an owner
# record "<pid> <starttime>" written after the lock is won, no age- or
# name-based staleness, and the lock descriptor closed in every child the
# updater starts. Real script, real concurrent processes, real git
# repositories: see tests/updater_helper.bash (updater_hold_lock starts an
# updater that stays inside its critical section).

load bats_shell_state
load scratch_tmpdir
load updater_helper

setup_file() {
    updater_template_build
}

setup() {
    scratch_setup
    updater_node_setup
    HOLDER_PIDS=()
    ORPHAN_PIDS=()
    STATE="$REPO/.git/lyrebird-updater"
    LOCK="$STATE/updater.lock"
}

teardown() {
    updater_holders_stop
    scratch_teardown
}

_lock_is_held() {
    ! flock -n "$1" true
}

# a process that holds LOCK without being an updater, for as long as it lives
_hold_lock_with_flock() {
    mkdir -p "$STATE"
    flock "$LOCK" sleep 25 3>&- &
    HOLDER_PIDS+=("$!")
    updater_wait_for _lock_is_held "$LOCK"
}

# ============================================================================
# What the lock is
# ============================================================================

@test "the lock is an flock on a file that is never removed; it records the holder's pid and start time" {
    updater_checkout v1.1.0
    chmod +x "$REPO/lyrebird-updater.sh"
    UPDATER_HOLD_DIRECT=yes updater_hold_lock 2 --version
    [ -f "$LOCK" ]
    # really held: another open file description cannot take it
    run flock -n "$LOCK" true
    [ "$status" -ne 0 ]
    local rec_pid rec_start
    read -r rec_pid rec_start _ <"$LOCK"
    [ "$rec_pid" = "$HOLDER_PID" ]
    [ "$rec_start" = "$(updater_starttime "$HOLDER_PID")" ]
    # one fixed-width line: 64 columns and a newline
    [ "$(stat -c %s "$LOCK")" -eq 65 ]
    # the process was started as a program: its name is the script's, not "bash"
    [ "$(cat "/proc/$HOLDER_PID/comm")" = "lyrebird-update" ]
    local inode
    inode="$(stat -c %i "$LOCK")"
    wait "$HOLDER_PID"
    # finished: the lock is free, the file (and the last owner's record) is still there
    flock -n "$LOCK" true
    [ "$(stat -c %i "$LOCK")" = "$inode" ]
    read -r rec_pid _ <"$LOCK"
    [ "$rec_pid" = "$HOLDER_PID" ]
    # and the next updater reuses the very same file
    updater_run --version
    [ "$status" -eq 0 ]
    [ "$(stat -c %i "$LOCK")" = "$inode" ]
}

@test "SIGKILL of the holder frees the lock at once, even while its git child still runs; nothing is unlinked" {
    updater_checkout v1.1.0
    updater_hold_lock 25 --status
    local inode kids kid alive=0
    inode="$(stat -c %i "$LOCK")"
    kids="$(updater_descendants "$HOLDER_PID")"
    [ -n "$kids" ]
    for kid in $kids; do ORPHAN_PIDS+=("$kid"); done
    kill -KILL "$HOLDER_PID"
    wait "$HOLDER_PID" 2>/dev/null || true
    # the git the updater was running (the shim and its sleep) is still alive ...
    for kid in $kids; do
        if kill -0 "$kid" 2>/dev/null; then alive=$((alive + 1)); fi
    done
    [ "$alive" -ge 1 ]
    # ... and does not keep the lock: it is free the moment the updater is gone
    flock -n "$LOCK" true
    # the next updater takes it without waiting; the file is the same one
    LYREBIRD_UPDATER_LOCK_WAIT=1 updater_run --status
    [ "$status" -eq 0 ]
    [[ "$output" != *"Waiting for other instance"* ]]
    [ "$(stat -c %i "$LOCK")" = "$inode" ]
}

@test "a second updater waits for the holder and goes ahead the moment it exits" {
    updater_checkout v1.1.0
    updater_hold_lock 3 --version
    LYREBIRD_UPDATER_LOCK_WAIT=20 updater_run --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"Waiting for other instance to finish"* ]]
    [[ "$output" == *"LyreBirdAudio Version Manager"* ]]
    wait "$HOLDER_PID"
}

@test "an updater that gives up exits 7, names the holder with start time and command, and leaves the record alone" {
    updater_checkout v1.1.0
    updater_hold_lock 25 --status
    LYREBIRD_UPDATER_LOCK_WAIT=1 updater_run --status
    [ "$status" -eq 7 ]
    [[ "$output" == *"Lock held by process $HOLDER_PID (start time $(updater_starttime "$HOLDER_PID")): "* ]]
    [[ "$output" == *"lyrebird-updater.sh --status"* ]]
    [[ "$output" == *"Nothing needs to be deleted"* ]]
    local rec_pid
    read -r rec_pid _ <"$LOCK"
    [ "$rec_pid" = "$HOLDER_PID" ]
    _lock_is_held "$LOCK"
}

# ============================================================================
# Updaters started in the same instant
# ============================================================================

# Wait until N processes have checked in with a ready.<i> file in DIR
_ready_count_is() {
    [ "$(find "$1" -maxdepth 1 -name 'ready.*' | wc -l)" -eq "$2" ]
}

# N updaters (every other one executed directly, the rest through bash) held
# at a gate until every one of them has started, then released together; each,
# once it holds the lock, stays in its critical section for 6 s while the
# others give up after 1 s
_same_instant() {
    local n="$1" i gate
    updater_checkout v1.1.0
    chmod +x "$REPO/lyrebird-updater.sh"
    updater_inject rev-parse before SLEEP
    export FAULT_SLEEP=6 LYREBIRD_UPDATER_LOCK_WAIT=1
    updater_stdin
    local input="${UPDATER_INPUT%$'\n'}"
    unset UPDATER_INPUT
    mkdir -p "$NODE/gate.d"
    exec {gate}>"$NODE/gate"
    flock -x "$gate"
    for i in $(seq 1 "$n"); do
        (
            : >"$NODE/gate.d/ready.$i"
            if ((i % 2)); then
                cmd=("$REPO/lyrebird-updater.sh")
            else
                cmd=(bash "$REPO/lyrebird-updater.sh")
            fi
            rc=0
            flock -s -o "$NODE/gate" env PATH="$SHIMS:$PATH" "${cmd[@]}" --status <<<"$input" >"$NODE/out.$i" 2>&1 || rc=$?
            echo "$rc" >"$NODE/rc.$i"
        ) 3>&- {gate}>&- &
    done
    updater_wait_for _ready_count_is "$NODE/gate.d" "$n"
    sleep 0.3 # and every one of them is blocked at the gate
    exec {gate}>&-
    wait
    local ok=0 locked=0 rc
    for i in $(seq 1 "$n"); do
        rc="$(cat "$NODE/rc.$i")"
        case "$rc" in
            0) ok=$((ok + 1)) ;;
            7) locked=$((locked + 1)) ;;
            *)
                echo "updater $i exited $rc:"
                cat "$NODE/out.$i"
                return 1
                ;;
        esac
    done
    echo "ok=$ok locked=$locked sleeps=$(grep -c 'fault SLEEP' "$FAULT_LOG")"
    [ "$ok" -eq 1 ]
    [ "$locked" -eq $((n - 1)) ]
    # and only one of them was ever inside the critical section
    [ "$(grep -c 'fault SLEEP' "$FAULT_LOG")" -eq 1 ]
}

@test "eight updaters started in the same instant: exactly one proceeds, the others exit 7" {
    _same_instant 8
}

# The old stale-lock removal (kill -0, rm -rf, mkdir) let two processes both
# remove the dead holder's lock and both create their own: with 30 racing
# processes that happened in about two rounds out of three. Each process that
# wins records when it enters and leaves its critical section; the test fails
# when two critical sections overlap (so a slow start of some process cannot
# make it fail: one that comes late and takes the lock after the winner has
# left is not a violation).
@test "thirty processes taking the lock in the same instant after a crashed 1.7.0 updater: never two holders at once (six rounds)" {
    local round i gate peak
    local race="$NODE/race"
    for round in 1 2 3 4 5 6; do
        rm -rf "$race"
        mkdir -p "$race/state/lock" "$race/ready"
        echo 2147483646 >"$race/state/lock/pid"
        : >"$race/events"
        exec {gate}>"$race/gate"
        flock -x "$gate"
        for i in $(seq 1 30); do
            (
                : >"$race/ready/ready.$i"
                exec flock -s -o "$race/gate" env LYREBIRD_UPDATER_STATE_DIR="$race/state" LYREBIRD_UPDATER_LOCK_WAIT=1 \
                    bash -c 'source "$1"; set +e; if acquire_lock >/dev/null 2>&1; then echo "+ $(date +%s%N)" >>"$2"; sleep 1; echo "- $(date +%s%N)" >>"$2"; fi' \
                    _ "$REPO/lyrebird-updater.sh" "$race/events"
            ) 3>&- {gate}>&- &
        done
        updater_wait_for _ready_count_is "$race/ready" 30
        sleep 0.3
        exec {gate}>&-
        wait
        peak="$(sort -k2,2n "$race/events" | awk '$1 == "+" {c++; if (c > max) max = c} $1 == "-" {c--} END {print max + 0}')"
        [ "$peak" -eq 1 ] || {
            echo "round $round: $peak processes were inside the critical section at the same time"
            cat "$race/events"
            return 1
        }
    done
}

@test "a live updater is never judged stale because of its name or how it was started" {
    updater_checkout v1.1.0
    ln -s lyrebird-updater.sh "$REPO/refresh-node"
    UPDATER_HOLD_SCRIPT="$REPO/refresh-node" updater_hold_lock 25 --status
    # its command line says nothing about "lyrebird-updater"
    [[ "$(tr '\0' ' ' <"/proc/$HOLDER_PID/cmdline")" != *lyrebird-updater* ]]
    LYREBIRD_UPDATER_LOCK_WAIT=1 updater_run --status
    [ "$status" -eq 7 ]
    [[ "$output" == *"Lock held by process $HOLDER_PID"* ]]
    _lock_is_held "$LOCK"
}

# ============================================================================
# The owner record is information, never a reason to take the lock
# ============================================================================

@test "a lock held by a process that recorded nothing is reported as such, with the processes that have the file open" {
    updater_checkout v1.1.0
    _hold_lock_with_flock
    LYREBIRD_UPDATER_LOCK_WAIT=1 updater_run --status
    [ "$status" -eq 7 ]
    [[ "$output" == *"Lock held by another process (no owner recorded)"* ]]
    [[ "$output" == *"Processes with the lock file open: "* ]]
    [[ "$output" == *"(flock)"* ]]
}

@test "a recorded owner that is not running, or whose pid was recycled, is not blamed; a free lock is simply taken" {
    updater_checkout v1.1.0
    mkdir -p "$STATE"
    # free lock, record of a dead process: taken, record replaced
    printf '%-64s\n' "2147483646 12345" >"$LOCK"
    updater_run --version
    [ "$status" -eq 0 ]
    local rec_pid
    read -r rec_pid _ <"$LOCK"
    [ "$rec_pid" != "2147483646" ]
    # held, record of a dead process
    _hold_lock_with_flock
    printf '%-64s\n' "2147483646 12345" >"$LOCK"
    LYREBIRD_UPDATER_LOCK_WAIT=1 updater_run --version
    [ "$status" -eq 7 ]
    [[ "$output" == *"the last recorded owner, process 2147483646, start time 12345, is not running"* ]]
    # held, record of a live process with another start time (a recycled pid)
    printf '%-64s\n' "$$ 1" >"$LOCK"
    LYREBIRD_UPDATER_LOCK_WAIT=1 updater_run --version
    [ "$status" -eq 7 ]
    [[ "$output" == *"process $$, start time 1, is not running"* ]]
    [[ "$output" != *"Lock held by process $$"* ]]
}

@test "a lock file that already holds data is not truncated: the record is written in place and what follows it stays" {
    updater_checkout v1.1.0
    mkdir -p "$STATE"
    {
        printf '%-64s\n' "2147483646 12345"
        printf 'data after the record\nand more\n'
    } >"$LOCK"
    updater_run --version
    [ "$status" -eq 0 ]
    local first
    first="$(head -n 1 "$LOCK")"
    [[ "$first" =~ ^[0-9]+\ [0-9]+\ *$ ]]
    [ "${first%% *}" != "2147483646" ]
    grep -qx 'data after the record' "$LOCK"
    grep -qx 'and more' "$LOCK"
}

# ============================================================================
# The descriptor is not inherited by anything the updater starts
# ============================================================================

@test "git does not inherit the lock descriptor, including the git that timeout starts for a fetch" {
    updater_checkout v1.1.0
    export FAULT_PROBE_PATH="$LOCK"
    # a plain git call
    updater_inject rev-parse before PROBE_FD
    updater_run --status
    [ "$status" -eq 0 ]
    grep -q "probe fd-open=no rev-parse $LOCK" "$FAULT_LOG"
    # the three git calls the updater makes through timeout(1), which runs the git binary itself
    local key
    for key in ls-remote fetch remote; do
        updater_inject "$key" before PROBE_FD
        updater_run --list
        [ "$status" -eq 0 ]
        grep -q "probe fd-open=no $key $LOCK" "$FAULT_LOG" || { echo "$key: $(cat "$FAULT_LOG")"; return 1; }
    done
    # the variables set in front of those calls still reach git (the low-speed bound of the
    # fetch and of the default-branch probe: LYREBIRD_FETCH_TIMEOUT=5, LYREBIRD_REMOTE_PROBE_TIMEOUT=3)
    updater_inject fetch before PROBE_FD
    updater_run --list
    grep -q "probe fd-open=no fetch $LOCK low-speed-time=5" "$FAULT_LOG"
    updater_inject ls-remote before PROBE_FD
    updater_run --list
    grep -q "probe fd-open=no ls-remote $LOCK low-speed-time=3" "$FAULT_LOG"
    # and the quick fetch of the start-up diagnostics
    updater_inject fetch before PROBE_FD
    updater_stdin q
    updater_run
    [ "$status" -eq 0 ]
    grep -q "probe fd-open=no fetch $LOCK" "$FAULT_LOG"
}

@test "a child that git leaves running after the updater has exited, like a detached git gc, does not keep the lock" {
    updater_checkout v1.1.0
    export FAULT_SLEEP=25
    updater_inject fetch after DETACH
    updater_run --list
    [ "$status" -eq 0 ]
    local detached
    detached="$(sed -n 's/^detached //p' "$FAULT_LOG" | head -n 1)"
    [ -n "$detached" ]
    ORPHAN_PIDS+=("$detached")
    # it outlived the updater ...
    kill -0 "$detached"
    # ... and does not have the lock file open, so the lock is free
    flock -n "$LOCK" true
}

@test "systemctl does not inherit the lock descriptor" {
    updater_checkout v1.1.0
    updater_install_fake_service running
    export FAKE_SVC_LOCK_PROBE="$LOCK"
    updater_stdin 3 v1.2.0 "" q
    updater_run
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.2.0" ]
    grep -q 'systemctl stop mediamtx-audio' "$FAKE_SVC_LOG"
    grep -q 'systemctl start mediamtx-audio' "$FAKE_SVC_LOG"
    ! grep -q 'lock-fd-open' "$FAKE_SVC_LOG" || false
}

@test "the stream manager's install, run when the updater reinstalls the service, does not inherit the lock descriptor" {
    updater_checkout v1.1.0
    # v1.2.1: a stream manager that reports whether it has the lock file open
    git -C "$WORK" checkout -q v1.2.0
    cat >"$WORK/lyrebird-stream-manager.sh" <<'EOF'
#!/bin/bash
for fd in /proc/$$/fd/*; do
    [[ "$fd" -ef "$MANAGER_PROBE_PATH" ]] && echo "manager has the lock file open" >>"$MANAGER_PROBE_LOG"
done
echo "manager ran: $*" >>"$MANAGER_PROBE_LOG"
EOF
    git -C "$WORK" commit -qam "v1.2.1 (probing stream manager)"
    git -C "$WORK" tag v1.2.1
    git -C "$WORK" push -q origin v1.2.1 2>/dev/null
    git -C "$WORK" checkout -q main
    git -C "$REPO" fetch -q origin --tags
    updater_install_fake_service running
    export MANAGER_PROBE_PATH="$LOCK" MANAGER_PROBE_LOG="$NODE/manager.log"
    updater_stdin 3 v1.2.1 "" q
    updater_run
    [ "$status" -eq 0 ]
    [ "$(updater_head)" = "v1.2.1" ]
    grep -qx 'manager ran: install' "$MANAGER_PROBE_LOG"
    ! grep -q 'has the lock file open' "$MANAGER_PROBE_LOG" || false
}

@test "a self-update hands the lock over: the re-exec'd updater takes it at once instead of waiting for its own earlier descriptor" {
    updater_checkout v1.1.0
    updater_stdin 3 v1.3.0 "" q
    LYREBIRD_UPDATER_LOCK_WAIT=2 updater_run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Restarting with updated version"* ]]
    [[ "$output" != *"Waiting for other instance"* ]]
    [ "$(updater_head)" = "v1.3.0" ]
    # and it is free again at the end
    flock -n "$LOCK" true
}

# ============================================================================
# Which commands take the lock
# ============================================================================

@test "--history takes no lock: it answers while another updater holds it, and creates no lock file on a node that never ran one" {
    updater_checkout v1.1.0
    updater_run --history
    [ "$status" -eq 0 ]
    [ ! -e "$LOCK" ]
    updater_hold_lock 25 --status
    LYREBIRD_UPDATER_LOCK_WAIT=1 updater_run --history
    [ "$status" -eq 0 ]
    [[ "$output" == *"Update History"* ]]
}

@test "--status and --list still take the lock (unchanged): they are refused with exit 7 while another updater holds it" {
    updater_checkout v1.1.0
    updater_hold_lock 25 --status
    local arg
    for arg in --status --list; do
        LYREBIRD_UPDATER_LOCK_WAIT=1 updater_run "$arg"
        [ "$status" -eq 7 ] || { echo "$arg: status $status"; return 1; }
    done
}

# ============================================================================
# Prerequisites
# ============================================================================

# A PATH directory with only the listed tools (symlinks), for a node that
# lacks one of them
_path_with_tools() {
    local dir="$NODE/tools" tool
    mkdir -p "$dir"
    for tool in "$@"; do
        ln -sf "$(command -v "$tool")" "$dir/$tool"
    done
    printf '%s' "$dir"
}

@test "a node without flock is refused up front (exit 2) and told where flock comes from" {
    updater_checkout v1.1.0
    local tools
    tools="$(_path_with_tools git awk sed grep tput basename dirname id cat tr stat)"
    updater_stdin
    run env PATH="$tools" "$(command -v bash)" "$REPO/lyrebird-updater.sh" --status <<<"${UPDATER_INPUT%$'\n'}"
    unset UPDATER_INPUT
    [ "$status" -eq 2 ]
    [[ "$output" == *"Required utilities not found: flock"* ]]
    [[ "$output" == *"util-linux"* ]]
}

@test "a node without git is still refused (exit 2) as not having git: the git function does not make it look installed" {
    updater_checkout v1.1.0
    local tools
    tools="$(_path_with_tools flock awk sed grep tput basename dirname id cat tr stat)"
    updater_stdin
    run env PATH="$tools" "$(command -v bash)" "$REPO/lyrebird-updater.sh" --status <<<"${UPDATER_INPUT%$'\n'}"
    unset UPDATER_INPUT
    [ "$status" -eq 2 ]
    [[ "$output" == *"Git is not installed"* ]]
}

# ============================================================================
# Lock directories of older updaters
# ============================================================================

@test "a live 1.7.0 updater holding its lock directory in the state directory is honoured (exit 7)" {
    updater_checkout v1.1.0
    mkdir -p "$STATE/lock"
    ( exec -a "lyrebird-updater.sh" sleep 30 ) 3>&- &
    local holder=$!
    HOLDER_PIDS+=("$holder")
    echo "$holder" >"$STATE/lock/pid"
    LYREBIRD_UPDATER_LOCK_WAIT=1 updater_run --status
    [ "$status" -eq 7 ]
    [[ "$output" == *"Another (older) updater instance is running: $STATE/lock"* ]]
    [ -d "$STATE/lock" ]
}

@test "the lock directory of a dead 1.7.0 updater is removed, so a 1.7.0 updater started after a rollback can create its own" {
    updater_checkout v1.1.0
    mkdir -p "$STATE/lock"
    echo 2147483646 >"$STATE/lock/pid"
    updater_run --status
    [ "$status" -eq 0 ]
    [ ! -e "$STATE/lock" ]
}

@test "an empty 1.7.0 lock directory (its updater was killed between mkdir and the pid write) no longer locks every later run out" {
    updater_checkout v1.1.0
    mkdir -p "$STATE/lock"
    LYREBIRD_UPDATER_LOCK_WAIT=2 updater_run --status
    [ "$status" -eq 0 ]
    [ ! -e "$STATE/lock" ]
}

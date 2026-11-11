#!/usr/bin/env bats
# Locking in lyrebird-stream-manager.sh (register: LB-05, X-02; decision D2).
#
# Every test runs the REAL script: the lock functions are sourced from
# lyrebird-stream-manager.sh and called in real, concurrent processes. Each
# process is started in one of two ways:
#
#   bash   `bash <dir>/lyrebird-stream-manager.sh ROLE ...`
#   direct `<dir>/lyrebird-stream-manager.sh ROLE ...` through its shebang
#
# The role script is written under the literal name lyrebird-stream-manager.sh
# because that is how systemd runs the manager (ExecStart=.../lyrebird-stream-
# manager.sh start): the kernel then reports the 15-character comm
# "lyrebird-stream", which the old `ps comm` staleness test could never match,
# so a live owner was always judged stale. A role script only sources the real
# script and calls its functions; the lock logic under test is never copied.
#
# The processes that hold a lock use only bash builtins while they hold it
# (read on a FIFO instead of sleep): a child process would inherit the lock
# descriptor and keep the lock alive after its parent was SIGKILLed.

load scratch_tmpdir

setup() {
    scratch_setup
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
    LK="$TEST_SCRATCH/lk"
    mkdir -p "$LK/cfg" "$LK/ff" "$LK/bin" "$LK/role"
    BG_PIDS=()

    # Private paths for everything the script writes
    export LB_REAL_SCRIPT="$PROJECT_ROOT/lyrebird-stream-manager.sh"
    export MEDIAMTX_LOCK_FILE="$LK/run.lock"
    export MEDIAMTX_LOG_FILE="$LK/sm.log"
    export MEDIAMTX_CONFIG_DIR="$LK/cfg"
    export MEDIAMTX_PID_FILE="$LK/mtx.pid"
    export MEDIAMTX_FFMPEG_DIR="$LK/ff"
    export MEDIAMTX_RESTART_MARKER="$LK/restart.marker"
    export MEDIAMTX_CLEANUP_MARKER="$LK/cleanup.marker"
    export MEDIAMTX_HOST="locks.invalid"
    export LOCK_ACQUISITION_TIMEOUT=2
    export STOP_LOCK_TIMEOUT=1
    export LB_IDLE_FIFO="$LK/idle.fifo"
    export LB_DIR="$LK"
    export LB_READY="$LK/ready" LB_STOP="$LK/stop"
    mkfifo "$LB_IDLE_FIFO"

    # Nothing of the host may be touched: process lookups and kills, port
    # probes and API calls are PATH shims that only record what was asked
    local tool
    for tool in pkill pgrep lsof ss; do
        printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"%s/%s.calls"\nexit 1\n' "$LK" "$tool" >"$LK/bin/$tool"
    done
    printf '#!/bin/bash\nexit 0\n' >"$LK/bin/curl"
    chmod +x "$LK/bin/"*
    export PATH="$LK/bin:$PATH"

    _write_role_script
}

teardown() {
    local pid
    for pid in "${BG_PIDS[@]:-}"; do
        [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    done
    # Children a test started on purpose (MediaMTX stub, wrappers)
    for pid in "${EXTRA_PIDS[@]:-}"; do
        [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    done
    scratch_teardown
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# The role script: sources the real script under the name systemd runs it by
_write_role_script() {
    ROLE="$LK/role/lyrebird-stream-manager.sh"
    export LB_ROLE="$ROLE"
    cat >"$ROLE" <<'ROLE_EOF'
#!/bin/bash
# Test role. Usage: lyrebird-stream-manager.sh ROLE ARGS...
role="$1"
shift
# The real script, with CURRENT_COMMAND=start; it keeps its set -euo pipefail
# shellcheck source=/dev/null
source "$LB_REAL_SCRIPT" start

# Wait without forking: a child would inherit the lock descriptor
exec {IDLE_FD}<>"$LB_IDLE_FIFO"
idle() { read -r -t "$1" -u "$IDLE_FD" || true; }

case "$role" in
    hold) # hold READY STOPFILE [TIMEOUT]: take the lock, hold it until STOPFILE exists
        ready="$1" stop="$2" to="${3:-20}"
        rc=0
        acquire_lock "$to" || rc=$?
        if [[ $rc -ne 0 ]]; then
            printf 'FAILED\n' >"$ready"
            exit 3
        fi
        printf '%s\n' "$BASHPID" >"$ready"
        until [[ -e "$stop" ]]; do idle 0.05; done
        release_lock
        ;;
    hold-config) # hold-config READY STOPFILE: the same for the configuration lock
        ready="$1" stop="$2"
        rc=0
        acquire_config_lock 20 || rc=$?
        if [[ $rc -ne 0 ]]; then
            printf 'FAILED\n' >"$ready"
            exit 3
        fi
        printf '%s\n' "$BASHPID" >"$ready"
        until [[ -e "$stop" ]]; do idle 0.05; done
        release_config_lock_unsafe
        ;;
    try) # try TIMEOUT: one acquisition attempt
        rc=0
        acquire_lock "$1" || rc=$?
        printf 'rc=%s\n' "$rc"
        ;;
    cs) # cs LABEL EVENTS TIMEOUT HOLD: critical section that logs ACQ and REL
        label="$1" events="$2" to="$3" hold="$4"
        rc=0
        acquire_lock "$to" || rc=$?
        if [[ $rc -ne 0 ]]; then
            printf '%s FAIL\n' "$label" >>"$events"
            exit 3
        fi
        printf '%s ACQ\n' "$label" >>"$events"
        idle "$hold"
        printf '%s REL\n' "$label" >>"$events"
        release_lock
        ;;
    count) # count N COUNTER TIMEOUT: N locked read-modify-write increments
        n="$1" counter="$2" to="$3"
        for ((i = 0; i < n; i++)); do
            rc=0
            acquire_lock "$to" || rc=$?
            if [[ $rc -ne 0 ]]; then
                printf 'FAIL\n' >>"$counter.fail"
                exit 3
            fi
            read -r v <"$counter"
            printf '%s\n' "$((v + 1))" >"$counter"
            release_lock
        done
        ;;
    eval) # eval CODE: run CODE inside the sourced script
        eval "$1"
        ;;
    *)
        printf 'unknown role %s\n' "$role" >&2
        exit 64
        ;;
esac
ROLE_EOF
    chmod +x "$ROLE"
}

# Run a role in the foreground: _role bash|direct ROLE ARGS...
_role() {
    local mode="$1"
    shift
    if [[ "$mode" == "bash" ]]; then
        bash "$ROLE" "$@"
    else
        "$ROLE" "$@"
    fi
}

# Start a role in the background; its output goes to $LK/bg.<n>.out
_role_bg() {
    local mode="$1"
    shift
    local out="$LK/bg.${#BG_PIDS[@]}.out"
    if [[ "$mode" == "bash" ]]; then
        bash "$ROLE" "$@" >"$out" 2>&1 3>&- &
    else
        "$ROLE" "$@" >"$out" 2>&1 3>&- &
    fi
    BG_PIDS+=("$!")
}

# Wait until FILE is non-empty (at most $2 seconds)
_wait_nonempty() {
    local file="$1" limit="${2:-15}" i
    for ((i = 0; i < limit * 20; i++)); do
        [[ -s "$file" ]] && return 0
        sleep 0.05
    done
    echo "timed out waiting for $file" >&2
    cat "$LK"/bg.*.out >&2 2>/dev/null || true
    tail -n 20 "$MEDIAMTX_LOG_FILE" >&2 2>/dev/null || true
    return 1
}

# Wait until process $1 no longer exists (at most $2 seconds)
_wait_gone() {
    local pid="$1" limit="${2:-15}" i
    for ((i = 0; i < limit * 20; i++)); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.05
    done
    echo "process $pid is still running" >&2
    return 1
}

# Start a holder and wait until it owns the lock; sets HOLDER_PID
_start_holder() {
    local mode="$1" kind="${2:-hold}"
    rm -f "$LK/ready" "$LK/stop"
    _role_bg "$mode" "$kind" "$LK/ready" "$LK/stop"
    _wait_nonempty "$LK/ready"
    HOLDER_PID="$(<"$LK/ready")"
    [[ "$HOLDER_PID" =~ ^[0-9]+$ ]]
}

_stop_holder() {
    : >"$LK/stop"
    _wait_gone "$HOLDER_PID"
}

# Field 22 of /proc/<pid>/stat, counted after the command name's closing paren
_starttime() {
    sed 's/^.*) //' "/proc/$1/stat" | awk '{print $20}'
}

# First line of a lock file, exactly as stored
_record() {
    head -n 1 "$1"
}

# A read-only descriptor on the file as it is now, number left in WITNESS_FD.
# While it stays open that inode cannot be given to another file, so "still the
# same file" can be checked with -ef even on a filesystem that hands the inode
# number of a file that was just deleted to the next new one (a plain
# `stat -c %i` comparison cannot tell a deleted-and-recreated lock file from
# the original there; this sandbox's /tmp is such a filesystem).
_witness() {
    exec {WITNESS_FD}<"$1"
}

# _same_file WITNESS_FD PATH: PATH is still the file the witness was opened on
_same_file() {
    [[ "/proc/$$/fd/$1" -ef "$2" ]]
}

# ---------------------------------------------------------------------------
# Mutual exclusion that does not depend on the owner's age, name or comm
# ---------------------------------------------------------------------------

_t_exclusive() {
    local mode="$1"
    _start_holder "$mode"
    local w
    _witness "$MEDIAMTX_LOCK_FILE"
    w=$WITNESS_FD

    run _role "$mode" try 1
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=1"* ]]

    # Still one file, still the owner's
    _same_file "$w" "$MEDIAMTX_LOCK_FILE"
    _stop_holder

    run _role "$mode" try 1
    [[ "$output" == *"rc=0"* ]]
    _same_file "$w" "$MEDIAMTX_LOCK_FILE"
}

@test "a held lock is not granted to a second process [LB-05, bash invocation]" {
    _t_exclusive bash
}

@test "a held lock is not granted to a second process [LB-05, direct execution]" {
    _t_exclusive direct
}

@test "acquire_lock creates the lock file and its directory when they do not exist" {
    export MEDIAMTX_LOCK_FILE="$LK/not-yet/dir/run.lock"
    [ ! -e "$LK/not-yet" ]
    run bash "$ROLE" try 1
    [[ "$output" == *"rc=0"* ]]
    [ -f "$LK/not-yet/dir/run.lock" ]
}

@test "direct execution has the 15-character comm the old staleness check could never match" {
    _start_holder direct
    [ "$(<"/proc/$HOLDER_PID/comm")" = "lyrebird-stream" ]
    _stop_holder
}

_t_old_lock_file() {
    local mode="$1"
    _start_holder "$mode"
    local w before
    _witness "$MEDIAMTX_LOCK_FILE"
    w=$WITNESS_FD
    before="$(_record "$MEDIAMTX_LOCK_FILE")"

    # The owner is alive and has held the lock for hours as far as the file's
    # age goes (the old code called a start/restart caller "stale" after 300 s)
    touch -d '2 hours ago' "$MEDIAMTX_LOCK_FILE"
    # (start is the command the old code applied the age rule to)
    run _role "$mode" try 1
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" != *"rc=0"* ]]

    _same_file "$w" "$MEDIAMTX_LOCK_FILE"
    [ "$(_record "$MEDIAMTX_LOCK_FILE")" = "$before" ]
    _stop_holder
}

@test "a live owner is never judged stale because the lock file is old [LB-05, bash invocation]" {
    _t_old_lock_file bash
}

@test "a live owner is never judged stale because the lock file is old [LB-05, direct execution]" {
    _t_old_lock_file direct
}

_t_waiter_keeps_record() {
    local mode="$1"
    _start_holder "$mode"
    local before
    before="$(<"$MEDIAMTX_LOCK_FILE")"
    [ -n "$before" ]

    run _role "$mode" try 1
    [[ "$output" == *"rc=1"* ]]
    run _role "$mode" try 1
    [[ "$output" == *"rc=1"* ]]

    # The waiters opened the file; the owner's record is byte for byte intact
    [ "$(<"$MEDIAMTX_LOCK_FILE")" = "$before" ]
    [ "$(_record "$MEDIAMTX_LOCK_FILE" | awk '{print $1}')" = "$HOLDER_PID" ]
    _stop_holder
}

@test "a process waiting for the lock never truncates the owner record [LB-05, bash invocation]" {
    _t_waiter_keeps_record bash
}

@test "a process waiting for the lock never truncates the owner record [LB-05, direct execution]" {
    _t_waiter_keeps_record direct
}

# Owner plus two openers (the register's three-way scenario): the second
# opener used to see the PID erased by the first opener, call the lock stale,
# unlink it and acquire a third inode while the owner still held the first.
_t_three_way() {
    local mode="$1" events="$LK/events"
    : >"$events"
    _role_bg "$mode" cs owner "$events" 20 2
    local i
    for ((i = 0; i < 200; i++)); do
        grep -q '^owner ACQ$' "$events" && break
        sleep 0.05
    done
    grep -q '^owner ACQ$' "$events"
    local w
    _witness "$MEDIAMTX_LOCK_FILE"
    w=$WITNESS_FD

    _role_bg "$mode" cs opener1 "$events" 20 0.3
    sleep 0.3
    _role_bg "$mode" cs opener2 "$events" 20 0.3

    local pid
    for pid in "${BG_PIDS[@]}"; do
        wait "$pid"
    done

    # Exactly one holder at a time: ACQ and REL alternate, same label
    run awk '
        $2 == "ACQ" { if (held != "") { print "overlap: " $1 " acquired while " held " held"; bad = 1 } held = $1; n++ }
        $2 == "REL" { if (held != $1) { print "unbalanced release by " $1; bad = 1 } held = "" }
        $2 == "FAIL" { print "failed: " $1; bad = 1 }
        END { if (n != 3) { print "expected 3 acquisitions, saw " n; bad = 1 } exit bad }' "$events"
    echo "$output" >&2
    [ "$status" -eq 0 ]
    _same_file "$w" "$MEDIAMTX_LOCK_FILE"
}

@test "owner plus two openers: exactly one holder at a time [LB-05, bash invocation]" {
    _t_three_way bash
}

@test "owner plus two openers: exactly one holder at a time [LB-05, direct execution]" {
    _t_three_way direct
}

# The kernel releases the flock when the holder dies; nothing may be unlinked
# or replaced for the next process to get in (the old code removed the path
# because the recorded PID was dead).
_t_sigkill() {
    local mode="$1"
    _start_holder "$mode"
    local w
    _witness "$MEDIAMTX_LOCK_FILE"
    w=$WITNESS_FD

    kill -9 "$HOLDER_PID"
    _wait_gone "$HOLDER_PID"

    run _role "$mode" try 3
    [[ "$output" == *"rc=0"* ]]
    # Same file as before, no unlink, no "stale" handling
    _same_file "$w" "$MEDIAMTX_LOCK_FILE"
    [[ "$output" != *"stale"* ]]
}

@test "the lock is released when its holder is SIGKILLed; the next acquire reuses the same file [LB-05, bash invocation]" {
    _t_sigkill bash
}

@test "the lock is released when its holder is SIGKILLed; the next acquire reuses the same file [LB-05, direct execution]" {
    _t_sigkill direct
}

@test "the owner record is '<pid> <starttime>' with field 22 of /proc/<pid>/stat [D2]" {
    _start_holder direct
    local rec
    rec="$(_record "$MEDIAMTX_LOCK_FILE")"
    [[ "$rec" =~ ^[0-9]+\ [0-9]+\ *$ ]]
    [ "$(awk '{print $1}' <<<"$rec")" = "$HOLDER_PID" ]
    [ "$(awk '{print $2}' <<<"$rec")" = "$(_starttime "$HOLDER_PID")" ]
    _stop_holder
}

@test "a refused process names the real owner: pid, start time and command [D2]" {
    _start_holder bash
    run _role bash try 1
    [[ "$output" == *"Failed to acquire lock after 1 seconds"* ]]
    [[ "$output" == *"PID $HOLDER_PID (start time $(_starttime "$HOLDER_PID"))"* ]]
    [[ "$output" == *"lyrebird-stream-manager.sh hold"* ]]
    _stop_holder
}

@test "a recorded PID that now belongs to another process is not blamed [D2]" {
    _start_holder bash
    # An unrelated live process; pretend it is the owner but with a start time
    # that is not its own (what a recycled PID looks like)
    sleep 3141 3>&- &
    local other=$!
    EXTRA_PIDS+=("$other")
    printf '%-64s\n' "$other 1" | dd of="$MEDIAMTX_LOCK_FILE" conv=notrunc 2>/dev/null

    run _role bash try 1
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" != *"sleep 3141"* ]]
    [[ "$output" != *"is held; PID $other"* ]]
    [[ "$output" == *"is not running"* ]]
    # What is actually holding the lock is still reported
    [[ "$output" == *"Processes with the lock file open:"* ]]
    [[ "$output" == *"$HOLDER_PID(bash)"* ]]
    _stop_holder
}

@test "LOCK_STALE_THRESHOLD is ignored and logged once as deprecated [D2]" {
    _start_holder bash
    # Backdate the file and set the old threshold to one second: neither may
    # make the owner look stale
    touch -d '2 hours ago' "$MEDIAMTX_LOCK_FILE"
    run env LOCK_STALE_THRESHOLD=1 bash "$ROLE" eval '
        a=0; acquire_lock 1 || a=$?
        b=0; acquire_lock 1 || b=$?
        printf "first=%s second=%s\n" "$a" "$b"'
    [[ "$output" == *"first=1 second=1"* ]]
    local lines
    lines="$(grep -c 'LOCK_STALE_THRESHOLD is deprecated and ignored' "$MEDIAMTX_LOG_FILE")"
    [ "$lines" -eq 1 ]
    _stop_holder

    # Without the variable there is no deprecation line at all
    : >"$MEDIAMTX_LOG_FILE"
    run bash "$ROLE" try 1
    [[ "$output" == *"rc=0"* ]]
    ! grep -q 'LOCK_STALE_THRESHOLD' "$MEDIAMTX_LOG_FILE" || false
}

@test "a process that already holds the lock keeps it when it acquires again (restart = stop + start) [D2]" {
    run bash "$ROLE" eval '
        acquire_lock 1 || exit 10
        fd=$MAIN_LOCK_FD
        exec {witness}<"$MEDIAMTX_LOCK_FILE"
        # a second process cannot get in before, between or after
        out=$(bash "$LB_ROLE" try 1 2>/dev/null)
        acquire_lock 1 || exit 11
        [[ $MAIN_LOCK_FD -eq $fd ]] || exit 12
        out2=$(bash "$LB_ROLE" try 1 2>/dev/null)
        same=different-file
        [[ /proc/$$/fd/$witness -ef "$MEDIAMTX_LOCK_FILE" ]] && same=same-file
        printf "%s %s %s\n" "$out" "$out2" "$same"'
    [ "$status" -eq 0 ]
    [ "$output" = "rc=1 rc=1 same-file" ]
    # The second call kept the lock instead of releasing and re-taking it
    [ "$(grep -c 'Acquired lock' "$MEDIAMTX_LOG_FILE")" -eq 1 ]
    grep -q 'Lock already held' "$MEDIAMTX_LOG_FILE"
}

@test "acquiring and releasing locks leaves the shell's stderr alone [X-06]" {
    run bash "$ROLE" eval '
        exec 2>"$LB_DIR/err.out"
        before=$(readlink /proc/$$/fd/2)
        acquire_lock 1
        release_lock
        acquire_lock 1
        release_lock_unsafe
        release_config_lock_unsafe
        after=$(readlink /proc/$$/fd/2)
        [[ $before == "$after" ]] && echo same-stderr || echo "stderr changed: $before -> $after"'
    [ "$status" -eq 0 ]
    [ "$output" = "same-stderr" ]
}

@test "no age- or name-based staleness code is left: is_lock_stale and LOCK_STALE_THRESHOLD are gone [D2]" {
    run bash "$ROLE" eval '
        declare -F is_lock_stale >/dev/null && echo "is_lock_stale still defined"
        declare -p LOCK_STALE_THRESHOLD >/dev/null 2>&1 && echo "LOCK_STALE_THRESHOLD still defined"
        echo checked'
    [ "$output" = "checked" ]
}

# ---------------------------------------------------------------------------
# Stress: no lost update, ever
# ---------------------------------------------------------------------------

_t_stress() {
    local mode="$1" procs="$2" iters="$3"
    printf '0\n' >"$LK/counter"
    local i
    for ((i = 0; i < procs; i++)); do
        _role_bg "$mode" count "$iters" "$LK/counter" 120
    done
    local pid failed=0
    for pid in "${BG_PIDS[@]}"; do
        wait "$pid" || failed=$((failed + 1))
    done
    [ "$failed" -eq 0 ]
    [ ! -e "$LK/counter.fail" ]
    [ "$(<"$LK/counter")" -eq $((procs * iters)) ]
}

@test "stress: 8 processes x 25 locked increments lose no update [LB-05, direct execution]" {
    local w
    : >>"$MEDIAMTX_LOCK_FILE"
    _witness "$MEDIAMTX_LOCK_FILE"
    w=$WITNESS_FD
    _t_stress direct 8 25
    _same_file "$w" "$MEDIAMTX_LOCK_FILE"
}

@test "stress: 6 processes x 20 locked increments lose no update [LB-05, bash invocation]" {
    _t_stress bash 6 20
}

# ---------------------------------------------------------------------------
# Lock paths are never unlinked or truncated by cleanup, stop or force-stop
# ---------------------------------------------------------------------------

@test "cleanup_stale_processes removes neither lock file [LB-05]" {
    : >>"$MEDIAMTX_LOCK_FILE"
    : >>"$LK/cfg/.config.lock"
    local w_lock w_cfg
    _witness "$MEDIAMTX_LOCK_FILE"
    w_lock=$WITNESS_FD
    _witness "$LK/cfg/.config.lock"
    w_cfg=$WITNESS_FD

    run bash "$ROLE" eval 'cleanup_stale_processes'
    [ "$status" -eq 0 ]
    _same_file "$w_lock" "$MEDIAMTX_LOCK_FILE"
    _same_file "$w_cfg" "$LK/cfg/.config.lock"
}

_force_stop_fixture() {
    : >"$LK/ff/mic1.pid"
    : >"$LK/ff/mic1.sh"
    : >"$LK/restart.marker"
}

@test "force_stop_mediamtx waits for the lock and refuses, touching nothing, while another process holds it [LB-05]" {
    _force_stop_fixture
    _start_holder bash
    local w before
    _witness "$MEDIAMTX_LOCK_FILE"
    w=$WITNESS_FD
    before="$(<"$MEDIAMTX_LOCK_FILE")"

    run bash "$ROLE" eval 'rc=0; force_stop_mediamtx || rc=$?; echo "force-stop rc=$rc"'
    [[ "$output" == *"force-stop rc=5"* ]]
    [[ "$output" == *"Refusing to force-stop"* ]]
    [[ "$output" == *"PID $HOLDER_PID (start time"* ]]

    # Nothing was killed, deleted or unlinked
    [ ! -e "$LK/pkill.calls" ]
    [ -e "$LK/ff/mic1.pid" ]
    [ -e "$LK/ff/mic1.sh" ]
    [ -e "$LK/restart.marker" ]
    _same_file "$w" "$MEDIAMTX_LOCK_FILE"
    [ "$(<"$MEDIAMTX_LOCK_FILE")" = "$before" ]
    _stop_holder
}

@test "force_stop_mediamtx takes the lock when it is free, cleans up and leaves the lock file in place [LB-05]" {
    _force_stop_fixture
    : >>"$MEDIAMTX_LOCK_FILE"
    local w
    _witness "$MEDIAMTX_LOCK_FILE"
    w=$WITNESS_FD

    run bash "$ROLE" eval 'force_stop_mediamtx; echo "rc=$? fd=$MAIN_LOCK_FD"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=0 fd="* ]]
    [ -s "$LK/pkill.calls" ]
    [ ! -e "$LK/ff/mic1.pid" ]
    [ ! -e "$LK/ff/mic1.sh" ]
    [ ! -e "$LK/restart.marker" ]
    _same_file "$w" "$MEDIAMTX_LOCK_FILE"
}

@test "a force-stop started while another command holds the lock waits for it, then goes ahead [LB-05]" {
    export STOP_LOCK_TIMEOUT=20
    _force_stop_fixture
    _start_holder bash
    _role_bg bash eval 'force_stop_mediamtx; echo "force-stop done rc=$?"'
    local waiter="${BG_PIDS[${#BG_PIDS[@]} - 1]}"
    sleep 0.7
    # Still waiting: it has not killed or deleted anything
    kill -0 "$waiter"
    [ -e "$LK/ff/mic1.pid" ]
    [ ! -e "$LK/pkill.calls" ]
    _stop_holder
    wait "$waiter"
    [ ! -e "$LK/ff/mic1.pid" ]
    [ -s "$LK/pkill.calls" ]
    grep -q 'force-stop done rc=0' "$LK/bg.1.out"
}

@test "stop_mediamtx refuses, touching nothing, while another process holds the lock [LB-05]" {
    : >"$LK/ff/mic1.pid"
    _start_holder bash
    run bash "$ROLE" eval 'rc=0; stop_mediamtx || rc=$?; echo "stop rc=$rc"'
    [[ "$output" == *"stop rc=5"* ]]
    [[ "$output" == *"Refusing to stop"* ]]
    [[ "$output" == *"PID $HOLDER_PID (start time"* ]]
    [ ! -e "$LK/pkill.calls" ]
    [ -e "$LK/ff/mic1.pid" ]
    _stop_holder

    # Free again: the same stop goes through
    run bash "$ROLE" eval 'rc=0; stop_mediamtx || rc=$?; echo "stop rc=$rc"'
    [[ "$output" == *"stop rc=0"* ]]
}

@test "a start that cannot get the lock leaves no cleanup marker behind [LB-05]" {
    _start_holder bash
    # What main() does: a cleanup trap on exit, then start_mediamtx
    run bash "$ROLE" eval 'COMMAND=start; trap cleanup EXIT; start_mediamtx'
    [ "$status" -eq 5 ]
    [[ "$output" == *"Failed to acquire lock"* ]]
    # A marker would make the NEXT start run cleanup_stale_processes and kill
    # the healthy stack that holds the lock
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]
    _stop_holder
}

@test "the log lock file is never truncated by log() [D2]" {
    run bash "$ROLE" eval '
        printf SENTINEL >"${LOG_FILE}.lock"
        log INFO "one line"
        cat "${LOG_FILE}.lock"'
    [[ "$output" == *"SENTINEL"* ]]
}

# ---------------------------------------------------------------------------
# The configuration lock is the same primitive
# ---------------------------------------------------------------------------

@test "the config lock records the owner like the main lock and keeps its file [D2]" {
    _start_holder bash hold-config
    local rec
    rec="$(_record "$LK/cfg/.config.lock")"
    [[ "$rec" =~ ^[0-9]+\ [0-9]+\ *$ ]]
    [ "$(awk '{print $1}' <<<"$rec")" = "$HOLDER_PID" ]
    local w
    _witness "$LK/cfg/.config.lock"
    w=$WITNESS_FD

    run bash "$ROLE" eval 'rc=0; acquire_config_lock 1 || rc=$?; echo "config rc=$rc"'
    [[ "$output" == *"config rc=1"* ]]
    [[ "$output" == *"Failed to acquire config lock"* ]]
    [[ "$output" == *"PID $HOLDER_PID (start time"* ]]
    _same_file "$w" "$LK/cfg/.config.lock"
    [ "$(_record "$LK/cfg/.config.lock")" = "$rec" ]
    _stop_holder
}

@test "generate_mediamtx_config waits for the config lock, then writes the config and keeps the lock file [D2]" {
    printf '#!/bin/bash\n[[ "$1" == --version ]] && echo v1.15.0\nexit 0\n' >"$LK/mediamtx-stub"
    chmod +x "$LK/mediamtx-stub"
    export MEDIAMTX_BINARY="$LK/mediamtx-stub"

    _start_holder bash hold-config
    local w
    _witness "$LK/cfg/.config.lock"
    w=$WITNESS_FD
    # Release the config lock one second after generate has started waiting
    (
        sleep 1
        : >"$LK/stop"
    ) 3>&- &
    EXTRA_PIDS+=("$!")

    run bash "$ROLE" eval 'rc=0; generate_mediamtx_config || rc=$?; echo "generate rc=$rc"'
    [[ "$output" == *"generate rc=0"* ]]
    grep -q '^rtspAddress: :8554$' "$MEDIAMTX_CONFIG_DIR/mediamtx.yml"

    _same_file "$w" "$LK/cfg/.config.lock"
    [[ "$(_record "$LK/cfg/.config.lock")" =~ ^[0-9]+\ [0-9]+\ *$ ]]
    _wait_gone "$HOLDER_PID"
}

# ---------------------------------------------------------------------------
# No long-lived child holds a lock descriptor (X-02)
# ---------------------------------------------------------------------------

# Descriptors of process $1 that refer to file $2 (the lock file)
_fds_on() {
    local pid="$1" target="$2" fd out=""
    for fd in /proc/"$pid"/fd/*; do
        [[ "$fd" -ef "$target" ]] && out+="${fd##*/} "
    done
    printf '%s' "$out"
}

@test "spawn_detached starts the command itself with no descriptor above stderr, even an inherited one [X-02]" {
    run bash "$ROLE" eval '
        acquire_lock 1
        acquire_config_lock 1
        # a descriptor inherited from a parent, like the monitor lock of `flock FILE -c`
        exec {inherited}<>"$LB_IDLE_FIFO"
        spawn_detached nohup setsid sleep 30 >/dev/null 2>&1 &
        child=$!
        sleep 0.3
        printf "comm=%s\n" "$(cat /proc/$child/comm)"
        printf "fds=%s\n" "$(ls /proc/$child/fd | tr "\n" " ")"
        kill "$child"'
    [ "$status" -eq 0 ]
    # $! is the command's own PID (the subshell was replaced by it) ...
    [[ "$output" == *"comm=sleep"* ]]
    # ... and only stdin, stdout and stderr are open in it
    [[ "$output" == *"fds=0 1 2 "* ]]
}

@test "spawn_detached refuses to run in the foreground, where it would replace the manager itself [X-02]" {
    run bash "$ROLE" eval 'rc=0; spawn_detached true || rc=$?; echo "still running rc=$rc"'
    [[ "$output" == *"still running rc=1" ]]
}

@test "every nohup launch in the script goes through spawn_detached [X-02]" {
    run bash -c 'grep -nE "(^|[^_[:alnum:]])nohup " "$1" | grep -vE "spawn_detached nohup|^[0-9]+:[[:space:]]*#"' _ "$PROJECT_ROOT/lyrebird-stream-manager.sh"
    # what is printed is a launch that bypasses the helper: there must be none
    [ -z "$output" ]
}

# A MediaMTX stand-in the real start_mediamtx can launch. It names itself
# "mediamtx" (the process-identity check accepts that comm) and, unlike a
# background bash script, dies on SIGINT, which is how stop_mediamtx asks.
_write_mediamtx_stub() {
    mkdir -p "$LK/stub"
    cat >"$LK/stub/mediamtx" <<'STUB_EOF'
#!/bin/bash
[[ "${1:-}" == --version ]] && { echo v1.21.1; exit 0; }
exec python3 -I -c 'import ctypes, signal, time
ctypes.CDLL(None).prctl(15, b"mediamtx", 0, 0, 0)
signal.signal(signal.SIGINT, signal.SIG_DFL)
time.sleep(300)'
STUB_EOF
    chmod +x "$LK/stub/mediamtx"
    export MEDIAMTX_BINARY="$LK/stub/mediamtx"
}

# Hardware-only seams: no USB device and no stream publishing. Everything else
# (the lock, the config generation, the launch itself) is the real function.
_SEAMS='
detect_audio_devices() { echo "testmic:1"; }
wait_for_usb_stabilization() { return 0; }
start_all_ffmpeg_streams() { :; }
validate_stream() { return 0; }
check_audio_device() { return 0; }
'

# The generated wrapper checks /dev/snd/pcmC<N>D0c, which a machine without
# sound hardware (CI) does not have, and drives a real ffmpeg. For the tests of
# the wrapper launch sites only, `bash` on PATH is a shim that runs the wrapper
# the manager generated with those two hardware dependencies pointed at stand-
# ins (an existing path, and a stub ffmpeg that just waits). The launch itself,
# the wrapper text and the lock are the real ones.
_use_wrapper_hardware_stand_ins() {
    mkdir -p "$LK/wrapbin"
    cat >"$LK/wrapbin/bash" <<'SHIM_EOF'
#!/bin/bash
if [[ "${1:-}" == "$LB_DIR/ff/"*.sh ]]; then
    script="$1"
    shift
    sed -e 's#/dev/snd/pcmC${card_num}D0c#/dev/null#' \
        -e 's#/dev/snd/pcmC${CARD_NUM}D0c#/dev/null#' \
        -e 's#export PATH="/usr/local/sbin#export PATH="'"$LB_DIR"'/bin:/usr/local/sbin#' \
        "$script" >"${script%.sh}.standin"
    exec /bin/bash "${script%.sh}.standin" "$@"
fi
exec /bin/bash "$@"
SHIM_EOF
    printf '#!/bin/bash\nexec sleep 600\n' >"$LK/bin/ffmpeg"
    chmod +x "$LK/wrapbin/bash" "$LK/bin/ffmpeg"
    export PATH="$LK/wrapbin:$PATH"
}

# PIDs of every descendant of $1
_descendants() {
    local parent="$1" pid ppid
    while read -r pid ppid; do
        if [[ "$ppid" == "$parent" ]]; then
            printf '%s\n' "$pid"
            _descendants "$pid"
        fi
    done < <(ps -eo pid=,ppid=)
}

# The launcher runs CODE (a real start_* function), reports the child's PID
# through LB_READY, then keeps holding the lock until LB_STOP appears.
# Sets CHILD_PID and LAUNCHER_PID.
_start_launcher() {
    local code="$1" pidfile="$2"
    rm -f "$LB_READY" "$LB_STOP"
    _role_bg bash eval "$_SEAMS
$code
read -r child <\"$pidfile\"
printf '%s\n' \"\$child\" >\"\$LB_READY\"
until [[ -e \"\$LB_STOP\" ]]; do idle 0.05; done"
    LAUNCHER_PID="${BG_PIDS[${#BG_PIDS[@]} - 1]}"
    _wait_nonempty "$LB_READY" 30
    CHILD_PID="$(<"$LB_READY")"
    [[ "$CHILD_PID" =~ ^[0-9]+$ ]]
    EXTRA_PIDS+=("$CHILD_PID")
}

# The child is running, holds no lock file, and the lock is free once the
# launcher has gone (the old code left it held by the child)
_assert_child_holds_no_lock() {
    local w
    _witness "$MEDIAMTX_LOCK_FILE"
    w=$WITNESS_FD
    kill -0 "$CHILD_PID"
    local pid
    for pid in "$CHILD_PID" $(_descendants "$CHILD_PID"); do
        EXTRA_PIDS+=("$pid")
        [ "$(_fds_on "$pid" "$MEDIAMTX_LOCK_FILE")" = "" ]
        [ "$(_fds_on "$pid" "$LK/cfg/.config.lock")" = "" ]
    done

    # the launcher itself still holds the lock, so the test means something
    run _role bash try 1
    [[ "$output" == *"rc=1"* ]]

    : >"$LB_STOP"
    _wait_gone "$LAUNCHER_PID"
    kill -0 "$CHILD_PID"
    run _role bash try 3
    [[ "$output" == *"rc=0"* ]]
    # and no unlink/re-create cycle happened on the way
    _same_file "$w" "$MEDIAMTX_LOCK_FILE"
}

@test "the MediaMTX child holds no lock descriptor, so the lock is free once the launcher exits [X-02]" {
    _write_mediamtx_stub
    _start_launcher 'start_mediamtx >/dev/null || exit 9' "$MEDIAMTX_PID_FILE"
    _assert_child_holds_no_lock
}

@test "a multiplex wrapper and its ffmpeg hold no lock descriptor, so the lock is free once the launcher exits [X-02]" {
    _use_wrapper_hardware_stand_ins
    _start_launcher 'acquire_lock 5 && start_ffmpeg_multiplex_stream testmic:1 testmic:2 >/dev/null || exit 9' "$LK/ff/all_mics.pid"
    _assert_child_holds_no_lock
}

@test "a per-stream wrapper and its ffmpeg hold no lock descriptor, so the lock is free once the launcher exits [X-02]" {
    _use_wrapper_hardware_stand_ins
    export STREAM_STARTUP_DELAY=0
    _start_launcher 'acquire_lock 5 && start_ffmpeg_stream testmic 1 testmic >/dev/null || exit 9' "$LK/ff/testmic.pid"
    _assert_child_holds_no_lock
}

@test "stop after start in one process does not wait for a lock its own child kept alive [X-02]" {
    _write_mediamtx_stub
    run bash "$ROLE" eval "$_SEAMS"'
        start_mediamtx >/dev/null || exit 9
        mtx=$(<"$MEDIAMTX_PID_FILE")
        rc=0
        stop_mediamtx || rc=$?
        alive=no
        kill -0 "$mtx" 2>/dev/null && alive=yes
        printf "stop rc=%s mediamtx-alive=%s\n" "$rc" "$alive"'
    [[ "$output" == *"stop rc=0 mediamtx-alive=no"* ]]
    # The old code waited out 5 s for the lock its own child kept alive and
    # then went ahead without it
    ! grep -q 'Could not acquire lock\|Failed to acquire lock\|Refusing to stop' "$MEDIAMTX_LOG_FILE" || false
}

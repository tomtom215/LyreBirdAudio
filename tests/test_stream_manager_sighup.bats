#!/usr/bin/env bats
# What a SIGHUP does to an interactive manager process (register: item 8a of the
# residual manager work; follows the real `reload` command of LB-11/X-12).
#
# The handler installed for a run that is not under systemd said "SIGHUP: Reload
# configuration without full restart" and ran a full restart_mediamtx: stop every
# stream and MediaMTX, wait, start again. A terminal hang-up (a dropped SSH session
# during an interactive `start`) was therefore an outage. It now runs the same
# reload the `reload` command runs, which restarts nothing; while the process is in
# the middle of a lifecycle command of its own (it holds the lifecycle lock) the
# signal is logged and ignored, because a nested start of the streams could launch a
# second wrapper for a stream whose first one is not recorded yet.
#
# The script under test is the real one, executed as a command (the handlers are
# installed only for a process that runs the script itself, not for a sourced one):
# a copy of it whose final `main "$@"` is replaced by the test's code, so that the
# real trap installation and the real handler run. Stood in for, by function
# definitions after the script has loaded: restart_mediamtx and reload_mediamtx
# (each prints which one was called) in the first tests; in the last one only the
# things reload_mediamtx would start or stop, which record their calls.

load scratch_tmpdir

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    HU="$TEST_SCRATCH/hu"
    mkdir -p "$HU/copy" "$HU/cfg" "$HU/ff"
    cp "$PROJECT_ROOT/lyrebird-common.sh" "$HU/copy/"
    export HU PROJECT_ROOT
    export MEDIAMTX_CONFIG_DIR="$HU/cfg" MEDIAMTX_FFMPEG_DIR="$HU/ff" MEDIAMTX_PID_FILE="$HU/mtx.pid"
    export MEDIAMTX_LOCK_FILE="$HU/run.lock" MEDIAMTX_LOG_FILE="$HU/sm.log" STREAM_MANAGER_LOG_FILE="$HU/sm.log"
    export MEDIAMTX_RESTART_MARKER="$HU/restart.marker" MEDIAMTX_CLEANUP_MARKER="$HU/cleanup.marker"
    export MEDIAMTX_HOST=hup.invalid MEDIAMTX_BINARY="$HU/no-mediamtx"
    export LOCK_ACQUISITION_TIMEOUT=2
    : >"$HU/calls"
}

teardown() {
    scratch_teardown
}

# Run the manager script (a copy) as a command, not under systemd, with CODE in place of
# its final `main "$@"`
run_manager_with() {
    CODE="$1" python3 -I -c '
import os
src = open(os.environ["PROJECT_ROOT"] + "/lyrebird-stream-manager.sh").read()
old = "    main \"$@\"\n"
assert src.count(old) == 1
open(os.environ["HU"] + "/copy/lyrebird-stream-manager.sh", "w").write(src.replace(old, os.environ["CODE"] + "\n"))'
    run env -u INVOCATION_ID -u LYREBIRD_UNDER_SYSTEMD bash "$HU/copy/lyrebird-stream-manager.sh"
}

@test "SIGHUP runs the reload and never the full restart [SIGHUP reload]" {
    run_manager_with '
    restart_mediamtx() { echo "CALLED restart_mediamtx"; }
    reload_mediamtx() { echo "CALLED reload_mediamtx"; }
    trap -p HUP
    kill -HUP $$
    echo FINISHED'
    [ "$status" -eq 0 ]
    [[ "$output" == *"CALLED reload_mediamtx"* ]]
    [[ "$output" != *"CALLED restart_mediamtx"* ]]
    [[ "$output" == *"FINISHED"* ]]
    # the handler is the named function, not a restart in a trap string
    [[ "$output" == *"trap -- 'on_sighup' SIGHUP"* ]]
    grep -qF 'Received SIGHUP, reloading the MediaMTX configuration (nothing is restarted)' "$HU/sm.log"
}

@test "a reload that fails after SIGHUP is logged and the process goes on; nothing was stopped [SIGHUP reload]" {
    run_manager_with '
    restart_mediamtx() { echo "CALLED restart_mediamtx"; }
    stop_mediamtx() { echo "CALLED stop_mediamtx"; }
    reload_mediamtx() { return 7; }
    kill -HUP $$
    echo FINISHED'
    [ "$status" -eq 0 ]
    [[ "$output" == *"FINISHED"* ]]
    [[ "$output" != *"CALLED"* ]]
    grep -qF 'Reload after SIGHUP failed (exit 7); nothing was stopped' "$HU/sm.log"
}

@test "while this process runs a lifecycle command (it holds the lock) SIGHUP is logged and ignored, and reloads again once the lock is released [SIGHUP reload]" {
    run_manager_with '
    restart_mediamtx() { echo "CALLED restart_mediamtx"; }
    reload_mediamtx() { echo "CALLED reload_mediamtx"; }
    acquire_lock
    kill -HUP $$
    echo "AFTER-FIRST-HUP"
    release_lock
    kill -HUP $$
    echo FINISHED'
    [ "$status" -eq 0 ]
    [[ "$output" == *"AFTER-FIRST-HUP"* ]]
    [[ "$output" != *"CALLED restart_mediamtx"* ]]
    # exactly one reload: the second signal, after the lock was released
    [ "$(grep -c 'CALLED reload_mediamtx' <<<"$output")" -eq 1 ]
    [[ "$output" == *"AFTER-FIRST-HUP"*"CALLED reload_mediamtx"*"FINISHED"* ]]
    grep -qF 'Received SIGHUP while a lifecycle command is running in this process; not reloading' "$HU/sm.log"
}

@test "SIGHUP through the real reload_mediamtx stops nothing and restarts nothing; the idempotent start reconciles [SIGHUP reload]" {
    # Stood in for: the lifecycle lock, the ownership probes, the readiness wait and the start
    # path (each records its call), as in tests/test_stream_manager_reload.bats; the
    # configuration is rendered by the real generator for a binary that is not there
    run_manager_with '
    acquire_lock() { echo "acquire_lock" >>"$HU/calls"; return 0; }
    foreign_mediamtx_owner() { return 1; }
    owned_mediamtx_pid() { printf 4242; }
    wait_for_mediamtx_ready() { echo "wait_for_mediamtx_ready $1" >>"$HU/calls"; return 0; }
    start_mediamtx() { echo "start_mediamtx" >>"$HU/calls"; return 0; }
    stop_mediamtx() { echo "stop_mediamtx" >>"$HU/calls"; }
    restart_mediamtx() { echo "restart_mediamtx" >>"$HU/calls"; }
    terminate_process_group() { echo "terminate_process_group $*" >>"$HU/calls"; }
    sleep() { :; }
    kill -HUP $$
    echo FINISHED'
    [ "$status" -eq 0 ]
    [[ "$output" == *"FINISHED"* ]]
    grep -qx 'start_mediamtx' "$HU/calls"
    ! grep -qE 'stop_mediamtx|restart_mediamtx|terminate_process_group' "$HU/calls"
    [ -s "$HU/cfg/mediamtx.yml" ]
    [ ! -e "$HU/restart.marker" ]
    [ ! -e "$HU/cleanup.marker" ]
}

@test "the handler is the same function wherever the HUP trap is set again: after the critical section the trap is still on_sighup [SIGHUP reload]" {
    # exit_critical_section sets the traps again after a lock was taken; it used to put the
    # restart handler back
    run_manager_with '
    acquire_lock
    release_lock
    trap -p HUP'
    [ "$status" -eq 0 ]
    [[ "$output" == *"trap -- 'on_sighup' SIGHUP"* ]]
    [[ "$output" != *restart_mediamtx* ]]
}

#!/usr/bin/env bats
# `status` run without root (register: X-36).
#
# show_status probed each stream wrapper with `kill -0`. For another user's live
# process that fails with EPERM, so a non-root `status` printed every wrapper
# started by root as "Not running" while MediaMTX, the status file and the API
# all said it was publishing. The wrapper is now identified through the helpers
# of the process-ownership work (read_pid_safe and the /proc identity check): a
# process whose /proc entry cannot be read is "unknown", never "dead".
#
# The stack is started by root with the real manager (tests/manager_stage.bash);
# `status` is then run by another user with setpriv, over the same private
# directories made readable for that user. The test skips where setpriv is not
# there or that user can read other users' /proc/<pid>/exe.

load scratch_tmpdir
load manager_stage

setup() {
    scratch_setup
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
    stage_setup
}

teardown() {
    stage_teardown
    scratch_teardown
}

NOBODY=65534

# Skip unless another user can be set up as the reader. Makes the private tree
# readable and traversable for that user and gives it its own log file.
require_other_user() {
    command -v setpriv >/dev/null || skip "setpriv is not available"
    [ "$(id -u)" -eq 0 ] || skip "needs root to run a command as another user"
    local d="$TEST_SCRATCH"
    chmod -R a+rX "$TEST_SCRATCH"
    while [[ "$d" != "/" ]]; do
        if ! setpriv --reuid="$NOBODY" --regid="$NOBODY" --clear-groups test -x "$d"; then
            [[ -O "$d" ]] || skip "cannot make $d traversable for another user"
            chmod o+x "$d"
        fi
        d="$(dirname "$d")"
    done
    mkdir -p "$TEST_SCRATCH/nobody"
    chmod 777 "$TEST_SCRATCH/nobody"
}

# Run CODE as the other user with the real script and the stage's hardware seams
as_other_user() {
    run setpriv --reuid="$NOBODY" --regid="$NOBODY" --clear-groups \
        env STREAM_MANAGER_LOG_FILE="$TEST_SCRATCH/nobody/sm.log" LYREBIRD_STATE_DIR="$TEST_SCRATCH/nobody/state" \
        bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"; eval "$STAGE_SEAMS"; eval "$1"' _ "$1"
}

# The wrapper's /proc/<pid>/exe must be unreadable for the other user, or there is nothing to test
require_unreadable_exe() {
    local pid="$1"
    run setpriv --reuid="$NOBODY" --regid="$NOBODY" --clear-groups readlink "/proc/$pid/exe"
    [ "$status" -ne 0 ] || skip "this user can read other users' /proc/<pid>/exe"
}

@test "status as another user shows a stream wrapper started by root as running or unknown, never Not running [X-36]" {
    require_other_user
    device_add mic1 31
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    local wrapper
    wrapper="$(stream_pid mic1)"
    pid_running "$wrapper"
    require_unreadable_exe "$wrapper"

    # the control: root sees it running
    stage 'show_status'
    [[ "$output" == *"Status: "*"Running"*"(PID: $wrapper)"* ]]

    as_other_user 'show_status'
    [ "$status" -eq 0 ]
    # kill -0 gave EPERM here and this line said "Not running"
    [[ "$output" != *"Not running"*"mic1"* ]]
    [[ "$output" == *"mic1"* ]]
    [[ "$output" == *"Status: "*"Unknown"*"(PID: $wrapper;"* ]]
    [[ "$output" != *"    Status: "*"Not running"* ]]
    # nothing was removed or signalled
    [ -f "$ST/ff/mic1.pid" ]
    pid_running "$wrapper"
}

@test "status as another user still says Not running for a wrapper that is really gone [X-36]" {
    require_other_user
    device_add mic1 31
    device_add mic2 32
    stage 'COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    local w1 w2
    w1="$(stream_pid mic1)"
    w2="$(stream_pid mic2)"
    require_unreadable_exe "$w1"
    # mic2's wrapper and its FFmpeg die; its PID file stays behind
    kill -KILL "$w2"
    wait_until '! pid_running '"$w2" 5

    as_other_user 'show_status'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Status: "*"Unknown"*"(PID: $w1;"* ]]
    [[ "$output" == *"    Status: "*"Not running"* ]]
    [ "$(grep -c 'Not running' <<<"$output")" -eq 1 ]
}

@test "status as another user shows the multiplex wrapper as running or unknown, and does not fall back to the per-device listing [X-36]" {
    require_other_user
    device_add mic1 31
    device_add mic2 33
    export STREAM_MODE=multiplex MULTIPLEX_STREAM_NAME=mix
    stage 'resolve_multiplex_stream_name; COMMAND=start; start_mediamtx'
    [ "$status" -eq 0 ]
    local wrapper
    wrapper="$(stream_pid mix)"
    pid_running "$wrapper"
    require_unreadable_exe "$wrapper"

    as_other_user 'resolve_multiplex_stream_name; show_status'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Multiplex stream (combining 2 devices):"* ]]
    [[ "$output" == *"Status: "*"Unknown"*"(PID: $wrapper;"* ]]
    [[ "$output" != *"Not running"* ]]
}

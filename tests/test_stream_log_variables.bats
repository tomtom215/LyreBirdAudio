#!/usr/bin/env bats
# The manager's own log file and MediaMTX's output file are two different
# files with two different variables (register: X-15).
#
# lyrebird-stream-manager.sh used to read BOTH from MEDIAMTX_LOG_FILE, so an
# operator who set it to move MediaMTX's output also moved the manager's own log
# into the same file. The real script is sourced in a child process (its
# set -euo pipefail must not leak into bats) and the real log() is called.

load scratch_tmpdir

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export PROJECT_ROOT
    D="$TEST_SCRATCH/d"
    mkdir -p "$D"
}

teardown() {
    scratch_teardown
}

# Run CODE with the real script sourced, with no log variable inherited from
# the environment of the test run.
sm_clean() {
    env -u STREAM_MANAGER_LOG_FILE -u MEDIAMTX_LOG_FILE "$@"
}

@test "the manager's own log follows STREAM_MANAGER_LOG_FILE and leaves MEDIAMTX_LOG_FILE alone [X-15]" {
    run sm_clean STREAM_MANAGER_LOG_FILE="$D/manager.log" MEDIAMTX_LOG_FILE="$D/mediamtx.out" \
        bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"
                 log INFO "hello from the manager"
                 printf "LOG_FILE=%s\nMEDIAMTX_LOG_FILE=%s\n" "$LOG_FILE" "$MEDIAMTX_LOG_FILE"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"LOG_FILE=$D/manager.log"* ]]
    [[ "$output" == *"MEDIAMTX_LOG_FILE=$D/mediamtx.out"* ]]
    grep -q 'hello from the manager' "$D/manager.log"
    [ ! -e "$D/mediamtx.out" ]
}

@test "MEDIAMTX_LOG_FILE alone no longer moves the manager's own log [X-15]" {
    run sm_clean MEDIAMTX_LOG_FILE="$D/mediamtx.out" \
        bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"
                 printf "LOG_FILE=%s\nMEDIAMTX_LOG_FILE=%s\n" "$LOG_FILE" "$MEDIAMTX_LOG_FILE"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"LOG_FILE=/var/log/lyrebird-stream-manager.log"* ]]
    [[ "$output" == *"MEDIAMTX_LOG_FILE=$D/mediamtx.out"* ]]
}

@test "STREAM_MANAGER_LOG_FILE alone leaves MediaMTX's output file at its default [X-15]" {
    run sm_clean STREAM_MANAGER_LOG_FILE="$D/manager.log" \
        bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"
                 printf "LOG_FILE=%s\nMEDIAMTX_LOG_FILE=%s\n" "$LOG_FILE" "$MEDIAMTX_LOG_FILE"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"LOG_FILE=$D/manager.log"* ]]
    [[ "$output" == *"MEDIAMTX_LOG_FILE=/var/log/mediamtx.out"* ]]
}

@test "both log file defaults are unchanged when no variable is set [X-15]" {
    run sm_clean bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"
                          printf "LOG_FILE=%s\nMEDIAMTX_LOG_FILE=%s\n" "$LOG_FILE" "$MEDIAMTX_LOG_FILE"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"LOG_FILE=/var/log/lyrebird-stream-manager.log"* ]]
    [[ "$output" == *"MEDIAMTX_LOG_FILE=/var/log/mediamtx.out"* ]]
}

@test "the help text names both log variables [X-15]" {
    run sm_clean STREAM_MANAGER_LOG_FILE="$D/manager.log" MEDIAMTX_LOG_FILE="$D/mediamtx.out" \
        bash "$PROJECT_ROOT/lyrebird-stream-manager.sh" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"System log: $D/manager.log (STREAM_MANAGER_LOG_FILE)"* ]]
    [[ "$output" == *"MediaMTX log: $D/mediamtx.out (MEDIAMTX_LOG_FILE)"* ]]
}

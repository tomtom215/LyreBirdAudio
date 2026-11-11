#!/usr/bin/env bats
# The `reload` command of lyrebird-stream-manager.sh (register: LB-11, X-12;
# decision D12): what the unit's ExecReload= runs. The sample unit's
# `ExecReload=... reload` ended in "Unknown command" (exit 1), and the signals the
# units sent instead (HUP, USR1) are not handled by MediaMTX 1.21.1.
#
# The real script is sourced in a fresh bash for every call and reload_mediamtx,
# mediamtx_changed_keys, mediamtx_reload_effect and the real MediaMTX
# configuration generator run. Stood in for: the lifecycle lock, the ownership
# probes (tested by tests/test_stream_manager_ownership.bats), the readiness wait
# and the idempotent start path (each records its call). A real MediaMTX and real
# FFmpeg run the whole thing in the live test at the end of test_mediamtx_live.bats
# (tests/reload_e2e.bash).

load scratch_tmpdir

setup() {
    scratch_setup
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
    RL="$TEST_SCRATCH/rl"
    mkdir -p "$RL"/{cfg,ff}
    export PROJECT_ROOT RL
    export MEDIAMTX_CONFIG_DIR="$RL/cfg" MEDIAMTX_FFMPEG_DIR="$RL/ff" MEDIAMTX_PID_FILE="$RL/mtx.pid"
    export MEDIAMTX_LOCK_FILE="$RL/run.lock" MEDIAMTX_LOG_FILE="$RL/sm.log"
    export MEDIAMTX_RESTART_MARKER="$RL/restart.marker" MEDIAMTX_CLEANUP_MARKER="$RL/cleanup.marker"
    export MEDIAMTX_HOST=reload.invalid MEDIAMTX_BINARY="$RL/no-mediamtx"
    SCRIPT="$PROJECT_ROOT/lyrebird-stream-manager.sh"
    : >"$RL/calls"
}

teardown() {
    scratch_teardown
}

# reload with every seam recording its call; the tests override what they need
# through $SEAMS (shell code evaluated after the defaults)
run_reload() {
    export SEAMS="${SEAMS:-}"
    run bash -c '
        source "$1" >/dev/null 2>&1
        acquire_lock() { echo "acquire_lock" >>"$RL/calls"; return 0; }
        foreign_mediamtx_owner() { return 1; }
        owned_mediamtx_pid() { printf 4242; }
        wait_for_mediamtx_ready() { echo "wait_for_mediamtx_ready $1" >>"$RL/calls"; return 0; }
        start_mediamtx() { echo "start_mediamtx" >>"$RL/calls"; return "${START_RC:-0}"; }
        stop_mediamtx() { echo "stop_mediamtx" >>"$RL/calls"; }
        restart_mediamtx() { echo "restart_mediamtx" >>"$RL/calls"; }
        terminate_process_group() { echo "terminate_process_group $*" >>"$RL/calls"; }
        sleep() { :; }
        eval "$SEAMS"
        rc=0
        reload_mediamtx || rc=$?
        echo "rc=$rc skip_cleanup=$SKIP_CLEANUP"
        exit "$rc"' _ "$SCRIPT"
}

calls() { tr '\n' ' ' <"$RL/calls"; }

# ---------------------------------------------------------------------------
# mediamtx_changed_keys / mediamtx_reload_effect
# ---------------------------------------------------------------------------

keys_between() {
    run bash -c 'source "$1" >/dev/null 2>&1; mediamtx_changed_keys "$2" "$3"' _ "$SCRIPT" "$1" "$2"
}

@test "mediamtx_changed_keys: identical texts, comments and blank lines change nothing [LB-11]" {
    keys_between $'logLevel: info\napi: yes\n' $'logLevel: info\napi: yes\n'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    keys_between $'# Managed\nlogLevel: info\n\npaths:\n  a:\n    source: publisher\n' $'logLevel: info\n# another comment\npaths:\n  a:\n    source: publisher\n\n'
    [ -z "$output" ]
}

@test "mediamtx_changed_keys: names changed, added and removed keys, and a changed block under paths [LB-11]" {
    keys_between $'logLevel: info\nhls: no\napi: yes\npaths:\n  a:\n    source: publisher\n' \
        $'logLevel: warn\nhls: no\nmoq: no\npaths:\n  a:\n    source: publisher\n    sourceProtocol: tcp\n'
    [ "$status" -eq 0 ]
    [ "$output" = $'logLevel\napi\npaths\nmoq' ]
}

@test "mediamtx_reload_effect: says per key whether publishers stay, which of them are disconnected, and when it is not known [LB-11, X-12]" {
    local key
    for key in api apiAddress rtmp hls webrtc srt; do
        run bash -c 'source "$1" >/dev/null 2>&1; mediamtx_reload_effect "$2"' _ "$SCRIPT" "$key"
        [[ "$output" == *"connected publishers stay connected"* ]]
    done
    for key in logLevel readTimeout writeTimeout metrics metricsAddress rtsp rtspAddress rtspTransports; do
        run bash -c 'source "$1" >/dev/null 2>&1; mediamtx_reload_effect "$2"' _ "$SCRIPT" "$key"
        [[ "$output" == *"disconnects every publisher"* ]]
    done
    run bash -c 'source "$1" >/dev/null 2>&1; mediamtx_reload_effect paths' _ "$SCRIPT"
    [[ "$output" == *"a path entry that changed are disconnected"* ]]
    run bash -c 'source "$1" >/dev/null 2>&1; mediamtx_reload_effect someFutureKey' _ "$SCRIPT"
    [[ "$output" == *"not verified for this key"* ]]
}

# ---------------------------------------------------------------------------
# reload_mediamtx
# ---------------------------------------------------------------------------

@test "reload: an unchanged configuration leaves MediaMTX alone, says so, and only reconciles the streams through the start path [LB-11]" {
    # the real generator writes the file once; a second render is the same text
    SEAMS='generate_mediamtx_config' run_reload >/dev/null
    : >"$RL/calls"
    run_reload
    [ "$status" -eq 0 ]
    [[ "$output" == *"MediaMTX configuration is unchanged; nothing for MediaMTX (PID 4242) to reload"* ]]
    [[ "$output" == *"rc=0 skip_cleanup=true" ]]
    [ "$(calls)" = "acquire_lock start_mediamtx " ]
}

@test "reload: a changed configuration is reported key by key with its effect, MediaMTX is waited for and never stopped or restarted [LB-11, X-12]" {
    # a file as an older generator (or an operator) left it, differing in a publisher-safe and a publisher-dropping key
    run_reload >/dev/null
    : >"$RL/calls"
    sed -E -i 's/^hls: no/hls: yes/; s/^logLevel: info/logLevel: warn/' "$RL/cfg/mediamtx.yml"
    run_reload
    [ "$status" -eq 0 ]
    [[ "$output" == *"configuration key 'logLevel' changed: applied live by MediaMTX, which disconnects every publisher"* ]]
    [[ "$output" == *"configuration key 'hls' changed: applied live by MediaMTX; connected publishers stay connected"* ]]
    [[ "$output" == *"is running with the new configuration; it was not restarted"* ]]
    [ "$(calls)" = "acquire_lock wait_for_mediamtx_ready 4242 start_mediamtx " ]
    grep -q '^hls: no' "$RL/cfg/mediamtx.yml"
    grep -q '^logLevel: info' "$RL/cfg/mediamtx.yml"
}

@test "reload: a MediaMTX that does not answer after the change is an error and the start path is not run [LB-11]" {
    run_reload >/dev/null
    : >"$RL/calls"
    sed -E -i 's/^hls: no/hls: yes/' "$RL/cfg/mediamtx.yml"
    SEAMS='wait_for_mediamtx_ready() { echo wait >>"$RL/calls"; return 1; }' run_reload
    [ "$status" -eq 1 ]
    [[ "$output" == *"did not come back after the new configuration"* ]]
    [[ "$output" == *"skip_cleanup=true" ]]
    [ "$(calls)" = "acquire_lock wait " ]
}

@test "reload: not running is E_MEDIAMTX_DOWN (7) and starts nothing, another owner is E_OWNERSHIP (8) and touches nothing, the lock is E_LOCK_FAILED (5) [LB-11]" {
    SEAMS='owned_mediamtx_pid() { return 1; }; generate_mediamtx_config() { echo generate >>"$RL/calls"; }' run_reload
    [ "$status" -eq 7 ]
    [[ "$output" == *"Cannot reload: the MediaMTX of this manager is not running (use start)"* ]]
    [[ "$output" == *"skip_cleanup=true" ]]
    [ "$(calls)" = "acquire_lock " ]

    : >"$RL/calls"
    SEAMS='foreign_mediamtx_owner() { echo "mediamtx.service is active"; return 0; }; generate_mediamtx_config() { echo generate >>"$RL/calls"; }' run_reload
    [ "$status" -eq 8 ]
    [[ "$output" == *"Refusing to reload: mediamtx.service is active"* ]]
    [ "$(calls)" = "acquire_lock " ]
    [ ! -e "$RL/cfg/mediamtx.yml" ]

    : >"$RL/calls"
    SEAMS='acquire_lock() { return 1; }; generate_mediamtx_config() { echo generate >>"$RL/calls"; }' run_reload
    [ "$status" -eq 5 ]
    [[ "$output" == *"Refusing to reload: another lifecycle command holds the lock"* ]]
    [ "$(calls)" = "" ]
}

@test "reload: a configuration that cannot be generated is E_CONFIG_ERROR (4) with MediaMTX and the streams left alone [LB-11]" {
    SEAMS='generate_mediamtx_config() { return 1; }' run_reload
    [ "$status" -eq 4 ]
    [[ "$output" == *"the MediaMTX configuration could not be generated; MediaMTX (PID 4242) was left alone"* ]]
    [[ "$output" == *"skip_cleanup=true" ]]
    [ "$(calls)" = "acquire_lock " ]
}

@test "reload: the exit status of the start path is the status of reload [LB-11]" {
    START_RC=4 run_reload
    [ "$status" -eq 4 ]
}

@test "reload never calls stop, restart or a process signal, on any path [LB-11, D1]" {
    run_reload >/dev/null
    sed -E -i 's/^hls: no/hls: yes/' "$RL/cfg/mediamtx.yml"
    : >"$RL/calls"
    run_reload
    SEAMS='owned_mediamtx_pid() { return 1; }' run_reload
    SEAMS='generate_mediamtx_config() { return 1; }' run_reload
    ! grep -E 'stop_mediamtx|restart_mediamtx|terminate_process_group' "$RL/calls"
    # and nothing in the function can: the static control
    run bash -c 'source "$1" >/dev/null 2>&1; declare -f reload_mediamtx mediamtx_reload_effect mediamtx_changed_keys' _ "$SCRIPT"
    [[ "$output" != *stop_mediamtx* && "$output" != *restart_mediamtx* && "$output" != *terminate_process_group* && "$output" != *"kill "* && "$output" != *pkill* ]]
}

# ---------------------------------------------------------------------------
# the command
# ---------------------------------------------------------------------------

@test "the reload command exists: main runs check_root, check_dependencies, setup_directories, validate_config and reload_mediamtx, and passes its status on [LB-11, X-12]" {
    run bash -c '
        source "$1" >/dev/null 2>&1
        check_root() { echo check_root >>"$RL/calls"; }
        check_dependencies() { echo check_dependencies >>"$RL/calls"; }
        setup_directories() { echo setup_directories >>"$RL/calls"; }
        validate_config() { echo validate_config >>"$RL/calls"; }
        reload_mediamtx() { echo reload_mediamtx >>"$RL/calls"; return 7; }
        main reload' _ "$SCRIPT"
    [ "$status" -eq 7 ]
    [[ "$output" != *"Unknown command"* ]]
    [ "$(calls)" = "check_root check_dependencies setup_directories validate_config reload_mediamtx " ]
}

@test "a reload with an invalid device configuration is refused before anything is generated [LB-11]" {
    run bash -c '
        source "$1" >/dev/null 2>&1
        check_root() { :; }
        check_dependencies() { :; }
        setup_directories() { :; }
        validate_config() { return 1; }
        reload_mediamtx() { echo reload_mediamtx >>"$RL/calls"; }
        main reload' _ "$SCRIPT"
    [ "$status" -eq 4 ]
    [ "$(calls)" = "" ]
}

@test "help lists the reload command and what it does and does not do [LB-11]" {
    run bash "$SCRIPT" help
    [ "$status" -eq 0 ]
    [[ "$output" == *"    reload      Re-render the MediaMTX configuration"* ]]
    [[ "$output" == *"Nothing is"* ]]
    [[ "$output" == *"ExecReload="* ]]
}

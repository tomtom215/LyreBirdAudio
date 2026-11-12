#!/usr/bin/env bats
# X-54: the display code (the orchestrator's state and the diagnostics) finds this
# installation's processes by identity, never by name (decision D11).
#
# They used `pgrep -x mediamtx`, `pgrep -x ffmpeg` (every FFmpeg on the host counted as
# a stream) and `pgrep -f <binary>` / `pgrep -f lyrebird-stream-manager.sh`: a process
# that merely carries the name or has the path in its command line counted. The real
# functions run against real processes. The processes to tell apart are decoys
# (tests/process_decoys.bash): copies of the bash binary on a script that only waits,
# so /proc/<pid>/exe, argv and the name are what the test chooses. pgrep is a shim that
# only ever matches decoys, so the old code hits decoys, which is how the defect shows,
# and never a process of the machine the suite runs on.

load scratch_tmpdir
load process_decoys

setup() {
    scratch_setup
    decoy_setup
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    MX="$TEST_SCRATCH/mx"
    export PROJECT_ROOT TEST_SCRATCH MX
    mkdir -p "$MX/bin" "$MX/cfg" "$MX/ff" "$MX/other" "$MX/shbin" "$MX/ffbin"
    export MEDIAMTX_BINARY="$MX/bin/mediamtx" MEDIAMTX_CONFIG_FILE="$MX/cfg/mediamtx.yml" MEDIAMTX_FFMPEG_DIR="$MX/ff"
    HOLD="$MX/hold.sh"
    decoy_bash_copy "$MEDIAMTX_BINARY"
    decoy_hold_script "$HOLD"
    decoy_hold_script "$MEDIAMTX_CONFIG_FILE"
    # a bash for the wrappers, as the manager's are: argv[1] is the generated stream script
    decoy_bash_copy "$MX/shbin/bash"
    decoy_hold_script "$MX/ff/mic1.sh"
    decoy_hold_script "$MX/ff/mic2.sh"
    decoy_hold_script "$MX/ff/sub-mic.sh"
}

teardown() {
    decoy_teardown
    scratch_teardown
}

# The real MediaMTX of this installation: the program at MEDIAMTX_BINARY on its configuration
start_real_mediamtx() {
    decoy_spawn real_mtx "$MEDIAMTX_BINARY" "$MEDIAMTX_CONFIG_FILE"
}

# Two wrappers of this installation: bash on <ff dir>/<stream>.sh
start_real_wrappers() {
    decoy_spawn wrapper1 "$MX/shbin/bash" "$MX/ff/mic1.sh"
    decoy_spawn wrapper2 "$MX/shbin/bash" "$MX/ff/mic2.sh"
}

# Look-alikes: everything a name or a pattern takes for MediaMTX, an FFmpeg stream or
# the stream manager, and none of it is
start_lookalikes() {
    # a program called mediamtx somewhere else (another installation), on no configuration of ours
    decoy_bash_copy "$MX/other/mediamtx"
    decoy_spawn other_mtx "$MX/other/mediamtx" "$HOLD"
    # the same configuration run by another program (the name pgrep -x sees is its own)
    decoy_bash_copy "$MX/other/mediamtx2"
    decoy_spawn other_exe "$MX/other/mediamtx2" "$MEDIAMTX_CONFIG_FILE"
    # an editor whose command line holds the binary's path
    decoy_spawn_as editor vim "$MX/shbin/bash" "$HOLD" "$MEDIAMTX_BINARY"
    # a process whose command line names the stream manager script
    decoy_spawn_as sm_named lyrebird-stream-manager.sh "$MX/shbin/bash" "$HOLD" lyrebird-stream-manager.sh
    # every FFmpeg of the host that is not ours: called ffmpeg, children of nothing of ours
    decoy_bash_copy "$MX/ffbin/ffmpeg"
    decoy_spawn ffmpeg1 "$MX/ffbin/ffmpeg" "$HOLD"
    decoy_spawn ffmpeg2 "$MX/ffbin/ffmpeg" "$HOLD"
    decoy_spawn ffmpeg3 "$MX/ffbin/ffmpeg" "$HOLD"
    # a stream script run by another program, and one in a directory below ours
    decoy_bash_copy "$MX/other/sh"
    decoy_spawn other_wrapper "$MX/other/sh" "$MX/ff/mic1.sh"
    mkdir -p "$MX/ff/sub"
    decoy_hold_script "$MX/ff/sub/deep.sh"
    decoy_spawn deep_wrapper "$MX/shbin/bash" "$MX/ff/sub/deep.sh"
}

# The orchestrator's state after the real refresh_system_state: "running=<bool> streams=<n>"
orch_state() {
    run env MEDIAMTX_BINARY="$MEDIAMTX_BINARY" MEDIAMTX_CONFIG_FILE="$MEDIAMTX_CONFIG_FILE" MEDIAMTX_FFMPEG_DIR="$MEDIAMTX_FFMPEG_DIR" \
        bash -c '
        source "$PROJECT_ROOT/lyrebird-orchestrator.sh" >/dev/null 2>&1
        log() { :; }
        refresh_system_state
        echo "running=$MEDIAMTX_RUNNING streams=$ACTIVE_STREAMS"'
}

# ---------------------------------------------------------------------------
# the library's scans
# ---------------------------------------------------------------------------

@test "lyrebird_mediamtx_pids names only the program at the binary's path running this configuration, among look-alikes [X-54]" {
    start_real_mediamtx
    start_lookalikes
    run bash -c 'source "$PROJECT_ROOT/lyrebird-common.sh"; lyrebird_mediamtx_pids "$MEDIAMTX_BINARY" "$MEDIAMTX_CONFIG_FILE"'
    [ "$status" -eq 0 ]
    [ "$output" = "$(decoy_pid real_mtx)" ]
    # another configuration: none, and the status says so
    run bash -c 'source "$PROJECT_ROOT/lyrebird-common.sh"; lyrebird_mediamtx_pids "$MEDIAMTX_BINARY" "$MX/cfg/other.yml"'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "lyrebird_stream_wrapper_pids names the manager's wrapper scripts directly in its directory, run by a bash, and no FFmpeg [X-54]" {
    start_real_wrappers
    start_lookalikes
    run bash -c 'source "$PROJECT_ROOT/lyrebird-common.sh"; lyrebird_stream_wrapper_pids "$MEDIAMTX_FFMPEG_DIR" | sort'
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n%s\n' "$(decoy_pid wrapper1)" "$(decoy_pid wrapper2)" | sort)" ]
    run bash -c 'source "$PROJECT_ROOT/lyrebird-common.sh"; lyrebird_stream_wrapper_pids "$MX/empty"'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# the orchestrator's state
# ---------------------------------------------------------------------------

@test "the orchestrator does not take a decoy called mediamtx or any FFmpeg of the host for MediaMTX and its streams [X-54]" {
    start_lookalikes
    orch_state
    [ "$status" -eq 0 ]
    [ "$output" = "running=false streams=0" ] || {
        echo "$output"
        false
    }
}

@test "the orchestrator counts this installation's MediaMTX and its wrappers, and only those [X-54]" {
    start_real_mediamtx
    start_real_wrappers
    start_lookalikes
    orch_state
    [ "$status" -eq 0 ]
    [ "$output" = "running=true streams=2" ] || {
        echo "$output"
        false
    }
}

@test "the orchestrator needs no pgrep: the state is the same without it [X-54]" {
    start_real_mediamtx
    start_real_wrappers
    # a PATH without pgrep (and with the shims the decoy setup put first removed)
    local nopg="$TEST_SCRATCH/nopgrep" t
    mkdir -p "$nopg"
    for t in bash cat head wc readlink dirname basename grep awk sed date mktemp sleep id tr cut env; do
        ln -s "$(command -v "$t")" "$nopg/$t"
    done
    run env PATH="$nopg" MEDIAMTX_BINARY="$MEDIAMTX_BINARY" MEDIAMTX_CONFIG_FILE="$MEDIAMTX_CONFIG_FILE" MEDIAMTX_FFMPEG_DIR="$MEDIAMTX_FFMPEG_DIR" \
        "$nopg/bash" -c '
        source "$PROJECT_ROOT/lyrebird-orchestrator.sh" >/dev/null 2>&1
        log() { :; }
        check_dependencies && echo "deps ok"
        refresh_system_state
        echo "running=$MEDIAMTX_RUNNING streams=$ACTIVE_STREAMS"'
    [[ "$output" == *"deps ok"* ]] || {
        echo "$output"
        false
    }
    [[ "$output" == *"running=true streams=2"* ]]
}

# ---------------------------------------------------------------------------
# the diagnostics
# ---------------------------------------------------------------------------

# the diagnostics' view after the real functions: pid of MediaMTX it caches, and the manager status
diag_view() {
    run env MEDIAMTX_BINARY="$MEDIAMTX_BINARY" MEDIAMTX_CONFIG_FILE="$MEDIAMTX_CONFIG_FILE" STREAM_MANAGER_LOG_FILE="$TEST_SCRATCH/none.log" \
        bash -c '
        source "$PROJECT_ROOT/lyrebird-diagnostics.sh" >/dev/null 2>&1
        cache_mediamtx_pid
        echo "pid=[$MEDIAMTX_PID]"
        echo "manager=$(get_stream_manager_status)"'
}

@test "the diagnostics cache no PID and report no running manager for look-alikes: a decoy called mediamtx, an editor with the binary's path, a command line naming the manager [X-54]" {
    start_lookalikes
    diag_view
    [ "$status" -eq 0 ]
    [[ "$output" == *"pid=[]"* ]] || {
        echo "$output"
        false
    }
    [[ "$output" == *"manager=not_configured"* ]] || {
        echo "$output"
        false
    }
}

@test "the diagnostics cache the PID of this installation's MediaMTX and call the node running [X-54]" {
    start_real_mediamtx
    start_lookalikes
    diag_view
    [ "$status" -eq 0 ]
    [[ "$output" == *"pid=[$(decoy_pid real_mtx)]"* ]] || {
        echo "$output"
        false
    }
    [[ "$output" == *"manager=running"* ]]
}

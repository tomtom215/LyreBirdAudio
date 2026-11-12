#!/usr/bin/env bats
# Unit tests for lyrebird-stream-manager.sh functions
# Run with: bats tests/test_stream_manager.bats
# Every test runs the REAL script (sm sources it in a fresh bash: its set -euo pipefail
# must not leak into bats). The tests that used to re-define a function in the test and
# test the copy (register: X-18) were converted to the real function or, where the same
# behaviour has a real-function test in another file, removed; see the commit that did it.

load scratch_tmpdir

setup() {
    scratch_setup
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"

    # Source common library first
    source "$PROJECT_ROOT/lyrebird-common.sh" 2>/dev/null || true

    # Create a mock log function if not defined
    if ! declare -f log &>/dev/null; then
        log() { :; }
    fi

    # Whatever the real script writes goes to private files, and its ALSA tree is a private one
    export PROJECT_ROOT TEST_SCRATCH
    export STREAM_MANAGER_LOG_FILE="$TEST_SCRATCH/sm.log" MEDIAMTX_LOG_FILE="$TEST_SCRATCH/sm.log"
    export ASOUND_PROC_ROOT="$TEST_SCRATCH/asound"
    mkdir -p "$ASOUND_PROC_ROOT"
}

# Run CODE in a fresh bash that has sourced the REAL script (set +e after the load, as the
# bats test needs to see the status, not die of errexit); status and output are bats' `run`
sm() {
    run bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1; set +e; eval "$1"' _ "$1"
}

teardown() {
    scratch_teardown
}

# ============================================================================
# Stream name sanitization (the real sanitize_path_name)
# ============================================================================

@test "sanitize stream name removes special characters" {
    sm 'sanitize_path_name "My Device (USB Audio)"'
    [ "$status" -eq 0 ]
    [ "$output" = "my_device_usb_audio" ]
    [[ ! "$output" =~ [\(\)\ ] ]]
}

@test "sanitize stream name handles empty input" {
    sm 'sanitize_path_name ""'
    [ "$status" -eq 0 ]
    # nothing usable is left: the name is a timestamped fallback
    [[ "$output" =~ ^stream_[0-9]+$ ]]
}

@test "sanitize stream name keeps a name within MAX_STREAM_NAME_LENGTH and shortens a longer one to exactly that length with a hash suffix" {
    sm 'echo "max=$MAX_STREAM_NAME_LENGTH"
        sanitize_path_name "this_is_a_valid_length_name"
        sanitize_path_name "this_is_a_very_very_very_very_very_very_long_stream_name_that_exceeds_limit" 2>/dev/null'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "max=48" ]
    [ "${lines[1]}" = "this_is_a_valid_length_name" ]
    [ "${#lines[2]}" -eq 48 ]
    [[ "${lines[2]}" =~ ^[a-z_]{39}_[0-9a-f]{8}$ ]]
    # what is kept is the start of the name
    [[ "this_is_a_very_very_very_very_very_very_long_stream_name_that_exceeds_limit" == "${lines[2]:0:39}"* ]]
}

# ============================================================================
# Library version compatibility (the real check_version_compatibility)
# ============================================================================
# (the comparison of the manager's two version strings; the installer's and the
# updater's own version_compare functions are tested in test_install_mediamtx.bats
# and test_lyrebird_updater.bats)

@test "check_version_compatibility accepts the required version exactly" {
    sm 'lyrebird_common_version() { echo "1.0.0"; }; echo "required=$MIN_COMPATIBLE_COMMON_VERSION"; check_version_compatibility; echo "rc=$?"'
    [[ "$output" == *"required=1.0.0"* ]]
    [[ "$output" == *"rc=0"* ]]
}

@test "check_version_compatibility accepts a newer library, by any of major, minor and patch" {
    sm 'for v in 2.0.0 1.1.0 1.0.1 10.0.0; do lyrebird_common_version() { echo "$v"; }; check_version_compatibility; echo "$v rc=$?"; done'
    [[ "$output" == *"2.0.0 rc=0"* ]]
    [[ "$output" == *"1.1.0 rc=0"* ]]
    [[ "$output" == *"1.0.1 rc=0"* ]]
    [[ "$output" == *"10.0.0 rc=0"* ]]
}

@test "check_version_compatibility refuses an older library with a warning that names both versions" {
    sm 'lyrebird_common_version() { echo "0.9.5"; }; check_version_compatibility; echo "rc=$?"'
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"lyrebird-common.sh version 0.9.5 is older than required 1.0.0"* ]]
}

# ============================================================================
# PID files (the real read_pid_safe)
# ============================================================================

@test "PID validation accepts valid PID" {
    sm 'sleep 30 >/dev/null 2>&1 3>&- & pid=$!
        trap "kill $pid 2>/dev/null" EXIT
        echo "$pid" >"$TEST_SCRATCH/p.pid"
        echo "got=$(read_pid_safe "$TEST_SCRATCH/p.pid") want=$pid"'
    [ "$status" -eq 0 ]
    [[ "$output" =~ got=([0-9]+)\ want=([0-9]+) ]]
    [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]
}

@test "PID validation rejects negative PID" {
    echo "-1" >"$TEST_SCRATCH/p.pid"
    sm 'echo "got=[$(read_pid_safe "$TEST_SCRATCH/p.pid")]"; [[ ! -e "$TEST_SCRATCH/p.pid" ]] && echo "file removed"'
    [[ "$output" == *"got=[]"* ]]
    # a PID file with invalid content is removed, not kept
    [[ "$output" == *"file removed"* ]]
}

@test "PID validation rejects non-numeric PID" {
    echo "abc" >"$TEST_SCRATCH/p.pid"
    sm 'echo "got=[$(read_pid_safe "$TEST_SCRATCH/p.pid")]"; [[ ! -e "$TEST_SCRATCH/p.pid" ]] && echo "file removed"'
    [[ "$output" == *"got=[]"* ]]
    [[ "$output" == *"file removed"* ]]
}

@test "PID validation rejects zero and a PID above the system maximum" {
    local bad
    for bad in 0 99999999999; do
        echo "$bad" >"$TEST_SCRATCH/p.pid"
        sm 'echo "got=[$(read_pid_safe "$TEST_SCRATCH/p.pid")] max=$SYSTEM_PID_MAX"; [[ ! -e "$TEST_SCRATCH/p.pid" ]] && echo "file removed"'
        [[ "$output" == *"got=[]"* ]] || {
            echo "$bad: $output"
            false
        }
        [[ "$output" == *"file removed"* ]]
    done
}

# ============================================================================
# Device entries ("name:card", as detect_audio_devices prints them)
# ============================================================================

@test "device info parsing extracts name and card" {
    mkdir -p "$ASOUND_PROC_ROOT/card3/pcm0c"
    sm 'stream_outcome_expect "Blue_Yeti:3" 2>/dev/null
        for p in "${OUTCOME_PATHS[@]}"; do echo "device=${OUTCOME_DEVICE[$p]} card=${OUTCOME_CARD[$p]}"; done'
    [ "$status" -eq 0 ]
    [ "$output" = "device=Blue_Yeti card=3" ]
}

@test "device info parsing skips an entry with no card" {
    sm 'stream_outcome_expect "Blue_Yeti" 2>/dev/null; echo "streams=${#OUTCOME_PATHS[@]}"'
    [ "$status" -eq 0 ]
    [ "$output" = "streams=0" ]
}

# ============================================================================
# Configuration (defaults and environment overrides of the real script)
# ============================================================================

@test "default values are set for timeouts" {
    run env -u MEDIAMTX_API_TIMEOUT bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1; echo "$MEDIAMTX_API_TIMEOUT"'
    [ "$status" -eq 0 ]
    [ "$output" -eq 60 ]
}

@test "environment variables override defaults" {
    run env MEDIAMTX_API_TIMEOUT=120 bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1; echo "$MEDIAMTX_API_TIMEOUT"'
    [ "$status" -eq 0 ]
    [ "$output" -eq 120 ]
}

# ============================================================================
# Reserved stream names (the real sanitize_path_name; canonical_stream_name's
# own rejection of reserved words is tested in test_stream_names.bats)
# ============================================================================

@test "reserved name check rejects 'control'" {
    sm 'sanitize_path_name control 2>/dev/null'
    [ "$status" -eq 0 ]
    # a reserved name is not used as it is: it gets a prefix
    [ "$output" = "stream_control" ]
}

@test "reserved name check allows 'mic1'" {
    sm 'sanitize_path_name mic1 2>/dev/null'
    [ "$status" -eq 0 ]
    [ "$output" = "mic1" ]
}

# ============================================================================
# Lock File Tests
# ============================================================================
# The lock tests that used to live here exercised inline copies of the code
# (an `acquire_lock` redefined in the test, and a bare `flock`). The real
# acquire_lock/release_lock, the config lock and their callers are tested in
# test_stream_manager_locks.bats, with real concurrent processes.

# ============================================================================
# Network connectivity (the real check_network_connectivity)
# ============================================================================
# The function keeps its failure counter in /run, a path it does not let a caller
# move; the tests that reach it run in a private mount namespace with a tmpfs over
# /run (unshare --mount), so the machine's /run is never written.

# Stand-ins for `ip` (the default route) and `ping` (records its arguments), in $TEST_SCRATCH/netbin
network_shims() {
    mkdir -p "$TEST_SCRATCH/netbin"
    printf '%s\n' '#!/bin/bash' 'echo "${FAKE_ROUTE:-}"' >"$TEST_SCRATCH/netbin/ip"
    printf '%s\n' '#!/bin/bash' 'echo "$*" >>"$TEST_SCRATCH/ping.calls"' 'exit "${FAKE_PING_RC:-0}"' >"$TEST_SCRATCH/netbin/ping"
    chmod +x "$TEST_SCRATCH/netbin/ip" "$TEST_SCRATCH/netbin/ping"
    export TEST_SCRATCH
}

@test "gateway IP extraction: the next hop of the default route is what the connectivity check pings" {
    unshare --mount true 2>/dev/null || skip "a private mount namespace (unshare --mount) is not permitted here"
    network_shims
    run unshare --mount env PATH="$TEST_SCRATCH/netbin:$PATH" FAKE_ROUTE='default via 192.0.2.1 dev eth0 proto static metric 100' bash -c '
        mount -t tmpfs tmpfs /run || exit 99
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        set +e
        check_network_connectivity
        echo "rc=$?"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=0"* ]]
    [ "$(cat "$TEST_SCRATCH/ping.calls")" = "-c 1 -W 5 192.0.2.1" ]
}

@test "gateway IP extraction: with no default route the check is skipped and nothing is pinged" {
    network_shims
    # `route` and `netstat`, the fallbacks, find nothing either
    printf '%s\n' '#!/bin/bash' 'exit 0' >"$TEST_SCRATCH/netbin/route"
    cp "$TEST_SCRATCH/netbin/route" "$TEST_SCRATCH/netbin/netstat"
    chmod +x "$TEST_SCRATCH/netbin/route" "$TEST_SCRATCH/netbin/netstat"
    run env PATH="$TEST_SCRATCH/netbin:$PATH" FAKE_ROUTE= bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        set +e
        check_network_connectivity
        echo "rc=$?"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=0"* ]]
    [ ! -e "$TEST_SCRATCH/ping.calls" ]
}

# ============================================================================
# Disk space monitoring (the real check_disk_space)
# ============================================================================

# A `df` that reports one filesystem at $1 percent with $2 KiB available, for every path
disk_shim() {
    mkdir -p "$TEST_SCRATCH/dfbin"
    printf '%s\n' '#!/bin/bash' \
        'echo "Filesystem 1024-blocks Used Available Capacity Mounted on"' \
        'echo "fake 100000000 1 ${FAKE_DF_AVAIL:-50000000} ${FAKE_DF_PCT}% /"' >"$TEST_SCRATCH/dfbin/df"
    chmod +x "$TEST_SCRATCH/dfbin/df"
}

@test "disk space check returns percentage" {
    disk_shim
    # below the warning threshold nothing is reported and the status is 0
    run env PATH="$TEST_SCRATCH/dfbin:$PATH" FAKE_DF_PCT=70 bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        set +e
        check_disk_space 2>&1; echo "rc=$?"'
    [ "$status" -eq 0 ]
    [ "$output" = "rc=0" ]
}

@test "disk space warning threshold check" {
    disk_shim
    # at DISK_SPACE_WARNING_PERCENT (80): a warning, status 1; at DISK_SPACE_CRITICAL_PERCENT (95): critical, status 2
    run env PATH="$TEST_SCRATCH/dfbin:$PATH" FAKE_DF_PCT=85 bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        set +e
        echo "thresholds=$DISK_SPACE_WARNING_PERCENT/$DISK_SPACE_CRITICAL_PERCENT"
        check_disk_space 2>&1; echo "rc=$?"'
    [[ "$output" == *"thresholds=80/95"* ]]
    [[ "$output" == *"Warning: Disk space on /: 85% used"* ]]
    [[ "$output" == *"rc=1"* ]]
    run env PATH="$TEST_SCRATCH/dfbin:$PATH" FAKE_DF_PCT=96 bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        set +e
        check_disk_space 2>&1; echo "rc=$?"'
    [[ "$output" == *"Critical: Disk space on /: 96% used"* ]]
    [[ "$output" == *"rc=2"* ]]
    # little free space is critical whatever the percentage says (DISK_SPACE_MIN_FREE_MB, 100)
    run env PATH="$TEST_SCRATCH/dfbin:$PATH" FAKE_DF_PCT=10 FAKE_DF_AVAIL=51200 bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        set +e
        check_disk_space 2>&1; echo "rc=$?"'
    [[ "$output" == *"Critical: Disk space on /: 10% used, 50MB free"* ]]
    [[ "$output" == *"rc=2"* ]]
}

# ============================================================================
# Audio buffer configuration (the real AUDIO_RTBUFSIZE)
# ============================================================================

@test "rtbufsize calculation" {
    # 32 MB by default, an environment value overrides it, a value that is not a number falls back
    run env -u AUDIO_RTBUFSIZE bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1; echo "$AUDIO_RTBUFSIZE"'
    [ "$output" = "33554432" ]  # 32 * 1024 * 1024
    run env AUDIO_RTBUFSIZE=1048576 bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1; echo "$AUDIO_RTBUFSIZE"'
    [ "$output" = "1048576" ]
    run env AUDIO_RTBUFSIZE=lots bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1; echo "$AUDIO_RTBUFSIZE"'
    [ "$output" = "33554432" ]
}

# ============================================================================
# Regression tests for the FFmpeg wrapper self-healing loop (C2/C3)
# The wrapper is generated text run under `set -euo pipefail`, so these guard
# the generated source AND prove the underlying bash mechanism.
# ============================================================================

@test "wrapper wait preserves exit code without tripping errexit [C2 regression]" {
    # Both wrappers (individual + multiplex) must use the safe idiom.
    run grep -c 'wait "${FFMPEG_PID}" 2>/dev/null || exit_code=$?' \
        "$PROJECT_ROOT/lyrebird-stream-manager.sh"
    [ "$status" -eq 0 ]
    [ "$output" -eq 2 ]
    # The old bare-wait-then-$? pattern must be gone (would let errexit kill the
    # wrapper on FFmpeg's first non-zero exit, before restart/backoff ran).
    run grep -nE '^[[:space:]]*wait "\$\{FFMPEG_PID\}" 2>/dev/null[[:space:]]*$' \
        "$PROJECT_ROOT/lyrebird-stream-manager.sh"
    [ "$status" -ne 0 ]
}

@test "safe wait idiom survives a non-zero child under set -e [C2 mechanism]" {
    run bash -c '
        set -euo pipefail
        ( exit 3 ) & p=$!          # stand-in for FFmpeg dying non-zero
        exit_code=0
        wait "$p" 2>/dev/null || exit_code=$?
        echo "reached restart logic ec=$exit_code"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"reached restart logic ec=3"* ]]
}

@test "old bare-wait idiom aborts under set -e [C2 characterization]" {
    # Documents the bug this fixes: control never reaches the restart logic.
    run bash -c '
        set -euo pipefail
        ( exit 3 ) & p=$!
        wait "$p" 2>/dev/null
        echo "reached restart logic"
    '
    [ "$status" -ne 0 ]
    [[ "$output" != *"reached restart logic"* ]]
}

@test "wrapper does not tie its lifetime to the transient launcher PID [C3 regression]" {
    # check_parent_alive must be neutralised: MAIN_SCRIPT_PID is the launcher,
    # which exits by design, so killing the wrapper on its death defeats restart.
    run grep -c 'kill -0 "${MAIN_SCRIPT_PID}"' "$PROJECT_ROOT/lyrebird-stream-manager.sh"
    [ "$output" -eq 0 ]
}

# ============================================================================
# Regression tests for supervision reliability (SM-2 H8, SM-4)
# ============================================================================

@test "cron resurrection is bounded per stream per hour [SM-2/H8 regression]" {
    run env PROJECT_ROOT="$PROJECT_ROOT" CRON=1 \
        CRON_RESTART_STATE_DIR="$(mktemp -d)" CRON_RESTART_MAX_PER_HOUR=2 bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1 || true
        set +euo pipefail
        r=""
        for i in 1 2 3 4; do should_restart_stream s >/dev/null 2>&1 && r+=A || r+=D; done
        printf "%s" "$r"
    '
    [ "$status" -eq 0 ]
    # First two restarts allowed, the rest rate-limited (was: never restart at all).
    [ "$output" = "AADD" ]
}

@test "non-cron (service/interactive) restart is always permitted [SM-2 regression]" {
    run env PROJECT_ROOT="$PROJECT_ROOT" bash -c '
        unset CRON
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1 || true
        set +euo pipefail
        r=""
        for i in 1 2 3 4 5; do should_restart_stream s >/dev/null 2>&1 && r+=A || r+=D; done
        printf "%s" "$r"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "AAAAA" ]
}

@test "disk-full alone is degraded, NOT a service-restart trigger [SM-4 regression]" {
    run env PROJECT_ROOT="$PROJECT_ROOT" bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1 || true
        set +euo pipefail
        check_resource_usage() { return 0; }       # our own process fine
        check_disk_space() { return 2; }           # disk critical
        check_memory_usage() { return 0; }
        check_network_connectivity() { return 0; }
        update_heartbeat() { :; }
        check_all_resources; rc=$?
        printf "rc=%s ecrit=%s\n" "$rc" "$E_CRITICAL_RESOURCE"
    '
    [ "$status" -eq 0 ]
    local rc ecrit
    rc=$(printf '%s\n' "$output" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')
    ecrit=$(printf '%s\n' "$output" | sed -n 's/.*ecrit=\([0-9]*\).*/\1/p')
    # A restart can't free disk; must NOT return the restart-triggering code.
    [ "$rc" != "$ecrit" ]
}

@test "our-process resource exhaustion IS a restart trigger [SM-4 regression]" {
    run env PROJECT_ROOT="$PROJECT_ROOT" bash -c '
        source "$PROJECT_ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1 || true
        set +euo pipefail
        check_resource_usage() { return 1; }       # OUR process critical (fixable by restart)
        check_disk_space() { return 0; }
        check_memory_usage() { return 0; }
        check_network_connectivity() { return 0; }
        update_heartbeat() { :; }
        check_all_resources; rc=$?
        printf "rc=%s ecrit=%s\n" "$rc" "$E_CRITICAL_RESOURCE"
    '
    [ "$status" -eq 0 ]
    local rc ecrit
    rc=$(printf '%s\n' "$output" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')
    ecrit=$(printf '%s\n' "$output" | sed -n 's/.*ecrit=\([0-9]*\).*/\1/p')
    [ "$rc" = "$ecrit" ]     # restart trigger preserved for genuinely fixable conditions
}

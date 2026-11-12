#!/usr/bin/env bats
# Unit tests for install_mediamtx.sh
# Run with: bats tests/test_install_mediamtx.bats
# Install bats: sudo apt-get install bats

# Setup - source the installer script
load bats_shell_state
load process_decoys
load installer_fixture

setup() {
    # Get the directory of this test file
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"

    # Create temp directories for testing
    # The installer resets TEMP_DIR/CONFIG_FILE to "" and makes LOCK_FILE a
    # readonly system path when sourced, so keep this file's own paths in
    # TEST_* variables and delete only those (deleting "$LOCK_FILE" removed
    # the real /run/lock/mediamtx-installer.lock after every test).
    TEST_TEMP_DIR="$(mktemp -d)"
    TEST_LOCK_FILE="$(mktemp)"
    TEST_CONFIG_FILE="$(mktemp)"
    export TEMP_DIR="$TEST_TEMP_DIR" LOCK_FILE="$TEST_LOCK_FILE" CONFIG_FILE="$TEST_CONFIG_FILE"

    # Set dry-run mode to avoid actual system changes
    export DRY_RUN=true

    # Source the installer script
    bats_save_shell_state
    source "$PROJECT_ROOT/install_mediamtx.sh"
    bats_restore_shell_state
}

# Teardown - clean up temp files
teardown() {
    decoy_teardown
    local f
    for f in "${TEST_TEMP_DIR:-}" "${TEST_LOCK_FILE:-}" "${TEST_CONFIG_FILE:-}"; do
        [[ "$f" == "${TMPDIR:-/tmp}"/tmp.* ]] && rm -rf -- "$f"
    done
    return 0
}

# ============================================================================
# Script Metadata Tests
# ============================================================================

@test "SCRIPT_VERSION is defined" {
    [ -n "$SCRIPT_VERSION" ]
    [[ "$SCRIPT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "SCRIPT_NAME is defined" {
    [ -n "$SCRIPT_NAME" ]
}

# ============================================================================
# Logging Function Tests
# ============================================================================

@test "log_debug function exists" {
    run type log_debug
    [ "$status" -eq 0 ]
}

@test "log_info function exists" {
    run type log_info
    [ "$status" -eq 0 ]
}

@test "log_warn function exists" {
    run type log_warn
    [ "$status" -eq 0 ]
}

@test "log_error function exists" {
    run type log_error
    [ "$status" -eq 0 ]
}

@test "fatal function exists" {
    run type fatal
    [ "$status" -eq 0 ]
}

# ============================================================================
# Initialization Tests
# ============================================================================

@test "initialize_runtime_vars function exists" {
    run type initialize_runtime_vars
    [ "$status" -eq 0 ]
}

@test "error_handler function exists" {
    run type error_handler
    [ "$status" -eq 0 ]
}

@test "cleanup function exists" {
    run type cleanup
    [ "$status" -eq 0 ]
}

# ============================================================================
# Lock Function Tests
# ============================================================================

@test "acquire_lock function exists" {
    run type acquire_lock
    [ "$status" -eq 0 ]
}

@test "release_lock function exists" {
    run type release_lock
    [ "$status" -eq 0 ]
}

# ============================================================================
# Temp Directory Tests
# ============================================================================

@test "create_temp_dir function exists" {
    run type create_temp_dir
    [ "$status" -eq 0 ]
}

# ============================================================================
# Config Tests
# ============================================================================

@test "load_config function exists" {
    run type load_config
    [ "$status" -eq 0 ]
}

# ============================================================================
# Rollback Tests
# ============================================================================

@test "execute_rollback function exists" {
    run type execute_rollback
    [ "$status" -eq 0 ]
}

# ============================================================================
# Validation Tests
# ============================================================================

@test "validate_input function exists" {
    run type validate_input
    [ "$status" -eq 0 ]
}

@test "check_requirements function exists" {
    run type check_requirements
    [ "$status" -eq 0 ]
}

@test "validate_version function exists" {
    run type validate_version
    [ "$status" -eq 0 ]
}

@test "validate_version accepts valid semver" {
    run validate_version "v1.0.0"
    [ "$status" -eq 0 ]
}

@test "validate_version accepts version without v prefix" {
    run validate_version "1.15.0"
    [ "$status" -eq 0 ]
}

@test "validate_url function exists" {
    run type validate_url
    [ "$status" -eq 0 ]
}

@test "validate_url accepts https URL" {
    run validate_url "https://example.com/file.tar.gz"
    [ "$status" -eq 0 ]
}

@test "validate_url accepts http URL" {
    run validate_url "http://example.com/file.tar.gz"
    [ "$status" -eq 0 ]
}

# ============================================================================
# Version Comparison Tests
# ============================================================================

@test "version_compare function exists" {
    run type version_compare
    [ "$status" -eq 0 ]
}

# version_compare is a predicate: exit 0 iff v1 >= v2 (see its caller in
# the --upgrade gate). It prints nothing on success.
@test "version_compare: 1.0.0 < 2.0.0" {
    run version_compare "1.0.0" "2.0.0"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "version_compare: 2.0.0 > 1.0.0" {
    run version_compare "2.0.0" "1.0.0"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "version_compare: 1.0.0 = 1.0.0" {
    run version_compare "1.0.0" "1.0.0"
    [ "$status" -eq 0 ]
}

@test "version_compare: 1.10.0 > 1.9.0" {
    run version_compare "1.10.0" "1.9.0"
    [ "$status" -eq 0 ]
    run version_compare "1.9.0" "1.10.0"
    [ "$status" -eq 1 ]
}

@test "version_compare: 1.0.10 > 1.0.9" {
    run version_compare "1.0.10" "1.0.9"
    [ "$status" -eq 0 ]
    run version_compare "1.0.9" "1.0.10"
    [ "$status" -eq 1 ]
}

@test "version_compare: leading v is ignored" {
    run version_compare "v1.2.0" "1.1.9"
    [ "$status" -eq 0 ]
    run version_compare "1.1.9" "v1.2.0"
    [ "$status" -eq 1 ]
}

# ============================================================================
# Checksum Tests
# ============================================================================

@test "verify_checksum function exists" {
    run type verify_checksum
    [ "$status" -eq 0 ]
}

# ============================================================================
# Platform Detection Tests
# ============================================================================

@test "detect_platform function exists" {
    run type detect_platform
    [ "$status" -eq 0 ]
}

@test "detect_platform runs without error" {
    run detect_platform
    [ "$status" -eq 0 ]
}

@test "detect_platform sets PLATFORM_OS" {
    detect_platform
    [ "$PLATFORM_OS" = "linux" ]
}

@test "detect_platform sets PLATFORM_ARCH" {
    detect_platform
    [[ "$PLATFORM_ARCH" =~ ^(amd64|386|arm64|armv7|armv6)$ ]]
}

# ============================================================================
# Download Tests
# ============================================================================

@test "download_file function exists" {
    run type download_file
    [ "$status" -eq 0 ]
}

# ============================================================================
# GitHub Release Tests
# ============================================================================

@test "parse_github_release function exists" {
    run type parse_github_release
    [ "$status" -eq 0 ]
}

@test "get_release_info function exists" {
    run type get_release_info
    [ "$status" -eq 0 ]
}

# ============================================================================
# Management Mode Tests
# ============================================================================

@test "detect_management_mode function exists" {
    run type detect_management_mode
    [ "$status" -eq 0 ]
}

@test "find_stream_manager function exists" {
    run type find_stream_manager
    [ "$status" -eq 0 ]
}

# ============================================================================
# Asset URL Tests
# ============================================================================

@test "build_asset_url function exists" {
    run type build_asset_url
    [ "$status" -eq 0 ]
}

# ============================================================================
# Download MediaMTX Tests
# ============================================================================

@test "download_mediamtx function exists" {
    run type download_mediamtx
    [ "$status" -eq 0 ]
}

# ============================================================================
# Config Creation Tests
# ============================================================================

@test "create_config function exists" {
    run type create_config
    [ "$status" -eq 0 ]
}

# ============================================================================
# Service Creation Tests
# ============================================================================

@test "create_service function exists" {
    run type create_service
    [ "$status" -eq 0 ]
}

@test "create_user function exists" {
    run type create_user
    [ "$status" -eq 0 ]
}

# ============================================================================
# Install/Update/Uninstall Tests
# ============================================================================

@test "install_mediamtx function exists" {
    run type install_mediamtx
    [ "$status" -eq 0 ]
}

@test "update_mediamtx function exists" {
    run type update_mediamtx
    [ "$status" -eq 0 ]
}

@test "uninstall_mediamtx function exists" {
    run type uninstall_mediamtx
    [ "$status" -eq 0 ]
}

# ============================================================================
# Service Control Tests
# ============================================================================

@test "stop_mediamtx function exists" {
    run type stop_mediamtx
    [ "$status" -eq 0 ]
}

@test "start_mediamtx function exists" {
    run type start_mediamtx
    [ "$status" -eq 0 ]
}

# ============================================================================
# Status and Verification Tests
# ============================================================================

@test "show_status function exists" {
    run type show_status
    [ "$status" -eq 0 ]
}

@test "verify_installation function exists" {
    run type verify_installation
    [ "$status" -eq 0 ]
}

# ============================================================================
# Guidance Tests
# ============================================================================

@test "show_post_install_guidance function exists" {
    run type show_post_install_guidance
    [ "$status" -eq 0 ]
}

@test "show_post_update_guidance function exists" {
    run type show_post_update_guidance
    [ "$status" -eq 0 ]
}

# ============================================================================
# Help and Parse Tests
# ============================================================================

@test "show_help function exists" {
    run type show_help
    [ "$status" -eq 0 ]
}

@test "show_help outputs usage" {
    run show_help
    [ "$status" -eq 0 ]
    [[ "$output" =~ "install" ]] || [[ "$output" =~ "INSTALL" ]]
}

@test "parse_arguments function exists" {
    run type parse_arguments
    [ "$status" -eq 0 ]
}

@test "main function exists" {
    run type main
    [ "$status" -eq 0 ]
}

# ============================================================================
# Default Configuration Tests
# ============================================================================

@test "DEFAULT_INSTALL_PREFIX is defined" {
    [ -n "$DEFAULT_INSTALL_PREFIX" ]
}

@test "SERVICE_USER and SERVICE_GROUP default to mediamtx" {
    run env -u MEDIAMTX_USER -u MEDIAMTX_GROUP bash -c \
        'source "$1" >/dev/null 2>&1; echo "$SERVICE_USER:$SERVICE_GROUP"' _ "$PROJECT_ROOT/install_mediamtx.sh"
    [ "$output" = "mediamtx:mediamtx" ]
}

@test "MEDIAMTX_USER and MEDIAMTX_GROUP override the service account" {
    run env MEDIAMTX_USER=svcuser MEDIAMTX_GROUP=svcgroup bash -c \
        'source "$1" >/dev/null 2>&1; echo "$SERVICE_USER:$SERVICE_GROUP"' _ "$PROJECT_ROOT/install_mediamtx.sh"
    [ "$output" = "svcuser:svcgroup" ]
}

# ============================================================================
# Regression tests for update/rollback reliability (INST-1/4/6/8)
# ============================================================================

@test "execute_rollback restarts the service when it was running [INST-1 regression]" {
    local marker; marker="$(mktemp)"
    env PROJECT_ROOT="$PROJECT_ROOT" MARKER="$marker" DRY_RUN=true bash -c '
        source "$PROJECT_ROOT/install_mediamtx.sh" 2>/dev/null || true
        set +euo pipefail
        # Stub the starter to record that (and how) it was invoked.
        start_mediamtx() { echo "STARTED:$1" >> "$MARKER"; }
        WAS_RUNNING=true
        MANAGEMENT_MODE=systemd
        BINARY_BACKUP=""          # nothing to restore; we only assert the restart
        execute_rollback
    '
    local restarted=0
    grep -q "STARTED:systemd" "$marker" && restarted=1
    rm -f "$marker"
    [ "$restarted" -eq 1 ]        # pre-fix rollback never restarted -> stayed down
}

@test "execute_rollback does NOT restart when nothing was running [INST-1 regression]" {
    local marker; marker="$(mktemp)"
    env PROJECT_ROOT="$PROJECT_ROOT" MARKER="$marker" DRY_RUN=true bash -c '
        source "$PROJECT_ROOT/install_mediamtx.sh" 2>/dev/null || true
        set +euo pipefail
        start_mediamtx() { echo "STARTED:$1" >> "$MARKER"; }
        WAS_RUNNING=false
        MANAGEMENT_MODE=none
        BINARY_BACKUP=""
        execute_rollback
    '
    local restarted=0
    [ -s "$marker" ] && restarted=1
    rm -f "$marker"
    [ "$restarted" -eq 0 ]        # a fresh install / uninstall must not resurrect
}

@test "version_compare treats an 'unknown' current version as older [INST-6 regression]" {
    run version_compare "unknown" "1.15.0"
    [ "$status" -eq 1 ]           # must NOT be >= MIN, so --upgrade is skipped
}

@test "verify_service_started returns 0 immediately when systemctl is active [INST-4 regression]" {
    local bin; bin="$(mktemp -d)"
    printf '#!/bin/bash\ncase "$1" in is-active) exit 0;; esac\nexit 0\n' > "$bin/systemctl"
    chmod +x "$bin/systemctl"
    DRY_RUN_MODE=false PATH="$bin:$PATH" run verify_service_started systemd
    rm -rf "$bin"
    [ "$status" -eq 0 ]
}

@test "release_lock preserves the lock file, removes only the pid file [INST-8 regression]" {
    : > "${LOCK_FILE}.pid"
    exec 200>"${LOCK_FILE}"
    LOCK_FD=200
    release_lock
    local kept=0 pidgone=0
    [ -f "${LOCK_FILE}" ] && kept=1
    [ ! -f "${LOCK_FILE}.pid" ] && pidgone=1
    [ "$kept" -eq 1 ]             # removing it reintroduces the flock+unlink race
    [ "$pidgone" -eq 1 ]
}

# ============================================================================
# Process control by identity, not by name [LB-10 installer part, D11]
#
# The installer must stop, restart and roll back MediaMTX without signalling
# anything it cannot prove is the MediaMTX it manages. These tests start real
# look-alike processes (decoys, see tests/process_decoys.bash), run the real
# installer functions and check which processes survive and which signals were
# sent. Functions run in a fresh bash that sourced the script, so the script's
# own `set -euo pipefail` and ERR trap are in force, as in production. The
# pkill/pgrep shims only ever act on decoys, so the same tests can also be run
# against the old name-based code to show what it did.
# ============================================================================

# Point the installer at a private prefix/config dir and shim systemctl,
# pkill, pgrep and kill (see process_decoys.bash).
installer_env() {
    decoy_setup
    export MEDIAMTX_PREFIX="$DECOY_DIR/prefix"
    export MEDIAMTX_CONFIG_DIR="$DECOY_DIR/etc/mediamtx"
    export MEDIAMTX_STATE_DIR="$DECOY_DIR/state"
    export MEDIAMTX_PID_FILE="$DECOY_DIR/mediamtx-audio.pid"
    export MEDIAMTX_STOP_TIMEOUT="${1:-3}"
    INSTALL_DIR="$MEDIAMTX_PREFIX/bin"
    CONFIG_DIR="$MEDIAMTX_CONFIG_DIR"
    mkdir -p "$INSTALL_DIR" "$CONFIG_DIR"
}

# Start the processes the installer must tell apart:
#   M  the managed MediaMTX: installed binary and exactly the installed config
#   A  installed binary, but a config path that merely starts with the installed one
#   B  another MediaMTX binary run on the installed config path
#   C  a mediamtx-exporter (name contains "mediamtx")
#   D  an ffmpeg stub publishing to rtsp://localhost:18554/other
# Options: --no-managed (leave M out), --ignore-term (M and B ignore SIGTERM).
fleet_up() {
    local with_managed=true term_mode=""
    local opt
    for opt in "$@"; do
        case "$opt" in
            --no-managed) with_managed=false ;;
            --ignore-term) term_mode=ignore_term ;;
        esac
    done
    decoy_hold_script "$CONFIG_DIR/mediamtx.yml" "$term_mode"
    decoy_hold_script "$CONFIG_DIR/mediamtx.yml.bak"
    decoy_hold_script "$DECOY_DIR/exporter/run.sh"
    decoy_hold_script "$DECOY_DIR/stubs/run.sh"
    decoy_bash_copy "$INSTALL_DIR/mediamtx"
    decoy_bash_copy "$DECOY_DIR/other/bin/mediamtx"
    decoy_bash_copy "$DECOY_DIR/exporter/mediamtx-exporter"
    decoy_bash_copy "$DECOY_DIR/stubs/ffmpeg"
    if [[ "$with_managed" == "true" ]]; then
        decoy_spawn M "$INSTALL_DIR/mediamtx" "$CONFIG_DIR/mediamtx.yml"
    fi
    decoy_spawn A "$INSTALL_DIR/mediamtx" "$CONFIG_DIR/mediamtx.yml.bak"
    decoy_spawn B "$DECOY_DIR/other/bin/mediamtx" "$CONFIG_DIR/mediamtx.yml"
    decoy_spawn C "$DECOY_DIR/exporter/mediamtx-exporter" "$DECOY_DIR/exporter/run.sh"
    decoy_spawn D "$DECOY_DIR/stubs/ffmpeg" "$DECOY_DIR/stubs/run.sh" rtsp://localhost:18554/other
}

# A stand-in for lyrebird-stream-manager.sh that records its calls. Stopping
# it never kills anything; with fail.manager_stop it exits non-zero.
stub_stream_manager() {
    export MANAGER_LOG="$DECOY_DIR/manager.log"
    export STUB_MANAGER="$DECOY_DIR/lyrebird-stream-manager.sh"
    : >"$MANAGER_LOG"
    cat >"$STUB_MANAGER" <<'STUB'
#!/bin/bash
echo "manager $*" >>"$MANAGER_LOG"
if [[ "${1:-}" == "stop" && -e "$SHIM_STATE/fail.manager_stop" ]]; then
    exit 1
fi
exit 0
STUB
    chmod +x "$STUB_MANAGER"
}

# Run an installer function in a fresh bash that has sourced the script (its
# own strict mode and ERR trap in force), with the decoy shims on PATH and the
# guarded kill exported. $PREAMBLE is evaluated after sourcing, to override
# functions at the edges (the stream manager lookup, sleep).
run_strict() {
    export -f kill decoy_registered
    export PROJECT_ROOT PREAMBLE="${PREAMBLE:-}"
    run bash -c 'source "$PROJECT_ROOT/install_mediamtx.sh"; eval "$PREAMBLE"; "$@"' _ "$@"
}

# Fail unless every signal sent so far went to the managed process M
assert_signals_only_to_managed() {
    local mpid others
    mpid="$(decoy_pid M)"
    others="$(decoy_signals | grep -vE "^kill -(TERM|KILL) ${mpid}\$" || true)"
    [ -z "$others" ] || {
        echo "signals sent to something other than M ($mpid):"
        echo "$others"
        return 1
    }
}

assert_decoys_alive() {
    local label
    for label in "$@"; do
        decoy_alive "$label" || {
            echo "decoy $label was killed"
            return 1
        }
    done
}

@test "is_managed_mediamtx_pid accepts only the exact binary and config path [LB-10 installer]" {
    installer_env
    fleet_up
    run_strict is_managed_mediamtx_pid "$(decoy_pid M)"
    [ "$status" -eq 0 ]
    local label bad
    for label in A B C D; do
        run_strict is_managed_mediamtx_pid "$(decoy_pid "$label")"
        [ "$status" -eq 1 ] || {
            echo "look-alike $label was accepted"
            return 1
        }
    done
    for bad in "" abc 0 -1 99999999; do
        run_strict is_managed_mediamtx_pid "$bad"
        [ "$status" -eq 1 ] || {
            echo "invalid pid '$bad' was accepted"
            return 1
        }
    done
}

@test "find_managed_mediamtx_pids lists only the exact-identity process among look-alikes [LB-10 installer]" {
    installer_env
    fleet_up
    run_strict find_managed_mediamtx_pids
    [ "$status" -eq 0 ]
    [ "$output" = "$(decoy_pid M)" ]
}

@test "find_managed_mediamtx_pids lists nothing when only look-alikes run [LB-10 installer]" {
    installer_env
    fleet_up --no-managed
    run_strict find_managed_mediamtx_pids
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the managed process is still recognised after an update replaced its binary [LB-10 installer]" {
    installer_env
    fleet_up
    # What update_mediamtx does: install a new file over the installed path
    decoy_bash_copy "$INSTALL_DIR/mediamtx.new"
    mv -f "$INSTALL_DIR/mediamtx.new" "$INSTALL_DIR/mediamtx"
    [[ "$(readlink "/proc/$(decoy_pid M)/exe")" == *" (deleted)" ]]
    run_strict find_managed_mediamtx_pids
    [ "$status" -eq 0 ]
    [ "$output" = "$(decoy_pid M)" ]
}

@test "signal_managed_pid does not signal a process whose start time differs, as after PID reuse [LB-10 installer]" {
    installer_env
    fleet_up
    local mpid start
    mpid="$(decoy_pid M)"
    start="$(decoy_starttime "$mpid")"
    # The PID is that of the managed binary, but the recorded start time is another process's
    run_strict signal_managed_pid TERM "$mpid" "$((start + 1))"
    [ "$status" -eq 1 ]
    assert_decoys_alive M
    [ -z "$(decoy_signals)" ]
    # With the matching start time the same call signals it
    run_strict signal_managed_pid TERM "$mpid" "$start"
    [ "$status" -eq 0 ]
    decoy_dead M
}

@test "proc_alive tells the recorded process from a reused PID [LB-10 installer]" {
    installer_env
    fleet_up
    local mpid start
    mpid="$(decoy_pid M)"
    start="$(decoy_starttime "$mpid")"
    run_strict proc_alive "$mpid" "$start"
    [ "$status" -eq 0 ]
    run_strict proc_alive "$mpid" "$((start + 1))"
    [ "$status" -eq 1 ]
    run_strict proc_alive 99999999 "$start"
    [ "$status" -eq 1 ]
}

@test "proc_alive counts a zombie as gone, so a stop does not wait on a process whose parent never reaps it [LB-10 installer]" {
    installer_env
    # The child exits at once; its parent (which became `sleep`) never waits for it.
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
    run_strict proc_alive "$zpid" "$(decoy_starttime "$zpid")"
    [ "$status" -eq 1 ]
}

@test "detect_management_mode reports none while only look-alikes run [LB-10 installer]" {
    installer_env
    fleet_up --no-managed
    run_strict detect_management_mode
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

@test "detect_management_mode reports manual for the exact-identity process among look-alikes [LB-10 installer]" {
    installer_env
    fleet_up
    run_strict detect_management_mode
    [ "$status" -eq 0 ]
    [ "$output" = "manual" ]
}

@test "detect_management_mode reports stream-manager when the manager's PID file names the verified process [LB-10 installer]" {
    installer_env
    fleet_up
    echo "$(decoy_pid M)" >"$MEDIAMTX_PID_FILE"
    run_strict detect_management_mode
    [ "$status" -eq 0 ]
    [ "$output" = "stream-manager" ]
}

@test "detect_management_mode ignores a PID file that names a look-alike [LB-10 installer]" {
    installer_env
    fleet_up --no-managed
    echo "$(decoy_pid A)" >"$MEDIAMTX_PID_FILE"
    run_strict detect_management_mode
    [ "$status" -eq 0 ]
    [ "$output" = "none" ]
}

@test "detect_management_mode takes systemd unit state first [LB-10 installer]" {
    installer_env
    fleet_up
    decoy_unit_active mediamtx
    run_strict detect_management_mode
    [ "$output" = "systemd" ]
    rm -f "$SHIM_STATE/active.mediamtx"
    decoy_unit_active mediamtx-audio
    run_strict detect_management_mode
    [ "$output" = "stream-manager-service" ]
}

@test "stop_mediamtx (manual) signals only the exact-identity process and no name-based tool runs [LB-10 installer]" {
    installer_env
    fleet_up
    run_strict stop_mediamtx manual
    [ "$status" -eq 0 ]
    decoy_dead M
    assert_decoys_alive A B C D
    assert_signals_only_to_managed
    [[ "$(decoy_signals)" == *"kill -TERM $(decoy_pid M)"* ]]
    [[ "$output" != *"Command failed"* ]]
}

@test "stop_mediamtx sends SIGKILL to the exact-identity process that ignores SIGTERM, after a bounded wait [LB-10 installer]" {
    installer_env 1
    fleet_up --ignore-term
    local start end
    start=$SECONDS
    run_strict stop_mediamtx manual
    end=$SECONDS
    [ "$status" -eq 0 ]
    decoy_dead M
    assert_decoys_alive A B C D
    assert_signals_only_to_managed
    # TERM first, KILL later, both only to M
    local mpid sigs
    mpid="$(decoy_pid M)"
    sigs="$(decoy_signals | tr '\n' ' ')"
    [[ "$sigs" == "kill -TERM $mpid kill -KILL $mpid " ]] || {
        echo "signal sequence: $sigs"
        return 1
    }
    # bounded: about the 1 s grace period, nowhere near the default 10 s
    [ $((end - start)) -le 6 ]
}

@test "stop_mediamtx (stream-manager) stops through the manager and leaves FFmpeg and look-alikes alone [LB-10 installer]" {
    installer_env
    fleet_up
    stub_stream_manager
    PREAMBLE='find_stream_manager() { echo "$STUB_MANAGER"; }' run_strict stop_mediamtx stream-manager
    [ "$status" -eq 0 ]
    grep -qx "manager stop" "$MANAGER_LOG"
    # the stub's stop leaves M running; it is then stopped by identity
    decoy_dead M
    assert_decoys_alive A B C D
    assert_signals_only_to_managed
}

@test "stop_mediamtx (stream-manager) falls back to the verified process only, never to FFmpeg, when the manager's stop fails [LB-10 installer]" {
    installer_env
    fleet_up
    stub_stream_manager
    : >"$SHIM_STATE/fail.manager_stop"
    PREAMBLE='find_stream_manager() { echo "$STUB_MANAGER"; }' run_strict stop_mediamtx stream-manager
    [ "$status" -eq 0 ]
    # D is an ffmpeg publishing to rtsp://localhost: the old fallback killed it
    assert_decoys_alive A B C D
    decoy_dead M
    assert_signals_only_to_managed
    [[ "$output" == *"FFmpeg streams it started were NOT touched"* ]]
}

@test "stop_mediamtx (stream-manager) without a stream manager script stops only the verified process [LB-10 installer]" {
    installer_env
    fleet_up
    PREAMBLE='find_stream_manager() { return 1; }' run_strict stop_mediamtx stream-manager
    [ "$status" -eq 0 ]
    [[ "$output" == *"Stream manager not found"* ]]
    decoy_dead M
    assert_decoys_alive A B C D
    assert_signals_only_to_managed
}

@test "stop_mediamtx (systemd) stops through systemctl and signals nothing when the unit owns the process [LB-10 installer]" {
    installer_env
    fleet_up --no-managed
    decoy_unit_active mediamtx
    run_strict stop_mediamtx systemd
    [ "$status" -eq 0 ]
    grep -qx "systemctl stop mediamtx" "$SYSTEMCTL_LOG"
    [ -z "$(decoy_signals)" ]
    assert_decoys_alive A B C D
}

@test "stop_mediamtx (systemd) goes on when systemctl reports a failure but the unit is no longer active [LB-10 installer]" {
    installer_env
    fleet_up --no-managed
    decoy_fail stop
    run_strict stop_mediamtx systemd
    [ "$status" -eq 0 ]
    [[ "$output" == *"no longer active"* ]]
    [ -z "$(decoy_signals)" ]
    assert_decoys_alive A B C D
}

@test "stop_mediamtx with nothing running returns at once and signals nothing [LB-10 installer]" {
    installer_env
    fleet_up --no-managed
    local start end
    start=$SECONDS
    run_strict stop_mediamtx none
    end=$SECONDS
    [ "$status" -eq 0 ]
    [ -z "$(decoy_signals)" ]
    assert_decoys_alive A B C D
    # the old code slept 2 s whatever the state
    [ $((end - start)) -le 1 ]
}

@test "stop_mediamtx (stream-manager-service) stops the stream manager unit through systemctl [LB-10 installer]" {
    installer_env
    fleet_up --no-managed
    decoy_unit_active mediamtx-audio
    run_strict stop_mediamtx stream-manager-service
    [ "$status" -eq 0 ]
    grep -qx "systemctl stop mediamtx-audio" "$SYSTEMCTL_LOG"
    [ -z "$(decoy_signals)" ]
    assert_decoys_alive A B C D
}

@test "stop_mediamtx fails without signalling anything when systemd cannot stop an active unit [LB-10 installer]" {
    installer_env
    fleet_up
    decoy_unit_active mediamtx
    decoy_fail stop
    run_strict stop_mediamtx systemd
    [ "$status" -eq 1 ]
    [[ "$output" == *"still active"* ]]
    # M is the unit's process: stopping it behind systemd's back would only fight Restart=
    assert_decoys_alive M A B C D
    [ -z "$(decoy_signals)" ]
}

@test "start_mediamtx and execute_rollback restart through the owner and signal nothing [LB-10 installer]" {
    installer_env
    fleet_up --no-managed
    stub_stream_manager
    local mode
    for mode in systemd stream-manager-service stream-manager manual; do
        : >"$SYSTEMCTL_LOG"
        : >"$MANAGER_LOG"
        PREAMBLE="find_stream_manager() { echo \"\$STUB_MANAGER\"; }; WAS_RUNNING=true; MANAGEMENT_MODE=$mode" \
            run_strict execute_rollback
        [ "$status" -eq 0 ] || {
            echo "rollback ($mode) failed: $output"
            return 1
        }
        case "$mode" in
            systemd) grep -qx "systemctl start mediamtx" "$SYSTEMCTL_LOG" ;;
            stream-manager-service) grep -qx "systemctl start mediamtx-audio" "$SYSTEMCTL_LOG" ;;
            stream-manager) grep -qx "manager start" "$MANAGER_LOG" ;;
            manual) [[ "$output" == *"manually restart"* ]] ;;
        esac
        [ -z "$(decoy_signals)" ] || {
            echo "signals during rollback ($mode): $(decoy_signals)"
            return 1
        }
    done
    assert_decoys_alive A B C D
}

@test "verify_service_started does not accept a look-alike named mediamtx as the installed MediaMTX [LB-10 installer]" {
    installer_env
    fleet_up --no-managed
    PREAMBLE='sleep() { :; }' run_strict verify_service_started manual
    [ "$status" -eq 1 ]
}

@test "verify_service_started accepts the exact-identity process [LB-10 installer]" {
    installer_env
    fleet_up
    PREAMBLE='sleep() { :; }' run_strict verify_service_started manual
    [ "$status" -eq 0 ]
}

@test "verify_service_started follows the stream manager unit's state [LB-10 installer]" {
    installer_env
    fleet_up --no-managed
    PREAMBLE='sleep() { :; }' run_strict verify_service_started stream-manager-service
    [ "$status" -eq 1 ]
    decoy_unit_active mediamtx-audio
    PREAMBLE='sleep() { :; }' run_strict verify_service_started stream-manager-service
    [ "$status" -eq 0 ]
}

@test "update_mediamtx leaves the installed binary alone and stops when MediaMTX cannot be stopped [LB-10 installer]" {
    installer_env
    fleet_up
    decoy_unit_active mediamtx
    decoy_fail stop
    local before
    before="$(sha256sum "$INSTALL_DIR/mediamtx")"
    PREAMBLE='get_release_info() { RELEASE_VERSION=v99.0.0; }; download_mediamtx() { : >"$DECOY_DIR/download.called"; return 1; }' \
        run_strict update_mediamtx
    [ "$status" -eq 7 ]
    [[ "$output" == *"Could not stop MediaMTX"* ]]
    # nothing was backed up, replaced or downloaded, and nothing was signalled
    [ ! -e "$DECOY_DIR/download.called" ]
    [ "$(sha256sum "$INSTALL_DIR/mediamtx")" = "$before" ]
    run bash -c 'compgen -G "$1/mediamtx.backup.*" >/dev/null' _ "$INSTALL_DIR"
    [ "$status" -ne 0 ]
    assert_decoys_alive M A B C D
    [ -z "$(decoy_signals)" ]
}

@test "uninstall_mediamtx removes nothing and stops when MediaMTX cannot be stopped [LB-10 installer]" {
    # Safety: a run against code that does not stop here would go on to remove
    # the real unit file, so never run this where one is installed.
    [ ! -e /etc/systemd/system/mediamtx.service ] || skip "a real mediamtx.service is installed on this host"
    installer_env
    fleet_up
    mkdir -p "$MEDIAMTX_STATE_DIR"
    decoy_unit_active mediamtx
    decoy_fail stop
    run_strict uninstall_mediamtx </dev/null
    [ "$status" -eq 7 ]
    [[ "$output" == *"Could not stop MediaMTX"* ]]
    [ -x "$INSTALL_DIR/mediamtx" ]
    [ -f "$CONFIG_DIR/mediamtx.yml" ]
    [ -d "$MEDIAMTX_STATE_DIR" ]
    assert_decoys_alive M A B C D
    [ -z "$(decoy_signals)" ]
}

@test "show_status says so when a non-root run cannot identify a MediaMTX started outside systemd [LB-10 installer]" {
    installer_env
    fleet_up --no-managed
    export MEDIAMTX_RTSP_PORT=31041 MEDIAMTX_API_PORT=31042 MEDIAMTX_METRICS_PORT=31043
    PREAMBLE='is_root() { return 1; }' run_strict show_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Not detected (run as root"* ]]
    # as root, with nothing provably running, it is a plain "Not running"
    PREAMBLE='is_root() { return 0; }' run_strict show_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Not running"* ]]
}

@test "install_mediamtx.sh has no name- or pattern-based process control [LB-10 installer]" {
    # Comment lines are skipped; the code itself must not call these tools.
    run grep -nE '^[^#]*\b(pkill|killall|pgrep|pidof)\b' "$PROJECT_ROOT/install_mediamtx.sh"
    [ "$status" -eq 1 ] || {
        echo "$output"
        return 1
    }
}

# ============================================================================
# Ports are configuration [X-19 installer part, D15]
#
# The installer reads MEDIAMTX_RTSP_PORT / MEDIAMTX_API_PORT /
# MEDIAMTX_METRICS_PORT once at start-up (defaults 8554 / 9997 / 9998). These
# tests use ports from the private block 31000-31099 and never touch the
# default ports.
# ============================================================================

@test "create_config writes the RTSP, API and metrics ports named by the environment [X-19 installer]" {
    installer_env
    export MEDIAMTX_RTSP_PORT=31021 MEDIAMTX_API_PORT=31022 MEDIAMTX_METRICS_PORT=31023
    run_strict create_config
    [ "$status" -eq 0 ]
    # (the API and metrics bind the loopback address since installer pass 2 [LB-06 installer]; the
    # port is what this test is about)
    grep -qxF 'rtspAddress: :31021' "$CONFIG_DIR/mediamtx.yml"
    grep -qxF 'apiAddress: 127.0.0.1:31022' "$CONFIG_DIR/mediamtx.yml"
    grep -qxF 'metricsAddress: 127.0.0.1:31023' "$CONFIG_DIR/mediamtx.yml"
    run grep -E '^(rtsp|api|metrics)Address: .*:(8554|9997|9998)$' "$CONFIG_DIR/mediamtx.yml"
    [ "$status" -eq 1 ]
}

@test "create_config keeps the documented default ports when the variables are unset [X-19 installer]" {
    installer_env
    unset MEDIAMTX_RTSP_PORT MEDIAMTX_API_PORT MEDIAMTX_METRICS_PORT
    run_strict create_config
    [ "$status" -eq 0 ]
    grep -qxF 'rtspAddress: :8554' "$CONFIG_DIR/mediamtx.yml"
    grep -qxF 'apiAddress: 127.0.0.1:9997' "$CONFIG_DIR/mediamtx.yml"
    grep -qxF 'metricsAddress: 127.0.0.1:9998' "$CONFIG_DIR/mediamtx.yml"
}

@test "show_status checks the ports named by MEDIAMTX_RTSP_PORT, MEDIAMTX_API_PORT and MEDIAMTX_METRICS_PORT [X-19 installer]" {
    command -v lsof >/dev/null 2>&1 || command -v ss >/dev/null 2>&1 || skip "neither lsof nor ss is installed"
    installer_env
    cat >"$DECOY_DIR/listen.py" <<'PY'
import socket
import sys
import time

socks = []
for port in sys.argv[2:]:
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", int(port)))
    s.listen(1)
    socks.append(s)
open(sys.argv[1], "w").close()
time.sleep(60)
PY
    # Listeners on the RTSP and API ports of the private block; metrics left free
    decoy_spawn L "$(command -v python3)" -I "$DECOY_DIR/listen.py" "$DECOY_DIR/listen.ready" 31021 31022
    local i
    for ((i = 0; i < 100; i++)); do
        [[ -e "$DECOY_DIR/listen.ready" ]] && break
        sleep 0.05
    done
    [ -e "$DECOY_DIR/listen.ready" ]
    export MEDIAMTX_RTSP_PORT=31021 MEDIAMTX_API_PORT=31022 MEDIAMTX_METRICS_PORT=31023
    run_strict show_status
    [ "$status" -eq 0 ]
    [[ "$output" == *"RTSP (31021): "*"In use"* ]]
    [[ "$output" == *"API (31022): "*"In use"* ]]
    [[ "$output" == *"Metrics (31023): "*"Not in use"* ]]
    [[ "$output" != *"(8554)"* && "$output" != *"(9997)"* && "$output" != *"(9998)"* ]]
}

@test "show_help documents the port, stop-timeout and PID-file variables [X-19 installer]" {
    run show_help
    [ "$status" -eq 0 ]
    local var
    for var in MEDIAMTX_RTSP_PORT MEDIAMTX_API_PORT MEDIAMTX_METRICS_PORT MEDIAMTX_STOP_TIMEOUT MEDIAMTX_PID_FILE; do
        [[ "$output" == *"$var"* ]] || {
            echo "help does not mention $var"
            return 1
        }
    done
}

# ============================================================================
# The configuration comes from the shared generator [LB-06 installer,
# LB-22 installer, N-2]
#
# create_config used to write its own heredoc: API and metrics on every
# interface, SRT and (MediaMTX 1.19+) MoQ left on, `paths: {}` (so MediaMTX
# answers every publisher with "path is not configured"), no ownership marker,
# the ports written as given. It now renders lyrebird_render_mediamtx_config,
# the generator the stream manager uses, validates the ports and writes through
# lyrebird_atomic_write. Real MediaMTX binaries: tests/test_install_mediamtx_live.bats.
# ============================================================================

# An executable that answers like MediaMTX where the installer asks: --version
# prints VERSION. With "validate" its --help lists --validate-conf, and
# --validate-conf=FILE logs FILE's path and first line to $FAKE_LOG and exits
# 1 (printing "ERR: $FAKE_REJECT" on stderr) when FAKE_REJECT is set.
#   fake_mediamtx PATH VERSION [validate]
fake_mediamtx() {
    local path="$1" version="$2" mode="${3:-}"
    mkdir -p "$(dirname "$path")"
    {
        echo '#!/bin/bash'
        echo 'case "${1:-}" in'
        printf '    --version) echo %q; exit 0 ;;\n' "$version"
        if [[ "$mode" == validate ]]; then
            echo '    --help) echo "Flags:"; echo "  --validate-conf=path  check whether a configuration file is valid"; exit 0 ;;'
            echo '    --validate-conf=*)'
            echo '        f="${1#--validate-conf=}"'
            echo '        { echo "validated $f"; head -n 1 "$f"; } >>"${FAKE_LOG:-/dev/null}"'
            echo '        if [[ -n "${FAKE_REJECT:-}" ]]; then echo "ERR: $FAKE_REJECT" >&2; exit 1; fi'
            echo '        exit 0 ;;'
        fi
        echo 'esac'
        echo 'exit 0'
    } >"$path"
    chmod +x "$path"
}

# Shell code that stands in, in the installer's process, for every step of install
# that would reach outside this test's private directories (the release download,
# the service user, the unit directory); each leaves a marker in $DECOY_DIR, so a
# test can check that none of them ran
install_stubs() {
    printf '%s\n' \
        'get_release_info() { : >"$DECOY_DIR/release.called"; RELEASE_VERSION=v9.9.9; }' \
        'download_mediamtx() { : >"$DECOY_DIR/download.called"; }' \
        'create_user() { : >"$DECOY_DIR/user.called"; }' \
        'create_service() { : >"$DECOY_DIR/service.called"; }'
}

# What the shared generator renders for the given options, on stdout
render_expected() {
    bash -c 'source "$1"; shift; lyrebird_render_mediamtx_config "$@"' _ "$PROJECT_ROOT/lyrebird-common.sh" "$@"
}

@test "create_config writes the shared generator's configuration for the installed binary, byte for byte, marker first [LB-22 installer, LB-06 installer]" {
    installer_env
    fake_mediamtx "$INSTALL_DIR/mediamtx" v1.21.1
    export MEDIAMTX_RTSP_PORT=31021 MEDIAMTX_API_PORT=31022 MEDIAMTX_METRICS_PORT=31023
    run_strict create_config
    [ "$status" -eq 0 ]
    render_expected --mediamtx-version v1.21.1 --rtsp-port 31021 --api-port 31022 --metrics-port 31023 >"$DECOY_DIR/expected.yml"
    cmp "$DECOY_DIR/expected.yml" "$CONFIG_DIR/mediamtx.yml"
    [ "$(head -n 1 "$CONFIG_DIR/mediamtx.yml")" = "# Managed by LyreBirdAudio" ]
    # the loopback API and metrics, and every protocol the project does not use switched off
    grep -qxF 'apiAddress: 127.0.0.1:31022' "$CONFIG_DIR/mediamtx.yml"
    grep -qxF 'metricsAddress: 127.0.0.1:31023' "$CONFIG_DIR/mediamtx.yml"
    local key
    for key in rtmp hls webrtc srt moq; do
        grep -qxF "$key: no" "$CONFIG_DIR/mediamtx.yml" || {
            echo "$key is not switched off"
            return 1
        }
    done
    # a publisher can publish: one catch-all path, not `paths: {}`
    grep -qF "'~^[a-zA-Z0-9_-]+\$':" "$CONFIG_DIR/mediamtx.yml"
    ! grep -q 'paths: {}' "$CONFIG_DIR/mediamtx.yml" || false
}

@test "create_config leaves the moq key to the installed binary's version, and says so when it cannot tell [LB-06 installer]" {
    installer_env
    local version
    for version in v1.15.0 v1.18.0; do
        fake_mediamtx "$INSTALL_DIR/mediamtx" "$version"
        rm -f "$CONFIG_DIR/mediamtx.yml"
        run_strict create_config
        [ "$status" -eq 0 ]
        ! grep -q '^moq:' "$CONFIG_DIR/mediamtx.yml" || {
            echo "moq written for $version, which rejects it"
            return 1
        }
    done
    for version in v1.19.0 v1.21.3 v2.0.0; do
        fake_mediamtx "$INSTALL_DIR/mediamtx" "$version"
        rm -f "$CONFIG_DIR/mediamtx.yml"
        run_strict create_config
        [ "$status" -eq 0 ]
        grep -qxF 'moq: no' "$CONFIG_DIR/mediamtx.yml" || {
            echo "moq not switched off for $version"
            return 1
        }
    done
    # a binary that does not run: the release being installed says which version it is
    printf '#!/bin/bash\nexit 1\n' >"$INSTALL_DIR/mediamtx"
    rm -f "$CONFIG_DIR/mediamtx.yml"
    PREAMBLE='RELEASE_VERSION=v1.21.1' run_strict create_config
    [ "$status" -eq 0 ]
    grep -qxF 'moq: no' "$CONFIG_DIR/mediamtx.yml"
    # no binary and no release: no key a version could reject, and a warning that says what that costs
    rm -f "$INSTALL_DIR/mediamtx" "$CONFIG_DIR/mediamtx.yml"
    PREAMBLE='' run_strict create_config
    [ "$status" -eq 0 ]
    ! grep -q '^moq:' "$CONFIG_DIR/mediamtx.yml" || false
    [[ "$output" == *"version is unknown"* && "$output" == *"MoQ"* ]]
}

@test "a port that is not an integer from 1 to 65535 stops create_config with a message that names the variable, and nothing is written [N-2]" {
    installer_env
    local var value
    for var in MEDIAMTX_RTSP_PORT MEDIAMTX_API_PORT MEDIAMTX_METRICS_PORT; do
        for value in abc 0 65536 -1 1e3 ' 80' '80 81' $'80\n81' '8554;touch pwned' 99999999999; do
            rm -f "$CONFIG_DIR/mediamtx.yml"
            export "$var=$value"
            run_strict create_config
            unset "$var"
            [ "$status" -eq 10 ] || {
                echo "$var=$value: status $status"
                echo "$output"
                return 1
            }
            [[ "$output" == *"$var must be an integer from 1 to 65535"* ]] || {
                echo "$var=$value: the message does not name the variable:"
                echo "$output"
                return 1
            }
            [ ! -e "$CONFIG_DIR/mediamtx.yml" ] || {
                echo "$var=$value: a configuration was written"
                return 1
            }
        done
    done
}

@test "install checks the ports and the generator before it downloads or writes anything [N-2, LB-22 installer]" {
    installer_env
    local preamble
    preamble="$(install_stubs)"
    # a bad port
    MEDIAMTX_API_PORT=abc PREAMBLE="$preamble" run_strict install_mediamtx
    [ "$status" -eq 10 ]
    [[ "$output" == *"MEDIAMTX_API_PORT must be an integer from 1 to 65535 (got: abc)"* ]]
    # two settings that name the same port: the generator refuses, and says which
    MEDIAMTX_API_PORT=31022 MEDIAMTX_METRICS_PORT=31022 PREAMBLE="$preamble" run_strict install_mediamtx
    [ "$status" -eq 10 ]
    [[ "$output" == *"must differ"* ]]
    # nothing was fetched, installed or written
    [ ! -e "$DECOY_DIR/release.called" ]
    [ ! -e "$DECOY_DIR/download.called" ]
    [ ! -e "$DECOY_DIR/user.called" ]
    [ ! -e "$DECOY_DIR/service.called" ]
    [ ! -e "$INSTALL_DIR/mediamtx" ]
    [ -z "$(ls -A "$CONFIG_DIR")" ]
}

@test "install without --no-config stops at once, exit 4, when lyrebird-common.sh is not beside the installer [LB-22 installer]" {
    installer_env
    # a copy of the installer in a directory that has no library
    mkdir -p "$DECOY_DIR/standalone"
    cp "$PROJECT_ROOT/install_mediamtx.sh" "$DECOY_DIR/standalone/"
    export DECOY_DIR
    run bash -c 'source "$DECOY_DIR/standalone/install_mediamtx.sh"
        get_release_info() { : >"$DECOY_DIR/release.called"; }
        install_mediamtx' _
    [ "$status" -eq 4 ]
    [[ "$output" == *"lyrebird-common.sh is required"* ]]
    [ ! -e "$DECOY_DIR/release.called" ]
    # create_config says the same; --no-config does not need the library
    run bash -c 'source "$DECOY_DIR/standalone/install_mediamtx.sh"; create_config' _
    [ "$status" -eq 4 ]
    [[ "$output" == *"lyrebird-common.sh is required"* ]]
    run bash -c 'source "$DECOY_DIR/standalone/install_mediamtx.sh"; SKIP_CONFIG=true; check_config_inputs; create_config' _
    [ "$status" -eq 0 ]
}

@test "ports with leading zeros are read as decimal, and an empty variable means the default [N-2, X-19 installer]" {
    installer_env
    export MEDIAMTX_RTSP_PORT=08554 MEDIAMTX_API_PORT= MEDIAMTX_METRICS_PORT=09998
    run_strict create_config
    [ "$status" -eq 0 ]
    grep -qxF 'rtspAddress: :8554' "$CONFIG_DIR/mediamtx.yml"
    grep -qxF 'apiAddress: 127.0.0.1:9997' "$CONFIG_DIR/mediamtx.yml"
    grep -qxF 'metricsAddress: 127.0.0.1:9998' "$CONFIG_DIR/mediamtx.yml"
}

@test "create_config on a new installation writes a 0644 file with no backup and no temporary file left [LB-22 installer]" {
    installer_env
    run_strict create_config
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$CONFIG_DIR/mediamtx.yml")" = 644 ]
    [ "$(ls -A "$CONFIG_DIR")" = "mediamtx.yml" ]
    [[ "$output" == *"delete its first line"* ]]
}

@test "create_config writes through lyrebird_atomic_write, and a write that fails leaves the old file as it was [LB-22 installer]" {
    installer_env
    run_strict create_config
    [ "$status" -eq 0 ]
    local before
    before="$(sha256sum <"$CONFIG_DIR/mediamtx.yml")"
    # the same helper the stream manager writes its configuration with: destination and mode
    export MEDIAMTX_RTSP_PORT=31021
    PREAMBLE='lyrebird_atomic_write() { printf "%s\n" "$*" >>"$DECOY_DIR/atomic.log"; return 1; }' \
        run_strict create_config
    [ "$status" -ne 0 ]
    [ "$(cat "$DECOY_DIR/atomic.log")" = "$CONFIG_DIR/mediamtx.yml 0644" ]
    [[ "$output" == *"Failed to write"* ]]
    # (the failed write triggered the installer's rollback, which puts the backup it had made back)
    [ "$(sha256sum <"$CONFIG_DIR/mediamtx.yml")" = "$before" ]
    [ -z "$(compgen -G "$CONFIG_DIR/.mediamtx.yml.*" || true)" ]
}

@test "a managed file whose rendering is unchanged is left untouched: same inode, same mtime, no backup [LB-22 installer]" {
    installer_env
    run_strict create_config
    [ "$status" -eq 0 ]
    touch -d '2020-01-01 00:00:00' "$CONFIG_DIR/mediamtx.yml"
    local inode mtime
    inode="$(stat -c %i "$CONFIG_DIR/mediamtx.yml")"
    mtime="$(stat -c %Y "$CONFIG_DIR/mediamtx.yml")"
    run_strict create_config
    [ "$status" -eq 0 ]
    [[ "$output" == *"left untouched"* ]]
    [ "$(stat -c %i "$CONFIG_DIR/mediamtx.yml")" = "$inode" ]
    [ "$(stat -c %Y "$CONFIG_DIR/mediamtx.yml")" = "$mtime" ]
    [ "$(ls -A "$CONFIG_DIR")" = "mediamtx.yml" ]
}

@test "a managed file whose rendering changes is replaced after a timestamped backup of the old one [LB-22 installer]" {
    installer_env
    export MEDIAMTX_RTSP_PORT=31021
    run_strict create_config
    [ "$status" -eq 0 ]
    cp "$CONFIG_DIR/mediamtx.yml" "$DECOY_DIR/first.yml"
    export MEDIAMTX_RTSP_PORT=31031
    run_strict create_config
    [ "$status" -eq 0 ]
    grep -qxF 'rtspAddress: :31031' "$CONFIG_DIR/mediamtx.yml"
    local -a backups=()
    mapfile -t backups < <(compgen -G "$CONFIG_DIR/mediamtx.yml.backup.*")
    [ "${#backups[@]}" -eq 1 ]
    [[ "${backups[0]}" =~ mediamtx\.yml\.backup\.[0-9]{8}-[0-9]{6}$ ]]
    cmp "$DECOY_DIR/first.yml" "${backups[0]}"
    [[ "$output" == *"backed up to: ${backups[0]}"* ]]
}

@test "an operator-owned file is not overwritten without --force: bytes, mode and inode survive, and the message says how to replace it [LB-22 installer]" {
    installer_env
    printf '# my own settings\nlogLevel: debug\nrtspAddress: :8554\n' >"$CONFIG_DIR/mediamtx.yml"
    chmod 640 "$CONFIG_DIR/mediamtx.yml"
    cp -p "$CONFIG_DIR/mediamtx.yml" "$DECOY_DIR/mine.yml"
    local inode
    inode="$(stat -c %i "$CONFIG_DIR/mediamtx.yml")"
    run_strict create_config
    [ "$status" -eq 0 ]
    cmp "$DECOY_DIR/mine.yml" "$CONFIG_DIR/mediamtx.yml"
    [ "$(stat -c %a "$CONFIG_DIR/mediamtx.yml")" = 640 ]
    [ "$(stat -c %i "$CONFIG_DIR/mediamtx.yml")" = "$inode" ]
    [ "$(ls -A "$CONFIG_DIR")" = "mediamtx.yml" ]
    [[ "$output" == *"NOT overwritten"* && "$output" == *"--force"* && "$output" == *"# Managed by LyreBirdAudio"* ]]
}

@test "--force replaces an operator-owned file after saving a backup with its mode, and says it is doing so [LB-22 installer]" {
    installer_env
    printf '# my own settings\nlogLevel: debug\nauthMethod: internal\n' >"$CONFIG_DIR/mediamtx.yml"
    chmod 640 "$CONFIG_DIR/mediamtx.yml"
    cp -p "$CONFIG_DIR/mediamtx.yml" "$DECOY_DIR/mine.yml"
    PREAMBLE='FORCE_MODE=true' run_strict create_config
    [ "$status" -eq 0 ]
    [ "$(head -n 1 "$CONFIG_DIR/mediamtx.yml")" = "# Managed by LyreBirdAudio" ]
    local -a backups=()
    mapfile -t backups < <(compgen -G "$CONFIG_DIR/mediamtx.yml.backup.*")
    [ "${#backups[@]}" -eq 1 ]
    cmp "$DECOY_DIR/mine.yml" "${backups[0]}"
    # the copy keeps the mode: an operator's 0640 file does not become world-readable
    [ "$(stat -c %a "${backups[0]}")" = 640 ]
    [[ "$output" == *"was not generated by LyreBirdAudio: replacing it because --force was given"* ]]
}

@test "the file an earlier release of this installer wrote is recognised as such, kept without --force and replaced with it [LB-06 installer, LB-22 installer]" {
    installer_env
    {
        echo '###############################################'
        echo '# MediaMTX Configuration'
        echo '# Generated by install_mediamtx.sh v2.0.1'
        echo 'apiAddress: :9997'
        echo 'paths: {}'
    } >"$CONFIG_DIR/mediamtx.yml"
    run_strict create_config
    [ "$status" -eq 0 ]
    grep -qxF 'apiAddress: :9997' "$CONFIG_DIR/mediamtx.yml"
    [[ "$output" == *"earlier release of this installer"* && "$output" == *"every interface"* ]]
    PREAMBLE='FORCE_MODE=true' run_strict create_config
    [ "$status" -eq 0 ]
    grep -qxF 'apiAddress: 127.0.0.1:9997' "$CONFIG_DIR/mediamtx.yml"
    [[ "$output" == *"earlier release of this installer"* ]]
}

@test "an empty file, what a power cut during the old non-durable write leaves, is replaced and not treated as the operator's [LB-22 installer]" {
    installer_env
    : >"$CONFIG_DIR/mediamtx.yml"
    run_strict create_config
    [ "$status" -eq 0 ]
    [ "$(head -n 1 "$CONFIG_DIR/mediamtx.yml")" = "# Managed by LyreBirdAudio" ]
    [ "$(ls -A "$CONFIG_DIR")" = "mediamtx.yml" ]
}

@test "two replacements in the same second keep both backups [LB-22 installer]" {
    installer_env
    export MEDIAMTX_RTSP_PORT=31021
    run_strict create_config
    [ "$status" -eq 0 ]
    local port
    for port in 31031 31041; do
        export MEDIAMTX_RTSP_PORT=$port
        PREAMBLE='date() { echo 20260101-000000; }' run_strict create_config
        [ "$status" -eq 0 ]
    done
    local -a backups=()
    mapfile -t backups < <(compgen -G "$CONFIG_DIR/mediamtx.yml.backup.*" | sort)
    [ "${#backups[@]}" -eq 2 ]
    grep -qxF 'rtspAddress: :31021' "${backups[0]}" || grep -qxF 'rtspAddress: :31021' "${backups[1]}"
    grep -qxF 'rtspAddress: :31031' "${backups[0]}" || grep -qxF 'rtspAddress: :31031' "${backups[1]}"
}

@test "the generated configuration is validated by the binary that will run it, before the file is replaced [LB-22 installer]" {
    installer_env
    fake_mediamtx "$INSTALL_DIR/mediamtx" v1.21.1 validate
    export FAKE_LOG="$DECOY_DIR/fake.log"
    run_strict create_config
    [ "$status" -eq 0 ]
    # MediaMTX was asked about a file other than the destination, and that file was the rendering
    local asked
    asked="$(sed -n 1p "$FAKE_LOG")"
    [[ "$asked" == validated\ * && "$asked" != *"$CONFIG_DIR/mediamtx.yml" ]]
    [ "$(sed -n 2p "$FAKE_LOG")" = "# Managed by LyreBirdAudio" ]
    # a binary that rejects it: nothing is written and MediaMTX's own words are shown
    cp "$CONFIG_DIR/mediamtx.yml" "$DECOY_DIR/before.yml"
    export MEDIAMTX_RTSP_PORT=31031 FAKE_REJECT='json: unknown field "moq"'
    run_strict create_config
    [ "$status" -eq 7 ]
    [[ "$output" == *'MediaMTX rejects the generated configuration'* && "$output" == *'unknown field "moq"'* ]]
    cmp "$DECOY_DIR/before.yml" "$CONFIG_DIR/mediamtx.yml"
    [ "$(ls -A "$CONFIG_DIR")" = "mediamtx.yml" ]
}

# ============================================================================
# The systemd unit is rendered from config/mediamtx.service [LB-02 installer,
# X-12, LB-12, D12]
#
# create_service used to write its own heredoc: ExecReload=/bin/kill -USR1
# (MediaMTX 1.21.1 ignores SIGUSR1; it re-reads its file by itself),
# StartLimitInterval=/StartLimitBurst= under [Service] (accepted by systemd, but
# not the canonical placement), no Conflicts= with the stream manager's unit.
# It now renders the one template. systemd's own parser checks the result.
# ============================================================================

# The installer's unit-related environment, on top of installer_env: units go to
# $DECOY_DIR/units (the systemctl shim logs daemon-reload), the service account is
# "svcuser:svcgroup", the paths are private
unit_env() {
    installer_env
    export MEDIAMTX_SERVICE_DIR="$DECOY_DIR/units" MEDIAMTX_USER=svcuser MEDIAMTX_GROUP=svcgroup
    mkdir -p "$MEDIAMTX_SERVICE_DIR"
}

# The default settings: no override of a path or account
render_default_unit() {
    env -u MEDIAMTX_PREFIX -u MEDIAMTX_CONFIG_DIR -u MEDIAMTX_STATE_DIR -u MEDIAMTX_USER -u MEDIAMTX_GROUP \
        -u MEDIAMTX_UNIT_TEMPLATE -u MEDIAMTX_SERVICE_DIR \
        bash -c 'source "$1"; render_service_unit' _ "$PROJECT_ROOT/install_mediamtx.sh"
}

# The first KEY= line of SECTION in FILE (a unit file)
unit_value() {
    awk -v sec="[$2]" -v key="$3=" '
        /^\[/ { cur = $0 }
        cur == sec && index($0, key) == 1 { print substr($0, length(key) + 1); exit }' "$1"
}

@test "the unit with the default settings is the template, with only the lines its header lists replaced [LB-02 installer, D12: no drift]" {
    local template="$PROJECT_ROOT/config/mediamtx.service" unit="$BATS_TEST_TMPDIR/unit.service"
    render_default_unit >"$unit"
    # with default paths and the default account the output is the template except the
    # two account lines (the template has them commented out) and the log destination
    run diff "$template" "$unit"
    [ "$status" -eq 1 ]
    [ "$(grep -c '^[<>]' <<<"$output")" -eq 8 ]
    [ "$(grep '^[<>]' <<<"$output" | grep -vcE '^[<>] (# )?(User=mediamtx|Group=mediamtx|StandardOutput=|StandardError=)')" -eq 0 ]
    grep -qxF 'User=mediamtx' "$unit"
    grep -qxF 'Group=mediamtx' "$unit"
    grep -qxF 'StandardOutput=journal' "$unit"
    grep -qxF 'StandardError=journal' "$unit"
    # with every setting changed, exactly the keys the header lists differ, line for line
    unit_env
    PREAMBLE='' run_strict render_service_unit
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" >"$unit"
    [ "$(wc -l <"$template")" -eq "$(wc -l <"$unit")" ]
    local n=0 a b bad=""
    while IFS= read -r a && IFS= read -r b <&3; do
        n=$((n + 1))
        if [ "$a" != "$b" ]; then
            case "$a" in
                ExecStart=* | WorkingDirectory=* | ReadWritePaths=* | StandardOutput=* | StandardError=* | '# User=mediamtx' | '# Group=mediamtx') ;;
                *) bad+="line $n: '$a' became '$b'"$'\n' ;;
            esac
        fi
    done <"$template" 3<"$unit"
    [ -z "$bad" ] || {
        echo "$bad"
        false
    }
    grep -qxF "ExecStart=$INSTALL_DIR/mediamtx $CONFIG_DIR/mediamtx.yml" "$unit"
    grep -qxF "WorkingDirectory=$MEDIAMTX_STATE_DIR" "$unit"
    grep -qxF "ReadWritePaths=/var/log $MEDIAMTX_STATE_DIR $CONFIG_DIR" "$unit"
    grep -qxF 'User=svcuser' "$unit"
    grep -qxF 'Group=svcgroup' "$unit"
}

@test "the rendered unit conflicts with the stream manager's unit, has the start limit in [Unit] and no ExecReload or signal, and the script writes no unit text of its own [LB-02 installer, X-12, LB-12]" {
    unit_env
    local unit="$BATS_TEST_TMPDIR/unit.service"
    PREAMBLE='' run_strict render_service_unit
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" >"$unit"
    [ "$(unit_value "$unit" Unit Conflicts)" = "mediamtx-audio.service" ]
    # the two halves of the exclusion: no Wants=/Requires=/BindsTo=/PartOf= of the manager's unit
    ! grep -qE '^(Wants|Requires|Requisite|BindsTo|PartOf|Upholds)=.*mediamtx-audio' "$unit" || false
    # canonical placement, nothing in [Service]
    [ -n "$(unit_value "$unit" Unit StartLimitIntervalSec)" ]
    [ -n "$(unit_value "$unit" Unit StartLimitBurst)" ]
    run awk '/^\[/ { cur = $0 } /^StartLimit/ { print cur }' "$unit"
    [ -z "$(grep -v '^\[Unit\]$' <<<"$output")" ]
    ! grep -q '^StartLimitInterval=' "$unit" || false
    # MediaMTX re-reads its file by itself and ends on SIGHUP: nothing reloads by signal
    [ -z "$(unit_value "$unit" Service ExecReload)" ]
    # (active lines only: the template's comments explain why there is no reload)
    ! grep -vE '^[[:space:]]*#' "$unit" | grep -qE 'USR1|USR2|-HUP|SIGHUP|/bin/kill' || false
    # the account and the command
    [ "$(unit_value "$unit" Service User)" = "svcuser" ]
    [ "$(unit_value "$unit" Service Group)" = "svcgroup" ]
    [ "$(unit_value "$unit" Service ExecStart)" = "$INSTALL_DIR/mediamtx $CONFIG_DIR/mediamtx.yml" ]
    # no unit text left in the installer: no section header, no ExecReload, no inline directive
    run grep -nE '^\[(Unit|Service|Install)\]|ExecReload|StartLimitInterval|kill -USR1' "$PROJECT_ROOT/install_mediamtx.sh"
    [ "$status" -eq 1 ] || {
        echo "$output"
        false
    }
}

@test "systemd accepts the rendered unit with no finding, alone and together with the stream manager's unit [LB-02 installer, LB-12, D12]" {
    command -v systemd-analyze >/dev/null 2>&1 || skip "systemd-analyze not available"
    unit_env
    # ExecStart must name an existing executable for verify to say nothing at all
    fake_mediamtx "$INSTALL_DIR/mediamtx" v1.21.3
    PREAMBLE='' run_strict render_service_unit
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" >"$DECOY_DIR/mediamtx.service"
    run systemd-analyze verify "$DECOY_DIR/mediamtx.service"
    [ -z "$output" ]
    run systemd-analyze verify "$DECOY_DIR/mediamtx.service" "$PROJECT_ROOT/config/mediamtx-audio.service"
    [ -z "$(grep -v 'is not executable: No such file or directory' <<<"$output")" ]
    # the unit as installed on a node with no overrides (its ExecStart names /usr/local/bin/mediamtx,
    # which this machine does not have: the one finding that is allowed)
    render_default_unit >"$DECOY_DIR/default.service"
    run systemd-analyze verify "$DECOY_DIR/default.service"
    [ -z "$(grep -v 'is not executable: No such file or directory' <<<"$output")" ]
}

@test "a value the unit file cannot carry stops create_service before anything is written: a path with a space, an account name with a newline [LB-02 installer, D12]" {
    unit_env
    local value
    for value in '/opt/my mediamtx' '/opt/x;y' '/opt/x%h' $'/opt/x\nExecStartPre=/bin/touch pwned'; do
        MEDIAMTX_PREFIX="$value" PREAMBLE='' run_strict create_service
        [ "$status" -eq 10 ] || {
            echo "prefix '$value': status $status"
            return 1
        }
        [[ "$output" == *"Cannot write the unit"* ]]
    done
    for value in 'svc user' $'svcuser\nExecStartPre=/bin/touch pwned' '-svcuser' 'svc%user'; do
        MEDIAMTX_USER="$value" PREAMBLE='' run_strict create_service
        [ "$status" -eq 10 ] || {
            echo "user '$value': status $status"
            return 1
        }
        [[ "$output" == *"account name"* ]]
    done
    [ -z "$(ls -A "$MEDIAMTX_SERVICE_DIR")" ]
}

@test "a missing template, and a template that lacks a line the renderer replaces, are refused with a message that says what to do [D12]" {
    unit_env
    MEDIAMTX_UNIT_TEMPLATE="$DECOY_DIR/nonexistent.service" PREAMBLE='' run_strict create_service
    [ "$status" -eq 10 ]
    [[ "$output" == *"unit template"*"is missing"* && "$output" == *"MEDIAMTX_UNIT_TEMPLATE"* ]]
    local key
    for key in ExecStart WorkingDirectory ReadWritePaths StandardOutput StandardError; do
        grep -v "^${key}=" "$PROJECT_ROOT/config/mediamtx.service" >"$DECOY_DIR/drifted.service"
        MEDIAMTX_UNIT_TEMPLATE="$DECOY_DIR/drifted.service" PREAMBLE='' run_strict create_service
        [ "$status" -eq 10 ]
        [[ "$output" == *"has no ${key} line"* ]] || {
            echo "$key: $output"
            return 1
        }
    done
    # the commented account lines are replaced, so they must be there
    for key in User Group; do
        grep -v "^# ${key}=" "$PROJECT_ROOT/config/mediamtx.service" >"$DECOY_DIR/drifted.service"
        MEDIAMTX_UNIT_TEMPLATE="$DECOY_DIR/drifted.service" PREAMBLE='' run_strict create_service
        [ "$status" -eq 10 ]
        [[ "$output" == *"has no ${key} line"* ]]
    done
    [ -z "$(ls -A "$MEDIAMTX_SERVICE_DIR")" ]
}

@test "create_service writes the rendered unit atomically with mode 0644, reloads systemd, and keeps a copy of the unit it replaces [LB-02 installer, D14]" {
    unit_env
    PREAMBLE='' run_strict render_service_unit
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" >"$DECOY_DIR/expected.service"
    # (run captures $output without the final newline: compare the content)
    PREAMBLE='' run_strict create_service
    [ "$status" -eq 0 ]
    cmp "$DECOY_DIR/expected.service" "$MEDIAMTX_SERVICE_DIR/mediamtx.service"
    [ "$(stat -c %a "$MEDIAMTX_SERVICE_DIR/mediamtx.service")" = 644 ]
    grep -qx 'systemctl daemon-reload' "$SYSTEMCTL_LOG"
    [ "$(ls -A "$MEDIAMTX_SERVICE_DIR")" = "mediamtx.service" ]
    # a second install with another account replaces it, keeping the first as a backup with its mode
    chmod 640 "$MEDIAMTX_SERVICE_DIR/mediamtx.service"
    MEDIAMTX_USER=otheruser PREAMBLE='' run_strict create_service
    [ "$status" -eq 0 ]
    grep -qxF 'User=otheruser' "$MEDIAMTX_SERVICE_DIR/mediamtx.service"
    local -a backups=()
    mapfile -t backups < <(compgen -G "$MEDIAMTX_SERVICE_DIR/mediamtx.service.backup.*")
    [ "${#backups[@]}" -eq 1 ]
    cmp "$DECOY_DIR/expected.service" "${backups[0]}"
    [ "$(stat -c %a "${backups[0]}")" = 640 ]
    # the shared durable writer did the writing
    MEDIAMTX_USER=thirduser PREAMBLE='lyrebird_atomic_write() { printf "%s\n" "$*" >>"$DECOY_DIR/atomic.log"; cat >/dev/null; return 1; }' \
        run_strict create_service
    [ "$status" -ne 0 ]
    [ "$(cat "$DECOY_DIR/atomic.log")" = "$MEDIAMTX_SERVICE_DIR/mediamtx.service 0644" ]
    [[ "$output" == *"Failed to write"* ]]
}

@test "install checks the unit template and the values it carries before it downloads or writes anything; --no-service skips the check [LB-02 installer, D12]" {
    unit_env
    local preamble
    preamble="$(install_stubs)"
    MEDIAMTX_UNIT_TEMPLATE="$DECOY_DIR/nonexistent.service" PREAMBLE="$preamble" run_strict install_mediamtx
    [ "$status" -eq 10 ]
    [[ "$output" == *"is missing"* ]]
    MEDIAMTX_USER='svc user' PREAMBLE="$preamble" run_strict install_mediamtx
    [ "$status" -eq 10 ]
    [ ! -e "$DECOY_DIR/release.called" ]
    [ ! -e "$DECOY_DIR/download.called" ]
    [ ! -e "$DECOY_DIR/user.called" ]
    [ ! -e "$DECOY_DIR/service.called" ]
    [ -z "$(ls -A "$MEDIAMTX_SERVICE_DIR")" ]
    # --no-service: no unit is written, so none is checked
    MEDIAMTX_UNIT_TEMPLATE="$DECOY_DIR/nonexistent.service" PREAMBLE='check_service_inputs' run_strict true
    [ "$status" -eq 10 ]
    MEDIAMTX_UNIT_TEMPLATE="$DECOY_DIR/nonexistent.service" PREAMBLE='SKIP_SERVICE=true; check_service_inputs' run_strict true
    [ "$status" -eq 0 ]
}

# ============================================================================
# update: the verified download path, and a MediaMTX nobody supervises
# [N-1, supply chain: MediaMTX's own --upgrade]
#
# Without a pinned version `update` ran the installed MediaMTX's own
# `--upgrade`. Upstream (internal/upgrade/upgrade.go, v1.21.3) downloads the
# newest v1.x tag's tarball with http.Get and replaces the executable through
# selfupdate.Apply with empty options: no checksum, no signature, whatever
# --force says; only afterwards did the installer compare the version it
# printed. `update` now always takes the path `install` takes: the tarball is
# verified against the release's checksums.sha256 (a mismatch is fatal), then
# installed atomically, with the previous binary restored on failure.
# The release comes from a local stand-in (tests/installer_fixture.bash); the
# download, checksum, extraction and replacement code is the installer's own.
# ============================================================================

# A release (default v9.9.9) whose binary is a fake MediaMTX that runs ("good"),
# one whose --version fails ("broken"), or a good one with a wrong published
# checksum ("bad-checksum"); sets FIXTURE_DIR and NEW_BINARY
#   update_fixture [good|broken|bad-checksum] [VERSION]
update_fixture() {
    local kind="${1:-good}" version="${2:-v9.9.9}" mode=""
    export FIXTURE_DIR="$DECOY_DIR/release"
    NEW_BINARY="$DECOY_DIR/new/mediamtx"
    mkdir -p "$DECOY_DIR/new"
    if [[ "$kind" == broken ]]; then
        printf '#!/bin/bash\necho "cannot execute binary file" >&2\nexit 126\n' >"$NEW_BINARY"
        chmod +x "$NEW_BINARY"
    else
        fake_mediamtx "$NEW_BINARY" "$version"
    fi
    if [[ "$kind" == bad-checksum ]]; then
        mode=bad-checksum
    fi
    installer_release_fixture "$FIXTURE_DIR" "$version" "$NEW_BINARY" "$mode"
}

# The installer's process code for an update from the fixture (see update_fixture)
update_preamble() {
    installer_fixture_preamble
    printf '%s\n' "$@"
}

@test "update in manual mode ends successfully with the new binary in place, MediaMTX stopped, and says how to start it, instead of rolling back [N-1]" {
    installer_env
    fleet_up
    update_fixture good
    local config_before
    config_before="$(sha256sum <"$CONFIG_DIR/mediamtx.yml")"
    PREAMBLE="$(update_preamble)" run_strict update_mediamtx
    [ "$status" -eq 0 ] || {
        echo "$output"
        false
    }
    # the new binary is the one in the release, and MediaMTX is stopped (the installer stopped it)
    cmp "$NEW_BINARY" "$INSTALL_DIR/mediamtx"
    decoy_dead M
    assert_decoys_alive A B C D
    assert_signals_only_to_managed
    # the operator is told, with the command, and nothing was rolled back
    [[ "$output" == *"MediaMTX is NOT running"* ]]
    [[ "$output" == *"Start MediaMTX again"* ]]
    [[ "$output" == *"  $INSTALL_DIR/mediamtx $CONFIG_DIR/mediamtx.yml"* ]]
    [[ "$output" != *"did not come back up"* && "$output" != *"rollback"* && "$output" != *"Restoring binary"* ]]
    # the previous binary was kept as a backup; the configuration was not touched
    [ -n "$(compgen -G "$INSTALL_DIR/mediamtx.backup.*" || true)" ]
    [ "$(sha256sum <"$CONFIG_DIR/mediamtx.yml")" = "$config_before" ]
    [ "$(ls -A "$CONFIG_DIR" | tr '\n' ' ')" = "mediamtx.yml mediamtx.yml.bak " ]
    # nothing was started by the installer: it does not own this process
    ! grep -q '^systemctl start' "$SYSTEMCTL_LOG" || false
}

@test "update rolls back, restoring the previous binary, when the new binary does not run: with MediaMTX stopped by hand, and with nothing running [N-1]" {
    installer_env
    fleet_up
    update_fixture broken
    local before
    before="$(sha256sum <"$INSTALL_DIR/mediamtx")"
    PREAMBLE="$(update_preamble)" run_strict update_mediamtx
    [ "$status" -eq 7 ]
    [[ "$output" == *"does not run"* ]]
    [ "$(sha256sum <"$INSTALL_DIR/mediamtx")" = "$before" ]
    [[ "$output" == *"Restoring binary backup"* ]]
    # nothing was running: a binary that cannot run is not left installed (the old code left it)
    decoy_teardown
    installer_env
    update_fixture broken
    printf '#!/bin/bash\necho v1.20.0\n' >"$INSTALL_DIR/mediamtx"
    chmod +x "$INSTALL_DIR/mediamtx"
    before="$(sha256sum <"$INSTALL_DIR/mediamtx")"
    PREAMBLE="$(update_preamble)" run_strict update_mediamtx
    [ "$status" -eq 7 ]
    [[ "$output" == *"does not run"* ]]
    [ "$(sha256sum <"$INSTALL_DIR/mediamtx")" = "$before" ]
}

@test "update with a wrong published checksum is fatal, exit 6, and leaves the previous binary installed; --force does not accept a mismatch [supply chain]" {
    installer_env
    printf '#!/bin/bash\necho v1.20.0\n' >"$INSTALL_DIR/mediamtx"
    chmod +x "$INSTALL_DIR/mediamtx"
    update_fixture bad-checksum
    local before
    before="$(sha256sum <"$INSTALL_DIR/mediamtx")"
    PREAMBLE="$(update_preamble)" run_strict update_mediamtx
    [ "$status" -eq 6 ]
    [[ "$output" == *"Checksum mismatch"* ]]
    [ "$(sha256sum <"$INSTALL_DIR/mediamtx")" = "$before" ]
    PREAMBLE="$(update_preamble 'FORCE_MODE=true')" run_strict update_mediamtx
    [ "$status" -eq 6 ]
    [[ "$output" == *"Checksum mismatch"* ]]
    [ "$(sha256sum <"$INSTALL_DIR/mediamtx")" = "$before" ]
}

@test "update never runs the installed MediaMTX's own --upgrade: the binary that ends up installed is the one from the verified tarball [supply chain]" {
    installer_env
    update_fixture good
    # An old MediaMTX that has --upgrade. Its --upgrade does what upstream's does: it replaces
    # the executable with whatever it fetched, with no checksum check (here a different file that
    # also reports v9.9.9, so that a version comparison afterwards would be satisfied).
    export CALLS_LOG="$DECOY_DIR/calls.log"
    export TAMPERED="$DECOY_DIR/tampered"
    printf '#!/bin/bash\n# not the release\necho v9.9.9\n' >"$TAMPERED"
    chmod +x "$TAMPERED"
    cat >"$INSTALL_DIR/mediamtx" <<'OLD'
#!/bin/bash
echo "$*" >>"$CALLS_LOG"
case "${1:-}" in
    --version) echo v1.20.0 ;;
    --upgrade) cp "$TAMPERED" "$0" && echo "MediaMTX upgraded successfully" ;;
esac
exit 0
OLD
    chmod +x "$INSTALL_DIR/mediamtx"
    PREAMBLE="$(update_preamble)" run_strict update_mediamtx
    [ "$status" -eq 0 ] || {
        echo "$output"
        false
    }
    ! grep -qx -- '--upgrade' "$CALLS_LOG" || {
        echo "the installed MediaMTX was asked to upgrade itself"
        false
    }
    cmp "$NEW_BINARY" "$INSTALL_DIR/mediamtx"
    # the same with a pinned version: the verified path, as before
    : >"$CALLS_LOG"
    cat >"$INSTALL_DIR/mediamtx" <<'OLD'
#!/bin/bash
echo "$*" >>"$CALLS_LOG"
case "${1:-}" in
    --version) echo v1.20.0 ;;
    --upgrade) cp "$TAMPERED" "$0" ;;
esac
exit 0
OLD
    PREAMBLE="$(update_preamble 'TARGET_VERSION=v9.9.9')" run_strict update_mediamtx
    [ "$status" -eq 0 ]
    cmp "$NEW_BINARY" "$INSTALL_DIR/mediamtx"
    ! grep -qx -- '--upgrade' "$CALLS_LOG" || false
}

@test "update in service modes still verifies that the service came back: success when it is active, rollback with the previous binary when it is not [N-1, unchanged verification]" {
    installer_env
    update_fixture good
    local mode unit
    for mode in systemd stream-manager-service; do
        unit=mediamtx
        [[ "$mode" == stream-manager-service ]] && unit=mediamtx-audio
        # the running unit: update stops it, installs, starts it, verifies it is active
        printf '#!/bin/bash\necho v1.20.0\n' >"$INSTALL_DIR/mediamtx"
        chmod +x "$INSTALL_DIR/mediamtx"
        rm -f "$SHIM_STATE"/active.* "$SHIM_STATE"/fail.*
        decoy_unit_active "$unit"
        : >"$SYSTEMCTL_LOG"
        PREAMBLE="$(update_preamble 'sleep() { :; }')" run_strict update_mediamtx
        [ "$status" -eq 0 ] || {
            echo "$mode: $output"
            false
        }
        cmp "$NEW_BINARY" "$INSTALL_DIR/mediamtx"
        grep -qx "systemctl stop $unit" "$SYSTEMCTL_LOG"
        grep -qx "systemctl start $unit" "$SYSTEMCTL_LOG"
        [[ "$output" != *"NOT running"* ]]
        # the unit does not come back: fatal, the previous binary is restored and a restart is tried again
        printf '#!/bin/bash\necho v1.20.0\n' >"$INSTALL_DIR/mediamtx"
        chmod +x "$INSTALL_DIR/mediamtx"
        local before
        before="$(sha256sum <"$INSTALL_DIR/mediamtx")"
        rm -f "$SHIM_STATE"/active.* "$SHIM_STATE"/fail.*
        decoy_unit_active "$unit"
        decoy_fail start
        : >"$SYSTEMCTL_LOG"
        PREAMBLE="$(update_preamble 'sleep() { :; }')" run_strict update_mediamtx
        [ "$status" -eq 7 ] || {
            echo "$mode: status $status: $output"
            false
        }
        [[ "$output" == *"did not come back up after the update"* ]]
        [ "$(sha256sum <"$INSTALL_DIR/mediamtx")" = "$before" ]
        [ "$(grep -cx "systemctl start $unit" "$SYSTEMCTL_LOG")" -eq 2 ]
    done
}

@test "update in stream-manager mode still verifies by identity that MediaMTX came back, and rolls back when it did not [N-1, unchanged verification]" {
    installer_env
    fleet_up
    stub_stream_manager
    echo "$(decoy_pid M)" >"$MEDIAMTX_PID_FILE"
    update_fixture good
    # the stand-in manager's start does not start MediaMTX: the update must not report success
    PREAMBLE="$(update_preamble 'find_stream_manager() { echo "$STUB_MANAGER"; }' 'sleep() { :; }')" run_strict update_mediamtx
    [ "$status" -eq 7 ]
    grep -qx "manager stop" "$MANAGER_LOG"
    grep -qx "manager start" "$MANAGER_LOG"
    [[ "$output" == *"did not come back up after the update"* ]]
    assert_decoys_alive A B C D
}

@test "the help says update is a verified download with rollback and does not claim a built-in upgrade [supply chain]" {
    run show_help
    [ "$status" -eq 0 ]
    [[ "$output" == *"checksums.sha256"* ]]
    [[ "$output" == *"NOT started"* ]]
    [[ "$output" != *"uses built-in --upgrade"* && "$output" != *"built-in upgrade support"* ]]
}

@test "update says so when it crosses MediaMTX 1.19 with a generated configuration that cannot switch MoQ off, and stays quiet when there is nothing to say [LB-06 installer]" {
    installer_env
    local moq_warning="starts a MoQ server"
    # a configuration the installer generated for MediaMTX 1.18, which rejects the moq key
    fake_mediamtx "$INSTALL_DIR/mediamtx" v1.18.0
    run_strict create_config
    [ "$status" -eq 0 ]
    ! grep -q '^moq:' "$CONFIG_DIR/mediamtx.yml" || false
    cp "$CONFIG_DIR/mediamtx.yml" "$DECOY_DIR/generated.yml"
    # updated to 1.21.3: MediaMTX would now start a MoQ listener on every interface
    update_fixture good v1.21.3
    PREAMBLE="$(update_preamble)" run_strict update_mediamtx
    [ "$status" -eq 0 ]
    [[ "$output" == *"$moq_warning"* && "$output" == *"$CONFIG_DIR/mediamtx.yml"* && "$output" == *"moq: no"* ]]
    # it only says so: the configuration is not rewritten by an update
    cmp "$DECOY_DIR/generated.yml" "$CONFIG_DIR/mediamtx.yml"
    [ "$(ls -A "$CONFIG_DIR")" = "mediamtx.yml" ]
    # quiet: the file already switches MoQ off (generated for a version that has the key)
    fake_mediamtx "$INSTALL_DIR/mediamtx" v1.21.3
    rm -f "$CONFIG_DIR/mediamtx.yml"
    run_strict create_config
    grep -qxF 'moq: no' "$CONFIG_DIR/mediamtx.yml"
    # (the installed binary is older than the release, or update would stop at "already at version")
    fake_mediamtx "$INSTALL_DIR/mediamtx" v1.21.2
    PREAMBLE="$(update_preamble)" run_strict update_mediamtx
    [ "$status" -eq 0 ]
    [[ "$output" == *"Updated to version: v1.21.3"* && "$output" != *"$moq_warning"* ]]
    # quiet: the new version has no MoQ
    fake_mediamtx "$INSTALL_DIR/mediamtx" v1.18.0
    cp "$DECOY_DIR/generated.yml" "$CONFIG_DIR/mediamtx.yml"
    update_fixture good v1.18.2
    PREAMBLE="$(update_preamble)" run_strict update_mediamtx
    [ "$status" -eq 0 ]
    [[ "$output" == *"Updated to version: v1.18.2"* && "$output" != *"$moq_warning"* ]]
    # quiet: the file is the operator's (no marker), or there is none
    fake_mediamtx "$INSTALL_DIR/mediamtx" v1.18.0
    update_fixture good v1.21.3
    sed 1d "$DECOY_DIR/generated.yml" >"$CONFIG_DIR/mediamtx.yml"
    PREAMBLE="$(update_preamble)" run_strict update_mediamtx
    [ "$status" -eq 0 ]
    [[ "$output" == *"Updated to version: v1.21.3"* && "$output" != *"$moq_warning"* ]]
    fake_mediamtx "$INSTALL_DIR/mediamtx" v1.18.0
    rm -f "$CONFIG_DIR/mediamtx.yml"
    PREAMBLE="$(update_preamble)" run_strict update_mediamtx
    [ "$status" -eq 0 ]
    [[ "$output" == *"Updated to version: v1.21.3"* && "$output" != *"$moq_warning"* ]]
    # quiet: the stream manager renders the file again at every start, with the binary's version
    fake_mediamtx "$INSTALL_DIR/mediamtx" v1.18.0
    cp "$DECOY_DIR/generated.yml" "$CONFIG_DIR/mediamtx.yml"
    decoy_unit_active mediamtx-audio
    PREAMBLE="$(update_preamble 'sleep() { :; }')" run_strict update_mediamtx
    [ "$status" -eq 0 ]
    [[ "$output" == *"Updated to version: v1.21.3"* && "$output" != *"$moq_warning"* ]]
}

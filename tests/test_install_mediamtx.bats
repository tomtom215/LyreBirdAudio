#!/usr/bin/env bats
# Unit tests for install_mediamtx.sh
# Run with: bats tests/test_install_mediamtx.bats
# Install bats: sudo apt-get install bats

# Setup - source the installer script
load bats_shell_state
load process_decoys

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
    grep -qxF 'rtspAddress: :31021' "$CONFIG_DIR/mediamtx.yml"
    grep -qxF 'apiAddress: :31022' "$CONFIG_DIR/mediamtx.yml"
    grep -qxF 'metricsAddress: :31023' "$CONFIG_DIR/mediamtx.yml"
    run grep -E '^(rtsp|api|metrics)Address: :(8554|9997|9998)$' "$CONFIG_DIR/mediamtx.yml"
    [ "$status" -eq 1 ]
}

@test "create_config keeps the documented default ports when the variables are unset [X-19 installer]" {
    installer_env
    unset MEDIAMTX_RTSP_PORT MEDIAMTX_API_PORT MEDIAMTX_METRICS_PORT
    run_strict create_config
    [ "$status" -eq 0 ]
    grep -qxF 'rtspAddress: :8554' "$CONFIG_DIR/mediamtx.yml"
    grep -qxF 'apiAddress: :9997' "$CONFIG_DIR/mediamtx.yml"
    grep -qxF 'metricsAddress: :9998' "$CONFIG_DIR/mediamtx.yml"
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

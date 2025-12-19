#!/bin/bash
# lyrebird-updater.sh - Production-Ready Version Manager
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# Author: Tom F (https://github.com/tomtom215)
# Copyright: Tom F and LyreBirdAudio contributors
# License: Apache 2.0
#
# Version: 1.5.1 - Self-Update Syntax Validation
#
# NEW in v1.5.1:
#   - Pre-exec syntax validation for self-updates
#   - Protection against broken script deployment
#   - Enhanced error reporting for syntax failures
#
# v1.5.0 features:
#   - Automatic systemd service detection and update handling
#   - Pre-checkout service stop with state preservation
#   - Post-checkout service reinstallation and restart
#   - User customization detection and preservation
#   - Rollback support for failed service updates
#   - Self-update coordination with service updates
#   - Cron job update handling
#
# This script provides safe, reliable version management with:
#   - Atomic operations with automatic rollback on failure
#   - Comprehensive git state validation and recovery
#   - Lock file protection against concurrent execution
#   - Transaction-based stash management
#   - Progressive error recovery with user guidance
#   - Clear, non-technical UX for non-git-expert users
#   - Network resilience with retries
#   - Systemd service lifecycle management
#   - Self-update syntax validation
#
# Prerequisites:
#   - Git 2.0+ and Bash 4.0+
#   - Must be run from within a cloned LyreBirdAudio git repository

# Ensure bash is being used
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash. Please run with: bash $0 $*" >&2
    exit 1
fi

# Strict error handling and security
export LC_ALL=C # Ensure consistent sorting and string handling
umask 077       # Secure file creation (owner-only by default)

set -o errexit  # Exit on any command failure
set -o pipefail # Catch errors in pipes
set -o nounset  # Exit if uninitialized variable is used
set -o errtrace # Inherit ERR trap in functions

# Source shared library if available (backward compatible)
# Provides: colors, logging, command_exists, compute_hash, exit codes
# Falls back gracefully if library not present - all functions defined locally below
_LYREBIRD_COMMON="${BASH_SOURCE[0]%/*}/lyrebird-common.sh"
# shellcheck source=lyrebird-common.sh
[[ -f "$_LYREBIRD_COMMON" ]] && source "$_LYREBIRD_COMMON" || true
unset _LYREBIRD_COMMON

################################################################################
# Constants and Configuration
################################################################################

# Script metadata
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly VERSION="1.5.1"
readonly LOCKFILE="${SCRIPT_DIR}/.lyrebird-updater.lock"

# Repository configuration
readonly REPO_OWNER="tomtom215"
readonly REPO_NAME="LyreBirdAudio"
readonly REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"

# Exit codes
readonly E_SUCCESS=0
readonly E_GENERAL=1
readonly E_PREREQUISITES=2
readonly E_NOT_GIT_REPO=3
readonly E_NO_REMOTE=4
readonly E_PERMISSION=5
readonly E_LOCKED=7
readonly E_BAD_STATE=8
readonly E_USER_ABORT=9

# Version requirements
readonly MIN_GIT_MAJOR=2
readonly MIN_GIT_MINOR=0
readonly MIN_BASH_MAJOR=4
readonly MIN_BASH_MINOR=0

# Operation timeouts and retries
readonly FETCH_TIMEOUT=30
readonly FETCH_RETRIES=3
readonly FETCH_RETRY_DELAY=2
readonly LOCK_MAX_WAIT=30
readonly TAG_LIST_LIMIT=20

# Service update configuration
readonly SERVICE_NAME="mediamtx-audio"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly SERVICE_CRON_FILE="/etc/cron.d/mediamtx-monitor"
readonly SERVICE_SCRIPT="lyrebird-stream-manager.sh"
readonly SERVICE_UPDATE_MARKER="/run/lyrebird-service-update.marker"
readonly SERVICE_STOP_TIMEOUT=30
readonly SERVICE_START_TIMEOUT=10

# Colors for output (using tput for portability)
if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
    RED=$(tput setaf 1)
    readonly RED
    GREEN=$(tput setaf 2)
    readonly GREEN
    YELLOW=$(tput setaf 3)
    readonly YELLOW
    BLUE=$(tput setaf 4)
    readonly BLUE
    CYAN=$(tput setaf 6)
    readonly CYAN
    BOLD=$(tput bold)
    readonly BOLD
    NC=$(tput sgr0)
    readonly NC
else
    readonly RED=""
    readonly GREEN=""
    readonly YELLOW=""
    readonly BLUE=""
    readonly CYAN=""
    readonly BOLD=""
    readonly NC=""
fi

################################################################################
# Global State Variables
################################################################################

# Debug mode
DEBUG="${DEBUG:-false}"
export DEBUG # Export so child processes inherit

# Repository state (populated and validated by functions)
DEFAULT_BRANCH=""
CURRENT_VERSION=""
CURRENT_BRANCH=""
IS_DETACHED=false
HAS_LOCAL_CHANGES=false
GIT_STATE="unknown" # clean, dirty, merge, rebase, revert, cherry-pick, bisect, sequencer

# Transaction state for rollback capability
declare -A TRANSACTION_STATE=(
    [active]=false
    [stash_hash]=""
    [original_ref]=""
    [original_head]=""
    [operation]=""
)

# Available versions array
declare -a AVAILABLE_VERSIONS=()

# Git configuration backup for restoration
declare -A ORIGINAL_GIT_CONFIG=()

# Service update state
declare -A SERVICE_STATE=(
    [installed]=false
    [was_running]=false
    [was_enabled]=false
    [has_customizations]=false
    [service_file]=""
    [cron_file]=""
    [backup_service_file]=""
    [backup_cron_file]=""
)

# Custom environment variables from service file
declare -a SERVICE_CUSTOM_ENV=()

################################################################################
# Logging Functions
################################################################################

log_debug() {
    if [[ "$DEBUG" == "true" ]]; then
        echo "${CYAN}[DEBUG]${NC} $*" >&2
    fi
}

log_info() {
    echo "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo "${GREEN}[[OK]]${NC} $*"
}

log_warn() {
    echo "${YELLOW}[!]${NC} $*" >&2
}

log_error() {
    echo "${RED}[[X]]${NC} $*" >&2
}

log_step() {
    echo "${BOLD}>${NC} $*"
}

################################################################################
# Lock File Management
################################################################################

acquire_lock() {
    local waited=0

    # Verify SCRIPT_DIR is writable before attempting lock file operations
    if [[ ! -w "$SCRIPT_DIR" ]]; then
        log_error "Cannot write to script directory: $SCRIPT_DIR"
        log_info "The lock file needs to be created in this directory"
        log_info "Permission denied or directory is read-only"
        return "$E_PERMISSION"
    fi

    while true; do
        # ATOMIC OPERATION: mkdir fails if directory exists
        if mkdir "$LOCKFILE" 2>/dev/null; then
            # Write PID atomically using temp file + rename
            local pid_file="${LOCKFILE}/pid"
            local pid_tmp="${LOCKFILE}/pid.$$"
            if echo "$$" >"$pid_tmp" 2>/dev/null && mv "$pid_tmp" "$pid_file" 2>/dev/null; then
                log_debug "Lock acquired (PID: $$)"
                return 0
            else
                # Failed to write PID - clean up and retry
                rm -rf "$LOCKFILE" 2>/dev/null
                sleep 0.1
                continue
            fi
        fi

        # Check if lock is stale (process no longer exists)
        if [[ -f "${LOCKFILE}/pid" ]]; then
            local lock_pid
            lock_pid=$(cat "${LOCKFILE}/pid" 2>/dev/null || echo "")

            if [[ -n "$lock_pid" ]] && [[ "$lock_pid" =~ ^[0-9]+$ ]]; then
                # Verify process is dead AND was actually our script (prevent PID recycling attack)
                if ! kill -0 "$lock_pid" 2>/dev/null; then
                    log_warn "Removing stale lock from dead process $lock_pid"
                    # Atomically try to remove - if another process beats us, that's fine
                    if rm -rf "$LOCKFILE" 2>/dev/null; then
                        # Verify removal succeeded before retry
                        if [[ ! -d "$LOCKFILE" ]]; then
                            continue
                        fi
                    fi
                    # Another process claimed lock between our check and removal - wait
                    sleep 0.5
                    continue
                elif [[ -d "/proc/$lock_pid" ]]; then
                    # Process exists - verify it's actually lyrebird-updater (not PID recycling)
                    local proc_cmdline
                    proc_cmdline=$(tr '\0' ' ' <"/proc/$lock_pid/cmdline" 2>/dev/null || echo "")
                    if [[ -n "$proc_cmdline" ]] && [[ "$proc_cmdline" != *"lyrebird-updater"* ]]; then
                        log_warn "Stale lock: PID $lock_pid is now a different process"
                        rm -rf "$LOCKFILE" 2>/dev/null || true
                        continue
                    fi
                fi
            fi
        fi

        # Wait timeout
        if [[ $waited -ge $LOCK_MAX_WAIT ]]; then
            local lock_owner
            lock_owner=$(cat "${LOCKFILE}/pid" 2>/dev/null || echo "unknown")
            log_error "Lock held by process $lock_owner"
            log_error "If you're sure no other instance is running, remove: $LOCKFILE"
            return "$E_LOCKED"
        fi

        [[ $waited -eq 0 ]] && log_info "Waiting for other instance to finish..."
        sleep 1
        ((waited++))
    done
}

# shellcheck disable=SC2317  # Function invoked indirectly via cleanup
release_lock() {
    if [[ -d "$LOCKFILE" ]]; then
        local lock_pid
        lock_pid=$(cat "${LOCKFILE}/pid" 2>/dev/null || echo "")

        if [[ "$lock_pid" == "$$" ]]; then
            rm -rf "$LOCKFILE"
            log_debug "Lock released"
        else
            log_debug "Lock not owned by this process (PID: $$, lock: $lock_pid)"
        fi
    fi
}

################################################################################
# Systemd Service Detection and State Management
################################################################################

# Detect if systemd service is installed and capture its state
detect_systemd_service() {
    log_debug "Detecting systemd service installation..."

    # Reset state
    SERVICE_STATE[installed]=false
    SERVICE_STATE[was_running]=false
    SERVICE_STATE[was_enabled]=false
    SERVICE_STATE[has_customizations]=false
    SERVICE_STATE[service_file]="$SERVICE_FILE"
    SERVICE_STATE[cron_file]="$SERVICE_CRON_FILE"
    SERVICE_STATE[backup_service_file]=""
    SERVICE_STATE[backup_cron_file]=""
    SERVICE_CUSTOM_ENV=()

    # Check if service file exists
    if [[ ! -f "$SERVICE_FILE" ]]; then
        log_debug "No systemd service file found at: $SERVICE_FILE"
        return 1
    fi

    SERVICE_STATE[installed]=true
    log_debug "Detected installed systemd service: $SERVICE_NAME"

    # Check if service is running
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        SERVICE_STATE[was_running]=true
        log_debug "Service is currently running"
    fi

    # Check if service is enabled
    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        SERVICE_STATE[was_enabled]=true
        log_debug "Service is enabled for boot"
    fi

    # Detect customizations
    detect_service_customizations

    return 0
}

# Detect custom environment variables in service file
detect_service_customizations() {
    local service_file="$SERVICE_FILE"

    # Known default environment variables that the script generates
    local -A default_vars=(
        ["HOME"]="/root"
        ["PATH"]="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ["USB_STABILIZATION_DELAY"]="10"
        ["STREAM_MODE"]="individual"
        ["MULTIPLEX_FILTER_TYPE"]="amix"
        ["MULTIPLEX_STREAM_NAME"]="all_mics"
        ["INVOCATION_ID"]="systemd"
    )

    # Extract Environment= lines from service file
    local env_lines
    env_lines=$(grep "^Environment=" "$service_file" 2>/dev/null || true)

    if [[ -z "$env_lines" ]]; then
        log_debug "No environment variables found in service file"
        return 0
    fi

    # Check each environment line for customizations
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            continue
        fi

        # Extract variable name and value
        # Format: Environment="VAR=value" or Environment=VAR=value
        local var_full="${line#Environment=}"
        var_full="${var_full#\"}"
        var_full="${var_full%\"}"

        local var_name="${var_full%%=*}"
        local var_value="${var_full#*=}"

        # Check if this is a customized value
        if [[ -n "${default_vars[$var_name]+isset}" ]]; then
            # Known variable - check if value differs from default
            if [[ "${default_vars[$var_name]}" != "$var_value" ]]; then
                SERVICE_STATE[has_customizations]=true
                SERVICE_CUSTOM_ENV+=("$line")
                log_debug "Detected custom environment: $var_name=$var_value (default: ${default_vars[$var_name]})"
            fi
        else
            # Unknown variable - definitely custom
            SERVICE_STATE[has_customizations]=true
            SERVICE_CUSTOM_ENV+=("$line")
            log_debug "Detected custom environment variable: $var_name=$var_value"
        fi
    done <<<"$env_lines"

    if [[ "${SERVICE_STATE[has_customizations]}" == "true" ]]; then
        log_debug "Found ${#SERVICE_CUSTOM_ENV[@]} custom environment variable(s)"
    fi
}

# Backup service and cron files for rollback
backup_service_files() {
    log_debug "Backing up service files..."

    local service_file="${SERVICE_STATE[service_file]}"
    local cron_file="${SERVICE_STATE[cron_file]}"

    # Backup service file
    if [[ -f "$service_file" ]]; then
        local backup_service
        backup_service="$(mktemp "${service_file}.backup.XXXXXX")"

        if ! cp -a "$service_file" "$backup_service" 2>/dev/null; then
            log_error "Failed to backup service file"
            rm -f "$backup_service" 2>/dev/null || true
            return 1
        fi

        SERVICE_STATE[backup_service_file]="$backup_service"
        log_debug "Backed up service file to: $backup_service"
    fi

    # Backup cron file if it exists
    if [[ -f "$cron_file" ]]; then
        local backup_cron
        backup_cron="$(mktemp "${cron_file}.backup.XXXXXX")"

        if ! cp -a "$cron_file" "$backup_cron" 2>/dev/null; then
            log_warn "Failed to backup cron file (non-critical)"
            rm -f "$backup_cron" 2>/dev/null || true
            # Don't fail - cron backup is non-critical
        else
            SERVICE_STATE[backup_cron_file]="$backup_cron"
            log_debug "Backed up cron file to: $backup_cron"
        fi
    fi

    return 0
}

# Stop service safely with timeout
stop_service_safe() {
    if [[ "${SERVICE_STATE[was_running]}" != "true" ]]; then
        log_debug "Service was not running, skipping stop"
        return 0
    fi

    log_step "Stopping $SERVICE_NAME service..."

    # Try graceful stop
    if systemctl stop "$SERVICE_NAME" 2>/dev/null; then
        # Wait for service to actually stop
        local elapsed=0
        while systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && [[ $elapsed -lt $SERVICE_STOP_TIMEOUT ]]; do
            sleep 1
            ((elapsed++))
        done

        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            log_warn "Service did not stop gracefully within ${SERVICE_STOP_TIMEOUT}s, forcing..."
            systemctl kill "$SERVICE_NAME" 2>/dev/null || true
            sleep 2
        else
            log_success "Service stopped successfully"
            return 0
        fi
    else
        log_warn "Failed to stop service gracefully, forcing..."
        systemctl kill "$SERVICE_NAME" 2>/dev/null || true
        sleep 2
    fi

    # Verify stopped
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_error "Failed to stop service after force kill"
        return 1
    fi

    log_success "Service stopped (forced)"
    return 0
}

# Reinstall service definition while preserving customizations
reinstall_service_with_customizations() {
    local script_path="$1"

    log_step "Reinstalling service definition..."

    # Verify script exists and is executable
    if [[ ! -f "$script_path" ]]; then
        log_error "Service manager script not found: $script_path"
        return 1
    fi

    if [[ ! -x "$script_path" ]]; then
        log_debug "Making script executable: $script_path"
        chmod +x "$script_path" 2>/dev/null || {
            log_error "Cannot make script executable: $script_path"
            return 1
        }
    fi

    # Call install command to regenerate service file
    # Capture output but suppress expected informational messages
    local install_output
    if ! install_output=$("$script_path" install 2>&1); then
        log_error "Failed to reinstall service definition"
        if [[ -n "$install_output" ]]; then
            log_debug "Install output: $install_output"
        fi
        return 1
    fi

    log_success "Service definition reinstalled"

    # If there were customizations, merge them back in
    if [[ "${SERVICE_STATE[has_customizations]}" == "true" ]]; then
        log_step "Restoring custom environment variables..."

        local service_file="${SERVICE_STATE[service_file]}"

        if [[ ! -f "$service_file" ]]; then
            log_error "Service file not found after reinstall: $service_file"
            return 1
        fi

        # Create temporary file for merging
        local temp_service
        temp_service="$(mktemp)"

        # Strategy: Insert custom env vars after the last Environment= line
        # This preserves the structure and ensures custom values override defaults
        local last_env_line_num
        last_env_line_num=$(grep -n "^Environment=" "$service_file" | tail -n1 | cut -d: -f1)

        if [[ -z "$last_env_line_num" ]]; then
            # No Environment= lines found - insert after WorkingDirectory
            local working_dir_line
            working_dir_line=$(grep -n "^WorkingDirectory=" "$service_file" | tail -n1 | cut -d: -f1)

            if [[ -n "$working_dir_line" ]]; then
                # Insert after WorkingDirectory
                head -n "$working_dir_line" "$service_file" >"$temp_service"
                for custom_env in "${SERVICE_CUSTOM_ENV[@]}"; do
                    echo "$custom_env" >>"$temp_service"
                    log_debug "Restored: $custom_env"
                done
                tail -n +"$((working_dir_line + 1))" "$service_file" >>"$temp_service"
            else
                log_warn "Could not find insertion point for custom variables"
                cp "$service_file" "$temp_service"
            fi
        else
            # Insert after last Environment= line
            head -n "$last_env_line_num" "$service_file" >"$temp_service"
            for custom_env in "${SERVICE_CUSTOM_ENV[@]}"; do
                echo "$custom_env" >>"$temp_service"
                log_debug "Restored: $custom_env"
            done
            tail -n +"$((last_env_line_num + 1))" "$service_file" >>"$temp_service"
        fi

        # Atomically replace service file
        if ! mv -f "$temp_service" "$service_file" 2>/dev/null; then
            log_error "Failed to restore customizations to service file"
            rm -f "$temp_service"
            return 1
        fi

        log_success "Custom environment variables restored (${#SERVICE_CUSTOM_ENV[@]} variable(s))"
    fi

    return 0
}

# Start service safely with verification
start_service_safe() {
    if [[ "${SERVICE_STATE[was_running]}" != "true" ]]; then
        log_debug "Service was not running before update, not starting"
        return 0
    fi

    log_step "Starting $SERVICE_NAME service..."

    # Start service
    local start_output
    if ! start_output=$(systemctl start "$SERVICE_NAME" 2>&1); then
        log_error "Failed to start service"
        if [[ -n "$start_output" ]]; then
            log_debug "Start output: $start_output"
        fi
        log_info "Check status: systemctl status $SERVICE_NAME"
        log_info "Check logs: journalctl -u $SERVICE_NAME -n 50 --no-pager"
        return 1
    fi

    # Wait for service to fully start
    local elapsed=0
    while ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && [[ $elapsed -lt $SERVICE_START_TIMEOUT ]]; do
        sleep 1
        ((elapsed++))
    done

    # Verify service is running
    if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_error "Service failed to start within ${SERVICE_START_TIMEOUT}s"
        log_info "Check status: systemctl status $SERVICE_NAME"
        log_info "Check logs: journalctl -u $SERVICE_NAME -n 50 --no-pager"
        return 1
    fi

    log_success "Service started successfully"
    return 0
}

# Restore service files from backup
restore_service_from_backup() {
    log_warn "Restoring service files from backup..."

    local service_file="${SERVICE_STATE[service_file]}"
    local backup_service="${SERVICE_STATE[backup_service_file]}"
    local cron_file="${SERVICE_STATE[cron_file]}"
    local backup_cron="${SERVICE_STATE[backup_cron_file]}"

    local restore_failed=false

    # Restore service file
    if [[ -f "$backup_service" ]]; then
        if cp -a "$backup_service" "$service_file" 2>/dev/null; then
            log_debug "Service file restored from backup"
        else
            log_error "Failed to restore service file from backup"
            restore_failed=true
        fi
    fi

    # Restore cron file
    if [[ -f "$backup_cron" ]]; then
        if cp -a "$backup_cron" "$cron_file" 2>/dev/null; then
            log_debug "Cron file restored from backup"
        else
            log_warn "Failed to restore cron file from backup (non-critical)"
        fi
    fi

    # Reload systemd to pick up restored service file
    systemctl daemon-reload 2>/dev/null || true

    if [[ "$restore_failed" == "true" ]]; then
        return 1
    fi

    log_info "Service files restored from backup"
    return 0
}

# Clean up backup files
cleanup_service_backups() {
    log_debug "Cleaning up service backup files..."

    local backup_service="${SERVICE_STATE[backup_service_file]}"
    local backup_cron="${SERVICE_STATE[backup_cron_file]}"

    if [[ -f "$backup_service" ]]; then
        rm -f "$backup_service" 2>/dev/null || true
        log_debug "Removed service backup file"
    fi

    if [[ -f "$backup_cron" ]]; then
        rm -f "$backup_cron" 2>/dev/null || true
        log_debug "Removed cron backup file"
    fi
}

# Save service state to marker file for post-exec restoration
save_service_state_to_marker() {
    log_debug "Saving service state to marker file..."

    local marker="$SERVICE_UPDATE_MARKER"
    local temp_marker
    temp_marker="$(mktemp)"

    # Write state as simple key=value format for easy sourcing
    cat >"$temp_marker" <<EOF
# Service update state - automatically generated
INSTALLED=${SERVICE_STATE[installed]}
WAS_RUNNING=${SERVICE_STATE[was_running]}
WAS_ENABLED=${SERVICE_STATE[was_enabled]}
HAS_CUSTOMIZATIONS=${SERVICE_STATE[has_customizations]}
SERVICE_FILE=${SERVICE_STATE[service_file]}
CRON_FILE=${SERVICE_STATE[cron_file]}
BACKUP_SERVICE_FILE=${SERVICE_STATE[backup_service_file]}
BACKUP_CRON_FILE=${SERVICE_STATE[backup_cron_file]}
EOF

    # Append custom environment lines with indices
    if [[ ${#SERVICE_CUSTOM_ENV[@]} -gt 0 ]]; then
        echo "CUSTOM_ENV_COUNT=${#SERVICE_CUSTOM_ENV[@]}" >>"$temp_marker"
        local i=0
        for env_line in "${SERVICE_CUSTOM_ENV[@]}"; do
            # Escape quotes for safe storage
            local escaped_line="${env_line//\"/\\\"}"
            echo "CUSTOM_ENV_${i}=\"${escaped_line}\"" >>"$temp_marker"
            ((i++))
        done
    else
        echo "CUSTOM_ENV_COUNT=0" >>"$temp_marker"
    fi

    # Atomic move with restricted permissions
    if ! mv -f "$temp_marker" "$marker" 2>/dev/null; then
        log_error "Failed to save service state marker"
        rm -f "$temp_marker"
        return 1
    fi

    chmod 600 "$marker" 2>/dev/null || true
    log_debug "Service state saved to: $marker"
    return 0
}

# Load service state from marker file
load_service_state_from_marker() {
    local marker="$SERVICE_UPDATE_MARKER"

    if [[ ! -f "$marker" ]]; then
        log_debug "No service state marker file found"
        return 1
    fi

    log_debug "Loading service state from marker file..."

    # Reset state
    SERVICE_STATE=()
    SERVICE_CUSTOM_ENV=()

    # Source the marker file to load variables
    # shellcheck source=/dev/null
    source "$marker" 2>/dev/null || {
        log_error "Failed to load service state marker"
        return 1
    }

    # Reconstruct SERVICE_STATE associative array
    SERVICE_STATE[installed]="${INSTALLED:-false}"
    SERVICE_STATE[was_running]="${WAS_RUNNING:-false}"
    SERVICE_STATE[was_enabled]="${WAS_ENABLED:-false}"
    SERVICE_STATE[has_customizations]="${HAS_CUSTOMIZATIONS:-false}"
    SERVICE_STATE[service_file]="${SERVICE_FILE:-}"
    SERVICE_STATE[cron_file]="${CRON_FILE:-}"
    SERVICE_STATE[backup_service_file]="${BACKUP_SERVICE_FILE:-}"
    SERVICE_STATE[backup_cron_file]="${BACKUP_CRON_FILE:-}"

    # Reconstruct SERVICE_CUSTOM_ENV array
    local custom_env_count="${CUSTOM_ENV_COUNT:-0}"
    for ((i = 0; i < custom_env_count; i++)); do
        local var_name="CUSTOM_ENV_${i}"
        # Unescape quotes
        local env_value="${!var_name}"
        env_value="${env_value//\\\"/\"}"
        SERVICE_CUSTOM_ENV+=("$env_value")
    done

    log_debug "Service state loaded: installed=${SERVICE_STATE[installed]}, was_running=${SERVICE_STATE[was_running]}, customizations=${SERVICE_STATE[has_customizations]}"
    return 0
}

# Check if there's a pending service update
check_pending_service_update() {
    if [[ -f "$SERVICE_UPDATE_MARKER" ]]; then
        log_debug "Detected pending service update marker"
        return 0
    fi
    return 1
}

# Complete a pending service update (called after script restart)
complete_pending_service_update() {
    if ! load_service_state_from_marker; then
        log_debug "No pending service update found"
        return 0
    fi

    echo
    log_info "Completing pending service update from previous operation..."
    echo

    # Complete the service update
    if ! post_checkout_service_update; then
        log_error "Failed to complete pending service update"
        log_warn "Service may need manual intervention"
        log_info "Try: systemctl status $SERVICE_NAME"
        return 1
    fi

    # Remove marker on success
    rm -f "$SERVICE_UPDATE_MARKER"

    echo
    log_success "Service update completed successfully"
    return 0
}

################################################################################
# Service Update Handler (Pre-Checkout)
################################################################################

# Handle service update preparation before git checkout
handle_systemd_service_update() {
    local target_version="$1"

    # Detect if service is installed
    if ! detect_systemd_service; then
        log_debug "No systemd service installed, skipping service update handling"
        return 0
    fi

    log_info "Detected installed systemd service: $SERVICE_NAME"

    # Show service status
    echo
    echo "${BOLD}Systemd Service Status:${NC}"
    echo "  Service file: ${SERVICE_STATE[service_file]}"
    echo "  Currently running: ${SERVICE_STATE[was_running]}"
    echo "  Enabled at boot: ${SERVICE_STATE[was_enabled]}"

    if [[ "${SERVICE_STATE[has_customizations]}" == "true" ]]; then
        echo "  ${YELLOW}Custom environment variables: ${#SERVICE_CUSTOM_ENV[@]}${NC}"
        echo
        echo "${YELLOW}Detected customizations:${NC}"
        for env_line in "${SERVICE_CUSTOM_ENV[@]}"; do
            echo "    ${env_line}"
        done
        echo
        log_info "These customizations will be preserved during the update"
    fi

    echo
    log_info "The service will be stopped during the update and restarted afterwards"
    echo

    # Confirm if customizations exist
    if [[ "${SERVICE_STATE[has_customizations]}" == "true" ]]; then
        if ! confirm_action "Continue with service update?"; then
            log_info "Service update cancelled by user"
            return "$E_USER_ABORT"
        fi
        echo
    fi

    # Backup service files
    if ! backup_service_files; then
        log_error "Failed to backup service files"
        return "$E_GENERAL"
    fi

    # Stop service if running
    if ! stop_service_safe; then
        log_error "Failed to stop service - cannot proceed with update"
        # Cleanup backups since we're aborting
        cleanup_service_backups
        return "$E_GENERAL"
    fi

    # Save state to marker file (for post-exec completion if updater restarts)
    if ! save_service_state_to_marker; then
        log_error "Failed to save service state"
        # Try to restart service since we're aborting
        if [[ "${SERVICE_STATE[was_running]}" == "true" ]]; then
            systemctl start "$SERVICE_NAME" 2>/dev/null || true
        fi
        cleanup_service_backups
        return "$E_GENERAL"
    fi

    log_debug "Service update preparation completed"
    return 0
}

################################################################################
# Service Update Handler (Post-Checkout)
################################################################################

# Complete service update after successful git checkout
post_checkout_service_update() {
    local script_path="./${SERVICE_SCRIPT}"

    # Verify service was installed
    if [[ "${SERVICE_STATE[installed]}" != "true" ]]; then
        log_debug "Service not installed, skipping post-checkout service update"
        return 0
    fi

    # Check if service script exists in new version
    if [[ ! -f "$script_path" ]]; then
        log_error "Service script not found after checkout: $script_path"
        log_error "This indicates the service script was removed or renamed"
        return 1
    fi

    # Check if the service script actually changed
    local script_changed=false
    if ! git diff --quiet "${TRANSACTION_STATE[original_head]}" HEAD -- "$script_path" 2>/dev/null; then
        script_changed=true
        log_info "Service script changed, reinstalling service definition..."
    else
        log_debug "Service script unchanged, skipping reinstallation"
    fi

    # If script changed, reinstall service
    if [[ "$script_changed" == "true" ]]; then
        if ! reinstall_service_with_customizations "$script_path"; then
            log_error "Failed to reinstall service definition"
            return 1
        fi

        # Reload systemd daemon to pick up new service definition
        log_step "Reloading systemd daemon..."
        if ! systemctl daemon-reload 2>&1 | grep -v "^$" | head -5; then
            log_error "Failed to reload systemd daemon"
            return 1
        fi
        log_success "Systemd daemon reloaded"
    fi

    # Start service if it was running before
    if ! start_service_safe; then
        log_error "Service update failed - service did not start"
        log_warn "Attempting to restore service from backup..."

        # Attempt rollback
        restore_service_from_backup
        systemctl daemon-reload 2>/dev/null || true
        systemctl start "$SERVICE_NAME" 2>/dev/null || true

        return 1
    fi

    # Success - cleanup backups
    cleanup_service_backups

    log_success "Service update completed successfully"
    return 0
}

################################################################################
# Cleanup and Error Handlers
################################################################################

# shellcheck disable=SC2317  # Function invoked indirectly via cleanup
cleanup() {
    local exit_code=$?

    log_debug "Cleanup triggered (exit code: $exit_code)"

    # CRITICAL: Disable traps to prevent recursion
    trap - EXIT INT TERM

    # If we're in an active transaction and exiting with error, attempt rollback
    if [[ "${TRANSACTION_STATE[active]}" == "true" ]] && [[ $exit_code -ne 0 ]]; then
        log_error "Operation failed - attempting automatic rollback..."
        transaction_rollback
    fi

    # Restore git configuration
    restore_git_config

    # Release lock file
    release_lock

    # Exit without re-triggering trap
    exit "$exit_code"
}

# Trap all exit conditions
trap cleanup EXIT
trap 'log_error "Script interrupted by user"; exit $E_USER_ABORT' INT TERM

################################################################################
# Git Configuration Management
################################################################################

save_git_config() {
    log_debug "Saving git configuration..."

    # Save core.fileMode setting
    local current_filemode
    current_filemode=$(git config --local core.fileMode 2>/dev/null || echo "")
    ORIGINAL_GIT_CONFIG["core.fileMode"]="$current_filemode"

    # Apply our temporary setting
    git config --local core.fileMode false 2>/dev/null || true

    log_debug "Git config saved (core.fileMode: ${current_filemode:-<unset>})"
}

# shellcheck disable=SC2317  # Function invoked indirectly via cleanup
restore_git_config() {
    log_debug "Restoring git configuration..."

    # Restore core.fileMode
    if [[ -n "${ORIGINAL_GIT_CONFIG["core.fileMode"]:-}" ]]; then
        git config --local core.fileMode "${ORIGINAL_GIT_CONFIG["core.fileMode"]}" 2>/dev/null || true
    else
        git config --unset --local core.fileMode 2>/dev/null || true
    fi

    log_debug "Git config restored"
}

################################################################################
# Prerequisite Checks
################################################################################

check_prerequisites() {
    log_debug "Checking prerequisites..."

    # IMPORTANT: Warn if running with sudo or as root
    if [[ "${SUDO_USER:-}" != "" ]] || [[ "$EUID" -eq 0 ]]; then
        log_warn "[!]  WARNING: This script is running with root/sudo privileges"
        log_warn "This may change file ownership in the repository"
        echo

        if [[ "${SUDO_USER:-}" != "" ]]; then
            log_info "You used: sudo ./lyrebird-updater.sh"
            log_info "This is usually NOT needed. Try running without sudo"
        else
            log_warn "Running directly as root is not recommended"
        fi
        echo

        if ! confirm_action "Continue anyway? (may modify file ownership)"; then
            log_error "Cancelled by user"
            return "$E_USER_ABORT"
        fi
        echo
    fi

    # Check for git
    if ! command -v git >/dev/null 2>&1; then
        log_error "Git is not installed or not in PATH"
        log_info "Installation instructions:"
        log_info "  Debian/Ubuntu: sudo apt-get install git"
        log_info "  Fedora/RHEL:   sudo dnf install git"
        log_info "  macOS:         brew install git"
        return "$E_PREREQUISITES"
    fi

    # Check git version
    local git_version
    if ! git_version="$(git --version 2>/dev/null | awk '{print $3}')"; then
        log_error "Could not determine git version"
        return "$E_PREREQUISITES"
    fi

    local git_major git_minor
    git_major="${git_version%%.*}"
    git_minor="${git_version#*.}"
    git_minor="${git_minor%%.*}"

    if [[ "$git_major" -lt "$MIN_GIT_MAJOR" ]] \
        || [[ "$git_major" -eq "$MIN_GIT_MAJOR" && "$git_minor" -lt "$MIN_GIT_MINOR" ]]; then
        log_error "Git version $git_version is too old (required: ${MIN_GIT_MAJOR}.${MIN_GIT_MINOR}+)"
        return "$E_PREREQUISITES"
    fi

    log_debug "Git version: $git_version [OK]"

    # Check bash version
    local bash_major="${BASH_VERSINFO[0]}"
    local bash_minor="${BASH_VERSINFO[1]}"

    if [[ "$bash_major" -lt "$MIN_BASH_MAJOR" ]] \
        || [[ "$bash_major" -eq "$MIN_BASH_MAJOR" && "$bash_minor" -lt "$MIN_BASH_MINOR" ]]; then
        log_error "Bash version $bash_major.$bash_minor is too old (required: ${MIN_BASH_MAJOR}.${MIN_BASH_MINOR}+)"
        return "$E_PREREQUISITES"
    fi

    log_debug "Bash version: $bash_major.$bash_minor [OK]"

    # Check for required external utilities
    local required_utils=("awk" "sed" "grep" "tput")
    local missing_utils=()

    for util in "${required_utils[@]}"; do
        if ! command -v "$util" >/dev/null 2>&1; then
            missing_utils+=("$util")
        fi
    done

    if [[ ${#missing_utils[@]} -gt 0 ]]; then
        log_error "Required utilities not found: ${missing_utils[*]}"
        log_info "Please install these utilities and try again"
        return "$E_PREREQUISITES"
    fi

    # Check for systemctl (for service management)
    if ! command -v systemctl >/dev/null 2>&1; then
        log_debug "systemctl not found - service update features will be limited"
    fi

    # Check for stat (different syntax on different systems)
    if ! command -v stat >/dev/null 2>&1; then
        log_warn "Warning: 'stat' command not found"
        log_info "Some features may not work properly"
    fi

    # Check for timeout (optional but recommended)
    if ! command -v timeout >/dev/null 2>&1; then
        # Try gtimeout on macOS
        if [[ "$OSTYPE" == "darwin"* ]] && command -v gtimeout >/dev/null 2>&1; then
            log_debug "Using gtimeout (macOS coreutils)"
            # Create function alias for compatibility
            timeout() { gtimeout "$@"; }
            export -f timeout
        else
            log_debug "Note: 'timeout' command not available (fetch operations may hang)"
        fi
    fi

    log_debug "All prerequisites checked [OK]"
    return 0
}

################################################################################
# Git Repository Validation
################################################################################

check_git_repository() {
    log_debug "Validating git repository..."

    # Check if we're in a git repository
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        log_error "Not a git repository"
        log_error "This script must be run from within the LyreBirdAudio repository"
        echo
        log_info "To get started:"
        log_info "  1. Clone: git clone $REPO_URL"
        log_info "  2. Enter:  cd $REPO_NAME"
        log_info "  3. Run:    ./$SCRIPT_NAME"
        return "$E_NOT_GIT_REPO"
    fi

    # Verify remote is configured
    local origin_url
    if ! origin_url="$(git remote get-url origin 2>/dev/null)"; then
        log_error "No 'origin' remote configured"
        log_info "To fix: git remote add origin $REPO_URL"
        return "$E_NOT_GIT_REPO"
    fi

    # Validate origin URL
    if [[ ! "$origin_url" =~ github\.com[:/]${REPO_OWNER}/${REPO_NAME} ]]; then
        log_warn "Remote 'origin' URL does not match expected repository"
        log_warn "Expected: $REPO_URL"
        log_warn "Found:    $origin_url"
        echo
        if ! confirm_action "Continue anyway?"; then
            return "$E_NOT_GIT_REPO"
        fi
    fi

    # Check git permissions
    local git_dir
    if ! git_dir="$(git rev-parse --git-dir 2>/dev/null)"; then
        log_error "Could not determine .git directory location"
        return "$E_PERMISSION"
    fi

    if [[ ! -w "$git_dir" ]]; then
        log_error "No write permission for git repository: $git_dir"
        log_info "To fix: sudo chown -R $USER:$USER $(git rev-parse --show-toplevel)"
        return "$E_PERMISSION"
    fi

    # Check if git directory is owned by root (common issue)
    if [[ -e "$git_dir/config" ]] && command -v stat >/dev/null 2>&1; then
        local owner
        owner="$(stat -c %U "$git_dir/config" 2>/dev/null || stat -f %Su "$git_dir/config" 2>/dev/null || echo "$USER")"

        if [[ "$owner" == "root" ]]; then
            log_error "Git repository files are owned by root"
            log_info "To fix: sudo chown -R $USER:$USER $(git rev-parse --show-toplevel)"
            return "$E_PERMISSION"
        fi
    fi

    log_debug "Git repository validated [OK]"
    return 0
}

################################################################################
# Git State Detection and Validation
################################################################################

detect_git_state() {
    log_debug "Detecting git state..."

    local git_dir
    git_dir="$(git rev-parse --git-dir 2>/dev/null)"

    # Check for ongoing operations (order matters - check most specific first)
    if [[ -f "$git_dir/MERGE_HEAD" ]]; then
        GIT_STATE="merge"
        log_debug "Git state: merge in progress"
        return 0
    elif [[ -d "$git_dir/rebase-merge" ]] || [[ -d "$git_dir/rebase-apply" ]]; then
        GIT_STATE="rebase"
        log_debug "Git state: rebase in progress"
        return 0
    elif [[ -f "$git_dir/REVERT_HEAD" ]]; then
        GIT_STATE="revert"
        log_debug "Git state: revert in progress"
        return 0
    elif [[ -f "$git_dir/CHERRY_PICK_HEAD" ]]; then
        GIT_STATE="cherry-pick"
        log_debug "Git state: cherry-pick in progress"
        return 0
    elif [[ -f "$git_dir/BISECT_LOG" ]]; then
        GIT_STATE="bisect"
        log_debug "Git state: bisect in progress"
        return 0
    elif [[ -d "$git_dir/sequencer" ]]; then
        GIT_STATE="sequencer"
        log_debug "Git state: sequencer operation in progress (interactive rebase/revert)"
        return 0
    fi

    # Check for local changes
    check_local_changes

    if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
        GIT_STATE="dirty"
        log_debug "Git state: dirty (local modifications)"
    else
        GIT_STATE="clean"
        log_debug "Git state: clean"
    fi

    return 0
}

validate_clean_state() {
    detect_git_state

    case "$GIT_STATE" in
        merge)
            log_error "Git merge in progress"
            log_info "You must complete or abort the merge first:"
            log_info "  To continue merge:  git merge --continue"
            log_info "  To cancel merge:    git merge --abort"
            return "$E_BAD_STATE"
            ;;
        rebase)
            log_error "Git rebase in progress"
            log_info "You must complete or abort the rebase first:"
            log_info "  To continue rebase: git rebase --continue"
            log_info "  To cancel rebase:   git rebase --abort"
            return "$E_BAD_STATE"
            ;;
        revert)
            log_error "Git revert in progress"
            log_info "You must complete or abort the revert first:"
            log_info "  To continue:        git revert --continue"
            log_info "  To cancel:          git revert --abort"
            return "$E_BAD_STATE"
            ;;
        cherry-pick)
            log_error "Git cherry-pick in progress"
            log_info "You must complete or abort the cherry-pick first:"
            log_info "  To continue:        git cherry-pick --continue"
            log_info "  To cancel:          git cherry-pick --abort"
            return "$E_BAD_STATE"
            ;;
        bisect)
            log_error "Git bisect in progress"
            log_info "You must finish the bisect first:"
            log_info "  To complete: git bisect reset"
            return "$E_BAD_STATE"
            ;;
        sequencer)
            log_error "Git sequencer operation in progress"
            log_info "You must complete or abort the current operation first"
            log_info "Check 'git status' for details"
            return "$E_BAD_STATE"
            ;;
        clean | dirty)
            # These are valid states
            return 0
            ;;
        *)
            log_warn "Unknown git state detected"
            return 0
            ;;
    esac
}

################################################################################
# Repository State Functions
################################################################################

get_default_branch() {
    log_debug "Detecting default branch..."

    # Special handling for git-flow: if both main and develop exist, develop is development branch
    local has_develop=false
    local has_main=false
    local remote_head=""

    # Check what branches exist
    if git show-ref --verify --quiet refs/remotes/origin/develop 2>/dev/null; then
        has_develop=true
        log_debug "Found develop branch"
    fi

    if git show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
        has_main=true
        log_debug "Found main branch"
    fi

    # Git-flow pattern: both main and develop exist -> develop is development
    if [[ "$has_develop" == "true" && "$has_main" == "true" ]]; then
        log_debug "Git-flow detected (both main and develop exist) -> using develop as development branch"
        echo "develop"
        return 0
    fi

    # Try to get remote HEAD (but only use if not in git-flow pattern)
    if remote_head="$(git ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/ {sub(/refs\/heads\//, "", $2); print $2; exit}')"; then
        if [[ -n "$remote_head" ]]; then
            log_debug "Remote HEAD points to: $remote_head"
            echo "$remote_head"
            return 0
        fi
    fi

    log_debug "Remote HEAD detection failed, checking local branches..."

    # Check for develop (single develop branch without main)
    if [[ "$has_develop" == "true" ]]; then
        log_debug "Default branch: develop (git-flow single)"
        echo "develop"
        return 0
    fi

    # Check for main (GitHub modern)
    if [[ "$has_main" == "true" ]]; then
        log_debug "Default branch: main (GitHub)"
        echo "main"
        return 0
    fi

    # Check for master (legacy)
    if git show-ref --verify --quiet refs/remotes/origin/master 2>/dev/null; then
        log_debug "Default branch: master (legacy)"
        echo "master"
        return 0
    fi

    # Fallback
    log_debug "No standard branches found, using fallback: main"
    echo "main"
    return 0
}

get_current_version() {
    log_debug "Getting current version..."

    # Check if HEAD exists
    if ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        CURRENT_VERSION="(empty repository)"
        CURRENT_BRANCH=""
        IS_DETACHED=false
        return 0
    fi

    # Get short commit hash
    CURRENT_VERSION="$(git rev-parse --short HEAD 2>/dev/null)"

    # Check if detached HEAD
    if ! git symbolic-ref -q HEAD >/dev/null 2>&1; then
        IS_DETACHED=true
        CURRENT_BRANCH=""

        # Try to get tag name
        local tag_name
        if tag_name="$(git describe --tags --exact-match HEAD 2>/dev/null)"; then
            CURRENT_VERSION="$tag_name"
        fi

        log_debug "Viewing specific version: $CURRENT_VERSION"
    else
        IS_DETACHED=false
        CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
        log_debug "On branch $CURRENT_BRANCH at $CURRENT_VERSION"
    fi

    return 0
}

check_local_changes() {
    log_debug "Checking for local changes..."

    # Check if HEAD exists
    if ! git rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        HAS_LOCAL_CHANGES=false
        return 0
    fi

    # Check for any changes
    if ! git diff-index --quiet HEAD 2>/dev/null \
        || git ls-files --others --exclude-standard 2>/dev/null | grep -q .; then
        HAS_LOCAL_CHANGES=true
        log_debug "Local modifications detected"
    else
        HAS_LOCAL_CHANGES=false
        log_debug "No local modifications"
    fi

    return 0
}

################################################################################
# User Interaction Helpers
################################################################################

confirm_action() {
    local prompt="$1"
    local default="${2:-N}"
    local response

    if [[ "$default" == "Y" ]]; then
        if ! read -r -p "${prompt} [Y/n] " response; then
            # EOF - return false for safety
            echo
            return 1
        fi
        response="${response:-Y}"
    else
        if ! read -r -p "${prompt} [y/N] " response; then
            # EOF - return false for safety
            echo
            return 1
        fi
        response="${response:-N}"
    fi

    [[ "$response" =~ ^[Yy]$ ]]
}

# Require explicit "yes" confirmation for destructive operations
confirm_destructive_action() {
    local prompt="$1"
    local response

    if ! read -r -p "${prompt} " response; then
        # EOF - return false for safety
        echo
        return 1
    fi
    [[ "$response" == "yes" ]]
}

################################################################################
# Transaction Management
################################################################################

transaction_begin() {
    local operation="$1"

    if [[ "${TRANSACTION_STATE[active]}" == "true" ]]; then
        log_error "Transaction already active: ${TRANSACTION_STATE[operation]}"
        return "$E_GENERAL"
    fi

    log_debug "Transaction begin: $operation"

    # Save current state
    TRANSACTION_STATE[active]=true
    TRANSACTION_STATE[operation]="$operation"
    TRANSACTION_STATE[original_head]="$(git rev-parse HEAD 2>/dev/null || echo "")"

    if ! git symbolic-ref -q HEAD >/dev/null 2>&1; then
        TRANSACTION_STATE[original_ref]="HEAD" # Detached
    else
        TRANSACTION_STATE[original_ref]="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    fi

    return 0
}

transaction_stash_changes() {
    if [[ "${TRANSACTION_STATE[active]}" != "true" ]]; then
        log_error "No active transaction"
        return "$E_GENERAL"
    fi

    log_debug "Creating transaction stash..."

    # Use nanoseconds + random for better uniqueness
    local stash_nonce
    stash_nonce="$(date +%s.%N 2>/dev/null || date +%s)-$$-$RANDOM"

    local stash_message
    stash_message="lyrebird-tx-${TRANSACTION_STATE[operation]}-${stash_nonce}"

    if ! git stash push -u -m "$stash_message" >/dev/null 2>&1; then
        log_error "Failed to save your changes"
        return "$E_GENERAL"
    fi

    # Verify stash was created and get its hash
    local stash_hash
    if ! stash_hash="$(git rev-parse 'stash@{0}' 2>/dev/null)"; then
        log_error "Failed to save your changes (couldn't verify save)"
        return "$E_GENERAL"
    fi

    TRANSACTION_STATE[stash_hash]="$stash_hash"
    log_debug "Transaction stash created: $stash_hash"

    return 0
}

transaction_commit() {
    if [[ "${TRANSACTION_STATE[active]}" != "true" ]]; then
        log_error "No active transaction"
        return "$E_GENERAL"
    fi

    log_debug "Transaction commit: ${TRANSACTION_STATE[operation]}"

    # Clear transaction state
    TRANSACTION_STATE[active]=false
    TRANSACTION_STATE[stash_hash]=""
    TRANSACTION_STATE[original_ref]=""
    TRANSACTION_STATE[original_head]=""
    TRANSACTION_STATE[operation]=""

    return 0
}

transaction_rollback() {
    if [[ "${TRANSACTION_STATE[active]}" != "true" ]]; then
        log_debug "No active transaction to rollback"
        return 0
    fi

    log_warn "Rolling back: ${TRANSACTION_STATE[operation]}"

    # Disable traps during rollback to prevent recursion
    local original_exit_trap original_int_trap original_term_trap
    original_exit_trap="$(trap -p EXIT)"
    original_int_trap="$(trap -p INT)"
    original_term_trap="$(trap -p TERM)"
    trap - EXIT INT TERM

    # Attempt to return to original ref
    if [[ -n "${TRANSACTION_STATE[original_ref]}" ]]; then
        log_debug "Restoring original ref: ${TRANSACTION_STATE[original_ref]}"
        if ! git checkout "${TRANSACTION_STATE[original_ref]}" --force >/dev/null 2>&1; then
            log_error "Could not restore original ref"
            # Try to at least get to original HEAD
            if [[ -n "${TRANSACTION_STATE[original_head]}" ]]; then
                git checkout "${TRANSACTION_STATE[original_head]}" --force >/dev/null 2>&1 || true
            fi
        fi
    fi

    # Restore stashed changes if any
    if [[ -n "${TRANSACTION_STATE[stash_hash]}" ]]; then
        log_debug "Restoring saved changes: ${TRANSACTION_STATE[stash_hash]}"

        # Find stash ref from hash
        local stash_ref
        stash_ref=$(git stash list --format="%gd %H" | grep "${TRANSACTION_STATE[stash_hash]}" | cut -d' ' -f1 || echo "")

        if [[ -n "$stash_ref" ]]; then
            if git stash pop "$stash_ref" >/dev/null 2>&1; then
                log_success "Your changes were restored"
            else
                log_warn "Could not restore your changes automatically"
                log_info "Your changes are saved in: $stash_ref"
                log_info "To restore: git stash pop $stash_ref"
            fi
        else
            log_warn "Could not find your saved changes"
        fi
    fi

    # Restore service files if update was in progress
    if [[ -f "$SERVICE_UPDATE_MARKER" ]]; then
        log_warn "Rolling back service update..."
        if load_service_state_from_marker; then
            restore_service_from_backup

            # Reload systemd and attempt to restart service
            if [[ "${SERVICE_STATE[was_running]}" == "true" ]]; then
                systemctl daemon-reload 2>/dev/null || true
                systemctl start "$SERVICE_NAME" 2>/dev/null || {
                    log_warn "Could not restart service after rollback"
                    log_info "Manual intervention may be required"
                    log_info "Check: systemctl status $SERVICE_NAME"
                }
            fi

            cleanup_service_backups
        fi
        rm -f "$SERVICE_UPDATE_MARKER"
    fi

    # Clear transaction state
    TRANSACTION_STATE[active]=false
    TRANSACTION_STATE[stash_hash]=""
    TRANSACTION_STATE[original_ref]=""
    TRANSACTION_STATE[original_head]=""
    TRANSACTION_STATE[operation]=""

    # Restore traps
    eval "$original_exit_trap"
    eval "$original_int_trap"
    eval "$original_term_trap"

    log_warn "Rollback complete"

    return 0
}

################################################################################
# Git Operations with Validation
################################################################################

fetch_updates_safe() {
    log_step "Checking for updates from GitHub..."

    local attempt=1
    local fetch_output
    local fetch_succeeded=false

    while [[ $attempt -le $FETCH_RETRIES ]]; do
        if [[ $attempt -gt 1 ]]; then
            log_info "Retry attempt $attempt of $FETCH_RETRIES (waiting ${FETCH_RETRY_DELAY}s...)"
            sleep "$FETCH_RETRY_DELAY"
        fi

        # Try fetch with timeout if available
        if command -v timeout >/dev/null 2>&1; then
            if fetch_output=$(timeout "$FETCH_TIMEOUT" git fetch --all --tags --prune 2>&1); then
                fetch_succeeded=true
                break
            fi
        else
            # No timeout command, try without it
            if fetch_output=$(git fetch --all --tags --prune 2>&1); then
                fetch_succeeded=true
                break
            fi
        fi

        log_debug "Fetch attempt $attempt failed"
        attempt=$((attempt + 1))
    done

    if [[ "$fetch_succeeded" != "true" ]]; then
        log_error "Failed to fetch updates after $FETCH_RETRIES attempts"
        log_error "Please check your internet connection"
        log_debug "Last error: $fetch_output"
        return "$E_NO_REMOTE"
    fi

    # Update remote HEAD reference
    git remote set-head origin --auto >/dev/null 2>&1 || true

    log_success "Updates fetched successfully"
    return 0
}

validate_version_exists() {
    local version="$1"

    if [[ -z "$version" ]]; then
        return 1
    fi

    log_debug "Validating version: $version"

    # Check various ref types
    if git rev-parse --verify --quiet "refs/tags/$version" >/dev/null 2>&1; then
        log_debug "Found as tag: $version"
        return 0
    elif git rev-parse --verify --quiet "refs/heads/$version" >/dev/null 2>&1; then
        log_debug "Found as local branch: $version"
        return 0
    elif git rev-parse --verify --quiet "refs/remotes/origin/$version" >/dev/null 2>&1; then
        log_debug "Found as remote branch: $version"
        return 0
    elif git rev-parse --verify --quiet "$version^{commit}" >/dev/null 2>&1; then
        log_debug "Found as commit: $version"
        return 0
    fi

    log_debug "Version not found: $version"
    return 1
}

switch_version_safe() {
    local target_version="$1"

    if [[ -z "$target_version" ]]; then
        log_error "No version specified"
        return "$E_GENERAL"
    fi

    # Validate we're in a clean state for the operation
    if ! validate_clean_state; then
        return "$E_BAD_STATE"
    fi

    # Validate target exists
    if ! validate_version_exists "$target_version"; then
        log_error "Version '$target_version' does not exist"
        log_info "Try running 'Check for Updates' first (option 4)"
        return "$E_GENERAL"
    fi

    # Get current state
    get_current_version

    # Check if already on this version
    if [[ "$CURRENT_VERSION" == "$target_version" ]]; then
        log_info "Already on version: $target_version"
        return 0
    fi

    # Begin transaction
    if ! transaction_begin "switch to $target_version"; then
        return "$E_GENERAL"
    fi

    # Handle local changes
    check_local_changes
    if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
        echo
        log_warn "You have local modifications"
        echo
        git status --short 2>/dev/null | head -n 15

        local total_changes
        total_changes=$(git status --short 2>/dev/null | wc -l)
        if [[ "$total_changes" -gt 15 ]]; then
            echo "  ... and $((total_changes - 15)) more files"
        fi
        echo

        log_info "Your changes must be saved before switching versions"
        echo
        if ! confirm_action "Save your changes temporarily? (recommended)"; then
            log_info "Operation cancelled"
            transaction_rollback
            return "$E_USER_ABORT"
        fi

        if ! transaction_stash_changes; then
            transaction_rollback
            return "$E_GENERAL"
        fi

        log_success "Your changes have been saved and will be restored after the update"
    fi

    # Handle systemd service update (pre-checkout)
    local service_update_result=0
    if handle_systemd_service_update "$target_version"; then
        log_debug "Service update preparation successful"
    else
        service_update_result=$?
        if [[ $service_update_result -eq $E_USER_ABORT ]]; then
            log_info "Operation cancelled by user during service update"
            transaction_rollback
            return "$E_USER_ABORT"
        else
            log_error "Service update preparation failed"
            transaction_rollback
            return "$E_GENERAL"
        fi
    fi

    # Check if script itself will be modified (self-update)
    local script_will_change=false
    if ! git diff --quiet HEAD "$target_version" -- "$SCRIPT_NAME" 2>/dev/null; then
        script_will_change=true
        log_info "The updater script itself will be updated"
        log_info "The process will restart automatically after the update"
        echo
        sleep 2
    fi

    # Perform the checkout
    log_step "Switching to version: $target_version"

    # Verify write permissions to working directory before checkout
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
    if [[ -z "$repo_root" ]]; then
        log_error "Could not determine repository root"
        transaction_rollback
        return "$E_GENERAL"
    fi

    if [[ ! -w "$repo_root" ]]; then
        log_error "No write permission for working directory: $repo_root"
        log_info "To fix: sudo chown -R $USER:$USER $repo_root"
        transaction_rollback
        return "$E_PERMISSION"
    fi

    local checkout_output
    if ! checkout_output=$(git checkout "$target_version" 2>&1); then
        log_error "Failed to switch to version: $target_version"
        echo "$checkout_output" >&2
        transaction_rollback
        return "$E_GENERAL"
    fi

    # Verify we actually switched to the target
    local new_head
    new_head="$(git rev-parse HEAD 2>/dev/null)"
    local target_head
    target_head="$(git rev-parse "$target_version" 2>/dev/null)"

    if [[ "$new_head" != "$target_head" ]]; then
        log_error "Checkout completed but HEAD does not match target"
        log_error "This indicates a git state inconsistency"
        transaction_rollback
        return "$E_GENERAL"
    fi

    log_success "Switched to version: $target_version"

    # Set executable permissions on known scripts
    set_script_permissions

    # Handle self-update scenario
    if [[ "$script_will_change" == "true" ]]; then
        log_info "Restarting with updated version..."

        # Compute absolute path for robustness
        local script_path
        if command -v realpath >/dev/null 2>&1; then
            script_path="$(realpath "$SCRIPT_NAME" 2>/dev/null)"
        elif command -v readlink >/dev/null 2>&1; then
            script_path="$(readlink -f "$SCRIPT_NAME" 2>/dev/null)"
        else
            # Fallback to constructing absolute path
            script_path="${SCRIPT_DIR}/${SCRIPT_NAME}"
        fi

        # Ensure script is executable
        if [[ ! -x "$script_path" ]]; then
            if ! chmod +x "$script_path" 2>/dev/null; then
                log_error "Failed to make new script executable: $script_path"
                log_error "Self-update cannot proceed"
                transaction_rollback
                return "$E_PERMISSION"
            fi
        fi

        # CRITICAL: Validate syntax before committing transaction
        log_debug "Validating new script syntax..."
        if ! bash -n "$script_path" 2>/dev/null; then
            log_error "New script has syntax errors!"
            log_error "Cannot safely restart with broken script"
            echo >&2
            log_error "Syntax validation errors:"
            bash -n "$script_path" 2>&1 | head -10 | sed 's/^/  /' >&2
            echo >&2
            log_error "Rolling back to previous version..."
            transaction_rollback
            return "$E_GENERAL"
        fi
        log_debug "Syntax validation passed [OK]"

        # Prepare restart arguments
        local restart_args=()
        if [[ -n "${TRANSACTION_STATE[stash_hash]}" ]]; then
            restart_args=("--post-update-restore" "${TRANSACTION_STATE[stash_hash]}")
        else
            restart_args=("--post-update-complete")
        fi

        # NOW safe to commit transaction (syntax validated)
        transaction_commit

        # Service update marker remains for post-exec completion
        # No need to cleanup - new script will handle it

        # Replace this process with the new script
        # shellcheck disable=SC2093  # exec is intentional here for self-update
        exec "$script_path" "${restart_args[@]}"

        # This line only reached if exec fails (kernel-level failure)
        log_error "Failed to restart with new version (exec failed)"
        log_error "This is a critical error - manual intervention required"
        log_error "The new version is checked out but not running"
        log_error "Try running manually: $script_path"
        exit "$E_GENERAL"
    fi

    # Complete service update (post-checkout)
    if ! post_checkout_service_update; then
        log_error "Service update failed after checkout"
        transaction_rollback
        return "$E_GENERAL"
    fi

    # Remove service update marker on success
    rm -f "$SERVICE_UPDATE_MARKER"

    # Restore stashed changes (if not self-updating)
    if [[ -n "${TRANSACTION_STATE[stash_hash]}" ]]; then
        echo
        log_step "Restoring your saved changes..."

        local stash_ref
        stash_ref=$(git stash list --format="%gd %H" | grep "${TRANSACTION_STATE[stash_hash]}" | cut -d' ' -f1 || echo "")

        if [[ -z "$stash_ref" ]]; then
            log_warn "Could not find your saved changes"
            log_info "Your changes may have been lost (stash hash: ${TRANSACTION_STATE[stash_hash]})"
        else
            # Try to pop the stash
            if git stash pop "$stash_ref" >/dev/null 2>&1; then
                log_success "Changes restored successfully"
            else
                # Pop failed, try apply
                if git stash apply "$stash_ref" >/dev/null 2>&1; then
                    log_success "Changes restored (with manual stash cleanup needed)"
                    log_info "To remove the stash: git stash drop $stash_ref"
                else
                    log_warn "Could not restore changes automatically (conflicts detected)"
                    log_info "Your changes are saved in: $stash_ref"
                    log_info "To restore manually: git stash pop $stash_ref"
                    log_info "You may need to resolve conflicts first"
                fi
            fi
        fi
    fi

    # Commit transaction
    transaction_commit

    # Update state
    get_current_version
    check_local_changes

    echo
    log_success "Version switch complete!"

    return 0
}

reset_to_clean_state() {
    local target="$1"

    if [[ -z "$target" ]]; then
        log_error "No target specified for reset"
        return "$E_GENERAL"
    fi

    # Validate we're not in a bad state
    if ! validate_clean_state; then
        return "$E_BAD_STATE"
    fi

    # Validate target exists
    if ! git rev-parse --verify --quiet "$target" >/dev/null 2>&1; then
        log_error "Target '$target' does not exist"
        return "$E_GENERAL"
    fi

    # Show what will be deleted before confirmation
    echo
    log_warn "WARNING: This action CANNOT be undone!"
    echo
    log_warn "The following changes will be PERMANENTLY deleted:"
    echo
    git status --short 2>/dev/null || echo "  (no changes)"
    echo
    log_warn "Reset target: $target"
    echo

    # Require explicit "yes" confirmation
    if ! confirm_destructive_action "Type 'yes' (case-sensitive) to confirm reset, or anything else to cancel: "; then
        log_info "Reset cancelled"
        return 0
    fi

    log_step "Resetting to clean state: $target"

    # Perform reset
    if ! git reset --hard "$target" >/dev/null 2>&1; then
        log_error "Failed to reset to $target"
        return "$E_GENERAL"
    fi

    # Clean untracked files
    if ! git clean -fd >/dev/null 2>&1; then
        log_warn "Could not remove all untracked files"
    fi

    log_success "Reset complete. Your changes are gone. Repository is clean."

    # Set script permissions
    set_script_permissions

    # Update state
    get_current_version
    check_local_changes

    return 0
}

set_script_permissions() {
    log_debug "Setting executable permissions on scripts..."

    local scripts=(
        "install_mediamtx.sh"
        "lyrebird-orchestrator.sh"
        "lyrebird-updater.sh"
        "lyrebird-stream-manager.sh"
        "usb-audio-mapper.sh"
    )

    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            if ! chmod +x "$script" 2>/dev/null; then
                log_warn "Could not set executable permission on $script (permission denied)"
                log_debug "This may cause issues when running $script"
            fi
        fi
    done

    return 0
}

################################################################################
# Version Listing and Selection
################################################################################

list_available_releases() {
    AVAILABLE_VERSIONS=()

    echo
    echo "${BOLD}=== Available Versions ===${NC}"
    echo

    # List stable releases (tags)
    echo "${BOLD}Stable Releases (numbered versions, tested and stable):${NC}"

    if git tag -l 'v*' --sort=-creatordate | head -n "$TAG_LIST_LIMIT" | grep -q .; then
        local counter=1
        while IFS= read -r tag; do
            local tag_date
            tag_date=$(git log -1 --format=%ai "$tag" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
            printf "  %2d) %-15s (created: %s)\n" "$counter" "$tag" "$tag_date"

            AVAILABLE_VERSIONS+=("$tag")
            ((counter++))
        done < <(git tag -l 'v*' --sort=-creatordate | head -n "$TAG_LIST_LIMIT")

        local tag_count
        tag_count=$(git tag -l 'v*' | wc -l)
        if [[ "$tag_count" -gt "$TAG_LIST_LIMIT" ]]; then
            echo "      ... and $((tag_count - TAG_LIST_LIMIT)) more (not shown)"
        fi
    else
        echo "  (no stable releases found)"
    fi

    echo
    echo "${BOLD}Development & Feature Branches (select any to switch):${NC}"
    echo "  The '${DEFAULT_BRANCH}' branch is where active development happens."
    echo

    local branch_counter=$((${#AVAILABLE_VERSIONS[@]} + 1))
    local git_branches
    git_branches=$(git branch -r | grep -v HEAD | sed 's/origin\///' | sed 's/^[[:space:]]*//')

    if [[ -n "$git_branches" ]]; then
        while IFS= read -r branch; do
            if [[ "$branch" == "$DEFAULT_BRANCH" ]]; then
                printf "  %2d) %s %s\n" "$branch_counter" "$branch" "(development)"
            else
                printf "  %2d) %s\n" "$branch_counter" "$branch"
            fi
            AVAILABLE_VERSIONS+=("$branch")
            ((branch_counter++))
        done <<<"$git_branches"
    else
        echo "  (no development branches found)"
    fi

    echo
    echo "${CYAN}Tip: You can also enter any commit hash or branch name directly${NC}"
    echo
}

select_version_interactive() {
    # Fetch updates first
    if ! fetch_updates_safe; then
        log_warn "Could not fetch updates - using cached information"
        echo
    fi

    # Show available versions
    list_available_releases

    echo "You can enter:"
    echo "  - A number from the list (e.g., 1, 5)"
    echo "  - A tag directly (e.g., v1.2.0)"
    echo "  - A branch name (e.g., ${DEFAULT_BRANCH}, feature/streaming)"
    echo "  - A commit hash (e.g., abc1234)"
    echo "  - Press Enter to cancel"
    echo
    read -r -p "Your selection: " selection

    if [[ -z "$selection" ]]; then
        log_info "Selection cancelled"
        return 0
    fi

    local target_version=""

    # Check if input is a number
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        local index=$((selection - 1))

        if [[ "$index" -ge 0 ]] && [[ "$index" -lt "${#AVAILABLE_VERSIONS[@]}" ]]; then
            target_version="${AVAILABLE_VERSIONS[$index]}"
            log_info "Selected: $target_version"
        else
            log_error "Invalid selection: $selection"
            log_info "Please choose between 1 and ${#AVAILABLE_VERSIONS[@]}"
            return "$E_GENERAL"
        fi
    else
        # Validate direct version name input against whitelist
        if [[ ! "$selection" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
            log_error "Invalid version format"
            log_error "Only alphanumeric characters, dots, underscores, slashes, and hyphens are allowed"
            return "$E_GENERAL"
        fi

        target_version="$selection"
    fi

    # Additional validation - verify version exists
    if ! validate_version_exists "$target_version"; then
        log_error "Version '$target_version' does not exist"
        log_info "Try running 'Check for Updates' first (option 4)"
        return "$E_GENERAL"
    fi

    switch_version_safe "$target_version"
}

switch_to_latest_stable() {
    log_step "Finding latest stable release..."

    # Fetch first
    if ! fetch_updates_safe; then
        log_warn "Using cached version information"
    fi

    # Get latest tag by creation date
    local latest_tag
    if ! latest_tag="$(git tag -l 'v*' --sort=-creatordate | head -n 1)"; then
        log_error "No stable releases found"
        return "$E_GENERAL"
    fi

    if [[ -z "$latest_tag" ]]; then
        log_error "No version tags found in repository"
        log_info "The repository may not have any releases yet"
        return "$E_GENERAL"
    fi

    log_info "Latest stable release: $latest_tag"
    switch_version_safe "$latest_tag"
}

switch_to_development() {
    log_step "Switching to development version..."

    # Fetch first
    if ! fetch_updates_safe; then
        log_warn "Using cached version information"
    fi

    switch_version_safe "$DEFAULT_BRANCH"
}

################################################################################
# Status Display Functions
################################################################################

show_status() {
    get_current_version
    check_local_changes
    detect_git_state

    echo
    echo "${BOLD}=== Repository Status ===${NC}"
    echo

    # Current position
    if [[ "$IS_DETACHED" == "true" ]]; then
        echo "${BOLD}Current State:${NC}"
        echo "  Status:     ${YELLOW}Viewing a Specific Release (not on a branch)${NC}"
        echo "  Version:    ${BOLD}$CURRENT_VERSION${NC}"

        local tags_here
        tags_here=$(git tag --points-at HEAD 2>/dev/null | tr '\n' ' ')
        if [[ -n "$tags_here" ]]; then
            echo "  Tags:       $tags_here"
        fi
    else
        echo "${BOLD}Current Branch:${NC}"
        echo "  Branch:     ${BOLD}$CURRENT_BRANCH${NC}"
        echo "  Commit:     ${BOLD}$CURRENT_VERSION${NC}"

        # Show branch type
        if [[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]]; then
            echo "  Type:       ${CYAN}Development (where new features are added)${NC}"
        else
            echo "  Type:       Feature/Release branch"
        fi

        # Check if on a tag
        local current_tag
        current_tag=$(git describe --exact-match --tags HEAD 2>/dev/null || echo "")
        if [[ -n "$current_tag" ]]; then
            echo "  Tag:        ${GREEN}$current_tag${NC}"
        fi

        # Show relationship to remote
        if git show-ref --verify --quiet "refs/remotes/origin/$CURRENT_BRANCH" 2>/dev/null; then
            local ahead behind
            ahead=$(git rev-list --count "origin/$CURRENT_BRANCH..HEAD" 2>/dev/null || echo "0")
            behind=$(git rev-list --count "HEAD..origin/$CURRENT_BRANCH" 2>/dev/null || echo "0")

            if [[ "$ahead" -gt 0 ]] && [[ "$behind" -gt 0 ]]; then
                echo "  Remote:     ${YELLOW}Diverged ($ahead ahead, $behind behind)${NC}"
            elif [[ "$ahead" -gt 0 ]]; then
                echo "  Remote:     ${YELLOW}$ahead commit(s) ahead${NC}"
            elif [[ "$behind" -gt 0 ]]; then
                echo "  Remote:     ${YELLOW}$behind commit(s) behind${NC}"
            else
                echo "  Remote:     ${GREEN}In sync${NC}"
            fi
        else
            echo "  Remote:     ${YELLOW}No remote tracking${NC}"
        fi
    fi

    echo
    echo "${BOLD}Working Directory:${NC}"

    case "$GIT_STATE" in
        clean)
            echo "  Status:     ${GREEN}Ready (no local modifications)${NC}"
            ;;
        dirty)
            echo "  Status:     ${YELLOW}Has Local Modifications${NC}"
            echo
            echo "  File Status Legend:  M=modified  A=added  D=deleted  ?=untracked"
            echo
            git status --short | head -n 10 | sed 's/^/    /'

            local change_count
            change_count=$(git status --short | wc -l)
            if [[ "$change_count" -gt 10 ]]; then
                echo "    ... and $((change_count - 10)) more"
            fi
            ;;
        merge | rebase | revert | cherry-pick | bisect | sequencer)
            echo "  Status:     ${RED}${GIT_STATE^^} IN PROGRESS${NC}"
            ;;
    esac

    echo
    echo "${BOLD}Repository Info:${NC}"

    local repo_remote
    repo_remote=$(git remote get-url origin 2>/dev/null || echo "none")
    echo "  Remote:     $repo_remote"

    local last_fetch="never"
    if [[ -f ".git/FETCH_HEAD" ]] && command -v stat >/dev/null 2>&1; then
        last_fetch=$(stat -c %y ".git/FETCH_HEAD" 2>/dev/null | cut -d'.' -f1 \
            || stat -f %Sm ".git/FETCH_HEAD" 2>/dev/null || echo "unknown")
        # Ensure last_fetch is not empty
        [[ -z "$last_fetch" ]] && last_fetch="unknown"
    fi
    echo "  Last fetch: $last_fetch"

    # Show systemd service status if installed
    if [[ -f "$SERVICE_FILE" ]]; then
        echo
        echo "${BOLD}Systemd Service:${NC}"
        echo "  Service:    $SERVICE_NAME"

        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            echo "  Status:     ${GREEN}Running${NC}"
        else
            echo "  Status:     ${YELLOW}Stopped${NC}"
        fi

        if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
            echo "  Enabled:    ${GREEN}Yes${NC}"
        else
            echo "  Enabled:    ${YELLOW}No${NC}"
        fi
    fi

    echo
}

show_startup_diagnostics() {
    get_current_version
    check_local_changes

    echo
    echo "${BOLD}=== LyreBirdAudio Version Manager v${VERSION} ===${NC}"
    echo

    # Current version
    if [[ "$IS_DETACHED" == "true" ]]; then
        echo "Current:  ${YELLOW}Viewing Release: ${BOLD}$CURRENT_VERSION${NC}${YELLOW} (not tracking a branch)${NC}"
    else
        if [[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]]; then
            echo "Current:  ${GREEN}Development Branch ${BOLD}$CURRENT_BRANCH${NC} @ $CURRENT_VERSION"
        else
            echo "Current:  ${CYAN}Branch ${BOLD}$CURRENT_BRANCH${NC} @ $CURRENT_VERSION"
        fi
    fi

    if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
        echo "Changes:  ${YELLOW}You have local modifications${NC}"
    else
        echo "Changes:  ${GREEN}Clean working directory${NC}"
    fi

    echo
    log_step "Checking for updates..."

    # Quick fetch (with short timeout)
    local fetch_ok=false
    if command -v timeout >/dev/null 2>&1; then
        if timeout 5 git fetch --all --tags --prune --quiet 2>/dev/null; then
            fetch_ok=true
        fi
    else
        if git fetch --all --tags --prune --quiet 2>/dev/null; then
            fetch_ok=true
        fi
    fi

    if [[ "$fetch_ok" == "true" ]]; then
        echo "          ${GREEN}[OK]${NC} Connected to GitHub"
    else
        echo "          ${YELLOW}!${NC} Could not connect (using cached data)"
    fi

    # Check for stable releases
    local latest_tag
    latest_tag="$(git tag -l 'v*' --sort=-creatordate 2>/dev/null | head -n 1)"

    if [[ -n "$latest_tag" ]]; then
        local current_tag
        current_tag="$(git describe --exact-match --tags HEAD 2>/dev/null || echo "")"

        if [[ -n "$current_tag" ]] && [[ "$current_tag" == "$latest_tag" ]]; then
            echo "Stable:   ${GREEN}You're on latest: $latest_tag${NC}"
        else
            echo "Stable:   ${YELLOW}Update available: $latest_tag${NC}"
            echo "          ${CYAN}^ Select option 1 to update${NC}"
        fi
    fi

    # Check development branch
    if [[ "$IS_DETACHED" == "false" ]]; then
        local behind
        behind=$(git rev-list --count "HEAD..origin/$CURRENT_BRANCH" 2>/dev/null || echo "0")

        if [[ "$behind" -gt 0 ]]; then
            echo "Dev:      ${YELLOW}$behind commit(s) behind origin/$CURRENT_BRANCH${NC}"
            echo "          ${CYAN}^ Select option 2 to update${NC}"
        else
            echo "Dev:      ${GREEN}Up to date with origin/$CURRENT_BRANCH${NC}"
        fi
    fi

    echo

    # Only prompt if stdin is a terminal
    if [[ -t 0 ]]; then
        read -r -p "Press Enter to continue..."
    fi
}

################################################################################
# Help and Menu Functions
################################################################################

show_help() {
    # Get default branch dynamically
    local help_default_branch="${DEFAULT_BRANCH:-develop}"

    cat <<EOF

================================================================================
   LyreBirdAudio Version Manager - Help Guide
================================================================================

BRANCH TYPES:
  - Stable Releases (tags like v1.2.0)
    - Tested, production-ready versions
    - Recommended for most users
    - Updates released periodically

  - Development Branch (${help_default_branch})
    - Latest code with new features
    - Where active development happens
    - May contain bugs or incomplete features
    - Good for testing new functionality

=== MAIN OPTIONS ===

1) Switch to Latest Stable Release
   ^ Newest tested version
   ^ Recommended for production use
   ^ Automatically checks for updates
   ^ Your changes will be saved temporarily
   ^ Systemd services automatically updated

2) Switch to Development Version (${help_default_branch})
   ^ Latest code with newest features
   ^ Where new features are actively developed
   ^ May have bugs or incomplete features
   ^ For testing and development
   ^ Your changes will be saved temporarily
   ^ Systemd services automatically updated

3) Switch to Specific Version or Branch
   ^ Choose any stable release (tag), development branch, or feature branch
   ^ Full list shows all available options
   ^ Can input version name directly (v1.2.0, develop, feature/xyz)
   ^ Useful for testing, switching between branches, or rollback
   ^ Your changes will be saved temporarily
   ^ Systemd services automatically updated

4) Check for New Updates
   ^ Downloads version information from GitHub
   ^ Doesn't change your current version
   ^ Shows what's available

5) Show Detailed Status
   ^ Your current version and branch
   ^ What type of branch you're on
   ^ Local modifications status
   ^ Sync status with remote
   ^ Repository information
   ^ Systemd service status

6) Discard All Changes & Reset
   ^ PERMANENTLY deletes local modifications
   ^ Resets to a clean version
   ^ Use with caution!

=== SYSTEMD SERVICE INTEGRATION ===

The updater now automatically handles systemd service updates:

  [OK] Detects if mediamtx-audio.service is installed
  [OK] Stops service before version switch
  [OK] Preserves custom environment variables
  [OK] Reinstalls service definition if script changed
  [OK] Restarts service after successful update
  [OK] Rolls back service on failure

Your custom service configuration (e.g., STREAM_MODE, MULTIPLEX_FILTER_TYPE)
will be preserved during updates.

=== SAFETY FEATURES ===

[OK] Your changes are automatically saved before updating
[OK] Service configurations are preserved across updates
[OK] Confirmation required for destructive actions
[OK] Automatic rollback if operations fail
[OK] Clear warnings before permanent actions
[OK] Service restoration on update failure
[OK] Syntax validation for self-updates

=== COMMON QUESTIONS ===

Q: What happens to my changes when I update?
A: They're automatically saved and will be restored after the update

Q: What happens to my systemd service?
A: It's automatically stopped, updated, and restarted with your custom config

Q: Can I undo an update?
A: Yes, use option 3 to switch back to any previous version

Q: What if something goes wrong?
A: The script automatically tries to recover, including service restoration

Q: How do I start fresh with no modifications?
A: Use option 6 to reset to a clean state

Q: What's the difference between stable and development?
A: Stable = tested releases (v1.2.0). Development = latest code (${help_default_branch})

Q: Will my custom service variables be lost?
A: No, custom environment variables are automatically preserved

Q: What if the updater itself has errors?
A: Syntax validation prevents deployment of broken scripts

=== MORE HELP ===

Visit: https://github.com/tomtom215/LyreBirdAudio

EOF
}

main_menu() {
    while true; do
        get_current_version
        check_local_changes

        clear
        echo
        echo "${BOLD}+---------------------------------------------------------+${NC}"
        echo "${BOLD}|     LyreBirdAudio - Version Manager v${VERSION}      |${NC}"
        echo "${BOLD}+---------------------------------------------------------+${NC}"
        echo

        # Status header
        if [[ "$IS_DETACHED" == "true" ]]; then
            echo "  Current:  ${YELLOW}$CURRENT_VERSION${NC}"
        else
            if [[ "$CURRENT_BRANCH" == "$DEFAULT_BRANCH" ]]; then
                echo "  Current:  ${GREEN}$CURRENT_BRANCH${NC} (development) @ ${BOLD}$CURRENT_VERSION${NC}"
            else
                echo "  Current:  ${CYAN}$CURRENT_BRANCH${NC} @ ${BOLD}$CURRENT_VERSION${NC}"
            fi
        fi

        if [[ "$HAS_LOCAL_CHANGES" == "true" ]]; then
            echo "  Changes:  ${YELLOW}Has local modifications${NC}"
        else
            echo "  Changes:  ${GREEN}None${NC}"
        fi

        # Show service status if installed
        if [[ -f "$SERVICE_FILE" ]]; then
            if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
                echo "  Service:  ${GREEN}Running${NC}"
            else
                echo "  Service:  ${YELLOW}Stopped${NC}"
            fi
        fi

        echo
        echo "${BOLD}=== UPDATE ===${NC}"
        echo "  ${BOLD}1${NC}) Switch to Latest Stable Release"
        echo "     (Newest tested version-recommended)"
        echo "  ${BOLD}2${NC}) Switch to Development Version (${DEFAULT_BRANCH})"
        echo "     (Latest code with new features-where active development happens)"
        echo "  ${BOLD}3${NC}) Switch to Specific Version or Branch"
        echo "     (Any release tag, branch, or commit-full flexibility)"
        echo
        echo "${BOLD}=== INFO ===${NC}"
        echo "  ${BOLD}4${NC}) Check for New Updates"
        echo "  ${BOLD}5${NC}) Show Detailed Status"
        echo
        echo "${BOLD}=== DANGER ZONE ===${NC}"
        echo "  ${BOLD}6${NC}) Discard All Changes & Reset..."
        echo
        echo "  ${BOLD}H${NC}) Help  |  ${BOLD}Q${NC}) Quit"
        echo
        read -r -p "Select [1-6, H, Q]: " choice

        case "$choice" in
            1)
                switch_to_latest_stable
                read -r -p "Press Enter to continue..."
                ;;
            2)
                switch_to_development
                read -r -p "Press Enter to continue..."
                ;;
            3)
                select_version_interactive
                read -r -p "Press Enter to continue..."
                ;;
            4)
                if fetch_updates_safe; then
                    list_available_releases
                fi
                read -r -p "Press Enter to continue..."
                ;;
            5)
                show_status
                read -r -p "Press Enter to continue..."
                ;;
            6)
                reset_menu
                ;;
            h | H)
                show_help
                read -r -p "Press Enter to continue..."
                ;;
            q | Q)
                echo
                log_info "Thank you for using LyreBirdAudio Version Manager"
                return 0
                ;;
            *)
                log_error "Invalid option: $choice"
                sleep 1
                ;;
        esac
    done
}

reset_menu() {
    while true; do
        echo
        echo "${BOLD}=== DISCARD CHANGES & RESET ===${NC}"
        log_warn "This will PERMANENTLY delete all your local modifications!"
        echo
        echo "Reset to:"
        echo "  ${BOLD}1${NC}) Latest remote version of current branch"
        echo "     (Only available if you're tracking a branch)"
        echo "  ${BOLD}2${NC}) Latest development version (${DEFAULT_BRANCH})"
        echo "  ${BOLD}3${NC}) Specific version (let me choose)"
        echo "  ${BOLD}C${NC}) Cancel"
        echo
        read -r -p "Select [1-3, C]: " choice

        case "$choice" in
            1)
                get_current_version
                if [[ "$IS_DETACHED" == "true" ]]; then
                    log_warn "You're viewing a specific version (not tracking a branch)"
                    log_info "Resetting to HEAD won't change anything"
                    log_info "Choose option 2 or 3 instead"
                    read -r -p "Press Enter to continue..."
                else
                    if git show-ref --verify --quiet "refs/remotes/origin/$CURRENT_BRANCH"; then
                        reset_to_clean_state "origin/$CURRENT_BRANCH"
                    else
                        log_error "Remote branch not found: origin/$CURRENT_BRANCH"
                    fi
                fi
                read -r -p "Press Enter to continue..."
                return 0
                ;;
            2)
                if git show-ref --verify --quiet "refs/remotes/origin/${DEFAULT_BRANCH}"; then
                    reset_to_clean_state "origin/${DEFAULT_BRANCH}"
                else
                    log_error "Development branch not found: origin/${DEFAULT_BRANCH}"
                    log_info "Try option 4 from main menu to fetch updates"
                fi
                read -r -p "Press Enter to continue..."
                return 0
                ;;
            3)
                log_step "Fetching available versions..."
                if ! fetch_updates_safe; then
                    log_warn "Using cached information"
                fi

                list_available_releases
                echo
                read -r -p "Enter version to reset to: " version

                if [[ -z "$version" ]]; then
                    log_info "Cancelled"
                elif ! validate_version_exists "$version"; then
                    log_error "Version '$version' does not exist"
                else
                    reset_to_clean_state "$version"
                fi
                read -r -p "Press Enter to continue..."
                return 0
                ;;
            c | C)
                log_info "Cancelled"
                read -r -p "Press Enter to continue..."
                return 0
                ;;
            *)
                log_error "Invalid choice"
                sleep 1
                ;;
        esac
    done
}

################################################################################
# Main Entry Point
################################################################################

main() {
    # Change to script directory
    if ! cd "$SCRIPT_DIR" 2>/dev/null; then
        log_error "Failed to change to script directory: $SCRIPT_DIR"
        exit "$E_GENERAL"
    fi

    # Check prerequisites
    if ! check_prerequisites; then
        exit "$E_PREREQUISITES"
    fi

    # Acquire lock
    if ! acquire_lock; then
        exit "$E_LOCKED"
    fi

    # Validate git repository
    if ! check_git_repository; then
        exit "$E_NOT_GIT_REPO"
    fi

    # Save and configure git settings
    save_git_config

    # Detect default branch (CRITICAL: Must be done early and consistently used)
    DEFAULT_BRANCH="$(get_default_branch)"
    log_debug "Default branch: $DEFAULT_BRANCH"

    # Handle command line arguments
    if [[ $# -gt 0 ]]; then
        case "$1" in
            --post-update-restore)
                if [[ -z "${2:-}" ]]; then
                    log_error "Missing stash hash argument"
                    exit "$E_GENERAL"
                fi

                echo
                log_success "Updater has been updated!"
                log_step "Restoring your saved changes..."

                local stash_hash="$2"
                local stash_ref
                stash_ref=$(git stash list --format="%gd %H" | grep "$stash_hash" | cut -d' ' -f1 || echo "")

                if [[ -n "$stash_ref" ]]; then
                    if git stash pop "$stash_ref" >/dev/null 2>&1; then
                        log_success "Changes restored successfully"
                    else
                        log_warn "Could not restore changes automatically"
                        log_info "Your changes are in: $stash_ref"
                        log_info "To restore: git stash pop $stash_ref"
                    fi
                else
                    log_warn "Could not find your saved changes"
                fi

                # Check for pending service update
                if check_pending_service_update; then
                    if ! complete_pending_service_update; then
                        log_error "Service update completion failed"
                        log_info "You may need to manually check the service status"
                    fi
                fi

                echo
                read -r -p "Press Enter to continue..."
                ;;

            --post-update-complete)
                echo
                log_success "Updater has been updated successfully!"

                # Check for pending service update
                if check_pending_service_update; then
                    if ! complete_pending_service_update; then
                        log_error "Service update completion failed"
                        log_info "You may need to manually check the service status"
                    fi
                fi

                echo
                read -r -p "Press Enter to continue..."
                ;;

            --version | -v)
                echo "LyreBirdAudio Version Manager v${VERSION}"
                exit "$E_SUCCESS"
                ;;

            --help | -h)
                show_help
                exit "$E_SUCCESS"
                ;;

            --status | -s)
                show_status
                exit "$E_SUCCESS"
                ;;

            --list | -l)
                fetch_updates_safe || true
                list_available_releases
                exit "$E_SUCCESS"
                ;;

            *)
                log_error "Unknown option: $1"
                echo "Try '$SCRIPT_NAME --help' for more information"
                exit "$E_GENERAL"
                ;;
        esac
    fi

    # Check for pending service update (in case of abnormal termination)
    if check_pending_service_update; then
        log_warn "Detected incomplete service update from previous run"
        if confirm_action "Complete the pending service update now?"; then
            if ! complete_pending_service_update; then
                log_error "Failed to complete pending service update"
                log_info "You may need to manually check the service"
            fi
        else
            log_info "Service update will be attempted on next version switch"
        fi
        echo
    fi

    # Show startup diagnostics
    show_startup_diagnostics

    # Run interactive menu
    main_menu

    exit "$E_SUCCESS"
}

# Run main function
main "$@"

#!/bin/bash
# mediamtx-stream-manager.sh - Automatic MediaMTX audio stream configuration
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# Author: Tom F (https://github.com/tomtom215)
# Copyright: Tom F and LyreBirdAudio contributors
# License: Apache 2.0
#
# This script automatically detects USB microphones and creates MediaMTX 
# configurations for continuous 24/7 RTSP audio streams.
#
# Version: 1.3.3 - Critical production fixes based on comprehensive code review
# Compatible with MediaMTX v1.15.0+
#
# Version History:
# v1.3.3 - Critical production fixes based on comprehensive code review
#   CRITICAL FIXES:
#   - Fixed corrupted unicode characters in stream validation output
#   - Fixed unbound variable error (is_multiplex_mode) in show_status()
#   - Fixed file descriptor leak in log() function preventing FD exhaustion
#   - Fixed stale PID validation causing stream restart failures
#   - Fixed return value in start_all_ffmpeg_streams() to signal partial failures
#   - Fixed stream lock race condition preventing duplicate process creation
#   - Fixed multiplex stream name sanitization to prevent RTSP URL parsing failures
#   - Fixed file descriptor leak in lock acquisition error paths
#   - Fixed integer overflow in wrapper restart delay calculations
#   - Fixed MediaMTX orphaning when multiplex mode fails device validation
#   QUALITY FIXES:
#   - Fixed nullglob state restoration to handle both enabled/disabled states
#   - Added FFmpeg startup timeout constant to prevent hanging wrappers
#   - Removed unused variable from lock acquisition error handling
#   VERIFIED: Zero functionality removed, 100% backward compatible with v1.3.2
#
# v1.3.2 - Production hardening for multiplex mode
#   - Fixed array expansion bug in multiplex wrapper script
#   - Added systemd detection for signal handlers to prevent conflicts
#   - Added multiplex configuration to systemd service file
#
# v1.3.1 - Enhanced user interface for multiplex mode
#   - Added -f/--filter option for filter type selection (amix/amerge)
#   - Added -n/--name option for custom stream naming
#   - Added input validation for filter types
#
# v1.3.0 - Individual and multiplex streaming modes
#   - Added multiplex mode for combining multiple microphones into single stream
#   - Added filter support (amix for mixing, amerge for channel separation)
#   - Preserved all v1.2.0 critical fixes and functionality
#
# v1.2.0 - Major production reliability overhaul
#   - Fixed CONFIG_LOCK_FILE subshell isolation for proper config updates
#   - Fixed PID file permission race condition for systemd compatibility
#   - Made cleanup marker creation atomic to prevent partial states
#   - Added resource monitoring with 'monitor' command
#   - Added deferred cleanup handler for interrupted terminations
#   - Enhanced all atomic file operations (PID, config, markers)
#   - Improved process group termination and signal propagation
#   - Stabilized device detection with single scan approach
#
# Requirements:
# - MediaMTX installed (use install_mediamtx.sh)
# - USB audio devices
# - ffmpeg installed for audio encoding

# Ensure we're running with bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash. Please run with: bash $0 $*" >&2
    exit 1
fi

set -euo pipefail

# Enable error tracing in debug mode
if [[ "${DEBUG:-false}" == "true" ]]; then
    set -x
fi

# Constants
readonly VERSION="1.3.3"

# Script identification
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Error codes
readonly E_GENERAL=1
readonly E_CRITICAL_RESOURCE=2
readonly E_MISSING_DEPS=3
readonly E_CONFIG_ERROR=4
readonly E_LOCK_FAILED=5
readonly E_USB_NO_DEVICES=6

# Configurable paths with environment variable defaults
readonly CONFIG_DIR="${MEDIAMTX_CONFIG_DIR:-/etc/mediamtx}"
readonly CONFIG_FILE="${MEDIAMTX_CONFIG_FILE:-${CONFIG_DIR}/mediamtx.yml}"
readonly DEVICE_CONFIG_FILE="${MEDIAMTX_DEVICE_CONFIG:-${CONFIG_DIR}/audio-devices.conf}"
readonly PID_FILE="${MEDIAMTX_PID_FILE:-/var/run/mediamtx-audio.pid}"
readonly FFMPEG_PID_DIR="${MEDIAMTX_FFMPEG_DIR:-/var/lib/mediamtx-ffmpeg}"
readonly LOCK_FILE="${MEDIAMTX_LOCK_FILE:-/var/run/mediamtx-audio.lock}"
readonly LOG_FILE="${MEDIAMTX_LOG_FILE:-/var/log/mediamtx-stream-manager.log}"
readonly MEDIAMTX_LOG_FILE="${MEDIAMTX_LOG_FILE:-/var/log/mediamtx.out}"
readonly MEDIAMTX_BIN="${MEDIAMTX_BINARY:-/usr/local/bin/mediamtx}"
readonly MEDIAMTX_HOST="${MEDIAMTX_HOST:-localhost}"
# Note: These are NOT readonly to allow command-line option overrides
STREAM_MODE="${STREAM_MODE:-individual}"
MULTIPLEX_STREAM_NAME="${MULTIPLEX_STREAM_NAME:-all_mics}"
MULTIPLEX_FILTER_TYPE="${MULTIPLEX_FILTER_TYPE:-amix}"
readonly RESTART_MARKER="${MEDIAMTX_RESTART_MARKER:-/var/run/mediamtx-audio.restart}"
readonly CLEANUP_MARKER="${MEDIAMTX_CLEANUP_MARKER:-/var/run/mediamtx-audio.cleanup}"
readonly CONFIG_LOCK_FILE="${CONFIG_DIR}/.config.lock"

# System limits
SYSTEM_PID_MAX="$(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 32768)"
readonly SYSTEM_PID_MAX

# Timeouts
readonly PID_TERMINATION_TIMEOUT="${PID_TERMINATION_TIMEOUT:-10}"
readonly MEDIAMTX_API_TIMEOUT="${MEDIAMTX_API_TIMEOUT:-60}"
readonly LOCK_ACQUISITION_TIMEOUT="${LOCK_ACQUISITION_TIMEOUT:-30}"
readonly LOCK_STALE_THRESHOLD="${LOCK_STALE_THRESHOLD:-300}"  # 5 minutes
readonly FFMPEG_STARTUP_TIMEOUT="${FFMPEG_STARTUP_TIMEOUT:-30}"  # v1.3.3: Prevent hanging wrappers

# Audio settings
readonly DEFAULT_SAMPLE_RATE="48000"
readonly DEFAULT_CHANNELS="2"
readonly DEFAULT_CODEC="opus"
readonly DEFAULT_BITRATE="128k"
readonly DEFAULT_THREAD_QUEUE="8192"
readonly DEFAULT_ANALYZEDURATION="5000000"
readonly DEFAULT_PROBESIZE="5000000"

# Timing settings
readonly STREAM_STARTUP_DELAY="${STREAM_STARTUP_DELAY:-10}"
readonly STREAM_VALIDATION_ATTEMPTS="${STREAM_VALIDATION_ATTEMPTS:-3}"
readonly STREAM_VALIDATION_DELAY="${STREAM_VALIDATION_DELAY:-5}"
readonly USB_STABILIZATION_DELAY="${USB_STABILIZATION_DELAY:-5}"
readonly RESTART_STABILIZATION_DELAY="${RESTART_STABILIZATION_DELAY:-15}"

# Resource monitoring thresholds
readonly MAX_FD_WARNING="${MAX_FD_WARNING:-500}"
readonly MAX_FD_CRITICAL="${MAX_FD_CRITICAL:-1000}"
readonly MAX_CPU_WARNING="${MAX_CPU_WARNING:-20}"
readonly MAX_CPU_CRITICAL="${MAX_CPU_CRITICAL:-40}"
readonly MAX_WRAPPER_RESTARTS="${MAX_WRAPPER_RESTARTS:-50}"
readonly WRAPPER_SUCCESS_DURATION="${WRAPPER_SUCCESS_DURATION:-300}"

# Log rotation settings
readonly MAIN_LOG_MAX_SIZE="${MAIN_LOG_MAX_SIZE:-104857600}"  # 100MB
readonly FFMPEG_LOG_MAX_SIZE="${FFMPEG_LOG_MAX_SIZE:-10485760}"  # 10MB
readonly MEDIAMTX_LOG_MAX_SIZE="${MEDIAMTX_LOG_MAX_SIZE:-52428800}"  # 50MB

# Standard timing constants
readonly QUICK_SLEEP=0.1
readonly SHORT_SLEEP=1
readonly MEDIUM_SLEEP=2

# Global lock file descriptor
declare -gi MAIN_LOCK_FD=-1

# Global config lock file descriptor (v1.4.2)
declare -gi CONFIG_LOCK_FD=-1

# Skip cleanup flag
declare -g SKIP_CLEANUP=false

# Command being executed
declare -g CURRENT_COMMAND="${1:-}"

# Flag to indicate if we're in a stop/force-stop operation
declare -g STOPPING_SERVICE=false

# Color codes (only use if terminal supports them)
if [[ -t 2 ]] && command -v tput >/dev/null 2>&1; then
    RED="$(tput setaf 1)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)"
    CYAN="$(tput setaf 6)"
    NC="$(tput sgr0)"
    readonly RED GREEN YELLOW BLUE CYAN NC
else
    readonly RED=""
    readonly GREEN=""
    readonly YELLOW=""
    readonly BLUE=""
    readonly CYAN=""
    readonly NC=""
fi

# Command existence cache
declare -gA COMMAND_CACHE=()

# Cache command existence check
command_exists() {
    local cmd="$1"
    if [[ -z "${COMMAND_CACHE[$cmd]+isset}" ]]; then
        if command -v "$cmd" &>/dev/null; then
            COMMAND_CACHE[$cmd]=1
        else
            COMMAND_CACHE[$cmd]=0
        fi
    fi
    [[ "${COMMAND_CACHE[$cmd]}" -eq 1 ]]
}

# Portable stat alternative
get_file_size() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo 0
        return
    fi
    if command_exists stat; then
        stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0
    elif command_exists wc; then
        wc -c < "$file" 2>/dev/null | tr -d ' ' || echo 0
    else
        echo 0
    fi
}

# Portable hash function
compute_hash() {
    if command_exists sha256sum; then
        sha256sum | cut -d' ' -f1
    elif command_exists shasum; then
        shasum -a 256 | cut -d' ' -f1
    elif command_exists openssl; then
        openssl dgst -sha256 | sed 's/^.* //'
    else
        # Fallback: use cksum for basic change detection
        cksum | cut -d' ' -f1
    fi
}

# v1.4.2 FIX: Enhanced atomic cleanup with better marker creation
cleanup() {
    local exit_code=$?
    
    # Skip cleanup if requested or if we're stopping the service
    if [[ "${SKIP_CLEANUP}" == "true" ]] || [[ "${STOPPING_SERVICE}" == "true" ]]; then
        release_lock_unsafe
        release_config_lock_unsafe
        exit "${exit_code}"
    fi
    
    # Only perform cleanup on unexpected exit (non-zero exit code)
    if [[ $exit_code -ne 0 ]]; then
        # CRITICAL FIX: Use atomic marker creation
        local marker_tmp
        marker_tmp="$(mktemp "${CLEANUP_MARKER}.XXXXXX" 2>/dev/null)" && \
            mv -f "$marker_tmp" "${CLEANUP_MARKER}" 2>/dev/null || \
            touch "${CLEANUP_MARKER}" 2>/dev/null || true
    fi
    
    # Always release locks on exit
    release_lock_unsafe
    release_config_lock_unsafe
    
    exit "${exit_code}"
}

# Set trap for cleanup only in main script
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ $$ -eq $BASHPID ]]; then
    trap cleanup EXIT INT TERM HUP QUIT
    
    # Enhanced signal handlers for v1.3.0/v1.3.2
    # FIX v1.3.2: Only set custom handlers when NOT running under systemd
    if [[ -z "${INVOCATION_ID:-}" ]]; then
        # Not running under systemd - safe to use custom handlers
        trap 'log INFO "Received SIGHUP, reloading configuration"; restart_mediamtx' HUP
        # Redirect output for USR1 since we might be daemonized
        trap 'log INFO "Received SIGUSR1, dumping status"; show_status >/dev/null 2>&1 || log INFO "Status dump completed"' USR1
    fi
    # Note: When running under systemd (INVOCATION_ID is set), default signal handlers are used
fi

# v1.4.2 FIX: Enhanced deferred cleanup handler with staleness check
handle_deferred_cleanup() {
    if [[ -f "${CLEANUP_MARKER}" ]]; then
        log INFO "Handling deferred cleanup from previous termination"
        
        # Check if marker is stale (>300 seconds old)
        local marker_age
        marker_age="$(( $(date +%s) - $(stat -c %Y "${CLEANUP_MARKER}" 2>/dev/null || echo 0) ))"
        
        if [[ $marker_age -gt 300 ]]; then
            log WARN "Cleanup marker is ${marker_age}s old, might be stale"
        fi
        
        cleanup_stale_processes
        
        # v1.4.2: Verify cleanup completeness
        verify_cleanup_complete
        
        rm -f "${CLEANUP_MARKER}"
    fi
}

# v1.4.2 NEW: Verify cleanup completeness
verify_cleanup_complete() {
    local issues_found=0
    
    # Check for orphaned wrapper scripts
    local wrapper_count
    wrapper_count=$(pgrep -f "${FFMPEG_PID_DIR}/.*\.sh" 2>/dev/null | wc -l || echo 0)
    if [[ $wrapper_count -gt 0 ]]; then
        log WARN "Found $wrapper_count orphaned wrapper processes"
        ((issues_found++))
    fi
    
    # Check for orphaned FFmpeg processes
    local ffmpeg_count
    ffmpeg_count=$(pgrep -f "^ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" 2>/dev/null | wc -l || echo 0)
    if [[ $ffmpeg_count -gt 0 ]]; then
        log WARN "Found $ffmpeg_count orphaned FFmpeg processes"
        ((issues_found++))
    fi
    
    # Check for stale PID files
    local stale_pids=0
    shopt -s nullglob
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        if [[ -f "$pid_file" ]]; then
            local pid
            pid="$(cat "$pid_file" 2>/dev/null || true)"
            if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
                ((stale_pids++))
                rm -f "$pid_file"
            fi
        fi
    done
    shopt -u nullglob
    
    if [[ $stale_pids -gt 0 ]]; then
        log WARN "Cleaned $stale_pids stale PID files"
        ((issues_found++))
    fi
    
    if [[ $issues_found -eq 0 ]]; then
        log DEBUG "Cleanup verification passed - no issues found"
        return 0
    else
        log WARN "Cleanup verification found $issues_found issues"
        return 1
    fi
}

# v1.4.2 NEW: Release config lock safely
release_config_lock_unsafe() {
    if [[ "${CONFIG_LOCK_FD}" -gt 2 ]]; then
        exec {CONFIG_LOCK_FD}>&- 2>/dev/null || true
    fi
    CONFIG_LOCK_FD=-1
}

# Enhanced logging without in-script rotation
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    # Create log directory if it doesn't exist
    local log_dir
    log_dir="$(dirname "${LOG_FILE}")"
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" 2>/dev/null || true
    fi
    
    # Handle writing atomically without rotation
    (
        local lock_fd=-1
        local lock_file="${LOG_FILE}.lock"
        
        # Try to acquire lock with proper FD management
        {
            exec {lock_fd}>"${lock_file}" 2>/dev/null
        } || {
            # Can't create lock, output to stderr only
            case "${level}" in
                ERROR) echo -e "${RED}[ERROR]${NC} ${message}" >&2 ;;
                WARN) echo -e "${YELLOW}[WARN]${NC} ${message}" >&2 ;;
                INFO) echo -e "${GREEN}[INFO]${NC} ${message}" >&2 ;;
                DEBUG) [[ "${DEBUG:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} ${message}" >&2 ;;
            esac
            return
        }
        
        # Validate FD
        if [[ ${lock_fd} -le 2 ]]; then
            case "${level}" in
                ERROR) echo -e "${RED}[ERROR]${NC} ${message}" >&2 ;;
                WARN) echo -e "${YELLOW}[WARN]${NC} ${message}" >&2 ;;
                INFO) echo -e "${GREEN}[INFO]${NC} ${message}" >&2 ;;
                DEBUG) [[ "${DEBUG:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} ${message}" >&2 ;;
            esac
            exec {lock_fd}>&- 2>/dev/null || true
            return
        fi
        
        if ! flock -x -w 5 ${lock_fd}; then
            # Can't get lock, just write to stderr
            case "${level}" in
                ERROR) echo -e "${RED}[ERROR]${NC} ${message}" >&2 ;;
                WARN) echo -e "${YELLOW}[WARN]${NC} ${message}" >&2 ;;
                INFO) echo -e "${GREEN}[INFO]${NC} ${message}" >&2 ;;
                DEBUG) [[ "${DEBUG:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} ${message}" >&2 ;;
            esac
            exec {lock_fd}>&- 2>/dev/null || true
            return
        fi
        
        # Simply append (creates file if needed)
        echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}" 2>/dev/null || true
        
        # Ensure FD is closed
        exec {lock_fd}>&- 2>/dev/null || true
    )
    
    # Also output to stderr with colors
    case "${level}" in
        ERROR)
            echo -e "${RED}[ERROR]${NC} ${message}" >&2
            ;;
        WARN)
            echo -e "${YELLOW}[WARN]${NC} ${message}" >&2
            ;;
        INFO)
            echo -e "${GREEN}[INFO]${NC} ${message}" >&2
            ;;
        DEBUG)
            if [[ "${DEBUG:-false}" == "true" ]]; then
                echo -e "${BLUE}[DEBUG]${NC} ${message}" >&2
            fi
            ;;
    esac
}

# Error handling with proper exit codes
error_exit() {
    local message="$1"
    local exit_code="${2:-${E_GENERAL}}"
    log ERROR "$message"
    exit "${exit_code}"
}

# v1.4.2 FIX: PID file operations with permissions set before atomic move
write_pid_atomic() {
    local pid="$1"
    local pid_file="$2"
    local pid_dir
    pid_dir="$(dirname "$pid_file")"
    
    # Validate PID format
    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        log ERROR "Invalid PID format: $pid"
        return 1
    fi
    
    # Remove leading zeros to prevent octal interpretation
    pid="$((10#$pid))"
    
    # Validate PID range
    if [[ $pid -lt 1 ]] || [[ $pid -gt $SYSTEM_PID_MAX ]]; then
        log ERROR "PID out of range: $pid (max: $SYSTEM_PID_MAX)"
        return 1
    fi
    
    # Verify process exists before writing
    if ! kill -0 "$pid" 2>/dev/null; then
        log ERROR "Process $pid does not exist"
        return 1
    fi
    
    # Ensure directory exists
    if [[ ! -d "$pid_dir" ]]; then
        mkdir -p "$pid_dir" 2>/dev/null || {
            log ERROR "Failed to create PID directory: $pid_dir"
            return 1
        }
    fi
    
    # Create temp file for atomic write
    local temp_pid
    temp_pid="$(mktemp -p "$pid_dir" "$(basename "$pid_file").XXXXXX" 2>/dev/null)" || {
        log ERROR "Failed to create temp PID file in $pid_dir"
        return 1
    }
    
    # Write PID with verification
    echo "${pid}" > "$temp_pid" || {
        rm -f "$temp_pid"
        log ERROR "Failed to write PID to temp file"
        return 1
    }
    
    # CRITICAL FIX: Set permissions BEFORE atomic move
    chmod 644 "$temp_pid" 2>/dev/null || {
        rm -f "$temp_pid"
        log ERROR "Failed to set permissions on temp PID file"
        return 1
    }
    
    # Verify written content
    local written_pid
    written_pid="$(cat "$temp_pid" 2>/dev/null)" || {
        rm -f "$temp_pid"
        log ERROR "Failed to verify written PID"
        return 1
    }
    
    if [[ "$written_pid" != "$pid" ]]; then
        rm -f "$temp_pid"
        log ERROR "PID verification failed: wrote $pid, read $written_pid"
        return 1
    fi
    
    # Double-check process still exists before final move
    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$temp_pid"
        log ERROR "Process $pid died during PID file creation"
        return 1
    fi
    
    # Atomically move into place (permissions already set)
    if ! mv -f "$temp_pid" "$pid_file"; then
        rm -f "$temp_pid"
        log ERROR "Failed to atomically move PID file"
        return 1
    fi
    
    log DEBUG "Wrote PID $pid to $pid_file"
    return 0
}

read_pid_safe() {
    local pid_file="$1"
    
    if [[ ! -f "$pid_file" ]]; then
        echo ""
        return 0
    fi
    
    local pid
    pid="$(cat "$pid_file" 2>/dev/null || echo "")"
    
    if [[ -z "$pid" ]]; then
        echo ""
        return 0
    fi
    
    # Remove any whitespace
    pid="$(echo -n "$pid" | tr -d '[:space:]')"
    
    # Validate PID format
    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        log ERROR "PID file $pid_file contains invalid data: '$pid'"
        rm -f "$pid_file"
        echo ""
        return 0
    fi
    
    # Remove leading zeros to prevent octal interpretation
    pid="$((10#$pid))"
    
    # Validate PID range
    if [[ $pid -lt 1 ]] || [[ $pid -gt $SYSTEM_PID_MAX ]]; then
        log ERROR "PID file $pid_file contains out-of-range PID: $pid"
        rm -f "$pid_file"
        echo ""
        return 0
    fi
    
    # Check if process exists
    if ! kill -0 "$pid" 2>/dev/null; then
        log DEBUG "PID $pid from $pid_file is not running"
        rm -f "$pid_file"
        echo ""
        return 0
    fi
    
    echo "$pid"
}

# Process termination with SIGINT for RTSP cleanup
wait_for_pid_termination() {
    local pid="$1"
    local timeout="${2:-${PID_TERMINATION_TIMEOUT}}"
    
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    
    log DEBUG "Waiting for PID $pid to terminate (timeout: ${timeout}s)"
    
    local elapsed=0
    while kill -0 "$pid" 2>/dev/null && [[ $elapsed -lt $timeout ]]; do
        sleep "$SHORT_SLEEP"
        ((elapsed++))
    done
    
    if kill -0 "$pid" 2>/dev/null; then
        log WARN "PID $pid did not terminate within ${timeout}s"
        return 1
    fi
    
    log DEBUG "PID $pid terminated successfully"
    return 0
}

# Process group termination with proper handling
terminate_process_group() {
    local pid="$1"
    local timeout="${2:-10}"
    
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    
    # Try process group first if it exists
    if kill -INT -- -"$pid" 2>/dev/null; then
        log DEBUG "Sent SIGINT to process group $pid"
    else
        # Fall back to individual process
        log DEBUG "Process group not available, sending SIGINT to PID $pid"
        kill -INT "$pid" 2>/dev/null || true
    fi
    
    # Also kill children explicitly if pkill is available
    if command_exists pkill; then
        pkill -INT -P "$pid" 2>/dev/null || true
    fi
    
    if ! wait_for_pid_termination "$pid" "$timeout"; then
        # Force kill if needed
        if kill -KILL -- -"$pid" 2>/dev/null; then
            log DEBUG "Sent SIGKILL to process group $pid"
        else
            kill -KILL "$pid" 2>/dev/null || true
        fi
        
        if command_exists pkill; then
            pkill -KILL -P "$pid" 2>/dev/null || true
        fi
        wait_for_pid_termination "$pid" 2
    fi
}

# Lock management with stale lock detection
is_lock_stale() {
    if [[ ! -f "${LOCK_FILE}" ]]; then
        return 1  # No lock file, not stale
    fi
    
    # Check if lock file has a PID
    local lock_pid
    lock_pid="$(head -n1 "${LOCK_FILE}" 2>/dev/null | tr -d '[:space:]')"
    
    if [[ -z "$lock_pid" ]] || ! [[ "$lock_pid" =~ ^[0-9]+$ ]]; then
        log WARN "Lock file exists but contains no valid PID"
        return 0  # Stale
    fi
    
    # Check if the process is still running
    if ! kill -0 "$lock_pid" 2>/dev/null; then
        log WARN "Lock file PID $lock_pid is not running"
        return 0  # Stale
    fi
    
    # Check if the process is actually our script
    local proc_cmd
    proc_cmd="$(ps -p "$lock_pid" -o comm= 2>/dev/null || true)"
    if [[ "$proc_cmd" != "bash" ]] && [[ "$proc_cmd" != "${SCRIPT_NAME}" ]]; then
        log WARN "Lock file PID $lock_pid is not our script (found: $proc_cmd)"
        return 0  # Stale
    fi
    
    # Check lock file age
    local lock_age
    lock_age="$(( $(date +%s) - $(stat -c %Y "${LOCK_FILE}" 2>/dev/null || echo 0) ))"
    if [[ $lock_age -gt ${LOCK_STALE_THRESHOLD} ]]; then
        log WARN "Lock file is ${lock_age} seconds old (threshold: ${LOCK_STALE_THRESHOLD})"
        # Additional check: is it really stuck or just long-running?
        if [[ "${CURRENT_COMMAND}" == "start" ]] || [[ "${CURRENT_COMMAND}" == "restart" ]]; then
            return 0  # Consider stale for start/restart
        fi
    fi
    
    return 1  # Not stale
}

acquire_lock() {
    local timeout="${1:-${LOCK_ACQUISITION_TIMEOUT}}"
    local force="${2:-false}"
    
    # CRITICAL FIX: Always close existing FD before reuse
    if [[ ${MAIN_LOCK_FD} -gt 2 ]]; then
        exec {MAIN_LOCK_FD}>&- 2>/dev/null || true
    fi
    MAIN_LOCK_FD=-1
    
    # Create lock directory if it doesn't exist
    local lock_dir
    lock_dir="$(dirname "${LOCK_FILE}")"
    if [[ ! -d "$lock_dir" ]]; then
        mkdir -p "$lock_dir" 2>/dev/null || {
            log ERROR "Cannot create lock directory: $lock_dir"
            return 1
        }
    fi
    
    # Check for stale lock
    if is_lock_stale; then
        log INFO "Removing stale lock file"
        rm -f "${LOCK_FILE}"
    fi
    
    # Open lock file and get file descriptor
    {
        exec {MAIN_LOCK_FD}>"${LOCK_FILE}" 2>/dev/null
    } || {
        log ERROR "Cannot create lock file ${LOCK_FILE}"
        MAIN_LOCK_FD=-1
        return 1
    }
    
    # Validate FD is valid (> 2)
    if [[ ${MAIN_LOCK_FD} -le 2 ]]; then
        log ERROR "Invalid lock file descriptor: ${MAIN_LOCK_FD}"
        MAIN_LOCK_FD=-1
        return 1
    fi
    
    # Try to acquire lock
    if ! flock -w "$timeout" "${MAIN_LOCK_FD}"; then
        # v1.3.3 FIX: Enhanced error handling for FD closure failure
        if ! exec {MAIN_LOCK_FD}>&- 2>/dev/null; then
            log WARN "Failed to close lock FD properly during acquisition failure"
        fi
        MAIN_LOCK_FD=-1
        
        if [[ "$force" == "true" ]]; then
            log WARN "Failed to acquire lock, forcing due to force flag"
            return 0  # Continue anyway
        else
            log ERROR "Failed to acquire lock after ${timeout} seconds"
            return 1
        fi
    fi
    
    # Write our PID to the lock file
    echo "$$" >&"${MAIN_LOCK_FD}" || true
    
    log DEBUG "Acquired lock (PID: $$, FD: ${MAIN_LOCK_FD})"
    return 0
}

release_lock() {
    if [[ "${MAIN_LOCK_FD}" -gt 2 ]]; then
        log DEBUG "Releasing lock (FD: ${MAIN_LOCK_FD})"
        exec {MAIN_LOCK_FD}>&- 2>/dev/null || true
    fi
    MAIN_LOCK_FD=-1
    # Don't remove lock file - let next process reuse it
}

# Unsafe lock release for cleanup trap
release_lock_unsafe() {
    if [[ "${MAIN_LOCK_FD}" -gt 2 ]]; then
        exec {MAIN_LOCK_FD}>&- 2>/dev/null || true
    fi
    MAIN_LOCK_FD=-1
}

# Check if running as root
check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        error_exit "This script must be run as root (use sudo)" "${E_GENERAL}"
    fi
}

# Check dependencies
check_dependencies() {
    local missing=()
    
    for cmd in ffmpeg jq arecord; do
        if ! command_exists "$cmd"; then
            missing+=("$cmd")
        fi
    done
    
    # Check for setsid (optional but recommended)
    if ! command_exists setsid; then
        log WARN "setsid not found - processes will run without session isolation"
    fi
    
    if [[ ! -x "${MEDIAMTX_BIN}" ]]; then
        missing+=("mediamtx (run install_mediamtx.sh first)")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error_exit "Missing dependencies: ${missing[*]}" "${E_MISSING_DEPS}"
    fi
}

# Create required directories
setup_directories() {
    mkdir -p "${CONFIG_DIR}"
    mkdir -p "$(dirname "${LOG_FILE}")"
    mkdir -p "$(dirname "${PID_FILE}")"
    mkdir -p "${FFMPEG_PID_DIR}"
    
    chmod 755 "${FFMPEG_PID_DIR}"
    
    if [[ ! -f "${LOG_FILE}" ]]; then
        touch "${LOG_FILE}"
        chmod 644 "${LOG_FILE}"
    fi
    
    # Setup MediaMTX log rotation if logrotate is available
    if command_exists logrotate && [[ -d /etc/logrotate.d ]]; then
        setup_mediamtx_logrotate
    fi
}

# Setup MediaMTX log rotation
setup_mediamtx_logrotate() {
    # Skip if running under systemd with protected filesystem
    if [[ -n "${INVOCATION_ID:-}" ]] || [[ ! -w /etc/logrotate.d ]]; then
        log DEBUG "Skipping logrotate setup (read-only filesystem or systemd environment)"
        return 0
    fi
    
    cat > /etc/logrotate.d/mediamtx << EOF
${MEDIAMTX_LOG_FILE} {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
    size ${MEDIAMTX_LOG_MAX_SIZE}
    postrotate
        # Send USR1 signal to MediaMTX if running
        if [ -f "${PID_FILE}" ]; then
            kill -USR1 \$(cat ${PID_FILE}) 2>/dev/null || true
        fi
    endscript
}

${LOG_FILE} {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
    size ${MAIN_LOG_MAX_SIZE}
}

${FFMPEG_PID_DIR}/*.log {
    daily
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    size ${FFMPEG_LOG_MAX_SIZE}
}
EOF
    
    chmod 644 /etc/logrotate.d/mediamtx
    log DEBUG "MediaMTX log rotation configured"
}

# Resource monitoring
check_resource_usage() {
    local mediamtx_pid
    mediamtx_pid="$(read_pid_safe "${PID_FILE}")"
    
    if [[ -z "$mediamtx_pid" ]]; then
        log DEBUG "MediaMTX not running, skipping resource check"
        return 0
    fi
    
    # Check file descriptors
    local fd_count=0
    if [[ -d "/proc/$mediamtx_pid/fd" ]]; then
        fd_count=$(find "/proc/$mediamtx_pid/fd" -maxdepth 1 -type l 2>/dev/null | wc -l)
    fi
    
    # Check CPU usage
    local cpu_percent="0"
    if command_exists ps; then
        cpu_percent=$(ps -o %cpu= -p "$mediamtx_pid" 2>/dev/null | tr -d ' ' || echo "0")
    fi
    
    # Extract integer part of CPU percentage
    local cpu_int="${cpu_percent%.*}"
    cpu_int="${cpu_int:-0}"
    
    # Check thread count
    local thread_count=0
    if command_exists ps; then
        thread_count=$(ps -o nlwp= -p "$mediamtx_pid" 2>/dev/null | tr -d ' ' || echo "0")
    fi
    
    # Log current resource usage
    log DEBUG "Resource usage - PID: $mediamtx_pid, FDs: $fd_count, CPU: ${cpu_percent}%, Threads: $thread_count"
    
    # Check thresholds
    local needs_restart=false
    local reason=""
    
    if [[ $fd_count -gt ${MAX_FD_CRITICAL} ]]; then
        log ERROR "Critical: File descriptors exceeded limit ($fd_count > ${MAX_FD_CRITICAL})"
        needs_restart=true
        reason="FD_LIMIT"
    elif [[ $fd_count -gt ${MAX_FD_WARNING} ]]; then
        log WARN "Warning: High file descriptor count ($fd_count > ${MAX_FD_WARNING})"
    fi
    
    if [[ $cpu_int -gt ${MAX_CPU_CRITICAL} ]]; then
        log ERROR "Critical: CPU usage exceeded limit (${cpu_percent}% > ${MAX_CPU_CRITICAL}%)"
        needs_restart=true
        reason="${reason:+$reason,}CPU_LIMIT"
    elif [[ $cpu_int -gt ${MAX_CPU_WARNING} ]]; then
        log WARN "Warning: High CPU usage (${cpu_percent}% > ${MAX_CPU_WARNING}%)"
    fi
    
    # Check wrapper processes
    local wrapper_count
    wrapper_count=$(pgrep -f "${FFMPEG_PID_DIR}/.*\.sh" 2>/dev/null | wc -l || echo 0)
    local expected_wrappers
    expected_wrappers=$(find "${FFMPEG_PID_DIR}" -maxdepth 1 -name "*.pid" -type f 2>/dev/null | wc -l)
    
    # Check for excessive wrapper processes
    if [[ $wrapper_count -gt $expected_wrappers ]]; then
        log ERROR "Critical: Extra wrapper processes ($wrapper_count vs expected $expected_wrappers)"
        needs_restart=true
        reason="${reason:+$reason,}WRAPPER_LEAK"
    fi
    
    # Return exit code 2 if restart needed
    if [[ "$needs_restart" == "true" ]]; then
        log ERROR "CRITICAL: Resource limits exceeded: $reason"
        return ${E_CRITICAL_RESOURCE}
    fi
    
    return 0
}

# Enhanced stream validation
validate_stream() {
    local stream_path="$1"
    local max_attempts="${2:-${STREAM_VALIDATION_ATTEMPTS}}"
    local attempt=0
    
    log DEBUG "Validating stream $stream_path"
    
    while [[ $attempt -lt $max_attempts ]]; do
        ((attempt++)) || true
        
        sleep "${STREAM_VALIDATION_DELAY}"
        
        # Try API validation if curl available
        if command_exists curl; then
            local api_url="http://${MEDIAMTX_HOST}:9997/v3/paths/get/${stream_path}"
            if curl -s --max-time 2 "${api_url}" 2>/dev/null | grep -q '"ready":true'; then
                log DEBUG "Stream $stream_path validated via API (attempt ${attempt})"
                return 0
            fi
        fi
        
        # Fallback to process check
        local pid_file="${FFMPEG_PID_DIR}/${stream_path}.pid"
        if [[ -f "$pid_file" ]]; then
            local pid
            pid="$(read_pid_safe "$pid_file")"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                # Check if FFmpeg child exists
                if pgrep -P "$pid" -f "ffmpeg" >/dev/null 2>&1; then
                    log DEBUG "Stream $stream_path validated via process (attempt ${attempt})"
                    return 0
                fi
            fi
        fi
    done
    
    log WARN "Stream $stream_path failed validation after ${max_attempts} attempts"
    return 1
}

# Detect restart scenario
is_restart_scenario() {
    if [[ -f "${RESTART_MARKER}" ]]; then
        local marker_age
        marker_age="$(( $(date +%s) - $(stat -c %Y "${RESTART_MARKER}" 2>/dev/null || echo 0) ))"
        if [[ $marker_age -lt 60 ]]; then
            return 0
        fi
    fi
    
    if pgrep -x "$(basename "${MEDIAMTX_BIN}")" >/dev/null 2>&1; then
        return 0
    fi
    
    if pgrep -f "^ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

mark_restart() {
    touch "${RESTART_MARKER}"
}

clear_restart_marker() {
    rm -f "${RESTART_MARKER}"
}

cleanup_stale_processes() {
    log INFO "Cleaning up stale processes and files"
    
    # Save and set nullglob
    local nullglob_state
    shopt -q nullglob && nullglob_state=on || nullglob_state=off
    shopt -s nullglob
    
    # Clean up wrapper scripts
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        if [[ -f "$pid_file" ]]; then
            local pid
            pid="$(read_pid_safe "$pid_file")"
            if [[ -n "$pid" ]]; then
                terminate_process_group "$pid" 5
            fi
            rm -f "$pid_file"
        fi
    done
    
    # Kill orphaned FFmpeg processes
    while IFS= read -r pid; do
        if [[ -n "$pid" ]]; then
            log DEBUG "Killing orphaned FFmpeg PID $pid"
            terminate_process_group "$pid" 2
        fi
    done < <(pgrep -f "^ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" 2>/dev/null || true)
    
    # Clean up MediaMTX
    if [[ -f "${PID_FILE}" ]]; then
        local mediamtx_pid
        mediamtx_pid="$(read_pid_safe "${PID_FILE}")"
        if [[ -n "$mediamtx_pid" ]]; then
            log DEBUG "Terminating MediaMTX PID $mediamtx_pid"
            terminate_process_group "$mediamtx_pid" 5
        fi
        rm -f "${PID_FILE}"
    fi
    
    # Kill any MediaMTX processes using our config
    if [[ -f "${CONFIG_FILE}" ]]; then
        local mediamtx_pids
        mediamtx_pids="$(pgrep -f "^${MEDIAMTX_BIN}.*${CONFIG_FILE}$" 2>/dev/null || true)"
        if [[ -n "$mediamtx_pids" ]]; then
            echo "$mediamtx_pids" | while read -r pid; do
                if [[ -n "$pid" ]]; then
                    terminate_process_group "$pid" 2
                fi
            done
        fi
    fi
    
    # Clean temporary files
    rm -f "${FFMPEG_PID_DIR}"/*.pid
    rm -f "${FFMPEG_PID_DIR}"/*.sh
    rm -f "${FFMPEG_PID_DIR}"/*.log
    rm -f "${FFMPEG_PID_DIR}"/*.log.old
    
    # Clean up markers
    rm -f "${CLEANUP_MARKER}"
    rm -f "${RESTART_MARKER}"
    rm -f "${CONFIG_LOCK_FILE}"
    
    # v1.3.3 FIX: Restore nullglob state correctly for both on/off
    if [[ "$nullglob_state" == "on" ]]; then
        shopt -s nullglob
    else
        shopt -u nullglob
    fi
    
    log INFO "Cleanup completed"
}

# Wait for USB stabilization
wait_for_usb_stabilization() {
    local max_wait="${1:-${USB_STABILIZATION_DELAY}}"
    local stable_count_needed=2
    local stable_count=0
    local last_device_hash=""
    local elapsed=0
    
    log INFO "Waiting for USB audio subsystem to stabilize (max ${max_wait}s)..."
    
    while [[ $elapsed -lt $max_wait ]]; do
        local current_device_hash
        current_device_hash="$(detect_audio_devices | sort | compute_hash)"
        
        if [[ "$current_device_hash" == "$last_device_hash" ]] && [[ -n "$current_device_hash" ]]; then
            ((stable_count++)) || true
            if [[ $stable_count -ge $stable_count_needed ]]; then
                local device_count
                device_count="$(detect_audio_devices | wc -l)"
                log INFO "USB audio subsystem stable with $device_count devices"
                return 0
            fi
        else
            stable_count=0
            last_device_hash="$current_device_hash"
        fi
        
        sleep "$MEDIUM_SLEEP"
        ((elapsed+=2))
    done
    
    local device_count
    device_count="$(detect_audio_devices | wc -l)"
    if [[ $device_count -gt 0 ]]; then
        log WARN "USB stabilization timeout, proceeding with $device_count devices"
        return 0
    else
        log ERROR "No USB audio devices detected after ${max_wait} seconds"
        return 1
    fi
}

# Wait for MediaMTX API
wait_for_mediamtx_ready() {
    local pid="$1"
    local max_wait="${MEDIAMTX_API_TIMEOUT}"
    local elapsed=0
    
    log INFO "Waiting for MediaMTX to become ready..."
    
    while [[ $elapsed -lt $max_wait ]]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            log ERROR "MediaMTX process died during startup"
            return 1
        fi
        
        if command_exists curl; then
            if curl -s --max-time 2 "http://${MEDIAMTX_HOST}:9997/v3/paths/list" >/dev/null 2>&1; then
                log INFO "MediaMTX API is ready after ${elapsed} seconds"
                return 0
            fi
        else
            # Fallback: just check if process is running
            if [[ $elapsed -ge 10 ]]; then
                log INFO "MediaMTX assumed ready (curl not available)"
                return 0
            fi
        fi
        
        sleep 1
        ((elapsed++))
        
        if [[ $((elapsed % 5)) -eq 0 ]]; then
            log DEBUG "Still waiting for MediaMTX API... (${elapsed}s/${max_wait}s)"
        fi
    done
    
    log ERROR "MediaMTX API did not become ready within ${max_wait} seconds"
    return 1
}

# Device configuration
load_device_config() {
    if [[ -f "${DEVICE_CONFIG_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${DEVICE_CONFIG_FILE}"
    fi
}

save_device_config() {
    local tmp_config
    tmp_config="$(mktemp -p "$(dirname "${DEVICE_CONFIG_FILE}")" "$(basename "${DEVICE_CONFIG_FILE}").XXXXXX")"
    
    cat > "$tmp_config" << 'EOF'
# Audio device configuration
# Format: DEVICE_<sanitized_name>_<parameter>=value

# Universal defaults:
# - Sample Rate: 48000 Hz
# - Channels: 2 (stereo)
# - Format: s16le (16-bit little-endian)
# - Codec: opus
# - Bitrate: 128k

# Example overrides:
# DEVICE_USB_BLUE_YETI_SAMPLE_RATE=44100
# DEVICE_USB_BLUE_YETI_CHANNELS=1
EOF
    
    mv -f "$tmp_config" "${DEVICE_CONFIG_FILE}"
    chmod 644 "${DEVICE_CONFIG_FILE}"
}

sanitize_device_name() {
    local name="$1"
    local sanitized
    sanitized=$(printf '%s' "$name" | sed 's/[^a-zA-Z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//')
    
    if [[ "$sanitized" =~ ^[0-9] ]]; then
        sanitized="dev_${sanitized}"
    fi
    
    if [[ -z "$sanitized" ]]; then
        sanitized="unknown_device_$(date +%s)"
    fi
    
    printf '%s\n' "$sanitized"
}

sanitize_path_name() {
    local name="$1"
    name="${name#usb-audio-}"
    name="${name#usb_audio_}"
    local sanitized
    sanitized="$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^0-9a-z]/_/g' | sed 's/__*/_/g' | sed 's/^_*//;s/_*$//')"
    
    if [[ -z "$sanitized" ]]; then
        sanitized="stream_$(date +%s)"
    fi
    
    echo "$sanitized"
}

get_device_config() {
    local device_name="$1"
    local param="$2"
    local default_value="$3"
    
    local safe_name
    safe_name="$(sanitize_device_name "$device_name")"
    
    local config_key="DEVICE_${safe_name^^}_${param^^}"
    
    if [[ -n "${!config_key+x}" ]]; then
        echo "${!config_key}"
    else
        echo "$default_value"
    fi
}

# Detect USB audio devices
detect_audio_devices() {
    local devices=()
    local retry_count=0
    local max_retries=3
    
    while [[ $retry_count -lt $max_retries ]]; do
        devices=()
        
        if [[ -d /dev/snd/by-id ]]; then
            for device in /dev/snd/by-id/*; do
                if [[ -L "$device" ]] && [[ "$device" != *"-event-"* ]]; then
                    local device_name
                    device_name="$(basename "$device")"
                    
                    local target
                    target="$(readlink -f "$device")"
                    if [[ "$target" =~ controlC([0-9]+) ]]; then
                        local card_num="${BASH_REMATCH[1]}"
                        
                        if [[ -f "/proc/asound/card${card_num}/usbid" ]]; then
                            devices+=("${device_name}:${card_num}")
                        fi
                    fi
                fi
            done
        fi
        
        # If we found devices or this is our last retry, break
        if [[ ${#devices[@]} -gt 0 ]] || [[ $retry_count -eq $((max_retries - 1)) ]]; then
            break
        fi
        
        # Wait a bit before retry
        sleep 0.5
        ((retry_count++))
    done
    
    # Fallback to /proc/asound/cards if no devices found
    if [[ ${#devices[@]} -eq 0 ]] && [[ -f /proc/asound/cards ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+\[([^]]+)\] ]]; then
                local card_num="${BASH_REMATCH[1]}"
                local card_name="${BASH_REMATCH[2]}"
                if [[ -f "/proc/asound/card${card_num}/usbid" ]]; then
                    local safe_name
                    safe_name="$(echo "$card_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')"
                    if [[ -n "$safe_name" ]]; then
                        devices+=("usb-audio-${safe_name}:${card_num}")
                    fi
                fi
            fi
        done < /proc/asound/cards
    fi
    
    if [[ ${#devices[@]} -gt 0 ]]; then
        printf '%s\n' "${devices[@]}"
    fi
}

# Check audio device availability
check_audio_device() {
    local card_num="$1"
    
    if [[ ! -e "/dev/snd/pcmC${card_num}D0c" ]]; then
        return 1
    fi
    
    # Use a simple existence check instead of opening the device
    if arecord -l 2>/dev/null | grep -q "card ${card_num}:"; then
        return 0
    fi
    
    return 1
}

# Generate stream path
generate_stream_path() {
    local device_name="$1"
    local card_num="${2:-}"
    local base_path=""
    
    if [[ -n "$card_num" ]] && [[ -f "/proc/asound/cards" ]]; then
        local card_info
        card_info=$(grep -E "^ *${card_num} " /proc/asound/cards 2>/dev/null || true)
        
        if [[ -n "$card_info" ]]; then
            if [[ "$card_info" =~ \[([^]]+)\] ]]; then
                local card_name="${BASH_REMATCH[1]}"
                card_name="$(echo "$card_name" | xargs)"
                
                if [[ "$card_name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
                    base_path="$card_name"
                fi
            fi
        fi
    fi
    
    if [[ -z "$base_path" ]]; then
        base_path="$(sanitize_path_name "$device_name")"
    fi
    
    if [[ ! "$base_path" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        base_path="stream_${base_path}"
    fi
    
    if [[ ${#base_path} -gt 64 ]]; then
        base_path="${base_path:0:64}"
    fi
    
    echo "$base_path"
}

# Start FFmpeg multiplex stream (single stream from multiple devices)
start_ffmpeg_multiplex_stream() {
    local -a devices=("$@")
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        log ERROR "No devices provided for multiplex stream"
        return 1
    fi
    
    # v1.3.3 CRITICAL FIX: Sanitize stream name to prevent RTSP URL parsing failures
    local stream_path
    stream_path="$(sanitize_path_name "${MULTIPLEX_STREAM_NAME}")"
    
    # Ensure stream name doesn't start with a digit
    if [[ "$stream_path" =~ ^[0-9] ]]; then
        stream_path="stream_${stream_path}"
    fi
    
    local pid_file="${FFMPEG_PID_DIR}/${stream_path}.pid"
    
    # Check if already running
    if [[ -f "$pid_file" ]]; then
        local existing_pid
        existing_pid="$(read_pid_safe "$pid_file")"
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            # v1.3.4 FIX: Verify PID actually belongs to our wrapper script
            if pgrep -f "${FFMPEG_PID_DIR}/${stream_path}.sh" | grep -q "^${existing_pid}$"; then
                log DEBUG "Multiplex stream $stream_path already running"
                return 0
            else
                log WARN "Stale PID file for $stream_path (PID $existing_pid is not our wrapper)"
                rm -f "$pid_file"
            fi
        fi
    fi
    
    # Validate filter type
    if [[ "${MULTIPLEX_FILTER_TYPE}" != "amix" ]] && [[ "${MULTIPLEX_FILTER_TYPE}" != "amerge" ]]; then
        log ERROR "Invalid MULTIPLEX_FILTER_TYPE: ${MULTIPLEX_FILTER_TYPE}. Must be 'amix' or 'amerge'"
        return 1
    fi
    
    # Build device array and validate all devices
    local -a valid_devices=()
    local -a card_numbers=()
    local -a device_names=()
    
    for device_info in "${devices[@]}"; do
        IFS=':' read -r device_name card_num <<< "$device_info"
        
        if [[ -z "$device_name" ]] || [[ -z "$card_num" ]]; then
            log WARN "Skipping invalid device info: $device_info"
            continue
        fi
        
        if ! check_audio_device "$card_num"; then
            log WARN "Audio device card ${card_num} is not accessible, skipping"
            continue
        fi
        
        valid_devices+=("$device_info")
        card_numbers+=("$card_num")
        device_names+=("$device_name")
    done
    
    if [[ ${#valid_devices[@]} -eq 0 ]]; then
        log ERROR "No valid audio devices available for multiplex stream"
        return 1
    fi
    
    log INFO "Starting multiplex FFmpeg stream with ${#valid_devices[@]} devices (filter: ${MULTIPLEX_FILTER_TYPE})"
    
    # Get audio configuration from first device (all devices should match)
    local first_device="${device_names[0]}"
    local sample_rate channels codec bitrate thread_queue
    sample_rate="$(get_device_config "$first_device" "SAMPLE_RATE" "$DEFAULT_SAMPLE_RATE")"
    channels="$(get_device_config "$first_device" "CHANNELS" "$DEFAULT_CHANNELS")"
    codec="$(get_device_config "$first_device" "CODEC" "$DEFAULT_CODEC")"
    bitrate="$(get_device_config "$first_device" "BITRATE" "$DEFAULT_BITRATE")"
    thread_queue="$(get_device_config "$first_device" "THREAD_QUEUE" "$DEFAULT_THREAD_QUEUE")"
    
    # Create wrapper script
    local wrapper_script="${FFMPEG_PID_DIR}/${stream_path}.sh"
    local ffmpeg_log="${FFMPEG_PID_DIR}/${stream_path}.log"
    
    # Create wrapper with all variables properly quoted
    cat > "$wrapper_script" << 'WRAPPER_START'
#!/bin/bash
set -euo pipefail

# Ensure PATH includes common binary locations
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

WRAPPER_START

    # Write configuration variables
    cat >> "$wrapper_script" << EOF
# Stream Configuration
STREAM_PATH="$stream_path"
SAMPLE_RATE="$sample_rate"
CHANNELS="$channels"
BITRATE="$bitrate"
THREAD_QUEUE="$thread_queue"
ANALYZEDURATION="$DEFAULT_ANALYZEDURATION"
PROBESIZE="$DEFAULT_PROBESIZE"
CODEC="$codec"
FILTER_TYPE="${MULTIPLEX_FILTER_TYPE}"

# File paths
FFMPEG_LOG="$ffmpeg_log"
LOG_FILE="$LOG_FILE"
WRAPPER_PID_FILE="$pid_file"
CLEANUP_MARKER="$CLEANUP_MARKER"
MEDIAMTX_HOST="$MEDIAMTX_HOST"

# Restart configuration
RESTART_COUNT=0
CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=5
MAX_WRAPPER_RESTARTS=$MAX_WRAPPER_RESTARTS
WRAPPER_SUCCESS_DURATION=$WRAPPER_SUCCESS_DURATION
RESTART_DELAY=10
FFMPEG_LOG_MAX_SIZE=$FFMPEG_LOG_MAX_SIZE

# Device arrays (initialized empty, populated below)
declare -a CARD_NUMBERS=()
declare -a DEVICE_NAMES=()

FFMPEG_PID=""
PARENT_PID=\$PPID
EOF
    
    # FIX v1.3.2: Populate arrays with proper quoting to handle spaces in device names
    for i in "${!card_numbers[@]}"; do
        cat >> "$wrapper_script" << EOF
CARD_NUMBERS+=("${card_numbers[$i]}")
DEVICE_NAMES+=("${device_names[$i]}")
EOF
    done
    
    # Add device count after arrays are populated
    cat >> "$wrapper_script" << EOF

# Number of devices
NUM_DEVICES=${#valid_devices[@]}
EOF

    # Add the wrapper logic
    cat >> "$wrapper_script" << 'WRAPPER_LOGIC'

# Create log file if it doesn't exist
touch "${FFMPEG_LOG}" 2>/dev/null || true

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [MULTIPLEX-WRAPPER] $1" >> "${FFMPEG_LOG}" 2>/dev/null || true
}

log_critical() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STREAM:${STREAM_PATH}] $1" >> "${LOG_FILE}" 2>/dev/null || true
}

# Cleanup handler
cleanup_wrapper() {
    local exit_code=$?
    log_message "Wrapper cleanup initiated (exit code: $exit_code)"
    
    # Atomic check and kill
    local ffmpeg_pid="${FFMPEG_PID:-}"
    if [[ -n "$ffmpeg_pid" ]]; then
        if kill -0 "$ffmpeg_pid" 2>/dev/null; then
            log_message "Sending SIGINT to FFmpeg process ${ffmpeg_pid}"
            kill -INT "$ffmpeg_pid" 2>/dev/null || true
            
            # Wait briefly for termination
            local term_wait=0
            while kill -0 "$ffmpeg_pid" 2>/dev/null && [[ $term_wait -lt 5 ]]; do
                sleep 0.2
                ((term_wait++))
            done
            
            # Force kill if still running
            if kill -0 "$ffmpeg_pid" 2>/dev/null; then
                kill -KILL "$ffmpeg_pid" 2>/dev/null || true
            fi
        fi
    fi
    
    rm -f "${WRAPPER_PID_FILE}"
    log_critical "Multiplex stream wrapper terminated for ${STREAM_PATH}"
    exit "$exit_code"
}

trap cleanup_wrapper EXIT INT TERM

# Run FFmpeg with multiplex configuration
run_ffmpeg() {
    log_message "Starting FFmpeg with ${NUM_DEVICES} devices (filter: ${FILTER_TYPE})"
    
    # Build command array to handle spaces properly
    local ffmpeg_cmd=(
        ffmpeg
        -hide_banner
        -loglevel warning
    )
    
    # Add input for each device
    for i in "${!CARD_NUMBERS[@]}"; do
        local card_num="${CARD_NUMBERS[$i]}"
        local audio_device="plughw:${card_num},0"
        
        log_message "Adding input $((i+1))/${NUM_DEVICES}: ${DEVICE_NAMES[$i]} (card ${card_num})"
        
        ffmpeg_cmd+=(
            -analyzeduration "${ANALYZEDURATION}"
            -probesize "${PROBESIZE}"
            -f alsa
            -ar "${SAMPLE_RATE}"
            -ac "${CHANNELS}"
            -thread_queue_size "${THREAD_QUEUE}"
            -i "${audio_device}"
        )
    done
    
    # Build filter complex based on filter type
    if [[ "${FILTER_TYPE}" == "amix" ]]; then
        # Mix all audio inputs into a single output
        # Create input labels [0:a][1:a][2:a]... and use amix filter
        local filter_inputs=""
        for i in "${!CARD_NUMBERS[@]}"; do
            filter_inputs+="[${i}:a]"
        done
        
        local filter_complex="${filter_inputs}amix=inputs=${NUM_DEVICES}:duration=longest:normalize=0,aresample=async=1:first_pts=0"
        ffmpeg_cmd+=(-filter_complex "$filter_complex")
        
        log_message "Using amix filter to mix ${NUM_DEVICES} audio streams"
        
    elif [[ "${FILTER_TYPE}" == "amerge" ]]; then
        # Merge all audio inputs keeping channels separate
        # This creates a single stream with (NUM_DEVICES * CHANNELS) channels
        local filter_inputs=""
        for i in "${!CARD_NUMBERS[@]}"; do
            filter_inputs+="[${i}:a]"
        done
        
        local filter_complex="${filter_inputs}amerge=inputs=${NUM_DEVICES},aresample=async=1:first_pts=0"
        ffmpeg_cmd+=(-filter_complex "$filter_complex")
        
        log_message "Using amerge filter to merge ${NUM_DEVICES} audio streams"
    else
        log_message "ERROR: Invalid filter type: ${FILTER_TYPE}"
        return 1
    fi
    
    # Add codec options based on codec type
    case "${CODEC}" in
        opus)
            ffmpeg_cmd+=(-c:a libopus -b:a "${BITRATE}" -application audio)
            ;;
        aac)
            ffmpeg_cmd+=(-c:a aac -b:a "${BITRATE}")
            ;;
        mp3)
            ffmpeg_cmd+=(-c:a libmp3lame -b:a "${BITRATE}")
            ;;
        *)
            ffmpeg_cmd+=(-c:a libopus -b:a "${BITRATE}")
            ;;
    esac
    
    # Add output options
    ffmpeg_cmd+=(
        -f rtsp
        -rtsp_transport tcp
        "rtsp://${MEDIAMTX_HOST}:8554/${STREAM_PATH}"
    )
    
    # Log the complete command for debugging
    log_message "FFmpeg command: ${ffmpeg_cmd[*]}"
    
    # Start FFmpeg with proper process group
    if command -v setsid &>/dev/null; then
        setsid "${ffmpeg_cmd[@]}" >> "${FFMPEG_LOG}" 2>&1 &
        FFMPEG_PID=$!
    else
        "${ffmpeg_cmd[@]}" >> "${FFMPEG_LOG}" 2>&1 &
        FFMPEG_PID=$!
    fi
    
    # Validate FFmpeg process started
    sleep 0.5
    if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
        log_message "ERROR: FFmpeg failed to start"
        if [[ -f "${FFMPEG_LOG}" ]]; then
            log_message "Last output: $(tail -n 5 "${FFMPEG_LOG}" 2>/dev/null | tr '\n' ' ')"
        fi
        FFMPEG_PID=""
        return 1
    fi
    
    log_message "Started multiplex FFmpeg with PID ${FFMPEG_PID}"
    return 0
}

check_devices_exist() {
    for card_num in "${CARD_NUMBERS[@]}"; do
        if [[ ! -e "/dev/snd/pcmC${card_num}D0c" ]]; then
            log_message "Device card ${card_num} no longer exists"
            return 1
        fi
    done
    return 0
}

# Check if parent is still alive
check_parent_alive() {
    if [[ -n "${PARENT_PID}" ]] && [[ "${PARENT_PID}" -gt 1 ]]; then
        if ! kill -0 "${PARENT_PID}" 2>/dev/null; then
            log_message "Parent process ${PARENT_PID} died, exiting"
            return 1
        fi
    fi
    return 0
}

# Log startup
log_critical "Multiplex stream wrapper starting for ${STREAM_PATH} with ${NUM_DEVICES} devices"
log_message "Wrapper PID: $$, Parent PID: ${PARENT_PID}"
log_message "Filter type: ${FILTER_TYPE}"

# Main restart loop
while true; do
    # Check parent is alive
    if ! check_parent_alive; then
        break
    fi
    
    if [[ -f "${CLEANUP_MARKER}" ]]; then
        log_message "Cleanup in progress, stopping wrapper"
        break
    fi
    
    if ! check_devices_exist; then
        log_message "One or more devices no longer exist"
        break
    fi
    
    if [[ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]]; then
        log_message "Too many consecutive failures ($CONSECUTIVE_FAILURES)"
        break
    fi
    
    if [[ $RESTART_COUNT -ge $MAX_WRAPPER_RESTARTS ]]; then
        log_message "Max restarts reached ($RESTART_COUNT)"
        break
    fi
    
    log_message "Starting FFmpeg (attempt #$((RESTART_COUNT + 1)))"
    
    START_TIME=$(date +%s)
    
    if ! run_ffmpeg; then
        log_message "Failed to start FFmpeg"
        ((CONSECUTIVE_FAILURES++))
        # v1.3.3 CRITICAL FIX: Protect against integer overflow in restart delay
        if (( RESTART_DELAY <= 0 )) || (( RESTART_DELAY > 300 )); then
            RESTART_DELAY=10
        else
            RESTART_DELAY=$((RESTART_DELAY * 2))
            if (( RESTART_DELAY > 300 )); then
                RESTART_DELAY=300
            fi
        fi
        sleep $RESTART_DELAY
        continue
    fi
    
    # Wait for FFmpeg to exit
    wait "${FFMPEG_PID}" 2>/dev/null
    exit_code=$?
    
    FFMPEG_PID=""
    
    END_TIME=$(date +%s)
    RUN_TIME=$((END_TIME - START_TIME))
    
    log_message "FFmpeg exited with code ${exit_code} after ${RUN_TIME} seconds"
    
    ((RESTART_COUNT++))
    
    # Reset failures and delay if ran successfully
    if [[ ${RUN_TIME} -gt ${WRAPPER_SUCCESS_DURATION} ]]; then
        CONSECUTIVE_FAILURES=0
        RESTART_DELAY=10
        log_message "Successful run, reset delay to ${RESTART_DELAY}s"
    else
        ((CONSECUTIVE_FAILURES++))
        # v1.3.3 CRITICAL FIX: Protect against integer overflow in restart delay
        if (( RESTART_DELAY <= 0 )) || (( RESTART_DELAY > 300 )); then
            RESTART_DELAY=10
        else
            RESTART_DELAY=$((RESTART_DELAY * 2))
            if (( RESTART_DELAY > 300 )); then
                RESTART_DELAY=300
            fi
        fi
    fi
    
    # Check parent before sleeping
    if ! check_parent_alive; then
        break
    fi
    
    log_message "Waiting ${RESTART_DELAY}s before restart (failures: $CONSECUTIVE_FAILURES)"
    sleep ${RESTART_DELAY}
done

log_message "Wrapper exiting for ${STREAM_PATH}"
WRAPPER_LOGIC
    
    chmod +x "$wrapper_script"
    
    # Check wrapper script was created properly
    if [[ ! -x "$wrapper_script" ]]; then
        log ERROR "Failed to create executable wrapper script"
        return 1
    fi
    
    # Validate wrapper script syntax
    if ! bash -n "$wrapper_script" 2>/dev/null; then
        log ERROR "Wrapper script has syntax errors"
        return 1
    fi
    
    # v1.3.3 CRITICAL FIX: Acquire stream-specific lock to prevent race condition
    local stream_lock="${FFMPEG_PID_DIR}/${stream_path}.lock"
    local stream_lock_fd=-1
    
    {
        exec {stream_lock_fd}>"${stream_lock}" 2>/dev/null
    } || {
        log ERROR "Failed to create stream lock file"
        return 1
    }
    
    if ! flock -n "${stream_lock_fd}" 2>/dev/null; then
        log WARN "Stream $stream_path is already being started by another process"
        exec {stream_lock_fd}>&- 2>/dev/null || true
        return 1
    fi
    
    # Start wrapper with process group using setsid if available
    log DEBUG "Starting multiplex wrapper script: $wrapper_script"
    if command_exists setsid; then
        nohup setsid bash "$wrapper_script" >/dev/null 2>&1 &
    else
        nohup bash "$wrapper_script" >/dev/null 2>&1 &
    fi
    
    local wrapper_pid=$!
    
    # Give wrapper time to start
    sleep "${QUICK_SLEEP}"
    
    # Verify wrapper is running
    if ! kill -0 "$wrapper_pid" 2>/dev/null; then
        log ERROR "Multiplex wrapper failed to start"
        exec {stream_lock_fd}>&- 2>/dev/null || true
        rm -f "$stream_lock"
        return 1
    fi
    
    # Write wrapper PID atomically
    if ! write_pid_atomic "$wrapper_pid" "$pid_file"; then
        log ERROR "Failed to write multiplex wrapper PID"
        kill -TERM "$wrapper_pid" 2>/dev/null || true
        exec {stream_lock_fd}>&- 2>/dev/null || true
        rm -f "$stream_lock"
        return 1
    fi
    
    # Release stream lock
    exec {stream_lock_fd}>&- 2>/dev/null || true
    rm -f "$stream_lock"
    
    log INFO "Multiplex stream started successfully (wrapper PID: $wrapper_pid)"
    return 0
}

# Start FFmpeg stream
start_ffmpeg_stream() {
    local device_name="$1"
    local card_num="$2"
    local stream_path="$3"
    
    local pid_file="${FFMPEG_PID_DIR}/${stream_path}.pid"
    
    # Check if already running
    if [[ -f "$pid_file" ]]; then
        local existing_pid
        existing_pid="$(read_pid_safe "$pid_file")"
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            # v1.3.4 FIX: Verify PID actually belongs to our wrapper script
            if pgrep -f "${FFMPEG_PID_DIR}/${stream_path}.sh" | grep -q "^${existing_pid}$"; then
                log DEBUG "Stream $stream_path already running"
                return 0
            else
                log WARN "Stale PID file for $stream_path (PID $existing_pid is not our wrapper)"
                rm -f "$pid_file"
            fi
        fi
    fi
    
    if ! check_audio_device "$card_num"; then
        log ERROR "Audio device card ${card_num} is not accessible"
        return 1
    fi
    
    # Get device configuration
    local sample_rate channels codec bitrate thread_queue
    sample_rate="$(get_device_config "$device_name" "SAMPLE_RATE" "$DEFAULT_SAMPLE_RATE")"
    channels="$(get_device_config "$device_name" "CHANNELS" "$DEFAULT_CHANNELS")"
    codec="$(get_device_config "$device_name" "CODEC" "$DEFAULT_CODEC")"
    bitrate="$(get_device_config "$device_name" "BITRATE" "$DEFAULT_BITRATE")"
    thread_queue="$(get_device_config "$device_name" "THREAD_QUEUE" "$DEFAULT_THREAD_QUEUE")"
    
    log INFO "Starting FFmpeg for $stream_path (device: $device_name, card: $card_num)"
    
    # Create wrapper script
    local wrapper_script="${FFMPEG_PID_DIR}/${stream_path}.sh"
    local ffmpeg_log="${FFMPEG_PID_DIR}/${stream_path}.log"
    
    # Create wrapper with all variables properly quoted
    cat > "$wrapper_script" << 'WRAPPER_START'
#!/bin/bash
set -euo pipefail

# Ensure PATH includes common binary locations
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

WRAPPER_START

    # Write configuration variables
    cat >> "$wrapper_script" << EOF
# Stream Configuration
STREAM_PATH="$stream_path"
CARD_NUM="$card_num"
SAMPLE_RATE="$sample_rate"
CHANNELS="$channels"
BITRATE="$bitrate"
THREAD_QUEUE="$thread_queue"
ANALYZEDURATION="$DEFAULT_ANALYZEDURATION"
PROBESIZE="$DEFAULT_PROBESIZE"
CODEC="$codec"

# File paths
FFMPEG_LOG="$ffmpeg_log"
LOG_FILE="$LOG_FILE"
WRAPPER_PID_FILE="$pid_file"
CLEANUP_MARKER="$CLEANUP_MARKER"
MEDIAMTX_HOST="$MEDIAMTX_HOST"

# Restart configuration
RESTART_COUNT=0
CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=5
MAX_WRAPPER_RESTARTS=$MAX_WRAPPER_RESTARTS
WRAPPER_SUCCESS_DURATION=$WRAPPER_SUCCESS_DURATION
RESTART_DELAY=10
FFMPEG_LOG_MAX_SIZE=$FFMPEG_LOG_MAX_SIZE

FFMPEG_PID=""
PARENT_PID=\$PPID
EOF

    # Add the wrapper logic
    cat >> "$wrapper_script" << 'WRAPPER_LOGIC'

# Create log file if it doesn't exist
touch "${FFMPEG_LOG}" 2>/dev/null || true

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WRAPPER] $1" >> "${FFMPEG_LOG}" 2>/dev/null || true
}

log_critical() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STREAM:${STREAM_PATH}] $1" >> "${LOG_FILE}" 2>/dev/null || true
}

# Cleanup handler
cleanup_wrapper() {
    local exit_code=$?
    log_message "Wrapper cleanup initiated (exit code: $exit_code)"
    
    # Atomic check and kill
    local ffmpeg_pid="${FFMPEG_PID:-}"
    if [[ -n "$ffmpeg_pid" ]]; then
        if kill -0 "$ffmpeg_pid" 2>/dev/null; then
            log_message "Sending SIGINT to FFmpeg process ${ffmpeg_pid}"
            kill -INT "$ffmpeg_pid" 2>/dev/null || true
            
            # Wait briefly for termination
            local term_wait=0
            while kill -0 "$ffmpeg_pid" 2>/dev/null && [[ $term_wait -lt 5 ]]; do
                sleep 0.2
                ((term_wait++))
            done
            
            # Force kill if still running
            if kill -0 "$ffmpeg_pid" 2>/dev/null; then
                kill -KILL "$ffmpeg_pid" 2>/dev/null || true
            fi
        fi
    fi
    
    rm -f "${WRAPPER_PID_FILE}"
    log_critical "Stream wrapper terminated for ${STREAM_PATH}"
    exit "$exit_code"
}

trap cleanup_wrapper EXIT INT TERM

# Run FFmpeg with proper quoting
run_ffmpeg() {
    local audio_device="plughw:${CARD_NUM},0"
    
    log_message "Starting FFmpeg with device: $audio_device"
    
    # Build command array to handle spaces properly
    local ffmpeg_cmd=(
        ffmpeg
        -hide_banner
        -loglevel warning
        -analyzeduration "${ANALYZEDURATION}"
        -probesize "${PROBESIZE}"
        -f alsa
        -ar "${SAMPLE_RATE}"
        -ac "${CHANNELS}"
        -thread_queue_size "${THREAD_QUEUE}"
        -i "${audio_device}"
        -af "aresample=async=1:first_pts=0"
    )
    
    # Add codec options based on codec type. Set to "lowdelay" instead of "audio" for voice
    case "${CODEC}" in
        opus)
            ffmpeg_cmd+=(-c:a libopus -b:a "${BITRATE}" -application audio) 
            ;;
        aac)
            ffmpeg_cmd+=(-c:a aac -b:a "${BITRATE}")
            ;;
        mp3)
            ffmpeg_cmd+=(-c:a libmp3lame -b:a "${BITRATE}")
            ;;
        *)
            ffmpeg_cmd+=(-c:a libopus -b:a "${BITRATE}")
            ;;
    esac
    
    # Add output options
    ffmpeg_cmd+=(
        -f rtsp
        -rtsp_transport tcp
        "rtsp://${MEDIAMTX_HOST}:8554/${STREAM_PATH}"
    )
    
    # Start FFmpeg with proper process group
    if command -v setsid &>/dev/null; then
        setsid "${ffmpeg_cmd[@]}" >> "${FFMPEG_LOG}" 2>&1 &
        FFMPEG_PID=$!
    else
        "${ffmpeg_cmd[@]}" >> "${FFMPEG_LOG}" 2>&1 &
        FFMPEG_PID=$!
    fi
    
    # Validate FFmpeg process started
    sleep 0.2
    if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
        log_message "ERROR: FFmpeg failed to start"
        if [[ -f "${FFMPEG_LOG}" ]]; then
            log_message "Last output: $(tail -n 3 "${FFMPEG_LOG}" 2>/dev/null | tr '\n' ' ')"
        fi
        FFMPEG_PID=""
        return 1
    fi
    
    log_message "Started FFmpeg with PID ${FFMPEG_PID}"
    return 0
}

check_device_exists() {
    [[ -e "/dev/snd/pcmC${CARD_NUM}D0c" ]]
}

# Check if parent is still alive
check_parent_alive() {
    if [[ -n "${PARENT_PID}" ]] && [[ "${PARENT_PID}" -gt 1 ]]; then
        if ! kill -0 "${PARENT_PID}" 2>/dev/null; then
            log_message "Parent process ${PARENT_PID} died, exiting"
            return 1
        fi
    fi
    return 0
}

# Log startup
log_critical "Stream wrapper starting for ${STREAM_PATH} (card ${CARD_NUM})"
log_message "Wrapper PID: $$, Parent PID: ${PARENT_PID}"

# Main restart loop
while true; do
    # Check parent is alive
    if ! check_parent_alive; then
        break
    fi
    
    if [[ -f "${CLEANUP_MARKER}" ]]; then
        log_message "Cleanup in progress, stopping wrapper"
        break
    fi
    
    if ! check_device_exists; then
        log_message "Device card ${CARD_NUM} no longer exists"
        break
    fi
    
    if [[ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]]; then
        log_message "Too many consecutive failures ($CONSECUTIVE_FAILURES)"
        break
    fi
    
    if [[ $RESTART_COUNT -ge $MAX_WRAPPER_RESTARTS ]]; then
        log_message "Max restarts reached ($RESTART_COUNT)"
        break
    fi
    
    log_message "Starting FFmpeg (attempt #$((RESTART_COUNT + 1)))"
    
    START_TIME=$(date +%s)
    
    if ! run_ffmpeg; then
        log_message "Failed to start FFmpeg"
        ((CONSECUTIVE_FAILURES++))
        # v1.3.3 CRITICAL FIX: Protect against integer overflow in restart delay
        if (( RESTART_DELAY <= 0 )) || (( RESTART_DELAY > 300 )); then
            RESTART_DELAY=10
        else
            RESTART_DELAY=$((RESTART_DELAY * 2))
            if (( RESTART_DELAY > 300 )); then
                RESTART_DELAY=300
            fi
        fi
        sleep $RESTART_DELAY
        continue
    fi
    
    # Wait for FFmpeg to exit
    wait "${FFMPEG_PID}" 2>/dev/null
    exit_code=$?
    
    FFMPEG_PID=""
    
    END_TIME=$(date +%s)
    RUN_TIME=$((END_TIME - START_TIME))
    
    log_message "FFmpeg exited with code ${exit_code} after ${RUN_TIME} seconds"
    
    ((RESTART_COUNT++))
    
    # Reset failures and delay if ran successfully
    if [[ ${RUN_TIME} -gt ${WRAPPER_SUCCESS_DURATION} ]]; then
        CONSECUTIVE_FAILURES=0
        RESTART_DELAY=10
        log_message "Successful run, reset delay to ${RESTART_DELAY}s"
    else
        ((CONSECUTIVE_FAILURES++))
        # v1.3.3 CRITICAL FIX: Protect against integer overflow in restart delay
        if (( RESTART_DELAY <= 0 )) || (( RESTART_DELAY > 300 )); then
            RESTART_DELAY=10
        else
            RESTART_DELAY=$((RESTART_DELAY * 2))
            if (( RESTART_DELAY > 300 )); then
                RESTART_DELAY=300
            fi
        fi
    fi
    
    # Check parent before sleeping
    if ! check_parent_alive; then
        break
    fi
    
    log_message "Waiting ${RESTART_DELAY}s before restart (failures: $CONSECUTIVE_FAILURES)"
    sleep ${RESTART_DELAY}
done

log_message "Wrapper exiting for ${STREAM_PATH}"
WRAPPER_LOGIC
    
    chmod +x "$wrapper_script"
    
    # Check wrapper script was created properly
    if [[ ! -x "$wrapper_script" ]]; then
        log ERROR "Failed to create executable wrapper script"
        return 1
    fi
    
    # v1.3.3 CRITICAL FIX: Acquire stream-specific lock to prevent race condition
    local stream_lock="${FFMPEG_PID_DIR}/${stream_path}.lock"
    local stream_lock_fd=-1
    
    {
        exec {stream_lock_fd}>"${stream_lock}" 2>/dev/null
    } || {
        log ERROR "Failed to create stream lock file"
        return 1
    }
    
    if ! flock -n "${stream_lock_fd}" 2>/dev/null; then
        log WARN "Stream $stream_path is already being started by another process"
        exec {stream_lock_fd}>&- 2>/dev/null || true
        return 1
    fi
    
    # Start wrapper with process group using setsid if available
    log DEBUG "Starting wrapper script: $wrapper_script"
    if command_exists setsid; then
        nohup setsid bash "$wrapper_script" >/dev/null 2>&1 &
    else
        nohup bash "$wrapper_script" >/dev/null 2>&1 &
    fi
    local pid=$!
    
    # Give wrapper time to start and check for immediate failures
    sleep 0.5
    
    if ! kill -0 "$pid" 2>/dev/null; then
        log ERROR "Wrapper failed to start for $stream_path"
        # Check if log file exists and has error messages
        if [[ -f "$ffmpeg_log" ]]; then
            local last_log
            last_log="$(tail -n 5 "$ffmpeg_log" 2>/dev/null | head -n 1)"
            if [[ -n "$last_log" ]]; then
                log ERROR "Wrapper log: $last_log"
            fi
        fi
        exec {stream_lock_fd}>&- 2>/dev/null || true
        rm -f "$stream_lock"
        rm -f "$wrapper_script"
        return 1
    fi
    
    # Write PID file with enhanced validation
    if ! write_pid_atomic "$pid" "$pid_file"; then
        log ERROR "Failed to write PID file for $stream_path"
        kill "$pid" 2>/dev/null || true
        exec {stream_lock_fd}>&- 2>/dev/null || true
        rm -f "$stream_lock"
        rm -f "$wrapper_script"
        return 1
    fi
    
    # Release stream lock
    exec {stream_lock_fd}>&- 2>/dev/null || true
    rm -f "$stream_lock"
    
    log DEBUG "Wrapper started with PID $pid for stream $stream_path"
    
    # Wait for stream to stabilize
    sleep $((STREAM_STARTUP_DELAY + 3))
    
    if validate_stream "$stream_path"; then
        log INFO "Stream $stream_path started successfully"
        return 0
    else
        log ERROR "Stream $stream_path failed validation"
        kill "$pid" 2>/dev/null || true
        rm -f "$pid_file"
        return 1
    fi
}

# Stop FFmpeg stream
stop_ffmpeg_stream() {
    local stream_path="$1"
    local pid_file="${FFMPEG_PID_DIR}/${stream_path}.pid"
    
    if [[ ! -f "$pid_file" ]]; then
        return 0
    fi
    
    local pid
    pid="$(read_pid_safe "$pid_file")"
    
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        log INFO "Stopping FFmpeg for $stream_path (PID: $pid)"
        terminate_process_group "$pid" 10
    fi
    
    rm -f "$pid_file"
    rm -f "${FFMPEG_PID_DIR}/${stream_path}.sh"
    rm -f "${FFMPEG_PID_DIR}/${stream_path}.log"
    rm -f "${FFMPEG_PID_DIR}/${stream_path}.log.old"
}

# Start all streams with stable device list
start_all_ffmpeg_streams() {
    # Receive device list as arguments instead of detecting again
    local devices=("$@")
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        log WARN "No USB audio devices provided"
        return 0
    fi
    
    log INFO "Starting FFmpeg streams for ${#devices[@]} devices"
    
    local success_count=0
    local failed_streams=()
    
    for device_info in "${devices[@]}"; do
        IFS=':' read -r device_name card_num <<< "$device_info"
        
        if [[ -z "$device_name" ]] || [[ -z "$card_num" ]]; then
            continue
        fi
        
        if [[ ! -e "/dev/snd/controlC${card_num}" ]]; then
            continue
        fi
        
        local stream_path
        stream_path="$(generate_stream_path "$device_name" "$card_num")"
        
        if start_ffmpeg_stream "$device_name" "$card_num" "$stream_path"; then
            ((success_count++)) || true
        else
            failed_streams+=("$stream_path")
            log ERROR "Failed to start stream for $device_name (card $card_num)"
        fi
    done
    
    # Log summary with details about failures
    if [[ ${#failed_streams[@]} -gt 0 ]]; then
        log WARN "Started $success_count/${#devices[@]} FFmpeg streams. Failed: ${failed_streams[*]}"
        return 1  # v1.3.4 FIX: Return error on partial failures for monitoring
    else
        log INFO "Successfully started all $success_count/${#devices[@]} FFmpeg streams"
        return 0
    fi
}

# Stop all streams
stop_all_ffmpeg_streams() {
    log INFO "Stopping all FFmpeg streams"
    
    local nullglob_state
    shopt -q nullglob && nullglob_state=on || nullglob_state=off
    shopt -s nullglob
    
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        if [[ -f "$pid_file" ]]; then
            local stream_path
            stream_path="$(basename "$pid_file" .pid)"
            stop_ffmpeg_stream "$stream_path"
        fi
    done
    
    # v1.3.3 FIX: Restore nullglob state correctly for both on/off
    if [[ "$nullglob_state" == "on" ]]; then
        shopt -s nullglob
    else
        shopt -u nullglob
    fi
    
    pkill -f "^ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" 2>/dev/null || true
}

# v1.4.2 FIX: Generate MediaMTX configuration without subshell locking
generate_mediamtx_config() {
    log INFO "Generating MediaMTX configuration"
    
    if [[ ! -f "${DEVICE_CONFIG_FILE}" ]]; then
        save_device_config
    fi
    
    load_device_config
    
    # Ensure config directory exists
    if [[ ! -d "${CONFIG_DIR}" ]]; then
        mkdir -p "${CONFIG_DIR}" 2>/dev/null || {
            log ERROR "Failed to create config directory: ${CONFIG_DIR}"
            return 1
        }
    fi
    
    # CRITICAL FIX: Don't use subshell for locking - keep lock in main shell
    # Close any existing config lock first
    if [[ ${CONFIG_LOCK_FD} -gt 2 ]]; then
        exec {CONFIG_LOCK_FD}>&- 2>/dev/null || true
    fi
    CONFIG_LOCK_FD=-1
    
    # Create lock file with proper error handling
    {
        exec {CONFIG_LOCK_FD}>"${CONFIG_LOCK_FILE}" 2>/dev/null
    } || {
        log ERROR "Failed to create config lock file"
        return 1
    }
    
    # Validate FD
    if [[ ${CONFIG_LOCK_FD} -le 2 ]]; then
        log ERROR "Invalid config lock FD"
        exec {CONFIG_LOCK_FD}>&- 2>/dev/null || true
        CONFIG_LOCK_FD=-1
        return 1
    fi
    
    if ! flock -x -w 10 ${CONFIG_LOCK_FD}; then
        log ERROR "Failed to acquire config lock"
        exec {CONFIG_LOCK_FD}>&- 2>/dev/null || true
        CONFIG_LOCK_FD=-1
        return 1
    fi
    
    # Create temp file for atomic write
    local tmp_config
    tmp_config="$(mktemp -p "$(dirname "${CONFIG_FILE}")" "$(basename "${CONFIG_FILE}").XXXXXX")"
    
    cat > "$tmp_config" << 'EOF'
# MediaMTX Configuration - Audio Streams
logLevel: info
readTimeout: 30s
writeTimeout: 30s

api: yes
apiAddress: :9997

metrics: yes
metricsAddress: :9998

rtsp: yes
rtspAddress: :8554
rtspTransports: [tcp, udp]

rtmp: no
hls: no
webrtc: no
srt: no

paths:
EOF
    
    # Add paths based on stream mode
    if [[ "${STREAM_MODE}" == "multiplex" ]]; then
        cat >> "$tmp_config" << EOF
  ${MULTIPLEX_STREAM_NAME}:
    source: publisher
    sourceProtocol: automatic
    sourceOnDemand: no
EOF
    else
        # Individual mode - accept any stream name
        cat >> "$tmp_config" << EOF
  '~^[a-zA-Z0-9_-]+$':
    source: publisher
    sourceProtocol: automatic
    sourceOnDemand: no
EOF
    fi
    
    # Atomically move into place
    mv -f "$tmp_config" "${CONFIG_FILE}"
    chmod 644 "${CONFIG_FILE}"
    
    # Release config lock
    exec {CONFIG_LOCK_FD}>&- 2>/dev/null || true
    CONFIG_LOCK_FD=-1
    
    log INFO "Configuration generated successfully"
    return 0
}

# Check if MediaMTX is running
is_mediamtx_running() {
    if [[ -f "${PID_FILE}" ]]; then
        local pid
        pid="$(read_pid_safe "${PID_FILE}")"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Start MediaMTX with single device detection
start_mediamtx() {
    if ! acquire_lock; then
        error_exit "Failed to acquire lock" "${E_LOCK_FAILED}"
    fi
    
    # Handle deferred cleanup from previous termination
    handle_deferred_cleanup
    
    if is_restart_scenario; then
        log INFO "Detected restart scenario, cleaning up"
        cleanup_stale_processes
        if ! wait_for_usb_stabilization "${RESTART_STABILIZATION_DELAY}"; then
            log ERROR "USB subsystem not stable after restart"
            return "${E_USB_NO_DEVICES}"
        fi
        clear_restart_marker
    else
        cleanup_stale_processes
    fi
    
    if is_mediamtx_running; then
        log WARN "MediaMTX already running"
        return 0
    fi
    
    log INFO "Starting MediaMTX..."
    
    if ! wait_for_usb_stabilization "${USB_STABILIZATION_DELAY}"; then
        log ERROR "USB audio subsystem not ready"
        return "${E_USB_NO_DEVICES}"
    fi
    
    # Detect devices ONCE after stabilization
    local devices=()
    readarray -t devices < <(detect_audio_devices)
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        log ERROR "No USB audio devices detected"
        return "${E_USB_NO_DEVICES}"
    fi
    
    if ! generate_mediamtx_config; then
        error_exit "Failed to generate configuration" "${E_CONFIG_ERROR}"
    fi
    
    # Check ports if lsof is available
    if command_exists lsof; then
        for port in 8554 9997 9998; do
            if lsof -i ":$port" >/dev/null 2>&1; then
                log ERROR "Port $port is already in use"
                return 1
            fi
        done
    elif command_exists ss; then
        for port in 8554 9997 9998; do
            if ss -tuln | grep -q ":$port "; then
                log ERROR "Port $port appears to be in use"
                return 1
            fi
        done
    else
        log WARN "Cannot check if MediaMTX ports are in use"
    fi
    
    # Set limits
    ulimit -n 65536 2>/dev/null || true
    ulimit -u 4096 2>/dev/null || true
    
    # Start MediaMTX with process group
    if command_exists setsid; then
        nohup setsid "${MEDIAMTX_BIN}" "${CONFIG_FILE}" >> "${MEDIAMTX_LOG_FILE}" 2>&1 &
    else
        nohup "${MEDIAMTX_BIN}" "${CONFIG_FILE}" >> "${MEDIAMTX_LOG_FILE}" 2>&1 &
    fi
    local pid=$!
    
    sleep "$QUICK_SLEEP"
    
    if ! kill -0 "$pid" 2>/dev/null; then
        log ERROR "MediaMTX process died immediately"
        return 1
    fi
    
    if ! wait_for_mediamtx_ready "$pid"; then
        terminate_process_group "$pid" 5
        log ERROR "MediaMTX failed to become ready"
        return 1
    fi
    
    if ! write_pid_atomic "$pid" "${PID_FILE}"; then
        log ERROR "Failed to write PID file"
        terminate_process_group "$pid" 5
        return 1
    fi
    
    log INFO "MediaMTX started successfully (PID: $pid)"
    
    # Start streams based on mode
    if [[ "${STREAM_MODE}" == "multiplex" ]]; then
        # v1.3.3 CRITICAL FIX: Validate device count before starting multiplex stream
        if [[ ${#devices[@]} -eq 0 ]]; then
            log ERROR "Multiplex mode requires devices but none detected"
            stop_mediamtx
            return "${E_USB_NO_DEVICES}"
        fi
        
        log INFO "Multiplex mode - starting single multiplexed stream to ${MULTIPLEX_STREAM_NAME}"
        # Start single multiplex stream with all devices
        if ! start_ffmpeg_multiplex_stream "${devices[@]}"; then
            log ERROR "Failed to start multiplex stream"
            stop_mediamtx
            return 1
        fi
    else
        log INFO "Individual stream mode - starting separate streams"
        # Pass the stable device list to start function
        start_all_ffmpeg_streams "${devices[@]}"
    fi
    
    # Display stream status based on mode
    echo
    echo -e "${GREEN}=== Available RTSP Streams ===${NC}"
    
    if [[ "${STREAM_MODE}" == "multiplex" ]]; then
        # In multiplex mode, validate the single multiplexed stream
        local stream_path="${MULTIPLEX_STREAM_NAME}"
        if validate_stream "$stream_path"; then
            echo -e "${GREEN}✓${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path} (multiplexed from ${#devices[@]} devices)"
        else
            echo -e "${RED}✗${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path} (failed)"
        fi
    else
        # In individual mode, validate each device's stream
        for device_info in "${devices[@]}"; do
            IFS=':' read -r device_name card_num <<< "$device_info"
            local stream_path
            stream_path="$(generate_stream_path "$device_name" "$card_num")"
            
            if validate_stream "$stream_path"; then
                echo -e "${GREEN}✓${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path}"
            else
                echo -e "${RED}✗${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path} (failed)"
            fi
        done
    fi
    
    echo
    return 0
}

# Stop MediaMTX without requiring lock
stop_mediamtx() {
    STOPPING_SERVICE=true
    
    # Try to acquire lock but don't fail if we can't
    if ! acquire_lock 5; then
        log WARN "Could not acquire lock, proceeding with stop anyway"
    fi
    
    stop_all_ffmpeg_streams
    
    if ! is_mediamtx_running; then
        log WARN "MediaMTX is not running"
        STOPPING_SERVICE=false
        return 0
    fi
    
    log INFO "Stopping MediaMTX..."
    
    local pid
    pid="$(read_pid_safe "${PID_FILE}")"
    
    if [[ -n "$pid" ]]; then
        terminate_process_group "$pid" 30
    fi
    
    rm -f "${PID_FILE}"
    
    log INFO "MediaMTX stopped"
    STOPPING_SERVICE=false
    return 0
}

# Force stop without locks
force_stop_mediamtx() {
    STOPPING_SERVICE=true
    
    log WARN "Force stopping MediaMTX and all related processes"
    
    # Kill all FFmpeg processes
    pkill -f "^ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" 2>/dev/null || true
    
    # Kill all wrapper scripts
    pkill -f "${FFMPEG_PID_DIR}/.*\.sh" 2>/dev/null || true
    
    # Kill MediaMTX
    if [[ -f "${PID_FILE}" ]]; then
        local pid
        pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
        if [[ -n "$pid" ]]; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    
    # Kill any MediaMTX process
    pkill -f "^${MEDIAMTX_BIN}" 2>/dev/null || true
    
    # Clean up all files
    rm -f "${PID_FILE}"
    rm -f "${FFMPEG_PID_DIR}"/*.pid
    rm -f "${FFMPEG_PID_DIR}"/*.sh
    rm -f "${FFMPEG_PID_DIR}"/*.log
    rm -f "${FFMPEG_PID_DIR}"/*.log.old
    rm -f "${RESTART_MARKER}"
    rm -f "${CLEANUP_MARKER}"
    rm -f "${LOCK_FILE}"
    rm -f "${CONFIG_LOCK_FILE}"
    
    log INFO "Force stop completed"
    STOPPING_SERVICE=false
    return 0
}

# Restart MediaMTX
restart_mediamtx() {
    mark_restart
    stop_mediamtx
    sleep "$MEDIUM_SLEEP"
    start_mediamtx
}

# Show status
show_status() {
    SKIP_CLEANUP=true
    
    echo -e "${CYAN}=== MediaMTX Audio Stream Status ===${NC}"
    echo
    
    if is_mediamtx_running; then
        local pid
        pid="$(read_pid_safe "${PID_FILE}")"
        echo -e "MediaMTX: ${GREEN}Running${NC} (PID: $pid)"
        
        # Show resource usage
        if [[ -n "$pid" ]]; then
            local fd_count cpu_percent thread_count
            fd_count=$(find "/proc/$pid/fd" -maxdepth 1 -type l 2>/dev/null | wc -l || echo "?")
            cpu_percent=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ' || echo "?")
            thread_count=$(ps -o nlwp= -p "$pid" 2>/dev/null | tr -d ' ' || echo "?")
            echo "  Resources: FDs=$fd_count, CPU=${cpu_percent}%, Threads=$thread_count"
        fi
    else
        echo -e "MediaMTX: ${RED}Not running${NC}"
    fi
    
    echo
    
    local multiplex_pid_file="${FFMPEG_PID_DIR}/${MULTIPLEX_STREAM_NAME}.pid"
    local is_multiplex_mode=false
    
    if [[ -f "$multiplex_pid_file" ]]; then
        local multiplex_pid
        multiplex_pid="$(read_pid_safe "$multiplex_pid_file")"
        if [[ -n "$multiplex_pid" ]] && kill -0 "$multiplex_pid" 2>/dev/null; then
            is_multiplex_mode=true
        fi
    fi
    
    readarray -t devices < <(detect_audio_devices)
    if [[ "$is_multiplex_mode" == "true" ]]; then
        # Multiplex mode is active
        echo "Multiplex stream (combining ${#devices[@]} devices):"
        echo "  Stream: rtsp://${MEDIAMTX_HOST}:8554/${MULTIPLEX_STREAM_NAME}"
        
        local multiplex_pid
        multiplex_pid="$(read_pid_safe "$multiplex_pid_file")"
        if [[ -n "$multiplex_pid" ]] && kill -0 "$multiplex_pid" 2>/dev/null; then
            echo -e "  Status: ${GREEN}Running${NC} (PID: $multiplex_pid)"
        else
            echo -e "  Status: ${RED}Not running${NC}"
        fi
        
        echo
        echo "Source devices:"
        if [[ ${#devices[@]} -eq 0 ]]; then
            echo "  No devices found"
        else
            for device_info in "${devices[@]}"; do
                IFS=':' read -r device_name card_num <<< "$device_info"
                echo "  - $device_name (card $card_num)"
            done
        fi
    else
        # Individual stream mode
        echo "Detected USB audio devices:"
        if [[ ${#devices[@]} -eq 0 ]]; then
            echo "  No devices found"
        else
            for device_info in "${devices[@]}"; do
                IFS=':' read -r device_name card_num <<< "$device_info"
                
                local stream_path
                stream_path="$(generate_stream_path "$device_name" "$card_num")"
                
                echo "  - $device_name (card $card_num)"
                echo "    Stream: rtsp://${MEDIAMTX_HOST}:8554/$stream_path"
                
                local pid_file="${FFMPEG_PID_DIR}/${stream_path}.pid"
                if [[ -f "$pid_file" ]]; then
                    local pid
                    pid="$(read_pid_safe "$pid_file")"
                    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                        echo -e "    Status: ${GREEN}Running${NC} (PID: $pid)"
                    else
                        echo -e "    Status: ${RED}Not running${NC}"
                    fi
                else
                    echo -e "    Status: ${RED}Not running${NC}"
                fi
            done
        fi
    fi
    
    SKIP_CLEANUP=false
}

# Show configuration
show_config() {
    echo -e "${CYAN}=== Device Configuration ===${NC}"
    echo
    
    if [[ ! -f "${DEVICE_CONFIG_FILE}" ]]; then
        echo "Creating default configuration..."
        save_device_config
    fi
    
    cat "${DEVICE_CONFIG_FILE}"
}

# Create systemd service
create_systemd_service() {
    local service_file="/etc/systemd/system/mediamtx-audio.service"
    
    # FIX v1.3.2: Capture current configuration for systemd service
    local stream_mode="${STREAM_MODE:-individual}"
    local multiplex_filter="${MULTIPLEX_FILTER_TYPE:-amix}"
    local multiplex_name="${MULTIPLEX_STREAM_NAME:-all_mics}"
    
    cat > "$service_file" << EOF
[Unit]
Description=MediaMTX Audio Stream Manager v${VERSION}
After=network.target sound.target
Wants=sound.target

[Service]
Type=forking
ExecStart=${SCRIPT_DIR}/${SCRIPT_NAME} start
ExecStop=${SCRIPT_DIR}/${SCRIPT_NAME} stop
ExecReload=${SCRIPT_DIR}/${SCRIPT_NAME} restart
PIDFile=${PID_FILE}
Restart=on-failure
RestartSec=30
StartLimitInterval=600
StartLimitBurst=5
User=root
Group=audio

TimeoutStartSec=300
TimeoutStopSec=120

LimitNOFILE=65536
LimitNPROC=4096

PrivateTmp=yes
ProtectSystem=full
NoNewPrivileges=yes
ReadWritePaths=/etc/mediamtx /var/lib/mediamtx-ffmpeg /var/log /var/run

Environment="HOME=/root"
Environment="USB_STABILIZATION_DELAY=10"
Environment="STREAM_MODE=${stream_mode}"
Environment="MULTIPLEX_FILTER_TYPE=${multiplex_filter}"
Environment="MULTIPLEX_STREAM_NAME=${multiplex_name}"
Environment="INVOCATION_ID=systemd"
WorkingDirectory=${SCRIPT_DIR}

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$service_file"
    
    # Setup logrotate configuration during install
    if command_exists logrotate && [[ -d /etc/logrotate.d ]]; then
        log INFO "Setting up log rotation configuration"
        cat > /etc/logrotate.d/mediamtx << EOF
${MEDIAMTX_LOG_FILE} {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
    size ${MEDIAMTX_LOG_MAX_SIZE}
    postrotate
        # Send USR1 signal to MediaMTX if running
        if [ -f "${PID_FILE}" ]; then
            kill -USR1 \$(cat ${PID_FILE}) 2>/dev/null || true
        fi
    endscript
}

${LOG_FILE} {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 644 root root
    size ${MAIN_LOG_MAX_SIZE}
}

${FFMPEG_PID_DIR}/*.log {
    daily
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
    size ${FFMPEG_LOG_MAX_SIZE}
}
EOF
        chmod 644 /etc/logrotate.d/mediamtx
        log INFO "Log rotation configured successfully"
    fi
    
    # Create monitoring cron job with correct syntax
    cat > /etc/cron.d/mediamtx-monitor << EOF
# Monitor MediaMTX resource usage every 5 minutes
# Exit code 2 from monitor indicates critical state requiring restart
*/5 * * * * root ${SCRIPT_DIR}/${SCRIPT_NAME} monitor; [ \$? -eq 2 ] && systemctl restart mediamtx-audio
EOF
    
    systemctl daemon-reload
    
    echo "Systemd service created: $service_file"
    echo "Monitoring cron job created: /etc/cron.d/mediamtx-monitor"
    echo ""
    echo "=== Stream Mode Configuration ==="
    echo "Current mode: ${stream_mode}"
    if [[ "${stream_mode}" == "multiplex" ]]; then
        echo "  Filter type: ${multiplex_filter}"
        echo "  Stream name: ${multiplex_name}"
    fi
    echo ""
    echo "To change mode after installation:"
    echo "  sudo systemctl edit mediamtx-audio"
    echo "  Add/modify: Environment=\"STREAM_MODE=multiplex\""
    echo "  Add/modify: Environment=\"MULTIPLEX_FILTER_TYPE=amix\""
    echo "  Add/modify: Environment=\"MULTIPLEX_STREAM_NAME=studio\""
    echo "  Then: sudo systemctl daemon-reload && sudo systemctl restart mediamtx-audio"
    echo ""
    echo "Enable: sudo systemctl enable mediamtx-audio"
    echo "Start: sudo systemctl start mediamtx-audio"
}

# Show help
show_help() {
    cat << EOF
MediaMTX Stream Manager v${VERSION}
Part of LyreBirdAudio - RTSP Audio Streaming Suite

Usage: ${SCRIPT_NAME} [OPTIONS] COMMAND

Options:
    -m, --mode MODE      Stream mode (individual|multiplex) [default: individual]
    -f, --filter TYPE    Multiplex filter type (amix|amerge) [default: amix]
    -n, --name NAME      Multiplex stream name [default: all_mics]
    -d, --debug          Enable debug output
    -h, --help           Show this help message

Environment Variables:
    MULTIPLEX_FILTER_TYPE    Multiplex audio filter type [default: amix]
                             - amix: Mix all audio sources into one output
                             - amerge: Merge sources keeping channels separate

Commands:
    start       Start MediaMTX and FFmpeg streams
    stop        Stop MediaMTX and FFmpeg streams
    force-stop  Force stop all processes (emergency use)
    restart     Restart everything
    status      Show current status
    config      Show device configuration
    monitor     Check resource usage (exits with code 2 if restart needed)
    install     Create systemd service
    help        Show this help

Configuration files:
    Device config: ${DEVICE_CONFIG_FILE}
    MediaMTX config: ${CONFIG_FILE}
    System log: ${LOG_FILE}
    MediaMTX log: ${MEDIAMTX_LOG_FILE}

Multiplex Mode Usage:
    Individual mode (default):
        sudo ./mediamtx-stream-manager.sh start
        Creates separate RTSP streams for each USB microphone
    
    Multiplex mode - Mix audio (amix):
        sudo ./mediamtx-stream-manager.sh -m multiplex -f amix start
        # Or use default filter (amix)
        sudo ./mediamtx-stream-manager.sh -m multiplex start
        Mixes all microphones into a single audio stream
        Output: rtsp://localhost:8554/${MULTIPLEX_STREAM_NAME}
    
    Multiplex mode - Separate channels (amerge):
        sudo ./mediamtx-stream-manager.sh -m multiplex -f amerge start
        Merges all microphones keeping channels separate
        Output: Single stream with (num_devices * channels_per_device) total channels
    
    Custom stream name:
        sudo ./mediamtx-stream-manager.sh -m multiplex -f amix -n studio start
        Output: rtsp://localhost:8554/studio
    
    Environment variables (still supported):
        sudo MULTIPLEX_FILTER_TYPE=amix ./mediamtx-stream-manager.sh -m multiplex start
        sudo MULTIPLEX_STREAM_NAME=studio ./mediamtx-stream-manager.sh -m multiplex start

Version ${VERSION} - Production Ready Fixes Applied:
v1.4.2:
    - CRITICAL: Fixed CONFIG_LOCK_FILE subshell isolation issue
    - CRITICAL: Fixed PID file permission race condition
    - CRITICAL: Made cleanup marker creation atomic
    - Added cleanup verification for enhanced robustness
v1.4.1:
    - CRITICAL: Fixed file descriptor leak in lock management
    - CRITICAL: Removed conflicting in-script log rotation
    - CRITICAL: Fixed cron job syntax for proper monitoring
    - CRITICAL: Stabilized device detection with single scan
    - CRITICAL: Added missing signal handlers (HUP, QUIT)
    - CRITICAL: Added CONFIG_LOCK_FILE cleanup

Resource Monitoring:
    The monitor command checks for:
    - File descriptor leaks (warn: ${MAX_FD_WARNING}, critical: ${MAX_FD_CRITICAL})
    - High CPU usage (warn: ${MAX_CPU_WARNING}%, critical: ${MAX_CPU_CRITICAL}%)
    - Wrapper process accumulation
    
    Monitor exits with code 2 when critical thresholds are exceeded,
    allowing systemd or cron to handle the restart.

Exit Codes:
    0 - Success
    1 - General error
    2 - Critical resource state (monitor command only)
    3 - Missing dependencies
    4 - Configuration error
    5 - Lock acquisition failed
    6 - No USB devices found

EOF
}

# Main function with enhanced argument parsing
parse_arguments() {
    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--mode)
                shift
                STREAM_MODE="${1}"
                if [[ "${STREAM_MODE}" != "individual" ]] && [[ "${STREAM_MODE}" != "multiplex" ]]; then
                    echo "Error: Invalid stream mode '${STREAM_MODE}'. Use 'individual' or 'multiplex'" >&2
                    exit 1
                fi
                shift
                ;;
            -f|--filter)
                shift
                MULTIPLEX_FILTER_TYPE="${1}"
                if [[ "${MULTIPLEX_FILTER_TYPE}" != "amix" ]] && [[ "${MULTIPLEX_FILTER_TYPE}" != "amerge" ]]; then
                    echo "Error: Invalid filter type '${MULTIPLEX_FILTER_TYPE}'. Use 'amix' or 'amerge'" >&2
                    exit 1
                fi
                shift
                ;;
            -n|--name)
                shift
                MULTIPLEX_STREAM_NAME="${1}"
                shift
                ;;
            -d|--debug)
                export DEBUG=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                echo "Error: Unknown option '$1'" >&2
                show_help
                exit 1
                ;;
            *)
                # This is the command - return it and preserve remaining args
                COMMAND="$1"
                return 0
                ;;
        esac
    done
    
    # No command specified
    COMMAND="help"
}

main() {
    local exit_code=0
    
    # Parse arguments
    COMMAND=""
    parse_arguments "$@"
    
    # Log stream mode if set
    if [[ -n "${STREAM_MODE}" ]] && [[ "${STREAM_MODE}" != "individual" ]]; then
        log INFO "Stream mode: ${STREAM_MODE}"
    fi
    
    case "${COMMAND}" in
        start)
            check_root
            check_dependencies
            setup_directories
            start_mediamtx
            exit_code=$?
            ;;
        stop)
            check_root
            check_dependencies
            setup_directories
            stop_mediamtx
            exit_code=$?
            ;;
        force-stop)
            check_root
            setup_directories
            force_stop_mediamtx
            exit_code=$?
            ;;
        restart)
            check_root
            check_dependencies
            setup_directories
            restart_mediamtx
            exit_code=$?
            ;;
        status)
            show_status
            exit_code=$?
            ;;
        config)
            show_config
            exit_code=$?
            ;;
        monitor)
            check_root
            setup_directories
            # Return the exit code from check_resource_usage
            check_resource_usage
            exit_code=$?
            ;;
        install)
            check_root
            create_systemd_service
            exit_code=$?
            ;;
        help|--help|-h|"")
            show_help
            exit_code=0
            ;;
        *)
            echo "Error: Unknown command '${1}'" >&2
            show_help
            exit_code=1
            ;;
    esac
    
    # Properly propagate exit code
    exit ${exit_code}
}

# Run main
main "$@"

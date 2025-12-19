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
# Version: 1.4.2 - Production reliability enhancements
# Compatible with MediaMTX v1.15.0+
#
# Version History:
# v1.4.2 - Production reliability enhancements for 24/7 field deployment
#   MONITORING ENHANCEMENTS:
#   - Watchdog/heartbeat mechanism with optional hardware watchdog support
#   - Disk space monitoring with configurable thresholds
#   - Memory usage trending and leak detection
#   - Network connectivity monitoring with gateway check
#   - MediaMTX API version auto-detection with fallback
#   - USB device ALSA availability checking before restart
#   - Configuration validation on startup
#
#   BUFFERING IMPROVEMENTS:
#   - Optional memory-based audio ring buffer (reduces data loss on restart)
#   - Configurable buffer size per stream
#   - Optional disk persistence for buffers (SD card wear consideration)
#
#   RELIABILITY FIXES:
#   - Enhanced signal handling (SIGPIPE, SIGHUP, SIGQUIT)
#   - Lock directory validation before file creation
#   - Process group termination improvements
#   - Version compatibility checking between scripts
#
# v1.4.1 - Friendly name support for audio device configuration
#   CONFIGURATION ENHANCEMENT:
#   - Added dual-lookup config system supporting both friendly and full device names
#   - Users can now use friendly stream names (e.g., DEVICE_BLUE_YETI_SAMPLE_RATE=44100)
#   - Friendly names match RTSP stream paths for easier configuration
#   - Maintains 100% backward compatibility with existing full device name configs
#   - Updated config file template with friendly name documentation and examples
#
# v1.4.0 - Production stability and monitoring enhancements
#   RELIABILITY IMPROVEMENTS:
#   - Separate monitoring lock eliminates service/cron contention
#   - Conservative cron restart policy (exit 2 only) for stable 24/7 operation
#   - Increased systemd restart tolerance (10 restarts/20min) for USB hotplug
#   - Recursive process tree termination ensures complete cleanup
#   - Enhanced lock file mutual exclusion prevents concurrent execution
#
#   MONITORING ENHANCEMENTS:
#   - Multiplex stream health monitoring with automatic restart
#   - Real-time progress messages during stream initialization
#   - FFmpeg log rotation prevents unbounded disk usage
#   - Resource monitoring (CPU, file descriptors) with threshold alerts
#
#   STABILITY FIXES:
#   - Stream name validation prevents RTSP parsing failures
#   - Cron installation handles special characters in paths
#   - Wrapper PID validation detects stale processes
#   - Config file permission race condition eliminated
#
#   API COMPATIBILITY:
#   - Error codes maintained for backward compatibility
#   - Best-effort return behavior for partial stream failures
#
# v1.3.4 - Production fix for stream persistence after device events
#   CRITICAL FIXES:
#   - Removed stream-specific lock that caused restart failures after device events
#   - Added stream health monitoring with automatic restart to monitor command
#   - Fixed wrapper PID validation to detect truly stale processes
#   - Added stream reconciliation without touching device discovery logic
#   VERIFIED: Maintains v1.3.2 stability while adding v1.3.3 quality fixes
#   VERIFIED: Zero changes to device detection - proven logic preserved
#
# v1.3.3 and earlier - Production hardening and feature development
#   - Multiplex streaming mode for combining multiple microphones
#   - Comprehensive code review fixes (FD leaks, unicode, validation)
#   - systemd integration and signal handling improvements
#   - Resource monitoring and atomic file operations
#
# Requirements:
# - MediaMTX installed (use install_mediamtx.sh)
# - USB audio devices
# - ffmpeg installed for audio encoding

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

# Source shared library if available (backward compatible)
# Provides: colors, logging, command_exists, compute_hash, exit codes
# Falls back gracefully if library not present - all functions defined locally below
_LYREBIRD_COMMON="${BASH_SOURCE[0]%/*}/lyrebird-common.sh"

# v1.4.2: Verify library integrity before sourcing (security hardening)
# Set LYREBIRD_COMMON_EXPECTED_HASH to enable verification
# To generate: sha256sum lyrebird-common.sh | cut -d' ' -f1
_LYREBIRD_COMMON_EXPECTED_HASH="${LYREBIRD_COMMON_EXPECTED_HASH:-}"

_verify_common_library() {
    local lib_path="$1"
    local expected_hash="$2"

    # Skip verification if no expected hash provided (backward compatible)
    [[ -z "$expected_hash" ]] && return 0

    # Compute actual hash
    local actual_hash=""
    if command -v sha256sum >/dev/null 2>&1; then
        actual_hash=$(sha256sum "$lib_path" 2>/dev/null | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then
        actual_hash=$(shasum -a 256 "$lib_path" 2>/dev/null | cut -d' ' -f1)
    else
        # No hash tool available, skip verification with warning
        echo "[WARN] Cannot verify lyrebird-common.sh integrity (no sha256sum/shasum)" >&2
        return 0
    fi

    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "[ERROR] lyrebird-common.sh integrity check failed!" >&2
        echo "[ERROR] Expected: $expected_hash" >&2
        echo "[ERROR] Actual:   $actual_hash" >&2
        echo "[ERROR] The library may have been tampered with. Aborting." >&2
        return 1
    fi

    return 0
}

# shellcheck source=lyrebird-common.sh
if [[ -f "$_LYREBIRD_COMMON" ]]; then
    if _verify_common_library "$_LYREBIRD_COMMON" "$_LYREBIRD_COMMON_EXPECTED_HASH"; then
        source "$_LYREBIRD_COMMON"
    else
        # Integrity check failed - exit for security
        exit 1
    fi
fi
unset _LYREBIRD_COMMON _LYREBIRD_COMMON_EXPECTED_HASH
unset -f _verify_common_library

# Constants
readonly VERSION="1.4.2"

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
readonly E_MEDIAMTX_DOWN=7
readonly E_MONITOR_DEGRADED=10

# Configurable paths with environment variable defaults
readonly CONFIG_DIR="${MEDIAMTX_CONFIG_DIR:-/etc/mediamtx}"
readonly CONFIG_FILE="${MEDIAMTX_CONFIG_FILE:-${CONFIG_DIR}/mediamtx.yml}"
readonly DEVICE_CONFIG_FILE="${MEDIAMTX_DEVICE_CONFIG:-${CONFIG_DIR}/audio-devices.conf}"
readonly PID_FILE="${MEDIAMTX_PID_FILE:-/run/mediamtx-audio.pid}"
readonly FFMPEG_PID_DIR="${MEDIAMTX_FFMPEG_DIR:-/var/lib/mediamtx-ffmpeg}"
readonly LOCK_FILE="${MEDIAMTX_LOCK_FILE:-/run/mediamtx-audio.lock}"
# Lock file strategy:
# - Uses flock() for exclusive access (kernel-enforced)
# - File descriptor stored in MAIN_LOCK_FD global variable
# - Deleted only when demonstrably stale (via is_lock_stale function)
# - NOT deleted on timeout failure (avoids race conditions)
# - Separate monitor lock (/run/mediamtx-monitor.lock) used by cron
#   to avoid contention with service lock during start/stop operations
readonly LOG_FILE="${MEDIAMTX_LOG_FILE:-/var/log/mediamtx-stream-manager.log}"
readonly MEDIAMTX_LOG_FILE="${MEDIAMTX_LOG_FILE:-/var/log/mediamtx.out}"
readonly MEDIAMTX_BIN="${MEDIAMTX_BINARY:-/usr/local/bin/mediamtx}"
readonly MEDIAMTX_HOST="${MEDIAMTX_HOST:-localhost}"
# Note: These are NOT readonly to allow command-line option overrides
STREAM_MODE="${STREAM_MODE:-individual}"
MULTIPLEX_STREAM_NAME="${MULTIPLEX_STREAM_NAME:-all_mics}"
MULTIPLEX_FILTER_TYPE="${MULTIPLEX_FILTER_TYPE:-amix}"
readonly RESTART_MARKER="${MEDIAMTX_RESTART_MARKER:-/run/mediamtx-audio.restart}"
readonly CLEANUP_MARKER="${MEDIAMTX_CLEANUP_MARKER:-/run/mediamtx-audio.cleanup}"
readonly CONFIG_LOCK_FILE="${CONFIG_DIR}/.config.lock"

# System limits
SYSTEM_PID_MAX="$(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 32768)"
readonly SYSTEM_PID_MAX

# Timeouts
readonly PID_TERMINATION_TIMEOUT="${PID_TERMINATION_TIMEOUT:-10}"
readonly MEDIAMTX_API_TIMEOUT="${MEDIAMTX_API_TIMEOUT:-60}"
readonly LOCK_ACQUISITION_TIMEOUT="${LOCK_ACQUISITION_TIMEOUT:-30}"
readonly LOCK_STALE_THRESHOLD="${LOCK_STALE_THRESHOLD:-300}" # 5 minutes

# Audio settings
readonly DEFAULT_SAMPLE_RATE="${DEFAULT_SAMPLE_RATE:-48000}"
readonly DEFAULT_CHANNELS="${DEFAULT_CHANNELS:-2}"
readonly DEFAULT_CODEC="${DEFAULT_CODEC:-opus}"
readonly DEFAULT_BITRATE="${DEFAULT_BITRATE:-128k}"
readonly DEFAULT_THREAD_QUEUE="${DEFAULT_THREAD_QUEUE:-8192}"
readonly DEFAULT_ANALYZEDURATION="${DEFAULT_ANALYZEDURATION:-5000000}"
readonly DEFAULT_PROBESIZE="${DEFAULT_PROBESIZE:-5000000}"

# Stream name validation
readonly MAX_STREAM_NAME_LENGTH=48
readonly MIN_STREAM_NAME_LENGTH=1
readonly RESERVED_STREAM_NAMES="control|stats|api|metrics|health"

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

# Wrapper restart behavior (extracted from hardcoded values)
readonly MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-5}"
readonly INITIAL_RESTART_DELAY="${INITIAL_RESTART_DELAY:-10}"
readonly MAX_RESTART_DELAY="${MAX_RESTART_DELAY:-300}"

# Log rotation settings
readonly MAIN_LOG_MAX_SIZE="${MAIN_LOG_MAX_SIZE:-104857600}"        # 100MB
readonly FFMPEG_LOG_MAX_SIZE="${FFMPEG_LOG_MAX_SIZE:-10485760}"     # 10MB
readonly MEDIAMTX_LOG_MAX_SIZE="${MEDIAMTX_LOG_MAX_SIZE:-52428800}" # 50MB

# ============================================================================
# Production Reliability Settings (v1.4.2 additions)
# ============================================================================

# Watchdog/Heartbeat settings
# Heartbeat runs more frequently than cron for faster failure detection
readonly HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-30}"             # Seconds between heartbeats
readonly HEARTBEAT_FILE="${HEARTBEAT_FILE:-/run/mediamtx-audio.heartbeat}"
readonly ENABLE_HARDWARE_WATCHDOG="${ENABLE_HARDWARE_WATCHDOG:-auto}" # auto, yes, no
readonly HARDWARE_WATCHDOG_DEVICE="${HARDWARE_WATCHDOG_DEVICE:-/dev/watchdog}"
readonly HARDWARE_WATCHDOG_TIMEOUT="${HARDWARE_WATCHDOG_TIMEOUT:-60}" # Seconds

# Disk space monitoring thresholds
readonly DISK_SPACE_WARNING_PERCENT="${DISK_SPACE_WARNING_PERCENT:-80}"
readonly DISK_SPACE_CRITICAL_PERCENT="${DISK_SPACE_CRITICAL_PERCENT:-95}"
readonly DISK_SPACE_MIN_FREE_MB="${DISK_SPACE_MIN_FREE_MB:-100}"    # Minimum free MB

# Memory monitoring and leak detection
readonly MEM_WARNING_PERCENT="${MEM_WARNING_PERCENT:-80}"
readonly MEM_CRITICAL_PERCENT="${MEM_CRITICAL_PERCENT:-95}"
readonly MEM_GROWTH_THRESHOLD_MB="${MEM_GROWTH_THRESHOLD_MB:-100}"  # MB growth triggers restart
readonly MEM_SAMPLE_FILE="${MEM_SAMPLE_FILE:-/var/lib/mediamtx-ffmpeg/.mem_samples}"

# Network connectivity monitoring
readonly NETWORK_CHECK_ENABLED="${NETWORK_CHECK_ENABLED:-true}"
readonly NETWORK_CHECK_TARGET="${NETWORK_CHECK_TARGET:-gateway}"    # gateway, specific IP, or hostname
readonly NETWORK_CHECK_TIMEOUT="${NETWORK_CHECK_TIMEOUT:-5}"        # Seconds
readonly NETWORK_FAIL_THRESHOLD="${NETWORK_FAIL_THRESHOLD:-3}"      # Consecutive failures before alert

# Audio buffering (memory-based with optional disk persistence)
# Memory buffering is done via FFmpeg's rtbufsize option (no SD card wear)
readonly AUDIO_BUFFER_ENABLED="${AUDIO_BUFFER_ENABLED:-true}"       # Enable enhanced memory buffering
readonly AUDIO_BUFFER_SIZE_MB="${AUDIO_BUFFER_SIZE_MB:-64}"         # Memory buffer size per stream (MB)
readonly AUDIO_RTBUFSIZE="${AUDIO_RTBUFSIZE:-33554432}"             # Real-time buffer size in bytes (32MB default)
# Local recording (ring buffer) - writes audio to tmpfs or disk alongside streaming
readonly AUDIO_LOCAL_RECORDING="${AUDIO_LOCAL_RECORDING:-false}"    # Enable local recording backup
readonly AUDIO_RECORDING_PATH="${AUDIO_RECORDING_PATH:-/dev/shm/lyrebird-buffer}" # Default to tmpfs (RAM)
readonly AUDIO_RECORDING_SEGMENT_TIME="${AUDIO_RECORDING_SEGMENT_TIME:-300}" # 5 min segments
readonly AUDIO_RECORDING_SEGMENTS="${AUDIO_RECORDING_SEGMENTS:-12}" # Keep last 12 segments (1 hour)
readonly AUDIO_DISK_PERSIST="${AUDIO_DISK_PERSIST:-false}"          # Move segments to disk (SD card wear!)
readonly AUDIO_DISK_PATH="${AUDIO_DISK_PATH:-/var/lib/mediamtx-ffmpeg/recordings}"

# Audio level monitoring (detect dead/silent microphones)
readonly AUDIO_LEVEL_CHECK_ENABLED="${AUDIO_LEVEL_CHECK_ENABLED:-true}"  # Enable silence detection
readonly AUDIO_LEVEL_SAMPLE_DURATION="${AUDIO_LEVEL_SAMPLE_DURATION:-3}" # Seconds to sample for level check
readonly AUDIO_SILENCE_THRESHOLD_DB="${AUDIO_SILENCE_THRESHOLD_DB:--60}" # dB below which is "silence"
readonly AUDIO_SILENCE_WARN_DURATION="${AUDIO_SILENCE_WARN_DURATION:-60}" # Seconds of silence before warning

# MediaMTX API version compatibility
readonly MEDIAMTX_API_VERSION="${MEDIAMTX_API_VERSION:-auto}"       # auto, v3, v2, v1
readonly MEDIAMTX_API_FALLBACK="${MEDIAMTX_API_FALLBACK:-true}"     # Try older API versions

# USB device health checks
readonly USB_ALSA_CHECK_ENABLED="${USB_ALSA_CHECK_ENABLED:-true}"   # Check ALSA availability before restart
readonly USB_DISCONNECT_GRACE_PERIOD="${USB_DISCONNECT_GRACE_PERIOD:-10}" # Seconds to wait after disconnect

# Version compatibility
readonly MIN_COMPATIBLE_COMMON_VERSION="1.0.0"
readonly SCRIPT_COMPAT_VERSION="1.4.2"

# Standard timing constants
readonly QUICK_SLEEP=0.1
readonly SHORT_SLEEP=1
readonly MEDIUM_SLEEP=2

# Global lock file descriptor
declare -gi MAIN_LOCK_FD=-1

# Global config lock file descriptor
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

# Enhanced atomic cleanup with better marker creation
cleanup() {
    local exit_code=$?

    # Skip cleanup if requested or if we're stopping the service
    if [[ "${SKIP_CLEANUP}" == "true" ]] || [[ "${STOPPING_SERVICE}" == "true" ]]; then
        release_lock_unsafe
        release_config_lock_unsafe
        exit "${exit_code}"
    fi

    # Only perform cleanup on unexpected exit (non-zero exit code)
    # Skip marker creation for read-only commands to prevent race conditions
    if [[ $exit_code -ne 0 ]] && [[ "${COMMAND}" != "monitor" ]] && [[ "${COMMAND}" != "status" ]] && [[ "${COMMAND}" != "config" ]]; then
        # Use atomic marker creation
        local marker_tmp
        marker_tmp="$(mktemp "${CLEANUP_MARKER}.XXXXXX" 2>/dev/null)" \
            && mv -f "$marker_tmp" "${CLEANUP_MARKER}" 2>/dev/null \
            || touch "${CLEANUP_MARKER}" 2>/dev/null || true
    fi

    # Always release locks on exit
    release_lock_unsafe
    release_config_lock_unsafe

    exit "${exit_code}"
}

# Set trap for cleanup only in main script
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ $$ -eq $BASHPID ]]; then
    # Comprehensive signal handling for production reliability
    trap cleanup EXIT INT TERM QUIT

    # Ignore SIGPIPE to prevent crashes on broken pipe (common in API calls)
    trap '' PIPE

    # Enhanced signal handlers
    # Only set custom handlers when NOT running under systemd
    if [[ -z "${INVOCATION_ID:-}" ]]; then
        # Not running under systemd - safe to use custom handlers
        # SIGHUP: Reload configuration without full restart
        trap 'log INFO "Received SIGHUP, reloading configuration"; restart_mediamtx' HUP
        # SIGUSR1: Dump status for debugging
        trap 'log INFO "Received SIGUSR1, dumping status"; show_status >/dev/null 2>&1 || log INFO "Status dump completed"' USR1
        # SIGUSR2: Force heartbeat update
        trap 'log DEBUG "Received SIGUSR2, updating heartbeat"; update_heartbeat' USR2
    fi
    # Note: When running under systemd (INVOCATION_ID is set), default signal handlers are used
fi

# Critical section protection - prevents signal handlers from interrupting
# atomic operations like lock acquisition and PID file writes
CRITICAL_SECTION_ACTIVE=false

# Enter critical section - block HUP and USR1 signals to prevent corruption
# Call this before lock acquisition, PID file writes, or config file operations
enter_critical_section() {
    if [[ "$CRITICAL_SECTION_ACTIVE" == "true" ]]; then
        return 0 # Already in critical section
    fi
    CRITICAL_SECTION_ACTIVE=true
    # Block signals that could interrupt critical operations
    trap '' HUP USR1
}

# Exit critical section - restore signal handlers
# Always call this after critical operations complete
exit_critical_section() {
    if [[ "$CRITICAL_SECTION_ACTIVE" != "true" ]]; then
        return 0 # Not in critical section
    fi
    CRITICAL_SECTION_ACTIVE=false
    # Restore signal handlers (only when not running under systemd)
    if [[ -z "${INVOCATION_ID:-}" ]]; then
        trap 'log INFO "Received SIGHUP, reloading configuration"; restart_mediamtx' HUP
        trap 'log INFO "Received SIGUSR1, dumping status"; show_status >/dev/null 2>&1 || log INFO "Status dump completed"' USR1
    fi
}

# Enhanced deferred cleanup handler with staleness check
handle_deferred_cleanup() {
    if [[ -f "${CLEANUP_MARKER}" ]]; then
        log INFO "Handling deferred cleanup from previous termination"

        # Check if marker is stale (>300 seconds old)
        local marker_age
        marker_age="$(($(date +%s) - $(stat -c %Y "${CLEANUP_MARKER}" 2>/dev/null || echo 0)))"

        if [[ $marker_age -gt 300 ]]; then
            log WARN "Cleanup marker is ${marker_age}s old, might be stale"
        fi

        cleanup_stale_processes

        # Verify cleanup completeness
        verify_cleanup_complete

        rm -f "${CLEANUP_MARKER}"
    fi
}

# Verify cleanup completeness
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
    local nullglob_state
    shopt -q nullglob && nullglob_state=on || nullglob_state=off
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
    # Restore nullglob only if it was originally off (avoids redundant shopt -s)
    [[ "$nullglob_state" == "off" ]] && shopt -u nullglob

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

# Release config lock safely
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
        echo "[${timestamp}] [${level}] ${message}" >>"${LOG_FILE}" 2>/dev/null || true

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

# PID file operations with permissions set before atomic move
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
    echo "${pid}" >"$temp_pid" || {
        rm -f "$temp_pid"
        log ERROR "Failed to write PID to temp file"
        return 1
    }

    # Set permissions BEFORE atomic move
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

# Read and validate PID from file
#
# Performs comprehensive validation:
# 1. Checks if file exists
# 2. Reads content (ignoring errors)
# 3. Strips all whitespace
# 4. Validates format: digits only via regex
# 5. Removes leading zeros: 10#$pid (prevents octal interpretation)
# 6. Validates range: 1 to SYSTEM_PID_MAX
# 7. Verifies process exists via kill -0
# 8. Validates process identity to detect PID reuse
#
# Parameters:
#   $1 = Path to PID file
#
# Returns:
#   stdout: Validated PID (numeric string) or empty string
#   exit: Always 0 (errors return empty string, not error code)
#
# Side Effects:
#   - Deletes PID file if content is invalid or process doesn't exist
#   - Logs ERROR for invalid format or out-of-range PID
#   - Logs DEBUG if process not running or identity mismatch
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

    # Validate process identity to detect PID reuse
    # This is a defensive check against the rare case where a PID is recycled
    local proc_cmd
    proc_cmd="$(ps -p "$pid" -o comm= 2>/dev/null || true)"

    if [[ -n "$proc_cmd" ]]; then
        # Check if process matches expected patterns for our services
        # - mediamtx: the main MediaMTX binary
        # - bash: wrapper scripts that manage FFmpeg streams
        # - ffmpeg: FFmpeg processes (though typically tracked via wrapper)
        if [[ "$proc_cmd" != "mediamtx" ]] && [[ "$proc_cmd" != "bash" ]] && [[ "$proc_cmd" != "ffmpeg" ]]; then
            # Process exists but is not one of our expected types
            # This could indicate PID reuse - log and reject
            log DEBUG "PID $pid from $pid_file has unexpected process '$proc_cmd' (possible PID reuse)"
            rm -f "$pid_file"
            echo ""
            return 0
        fi
    fi
    # If proc_cmd is empty, ps failed but kill -0 succeeded
    # This can happen in edge cases, so we accept it (defensive)

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

# Process group termination with recursive descendant finding
terminate_process_group() {
    local pid="$1"
    local timeout="${2:-10}"

    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    # Helper function to recursively find all descendants
    get_descendants() {
        local parent_pid="$1"
        local descendants=""

        # Get immediate children
        local children
        children=$(pgrep -P "$parent_pid" 2>/dev/null || true)

        if [[ -n "$children" ]]; then
            for child in $children; do
                # Add this child
                descendants="$descendants $child"
                # Recursively get this child's descendants
                local child_descendants
                child_descendants=$(get_descendants "$child")
                descendants="$descendants$child_descendants"
            done
        fi

        echo "$descendants"
    }

    # Get all descendants (children, grandchildren, etc.)
    local all_pids
    all_pids=$(get_descendants "$pid")
    all_pids="$pid $all_pids"

    # Try process group first if it exists
    if kill -INT -- -"$pid" 2>/dev/null; then
        log DEBUG "Sent SIGINT to process group $pid"
    else
        # Fall back to individual process
        log DEBUG "Process group not available, sending SIGINT to PID $pid"
        kill -INT "$pid" 2>/dev/null || true
    fi

    # Also kill all descendants explicitly
    for descendant_pid in $all_pids; do
        if [[ "$descendant_pid" != "$pid" ]]; then
            kill -INT "$descendant_pid" 2>/dev/null || true
        fi
    done

    if ! wait_for_pid_termination "$pid" "$timeout"; then
        # Force kill if needed
        if kill -KILL -- -"$pid" 2>/dev/null; then
            log DEBUG "Sent SIGKILL to process group $pid"
        else
            kill -KILL "$pid" 2>/dev/null || true
        fi

        # Force kill all descendants
        for descendant_pid in $all_pids; do
            if [[ "$descendant_pid" != "$pid" ]]; then
                kill -KILL "$descendant_pid" 2>/dev/null || true
            fi
        done

        wait_for_pid_termination "$pid" 2
    fi
}

# Lock management with stale lock detection
# Uses multiple verification methods to prevent PID recycling attacks
is_lock_stale() {
    if [[ ! -f "${LOCK_FILE}" ]]; then
        return 1 # No lock file, not stale
    fi

    # Check if lock file has a PID
    local lock_pid
    lock_pid="$(head -n1 "${LOCK_FILE}" 2>/dev/null | tr -d '[:space:]')"

    if [[ -z "$lock_pid" ]] || ! [[ "$lock_pid" =~ ^[0-9]+$ ]]; then
        log WARN "Lock file exists but contains no valid PID"
        return 0 # Stale
    fi

    # Validate PID is in reasonable range (prevent injection/overflow)
    if [[ ${#lock_pid} -gt 10 ]] || [[ "$lock_pid" -gt 4194304 ]]; then
        log WARN "Lock file contains invalid PID: $lock_pid"
        return 0 # Stale
    fi

    # Check if the process is still running
    if ! kill -0 "$lock_pid" 2>/dev/null; then
        log WARN "Lock file PID $lock_pid is not running"
        return 0 # Stale
    fi

    # Robust PID verification: check /proc/PID/cmdline to prevent PID recycling
    # This is more reliable than ps -p which could return stale data
    if [[ -d "/proc/$lock_pid" ]]; then
        local proc_cmdline
        proc_cmdline=$(tr '\0' ' ' <"/proc/$lock_pid/cmdline" 2>/dev/null || echo "")
        if [[ -n "$proc_cmdline" ]]; then
            # Verify it's actually our script (check for script name in cmdline)
            if [[ "$proc_cmdline" != *"mediamtx-stream-manager"* ]] \
                && [[ "$proc_cmdline" != *"${SCRIPT_NAME}"* ]]; then
                log WARN "Lock file PID $lock_pid is now a different process (PID recycled)"
                log DEBUG "Found cmdline: ${proc_cmdline:0:100}"
                return 0 # Stale - PID was recycled
            fi
        fi
    else
        # /proc entry doesn't exist but kill -0 succeeded - race condition or zombie
        log WARN "Process $lock_pid exists but /proc entry missing"
        return 0 # Stale
    fi

    # Fallback: also check via ps for non-Linux systems
    local proc_cmd
    proc_cmd="$(ps -p "$lock_pid" -o comm= 2>/dev/null || true)"
    if [[ -n "$proc_cmd" ]] && [[ "$proc_cmd" != "bash" ]] && [[ "$proc_cmd" != "${SCRIPT_NAME}" ]]; then
        log WARN "Lock file PID $lock_pid command mismatch (found: $proc_cmd)"
        return 0 # Stale
    fi

    # Check lock file age
    local lock_age
    lock_age="$(($(date +%s) - $(stat -c %Y "${LOCK_FILE}" 2>/dev/null || echo 0)))"
    if [[ $lock_age -gt ${LOCK_STALE_THRESHOLD} ]]; then
        log WARN "Lock file is ${lock_age} seconds old (threshold: ${LOCK_STALE_THRESHOLD})"
        # Additional check: is it really stuck or just long-running?
        if [[ "${CURRENT_COMMAND}" == "start" ]] || [[ "${CURRENT_COMMAND}" == "restart" ]]; then
            return 0 # Consider stale for start/restart
        fi
    fi

    return 1 # Not stale
}

# Acquire exclusive file-based lock with timeout
#
# Acquisition sequence:
# 1. Closes any existing file descriptor
# 2. Creates lock directory if needed
# 3. Checks for stale lock (via is_lock_stale) and removes if stale
# 4. Opens LOCK_FILE and gets file descriptor
# 5. Validates file descriptor > 2
# 6. Calls flock -w with timeout
# 7. Writes current PID to lock file
#
# Lock file deletion:
# - Deleted only if is_lock_stale() returns true (age > threshold AND process dead)
# - NOT deleted on timeout failure (another process legitimately holds lock)
#
# Parameters:
#   $1 = Timeout in seconds (default: LOCK_ACQUISITION_TIMEOUT)
#   $2 = Force flag: "true" or "false" (default: "false")
#        If "true": returns 0 even if lock acquisition fails
#
# Returns:
#   0 = Lock acquired successfully OR force="true"
#   1 = Lock acquisition failed AND force="false"
#
# Side Effects:
#   - Sets global MAIN_LOCK_FD to file descriptor number (or -1 on failure)
#   - Creates LOCK_FILE if doesn't exist
#   - Writes current PID to lock file
#   - May delete lock file if demonstrably stale
#   - Logs DEBUG on success, ERROR/WARN on failure
acquire_lock() {
    local timeout="${1:-${LOCK_ACQUISITION_TIMEOUT}}"
    local force="${2:-false}"

    # Enter critical section to prevent signal handlers from interrupting lock operations
    enter_critical_section

    # Always close existing FD before reuse
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
            exit_critical_section
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
        exit_critical_section
        return 1
    }

    # Validate FD is valid (> 2)
    if [[ ${MAIN_LOCK_FD} -le 2 ]]; then
        log ERROR "Invalid lock file descriptor: ${MAIN_LOCK_FD}"
        MAIN_LOCK_FD=-1
        exit_critical_section
        return 1
    fi

    # Try to acquire lock
    if ! flock -w "$timeout" "${MAIN_LOCK_FD}"; then
        # Enhanced error handling for FD closure failure
        if ! exec {MAIN_LOCK_FD}>&- 2>/dev/null; then
            log WARN "Failed to close lock FD properly during acquisition failure"
        fi
        MAIN_LOCK_FD=-1

        exit_critical_section
        if [[ "$force" == "true" ]]; then
            log WARN "Failed to acquire lock, forcing due to force flag"
            return 0 # Continue anyway
        else
            log ERROR "Failed to acquire lock after ${timeout} seconds"
            return 1
        fi
    fi

    # Write our PID to the lock file
    echo "$$" >&"${MAIN_LOCK_FD}" || true

    # Exit critical section - lock is acquired, safe to allow signals again
    exit_critical_section

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

    # Set directory permissions: rwxr-xr-x (owner write, group/other read+execute)
    chmod 755 "${FFMPEG_PID_DIR}"

    if [[ ! -f "${LOG_FILE}" ]]; then
        touch "${LOG_FILE}"
        # Set log file permissions: rw-r--r-- (owner write, group/other read)
        chmod 644 "${LOG_FILE}"
    fi

    # v1.4.2: Setup audio recording buffer directories if local recording is enabled
    if [[ "${AUDIO_LOCAL_RECORDING}" == "true" ]]; then
        # Create recording directory (default is /dev/shm which is tmpfs/RAM)
        if [[ ! -d "${AUDIO_RECORDING_PATH}" ]]; then
            if mkdir -p "${AUDIO_RECORDING_PATH}" 2>/dev/null; then
                chmod 755 "${AUDIO_RECORDING_PATH}"
                log INFO "Created audio buffer directory: ${AUDIO_RECORDING_PATH}"
            else
                log WARN "Could not create audio buffer directory: ${AUDIO_RECORDING_PATH}"
            fi
        fi

        # If disk persistence is enabled, create disk path
        if [[ "${AUDIO_DISK_PERSIST}" == "true" ]] && [[ ! -d "${AUDIO_DISK_PATH}" ]]; then
            if mkdir -p "${AUDIO_DISK_PATH}" 2>/dev/null; then
                chmod 755 "${AUDIO_DISK_PATH}"
                log INFO "Created disk recording directory: ${AUDIO_DISK_PATH}"
            else
                log WARN "Could not create disk recording directory: ${AUDIO_DISK_PATH}"
            fi
        fi
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

    cat >/etc/logrotate.d/mediamtx <<EOF
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

# ============================================================================
# Production Reliability Functions (v1.4.2)
# ============================================================================

# Check disk space on critical partitions
# Returns: 0 = OK, 1 = warning, 2 = critical
check_disk_space() {
    local check_paths=("/" "/var" "/var/log" "${FFMPEG_PID_DIR}" "${CONFIG_DIR}")
    local critical_found=false
    local warning_found=false

    for check_path in "${check_paths[@]}"; do
        # Skip if path doesn't exist
        [[ -d "$check_path" ]] || continue

        # Get disk usage (portable method)
        local usage_info
        usage_info=$(df -P "$check_path" 2>/dev/null | tail -1) || continue

        local used_percent available_kb
        used_percent=$(echo "$usage_info" | awk '{print $5}' | tr -d '%')
        available_kb=$(echo "$usage_info" | awk '{print $4}')

        # Skip if we couldn't parse the values
        [[ "$used_percent" =~ ^[0-9]+$ ]] || continue
        [[ "$available_kb" =~ ^[0-9]+$ ]] || continue

        local available_mb=$((available_kb / 1024))

        # Check thresholds
        if [[ $used_percent -ge ${DISK_SPACE_CRITICAL_PERCENT} ]] || [[ $available_mb -lt ${DISK_SPACE_MIN_FREE_MB} ]]; then
            log ERROR "Critical: Disk space on $check_path: ${used_percent}% used, ${available_mb}MB free"
            critical_found=true
        elif [[ $used_percent -ge ${DISK_SPACE_WARNING_PERCENT} ]]; then
            log WARN "Warning: Disk space on $check_path: ${used_percent}% used, ${available_mb}MB free"
            warning_found=true
        fi
    done

    if [[ "$critical_found" == "true" ]]; then
        return 2
    elif [[ "$warning_found" == "true" ]]; then
        return 1
    fi
    return 0
}

# Check memory usage with trending for leak detection
# Stores samples over time to detect gradual growth
check_memory_usage() {
    local mediamtx_pid
    mediamtx_pid="$(read_pid_safe "${PID_FILE}")"

    if [[ -z "$mediamtx_pid" ]]; then
        log DEBUG "MediaMTX not running, skipping memory check"
        return 0
    fi

    # Get RSS memory in KB for MediaMTX
    local rss_kb=0
    if [[ -f "/proc/$mediamtx_pid/status" ]]; then
        rss_kb=$(grep "VmRSS:" "/proc/$mediamtx_pid/status" 2>/dev/null | awk '{print $2}' || echo 0)
    fi

    # Get total RSS for all FFmpeg processes
    local ffmpeg_rss=0
    while IFS= read -r pid; do
        if [[ -n "$pid" ]] && [[ -f "/proc/$pid/status" ]]; then
            local pid_rss
            pid_rss=$(grep "VmRSS:" "/proc/$pid/status" 2>/dev/null | awk '{print $2}' || echo 0)
            ffmpeg_rss=$((ffmpeg_rss + pid_rss))
        fi
    done < <(pgrep -f "^ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" 2>/dev/null || true)

    local total_rss_mb=$(((rss_kb + ffmpeg_rss) / 1024))

    # Store sample for trending
    local timestamp
    timestamp=$(date +%s)
    local sample_dir
    sample_dir=$(dirname "${MEM_SAMPLE_FILE}")

    if [[ -d "$sample_dir" ]] || mkdir -p "$sample_dir" 2>/dev/null; then
        echo "${timestamp}:${total_rss_mb}" >> "${MEM_SAMPLE_FILE}" 2>/dev/null || true

        # Keep only last 100 samples
        if [[ -f "${MEM_SAMPLE_FILE}" ]]; then
            tail -100 "${MEM_SAMPLE_FILE}" > "${MEM_SAMPLE_FILE}.tmp" 2>/dev/null \
                && mv "${MEM_SAMPLE_FILE}.tmp" "${MEM_SAMPLE_FILE}" 2>/dev/null || true
        fi

        # Check for memory growth trend (compare first and last sample)
        if [[ -f "${MEM_SAMPLE_FILE}" ]] && [[ $(wc -l < "${MEM_SAMPLE_FILE}") -ge 10 ]]; then
            local first_sample last_sample
            first_sample=$(head -1 "${MEM_SAMPLE_FILE}" | cut -d: -f2)
            last_sample=$(tail -1 "${MEM_SAMPLE_FILE}" | cut -d: -f2)

            if [[ "$first_sample" =~ ^[0-9]+$ ]] && [[ "$last_sample" =~ ^[0-9]+$ ]]; then
                local growth_mb=$((last_sample - first_sample))
                if [[ $growth_mb -gt ${MEM_GROWTH_THRESHOLD_MB} ]]; then
                    log WARN "Memory growth detected: ${growth_mb}MB increase (${first_sample}MB -> ${last_sample}MB)"
                    log WARN "Consider restarting to prevent potential memory leak"
                fi
            fi
        fi
    fi

    log DEBUG "Memory usage: MediaMTX ${rss_kb}KB, FFmpeg ${ffmpeg_rss}KB, Total ${total_rss_mb}MB"

    # Check system memory
    local mem_total mem_available mem_used_percent
    if [[ -f /proc/meminfo ]]; then
        mem_total=$(grep "MemTotal:" /proc/meminfo | awk '{print $2}')
        mem_available=$(grep "MemAvailable:" /proc/meminfo | awk '{print $2}')
        if [[ -n "$mem_total" ]] && [[ -n "$mem_available" ]] && [[ "$mem_total" -gt 0 ]]; then
            mem_used_percent=$(( (mem_total - mem_available) * 100 / mem_total ))

            if [[ $mem_used_percent -ge ${MEM_CRITICAL_PERCENT} ]]; then
                log ERROR "Critical: System memory usage at ${mem_used_percent}%"
                return 2
            elif [[ $mem_used_percent -ge ${MEM_WARNING_PERCENT} ]]; then
                log WARN "Warning: System memory usage at ${mem_used_percent}%"
                return 1
            fi
        fi
    fi

    return 0
}

# Check network connectivity
# Uses gateway ping by default, configurable target
check_network_connectivity() {
    if [[ "${NETWORK_CHECK_ENABLED}" != "true" ]]; then
        return 0
    fi

    local target="${NETWORK_CHECK_TARGET}"

    # Resolve "gateway" to actual gateway IP
    if [[ "$target" == "gateway" ]]; then
        # Try multiple methods to find gateway
        target=$(ip route | grep default | awk '{print $3}' | head -1 2>/dev/null) \
            || target=$(route -n | grep "^0.0.0.0" | awk '{print $2}' | head -1 2>/dev/null) \
            || target=$(netstat -rn | grep "^0.0.0.0" | awk '{print $2}' | head -1 2>/dev/null) \
            || target=""

        if [[ -z "$target" ]]; then
            log DEBUG "Could not determine gateway, skipping network check"
            return 0
        fi
    fi

    # Ping test
    if command_exists ping; then
        if ping -c 1 -W "${NETWORK_CHECK_TIMEOUT}" "$target" >/dev/null 2>&1; then
            log DEBUG "Network connectivity OK (gateway: $target)"
            # Reset failure counter
            echo "0" > /run/mediamtx-network-failures 2>/dev/null || true
            return 0
        else
            # Increment failure counter
            local failures=0
            [[ -f /run/mediamtx-network-failures ]] && failures=$(cat /run/mediamtx-network-failures 2>/dev/null || echo 0)
            failures=$((failures + 1))
            echo "$failures" > /run/mediamtx-network-failures 2>/dev/null || true

            if [[ $failures -ge ${NETWORK_FAIL_THRESHOLD} ]]; then
                log ERROR "Network connectivity lost: $failures consecutive failures to reach $target"
                return 1
            else
                log WARN "Network check failed ($failures/${NETWORK_FAIL_THRESHOLD}): cannot reach $target"
                return 0
            fi
        fi
    fi

    return 0
}

# Detect MediaMTX API version and return appropriate base URL
# Tries v3, v2, v1 in order if auto-detection is enabled
detect_mediamtx_api_version() {
    local host="${MEDIAMTX_HOST:-localhost}"
    local port="${MEDIAMTX_API_PORT:-9997}"
    local base_url="http://${host}:${port}"

    # If version is explicitly set, use it
    if [[ "${MEDIAMTX_API_VERSION}" != "auto" ]]; then
        echo "${base_url}/${MEDIAMTX_API_VERSION}"
        return 0
    fi

    # Auto-detect: try versions in order
    if command_exists curl; then
        for version in v3 v2 v1; do
            local test_url="${base_url}/${version}/paths/list"
            if curl -s --max-time 2 "$test_url" >/dev/null 2>&1; then
                log DEBUG "Detected MediaMTX API version: $version"
                echo "${base_url}/${version}"
                return 0
            fi
        done

        # Fallback: try without version prefix (very old MediaMTX)
        if [[ "${MEDIAMTX_API_FALLBACK}" == "true" ]]; then
            if curl -s --max-time 2 "${base_url}/paths/list" >/dev/null 2>&1; then
                log DEBUG "Using legacy MediaMTX API (no version prefix)"
                echo "${base_url}"
                return 0
            fi
        fi
    fi

    # Default to v3 if detection fails
    log WARN "Could not detect MediaMTX API version, defaulting to v3"
    echo "${base_url}/v3"
    return 0
}

# Check if ALSA device is available before attempting stream restart
# Prevents restart loops when USB device is disconnected
check_alsa_device_available() {
    local card_num="$1"

    if [[ "${USB_ALSA_CHECK_ENABLED}" != "true" ]]; then
        return 0
    fi

    # Check if card exists in ALSA
    if [[ ! -d "/proc/asound/card${card_num}" ]]; then
        log DEBUG "ALSA card ${card_num} not found in /proc/asound"
        return 1
    fi

    # Check if device is accessible
    if command_exists arecord; then
        if ! arecord -l 2>/dev/null | grep -q "card ${card_num}:"; then
            log DEBUG "ALSA card ${card_num} not listed by arecord"
            return 1
        fi
    fi

    # Additional check: verify the device node exists
    local device_path="/dev/snd/pcmC${card_num}D0c"
    if [[ ! -e "$device_path" ]]; then
        log DEBUG "Device node $device_path does not exist"
        return 1
    fi

    return 0
}

# Check audio level for a device to detect dead/silent microphones
# Uses FFmpeg's volumedetect filter to sample audio levels
# Returns: 0 = audio detected, 1 = silence/dead mic, 2 = check failed
check_audio_level() {
    local card_num="$1"
    local stream_name="${2:-unknown}"

    if [[ "${AUDIO_LEVEL_CHECK_ENABLED}" != "true" ]]; then
        return 0
    fi

    # Verify FFmpeg is available
    if ! command_exists ffmpeg; then
        log DEBUG "FFmpeg not available for audio level check"
        return 0
    fi

    local audio_device="plughw:${card_num},0"
    local sample_duration="${AUDIO_LEVEL_SAMPLE_DURATION}"
    local silence_threshold="${AUDIO_SILENCE_THRESHOLD_DB}"

    log DEBUG "Checking audio level for $stream_name (device: $audio_device)"

    # Use FFmpeg to sample audio and detect volume
    # -t limits duration, volumedetect filter outputs max/mean volume
    local ffmpeg_output
    ffmpeg_output=$(ffmpeg -f alsa -i "$audio_device" -t "$sample_duration" \
        -af volumedetect -f null /dev/null 2>&1) || {
        log DEBUG "FFmpeg audio level check failed for $stream_name"
        return 2
    }

    # Parse max volume from output (format: "max_volume: -XX.X dB")
    local max_volume
    max_volume=$(echo "$ffmpeg_output" | grep -o "max_volume: [0-9.-]*" | grep -o "[0-9.-]*" | head -1)

    if [[ -z "$max_volume" ]]; then
        log DEBUG "Could not parse audio level for $stream_name"
        return 2
    fi

    # Compare with threshold (both are negative dB values)
    # Note: -30 dB is louder than -60 dB, so we check if max > threshold
    local max_int="${max_volume%.*}"  # Remove decimal for integer comparison
    local threshold_int="${silence_threshold%.*}"

    if [[ $max_int -lt $threshold_int ]]; then
        log WARN "Silence detected on $stream_name: max volume ${max_volume} dB (threshold: ${silence_threshold} dB)"

        # Track silence duration
        local silence_file="/run/mediamtx-silence-${stream_name}"
        local silence_start
        if [[ -f "$silence_file" ]]; then
            silence_start=$(cat "$silence_file" 2>/dev/null || echo "0")
        else
            silence_start=$(date +%s)
            echo "$silence_start" > "$silence_file" 2>/dev/null || true
        fi

        local now
        now=$(date +%s)
        local silence_duration=$((now - silence_start))

        if [[ $silence_duration -ge ${AUDIO_SILENCE_WARN_DURATION} ]]; then
            log ERROR "DEAD MIC: $stream_name has been silent for ${silence_duration}s (>${AUDIO_SILENCE_WARN_DURATION}s)"
        fi

        return 1
    else
        # Audio detected - clear silence tracking
        rm -f "/run/mediamtx-silence-${stream_name}" 2>/dev/null || true
        log DEBUG "Audio level OK for $stream_name: max volume ${max_volume} dB"
        return 0
    fi
}

# Check all streams for audio levels
check_all_audio_levels() {
    if [[ "${AUDIO_LEVEL_CHECK_ENABLED}" != "true" ]]; then
        return 0
    fi

    local devices=()
    readarray -t devices < <(detect_audio_devices 2>/dev/null) || return 0

    local silent_count=0
    for device_info in "${devices[@]}"; do
        IFS=':' read -r device_name card_num <<<"$device_info"
        [[ -z "$device_name" ]] || [[ -z "$card_num" ]] && continue

        local stream_path
        stream_path="$(generate_stream_path "$device_name" "$card_num" 2>/dev/null)" || continue

        if ! check_audio_level "$card_num" "$stream_path"; then
            ((silent_count++))
        fi
    done

    if [[ $silent_count -gt 0 ]]; then
        log WARN "Audio level check: $silent_count device(s) with silence detected"
        return 1
    fi

    return 0
}

# Validate configuration file syntax
validate_config() {
    local config_file="${1:-${DEVICE_CONFIG_FILE}}"

    if [[ ! -f "$config_file" ]]; then
        log DEBUG "Config file $config_file does not exist (using defaults)"
        return 0
    fi

    # Check for basic shell syntax errors
    if ! bash -n "$config_file" 2>/dev/null; then
        log ERROR "Configuration file $config_file has syntax errors"
        return 1
    fi

    # Source in subshell to check for errors
    if ! (source "$config_file" 2>/dev/null); then
        log ERROR "Configuration file $config_file failed to source"
        return 1
    fi

    log DEBUG "Configuration file $config_file validated successfully"
    return 0
}

# Watchdog heartbeat - writes timestamp to heartbeat file
# Can be used by external watchdog or systemd WatchdogSec
update_heartbeat() {
    local timestamp
    timestamp=$(date +%s)

    # Ensure directory exists
    local heartbeat_dir
    heartbeat_dir=$(dirname "${HEARTBEAT_FILE}")
    [[ -d "$heartbeat_dir" ]] || mkdir -p "$heartbeat_dir" 2>/dev/null || true

    # Write timestamp atomically
    echo "$timestamp" > "${HEARTBEAT_FILE}.tmp" 2>/dev/null \
        && mv "${HEARTBEAT_FILE}.tmp" "${HEARTBEAT_FILE}" 2>/dev/null \
        || true

    # Notify systemd watchdog if running under systemd
    if [[ -n "${NOTIFY_SOCKET:-}" ]] && command_exists systemd-notify; then
        systemd-notify WATCHDOG=1 2>/dev/null || true
    fi

    # Kick hardware watchdog if enabled
    kick_hardware_watchdog
}

# Initialize hardware watchdog (graceful - never blocks if unavailable)
init_hardware_watchdog() {
    # Check if hardware watchdog should be enabled
    case "${ENABLE_HARDWARE_WATCHDOG}" in
        no|false|0)
            log DEBUG "Hardware watchdog disabled by configuration"
            return 0
            ;;
        yes|true|1)
            # Explicitly enabled - warn if not available
            if [[ ! -c "${HARDWARE_WATCHDOG_DEVICE}" ]]; then
                log WARN "Hardware watchdog enabled but device ${HARDWARE_WATCHDOG_DEVICE} not found"
                return 0
            fi
            ;;
        auto|*)
            # Auto-detect - silently skip if not available
            if [[ ! -c "${HARDWARE_WATCHDOG_DEVICE}" ]]; then
                log DEBUG "Hardware watchdog not available (auto-detect)"
                return 0
            fi
            ;;
    esac

    # Try to set watchdog timeout (requires root)
    if [[ -w "${HARDWARE_WATCHDOG_DEVICE}" ]]; then
        # Note: This uses the magic close feature - we just write to keep it alive
        # The timeout is typically set in kernel/firmware
        log INFO "Hardware watchdog initialized at ${HARDWARE_WATCHDOG_DEVICE}"
        export HARDWARE_WATCHDOG_ACTIVE=true
    else
        log DEBUG "Hardware watchdog device not writable (may require root)"
        export HARDWARE_WATCHDOG_ACTIVE=false
    fi

    return 0
}

# Kick hardware watchdog to prevent system reset
kick_hardware_watchdog() {
    if [[ "${HARDWARE_WATCHDOG_ACTIVE:-false}" != "true" ]]; then
        return 0
    fi

    # Write any character to the watchdog device to kick it
    if [[ -w "${HARDWARE_WATCHDOG_DEVICE}" ]]; then
        echo "1" > "${HARDWARE_WATCHDOG_DEVICE}" 2>/dev/null || true
    fi
}

# Version compatibility check
# Verifies that lyrebird-common.sh meets minimum version requirements
check_version_compatibility() {
    # Check if lyrebird-common.sh provides version
    if declare -f lyrebird_common_version >/dev/null 2>&1; then
        local common_version
        common_version=$(lyrebird_common_version 2>/dev/null || echo "0.0.0")

        # Simple version comparison (major.minor.patch)
        local required="${MIN_COMPATIBLE_COMMON_VERSION}"
        local IFS='.'
        read -ra req_parts <<< "$required"
        read -ra cur_parts <<< "$common_version"

        for i in 0 1 2; do
            local req_num="${req_parts[$i]:-0}"
            local cur_num="${cur_parts[$i]:-0}"

            if [[ $cur_num -lt $req_num ]]; then
                log WARN "lyrebird-common.sh version $common_version is older than required $required"
                return 1
            elif [[ $cur_num -gt $req_num ]]; then
                break
            fi
        done
    fi

    return 0
}

# Enhanced resource check that includes all new monitoring
check_all_resources() {
    local issues=0
    local critical=false

    # Original resource check
    if ! check_resource_usage; then
        critical=true
    fi

    # Disk space check
    local disk_result
    check_disk_space
    disk_result=$?
    if [[ $disk_result -eq 2 ]]; then
        critical=true
    fi
    [[ $disk_result -ne 0 ]] && ((issues++))

    # Memory check
    local mem_result
    check_memory_usage
    mem_result=$?
    if [[ $mem_result -eq 2 ]]; then
        critical=true
    fi
    [[ $mem_result -ne 0 ]] && ((issues++))

    # Network check
    if ! check_network_connectivity; then
        ((issues++))
    fi

    # Update heartbeat to show we're alive
    update_heartbeat

    if [[ "$critical" == "true" ]]; then
        return ${E_CRITICAL_RESOURCE}
    elif [[ $issues -gt 0 ]]; then
        return 1
    fi

    return 0
}

# Detect if running from cron using multi-method detection
is_cron_context() {
    # Multi-method cron detection for maximum reliability

    # Method 1: Check explicit CRON environment variable (most reliable)
    if [[ "${CRON:-0}" == "1" ]]; then
        return 0
    fi

    # Method 2: Check if stdin/stdout are not terminals (typical cron behavior)
    if [[ ! -t 0 ]] && [[ ! -t 1 ]] && [[ -z "${TERM:-}" ]]; then
        # Additional check: not in SSH session (which also has non-tty)
        if [[ -z "${SSH_CLIENT:-}" ]] && [[ -z "${SSH_TTY:-}" ]]; then
            # Check parent process name contains cron-related strings
            local parent_cmd
            parent_cmd="$(ps -o comm= -p $PPID 2>/dev/null || true)"
            if [[ "$parent_cmd" =~ cron|CRON|anacron ]]; then
                return 0
            fi
        fi
    fi

    # Method 3: Check systemd cgroup (systemd-based cron only)
    if [[ -f /proc/self/cgroup ]]; then
        if grep -qE "cron\.service|cronie\.service" /proc/self/cgroup 2>/dev/null; then
            return 0
        fi
    fi

    # Method 4: Check parent process name directly
    if [[ -f /proc/$PPID/comm ]]; then
        local parent_comm
        parent_comm="$(cat /proc/$PPID/comm 2>/dev/null || true)"
        if [[ "$parent_comm" =~ ^(cron|crond|anacron)$ ]]; then
            return 0
        fi
    fi

    return 1
}

# Stream health monitoring with automatic restart
monitor_streams() {
    log INFO "Checking stream health..."

    # First check if MediaMTX is running
    local mediamtx_pid
    mediamtx_pid="$(read_pid_safe "${PID_FILE}")"

    if [[ -z "$mediamtx_pid" ]] || ! kill -0 "$mediamtx_pid" 2>/dev/null; then
        log WARN "MediaMTX is not running - skipping stream health check"
        log INFO "Run 'start' command to start MediaMTX and streams"
        return "${E_MEDIAMTX_DOWN}"
    fi

    # Detect if running from cron - if so, report only, don't restart
    local allow_restart=true
    if is_cron_context; then
        allow_restart=false
        log DEBUG "Running from cron - report-only mode (no stream restarts)"
    fi

    # Get current devices
    local devices=()
    readarray -t devices < <(detect_audio_devices)

    if [[ ${#devices[@]} -eq 0 ]]; then
        log WARN "No USB audio devices detected"
        return "${E_USB_NO_DEVICES}"
    fi

    local streams_healthy=0
    local streams_restarted=0
    local streams_failed=0
    local streams_checked=0

    # Handle multiplex mode health monitoring
    if [[ "${STREAM_MODE}" == "multiplex" ]]; then
        ((streams_checked++)) || true

        # Sanitize stream name (same logic as start_ffmpeg_multiplex_stream)
        local stream_path
        stream_path="$(sanitize_path_name "${MULTIPLEX_STREAM_NAME}")"
        if [[ "$stream_path" =~ ^[0-9] ]]; then
            stream_path="stream_${stream_path}"
        fi

        local pid_file="${FFMPEG_PID_DIR}/${stream_path}.pid"

        # Check if PID file exists
        if [[ ! -f "$pid_file" ]]; then
            if [[ "$allow_restart" == "true" ]]; then
                log WARN "Multiplex stream $stream_path has no PID file - restarting"
                if start_ffmpeg_multiplex_stream "${devices[@]}"; then
                    ((streams_restarted++)) || true
                    log INFO "Successfully restarted multiplex stream $stream_path"
                else
                    ((streams_failed++)) || true
                    log ERROR "Failed to restart multiplex stream $stream_path"
                fi
            else
                ((streams_failed++)) || true
                log WARN "Multiplex stream $stream_path has no PID file (cron mode: not restarting)"
            fi
        else
            # Check if process is running
            local pid
            pid="$(read_pid_safe "$pid_file")"

            if [[ -z "$pid" ]]; then
                if [[ "$allow_restart" == "true" ]]; then
                    log WARN "Multiplex stream $stream_path PID is invalid - restarting"
                    if start_ffmpeg_multiplex_stream "${devices[@]}"; then
                        ((streams_restarted++)) || true
                        log INFO "Successfully restarted multiplex stream $stream_path"
                    else
                        ((streams_failed++)) || true
                        log ERROR "Failed to restart multiplex stream $stream_path"
                    fi
                else
                    ((streams_failed++)) || true
                    log WARN "Multiplex stream $stream_path PID is invalid (cron mode: not restarting)"
                fi
            elif ! pgrep -f "${FFMPEG_PID_DIR}/${stream_path}.sh" | grep -q "^${pid}$" 2>/dev/null; then
                if [[ "$allow_restart" == "true" ]]; then
                    log WARN "Multiplex stream $stream_path PID $pid is stale - restarting"
                    rm -f "$pid_file"
                    if start_ffmpeg_multiplex_stream "${devices[@]}"; then
                        ((streams_restarted++)) || true
                        log INFO "Successfully restarted multiplex stream $stream_path"
                    else
                        ((streams_failed++)) || true
                        log ERROR "Failed to restart multiplex stream $stream_path"
                    fi
                else
                    ((streams_failed++)) || true
                    log WARN "Multiplex stream $stream_path PID $pid is stale (cron mode: not restarting)"
                fi
            else
                ((streams_healthy++)) || true
                log DEBUG "Multiplex stream $stream_path is healthy (PID: $pid)"
            fi
        fi
    else
        # Individual mode: check each stream
        for device_info in "${devices[@]}"; do
            IFS=':' read -r device_name card_num <<<"$device_info"

            if [[ -z "$device_name" ]] || [[ -z "$card_num" ]]; then
                continue
            fi

            local stream_path
            stream_path="$(generate_stream_path "$device_name" "$card_num")"
            local pid_file="${FFMPEG_PID_DIR}/${stream_path}.pid"

            ((streams_checked++)) || true

            # Check if PID file exists
            if [[ ! -f "$pid_file" ]]; then
                if [[ "$allow_restart" == "true" ]]; then
                    # v1.4.2: Check ALSA device availability before restart
                    if ! check_alsa_device_available "$card_num"; then
                        log WARN "Stream $stream_path: ALSA device not available (card $card_num), skipping restart"
                        ((streams_failed++)) || true
                        continue
                    fi
                    log WARN "Stream $stream_path has no PID file - restarting"
                    if start_ffmpeg_stream "$device_name" "$card_num" "$stream_path"; then
                        ((streams_restarted++)) || true
                        log INFO "Successfully restarted stream $stream_path"
                    else
                        ((streams_failed++)) || true
                        log ERROR "Failed to restart stream $stream_path"
                    fi
                else
                    ((streams_failed++)) || true
                    log WARN "Stream $stream_path has no PID file (cron mode: not restarting)"
                fi
                continue
            fi

            # Check if process is running
            local pid
            pid="$(read_pid_safe "$pid_file")"

            if [[ -z "$pid" ]]; then
                if [[ "$allow_restart" == "true" ]]; then
                    # v1.4.2: Check ALSA device availability before restart
                    if ! check_alsa_device_available "$card_num"; then
                        log WARN "Stream $stream_path: ALSA device not available (card $card_num), skipping restart"
                        ((streams_failed++)) || true
                        continue
                    fi
                    log WARN "Stream $stream_path PID is invalid - restarting"
                    if start_ffmpeg_stream "$device_name" "$card_num" "$stream_path"; then
                        ((streams_restarted++)) || true
                        log INFO "Successfully restarted stream $stream_path"
                    else
                        ((streams_failed++)) || true
                        log ERROR "Failed to restart stream $stream_path"
                    fi
                else
                    ((streams_failed++)) || true
                    log WARN "Stream $stream_path PID is invalid (cron mode: not restarting)"
                fi
                continue
            fi

            # Verify the PID actually belongs to our wrapper
            if ! pgrep -f "${FFMPEG_PID_DIR}/${stream_path}.sh" | grep -q "^${pid}$" 2>/dev/null; then
                if [[ "$allow_restart" == "true" ]]; then
                    # v1.4.2: Check ALSA device availability before restart
                    if ! check_alsa_device_available "$card_num"; then
                        log WARN "Stream $stream_path: ALSA device not available (card $card_num), skipping restart"
                        ((streams_failed++)) || true
                        continue
                    fi
                    log WARN "Stream $stream_path PID $pid is stale - restarting"
                    rm -f "$pid_file"
                    if start_ffmpeg_stream "$device_name" "$card_num" "$stream_path"; then
                        ((streams_restarted++)) || true
                        log INFO "Successfully restarted stream $stream_path"
                    else
                        ((streams_failed++)) || true
                        log ERROR "Failed to restart stream $stream_path"
                    fi
                else
                    ((streams_failed++)) || true
                    log WARN "Stream $stream_path PID $pid is stale (cron mode: not restarting)"
                fi
                continue
            fi

            ((streams_healthy++)) || true
            log DEBUG "Stream $stream_path is healthy (PID: $pid)"
        done
    fi

    # Provide accurate summary
    if [[ $streams_failed -gt 0 ]]; then
        if [[ $streams_restarted -gt 0 ]]; then
            log WARN "Stream health check complete: $streams_healthy healthy, $streams_restarted restarted, $streams_failed FAILED (total: $streams_checked)"
        else
            log ERROR "Stream health check complete: $streams_healthy healthy, $streams_failed FAILED (total: $streams_checked)"
        fi
    elif [[ $streams_restarted -gt 0 ]]; then
        log INFO "Stream health check complete: $streams_healthy healthy, $streams_restarted restarted (total: $streams_checked)"
    else
        log INFO "Stream health check complete: all $streams_checked streams healthy"
    fi

    # Return appropriate exit code based on monitoring results
    if [[ -z "$mediamtx_pid" ]] || ! kill -0 "$mediamtx_pid" 2>/dev/null; then
        # MediaMTX not running - critical failure already logged
        return "${E_MEDIAMTX_DOWN}"
    elif [[ $streams_failed -gt 0 ]]; then
        # Some streams failed - degraded state
        return "${E_MONITOR_DEGRADED}"
    else
        # All healthy
        return 0
    fi
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
        # v1.4.2: Use API version detection for compatibility
        if command_exists curl; then
            local api_base
            api_base=$(detect_mediamtx_api_version)
            local api_url="${api_base}/paths/get/${stream_path}"
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
        marker_age="$(($(date +%s) - $(stat -c %Y "${RESTART_MARKER}" 2>/dev/null || echo 0)))"
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

# Clean up all processes and temporary files
#
# Execution order (as implemented):
# 1. Wrapper processes (via PID files in FFMPEG_PID_DIR)
#    - Calls terminate_process_group with 5s timeout
#    - Deletes PID files
# 2. Orphaned FFmpeg processes (via pgrep pattern match)
#    - Matches: ^ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554
#    - Calls terminate_process_group with 2s timeout
# 3. MediaMTX process (via PID_FILE)
#    - Calls terminate_process_group with 5s timeout
#    - Deletes PID file
# 4. MediaMTX processes using our config (via pgrep pattern match)
#    - Matches: ^${MEDIAMTX_BIN}.*${CONFIG_FILE}$
#    - Calls terminate_process_group with 2s timeout
# 5. Temporary files
#    - Deletes: *.pid, *.sh, *.log, *.log.old from FFMPEG_PID_DIR
# 6. Marker files
#    - Deletes: CLEANUP_MARKER, RESTART_MARKER, CONFIG_LOCK_FILE
#
# Parameters: None
#
# Returns: 0 (always - best-effort cleanup)
#
# Side Effects:
#   - Terminates processes (wrappers, FFmpeg, MediaMTX)
#   - Deletes files (PID files, scripts, logs, markers)
#   - Modifies nullglob shell option (saves and restores state)
#   - Logs INFO at start and completion, DEBUG for each operation
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

    # Restore nullglob only if it was originally off (avoids redundant shopt -s)
    [[ "$nullglob_state" == "off" ]] && shopt -u nullglob

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
        ((elapsed += 2))
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
            # v1.4.2: Try multiple API versions for compatibility
            for api_version in v3 v2 v1 ""; do
                local test_url="http://${MEDIAMTX_HOST}:9997/${api_version:+$api_version/}paths/list"
                if curl -s --max-time 2 "$test_url" >/dev/null 2>&1; then
                    log INFO "MediaMTX API is ready after ${elapsed} seconds (API: ${api_version:-legacy})"
                    return 0
                fi
            done
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

    cat >"$tmp_config" <<'EOF'
# Audio device configuration
# Format: DEVICE_<name>_<parameter>=value
#
# You can use either:
#   1. Friendly stream names (e.g., DEVICE_BLUE_YETI_SAMPLE_RATE=44100)
#   2. Full device names (e.g., DEVICE_USB_AUDIO_BLUE_YETI_SAMPLE_RATE=44100)
#
# Friendly names are recommended and match the RTSP stream paths.

# Universal defaults:
# - Sample Rate: 48000 Hz
# - Channels: 2 (stereo)
# - Format: s16le (16-bit little-endian)
# - Codec: opus
# - Bitrate: 128k

# Example overrides using friendly names:
# DEVICE_BLUE_YETI_SAMPLE_RATE=44100
# DEVICE_BLUE_YETI_CHANNELS=1
# DEVICE_BLUE_YETI_CODEC=pcm_s16le
# DEVICE_BLUE_YETI_BITRATE=256k
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

# Sanitize device name for RTSP path usage
#
# Transformation sequence:
# 1. Strips prefixes: "usb-audio-" and "usb_audio_"
# 2. Converts to lowercase
# 3. Replaces non-alphanumeric characters with underscore
# 4. Collapses multiple consecutive underscores to single underscore
# 5. Removes leading and trailing underscores
# 6. If result is empty: generates "stream_$(date +%s)"
# 7. If matches reserved words: prefixes with "stream_"
# 8. If exceeds MAX_STREAM_NAME_LENGTH: truncates and appends 8-char hash
# 9. If below MIN_STREAM_NAME_LENGTH: replaces with "stream_$(date +%s)"
#
# Parameters:
#   $1 = Raw device name (e.g., "USB Audio Device #1")
#
# Returns:
#   stdout: Sanitized path name (lowercase alphanumeric + underscore only)
#   exit: 0 (always)
#
# Examples (observable from code logic):
#   "USB Audio Device" -> "usb_audio_device"
#   "Device-123" -> "device_123"
#   "   " (spaces only) -> "stream_1699564821" (timestamp fallback)
#   Reserved word -> "stream_<reserved>" (prefixed)
#   Very long name -> "truncated_name_a1b2c3d4" (with hash)
sanitize_path_name() {
    local name="$1"
    name="${name#usb-audio-}"
    name="${name#usb_audio_}"
    local sanitized
    sanitized="$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^0-9a-z]/_/g' | sed 's/__*/_/g' | sed 's/^_*//;s/_*$//')"

    # Generate fallback if empty
    if [[ -z "$sanitized" ]]; then
        sanitized="stream_$(date +%s)"
    fi

    # Check reserved words
    if [[ "$sanitized" =~ ^(${RESERVED_STREAM_NAMES})$ ]]; then
        log WARN "Stream name '$sanitized' is reserved, adding prefix"
        sanitized="stream_${sanitized}"
    fi

    # Enforce length limits
    if [[ ${#sanitized} -gt $MAX_STREAM_NAME_LENGTH ]]; then
        local hash
        hash="$(echo -n "$sanitized" | md5sum | cut -c1-8)"
        sanitized="${sanitized:0:$((MAX_STREAM_NAME_LENGTH - 9))}_${hash}"
        log DEBUG "Truncated long stream name to: $sanitized"
    fi

    if [[ ${#sanitized} -lt $MIN_STREAM_NAME_LENGTH ]]; then
        sanitized="stream_$(date +%s)"
        log WARN "Stream name too short, using fallback: $sanitized"
    fi

    echo "$sanitized"
}

get_device_config() {
    local device_name="$1"
    local param="$2"
    local default_value="$3"
    local stream_path="${4:-}" # Optional friendly stream path

    local config_value=""

    # Strategy 1: Try friendly stream name first (if provided)
    if [[ -n "$stream_path" ]]; then
        local friendly_name
        friendly_name="$(sanitize_device_name "$stream_path")"
        local friendly_key="DEVICE_${friendly_name^^}_${param^^}"

        if [[ -n "${!friendly_key+x}" ]]; then
            config_value="${!friendly_key}"
        fi
    fi

    # Strategy 2: Fall back to full device name
    if [[ -z "$config_value" ]]; then
        local safe_name
        safe_name="$(sanitize_device_name "$device_name")"
        local device_key="DEVICE_${safe_name^^}_${param^^}"

        if [[ -n "${!device_key+x}" ]]; then
            config_value="${!device_key}"
        fi
    fi

    # Strategy 3: Return default if no match
    if [[ -z "$config_value" ]]; then
        config_value="$default_value"
    fi

    echo "$config_value"
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
        done </proc/asound/cards
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

    # Sanitize stream name to prevent RTSP URL parsing failures
    local stream_path
    stream_path="$(sanitize_path_name "${MULTIPLEX_STREAM_NAME}")"

    # Ensure stream name doesn't start with a digit
    if [[ "$stream_path" =~ ^[0-9] ]]; then
        stream_path="stream_${stream_path}"
    fi

    # Validate final stream name
    if [[ ${#stream_path} -gt $MAX_STREAM_NAME_LENGTH ]]; then
        log ERROR "Stream name too long after sanitization: $stream_path (max: $MAX_STREAM_NAME_LENGTH)"
        return 1
    fi

    if [[ "$stream_path" =~ ^(${RESERVED_STREAM_NAMES})$ ]]; then
        log ERROR "Stream name '$stream_path' conflicts with reserved MediaMTX path"
        return 1
    fi

    local pid_file="${FFMPEG_PID_DIR}/${stream_path}.pid"

    # Check if already running
    if [[ -f "$pid_file" ]]; then
        local existing_pid
        existing_pid="$(read_pid_safe "$pid_file")"
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            # Verify PID actually belongs to our wrapper script
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
        IFS=':' read -r device_name card_num <<<"$device_info"

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
    sample_rate="$(get_device_config "$first_device" "SAMPLE_RATE" "$DEFAULT_SAMPLE_RATE" "$stream_path")"
    channels="$(get_device_config "$first_device" "CHANNELS" "$DEFAULT_CHANNELS" "$stream_path")"
    codec="$(get_device_config "$first_device" "CODEC" "$DEFAULT_CODEC" "$stream_path")"
    bitrate="$(get_device_config "$first_device" "BITRATE" "$DEFAULT_BITRATE" "$stream_path")"
    thread_queue="$(get_device_config "$first_device" "THREAD_QUEUE" "$DEFAULT_THREAD_QUEUE" "$stream_path")"

    # Create wrapper script
    local wrapper_script="${FFMPEG_PID_DIR}/${stream_path}.sh"
    local ffmpeg_log="${FFMPEG_PID_DIR}/${stream_path}.log"

    # Create wrapper with all variables properly quoted
    cat >"$wrapper_script" <<'WRAPPER_START'
#!/bin/bash
set -euo pipefail

# Ensure PATH includes common binary locations
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

WRAPPER_START

    # Write configuration variables
    cat >>"$wrapper_script" <<EOF
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
MAX_CONSECUTIVE_FAILURES=$MAX_CONSECUTIVE_FAILURES
MAX_WRAPPER_RESTARTS=$MAX_WRAPPER_RESTARTS
WRAPPER_SUCCESS_DURATION=$WRAPPER_SUCCESS_DURATION
RESTART_DELAY=$INITIAL_RESTART_DELAY
FFMPEG_LOG_MAX_SIZE=$FFMPEG_LOG_MAX_SIZE

# Device arrays (initialized empty, populated below)
declare -a CARD_NUMBERS=()
declare -a DEVICE_NAMES=()

FFMPEG_PID=""
MAIN_SCRIPT_PID="$$"
EOF

    # Populate arrays with proper quoting to handle spaces in device names
    for i in "${!card_numbers[@]}"; do
        cat >>"$wrapper_script" <<EOF
CARD_NUMBERS+=("${card_numbers[$i]}")
DEVICE_NAMES+=("${device_names[$i]}")
EOF
    done

    # Add device count after arrays are populated
    cat >>"$wrapper_script" <<EOF

# Number of devices
NUM_DEVICES=${#valid_devices[@]}
EOF

    # Add the wrapper logic
    cat >>"$wrapper_script" <<'WRAPPER_LOGIC'

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
    
    # Rotate log if exceeds size limit to prevent disk exhaustion
    if [[ -f "${FFMPEG_LOG}" ]]; then
        local current_size
        current_size=$(stat -c %s "${FFMPEG_LOG}" 2>/dev/null || echo 0)
        if (( current_size > FFMPEG_LOG_MAX_SIZE )); then
            log_message "Rotating FFmpeg log (current size: ${current_size} bytes, max: ${FFMPEG_LOG_MAX_SIZE})"
            mv -f "${FFMPEG_LOG}" "${FFMPEG_LOG}.old" 2>/dev/null || true
            # Note: FFmpeg will automatically create new log file on next write
        fi
    fi
    
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
    if [[ -n "${MAIN_SCRIPT_PID}" ]] && [[ "${MAIN_SCRIPT_PID}" -gt 1 ]]; then
        if ! kill -0 "${MAIN_SCRIPT_PID}" 2>/dev/null; then
            log_message "Main script (PID ${MAIN_SCRIPT_PID}) has terminated, exiting"
            return 1
        fi
    fi
    return 0
}

# Log startup
log_critical "Multiplex stream wrapper starting for ${STREAM_PATH} with ${NUM_DEVICES} devices"
log_message "Wrapper PID: $$, Main script PID: ${MAIN_SCRIPT_PID}"
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
        # Protect against integer overflow in restart delay
        if (( RESTART_DELAY <= 0 )) || (( RESTART_DELAY > MAX_RESTART_DELAY )); then
            RESTART_DELAY=$INITIAL_RESTART_DELAY
        else
            RESTART_DELAY=$((RESTART_DELAY * 2))
            if (( RESTART_DELAY > MAX_RESTART_DELAY )); then
                RESTART_DELAY=$MAX_RESTART_DELAY
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
        RESTART_DELAY=$INITIAL_RESTART_DELAY
        log_message "Successful run, reset delay to ${RESTART_DELAY}s"
    else
        ((CONSECUTIVE_FAILURES++))
        # Protect against integer overflow in restart delay
        if (( RESTART_DELAY <= 0 )) || (( RESTART_DELAY > MAX_RESTART_DELAY )); then
            RESTART_DELAY=$INITIAL_RESTART_DELAY
        else
            RESTART_DELAY=$((RESTART_DELAY * 2))
            if (( RESTART_DELAY > MAX_RESTART_DELAY )); then
                RESTART_DELAY=$MAX_RESTART_DELAY
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
        return 1
    fi

    # Write wrapper PID atomically
    if ! write_pid_atomic "$wrapper_pid" "$pid_file"; then
        log ERROR "Failed to write multiplex wrapper PID"
        kill -TERM "$wrapper_pid" 2>/dev/null || true
        return 1
    fi

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
            # Verify PID actually belongs to our wrapper script
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
    sample_rate="$(get_device_config "$device_name" "SAMPLE_RATE" "$DEFAULT_SAMPLE_RATE" "$stream_path")"
    channels="$(get_device_config "$device_name" "CHANNELS" "$DEFAULT_CHANNELS" "$stream_path")"
    codec="$(get_device_config "$device_name" "CODEC" "$DEFAULT_CODEC" "$stream_path")"
    bitrate="$(get_device_config "$device_name" "BITRATE" "$DEFAULT_BITRATE" "$stream_path")"
    thread_queue="$(get_device_config "$device_name" "THREAD_QUEUE" "$DEFAULT_THREAD_QUEUE" "$stream_path")"

    log INFO "Starting FFmpeg for $stream_path (device: $device_name, card: $card_num)"

    # Create wrapper script
    local wrapper_script="${FFMPEG_PID_DIR}/${stream_path}.sh"
    local ffmpeg_log="${FFMPEG_PID_DIR}/${stream_path}.log"

    # Create wrapper with all variables properly quoted
    cat >"$wrapper_script" <<'WRAPPER_START'
#!/bin/bash
set -euo pipefail

# Ensure PATH includes common binary locations
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

WRAPPER_START

    # Write configuration variables
    cat >>"$wrapper_script" <<EOF
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

# Parent process tracking - use main script PID, not immediate parent
MAIN_SCRIPT_PID="$$"

# Restart configuration
RESTART_COUNT=0
CONSECUTIVE_FAILURES=0
MAX_CONSECUTIVE_FAILURES=$MAX_CONSECUTIVE_FAILURES
MAX_WRAPPER_RESTARTS=$MAX_WRAPPER_RESTARTS
WRAPPER_SUCCESS_DURATION=$WRAPPER_SUCCESS_DURATION
RESTART_DELAY=$INITIAL_RESTART_DELAY
FFMPEG_LOG_MAX_SIZE=$FFMPEG_LOG_MAX_SIZE

# Audio buffering configuration
AUDIO_BUFFER_ENABLED="${AUDIO_BUFFER_ENABLED}"
AUDIO_RTBUFSIZE="${AUDIO_RTBUFSIZE}"
AUDIO_LOCAL_RECORDING="${AUDIO_LOCAL_RECORDING}"
AUDIO_RECORDING_PATH="${AUDIO_RECORDING_PATH}"
AUDIO_RECORDING_SEGMENT_TIME="${AUDIO_RECORDING_SEGMENT_TIME}"
AUDIO_RECORDING_SEGMENTS="${AUDIO_RECORDING_SEGMENTS}"

FFMPEG_PID=""
EOF

    # Add the wrapper logic
    cat >>"$wrapper_script" <<'WRAPPER_LOGIC'

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
    )

    # v1.4.2: Add memory buffering if enabled (reduces data loss on restart)
    if [[ "${AUDIO_BUFFER_ENABLED}" == "true" ]]; then
        ffmpeg_cmd+=(-rtbufsize "${AUDIO_RTBUFSIZE}")
        log_message "Memory buffering enabled: ${AUDIO_RTBUFSIZE} bytes"
    fi

    # Add input options
    ffmpeg_cmd+=(
        -f alsa
        -ar "${SAMPLE_RATE}"
        -ac "${CHANNELS}"
        -thread_queue_size "${THREAD_QUEUE}"
        -i "${audio_device}"
        -af "aresample=async=1:first_pts=0"
    )

    # Add codec options based on codec type
    local codec_opts=()
    case "${CODEC}" in
        opus)
            codec_opts=(-c:a libopus -b:a "${BITRATE}" -application audio)
            ;;
        aac)
            codec_opts=(-c:a aac -b:a "${BITRATE}")
            ;;
        mp3)
            codec_opts=(-c:a libmp3lame -b:a "${BITRATE}")
            ;;
        *)
            codec_opts=(-c:a libopus -b:a "${BITRATE}")
            ;;
    esac

    # v1.4.2: Add local recording if enabled (ring buffer in tmpfs/RAM)
    if [[ "${AUDIO_LOCAL_RECORDING}" == "true" ]]; then
        # Create recording directory (defaults to /dev/shm which is tmpfs/RAM)
        mkdir -p "${AUDIO_RECORDING_PATH}/${STREAM_PATH}" 2>/dev/null || true

        # Use tee muxer for simultaneous streaming and recording
        ffmpeg_cmd+=("${codec_opts[@]}")
        ffmpeg_cmd+=(
            -f tee
            -map 0:a
            "[f=rtsp:rtsp_transport=tcp]rtsp://${MEDIAMTX_HOST}:8554/${STREAM_PATH}|[f=segment:segment_time=${AUDIO_RECORDING_SEGMENT_TIME}:segment_wrap=${AUDIO_RECORDING_SEGMENTS}:strftime=0]${AUDIO_RECORDING_PATH}/${STREAM_PATH}/audio_%03d.${CODEC}"
        )
        log_message "Local recording enabled: ${AUDIO_RECORDING_PATH}/${STREAM_PATH} (${AUDIO_RECORDING_SEGMENTS} x ${AUDIO_RECORDING_SEGMENT_TIME}s segments)"
    else
        # Standard output: stream only
        ffmpeg_cmd+=("${codec_opts[@]}")
        ffmpeg_cmd+=(
            -f rtsp
            -rtsp_transport tcp
            "rtsp://${MEDIAMTX_HOST}:8554/${STREAM_PATH}"
        )
    fi
    
    # Rotate log if exceeds size limit to prevent disk exhaustion
    if [[ -f "${FFMPEG_LOG}" ]]; then
        local current_size
        current_size=$(stat -c %s "${FFMPEG_LOG}" 2>/dev/null || echo 0)
        if (( current_size > FFMPEG_LOG_MAX_SIZE )); then
            log_message "Rotating FFmpeg log (current size: ${current_size} bytes, max: ${FFMPEG_LOG_MAX_SIZE})"
            mv -f "${FFMPEG_LOG}" "${FFMPEG_LOG}.old" 2>/dev/null || true
            # Note: FFmpeg will automatically create new log file on next write
        fi
    fi
    
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
    if [[ -n "${MAIN_SCRIPT_PID}" ]] && [[ "${MAIN_SCRIPT_PID}" -gt 1 ]]; then
        if ! kill -0 "${MAIN_SCRIPT_PID}" 2>/dev/null; then
            log_message "Main script (PID ${MAIN_SCRIPT_PID}) has terminated, exiting"
            return 1
        fi
    fi
    return 0
}

# Log startup
log_critical "Stream wrapper starting for ${STREAM_PATH} (card ${CARD_NUM})"
log_message "Wrapper PID: $$, Main script PID: ${MAIN_SCRIPT_PID}"

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
        # Protect against integer overflow in restart delay
        if (( RESTART_DELAY <= 0 )) || (( RESTART_DELAY > MAX_RESTART_DELAY )); then
            RESTART_DELAY=$INITIAL_RESTART_DELAY
        else
            RESTART_DELAY=$((RESTART_DELAY * 2))
            if (( RESTART_DELAY > MAX_RESTART_DELAY )); then
                RESTART_DELAY=$MAX_RESTART_DELAY
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
        RESTART_DELAY=$INITIAL_RESTART_DELAY
        log_message "Successful run, reset delay to ${RESTART_DELAY}s"
    else
        ((CONSECUTIVE_FAILURES++))
        # Protect against integer overflow in restart delay
        if (( RESTART_DELAY <= 0 )) || (( RESTART_DELAY > MAX_RESTART_DELAY )); then
            RESTART_DELAY=$INITIAL_RESTART_DELAY
        else
            RESTART_DELAY=$((RESTART_DELAY * 2))
            if (( RESTART_DELAY > MAX_RESTART_DELAY )); then
                RESTART_DELAY=$MAX_RESTART_DELAY
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
            local recent_logs
            recent_logs="$(tail -n 10 "$ffmpeg_log" 2>/dev/null)"
            if [[ -n "$recent_logs" ]]; then
                log ERROR "Wrapper logs (last 10 lines):"
                while IFS= read -r line; do
                    log ERROR "  $line"
                done <<<"$recent_logs"
            fi
        fi
        rm -f "$wrapper_script"
        return 1
    fi

    # Write PID file with enhanced validation
    if ! write_pid_atomic "$pid" "$pid_file"; then
        log ERROR "Failed to write PID file for $stream_path"
        kill "$pid" 2>/dev/null || true
        rm -f "$wrapper_script"
        return 1
    fi

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
    local device_idx=0

    for device_info in "${devices[@]}"; do
        ((device_idx++)) || true
        IFS=':' read -r device_name card_num <<<"$device_info"

        if [[ -z "$device_name" ]] || [[ -z "$card_num" ]]; then
            continue
        fi

        if [[ ! -e "/dev/snd/controlC${card_num}" ]]; then
            continue
        fi

        local stream_path
        stream_path="$(generate_stream_path "$device_name" "$card_num")"

        # Progress feedback for manual starts
        echo "Starting stream ${device_idx}/${#devices[@]}: ${stream_path}..."

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
    else
        log INFO "Successfully started all $success_count/${#devices[@]} FFmpeg streams"
    fi

    # Always return 0 for best-effort behavior
    return 0
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

    # Restore nullglob only if it was originally off (avoids redundant shopt -s)
    [[ "$nullglob_state" == "off" ]] && shopt -u nullglob

    pkill -f "^ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" 2>/dev/null || true
}

# Generate MediaMTX configuration without subshell locking
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

    # Don't use subshell for locking - keep lock in main shell
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

    cat >"$tmp_config" <<'EOF'
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
        cat >>"$tmp_config" <<EOF
  ${MULTIPLEX_STREAM_NAME}:
    source: publisher
    sourceProtocol: automatic
    sourceOnDemand: no
EOF
    else
        # Individual mode - accept any stream name
        cat >>"$tmp_config" <<EOF
  '~^[a-zA-Z0-9_-]+$':
    source: publisher
    sourceProtocol: automatic
    sourceOnDemand: no
EOF
    fi

    # Set permissions BEFORE atomic move (following write_pid_atomic pattern)
    chmod 644 "$tmp_config" 2>/dev/null || {
        rm -f "$tmp_config"
        log ERROR "Failed to set permissions on temp config file"
        exec {CONFIG_LOCK_FD}>&- 2>/dev/null || true
        CONFIG_LOCK_FD=-1
        return 1
    }

    # Atomically move into place
    mv -f "$tmp_config" "${CONFIG_FILE}" || {
        rm -f "$tmp_config"
        log ERROR "Failed to move config file into place"
        exec {CONFIG_LOCK_FD}>&- 2>/dev/null || true
        CONFIG_LOCK_FD=-1
        return 1
    }

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
        nohup setsid "${MEDIAMTX_BIN}" "${CONFIG_FILE}" >>"${MEDIAMTX_LOG_FILE}" 2>&1 &
    else
        nohup "${MEDIAMTX_BIN}" "${CONFIG_FILE}" >>"${MEDIAMTX_LOG_FILE}" 2>&1 &
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
        # Validate device count before starting multiplex stream
        if [[ ${#devices[@]} -eq 0 ]]; then
            log ERROR "Multiplex mode requires devices but none detected"
            stop_mediamtx
            return "${E_USB_NO_DEVICES}"
        fi

        log INFO "Multiplex mode - starting single multiplexed stream to ${MULTIPLEX_STREAM_NAME}"
        echo "Starting multiplexed stream (${#devices[@]} devices): ${MULTIPLEX_STREAM_NAME}..."
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
            echo -e "${GREEN}[OK]${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path} (multiplexed from ${#devices[@]} devices)"
        else
            echo -e "${RED}[FAIL]${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path} (failed)"
        fi
    else
        # In individual mode, validate each device's stream
        for device_info in "${devices[@]}"; do
            IFS=':' read -r device_name card_num <<<"$device_info"
            local stream_path
            stream_path="$(generate_stream_path "$device_name" "$card_num")"

            if validate_stream "$stream_path"; then
                echo -e "${GREEN}[OK]${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path}"
            else
                echo -e "${RED}[FAIL]${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path} (failed)"
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

    local devices=()
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
                IFS=':' read -r device_name card_num <<<"$device_info"
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
                IFS=':' read -r device_name card_num <<<"$device_info"

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

    # Capture current configuration for systemd service
    local stream_mode="${STREAM_MODE:-individual}"
    local multiplex_filter="${MULTIPLEX_FILTER_TYPE:-amix}"
    local multiplex_name="${MULTIPLEX_STREAM_NAME:-all_mics}"

    cat >"$service_file" <<EOF
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
StartLimitInterval=1200
StartLimitBurst=10
User=root
Group=audio

StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

TimeoutStartSec=300
TimeoutStopSec=120

LimitNOFILE=65536
LimitNPROC=4096

PrivateTmp=yes
ProtectSystem=full
NoNewPrivileges=yes
ReadWritePaths=/etc/mediamtx /var/lib/mediamtx-ffmpeg /var/log /var/run

Environment="HOME=/root"
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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
        cat >/etc/logrotate.d/mediamtx <<EOF
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

    # Create monitoring cron job with conservative restart policy and overlap protection
    # Conservative restart policy: only restart on critical resource failure
    # Using flock to prevent overlapping monitor instances when checks exceed 5 minutes
    cat >/etc/cron.d/mediamtx-monitor <<EOF
# Monitor MediaMTX resource usage and stream health every 5 minutes
# Conservative restart policy (only on critical resource failure):
#   Exit 0: All healthy - no action
#   Exit 2: Critical resource state - RESTART SERVICE
#   Exit 6: No USB devices - LOG ONLY (transient, will recover)
#   Exit 7: MediaMTX not running - LOG ONLY (may recover)
#   Exit 10: Stream degradation - LOG ONLY (monitor will fix on next cycle)
#
# CRON=1 enables explicit cron context detection
# flock prevents overlapping runs when monitor exceeds 5-minute interval
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CRON=1

*/5 * * * * root flock -n /run/mediamtx-monitor.lock -c '${SCRIPT_DIR}/${SCRIPT_NAME} monitor; EXIT=\$?; if [ \$EXIT -eq 2 ]; then systemctl restart mediamtx-audio; elif [ \$EXIT -ne 0 ]; then logger -t mediamtx-monitor "Non-critical exit code \$EXIT (no restart)"; fi' || logger -t mediamtx-monitor "Monitor already running or locked"
EOF

    systemctl daemon-reload

    echo "Systemd service created: $service_file"
    echo "Monitoring cron job created: /etc/cron.d/mediamtx-monitor"
    echo ""
    echo "=== v1.4.1 Configuration Enhancements ==="
    echo "  * Friendly name support for audio device configuration"
    echo "  * Use stream names in config (e.g., DEVICE_BLUE_YETI_SAMPLE_RATE=44100)"
    echo "  * 100% backward compatible with existing full device name configs"
    echo ""
    echo "=== v1.4.0 Production Enhancements ==="
    echo "  * Separate monitoring lock (eliminates service/cron contention)"
    echo "  * Conservative restart policy (only on critical resource failure)"
    echo "  * Overlapping monitor protection (flock-based locking)"
    echo "  * Increased restart tolerance (10 restarts in 20 minutes)"
    echo "  * Recursive process cleanup (ensures complete termination)"
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
    cat <<EOF
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
    monitor     Check resource usage and stream health
                Exit codes: 0=healthy, 2=critical resources, 3=MediaMTX down,
                            7=no devices, 10=streams degraded
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


Resource Monitoring:
    The monitor command now checks:
    - Stream health (automatically restarts dead streams)
    - File descriptor usage (warn: ${MAX_FD_WARNING}, critical: ${MAX_FD_CRITICAL})
    - High CPU usage (warn: ${MAX_CPU_WARNING}%, critical: ${MAX_CPU_CRITICAL}%)
    - Wrapper process health
    
    Conservative restart policy:
    - Exit 2 (Critical resource failure): Triggers full service restart
    - Exit 7 (MediaMTX down): Logged, no restart (may recover)
    - Exit 6 (No USB devices): Logged, no restart (transient state)
    - Exit 10 (Stream degraded): Logged, no restart (fixed on next cycle)

Exit Codes:
    0  - Success
    1  - General error
    2  - Critical resource state (TRIGGERS RESTART in cron)
    3  - Missing dependencies
    4  - Configuration error
    5  - Lock acquisition failed
    6  - No USB devices found (logged only)
    7  - MediaMTX not running (logged only)
    10 - Stream monitoring degraded (logged only)

EOF
}

# Main function with enhanced argument parsing
parse_arguments() {
    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m | --mode)
                shift
                STREAM_MODE="${1}"
                if [[ "${STREAM_MODE}" != "individual" ]] && [[ "${STREAM_MODE}" != "multiplex" ]]; then
                    echo "Error: Invalid stream mode '${STREAM_MODE}'. Use 'individual' or 'multiplex'" >&2
                    exit 1
                fi
                shift
                ;;
            -f | --filter)
                shift
                MULTIPLEX_FILTER_TYPE="${1}"
                if [[ "${MULTIPLEX_FILTER_TYPE}" != "amix" ]] && [[ "${MULTIPLEX_FILTER_TYPE}" != "amerge" ]]; then
                    echo "Error: Invalid filter type '${MULTIPLEX_FILTER_TYPE}'. Use 'amix' or 'amerge'" >&2
                    exit 1
                fi
                shift
                ;;
            -n | --name)
                shift
                MULTIPLEX_STREAM_NAME="${1}"
                shift
                ;;
            -d | --debug)
                export DEBUG=true
                shift
                ;;
            -h | --help)
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

# Main entry point and command router
#
# Execution flow:
# 1. Calls parse_arguments() to parse command-line options and extract command
# 2. Logs stream mode if non-default
# 3. Routes to command handler via case statement
# 4. Captures exit code from command handler
# 5. Exits with propagated exit code
#
# Commands:
#   start       - Checks root, dependencies, directories, then starts service
#   stop        - Checks root, dependencies, directories, then stops service
#   force-stop  - Checks root, directories, then force-stops service
#   restart     - Checks root, dependencies, directories, then restarts service
#   status      - Shows current status (no root check)
#   config      - Shows configuration (no root check)
#   monitor     - Checks root, directories, resources, then monitors streams
#   install     - Checks root, then creates systemd service
#   help        - Shows help text
#
# Parameters:
#   $@ = Command-line arguments (passed to parse_arguments)
#
# Returns:
#   0 = Success (E_GENERAL=0 not used, success is 0)
#   1 = General error (E_GENERAL)
#   2 = Critical resource state (E_CRITICAL_RESOURCE)
#   3 = Missing dependencies (E_MISSING_DEPS)
#   4 = Configuration error (E_CONFIG_ERROR)
#   5 = Lock acquisition failed (E_LOCK_FAILED)
#   6 = No USB devices found (E_USB_NO_DEVICES)
#   7 = MediaMTX not running (E_MEDIAMTX_DOWN)
#   10 = Stream monitoring degraded (E_MONITOR_DEGRADED)
#
# Side Effects:
#   - Calls exit() - does not return
#   - May modify filesystem (logs, config files, PID files)
#   - May start/stop processes
main() {
    local exit_code=0

    # Parse arguments
    # Note: COMMAND is global so cleanup() can check it
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
            # v1.4.2: Pre-start validation and initialization
            check_version_compatibility || log WARN "Version compatibility check failed (continuing anyway)"
            validate_config || error_exit "Configuration validation failed" ${E_CONFIG_ERROR}
            init_hardware_watchdog
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
            # v1.4.2: Use enhanced resource monitoring with disk, memory, and network checks
            # First check all resources (returns E_CRITICAL_RESOURCE if critical issues)
            if ! check_all_resources; then
                local resource_code=$?
                if [[ $resource_code -eq ${E_CRITICAL_RESOURCE} ]]; then
                    exit ${E_CRITICAL_RESOURCE}
                fi
                # Non-critical issues are logged but we continue
            fi
            # Then check and restart streams (returns error codes for failures)
            monitor_streams
            exit_code=$?
            # Log exit code for debugging
            if [[ $exit_code -ne 0 ]]; then
                log DEBUG "Monitor command exiting with code $exit_code"
            fi
            ;;
        install)
            check_root
            create_systemd_service
            exit_code=$?
            ;;
        help | --help | -h | "")
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

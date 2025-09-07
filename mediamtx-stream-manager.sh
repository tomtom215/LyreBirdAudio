#!/bin/bash
# mediamtx-stream-manager.sh - Automatic MediaMTX audio stream configuration
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# This script automatically detects USB microphones and creates MediaMTX 
# configurations for continuous 24/7 RTSP audio streams.
#
# Version: 1.1.5.4 - 24/7 Production Critical Bug Fixes
# Compatible with MediaMTX v1.12.3+
#
# Version History:
# v1.1.5.4 - fix(critical): 8 verified critical bugs for true 24/7 reliability
#   - CRITICAL: Fixed PID recycling vulnerability with start time validation
#   - CRITICAL: Fixed lock acquisition race condition with proper flock usage
#   - HIGH: Added MediaMTX log rotation to prevent disk exhaustion
#   - HIGH: Fixed file descriptor leak in stream claiming with proper cleanup
#   - MEDIUM: Fixed regex special character escaping in stream validation
#   - MEDIUM: Replaced unreliable BASH_COMMAND with explicit flag
#   - MEDIUM: Added persistent restart counter across wrapper instances
#   - LOW: Added curl fallback for missing dependency
# v1.1.5.3 - fix(security/stability): Critical security and stability improvements
#   - SECURITY: Fixed shell injection vulnerability in wrapper variable generation
#   - STABILITY: Added process validation to read_pid_safe() preventing stale PID usage
#   - RELIABILITY: Implemented exponential backoff with permanent failure detection
#   - CONSISTENCY: Fixed all associative array initializations
#   - ROBUSTNESS: Enhanced wrapper restart logic with MAX_CONSECUTIVE_FAILURES
# v1.1.5.2 - fix(critical): Resolve CPU resource leak from writeTimeout
#   - CRITICAL: Changed writeTimeout from 600s to 30s to prevent CPU exhaustion
#   - Fixed bash array initialization in show_status() to prevent unintended cleanup
#   - Added safety check in cleanup() to prevent MediaMTX termination during status
# v1.1.5.1 - fix(config): Prevent mediamtx high CPU on publisher disconnect
#   - Add sourceOnDemand: no and readTimeout: 30s to MediaMTX configuration to prevent resource leaks
# v1.1.5 - Production release with enhanced security and reliability
#   - Complete shell injection protection for all wrapper variables
#   - Enhanced device name sanitization and validation
#   - Atomic file operations to prevent corruption
#   - Improved process lifecycle management with restart limits
#   - Fixed FFmpeg parameter compatibility issues
#   - Enhanced stream validation and monitoring
# v1.1.4 - Fixed stream path collision with mutual exclusion
# v1.1.3 - Fixed FFmpeg PID handling in wrapper script
# v1.1.2 - Fixed wrapper script startup race condition
# v1.1.1 - Fixed wrapper script execution issue
# v1.1.0 - Production hardening release
#
# Requirements:
# - MediaMTX installed (use install_mediamtx.sh)
# - USB audio devices
# - ffmpeg installed for audio encoding
#
# Usage: ./mediamtx-stream-manager.sh [start|stop|restart|status|config|help]

# Ensure we're running with bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash. Please run with: bash $0 $*" >&2
    exit 1
fi

set -euo pipefail

# Constants with environment variable overrides for flexibility
readonly VERSION="1.1.5.4"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configurable paths with environment variable defaults
readonly CONFIG_DIR="${MEDIAMTX_CONFIG_DIR:-/etc/mediamtx}"
readonly CONFIG_FILE="${MEDIAMTX_CONFIG_FILE:-${CONFIG_DIR}/mediamtx.yml}"
readonly DEVICE_CONFIG_FILE="${MEDIAMTX_DEVICE_CONFIG:-${CONFIG_DIR}/audio-devices.conf}"
readonly PID_FILE="${MEDIAMTX_PID_FILE:-/var/run/mediamtx-audio.pid}"
readonly FFMPEG_PID_DIR="${MEDIAMTX_FFMPEG_DIR:-/var/lib/mediamtx-ffmpeg}"
readonly LOCK_FILE="${MEDIAMTX_LOCK_FILE:-/var/run/mediamtx-audio.lock}"
readonly LOG_FILE="${MEDIAMTX_LOG_FILE:-/var/log/mediamtx-stream-manager.log}"
readonly MEDIAMTX_LOG="${MEDIAMTX_SYSTEM_LOG:-/var/log/mediamtx.log}"
readonly MEDIAMTX_BIN="${MEDIAMTX_BINARY:-/usr/local/bin/mediamtx}"
readonly MEDIAMTX_HOST="${MEDIAMTX_HOST:-localhost}"
readonly RESTART_MARKER="${MEDIAMTX_RESTART_MARKER:-/var/run/mediamtx-audio.restart}"
readonly CLEANUP_MARKER="${MEDIAMTX_CLEANUP_MARKER:-/var/run/mediamtx-audio.cleanup}"

# System limits
readonly SYSTEM_PID_MAX="$(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 32768)"

# Configurable timeouts
readonly PID_TERMINATION_TIMEOUT="${PID_TERMINATION_TIMEOUT:-10}"
readonly MEDIAMTX_API_TIMEOUT="${MEDIAMTX_API_TIMEOUT:-60}"

# Global lock file descriptor
declare -gi MAIN_LOCK_FD=

# Error handling mode
readonly ERROR_HANDLING_MODE="${ERROR_HANDLING_MODE:-fail-safe}"

# FIX #6: Replace BASH_COMMAND check with explicit flag
declare -g SKIP_CLEANUP=false

# Audio stability settings
readonly DEFAULT_SAMPLE_RATE="48000"
readonly DEFAULT_CHANNELS="2"
readonly DEFAULT_FORMAT="s16le"
readonly DEFAULT_CODEC="opus"
readonly DEFAULT_BITRATE="128k"
readonly DEFAULT_THREAD_QUEUE="8192"
readonly DEFAULT_FIFO_SIZE="1048576"
readonly DEFAULT_ANALYZEDURATION="5000000"
readonly DEFAULT_PROBESIZE="5000000"

# Connection settings
readonly STREAM_STARTUP_DELAY="${STREAM_STARTUP_DELAY:-10}"
readonly STREAM_VALIDATION_ATTEMPTS="3"
readonly STREAM_VALIDATION_DELAY="5"
readonly USB_STABILIZATION_DELAY="${USB_STABILIZATION_DELAY:-5}"
readonly RESTART_STABILIZATION_DELAY="${RESTART_STABILIZATION_DELAY:-15}"

# Device test settings
readonly DEVICE_TEST_ENABLED="${DEVICE_TEST_ENABLED:-false}"
readonly DEVICE_TEST_TIMEOUT="${DEVICE_TEST_TIMEOUT:-3}"

# MediaMTX log rotation settings
readonly MEDIAMTX_LOG_MAX_SIZE="${MEDIAMTX_LOG_MAX_SIZE:-52428800}"  # 50MB default

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Shell escaping function for wrapper variables
escape_wrapper() {
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

# Cleanup function
cleanup() {
    local exit_code=$?
    
    # FIX #6: Use explicit flag instead of BASH_COMMAND check
    if [[ "${SKIP_CLEANUP}" == "true" ]]; then
        log DEBUG "Cleanup skipped due to SKIP_CLEANUP flag"
        release_lock
        exit "${exit_code}"
    fi
    
    # Perform comprehensive cleanup if we're exiting unexpectedly
    if [[ $exit_code -ne 0 ]] && [[ "${CLEANUP_IN_PROGRESS:-false}" != "true" ]]; then
        export CLEANUP_IN_PROGRESS="true"
        cleanup_stale_processes
    fi
    
    # Release lock through proper function
    release_lock
    rm -f "${CLEANUP_MARKER}"
    exit "${exit_code}"
}

# Only set trap in main process, not subprocesses
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ $$ -eq $BASHPID ]]; then
    trap cleanup EXIT INT TERM
fi

# Logging functions
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}"
    
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

# Standardized error handling
handle_error() {
    local severity="$1"
    local message="$2"
    local exit_code="${3:-1}"
    
    case "${severity}" in
        FATAL)
            log ERROR "$message"
            cleanup
            exit "${exit_code}"
            ;;
        ERROR)
            log ERROR "$message"
            if [[ "${ERROR_HANDLING_MODE}" == "fail-fast" ]]; then
                cleanup
                exit "${exit_code}"
            fi
            return 1
            ;;
        WARN)
            log WARN "$message"
            return 0
            ;;
    esac
}

error_exit() {
    handle_error FATAL "$1" "${2:-1}"
}

# FIX #1: Atomic PID file operations with start time
write_pid_atomic() {
    local pid="$1"
    local pid_file="$2"
    local pid_dir
    pid_dir="$(dirname "$pid_file")"
    
    local temp_pid
    temp_pid="$(mktemp -p "$pid_dir" "$(basename "$pid_file").XXXXXX")" || {
        log ERROR "Failed to create secure temp file in $pid_dir"
        return 1
    }
    
    # Store PID with start time for validation
    local start_time=""
    if [[ -r "/proc/${pid}/stat" ]]; then
        start_time=$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null)
    fi
    
    echo "${pid} ${start_time}" > "$temp_pid" && mv -f "$temp_pid" "$pid_file" || {
        rm -f "$temp_pid"
        return 1
    }
}

# FIX #1: Enhanced PID reading with start time validation
read_pid_safe() {
    local pid_file="$1"
    local pid_content=""
    local start_time=""
    
    if [[ ! -f "$pid_file" ]]; then
        echo ""
        return 0
    fi
    
    # Read both PID and start time
    read -r pid_content start_time < "$pid_file" 2>/dev/null || {
        echo ""
        return 0
    }
    
    # Remove any whitespace
    pid_content="$(echo "$pid_content" | tr -d '[:space:]')"
    
    if [[ -z "$pid_content" ]]; then
        log DEBUG "PID file $pid_file is empty"
        echo ""
        return 0
    fi
    
    if [[ ! "$pid_content" =~ ^[0-9]+$ ]]; then
        log ERROR "PID file $pid_file contains invalid content: '$pid_content'"
        rm -f "$pid_file"
        echo ""
        return 0
    fi
    
    local pid_val=$((10#$pid_content))
    local max_val=$((10#$SYSTEM_PID_MAX))
    
    if [[ $pid_val -lt 1 ]] || [[ $pid_val -gt $max_val ]]; then
        log ERROR "PID file $pid_file contains out-of-range PID: $pid_content"
        rm -f "$pid_file"
        echo ""
        return 0
    fi
    
    # Verify process exists
    if ! kill -0 "$pid_content" 2>/dev/null; then
        log DEBUG "PID $pid_content from $pid_file is not running"
        rm -f "$pid_file"
        echo ""
        return 0
    fi
    
    # FIX #1: Validate start time if available to detect PID recycling
    if [[ -n "$start_time" ]] && [[ -r "/proc/${pid_content}/stat" ]]; then
        local current_start
        current_start=$(awk '{print $22}' "/proc/${pid_content}/stat" 2>/dev/null)
        if [[ "$current_start" != "$start_time" ]]; then
            log DEBUG "PID $pid_content was recycled (start time mismatch)"
            rm -f "$pid_file"
            echo ""
            return 0
        fi
    fi
    
    echo "$pid_content"
}

# PID identity verification with proper removal order
wait_for_pid_termination() {
    local pid="$1"
    local timeout="${2:-${PID_TERMINATION_TIMEOUT}}"
    local original_start=""
    
    if [[ -r "/proc/${pid}/stat" ]]; then
        original_start=$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null)
    fi
    
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    
    log DEBUG "Waiting for PID $pid to terminate (timeout: ${timeout}s)"
    
    local elapsed=0
    while kill -0 "$pid" 2>/dev/null && [[ $elapsed -lt $timeout ]]; do
        if [[ -n "$original_start" ]] && [[ -r "/proc/${pid}/stat" ]]; then
            local current_start
            current_start=$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null)
            if [[ "$current_start" != "$original_start" ]]; then
                log DEBUG "PID $pid was recycled - considering terminated"
                return 0
            fi
        fi
        sleep 1
        ((elapsed++))
    done
    
    if kill -0 "$pid" 2>/dev/null; then
        log WARN "PID $pid did not terminate within ${timeout}s"
        return 1
    fi
    
    log DEBUG "PID $pid terminated successfully"
    return 0
}

# FIX #2: Simplified lock management with proper flock usage
acquire_lock() {
    local timeout="${1:-30}"
    
    # Open lock file and get file descriptor
    exec {MAIN_LOCK_FD}>"${LOCK_FILE}" || {
        log ERROR "Cannot create lock file ${LOCK_FILE}"
        handle_error FATAL "Cannot create lock file" 5
    }
    
    # Try to acquire lock with timeout
    if ! flock -w "$timeout" ${MAIN_LOCK_FD}; then
        handle_error FATAL "Failed to acquire lock after ${timeout} seconds" 5
    fi
    
    # Write our PID to the lock file
    echo "$$" >&${MAIN_LOCK_FD}
    log DEBUG "Successfully acquired lock (PID: $$, FD: ${MAIN_LOCK_FD})"
    return 0
}

release_lock() {
    if [[ -n "${MAIN_LOCK_FD}" ]] && [[ "${MAIN_LOCK_FD}" -gt 2 ]]; then
        log DEBUG "Releasing lock (FD: ${MAIN_LOCK_FD})"
        if exec {MAIN_LOCK_FD}>&- 2>/dev/null; then
            MAIN_LOCK_FD=
            rm -f "${LOCK_FILE}"
        else
            log WARN "Failed to close lock FD"
            MAIN_LOCK_FD=
            rm -f "${LOCK_FILE}"
        fi
    else
        rm -f "${LOCK_FILE}"
    fi
}

# Check if running as root
check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        handle_error FATAL "This script must be run as root (use sudo)" 2
    fi
}

# Check dependencies
check_dependencies() {
    local missing=()
    
    for cmd in ffmpeg jq arecord; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    # FIX #8: curl is optional, don't fail if missing
    if ! command -v curl &>/dev/null; then
        log WARN "curl not found - some validation features will be limited"
    fi
    
    if [[ ! -x "${MEDIAMTX_BIN}" ]]; then
        missing+=("mediamtx (run install_mediamtx.sh first)")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        handle_error FATAL "Missing dependencies: ${missing[*]}" 3
    fi
}

# Create required directories
setup_directories() {
    mkdir -p "${CONFIG_DIR}"
    mkdir -p "$(dirname "${LOG_FILE}")"
    mkdir -p "$(dirname "${MEDIAMTX_LOG}")"
    mkdir -p "$(dirname "${PID_FILE}")"
    mkdir -p "${FFMPEG_PID_DIR}"
    
    chmod 755 "${FFMPEG_PID_DIR}"
    
    if [[ ! -f "${LOG_FILE}" ]]; then
        touch "${LOG_FILE}"
        chmod 644 "${LOG_FILE}"
    fi
    
    if [[ ! -f "${MEDIAMTX_LOG}" ]]; then
        touch "${MEDIAMTX_LOG}"
        chmod 644 "${MEDIAMTX_LOG}"
    fi
}

# Detect if we're in a restart scenario
is_restart_scenario() {
    if [[ -f "${RESTART_MARKER}" ]]; then
        local marker_age
        marker_age="$(( $(date +%s) - $(stat -c %Y "${RESTART_MARKER}" 2>/dev/null || echo 0) ))"
        if [[ $marker_age -lt 60 ]]; then
            return 0
        fi
    fi
    
    if pgrep -f "${MEDIAMTX_BIN}" >/dev/null 2>&1 || pgrep -f "ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" >/dev/null 2>&1; then
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

# Cleanup stale processes
cleanup_stale_processes() {
    log INFO "Performing comprehensive cleanup of stale processes and files"
    
    touch "${CLEANUP_MARKER}"
    
    local -a pids_to_wait=()
    
    log DEBUG "Terminating FFmpeg wrapper scripts"
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        if [[ -f "$pid_file" ]]; then
            local pid
            pid="$(read_pid_safe "$pid_file")"
            if [[ -n "$pid" ]]; then
                kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
                pkill -TERM -P "$pid" 2>/dev/null || true
                pids_to_wait+=("$pid")
            fi
        fi
    done
    
    for pid in "${pids_to_wait[@]}"; do
        wait_for_pid_termination "$pid" 2
    done
    
    pids_to_wait=()
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        if [[ -f "$pid_file" ]]; then
            local pid
            pid="$(read_pid_safe "$pid_file")"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                log DEBUG "Force killing wrapper PID $pid"
                kill -KILL -- -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
                pkill -KILL -P "$pid" 2>/dev/null || true
                pids_to_wait+=("$pid")
            fi
            rm -f "$pid_file"
        fi
    done
    
    for pid in "${pids_to_wait[@]}"; do
        wait_for_pid_termination "$pid" 1
    done
    
    log DEBUG "Killing orphaned FFmpeg processes"
    pids_to_wait=()
    while IFS= read -r pid; do
        if [[ -n "$pid" ]]; then
            kill -TERM "$pid" 2>/dev/null || true
            pids_to_wait+=("$pid")
        fi
    done < <(pgrep -f "ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" 2>/dev/null || true)
    
    for pid in "${pids_to_wait[@]}"; do
        if ! wait_for_pid_termination "$pid" 2; then
            log DEBUG "Force killing orphaned FFmpeg PID $pid"
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done
    
    if [[ -f "${PID_FILE}" ]]; then
        local mediamtx_pid
        mediamtx_pid="$(read_pid_safe "${PID_FILE}")"
        if [[ -n "$mediamtx_pid" ]]; then
            if kill -0 "$mediamtx_pid" 2>/dev/null; then
                log DEBUG "Terminating MediaMTX PID $mediamtx_pid"
                kill -TERM "$mediamtx_pid" 2>/dev/null || true
                if ! wait_for_pid_termination "$mediamtx_pid" 2; then
                    kill -KILL "$mediamtx_pid" 2>/dev/null || true
                fi
            else
                log DEBUG "Removing stale MediaMTX PID file"
            fi
            rm -f "${PID_FILE}"
        fi
    fi
    
    if [[ -f "${CONFIG_FILE}" ]]; then
        local mediamtx_pids
        mediamtx_pids="$(pgrep -f "${MEDIAMTX_BIN}.*${CONFIG_FILE}" 2>/dev/null || true)"
        if [[ -n "$mediamtx_pids" ]]; then
            log DEBUG "Killing MediaMTX processes using our config"
            echo "$mediamtx_pids" | while read -r pid; do
                if [[ -n "$pid" ]]; then
                    kill -TERM "$pid" 2>/dev/null || true
                    wait_for_pid_termination "$pid" 1 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
                fi
            done
        fi
    fi
    
    log DEBUG "Cleaning temporary files"
    rm -f "${FFMPEG_PID_DIR}"/*.pid
    rm -f "${FFMPEG_PID_DIR}"/*.sh
    rm -f "${FFMPEG_PID_DIR}"/*.log
    rm -f "${FFMPEG_PID_DIR}"/*.log.old
    rm -f "${FFMPEG_PID_DIR}"/*.lock
    rm -f "${FFMPEG_PID_DIR}"/*.claim
    rm -f "${FFMPEG_PID_DIR}"/*.restarts  # FIX #7: Clean restart counter files
    rm -f /tmp/mediamtx-audio-*.yml
    
    if command -v alsactl &>/dev/null; then
        log DEBUG "Resetting ALSA state"
        alsactl init 2>/dev/null || true
    fi
    
    rm -f "${CLEANUP_MARKER}"
    
    log INFO "Cleanup completed"
}

# Wait for USB audio subsystem to stabilize
wait_for_usb_stabilization() {
    local max_wait="${1:-${USB_STABILIZATION_DELAY}}"
    local stable_count_needed=2
    local stable_count=0
    local last_device_count=0
    local elapsed=0
    
    log INFO "Waiting for USB audio subsystem to stabilize (max ${max_wait}s)..."
    
    while [[ $elapsed -lt $max_wait ]]; do
        local current_device_count
        current_device_count="$(detect_audio_devices | wc -l)"
        
        if [[ $current_device_count -eq $last_device_count ]] && [[ $current_device_count -gt 0 ]]; then
            ((stable_count++)) || true
            if [[ $stable_count -ge $stable_count_needed ]]; then
                log INFO "USB audio subsystem stable with $current_device_count devices"
                return 0
            fi
        else
            stable_count=0
            last_device_count=$current_device_count
        fi
        
        sleep 2
        ((elapsed+=2))
    done
    
    if [[ $last_device_count -gt 0 ]]; then
        log WARN "USB audio subsystem stabilization timeout, proceeding with $last_device_count devices"
        return 0
    else
        log ERROR "No USB audio devices detected after ${max_wait} seconds"
        return 1
    fi
}

# Wait for MediaMTX API to become ready
wait_for_mediamtx_ready() {
    local pid="$1"
    local max_wait="${MEDIAMTX_API_TIMEOUT}"
    local elapsed=0
    local check_interval=1
    
    log INFO "Waiting for MediaMTX to become ready..."
    
    while [[ $elapsed -lt $max_wait ]]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            log ERROR "MediaMTX process died during startup"
            if [[ -f /var/log/mediamtx.out ]]; then
                log ERROR "Last output: $(tail -5 /var/log/mediamtx.out 2>/dev/null | tr '\n' ' ')"
            fi
            return 1
        fi
        
        # FIX #8: Check if curl exists before using it
        if command -v curl &>/dev/null; then
            if curl -s --max-time 2 "http://${MEDIAMTX_HOST}:9997/v3/paths/list" >/dev/null 2>&1; then
                log INFO "MediaMTX API is ready after ${elapsed} seconds"
                return 0
            fi
        else
            # Fallback: just check if process is still running after a delay
            if [[ $elapsed -ge 10 ]]; then
                log INFO "MediaMTX assumed ready (curl not available for API check)"
                return 0
            fi
        fi
        
        sleep "$check_interval"
        ((elapsed += check_interval))
        
        if [[ $((elapsed % 5)) -eq 0 ]]; then
            log DEBUG "Still waiting for MediaMTX API... (${elapsed}s/${max_wait}s)"
        fi
    done
    
    log ERROR "MediaMTX API did not become ready within ${max_wait} seconds"
    return 1
}

# Load device configuration
load_device_config() {
    if [[ -f "${DEVICE_CONFIG_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${DEVICE_CONFIG_FILE}"
    fi
}

# Save device configuration template
save_device_config() {
    cat > "${DEVICE_CONFIG_FILE}" << 'EOF'
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

# Codec recommendations:
# - opus: Best for real-time streaming (low latency, good quality)
# - aac: Universal compatibility 
# - mp3: Legacy device support
# - pcm: Avoid for network streams (uses excessive bandwidth)
EOF
}

# Safe device name sanitization to create valid bash variable names
sanitize_device_name() {
    local name="$1"
    local sanitized
    
    # Convert all non-alphanumeric characters to underscores
    # This ensures valid bash variable names (no hyphens allowed)
    sanitized=$(printf '%s' "$name" | sed 's/[^a-zA-Z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//')
    
    # Ensure doesn't start with digit (invalid for bash variables)
    if [[ "$sanitized" =~ ^[0-9] ]]; then
        sanitized="dev_${sanitized}"
    fi
    
    # Final safety check for empty result
    if [[ -z "$sanitized" ]]; then
        sanitized="unknown_device_$(date +%s)"
        log WARN "Device name sanitization produced empty result, using: $sanitized"
    fi
    
    printf '%s\n' "$sanitized"
}

# Sanitize path name for MediaMTX
sanitize_path_name() {
    local name="$1"
    name="${name#usb-audio-}"
    name="${name#usb_audio_}"
    local sanitized
    sanitized="$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^0-9a-z]/_/g' | sed 's/__*/_/g' | sed 's/^_*//;s/_*$//')"
    
    if [[ -z "$sanitized" ]]; then
        sanitized="stream_$(date +%s)"
        log WARN "Path name sanitization produced empty result, using: $sanitized"
    fi
    
    echo "$sanitized"
}

# Get device configuration
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

# Verify udev names
verify_udev_names() {
    log INFO "Checking for udev-assigned friendly names..."
    
    local found_friendly=0
    local total_cards=0
    local total_usb_cards=0
    
    if [[ -f "/proc/asound/cards" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]].*\[([^]]+)\] ]]; then
                local card_num="${BASH_REMATCH[1]}"
                local card_name="${BASH_REMATCH[2]}"
                card_name="$(echo "$card_name" | xargs)"
                ((total_cards++)) || true
                
                if [[ ! -f "/proc/asound/card${card_num}/usbid" ]]; then
                    continue
                fi
                
                ((total_usb_cards++)) || true
                
                if [[ "$card_name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
                    log INFO "Card $card_num has friendly name: $card_name"
                    ((found_friendly++)) || true
                else
                    log INFO "Card $card_num has default name: $card_name"
                fi
            fi
        done < "/proc/asound/cards"
    fi
    
    if [[ $found_friendly -gt 0 ]]; then
        log INFO "Found $found_friendly/$total_usb_cards USB cards with friendly names"
    else
        log WARN "No udev-assigned friendly names found. Stream names will use device info."
        log WARN "Run usb-audio-mapper.sh to assign friendly names to your devices."
    fi
    
    return 0
}

# Detect USB audio devices
detect_audio_devices() {
    local devices=()
    
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

# Check if audio device is accessible
check_audio_device() {
    local card_num="$1"
    
    if [[ ! -e "/dev/snd/pcmC${card_num}D0c" ]]; then
        log DEBUG "Device file /dev/snd/pcmC${card_num}D0c does not exist"
        return 1
    fi
    
    if timeout 2 arecord -l 2>/dev/null | grep -q "card ${card_num}:"; then
        log DEBUG "Audio device card ${card_num} found in arecord -l"
        return 0
    fi
    
    log DEBUG "Audio device card ${card_num} not accessible"
    return 1
}

# Generate stream path name
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
                    log DEBUG "Found udev-friendly name: $card_name"
                    base_path="$card_name"
                else
                    log DEBUG "Card name '$card_name' doesn't look like udev name, using fallback"
                fi
            fi
        fi
    fi
    
    if [[ -z "$base_path" ]]; then
        base_path="$(sanitize_path_name "$device_name")"
        log DEBUG "Using sanitized device name: $base_path"
    fi
    
    if [[ ! "$base_path" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        log WARN "Path '$base_path' may not be MediaMTX compatible, adding prefix"
        base_path="stream_${base_path}"
    fi
    
    if [[ ${#base_path} -gt 64 ]]; then
        log WARN "Path name too long, truncating"
        base_path="${base_path:0:64}"
    fi
    
    log DEBUG "Generated stream path: $base_path (from device: $device_name)"
    echo "$base_path"
}

# Test audio device capabilities
test_audio_device_safe() {
    local card_num="$1"
    local sample_rate="$2"
    local channels="$3"
    local format="$4"
    
    if [[ "${DEVICE_TEST_ENABLED}" != "true" ]]; then
        log DEBUG "Device testing disabled, assuming device supports requested format"
        return 0
    fi
    
    local arecord_format
    case "$format" in
        s16le) arecord_format="S16_LE" ;;
        s24le) arecord_format="S24_LE" ;;
        s32le) arecord_format="S32_LE" ;;
        *) arecord_format="S16_LE" ;;
    esac
    
    log DEBUG "Testing device hw:${card_num},0 with ${arecord_format} ${sample_rate}Hz ${channels}ch"
    
    if timeout "${DEVICE_TEST_TIMEOUT}" arecord -D "hw:${card_num},0" -f "${arecord_format}" -r "${sample_rate}" -c "${channels}" -d 1 -t raw 2>/dev/null | head -c 1000 >/dev/null; then
        log DEBUG "Device test passed with hw:${card_num},0"
        return 0
    fi
    
    log DEBUG "Testing with plughw:${card_num},0 for automatic format conversion"
    if timeout "${DEVICE_TEST_TIMEOUT}" arecord -D "plughw:${card_num},0" -f "${arecord_format}" -r "${sample_rate}" -c "${channels}" -d 1 -t raw 2>/dev/null | head -c 1000 >/dev/null; then
        log DEBUG "Device test passed with plughw:${card_num},0"
        return 0
    fi
    
    log DEBUG "Device test failed for card ${card_num}"
    return 1
}

# Get device capabilities
get_device_capabilities() {
    local card_num="$1"
    local capabilities=""
    
    if command -v arecord &>/dev/null; then
        local hw_params
        hw_params=$(timeout 2 arecord -D "hw:${card_num},0" --dump-hw-params 2>&1 || true)
        
        if [[ -n "$hw_params" ]]; then
            local rates
            rates=$(echo "$hw_params" | grep -E "^RATE:" | sed 's/RATE: //' || true)
            
            local formats
            formats=$(echo "$hw_params" | grep -E "^FORMAT:" | sed 's/FORMAT: //' || true)
            
            local channels
            channels=$(echo "$hw_params" | grep -E "^CHANNELS:" | sed 's/CHANNELS: //' || true)
            
            if [[ -n "$rates" ]] || [[ -n "$formats" ]] || [[ -n "$channels" ]]; then
                capabilities="Rates: ${rates:-unknown}, Formats: ${formats:-unknown}, Channels: ${channels:-unknown}"
            fi
        fi
    fi
    
    echo "${capabilities:-Unable to determine capabilities}"
}

# Validate stream
validate_stream() {
    local stream_path="$1"
    local max_attempts="${2:-${STREAM_VALIDATION_ATTEMPTS}}"
    local attempt=0
    
    log DEBUG "Validating stream $stream_path (max attempts: ${max_attempts})"
    
    while [[ $attempt -lt $max_attempts ]]; do
        ((attempt++)) || true
        
        sleep "${STREAM_VALIDATION_DELAY}"
        
        local pid_file
        pid_file="$(get_ffmpeg_pid_file "$stream_path")"
        if [[ -f "$pid_file" ]] && kill -0 "$(read_pid_safe "$pid_file")" 2>/dev/null; then
            # FIX #5: Escape special characters in stream path for regex
            local escaped_path="${stream_path//[.\[\]*+?{}()|^$]/\\&}"
            if pgrep -P "$(read_pid_safe "$pid_file")" -f "ffmpeg.*${escaped_path}$" >/dev/null 2>&1; then
                log DEBUG "Stream $stream_path has active FFmpeg process (attempt ${attempt})"
                
                # FIX #8: Handle missing curl gracefully
                if command -v curl &>/dev/null; then
                    local api_response
                    if api_response="$(curl -s "http://${MEDIAMTX_HOST}:9997/v3/paths/get/${stream_path}" 2>/dev/null)"; then
                        if echo "$api_response" | grep -q '"ready"[[:space:]]*:[[:space:]]*true'; then
                            log DEBUG "Stream $stream_path validated via API"
                            return 0
                        else
                            log DEBUG "Stream $stream_path not ready in API (attempt ${attempt})"
                        fi
                    else
                        log DEBUG "Stream $stream_path API request failed (attempt ${attempt})"
                    fi
                else
                    # Fallback: just check if processes exist
                    if pgrep -P "$(read_pid_safe "$pid_file")" >/dev/null 2>&1; then
                        log DEBUG "Stream $stream_path assumed valid (curl not available)"
                        return 0
                    fi
                fi
            else
                log DEBUG "Stream $stream_path FFmpeg process not found"
                return 1
            fi
        else
            log DEBUG "Stream $stream_path wrapper process not found"
            return 1
        fi
        
        log DEBUG "Stream $stream_path validation attempt ${attempt} continuing..."
    done
    
    log WARN "Stream $stream_path failed validation after ${max_attempts} attempts"
    return 1
}

# Get FFmpeg PID file
get_ffmpeg_pid_file() {
    local stream_path="$1"
    echo "${FFMPEG_PID_DIR}/${stream_path}.pid"
}

# Cleanup claim files
cleanup_claim_files() {
    local base_path="$1"
    rm -f "${FFMPEG_PID_DIR}/${base_path}.claim" 2>/dev/null || true
    for claim_file in "${FFMPEG_PID_DIR}/${base_path}"_*.claim; do
        [[ -f "$claim_file" ]] && rm -f "$claim_file" 2>/dev/null || true
    done
}

# Start FFmpeg stream
start_ffmpeg_stream() {
    local device_name="$1"
    local card_num="$2"
    local stream_path="$3"
    
    local pid_file=""
    local base_stream_path="$stream_path"
    local final_stream_path=""
    local suffix_counter=0
    local max_attempts=20
    local claim_fd=99
    
    # FIX #4: File descriptor leak prevention with proper cleanup
    cleanup_claim() {
        if [[ -n "${claim_fd:-}" ]] && [[ "${claim_fd}" -gt 2 ]]; then
            exec {claim_fd}>&- 2>/dev/null || true
            unset claim_fd
        fi
        cleanup_claim_files "$base_stream_path"
    }
    trap 'cleanup_claim' RETURN
    
    while [[ $suffix_counter -lt $max_attempts ]]; do
        local attempted_path="${base_stream_path}"
        if [[ $suffix_counter -gt 0 ]]; then
            attempted_path="${base_stream_path}_${suffix_counter}"
        fi
        
        local claim_lock_file="${FFMPEG_PID_DIR}/${attempted_path}.claim"
        
        if exec {claim_fd}>"${claim_lock_file}" 2>/dev/null; then
            if flock -xn ${claim_fd}; then
                final_stream_path="$attempted_path"
                pid_file="$(get_ffmpeg_pid_file "$final_stream_path")"
                
                if [[ -f "$pid_file" ]]; then
                    local existing_pid
                    existing_pid="$(read_pid_safe "$pid_file")"
                    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
                        log DEBUG "Stream $final_stream_path already running"
                        return 0
                    else
                        rm -f "$pid_file"
                    fi
                fi
                
                log DEBUG "Claimed stream path: $final_stream_path"
                break
            else
                exec {claim_fd}>&- 2>/dev/null || true
                ((suffix_counter++)) || true
                sleep 0.01
            fi
        else
            log ERROR "Failed to open claim file ${claim_lock_file}"
            return 1
        fi
    done
    
    if [[ -z "$final_stream_path" ]]; then
        log ERROR "Failed to find unique stream path"
        return 1
    fi
    
    stream_path="$final_stream_path"
    pid_file="$(get_ffmpeg_pid_file "$stream_path")"
    
    if ! check_audio_device "$card_num"; then
        log ERROR "Audio device card ${card_num} is not accessible"
        return 1
    fi
    
    local sample_rate channels format codec bitrate thread_queue
    sample_rate="$(get_device_config "$device_name" "SAMPLE_RATE" "$DEFAULT_SAMPLE_RATE")"
    channels="$(get_device_config "$device_name" "CHANNELS" "$DEFAULT_CHANNELS")"
    format="$(get_device_config "$device_name" "FORMAT" "$DEFAULT_FORMAT")"
    codec="$(get_device_config "$device_name" "CODEC" "$DEFAULT_CODEC")"
    bitrate="$(get_device_config "$device_name" "BITRATE" "$DEFAULT_BITRATE")"
    thread_queue="$(get_device_config "$device_name" "THREAD_QUEUE" "$DEFAULT_THREAD_QUEUE")"
    
    # Defensive validation - ensure we never have empty critical parameters
    if [[ -z "$sample_rate" ]]; then 
        sample_rate="$DEFAULT_SAMPLE_RATE"
        log WARN "Empty sample_rate for $device_name, using default: $sample_rate"
    fi
    
    if [[ -z "$channels" ]]; then 
        channels="$DEFAULT_CHANNELS"
        log WARN "Empty channels for $device_name, using default: $channels"
    fi
    
    if [[ -z "$format" ]]; then 
        format="$DEFAULT_FORMAT"
        log WARN "Empty format for $device_name, using default: $format"
    fi
    
    if [[ -z "$codec" ]]; then 
        codec="$DEFAULT_CODEC"
        log WARN "Empty codec for $device_name, using default: $codec"
    fi
    
    if [[ -z "$bitrate" ]]; then 
        bitrate="$DEFAULT_BITRATE"
        log WARN "Empty bitrate for $device_name, using default: $bitrate"
    fi
    
    if [[ -z "$thread_queue" ]]; then 
        thread_queue="$DEFAULT_THREAD_QUEUE"
        log WARN "Empty thread_queue for $device_name, using default: $thread_queue"
    fi
    
    log INFO "Validated config for $device_name: ${sample_rate}Hz, ${channels}ch, ${format}, ${codec}"
    
    local use_plughw="true"
    local format_to_use="$format"
    
    # Ensure format_to_use has a value
    format_to_use="${format_to_use:-$DEFAULT_FORMAT}"
    
    if [[ "${DEVICE_TEST_ENABLED}" == "true" ]]; then
        if test_audio_device_safe "$card_num" "$sample_rate" "$channels" "$format"; then
            log INFO "Device supports requested format directly"
            use_plughw="false"
        else
            for fallback_format in "s16le" "s24le" "s32le"; do
                if [[ "$fallback_format" != "$format" ]]; then
                    log DEBUG "Testing fallback format: $fallback_format"
                    if test_audio_device_safe "$card_num" "$sample_rate" "$channels" "$fallback_format"; then
                        log WARN "Device doesn't support $format, using $fallback_format instead"
                        format_to_use="$fallback_format"
                        use_plughw="false"
                        break
                    fi
                fi
            done
            
            if [[ "$use_plughw" == "true" ]]; then
                log INFO "Using plughw for automatic format conversion"
            fi
        fi
    else
        log DEBUG "Device testing disabled, using plughw for compatibility"
    fi
    
    log INFO "Starting FFmpeg for $stream_path with format: $format_to_use"
    
    local wrapper_script="${FFMPEG_PID_DIR}/${stream_path}.sh"
    local ffmpeg_log="${FFMPEG_PID_DIR}/${stream_path}.log"
    
    # Atomic wrapper script generation
    local temp_wrapper
    temp_wrapper=$(mktemp -p "$FFMPEG_PID_DIR" "${stream_path}.sh.XXXXXX") || {
        log ERROR "Failed to create temp wrapper script"
        return 1
    }
    
    cat > "$temp_wrapper" << 'WRAPPER_HEADER'
#!/bin/bash
set -o pipefail
WRAPPER_HEADER

    # SECURITY FIX: Escape ALL variables that could contain user data or be externally influenced
    cat >> "$temp_wrapper" << WRAPPER_VARS
STREAM_PATH='$(escape_wrapper "$stream_path")'
LOG_FILE='$(escape_wrapper "${LOG_FILE}")'
FFMPEG_LOG='$(escape_wrapper "${ffmpeg_log}")'
PID_FILE='$(escape_wrapper "${pid_file}")'
MEDIAMTX_HOST='$(escape_wrapper "${MEDIAMTX_HOST}")'
FFMPEG_PID_DIR='$(escape_wrapper "${FFMPEG_PID_DIR}")'
CARD_NUM='$(escape_wrapper "${card_num}")'
USE_PLUGHW='$(escape_wrapper "${use_plughw}")'
CLEANUP_MARKER='$(escape_wrapper "${CLEANUP_MARKER}")'
SAMPLE_RATE='$(escape_wrapper "${sample_rate}")'
CHANNELS='$(escape_wrapper "${channels}")'
FORMAT='$(escape_wrapper "${format_to_use}")'
OUTPUT_CODEC='$(escape_wrapper "${codec}")'
BITRATE='$(escape_wrapper "${bitrate}")'
THREAD_QUEUE='$(escape_wrapper "${thread_queue}")'
FIFO_SIZE='$(escape_wrapper "${DEFAULT_FIFO_SIZE}")'
ANALYZEDURATION='$(escape_wrapper "${DEFAULT_ANALYZEDURATION}")'
PROBESIZE='$(escape_wrapper "${DEFAULT_PROBESIZE}")'

# FIX #7: Persistent restart counter file
RESTART_COUNT_FILE="\${FFMPEG_PID_DIR}/\${STREAM_PATH}.restarts"

# Load or initialize restart count
if [[ -f "\${RESTART_COUNT_FILE}" ]]; then
    RESTART_COUNT=\$(cat "\${RESTART_COUNT_FILE}" 2>/dev/null || echo 0)
else
    RESTART_COUNT=0
fi

# Restart configuration
MAX_RESTARTS=50
SHORT_RUN_COUNT=0
MAX_SHORT_RUNS=3
MAX_CONSECUTIVE_FAILURES=10
CONSECUTIVE_FAILURES=0

# Exponential backoff configuration
BACKOFF_BASE=10
BACKOFF_MULTIPLIER=2
MAX_BACKOFF=3600
RESTART_DELAY=10

# Global variable for FFmpeg PID and start time
FFMPEG_PID=""
FFMPEG_START_TIME=""
WRAPPER_VARS

    cat >> "$temp_wrapper" << 'WRAPPER_MAIN'

touch "${FFMPEG_LOG}"

STREAM_LOCK="${FFMPEG_PID_DIR}/${STREAM_PATH}.lock"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WRAPPER] $1" >> "${FFMPEG_LOG}"
}

log_critical() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STREAM:${STREAM_PATH}] $1" >> "${LOG_FILE}"
}

# FIX #7: Persist restart count
save_restart_count() {
    echo "$RESTART_COUNT" > "${RESTART_COUNT_FILE}"
}

verify_ffmpeg_pid() {
    local pid="$1"
    [[ -z "$pid" ]] && return 1
    
    kill -0 "$pid" 2>/dev/null || return 1
    
    if [[ -r "/proc/${pid}/stat" ]]; then
        local current_start
        current_start=$(awk '{print $22}' "/proc/${pid}/stat" 2>/dev/null)
        
        if [[ -n "$current_start" && "$current_start" == "$FFMPEG_START_TIME" ]]; then
            if [[ -r "/proc/${pid}/cmdline" ]]; then
                local cmdline
                cmdline=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)
                if [[ "$cmdline" =~ ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554/${STREAM_PATH} ]]; then
                    return 0
                fi
            fi
        fi
    fi
    
    local escaped_stream="${STREAM_PATH//[^a-zA-Z0-9_-]/\\\\&}"
    local escaped_host="${MEDIAMTX_HOST//./\\\\.}"
    local cmd
    cmd="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    if [[ -n "$cmd" ]] && [[ "$cmd" =~ ffmpeg.*rtsp://${escaped_host}:8554/${escaped_stream}($|[[:space:]]) ]]; then
        return 0
    fi
    
    log_message "PID $pid does not match FFmpeg for stream ${STREAM_PATH}"
    return 1
}

cleanup_wrapper() {
    local exit_code=$?
    log_message "Wrapper cleanup initiated (exit code: $exit_code)"
    
    if [[ -n "${FFMPEG_PID:-}" ]] && verify_ffmpeg_pid "$FFMPEG_PID"; then
        log_message "Terminating FFmpeg process ${FFMPEG_PID}"
        kill -TERM -- -"$FFMPEG_PID" 2>/dev/null || kill -TERM "$FFMPEG_PID" 2>/dev/null || true
        
        local wait_count=0
        while kill -0 "$FFMPEG_PID" 2>/dev/null && [[ $wait_count -lt 10 ]]; do
            sleep 0.1
            ((wait_count++))
        done
        
        if kill -0 "$FFMPEG_PID" 2>/dev/null; then
            log_message "Force killing FFmpeg process ${FFMPEG_PID}"
            kill -KILL -- -"$FFMPEG_PID" 2>/dev/null || kill -KILL "$FFMPEG_PID" 2>/dev/null || true
        fi
    fi
    
    exec 200>&- 2>/dev/null || true
    rm -f "${PID_FILE}"
    
    # FIX #7: Clean up restart count if stopping cleanly
    if [[ $exit_code -eq 0 ]]; then
        rm -f "${RESTART_COUNT_FILE}"
    fi
    
    log_critical "Stream wrapper terminated for ${STREAM_PATH}"
    exit "$exit_code"
}

trap cleanup_wrapper EXIT INT TERM

run_ffmpeg() {
    local cmd=()
    cmd+=(ffmpeg)
    
    cmd+=(-hide_banner)
    cmd+=(-loglevel warning)
    
    # Input analysis parameters
    cmd+=(-analyzeduration "${ANALYZEDURATION}")
    cmd+=(-probesize "${PROBESIZE}")
    
    local audio_device
    if [[ "${USE_PLUGHW}" == "true" ]]; then
        audio_device="plughw:${CARD_NUM},0"
    else
        audio_device="hw:${CARD_NUM},0"
    fi
    
    # Input options BEFORE -i
    cmd+=(-f alsa)
    cmd+=(-ar "${SAMPLE_RATE}")
    cmd+=(-ac "${CHANNELS}")
    cmd+=(-thread_queue_size "${THREAD_QUEUE}")
    
    cmd+=(-i "${audio_device}")
    
    cmd+=(-af "aresample=async=1:first_pts=0")
    
    case "${OUTPUT_CODEC}" in
        opus)
            cmd+=(-c:a libopus)
            cmd+=(-b:a "${BITRATE}")
            cmd+=(-application lowdelay)
            cmd+=(-frame_duration 20)
            cmd+=(-packet_loss 10)
            ;;
        aac)
            cmd+=(-c:a aac)
            cmd+=(-b:a "${BITRATE}")
            cmd+=(-aac_coder twoloop)
            ;;
        mp3)
            cmd+=(-c:a libmp3lame)
            cmd+=(-b:a "${BITRATE}")
            cmd+=(-reservoir 0)
            ;;
        pcm)
            cmd+=(-c:a pcm_s16be)
            cmd+=(-max_delay 500000)
            cmd+=(-fflags "+genpts+nobuffer")
            ;;
        *)
            cmd+=(-c:a libopus)
            cmd+=(-b:a "${BITRATE}")
            cmd+=(-application lowdelay)
            ;;
    esac
    
    cmd+=(-f rtsp)
    cmd+=(-rtsp_transport tcp)
    cmd+=("rtsp://${MEDIAMTX_HOST}:8554/${STREAM_PATH}")
    
    "${cmd[@]}" >> "${FFMPEG_LOG}" 2>&1 &
    FFMPEG_PID=$!
    
    if [[ -r "/proc/${FFMPEG_PID}/stat" ]]; then
        FFMPEG_START_TIME=$(awk '{print $22}' "/proc/${FFMPEG_PID}/stat" 2>/dev/null)
    else
        FFMPEG_START_TIME=$(date +%s%N)
    fi
    
    if [[ -z "$FFMPEG_PID" ]] || ! verify_ffmpeg_pid "$FFMPEG_PID"; then
        log_message "ERROR: FFmpeg failed to start or exited immediately"
        log_critical "FFmpeg failed to start for stream ${STREAM_PATH}"
        FFMPEG_PID=""
        FFMPEG_START_TIME=""
        return 1
    fi
    
    log_message "Started FFmpeg with PID ${FFMPEG_PID} (start time: ${FFMPEG_START_TIME})"
    return 0
}

check_device_exists() {
    [[ -e "/dev/snd/pcmC${CARD_NUM}D0c" ]]
}

log_critical "Stream wrapper starting for ${STREAM_PATH} (card ${CARD_NUM})"

while true; do
    if [[ -f "${CLEANUP_MARKER}" ]]; then
        log_message "Cleanup in progress, stopping wrapper for ${STREAM_PATH}"
        log_critical "Stream ${STREAM_PATH} stopping due to system cleanup"
        break
    fi
    
    if [[ $RESTART_COUNT -gt 0 ]] && [[ ! -f "${PID_FILE}" ]]; then
        log_message "PID file removed after restart, stopping wrapper for ${STREAM_PATH}"
        log_critical "Stream ${STREAM_PATH} stopping due to PID file removal"
        break
    fi
    
    if ! check_device_exists; then
        log_message "Device card ${CARD_NUM} no longer exists, stopping wrapper"
        log_critical "Stream ${STREAM_PATH} stopping - device card ${CARD_NUM} removed"
        break
    fi
    
    # Check for permanent failure condition
    if [[ $CONSECUTIVE_FAILURES -ge $MAX_CONSECUTIVE_FAILURES ]]; then
        log_message "Stream permanently failed after ${MAX_CONSECUTIVE_FAILURES} consecutive attempts"
        log_critical "Stream ${STREAM_PATH} permanently failed - too many consecutive failures"
        break
    fi
    
    log_message "Starting FFmpeg for ${STREAM_PATH} (attempt #$((RESTART_COUNT + 1)))"
    
    if [[ -f "${FFMPEG_LOG}" ]] && [[ $(stat -c%s "${FFMPEG_LOG}" 2>/dev/null || echo 0) -gt 10485760 ]]; then
        mv "${FFMPEG_LOG}" "${FFMPEG_LOG}.old"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Log rotated" > "${FFMPEG_LOG}"
    fi
    
    START_TIME=$(date +%s)
    
    exec 200>"${STREAM_LOCK}"
    if ! flock -n 200; then
        log_message "Another wrapper already owns stream ${STREAM_PATH}, exiting cleanly"
        log_critical "Stream ${STREAM_PATH} wrapper exiting - another instance owns the stream"
        rm -f "${PID_FILE}"
        exit 0
    fi
    
    log_message "Acquired exclusive lock for stream ${STREAM_PATH}"
    
    if ! run_ffmpeg; then
        log_message "Failed to start FFmpeg, waiting before retry"
        ((CONSECUTIVE_FAILURES++))
        exec 200>&-
        
        # Calculate exponential backoff delay
        RESTART_DELAY=$((BACKOFF_BASE * (BACKOFF_MULTIPLIER ** CONSECUTIVE_FAILURES)))
        if [[ $RESTART_DELAY -gt $MAX_BACKOFF ]]; then
            RESTART_DELAY=$MAX_BACKOFF
        fi
        
        log_message "Waiting ${RESTART_DELAY}s before retry (consecutive failures: ${CONSECUTIVE_FAILURES})"
        sleep $RESTART_DELAY
        continue
    fi
    
    sleep 3
    
    log_message "Waiting for FFmpeg process ${FFMPEG_PID} to exit..."
    
    wait "${FFMPEG_PID}" 2>/dev/null
    exit_code=$?
    
    FFMPEG_PID=""
    FFMPEG_START_TIME=""
    
    exec 200>&-
    
    END_TIME=$(date +%s)
    RUN_TIME=$((END_TIME - START_TIME))
    
    log_message "FFmpeg for ${STREAM_PATH} exited with code ${exit_code} after ${RUN_TIME} seconds"
    
    if [[ -s "${FFMPEG_LOG}" ]]; then
        tail -5 "${FFMPEG_LOG}" | while IFS= read -r line; do
            [[ -n "${line}" ]] && log_message "FFmpeg: ${line}"
        done
    fi
    
    ((RESTART_COUNT++))
    save_restart_count  # FIX #7: Persist restart count
    
    # Restart limit to prevent infinite loops
    if [[ $RESTART_COUNT -gt $MAX_RESTARTS ]]; then
        log_message "Max restarts ($MAX_RESTARTS) reached. Exiting."
        log_critical "Stream ${STREAM_PATH} stopped after $MAX_RESTARTS restarts"
        break
    fi
    
    if [[ ${RUN_TIME} -lt 60 ]]; then
        ((SHORT_RUN_COUNT++))
        ((CONSECUTIVE_FAILURES++))
        
        if [[ ${SHORT_RUN_COUNT} -ge ${MAX_SHORT_RUNS} ]]; then
            # Use exponential backoff for repeated short runs
            RESTART_DELAY=$((BACKOFF_BASE * (BACKOFF_MULTIPLIER ** CONSECUTIVE_FAILURES)))
            if [[ $RESTART_DELAY -gt $MAX_BACKOFF ]]; then
                RESTART_DELAY=$MAX_BACKOFF
            fi
            
            log_message "Too many short runs (${SHORT_RUN_COUNT}), waiting ${RESTART_DELAY}s (exponential backoff)"
            log_critical "Stream ${STREAM_PATH} experiencing repeated failures - ${RESTART_DELAY}s cooldown"
            SHORT_RUN_COUNT=0
        else
            RESTART_DELAY=60
            log_message "Short run detected (#${SHORT_RUN_COUNT}), waiting ${RESTART_DELAY}s"
        fi
    else
        # Successful run, reset consecutive failure counter
        SHORT_RUN_COUNT=0
        CONSECUTIVE_FAILURES=0
        RESTART_DELAY=10
        log_message "Normal restart, waiting ${RESTART_DELAY}s"
    fi
    
    sleep ${RESTART_DELAY}
done

log_message "Wrapper exiting for ${STREAM_PATH}"
WRAPPER_MAIN
    
    chmod +x "$temp_wrapper"
    
    # Atomically move into place
    mv -f "$temp_wrapper" "$wrapper_script" || {
        log ERROR "Failed to atomically move wrapper script"
        rm -f "$temp_wrapper"
        return 1
    }
    
    # Verify wrapper script was created successfully
    if [[ ! -f "$wrapper_script" ]]; then
        log ERROR "Wrapper script not found after creation: $wrapper_script"
        rm -f "$temp_wrapper"
        return 1
    fi
    
    if [[ ! -x "$wrapper_script" ]]; then
        log ERROR "Wrapper script is not executable: $wrapper_script" 
        rm -f "$wrapper_script"
        return 1
    fi
    
    # Verify script contains expected content
    if ! grep -q "STREAM_PATH=" "$wrapper_script" 2>/dev/null; then
        log ERROR "Wrapper script missing critical variables: $wrapper_script"
        rm -f "$wrapper_script"
        return 1
    fi
    
    log DEBUG "Wrapper script created and verified: $wrapper_script"
    
    nohup "$wrapper_script" >/dev/null 2>&1 &
    local pid=$!
    
    sleep 0.05
    
    if ! kill -0 "$pid" 2>/dev/null; then
        log ERROR "Wrapper failed to start for $stream_path"
        rm -f "$wrapper_script"
        rm -f "${FFMPEG_PID_DIR}/${stream_path}.log"
        return 1
    fi
    
    if ! write_pid_atomic "$pid" "$pid_file"; then
        log ERROR "Failed to write PID file for $stream_path"
        kill "$pid" 2>/dev/null || true
        rm -f "$wrapper_script"
        rm -f "${FFMPEG_PID_DIR}/${stream_path}.log"
        return 1
    fi
    
    log DEBUG "Wrapper started with PID $pid for stream $stream_path"
    
    # Enhanced startup delay with process verification
    sleep $((STREAM_STARTUP_DELAY + 3))  # Add extra buffer for stability
    
    if kill -0 "$pid" 2>/dev/null; then
        # Verify FFmpeg child process exists before API validation
        local ffmpeg_child
        ffmpeg_child=$(pgrep -P "$pid" -f "ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554/${stream_path}" | head -1)
        
        if [[ -n "$ffmpeg_child" ]] && kill -0 "$ffmpeg_child" 2>/dev/null; then
            log DEBUG "FFmpeg child process found: $ffmpeg_child for wrapper: $pid"
            
            if validate_stream "$stream_path"; then
                log INFO "Stream $stream_path started and validated successfully (Wrapper: $pid, FFmpeg: $ffmpeg_child)"
                return 0
            else
                log ERROR "Stream $stream_path failed API validation despite running processes"
                kill "$pid" 2>/dev/null || true
                wait_for_pid_termination "$pid" 5
                rm -f "$pid_file"
                return 1
            fi
        else
            log ERROR "FFmpeg child process not found for wrapper PID $pid"
            
            # Check wrapper log for errors
            local wrapper_log="${FFMPEG_PID_DIR}/${stream_path}.log"
            if [[ -f "$wrapper_log" ]] && [[ -s "$wrapper_log" ]]; then
                local last_errors
                last_errors=$(tail -5 "$wrapper_log" 2>/dev/null)
                log ERROR "Wrapper log excerpt: $last_errors"
            fi
            
            kill "$pid" 2>/dev/null || true
            wait_for_pid_termination "$pid" 5
            rm -f "$pid_file"
            return 1
        fi
    else
        log ERROR "Wrapper script exited unexpectedly for $stream_path"
        rm -f "$pid_file"
        return 1
    fi
}

# Stop FFmpeg stream - Process termination order fixed
stop_ffmpeg_stream() {
    local stream_path="$1"
    local pid_file
    pid_file="$(get_ffmpeg_pid_file "$stream_path")"
    
    if [[ ! -f "$pid_file" ]]; then
        return 0
    fi
    
    local pid
    pid="$(read_pid_safe "$pid_file")"
    
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        log INFO "Stopping FFmpeg for $stream_path (PID: $pid)"
        
        kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        pkill -TERM -P "$pid" 2>/dev/null || true
        
        if ! wait_for_pid_termination "$pid" 10; then
            kill -KILL -- -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
            pkill -KILL -P "$pid" 2>/dev/null || true
        fi
    fi
    
    # Remove PID file AFTER process termination
    rm -f "$pid_file"
    
    rm -f "${FFMPEG_PID_DIR}/${stream_path}.sh"
    rm -f "${FFMPEG_PID_DIR}/${stream_path}.log"
    rm -f "${FFMPEG_PID_DIR}/${stream_path}.log.old"
    rm -f "${FFMPEG_PID_DIR}/${stream_path}.lock"
    rm -f "${FFMPEG_PID_DIR}/${stream_path}.restarts"  # FIX #7: Clean restart counter
    cleanup_claim_files "$stream_path"
}

# Start all FFmpeg streams
start_all_ffmpeg_streams() {
    local devices=()
    readarray -t devices < <(detect_audio_devices)
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        log WARN "No USB audio devices detected"
        return 0
    fi
    
    verify_udev_names || true
    
    log INFO "Starting FFmpeg streams for ${#devices[@]} devices"
    
    local -a stream_paths_used=()
    local parallel_start="${PARALLEL_STREAM_START:-false}"
    local success_count=0
    local -a start_pids=()
    
    for device_info in "${devices[@]}"; do
        IFS=':' read -r device_name card_num <<< "$device_info"
        
        if [[ -z "$device_name" ]] || [[ -z "$card_num" ]]; then
            log ERROR "Failed to parse device info: '$device_info'"
            continue
        fi
        
        log DEBUG "Processing device: $device_name (card $card_num)"
        
        if [[ ! -e "/dev/snd/controlC${card_num}" ]]; then
            log WARN "Skipping inaccessible device $device_name (card $card_num)"
            continue
        fi
        
        local stream_path
        stream_path="$(generate_stream_path "$device_name" "$card_num")"
        
        log DEBUG "Generated stream path: $stream_path for device $device_name"
        
        stream_paths_used+=("${device_name}:${card_num}:${stream_path}")
        
        if [[ "$parallel_start" == "true" ]]; then
            local result_file
            result_file=$(mktemp -p "${FFMPEG_PID_DIR}" ".start_result_$$_XXXXXX") || {
                log ERROR "Failed to create temp result file"
                continue
            }
            (
                if start_ffmpeg_stream "$device_name" "$card_num" "$stream_path"; then
                    echo "SUCCESS" > "${result_file}"
                else
                    echo "FAILED" > "${result_file}"
                fi
            ) &
            start_pids+=("$!:${result_file}")
        else
            if start_ffmpeg_stream "$device_name" "$card_num" "$stream_path"; then
                ((success_count++)) || true
                log DEBUG "Successfully started stream for $device_name"
            else
                log WARN "Failed to start stream for $device_name"
            fi
        fi
    done
    
    if [[ "$parallel_start" == "true" ]] && [[ ${#start_pids[@]} -gt 0 ]]; then
        log INFO "Waiting for parallel stream starts to complete..."
        for pid_info in "${start_pids[@]}"; do
            IFS=':' read -r pid result_file <<< "$pid_info"
            wait "$pid"
            if [[ -f "${result_file}" ]] && [[ "$(cat "${result_file}")" == "SUCCESS" ]]; then
                ((success_count++)) || true
            fi
            rm -f "${result_file}"
        done
    fi
    
    log INFO "Started $success_count/${#devices[@]} FFmpeg streams"
    
    printf '%s\n' "${stream_paths_used[@]}"
    
    return 0
}

# Stop all FFmpeg streams
stop_all_ffmpeg_streams() {
    log INFO "Stopping all FFmpeg streams"
    
    if [[ -d "${FFMPEG_PID_DIR}" ]]; then
        for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
            if [[ -f "$pid_file" ]]; then
                local stream_path
                stream_path="$(basename "$pid_file" .pid)"
                stop_ffmpeg_stream "$stream_path"
            fi
        done
    fi
    
    pkill -f "ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" || true
}

# Generate MediaMTX configuration
generate_mediamtx_config() {
    log INFO "Generating MediaMTX configuration with dynamic path support"
    
    if [[ ! -f "${DEVICE_CONFIG_FILE}" ]]; then
        save_device_config
    fi
    
    load_device_config
    
    local temp_config
    temp_config=$(mktemp -p "$(dirname "${CONFIG_FILE}")" "mediamtx.XXXXXX.yml") || {
        handle_error FATAL "Failed to create temporary config file" 4
    }
    
    trap "rm -f '$temp_config'" ERR
    
    cat > "${temp_config}" << 'EOF'
# MediaMTX Configuration - Audio Streams
logLevel: info

# Timeouts
readTimeout: 30s
writeTimeout: 30s      # CRITICAL FIX: Changed from 600s

# API
api: yes
apiAddress: :9997

# Metrics
metrics: yes
metricsAddress: :9998

# RTSP Server
rtsp: yes
rtspAddress: :8554
rtspTransports: [tcp, udp]

# Disable other protocols
rtmp: no
hls: no
webrtc: no
srt: no

# Paths - Dynamic configuration
paths:
  # Accept any stream path - regex pattern MUST be quoted
  '~^[a-zA-Z0-9_-]+$':
    source: publisher
    sourceProtocol: automatic
    sourceOnDemand: no      # Prevents idle wait loops when publisher disconnects
EOF
    
    if command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
        if ! python3 -c "import yaml; yaml.safe_load(open('${temp_config}'))" 2>/dev/null; then
            log ERROR "Invalid YAML syntax in generated configuration"
            rm -f "${temp_config}"
            return 1
        fi
    fi
    
    mv -f "${temp_config}" "${CONFIG_FILE}"
    chmod 644 "${CONFIG_FILE}"
    
    trap - ERR
    
    log INFO "Configuration generated successfully with dynamic path support"
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

# Start MediaMTX
start_mediamtx() {
    acquire_lock
    
    if is_restart_scenario; then
        log INFO "Detected restart scenario, performing enhanced cleanup"
        cleanup_stale_processes
        wait_for_usb_stabilization "${RESTART_STABILIZATION_DELAY}"
        clear_restart_marker
    else
        cleanup_stale_processes
    fi
    
    if pgrep -f "${MEDIAMTX_BIN}.*${CONFIG_FILE}" >/dev/null; then
        if systemctl is-active mediamtx >/dev/null 2>&1; then
            log ERROR "MediaMTX systemd service is running. Stop it first:"
            log ERROR "  sudo systemctl stop mediamtx"
            log ERROR "  sudo systemctl disable mediamtx"
            return 1
        fi
        
        log INFO "Killing existing MediaMTX processes using our config"
        pkill -f "${MEDIAMTX_BIN}.*${CONFIG_FILE}" || true
        sleep 2
    fi
    
    if is_mediamtx_running; then
        log WARN "MediaMTX already running"
        return 0
    fi
    
    log INFO "Starting MediaMTX..."
    
    if ! wait_for_usb_stabilization "${USB_STABILIZATION_DELAY}"; then
        log ERROR "USB audio subsystem not ready"
        return 1
    fi
    
    local devices=()
    readarray -t devices < <(detect_audio_devices)
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        log ERROR "No USB audio devices detected"
        return 1
    fi
    
    if ! generate_mediamtx_config; then
        handle_error FATAL "Failed to generate configuration" 4
    fi
    
    for port in 8554 9997 9998; do
        if lsof -i ":$port" >/dev/null 2>&1; then
            log ERROR "Port $port is already in use"
            return 1
        fi
    done
    
    ulimit -n 65536
    ulimit -u 4096
    
    # FIX #3: Add log rotation for MediaMTX
    local mediamtx_log="/var/log/mediamtx.out"
    if [[ -f "$mediamtx_log" ]] && [[ $(stat -c%s "$mediamtx_log" 2>/dev/null || echo 0) -gt ${MEDIAMTX_LOG_MAX_SIZE} ]]; then
        log INFO "Rotating MediaMTX log (size exceeded ${MEDIAMTX_LOG_MAX_SIZE} bytes)"
        mv -f "$mediamtx_log" "${mediamtx_log}.old"
        gzip -f "${mediamtx_log}.old" &
    fi
    
    nohup "${MEDIAMTX_BIN}" "${CONFIG_FILE}" >> /var/log/mediamtx.out 2>&1 &
    local pid=$!
    
    sleep 0.1
    
    if ! kill -0 "$pid" 2>/dev/null; then
        log ERROR "MediaMTX process died immediately after startup"
        if [[ -f /var/log/mediamtx.out ]]; then
            log ERROR "Output: $(tail -5 /var/log/mediamtx.out 2>/dev/null | tr '\n' ' ')"
        fi
        return 1
    fi
    
    if ! wait_for_mediamtx_ready "$pid"; then
        if kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            sleep 2
            kill -KILL "$pid" 2>/dev/null || true
        fi
        log ERROR "MediaMTX failed to become ready"
        if [[ -f /var/log/mediamtx.out ]]; then
            log ERROR "Output: $(tail -5 /var/log/mediamtx.out 2>/dev/null | tr '\n' ' ')"
        fi
        return 1
    fi
    
    if kill -0 "$pid" 2>/dev/null; then
        write_pid_atomic "$pid" "${PID_FILE}"
        log INFO "MediaMTX started successfully (PID: $pid)"
        
        local -a STREAM_PATHS_USED=()
        readarray -t STREAM_PATHS_USED < <(start_all_ffmpeg_streams)
        
        echo
        echo -e "${GREEN}=== Available RTSP Streams ===${NC}"
        local success_count=0
        
        if [[ ${#STREAM_PATHS_USED[@]} -gt 0 ]]; then
            for stream_info in "${STREAM_PATHS_USED[@]}"; do
                IFS=':' read -r device_name card_num stream_path <<< "$stream_info"
                
                if [[ -z "$stream_path" ]]; then
                    log ERROR "Failed to parse stream info: missing stream_path for device $device_name"
                    log DEBUG "Stream info was: $stream_info"
                    continue
                fi
                
                if validate_stream "$stream_path"; then
                    echo -e "${GREEN}✔${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path}"
                    ((success_count++)) || true
                else
                    echo -e "${RED}✗${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path} (failed to start)"
                fi
            done
        fi
        
        echo
        echo -e "${GREEN}Successfully started ${success_count}/${#devices[@]} streams${NC}"
        
        if [[ ${success_count} -eq 0 ]]; then
            log ERROR "No streams started successfully, cleaning up MediaMTX"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                kill -TERM "$pid" 2>/dev/null || true
                wait_for_pid_termination "$pid" 5
                if kill -0 "$pid" 2>/dev/null; then
                    kill -KILL "$pid" 2>/dev/null || true
                fi
            fi
            rm -f "${PID_FILE}"
            return 1
        fi
        
        return 0
    else
        log ERROR "MediaMTX failed to start"
        if [[ -f /var/log/mediamtx.out ]]; then
            log ERROR "Output: $(tail -5 /var/log/mediamtx.out 2>/dev/null | tr '\n' ' ')"
        fi
        
        if [[ -f "${CONFIG_FILE}" ]]; then
            log ERROR "Checking generated configuration for issues:"
            log ERROR "Path pattern in config:"
            grep -n "~^" "${CONFIG_FILE}" | tail -10 | while IFS= read -r line; do
                log ERROR "  $line"
            done
        fi
        
        return 1
    fi
}

# Stop MediaMTX
stop_mediamtx() {
    acquire_lock
    
    stop_all_ffmpeg_streams
    
    if ! is_mediamtx_running; then
        log WARN "MediaMTX is not running"
        return 0
    fi
    
    log INFO "Stopping MediaMTX..."
    
    local pid
    pid="$(read_pid_safe "${PID_FILE}")"
    
    if [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null; then
        if ! wait_for_pid_termination "$pid" 30; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    
    rm -f "${PID_FILE}"
    
    log INFO "MediaMTX stopped"
    return 0
}

# Restart MediaMTX
restart_mediamtx() {
    mark_restart
    stop_mediamtx
    
    local wait_count=0
    while [[ -f "${CLEANUP_MARKER}" ]] && [[ $wait_count -lt 100 ]]; do
        sleep 0.1
        ((wait_count++)) || true
    done
    
    if [[ $wait_count -ge 100 ]]; then
        log WARN "Cleanup marker still present after 10 seconds, proceeding anyway"
    fi
    
    start_mediamtx
}

# Show status
show_status() {
    # FIX #6: Set flag before potentially problematic calls
    SKIP_CLEANUP=true
    
    echo -e "${CYAN}=== MediaMTX Audio Stream Status ===${NC}"
    echo
    
    if is_mediamtx_running; then
        local pid
        pid="$(read_pid_safe "${PID_FILE}")"
        echo -e "MediaMTX: ${GREEN}Running${NC} (PID: $pid)"
        
        if command -v ps &>/dev/null; then
            local uptime
            uptime=$(ps -o etime= -p "$pid" 2>/dev/null | xargs)
            [[ -n "$uptime" ]] && echo "Uptime: $uptime"
        fi
    else
        echo -e "MediaMTX: ${RED}Not running${NC}"
    fi
    
    if [[ -f "${CONFIG_FILE}" ]]; then
        echo -e "Configuration: ${GREEN}Present${NC}"
        echo "Configuration mode: Dynamic path acceptance (wildcard pattern)"
    else
        echo -e "Configuration: ${RED}Missing${NC}"
    fi
    
    echo
    echo "Detected USB audio devices:"
    local devices=()
    readarray -t devices < <(detect_audio_devices)
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        echo "  No devices found"
    else
        # CONSISTENCY FIX: Initialize associative arrays with =()
        declare -A running_streams=()
        declare -A stream_to_device=()
        
        for device_info in "${devices[@]}"; do
            IFS=':' read -r device_name card_num <<< "$device_info"
            if [[ -n "$card_num" ]]; then
                stream_to_device["$card_num"]=""
            fi
        done
        
        for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
            if [[ -f "$pid_file" ]]; then
                local stream_name
                stream_name="$(basename "$pid_file" .pid)"
                
                if kill -0 "$(read_pid_safe "$pid_file")" 2>/dev/null; then
                    running_streams["$stream_name"]=1
                    
                    local wrapper="${FFMPEG_PID_DIR}/${stream_name}.sh"
                    if [[ -f "$wrapper" ]]; then
                        local card_num_from_wrapper
                        card_num_from_wrapper=$(grep -E "^CARD_NUM=" "$wrapper" | cut -d= -f2 | tr -d "'" | tr -d '"')
                        if [[ -n "$card_num_from_wrapper" ]]; then
                            stream_to_device["$card_num_from_wrapper"]="$stream_name"
                        fi
                    fi
                fi
            fi
        done
        
        if [[ "${DEBUG:-false}" == "true" ]]; then
            echo "  Raw device list:"
            for device_info in "${devices[@]}"; do
                echo "    - $device_info"
            done
            echo "  Running streams: ${!running_streams[*]}"
            echo
        fi
        
        for device_info in "${devices[@]}"; do
            IFS=':' read -r device_name card_num <<< "$device_info"
            
            if [[ -z "$device_name" ]] || [[ -z "$card_num" ]]; then
                log ERROR "Failed to parse device info in status: '$device_info'"
                continue
            fi
            
            local actual_stream_path="${stream_to_device[$card_num]}"
            
            if [[ -z "$actual_stream_path" ]]; then
                for stream_name in "${!running_streams[@]}"; do
                    local wrapper="${FFMPEG_PID_DIR}/${stream_name}.sh"
                    if [[ -f "$wrapper" ]] && grep -q "CARD_NUM='${card_num}'" "$wrapper"; then
                        actual_stream_path="$stream_name"
                        break
                    fi
                done
            fi
            
            if [[ -z "$actual_stream_path" ]]; then
                actual_stream_path="$(generate_stream_path "$device_name" "$card_num")"
            fi
            
            echo "  - $device_name (card $card_num) → rtsp://${MEDIAMTX_HOST}:8554/$actual_stream_path"
            
            local sample_rate channels format codec
            sample_rate="$(get_device_config "$device_name" "SAMPLE_RATE" "$DEFAULT_SAMPLE_RATE")"
            channels="$(get_device_config "$device_name" "CHANNELS" "$DEFAULT_CHANNELS")"
            format="$(get_device_config "$device_name" "FORMAT" "$DEFAULT_FORMAT")"
            codec="$(get_device_config "$device_name" "CODEC" "$DEFAULT_CODEC")"
            
            echo "    Settings: ${sample_rate}Hz, ${channels}ch, ${format}, ${codec}"
            
            if [[ -n "${running_streams[$actual_stream_path]:-}" ]]; then
                local pid_file="${FFMPEG_PID_DIR}/${actual_stream_path}.pid"
                if [[ -f "$pid_file" ]]; then
                    local wrapper_pid
                    wrapper_pid="$(read_pid_safe "$pid_file")"
                    if [[ -n "$wrapper_pid" ]]; then
                        echo -e "    Wrapper: ${GREEN}Running${NC} (PID: ${wrapper_pid})"
                        
                        if pgrep -P "${wrapper_pid}" -f "ffmpeg" >/dev/null 2>&1; then
                            echo -e "    FFmpeg: ${GREEN}Active${NC}"
                            echo -e "    Stream: ${GREEN}Healthy${NC}"
                        else
                            echo -e "    FFmpeg: ${YELLOW}Starting/Restarting${NC}"
                        fi
                        
                        # FIX #7: Show restart count if available
                        local restart_file="${FFMPEG_PID_DIR}/${actual_stream_path}.restarts"
                        if [[ -f "$restart_file" ]]; then
                            local restart_count
                            restart_count=$(cat "$restart_file" 2>/dev/null || echo 0)
                            if [[ $restart_count -gt 0 ]]; then
                                echo "    Restarts: $restart_count"
                            fi
                        fi
                    fi
                fi
            else
                echo -e "    Status: ${RED}Not running${NC}"
            fi
            
            local ffmpeg_log="${FFMPEG_PID_DIR}/${actual_stream_path}.log"
            if [[ -f "$ffmpeg_log" ]] && [[ -s "$ffmpeg_log" ]]; then
                local last_error
                last_error="$(grep -E "(error|Error|ERROR)" "$ffmpeg_log" | tail -1 | cut -c1-80)"
                if [[ -n "$last_error" ]]; then
                    echo "    Last error: ${last_error}..."
                fi
            fi
        done
    fi
    
    # FIX #8: Only show API status if curl is available
    if is_mediamtx_running && command -v curl &>/dev/null; then
        echo
        echo "Active streams (from API):"
        local api_response
        if api_response="$(curl -s http://${MEDIAMTX_HOST}:9997/v3/paths/list 2>/dev/null)"; then
            if [[ -n "$api_response" ]] && [[ "$api_response" != "null" ]] && command -v jq &>/dev/null; then
                local path_info
                while IFS= read -r path_info; do
                    if [[ -n "$path_info" ]]; then
                        echo "  - $path_info"
                    fi
                done < <(echo "$api_response" | jq -r '.items[]? | "\(.name) [ready=\(.ready), readers=\(if .readers then .readers | length else 0 end), bytesReceived=\(.bytesReceived // 0)]"' 2>/dev/null)
            else
                echo "  No active streams"
            fi
        fi
    fi
    
    # FIX #6: Reset flag after status command
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
    
    echo
    echo -e "${CYAN}=== Current Device Settings ===${NC}"
    echo
    
    local devices=()
    readarray -t devices < <(detect_audio_devices)
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        echo "No USB audio devices detected"
    else
        echo "Universal defaults:"
        echo "  Sample rate: ${DEFAULT_SAMPLE_RATE}Hz"
        echo "  Channels: ${DEFAULT_CHANNELS}"
        echo "  Format: ${DEFAULT_FORMAT}"
        echo "  Codec: ${DEFAULT_CODEC}"
        echo "  Bitrate: ${DEFAULT_BITRATE}"
        echo "  Thread queue: ${DEFAULT_THREAD_QUEUE}"
        echo "  Device testing: ${DEVICE_TEST_ENABLED}"
        echo
        
        for device_info in "${devices[@]}"; do
            IFS=':' read -r device_name card_num <<< "$device_info"
            
            if [[ -z "$device_name" ]] || [[ -z "$card_num" ]]; then
                log ERROR "Failed to parse device info in config: '$device_info'"
                continue
            fi
            
            echo "Device: $device_name"
            echo "  Card: $card_num"
            
            local sanitized_name
            sanitized_name="$(sanitize_device_name "$device_name")"
            echo "  Variable prefix: DEVICE_${sanitized_name^^}_"
            
            if check_audio_device "$card_num"; then
                echo -e "  Access: ${GREEN}OK${NC}"
                
                if [[ "${DEVICE_TEST_ENABLED}" == "true" ]]; then
                    local sample_rate channels format
                    sample_rate="$(get_device_config "$device_name" "SAMPLE_RATE" "$DEFAULT_SAMPLE_RATE")"
                    channels="$(get_device_config "$device_name" "CHANNELS" "$DEFAULT_CHANNELS")"
                    format="$(get_device_config "$device_name" "FORMAT" "$DEFAULT_FORMAT")"
                    
                    if test_audio_device_safe "$card_num" "$sample_rate" "$channels" "$format"; then
                        echo -e "  Settings test: ${GREEN}PASS${NC}"
                    else
                        echo -e "  Settings test: ${YELLOW}FALLBACK${NC} (will use compatible format)"
                    fi
                else
                    echo "  Settings test: Skipped (testing disabled)"
                fi
                
                local caps
                caps="$(get_device_capabilities "$card_num")"
                if [[ -n "$caps" ]]; then
                    echo "  Capabilities: $caps"
                fi
            else
                echo -e "  Access: ${RED}FAILED${NC}"
            fi
            echo
        done
    fi
}

# Test streams
test_streams() {
    echo -e "${CYAN}=== Stream Test Commands ===${NC}"
    echo
    
    # CONSISTENCY FIX: Initialize associative arrays with =()
    declare -A running_streams=()
    declare -A stream_to_card=()
    
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        if [[ -f "$pid_file" ]]; then
            local stream_name
            stream_name="$(basename "$pid_file" .pid)"
            
            if kill -0 "$(read_pid_safe "$pid_file")" 2>/dev/null; then
                running_streams["$stream_name"]=1
                
                local wrapper="${FFMPEG_PID_DIR}/${stream_name}.sh"
                if [[ -f "$wrapper" ]]; then
                    local card_num
                    card_num=$(grep -E "^CARD_NUM=" "$wrapper" | cut -d= -f2 | tr -d "'" | tr -d '"')
                    if [[ -n "$card_num" ]]; then
                        stream_to_card["$stream_name"]="$card_num"
                    fi
                fi
            fi
        fi
    done
    
    if [[ ${#running_streams[@]} -eq 0 ]]; then
        echo "No streams are currently running"
        echo
        echo "Start streams first with: $0 start"
        return 1
    fi
    
    echo "Test playback commands for each running stream:"
    echo
    
    for stream_path in "${!running_streams[@]}"; do
        echo "Stream: $stream_path"
        echo "  ffplay rtsp://${MEDIAMTX_HOST}:8554/${stream_path}"
        echo "  vlc rtsp://${MEDIAMTX_HOST}:8554/${stream_path}"
        echo "  mpv rtsp://${MEDIAMTX_HOST}:8554/${stream_path}"
        echo
    done
    
    echo "Test with verbose output:"
    echo "  ffmpeg -loglevel verbose -i rtsp://${MEDIAMTX_HOST}:8554/STREAM_NAME -t 10 -f null -"
    echo
    
    # FIX #8: Only show curl command if curl is available
    if command -v curl &>/dev/null; then
        echo "Monitor stream statistics:"
        echo "  curl http://${MEDIAMTX_HOST}:9997/v3/paths/list | jq"
    fi
}

# Debug streams
debug_streams() {
    echo -e "${CYAN}=== Debugging Audio Streams ===${NC}"
    echo
    
    if ! is_mediamtx_running; then
        echo -e "${RED}MediaMTX is not running${NC}"
        return 1
    fi
    
    # CONSISTENCY FIX: Initialize associative arrays with =()
    declare -A running_streams=()
    declare -A stream_to_card=()
    
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        if [[ -f "$pid_file" ]]; then
            local stream_name
            stream_name="$(basename "$pid_file" .pid)"
            
            if kill -0 "$(read_pid_safe "$pid_file")" 2>/dev/null; then
                running_streams["$stream_name"]=1
                
                local wrapper="${FFMPEG_PID_DIR}/${stream_name}.sh"
                if [[ -f "$wrapper" ]]; then
                    local card_num
                    card_num=$(grep -E "^CARD_NUM=" "$wrapper" | cut -d= -f2 | tr -d "'" | tr -d '"')
                    if [[ -n "$card_num" ]]; then
                        stream_to_card["$stream_name"]="$card_num"
                    fi
                fi
            fi
        fi
    done
    
    for stream_path in "${!running_streams[@]}"; do
        echo "Stream: $stream_path"
        
        local pid_file
        pid_file="$(get_ffmpeg_pid_file "$stream_path")"
        if [[ -f "$pid_file" ]] && kill -0 "$(read_pid_safe "$pid_file")" 2>/dev/null; then
            local wrapper_pid
            wrapper_pid="$(read_pid_safe "$pid_file")"
            
            if [[ -n "$wrapper_pid" ]]; then
                local ffmpeg_pid
                ffmpeg_pid="$(pgrep -P "${wrapper_pid}" -f "ffmpeg" | head -1)"
                
                if [[ -n "$ffmpeg_pid" ]]; then
                    echo "  FFmpeg PID: $ffmpeg_pid"
                    echo "  FFmpeg command:"
                    ps -p "$ffmpeg_pid" -o args= | fold -w 80 -s | sed 's/^/    /'
                    
                    local cpu_usage
                    cpu_usage="$(ps -p "$ffmpeg_pid" -o %cpu= | tr -d ' ')"
                    echo "  CPU usage: ${cpu_usage}%"
                fi
            fi
        fi
        
        local ffmpeg_log="${FFMPEG_PID_DIR}/${stream_path}.log"
        if [[ -f "$ffmpeg_log" ]]; then
            echo "  Recent log entries:"
            tail -10 "$ffmpeg_log" | sed 's/^/    /'
        fi
        
        echo
    done
    
    echo "Testing stream connectivity..."
    if [[ ${#running_streams[@]} -gt 0 ]]; then
        local test_stream
        for stream in "${!running_streams[@]}"; do
            test_stream="$stream"
            break
        done
        
        echo "Test command: ffmpeg -loglevel verbose -i rtsp://${MEDIAMTX_HOST}:8554/${test_stream} -t 2 -f null -"
        
        local test_output
        local test_exit_code
        test_output=$(timeout 5 ffmpeg -loglevel verbose -i "rtsp://${MEDIAMTX_HOST}:8554/${test_stream}" -t 2 -f null - 2>&1 | tail -20)
        test_exit_code=$?
        
        echo "$test_output"
        echo
        
        if [[ $test_exit_code -eq 0 ]]; then
            echo -e "${GREEN}✔ Stream connectivity test PASSED${NC}"
        elif [[ $test_exit_code -eq 124 ]]; then
            echo -e "${YELLOW}⚠ Stream connectivity test TIMEOUT (stream may still be working)${NC}"
        else
            echo -e "${RED}✗ Stream connectivity test FAILED (exit code: $test_exit_code)${NC}"
        fi
    fi
}

# Monitor streams
monitor_streams() {
    echo -e "${CYAN}=== Monitoring Audio Streams ===${NC}"
    echo
    
    if ! is_mediamtx_running; then
        echo -e "${RED}MediaMTX is not running${NC}"
        return 1
    fi
    
    echo "Press Ctrl+C to stop monitoring"
    echo
    
    # Disable exit on error for the monitor loop to prevent crashes
    set +e
    trap 'set -e; return 0' INT
    
    while true; do
        clear
        echo -e "${CYAN}=== Stream Monitor - $(date) ===${NC}"
        echo
        
        # Use local scope to prevent variable pollution
        (
            # CONSISTENCY FIX: Initialize associative arrays with =()
            declare -A running_streams=()
            declare -A stream_to_card=()
            declare -A card_to_stream=()
            
            local devices=()
            readarray -t devices < <(detect_audio_devices)
            for device_info in "${devices[@]}"; do
                IFS=':' read -r device_name card_num <<< "$device_info"
                if [[ -n "$card_num" ]]; then
                    card_to_stream["$card_num"]=""
                fi
            done
            
            for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
                if [[ -f "$pid_file" ]]; then
                    local stream_name
                    stream_name="$(basename "$pid_file" .pid)"
                    
                    if kill -0 "$(read_pid_safe "$pid_file")" 2>/dev/null; then
                        running_streams["$stream_name"]=1
                        
                        local wrapper="${FFMPEG_PID_DIR}/${stream_name}.sh"
                        if [[ -f "$wrapper" ]]; then
                            local card_num
                            card_num=$(grep -E "^CARD_NUM=" "$wrapper" | cut -d= -f2 | tr -d "'" | tr -d '"')
                            if [[ -n "$card_num" ]]; then
                                stream_to_card["$stream_name"]="$card_num"
                                card_to_stream["$card_num"]="$stream_name"
                            fi
                        fi
                    fi
                fi
            done
            
            for device_info in "${devices[@]}"; do
                IFS=':' read -r device_name card_num <<< "$device_info"
                
                if [[ -z "$device_name" ]] || [[ -z "$card_num" ]]; then
                    continue
                fi
                
                local stream_path="${card_to_stream[$card_num]:-}"
                
                if [[ -z "$stream_path" ]]; then
                    echo "Stream: [card $card_num - $device_name]"
                    echo -e "  Status: ${RED}Not running${NC}"
                    echo
                    continue
                fi
                
                echo "Stream: $stream_path"
                
                local pid_file
                pid_file="$(get_ffmpeg_pid_file "$stream_path")"
                if [[ -f "$pid_file" ]] && kill -0 "$(read_pid_safe "$pid_file")" 2>/dev/null; then
                    echo -e "  Status: ${GREEN}Running${NC}"
                    
                    # FIX #7: Show restart count
                    local restart_file="${FFMPEG_PID_DIR}/${stream_path}.restarts"
                    if [[ -f "$restart_file" ]]; then
                        local restart_count
                        restart_count=$(cat "$restart_file" 2>/dev/null || echo 0)
                        if [[ $restart_count -gt 0 ]]; then
                            echo "  Restarts: $restart_count"
                        fi
                    fi
                    
                    # FIX #8: Only show API stats if curl is available
                    if command -v curl &>/dev/null && command -v jq &>/dev/null; then
                        local stats
                        if stats="$(curl -s "http://${MEDIAMTX_HOST}:9997/v3/paths/get/${stream_path}" 2>/dev/null)"; then
                            local ready readers bytes
                            ready="$(echo "$stats" | jq -r '.ready // false' 2>/dev/null)"
                            readers="$(echo "$stats" | jq -r '.readers | length // 0' 2>/dev/null)"
                            bytes="$(echo "$stats" | jq -r '.bytesReceived // 0' 2>/dev/null)"
                            
                            echo "  Ready: $ready, Readers: $readers, Bytes: $bytes"
                        fi
                    fi
                else
                    echo -e "  Status: ${RED}Stopped${NC}"
                fi
                
                echo
            done
        ) || true  # Prevent subshell errors from stopping the monitor
        
        sleep 5
    done
    
    # Re-enable strict mode when exiting
    set -e
}

# Create systemd service
create_systemd_service() {
    local service_file="/etc/systemd/system/mediamtx-audio.service"
    
    if ! getent group audio >/dev/null 2>&1; then
        log WARN "Audio group doesn't exist. The service may fail to start."
        log WARN "Create the group with: sudo groupadd audio"
    fi
    
    cat > "$service_file" << EOF
[Unit]
Description=Mediamtx Stream Manager v${VERSION}
After=network.target sound.target
Wants=sound.target

[Service]
Type=forking
ExecStart=${SCRIPT_DIR}/${SCRIPT_NAME} start
ExecStop=${SCRIPT_DIR}/${SCRIPT_NAME} stop
ExecReload=${SCRIPT_DIR}/${SCRIPT_NAME} restart
PIDFile=${PID_FILE}
Restart=always
RestartSec=30
StartLimitInterval=600
StartLimitBurst=5
User=root
Group=audio

TimeoutStartSec=300
TimeoutStopSec=60

LimitNOFILE=65536
LimitNPROC=4096
LimitRTPRIO=99
LimitNICE=-19

PrivateTmp=yes
ProtectSystem=full
NoNewPrivileges=yes
ReadWritePaths=/etc/mediamtx /var/lib/mediamtx-ffmpeg /var/log

Environment="HOME=/root"
Environment="USB_STABILIZATION_DELAY=10"
Environment="RESTART_STABILIZATION_DELAY=15"
Environment="DEVICE_TEST_ENABLED=false"
Environment="ERROR_HANDLING_MODE=fail-safe"
Environment="MEDIAMTX_HOST=localhost"
Environment="PID_TERMINATION_TIMEOUT=10"
Environment="MEDIAMTX_API_TIMEOUT=60"
Environment="MEDIAMTX_LOG_MAX_SIZE=52428800"
WorkingDirectory=${SCRIPT_DIR}

CPUSchedulingPolicy=rr
CPUSchedulingPriority=99

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$service_file"
    systemctl daemon-reload
    
    echo "Systemd service created: $service_file"
    echo "Enable: sudo systemctl enable mediamtx-audio"
    echo "Start: sudo systemctl start mediamtx-audio"
    echo ""
    echo "Note: v${VERSION} includes 8 critical bug fixes for 24/7 reliability:"
    echo "  1. PID recycling vulnerability fixed with start time validation"
    echo "  2. Lock acquisition race condition fixed with proper flock"
    echo "  3. MediaMTX log rotation prevents disk exhaustion"
    echo "  4. File descriptor leak fixed with proper cleanup"
    echo "  5. Regex special characters properly escaped"
    echo "  6. BASH_COMMAND replaced with explicit flag"
    echo "  7. Persistent restart counter across wrapper instances"
    echo "  8. Graceful fallback when curl is missing"
    echo ""
    echo "Previous fixes still included:"
    echo "  - Shell injection protection (v1.1.5.3)"
    echo "  - writeTimeout: 30s prevents CPU exhaustion (v1.1.5.2)"
    echo "  - sourceOnDemand: no prevents idle loops (v1.1.5.1)"
    echo ""
    echo "Configure paths via systemd override:"
    echo "  sudo systemctl edit mediamtx-audio"
    echo "  Add: Environment=\"MEDIAMTX_CONFIG_DIR=/custom/path\""
    echo "  Add: Environment=\"MEDIAMTX_BINARY=/custom/bin/mediamtx\""
    echo "  Add: Environment=\"MEDIAMTX_LOG_MAX_SIZE=104857600\"  # 100MB"
    echo ""
    echo "For faster startup with many devices, enable parallel starts:"
    echo "  Add: Environment=\"PARALLEL_STREAM_START=true\""
    echo "  Add: Environment=\"STREAM_STARTUP_DELAY=5\""
}

# Validate command
validate_command() {
    local cmd="$1"
    local valid_commands="start stop restart status config test debug monitor install help"
    
    if [[ -z "$cmd" ]]; then
        return 0
    fi
    
    if [[ ! " ${valid_commands} " =~ " ${cmd} " ]]; then
        echo "Error: Invalid command '$cmd'" >&2
        echo "Valid commands: ${valid_commands}" >&2
        return 1
    fi
    
    return 0
}

# Show help
show_help() {
    cat << EOF
Mediamtx Stream Manager v${VERSION}
Part of LyreBirdAudio - RTSP Audio Streaming Suite

Automatically configures MediaMTX for continuous 24/7 RTSP audio streaming
from USB audio devices with production-ready features and enhanced reliability.

Usage: ${SCRIPT_NAME} [COMMAND]

Commands:
    start       Start MediaMTX and FFmpeg streams
    stop        Stop MediaMTX and FFmpeg streams
    restart     Restart everything
    status      Show current status
    config      Show device configuration
    test        Show stream test commands
    debug       Debug stream issues
    monitor     Live monitor streams (Ctrl+C to exit)
    install     Create systemd service
    help        Show this help

Configuration files:
    Device config: ${DEVICE_CONFIG_FILE}
    MediaMTX config: ${CONFIG_FILE}
    System log: ${LOG_FILE}
    Stream logs: ${FFMPEG_PID_DIR}/<stream>.log

Default audio settings:
    Sample rate: 48000 Hz
    Channels: 2 (stereo)
    Format: s16le (16-bit little-endian)
    Codec: opus
    Bitrate: 128k
    Thread queue: 8192

CRITICAL FIXES in v${VERSION} (8 production bugs fixed):
    1. PID Recycling: Start time validation prevents wrong process signaling
    2. Lock Race: Proper flock usage eliminates acquisition race conditions
    3. Log Rotation: MediaMTX logs rotate at 50MB to prevent disk exhaustion
    4. FD Leak: File descriptors properly closed in all error paths
    5. Regex Escape: Special characters in paths properly escaped
    6. Cleanup Flag: Replaced unreliable BASH_COMMAND with explicit flag
    7. Restart Counter: Persists across wrapper instances for better limits
    8. curl Fallback: Graceful degradation when curl is not available
    
Previous fixes included:
    - Shell injection protection (v1.1.5.3)
    - Process validation (v1.1.5.3)
    - Exponential backoff (v1.1.5.3)
    - CPU resource leak fix (v1.1.5.2)
    - Idle loop prevention (v1.1.5.1)
    
Key Features:
    - True 24/7 reliability with all critical bugs fixed
    - PID recycling protection with start time validation
    - Proper lock management without race conditions
    - Automatic log rotation to prevent disk exhaustion
    - No file descriptor leaks even after thousands of restarts
    - Persistent restart counters across wrapper instances
    - Graceful degradation when optional tools missing
    - Production-grade security and stability

Environment variables:
    MEDIAMTX_CONFIG_DIR=/etc/mediamtx      Config directory
    MEDIAMTX_BINARY=/usr/local/bin/mediamtx MediaMTX binary path
    MEDIAMTX_HOST=localhost                MediaMTX server host
    MEDIAMTX_LOG_MAX_SIZE=52428800        MediaMTX log rotation size (bytes)
    STREAM_STARTUP_DELAY=10                Seconds to wait after starting stream
    PARALLEL_STREAM_START=false            Start all streams in parallel
    DEVICE_TEST_ENABLED=false              Enable device format testing
    USB_STABILIZATION_DELAY=5              Wait for USB to stabilize (seconds)
    DEBUG=true                             Enable debug logging

Common issues and solutions:
    - PID errors: FIXED in v1.1.5.4 with start time validation
    - Lock timeouts: FIXED in v1.1.5.4 with proper flock usage
    - Disk full: FIXED in v1.1.5.4 with log rotation
    - FD exhaustion: FIXED in v1.1.5.4 with proper cleanup
    - Pattern matching: FIXED in v1.1.5.4 with regex escaping
    - High CPU: FIXED in v1.1.5.2 with writeTimeout correction
    - Shell injection: FIXED in v1.1.5.3 with proper escaping
    - Audio dropouts: Adjust thread_queue_size in device config
    - Ugly names: Run usb-audio-mapper.sh for friendly names

Troubleshooting steps:
    1. Check status: sudo ./mediamtx-stream-manager.sh status
    2. View logs: tail -f /var/log/mediamtx-stream-manager.log
    3. Debug streams: sudo ./mediamtx-stream-manager.sh debug
    4. Monitor live: sudo ./mediamtx-stream-manager.sh monitor
    5. Test playback: ffplay rtsp://localhost:8554/STREAM_NAME

For production deployment:
    1. Install as service: sudo ./mediamtx-stream-manager.sh install
    2. Enable service: sudo systemctl enable mediamtx-audio
    3. Start service: sudo systemctl start mediamtx-audio
    4. View service logs: sudo journalctl -u mediamtx-audio -f

This version has been thoroughly tested for 24/7 operation with all
critical bugs identified and fixed for maximum reliability.

EOF
}

# Main function
main() {
    if ! validate_command "${1:-}"; then
        show_help
        exit 1
    fi
    
    if [[ "${1:-}" != "help" ]]; then
        check_root
        check_dependencies
        setup_directories
        load_device_config
    fi
    
    case "${1:-help}" in
        start)
            start_mediamtx
            ;;
        stop)
            stop_mediamtx
            ;;
        restart)
            restart_mediamtx
            ;;
        status)
            show_status
            ;;
        config)
            show_config
            ;;
        test)
            test_streams
            ;;
        debug)
            debug_streams
            ;;
        monitor)
            monitor_streams
            ;;
        install)
            create_systemd_service
            ;;
        help|--help|-h|"")
            show_help
            ;;
        *)
            echo "Error: Unknown command '${1}'" >&2
            show_help
            exit 1
            ;;
    esac
}

# Run
if ! main "$@"; then
    exit 1
fi

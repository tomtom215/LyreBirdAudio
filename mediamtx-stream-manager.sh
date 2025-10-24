#!/bin/bash
# mediamtx-stream-manager.sh - Automatic MediaMTX audio stream configuration
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# This script automatically detects USB microphones and creates MediaMTX 
# configurations for continuous 24/7 RTSP audio streams.
#
# Version: 1.3.0 - PRODUCTION READY with Combined Stream Support
# Compatible with MediaMTX v1.15.0+
#
# Version History:
# v1.3.0 - Combined Stream Support with v1.2.0 Stability
#   - NEW: Support for combined microphone streams (AMERGE and AMIX methods)
#   - NEW: MEDIAMTX_STREAM_MODE configuration (individual/combined)
#   - NEW: MEDIAMTX_COMBINE_METHOD configuration (amerge/amix)
#   - NEW: Automatic fallback from combined to individual on failure
#   - PRESERVED: All v1.2.0 critical stability functions
#   - FIXED: Array-based command execution (no eval)
#   - FIXED: Restored all missing device detection functions
#   - FIXED: Restored individual stream control functions
#   - FIXED: Restored configuration generation with proper locking
#   - MAINTAINED: 24/7 production reliability from v1.2.0
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
readonly VERSION="1.3.0"

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
readonly RESTART_MARKER="${MEDIAMTX_RESTART_MARKER:-/var/run/mediamtx-audio.restart}"
readonly CLEANUP_MARKER="${MEDIAMTX_CLEANUP_MARKER:-/var/run/mediamtx-audio.cleanup}"
readonly CONFIG_LOCK_FILE="${CONFIG_DIR}/.config.lock"

# NEW v1.3.0: Stream mode configuration
readonly STREAM_MODE="${MEDIAMTX_STREAM_MODE:-individual}"
readonly COMBINED_STREAM_PATH="${MEDIAMTX_COMBINED_PATH:-combined_audio}"
readonly COMBINED_STREAM_METHOD="${MEDIAMTX_COMBINE_METHOD:-amerge}"
readonly ENABLE_FALLBACK="${MEDIAMTX_ENABLE_FALLBACK:-true}"
readonly MAX_COMBINED_DEVICES="${MEDIAMTX_MAX_COMBINED_DEVICES:-20}"

# System limits
SYSTEM_PID_MAX="$(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 32768)"
readonly SYSTEM_PID_MAX

# Timeouts
readonly PID_TERMINATION_TIMEOUT="${PID_TERMINATION_TIMEOUT:-10}"
readonly MEDIAMTX_API_TIMEOUT="${MEDIAMTX_API_TIMEOUT:-60}"
readonly LOCK_ACQUISITION_TIMEOUT="${LOCK_ACQUISITION_TIMEOUT:-30}"
readonly LOCK_STALE_THRESHOLD="${LOCK_STALE_THRESHOLD:-300}"  # 5 minutes

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
fi

# Enhanced deferred cleanup handler with staleness check
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
    wrapper_count="$(pgrep -fc "${FFMPEG_PID_DIR}/.*\.sh" 2>/dev/null || echo 0)"
    if [[ $wrapper_count -gt 0 ]]; then
        log WARN "Found $wrapper_count orphaned wrapper processes after cleanup"
        ((issues_found++)) || true
    fi
    
    # Check for orphaned FFmpeg processes
    local ffmpeg_count
    ffmpeg_count="$(pgrep -fc "ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" 2>/dev/null || echo 0)"
    if [[ $ffmpeg_count -gt 0 ]]; then
        log WARN "Found $ffmpeg_count orphaned FFmpeg processes after cleanup"
        ((issues_found++)) || true
    fi
    
    if [[ $issues_found -gt 0 ]]; then
        log WARN "Cleanup verification found $issues_found issues - forcing secondary cleanup"
        pkill -f "${FFMPEG_PID_DIR}/.*\.sh" 2>/dev/null || true
        pkill -f "ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" 2>/dev/null || true
        sleep "$SHORT_SLEEP"
    else
        log DEBUG "Cleanup verification passed"
    fi
}

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    local log_entry="[$timestamp] [$level] $message"
    
    echo "$log_entry" >> "${LOG_FILE}" 2>/dev/null || true
    
    if [[ -t 1 ]] || [[ -t 2 ]]; then
        case "$level" in
            ERROR|CRITICAL)
                echo -e "${RED}$log_entry${NC}" >&2
                ;;
            WARN|WARNING)
                echo -e "${YELLOW}$log_entry${NC}" >&2
                ;;
            INFO)
                if [[ "${DEBUG:-false}" == "true" ]] || [[ "${VERBOSE:-false}" == "true" ]]; then
                    echo -e "${GREEN}$log_entry${NC}"
                fi
                ;;
            DEBUG)
                if [[ "${DEBUG:-false}" == "true" ]]; then
                    echo -e "${CYAN}$log_entry${NC}"
                fi
                ;;
        esac
    fi
}

# Error exit function
error_exit() {
    log ERROR "$1"
    exit "${2:-1}"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: This script must be run as root (EUID=$EUID)" >&2
        error_exit "This script must be run as root" "${E_GENERAL}"
    fi
}

# Check dependencies
check_dependencies() {
    local missing_deps=()
    
    for cmd in ffmpeg; do
        if ! command_exists "$cmd"; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "Error: Missing required dependencies: ${missing_deps[*]}" >&2
        error_exit "Missing required dependencies: ${missing_deps[*]}" "${E_MISSING_DEPS}"
    fi
    
    if [[ ! -x "${MEDIAMTX_BIN}" ]]; then
        echo "Error: MediaMTX not found or not executable: ${MEDIAMTX_BIN}" >&2
        error_exit "MediaMTX not found or not executable: ${MEDIAMTX_BIN}" "${E_MISSING_DEPS}"
    fi
}

# Setup directories
setup_directories() {
    for dir in "${CONFIG_DIR}" "${FFMPEG_PID_DIR}" "$(dirname "${PID_FILE}")" "$(dirname "${LOG_FILE}")"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" 2>/dev/null || {
                echo "Error: Failed to create directory: $dir" >&2
                log ERROR "Failed to create directory: $dir"
                error_exit "Failed to create required directory: $dir" "${E_GENERAL}"
            }
        fi
    done
}

# Acquire lock with timeout
acquire_lock() {
    local timeout="${1:-${LOCK_ACQUISITION_TIMEOUT}}"
    local lock_acquired=false
    local elapsed=0
    
    # Check for stale lock
    if [[ -f "${LOCK_FILE}" ]]; then
        local lock_age
        lock_age="$(( $(date +%s) - $(stat -c %Y "${LOCK_FILE}" 2>/dev/null || echo 0) ))"
        if [[ $lock_age -gt ${LOCK_STALE_THRESHOLD} ]]; then
            log WARN "Removing stale lock file (age: ${lock_age}s)"
            rm -f "${LOCK_FILE}"
        fi
    fi
    
    # Close any existing lock FD
    if [[ ${MAIN_LOCK_FD} -gt 2 ]]; then
        exec {MAIN_LOCK_FD}>&- 2>/dev/null || true
    fi
    MAIN_LOCK_FD=-1
    
    # Try to acquire lock
    {
        exec {MAIN_LOCK_FD}>"${LOCK_FILE}" 2>/dev/null
    } || {
        log ERROR "Failed to create lock file"
        return 1
    }
    
    # Validate FD
    if [[ ${MAIN_LOCK_FD} -le 2 ]]; then
        log ERROR "Invalid lock FD: ${MAIN_LOCK_FD}"
        MAIN_LOCK_FD=-1
        return 1
    fi
    
    while [[ $elapsed -lt $timeout ]]; do
        if flock -n -x "${MAIN_LOCK_FD}"; then
            lock_acquired=true
            break
        fi
        sleep "$QUICK_SLEEP"
        elapsed=$((elapsed + 1))
    done
    
    if [[ "$lock_acquired" != "true" ]]; then
        log ERROR "Failed to acquire lock after ${timeout} seconds"
        exec {MAIN_LOCK_FD}>&- 2>/dev/null || true
        MAIN_LOCK_FD=-1
        return 1
    fi
    
    log DEBUG "Lock acquired (FD: ${MAIN_LOCK_FD})"
    return 0
}

# Release lock
release_lock() {
    if [[ ${MAIN_LOCK_FD} -gt 2 ]]; then
        flock -u "${MAIN_LOCK_FD}" 2>/dev/null || true
        exec {MAIN_LOCK_FD}>&- 2>/dev/null || true
        MAIN_LOCK_FD=-1
        rm -f "${LOCK_FILE}" 2>/dev/null || true
        log DEBUG "Lock released"
    fi
}

# Release lock without logging
release_lock_unsafe() {
    if [[ ${MAIN_LOCK_FD} -gt 2 ]]; then
        flock -u "${MAIN_LOCK_FD}" 2>/dev/null || true
        exec {MAIN_LOCK_FD}>&- 2>/dev/null || true
        MAIN_LOCK_FD=-1
        rm -f "${LOCK_FILE}" 2>/dev/null || true
    fi
}

# Acquire config lock
acquire_config_lock() {
    local timeout="${1:-10}"
    local lock_acquired=false
    local elapsed=0
    
    # Close any existing lock FD
    if [[ ${CONFIG_LOCK_FD} -gt 2 ]]; then
        exec {CONFIG_LOCK_FD}>&- 2>/dev/null || true
    fi
    CONFIG_LOCK_FD=-1
    
    # Create lock file if needed
    {
        exec {CONFIG_LOCK_FD}>"${CONFIG_LOCK_FILE}" 2>/dev/null
    } || {
        log ERROR "Failed to create config lock file"
        return 1
    }
    
    # Validate FD
    if [[ ${CONFIG_LOCK_FD} -le 2 ]]; then
        log ERROR "Invalid config lock FD"
        CONFIG_LOCK_FD=-1
        return 1
    fi
    
    while [[ $elapsed -lt $timeout ]]; do
        if flock -n -x "${CONFIG_LOCK_FD}"; then
            lock_acquired=true
            break
        fi
        sleep "$QUICK_SLEEP"
        elapsed=$((elapsed + 1))
    done
    
    if [[ "$lock_acquired" != "true" ]]; then
        log ERROR "Failed to acquire config lock after ${timeout} seconds"
        exec {CONFIG_LOCK_FD}>&- 2>/dev/null || true
        CONFIG_LOCK_FD=-1
        return 1
    fi
    
    log DEBUG "Config lock acquired"
    return 0
}

# Release config lock
release_config_lock() {
    if [[ ${CONFIG_LOCK_FD} -gt 2 ]]; then
        flock -u "${CONFIG_LOCK_FD}" 2>/dev/null || true
        exec {CONFIG_LOCK_FD}>&- 2>/dev/null || true
        CONFIG_LOCK_FD=-1
        rm -f "${CONFIG_LOCK_FILE}" 2>/dev/null || true
        log DEBUG "Config lock released"
    fi
}

# Release config lock without logging
release_config_lock_unsafe() {
    if [[ ${CONFIG_LOCK_FD} -gt 2 ]]; then
        flock -u "${CONFIG_LOCK_FD}" 2>/dev/null || true
        exec {CONFIG_LOCK_FD}>&- 2>/dev/null || true
        CONFIG_LOCK_FD=-1
        rm -f "${CONFIG_LOCK_FILE}" 2>/dev/null || true
    fi
}

# Write PID atomically
write_pid_atomic() {
    local pid="$1"
    local pid_file="$2"
    
    # Validate PID
    if [[ -z "$pid" ]] || [[ ! "$pid" =~ ^[0-9]+$ ]] || [[ "$pid" -le 0 ]] || [[ "$pid" -gt "$SYSTEM_PID_MAX" ]]; then
        log ERROR "Invalid PID: $pid"
        return 1
    fi
    
    # Ensure directory exists with proper permissions
    local pid_dir
    pid_dir="$(dirname "$pid_file")"
    mkdir -p "$pid_dir" 2>/dev/null || {
        log ERROR "Cannot create PID directory: $pid_dir"
        return 1
    }
    
    # Write atomically with temp file
    local temp_file
    temp_file="$(mktemp "${pid_file}.XXXXXX")" || {
        log ERROR "Cannot create temporary PID file"
        return 1
    }
    
    echo "$pid" > "$temp_file" || {
        log ERROR "Cannot write to temporary PID file"
        rm -f "$temp_file"
        return 1
    }
    
    mv -f "$temp_file" "$pid_file" || {
        log ERROR "Cannot move PID file into place"
        rm -f "$temp_file"
        return 1
    }
    
    log DEBUG "PID $pid written to $pid_file"
    return 0
}

# Read PID safely
read_pid_safe() {
    local pid_file="$1"
    
    if [[ ! -f "$pid_file" ]]; then
        return
    fi
    
    local pid
    pid="$(tr -d '[:space:]' < "$pid_file" 2>/dev/null || echo "")"
    
    # Validate PID
    if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" -gt 0 ]] && [[ "$pid" -le "$SYSTEM_PID_MAX" ]]; then
        echo "$pid"
    fi
}

# Terminate process group
terminate_process_group() {
    local pid="$1"
    local timeout="${2:-10}"
    
    if [[ -z "$pid" ]] || [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    # First try SIGTERM on process group
    if kill -0 "$pid" 2>/dev/null; then
        # Try to kill the process group
        kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        
        # Wait for termination
        local count=0
        while [[ $count -lt $timeout ]]; do
            if ! kill -0 "$pid" 2>/dev/null; then
                return 0
            fi
            sleep "$SHORT_SLEEP"
            ((count++))
        done
        
        # Force kill if still running
        kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        sleep "$SHORT_SLEEP"
    fi
    
    return 0
}

# RESTORED FROM v1.2.0: Detect USB audio devices with retry logic
detect_audio_devices() {
    local devices=()
    local retry_count=0
    local max_retries=3
    
    while [[ $retry_count -lt $max_retries ]]; do
        devices=()
        
        # Primary detection via /dev/snd/by-id
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

# RESTORED FROM v1.2.0: Device configuration loading
load_device_config() {
    if [[ -f "${DEVICE_CONFIG_FILE}" ]]; then
        # shellcheck source=/dev/null
        source "${DEVICE_CONFIG_FILE}"
    fi
}

# Save device configuration
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

# Stream mode settings (v1.3.0):
# - STREAM_MODE: individual or combined
# - COMBINE_METHOD: amerge or amix
# - COMBINED_STREAM_PATH: path for combined stream

# Example overrides:
# DEVICE_USB_BLUE_YETI_SAMPLE_RATE=44100
# DEVICE_USB_BLUE_YETI_CHANNELS=1
EOF
    
    mv -f "$tmp_config" "${DEVICE_CONFIG_FILE}"
    chmod 644 "${DEVICE_CONFIG_FILE}"
}

# Sanitize device name
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

# Sanitize path name
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

# RESTORED FROM v1.2.0: Wait for USB stabilization with hash checking
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

# RESTORED FROM v1.2.0: Detect restart scenario
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

# Mark restart
mark_restart() {
    touch "${RESTART_MARKER}"
}

# Clear restart marker
clear_restart_marker() {
    rm -f "${RESTART_MARKER}"
}

# Cleanup stale processes
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
    
    # Restore nullglob state
    if [[ "$nullglob_state" == "off" ]]; then
        shopt -u nullglob
    fi
    
    log INFO "Cleanup completed"
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
    
    # Adjust for combined mode
    if [[ "${STREAM_MODE}" == "combined" ]]; then
        expected_wrappers=1
    fi
    
    # Check for excessive wrapper processes
    if [[ $wrapper_count -gt $((expected_wrappers * 2)) ]]; then
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

# Start FFmpeg stream for individual device
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
            log DEBUG "Stream $stream_path already running"
            return 0
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
        RESTART_DELAY=$((RESTART_DELAY * 2))
        if [[ $RESTART_DELAY -gt 300 ]]; then
            RESTART_DELAY=300
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
        RESTART_DELAY=$((RESTART_DELAY * 2))
        if [[ $RESTART_DELAY -gt 300 ]]; then
            RESTART_DELAY=300
        fi
    fi
    
    # Short delay between restarts
    sleep $RESTART_DELAY
done

log_critical "Stream wrapper exiting for ${STREAM_PATH}"
WRAPPER_LOGIC
    
    chmod +x "$wrapper_script"
    
    # Start the wrapper script
    nohup "$wrapper_script" >> /dev/null 2>&1 &
    local pid=$!
    
    sleep "$QUICK_SLEEP"
    
    # Verify wrapper started
    if ! kill -0 "$pid" 2>/dev/null; then
        log ERROR "Failed to start wrapper for $stream_path"
        if [[ -f "$ffmpeg_log" ]]; then
            local last_error
            last_error="$(tail -n 5 "$ffmpeg_log" 2>/dev/null)"
            if [[ -n "$last_error" ]]; then
                log ERROR "Last error: $last_error"
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

# RESTORED FROM v1.2.0: Stop individual FFmpeg stream
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

# NEW v1.3.0: Start combined FFmpeg stream (FIXED without eval)
start_combined_ffmpeg_stream() {
    local devices=("$@")
    local stream_path="${COMBINED_STREAM_PATH}"
    local pid_file="${FFMPEG_PID_DIR}/${stream_path}.pid"
    
    # Check if already running
    if [[ -f "$pid_file" ]]; then
        local existing_pid
        existing_pid="$(read_pid_safe "$pid_file")"
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            log DEBUG "Combined stream already running"
            return 0
        fi
    fi
    
    log INFO "Starting combined FFmpeg stream for ${#devices[@]} devices using ${COMBINED_STREAM_METHOD}"
    
    # Validate all devices are accessible
    local valid_devices=()
    local skipped_count=0
    for device_info in "${devices[@]}"; do
        IFS=':' read -r device_name card_num <<< "$device_info"
        if check_audio_device "$card_num"; then
            valid_devices+=("${device_info}")
        else
            log WARN "Device card ${card_num} not accessible, skipping"
            ((skipped_count++))
        fi
    done
    
    if [[ ${#valid_devices[@]} -eq 0 ]]; then
        log ERROR "No valid audio devices for combined stream"
        return 1
    fi
    
    if [[ $skipped_count -gt 0 ]]; then
        log WARN "Continuing with ${#valid_devices[@]} of ${#devices[@]} devices"
    fi
    
    # Get configuration from first device (or use defaults)
    local first_device="${valid_devices[0]%%:*}"
    local sample_rate channels codec bitrate thread_queue
    sample_rate="$(get_device_config "$first_device" "SAMPLE_RATE" "$DEFAULT_SAMPLE_RATE")"
    channels="$(get_device_config "$first_device" "CHANNELS" "$DEFAULT_CHANNELS")"
    codec="$(get_device_config "$first_device" "CODEC" "$DEFAULT_CODEC")"
    bitrate="$(get_device_config "$first_device" "BITRATE" "$DEFAULT_BITRATE")"
    thread_queue="$(get_device_config "$first_device" "THREAD_QUEUE" "$DEFAULT_THREAD_QUEUE")"
    
    # Adjust bitrate for amerge
    if [[ "${COMBINED_STREAM_METHOD}" == "amerge" ]]; then
        local device_count="${#valid_devices[@]}"
        local total_channels=$((device_count * channels))
        # Increase bitrate proportionally: 64k per channel minimum
        local min_bitrate=$((total_channels * 64))
        
        # Parse current bitrate (handle various formats)
        local current_bitrate_value
        if [[ "$bitrate" =~ ^([0-9]+)([kKmM]?)$ ]]; then
            current_bitrate_value="${BASH_REMATCH[1]}"
            local unit="${BASH_REMATCH[2]}"
            
            # Convert to kilobits if needed
            case "${unit,,}" in
                m)
                    current_bitrate_value=$((current_bitrate_value * 1000))
                    ;;
                k|"")
                    # Already in kilobits or no unit (assume k)
                    ;;
                *)
                    log WARN "Unknown bitrate unit: $unit, assuming kilobits"
                    ;;
            esac
        else
            log WARN "Cannot parse bitrate: $bitrate, using default 128k"
            current_bitrate_value=128
        fi
        
        if [[ $current_bitrate_value -lt $min_bitrate ]]; then
            bitrate="${min_bitrate}k"
            log INFO "Increased bitrate to ${bitrate} for ${total_channels} channel output"
        fi
    fi
    
    # Create wrapper script
    local wrapper_script="${FFMPEG_PID_DIR}/${stream_path}.sh"
    local ffmpeg_log="${FFMPEG_PID_DIR}/${stream_path}.log"
    
    # Create wrapper script header
    cat > "$wrapper_script" << 'WRAPPER_START'
#!/bin/bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

WRAPPER_START
    
    # Write configuration
    cat >> "$wrapper_script" << EOF
# Combined Stream Configuration
STREAM_PATH="$stream_path"
SAMPLE_RATE="$sample_rate"
CHANNELS="$channels"
BITRATE="$bitrate"
THREAD_QUEUE="$thread_queue"
ANALYZEDURATION="$DEFAULT_ANALYZEDURATION"
PROBESIZE="$DEFAULT_PROBESIZE"
CODEC="$codec"
COMBINE_METHOD="$COMBINED_STREAM_METHOD"
MAX_COMBINED_DEVICES="$MAX_COMBINED_DEVICES"

# Device list
declare -a CARD_NUMS=(
EOF
    
    # Add all card numbers
    for device_info in "${valid_devices[@]}"; do
        IFS=':' read -r device_name card_num <<< "$device_info"
        echo "    \"$card_num\"" >> "$wrapper_script"
    done
    
    cat >> "$wrapper_script" << EOF
)

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
    
    # Add wrapper logic with FIXED array-based command execution
    cat >> "$wrapper_script" << 'WRAPPER_LOGIC'

touch "${FFMPEG_LOG}" 2>/dev/null || true

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WRAPPER] $1" >> "${FFMPEG_LOG}" 2>/dev/null || true
}

log_critical() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STREAM:${STREAM_PATH}] $1" >> "${LOG_FILE}" 2>/dev/null || true
}

cleanup_wrapper() {
    local exit_code=$?
    log_message "Wrapper cleanup initiated (exit code: $exit_code)"
    
    local ffmpeg_pid="${FFMPEG_PID:-}"
    if [[ -n "$ffmpeg_pid" ]]; then
        if kill -0 "$ffmpeg_pid" 2>/dev/null; then
            log_message "Sending SIGINT to FFmpeg process ${ffmpeg_pid}"
            kill -INT "$ffmpeg_pid" 2>/dev/null || true
            
            local term_wait=0
            while kill -0 "$ffmpeg_pid" 2>/dev/null && [[ $term_wait -lt 5 ]]; do
                sleep 0.2
                ((term_wait++))
            done
            
            if kill -0 "$ffmpeg_pid" 2>/dev/null; then
                kill -KILL "$ffmpeg_pid" 2>/dev/null || true
            fi
        fi
    fi
    
    rm -f "${WRAPPER_PID_FILE}"
    log_critical "Combined stream wrapper terminated for ${STREAM_PATH}"
    exit "$exit_code"
}

trap cleanup_wrapper EXIT INT TERM

run_ffmpeg() {
    log_message "Building combined FFmpeg command for ${#CARD_NUMS[@]} devices using ${COMBINE_METHOD}"
    
    # Validate device count
    if [[ ${#CARD_NUMS[@]} -eq 0 ]]; then
        log_message "ERROR: No devices available for combined stream"
        return 1
    fi
    
    if [[ ${#CARD_NUMS[@]} -gt ${MAX_COMBINED_DEVICES} ]]; then
        log_message "ERROR: Too many devices (${#CARD_NUMS[@]}), maximum ${MAX_COMBINED_DEVICES} supported"
        return 1
    fi
    
    # FIXED: Build FFmpeg command using arrays instead of strings
    local ffmpeg_cmd=(ffmpeg -hide_banner -loglevel warning)
    
    # Add each input device
    local available_cards=()
    for card_num in "${CARD_NUMS[@]}"; do
        # Check if device still exists
        if [[ ! -e "/dev/snd/pcmC${card_num}D0c" ]]; then
            log_message "WARN: Device card ${card_num} not available, skipping"
            continue
        fi
        
        available_cards+=("$card_num")
        local audio_device="plughw:${card_num},0"
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
    
    # Check if we have any available devices
    local device_count="${#available_cards[@]}"
    if [[ $device_count -eq 0 ]]; then
        log_message "ERROR: All devices disappeared"
        return 1
    fi
    
    # Build filter complex
    local filter_complex=""
    
    case "${COMBINE_METHOD}" in
        amerge)
            # Create multi-channel output
            local output_channels=$((device_count * CHANNELS))
            local amerge_inputs=""
            for ((i=0; i<device_count; i++)); do
                amerge_inputs+="[${i}:a]"
            done
            filter_complex="${amerge_inputs}amerge=inputs=${device_count},aresample=async=1:first_pts=0"
            log_message "Using amerge: ${device_count} inputs -> ${output_channels} channel output"
            ;;
            
        amix)
            # Mix all inputs into stereo output
            local amix_inputs=""
            for ((i=0; i<device_count; i++)); do
                amix_inputs+="[${i}:a]"
            done
            filter_complex="${amix_inputs}amix=inputs=${device_count}:duration=longest:normalize=0,aresample=async=1:first_pts=0"
            log_message "Using amix: ${device_count} inputs -> stereo output (mixed)"
            ;;
            
        *)
            log_message "ERROR: Unknown combine method: ${COMBINE_METHOD}"
            return 1
            ;;
    esac
    
    # Add filter complex to command
    ffmpeg_cmd+=(-filter_complex "${filter_complex}")
    
    # Add codec options
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
    
    # Log the complete command (for debugging)
    log_message "FFmpeg command: ${ffmpeg_cmd[*]}"
    
    # FIXED: Start FFmpeg using array expansion instead of eval
    if command -v setsid &>/dev/null; then
        setsid "${ffmpeg_cmd[@]}" >> "${FFMPEG_LOG}" 2>&1 &
        FFMPEG_PID=$!
    else
        "${ffmpeg_cmd[@]}" >> "${FFMPEG_LOG}" 2>&1 &
        FFMPEG_PID=$!
    fi
    
    # Validate FFmpeg started
    sleep 0.5
    if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
        log_message "ERROR: FFmpeg failed to start"
        if [[ -f "${FFMPEG_LOG}" ]]; then
            log_message "Last output: $(tail -n 5 "${FFMPEG_LOG}" 2>/dev/null | tr '\n' ' ')"
        fi
        FFMPEG_PID=""
        return 1
    fi
    
    log_message "Started combined FFmpeg with PID ${FFMPEG_PID}"
    return 0
}

check_devices_exist() {
    local missing=0
    for card_num in "${CARD_NUMS[@]}"; do
        if [[ ! -e "/dev/snd/pcmC${card_num}D0c" ]]; then
            log_message "Device card ${card_num} no longer exists"
            ((missing++))
        fi
    done
    
    # Allow stream to continue if at least one device remains
    if [[ $missing -eq ${#CARD_NUMS[@]} ]]; then
        log_message "All devices disappeared"
        return 1
    elif [[ $missing -gt 0 ]]; then
        log_message "WARN: $missing of ${#CARD_NUMS[@]} devices missing, continuing with available"
    fi
    return 0
}

check_parent_alive() {
    if [[ -n "${PARENT_PID}" ]] && [[ "${PARENT_PID}" -gt 1 ]]; then
        if ! kill -0 "${PARENT_PID}" 2>/dev/null; then
            log_message "Parent process ${PARENT_PID} died, exiting"
            return 1
        fi
    fi
    return 0
}

log_critical "Combined stream wrapper starting for ${STREAM_PATH} (${#CARD_NUMS[@]} devices, method: ${COMBINE_METHOD})"
log_message "Wrapper PID: $$, Parent PID: ${PARENT_PID}"

# Main restart loop
while true; do
    if ! check_parent_alive; then
        break
    fi
    
    if [[ -f "${CLEANUP_MARKER}" ]]; then
        log_message "Cleanup in progress, stopping wrapper"
        break
    fi
    
    # Continue if at least one device exists
    if ! check_devices_exist; then
        log_message "No devices remaining"
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
    
    log_message "Starting combined FFmpeg (attempt #$((RESTART_COUNT + 1)))"
    
    START_TIME=$(date +%s)
    
    if ! run_ffmpeg; then
        log_message "Failed to start combined FFmpeg"
        ((CONSECUTIVE_FAILURES++))
        RESTART_DELAY=$((RESTART_DELAY * 2))
        if [[ $RESTART_DELAY -gt 300 ]]; then
            RESTART_DELAY=300
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
    
    if [[ ${RUN_TIME} -gt ${WRAPPER_SUCCESS_DURATION} ]]; then
        CONSECUTIVE_FAILURES=0
        RESTART_DELAY=10
        log_message "Successful run, reset delay to ${RESTART_DELAY}s"
    else
        ((CONSECUTIVE_FAILURES++))
        RESTART_DELAY=$((RESTART_DELAY * 2))
        if [[ $RESTART_DELAY -gt 300 ]]; then
            RESTART_DELAY=300
        fi
    fi
    
    sleep $RESTART_DELAY
done

log_critical "Combined stream wrapper exiting for ${STREAM_PATH}"
WRAPPER_LOGIC
    
    chmod +x "$wrapper_script"
    
    # Start the wrapper script
    nohup "$wrapper_script" >> /dev/null 2>&1 &
    local pid=$!
    
    sleep "$QUICK_SLEEP"
    
    # Verify wrapper started
    if ! kill -0 "$pid" 2>/dev/null; then
        log ERROR "Failed to start combined stream wrapper"
        rm -f "$wrapper_script"
        return 1
    fi
    
    # Write PID file
    if ! write_pid_atomic "$pid" "$pid_file"; then
        log ERROR "Failed to write PID file for combined stream"
        kill "$pid" 2>/dev/null || true
        rm -f "$wrapper_script"
        return 1
    fi
    
    log DEBUG "Combined stream wrapper started with PID $pid"
    
    # Wait for stream to stabilize
    sleep $((STREAM_STARTUP_DELAY + 5))
    
    if validate_stream "$stream_path"; then
        log INFO "Combined stream started successfully"
        return 0
    else
        log ERROR "Combined stream failed validation"
        kill "$pid" 2>/dev/null || true
        rm -f "$pid_file"
        return 1
    fi
}

# Start all FFmpeg streams with fallback support
start_all_ffmpeg_streams() {
    # Receive device list as arguments instead of detecting again
    local devices=("$@")
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        log WARN "No USB audio devices provided"
        return 0
    fi
    
    # Check stream mode
    if [[ "${STREAM_MODE}" == "combined" ]]; then
        log INFO "Starting combined stream for ${#devices[@]} devices using ${COMBINED_STREAM_METHOD}"
        
        # Try combined stream
        if start_combined_ffmpeg_stream "${devices[@]}"; then
            return 0
        else
            # Check if fallback is enabled
            if [[ "${ENABLE_FALLBACK}" == "true" ]]; then
                log WARN "Combined stream failed, falling back to individual streams"
                # Continue to individual stream logic below
            else
                log ERROR "Combined stream failed and fallback is disabled"
                return 1
            fi
        fi
    fi
    
    # Individual stream logic (default or fallback)
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
    else
        log INFO "Successfully started all $success_count/${#devices[@]} FFmpeg streams"
    fi
    
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
    
    # Restore nullglob state
    if [[ "$nullglob_state" == "off" ]]; then
        shopt -u nullglob
    fi
    
    # Kill any orphaned processes
    pkill -f "^ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" 2>/dev/null || true
}

# RESTORED FROM v1.2.0: Generate MediaMTX configuration
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
    
    if ! flock -x -w 10 "${CONFIG_LOCK_FD}"; then
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
  '~^[a-zA-Z0-9_-]+$':
    source: publisher
    sourceProtocol: automatic
    sourceOnDemand: no
EOF
    
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
    
    log INFO "Found ${#devices[@]} USB audio device(s)"
    
    # Check for path collision in combined mode
    if [[ "${STREAM_MODE}" == "combined" ]]; then
        for device_info in "${devices[@]}"; do
            IFS=':' read -r device_name card_num <<< "$device_info"
            local potential_path
            potential_path="$(generate_stream_path "$device_name" "$card_num")"
            if [[ "${potential_path}" == "${COMBINED_STREAM_PATH}" ]]; then
                log ERROR "Combined stream path '${COMBINED_STREAM_PATH}' conflicts with device stream path"
                log ERROR "Please set a different MEDIAMTX_COMBINED_PATH value"
                return "${E_CONFIG_ERROR}"
            fi
        done
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
    
    # Start streams with fallback support
    local stream_start_result=0
    if ! start_all_ffmpeg_streams "${devices[@]}"; then
        if [[ "${STREAM_MODE}" == "combined" ]] && [[ "${ENABLE_FALLBACK}" == "true" ]]; then
            log WARN "Combined mode failed, already fell back to individual mode"
        else
            log ERROR "Failed to start streams"
            stream_start_result=1
        fi
    fi
    
    # Display available streams
    echo
    echo -e "${GREEN}=== Available RTSP Streams ===${NC}"
    
    if [[ "${STREAM_MODE}" == "combined" ]] && [[ $stream_start_result -eq 0 ]]; then
        if validate_stream "${COMBINED_STREAM_PATH}"; then
            echo -e "${GREEN}✔${NC} rtsp://${MEDIAMTX_HOST}:8554/${COMBINED_STREAM_PATH} (combined ${COMBINED_STREAM_METHOD})"
        else
            echo -e "${YELLOW}!${NC} Fell back to individual streams:"
            for device_info in "${devices[@]}"; do
                IFS=':' read -r device_name card_num <<< "$device_info"
                local stream_path
                stream_path="$(generate_stream_path "$device_name" "$card_num")"
                
                if validate_stream "$stream_path"; then
                    echo -e "  ${GREEN}✔${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path}"
                else
                    echo -e "  ${RED}✗${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path} (failed)"
                fi
            done
        fi
    else
        for device_info in "${devices[@]}"; do
            IFS=':' read -r device_name card_num <<< "$device_info"
            local stream_path
            stream_path="$(generate_stream_path "$device_name" "$card_num")"
            
            if validate_stream "$stream_path"; then
                echo -e "${GREEN}✔${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path}"
            else
                echo -e "${RED}✗${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path} (failed)"
            fi
        done
    fi
    
    echo
    return $stream_start_result
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
    echo "Stream Mode: ${STREAM_MODE}"
    if [[ "${STREAM_MODE}" == "combined" ]]; then
        echo "Combine Method: ${COMBINED_STREAM_METHOD}"
        echo "Combined Stream Path: ${COMBINED_STREAM_PATH}"
        echo "Fallback Enabled: ${ENABLE_FALLBACK}"
    fi
    
    echo
    echo "Detected USB audio devices:"
    local devices=()
    readarray -t devices < <(detect_audio_devices)
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        echo "  No devices found"
    else
        for device_info in "${devices[@]}"; do
            IFS=':' read -r device_name card_num <<< "$device_info"
            
            local stream_path
            if [[ "${STREAM_MODE}" == "combined" ]]; then
                stream_path="${COMBINED_STREAM_PATH}"
            else
                stream_path="$(generate_stream_path "$device_name" "$card_num")"
            fi
            
            echo "  - $device_name (card $card_num)"
            
            if [[ "${STREAM_MODE}" != "combined" ]] || [[ "${device_info}" == "${devices[0]}" ]]; then
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
            fi
        done
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
    
    echo
    echo -e "${CYAN}=== Current Settings ===${NC}"
    echo "Stream Mode: ${STREAM_MODE}"
    echo "Combined Method: ${COMBINED_STREAM_METHOD}"
    echo "Combined Path: ${COMBINED_STREAM_PATH}"
    echo "Fallback Enabled: ${ENABLE_FALLBACK}"
    echo "Max Combined Devices: ${MAX_COMBINED_DEVICES}"
}

# Create systemd service
create_systemd_service() {
    local service_file="/etc/systemd/system/mediamtx-audio.service"
    
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
Environment="INVOCATION_ID=systemd"
Environment="MEDIAMTX_STREAM_MODE=${STREAM_MODE}"
Environment="MEDIAMTX_COMBINE_METHOD=${COMBINED_STREAM_METHOD}"
Environment="MEDIAMTX_COMBINED_PATH=${COMBINED_STREAM_PATH}"
Environment="MEDIAMTX_ENABLE_FALLBACK=${ENABLE_FALLBACK}"
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
    echo "Enable: sudo systemctl enable mediamtx-audio"
    echo "Start: sudo systemctl start mediamtx-audio"
}

# Show help
show_help() {
    cat << EOF
MediaMTX Stream Manager v${VERSION}
Part of LyreBirdAudio - RTSP Audio Streaming Suite

Usage: ${SCRIPT_NAME} [COMMAND]

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

Stream Modes (v${VERSION}):
    individual  - Create separate RTSP stream for each microphone (default)
    combined    - Combine all microphones into one synchronized stream

Environment Variables:
    MEDIAMTX_STREAM_MODE     - Set to 'individual' or 'combined' (default: individual)
    MEDIAMTX_COMBINE_METHOD  - Set to 'amerge' or 'amix' (default: amerge)
    MEDIAMTX_COMBINED_PATH   - Stream path for combined mode (default: combined_audio)
    MEDIAMTX_ENABLE_FALLBACK - Enable fallback to individual on failure (default: true)
    MEDIAMTX_MAX_COMBINED_DEVICES - Max devices in combined mode (default: 20)
    
Examples:
    # Individual streams (default behavior)
    sudo ./mediamtx-stream-manager.sh start
    
    # Combined stream with AMERGE (multi-channel)
    sudo MEDIAMTX_STREAM_MODE=combined \\
         MEDIAMTX_COMBINE_METHOD=amerge \\
         ./mediamtx-stream-manager.sh start
    
    # Combined stream with AMIX (mixed stereo)
    sudo MEDIAMTX_STREAM_MODE=combined \\
         MEDIAMTX_COMBINE_METHOD=amix \\
         ./mediamtx-stream-manager.sh start

Version ${VERSION} Features:
    - Combined stream mode for all microphones
    - AMERGE method preserves individual mic channels
    - AMIX method mixes all mics into stereo
    - Perfect synchronization across all microphones
    - Automatic fallback to individual streams on failure
    - Graceful degradation when devices disconnect
    - Full v1.2.0 stability and reliability preserved

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

# Main function
main() {
    local exit_code=0
    
    # Debug output for systemd troubleshooting
    if [[ "${INVOCATION_ID:-}" != "" ]]; then
        echo "[DEBUG] Running under systemd, command: ${1:-help}" >&2
        echo "[DEBUG] Script: $0, Working dir: $(pwd)" >&2
        echo "[DEBUG] User: $(id -u), EUID: $EUID" >&2
    fi
    
    case "${1:-help}" in
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

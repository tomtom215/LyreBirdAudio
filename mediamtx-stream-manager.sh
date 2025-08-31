#!/bin/bash
# mediamtx-stream-manager.sh - Automatic MediaMTX audio stream configuration
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# This script automatically detects USB microphones and creates MediaMTX 
# configurations for continuous 24/7 RTSP audio streams.
#
# Version: 1.1.5 - Production-ready logging separation with enhanced reliability
# Compatible with MediaMTX v1.12.3+
#
# Version History:
# v1.1.5 - Production-ready logging separation with enhanced reliability
#   - Fixed critical path desynchronization bug between config and runtime
#   - Added cleanup_stale_processes to exit trap for proper cleanup
#   - Separated wrapper logs from system logs for better organization
#   - Stream-specific wrapper messages now go to individual stream logs
#   - System-wide events remain in main log file
#   - Added critical message logging for important stream events
#   - Improved log readability for 24/7 production monitoring
#   - Enhanced PID file validation to prevent invalid process operations
#   - Made MediaMTX host configurable via MEDIAMTX_HOST environment variable
#   - Improved error handling for device operations
#   - Fixed variable scoping bug in stream path handling
#   - Implemented atomic stream path claiming with flock
#   - Fixed PID file creation race condition
#   - Simplified generate_stream_path function
# v1.1.4 - Fixed stream path collision race condition
#   - Added flock-based mutual exclusion for stream paths
#   - Prevents "conflicting publisher" errors in MediaMTX
#   - Wrappers now exit cleanly if another owns the stream
#   - Eliminates unnecessary restart cycles from path collisions
# v1.1.3 - Fixed critical FFmpeg PID handling in wrapper script
#   - Fixed race condition where FFmpeg could exit before PID capture
#   - Improved process monitoring with polling instead of just wait
#   - Added immediate verification of FFmpeg process startup
#   - Better exit code capture and error detection
# v1.1.2 - Fixed race condition in wrapper script startup & enhanced robustness
#   - Enable TCP and UDP by default
#   - Create PID file before starting wrapper to prevent immediate exit
#   - Wrapper now properly waits for FFmpeg process
#   - Added parallel startup race condition mitigation
#   - Enhanced debug output with clear success/failure indication
#   - Added audio group validation for systemd service
# v1.1.1 - Fixed wrapper script execution issue
#   - Fixed FFMPEG_PID scope issue in wrapper scripts
#   - Properly capture and use FFmpeg process PID
# v1.1.0 - Production hardening release
#   - Fixed eval security issue with array-based execution
#   - Fixed parallel processing double-wait bug
#   - Standardized error handling with configurable modes
#   - Added input validation for all commands
#   - Implemented atomic PID file operations
#   - Enhanced lock file timeout handling
#   - Improved shellcheck compliance
#   - Backward compatible with v1.0.0 configurations
#
# Requirements:
# - MediaMTX installed (use install_mediamtx.sh)
# - USB audio devices
# - ffmpeg installed for audio encoding
#
# Usage: ./mediamtx-stream-manager.sh [start|stop|restart|status|config|help]

set -euo pipefail

# Constants
readonly VERSION="1.1.5"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_DIR="/etc/mediamtx"
readonly CONFIG_FILE="${CONFIG_DIR}/mediamtx.yml"
readonly DEVICE_CONFIG_FILE="${CONFIG_DIR}/audio-devices.conf"
readonly PID_FILE="/var/run/mediamtx-audio.pid"
readonly FFMPEG_PID_DIR="/var/lib/mediamtx-ffmpeg"
readonly LOCK_FILE="/var/run/mediamtx-audio.lock"
readonly LOG_FILE="/var/log/mediamtx-stream-manager.log"
readonly MEDIAMTX_LOG="/var/log/mediamtx.log"
readonly MEDIAMTX_BIN="/usr/local/bin/mediamtx"
readonly MEDIAMTX_HOST="${MEDIAMTX_HOST:-localhost}"
readonly TEMP_CONFIG="/tmp/mediamtx-audio-$$.yml"
readonly RESTART_MARKER="/var/run/mediamtx-audio.restart"
readonly CLEANUP_MARKER="/var/run/mediamtx-audio.cleanup"

# Error handling mode
readonly ERROR_HANDLING_MODE="${ERROR_HANDLING_MODE:-fail-safe}"

# Audio stability settings
readonly DEFAULT_SAMPLE_RATE="48000"
readonly DEFAULT_CHANNELS="2"
readonly DEFAULT_FORMAT="s16le"
readonly DEFAULT_CODEC="opus"
readonly DEFAULT_BITRATE="128k"
readonly DEFAULT_ALSA_BUFFER="100000"      # 100ms in microseconds
readonly DEFAULT_ALSA_PERIOD="20000"       # 20ms in microseconds
readonly DEFAULT_THREAD_QUEUE="8192"       # Increased for stability
readonly DEFAULT_FIFO_SIZE="1048576"       # 1MB FIFO buffer
readonly DEFAULT_ANALYZEDURATION="5000000" # 5 seconds
readonly DEFAULT_PROBESIZE="5000000"       # 5MB probe size

# Connection settings
readonly STREAM_STARTUP_DELAY="${STREAM_STARTUP_DELAY:-10}"  # Can be overridden via environment
readonly STREAM_VALIDATION_ATTEMPTS="3"
readonly STREAM_VALIDATION_DELAY="5"
readonly USB_STABILIZATION_DELAY="${USB_STABILIZATION_DELAY:-5}"  # Wait for USB to stabilize
readonly RESTART_STABILIZATION_DELAY="${RESTART_STABILIZATION_DELAY:-10}"  # Extra delay on restart

# Device test settings
readonly DEVICE_TEST_ENABLED="${DEVICE_TEST_ENABLED:-false}"  # Disable by default
readonly DEVICE_TEST_TIMEOUT="${DEVICE_TEST_TIMEOUT:-3}"      # Increased timeout

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Forward declare cleanup_stale_processes for trap
cleanup_stale_processes() {
    log INFO "Performing comprehensive cleanup of stale processes and files"
    
    # Mark that we're in cleanup mode
    touch "${CLEANUP_MARKER}"
    
    # Step 1: Kill all FFmpeg wrapper scripts
    log DEBUG "Terminating FFmpeg wrapper scripts"
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        if [[ -f "$pid_file" ]]; then
            local pid
            pid="$(read_pid_safe "$pid_file")"
            if [[ -n "$pid" ]]; then
                # Try graceful termination first
                kill -TERM "$pid" 2>/dev/null || true
                # Kill children
                pkill -TERM -P "$pid" 2>/dev/null || true
            fi
        fi
    done
    
    # Step 2: Wait briefly for graceful termination
    sleep 2
    
    # Step 3: Force kill any remaining wrapper processes
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        if [[ -f "$pid_file" ]]; then
            local pid
            pid="$(read_pid_safe "$pid_file")"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                log DEBUG "Force killing wrapper PID $pid"
                kill -KILL "$pid" 2>/dev/null || true
                pkill -KILL -P "$pid" 2>/dev/null || true
            fi
            rm -f "$pid_file"
        fi
    done
    
    # Step 4: Kill any orphaned FFmpeg processes
    log DEBUG "Killing orphaned FFmpeg processes"
    pkill -TERM -f "ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" 2>/dev/null || true
    sleep 1
    pkill -KILL -f "ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" 2>/dev/null || true
    
    # Step 5: Kill MediaMTX if running outside our control
    if [[ -f "${PID_FILE}" ]]; then
        local mediamtx_pid
        mediamtx_pid="$(read_pid_safe "${PID_FILE}")"
        if [[ -n "$mediamtx_pid" ]]; then
            if ! kill -0 "$mediamtx_pid" 2>/dev/null; then
                log DEBUG "Removing stale MediaMTX PID file"
                rm -f "${PID_FILE}"
            fi
        fi
    fi
    
    # Kill any MediaMTX processes not matching our PID
    pkill -TERM -f "${MEDIAMTX_BIN}" 2>/dev/null || true
    sleep 1
    pkill -KILL -f "${MEDIAMTX_BIN}" 2>/dev/null || true
    
    # Step 6: Clean up temporary files (preserve logs for diagnostics)
    log DEBUG "Cleaning temporary files (preserving logs for 24/7 monitoring)"
    rm -f "${FFMPEG_PID_DIR}"/*.pid
    rm -f "${FFMPEG_PID_DIR}"/*.sh
    # Preserve stream logs for production diagnostics and troubleshooting
    # rm -f "${FFMPEG_PID_DIR}"/*.log         # Commented: Keep for diagnostics
    # rm -f "${FFMPEG_PID_DIR}"/*.log.old     # Commented: Keep for history
    rm -f "${FFMPEG_PID_DIR}"/*.claim
    rm -f /tmp/mediamtx-audio-*.yml
    
    # Step 7: Reset ALSA if needed (helps with device issues)
    if command -v alsactl &>/dev/null; then
        log DEBUG "Resetting ALSA state"
        alsactl init 2>/dev/null || true
    fi
    
    # Clear cleanup marker
    rm -f "${CLEANUP_MARKER}"
    
    log INFO "Cleanup completed"
}

# Cleanup function - FIX #2: Call cleanup_stale_processes for proper cleanup
cleanup() {
    local exit_code=$?
    
    # Perform comprehensive cleanup if we're exiting unexpectedly
    if [[ $exit_code -ne 0 ]]; then
        cleanup_stale_processes
    fi
    
    rm -f "${TEMP_CONFIG}"
    rm -f "${LOCK_FILE}"
    rm -f "${CLEANUP_MARKER}"
    exit "${exit_code}"
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

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
            echo -e "${GREEN}[INFO]${NC} ${message}"
            ;;
        DEBUG)
            if [[ "${DEBUG:-false}" == "true" ]]; then
                echo -e "${BLUE}[DEBUG]${NC} ${message}"
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

# Atomic PID file operations
write_pid_atomic() {
    local pid="$1"
    local pid_file="$2"
    local temp_pid
    
    temp_pid="$(mktemp "${pid_file}.XXXXXX")"
    echo "$pid" > "$temp_pid"
    mv -f "$temp_pid" "$pid_file"
}

# Enhanced PID file reading with validation
read_pid_safe() {
    local pid_file="$1"
    local pid_content=""
    
    if [[ ! -f "$pid_file" ]]; then
        echo ""
        return 0
    fi
    
    # Read and sanitize PID content
    pid_content="$(cat "$pid_file" 2>/dev/null | tr -d '[:space:]')"
    
    # Validate content exists
    if [[ -z "$pid_content" ]]; then
        log DEBUG "PID file $pid_file is empty"
        echo ""
        return 0
    fi
    
    # Ensure content is numeric
    if [[ ! "$pid_content" =~ ^[0-9]+$ ]]; then
        log ERROR "PID file $pid_file contains invalid content: '$pid_content'"
        # Clean up corrupted file
        rm -f "$pid_file"
        echo ""
        return 0
    fi
    
    # Validate reasonable PID range (1 to kernel.pid_max, typically 4194304)
    if [[ "$pid_content" -lt 1 ]] || [[ "$pid_content" -gt 4194304 ]]; then
        log ERROR "PID file $pid_file contains out-of-range PID: $pid_content"
        rm -f "$pid_file"
        echo ""
        return 0
    fi
    
    echo "$pid_content"
}

# Lock file operations
acquire_lock() {
    local timeout="${1:-30}"
    local count=0
    local lock_age_limit=300  # 5 minutes
    
    while [[ -f "${LOCK_FILE}" ]] && [[ $count -lt $timeout ]]; do
        # Check lock age
        if [[ -f "${LOCK_FILE}" ]]; then
            local lock_age
            lock_age="$(( $(date +%s) - $(stat -c %Y "${LOCK_FILE}" 2>/dev/null || echo 0) ))"
            
            if [[ $lock_age -gt $lock_age_limit ]]; then
                log WARN "Removing stale lock file (age: ${lock_age}s)"
                rm -f "${LOCK_FILE}"
                break
            fi
        fi
        
        sleep 1
        ((count++))
    done
    
    if [[ $count -ge $timeout ]]; then
        # Force cleanup if lock is stale
        local lock_pid
        if [[ -f "${LOCK_FILE}" ]]; then
            lock_pid="$(read_pid_safe "${LOCK_FILE}")"
            if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
                log WARN "Removing stale lock file (PID $lock_pid not running)"
                rm -f "${LOCK_FILE}"
            else
                handle_error FATAL "Failed to acquire lock after ${timeout} seconds" 5
            fi
        fi
    fi
    
    write_pid_atomic $$ "${LOCK_FILE}"
}

release_lock() {
    rm -f "${LOCK_FILE}"
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
    
    for cmd in ffmpeg jq curl arecord; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ! -x "${MEDIAMTX_BIN}" ]]; then
        missing+=("mediamtx (run install_mediamtx.sh first)")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        handle_error FATAL "Missing dependencies: ${missing[*]}" 3
    fi
}

# Create required directories and fix permissions
setup_directories() {
    mkdir -p "${CONFIG_DIR}"
    mkdir -p "$(dirname "${LOG_FILE}")"
    mkdir -p "$(dirname "${MEDIAMTX_LOG}")"
    mkdir -p "$(dirname "${PID_FILE}")"
    mkdir -p "${FFMPEG_PID_DIR}"
    
    chmod 755 "${FFMPEG_PID_DIR}"
    
    # Enhanced: Handle potential ownership issues
    if [[ ! -f "${LOG_FILE}" ]]; then
        touch "${LOG_FILE}"
        chmod 644 "${LOG_FILE}"
    fi
    
    if [[ ! -f "${MEDIAMTX_LOG}" ]]; then
        touch "${MEDIAMTX_LOG}"
        chmod 666 "${MEDIAMTX_LOG}"
    fi
}

# Detect if we're in a restart scenario
is_restart_scenario() {
    # Check if restart marker exists and is recent (within 60 seconds)
    if [[ -f "${RESTART_MARKER}" ]]; then
        local marker_age
        marker_age="$(( $(date +%s) - $(stat -c %Y "${RESTART_MARKER}" 2>/dev/null || echo 0) ))"
        if [[ $marker_age -lt 60 ]]; then
            return 0
        fi
    fi
    
    # Check if MediaMTX or FFmpeg processes are still dying
    if pgrep -f "${MEDIAMTX_BIN}" >/dev/null 2>&1 || pgrep -f "ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" >/dev/null 2>&1; then
        return 0
    fi
    
    return 1
}

# Mark restart scenario
mark_restart() {
    touch "${RESTART_MARKER}"
}

# Clear restart marker
clear_restart_marker() {
    rm -f "${RESTART_MARKER}"
}

# Wait for USB audio subsystem to stabilize
wait_for_usb_stabilization() {
    local max_wait="${1:-30}"
    local stable_count_needed=2
    local stable_count=0
    local last_device_count=0
    local elapsed=0
    
    log INFO "Waiting for USB audio subsystem to stabilize..."
    
    while [[ $elapsed -lt $max_wait ]]; do
        local current_device_count
        current_device_count="$(detect_audio_devices | wc -l)"
        
        if [[ $current_device_count -eq $last_device_count ]] && [[ $current_device_count -gt 0 ]]; then
            ((stable_count++))
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
# IMPORTANT: Variable names must be ALL UPPERCASE

# Universal defaults:
# - Sample Rate: 48000 Hz
# - Channels: 2 (stereo)
# - Format: s16le (16-bit little-endian)
# - Codec: opus
# - Bitrate: 128k

# Audio stability settings:
# - ALSA_BUFFER: 100000 (microseconds - increase for stability)
# - ALSA_PERIOD: 20000 (microseconds - decrease for lower latency)
# - THREAD_QUEUE: 8192 (packets - increase if seeing buffer underruns)

# Example overrides:
# DEVICE_USB_BLUE_YETI_SAMPLE_RATE=44100
# DEVICE_USB_BLUE_YETI_CHANNELS=1
# DEVICE_USB_BLUE_YETI_ALSA_BUFFER=200000

# IMPORTANT: Most USB audio devices only support s16le format
# Only use s24le or s32le if you're certain your device supports it

# For devices with stability issues:
# DEVICE_USB_GENERIC_AUDIO_ALSA_BUFFER=200000
# DEVICE_USB_GENERIC_AUDIO_THREAD_QUEUE=16384

# Codec recommendations:
# - opus: Best for real-time streaming (low latency, good quality)
# - aac: Universal compatibility 
# - mp3: Legacy device support
# - pcm: Avoid for network streams (uses excessive bandwidth)

EOF
}

# Sanitize device name for use as variable name
sanitize_device_name() {
    local name="$1"
    echo "$name" | sed 's/[^a-zA-Z0-9]/_/g' | sed 's/^_*//;s/_*$//'
}

# Sanitize path name for MediaMTX
sanitize_path_name() {
    local name="$1"
    name="${name#usb-audio-}"
    name="${name#usb_audio_}"
    echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^0-9a-z]/_/g' | sed 's/__*/_/g' | sed 's/^_*//;s/_*$//'
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

# Helper function to verify udev names are properly set
verify_udev_names() {
    log INFO "Checking for udev-assigned friendly names..."
    
    local found_friendly=0
    local total_cards=0
    local total_usb_cards=0
    
    if [[ -f "/proc/asound/cards" ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^\ *([0-9]+)\ .*\[([^]]+)\] ]]; then
                local card_num="${BASH_REMATCH[1]}"
                local card_name="${BASH_REMATCH[2]}"
                # Trim whitespace from card name
                card_name="$(echo "$card_name" | xargs)"
                ((total_cards++))
                
                # Skip non-USB cards
                if [[ ! -f "/proc/asound/card${card_num}/usbid" ]]; then
                    continue
                fi
                
                ((total_usb_cards++))
                
                # Check if this looks like a friendly name
                # Friendly names are typically short, lowercase, alphanumeric
                if [[ "$card_name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
                    log INFO "Card $card_num has friendly name: $card_name"
                    ((found_friendly++))
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
}

# Detect USB audio devices - enhanced to include card number
detect_audio_devices() {
    local devices=()
    
    # Check /dev/snd/by-id/ for persistent names
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
                        # Include card number in the output
                        devices+=("${device_name}:${card_num}")
                    fi
                fi
            fi
        done
    fi
    
    # Fallback to /proc/asound/cards
    if [[ ${#devices[@]} -eq 0 ]] && [[ -f /proc/asound/cards ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+\[([^]]+)\] ]] && [[ -f "/proc/asound/card${BASH_REMATCH[1]}/usbid" ]]; then
                local card_num="${BASH_REMATCH[1]}"
                local card_name="${BASH_REMATCH[2]}"
                local safe_name
                safe_name="$(echo "$card_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')"
                devices+=("usb-audio-${safe_name}:${card_num}")
            fi
        done < /proc/asound/cards
    fi
    
    # Only print if we have devices
    if [[ ${#devices[@]} -gt 0 ]]; then
        printf '%s\n' "${devices[@]}"
    fi
}

# Enhanced check if audio device is accessible
check_audio_device() {
    local card_num="$1"
    
    # Explicit validation with clear error path
    if [[ ! -e "/dev/snd/pcmC${card_num}D0c" ]]; then
        log DEBUG "Device file /dev/snd/pcmC${card_num}D0c does not exist"
        return 1
    fi
    
    # Add timeout protection for arecord
    if timeout 2 arecord -l 2>/dev/null | grep -q "card ${card_num}:"; then
        log DEBUG "Audio device card ${card_num} found in arecord -l"
        return 0
    fi
    
    log DEBUG "Audio device card ${card_num} not accessible"
    return 1
}

# Generate stream path name with friendly names when available (FIX #4: Simplified)
generate_stream_path() {
    local device_name="$1"
    local card_num="${2:-}"  # Optional card number parameter
    local base_path=""
    
    # First, try to get the friendly name from /proc/asound/cards if we have card_num
    if [[ -n "$card_num" ]] && [[ -f "/proc/asound/cards" ]]; then
        local card_info
        card_info=$(grep -E "^ *${card_num} " /proc/asound/cards 2>/dev/null || true)
        
        if [[ -n "$card_info" ]]; then
            # Extract the name between square brackets [name]
            if [[ "$card_info" =~ \[([^]]+)\] ]]; then
                local card_name="${BASH_REMATCH[1]}"
                # Trim whitespace from card name
                card_name="$(echo "$card_name" | xargs)"
                
                # Check if this looks like a udev-assigned friendly name
                # (typically short, lowercase, no spaces or special chars)
                if [[ "$card_name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
                    log DEBUG "Found udev-friendly name: $card_name"
                    base_path="$card_name"
                else
                    log DEBUG "Card name '$card_name' doesn't look like udev name, using fallback"
                fi
            fi
        fi
    fi
    
    # If we didn't get a friendly name, fall back to the original logic
    if [[ -z "$base_path" ]]; then
        base_path="$(sanitize_path_name "$device_name")"
        log DEBUG "Using sanitized device name: $base_path"
    fi
    
    # Additional validation - ensure the path is MediaMTX compatible
    # MediaMTX has specific requirements for path names
    if [[ ! "$base_path" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        log WARN "Path '$base_path' may not be MediaMTX compatible, adding prefix"
        base_path="stream_${base_path}"
    fi
    
    # Ensure reasonable length (MediaMTX may have limits)
    if [[ ${#base_path} -gt 64 ]]; then
        log WARN "Path name too long, truncating"
        base_path="${base_path:0:64}"
    fi
    
    log DEBUG "Generated stream path: $base_path (from device: $device_name)"
    echo "$base_path"
}

# Test audio device capabilities with fallback
test_audio_device_safe() {
    local card_num="$1"
    local sample_rate="$2"
    local channels="$3"
    local format="$4"
    
    # Skip device testing if disabled
    if [[ "${DEVICE_TEST_ENABLED}" != "true" ]]; then
        log DEBUG "Device testing disabled, assuming device supports requested format"
        return 0
    fi
    
    # Convert format for arecord
    local arecord_format
    case "$format" in
        s16le) arecord_format="S16_LE" ;;
        s24le) arecord_format="S24_LE" ;;
        s32le) arecord_format="S32_LE" ;;
        *) arecord_format="S16_LE" ;;
    esac
    
    log DEBUG "Testing device hw:${card_num},0 with ${arecord_format} ${sample_rate}Hz ${channels}ch"
    
    # Test with requested parameters - direct hw access
    if timeout "${DEVICE_TEST_TIMEOUT}" arecord -D "hw:${card_num},0" -f "${arecord_format}" -r "${sample_rate}" -c "${channels}" -d 1 -t raw 2>/dev/null | head -c 1000 >/dev/null; then
        log DEBUG "Device test passed with hw:${card_num},0"
        return 0
    fi
    
    # If that fails, try with plughw for automatic format conversion
    log DEBUG "Testing with plughw:${card_num},0 for automatic format conversion"
    if timeout "${DEVICE_TEST_TIMEOUT}" arecord -D "plughw:${card_num},0" -f "${arecord_format}" -r "${sample_rate}" -c "${channels}" -d 1 -t raw 2>/dev/null | head -c 1000 >/dev/null; then
        log DEBUG "Device test passed with plughw:${card_num},0"
        return 0
    fi
    
    log DEBUG "Device test failed for card ${card_num}"
    return 1
}

# Get supported formats for a device
get_device_capabilities() {
    local card_num="$1"
    local capabilities=""
    
    if command -v arecord &>/dev/null; then
        # Try to get hardware parameters
        local hw_params
        hw_params=$(timeout 2 arecord -D "hw:${card_num},0" --dump-hw-params 2>&1 || true)
        
        if [[ -n "$hw_params" ]]; then
            # Extract supported sample rates
            local rates
            rates=$(echo "$hw_params" | grep -E "^RATE:" | sed 's/RATE: //' || true)
            
            # Extract supported formats
            local formats
            formats=$(echo "$hw_params" | grep -E "^FORMAT:" | sed 's/FORMAT: //' || true)
            
            # Extract supported channels
            local channels
            channels=$(echo "$hw_params" | grep -E "^CHANNELS:" | sed 's/CHANNELS: //' || true)
            
            if [[ -n "$rates" ]] || [[ -n "$formats" ]] || [[ -n "$channels" ]]; then
                capabilities="Rates: ${rates:-unknown}, Formats: ${formats:-unknown}, Channels: ${channels:-unknown}"
            fi
        fi
    fi
    
    echo "${capabilities:-Unable to determine capabilities}"
}

# Validate stream is working
validate_stream() {
    local stream_path="$1"
    local max_attempts="${2:-${STREAM_VALIDATION_ATTEMPTS}}"
    local attempt=0
    
    log DEBUG "Validating stream $stream_path (max attempts: ${max_attempts})"
    
    while [[ $attempt -lt $max_attempts ]]; do
        ((attempt++))
        
        # Wait before checking
        sleep "${STREAM_VALIDATION_DELAY}"
        
        # Check if FFmpeg process is still running
        local pid_file
        pid_file="$(get_ffmpeg_pid_file "$stream_path")"
        if [[ -f "$pid_file" ]] && kill -0 "$(read_pid_safe "$pid_file")" 2>/dev/null; then
            # Check for actual ffmpeg process
            if pgrep -P "$(read_pid_safe "$pid_file")" -f "ffmpeg.*${stream_path}" >/dev/null 2>&1; then
                log DEBUG "Stream $stream_path has active FFmpeg process (attempt ${attempt})"
                
                # Check via API if available
                if command -v curl &>/dev/null; then
                    local api_response
                    if api_response="$(curl -s "http://${MEDIAMTX_HOST}:9997/v3/paths/get/${stream_path}" 2>/dev/null)"; then
                        if echo "$api_response" | grep -q '"ready"[[:space:]]*:[[:space:]]*true'; then
                            log DEBUG "Stream $stream_path validated via API"
                            return 0
                        fi
                    fi
                fi
                
                # If API check failed but process is running, still consider it valid
                if [[ $attempt -eq $max_attempts ]]; then
                    log DEBUG "Stream $stream_path has running process, considering valid"
                    return 0
                fi
            fi
        else
            log DEBUG "Stream $stream_path process not found"
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

# Start FFmpeg stream with enhanced race condition check (FIX #2 & #3)
start_ffmpeg_stream() {
    local device_name="$1"
    local card_num="$2"
    local stream_path="$3"
    
    # FIX #2: Atomic stream path claiming using kernel-level flock
    local base_stream_path="$stream_path"
    local final_stream_path=""
    local suffix_counter=0
    local max_attempts=20
    local claim_fd=99
    
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
                        exec {claim_fd}>&-
                        rm -f "${claim_lock_file}"
                        return 0
                    else
                        rm -f "$pid_file"
                    fi
                fi
                
                log DEBUG "Claimed stream path: $final_stream_path"
                break
            else
                exec {claim_fd}>&-
                ((suffix_counter++))
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
    local pid_file
    pid_file="$(get_ffmpeg_pid_file "$stream_path")"
    
    # Verify device is accessible
    if ! check_audio_device "$card_num"; then
        log ERROR "Audio device card ${card_num} is not accessible"
        # Release claim lock on failure
        if [[ -n "${claim_fd:-}" ]]; then
            exec {claim_fd}>&-
            rm -f "${FFMPEG_PID_DIR}/${stream_path}.claim"
        fi
        return 1
    fi
    
    # Get device configuration
    local sample_rate channels format codec bitrate alsa_buffer alsa_period thread_queue
    sample_rate="$(get_device_config "$device_name" "SAMPLE_RATE" "$DEFAULT_SAMPLE_RATE")"
    channels="$(get_device_config "$device_name" "CHANNELS" "$DEFAULT_CHANNELS")"
    format="$(get_device_config "$device_name" "FORMAT" "$DEFAULT_FORMAT")"
    codec="$(get_device_config "$device_name" "CODEC" "$DEFAULT_CODEC")"
    bitrate="$(get_device_config "$device_name" "BITRATE" "$DEFAULT_BITRATE")"
    alsa_buffer="$(get_device_config "$device_name" "ALSA_BUFFER" "$DEFAULT_ALSA_BUFFER")"
    alsa_period="$(get_device_config "$device_name" "ALSA_PERIOD" "$DEFAULT_ALSA_PERIOD")"
    thread_queue="$(get_device_config "$device_name" "THREAD_QUEUE" "$DEFAULT_THREAD_QUEUE")"
    
    log INFO "Configuring $device_name: ${sample_rate}Hz, ${channels}ch, ${format} format, ${codec} codec"
    
    # Determine if we need format conversion based on device test or configuration
    local use_plughw="true"  # Default to using plughw for better compatibility
    local format_to_use="$format"
    
    # Only run device test if enabled
    if [[ "${DEVICE_TEST_ENABLED}" == "true" ]]; then
        if test_audio_device_safe "$card_num" "$sample_rate" "$channels" "$format"; then
            log INFO "Device supports requested format directly"
            use_plughw="false"
        else
            # Try common fallback formats
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
    
    # Create wrapper script
    local wrapper_script="${FFMPEG_PID_DIR}/${stream_path}.sh"
    local ffmpeg_log="${FFMPEG_PID_DIR}/${stream_path}.log"
    
    # Write wrapper script
    cat > "$wrapper_script" << 'WRAPPER_HEADER'
#!/bin/bash
# Auto-restart wrapper for FFmpeg stream
WRAPPER_HEADER

    # Add variables
    cat >> "$wrapper_script" << WRAPPER_VARS
STREAM_PATH="${stream_path}"
LOG_FILE="${LOG_FILE}"
FFMPEG_LOG="${ffmpeg_log}"
PID_FILE="${pid_file}"
CARD_NUM="${card_num}"
RESTART_COUNT=0
RESTART_DELAY=10
MAX_SHORT_RUNS=3
SHORT_RUN_COUNT=0
USE_PLUGHW="${use_plughw}"
CLEANUP_MARKER="${CLEANUP_MARKER}"
MEDIAMTX_HOST="${MEDIAMTX_HOST}"

# Audio parameters
SAMPLE_RATE="${sample_rate}"
CHANNELS="${channels}"
FORMAT="${format_to_use}"
OUTPUT_CODEC="${codec}"
BITRATE="${bitrate}"
ALSA_BUFFER="${alsa_buffer}"
ALSA_PERIOD="${alsa_period}"
THREAD_QUEUE="${thread_queue}"
FIFO_SIZE="${DEFAULT_FIFO_SIZE}"
ANALYZEDURATION="${DEFAULT_ANALYZEDURATION}"
PROBESIZE="${DEFAULT_PROBESIZE}"

# Global variable for FFmpeg PID
FFMPEG_PID=""
WRAPPER_VARS

    # Add the main wrapper logic with FIXED PID handling, STREAM LOCK, and IMPROVED LOGGING
    cat >> "$wrapper_script" << 'WRAPPER_MAIN'

touch "${FFMPEG_LOG}"

# Stream lock file for mutual exclusion
STREAM_LOCK="${FFMPEG_PID_DIR}/${STREAM_PATH}.lock"

# v1.1.5: Improved logging separation
# Stream-specific wrapper messages go to FFMPEG_LOG
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WRAPPER] $1" >> "${FFMPEG_LOG}"
}

# Critical system-wide messages go to main LOG_FILE
log_critical() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [STREAM:${STREAM_PATH}] $1" >> "${LOG_FILE}"
}

# Build and execute FFmpeg command
run_ffmpeg() {
    local cmd=()
    cmd+=(ffmpeg)
    
    # Global options
    cmd+=(-hide_banner)
    cmd+=(-loglevel warning)
    
    # Choose device based on USE_PLUGHW
    local audio_device
    if [[ "${USE_PLUGHW}" == "true" ]]; then
        audio_device="plughw:${CARD_NUM},0"
    else
        audio_device="hw:${CARD_NUM},0"
    fi
    
    # Input options - thread_queue_size must come BEFORE -i
    cmd+=(-f alsa)
    cmd+=(-thread_queue_size "${THREAD_QUEUE}")
    cmd+=(-i "${audio_device}")
    
    # Force input format
    cmd+=(-ar "${SAMPLE_RATE}")
    cmd+=(-ac "${CHANNELS}")
    
    # Audio filter - async resampling for clock drift compensation
    cmd+=(-af "aresample=async=1:first_pts=0")
    
    # Encoding options based on codec
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
            # PCM requires more buffering for stability
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
    
    # Output options
    cmd+=(-f rtsp)
    cmd+=(-rtsp_transport tcp)
    cmd+=("rtsp://${MEDIAMTX_HOST}:8554/${STREAM_PATH}")
    
    # Execute the command array directly and capture PID
    "${cmd[@]}" >> "${FFMPEG_LOG}" 2>&1 &
    FFMPEG_PID=$!
    
    # CRITICAL FIX: Verify FFmpeg started successfully
    if [[ -z "$FFMPEG_PID" ]] || ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
        log_message "ERROR: FFmpeg failed to start or exited immediately"
        log_critical "FFmpeg failed to start for stream ${STREAM_PATH}"
        FFMPEG_PID=""
        return 1
    fi
    
    log_message "Started FFmpeg with PID ${FFMPEG_PID}"
    return 0
}

# Check if device is still available
check_device_exists() {
    [[ -e "/dev/snd/pcmC${CARD_NUM}D0c" ]]
}

# Log critical startup message
log_critical "Stream wrapper starting for ${STREAM_PATH} (card ${CARD_NUM})"

# Main loop
while true; do
    # Check if cleanup is in progress
    if [[ -f "${CLEANUP_MARKER}" ]]; then
        log_message "Cleanup in progress, stopping wrapper for ${STREAM_PATH}"
        log_critical "Stream ${STREAM_PATH} stopping due to system cleanup"
        break
    fi
    
    if [[ ! -f "${PID_FILE}" ]]; then
        log_message "PID file removed, stopping wrapper for ${STREAM_PATH}"
        log_critical "Stream ${STREAM_PATH} stopping due to PID file removal"
        break
    fi
    
    if ! check_device_exists; then
        log_message "Device card ${CARD_NUM} no longer exists, stopping wrapper"
        log_critical "Stream ${STREAM_PATH} stopping - device card ${CARD_NUM} removed"
        break
    fi
    
    log_message "Starting FFmpeg for ${STREAM_PATH} (attempt #$((RESTART_COUNT + 1)))"
    
    # Rotate log if too large (10MB)
    if [[ -f "${FFMPEG_LOG}" ]] && [[ $(stat -c%s "${FFMPEG_LOG}" 2>/dev/null || echo 0) -gt 10485760 ]]; then
        mv "${FFMPEG_LOG}" "${FFMPEG_LOG}.old"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Log rotated" > "${FFMPEG_LOG}"
    fi
    
    # Record start time
    START_TIME=$(date +%s)
    
    # CRITICAL FIX: Acquire exclusive lock before starting FFmpeg
    # This prevents multiple wrappers from starting FFmpeg for the same stream
    exec 200>"${STREAM_LOCK}"
    if ! flock -n 200; then
        log_message "Another wrapper already owns stream ${STREAM_PATH}, exiting cleanly"
        log_critical "Stream ${STREAM_PATH} wrapper exiting - another instance owns the stream"
        rm -f "${PID_FILE}"
        exit 0  # Exit cleanly - this is not an error
    fi
    
    log_message "Acquired exclusive lock for stream ${STREAM_PATH}"
    
    # Execute FFmpeg (lock is held via fd 200)
    if ! run_ffmpeg; then
        log_message "Failed to start FFmpeg, waiting before retry"
        # Release lock before sleeping
        exec 200>&-
        sleep 30
        continue
    fi
    
    # Give FFmpeg time to initialize
    sleep 3
    
    # CRITICAL FIX: Use polling approach instead of just wait
    # This is more robust for detecting process exit
    exit_code=0
    while [[ -n "${FFMPEG_PID}" ]] && kill -0 "$FFMPEG_PID" 2>/dev/null; do
        sleep 1
    done
    
    # Capture actual exit code after process has died
    if [[ -n "${FFMPEG_PID}" ]]; then
        wait "$FFMPEG_PID" 2>/dev/null
        exit_code=$?
    fi
    
    # Release the lock (close fd 200)
    exec 200>&-
    
    # Calculate run time
    END_TIME=$(date +%s)
    RUN_TIME=$((END_TIME - START_TIME))
    
    log_message "FFmpeg for ${STREAM_PATH} exited with code ${exit_code} after ${RUN_TIME} seconds"
    
    # Log last errors
    if [[ -s "${FFMPEG_LOG}" ]]; then
        tail -5 "${FFMPEG_LOG}" | while IFS= read -r line; do
            [[ -n "${line}" ]] && log_message "FFmpeg: ${line}"
        done
    fi
    
    # Increment restart counter
    ((RESTART_COUNT++))
    
    # Handle short runs
    if [[ ${RUN_TIME} -lt 60 ]]; then
        ((SHORT_RUN_COUNT++))
        if [[ ${SHORT_RUN_COUNT} -ge ${MAX_SHORT_RUNS} ]]; then
            log_message "Too many short runs (${SHORT_RUN_COUNT}), extended delay of 300s"
            log_critical "Stream ${STREAM_PATH} experiencing repeated failures - 300s cooldown"
            RESTART_DELAY=300
            SHORT_RUN_COUNT=0
        else
            RESTART_DELAY=60
            log_message "Short run detected (#${SHORT_RUN_COUNT}), waiting ${RESTART_DELAY}s"
        fi
    else
        SHORT_RUN_COUNT=0
        RESTART_DELAY=10
        log_message "Normal restart, waiting ${RESTART_DELAY}s"
    fi
    
    sleep ${RESTART_DELAY}
done

log_message "Wrapper exiting for ${STREAM_PATH}"
log_critical "Stream wrapper terminated for ${STREAM_PATH}"
rm -f "${PID_FILE}"
WRAPPER_MAIN
    
    chmod +x "$wrapper_script"
    
    # FIX #3: Start wrapper first, then create PID file
    nohup "$wrapper_script" >/dev/null 2>&1 &
    local pid=$!
    
    # Brief pause for process startup
    sleep 0.05
    
    # Verify wrapper started
    if ! kill -0 "$pid" 2>/dev/null; then
        log ERROR "Wrapper failed to start for $stream_path"
        rm -f "$wrapper_script"
        rm -f "${FFMPEG_PID_DIR}/${stream_path}.log"
        # Release claim if held
        if [[ -n "${claim_fd:-}" ]]; then
            exec {claim_fd}>&-
            rm -f "${FFMPEG_PID_DIR}/${stream_path}.claim"
        fi
        return 1
    fi
    
    # Atomically create PID file
    write_pid_atomic "$pid" "$pid_file"
    log DEBUG "Wrapper started with PID $pid for stream $stream_path"
    
    # Wait for startup
    sleep "${STREAM_STARTUP_DELAY}"
    
    if kill -0 "$pid" 2>/dev/null; then
        # Release claim lock after successful startup
        if [[ -n "${claim_fd:-}" ]]; then
            exec {claim_fd}>&-
            rm -f "${FFMPEG_PID_DIR}/${stream_path}.claim"
        fi
        
        # Validate the stream is actually working
        if validate_stream "$stream_path"; then
            log INFO "FFmpeg for $stream_path started successfully (PID: $pid)"
            # Output the actual stream path used for proper propagation
            echo "$stream_path"
            return 0
        else
            log ERROR "Stream $stream_path failed validation"
            kill "$pid" 2>/dev/null || true
            rm -f "$pid_file"
            return 1
        fi
    else
        log ERROR "Wrapper script failed to start for $stream_path"
        rm -f "$pid_file"
        # Release claim lock on failure
        if [[ -n "${claim_fd:-}" ]]; then
            exec {claim_fd}>&-
            rm -f "${FFMPEG_PID_DIR}/${stream_path}.claim"
        fi
        return 1
    fi
}

# Stop FFmpeg stream
stop_ffmpeg_stream() {
    local stream_path="$1"
    local pid_file
    pid_file="$(get_ffmpeg_pid_file "$stream_path")"
    
    if [[ ! -f "$pid_file" ]]; then
        return 0
    fi
    
    local pid
    pid="$(read_pid_safe "$pid_file")"
    
    # Remove PID file to signal wrapper to stop
    rm -f "$pid_file"
    
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        log INFO "Stopping FFmpeg for $stream_path (PID: $pid)"
        
        # Send SIGTERM to wrapper
        kill -TERM "$pid" 2>/dev/null || true
        
        # Kill child processes
        pkill -TERM -P "$pid" 2>/dev/null || true
        
        local timeout=10
        while kill -0 "$pid" 2>/dev/null && [[ $timeout -gt 0 ]]; do
            sleep 1
            ((timeout--))
        done
        
        if [[ $timeout -eq 0 ]]; then
            kill -KILL "$pid" 2>/dev/null || true
            pkill -KILL -P "$pid" 2>/dev/null || true
        fi
    fi
    
    # Cleanup
    rm -f "${FFMPEG_PID_DIR}/${stream_path}.sh"
    rm -f "${FFMPEG_PID_DIR}/${stream_path}.log"
    rm -f "${FFMPEG_PID_DIR}/${stream_path}.log.old"
    rm -f "${FFMPEG_PID_DIR}/${stream_path}.claim"
}

# Start all FFmpeg streams (FIX #1: Variable scoping)
start_all_ffmpeg_streams() {
    local devices=()
    readarray -t devices < <(detect_audio_devices)
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        log WARN "No USB audio devices detected"
        return 0
    fi
    
    # Verify udev names before starting
    verify_udev_names
    
    log INFO "Starting FFmpeg streams for ${#devices[@]} devices"
    
    # Array to store actual stream paths used
    local -a stream_paths_used=()
    
    # Check if we should start streams in parallel (for faster startup with many devices)
    local parallel_start="${PARALLEL_STREAM_START:-false}"
    
    local success_count=0
    local -a start_pids=()
    
    for device_info in "${devices[@]}"; do
        IFS=':' read -r device_name card_num <<< "$device_info"
        
        if [[ ! -e "/dev/snd/controlC${card_num}" ]]; then
            log WARN "Skipping inaccessible device $device_name (card $card_num)"
            continue
        fi
        
        # Generate stream path with card number for friendly name lookup
        local stream_path
        stream_path="$(generate_stream_path "$device_name" "$card_num")"
        
        # Store the actual path used
        stream_paths_used+=("${device_info}:${stream_path}")
        
        if [[ "$parallel_start" == "true" ]] && [[ ${#devices[@]} -gt 3 ]]; then
            # Start in background for parallel processing
            # Use result files to track success/failure and actual path
            local result_file="${FFMPEG_PID_DIR}/.start_result_$_${RANDOM}"
            (
                local actual_path
                if actual_path=$(start_ffmpeg_stream "$device_name" "$card_num" "$stream_path"); then
                    echo "SUCCESS:${actual_path}" > "${result_file}"
                else
                    echo "FAILED" > "${result_file}"
                fi
            ) &
            start_pids+=("$!:${result_file}")
        else
            # Sequential start (default for reliability)
            local actual_stream_path
            if actual_stream_path=$(start_ffmpeg_stream "$device_name" "$card_num" "$stream_path"); then
                ((success_count++))
                # Store the actual path that was used (may differ due to collision handling)
                stream_paths_used+=("${device_info}:${actual_stream_path}")
            else
                stream_paths_used+=("${device_info}:${stream_path}:FAILED")
            fi
        fi
    done
    
    # If we started in parallel, wait for all to complete
    if [[ "$parallel_start" == "true" ]] && [[ ${#start_pids[@]} -gt 0 ]]; then
        log INFO "Waiting for parallel stream starts to complete..."
        for pid_info in "${start_pids[@]}"; do
            IFS=':' read -r pid result_file <<< "$pid_info"
            wait "$pid"
            if [[ -f "${result_file}" ]]; then
                local result_content
                result_content=$(cat "${result_file}")
                if [[ "$result_content" == SUCCESS:* ]]; then
                    ((success_count++))
                    # Extract the actual path from the result
                    local actual_path="${result_content#SUCCESS:}"
                    # Find the corresponding device info
                    for device_info in "${devices[@]}"; do
                        IFS=':' read -r device_name card_num <<< "$device_info"
                        local expected_path
                        expected_path="$(generate_stream_path "$device_name" "$card_num")"
                        # Match based on expected base path
                        if [[ "$actual_path" == "$expected_path"* ]]; then
                            stream_paths_used+=("${device_info}:${actual_path}")
                            break
                        fi
                    done
                fi
            fi
            rm -f "${result_file}"
        done
    fi
    
    log INFO "Started $success_count/${#devices[@]} FFmpeg streams"
    
    # FIX #1: Export the stream paths for use by the caller
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
    
    # Kill any stragglers
    pkill -f "ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" || true
}

# Generate MediaMTX configuration - FIX #1: Use wildcard pattern for dynamic paths
generate_mediamtx_config() {
    log INFO "Generating MediaMTX configuration with dynamic path support"
    
    if [[ ! -f "${DEVICE_CONFIG_FILE}" ]]; then
        save_device_config
    fi
    
    load_device_config
    
    # Ensure we start with a clean temp file
    rm -f "${TEMP_CONFIG}"
    
    # FIX #1: Use a wildcard pattern that accepts any audio stream path
    # This solves the path desynchronization issue by allowing any path
    cat > "${TEMP_CONFIG}" << 'EOF'
# MediaMTX Configuration - Audio Streams
logLevel: info

# Timeouts
readTimeout: 600s
writeTimeout: 600s

# API
api: yes
apiAddress: :9997

# Metrics
metrics: yes
metricsAddress: :9998

# RTSP Server
rtsp: yes
rtspAddress: :8554
# Enable TCP and UDP
rtspTransports: [tcp, udp]

# Disable other protocols
rtmp: no
hls: no
webrtc: no
srt: no

# Paths - Dynamic configuration that accepts any audio stream
paths:
  # Accept any stream path - this prevents path desynchronization issues
  ~^[a-zA-Z0-9_-]+$:
    source: publisher
    sourceProtocol: automatic
    # Optional: Add authentication or other settings here if needed
EOF
    
    # Validate YAML if possible
    if command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
        if ! python3 -c "import yaml; yaml.safe_load(open('${TEMP_CONFIG}'))" 2>/dev/null; then
            log ERROR "Invalid YAML syntax in generated configuration"
            rm -f "${TEMP_CONFIG}"
            return 1
        fi
    fi
    
    # Move config into place
    mv -f "${TEMP_CONFIG}" "${CONFIG_FILE}"
    chmod 644 "${CONFIG_FILE}"
    
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

# Start MediaMTX (FIX #1: Variable scoping)
start_mediamtx() {
    acquire_lock
    
    # Check if this is a restart scenario
    if is_restart_scenario; then
        log INFO "Detected restart scenario, performing enhanced cleanup"
        cleanup_stale_processes
        wait_for_usb_stabilization 20
        clear_restart_marker
    else
        # Still do basic cleanup
        cleanup_stale_processes
    fi
    
    # Kill existing processes
    if pgrep -f "${MEDIAMTX_BIN}" >/dev/null; then
        if systemctl is-active mediamtx >/dev/null 2>&1; then
            log ERROR "MediaMTX systemd service is running. Stop it first:"
            log ERROR "  sudo systemctl stop mediamtx"
            log ERROR "  sudo systemctl disable mediamtx"
            release_lock
            return 1
        fi
        
        log INFO "Killing existing MediaMTX processes"
        pkill -f "${MEDIAMTX_BIN}" || true
        sleep 2
    fi
    
    if is_mediamtx_running; then
        log WARN "MediaMTX already running"
        release_lock
        return 0
    fi
    
    log INFO "Starting MediaMTX..."
    
    setup_directories
    
    # Wait for USB devices to be ready
    if ! wait_for_usb_stabilization; then
        log ERROR "USB audio subsystem not ready"
        release_lock
        return 1
    fi
    
    # Check for devices
    local devices=()
    readarray -t devices < <(detect_audio_devices)
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        log ERROR "No USB audio devices detected"
        release_lock
        return 1
    fi
    
    # Generate config
    if ! generate_mediamtx_config; then
        release_lock
        handle_error FATAL "Failed to generate configuration" 4
    fi
    
    # Check ports
    for port in 8554 9997 9998; do
        if lsof -i ":$port" >/dev/null 2>&1; then
            log ERROR "Port $port is already in use"
            release_lock
            return 1
        fi
    done
    
    # Set ulimits for MediaMTX
    ulimit -n 65536
    ulimit -u 4096
    
    # Start MediaMTX
    nohup "${MEDIAMTX_BIN}" "${CONFIG_FILE}" > /var/log/mediamtx.out 2>&1 &
    local pid=$!
    
    sleep 5
    
    if kill -0 "$pid" 2>/dev/null; then
        write_pid_atomic "$pid" "${PID_FILE}"
        log INFO "MediaMTX started successfully (PID: $pid)"
        
        # Start FFmpeg streams
        # FIX #1: Declare array and use readarray to capture output
        local -a STREAM_PATHS_USED=()
        readarray -t STREAM_PATHS_USED < <(start_all_ffmpeg_streams)
        
        # Show results
        echo
        echo -e "${GREEN}=== Available RTSP Streams ===${NC}"
        local success_count=0
        
        # Use the stored stream paths from start_all_ffmpeg_streams
        if [[ ${#STREAM_PATHS_USED[@]} -gt 0 ]]; then
            for stream_info in "${STREAM_PATHS_USED[@]}"; do
                IFS=':' read -r device_name card_num stream_path <<< "$stream_info"
                
                # Validate stream is actually working
                if validate_stream "$stream_path"; then
                    echo -e "${GREEN}✔${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path}"
                    ((success_count++))
                else
                    echo -e "${RED}✗${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_path} (failed to start)"
                fi
            done
        else
            # Fallback to re-detecting if STREAM_PATHS_USED is empty
            if [[ ${#devices[@]} -gt 0 ]]; then
                for device_info in "${devices[@]}"; do
                    IFS=':' read -r device_name card_num <<< "$device_info"
                    # Look for the PID file to find the actual stream path used
                    local found_stream=""
                    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
                        if [[ -f "$pid_file" ]]; then
                            local stream_name
                            stream_name="$(basename "$pid_file" .pid)"
                            # Check if this might be for our device
                            if [[ "$stream_name" == *"$(sanitize_path_name "$device_name")"* ]] || 
                               grep -q "CARD_NUM=\"${card_num}\"" "${FFMPEG_PID_DIR}/${stream_name}.sh" 2>/dev/null; then
                                found_stream="$stream_name"
                                break
                            fi
                        fi
                    done
                    
                    if [[ -n "$found_stream" ]]; then
                        if validate_stream "$found_stream"; then
                            echo -e "${GREEN}✔${NC} rtsp://${MEDIAMTX_HOST}:8554/${found_stream}"
                            ((success_count++))
                        else
                            echo -e "${RED}✗${NC} rtsp://${MEDIAMTX_HOST}:8554/${found_stream} (failed to start)"
                        fi
                    fi
                done
            fi
        fi
        echo
        echo -e "${GREEN}Successfully started ${success_count}/${#devices[@]} streams${NC}"
        
        if [[ ${success_count} -eq 0 ]]; then
            log ERROR "No streams started successfully"
            release_lock
            return 1
        fi
        
        release_lock
        return 0
    else
        log ERROR "MediaMTX failed to start"
        if [[ -f /var/log/mediamtx.out ]]; then
            log ERROR "Output: $(tail -5 /var/log/mediamtx.out 2>/dev/null | tr '\n' ' ')"
        fi
        
        # Show the generated config for debugging
        if [[ -f "${CONFIG_FILE}" ]]; then
            log ERROR "Checking generated configuration for issues:"
            log ERROR "Path pattern in config:"
            grep -n "~^" "${CONFIG_FILE}" | tail -10 >&2
        fi
        
        release_lock
        return 1
    fi
}

# Stop MediaMTX
stop_mediamtx() {
    acquire_lock
    
    stop_all_ffmpeg_streams
    
    if ! is_mediamtx_running; then
        log WARN "MediaMTX is not running"
        pkill -f "${MEDIAMTX_BIN}" || true
        release_lock
        return 0
    fi
    
    log INFO "Stopping MediaMTX..."
    
    local pid
    pid="$(read_pid_safe "${PID_FILE}")"
    
    if [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null; then
        local timeout=30
        while kill -0 "$pid" 2>/dev/null && [[ $timeout -gt 0 ]]; do
            sleep 1
            ((timeout--))
        done
        
        if [[ $timeout -eq 0 ]]; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    
    rm -f "${PID_FILE}"
    pkill -f "${MEDIAMTX_BIN}" || true
    
    log INFO "MediaMTX stopped"
    release_lock
    return 0
}

# Restart MediaMTX
restart_mediamtx() {
    mark_restart
    stop_mediamtx
    sleep "${RESTART_STABILIZATION_DELAY}"
    start_mediamtx
}

# Show status
show_status() {
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
        # Build a map of actual running streams first
        declare -A running_streams
        declare -A stream_to_device
        
        # Find all running FFmpeg processes
        for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
            if [[ -f "$pid_file" ]]; then
                local stream_name
                stream_name="$(basename "$pid_file" .pid)"
                
                if kill -0 "$(read_pid_safe "$pid_file")" 2>/dev/null; then
                    running_streams["$stream_name"]=1
                    
                    # Extract card number from wrapper script
                    local wrapper="${FFMPEG_PID_DIR}/${stream_name}.sh"
                    if [[ -f "$wrapper" ]]; then
                        local card_num_from_wrapper
                        card_num_from_wrapper=$(grep -E "^CARD_NUM=" "$wrapper" | cut -d= -f2 | tr -d '"')
                        if [[ -n "$card_num_from_wrapper" ]]; then
                            stream_to_device["$card_num_from_wrapper"]="$stream_name"
                        fi
                    fi
                fi
            fi
        done
        
        # Debug: show raw device info
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
            
            # Find the actual stream name for this card
            local actual_stream_path="${stream_to_device[$card_num]}"
            
            # If not found in our map, look for it
            if [[ -z "$actual_stream_path" ]]; then
                # Try to find by matching device name in PID files
                for stream_name in "${!running_streams[@]}"; do
                    local wrapper="${FFMPEG_PID_DIR}/${stream_name}.sh"
                    if [[ -f "$wrapper" ]] && grep -q "CARD_NUM=\"${card_num}\"" "$wrapper"; then
                        actual_stream_path="$stream_name"
                        break
                    fi
                done
            fi
            
            # If still not found, generate what it should be (but this is just for display)
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
            
            # Check if this stream is actually running
            if [[ -n "${running_streams[$actual_stream_path]}" ]]; then
                local pid_file="${FFMPEG_PID_DIR}/${actual_stream_path}.pid"
                if [[ -f "$pid_file" ]]; then
                    local wrapper_pid
                    wrapper_pid="$(read_pid_safe "$pid_file")"
                    if [[ -n "$wrapper_pid" ]]; then
                        echo -e "    Wrapper: ${GREEN}Running${NC} (PID: ${wrapper_pid})"
                        
                        # Check for actual FFmpeg process
                        if pgrep -P "${wrapper_pid}" -f "ffmpeg" >/dev/null 2>&1; then
                            echo -e "    FFmpeg: ${GREEN}Active${NC}"
                            echo -e "    Stream: ${GREEN}Healthy${NC}"
                        else
                            echo -e "    FFmpeg: ${YELLOW}Starting/Restarting${NC}"
                        fi
                    fi
                fi
            else
                echo -e "    Status: ${RED}Not running${NC}"
            fi
            
            # Show last error if available
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
        echo "  ALSA buffer: ${DEFAULT_ALSA_BUFFER}μs"
        echo "  ALSA period: ${DEFAULT_ALSA_PERIOD}μs"
        echo "  Thread queue: ${DEFAULT_THREAD_QUEUE}"
        echo "  Device testing: ${DEVICE_TEST_ENABLED}"
        echo
        
        for device_info in "${devices[@]}"; do
            IFS=':' read -r device_name card_num <<< "$device_info"
            
            echo "Device: $device_name"
            echo "  Card: $card_num"
            
            local sanitized_name
            sanitized_name="$(sanitize_device_name "$device_name")"
            echo "  Variable prefix: DEVICE_${sanitized_name^^}_"
            
            # Check audio access
            if check_audio_device "$card_num"; then
                echo -e "  Access: ${GREEN}OK${NC}"
                
                # Only test device if enabled
                if [[ "${DEVICE_TEST_ENABLED}" == "true" ]]; then
                    # Test device with current settings
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
                
                # Show device capabilities
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
    
    # Get actual running streams
    declare -A running_streams
    declare -A stream_to_card
    
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        if [[ -f "$pid_file" ]]; then
            local stream_name
            stream_name="$(basename "$pid_file" .pid)"
            
            if kill -0 "$(read_pid_safe "$pid_file")" 2>/dev/null; then
                running_streams["$stream_name"]=1
                
                # Extract card number from wrapper script
                local wrapper="${FFMPEG_PID_DIR}/${stream_name}.sh"
                if [[ -f "$wrapper" ]]; then
                    local card_num
                    card_num=$(grep -E "^CARD_NUM=" "$wrapper" | cut -d= -f2 | tr -d '"')
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
    echo "Monitor stream statistics:"
    echo "  curl http://${MEDIAMTX_HOST}:9997/v3/paths/list | jq"
}

# Debug streams with enhanced output
debug_streams() {
    echo -e "${CYAN}=== Debugging Audio Streams ===${NC}"
    echo
    
    if ! is_mediamtx_running; then
        echo -e "${RED}MediaMTX is not running${NC}"
        return 1
    fi
    
    # Get actual running streams
    declare -A running_streams
    declare -A stream_to_card
    
    for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
        if [[ -f "$pid_file" ]]; then
            local stream_name
            stream_name="$(basename "$pid_file" .pid)"
            
            if kill -0 "$(read_pid_safe "$pid_file")" 2>/dev/null; then
                running_streams["$stream_name"]=1
                
                # Extract card number from wrapper script
                local wrapper="${FFMPEG_PID_DIR}/${stream_name}.sh"
                if [[ -f "$wrapper" ]]; then
                    local card_num
                    card_num=$(grep -E "^CARD_NUM=" "$wrapper" | cut -d= -f2 | tr -d '"')
                    if [[ -n "$card_num" ]]; then
                        stream_to_card["$stream_name"]="$card_num"
                    fi
                fi
            fi
        fi
    done
    
    # Debug each running stream
    for stream_path in "${!running_streams[@]}"; do
        echo "Stream: $stream_path"
        
        # Check wrapper and FFmpeg
        local pid_file
        pid_file="$(get_ffmpeg_pid_file "$stream_path")"
        if [[ -f "$pid_file" ]] && kill -0 "$(read_pid_safe "$pid_file")" 2>/dev/null; then
            local wrapper_pid
            wrapper_pid="$(read_pid_safe "$pid_file")"
            
            if [[ -n "$wrapper_pid" ]]; then
                # Get FFmpeg PID
                local ffmpeg_pid
                ffmpeg_pid="$(pgrep -P "${wrapper_pid}" -f "ffmpeg" | head -1)"
                
                if [[ -n "$ffmpeg_pid" ]]; then
                    echo "  FFmpeg PID: $ffmpeg_pid"
                    echo "  FFmpeg command:"
                    ps -p "$ffmpeg_pid" -o args= | fold -w 80 -s | sed 's/^/    /'
                    
                    # Check CPU usage
                    local cpu_usage
                    cpu_usage="$(ps -p "$ffmpeg_pid" -o %cpu= | tr -d ' ')"
                    echo "  CPU usage: ${cpu_usage}%"
                fi
            fi
        fi
        
        # Show last 10 lines of FFmpeg log
        local ffmpeg_log="${FFMPEG_PID_DIR}/${stream_path}.log"
        if [[ -f "$ffmpeg_log" ]]; then
            echo "  Recent log entries:"
            tail -10 "$ffmpeg_log" | sed 's/^/    /'
        fi
        
        echo
    done
    
    # Enhanced: Test stream with clear success/failure indication
    echo "Testing stream connectivity..."
    if [[ ${#running_streams[@]} -gt 0 ]]; then
        # Get first running stream
        local test_stream
        for stream in "${!running_streams[@]}"; do
            test_stream="$stream"
            break
        done
        
        echo "Test command: ffmpeg -loglevel verbose -i rtsp://${MEDIAMTX_HOST}:8554/${test_stream} -t 2 -f null -"
        
        # Capture exit code and provide clear feedback
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
    
    while true; do
        clear
        echo -e "${CYAN}=== Stream Monitor - $(date) ===${NC}"
        echo
        
        # Get actual running streams
        declare -A running_streams
        declare -A stream_to_card
        declare -A card_to_stream
        
        for pid_file in "${FFMPEG_PID_DIR}"/*.pid; do
            if [[ -f "$pid_file" ]]; then
                local stream_name
                stream_name="$(basename "$pid_file" .pid)"
                
                if kill -0 "$(read_pid_safe "$pid_file")" 2>/dev/null; then
                    running_streams["$stream_name"]=1
                    
                    # Extract card number from wrapper script
                    local wrapper="${FFMPEG_PID_DIR}/${stream_name}.sh"
                    if [[ -f "$wrapper" ]]; then
                        local card_num
                        card_num=$(grep -E "^CARD_NUM=" "$wrapper" | cut -d= -f2 | tr -d '"')
                        if [[ -n "$card_num" ]]; then
                            stream_to_card["$stream_name"]="$card_num"
                            card_to_stream["$card_num"]="$stream_name"
                        fi
                    fi
                fi
            fi
        done
        
        # Show status for each device
        local devices=()
        readarray -t devices < <(detect_audio_devices)
        
        for device_info in "${devices[@]}"; do
            IFS=':' read -r device_name card_num <<< "$device_info"
            
            # Find the actual stream name for this card
            local stream_path="${card_to_stream[$card_num]}"
            
            if [[ -z "$stream_path" ]]; then
                # Device not running
                echo "Stream: [card $card_num - $device_name]"
                echo -e "  Status: ${RED}Not running${NC}"
                echo
                continue
            fi
            
            echo "Stream: $stream_path"
            
            # Check wrapper status
            local pid_file
            pid_file="$(get_ffmpeg_pid_file "$stream_path")"
            if [[ -f "$pid_file" ]] && kill -0 "$(read_pid_safe "$pid_file")" 2>/dev/null; then
                echo -e "  Status: ${GREEN}Running${NC}"
                
                # Get stream stats from API
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
        
        sleep 5
    done
}

# Create systemd service with audio group check
create_systemd_service() {
    local service_file="/etc/systemd/system/mediamtx-audio.service"
    
    # Enhanced: Check if audio group exists
    if ! getent group audio >/dev/null 2>&1; then
        log WARN "Audio group doesn't exist. The service may fail to start."
        log WARN "Create the group with: sudo groupadd audio"
    fi
    
    cat > "$service_file" << EOF
[Unit]
Description=Mediamtx Stream Manager
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

# Extended timeout for multiple devices
TimeoutStartSec=300
TimeoutStopSec=60

# Resource limits
LimitNOFILE=65536
LimitNPROC=4096
LimitRTPRIO=99
LimitNICE=-19

# Security - removed ProtectSystem=full to allow writing to /etc
PrivateTmp=yes
ProtectSystem=false
NoNewPrivileges=yes
ReadWritePaths=/etc/mediamtx /var/lib/mediamtx-ffmpeg /var/log

# Environment
Environment="HOME=/root"
Environment="USB_STABILIZATION_DELAY=10"
Environment="RESTART_STABILIZATION_DELAY=15"
Environment="DEVICE_TEST_ENABLED=false"
Environment="ERROR_HANDLING_MODE=fail-safe"
Environment="MEDIAMTX_HOST=localhost"
WorkingDirectory=${SCRIPT_DIR}

# Audio priority
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
    echo "Note: The service has enhanced restart handling for system updates."
    echo "It will automatically detect and handle service restarts gracefully."
    echo ""
    echo "For faster startup with many devices, you can enable parallel starts:"
    echo "  sudo systemctl edit mediamtx-audio"
    echo "  Add: Environment=\"PARALLEL_STREAM_START=true\""
    echo "  Add: Environment=\"STREAM_STARTUP_DELAY=5\""
    echo ""
    echo "For multi-host deployments, configure the MediaMTX host:"
    echo "  Add: Environment=\"MEDIAMTX_HOST=your-server-ip\""
    echo ""
    echo "The service includes:"
    echo "  - USB stabilization delay for restart scenarios"
    echo "  - Enhanced cleanup of stale processes"
    echo "  - Automatic detection of restart conditions"
    echo "  - Device testing disabled by default for stability"
    echo "  - Atomic stream path claiming with flock"
    echo "  - PID file validation to prevent corruption issues"
}

# Validate command input
validate_command() {
    local cmd="$1"
    local valid_commands="start stop restart status config test debug monitor install help"
    
    if [[ -z "$cmd" ]]; then
        return 0  # Default to help
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
from USB audio devices with production-ready logging separation and enhanced reliability.

Usage: ${SCRIPT_NAME} [COMMAND]

Commands:
    start       Start MediaMTX and FFmpeg streams
    stop        Stop MediaMTX and FFmpeg streams
    restart     Restart everything
    status      Show current status
    config      Show device configuration
    test        Show stream test commands
    debug       Debug stream issues (enhanced output)
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
    ALSA buffer: 100ms
    ALSA period: 20ms

Enhancements in v${VERSION}:
    - Fixed critical path desynchronization bug between config and runtime
    - Added cleanup_stale_processes to exit trap for proper cleanup
    - Separated wrapper logs from system logs for better organization
    - Stream-specific messages now in individual stream logs
    - Critical system events remain in main log file
    - Improved log readability for 24/7 production monitoring
    - Enhanced PID file validation to prevent invalid process operations
    - Made MediaMTX host configurable via MEDIAMTX_HOST environment variable
    - Improved error handling for device operations
    - Fixed variable scoping bug in stream path handling
    - Implemented atomic stream path claiming with flock
    - Fixed PID file creation race condition
    - Simplified generate_stream_path function

Critical Fixes:
    - Path Desynchronization: MediaMTX now uses wildcard pattern to accept
      any stream path, preventing failures when FFmpeg chooses alternate paths
    - Cleanup Trap: Exit trap now properly calls cleanup_stale_processes
      to ensure all orphaned processes are terminated on unexpected exit

Log Locations:
    - System events: ${LOG_FILE}
    - Stream events: ${FFMPEG_PID_DIR}/<stream>.log
    - MediaMTX core: ${MEDIAMTX_LOG}

Environment variables:
    MEDIAMTX_HOST=localhost            MediaMTX server host (for multi-host setups)
    STREAM_STARTUP_DELAY=10            Seconds to wait after starting each stream
    PARALLEL_STREAM_START=false        Start all streams in parallel
    DEVICE_TEST_ENABLED=false          Enable device format testing
    DEVICE_TEST_TIMEOUT=3              Device test timeout in seconds
    USB_STABILIZATION_DELAY=5          Wait for USB to stabilize (seconds)
    RESTART_STABILIZATION_DELAY=10     Extra delay on restart (seconds)
    ERROR_HANDLING_MODE=fail-safe      Error handling (fail-safe or fail-fast)
    DEBUG=true                         Enable debug logging

Monitoring in Production:
    - Check system health: tail -f ${LOG_FILE}
    - Monitor specific stream: tail -f ${FFMPEG_PID_DIR}/<stream>.log
    - Watch all streams: tail -f ${FFMPEG_PID_DIR}/*.log
    - Service status: systemctl status mediamtx-audio
    - Service logs: journalctl -u mediamtx-audio -f

Common issues:
    - Path desync: FIXED - MediaMTX now accepts any stream path dynamically
    - Orphaned processes: FIXED - Cleanup trap ensures proper termination
    - Service restart problems: Automatically handled since v1.1.3
    - Stream path collisions: Fixed with atomic flock in v1.1.5
    - Log confusion: Resolved with separation in v1.1.5
    - PID corruption: Fixed with validation in v1.1.5
    - Ugly stream names: Run usb-audio-mapper.sh
    - Format errors: Script defaults to plughw for compatibility
    - Multi-host setup: Set MEDIAMTX_HOST environment variable

EOF
}

# Main
main() {
    setup_directories
    
    # Validate command before proceeding
    if ! validate_command "${1:-}"; then
        show_help
        exit 1
    fi
    
    if [[ "${1:-}" != "help" ]]; then
        check_dependencies
        check_root
    fi
    
    load_device_config
    
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
            # This shouldn't happen due to validation, but keep as safety
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

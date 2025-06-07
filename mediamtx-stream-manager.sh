#!/bin/bash
# mediamtx-audio-stream-manager.sh - Automatic MediaMTX audio stream configuration
#
# This script automatically detects USB microphones and creates MediaMTX 
# configurations for continuous 24/7 RTSP audio streams.
#
# Version: 8.0.3 - Fixed systemd timeout and filesystem permissions
# Compatible with MediaMTX v1.12.3+
#
# Requirements:
# - MediaMTX installed (use install_mediamtx.sh)
# - USB audio devices
# - ffmpeg installed for audio encoding
#
# Usage: ./mediamtx-audio-stream-manager.sh [start|stop|restart|status|config|help]

set -euo pipefail

# Constants
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_DIR="/etc/mediamtx"
readonly CONFIG_FILE="${CONFIG_DIR}/mediamtx.yml"
readonly DEVICE_CONFIG_FILE="${CONFIG_DIR}/audio-devices.conf"
readonly PID_FILE="/var/run/mediamtx-audio.pid"
readonly FFMPEG_PID_DIR="/var/lib/mediamtx-ffmpeg"
readonly LOCK_FILE="/var/run/mediamtx-audio.lock"
readonly LOG_FILE="/var/log/mediamtx-audio-manager.log"
readonly MEDIAMTX_LOG="/var/log/mediamtx.log"
readonly MEDIAMTX_BIN="/usr/local/bin/mediamtx"
readonly TEMP_CONFIG="/tmp/mediamtx-audio-$$.yml"

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

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Cleanup function
cleanup() {
    local exit_code=$?
    rm -f "${TEMP_CONFIG}"
    rm -f "${LOCK_FILE}"
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

error_exit() {
    log ERROR "$1"
    exit "${2:-1}"
}

# Lock file operations
acquire_lock() {
    local timeout="${1:-30}"
    local count=0
    
    while [[ -f "${LOCK_FILE}" ]] && [[ $count -lt $timeout ]]; do
        sleep 1
        ((count++))
    done
    
    if [[ $count -ge $timeout ]]; then
        error_exit "Failed to acquire lock after ${timeout} seconds" 5
    fi
    
    echo $$ > "${LOCK_FILE}"
}

release_lock() {
    rm -f "${LOCK_FILE}"
}

# Check if running as root
check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        error_exit "This script must be run as root (use sudo)" 2
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
        error_exit "Missing dependencies: ${missing[*]}" 3
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
    
    touch "${LOG_FILE}"
    touch "${MEDIAMTX_LOG}"
    chmod 666 "${MEDIAMTX_LOG}"
    chmod 644 "${LOG_FILE}"
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

# Check if audio device is accessible
check_audio_device() {
    local card_num="$1"
    
    # First check if device exists
    if [[ ! -e "/dev/snd/pcmC${card_num}D0c" ]]; then
        log DEBUG "Device file /dev/snd/pcmC${card_num}D0c does not exist"
        return 1
    fi
    
    # Try to list device capabilities
    if arecord -l 2>/dev/null | grep -q "card ${card_num}:"; then
        log DEBUG "Audio device card ${card_num} found in arecord -l"
        return 0
    fi
    
    log DEBUG "Audio device card ${card_num} not accessible"
    return 1
}

# Generate stream path name with friendly names when available
generate_stream_path() {
    local device_name="$1"
    local card_num="${2:-}"  # Optional card number parameter
    local check_collisions="${3:-true}"  # Optional parameter to disable collision check
    local base_path=""
    local final_path=""
    
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
    
    # Only check for collisions if requested (not during config generation)
    if [[ "$check_collisions" == "true" ]]; then
        # Check if this base path is already in use by checking active streams
        local collision_check="${base_path}"
        local suffix=0
        
        # Check against existing FFmpeg PID files to detect active streams
        while [[ -f "${FFMPEG_PID_DIR}/${collision_check}.pid" ]]; do
            # Check if the PID is actually running
            if [[ -f "${FFMPEG_PID_DIR}/${collision_check}.pid" ]]; then
                local existing_pid
                existing_pid=$(cat "${FFMPEG_PID_DIR}/${collision_check}.pid" 2>/dev/null || echo "0")
                
                if kill -0 "$existing_pid" 2>/dev/null; then
                    # Process is running, we need a different name
                    suffix=$((suffix + 1))
                    collision_check="${base_path}_${suffix}"
                    log DEBUG "Name collision detected, trying: $collision_check"
                else
                    # Stale PID file, clean it up
                    log DEBUG "Cleaning stale PID file for: $collision_check"
                    rm -f "${FFMPEG_PID_DIR}/${collision_check}.pid"
                    break
                fi
            fi
        done
        
        final_path="$collision_check"
    else
        final_path="$base_path"
    fi
    
    # Additional validation - ensure the path is MediaMTX compatible
    # MediaMTX has specific requirements for path names
    if [[ ! "$final_path" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        log WARN "Path '$final_path' may not be MediaMTX compatible, adding prefix"
        final_path="stream_${final_path}"
    fi
    
    # Ensure reasonable length (MediaMTX may have limits)
    if [[ ${#final_path} -gt 64 ]]; then
        log WARN "Path name too long, truncating"
        final_path="${final_path:0:64}"
    fi
    
    log DEBUG "Generated stream path: $final_path (from device: $device_name)"
    echo "$final_path"
}

# Test audio device capabilities with fallback
test_audio_device_safe() {
    local card_num="$1"
    local sample_rate="$2"
    local channels="$3"
    local format="$4"
    
    # Convert format for arecord
    local arecord_format
    case "$format" in
        s16le) arecord_format="S16_LE" ;;
        s24le) arecord_format="S24_LE" ;;
        s32le) arecord_format="S32_LE" ;;
        *) arecord_format="S16_LE" ;;
    esac
    
    # Test with requested parameters
    if timeout 2 arecord -D "hw:${card_num},0" -f "${arecord_format}" -r "${sample_rate}" -c "${channels}" -d 1 2>/dev/null | head -c 1000 >/dev/null; then
        return 0
    fi
    
    # If that fails, try with plughw for automatic format conversion
    if timeout 2 arecord -D "plughw:${card_num},0" -f "${arecord_format}" -r "${sample_rate}" -c "${channels}" -d 1 2>/dev/null | head -c 1000 >/dev/null; then
        return 0
    fi
    
    return 1
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
        if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
            # Check for actual ffmpeg process
            if pgrep -P "$(cat "$pid_file")" -f "ffmpeg.*${stream_path}" >/dev/null 2>&1; then
                log DEBUG "Stream $stream_path has active FFmpeg process (attempt ${attempt})"
                
                # Check via API if available
                if command -v curl &>/dev/null; then
                    local api_response
                    if api_response="$(curl -s "http://localhost:9997/v3/paths/get/${stream_path}" 2>/dev/null)"; then
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

# Start FFmpeg stream
start_ffmpeg_stream() {
    local device_name="$1"
    local card_num="$2"
    local stream_path="$3"
    
    local pid_file
    pid_file="$(get_ffmpeg_pid_file "$stream_path")"
    
    # Check if already running
    if [[ -f "$pid_file" ]]; then
        local pid
        pid="$(cat "$pid_file")"
        if kill -0 "$pid" 2>/dev/null; then
            log DEBUG "FFmpeg for $stream_path already running (PID: $pid)"
            return 0
        fi
    fi
    
    # Verify device is accessible
    if ! check_audio_device "$card_num"; then
        log ERROR "Audio device card ${card_num} is not accessible"
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
    
    # Test device capabilities and use fallback if needed
    if ! test_audio_device_safe "$card_num" "$sample_rate" "$channels" "$format"; then
        log WARN "Device test failed with ${format}, trying fallback to s16le"
        format="s16le"
        if ! test_audio_device_safe "$card_num" "$sample_rate" "$channels" "$format"; then
            log WARN "Device test still failing, will use plughw for format conversion"
        fi
    fi
    
    log INFO "Starting FFmpeg for $stream_path with format: $format"
    
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

# Audio parameters
SAMPLE_RATE="${sample_rate}"
CHANNELS="${channels}"
FORMAT="${format}"
OUTPUT_CODEC="${codec}"
BITRATE="${bitrate}"
ALSA_BUFFER="${alsa_buffer}"
ALSA_PERIOD="${alsa_period}"
THREAD_QUEUE="${thread_queue}"
FIFO_SIZE="${DEFAULT_FIFO_SIZE}"
ANALYZEDURATION="${DEFAULT_ANALYZEDURATION}"
PROBESIZE="${DEFAULT_PROBESIZE}"
WRAPPER_VARS

    # Add the main wrapper logic
    cat >> "$wrapper_script" << 'WRAPPER_MAIN'

touch "${FFMPEG_LOG}"

log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE}"
}

# Build FFmpeg command
build_ffmpeg_cmd() {
    local cmd="ffmpeg"
    
    # Global options
    cmd+=" -hide_banner"
    cmd+=" -loglevel warning"
    
    # Input options - thread_queue_size must come BEFORE -i
    cmd+=" -f alsa"
    cmd+=" -thread_queue_size ${THREAD_QUEUE}"
    cmd+=" -i plughw:${CARD_NUM},0"
    
    # Force input format
    cmd+=" -ar ${SAMPLE_RATE}"
    cmd+=" -ac ${CHANNELS}"
    
    # Audio filter - async resampling for clock drift compensation
    cmd+=" -af aresample=async=1:first_pts=0"
    
    # Encoding options based on codec
    case "${OUTPUT_CODEC}" in
        opus)
            cmd+=" -c:a libopus"
            cmd+=" -b:a ${BITRATE}"
            cmd+=" -application lowdelay"
            cmd+=" -frame_duration 20"
            cmd+=" -packet_loss 10"
            ;;
        aac)
            cmd+=" -c:a aac"
            cmd+=" -b:a ${BITRATE}"
            cmd+=" -aac_coder twoloop"
            ;;
        mp3)
            cmd+=" -c:a libmp3lame"
            cmd+=" -b:a ${BITRATE}"
            cmd+=" -reservoir 0"
            ;;
        pcm)
            # PCM requires more buffering for stability
            cmd+=" -c:a pcm_s16be"
            cmd+=" -max_delay 500000"
            cmd+=" -fflags +genpts+nobuffer"
            ;;
        *)
            cmd+=" -c:a libopus"
            cmd+=" -b:a ${BITRATE}"
            cmd+=" -application lowdelay"
            ;;
    esac
    
    # Output options
    cmd+=" -f rtsp"
    cmd+=" -rtsp_transport tcp"
    cmd+=" rtsp://localhost:8554/${STREAM_PATH}"
    
    echo "$cmd"
}

# Check if device is still available
check_device_exists() {
    [[ -e "/dev/snd/pcmC${CARD_NUM}D0c" ]]
}

# Main loop
while true; do
    if [[ ! -f "${PID_FILE}" ]]; then
        log_message "PID file removed, stopping wrapper for ${STREAM_PATH}"
        break
    fi
    
    if ! check_device_exists; then
        log_message "Device card ${CARD_NUM} no longer exists, stopping wrapper"
        break
    fi
    
    log_message "Starting FFmpeg for ${STREAM_PATH} (attempt #$((RESTART_COUNT + 1)))"
    
    # Rotate log if too large (10MB)
    if [[ -f "${FFMPEG_LOG}" ]] && [[ $(stat -c%s "${FFMPEG_LOG}" 2>/dev/null || echo 0) -gt 10485760 ]]; then
        mv "${FFMPEG_LOG}" "${FFMPEG_LOG}.old"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Log rotated" > "${FFMPEG_LOG}"
    fi
    
    # Build and execute FFmpeg command
    FFMPEG_CMD=$(build_ffmpeg_cmd)
    log_message "Command: ${FFMPEG_CMD}"
    
    # Record start time
    START_TIME=$(date +%s)
    
    # Execute FFmpeg
    eval "${FFMPEG_CMD}" >> "${FFMPEG_LOG}" 2>&1 &
    FFMPEG_PID=$!
    
    # Give FFmpeg time to initialize
    sleep 3
    
    # Wait for FFmpeg to exit
    wait ${FFMPEG_PID}
    exit_code=$?
    
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
rm -f "${PID_FILE}"
WRAPPER_MAIN
    
    chmod +x "$wrapper_script"
    
    # Start wrapper
    nohup "$wrapper_script" >/dev/null 2>&1 &
    local pid=$!
    
    # Save PID
    echo "$pid" > "$pid_file"
    
    # Wait for startup
    sleep "${STREAM_STARTUP_DELAY}"
    
    if kill -0 "$pid" 2>/dev/null; then
        # Validate the stream is actually working
        if validate_stream "$stream_path"; then
            log INFO "FFmpeg for $stream_path started successfully (PID: $pid)"
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
    pid="$(cat "$pid_file")"
    
    # Remove PID file to signal wrapper to stop
    rm -f "$pid_file"
    
    if kill -0 "$pid" 2>/dev/null; then
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
}

# Start all FFmpeg streams
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
            (
                if start_ffmpeg_stream "$device_name" "$card_num" "$stream_path"; then
                    echo "SUCCESS:${device_info}:${stream_path}"
                else
                    echo "FAILED:${device_info}:${stream_path}"
                fi
            ) &
            start_pids+=($!)
        else
            # Sequential start (default for reliability)
            if start_ffmpeg_stream "$device_name" "$card_num" "$stream_path"; then
                ((success_count++))
            fi
        fi
    done
    
    # If we started in parallel, wait for all to complete
    if [[ "$parallel_start" == "true" ]] && [[ ${#start_pids[@]} -gt 0 ]]; then
        log INFO "Waiting for parallel stream starts to complete..."
        for pid in "${start_pids[@]}"; do
            if wait "$pid"; then
                local result
                result=$(wait "$pid" 2>&1)
                if [[ "$result" =~ ^SUCCESS: ]]; then
                    ((success_count++))
                fi
            fi
        done
    fi
    
    log INFO "Started $success_count/${#devices[@]} FFmpeg streams"
    
    # Export the stream paths for use by the caller
    STREAM_PATHS_USED=("${stream_paths_used[@]}")
    
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
    pkill -f "ffmpeg.*rtsp://localhost:8554" || true
}

# Generate MediaMTX configuration
generate_mediamtx_config() {
    local devices=()
    readarray -t devices < <(detect_audio_devices)
    
    log INFO "Generating MediaMTX configuration for ${#devices[@]} devices"
    
    if [[ ! -f "${DEVICE_CONFIG_FILE}" ]]; then
        save_device_config
    fi
    
    load_device_config
    
    # Ensure we start with a clean temp file
    rm -f "${TEMP_CONFIG}"
    
    # Create minimal configuration - just the essentials for RTSP audio
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
rtspTransports: [tcp]

# Disable other protocols
rtmp: no
hls: no
webrtc: no
srt: no

# Paths
paths:
EOF

    # Add paths for each device
    local added_paths=""
    if [[ ${#devices[@]} -gt 0 ]]; then
        for device_info in "${devices[@]}"; do
            IFS=':' read -r device_name card_num <<< "$device_info"
            
            if [[ ! -e "/dev/snd/controlC${card_num}" ]]; then
                log DEBUG "Skipping device ${device_name} - control device not found"
                continue
            fi
            
            # Generate stream path with card number for friendly name lookup
            # Don't check for collisions during config generation
            local stream_path
            stream_path="$(generate_stream_path "$device_name" "$card_num" "false")"
            
            log DEBUG "Config: device=$device_name card=$card_num path=$stream_path"
            
            # Make sure we haven't already added this path
            if [[ "$added_paths" =~ ":${stream_path}:" ]]; then
                log WARN "Skipping duplicate path: ${stream_path}"
                continue
            fi
            added_paths="${added_paths}:${stream_path}:"
            
            cat >> "${TEMP_CONFIG}" << EOF
  ${stream_path}:
    source: publisher
    sourceProtocol: automatic
EOF
        done
    fi
    
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
    
    log INFO "Configuration generated successfully"
    return 0
}

# Check if MediaMTX is running
is_mediamtx_running() {
    if [[ -f "${PID_FILE}" ]]; then
        local pid
        pid="$(cat "${PID_FILE}")"
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

# Start MediaMTX
start_mediamtx() {
    acquire_lock
    
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
        error_exit "Failed to generate configuration" 4
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
        echo "$pid" > "${PID_FILE}"
        log INFO "MediaMTX started successfully (PID: $pid)"
        
        # Start FFmpeg streams
        # Declare array to store stream paths
        local -a STREAM_PATHS_USED=()
        start_all_ffmpeg_streams
        
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
                    echo -e "${GREEN}✓${NC} rtsp://localhost:8554/${stream_path}"
                    ((success_count++))
                else
                    echo -e "${RED}✗${NC} rtsp://localhost:8554/${stream_path} (failed to start)"
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
                            echo -e "${GREEN}✓${NC} rtsp://localhost:8554/${found_stream}"
                            ((success_count++))
                        else
                            echo -e "${RED}✗${NC} rtsp://localhost:8554/${found_stream} (failed to start)"
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
            log ERROR "Path definitions in config:"
            grep -n "^  [a-zA-Z0-9_-]*:" "${CONFIG_FILE}" | tail -10 >&2
            
            # Check for exact duplicates
            local dup_paths
            dup_paths=$(grep "^  [a-zA-Z0-9_-]*:" "${CONFIG_FILE}" | sort | uniq -d)
            if [[ -n "$dup_paths" ]]; then
                log ERROR "Found duplicate path definitions:"
                echo "$dup_paths" >&2
            fi
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
    pid="$(cat "${PID_FILE}")"
    
    if kill -TERM "$pid" 2>/dev/null; then
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
    stop_mediamtx
    sleep 5
    start_mediamtx
}

# Show status
show_status() {
    echo -e "${CYAN}=== MediaMTX Audio Stream Status ===${NC}"
    echo
    
    if is_mediamtx_running; then
        local pid
        pid="$(cat "${PID_FILE}")"
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
        local stream_count
        # Count only path entries under "paths:" section
        stream_count="$(awk '/^paths:/{flag=1;next}/^[^ ]/{flag=0}flag&&/^  [a-zA-Z0-9_-]+:/{count++}END{print count+0}' "${CONFIG_FILE}")"
        echo "Configured streams: $stream_count"
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
                
                if kill -0 "$(cat "$pid_file")" 2>/dev/null; then
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
            
            echo "  - $device_name (card $card_num) → rtsp://localhost:8554/$actual_stream_path"
            
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
                    wrapper_pid="$(cat "$pid_file")"
                    echo -e "    Wrapper: ${GREEN}Running${NC} (PID: ${wrapper_pid})"
                    
                    # Check for actual FFmpeg process
                    if pgrep -P "${wrapper_pid}" -f "ffmpeg" >/dev/null 2>&1; then
                        echo -e "    FFmpeg: ${GREEN}Active${NC}"
                        echo -e "    Stream: ${GREEN}Healthy${NC}"
                    else
                        echo -e "    FFmpeg: ${YELLOW}Starting/Restarting${NC}"
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
        if api_response="$(curl -s http://localhost:9997/v3/paths/list 2>/dev/null)"; then
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
                
                # Show device capabilities
                if command -v arecord &>/dev/null; then
                    local caps
                    caps="$(arecord -D "hw:${card_num},0" --dump-hw-params 2>&1 | grep -E "(RATE|CHANNELS|FORMAT)" | head -5 || true)"
                    if [[ -n "$caps" ]]; then
                        echo "  Capabilities:"
                        echo "$caps" | sed 's/^/    /'
                    fi
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
            
            if kill -0 "$(cat "$pid_file")" 2>/dev/null; then
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
        echo "  ffplay rtsp://localhost:8554/${stream_path}"
        echo "  vlc rtsp://localhost:8554/${stream_path}"
        echo "  mpv rtsp://localhost:8554/${stream_path}"
        echo
    done
    
    echo "Test with verbose output:"
    echo "  ffmpeg -loglevel verbose -i rtsp://localhost:8554/STREAM_NAME -t 10 -f null -"
    echo
    echo "Monitor stream statistics:"
    echo "  curl http://localhost:9997/v3/paths/list | jq"
}

# Debug streams
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
            
            if kill -0 "$(cat "$pid_file")" 2>/dev/null; then
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
        if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
            local wrapper_pid
            wrapper_pid="$(cat "$pid_file")"
            
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
        
        # Show last 10 lines of FFmpeg log
        local ffmpeg_log="${FFMPEG_PID_DIR}/${stream_path}.log"
        if [[ -f "$ffmpeg_log" ]]; then
            echo "  Recent log entries:"
            tail -10 "$ffmpeg_log" | sed 's/^/    /'
        fi
        
        echo
    done
    
    # Test stream with verbose output
    echo "Testing stream connectivity..."
    if [[ ${#running_streams[@]} -gt 0 ]]; then
        # Get first running stream
        local test_stream
        for stream in "${!running_streams[@]}"; do
            test_stream="$stream"
            break
        done
        
        echo "Test command: ffmpeg -loglevel verbose -i rtsp://localhost:8554/${test_stream} -t 2 -f null -"
        timeout 5 ffmpeg -loglevel verbose -i "rtsp://localhost:8554/${test_stream}" -t 2 -f null - 2>&1 | tail -20
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
                
                if kill -0 "$(cat "$pid_file")" 2>/dev/null; then
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
            if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
                echo -e "  Status: ${GREEN}Running${NC}"
                
                # Get stream stats from API
                if command -v curl &>/dev/null && command -v jq &>/dev/null; then
                    local stats
                    if stats="$(curl -s "http://localhost:9997/v3/paths/get/${stream_path}" 2>/dev/null)"; then
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

# Create systemd service
create_systemd_service() {
    local service_file="/etc/systemd/system/mediamtx-audio.service"
    
    cat > "$service_file" << EOF
[Unit]
Description=MediaMTX Audio Stream Manager
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
    echo "Note: The service has a 5-minute startup timeout to handle multiple devices."
    echo "If you have many devices, startup may take 15-30 seconds per device."
    echo ""
    echo "For faster startup with many devices, you can enable parallel starts:"
    echo "  sudo systemctl edit mediamtx-audio"
    echo "  Add: Environment=\"PARALLEL_STREAM_START=true\""
    echo "  Add: Environment=\"STREAM_STARTUP_DELAY=5\""
}

# Show help
show_help() {
    cat << EOF
MediaMTX Audio Stream Manager v8.0.3

Automatically configures MediaMTX for continuous 24/7 RTSP audio streaming
from USB audio devices using the official MediaMTX v1.12.3 configuration schema.

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
    Logs: ${LOG_FILE}
    FFmpeg logs: ${FFMPEG_PID_DIR}/<stream>.log

Default audio settings:
    Sample rate: 48000 Hz
    Channels: 2 (stereo)
    Format: s16le (16-bit little-endian)
    Codec: opus
    Bitrate: 128k
    ALSA buffer: 100ms
    ALSA period: 20ms

New in v8.0.3:
    - Fixed systemd service timeout for multiple devices
    - Fixed filesystem permissions for systemd service
    - Added configurable startup delay (STREAM_STARTUP_DELAY)
    - Added parallel stream start option (PARALLEL_STREAM_START)
    - Extended systemd timeout to 5 minutes for large deployments

Environment variables:
    STREAM_STARTUP_DELAY=10     Seconds to wait after starting each stream (default: 10)
    PARALLEL_STREAM_START=false Start all streams in parallel (default: false)
    DEBUG=true                  Enable debug logging (default: false)

Troubleshooting:
    - Check device access: arecord -l
    - View logs: tail -f ${LOG_FILE}
    - Check FFmpeg logs: tail -f ${FFMPEG_PID_DIR}/*.log
    - Monitor MediaMTX: tail -f ${MEDIAMTX_LOG}
    - Test device: arecord -D hw:N,0 -f S16_LE -r 48000 -c 2 -d 5 test.wav
    - Monitor streams: $0 monitor

Common issues:
    - Systemd timeout: Update service with 'sudo $0 install' and reload
    - Ugly stream names: Run usb-audio-mapper.sh to assign friendly names
    - Clients disconnecting: Check codec compatibility (avoid PCM for network streams)
    - No audio: Check ALSA buffer settings in config
    - Format errors: Script now auto-fallbacks to s16le
    - High CPU with PCM: Use compressed codecs (opus/aac)
    - Crackling: Increase ALSA_BUFFER in device config

EOF
}

# Main
main() {
    setup_directories
    
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
        help|--help|-h)
            show_help
            ;;
        *)
            echo "Error: Unknown command '${1}'"
            show_help
            exit 1
            ;;
    esac
}

# Run
if ! main "$@"; then
    exit 1
fi

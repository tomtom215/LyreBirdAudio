#!/bin/bash
# Enhanced Audio RTSP Streaming Script
# Version: 5.2.0
# Date: 2025-05-10
# Description: Production-grade script for streaming audio from capture devices to RTSP
#              With improved lock handling, atomic operations, and robust error recovery

# Exit on error (controlled)
set -o pipefail

# Global configuration variables - overridden by config file if present
MEDIAMTX_PATH="/usr/local/mediamtx/mediamtx"
RTSP_PORT="18554"
AUDIO_BITRATE="192k"
AUDIO_CODEC="libmp3lame"
AUDIO_CHANNELS="1"
AUDIO_SAMPLE_RATE="44100"
RUNTIME_DIR="/run/audio-rtsp"
TEMP_DIR="${RUNTIME_DIR}/tmp"
LOCK_FILE="${RUNTIME_DIR}/startmic.lock"
PID_FILE="${RUNTIME_DIR}/startmic.pid"
CONFIG_DIR="/etc/audio-rtsp"
DEVICE_CONFIG_DIR="${CONFIG_DIR}/devices"
LOG_DIR="/var/log/audio-rtsp"
STATE_DIR="${RUNTIME_DIR}/state"
DEVICE_MAP_FILE="${CONFIG_DIR}/device_map.conf"
DEVICE_BLACKLIST_FILE="${CONFIG_DIR}/device_blacklist.conf"
CONFIG_FILE="${CONFIG_DIR}/config"
FFMPEG_LOG_LEVEL="error"
FFMPEG_ADDITIONAL_OPTS=""
RESTART_DELAY=10
MAX_RESTART_ATTEMPTS=5
STREAM_CHECK_INTERVAL=30
LOG_LEVEL="info"  # Valid values: debug, info, warning, error
MAX_STREAMS=32    # Maximum number of streams to prevent resource exhaustion

# File descriptor for lock file
LOCK_FD=9

# Setup directories safely
setup_directories() {
    local dirs=(
        "$RUNTIME_DIR"
        "$TEMP_DIR"
        "$CONFIG_DIR"
        "$DEVICE_CONFIG_DIR"
        "$LOG_DIR"
        "$STATE_DIR"
    )
    
    for dir in "${dirs[@]}"; do
        if ! mkdir -p "$dir" 2>/dev/null; then
            if [[ "$dir" == "$RUNTIME_DIR"* ]]; then
                # Critical failure - can't create runtime dirs
                echo "ERROR: Failed to create runtime directory: $dir"
                echo "Attempting fallback to /tmp..."
                RUNTIME_DIR="/tmp/audio-rtsp"
                TEMP_DIR="${RUNTIME_DIR}/tmp"
                LOCK_FILE="${RUNTIME_DIR}/startmic.lock"
                PID_FILE="${RUNTIME_DIR}/startmic.pid"
                STATE_DIR="${RUNTIME_DIR}/state"
                
                # Try again with fallback
                if ! mkdir -p "$RUNTIME_DIR" "$TEMP_DIR" "$STATE_DIR" 2>/dev/null; then
                    echo "FATAL: Cannot create temporary directories. Exiting."
                    exit 1
                fi
                break
            elif [[ "$dir" == "$CONFIG_DIR"* ]]; then
                # Non-critical for config dirs - log and continue
                echo "WARNING: Failed to create config directory: $dir"
                if [[ "$dir" == "$DEVICE_CONFIG_DIR" ]]; then
                    DEVICE_CONFIG_DIR="${RUNTIME_DIR}/devices"
                    mkdir -p "$DEVICE_CONFIG_DIR" 2>/dev/null
                fi
            elif [[ "$dir" == "$LOG_DIR" ]]; then
                # Fallback for logs
                echo "WARNING: Failed to create log directory: $dir"
                LOG_DIR="${RUNTIME_DIR}/logs"
                mkdir -p "$LOG_DIR" 2>/dev/null
            fi
        fi
    done

    # Update paths if we had to use fallback directories
    TEMP_FILE="${TEMP_DIR}/stream_details.$$"
    LOG_FILE="${LOG_DIR}/audio-streams.log"
}

# Create required directories
setup_directories

# Initialize log with atomic write
initialize_log() {
    local temp_log="${LOG_FILE}.tmp.$$"
    {
        echo "----------------------------------------"
        echo "Service started at $(date)"
        echo "PID: $$"
        echo "----------------------------------------"
    } > "$temp_log"
    
    # Atomically move to create/append to log
    if [ -f "$LOG_FILE" ]; then
        cat "$temp_log" >> "$LOG_FILE"
        rm -f "$temp_log"
    else
        mv "$temp_log" "$LOG_FILE"
    fi
}

initialize_log

# Advanced logging function with proper log levels
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Determine if this message should be logged based on LOG_LEVEL
    local should_log=0
    case "$LOG_LEVEL" in
        debug)
            should_log=1
            ;;
        info)
            if [[ "$level" != "DEBUG" ]]; then
                should_log=1
            fi
            ;;
        warning)
            if [[ "$level" != "DEBUG" && "$level" != "INFO" ]]; then
                should_log=1
            fi
            ;;
        error)
            if [[ "$level" == "ERROR" || "$level" == "FATAL" ]]; then
                should_log=1
            fi
            ;;
    esac
    
    if [[ $should_log -eq 1 ]]; then
        # Atomic log write
        local temp_log="${LOG_FILE}.tmp.$$"
        echo "[$timestamp] [$level] $message" > "$temp_log"
        cat "$temp_log" >> "$LOG_FILE" 
        rm -f "$temp_log"
        
        # If this is a fatal error, also print to stderr
        if [[ "$level" == "FATAL" ]]; then
            echo "[$timestamp] [$level] $message" >&2
        fi
    fi
}

# Write a file atomically
atomic_write() {
    local file="$1"
    local content="$2"
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$file")" 2>/dev/null
    
    # Write to temp file first
    local temp_file="${file}.tmp.$$"
    echo "$content" > "$temp_file"
    
    # Move atomically
    mv "$temp_file" "$file"
    return $?
}

# Load configuration if available
if [ -f "$CONFIG_FILE" ]; then
    log "INFO" "Loading global configuration from $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Function to acquire lock with timeout
acquire_lock() {
    local lock_file="$1"
    local lock_fd="$2"
    local timeout="${3:-10}"  # Default timeout of 10 seconds
    
    # Make sure the directory exists
    mkdir -p "$(dirname "$lock_file")" 2>/dev/null
    
    # Open the lock file
    eval "exec $lock_fd>\"$lock_file\""
    
    log "DEBUG" "Attempting to acquire lock: $lock_file (FD: $lock_fd, timeout: ${timeout}s)"
    
    # Try to acquire the lock with timeout
    if ! flock -w "$timeout" -n "$lock_fd"; then
        # Check if there's a PID in the file
        if [ -s "$PID_FILE" ]; then
            OLD_PID=$(cat "$PID_FILE" 2>/dev/null || echo "0")
            if [[ -n "$OLD_PID" && "$OLD_PID" != "0" ]]; then
                # Check if process is still running
                if kill -0 "$OLD_PID" 2>/dev/null; then
                    log "ERROR" "Another instance is already running (PID: $OLD_PID)"
                    return 1
                else
                    log "WARNING" "Found stale PID file for non-existent process: $OLD_PID"
                    # We need to close and reopen the lock file
                    eval "exec $lock_fd>&-"
                    
                    # Remove stale lock and PID file
                    rm -f "$lock_file" "$PID_FILE"
                    
                    # Try again
                    eval "exec $lock_fd>\"$lock_file\""
                    if ! flock -w "$timeout" -n "$lock_fd"; then
                        log "ERROR" "Failed to acquire lock even after cleanup"
                        return 1
                    fi
                    log "INFO" "Successfully acquired lock after cleanup"
                fi
            else
                log "ERROR" "PID file contains invalid data"
                return 1
            fi
        else
            log "ERROR" "Cannot acquire lock (timeout after ${timeout}s)"
            return 1
        fi
    fi
    
    # Lock acquired, write our PID to it
    echo "$$" >&"$lock_fd"
    
    # Also write PID to PID file atomically
    atomic_write "$PID_FILE" "$$"
    
    log "DEBUG" "Successfully acquired lock: $lock_file"
    return 0
}

# Function to release lock
release_lock() {
    local lock_fd="$1"
    
    log "DEBUG" "Releasing lock (FD: $lock_fd)"
    
    # Close the file descriptor to release the lock
    eval "exec $lock_fd>&-"
    
    # Remove PID file if it contains our PID
    if [[ -f "$PID_FILE" ]]; then
        local pid_contents
        pid_contents=$(cat "$PID_FILE" 2>/dev/null || echo "")
        if [[ "$pid_contents" == "$$" ]]; then
            rm -f "$PID_FILE"
        fi
    fi
}

# Enhanced cleanup function
cleanup() {
    local exit_code="${1:-0}"
    local reason="${2:-normal exit}"
    
    log "INFO" "Starting cleanup process (reason: $reason)"
    
    # Stop all ffmpeg processes started by this script
    if [ -f "${TEMP_FILE}.pids" ]; then
        log "INFO" "Stopping ffmpeg processes"
        while read -r pid; do
            if kill -0 "$pid" 2>/dev/null; then
                log "DEBUG" "Stopping ffmpeg process: $pid"
                # First try SIGTERM for graceful shutdown
                kill -15 "$pid" 2>/dev/null
                
                # Give it a moment to shut down
                for ((i=0; i<3; i++)); do
                    if ! kill -0 "$pid" 2>/dev/null; then
                        break
                    fi
                    sleep 0.5
                done
                
                # If still running, force kill
                if kill -0 "$pid" 2>/dev/null; then
                    log "WARNING" "Process $pid didn't terminate gracefully, using SIGKILL"
                    kill -9 "$pid" 2>/dev/null
                fi
            fi
        done < "${TEMP_FILE}.pids"
    else
        # Fallback: try to stop relevant ffmpeg processes
        log "INFO" "No PID file found, attempting to find and stop ffmpeg RTSP processes"
        pkill -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" 2>/dev/null || true
    fi
    
    # Remove temporary files
    log "DEBUG" "Removing temporary files"
    rm -f "${TEMP_FILE}" "${TEMP_FILE}.pids" "${RUNTIME_DIR}/startmic_success"
    
    # Release lock
    release_lock "$LOCK_FD"
    
    log "INFO" "Cleanup completed, exiting with code $exit_code"
    
    # Exit with the provided exit code
    exit "$exit_code"
}

# Trap signals for clean exit
trap 'cleanup 0 "Received SIGINT"' INT
trap 'cleanup 0 "Received SIGTERM"' TERM
trap 'cleanup 0 "Normal exit"' EXIT

# Acquire lock
if ! acquire_lock "$LOCK_FILE" "$LOCK_FD" 10; then
    log "FATAL" "Failed to acquire lock, another instance may be running"
    # Don't call cleanup here as we don't have the lock
    exit 1
fi

# Store our PID
atomic_write "$PID_FILE" "$$"
log "INFO" "Process started with PID: $$"

# Define default excluded devices
EXCLUDED_DEVICES=("bcm2835_headpho" "vc4-hdmi" "HDMI" "vc4hdmi0" "vc4hdmi1")

# Load custom blacklist if it exists
if [ -f "$DEVICE_BLACKLIST_FILE" ]; then
    log "INFO" "Loading custom blacklist from $DEVICE_BLACKLIST_FILE"
    while read -r line; do
        # Skip comments and empty lines
        if [[ "$line" =~ ^[[:space:]]*# || -z "$line" ]]; then
            continue
        fi
        # Extract device ID (remove trailing comments if any)
        device_id=${line%%#*}
        device_id=$(echo "$device_id" | tr -d '[:space:]')  # Trim whitespace
        if [ -n "$device_id" ]; then
            EXCLUDED_DEVICES+=("$device_id")
        fi
    done < "$DEVICE_BLACKLIST_FILE"
else
    # Create a default blacklist file if it doesn't exist
    log "INFO" "Creating default blacklist file"
    mkdir -p "$(dirname "$DEVICE_BLACKLIST_FILE")" 2>/dev/null
    cat > "$DEVICE_BLACKLIST_FILE" << EOF
# Audio Device Blacklist - Add devices you want to exclude from streaming
# One device ID per line. Comments start with #

# Default excluded devices
bcm2835_headpho  # Raspberry Pi onboard audio output (no capture)
vc4-hdmi         # Raspberry Pi HDMI audio output (no capture)
HDMI             # Generic HDMI audio output (no capture)
vc4hdmi0         # Raspberry Pi HDMI0 audio output (no capture)
vc4hdmi1         # Raspberry Pi HDMI1 audio output (no capture)

# Add your custom exclusions below
EOF
fi

log "INFO" "Excluded devices: ${EXCLUDED_DEVICES[*]}"

# Kill any existing ffmpeg streams
log "INFO" "Stopping any existing ffmpeg streams..."
pkill -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" 2>/dev/null || true
sleep 1

# Function to check if MediaMTX is properly running and responding
check_mediamtx() {
    log "INFO" "Checking if MediaMTX is running..."

    # Method 1: Check for process
    if pgrep -f mediamtx > /dev/null; then
        log "INFO" "MediaMTX process found"
    elif command -v systemctl > /dev/null 2>&1 && systemctl is-active --quiet mediamtx.service; then
        log "INFO" "MediaMTX is running via systemd"
    else
        log "WARNING" "MediaMTX process not found, attempting to start"
        return 1
    fi
    
    # Method 2: Check if port is open
    if command -v nc > /dev/null 2>&1; then
        if nc -z localhost "$RTSP_PORT" 2>/dev/null; then
            log "INFO" "RTSP port $RTSP_PORT is open"
        else
            log "WARNING" "RTSP port $RTSP_PORT is not open"
            return 1
        fi
    fi
    
    # Method 3: Try a simple RTSP OPTIONS request if curl is available
    if command -v curl > /dev/null 2>&1; then
        if curl -s -I -X OPTIONS "rtsp://localhost:$RTSP_PORT" 2>&1 | grep -q "RTSP/1.0"; then
            log "INFO" "MediaMTX is responding to RTSP requests"
            return 0
        else
            log "WARNING" "MediaMTX not responding to RTSP requests properly"
            return 1
        fi
    fi
    
    # If we get here, basic checks passed but we couldn't do the full OPTIONS test
    return 0
}

# Start MediaMTX if needed
start_mediamtx() {
    # Try to start MediaMTX
    if [ -x "$MEDIAMTX_PATH" ]; then
        log "INFO" "Starting MediaMTX from $MEDIAMTX_PATH..."
        
        # Create log directory if it doesn't exist
        mkdir -p "$(dirname "${LOG_DIR}/mediamtx.log")" 2>/dev/null
        
        # Start MediaMTX with proper redirections
        "$MEDIAMTX_PATH" > "${LOG_DIR}/mediamtx.log" 2>&1 &
        
        # Store PID for potential future use
        local mediamtx_pid=$!
        log "INFO" "Started MediaMTX with PID: $mediamtx_pid"
        
        # Save in state directory
        mkdir -p "$STATE_DIR" 2>/dev/null
        atomic_write "${STATE_DIR}/mediamtx.pid" "$mediamtx_pid"
        
        # Give it time to initialize
        sleep 3
        
        # Check if it's running
        if kill -0 "$mediamtx_pid" 2>/dev/null; then
            log "INFO" "MediaMTX is running"
            return 0
        else
            log "ERROR" "MediaMTX failed to start"
            return 1
        fi
    else
        log "ERROR" "MediaMTX executable not found or not executable: $MEDIAMTX_PATH"
        return 1
    fi
}

# Check and potentially start MediaMTX
if ! check_mediamtx; then
    log "WARNING" "MediaMTX is not running properly"
    
    # Try to start via systemd first
    if command -v systemctl > /dev/null 2>&1 && systemctl list-unit-files | grep -q mediamtx.service; then
        log "INFO" "Attempting to start MediaMTX via systemd..."
        if systemctl start mediamtx.service; then
            log "INFO" "Started MediaMTX via systemd"
            sleep 3
        else
            log "ERROR" "Failed to start MediaMTX via systemd"
            # Fall back to direct start
            start_mediamtx
        fi
    else
        # Direct start
        start_mediamtx
    fi
    
    # Final check
    if ! check_mediamtx; then
        log "ERROR" "MediaMTX is still not running properly after start attempts"
        log "WARNING" "Continuing anyway, but streams may fail to connect"
    fi
fi

# Function to check if a sound card has a capture device
has_capture_device() {
    local card=$1
    if arecord -l 2>/dev/null | grep -q "card $card"; then
        return 0  # Has capture device
    else
        return 1  # No capture device
    fi
}

# Function to test if ffmpeg can capture from a device with retries
test_device_capture() {
    local card_id="$1"
    local max_retries=2
    local retry=0
    
    log "INFO" "Testing capture from card: $card_id"
    
    while [ $retry -le $max_retries ]; do
        # Run ffmpeg for a very short duration to test with plughw
        if timeout 3 ffmpeg -nostdin -f alsa -ac "$AUDIO_CHANNELS" -i "plughw:CARD=$card_id,DEV=0" \
             -t 0.1 -f null - > /dev/null 2>&1; then
            log "INFO" "Successfully captured audio from card: $card_id"
            return 0
        fi
        
        # Increment retry counter
        retry=$((retry + 1))
        
        if [ $retry -le $max_retries ]; then
            log "WARNING" "Failed to capture audio with plughw, trying alternative method..."
            
            # Try with hw: prefix instead
            if timeout 3 ffmpeg -nostdin -f alsa -ac "$AUDIO_CHANNELS" -i "hw:CARD=$card_id,DEV=0" \
                 -t 0.1 -f null - > /dev/null 2>&1; then
                log "INFO" "Successfully captured audio using hw: device reference"
                return 0
            fi
            
            # Small delay before next retry
            sleep 1
        fi
    done
    
    log "ERROR" "Failed to capture audio from card: $card_id after $max_retries retries"
    return 1
}

# Function to create a consistent unique identifier for a device
get_device_uuid() {
    local card_id="$1"
    local usb_info="$2"
    
    # For USB devices, use device-specific info to create a stable identifier
    if [ -n "$usb_info" ]; then
        # Extract vendor/product information if possible
        if [[ "$usb_info" =~ ([A-Za-z0-9]+:[A-Za-z0-9]+) ]]; then
            vendor_product="${BASH_REMATCH[1]}"
            echo "${card_id}_${vendor_product}" | tr -d ' '
        else
            # Fall back to a hash of the full USB info for uniqueness
            hash=$(echo "$usb_info" | md5sum | cut -c1-8)
            echo "${card_id}_${hash}" | tr -d ' '
        fi
    else
        # For non-USB devices, just use the card ID
        echo "$card_id" | tr -d ' '
    fi
}

# Function to get a user-friendly stream name
get_stream_name() {
    local card_id="$1"
    local device_uuid="$2"
    
    # First check if we have a mapped name for this device
    if [ -f "$DEVICE_MAP_FILE" ]; then
        local mapped_name
        mapped_name=$(grep "^$device_uuid=" "$DEVICE_MAP_FILE" 2>/dev/null | cut -d= -f2)
        if [ -n "$mapped_name" ]; then
            echo "$mapped_name"
            return
        fi
    fi
    
    # No mapping found, use sanitized card_id
    echo "$card_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g'
}

# Function to verify ffmpeg process is running properly
verify_ffmpeg_process() {
    local pid="$1"
    local stream_name="$2"
    local log_file="$3"
    local timeout=5  # seconds to wait for verification
    
    # First check if the process is running
    if ! kill -0 "$pid" 2>/dev/null; then
        log "ERROR" "FFmpeg process for $stream_name terminated immediately (PID: $pid)"
        return 1
    fi
    
    # Now wait for some output in the log file
    local start_time=$(date +%s)
    local current_time
    
    while true; do
        # Check for successful initialization in the log
        if [ -f "$log_file" ] && grep -q "Output #0, rtsp" "$log_file" 2>/dev/null; then
            log "INFO" "FFmpeg stream $stream_name successfully initialized (PID: $pid)"
            return 0
        fi
        
        # Check for errors
        if [ -f "$log_file" ] && grep -q "Error " "$log_file" 2>/dev/null; then
            log "ERROR" "FFmpeg error detected for $stream_name (PID: $pid)"
            log "ERROR" "Error details: $(grep "Error " "$log_file" | head -1)"
            return 1
        fi
        
        # Check if process still running
        if ! kill -0 "$pid" 2>/dev/null; then
            log "ERROR" "FFmpeg process for $stream_name terminated during initialization (PID: $pid)"
            return 1
        fi
        
        # Check timeout
        current_time=$(date +%s)
        if [ $((current_time - start_time)) -gt "$timeout" ]; then
            log "WARNING" "Timeout waiting for FFmpeg stream $stream_name initialization, assuming it's working (PID: $pid)"
            return 0
        fi
        
        # Small sleep to avoid CPU spinning
        sleep 0.5
    done
}

# Function to load device-specific configuration and start stream
start_device_stream() {
    local card_num="$1"
    local card_id="$2"
    local usb_info="$3"
    local rtsp_url="$4"
    local device_uuid="$5"
    local stream_name="$6"
    
    # Prepare log file for this stream
    local stream_log="${LOG_DIR}/${stream_name}_ffmpeg.log"
    
    # Save global audio settings
    local global_audio_channels="$AUDIO_CHANNELS"
    local global_audio_sample_rate="$AUDIO_SAMPLE_RATE"
    local global_audio_bitrate="$AUDIO_BITRATE"
    local global_audio_codec="$AUDIO_CODEC"
    local global_ffmpeg_additional_opts="$FFMPEG_ADDITIONAL_OPTS"
    
    # Check for device-specific config
    local device_config="${DEVICE_CONFIG_DIR}/${stream_name}.conf"
    local using_device_config=false
    
    if [ -f "$device_config" ]; then
        log "INFO" "Loading device-specific config for $stream_name: $device_config"
        # shellcheck disable=SC1090
        source "$device_config"
        using_device_config=true
    else
        log "INFO" "No device-specific config found for $stream_name, using global settings"
    fi
    
    # Log the settings being used
    log "INFO" "Using settings for $stream_name: channels=$AUDIO_CHANNELS, sample_rate=$AUDIO_SAMPLE_RATE, bitrate=$AUDIO_BITRATE, codec=$AUDIO_CODEC"
    
    # Create fresh log file
    > "$stream_log"
    
    # Start ffmpeg with the configured settings
    ffmpeg -nostdin -hide_banner -loglevel "$FFMPEG_LOG_LEVEL" \
          -f alsa -ac "$AUDIO_CHANNELS" -sample_rate "$AUDIO_SAMPLE_RATE" \
          -i "plughw:CARD=$card_id,DEV=0" \
          -acodec "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE" -ac "$AUDIO_CHANNELS" \
          -content_type 'audio/mpeg' $FFMPEG_ADDITIONAL_OPTS \
          -f rtsp -rtsp_transport tcp "$rtsp_url" > "$stream_log" 2>&1 &
    
    # Save the PID
    local ffmpeg_pid=$!
    
    # Verify the process is running properly
    if verify_ffmpeg_process "$ffmpeg_pid" "$stream_name" "$stream_log"; then
        # Add to PID file if verification passed
        echo "$ffmpeg_pid" >> "${TEMP_FILE}.pids"
        
        # Save PID to state directory for monitoring
        mkdir -p "${STATE_DIR}/streams" 2>/dev/null
        atomic_write "${STATE_DIR}/streams/${stream_name}.pid" "$ffmpeg_pid"
        
        # Create example device config if it doesn't exist (only do this the first time)
        if [ "$using_device_config" = false ] && [ ! -f "$device_config" ] && [ ! -f "${device_config}.example" ]; then
            log "INFO" "Creating example device config for $stream_name"
            mkdir -p "$DEVICE_CONFIG_DIR" 2>/dev/null
            cat > "${device_config}.example" << EOF
# Device-specific configuration for $stream_name
# Rename this file to $stream_name.conf (remove .example) to activate
# Created on $(date)

# Audio settings for this device
AUDIO_CHANNELS=$global_audio_channels
AUDIO_SAMPLE_RATE=$global_audio_sample_rate
AUDIO_BITRATE=$global_audio_bitrate
AUDIO_CODEC="$global_audio_codec"

# Advanced settings
# FFMPEG_ADDITIONAL_OPTS=""

# Additional device-specific settings
# AUDIO_NOISE_REDUCTION=true
# AUDIO_VOLUME_BOOST=1.5
EOF
        fi
        
        # Restore global settings for next device
        AUDIO_CHANNELS="$global_audio_channels"
        AUDIO_SAMPLE_RATE="$global_audio_sample_rate"
        AUDIO_BITRATE="$global_audio_bitrate"
        AUDIO_CODEC="$global_audio_codec"
        FFMPEG_ADDITIONAL_OPTS="$global_ffmpeg_additional_opts"
        
        return 0
    else
        log "ERROR" "Failed to start stream for $stream_name"
        # Clean up the failed process
        kill -9 "$ffmpeg_pid" 2>/dev/null || true
        
        # Restore global settings for next device
        AUDIO_CHANNELS="$global_audio_channels"
        AUDIO_SAMPLE_RATE="$global_audio_sample_rate"
        AUDIO_BITRATE="$global_audio_bitrate"
        AUDIO_CODEC="$global_audio_codec"
        FFMPEG_ADDITIONAL_OPTS="$global_ffmpeg_additional_opts"
        
        return 1
    fi
}

# Get list of sound cards
log "INFO" "Detecting sound cards with capture capabilities..."
SOUND_CARDS=$(cat /proc/asound/cards)
if [ -z "$SOUND_CARDS" ]; then
    log "ERROR" "Cannot access sound card information"
    atomic_write "${RUNTIME_DIR}/startmic_success" "STARTED"
    cleanup 0 "No sound cards detected"
fi

# Initialize tracking
rm -f "$TEMP_FILE" "${TEMP_FILE}.pids" 2>/dev/null
touch "$TEMP_FILE" "${TEMP_FILE}.pids"
STREAMS_CREATED=0
STREAM_ATTEMPTS=0

# Parse sound cards and start ffmpeg for each one with capture capability
while read -r line; do
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]*\[([^]]+)\][[:space:]]*:[[:space:]]*(.*) ]]; then
        CARD_NUM=${BASH_REMATCH[1]}
        CARD_ID=${BASH_REMATCH[2]}
        CARD_DESC=${BASH_REMATCH[3]}
        
        # Remove leading/trailing whitespace from card ID
        CARD_ID=$(echo "$CARD_ID" | tr -d '[:space:]')
        
        log "DEBUG" "Found sound card $CARD_NUM: $CARD_ID - $CARD_DESC"
        
        # Check if we've hit max streams limit
        if [ "$STREAMS_CREATED" -ge "$MAX_STREAMS" ]; then
            log "WARNING" "Maximum number of streams ($MAX_STREAMS) reached, skipping remaining devices"
            break
        fi
        
        # Limit attempts to prevent resource exhaustion
        STREAM_ATTEMPTS=$((STREAM_ATTEMPTS + 1))
        if [ "$STREAM_ATTEMPTS" -gt $((MAX_STREAMS * 2)) ]; then
            log "WARNING" "Too many stream attempts, possible infinite loop, breaking"
            break
        fi  # Fixed: Changed } to fi
        
        # Check if this device should be excluded
        EXCLUDED=0
        for excluded in "${EXCLUDED_DEVICES[@]}"; do
            if [ "$CARD_ID" = "$excluded" ]; then
                log "INFO" "Skipping excluded device: $CARD_ID"
                EXCLUDED=1
                break
            fi
        done
        
        if [ $EXCLUDED -eq 1 ]; then
            continue
        fi
        
        # Check if this card has capture capabilities
        if has_capture_device "$CARD_NUM"; then
            # Test if we can open the device
            if ! test_device_capture "$CARD_ID"; then
                log "WARNING" "Skipping card $CARD_NUM [$CARD_ID] - failed capture test"
                continue
            fi
            
            # Extract USB device info if available
            USB_INFO=""
            if [[ "$CARD_DESC" =~ USB-Audio ]]; then
                USB_INFO=$(echo "$CARD_DESC" | sed -n 's/.*USB-Audio - \(.*\)/\1/p')
            fi
            
            # Generate a stable, unique identifier for this device
            DEVICE_UUID=$(get_device_uuid "$CARD_ID" "$USB_INFO")
            
            # Get a stable, human-readable stream name
            STREAM_NAME=$(get_stream_name "$CARD_ID" "$DEVICE_UUID")
            RTSP_URL="rtsp://localhost:$RTSP_PORT/$STREAM_NAME"
            
            log "INFO" "Starting RTSP stream for card $CARD_NUM [$CARD_ID]: $RTSP_URL"
            
            # Store the stream details for display
            echo "$CARD_NUM|$CARD_ID|$USB_INFO|$RTSP_URL|$DEVICE_UUID|$STREAM_NAME" >> "$TEMP_FILE"
            
            # Start stream with device-specific config if available
            if start_device_stream "$CARD_NUM" "$CARD_ID" "$USB_INFO" "$RTSP_URL" "$DEVICE_UUID" "$STREAM_NAME"; then
                STREAMS_CREATED=$((STREAMS_CREATED + 1))
            fi
            
            # Small delay to stagger the starts
            sleep 0.5
        else
            log "INFO" "Skipping card $CARD_NUM [$CARD_ID] - no capture device found"
        fi
    fi
done <<< "$SOUND_CARDS"

# Create or update the device map file
if [ "$STREAMS_CREATED" -gt 0 ]; then
    # Create the device map file if it doesn't exist
    if [ ! -f "$DEVICE_MAP_FILE" ]; then
        log "INFO" "Creating device map file: $DEVICE_MAP_FILE"
        mkdir -p "$(dirname "$DEVICE_MAP_FILE")" 2>/dev/null
        cat > "$DEVICE_MAP_FILE" << EOF
# Audio Device Map - Edit this file to give devices persistent, friendly names
# Format: DEVICE_UUID=friendly_name
# Do not change the DEVICE_UUID values as they are used for consistent identification

EOF
        
        # Add initial entries for detected devices
        if [ -f "$TEMP_FILE" ]; then
            while read -r line; do
                IFS='|' read -r card_num card_id usb_info rtsp_url device_uuid stream_name <<< "$line"
                # Use sanitized card ID as the default name
                sanitized=$(echo "$card_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
                echo "$device_uuid=$sanitized" >> "$DEVICE_MAP_FILE"
            done < "$TEMP_FILE"
        fi
        
        log "INFO" "Created device map file: $DEVICE_MAP_FILE"
    else
        # Update existing map file with any new devices
        if [ -f "$TEMP_FILE" ]; then
            while read -r line; do
                IFS='|' read -r card_num card_id usb_info rtsp_url device_uuid stream_name <<< "$line"
                # Check if this UUID is already in the file
                if ! grep -q "^$device_uuid=" "$DEVICE_MAP_FILE"; then
                    # Add a sanitized default name
                    sanitized=$(echo "$card_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
                    echo "$device_uuid=$sanitized" >> "$DEVICE_MAP_FILE"
                    log "INFO" "Added new device to map: $device_uuid=$sanitized"
                fi
            done < "$TEMP_FILE"
        fi
    fi
fi

# Verify that streams are actually running
ACTUAL_STREAMS=$(pgrep -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" | wc -l)
if [ "$ACTUAL_STREAMS" -gt 0 ]; then
    STREAMS_CREATED=$ACTUAL_STREAMS
    log "INFO" "Verified $STREAMS_CREATED running ffmpeg RTSP streams"
else
    STREAMS_CREATED=0
    log "WARNING" "No running RTSP streams detected"
fi

# Check if any streams were created
if [ -f "$TEMP_FILE" ] && [ "$STREAMS_CREATED" -gt 0 ]; then
    echo ""
    echo "================================================================="
    echo "                  ACTIVE AUDIO RTSP STREAMS                      "
    echo "================================================================="
    printf "%-4s | %-15s | %-30s | %s\n" "Card" "Card ID" "USB Device" "RTSP URL"
    echo "-----------------------------------------------------------------"
    
    # Print a formatted table of the streams
    while IFS="|" read -r card_num card_id usb_info rtsp_url device_uuid stream_name; do
        # Truncate long fields for better display
        if [ ${#card_id} -gt 15 ]; then
            card_id="${card_id:0:12}..."
        fi
        if [ ${#usb_info} -gt 30 ]; then
            usb_info="${usb_info:0:27}..."
        fi
        printf "%-4s | %-15s | %-30s | %s\n" "$card_num" "$card_id" "$usb_info" "$rtsp_url"
    done < "$TEMP_FILE"
    
    echo "================================================================="
    echo ""
    
    # Get the IP address of the machine for external access
    IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    if [ -n "$IP_ADDR" ] && [ "$IP_ADDR" != "localhost" ]; then
        echo "To access streams from other devices, replace 'localhost' with '$IP_ADDR'"
        echo ""
    fi
    
    echo "To customize stream names, edit: $DEVICE_MAP_FILE"
    echo "To configure per-device settings, edit files in: $DEVICE_CONFIG_DIR/"
    echo "To blacklist devices, edit: $DEVICE_BLACKLIST_FILE"
    echo ""
    
    log "INFO" "Successfully started $STREAMS_CREATED audio streams"
else
    log "WARNING" "No audio streams were created. Check if you have audio capture devices connected."
    # Write empty PID file to indicate we're running but no streams are active
    touch "${TEMP_FILE}.pids"
fi

# Write success marker for systemd
atomic_write "${RUNTIME_DIR}/startmic_success" "STARTED"

# Function to monitor and restart streams if needed
monitor_streams() {
    log "INFO" "Starting monitor loop for child processes..."
    log "INFO" "Using RTSP port: $RTSP_PORT"
    
    # Initialize counters
    local restart_attempts=0
    local last_check_time=0
    local current_time=0
    local status_interval=300  # Log status every 5 minutes
    local last_status_time=0
    
    # Record start time
    local service_start_time=$(date +%s)
    atomic_write "${STATE_DIR}/service_start_time" "$service_start_time"
    
    # Create monitor state directory
    mkdir -p "${STATE_DIR}/monitoring" 2>/dev/null
    
    # Monitor loop
    while true; do
        current_time=$(date +%s)
        
        # Periodic status logging
        if [ $((current_time - last_status_time)) -ge "$status_interval" ]; then
            local uptime=$((current_time - service_start_time))
            local uptime_hours=$((uptime / 3600))
            local uptime_minutes=$(( (uptime % 3600) / 60 ))
            
            log "INFO" "Service status: Running for ${uptime_hours}h ${uptime_minutes}m, monitoring $STREAMS_CREATED streams"
            last_status_time=$current_time
            
            # Log resource usage if available
            if command -v free > /dev/null 2>&1; then
                memory_usage=$(free | grep Mem | awk '{print int($3/$2 * 100)}')
                log "INFO" "System memory usage: ${memory_usage}%"
            fi
            
            if [ -f "/proc/loadavg" ]; then
                load_avg=$(cat /proc/loadavg | cut -d' ' -f1)
                log "INFO" "System load average: $load_avg"
            fi
        fi
        
        # Only check streams at specified interval
        if [ $((current_time - last_check_time)) -ge "$STREAM_CHECK_INTERVAL" ]; then
            last_check_time=$current_time
            
            # Check if any ffmpeg processes are still running
            local running_processes=$(pgrep -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" | wc -l)
            
            if [ "$running_processes" -eq 0 ] && [ "$STREAMS_CREATED" -gt 0 ]; then
                log "WARNING" "No ffmpeg RTSP processes found. Attempting to restart streams..."
                
                # Check if RTSP server is accessible
                if ! check_mediamtx; then
                    log "ERROR" "MediaMTX is not accessible on port $RTSP_PORT"
                    
                    # Try to restart MediaMTX
                    log "INFO" "Attempting to restart MediaMTX"
                    if command -v systemctl > /dev/null 2>&1 && systemctl list-unit-files | grep -q mediamtx.service; then
                        systemctl restart mediamtx.service
                        sleep 3
                    else
                        # Try direct start if systemd not available
                        start_mediamtx
                    fi
                    
                    # Check again after restart attempt
                    if ! check_mediamtx; then
                        log "ERROR" "MediaMTX is still not accessible after restart attempt"
                    fi
                fi
                
                # Increment restart attempts
                restart_attempts=$((restart_attempts + 1))
                
                # Check if we've hit the maximum number of restart attempts
                if [ "$restart_attempts" -ge "$MAX_RESTART_ATTEMPTS" ]; then
                    log "ERROR" "Maximum restart attempts ($MAX_RESTART_ATTEMPTS) reached. Exiting monitor..."
                    cleanup 1 "Maximum restart attempts reached"
                fi
                
                # Sleep to avoid rapid restart cycles
                log "INFO" "Waiting ${RESTART_DELAY}s before restart attempt ${restart_attempts}/${MAX_RESTART_ATTEMPTS}..."
                sleep "$RESTART_DELAY"
                
                # Exit for systemd restart (more reliable than trying to restart ourselves)
                log "INFO" "Exiting for service restart"
                cleanup 1 "Exiting for service restart due to missing streams"
            else
                # Check if we have the expected number of streams
                if [ "$running_processes" -lt "$STREAMS_CREATED" ]; then
                    log "WARNING" "Found $running_processes running streams, expected $STREAMS_CREATED"
                    # We might want to implement per-stream restart here in the future
                fi  # Fixed: Changed } to fi in monitor_streams function
                
                if [ "$running_processes" -gt "$STREAMS_CREATED" ]; then
                    log "WARNING" "Found $running_processes running streams, but only expected $STREAMS_CREATED"
                    # This might indicate duplicate processes or external ffmpeg instances
                fi
                
                # Reset restart attempts counter if streams are running
                if [ "$restart_attempts" -gt 0 ] && [ "$running_processes" -gt 0 ]; then
                    log "INFO" "Streams appear to be running again. Resetting restart counter."
                    restart_attempts=0
                fi
            fi
        fi
        
        # Sleep to avoid high CPU usage
        sleep 5
    done
}

# If this script is used as a systemd service, we need to keep it running
# Detect if running under systemd and set appropriate behavior
if [ -d "/run/systemd/system" ]; then
    log "INFO" "Running as a systemd service"
    
    # Monitor and restart streams if needed
    monitor_streams
else
    # If running as a regular script
    log "INFO" "Press Ctrl+C to stop all streams and exit"
    
    # Keep script running to maintain the background processes
    wait
fi

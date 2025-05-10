#!/bin/bash
# Enhanced Audio RTSP Streaming Script
# Version: 4.0.0
# Date: 2025-05-10
# Description: Production-grade script for streaming audio from capture devices to RTSP
#              With support for per-device configuration

# Global configuration variables - overridden by config file if present
MEDIAMTX_PATH="/usr/local/mediamtx/mediamtx"
RTSP_PORT="18554"
AUDIO_BITRATE="192k"
AUDIO_CODEC="libmp3lame"
AUDIO_CHANNELS="1"
AUDIO_SAMPLE_RATE="44100"
RUNTIME_DIR="/run/audio-rtsp"
TEMP_DIR="${RUNTIME_DIR}/tmp"
TEMP_FILE="${TEMP_DIR}/stream_details.$$"
PID_FILE="${RUNTIME_DIR}/startmic.pid"
CONFIG_DIR="/etc/audio-rtsp"
DEVICE_CONFIG_DIR="${CONFIG_DIR}/devices"
LOG_DIR="/var/log/audio-rtsp"
DEVICE_MAP_FILE="${CONFIG_DIR}/device_map.conf"
DEVICE_BLACKLIST_FILE="${CONFIG_DIR}/device_blacklist.conf"
CONFIG_FILE="${CONFIG_DIR}/config"
FFMPEG_LOG_LEVEL="error"
FFMPEG_ADDITIONAL_OPTS=""
RESTART_DELAY=10
MAX_RESTART_ATTEMPTS=5
STREAM_CHECK_INTERVAL=30
LOG_LEVEL="info"  # Valid values: debug, info, warning, error

# Create directories
mkdir -p "$RUNTIME_DIR" "$TEMP_DIR" "$CONFIG_DIR" "$DEVICE_CONFIG_DIR" "$LOG_DIR" 2>/dev/null || {
    # Fallback to /tmp if we can't create the primary directories
    RUNTIME_DIR="/tmp/audio-rtsp"
    TEMP_DIR="${RUNTIME_DIR}/tmp"
    mkdir -p "$RUNTIME_DIR" "$TEMP_DIR" 2>/dev/null
    TEMP_FILE="${TEMP_DIR}/stream_details.$$"
    PID_FILE="${RUNTIME_DIR}/startmic.pid"
}

# Initialize log
LOG_FILE="${LOG_DIR}/audio-streams.log"
echo "----------------------------------------" >> "$LOG_FILE"
echo "Service started at $(date)" >> "$LOG_FILE"
echo "----------------------------------------" >> "$LOG_FILE"

# Basic logging function
log() {
    local level="$1"
    local message="$2"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG_FILE"
}

# Load configuration if available
if [ -f "$CONFIG_FILE" ]; then
    log "INFO" "Loading global configuration from $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Store our PID
echo $$ > "$PID_FILE"

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

# Check if MediaMTX is running
log "INFO" "Checking if MediaMTX is running..."
if pgrep -f mediamtx > /dev/null; then
    log "INFO" "MediaMTX is already running"
elif command -v systemctl > /dev/null 2>&1 && systemctl is-active --quiet mediamtx.service; then
    log "INFO" "MediaMTX is running via systemd"
else
    # Try to start MediaMTX
    if [ -x "$MEDIAMTX_PATH" ]; then
        log "INFO" "Starting MediaMTX from $MEDIAMTX_PATH..."
        "$MEDIAMTX_PATH" > "${LOG_DIR}/mediamtx.log" 2>&1 &
        log "INFO" "Started MediaMTX with PID: $!"
        sleep 3  # Give it time to initialize
    else
        log "ERROR" "MediaMTX executable not found or not executable: $MEDIAMTX_PATH"
    fi
fi

# Check if RTSP server is accessible
if command -v nc > /dev/null 2>&1 && nc -z localhost "$RTSP_PORT" 2>/dev/null; then
    log "INFO" "RTSP server is accessible on port $RTSP_PORT"
else
    log "WARNING" "RTSP server may not be accessible on port $RTSP_PORT"
    # Continue anyway - it might still work
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

# Function to test if ffmpeg can capture from a device
test_device_capture() {
    local card_id="$1"
    
    log "INFO" "Testing capture from card: $card_id"
    
    # Run ffmpeg for a very short duration to test with plughw
    if timeout 3 ffmpeg -nostdin -f alsa -ac "$AUDIO_CHANNELS" -i "plughw:CARD=$card_id,DEV=0" \
         -t 0.1 -f null - > /dev/null 2>&1; then
        log "INFO" "Successfully captured audio from card: $card_id"
        return 0
    else
        log "WARNING" "Failed to capture audio with plughw, trying alternative method..."
        
        # Try with hw: prefix instead
        if timeout 3 ffmpeg -nostdin -f alsa -ac "$AUDIO_CHANNELS" -i "hw:CARD=$card_id,DEV=0" \
             -t 0.1 -f null - > /dev/null 2>&1; then
            log "INFO" "Successfully captured audio using hw: device reference"
            return 0
        else
            log "ERROR" "Failed to capture audio from card: $card_id"
            return 1
        fi
    fi
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
        mapped_name=$(grep "^$device_uuid=" "$DEVICE_MAP_FILE" 2>/dev/null | cut -d= -f2)
        if [ -n "$mapped_name" ]; then
            echo "$mapped_name"
            return
        fi
    fi
    
    # No mapping found, use sanitized card_id
    echo "$card_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g'
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
    
    # Start ffmpeg with the configured settings
    ffmpeg -nostdin -hide_banner -loglevel "$FFMPEG_LOG_LEVEL" \
          -f alsa -ac "$AUDIO_CHANNELS" -sample_rate "$AUDIO_SAMPLE_RATE" \
          -i "plughw:CARD=$card_id,DEV=0" \
          -acodec "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE" -ac "$AUDIO_CHANNELS" \
          -content_type 'audio/mpeg' $FFMPEG_ADDITIONAL_OPTS \
          -f rtsp -rtsp_transport tcp "$rtsp_url" > "$stream_log" 2>&1 &
    
    # Save the PID
    local ffmpeg_pid=$!
    echo $ffmpeg_pid >> "${TEMP_FILE}.pids"
    
    # Create example device config if it doesn't exist (only do this the first time)
    if [ "$using_device_config" = false ] && [ ! -f "$device_config" ]; then
        log "INFO" "Creating example device config for $stream_name"
        mkdir -p "$DEVICE_CONFIG_DIR" 2>/dev/null
        cat > "$device_config.example" << EOF
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
}

# Get list of sound cards
log "INFO" "Detecting sound cards with capture capabilities..."
SOUND_CARDS=$(cat /proc/asound/cards)
if [ -z "$SOUND_CARDS" ]; then
    log "ERROR" "Cannot access sound card information"
    echo "STARTED" > "${RUNTIME_DIR}/startmic_success"
    exit 0  # Exit gracefully for systemd
fi

# Initialize tracking
> "$TEMP_FILE"
> "${TEMP_FILE}.pids"
STREAMS_CREATED=0

# Parse sound cards and start ffmpeg for each one with capture capability
while read -r line; do
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]*\[([^]]+)\][[:space:]]*:[[:space:]]*(.*) ]]; then
        CARD_NUM=${BASH_REMATCH[1]}
        CARD_ID=${BASH_REMATCH[2]}
        CARD_DESC=${BASH_REMATCH[3]}
        
        # Remove leading/trailing whitespace from card ID
        CARD_ID=$(echo "$CARD_ID" | tr -d '[:space:]')
        
        log "DEBUG" "Found sound card $CARD_NUM: $CARD_ID - $CARD_DESC"
        
        # Check if this device should be excluded
        EXCLUDED=0
        for excluded in "${EXCLUDED_DEVICES[@]}"; do
            if [ "$CARD_ID" = "$excluded" ]; then
                log "WARNING" "Skipping excluded device: $CARD_ID"
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
            start_device_stream "$CARD_NUM" "$CARD_ID" "$USB_INFO" "$RTSP_URL" "$DEVICE_UUID" "$STREAM_NAME"
            
            STREAMS_CREATED=$((STREAMS_CREATED + 1))
            
            # Small delay to stagger the starts
            sleep 0.5
        else
            log "WARNING" "Skipping card $CARD_NUM [$CARD_ID] - no capture device found"
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

# Count actual running ffmpeg processes to be sure
ACTUAL_STREAMS=$(pgrep -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" | wc -l)
if [ "$ACTUAL_STREAMS" -gt 0 ]; then
    STREAMS_CREATED=$ACTUAL_STREAMS
    log "INFO" "Found $STREAMS_CREATED running ffmpeg RTSP streams"
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
echo "STARTED" > "${RUNTIME_DIR}/startmic_success"

# Function to monitor and restart streams if needed
monitor_streams() {
    log "INFO" "Starting monitor loop for child processes..."
    log "INFO" "Using RTSP port: $RTSP_PORT"
    
    # Keep the script running - this is crucial for systemd
    restart_attempts=0
    
    while true; do
        # Check if any ffmpeg processes are still running
        if ! pgrep -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" > /dev/null; then
            log "WARNING" "No ffmpeg RTSP processes found. Attempting to restart streams..."
            
            # Check if RTSP server is accessible
            if command -v nc > /dev/null 2>&1 && ! nc -z localhost "$RTSP_PORT" 2>/dev/null; then
                log "ERROR" "RTSP server is not accessible on port $RTSP_PORT"
                
                # Try to start MediaMTX
                log "INFO" "Attempting to start MediaMTX"
                if command -v systemctl > /dev/null 2>&1 && systemctl list-unit-files | grep -q mediamtx.service; then
                    systemctl start mediamtx.service
                    sleep 3
                else
                    "$MEDIAMTX_PATH" > "${LOG_DIR}/mediamtx.log" 2>&1 &
                    sleep 3
                fi
            fi
            
            # Increment restart attempts
            restart_attempts=$((restart_attempts + 1))
            
            # Check if we've hit the maximum number of restart attempts
            if [ "$restart_attempts" -ge "$MAX_RESTART_ATTEMPTS" ]; then
                log "ERROR" "Maximum restart attempts ($MAX_RESTART_ATTEMPTS) reached. Exiting..."
                exit 1
            fi
            
            # Sleep to avoid rapid restart cycles
            log "INFO" "Waiting ${RESTART_DELAY}s before restart attempt ${restart_attempts}/${MAX_RESTART_ATTEMPTS}..."
            sleep "$RESTART_DELAY"
            
            # Exit so systemd can restart the service
            exit 1
        else
            # Reset restart attempts counter if streams are running
            if [ "$restart_attempts" -gt 0 ]; then
                log "INFO" "Streams appear to be running again. Resetting restart counter."
                restart_attempts=0
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

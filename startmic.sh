#!/bin/bash

# startmic.sh: Universal audio capture to RTSP streaming script
# Version: 1.2.0
# Date: 2025-05-06

# Exit on error
set -e

# Configuration variables
MEDIAMTX_PATH="/usr/local/mediamtx/mediamtx"
RTSP_PORT="18554"
AUDIO_BITRATE="192k"
AUDIO_CODEC="libmp3lame"
AUDIO_CHANNELS="1"
# Use runtime directory for temp files - works better with systemd
RUNTIME_DIR="/run/audio-rtsp"
TEMP_FILE="${RUNTIME_DIR}/stream_details.$$"
LOCK_FILE="${RUNTIME_DIR}/startmic.lock"
PID_FILE="${RUNTIME_DIR}/startmic.pid"
CONFIG_DIR="/etc/audio-rtsp"
DEVICE_MAP_FILE="${CONFIG_DIR}/device_map.conf"

# Create runtime directory if it doesn't exist
mkdir -p "$RUNTIME_DIR" 2>/dev/null || {
    # If mkdir fails, try a fallback to /tmp
    RUNTIME_DIR="/tmp/audio-rtsp"
    mkdir -p "$RUNTIME_DIR" 2>/dev/null
    TEMP_FILE="${RUNTIME_DIR}/stream_details.$$"
    LOCK_FILE="${RUNTIME_DIR}/startmic.lock"
    PID_FILE="${RUNTIME_DIR}/startmic.pid"
}

# Create config directory if it doesn't exist
mkdir -p "$CONFIG_DIR" 2>/dev/null || {
    echo "WARNING: Could not create config directory $CONFIG_DIR. Using $RUNTIME_DIR instead."
    CONFIG_DIR="$RUNTIME_DIR"
    DEVICE_MAP_FILE="${CONFIG_DIR}/device_map.conf"
}

# Store our PID
echo $$ > "$PID_FILE"

# Create lock file to prevent multiple instances
if ! ( set -o noclobber; echo "$$" > "$LOCK_FILE" ) 2>/dev/null; then
    # Check if the process holding the lock is still running
    OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "0")
    if [[ -n "$OLD_PID" && "$OLD_PID" != "0" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "ERROR: Another instance is already running (PID: $OLD_PID)"
        exit 1
    else
        # Lock exists but process doesn't, remove stale lock
        echo "WARNING: Removing stale lock file"
        rm -f "$LOCK_FILE"
        echo "$$" > "$LOCK_FILE"
    fi
fi

# Function: Clean up resources on exit
cleanup() {
    echo "Cleaning up..."
    # Remove temporary files
    rm -f "$TEMP_FILE" "${TEMP_FILE}.pids"
    
    # Remove lock file if it's ours
    if [[ -f "$LOCK_FILE" && "$(cat "$LOCK_FILE" 2>/dev/null)" == "$$" ]]; then
        rm -f "$LOCK_FILE"
    fi
    
    # Remove PID file
    rm -f "$PID_FILE"
}

# Function: Handle signals
handle_signal() {
    echo "Received termination signal. Stopping streams and exiting..."
    
    # Stop ffmpeg processes started by this script
    if [[ -f "${TEMP_FILE}.pids" ]]; then
        while read -r pid; do
            if kill -0 "$pid" 2>/dev/null; then
                echo "Stopping ffmpeg process: $pid"
                kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null
            fi
        done < "${TEMP_FILE}.pids"
    else
        # Fallback: try to stop relevant ffmpeg processes
        pkill -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" 2>/dev/null || true
    fi
    
    cleanup
    exit 0
}

# Set up signal handlers
trap 'handle_signal' INT TERM HUP
trap 'cleanup' EXIT

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check for required commands
for cmd in ffmpeg arecord pkill grep sed tr xargs hostname; do
    if ! command_exists "$cmd"; then
        echo "ERROR: Required command not found: $cmd"
        cleanup
        exit 1
    fi
done

# Optional: Check for netcat, but don't fail if not found
NC_CMD="nc"
if ! command_exists "$NC_CMD"; then
    if command_exists "netcat"; then
        NC_CMD="netcat"
    else
        echo "WARNING: Neither 'nc' nor 'netcat' found, will use sleep for MediaMTX initialization"
        NC_CMD=""
    fi
fi

# Function to wait for MediaMTX to initialize
wait_for_mediamtx() {
    local timeout=10
    local start_time=$(date +%s)
    echo "Waiting for MediaMTX to initialize (max ${timeout}s)..."
    
    if [[ -n "$NC_CMD" ]]; then
        # Use netcat if available
        while [[ $(($(date +%s) - start_time)) -lt $timeout ]]; do
            if $NC_CMD -z localhost "$RTSP_PORT" 2>/dev/null; then
                echo "MediaMTX is ready"
                return 0
            fi
            sleep 0.5
        done
    else
        # Fall back to sleep if netcat is not available
        sleep 3
        return 0
    fi
    
    echo "WARNING: MediaMTX initialization check timed out, continuing anyway"
    return 0  # Continue even if check fails for robustness
}

echo "Starting MediaMTX RTSP server..."
# Check if MediaMTX is already running
if pgrep mediamtx > /dev/null; then
    echo "MediaMTX is already running."
else
    # Check if MediaMTX executable exists and is executable
    if [[ ! -x "$MEDIAMTX_PATH" ]]; then
        echo "ERROR: MediaMTX executable not found or not executable: $MEDIAMTX_PATH"
        if [[ -f "$MEDIAMTX_PATH" ]]; then
            # File exists but not executable
            echo "Attempting to make it executable..."
            chmod +x "$MEDIAMTX_PATH" 2>/dev/null || echo "Failed to make executable, check permissions"
        fi
        cleanup
        exit 1
    fi
    
    # Start MediaMTX in the background
    "$MEDIAMTX_PATH" &
    
    # Wait for MediaMTX to initialize
    wait_for_mediamtx
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

# Function to create a consistent unique identifier for a device
get_device_uuid() {
    local card_id="$1"
    local usb_info="$2"
    
    # For USB devices, use device-specific info to create a stable identifier
    if [[ -n "$usb_info" ]]; then
        # Extract vendor/product information if possible
        local vendor_product
        if [[ "$usb_info" =~ ([A-Za-z0-9]+:[A-Za-z0-9]+) ]]; then
            vendor_product="${BASH_REMATCH[1]}"
            echo "${card_id}_${vendor_product}" | tr -d ' '
        else
            # Fall back to a hash of the full USB info for uniqueness
            local hash
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
    if [[ -f "$DEVICE_MAP_FILE" ]]; then
        local mapped_name
        mapped_name=$(grep "^$device_uuid=" "$DEVICE_MAP_FILE" 2>/dev/null | cut -d= -f2)
        if [[ -n "$mapped_name" ]]; then
            echo "$mapped_name"
            return
        fi
    fi
    
    # No mapping found, use sanitized card_id
    local sanitized
    sanitized=$(echo "$card_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
    echo "$sanitized"
}

# Kill any existing ffmpeg streams
echo "Stopping any existing ffmpeg streams..."
pkill -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" 2>/dev/null || true
sleep 1

# Get list of sound cards
echo "Detecting sound cards with capture capabilities..."
if ! SOUND_CARDS=$(cat /proc/asound/cards); then
    echo "ERROR: Cannot access sound card information"
    cleanup
    exit 1
fi

# Define excluded devices
EXCLUDED_DEVICES=("bcm2835_headpho" "vc4-hdmi" "HDMI")

# Create an array to store stream details that will be preserved when we exit the loop
declare -a STREAM_DETAILS_ARRAY

# Store device UUIDs for the device map
declare -a DEVICE_UUIDS

# Parse sound cards and start ffmpeg for each one with capture capability
while read -r line; do
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]*\[([^]]+)\][[:space:]]*:[[:space:]]*(.*) ]]; then
        CARD_NUM=${BASH_REMATCH[1]}
        CARD_ID=${BASH_REMATCH[2]}
        CARD_DESC=${BASH_REMATCH[3]}
        
        # Remove leading/trailing whitespace from card ID
        CARD_ID=$(echo "$CARD_ID" | xargs)
        
        # Extract USB device info if available
        USB_INFO=""
        if [[ "$CARD_DESC" =~ USB-Audio ]]; then
            USB_INFO=$(echo "$CARD_DESC" | sed -n 's/.*USB-Audio - \(.*\)/\1/p')
        fi
        
        # Check if this device should be excluded
        SHOULD_EXCLUDE=0
        for excluded in "${EXCLUDED_DEVICES[@]}"; do
            if [[ "$CARD_ID" == "$excluded" ]]; then
                echo "Skipping excluded device: $CARD_ID"
                SHOULD_EXCLUDE=1
                break
            fi
        done
        
        if [[ $SHOULD_EXCLUDE -eq 1 ]]; then
            continue
        fi
        
        # Check if this card has capture capabilities
        if has_capture_device "$CARD_NUM"; then
            # Test if we can open the device - but don't fail if it doesn't work
            # Just log a warning and continue
            if ! timeout 3 ffmpeg -nostdin -f alsa -i "plughw:CARD=$CARD_ID,DEV=0" \
                     -t 0.1 -f null - > /dev/null 2>&1; then
                echo "WARNING: Cannot test capture from card $CARD_NUM [$CARD_ID] - trying anyway"
            fi
            
            # Generate a stable, unique identifier for this device
            DEVICE_UUID=$(get_device_uuid "$CARD_ID" "$USB_INFO")
            DEVICE_UUIDS+=("$DEVICE_UUID")
            
            # Get a stable, human-readable stream name
            STREAM_NAME=$(get_stream_name "$CARD_ID" "$DEVICE_UUID")
            RTSP_URL="rtsp://localhost:$RTSP_PORT/$STREAM_NAME"
            
            echo "Starting RTSP stream for card $CARD_NUM [$CARD_ID]: $RTSP_URL"
            
            # Store the stream details for display later (outside the loop)
            STREAM_DETAILS_ARRAY+=("$CARD_NUM|$CARD_ID|$USB_INFO|$RTSP_URL|$DEVICE_UUID")
            
            # Start ffmpeg with the appropriate sound card
            # Redirect output to /dev/null to avoid cluttering the console
            ffmpeg -nostdin -f alsa -ac "$AUDIO_CHANNELS" -i "plughw:CARD=$CARD_ID,DEV=0" \
                  -acodec "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE" -ac "$AUDIO_CHANNELS" \
                  -content_type 'audio/mpeg' -f rtsp "$RTSP_URL" -rtsp_transport tcp > /dev/null 2>&1 &
            
            # Save the PID for later cleanup
            echo $! >> "${TEMP_FILE}.pids"
            
            # Small delay to stagger the ffmpeg starts
            sleep 0.5
        else
            echo "Skipping card $CARD_NUM [$CARD_ID] - no capture device found"
        fi
    fi
done <<< "$SOUND_CARDS"

# Check if any streams were created by counting the lines in the PID file
STREAMS_CREATED=0
if [[ -f "${TEMP_FILE}.pids" ]]; then
    STREAMS_CREATED=$(wc -l < "${TEMP_FILE}.pids")
fi

# Create or update the device map file with detected devices
if [[ "$STREAMS_CREATED" -gt 0 ]]; then
    # Create the device map file if it doesn't exist
    if [[ ! -f "$DEVICE_MAP_FILE" ]]; then
        echo "# Audio Device Map - Edit this file to give devices persistent, friendly names" > "$DEVICE_MAP_FILE"
        echo "# Format: DEVICE_UUID=friendly_name" >> "$DEVICE_MAP_FILE"
        echo "# Do not change the DEVICE_UUID values as they are used for consistent identification" >> "$DEVICE_MAP_FILE"
        echo "" >> "$DEVICE_MAP_FILE"
        
        # Add initial entries for detected devices
        for detail in "${STREAM_DETAILS_ARRAY[@]}"; do
            IFS='|' read -r card_num card_id usb_info rtsp_url device_uuid <<< "$detail"
            # Check if this UUID is already in the file
            if ! grep -q "^$device_uuid=" "$DEVICE_MAP_FILE" 2>/dev/null; then
                # Add a sanitized default name
                sanitized=$(echo "$card_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
                echo "$device_uuid=$sanitized" >> "$DEVICE_MAP_FILE"
            fi
        done
        
        echo "Created device map file: $DEVICE_MAP_FILE"
        echo "You can edit this file to give your audio devices persistent, friendly names."
    else
        # Update existing map file with any new devices
        for detail in "${STREAM_DETAILS_ARRAY[@]}"; do
            IFS='|' read -r card_num card_id usb_info rtsp_url device_uuid <<< "$detail"
            # Check if this UUID is already in the file
            if ! grep -q "^$device_uuid=" "$DEVICE_MAP_FILE" 2>/dev/null; then
                # Add a sanitized default name
                sanitized=$(echo "$card_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
                echo "$device_uuid=$sanitized" >> "$DEVICE_MAP_FILE"
                echo "Added new device to map file: $device_uuid=$sanitized"
            fi
        done
    fi
fi

# Write stream details to the temp file for display
for detail in "${STREAM_DETAILS_ARRAY[@]}"; do
    echo "$detail" >> "$TEMP_FILE"
done

# Check if any streams were created
if [[ -f "$TEMP_FILE" && "$STREAMS_CREATED" -gt 0 ]]; then
    echo ""
    echo "================================================================="
    echo "                  ACTIVE AUDIO RTSP STREAMS                      "
    echo "================================================================="
    printf "%-4s | %-15s | %-30s | %s | %s\n" "Card" "Card ID" "USB Device" "RTSP URL" "Device UUID"
    echo "-----------------------------------------------------------------"
    
    # Print a formatted table of the streams
    while IFS="|" read -r card_num card_id usb_info rtsp_url device_uuid; do
        printf "%-4s | %-15s | %-30s | %s | %s\n" "$card_num" "$card_id" "$usb_info" "$rtsp_url" "$device_uuid"
    done < "$TEMP_FILE"
    
    echo "================================================================="
    echo ""
    
    # Get the IP address of the machine for external access
    IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    if [[ -n "$IP_ADDR" && "$IP_ADDR" != "localhost" ]]; then
        echo "To access these streams from other devices on the network, replace"
        echo "'localhost' with '$IP_ADDR' in the RTSP URLs"
        echo ""
    fi
    
    echo "To customize stream names, edit: $DEVICE_MAP_FILE"
    echo "Changes will take effect the next time the service starts"
    echo ""
else
    echo "No audio streams were created. Check if you have audio capture devices connected."
    # Important: Don't exit with failure when running as a service if no audio devices are found
    # This allows the service to properly start even when no audio devices are connected
    # They can be added later without restarting the service
    
    # Write empty PID file to indicate we're running but no streams are active
    touch "${TEMP_FILE}.pids"
fi

# For systemd compatibility, this is crucial:
# Write a 'success' marker file that systemd can check
echo "STARTED" > "${RUNTIME_DIR}/startmic_success"

# If this script is used as a systemd service, we need to keep it running
# Detect if running under systemd and set appropriate behavior
if [[ -d "/run/systemd/system" ]]; then
    echo "Running as a systemd service"
    
    # For systemd, use a simple loop that regularly verifies ffmpeg processes
    while true; do
        # Check if ffmpeg processes are still running
        if [[ -f "${TEMP_FILE}.pids" ]]; then
            PROCESSES_RUNNING=0
            while read -r pid; do
                if kill -0 "$pid" 2>/dev/null; then
                    PROCESSES_RUNNING=$((PROCESSES_RUNNING + 1))
                fi
            done < "${TEMP_FILE}.pids"
            
            # If no processes are running, try to restart them
            if [[ "$PROCESSES_RUNNING" -eq 0 && "$STREAMS_CREATED" -gt 0 ]]; then
                echo "WARNING: All ffmpeg processes have stopped, consider restarting the service"
                # Don't exit - just keep monitoring
            fi
        fi
        
        # Sleep for 30 seconds before checking again
        sleep 30
    done
else
    # If running as a regular script or being sourced by another script
    if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
        echo "Running as a sourced script, returning control to parent"
        exit 0
    else
        # Keep script running to maintain the background processes
        echo "Press Ctrl+C to stop all streams and exit"
        wait
    fi
fi

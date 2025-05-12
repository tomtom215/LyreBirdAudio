#!/bin/bash
# Enhanced Audio RTSP Streaming Script
#
# Version: 6.2.0
# Date: 2025-05-14
# Description: Production-grade script for streaming audio from capture devices to RTSP
#              With improved device detection and robust permission handling
#
# Prerequisites:
# - Script must be installed with executable permissions (chmod 755)
# - Must be run as root or with appropriate permissions
# - Requires working directories to be writable
# - Requires ffmpeg and ALSA tools (arecord)
#
# Troubleshooting:
# - If service fails to start, check:
#   1. Permissions: sudo chmod +x /usr/local/bin/startmic.sh
#   2. Service errors: journalctl -u audio-rtsp -n 50
#   3. Run manually: sudo /usr/local/bin/startmic.sh
#   4. Check log files: /var/log/audio-rtsp/

# Exit on error (controlled)
set -o pipefail

# Self-healing permission check - fix permissions if needed
if [ ! -x "$0" ]; then
    echo "Warning: Script is not executable. Attempting to fix permissions..."
    chmod +x "$0" 2>/dev/null || {
        echo "ERROR: Could not set executable permission on $0"
        echo "Please run: chmod +x $0"
        exit 203  # Return specific systemd exec error code
    }
fi

# Global configuration variables 
MEDIAMTX_PATH="/usr/local/mediamtx/mediamtx"
RTSP_PORT="18554"
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

# Audio settings
AUDIO_BITRATE="192k"
AUDIO_CODEC="libmp3lame"
AUDIO_CHANNELS="1"
AUDIO_SAMPLE_RATE="44100"

# FFMPEG settings
FFMPEG_LOG_LEVEL="error"
FFMPEG_ADDITIONAL_OPTS=""

# Other settings
RESTART_DELAY=10
MAX_RESTART_ATTEMPTS=5
STREAM_CHECK_INTERVAL=30
LOG_LEVEL="info"  # Valid values: debug, info, warning, error
MAX_STREAMS=32    # Maximum number of streams to prevent resource exhaustion

# Privilege dropping settings
PRIVILEGE_DROP_USER="rtsp"
PRIVILEGE_DROP_CMD=""

# Create required directories with proper permissions
setup_directories() {
    local dirs=(
        "$RUNTIME_DIR"
        "$TEMP_DIR"
        "$LOG_DIR" 
        "$STATE_DIR"
        "$CONFIG_DIR"
        "$DEVICE_CONFIG_DIR"
        "${STATE_DIR}/streams"
    )
    
    for dir in "${dirs[@]}"; do
        if ! mkdir -p "$dir" 2>/dev/null; then
            echo "ERROR: Failed to create directory: $dir"
            # Try fallback for runtime directories
            if [[ "$dir" == "$RUNTIME_DIR"* ]]; then
                RUNTIME_DIR="/tmp/audio-rtsp"
                TEMP_DIR="${RUNTIME_DIR}/tmp"
                STATE_DIR="${RUNTIME_DIR}/state"
                echo "Attempting fallback to $RUNTIME_DIR"
                
                if ! mkdir -p "$RUNTIME_DIR" "$TEMP_DIR" "$STATE_DIR" 2>/dev/null; then
                    echo "FATAL: Cannot create temporary directories. Exiting."
                    exit 1
                fi
                break
            fi
        fi
        
        # Set correct permissions - world readable/executable but only owner writable
        chmod 755 "$dir" 2>/dev/null
    done
    
    # Create lock file directory
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null
}

setup_directories

# Define temporary files
TEMP_FILE="${TEMP_DIR}/stream_details.$$"
PIDS_FILE="${TEMP_DIR}/stream_pids.$$"
LOG_FILE="${LOG_DIR}/audio-streams.log"

# Initialize log file
initialize_log() {
    # Create log directory if it doesn't exist
    mkdir -p "$LOG_DIR" 2>/dev/null
    
    {
        echo "----------------------------------------"
        echo "Service started at $(date)"
        echo "PID: $$"
        echo "Version: 6.2.0"
        echo "----------------------------------------"
    } >> "$LOG_FILE"
}

initialize_log

# Advanced logging function with proper log levels
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="[$timestamp] [$level] $message"
    
    # Determine if this message should be logged based on LOG_LEVEL
    local should_log=0
    case "$LOG_LEVEL" in
        debug)
            should_log=1 ;;
        info)
            if [[ "$level" != "DEBUG" ]]; then should_log=1; fi ;;
        warning)
            if [[ "$level" != "DEBUG" && "$level" != "INFO" ]]; then should_log=1; fi ;;
        error)
            if [[ "$level" == "ERROR" || "$level" == "FATAL" ]]; then should_log=1; fi ;;
    esac
    
    if [[ $should_log -eq 1 ]]; then
        # Write to log file
        echo "$log_line" >> "$LOG_FILE"
        
        # Print to console for ERROR and FATAL logs
        if [[ "$level" == "ERROR" || "$level" == "FATAL" ]]; then
            echo "$log_line" >&2
        fi
    fi
}

# Function to ensure atomic writes to files
atomic_write() {
    local file="$1"
    local content="$2"
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$file")" 2>/dev/null
    
    # Write to temp file first then move atomically
    local temp_file="${file}.tmp.$$"
    echo "$content" > "$temp_file"
    mv -f "$temp_file" "$file" 2>/dev/null || {
        log "ERROR" "Failed to atomically write to $file"
        rm -f "$temp_file" 2>/dev/null
        return 1
    }
    
    return 0
}

# Clean integer function to safely handle numeric values
clean_integer() {
    local input="$1"
    local result
    
    # Remove non-digit characters
    result=$(echo "$input" | tr -cd '0-9')
    
    # Default to 0 if empty
    if [ -z "$result" ]; then
        echo "0"
    else
        echo "$result"
    fi
}

# Load configuration if available
if [ -f "$CONFIG_FILE" ]; then
    log "INFO" "Loading configuration from $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Function to check environment conditions and fix if possible
check_environment() {
    log "INFO" "Performing environment checks..."
    local status=0
    
    # Check if script is executable
    if [ ! -x "$0" ]; then
        log "ERROR" "Script is not executable. This may cause systemd startup issues."
        chmod +x "$0" 2>/dev/null || log "ERROR" "Failed to set executable permission on $0"
        status=1
    fi
    
    # Check directories
    for dir in "$RUNTIME_DIR" "$CONFIG_DIR" "$LOG_DIR" "$TEMP_DIR" "$STATE_DIR"; do
        if [ ! -d "$dir" ]; then
            log "WARNING" "Directory does not exist: $dir"
            mkdir -p "$dir" 2>/dev/null || {
                log "ERROR" "Failed to create directory: $dir"
                status=1
            }
        fi
        
        if [ ! -w "$dir" ]; then
            log "ERROR" "Directory is not writable: $dir"
            chmod 755 "$dir" 2>/dev/null || {
                log "ERROR" "Failed to set permissions on $dir"
                status=1
            }
        fi
    done
    
    # Check critical dependencies
    for cmd in ffmpeg arecord; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log "ERROR" "Required command not found: $cmd"
            status=1
        fi
    done
    
    # Check if MediaMTX is accessible
    if ! nc -z localhost "$RTSP_PORT" >/dev/null 2>&1; then
        log "WARNING" "MediaMTX not accessible on port $RTSP_PORT"
        
        # Check if MediaMTX service is running
        if command -v systemctl >/dev/null 2>&1; then
            if ! systemctl is-active --quiet mediamtx.service; then
                log "WARNING" "MediaMTX service is not running"
                log "INFO" "Attempting to start MediaMTX service..."
                systemctl start mediamtx.service 2>/dev/null || {
                    log "ERROR" "Failed to start MediaMTX service"
                    status=1
                }
            fi
        fi
    fi
    
    return $status
}

# Setup privilege dropping functionality
setup_privilege_dropping() {
    # Only attempt if running as root
    if [ "$(id -u)" -ne 0 ]; then
        log "INFO" "Not running as root, skipping privilege dropping setup"
        return 1
    fi
    
    log "INFO" "Setting up privilege dropping..."
    
    # Check if rtsp user exists
    if ! id -u "$PRIVILEGE_DROP_USER" >/dev/null 2>&1; then
        log "INFO" "Creating $PRIVILEGE_DROP_USER user for privilege separation"
        useradd -r -g audio -s /usr/sbin/nologin -d /nonexistent "$PRIVILEGE_DROP_USER" 2>/dev/null || {
            log "WARNING" "Could not create $PRIVILEGE_DROP_USER user"
            return 1
        }
    fi
    
    # Ensure proper permissions on runtime directories
    log "INFO" "Setting permissions for $PRIVILEGE_DROP_USER user"
    for dir in "$RUNTIME_DIR" "$TEMP_DIR" "$STATE_DIR"; do
        if [ -d "$dir" ]; then
            # Make directory and parents accessible
            chmod 755 "$dir" 2>/dev/null
        fi
    done
    
    # Ensure permissions on log directory
    if [ -d "$LOG_DIR" ]; then
        chmod 755 "$LOG_DIR" 2>/dev/null
        # Ensure rtsp user can write to the log directory
        chown root:"$PRIVILEGE_DROP_USER" "$LOG_DIR" 2>/dev/null
        chmod 775 "$LOG_DIR" 2>/dev/null
    fi
    
    # Set the privilege drop command based on available tools
    if command -v runuser >/dev/null 2>&1; then
        PRIVILEGE_DROP_CMD="runuser -u $PRIVILEGE_DROP_USER --"
        log "INFO" "Using runuser for privilege dropping"
    elif command -v su >/dev/null 2>&1; then
        PRIVILEGE_DROP_CMD="su $PRIVILEGE_DROP_USER -s /bin/bash -c"
        log "INFO" "Using su for privilege dropping"
    else
        log "WARNING" "No suitable command found for privilege dropping"
        return 1
    fi
    
    # Test the privilege dropping command
    if ! $PRIVILEGE_DROP_CMD "echo test" >/dev/null 2>&1; then
        log "WARNING" "Privilege dropping test failed, running as root"
        PRIVILEGE_DROP_CMD=""
        return 1
    fi
    
    # Success
    log "INFO" "Privilege dropping configured successfully"
    return 0
}

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

# Function to check if a sound card has a capture device
has_capture_device() {
    local card=$1
    if arecord -l 2>/dev/null | grep -q "card $card"; then
        return 0  # Has capture device
    else
        return 1  # No capture device
    fi
}

# Function to test if ffmpeg can capture from a device - with multiple retries
test_device_capture() {
    local card_id="$1"
    local max_retries=2
    local retry=0
    
    log "INFO" "Testing capture from card: $card_id"
    
    while [ $retry -le $max_retries ]; do
        # Try plughw first (safer and handles format conversion)
        if timeout 3 ffmpeg -nostdin -f alsa -ac "$AUDIO_CHANNELS" -i "plughw:CARD=$card_id,DEV=0" \
             -t 0.1 -f null - > /dev/null 2>&1; then
            log "INFO" "Successfully captured audio from card: $card_id using plughw"
            return 0
        fi
        
        # Try hw device directly
        if timeout 3 ffmpeg -nostdin -f alsa -ac "$AUDIO_CHANNELS" -i "hw:CARD=$card_id,DEV=0" \
             -t 0.1 -f null - > /dev/null 2>&1; then
            log "INFO" "Successfully captured audio from card: $card_id using hw"
            return 0
        fi
        
        # Try default device
        if timeout 3 ffmpeg -nostdin -f alsa -ac "$AUDIO_CHANNELS" -i "default:CARD=$card_id" \
             -t 0.1 -f null - > /dev/null 2>&1; then
            log "INFO" "Successfully captured audio from card: $card_id using default device"
            return 0
        fi
        
        retry=$((retry + 1))
        log "WARNING" "Retry $retry/$max_retries for device $card_id"
        sleep 1
    done
    
    log "WARNING" "Could not capture from card $card_id after $max_retries retries"
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
            local hash=$(echo "$usb_info" | md5sum | cut -c1-8)
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

# Advanced function to start a stream with proper privilege handling
start_stream() {
    local card_num="$1"
    local card_id="$2"
    local usb_info="$3"
    local device_uuid="$4"
    local stream_name="$5"
    local rtsp_url="rtsp://localhost:$RTSP_PORT/$stream_name"
    local stream_log="${LOG_DIR}/${stream_name}_ffmpeg.log"
    
    # Check for device-specific config
    local device_config="${DEVICE_CONFIG_DIR}/${stream_name}.conf"
    local using_device_config=false
    
    # Save global audio settings before potentially overriding them
    local global_audio_channels="$AUDIO_CHANNELS"
    local global_audio_sample_rate="$AUDIO_SAMPLE_RATE"
    local global_audio_bitrate="$AUDIO_BITRATE"
    local global_audio_codec="$AUDIO_CODEC"
    local global_ffmpeg_additional_opts="$FFMPEG_ADDITIONAL_OPTS"
    
    # Load device-specific config if available
    if [ -f "$device_config" ]; then
        log "INFO" "Loading device-specific config for $stream_name: $device_config"
        # shellcheck disable=SC1090
        source "$device_config"
        using_device_config=true
    else
        log "INFO" "No device-specific config found for $stream_name, using global settings"
    fi
    
    # Create fresh log file with proper permissions
    log "INFO" "Creating stream log file: $stream_log"
    > "$stream_log"
    # Make log file writable by rtsp user if needed
    if [ -n "$PRIVILEGE_DROP_CMD" ]; then
        chown root:"$PRIVILEGE_DROP_USER" "$stream_log" 2>/dev/null
        chmod 664 "$stream_log" 2>/dev/null
    fi
    
    log "INFO" "Starting stream: $rtsp_url"
    
    # Create the ffmpeg command line
    local ffmpeg_command="ffmpeg -nostdin -hide_banner -loglevel $FFMPEG_LOG_LEVEL \
        -f alsa -ac $AUDIO_CHANNELS -sample_rate $AUDIO_SAMPLE_RATE \
        -i plughw:CARD=$card_id,DEV=0 \
        -acodec $AUDIO_CODEC -b:a $AUDIO_BITRATE -ac $AUDIO_CHANNELS \
        -content_type 'audio/mpeg' $FFMPEG_ADDITIONAL_OPTS \
        -f rtsp -rtsp_transport tcp $rtsp_url"
    
    local pid
    
    if [ -n "$PRIVILEGE_DROP_CMD" ]; then
        # Using privilege dropping - run directly with the command
        # This avoids the need for temporary script files
        $PRIVILEGE_DROP_CMD "$ffmpeg_command > '$stream_log' 2>&1" &
        pid=$!
    else
        # Run as root
        eval "$ffmpeg_command > '$stream_log' 2>&1" &
        pid=$!
    fi
    
    # Verify process started
    if ! kill -0 "$pid" 2>/dev/null; then
        log "ERROR" "Failed to start stream process for $stream_name"
        
        # Restore global settings
        AUDIO_CHANNELS="$global_audio_channels"
        AUDIO_SAMPLE_RATE="$global_audio_sample_rate"
        AUDIO_BITRATE="$global_audio_bitrate"
        AUDIO_CODEC="$global_audio_codec"
        FFMPEG_ADDITIONAL_OPTS="$global_ffmpeg_additional_opts"
        
        return 1
    fi
    
    # Save the PID for tracking
    echo "$pid" >> "$PIDS_FILE"
    mkdir -p "${STATE_DIR}/streams" 2>/dev/null
    atomic_write "${STATE_DIR}/streams/${stream_name}.pid" "$pid"
    
    log "INFO" "Started stream for card $card_num ($card_id) with PID $pid"
    
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

# Clean up function for graceful exit
cleanup() {
    log "INFO" "Cleaning up..."
    
    # Kill all ffmpeg processes we started
    if [ -f "$PIDS_FILE" ]; then
        # First try SIGTERM
        while read -r pid; do
            pid=$(clean_integer "$pid")
            if [ -n "$pid" ] && [ "$pid" -gt 0 ]; then
                log "DEBUG" "Stopping process $pid with SIGTERM"
                kill -15 "$pid" 2>/dev/null || true
            fi
        done < "$PIDS_FILE"
        
        # Give processes time to terminate gracefully
        sleep 2
        
        # Then use SIGKILL for any still running
        while read -r pid; do
            pid=$(clean_integer "$pid")
            if [ -n "$pid" ] && [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then
                log "DEBUG" "Force killing process $pid with SIGKILL"
                kill -9 "$pid" 2>/dev/null || true
            fi
        done < "$PIDS_FILE"
    fi
    
    # Find any orphaned processes
    pkill -15 -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" 2>/dev/null || true
    sleep 1
    pkill -9 -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" 2>/dev/null || true
    
    # Remove temporary files
    rm -f "$PIDS_FILE" "$TEMP_FILE" 2>/dev/null
    
    log "INFO" "Cleanup completed, exiting"
    exit 0
}

# Set up trap for cleanup on exit
trap cleanup EXIT INT TERM

# Run environment checks
check_environment

# Set up privilege dropping if running as root
setup_privilege_dropping

# Kill any existing ffmpeg streams that might be running
log "INFO" "Stopping any existing ffmpeg streams..."
pkill -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" 2>/dev/null || true
sleep 1

# Initialize pids file
> "$PIDS_FILE"

# Get list of sound cards
log "INFO" "Detecting sound cards..."
SOUND_CARDS=$(cat /proc/asound/cards)
if [ -z "$SOUND_CARDS" ]; then
    log "ERROR" "No sound cards detected"
    # Write success marker for systemd even though no cards found
    atomic_write "${RUNTIME_DIR}/startmic_success" "STARTED"
    exit 0
fi

# Initialize streaming counter
STREAMS_CREATED=0

# Parse sound cards and create streams
while read -r line; do
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]*\[([^]]+)\][[:space:]]*:[[:space:]]*(.*) ]]; then
        CARD_NUM=${BASH_REMATCH[1]}
        CARD_ID=${BASH_REMATCH[2]}
        CARD_DESC=${BASH_REMATCH[3]}
        
        # Remove leading/trailing whitespace from card ID
        CARD_ID=$(echo "$CARD_ID" | tr -d '[:space:]')
        
        log "INFO" "Found sound card $CARD_NUM: $CARD_ID - $CARD_DESC"
        
        # Check if we've hit max streams limit
        if [ "$STREAMS_CREATED" -ge "$MAX_STREAMS" ]; then
            log "WARNING" "Maximum number of streams ($MAX_STREAMS) reached, skipping remaining devices"
            break
        fi
        
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
            
            log "INFO" "Creating stream for card $CARD_NUM [$CARD_ID]: $STREAM_NAME"
            
            # Store the stream details for display
            echo "$CARD_NUM|$CARD_ID|$USB_INFO|rtsp://localhost:$RTSP_PORT/$STREAM_NAME|$DEVICE_UUID|$STREAM_NAME" >> "$TEMP_FILE"
            
            # Start stream with device-specific config if available
            if start_stream "$CARD_NUM" "$CARD_ID" "$USB_INFO" "$DEVICE_UUID" "$STREAM_NAME"; then
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
if [ "$STREAMS_CREATED" -gt 0 ] && [ -f "$TEMP_FILE" ]; then
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
        while read -r line; do
            IFS='|' read -r card_num card_id usb_info rtsp_url device_uuid stream_name <<< "$line"
            # Use sanitized card ID as the default name
            sanitized=$(echo "$card_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
            echo "$device_uuid=$sanitized" >> "$DEVICE_MAP_FILE"
        done < "$TEMP_FILE"
        
        log "INFO" "Created device map file: $DEVICE_MAP_FILE"
    else
        # Update existing map file with any new devices
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

# Verify that streams are actually running
ACTUAL_STREAMS=$(pgrep -c -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" 2>/dev/null || echo "0")
ACTUAL_STREAMS=$(clean_integer "$ACTUAL_STREAMS")

if [ "$ACTUAL_STREAMS" -gt 0 ]; then
    STREAMS_CREATED=$ACTUAL_STREAMS
    log "INFO" "Verified $STREAMS_CREATED running ffmpeg RTSP streams"
else
    log "WARNING" "No running RTSP streams detected"
    STREAMS_CREATED=0
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
fi

# Write success marker for systemd
atomic_write "${RUNTIME_DIR}/startmic_success" "STARTED"

# Enhanced stream monitoring function with improved error handling
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
    
    # Keep the script running - critical for systemd
    while true; do
        # Get current time for checks
        current_time=$(date +%s)
        
        # Periodic status logging
        if [ $((current_time - last_status_time)) -ge "$status_interval" ]; then
            local uptime=$((current_time - service_start_time))
            local uptime_hours=$((uptime / 3600))
            local uptime_minutes=$(( (uptime % 3600) / 60 ))
            
            # Log resource usage if available
            if command -v free > /dev/null 2>&1; then
                local memory_usage=$(free | grep Mem | awk '{print int($3/$2 * 100)}')
                log "INFO" "Service status: Running for ${uptime_hours}h ${uptime_minutes}m, memory usage: ${memory_usage}%"
            else
                log "INFO" "Service status: Running for ${uptime_hours}h ${uptime_minutes}m"
            fi
            
            # Track active ffmpeg processes
            local running_processes=$(pgrep -c -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" 2>/dev/null || echo "0")
            running_processes=$(clean_integer "$running_processes")
            log "INFO" "Active ffmpeg RTSP processes: $running_processes"
            
            last_status_time=$current_time
        fi
        
        # Only check streams at specified interval
        if [ $((current_time - last_check_time)) -ge "$STREAM_CHECK_INTERVAL" ]; then
            last_check_time=$current_time
            
            # Check if any ffmpeg processes are still running
            local running_processes=$(pgrep -c -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" 2>/dev/null || echo "0")
            running_processes=$(clean_integer "$running_processes")
            
            if [ "$running_processes" -eq 0 ] && [ "$STREAMS_CREATED" -gt 0 ]; then
                # Increment restart attempts
                restart_attempts=$((restart_attempts + 1))
                
                log "WARNING" "No ffmpeg RTSP processes found. Attempt ${restart_attempts}/${MAX_RESTART_ATTEMPTS}"
                
                # Check RTSP server first
                if ! nc -z localhost $RTSP_PORT >/dev/null 2>&1; then
                    log "ERROR" "RTSP server is not accessible on port $RTSP_PORT"
                    
                    # Try to restart MediaMTX
                    log "INFO" "Attempting to restart MediaMTX"
                    if command -v systemctl > /dev/null 2>&1 && systemctl list-unit-files | grep -q mediamtx.service; then
                        systemctl restart mediamtx.service
                        sleep 5  # Give it time to start
                    fi
                fi
                
                # Check if max attempts reached
                if [ "$restart_attempts" -ge "$MAX_RESTART_ATTEMPTS" ]; then
                    log "ERROR" "Maximum restart attempts ($MAX_RESTART_ATTEMPTS) reached."
                    log "ERROR" "Exiting monitoring to allow systemd to handle service restart"
                    atomic_write "${STATE_DIR}/restart_failures" "$restart_attempts"
                    break
                fi
                
                # Sleep before next check
                sleep "$RESTART_DELAY"
            else
                # Reset restart counter if we have processes running
                if [ "$restart_attempts" -gt 0 ] && [ "$running_processes" -gt 0 ]; then
                    log "INFO" "Streams are now running. Resetting restart counter."
                    restart_attempts=0
                    atomic_write "${STATE_DIR}/restart_attempts" "0"
                fi
            fi
        fi
        
        # Sleep for a safe interval (5 seconds)
        sleep 5
    done
}

# If running as a systemd service, monitor streams
if [ -d "/run/systemd/system" ]; then
    log "INFO" "Running as a systemd service, monitoring streams"
    monitor_streams
else
    # If running as a regular script, just wait for termination
    log "INFO" "Press Ctrl+C to stop all streams and exit"
    # Wait for any background processes to exit 
    wait
fi

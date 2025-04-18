#!/bin/bash

# Exit on error
set -e

echo "Starting MediaMTX RTSP server..."
# Check if MediaMTX is already running
if pgrep mediamtx > /dev/null; then
    echo "MediaMTX is already running."
else
    # Start MediaMTX in the background
    /usr/local/mediamtx/mediamtx &
    echo "Waiting for MediaMTX to initialize..."
    sleep 3  # Allow MediaMTX time to start properly
fi

# Function to check if a sound card has a capture device
has_capture_device() {
    local card=$1
    if arecord -l | grep -q "card $card"; then
        return 0  # Has capture device
    else
        return 1  # No capture device
    fi
}

# Function to get a sanitized name for the RTSP stream
get_stream_name() {
    local card_name=$1
    # Remove spaces, special characters and convert to lowercase
    echo "$card_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g'
}

# Kill any existing ffmpeg processes
echo "Stopping any existing ffmpeg streams..."
pkill -f ffmpeg || true
sleep 1

# Get list of sound cards
echo "Detecting sound cards with capture capabilities..."
SOUND_CARDS=$(cat /proc/asound/cards)

# Create an associative array to store device details
declare -A STREAM_DETAILS

# Parse sound cards and start ffmpeg for each one with capture capability
echo "$SOUND_CARDS" | while read -r line; do
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
        
        # Exclude known system sound devices that shouldn't be used for capture
        if [[ "$CARD_ID" =~ ^(bcm2835_headpho|vc4-hdmi|HDMI)$ ]]; then
            echo "Skipping system audio device: $CARD_ID"
            continue
        fi
        
        # Check if this card has capture capabilities
        if has_capture_device "$CARD_NUM"; then
            # Generate stream name based on card ID
            STREAM_NAME=$(get_stream_name "$CARD_ID")
            RTSP_URL="rtsp://localhost:8554/$STREAM_NAME"
            
            echo "Starting RTSP stream for card $CARD_NUM [$CARD_ID]: $RTSP_URL"
            
            # Save the details to our array
            # Use a delimiter that's unlikely to appear in the names
            echo "$CARD_NUM|$CARD_ID|$USB_INFO|$RTSP_URL" >> /tmp/stream_details.$
            
            # Start ffmpeg with the appropriate sound card
            ffmpeg -nostdin -f alsa -ac 1 -i "plughw:CARD=$CARD_ID,DEV=0" \
                  -acodec libmp3lame -b:a 160k -ac 2 -content_type 'audio/mpeg' \
                  -f rtsp "$RTSP_URL" -rtsp_transport tcp &
            
            # Small delay to stagger the ffmpeg starts
            sleep 0.5
        else
            echo "Skipping card $CARD_NUM [$CARD_ID] - no capture device found"
        fi
    fi
done

# Check if any streams were created
if [ -f /tmp/stream_details.$ ]; then
    echo ""
    echo "================================================================="
    echo "                  ACTIVE AUDIO RTSP STREAMS                      "
    echo "================================================================="
    printf "%-4s | %-15s | %-30s | %s\n" "Card" "Card ID" "USB Device" "RTSP URL"
    echo "-----------------------------------------------------------------"
    
    # Print a formatted table of the streams
    while IFS="|" read -r card_num card_id usb_info rtsp_url; do
        printf "%-4s | %-15s | %-30s | %s\n" "$card_num" "$card_id" "$usb_info" "$rtsp_url"
    done < /tmp/stream_details.$
    
    echo "================================================================="
    echo ""
    
    # Get the IP address of the machine for external access
    IP_ADDR=$(hostname -I | awk '{print $1}')
    if [ -n "$IP_ADDR" ]; then
        echo "To access these streams from other devices on the network, replace"
        echo "'localhost' with '$IP_ADDR' in the RTSP URLs"
        echo ""
    fi
    
    # Clean up the temporary file
    rm /tmp/stream_details.$
else
    echo "No audio streams were created. Check if you have audio capture devices connected."
fi

# Keep script running to maintain the background processes
echo "Press Ctrl+C to stop all streams and exit"
wait

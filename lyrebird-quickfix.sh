#!/bin/bash
# lyrebird-quickfix.sh - Automated fix for common LyreBirdAudio streaming issues
# Run as: sudo bash lyrebird-quickfix.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

log_info "LyreBirdAudio Quick Fix - Starting diagnostics..."
echo

# Step 1: Detect audio devices
log_info "Step 1: Detecting USB audio devices..."
if ! arecord -l 2>/dev/null | grep -q "card"; then
    log_error "No audio devices detected!"
    echo "  Run 'arecord -l' to verify your USB device is connected"
    exit 1
fi

CARD_INFO=$(arecord -l | head -n 5)
echo "$CARD_INFO"

# Get first card number
CARD_NUM=$(echo "$CARD_INFO" | grep -oP 'card \K\d+' | head -1)
if [[ -z "$CARD_NUM" ]]; then
    log_error "Could not detect card number"
    exit 1
fi

log_success "Found audio card: $CARD_NUM"
echo

# Step 2: Test device accessibility
log_info "Step 2: Testing device accessibility..."
if timeout 5 arecord -D plughw:${CARD_NUM},0 -f S16_LE -r 48000 -c 2 -d 1 /tmp/test.wav 2>/dev/null; then
    log_success "Device is accessible"
    rm -f /tmp/test.wav
else
    log_error "Cannot access device"
    log_info "Trying to free the device..."
    fuser -k /dev/snd/pcmC${CARD_NUM}D0c 2>/dev/null || true
    sleep 2
    
    if timeout 5 arecord -D plughw:${CARD_NUM},0 -f S16_LE -r 48000 -c 2 -d 1 /tmp/test.wav 2>/dev/null; then
        log_success "Device is now accessible"
        rm -f /tmp/test.wav
    else
        log_error "Still cannot access device. Check if another application is using it."
        exit 1
    fi
fi
echo

# Step 3: Stop everything
log_info "Step 3: Stopping all services..."
pkill -9 ffmpeg 2>/dev/null || true
pkill -9 mediamtx 2>/dev/null || true
sleep 2
log_success "Services stopped"
echo

# Step 4: Clean up stale files
log_info "Step 4: Cleaning up stale files..."
rm -f /var/run/mediamtx-audio.* 2>/dev/null || true
rm -f /var/lib/mediamtx-ffmpeg/*.pid 2>/dev/null || true
rm -f /var/lib/mediamtx-ffmpeg/*.sh 2>/dev/null || true
log_success "Cleanup complete"
echo

# Step 5: Verify/create device configuration
log_info "Step 5: Configuring audio device..."
mkdir -p /etc/mediamtx

# Detect stream name from card info
STREAM_NAME="audio_card_${CARD_NUM}"
if arecord -l | grep -q "RØDE"; then
    STREAM_NAME="rode_ai_micro"
elif arecord -l | grep -q "Blue"; then
    STREAM_NAME="blue_yeti"
fi

# Create device config
cat > /etc/mediamtx/audio-devices.conf << EOF
# LyreBirdAudio device configuration
# Format: stream_name:alsa_device:sample_rate:channels
${STREAM_NAME}:hw:${CARD_NUM}:48000:2
EOF

log_success "Device configured as stream: ${STREAM_NAME}"
cat /etc/mediamtx/audio-devices.conf
echo

# Step 6: Verify MediaMTX is installed
log_info "Step 6: Verifying MediaMTX installation..."
if [[ ! -x /usr/local/bin/mediamtx ]]; then
    log_error "MediaMTX not found at /usr/local/bin/mediamtx"
    log_info "Run: sudo ./install_mediamtx.sh install"
    exit 1
fi

MEDIAMTX_VERSION=$(/usr/local/bin/mediamtx --version 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
log_success "MediaMTX installed: v${MEDIAMTX_VERSION}"
echo

# Step 7: Start MediaMTX
log_info "Step 7: Starting MediaMTX..."
if [[ ! -f /etc/mediamtx/mediamtx.yml ]]; then
    log_warn "Creating default MediaMTX config..."
    cat > /etc/mediamtx/mediamtx.yml << 'EOF'
logLevel: info
api: yes
apiAddress: :9997
metrics: yes
metricsAddress: :9998
rtsp: yes
rtspAddress: :8554
rtspTransports: [tcp, udp]
paths:
  '~^[a-zA-Z0-9_-]+$':
    source: publisher
    sourceOnDemand: no
EOF
fi

# Start MediaMTX in background
nohup /usr/local/bin/mediamtx /etc/mediamtx/mediamtx.yml > /var/log/mediamtx.out 2>&1 &
MEDIAMTX_PID=$!
echo "$MEDIAMTX_PID" > /var/run/mediamtx-audio.pid

sleep 3

# Verify MediaMTX is running
if kill -0 "$MEDIAMTX_PID" 2>/dev/null; then
    log_success "MediaMTX started (PID: $MEDIAMTX_PID)"
else
    log_error "MediaMTX failed to start"
    log_info "Check logs: tail -50 /var/log/mediamtx.out"
    exit 1
fi

# Wait for API
log_info "Waiting for MediaMTX API..."
for i in {1..10}; do
    if curl -s --max-time 2 http://localhost:9997/v3/paths/list >/dev/null 2>&1; then
        log_success "MediaMTX API is ready"
        break
    fi
    if [[ $i -eq 10 ]]; then
        log_error "MediaMTX API did not become ready"
        exit 1
    fi
    sleep 2
done
echo

# Step 8: Start FFmpeg stream manually
log_info "Step 8: Starting FFmpeg stream..."
mkdir -p /var/lib/mediamtx-ffmpeg

RTSP_URL="rtsp://localhost:8554/${STREAM_NAME}"
LOG_FILE="/var/lib/mediamtx-ffmpeg/${STREAM_NAME}.log"

# Create FFmpeg wrapper
cat > /var/lib/mediamtx-ffmpeg/${STREAM_NAME}.sh << EOF
#!/bin/bash
while true; do
    ffmpeg -hide_banner -loglevel warning \\
        -f alsa -ar 48000 -ac 2 -i plughw:${CARD_NUM},0 \\
        -c:a libopus -b:a 128k -application audio \\
        -f rtsp -rtsp_transport tcp \\
        ${RTSP_URL} >> ${LOG_FILE} 2>&1
    
    echo "[$(date)] FFmpeg exited, restarting in 5s..." >> ${LOG_FILE}
    sleep 5
done
EOF

chmod +x /var/lib/mediamtx-ffmpeg/${STREAM_NAME}.sh

# Start FFmpeg wrapper
nohup bash /var/lib/mediamtx-ffmpeg/${STREAM_NAME}.sh >/dev/null 2>&1 &
FFMPEG_PID=$!
echo "$FFMPEG_PID" > /var/lib/mediamtx-ffmpeg/${STREAM_NAME}.pid

sleep 5

if kill -0 "$FFMPEG_PID" 2>/dev/null; then
    log_success "FFmpeg stream started (PID: $FFMPEG_PID)"
else
    log_error "FFmpeg failed to start"
    log_info "Check logs: tail -20 ${LOG_FILE}"
    exit 1
fi
echo

# Step 9: Verify stream
log_info "Step 9: Verifying stream..."
sleep 5

if curl -s http://localhost:9997/v3/paths/list 2>/dev/null | grep -q "\"${STREAM_NAME}\""; then
    log_success "Stream is publishing!"
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}SUCCESS!${NC} Your stream is ready:"
    echo
    echo "  📡 Stream URL:"
    echo "     ${RTSP_URL}"
    echo
    echo "  🎵 Test playback:"
    echo "     ffplay -rtsp_transport tcp ${RTSP_URL}"
    echo "     vlc ${RTSP_URL}"
    echo
    echo "  📊 View status:"
    echo "     curl http://localhost:9997/v3/paths/list | jq"
    echo
    echo "  📋 Check logs:"
    echo "     tail -f ${LOG_FILE}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
else
    log_warn "Stream not detected in MediaMTX API yet"
    log_info "Wait 10 more seconds and check manually:"
    echo "  curl http://localhost:9997/v3/paths/list | jq"
    echo "  tail -20 ${LOG_FILE}"
fi

# Step 10: Create status check script
cat > /tmp/check_stream.sh << EOF
#!/bin/bash
echo "=== MediaMTX Status ==="
if kill -0 \$(cat /var/run/mediamtx-audio.pid 2>/dev/null) 2>/dev/null; then
    echo "MediaMTX: Running"
else
    echo "MediaMTX: Not running"
fi
echo

echo "=== FFmpeg Status ==="
if kill -0 \$(cat /var/lib/mediamtx-ffmpeg/${STREAM_NAME}.pid 2>/dev/null) 2>/dev/null; then
    echo "FFmpeg: Running"
else
    echo "FFmpeg: Not running"
fi
echo

echo "=== Stream Status ==="
curl -s http://localhost:9997/v3/paths/list 2>/dev/null | jq -r '.items[] | .name' || echo "API not responding"
echo

echo "=== Recent FFmpeg Log ==="
tail -10 ${LOG_FILE} 2>/dev/null || echo "No logs"
EOF

chmod +x /tmp/check_stream.sh

log_info "Status check script created: /tmp/check_stream.sh"
log_info "Run it anytime with: bash /tmp/check_stream.sh"
echo

log_success "Quick fix completed!"

#!/bin/bash
# Setup script for MediaMTX Monitor
# Run this script to install the MediaMTX monitor

# Define color codes for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Version information
SCRIPT_VERSION="1.0.0"
CONFIG_DIR="/etc/audio-rtsp"
CONFIG_FILE="${CONFIG_DIR}/config"
MONITOR_SCRIPT="/usr/local/bin/mediamtx-monitor.sh"
SERVICE_FILE="/etc/systemd/system/mediamtx-monitor.service"

# Show script information
echo -e "${BLUE}MediaMTX Monitor Setup v${SCRIPT_VERSION}${NC}"
echo -e "${GREEN}Setting up MediaMTX Resource Monitor...${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Please run as root${NC}"
  exit 1
fi

# Create timestamp for backups
TIMESTAMP=$(date +"%Y%m%d%H%M%S")

# Check if config directory exists
if [ ! -d "$CONFIG_DIR" ]; then
  echo -e "${YELLOW}Creating configuration directory...${NC}"
  mkdir -p "$CONFIG_DIR"
fi

# Create or update the configuration file
echo -e "${YELLOW}Updating configuration file...${NC}"
if [ -f "$CONFIG_FILE" ]; then
  echo -e "${YELLOW}Creating backup of existing config...${NC}"
  cp "$CONFIG_FILE" "${CONFIG_FILE}.backup-${TIMESTAMP}"
  
  # Check if MediaMTX monitor settings already exist
  if grep -q "MEDIAMTX_CPU_THRESHOLD" "$CONFIG_FILE"; then
    echo -e "${YELLOW}MediaMTX monitor settings already exist in config file.${NC}"
  else
    echo -e "${GREEN}Adding MediaMTX monitor settings to config file...${NC}"
    cat >> "$CONFIG_FILE" << 'EOF'

# MediaMTX Resource Monitor Configuration
# CPU threshold in percentage - restart if exceeded for MEDIAMTX_CPU_SUSTAINED_PERIODS
MEDIAMTX_CPU_THRESHOLD=80

# Number of consecutive periods CPU must be high before restart
MEDIAMTX_CPU_SUSTAINED_PERIODS=3

# How often to check CPU usage (in seconds)
MEDIAMTX_CPU_CHECK_INTERVAL=60

# Memory threshold in percentage - restart if exceeded
MEDIAMTX_MEMORY_THRESHOLD=15

# Maximum uptime in seconds - force restart after this time
# Default: 86400 (24 hours)
MEDIAMTX_MAX_UPTIME=86400

# Path to MediaMTX executable
MEDIAMTX_PATH=/usr/local/mediamtx/mediamtx

# MediaMTX process name for monitoring
MEDIAMTX_NAME=mediamtx

# MediaMTX systemd service name (if using systemd)
MEDIAMTX_SERVICE=mediamtx.service
EOF
  fi
else
  echo -e "${YELLOW}Creating new config file...${NC}"
  cat > "$CONFIG_FILE" << 'EOF'
# Audio RTSP Streaming Service Configuration
# Modify these settings to customize the service

# RTSP server port
RTSP_PORT=18554

# Number of seconds to wait before restart attempts
RESTART_DELAY=10

# Maximum number of restart attempts before giving up
MAX_RESTART_ATTEMPTS=5

# Logging level (debug, info, warning, error)
LOG_LEVEL=info

# Path to the log directory
LOG_DIR=/var/log/audio-rtsp

# Log rotation settings
LOG_ROTATE_DAYS=7

# MediaMTX Resource Monitor Configuration
# CPU threshold in percentage - restart if exceeded for MEDIAMTX_CPU_SUSTAINED_PERIODS
MEDIAMTX_CPU_THRESHOLD=80

# Number of consecutive periods CPU must be high before restart
MEDIAMTX_CPU_SUSTAINED_PERIODS=3

# How often to check CPU usage (in seconds)
MEDIAMTX_CPU_CHECK_INTERVAL=60

# Memory threshold in percentage - restart if exceeded
MEDIAMTX_MEMORY_THRESHOLD=15

# Maximum uptime in seconds - force restart after this time
# Default: 86400 (24 hours)
MEDIAMTX_MAX_UPTIME=86400

# Path to MediaMTX executable
MEDIAMTX_PATH=/usr/local/mediamtx/mediamtx

# MediaMTX process name for monitoring
MEDIAMTX_NAME=mediamtx

# MediaMTX systemd service name (if using systemd)
MEDIAMTX_SERVICE=mediamtx.service
EOF
fi

# Install the monitor script
echo -e "${YELLOW}Installing MediaMTX monitor script...${NC}"
if [ -f "$MONITOR_SCRIPT" ]; then
  echo -e "${YELLOW}Creating backup of existing script...${NC}"
  cp "$MONITOR_SCRIPT" "${MONITOR_SCRIPT}.backup-${TIMESTAMP}"
fi

# Paste the mediamtx-monitor.sh script content here
cat > "$MONITOR_SCRIPT" << 'EOF'
#!/bin/bash
# mediamtx-monitor.sh: MediaMTX CPU and Resource Monitor
# Version: 1.0.0
# Description: Monitors MediaMTX resource usage and restarts if necessary

# Configuration
CONFIG_DIR="/etc/audio-rtsp"
CONFIG_FILE="${CONFIG_DIR}/config"
MEDIAMTX_PATH="/usr/local/mediamtx/mediamtx"
MEDIAMTX_NAME="mediamtx"
MEDIAMTX_SERVICE="mediamtx.service"
RTSP_PORT="18554"
LOG_DIR="/var/log/audio-rtsp"
MONITOR_LOG="${LOG_DIR}/mediamtx-monitor.log"

# CPU thresholds and monitoring parameters
CPU_THRESHOLD=80         # Restart MediaMTX if CPU exceeds this percentage
CPU_SUSTAINED_PERIODS=3  # Number of consecutive periods CPU must be high
CPU_CHECK_INTERVAL=60    # Check CPU every X seconds
MEMORY_THRESHOLD=15      # Percentage of system memory
MAX_UPTIME=86400         # Force restart after 24 hours (86400 seconds)

# Initialize log file with appropriate permissions
mkdir -p "$LOG_DIR" 2>/dev/null
touch "$MONITOR_LOG" 2>/dev/null
chmod 644 "$MONITOR_LOG" 2>/dev/null

# Load configuration if available
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    # Override defaults with config file values if they exist
    if [ -n "$MEDIAMTX_CPU_THRESHOLD" ]; then
        CPU_THRESHOLD=$MEDIAMTX_CPU_THRESHOLD
    fi
    if [ -n "$MEDIAMTX_CPU_SUSTAINED_PERIODS" ]; then
        CPU_SUSTAINED_PERIODS=$MEDIAMTX_CPU_SUSTAINED_PERIODS
    fi
    if [ -n "$MEDIAMTX_CPU_CHECK_INTERVAL" ]; then
        CPU_CHECK_INTERVAL=$MEDIAMTX_CPU_CHECK_INTERVAL
    fi
    if [ -n "$MEDIAMTX_MEMORY_THRESHOLD" ]; then
        MEMORY_THRESHOLD=$MEDIAMTX_MEMORY_THRESHOLD
    fi
    if [ -n "$MEDIAMTX_MAX_UPTIME" ]; then
        MAX_UPTIME=$MEDIAMTX_MAX_UPTIME
    fi
    if [ -n "$MEDIAMTX_PATH" ]; then
        MEDIAMTX_PATH=$MEDIAMTX_PATH
    fi
    if [ -n "$MEDIAMTX_NAME" ]; then
        MEDIAMTX_NAME=$MEDIAMTX_NAME
    fi
    if [ -n "$MEDIAMTX_SERVICE" ]; then
        MEDIAMTX_SERVICE=$MEDIAMTX_SERVICE
    fi
fi

# Function for logging
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" >> "$MONITOR_LOG"
    # If running in terminal, also output to stdout
    if [ -t 1 ]; then
        echo "[$timestamp] $1"
    fi
}

# Check if we can use systemctl to manage MediaMTX
uses_systemd=false
if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files | grep -q "$MEDIAMTX_SERVICE"; then
        uses_systemd=true
    fi
fi

# Function to check if a process is running
is_process_running() {
    local process_name="$1"
    if pgrep -f "$process_name" >/dev/null 2>&1; then
        return 0  # Process is running
    else
        return 1  # Process is not running
    fi
}

# Function to get process ID of MediaMTX
get_mediamtx_pid() {
    local pid
    pid=$(pgrep -f "$MEDIAMTX_NAME" | head -n1)
    echo "$pid"
}

# Function to get MediaMTX uptime in seconds
get_mediamtx_uptime() {
    local pid=$1
    if [ -z "$pid" ]; then
        echo "0"
        return
    fi
    
    # Get process start time in seconds since boot
    if [ -f "/proc/$pid/stat" ]; then
        local starttime=$(awk '{print $22}' "/proc/$pid/stat")
        local btime=$(grep btime /proc/stat | awk '{print $2}')
        local uptime=$(cat /proc/uptime | awk '{print $1}' | cut -d. -f1)
        
        # Calculate process uptime in seconds
        local proc_uptime=$((uptime - (starttime / 100)))
        echo "$proc_uptime"
    else
        echo "0"
    fi
}

# Function to get MediaMTX CPU usage percentage
get_mediamtx_cpu() {
    local pid=$1
    if [ -z "$pid" ]; then
        echo "0"
        return
    fi
    
    # Use top to get CPU usage
    local cpu_usage
    cpu_usage=$(top -b -n 1 -p "$pid" | tail -n 1 | awk '{print $9}')
    
    # If top fails, try ps
    if [ -z "$cpu_usage" ]; then
        cpu_usage=$(ps -p "$pid" -o %cpu= | tr -d ' ')
    fi
    
    # Remove decimal places
    cpu_usage=${cpu_usage%%.*}
    
    # Return 0 if empty or not a number
    if [[ ! "$cpu_usage" =~ ^[0-9]+$ ]]; then
        echo "0"
    else
        echo "$cpu_usage"
    fi
}

# Function to get MediaMTX memory usage percentage
get_mediamtx_memory() {
    local pid=$1
    if [ -z "$pid" ]; then
        echo "0"
        return
    fi
    
    # Use ps to get memory usage (VSZ)
    local memory_percentage
    memory_percentage=$(ps -p "$pid" -o %mem= | tr -d ' ')
    
    # Remove decimal places
    memory_percentage=${memory_percentage%%.*}
    
    # Return 0 if empty or not a number
    if [[ ! "$memory_percentage" =~ ^[0-9]+$ ]]; then
        echo "0"
    else
        echo "$memory_percentage"
    fi
}

# Function to restart MediaMTX
restart_mediamtx() {
    local reason="$1"
    log "Restarting MediaMTX due to: $reason"
    
    # Stop all ffmpeg RTSP processes first to ensure clean restart
    log "Stopping ffmpeg RTSP processes..."
    pkill -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" 2>/dev/null || true
    sleep 2
    
    if [ "$uses_systemd" = true ]; then
        log "Using systemd to restart MediaMTX service..."
        systemctl restart "$MEDIAMTX_SERVICE"
    else
        log "Stopping MediaMTX process..."
        pkill -f "$MEDIAMTX_NAME" 2>/dev/null || true
        sleep 2
        
        # Verify it's actually stopped, force if necessary
        if is_process_running "$MEDIAMTX_NAME"; then
            log "MediaMTX still running, sending SIGKILL..."
            pkill -9 -f "$MEDIAMTX_NAME" 2>/dev/null || true
            sleep 1
        fi
        
        # Start MediaMTX
        if [ -x "$MEDIAMTX_PATH" ]; then
            log "Starting MediaMTX from $MEDIAMTX_PATH..."
            "$MEDIAMTX_PATH" >/dev/null 2>&1 &
        else
            log "ERROR: MediaMTX executable not found or not executable: $MEDIAMTX_PATH"
            return 1
        fi
    fi
    
    # Short delay to allow MediaMTX to initialize
    sleep 5
    
    # Verify MediaMTX is running
    if is_process_running "$MEDIAMTX_NAME"; then
        log "MediaMTX successfully restarted"
        
        # If audio-rtsp service is running, restart it as well to recreate streams
        if systemctl is-active --quiet audio-rtsp.service; then
            log "Restarting audio-rtsp service to recreate streams..."
            systemctl restart audio-rtsp.service
        fi
        
        return 0
    else
        log "ERROR: MediaMTX failed to restart"
        return 1
    fi
}

# Main monitoring loop
log "Starting MediaMTX resource monitor (CPU threshold: ${CPU_THRESHOLD}%, Memory threshold: ${MEMORY_THRESHOLD}%, Max uptime: ${MAX_UPTIME}s)"

# Track high CPU periods
consecutive_high_cpu=0

while true; do
    # Check if MediaMTX is running
    if ! is_process_running "$MEDIAMTX_NAME"; then
        log "WARNING: MediaMTX is not running! Attempting to start..."
        restart_mediamtx "process not running"
        sleep 10
        continue
    fi
    
    # Get MediaMTX PID
    mediamtx_pid=$(get_mediamtx_pid)
    if [ -z "$mediamtx_pid" ]; then
        log "WARNING: Could not determine MediaMTX PID"
        sleep 10
        continue
    fi
    
    # Get resource usage
    cpu_usage=$(get_mediamtx_cpu "$mediamtx_pid")
    memory_usage=$(get_mediamtx_memory "$mediamtx_pid")
    uptime=$(get_mediamtx_uptime "$mediamtx_pid")
    
    # Log current status at a regular interval
    if (( $(date +%s) % 300 < CPU_CHECK_INTERVAL )); then  # Log every 5 minutes
        log "STATUS: MediaMTX (PID: $mediamtx_pid) - CPU: ${cpu_usage}%, Memory: ${memory_usage}%, Uptime: ${uptime}s"
    fi
    
    # Check CPU threshold
    if [ "$cpu_usage" -ge "$CPU_THRESHOLD" ]; then
        consecutive_high_cpu=$((consecutive_high_cpu + 1))
        log "WARNING: MediaMTX CPU usage is high: ${cpu_usage}% (threshold: ${CPU_THRESHOLD}%, consecutive periods: ${consecutive_high_cpu}/${CPU_SUSTAINED_PERIODS})"
        
        # If CPU has been high for consecutive periods, restart
        if [ "$consecutive_high_cpu" -ge "$CPU_SUSTAINED_PERIODS" ]; then
            restart_mediamtx "sustained high CPU usage (${cpu_usage}%)"
            consecutive_high_cpu=0
        fi
    else
        # Reset counter if CPU is normal
        if [ "$consecutive_high_cpu" -gt 0 ]; then
            log "INFO: MediaMTX CPU usage normalized: ${cpu_usage}%"
            consecutive_high_cpu=0
        fi
    fi
    
    # Check memory threshold
    if [ "$memory_usage" -ge "$MEMORY_THRESHOLD" ]; then
        log "WARNING: MediaMTX memory usage is high: ${memory_usage}% (threshold: ${MEMORY_THRESHOLD}%)"
        restart_mediamtx "high memory usage (${memory_usage}%)"
    fi
    
    # Check uptime - force restart after MAX_UPTIME
    if [ "$uptime" -ge "$MAX_UPTIME" ]; then
        log "INFO: MediaMTX has reached maximum uptime of ${MAX_UPTIME}s, performing preventive restart"
        restart_mediamtx "scheduled restart after ${MAX_UPTIME}s uptime"
    fi
    
    # Sleep before next check
    sleep "$CPU_CHECK_INTERVAL"
done
EOF

chmod +x "$MONITOR_SCRIPT"
echo -e "${GREEN}MediaMTX monitor script installed to ${MONITOR_SCRIPT}${NC}"

# Create systemd service file
echo -e "${YELLOW}Creating systemd service file...${NC}"
if [ -f "$SERVICE_FILE" ]; then
  echo -e "${YELLOW}Creating backup of existing service file...${NC}"
  cp "$SERVICE_FILE" "${SERVICE_FILE}.backup-${TIMESTAMP}"
fi

cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=MediaMTX Resource Monitor
After=network.target
Wants=mediamtx.service
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/mediamtx-monitor.sh
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=10
# Give the monitor time to properly initialize
TimeoutStartSec=30
# Set resource limits
LimitNOFILE=65536
# Ensure environment is properly set up
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StandardOutput=append:/var/log/audio-rtsp/mediamtx-monitor-service.log
StandardError=append:/var/log/audio-rtsp/mediamtx-monitor-error.log
# Give the service a chance to clean up when stopping
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF

echo -e "${GREEN}MediaMTX monitor service file created at ${SERVICE_FILE}${NC}"

# Create log directory if it doesn't exist
mkdir -p /var/log/audio-rtsp

# Enable and start the service
echo -e "${YELLOW}Enabling and starting MediaMTX monitor service...${NC}"
systemctl daemon-reload

# Check if the service file is valid
if systemctl cat mediamtx-monitor.service &>/dev/null; then
    echo -e "${GREEN}Service file validated successfully${NC}"
    systemctl enable mediamtx-monitor.service
    
    # Try to start the service
    if systemctl start mediamtx-monitor.service; then
        echo -e "${GREEN}MediaMTX monitor service started successfully${NC}"
    else
        echo -e "${RED}MediaMTX monitor service failed to start. Check logs with:${NC}"
        echo "journalctl -u mediamtx-monitor.service"
    fi
else
    echo -e "${RED}Error in service file. Installation incomplete.${NC}"
    exit 1
fi

echo -e "${GREEN}MediaMTX monitor has been successfully installed!${NC}"
echo -e "The monitor will automatically restart MediaMTX if:"
echo -e "  - CPU usage exceeds ${MEDIAMTX_CPU_THRESHOLD:-80}% for ${MEDIAMTX_CPU_SUSTAINED_PERIODS:-3} consecutive checks"
echo -e "  - Memory usage exceeds ${MEDIAMTX_MEMORY_THRESHOLD:-15}%"
echo -e "  - Uptime exceeds ${MEDIAMTX_MAX_UPTIME:-86400} seconds (24 hours)"
echo -e "Service management commands:"
echo -e "  Check status: ${YELLOW}sudo systemctl status mediamtx-monitor${NC}"
echo -e "  Start service: ${YELLOW}sudo systemctl start mediamtx-monitor${NC}"
echo -e "  Stop service: ${YELLOW}sudo systemctl stop mediamtx-monitor${NC}"
echo -e "  Restart service: ${YELLOW}sudo systemctl restart mediamtx-monitor${NC}"
echo -e "  View logs: ${YELLOW}sudo tail -f /var/log/audio-rtsp/mediamtx-monitor.log${NC}"
echo -e "Configuration:"
echo -e "  Edit settings in: ${YELLOW}$CONFIG_FILE${NC}"
echo -e "  After editing, restart the monitor service: ${YELLOW}sudo systemctl restart mediamtx-monitor${NC}"

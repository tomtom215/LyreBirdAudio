#!/bin/bash
# MediaMTX Monitor Service Diagnostic and Fix Script
#
# https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/mediamtx-monitor-diagnostic-fix.sh
#
# Version: 1.0.0
# Date: 2025-05-15
#
# Script to diagnose and fix issues with the MediaMTX Monitor service

# Color codes for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Define paths
MONITOR_SCRIPT="/usr/local/bin/mediamtx-monitor.sh"
SERVICE_FILE="/etc/systemd/system/mediamtx-monitor.service"
CONFIG_DIR="/etc/audio-rtsp"
LOG_DIR="/var/log/audio-rtsp"
BACKUP_DIR="/tmp/mediamtx-monitor-fix-$(date +%s)"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Functions
echo_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }
echo_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
echo_debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo_error "This script must be run as root or with sudo"
    exit 1
fi

echo_info "Starting MediaMTX Monitor Service diagnostic"

# Step 1: Check if the service file exists
echo_info "Checking service file..."
if [ ! -f "$SERVICE_FILE" ]; then
    echo_error "Service file not found: $SERVICE_FILE"
    exit 1
fi

# Backup the service file
cp "$SERVICE_FILE" "$BACKUP_DIR/mediamtx-monitor.service.bak"
echo_info "Service file backed up to $BACKUP_DIR/mediamtx-monitor.service.bak"

# Step 2: Check if the monitor script exists
echo_info "Checking monitor script..."
if [ ! -f "$MONITOR_SCRIPT" ]; then
    echo_error "Monitor script not found: $MONITOR_SCRIPT"
    exit 1
fi

# Backup the monitor script
cp "$MONITOR_SCRIPT" "$BACKUP_DIR/mediamtx-monitor.sh.bak"
echo_info "Monitor script backed up to $BACKUP_DIR/mediamtx-monitor.sh.bak"

# Step 3: Validate the monitor script syntax
echo_info "Validating script syntax..."
if ! bash -n "$MONITOR_SCRIPT" 2>/dev/null; then
    echo_error "Syntax validation failed for monitor script"
    bash -n "$MONITOR_SCRIPT"
    echo_warning "Will attempt to fix common issues"
else
    echo_info "Script syntax validation passed"
fi

# Step 4: Analyze service file
echo_info "Analyzing service file..."
SERVICE_EXEC=$(grep "ExecStart" "$SERVICE_FILE" | awk -F "=" '{print $2}')
echo_info "Service ExecStart: $SERVICE_EXEC"

# Step 5: Check for common issues and fix them

# Issue 1: Missing shebang or incorrect path
echo_info "Checking script shebang..."
SHEBANG=$(head -n 1 "$MONITOR_SCRIPT")
if [[ "$SHEBANG" != "#!/bin/bash" && "$SHEBANG" != "#!/usr/bin/env bash" ]]; then
    echo_warning "Incorrect or missing shebang: $SHEBANG"
    # Ensure the file starts with proper shebang
    sed -i '1s|^.*$|#!/bin/bash|' "$MONITOR_SCRIPT"
    echo_info "Fixed shebang line"
fi

# Issue 2: Permissions
echo_info "Checking script permissions..."
if [ ! -x "$MONITOR_SCRIPT" ]; then
    echo_warning "Script is not executable"
    chmod +x "$MONITOR_SCRIPT"
    echo_info "Fixed script permissions"
fi

# Issue 3: Service file paths
echo_info "Checking service file paths..."
if ! grep -q "ExecStart=/bin/bash $MONITOR_SCRIPT" "$SERVICE_FILE"; then
    echo_warning "Service file has incorrect ExecStart"
    # Ensure the service has the proper ExecStart
    sed -i "s|^ExecStart=.*|ExecStart=/bin/bash $MONITOR_SCRIPT|" "$SERVICE_FILE"
    echo_info "Fixed service ExecStart path"
fi

# Issue 4: Create required directories
echo_info "Ensuring required directories exist..."
mkdir -p "$CONFIG_DIR" "$LOG_DIR" "${LOG_DIR}/state"
chmod 755 "$CONFIG_DIR" "$LOG_DIR" "${LOG_DIR}/state"
echo_info "Created required directories with proper permissions"

# Step 6: Create a minimal but functional monitor script
echo_info "Creating a simplified, robust monitor script..."

cat > "$MONITOR_SCRIPT" << 'EOF'
#!/bin/bash
# Simple and robust MediaMTX Monitor Script

# Configuration
CONFIG_DIR="/etc/audio-rtsp"
CONFIG_FILE="${CONFIG_DIR}/config"
LOG_DIR="/var/log/audio-rtsp"
MONITOR_LOG="${LOG_DIR}/mediamtx-monitor.log"
STATE_DIR="${LOG_DIR}/state"
RTSP_PORT="18554"
CPU_THRESHOLD=80
MEMORY_THRESHOLD=15
CHECK_INTERVAL=60

# Make sure directories exist
mkdir -p "$LOG_DIR" "$STATE_DIR" 2>/dev/null

# Simple logging function
log() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$1] $2" >> "$MONITOR_LOG"
}

# Create log file with proper permissions
touch "$MONITOR_LOG" 2>/dev/null
chmod 644 "$MONITOR_LOG" 2>/dev/null

log "INFO" "Starting MediaMTX monitor"

# Source config file if available
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" 2>/dev/null || log "WARNING" "Error loading config file"
fi

# Function to get MediaMTX PID
get_pid() {
    pgrep -f "mediamtx" | head -n1 || echo ""
}

# Function to get CPU usage
get_cpu() {
    local pid=$1
    if [ -z "$pid" ]; then
        echo "0"
        return
    fi
    
    if ! ps -p "$pid" >/dev/null 2>&1; then
        echo "0"
        return
    fi
    
    ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0"
}

# Function to get memory usage
get_memory() {
    local pid=$1
    if [ -z "$pid" ]; then
        echo "0"
        return
    fi
    
    if ! ps -p "$pid" >/dev/null 2>&1; then
        echo "0"
        return
    fi
    
    ps -p "$pid" -o %mem= 2>/dev/null | tr -d ' ' || echo "0"
}

# Function to restart MediaMTX
restart_mediamtx() {
    local reason="$1"
    log "RECOVERY" "Restarting MediaMTX due to: $reason"
    
    # Try systemd restart first
    if command -v systemctl >/dev/null 2>&1; then
        log "INFO" "Using systemctl to restart MediaMTX"
        systemctl restart mediamtx.service
        sleep 5
        return 0
    fi
    
    # Fallback to direct process control
    local pid=$(get_pid)
    if [ -n "$pid" ]; then
        log "INFO" "Stopping MediaMTX process $pid"
        kill -15 "$pid" 2>/dev/null
        sleep 2
        
        # Force kill if still running
        if ps -p "$pid" >/dev/null 2>&1; then
            log "WARNING" "Process didn't stop with SIGTERM, using SIGKILL"
            kill -9 "$pid" 2>/dev/null
        fi
    fi
    
    # Wait to ensure process is stopped
    sleep 2
    
    # Start MediaMTX directly if needed
    if [ -x "/usr/local/mediamtx/mediamtx" ]; then
        log "INFO" "Starting MediaMTX"
        nohup /usr/local/mediamtx/mediamtx >/dev/null 2>&1 &
        sleep 2
        return 0
    else
        log "ERROR" "MediaMTX executable not found"
        return 1
    fi
}

# Main loop with error handling
while true; do
    # Wrap everything in try/catch using bash error handling
    {
        # Get MediaMTX PID
        pid=$(get_pid)
        
        # If MediaMTX is not running, start it
        if [ -z "$pid" ]; then
            log "WARNING" "MediaMTX not running, starting it"
            restart_mediamtx "process not running"
            sleep 10
            continue
        fi
        
        # Get resource usage
        cpu=$(get_cpu "$pid")
        memory=$(get_memory "$pid")
        
        # Strip decimal parts if present to avoid comparison issues
        cpu=${cpu%%.*}
        memory=${memory%%.*}
        
        # Handle empty values
        if [ -z "$cpu" ] || ! [[ "$cpu" =~ ^[0-9]+$ ]]; then
            cpu=0
        fi
        
        if [ -z "$memory" ] || ! [[ "$memory" =~ ^[0-9]+$ ]]; then
            memory=0
        fi
        
        # Store metrics for status reporting
        echo "$cpu" > "${STATE_DIR}/current_cpu"
        echo "$memory" > "${STATE_DIR}/current_memory"
        
        # Log periodic status
        if [ $(($(date +%s) % 300)) -lt "$CHECK_INTERVAL" ]; then
            log "INFO" "Status: CPU ${cpu}%, Memory ${memory}%"
        fi
        
        # Check thresholds
        if [ "$cpu" -ge "$CPU_THRESHOLD" ]; then
            log "WARNING" "CPU usage too high: ${cpu}%"
            restart_mediamtx "high CPU usage"
            sleep 10
            continue
        fi
        
        if [ "$memory" -ge "$MEMORY_THRESHOLD" ]; then
            log "WARNING" "Memory usage too high: ${memory}%"
            restart_mediamtx "high memory usage"
            sleep 10
            continue
        fi
    } || {
        # Error handler
        log "ERROR" "Exception in monitor loop: $?"
        sleep 30
    }
    
    # Sleep until next check
    sleep "$CHECK_INTERVAL"
done
EOF

chmod +x "$MONITOR_SCRIPT"
echo_info "Created simplified, robust monitor script"

# Step 7: Fix service file
echo_info "Updating service file..."

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=MediaMTX Resource Monitor
After=network.target mediamtx.service
Wants=mediamtx.service
StartLimitIntervalSec=600
StartLimitBurst=5

[Service]
Type=simple
ExecStart=/bin/bash $MONITOR_SCRIPT
Restart=on-failure
RestartSec=30
StandardOutput=append:${LOG_DIR}/mediamtx-monitor-stdout.log
StandardError=append:${LOG_DIR}/mediamtx-monitor-stderr.log

# Ensure monitor can access required directories
ReadWritePaths=${LOG_DIR} ${CONFIG_DIR}
WorkingDirectory=/tmp

[Install]
WantedBy=multi-user.target
EOF

echo_info "Updated service file with proper configuration"

# Step 8: Reload systemd and restart the service
echo_info "Reloading systemd daemon..."
systemctl daemon-reload

echo_info "Restarting monitor service..."
systemctl restart mediamtx-monitor.service
sleep 3

# Step 9: Check if service is running now
echo_info "Checking service status..."
if systemctl is-active --quiet mediamtx-monitor.service; then
    echo_info "Service is now running successfully!"
else
    echo_error "Service is still not running. Checking logs..."
    journalctl -u mediamtx-monitor.service -n 20
    
    # Try to debug further
    echo_info "Attempting service direct start for debugging..."
    systemctl stop mediamtx-monitor.service
    bash -x "$MONITOR_SCRIPT" &
    MONITOR_PID=$!
    sleep 5
    if kill -0 $MONITOR_PID 2>/dev/null; then
        echo_info "Script runs successfully in debug mode"
        kill $MONITOR_PID
    else
        echo_error "Script fails even in debug mode"
    fi
fi

echo_info "Diagnostic and fix completed"
echo_info "Original files backed up to $BACKUP_DIR"

# Offer to display service status
echo -e "\n${YELLOW}Would you like to check the monitor service status now? (y/N) ${NC}"
read -r check_status
if [[ "$check_status" =~ ^[Yy]$ ]]; then
    systemctl status mediamtx-monitor.service
fi

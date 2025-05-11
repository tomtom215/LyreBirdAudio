#!/bin/bash
# MediaMTX Monitor Installation Script
# Version: 1.0.1
# Date: 2025-05-10
# Description: Installs and configures the MediaMTX monitoring system

# Color codes for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Display banner
echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}     MediaMTX Resource Monitor Installer      ${NC}"
echo -e "${BLUE}===============================================${NC}"
echo -e "${GREEN}Version: 1.0.1${NC}"
echo -e "${GREEN}Date: 2025-05-10${NC}"
echo

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root or with sudo${NC}"
    exit 1
fi

# Base directories
CONFIG_DIR="/etc/audio-rtsp"
LOG_DIR="/var/log/audio-rtsp"
INSTALL_LOG="${LOG_DIR}/monitor-install.log"

# Create directories if they don't exist
mkdir -p "$CONFIG_DIR" "$LOG_DIR" 2>/dev/null

# Initialize log
echo "=== Installation started at $(date) ===" > "$INSTALL_LOG"

# Helper function for logging
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" >> "$INSTALL_LOG"
    
    # Also output to console with colors
    case "$level" in
        "INFO")
            echo -e "${GREEN}[$level]${NC} $message"
            ;;
        "WARNING")
            echo -e "${YELLOW}[$level]${NC} $message"
            ;;
        "ERROR")
            echo -e "${RED}[$level]${NC} $message"
            ;;
        *)
            echo -e "[$level] $message"
            ;;
    esac
}

# Check for required commands
check_dependencies() {
    log "INFO" "Checking dependencies..."
    
    local missing_deps=()
    local deps=("bash" "systemctl" "awk" "grep" "ps" "top" "lsof" "kill" "pkill" "nc")
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log "WARNING" "Missing dependencies: ${missing_deps[*]}"
        echo -e "${YELLOW}Some dependencies are missing. Install them? (Y/n) [default: Y]${NC}"
        read -t 10 -r install_deps || install_deps="y"
        
        if [[ "$install_deps" =~ ^[Nn]$ ]]; then
            log "WARNING" "Continuing without installing dependencies"
            echo -e "${YELLOW}Note: Missing dependencies may cause reduced functionality${NC}"
        else
            log "INFO" "Installing missing dependencies..."
            
            # Detect package manager
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update
                apt-get install -y netcat-openbsd procps lsof psmisc
            elif command -v yum >/dev/null 2>&1; then
                yum install -y nc procps lsof psmisc
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y nc procps lsof psmisc
            else
                log "ERROR" "Could not detect package manager. Please install the missing dependencies manually."
                return 1
            fi
            
            log "INFO" "Dependencies installed successfully"
        fi
    else
        log "INFO" "All dependencies are installed"
    fi
    
    return 0
}

# Read user input with timeout
read_with_timeout() {
    local prompt="$1"
    local default="$2"
    local timeout=10
    local result
    
    echo -e "$prompt"
    read -t $timeout -r result || result="$default"
    
    if [ -z "$result" ]; then
        result="$default"
    fi
    
    echo "$result"
}

# Create configuration file with minimal user interaction
create_config() {
    log "INFO" "Creating configuration file..."
    
    local config_file="${CONFIG_DIR}/config"
    local backup=false
    
    # Check if file exists
    if [ -f "$config_file" ]; then
        # Create backup
        cp "$config_file" "${config_file}.bak.$(date +%Y%m%d%H%M%S)"
        backup=true
        log "INFO" "Backed up existing config file"
    fi
    
    # Get value from existing config or use default
    get_config_value() {
        local key="$1"
        local default="$2"
        local value="$default"
        
        if [ "$backup" = true ]; then
            local existing
            existing=$(grep "^$key=" "$config_file" 2>/dev/null | cut -d= -f2)
            if [ -n "$existing" ]; then
                value="$existing"
            fi
        fi
        
        echo "$value"
    }
    
    # Set configuration values
    local rtsp_port=$(get_config_value "RTSP_PORT" "18554")
    local cpu_threshold=$(get_config_value "CPU_THRESHOLD" "80")
    local memory_threshold=$(get_config_value "MEMORY_THRESHOLD" "15")
    local enable_auto_reboot=$(get_config_value "ENABLE_AUTO_REBOOT" "false")
    
    # Show configuration menu
    echo
    echo -e "${BLUE}=== MediaMTX Monitor Configuration ===${NC}"
    if [ "$backup" = true ]; then
        echo -e "${GREEN}Found existing configuration. Using current values as defaults.${NC}"
    else
        echo -e "${GREEN}Setting up new configuration with default values.${NC}"
    fi
    echo -e "${YELLOW}Press Enter to accept the default values shown in brackets.${NC}"
    echo
    
    # Simple yes/no prompt for interactive configuration
    echo -e "${YELLOW}Do you want to customize configuration? (y/N) [default: N]:${NC}"
    read -t 10 -r customize || customize="n"
    
    if [[ "$customize" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}RTSP Port [${rtsp_port}]:${NC} "
        read -t 10 -r input
        if [ -n "$input" ]; then
            rtsp_port="$input"
        fi
        
        echo -e "${YELLOW}CPU Threshold (%) [${cpu_threshold}]:${NC} "
        read -t 10 -r input
        if [ -n "$input" ]; then
            cpu_threshold="$input"
        fi
        
        echo -e "${YELLOW}Memory Threshold (%) [${memory_threshold}]:${NC} "
        read -t 10 -r input
        if [ -n "$input" ]; then
            memory_threshold="$input"
        fi
        
        echo -e "${YELLOW}Enable Auto Reboot (true/false) [${enable_auto_reboot}]:${NC} "
        read -t 10 -r input
        if [ -n "$input" ]; then
            enable_auto_reboot="$input"
        fi
    else
        echo -e "${GREEN}Using default/existing values for all configuration options${NC}"
    fi
    
    # Create or append to config file
    cat > "$config_file" << EOF
# MediaMTX Monitor Configuration
# Created/Updated: $(date)

# MediaMTX Information
MEDIAMTX_PATH="/usr/local/mediamtx/mediamtx"
MEDIAMTX_NAME="mediamtx"
MEDIAMTX_SERVICE="mediamtx.service"
RTSP_PORT="$rtsp_port"

# Logging Configuration
LOG_DIR="$LOG_DIR"
LOG_LEVEL="info"

# Resource Thresholds
CPU_THRESHOLD=$cpu_threshold
CPU_WARNING_THRESHOLD=$((cpu_threshold - 10))
CPU_SUSTAINED_PERIODS=3
MEMORY_THRESHOLD=$memory_threshold
MEMORY_WARNING_THRESHOLD=$((memory_threshold - 3))
EMERGENCY_CPU_THRESHOLD=95
EMERGENCY_MEMORY_THRESHOLD=20
FILE_DESCRIPTOR_THRESHOLD=1000
COMBINED_CPU_THRESHOLD=200
COMBINED_CPU_WARNING=150

# Recovery Settings
MAX_RESTART_ATTEMPTS=5
RESTART_COOLDOWN=300
REBOOT_THRESHOLD=3
ENABLE_AUTO_REBOOT=$enable_auto_reboot
REBOOT_COOLDOWN=1800

# Advanced Settings
MAX_UPTIME=86400  # 24 hours - forces preventive restart
CPU_TREND_PERIODS=10
CPU_CHECK_INTERVAL=60
EOF
    
    # Set permissions
    chmod 644 "$config_file"
    
    log "INFO" "Configuration file created at $config_file"
    return 0
}

# Install monitoring script
install_monitor_script() {
    log "INFO" "Installing MediaMTX monitoring script..."
    
    # Destination script path
    local script_path="/usr/local/bin/mediamtx-monitor.sh"
    
    # Check if mediamtx-monitor-fixed.sh exists in current directory
    if [ -f "mediamtx-monitor-fixed.sh" ]; then
        log "INFO" "Found mediamtx-monitor-fixed.sh in current directory"
        cp "mediamtx-monitor-fixed.sh" "$script_path"
    else
        log "ERROR" "mediamtx-monitor-fixed.sh not found in current directory"
        echo -e "${RED}mediamtx-monitor-fixed.sh script not found!${NC}"
        echo -e "${YELLOW}Would you like to create a minimalist version? (Y/n) [default: Y]${NC}"
        read -t 10 -r create_min || create_min="y"
        
        if [[ "$create_min" =~ ^[Nn]$ ]]; then
            return 1
        else
            log "INFO" "Creating minimal monitor script"
            # Create minimalist version of the script
            cat > "$script_path" << 'EOF'
#!/bin/bash
# Minimal MediaMTX Resource Monitor (Auto-generated)
# Version: 1.0.0

# Base configuration
CONFIG_DIR="/etc/audio-rtsp"
CONFIG_FILE="${CONFIG_DIR}/config"
LOG_DIR="/var/log/audio-rtsp"
MONITOR_LOG="${LOG_DIR}/mediamtx-monitor.log"
RTSP_PORT="18554"
CPU_THRESHOLD=80
MEMORY_THRESHOLD=15
CHECK_INTERVAL=60

# Source config file if available
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Create log directory
mkdir -p "$LOG_DIR" 2>/dev/null

# Simple logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2" >> "$MONITOR_LOG"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$1] $2"
}

log "INFO" "Starting minimal MediaMTX monitor"

# Function to get MediaMTX PID
get_pid() {
    pgrep -f "mediamtx" | head -n1
}

# Function to get CPU usage
get_cpu() {
    ps -p "$1" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0"
}

# Function to get memory usage
get_memory() {
    ps -p "$1" -o %mem= 2>/dev/null | tr -d ' ' || echo "0"
}

# Function to restart MediaMTX
restart_mediamtx() {
    log "RECOVERY" "Restarting MediaMTX due to: $1"
    
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-unit-files | grep -q "mediamtx.service"; then
            log "INFO" "Restarting via systemd"
            systemctl restart mediamtx.service
            return $?
        fi
    fi
    
    # Direct process management
    local pid=$(get_pid)
    if [ -n "$pid" ]; then
        log "INFO" "Stopping MediaMTX process $pid"
        kill -15 "$pid" 2>/dev/null
        sleep 2
        
        # Force kill if still running
        if ps -p "$pid" >/dev/null 2>&1; then
            log "WARNING" "Process still running, using SIGKILL"
            kill -9 "$pid" 2>/dev/null
        fi
    fi
    
    # Start MediaMTX
    if [ -x "/usr/local/mediamtx/mediamtx" ]; then
        log "INFO" "Starting MediaMTX"
        nohup /usr/local/mediamtx/mediamtx >/dev/null 2>&1 &
        return 0
    else
        log "ERROR" "MediaMTX executable not found"
        return 1
    fi
}

# Main monitoring loop
while true; do
    pid=$(get_pid)
    
    if [ -z "$pid" ]; then
        log "WARNING" "MediaMTX not running, starting it"
        restart_mediamtx "process not running"
        sleep 10
        continue
    fi
    
    cpu=$(get_cpu "$pid")
    memory=$(get_memory "$pid")
    
    log "INFO" "MediaMTX status: CPU ${cpu}%, Memory ${memory}%"
    
    # Check thresholds
    if [ "${cpu%.*}" -ge "$CPU_THRESHOLD" ]; then
        log "WARNING" "CPU usage too high: ${cpu}%"
        restart_mediamtx "high CPU usage"
        sleep 10
        continue
    fi
    
    if [ "${memory%.*}" -ge "$MEMORY_THRESHOLD" ]; then
        log "WARNING" "Memory usage too high: ${memory}%"
        restart_mediamtx "high memory usage"
        sleep 10
        continue
    fi
    
    # Sleep until next check
    sleep "$CHECK_INTERVAL"
done
EOF
        fi
    fi
    
    # Set permissions
    chmod 755 "$script_path"
    
    log "INFO" "Monitoring script installed at $script_path"
    return 0
}

# Create systemd service
create_systemd_service() {
    log "INFO" "Creating systemd service..."
    
    local service_file="/etc/systemd/system/mediamtx-monitor.service"
    
    # Check if service already exists
    if [ -f "$service_file" ]; then
        log "INFO" "Backing up existing service file"
        cp "$service_file" "${service_file}.bak.$(date +%Y%m%d%H%M%S)"
    fi
    
    # Create service file
    cat > "$service_file" << EOF
[Unit]
Description=MediaMTX Resource Monitor
After=network.target mediamtx.service
Wants=mediamtx.service
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
ExecStart=/usr/local/bin/mediamtx-monitor.sh
Restart=on-failure
RestartSec=30
StandardOutput=append:${LOG_DIR}/mediamtx-monitor.log
StandardError=append:${LOG_DIR}/mediamtx-monitor-error.log
LimitNOFILE=65536
TimeoutStopSec=20

# Security hardening
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
ReadWritePaths=${LOG_DIR} ${CONFIG_DIR}

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd
    systemctl daemon-reload
    
    log "INFO" "Systemd service created at $service_file"
    return 0
}

# Create status check script
create_status_script() {
    log "INFO" "Creating status check script..."
    
    local script_path="/usr/local/bin/check-mediamtx-monitor.sh"
    
    # Create the script
    cat > "$script_path" << 'EOF'
#!/bin/bash
# MediaMTX Monitor Status Check Script

# Color codes for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

CONFIG_DIR="/etc/audio-rtsp"
LOG_DIR="/var/log/audio-rtsp"
STATE_DIR="${LOG_DIR}/state"

echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}         MediaMTX Monitor Status Check        ${NC}"
echo -e "${BLUE}===============================================${NC}"
echo

# Check if monitoring service is running
echo -e "${YELLOW}Monitor Service Status:${NC}"
if systemctl is-active --quiet mediamtx-monitor.service; then
    echo -e "${GREEN}● Active and running${NC}"
    
    # Get service uptime
    SERVICE_STARTED=$(systemctl show mediamtx-monitor.service -p ActiveEnterTimestamp --value)
    if [ -n "$SERVICE_STARTED" ]; then
        SERVICE_UPTIME=$(printf "Started: %s\n" "$SERVICE_STARTED")
        echo -e "$SERVICE_UPTIME"
    fi
else
    echo -e "${RED}✗ Not running${NC}"
fi

# Get a brief systemd status
echo
echo -e "${YELLOW}Service Details:${NC}"
systemctl status mediamtx-monitor.service --no-pager | head -n 5

# Check MediaMTX process status
echo
echo -e "${YELLOW}MediaMTX Process Status:${NC}"
MEDIAMTX_PID=$(pgrep -f "mediamtx" | head -n1)
if [ -n "$MEDIAMTX_PID" ]; then
    echo -e "${GREEN}● Running with PID: $MEDIAMTX_PID${NC}"
    
    # Load resource metrics from state if available
    if [ -d "$STATE_DIR" ]; then
        if [ -f "${STATE_DIR}/current_cpu" ]; then
            CPU=$(cat "${STATE_DIR}/current_cpu")
            echo -e "CPU Usage: ${CPU}%"
        fi
        
        if [ -f "${STATE_DIR}/combined_cpu" ]; then
            COMBINED_CPU=$(cat "${STATE_DIR}/combined_cpu")
            echo -e "Combined CPU Usage (MediaMTX + ffmpeg): ${COMBINED_CPU}%"
        fi
        
        if [ -f "${STATE_DIR}/current_memory" ]; then
            MEMORY=$(cat "${STATE_DIR}/current_memory")
            echo -e "Memory Usage: ${MEMORY}%"
        fi
        
        if [ -f "${STATE_DIR}/current_fd" ]; then
            FD=$(cat "${STATE_DIR}/current_fd")
            echo -e "Open File Descriptors: ${FD}"
        fi
        
        if [ -f "${STATE_DIR}/current_uptime" ]; then
            UPTIME=$(cat "${STATE_DIR}/current_uptime")
            # Convert seconds to human-readable format
            UPTIME_HOURS=$((UPTIME / 3600))
            UPTIME_MINUTES=$(( (UPTIME % 3600) / 60 ))
            UPTIME_SECONDS=$((UPTIME % 60))
            echo -e "Uptime: ${UPTIME_HOURS}h ${UPTIME_MINUTES}m ${UPTIME_SECONDS}s"
        fi
    else
        echo -e "${YELLOW}No state data available${NC}"
    fi
else
    echo -e "${RED}✗ Not running${NC}"
fi

# Check recovery history
echo
echo -e "${YELLOW}Recovery History:${NC}"
if [ -f "${LOG_DIR}/recovery-actions.log" ]; then
    RECOVERY_COUNT=$(grep -c "\[RECOVERY\]" "${LOG_DIR}/recovery-actions.log")
    REBOOT_COUNT=$(grep -c "\[REBOOT\]" "${LOG_DIR}/recovery-actions.log")
    
    echo -e "Total recoveries: ${RECOVERY_COUNT}"
    echo -e "System reboot attempts: ${REBOOT_COUNT}"
    
    # Show last 3 recovery actions
    echo -e "\n${YELLOW}Last 3 recovery actions:${NC}"
    grep "\[RECOVERY\]" "${LOG_DIR}/recovery-actions.log" | tail -n 3 || echo -e "${GREEN}No recovery actions found${NC}"
else
    echo -e "${GREEN}No recovery actions recorded${NC}"
fi

# Check log file for errors
echo
echo -e "${YELLOW}Recent Logs:${NC}"
if [ -f "${LOG_DIR}/mediamtx-monitor.log" ]; then
    # Count errors and warnings
    ERROR_COUNT=$(grep -c "\[ERROR\]" "${LOG_DIR}/mediamtx-monitor.log")
    WARNING_COUNT=$(grep -c "\[WARNING\]" "${LOG_DIR}/mediamtx-monitor.log")
    
    echo -e "Errors: ${ERROR_COUNT}, Warnings: ${WARNING_COUNT}"
    
    # Show last 5 errors if any
    if [ "$ERROR_COUNT" -gt 0 ]; then
        echo -e "\n${RED}Last 5 errors:${NC}"
        grep "\[ERROR\]" "${LOG_DIR}/mediamtx-monitor.log" | tail -n 5
    fi
    
    # Show most recent log entries
    echo -e "\n${YELLOW}Most recent log entries:${NC}"
    tail -n 8 "${LOG_DIR}/mediamtx-monitor.log"
else
    echo -e "${YELLOW}No log file found${NC}"
fi

# System resource usage
echo
echo -e "${YELLOW}System Resource Usage:${NC}"
echo -e "Memory: $(free -h | grep Mem | awk '{print $3 "/" $2}')"
echo -e "CPU Load: $(uptime | awk -F'load average: ' '{print $2}')"
echo -e "Disk Usage: $(df -h /var/log | tail -n 1 | awk '{print $5 " used"}')"

# Help info
echo
echo -e "${BLUE}===============================================${NC}"
echo -e "${YELLOW}Useful Commands:${NC}"
echo -e "Start monitor:    ${GREEN}sudo systemctl start mediamtx-monitor${NC}"
echo -e "Stop monitor:     ${GREEN}sudo systemctl stop mediamtx-monitor${NC}"
echo -e "View logs:        ${GREEN}sudo tail -f $LOG_DIR/mediamtx-monitor.log${NC}"
echo -e "Edit config:      ${GREEN}sudo nano $CONFIG_DIR/config${NC}"
echo -e "==============================================="
EOF
    
    # Set permissions
    chmod 755 "$script_path"
    
    log "INFO" "Status check script created at $script_path"
    return 0
}

# Enable and start the service
enable_and_start_service() {
    log "INFO" "Enabling and starting the monitoring service..."
    
    # Enable the service to start at boot
    systemctl enable mediamtx-monitor.service
    
    # Start the service
    if systemctl start mediamtx-monitor.service; then
        log "INFO" "Service started successfully"
        
        # Wait a few seconds to see if the service stays running
        sleep 5
        
        if systemctl is-active --quiet mediamtx-monitor.service; then
            log "INFO" "Service is running properly"
            return 0
        else
            log "ERROR" "Service failed to stay running"
            echo -e "${RED}Service started but failed to stay running. Check logs for details:${NC}"
            echo -e "${YELLOW}$ sudo journalctl -u mediamtx-monitor.service -n 20${NC}"
            return 1
        fi
    else
        log "ERROR" "Failed to start service"
        echo -e "${RED}Failed to start the monitoring service. Check logs for details:${NC}"
        echo -e "${YELLOW}$ sudo journalctl -u mediamtx-monitor.service -n 20${NC}"
        return 1
    fi
}

# Main installation process
main() {
    # Check dependencies
    if ! check_dependencies; then
        log "ERROR" "Failed to check or install dependencies"
        echo -e "${RED}Failed to check or install dependencies. See log for details.${NC}"
        exit 1
    fi
    
    # Create configuration
    if ! create_config; then
        log "ERROR" "Failed to create configuration"
        echo -e "${RED}Failed to create configuration. See log for details.${NC}"
        exit 1
    fi
    
    # Install monitor script
    if ! install_monitor_script; then
        log "ERROR" "Failed to install monitor script"
        echo -e "${RED}Failed to install monitor script. See log for details.${NC}"
        exit 1
    fi
    
    # Create systemd service
    if ! create_systemd_service; then
        log "ERROR" "Failed to create systemd service"
        echo -e "${RED}Failed to create systemd service. See log for details.${NC}"
        exit 1
    fi
    
    # Create status check script
    if ! create_status_script; then
        log "ERROR" "Failed to create status check script"
        echo -e "${RED}Failed to create status check script. See log for details.${NC}"
        exit 1
    fi
    
    # Ask if user wants to start the service now
    echo
    echo -e "${YELLOW}Enable and start the monitoring service now? (Y/n) [default: Y]${NC}"
    read -t 10 -r start_service || start_service="y"
    
    if [[ ! "$start_service" =~ ^[Nn]$ ]]; then
        if ! enable_and_start_service; then
            log "WARNING" "Service setup completed with warnings"
            echo -e "${YELLOW}Installation completed with warnings.${NC}"
            exit 1
        fi
    else
        log "INFO" "Service not started automatically"
        echo -e "${YELLOW}Service not started. You can start it manually with:${NC}"
        echo -e "${GREEN}$ sudo systemctl start mediamtx-monitor.service${NC}"
    fi
    
    # Installation complete
    log "INFO" "Installation completed successfully"
    echo
    echo -e "${GREEN}===============================================${NC}"
    echo -e "${GREEN}   MediaMTX Monitor installed successfully!   ${NC}"
    echo -e "${GREEN}===============================================${NC}"
    echo
    echo -e "Configuration file: ${BLUE}$CONFIG_DIR/config${NC}"
    echo -e "Log directory: ${BLUE}$LOG_DIR${NC}"
    echo -e "Monitor script: ${BLUE}/usr/local/bin/mediamtx-monitor.sh${NC}"
    echo -e "Status check: ${BLUE}/usr/local/bin/check-mediamtx-monitor.sh${NC}"
    echo
    echo -e "To check status: ${YELLOW}sudo check-mediamtx-monitor.sh${NC}"
    echo -e "To view logs: ${YELLOW}sudo tail -f $LOG_DIR/mediamtx-monitor.log${NC}"
    echo -e "To edit config: ${YELLOW}sudo nano $CONFIG_DIR/config${NC}"
    echo
    
    return 0
}

# Run the main installation process
main

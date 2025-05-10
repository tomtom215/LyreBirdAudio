#!/bin/bash
# Complete MediaMTX Monitor Installation Script
# Version: 4.0.0
# Date: May 10, 2025
# Description: Installs a completely new version of the MediaMTX monitor
#              with combined CPU monitoring and robust error handling

# Set strict error handling
set -e
trap 'echo "Error occurred at line $LINENO. Command: $BASH_COMMAND"' ERR

# Define color codes for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration paths
MONITOR_SCRIPT="/usr/local/bin/enhanced-mediamtx-monitor.sh"
CONFIG_FILE="/etc/audio-rtsp/config"
STATUS_SCRIPT="/usr/local/bin/check-mediamtx-monitor.sh"
SERVICE_FILE="/etc/systemd/system/mediamtx-monitor.service"
BACKUP_DIR="/tmp/mediamtx-backup-$(date +%Y%m%d%H%M%S)"
LOG_DIR="/var/log/audio-rtsp"
LOG_FILE="${LOG_DIR}/monitor-install.log"

# Print to both console and log file
log() {
    local level=$1
    shift
    local message="$*"
    echo -e "${level}${message}${NC}" | tee -a "$LOG_FILE"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run as root${NC}"
    exit 1
fi

# Create backup directory and log directory
mkdir -p "$BACKUP_DIR" "$LOG_DIR"
touch "$LOG_FILE"

echo "=== MediaMTX Monitor Installation Log $(date) ===" > "$LOG_FILE"
log "${BLUE}" "MediaMTX Monitor Installation v4.0.0"
log "${GREEN}" "Installing new enhanced MediaMTX monitor with combined CPU monitoring"

# Backup existing files
log "${YELLOW}" "Creating backups of existing files..."
if [ -f "$MONITOR_SCRIPT" ]; then
    cp -f "$MONITOR_SCRIPT" "$BACKUP_DIR/$(basename "$MONITOR_SCRIPT")"
    log "${GREEN}" "Backed up monitor script"
fi

if [ -f "$STATUS_SCRIPT" ]; then
    cp -f "$STATUS_SCRIPT" "$BACKUP_DIR/$(basename "$STATUS_SCRIPT")"
    log "${GREEN}" "Backed up status script"
fi

if [ -f "$CONFIG_FILE" ]; then
    cp -f "$CONFIG_FILE" "$BACKUP_DIR/$(basename "$CONFIG_FILE")"
    log "${GREEN}" "Backed up config file"
fi

if [ -f "$SERVICE_FILE" ]; then
    cp -f "$SERVICE_FILE" "$BACKUP_DIR/$(basename "$SERVICE_FILE")"
    log "${GREEN}" "Backed up service file"
fi

log "${GREEN}" "All files backed up to $BACKUP_DIR"

# Stop the service if it's running
log "${YELLOW}" "Stopping existing service if running..."
systemctl stop mediamtx-monitor.service 2>/dev/null || true
sleep 2

# Load existing configuration values if available
log "${YELLOW}" "Loading existing configuration values..."
if [ -f "$CONFIG_FILE" ]; then
    # Extract key settings from existing config
    RTSP_PORT=$(grep -o "RTSP_PORT=[0-9]\+" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "18554")
    CPU_THRESHOLD=$(grep -o "MEDIAMTX_CPU_THRESHOLD=[0-9]\+" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "80")
    MEMORY_THRESHOLD=$(grep -o "MEDIAMTX_MEMORY_THRESHOLD=[0-9]\+" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "15")
    MAX_UPTIME=$(grep -o "MEDIAMTX_MAX_UPTIME=[0-9]\+" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "86400")
    
    # Check if combined CPU settings exist
    COMBINED_CPU_THRESHOLD=$(grep -o "MEDIAMTX_COMBINED_CPU_THRESHOLD=[0-9]\+" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "200")
    COMBINED_CPU_WARNING=$(grep -o "MEDIAMTX_COMBINED_CPU_WARNING_THRESHOLD=[0-9]\+" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "150")
    
    # Get MediaMTX path and name
    MEDIAMTX_PATH=$(grep -o "MEDIAMTX_PATH=[^ ]\+" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "/usr/local/mediamtx/mediamtx")
    MEDIAMTX_NAME=$(grep -o "MEDIAMTX_NAME=[^ ]\+" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "mediamtx")
    MEDIAMTX_SERVICE=$(grep -o "MEDIAMTX_SERVICE=[^ ]\+" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "mediamtx.service")
    
    # Get auto-reboot setting
    AUTO_REBOOT=$(grep -o "MEDIAMTX_ENABLE_AUTO_REBOOT=[a-z]\+" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 || echo "false")
    
    log "${GREEN}" "Loaded existing configuration values:"
    log "${GREEN}" "  RTSP Port: $RTSP_PORT"
    log "${GREEN}" "  CPU Threshold: $CPU_THRESHOLD%"
    log "${GREEN}" "  Memory Threshold: $MEMORY_THRESHOLD%"
    log "${GREEN}" "  Combined CPU Threshold: $COMBINED_CPU_THRESHOLD%"
    log "${GREEN}" "  Auto-Reboot: $AUTO_REBOOT"
else
    # Default values
    RTSP_PORT="18554"
    CPU_THRESHOLD="80"
    MEMORY_THRESHOLD="15"
    MAX_UPTIME="86400"
    COMBINED_CPU_THRESHOLD="200"
    COMBINED_CPU_WARNING="150"
    MEDIAMTX_PATH="/usr/local/mediamtx/mediamtx"
    MEDIAMTX_NAME="mediamtx"
    MEDIAMTX_SERVICE="mediamtx.service"
    AUTO_REBOOT="false"
    
    log "${YELLOW}" "No existing configuration found, using default values"
fi

# Create or update configuration file
log "${YELLOW}" "Creating updated configuration file..."
mkdir -p "$(dirname "$CONFIG_FILE")"

cat > "$CONFIG_FILE" << EOF
# Audio RTSP Streaming Service Configuration
# Modified by MediaMTX Monitor Installation Script v4.0.0
# Date: $(date)

# RTSP server port
RTSP_PORT=$RTSP_PORT

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
# ----------------------------------------------------------------------
# CPU threshold in percentage - restart if exceeded for MEDIAMTX_CPU_SUSTAINED_PERIODS
MEDIAMTX_CPU_THRESHOLD=$CPU_THRESHOLD

# Warning threshold for CPU (notifications sent at this level)
MEDIAMTX_CPU_WARNING_THRESHOLD=$((CPU_THRESHOLD - 10))

# Number of consecutive periods CPU must be high before restart
MEDIAMTX_CPU_SUSTAINED_PERIODS=3

# Number of periods to analyze for resource usage trends
MEDIAMTX_CPU_TREND_PERIODS=10

# How often to check CPU usage (in seconds)
MEDIAMTX_CPU_CHECK_INTERVAL=60

# Memory threshold in percentage - restart if exceeded
MEDIAMTX_MEMORY_THRESHOLD=$MEMORY_THRESHOLD

# Warning threshold for memory
MEDIAMTX_MEMORY_WARNING_THRESHOLD=$((MEMORY_THRESHOLD - 3))

# Maximum uptime in seconds - force restart after this time
# Default: 86400 (24 hours)
MEDIAMTX_MAX_UPTIME=$MAX_UPTIME

# Path to MediaMTX executable
MEDIAMTX_PATH=$MEDIAMTX_PATH

# MediaMTX process name for monitoring
MEDIAMTX_NAME=$MEDIAMTX_NAME

# MediaMTX systemd service name (if using systemd)
MEDIAMTX_SERVICE=$MEDIAMTX_SERVICE

# Maximum restart attempts before considering more drastic measures
MEDIAMTX_MAX_RESTART_ATTEMPTS=5

# Cooldown period between restarts (seconds)
MEDIAMTX_RESTART_COOLDOWN=300

# Number of failed recovery attempts before considering reboot
MEDIAMTX_REBOOT_THRESHOLD=3

# Whether to enable automatic reboots (true/false)
MEDIAMTX_ENABLE_AUTO_REBOOT=$AUTO_REBOOT

# Cooldown period before allowing reboot (seconds)
MEDIAMTX_REBOOT_COOLDOWN=1800

# Emergency threshold for immediate action (CPU percentage)
MEDIAMTX_EMERGENCY_CPU_THRESHOLD=95

# Emergency threshold for memory
MEDIAMTX_EMERGENCY_MEMORY_THRESHOLD=20

# File descriptor threshold - restart if exceeded
MEDIAMTX_FILE_DESCRIPTOR_THRESHOLD=1000

# Combined CPU threshold (MediaMTX + ffmpeg processes)
MEDIAMTX_COMBINED_CPU_THRESHOLD=$COMBINED_CPU_THRESHOLD

# Combined CPU warning threshold
MEDIAMTX_COMBINED_CPU_WARNING_THRESHOLD=$COMBINED_CPU_WARNING
EOF

log "${GREEN}" "Configuration file created successfully"

# Create new monitor script
log "${YELLOW}" "Creating new monitor script..."

cat > "$MONITOR_SCRIPT" << 'EOF'
#!/bin/bash
# Enhanced MediaMTX Resource Monitor - Production Grade
# Version: 4.0.0
# Date: May 10, 2025
# Description: Advanced monitoring and automatic recovery for MediaMTX with trend analysis
#              and progressive recovery strategies to prevent system-wide failures
#              Includes combined CPU monitoring of MediaMTX and related ffmpeg processes

# Set strict error handling
set -o pipefail
trap 'echo "Error at line $LINENO: Command \"$BASH_COMMAND\" failed with status $?"' ERR

# Define color codes for better visibility (for interactive use)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configurable parameters - these will be overridden by config file if present
CONFIG_DIR="/etc/audio-rtsp"
CONFIG_FILE="${CONFIG_DIR}/config"
MEDIAMTX_PATH="/usr/local/mediamtx/mediamtx"
MEDIAMTX_NAME="mediamtx"
MEDIAMTX_SERVICE="mediamtx.service"
RTSP_PORT="18554"
LOG_DIR="/var/log/audio-rtsp"
MONITOR_LOG="${LOG_DIR}/mediamtx-monitor.log"
RECOVERY_LOG="${LOG_DIR}/recovery-actions.log"
STATE_DIR="${LOG_DIR}/state"
STATS_DIR="${LOG_DIR}/stats"

# Resource thresholds and monitoring parameters
CPU_THRESHOLD=80              # Restart MediaMTX if CPU exceeds this percentage
CPU_WARNING_THRESHOLD=70      # Warning level for CPU
CPU_SUSTAINED_PERIODS=3       # Number of consecutive periods CPU must be high
CPU_TREND_PERIODS=10          # Number of periods to analyze for trending
CPU_CHECK_INTERVAL=60         # Check CPU every X seconds
MEMORY_THRESHOLD=15           # Percentage of system memory
MEMORY_WARNING_THRESHOLD=12   # Warning level for memory
MAX_UPTIME=86400              # Force restart after 24 hours (86400 seconds)
MAX_RESTART_ATTEMPTS=5        # Maximum number of restart attempts before escalation
RESTART_COOLDOWN=300          # Cooldown period between restarts (5 minutes)
REBOOT_THRESHOLD=3            # Number of failed recovery attempts before considering reboot
ENABLE_AUTO_REBOOT=false      # Whether to allow automatic reboots (use with caution)
REBOOT_COOLDOWN=1800          # Cooldown before reboot (30 minutes)
EMERGENCY_CPU_THRESHOLD=95    # Emergency CPU threshold for immediate action
EMERGENCY_MEMORY_THRESHOLD=20 # Emergency memory threshold for immediate action
FILE_DESCRIPTOR_THRESHOLD=1000 # Maximum allowed open files before taking action
COMBINED_CPU_THRESHOLD=200    # Combined CPU threshold (MediaMTX + ffmpeg processes)
COMBINED_CPU_WARNING=150      # Warning threshold for combined CPU

# State tracking variables
recovery_level=0
last_restart_time=0
restart_attempts_count=0
last_reboot_time=0
last_resource_warning=0
consecutive_failed_restarts=0

# Initialize directories with appropriate permissions
mkdir -p "$LOG_DIR" "$STATE_DIR" "$STATS_DIR" 2>/dev/null
touch "$MONITOR_LOG" "$RECOVERY_LOG" 2>/dev/null
chmod 755 "$LOG_DIR" "$STATE_DIR" "$STATS_DIR" 2>/dev/null
chmod 644 "$MONITOR_LOG" "$RECOVERY_LOG" 2>/dev/null

# Load configuration if available
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    
    # Override defaults with config file values if they exist
    # CPU settings
    if [ -n "$MEDIAMTX_CPU_THRESHOLD" ]; then
        CPU_THRESHOLD=$MEDIAMTX_CPU_THRESHOLD
    fi
    if [ -n "$MEDIAMTX_CPU_WARNING_THRESHOLD" ]; then
        CPU_WARNING_THRESHOLD=$MEDIAMTX_CPU_WARNING_THRESHOLD
    else
        # Set warning threshold to 10% below critical if not explicitly defined
        CPU_WARNING_THRESHOLD=$((CPU_THRESHOLD - 10))
        if [ "$CPU_WARNING_THRESHOLD" -lt 50 ]; then
            CPU_WARNING_THRESHOLD=50
        fi
    fi
    if [ -n "$MEDIAMTX_CPU_SUSTAINED_PERIODS" ]; then
        CPU_SUSTAINED_PERIODS=$MEDIAMTX_CPU_SUSTAINED_PERIODS
    fi
    if [ -n "$MEDIAMTX_CPU_CHECK_INTERVAL" ]; then
        CPU_CHECK_INTERVAL=$MEDIAMTX_CPU_CHECK_INTERVAL
    fi
    if [ -n "$MEDIAMTX_CPU_TREND_PERIODS" ]; then
        CPU_TREND_PERIODS=$MEDIAMTX_CPU_TREND_PERIODS
    fi
    
    # Memory settings
    if [ -n "$MEDIAMTX_MEMORY_THRESHOLD" ]; then
        MEMORY_THRESHOLD=$MEDIAMTX_MEMORY_THRESHOLD
    fi
    if [ -n "$MEDIAMTX_MEMORY_WARNING_THRESHOLD" ]; then
        MEMORY_WARNING_THRESHOLD=$MEDIAMTX_MEMORY_WARNING_THRESHOLD
    else
        # Set warning threshold to 20% below critical if not explicitly defined
        MEMORY_WARNING_THRESHOLD=$((MEMORY_THRESHOLD - 3))
        if [ "$MEMORY_WARNING_THRESHOLD" -lt 5 ]; then
            MEMORY_WARNING_THRESHOLD=5
        fi
    fi
    
    # Uptime settings
    if [ -n "$MEDIAMTX_MAX_UPTIME" ]; then
        MAX_UPTIME=$MEDIAMTX_MAX_UPTIME
    fi
    
    # Path settings
    if [ -n "$MEDIAMTX_PATH" ]; then
        MEDIAMTX_PATH=$MEDIAMTX_PATH
    fi
    if [ -n "$MEDIAMTX_NAME" ]; then
        MEDIAMTX_NAME=$MEDIAMTX_NAME
    fi
    if [ -n "$MEDIAMTX_SERVICE" ]; then
        MEDIAMTX_SERVICE=$MEDIAMTX_SERVICE
    fi
    
    # Recovery settings
    if [ -n "$MEDIAMTX_MAX_RESTART_ATTEMPTS" ]; then
        MAX_RESTART_ATTEMPTS=$MEDIAMTX_MAX_RESTART_ATTEMPTS
    fi
    if [ -n "$MEDIAMTX_RESTART_COOLDOWN" ]; then
        RESTART_COOLDOWN=$MEDIAMTX_RESTART_COOLDOWN
    fi
    if [ -n "$MEDIAMTX_REBOOT_THRESHOLD" ]; then
        REBOOT_THRESHOLD=$MEDIAMTX_REBOOT_THRESHOLD
    fi
    if [ -n "$MEDIAMTX_ENABLE_AUTO_REBOOT" ]; then
        ENABLE_AUTO_REBOOT=$MEDIAMTX_ENABLE_AUTO_REBOOT
    fi
    if [ -n "$MEDIAMTX_REBOOT_COOLDOWN" ]; then
        REBOOT_COOLDOWN=$MEDIAMTX_REBOOT_COOLDOWN
    fi
    if [ -n "$MEDIAMTX_EMERGENCY_CPU_THRESHOLD" ]; then
        EMERGENCY_CPU_THRESHOLD=$MEDIAMTX_EMERGENCY_CPU_THRESHOLD
    fi
    if [ -n "$MEDIAMTX_EMERGENCY_MEMORY_THRESHOLD" ]; then
        EMERGENCY_MEMORY_THRESHOLD=$MEDIAMTX_EMERGENCY_MEMORY_THRESHOLD
    fi
    if [ -n "$MEDIAMTX_FILE_DESCRIPTOR_THRESHOLD" ]; then
        FILE_DESCRIPTOR_THRESHOLD=$MEDIAMTX_FILE_DESCRIPTOR_THRESHOLD
    fi
    
    # Combined CPU settings
    if [ -n "$MEDIAMTX_COMBINED_CPU_THRESHOLD" ]; then
        COMBINED_CPU_THRESHOLD=$MEDIAMTX_COMBINED_CPU_THRESHOLD
    fi
    if [ -n "$MEDIAMTX_COMBINED_CPU_WARNING_THRESHOLD" ]; then
        COMBINED_CPU_WARNING=$MEDIAMTX_COMBINED_CPU_WARNING_THRESHOLD
    fi
fi

# Function for logging with timestamps and levels
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Always write to log file
    echo "[$timestamp] [$level] $message" >> "$MONITOR_LOG"
    
    # If it's a recovery action, also log to the recovery log
    if [[ "$level" == "RECOVERY" || "$level" == "REBOOT" ]]; then
        echo "[$timestamp] [$level] $message" >> "$RECOVERY_LOG"
    fi
    
    # If running in terminal, also output to stdout with colors
    if [ -t 1 ]; then
        case "$level" in
            "INFO")
                echo -e "${GREEN}[$timestamp] [$level]${NC} $message"
                ;;
            "WARNING")
                echo -e "${YELLOW}[$timestamp] [$level]${NC} $message"
                ;;
            "ERROR")
                echo -e "${RED}[$timestamp] [$level]${NC} $message"
                ;;
            "RECOVERY")
                echo -e "${BLUE}[$timestamp] [$level]${NC} $message"
                ;;
            "REBOOT")
                echo -e "${RED}[$timestamp] [$level]${NC} $message"
                ;;
            *)
                echo -e "[$timestamp] [$level] $message"
                ;;
        esac
    fi
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if we can use systemctl to manage MediaMTX
uses_systemd=false
if command_exists systemctl; then
    if systemctl list-unit-files | grep -q "$MEDIAMTX_SERVICE"; then
        uses_systemd=true
    fi
fi

# Function to check if audio-rtsp service is running
is_audio_rtsp_running() {
    if [ "$uses_systemd" = true ]; then
        if systemctl is-active --quiet audio-rtsp.service; then
            return 0  # Service is running
        else
            return 1  # Service is not running
        fi
    else
        # Fallback method if systemd is not used
        if pgrep -f "startmic.sh" >/dev/null 2>&1; then
            return 0  # Process is running
        else
            return 1  # Process is not running
        fi
    fi
}

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
    if [ -z "$pid" ] || ! ps -p "$pid" >/dev/null 2>&1; then
        echo "0"
        return
    fi
    
    local start_time
    local elapsed_seconds=0
    
    # Try different methods to get process start time
    if [ -f "/proc/$pid/stat" ]; then
        # Method 1: Using /proc/pid/stat and system uptime
        local proc_stat_data
        local btime
        local uptime_seconds
        
        proc_stat_data=$(cat "/proc/$pid/stat" 2>/dev/null)
        if [ $? -eq 0 ]; then
            # Extract the start time (in clock ticks since boot)
            local starttime
            starttime=$(echo "$proc_stat_data" | awk '{print $22}')
            
            # Get boot time
            btime=$(grep btime /proc/stat 2>/dev/null | awk '{print $2}')
            
            # Get system uptime in seconds
            uptime_seconds=$(cat /proc/uptime 2>/dev/null | awk '{print $1}' | cut -d. -f1)
            
            if [[ -n "$starttime" && -n "$btime" && -n "$uptime_seconds" ]]; then
                # Calculate process uptime in seconds (clock ticks to seconds conversion)
                local clk_tck
                clk_tck=$(getconf CLK_TCK 2>/dev/null || echo 100)  # Default to 100 if getconf fails
                elapsed_seconds=$((uptime_seconds - (starttime / clk_tck)))
            fi
        fi
    fi
    
    # Method 2: Using ps command
    if [ "$elapsed_seconds" -eq 0 ]; then
        local ps_start_time
        ps_start_time=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
        if [[ -n "$ps_start_time" && "$ps_start_time" =~ ^[0-9]+$ ]]; then
            elapsed_seconds=$ps_start_time
        fi
    fi
    
    # If both methods fail, try to get time from state file
    if [ "$elapsed_seconds" -eq 0 ]; then
        local state_file="${STATE_DIR}/mediamtx_start_time"
        if [ -f "$state_file" ]; then
            local stored_start_time
            stored_start_time=$(cat "$state_file" 2>/dev/null)
            local current_time
            current_time=$(date +%s)
            if [[ -n "$stored_start_time" && "$stored_start_time" =~ ^[0-9]+$ ]]; then
                elapsed_seconds=$((current_time - stored_start_time))
            fi
        fi
    fi
    
    echo "$elapsed_seconds"
}

# Function to get MediaMTX CPU usage percentage with improved accuracy
get_mediamtx_cpu() {
    local pid=$1
    local cpu_usage=0
    
    if [ -z "$pid" ] || ! ps -p "$pid" >/dev/null 2>&1; then
        echo "0"
        return
    fi
    
    # Method 1: Use top for more accurate measurement
    local top_output
    top_output=$(COLUMNS=512 top -b -n 2 -d 0.2 -p "$pid" 2>/dev/null | tail -1)
    if [ $? -eq 0 ]; then
        cpu_usage=$(echo "$top_output" | awk '{print $9}')
        # Remove decimal places if present
        cpu_usage=${cpu_usage%%.*}
    fi
    
    # Method 2: Fall back to ps if top fails
    if [[ -z "$cpu_usage" || ! "$cpu_usage" =~ ^[0-9]+$ ]]; then
        cpu_usage=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
        # Remove decimal places if present
        cpu_usage=${cpu_usage%%.*}
    fi
    
    # Ensure we have a valid number
    if [[ ! "$cpu_usage" =~ ^[0-9]+$ ]]; then
        cpu_usage=0
    fi
    
    echo "$cpu_usage"
}

# Function to get MediaMTX memory usage percentage
get_mediamtx_memory() {
    local pid=$1
    local memory_percentage=0
    
    if [ -z "$pid" ] || ! ps -p "$pid" >/dev/null 2>&1; then
        echo "0"
        return
    fi
    
    # Method 1: Use ps for memory percentage
    memory_percentage=$(ps -p "$pid" -o %mem= 2>/dev/null | tr -d ' ')
    
    # Method 2: Calculate manually if ps fails
    if [[ -z "$memory_percentage" || ! "$memory_percentage" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        if [ -f "/proc/$pid/status" ]; then
            # Get VmRSS (Resident Set Size) from proc
            local vm_rss
            vm_rss=$(grep VmRSS /proc/"$pid"/status 2>/dev/null | awk '{print $2}')
            
            # Get total system memory
            local total_mem
            total_mem=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
            
            if [[ -n "$vm_rss" && -n "$total_mem" && "$total_mem" -gt 0 ]]; then
                # Calculate percentage
                memory_percentage=$(echo "scale=2; ($vm_rss / $total_mem) * 100" | bc)
                # Get just the integer part
                memory_percentage=${memory_percentage%%.*}
            fi
        fi
    fi
    
    # Remove decimal places if present
    memory_percentage=${memory_percentage%%.*}
    
    # Ensure we have a valid number
    if [[ ! "$memory_percentage" =~ ^[0-9]+$ ]]; then
        memory_percentage=0
    fi
    
    echo "$memory_percentage"
}

# Function to get the number of open file descriptors for MediaMTX
get_mediamtx_file_descriptors() {
    local pid=$1
    local fd_count=0
    
    if [ -z "$pid" ] || ! ps -p "$pid" >/dev/null 2>&1; then
        echo "0"
        return
    fi
    
    # Count open files in /proc/PID/fd if available
    if [ -d "/proc/$pid/fd" ]; then
        fd_count=$(ls -la /proc/"$pid"/fd 2>/dev/null | wc -l)
        # Subtract 3 to account for ., .., and the count command itself
        fd_count=$((fd_count - 3))
        if [ "$fd_count" -lt 0 ]; then
            fd_count=0
        fi
    fi
    
    # Fallback: use lsof if /proc method fails
    if [ "$fd_count" -eq 0 ] && command_exists lsof; then
        fd_count=$(lsof -p "$pid" 2>/dev/null | wc -l)
        # Subtract 1 to account for the header line
        fd_count=$((fd_count - 1))
        if [ "$fd_count" -lt 0 ]; then
            fd_count=0
        fi
    fi
    
    echo "$fd_count"
}

# Function to get combined CPU usage of MediaMTX and related processes
get_combined_cpu_usage() {
    local mediamtx_pid=$1
    local total_cpu=0
    local mediamtx_cpu=0
    local ffmpeg_cpu=0
    
    # Get MediaMTX CPU usage
    if [ -n "$mediamtx_pid" ] && ps -p "$mediamtx_pid" >/dev/null 2>&1; then
        mediamtx_cpu=$(get_mediamtx_cpu "$mediamtx_pid")
        total_cpu=$mediamtx_cpu
    fi
    
    # Get all ffmpeg processes streaming to RTSP
    local ffmpeg_pids
    ffmpeg_pids=$(pgrep -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" 2>/dev/null)
    
    if [ -n "$ffmpeg_pids" ]; then
        # Count the number of ffmpeg processes
        local ffmpeg_count
        ffmpeg_count=$(echo "$ffmpeg_pids" | wc -l)
        
        # Use top to get CPU usage for all ffmpeg processes in one call
        local top_output
        top_output=$(COLUMNS=512 top -b -n 2 -d 0.2 | grep -E "ffmpeg.*rtsp" | awk '{sum+=$9} END {print sum}')
        
        if [ -n "$top_output" ] && [[ "$top_output" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            ffmpeg_cpu=${top_output%%.*}
            total_cpu=$((total_cpu + ffmpeg_cpu))
        else
            # Fallback: iterate through each process and sum CPU usage
            for pid in $ffmpeg_pids; do
                local proc_cpu
                proc_cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
                proc_cpu=${proc_cpu%%.*}
                
                if [[ "$proc_cpu" =~ ^[0-9]+$ ]]; then
                    ffmpeg_cpu=$((ffmpeg_cpu + proc_cpu))
                fi
            done
            total_cpu=$((total_cpu + ffmpeg_cpu))
        fi
        
        # Store the component values for reference
        echo "$mediamtx_cpu" > "${STATE_DIR}/mediamtx_cpu"
        echo "$ffmpeg_cpu" > "${STATE_DIR}/ffmpeg_cpu"
        echo "$ffmpeg_count" > "${STATE_DIR}/ffmpeg_count"
    fi
    
    echo "$total_cpu"
}

# Function to check for network issues
check_network_health() {
    # Check if RTSP port is accessible
    if ! nc -z localhost "$RTSP_PORT" >/dev/null 2>&1; then
        log "WARNING" "RTSP port $RTSP_PORT is not accessible"
        return 1
    fi
    
    # Check for established connections to MediaMTX
    local established_count
    established_count=$(netstat -tn 2>/dev/null | grep ":$RTSP_PORT" | grep ESTABLISHED | wc -l)
    
    # If there are many connections but no recent activity, it might be an issue
    if [ "$established_count" -gt 20 ]; then
        log "WARNING" "High number of established connections ($established_count) to RTSP port"
    fi
    
    return 0
}

# Function to analyze resource usage trends
analyze_trends() {
    local cpu_file="${STATS_DIR}/cpu_history.txt"
    local mem_file="${STATS_DIR}/mem_history.txt"
    local current_cpu=$1
    local current_mem=$2
    
    # Create files if they don't exist
    touch "$cpu_file" "$mem_file"
    
    # Add current values to history files
    echo "$current_cpu" >> "$cpu_file"
    echo "$current_mem" >> "$mem_file"
    
    # Trim history files to keep only the last CPU_TREND_PERIODS values
    if [ "$(wc -l < "$cpu_file")" -gt "$CPU_TREND_PERIODS" ]; then
        tail -n "$CPU_TREND_PERIODS" "$cpu_file" > "${cpu_file}.tmp" && mv "${cpu_file}.tmp" "$cpu_file"
    fi
    if [ "$(wc -l < "$mem_file")" -gt "$CPU_TREND_PERIODS" ]; then
        tail -n "$CPU_TREND_PERIODS" "$mem_file" > "${mem_file}.tmp" && mv "${mem_file}.tmp" "$mem_file"
    fi
    
    # Analyze CPU trend - this is a simple but effective approach
    local cpu_trend=0
    local cpu_data
    cpu_data=$(cat "$cpu_file")
    
    if [ "$(wc -l < "$cpu_file")" -ge 3 ]; then
        # Check for consistently increasing CPU usage over the last 3 samples
        local cpu_sample_1 cpu_sample_2 cpu_sample_3
        cpu_sample_1=$(echo "$cpu_data" | tail -n 3 | head -n 1)
        cpu_sample_2=$(echo "$cpu_data" | tail -n 2 | head -n 1)
        cpu_sample_3=$(echo "$cpu_data" | tail -n 1)
        
        if [[ "$cpu_sample_1" -lt "$cpu_sample_2" && "$cpu_sample_2" -lt "$cpu_sample_3" ]]; then
            # Calculate the rate of increase
            local increase_rate=$(( (cpu_sample_3 - cpu_sample_1) / 2 ))
            cpu_trend=$increase_rate
            
            if [ "$increase_rate" -gt 5 ]; then
                log "WARNING" "CPU usage is trending upward rapidly (rate: +${increase_rate}% per period)"
                return 1
            elif [ "$increase_rate" -gt 2 ]; then
                log "INFO" "CPU usage is trending upward (rate: +${increase_rate}% per period)"
            fi
        fi
    fi
    
    # Similar analysis could be done for memory, but CPU is often the critical factor for MediaMTX
    
    return 0
}

# Function to clean up before MediaMTX restart
cleanup_before_restart() {
    local pid=$1
    local force_kill=$2
    local stale_procs=()
    local cleanup_status=0
    
    log "INFO" "Cleaning up before MediaMTX restart..."
    
    # Find all child processes of the MediaMTX process
    if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
        # Get all child process IDs
        local child_pids
        child_pids=$(pstree -p "$pid" 2>/dev/null | grep -o '([0-9]\+)' | tr -d '()')
        
        if [ -n "$child_pids" ]; then
            log "INFO" "Found child processes of MediaMTX: $child_pids"
            
            # Gracefully terminate child processes first
            for child_pid in $child_pids; do
                if [ "$child_pid" != "$pid" ] && ps -p "$child_pid" >/dev/null 2>&1; then
                    log "INFO" "Sending SIGTERM to child process $child_pid"
                    kill -15 "$child_pid" >/dev/null 2>&1
                    stale_procs+=("$child_pid")
                fi
            done
        fi
    fi
    
    # Terminate any processes accessing the MediaMTX files (like lsof)
    if command_exists lsof && [ -x "$MEDIAMTX_PATH" ]; then
        local locking_pids
        locking_pids=$(lsof "$MEDIAMTX_PATH" 2>/dev/null | grep -v "^COMMAND" | awk '{print $2}' | sort -u)
        
        if [ -n "$locking_pids" ]; then
            log "INFO" "Found processes locking MediaMTX executable: $locking_pids"
            
            for lock_pid in $locking_pids; do
                if [ "$lock_pid" != "$$" ] && ps -p "$lock_pid" >/dev/null 2>&1; then
                    log "INFO" "Sending SIGTERM to locking process $lock_pid"
                    kill -15 "$lock_pid" >/dev/null 2>&1
                    stale_procs+=("$lock_pid")
                fi
            done
        fi
    fi
    
    # Find and terminate any zombie or defunct processes related to MediaMTX
    local zombie_pids
    zombie_pids=$(ps aux | grep "$MEDIAMTX_NAME" | grep "<defunct>" | awk '{print $2}')
    
    if [ -n "$zombie_pids" ]; then
        log "INFO" "Found zombie MediaMTX processes: $zombie_pids"
        
        for zombie_pid in $zombie_pids; do
            if ps -p "$zombie_pid" >/dev/null 2>&1; then
                log "INFO" "Sending SIGKILL to zombie process $zombie_pid"
                kill -9 "$zombie_pid" >/dev/null 2>&1
            fi
        done
    fi
    
    # Wait for a short time to allow processes to terminate
    sleep 2
    
    # Force kill any remaining stale processes if needed
    if [ "$force_kill" = true ] && [ ${#stale_procs[@]} -gt 0 ]; then
        for stale_pid in "${stale_procs[@]}"; do
            if ps -p "$stale_pid" >/dev/null 2>&1; then
                log "WARNING" "Process $stale_pid still running, sending SIGKILL"
                kill -9 "$stale_pid" >/dev/null 2>&1
                
                # Check if the kill was successful
                if ps -p "$stale_pid" >/dev/null 2>&1; then
                    log "ERROR" "Failed to kill process $stale_pid"
                    cleanup_status=1
                fi
            fi
        done
    fi
    
    # Clean up any leftover socket files that might prevent restart
    local rtsp_sockets
    rtsp_sockets=$(find /tmp -type s -name "*rtsp*" 2>/dev/null)
    if [ -n "$rtsp_sockets" ]; then
        log "INFO" "Cleaning up RTSP socket files: $rtsp_sockets"
        # shellcheck disable=SC2086
        rm -f $rtsp_sockets 2>/dev/null
    fi
    
    return $cleanup_status
}

# Function to verify MediaMTX is fully operational after restart
verify_mediamtx_health() {
    local pid=$1
    local start_time
    start_time=$(date +%s)
    local max_wait=30  # Maximum time to wait in seconds
    local success=false
    
    if [ -z "$pid" ]; then
        pid=$(get_mediamtx_pid)
    fi
    
    if [ -z "$pid" ]; then
        log "ERROR" "MediaMTX process not found after restart"
        return 1
    fi
    
    log "INFO" "Verifying MediaMTX health after restart (PID: $pid)..."
    
    # Wait for the RTSP port to become accessible
    local port_check_count=0
    while [ $port_check_count -lt 10 ]; do
        if nc -z localhost "$RTSP_PORT" >/dev/null 2>&1; then
            log "INFO" "RTSP port $RTSP_PORT is now accessible"
            success=true
            break
        fi
        
        port_check_count=$((port_check_count + 1))
        
        # Check if we've waited too long
        local current_time
        current_time=$(date +%s)
        if [ $((current_time - start_time)) -gt "$max_wait" ]; then
            log "ERROR" "Timeout waiting for RTSP port to become accessible"
            break
        fi
        
        sleep 1
    done
    
    # Verify the process is stable (not consuming too much CPU right away)
    local initial_cpu
    initial_cpu=$(get_mediamtx_cpu "$pid")
    
    # Store the start time for future uptime calculations
    echo "$(date +%s)" > "${STATE_DIR}/mediamtx_start_time"
    
    if [ "$success" = true ] && [ "$initial_cpu" -lt "$CPU_WARNING_THRESHOLD" ]; then
        log "INFO" "MediaMTX appears to be healthy after restart"
        return 0
    else
        log "ERROR" "MediaMTX health check failed after restart"
        return 1
    fi
}

# Function to restart any affected ffmpeg processes
restart_ffmpeg_processes() {
    # Find all ffmpeg processes that were streaming to RTSP
    local rtsp_ffmpeg_cmds=()
    local active_ffmpeg_cmds=()
    local restart_count=0
    
    # Only do this if the audio-rtsp service is running
    if is_audio_rtsp_running; then
        log "INFO" "Restarting ffmpeg processes for RTSP streams..."
        
        # Restart the audio-rtsp service to recreate all streams
        if [ "$uses_systemd" = true ]; then
            log "INFO" "Restarting audio-rtsp service"
            systemctl restart audio-rtsp.service
            local restart_status=$?
            
            if [ $restart_status -eq 0 ]; then
                log "INFO" "Successfully restarted audio-rtsp service"
                return 0
            else
                log "ERROR" "Failed to restart audio-rtsp service (exit code: $restart_status)"
                return 1
            fi
        else
            # Non-systemd restart approach
            log "ERROR" "Non-systemd restart not implemented"
            return 1
        fi
    else
        log "INFO" "Audio-RTSP service is not running, no streams to restart"
        return 0
    fi
}

# Progressive recovery function with multiple levels of intervention
recover_mediamtx() {
    local reason="$1"
    local current_time
    current_time=$(date +%s)
    local force_restart=false
    
    # Check if we're in cooldown period after a recent restart
    if [ $((current_time - last_restart_time)) -lt "$RESTART_COOLDOWN" ]; then
        # Only allow force restarts to bypass cooldown
        if [ "$reason" != "FORCE" ] && [ "$reason" != "EMERGENCY" ]; then
            log "INFO" "In cooldown period, skipping restart"
            return 1
        else
            force_restart=true
            log "WARNING" "Force restart requested, bypassing cooldown"
        fi
    fi
    
    # Update restart attempt tracking
    if [ $((current_time - last_restart_time)) -gt "$RESTART_COOLDOWN" ]; then
        # Reset counter if we're outside the cooldown window
        restart_attempts_count=0
    fi
    restart_attempts_count=$((restart_attempts_count + 1))
    
    # Determine recovery level based on restart attempts
    if [ "$reason" = "EMERGENCY" ]; then
        # Emergency recovery jumps straight to level 3
        recovery_level=3
    elif [ "$force_restart" = true ]; then
        # Force restart uses level 2
        recovery_level=2
    elif [ "$restart_attempts_count" -ge "$MAX_RESTART_ATTEMPTS" ]; then
        # Max restart attempts reached, escalate to reboot consideration
        recovery_level=4
    else
        # Progressive escalation based on previous attempt
        recovery_level=$((recovery_level + 1))
        if [ "$recovery_level" -gt 3 ]; then
            recovery_level=3
        fi
    fi
    
    log "RECOVERY" "Initiating level $recovery_level recovery due to: $reason"
    
    # Get MediaMTX PID
    local mediamtx_pid
    mediamtx_pid=$(get_mediamtx_pid)
    
    # Store system state for debugging
    if [ -n "$mediamtx_pid" ]; then
        local state_file="${STATE_DIR}/state_before_restart_$(date +%Y%m%d%H%M%S).txt"
        {
            echo "Recovery Level: $recovery_level"
            echo "Reason: $reason"
            echo "Time: $(date)"
            echo "MediaMTX PID: $mediamtx_pid"
            echo "CPU Usage: $(get_mediamtx_cpu "$mediamtx_pid")%"
            echo "Memory Usage: $(get_mediamtx_memory "$mediamtx_pid")%"
            echo "Open Files: $(get_mediamtx_file_descriptors "$mediamtx_pid")"
            echo "Uptime: $(get_mediamtx_uptime "$mediamtx_pid") seconds"
            echo "System Load: $(cat /proc/loadavg 2>/dev/null || echo "N/A")"
            echo "---"
            echo "Process List:"
            ps aux | grep -E "$MEDIAMTX_NAME|ffmpeg.*rtsp" || echo "No processes found"
            echo "---"
            echo "Network Connections:"
            netstat -tnp 2>/dev/null | grep -E "$RTSP_PORT|$mediamtx_pid" || echo "No connections found"
        } > "$state_file" 2>&1
        log "INFO" "System state saved to $state_file"
    fi
    
    # Implement different recovery strategies based on level
    case $recovery_level in
        1)
            # Level 1: Basic restart through systemd (gentlest method)
            log "RECOVERY" "Level 1: Performing standard systemd restart"
            
            if [ "$uses_systemd" = true ]; then
                log "INFO" "Using systemd to restart MediaMTX service"
                systemctl restart "$MEDIAMTX_SERVICE"
                local restart_status=$?
                
                if [ $restart_status -eq 0 ]; then
                    log "INFO" "Standard restart completed successfully"
                else
                    log "ERROR" "Standard restart failed with exit code $restart_status"
                    consecutive_failed_restarts=$((consecutive_failed_restarts + 1))
                    return 1
                fi
            else
                # Fallback for non-systemd systems
                log "WARNING" "Systemd not detected, using fallback restart method"
                
                if [ -n "$mediamtx_pid" ]; then
                    kill -15 "$mediamtx_pid" 2>/dev/null
                    sleep 2
                    
                    # Check if process stopped
                    if ps -p "$mediamtx_pid" >/dev/null 2>&1; then
                        log "WARNING" "Process did not stop with SIGTERM, using SIGKILL"
                        kill -9 "$mediamtx_pid" 2>/dev/null
                        sleep 1
                    fi
                fi
                
                # Start MediaMTX
                if [ -x "$MEDIAMTX_PATH" ]; then
                    log "INFO" "Starting MediaMTX from $MEDIAMTX_PATH"
                    nohup "$MEDIAMTX_PATH" >/dev/null 2>&1 &
                else
                    log "ERROR" "MediaMTX executable not found or not executable: $MEDIAMTX_PATH"
                    consecutive_failed_restarts=$((consecutive_failed_restarts + 1))
                    return 1
                fi
            fi
            ;;
            
        2)
            # Level 2: Thorough restart with cleanup and verification
            log "RECOVERY" "Level 2: Performing thorough restart with cleanup"
            
            # Stop any ffmpeg RTSP processes first
            log "INFO" "Stopping ffmpeg RTSP processes"
            pkill -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" 2>/dev/null || true
            sleep 2
            
            # Clean up MediaMTX and related processes
            cleanup_before_restart "$mediamtx_pid" false
            
            # Restart the service
            if [ "$uses_systemd" = true ]; then
                log "INFO" "Using systemd to restart MediaMTX service"
                systemctl stop "$MEDIAMTX_SERVICE"
                sleep 2
                systemctl start "$MEDIAMTX_SERVICE"
                local restart_status=$?
                
                if [ $restart_status -ne 0 ]; then
                    log "ERROR" "Thorough restart failed with exit code $restart_status"
                    consecutive_failed_restarts=$((consecutive_failed_restarts + 1))
                    return 1
                fi
            else
                # Fallback for non-systemd systems
                log "WARNING" "Systemd not detected, using fallback restart method"
                
                if [ -n "$mediamtx_pid" ]; then
                    kill -15 "$mediamtx_pid" 2>/dev/null
                    sleep 3
                    
                    # Check if process stopped
                    if ps -p "$mediamtx_pid" >/dev/null 2>&1; then
                        log "WARNING" "Process did not stop with SIGTERM, using SIGKILL"
                        kill -9 "$mediamtx_pid" 2>/dev/null
                        sleep 2
                    fi
                fi
                
                # Start MediaMTX
                if [ -x "$MEDIAMTX_PATH" ]; then
                    log "INFO" "Starting MediaMTX from $MEDIAMTX_PATH"
                    nohup "$MEDIAMTX_PATH" >/dev/null 2>&1 &
                else
                    log "ERROR" "MediaMTX executable not found or not executable: $MEDIAMTX_PATH"
                    consecutive_failed_restarts=$((consecutive_failed_restarts + 1))
                    return 1
                fi
            fi
            
            # Wait for MediaMTX to initialize
            sleep 5
            
            # Get the new PID
            local new_pid
            new_pid=$(get_mediamtx_pid)
            
            # Verify MediaMTX is running properly
            if ! verify_mediamtx_health "$new_pid"; then
                log "ERROR" "MediaMTX failed health check after thorough restart"
                consecutive_failed_restarts=$((consecutive_failed_restarts + 1))
                return 1
            fi
            ;;
            
        3)
            # Level 3: Aggressive restart with force cleanup and service chain restart
            log "RECOVERY" "Level 3: Performing aggressive recovery with force cleanup"
            
            # Stop all related services
            if [ "$uses_systemd" = true ]; then
                # Stop audio-rtsp first if it's running
                if systemctl is-active --quiet audio-rtsp.service; then
                    log "INFO" "Stopping audio-rtsp service first"
                    systemctl stop audio-rtsp.service
                fi
                
                # Stop MediaMTX service
                log "INFO" "Stopping MediaMTX service"
                systemctl stop "$MEDIAMTX_SERVICE"
            else
                # Non-systemd approach
                log "INFO" "Stopping all related processes"
                pkill -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" 2>/dev/null || true
                if [ -n "$mediamtx_pid" ]; then
                    kill -15 "$mediamtx_pid" 2>/dev/null
                fi
            fi
            
            # Wait to ensure services have stopped
            sleep 5
            
            # Force kill any remaining processes
            log "INFO" "Force killing any remaining MediaMTX processes"
            pkill -9 -f "$MEDIAMTX_NAME" 2>/dev/null || true
            
            # Aggressive cleanup
            cleanup_before_restart "$mediamtx_pid" true
            
            # Extra cleanup: clear shared memory, temp files, etc.
            log "INFO" "Cleaning up system resources"
            
            # Remove any MediaMTX lock files
            find /tmp -name "*$MEDIAMTX_NAME*" -type f -delete 2>/dev/null || true
            
            # Clear any stale socket files
            find /tmp -name "*.sock" -type s -delete 2>/dev/null || true
            
            # Wait for cleanup to complete
            sleep 3
            
            # Start MediaMTX
            if [ "$uses_systemd" = true ]; then
                log "INFO" "Starting MediaMTX service"
                systemctl start "$MEDIAMTX_SERVICE"
                local restart_status=$?
                
                if [ $restart_status -ne 0 ]; then
                    log "ERROR" "Aggressive restart failed with exit code $restart_status"
                    consecutive_failed_restarts=$((consecutive_failed_restarts + 1))
                    return 1
                fi
            else
                # Non-systemd start
                if [ -x "$MEDIAMTX_PATH" ]; then
                    log "INFO" "Starting MediaMTX from $MEDIAMTX_PATH"
                    nohup "$MEDIAMTX_PATH" >/dev/null 2>&1 &
                else
                    log "ERROR" "MediaMTX executable not found or not executable: $MEDIAMTX_PATH"
                    consecutive_failed_restarts=$((consecutive_failed_restarts + 1))
                    return 1
                fi
            fi
            
            # Wait longer for MediaMTX to initialize after aggressive restart
            sleep 10
            
            # Get the new PID
            local new_pid
            new_pid=$(get_mediamtx_pid)
            
            # Verify MediaMTX is running properly
            if ! verify_mediamtx_health "$new_pid"; then
                log "ERROR" "MediaMTX failed health check after aggressive restart"
                consecutive_failed_restarts=$((consecutive_failed_restarts + 1))
                return 1
            fi
            
            # Restart audio streams if MediaMTX is healthy
            log "INFO" "MediaMTX is healthy, restarting audio streams"
            if [ "$uses_systemd" = true ] && systemctl is-enabled --quiet audio-rtsp.service; then
                log "INFO" "Starting audio-rtsp service"
                systemctl start audio-rtsp.service
            fi
            ;;
            
        4)
            # Level 4: System reboot consideration
            log "RECOVERY" "Level 4: Considering system reboot after multiple failed recoveries"
            
            # Check if auto reboot is enabled
            if [ "$ENABLE_AUTO_REBOOT" = true ]; then
                # Check if we're within cooldown after recent reboot
                if [ $((current_time - last_reboot_time)) -lt "$REBOOT_COOLDOWN" ]; then
                    log "WARNING" "In reboot cooldown period, attempting one more aggressive recovery"
                    # Fall back to level 3 recovery during reboot cooldown
                    recovery_level=3
                    recover_mediamtx "EMERGENCY"
                    return $?
                fi
                
                # Check if failed restarts exceed threshold
                if [ "$consecutive_failed_restarts" -ge "$REBOOT_THRESHOLD" ]; then
                    # Perform last-chance aggressive recovery in case something changed
                    log "RECOVERY" "Final attempt at aggressive recovery before reboot"
                    recovery_level=3
                    if recover_mediamtx "FINAL_ATTEMPT"; then
                        log "INFO" "Final recovery attempt succeeded, cancelling reboot"
                        consecutive_failed_restarts=0
                        return 0
                    fi
                    
                    # If we got here, the final attempt failed
                    log "REBOOT" "Initiating system reboot after $consecutive_failed_restarts failed recoveries"
                    
                    # Record reboot in state file
                    echo "$(date +%s)" > "${STATE_DIR}/last_reboot_time"
                    last_reboot_time=$(date +%s)
                    
                    # Write a detailed report before reboot
                    local reboot_file="${STATE_DIR}/reboot_reason_$(date +%Y%m%d%H%M%S).txt"
                    {
                        echo "Reboot Reason: $consecutive_failed_restarts consecutive failed recoveries"
                        echo "Last Recovery Level: $recovery_level"
                        echo "Original Issue: $reason"
                        echo "Time: $(date)"
                        echo "---"
                        echo "System State:"
                        free -h
                        echo "---"
                        echo "Disk Space:"
                        df -h
                        echo "---"
                        echo "Process List:"
                        ps aux
                        echo "---"
                        echo "Last 20 log entries:"
                        tail -n 20 "$MONITOR_LOG"
                    } > "$reboot_file" 2>&1
                    
                    # Sync disks before reboot
                    sync
                    
                    # Actual reboot command
                    log "REBOOT" "Executing reboot now"
                    reboot
                    return 0
                else
                    log "WARNING" "Reboot threshold not met yet ($consecutive_failed_restarts/$REBOOT_THRESHOLD)"
                    # Try level 3 recovery as a fallback
                    recovery_level=3
                    recover_mediamtx "EMERGENCY"
                    return $?
                fi
            else
                log "WARNING" "Auto reboot is disabled, attempting aggressive recovery instead"
                # Fall back to level 3 recovery when auto reboot is disabled
                recovery_level=3
                recover_mediamtx "EMERGENCY"
                return $?
            fi
            ;;
    esac
    
    # Wait for MediaMTX to stabilize
    sleep 5
    
    # Update last restart time
    last_restart_time=$(date +%s)
    
    # Restart ffmpeg processes if needed
    if [ "$recovery_level" -ge 2 ]; then
        restart_ffmpeg_processes
    fi
    
    # Reset consecutive failed restarts counter on success
    consecutive_failed_restarts=0
    
    log "RECOVERY" "Recovery level $recovery_level completed successfully"
    return 0
}

# Main monitoring loop
initialize() {
    log "INFO" "Starting Enhanced MediaMTX Resource Monitor v4.0.0"
    log "INFO" "Configuration: CPU threshold: ${CPU_THRESHOLD}%, Memory threshold: ${MEMORY_THRESHOLD}%, Max uptime: ${MAX_UPTIME}s"
    log "INFO" "Combined CPU monitoring enabled: warning at ${COMBINED_CPU_WARNING}%, critical at ${COMBINED_CPU_THRESHOLD}%"
    log "INFO" "Recovery settings: Max restart attempts: $MAX_RESTART_ATTEMPTS, Reboot threshold: $REBOOT_THRESHOLD, Auto-reboot: $ENABLE_AUTO_REBOOT"
    
    # Load previous state if available
    if [ -f "${STATE_DIR}/last_restart_time" ]; then
        last_restart_time=$(cat "${STATE_DIR}/last_restart_time" 2>/dev/null || echo "0")
    fi
    if [ -f "${STATE_DIR}/last_reboot_time" ]; then
        last_reboot_time=$(cat "${STATE_DIR}/last_reboot_time" 2>/dev/null || echo "0")
    fi
    
    # Create state directory
    mkdir -p "${STATE_DIR}" "${STATS_DIR}" 2>/dev/null
    
    # Detect and set up trap for proper shutdown
    trap cleanup SIGINT SIGTERM
}

cleanup() {
    log "INFO" "Received shutdown signal, exiting cleanly"
    
    # Save current state
    echo "$last_restart_time" > "${STATE_DIR}/last_restart_time"
    echo "$last_reboot_time" > "${STATE_DIR}/last_reboot_time"
    
    exit 0
}

# Track high CPU periods and other state variables
consecutive_high_cpu=0
consecutive_high_memory=0
previous_cpu=0
previous_memory=0

# Initialize the monitor
initialize

# Main monitoring loop
while true; do
    # Check if MediaMTX is running
    if ! is_process_running "$MEDIAMTX_NAME"; then
        log "WARNING" "MediaMTX is not running! Attempting to start..."
        recover_mediamtx "process not running"
        sleep 10
        continue
    fi
    
    # Get MediaMTX PID
    mediamtx_pid=$(get_mediamtx_pid)
    if [ -z "$mediamtx_pid" ]; then
        log "WARNING" "Could not determine MediaMTX PID"
        sleep 10
        continue
    fi
    
    # Get resource usage
    cpu_usage=$(get_mediamtx_cpu "$mediamtx_pid")
    combined_cpu_usage=$(get_combined_cpu_usage "$mediamtx_pid")
    memory_usage=$(get_mediamtx_memory "$mediamtx_pid")
    uptime=$(get_mediamtx_uptime "$mediamtx_pid")
    file_descriptors=$(get_mediamtx_file_descriptors "$mediamtx_pid")
    
    # Record current state
    echo "$cpu_usage" > "${STATE_DIR}/current_cpu"
    echo "$combined_cpu_usage" > "${STATE_DIR}/combined_cpu"
    echo "$memory_usage" > "${STATE_DIR}/current_memory"
    echo "$uptime" > "${STATE_DIR}/current_uptime"
    echo "$file_descriptors" > "${STATE_DIR}/current_fd"
    
    # Log current status at a regular interval (every 5 minutes)
    if (( $(date +%s) % 300 < CPU_CHECK_INTERVAL )); then
        log "INFO" "STATUS: MediaMTX (PID: $mediamtx_pid) - CPU: ${cpu_usage}%, Combined CPU: ${combined_cpu_usage}%, Memory: ${memory_usage}%, FDs: $file_descriptors, Uptime: ${uptime}s"
    fi
    
    # Check for emergency conditions (immediate action required)
    if [ "$combined_cpu_usage" -ge "$COMBINED_CPU_THRESHOLD" ]; then
        log "ERROR" "EMERGENCY: Combined CPU usage critical: ${combined_cpu_usage}% (threshold: ${COMBINED_CPU_THRESHOLD}%)"
        recover_mediamtx "EMERGENCY combined CPU (${combined_cpu_usage}%)"
        sleep 15  # Longer wait after emergency action
        continue
    fi
    
    if [ "$cpu_usage" -ge "$EMERGENCY_CPU_THRESHOLD" ]; then
        log "ERROR" "EMERGENCY: MediaMTX CPU usage critical: ${cpu_usage}% (threshold: ${EMERGENCY_CPU_THRESHOLD}%)"
        recover_mediamtx "EMERGENCY CPU (${cpu_usage}%)"
        sleep 15  # Longer wait after emergency action
        continue
    fi
    
    if [ "$memory_usage" -ge "$EMERGENCY_MEMORY_THRESHOLD" ]; then
        log "ERROR" "EMERGENCY: MediaMTX memory usage critical: ${memory_usage}% (threshold: ${EMERGENCY_MEMORY_THRESHOLD}%)"
        recover_mediamtx "EMERGENCY memory (${memory_usage}%)"
        sleep 15  # Longer wait after emergency action
        continue
    fi
    
    if [ "$file_descriptors" -ge "$FILE_DESCRIPTOR_THRESHOLD" ]; then
        log "ERROR" "EMERGENCY: Too many open file descriptors: $file_descriptors (threshold: ${FILE_DESCRIPTOR_THRESHOLD})"
        recover_mediamtx "EMERGENCY file descriptors ($file_descriptors)"
        sleep 15  # Longer wait after emergency action
        continue
    fi
    
    # Analyze trends to detect gradual resource creep
    analyze_trends "$cpu_usage" "$memory_usage"
    trend_status=$?
    
    # Take action on concerning trends
    if [ $trend_status -ne 0 ]; then
        # Only act on trends if we're outside of cooldown
        current_time=$(date +%s)
        if [ $((current_time - last_resource_warning)) -gt 600 ]; then  # 10 minute cooldown for trend warnings
            log "WARNING" "Resource trend analysis indicates potential issue, scheduling preventive restart"
            last_resource_warning=$(date +%s)
            
            # If the previous restart was very recent, wait a bit
            if [ $((current_time - last_restart_time)) -lt 300 ]; then
                log "INFO" "Recent restart detected, scheduling preventive restart in 5 minutes"
                sleep 300
            fi
            
            recover_mediamtx "preventive maintenance (trend analysis)"
            sleep 15  # Longer wait after trend-based restart
            continue
        fi
    fi
    
    # Check CPU threshold
    if [ "$cpu_usage" -ge "$CPU_THRESHOLD" ]; then
        consecutive_high_cpu=$((consecutive_high_cpu + 1))
        log "WARNING" "MediaMTX CPU usage is high: ${cpu_usage}% (threshold: ${CPU_THRESHOLD}%, consecutive periods: ${consecutive_high_cpu}/${CPU_SUSTAINED_PERIODS})"
        
        # If CPU has been high for consecutive periods, restart
        if [ "$consecutive_high_cpu" -ge "$CPU_SUSTAINED_PERIODS" ]; then
            recover_mediamtx "sustained high CPU usage (${cpu_usage}%)"
            consecutive_high_cpu=0
            sleep 10
            continue
        fi
    else
        # Reset counter if CPU is normal
        if [ "$consecutive_high_cpu" -gt 0 ]; then
            if [ "$previous_cpu" -ge "$CPU_THRESHOLD" ] && [ "$cpu_usage" -lt "$previous_cpu" ]; then
                log "INFO" "MediaMTX CPU usage normalized: ${cpu_usage}% (down from ${previous_cpu}%)"
            fi
            consecutive_high_cpu=0
        fi
    fi
    
    # Check for combined CPU warning level
    if [ "$combined_cpu_usage" -ge "$COMBINED_CPU_WARNING" ] && [ "$combined_cpu_usage" -lt "$COMBINED_CPU_THRESHOLD" ]; then
        # Only log warnings occasionally to avoid log spam
        current_time=$(date +%s)
        if [ $((current_time - last_resource_warning)) -gt 300 ]; then  # 5 minute cooldown for warnings
            log "WARNING" "Combined CPU usage approaching threshold: ${combined_cpu_usage}% (warning: ${COMBINED_CPU_WARNING}%, critical: ${COMBINED_CPU_THRESHOLD}%)"
            last_resource_warning=$(date +%s)
        fi
    fi
    
    # Check memory threshold
    if [ "$memory_usage" -ge "$MEMORY_THRESHOLD" ]; then
        consecutive_high_memory=$((consecutive_high_memory + 1))
        log "WARNING" "MediaMTX memory usage is high: ${memory_usage}% (threshold: ${MEMORY_THRESHOLD}%, consecutive periods: ${consecutive_high_memory}/2)"
        
        # If memory has been high for consecutive periods, restart
        if [ "$consecutive_high_memory" -ge 2 ]; then
            recover_mediamtx "high memory usage (${memory_usage}%)"
            consecutive_high_memory=0
            sleep 10
            continue
        fi
    else
        # Reset counter if memory is normal
        if [ "$consecutive_high_memory" -gt 0 ]; then
            log "INFO" "MediaMTX memory usage normalized: ${memory_usage}%"
            consecutive_high_memory=0
        fi
    fi
    
    # Check for warning thresholds to provide early alerts
    if [ "$cpu_usage" -ge "$CPU_WARNING_THRESHOLD" ] && [ "$cpu_usage" -lt "$CPU_THRESHOLD" ]; then
        # Only log warnings occasionally to avoid log spam
        current_time=$(date +%s)
        if [ $((current_time - last_resource_warning)) -gt 300 ]; then  # 5 minute cooldown for warnings
            log "WARNING" "MediaMTX CPU usage approaching threshold: ${cpu_usage}% (warning: ${CPU_WARNING_THRESHOLD}%, critical: ${CPU_THRESHOLD}%)"
            last_resource_warning=$(date +%s)
        fi
    fi
    
    # Check uptime - force restart after MAX_UPTIME for preventive maintenance
    if [ "$uptime" -ge "$MAX_UPTIME" ]; then
        log "INFO" "MediaMTX has reached maximum uptime of ${MAX_UPTIME}s, performing preventive restart"
        recover_mediamtx "scheduled restart after ${MAX_UPTIME}s uptime"
        sleep 10
        continue
    fi
    
    # Store previous values for comparison
    previous_cpu=$cpu_usage
    previous_memory=$memory_usage
    
    # Sleep before next check
    sleep "$CPU_CHECK_INTERVAL"
done
EOF

log "${GREEN}" "Monitor script created successfully"
chmod +x "$MONITOR_SCRIPT"

# Create status script
log "${YELLOW}" "Creating status script..."

cat > "$STATUS_SCRIPT" << 'EOF'
#!/bin/bash
# MediaMTX Monitor Status Script
# Version: 4.0.0
# Date: May 10, 2025

# Define color codes for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

CONFIG_DIR="/etc/audio-rtsp"
CONFIG_FILE="${CONFIG_DIR}/config"
LOG_DIR="/var/log/audio-rtsp"
STATE_DIR="${LOG_DIR}/state"
STATS_DIR="${LOG_DIR}/stats"
MONITOR_LOG="${LOG_DIR}/mediamtx-monitor.log"
RECOVERY_LOG="${LOG_DIR}/recovery-actions.log"

# Load configuration settings if available
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE" 2>/dev/null
fi

# Function to show formatted value with color based on thresholds
show_value() {
    local value=$1
    local warning=$2
    local critical=$3
    local label=$4
    
    if [ "$value" -ge "$critical" ]; then
        echo -e "${label}: ${RED}${value}${NC} (critical: $critical)"
    elif [ "$value" -ge "$warning" ]; then
        echo -e "${label}: ${YELLOW}${value}${NC} (warning: $warning)"
    else
        echo -e "${label}: ${GREEN}${value}${NC}"
    fi
}

echo -e "${BLUE}Enhanced MediaMTX Monitor Status${NC}"

echo -e "\n${YELLOW}Monitor Service Status:${NC}"
if systemctl is-active --quiet mediamtx-monitor.service; then
    echo -e "${GREEN}Monitor service is running${NC}"
    SERVICE_UPTIME=$(systemctl show mediamtx-monitor.service -p ActiveEnterTimestamp --value | xargs -I{} date -d {} "+%Y-%m-%d %H:%M:%S")
    echo -e "Running since: ${GREEN}$SERVICE_UPTIME${NC}"
else
    echo -e "${RED}Monitor service is NOT running${NC}"
fi

echo -e "\n${YELLOW}MediaMTX Process Status:${NC}"
MEDIAMTX_PID=$(pgrep -f "${MEDIAMTX_NAME:-mediamtx}" | head -n1)
if [ -n "$MEDIAMTX_PID" ]; then
    echo -e "${GREEN}MediaMTX is running (PID: $MEDIAMTX_PID)${NC}"
    
    # Load current metrics from state files
    if [ -f "${STATE_DIR}/current_cpu" ]; then
        CPU=$(cat "${STATE_DIR}/current_cpu")
        show_value "$CPU" "${MEDIAMTX_CPU_WARNING_THRESHOLD:-70}" "${MEDIAMTX_CPU_THRESHOLD:-80}" "CPU Usage"
    fi
    
    # Show combined CPU if available
    if [ -f "${STATE_DIR}/combined_cpu" ]; then
        COMBINED_CPU=$(cat "${STATE_DIR}/combined_cpu")
        show_value "$COMBINED_CPU" "${MEDIAMTX_COMBINED_CPU_WARNING_THRESHOLD:-150}" "${MEDIAMTX_COMBINED_CPU_THRESHOLD:-200}" "Combined CPU Usage"
        
        # Show component breakdown if available
        if [ -f "${STATE_DIR}/mediamtx_cpu" ] && [ -f "${STATE_DIR}/ffmpeg_cpu" ]; then
            MEDIAMTX_CPU_PART=$(cat "${STATE_DIR}/mediamtx_cpu")
            FFMPEG_CPU_PART=$(cat "${STATE_DIR}/ffmpeg_cpu")
            FFMPEG_COUNT=$(cat "${STATE_DIR}/ffmpeg_count" 2>/dev/null || echo "?")
            echo -e "  └─ MediaMTX: ${GREEN}${MEDIAMTX_CPU_PART}%${NC}, FFmpeg (${FFMPEG_COUNT}): ${GREEN}${FFMPEG_CPU_PART}%${NC}"
        fi
    fi
    
    if [ -f "${STATE_DIR}/current_memory" ]; then
        MEM=$(cat "${STATE_DIR}/current_memory")
        show_value "$MEM" "${MEDIAMTX_MEMORY_WARNING_THRESHOLD:-12}" "${MEDIAMTX_MEMORY_THRESHOLD:-15}" "Memory Usage"
    fi
    
    if [ -f "${STATE_DIR}/current_uptime" ]; then
        UPTIME=$(cat "${STATE_DIR}/current_uptime")
        UPTIME_HOURS=$((UPTIME / 3600))
        UPTIME_MINS=$(((UPTIME % 3600) / 60))
        echo -e "Uptime: ${GREEN}${UPTIME_HOURS}h ${UPTIME_MINS}m${NC} (max: $((MEDIAMTX_MAX_UPTIME / 3600))h)"
    fi
    
    if [ -f "${STATE_DIR}/current_fd" ]; then
        FD=$(cat "${STATE_DIR}/current_fd")
        show_value "$FD" "$((MEDIAMTX_FILE_DESCRIPTOR_THRESHOLD / 2))" "${MEDIAMTX_FILE_DESCRIPTOR_THRESHOLD:-1000}" "Open Files"
    fi
else
    echo -e "${RED}MediaMTX is NOT running${NC}"
fi

echo -e "\n${YELLOW}Recent Monitor Activity:${NC}"
if [ -f "$MONITOR_LOG" ]; then
    echo -e "${GREEN}Last 10 monitor log entries:${NC}"
    tail -n 10 "$MONITOR_LOG"
else
    echo -e "${RED}No monitor log found${NC}"
fi

echo -e "\n${YELLOW}Recent Recovery Actions:${NC}"
if [ -f "$RECOVERY_LOG" ]; then
    if [ -s "$RECOVERY_LOG" ]; then
        echo -e "${RED}Recent recovery actions:${NC}"
        tail -n 5 "$RECOVERY_LOG"
    else
        echo -e "${GREEN}No recovery actions recorded${NC}"
    fi
else
    echo -e "${GREEN}No recovery actions recorded${NC}"
fi

echo -e "\n${YELLOW}Configuration Settings:${NC}"
if [ -f "$CONFIG_FILE" ]; then
    echo -e "CPU Threshold: ${MEDIAMTX_CPU_THRESHOLD:-80}%"
    echo -e "Memory Threshold: ${MEDIAMTX_MEMORY_THRESHOLD:-15}%"
    echo -e "Combined CPU Threshold: ${MEDIAMTX_COMBINED_CPU_THRESHOLD:-200}%"
    echo -e "Max Uptime: $((MEDIAMTX_MAX_UPTIME / 3600)) hours"
    echo -e "Auto-Reboot: ${MEDIAMTX_ENABLE_AUTO_REBOOT:-false}"
    echo -e "Reboot Threshold: ${MEDIAMTX_REBOOT_THRESHOLD:-3} failed recoveries"
else
    echo -e "${RED}Configuration file not found${NC}"
fi

echo -e "\n${YELLOW}Resource Trend Analysis:${NC}"
if [ -d "${STATS_DIR}" ]; then
    CPU_TREND_FILE="${STATS_DIR}/cpu_history.txt"
    if [ -f "$CPU_TREND_FILE" ]; then
        CPU_SAMPLES=$(wc -l < "$CPU_TREND_FILE")
        if [ "$CPU_SAMPLES" -ge 3 ]; then
            LAST_THREE=$(tail -n 3 "$CPU_TREND_FILE")
            FIRST=$(echo "$LAST_THREE" | head -n 1)
            SECOND=$(echo "$LAST_THREE" | head -n 2 | tail -n 1)
            THIRD=$(echo "$LAST_THREE" | tail -n 1)
            
            if [[ "$FIRST" -lt "$SECOND" && "$SECOND" -lt "$THIRD" ]]; then
                echo -e "CPU Trend: ${RED}Increasing${NC} ($FIRST → $SECOND → $THIRD)"
            elif [[ "$FIRST" -gt "$SECOND" && "$SECOND" -gt "$THIRD" ]]; then
                echo -e "CPU Trend: ${GREEN}Decreasing${NC} ($FIRST → $SECOND → $THIRD)"
            else
                echo -e "CPU Trend: ${YELLOW}Fluctuating${NC} ($FIRST → $SECOND → $THIRD)"
            fi
        else
            echo -e "CPU Trend: ${YELLOW}Not enough data${NC}"
        fi
    else
        echo -e "No trend data available yet"
    fi
else
    echo -e "${RED}No statistics directory found${NC}"
fi

echo -e "\n${YELLOW}Management Commands:${NC}"
echo -e "  Check status: ${GREEN}sudo check-mediamtx-monitor.sh${NC}"
echo -e "  View logs: ${GREEN}sudo tail -f $MONITOR_LOG${NC}"
echo -e "  Restart monitor: ${GREEN}sudo systemctl restart mediamtx-monitor.service${NC}"
echo -e "  View recovery actions: ${GREEN}sudo tail -f $RECOVERY_LOG${NC}"
EOF

log "${GREEN}" "Status script created successfully"
chmod +x "$STATUS_SCRIPT"

# Create systemd service file
log "${YELLOW}" "Creating systemd service file..."

cat > "$SERVICE_FILE" << 'EOF'
[Unit]
Description=Enhanced MediaMTX Resource Monitor
Documentation=file:/etc/audio-rtsp/config
After=network.target mediamtx.service
Wants=mediamtx.service
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/enhanced-mediamtx-monitor.sh
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=15
# Give the monitor time to properly initialize
TimeoutStartSec=30
# Set resource limits
LimitNOFILE=65536
# Ensure environment is properly set up
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StandardOutput=append:/var/log/audio-rtsp/mediamtx-monitor-service.log
StandardError=append:/var/log/audio-rtsp/mediamtx-monitor-error.log
# Give the service a chance to clean up when stopping
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

log "${GREEN}" "Service file created successfully"

# Set up log rotation
log "${YELLOW}" "Setting up log rotation..."
cat > /etc/logrotate.d/mediamtx-monitor << 'EOF'
/var/log/audio-rtsp/mediamtx-monitor*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 root root
    postrotate
        systemctl is-active --quiet mediamtx-monitor.service && systemctl restart mediamtx-monitor.service
    endscript
}
EOF

log "${GREEN}" "Log rotation configured"

# Enable and start the service
log "${YELLOW}" "Enabling and starting service..."
systemctl daemon-reload
systemctl enable mediamtx-monitor.service

# Try to start the service with a few attempts
for i in {1..3}; do
    log "${YELLOW}" "Starting service (attempt $i)..."
    if systemctl start mediamtx-monitor.service; then
        sleep 3
        if systemctl is-active --quiet mediamtx-monitor.service; then
            log "${GREEN}" "Service started successfully"
            break
        else
            log "${RED}" "Service failed to stay running on attempt $i"
        fi
    else
        log "${RED}" "Failed to start service on attempt $i"
    fi
    
    if [ $i -eq 3 ]; then
        log "${RED}" "Failed to start service after multiple attempts"
        log "${YELLOW}" "Please check logs with: journalctl -u mediamtx-monitor.service"
    else
        sleep 2
    fi
done

log "${GREEN}" "MediaMTX monitor installation completed successfully!"
echo -e "${GREEN}MediaMTX monitor installation completed!${NC}"
echo -e "${BLUE}The monitor now tracks combined CPU usage of MediaMTX and related ffmpeg processes${NC}"
echo -e "${YELLOW}Check status with:${NC} sudo check-mediamtx-monitor.sh"
echo -e "${YELLOW}View logs with:${NC} sudo tail -f /var/log/audio-rtsp/mediamtx-monitor.log"
echo -e "${YELLOW}If needed, adjust the thresholds in:${NC} $CONFIG_FILE"
echo -e "${YELLOW}Original files backed up to:${NC} $BACKUP_DIR"

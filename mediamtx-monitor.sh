#!/bin/bash
# MediaMTX Resource Monitor
#
# https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/mediamtx-monitor.sh
#
# Version: 1.0.3
# Date: 2025-05-11
# Description: Monitors MediaMTX health and resources with progressive recovery strategies
#              Handles CPU, memory, file descriptors and network monitoring
#              Includes recovery levels and trend analysis
#              Fixed timestamp initialization for cleaner reporting
# Changes in v1.0.3:
#   - Improved atomic write consistency throughout the script
#   - Replaced direct file writes with atomic_write function calls
#   - Fixed potential race conditions in state file operations

# ======================================================================
# Configuration and Setup
# ======================================================================

# Exit on pipe failures to catch errors in piped commands
set -o pipefail

# Set script version
SCRIPT_VERSION="1.0.3"

# Create unique ID for this instance
INSTANCE_ID="$$-$(date +%s)"

# Default configuration values (overridden by config file)
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
TEMP_DIR="/tmp/mediamtx-monitor-${INSTANCE_ID}"

# Resource thresholds
CPU_THRESHOLD=80
CPU_WARNING_THRESHOLD=70
CPU_SUSTAINED_PERIODS=3
CPU_TREND_PERIODS=10
CPU_CHECK_INTERVAL=60
MEMORY_THRESHOLD=15
MEMORY_WARNING_THRESHOLD=12
MAX_UPTIME=86400
MAX_RESTART_ATTEMPTS=5
RESTART_COOLDOWN=300
REBOOT_THRESHOLD=3
ENABLE_AUTO_REBOOT=false
REBOOT_COOLDOWN=1800
EMERGENCY_CPU_THRESHOLD=95
EMERGENCY_MEMORY_THRESHOLD=20
FILE_DESCRIPTOR_THRESHOLD=1000
COMBINED_CPU_THRESHOLD=200
COMBINED_CPU_WARNING=150

# Color codes for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# State tracking variables
recovery_level=0
last_restart_time=0
restart_attempts_count=0
last_reboot_time=0
last_resource_warning=0
consecutive_failed_restarts=0
uses_systemd=false

# ======================================================================
# Helper Functions
# ======================================================================

# Function for handling script errors
handle_error() {
    local line_number=$1
    local error_code=$2
    echo "[$line_number] [ERROR] Error at line ${line_number}: Command exited with status ${error_code}" >> "$MONITOR_LOG"
}

# Trap for error handling
trap 'handle_error $LINENO $?' ERR

# Function for logging with timestamps and levels
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Create log directories if they don't exist
    mkdir -p "$(dirname "$MONITOR_LOG")" "$(dirname "$RECOVERY_LOG")" 2>/dev/null
    
    # Create a temp file for atomic writes to avoid partial messages
    local temp_log_file="${TEMP_DIR}/log.${level}.${INSTANCE_ID}.tmp"
    
    # Ensure temp directory exists
    mkdir -p "${TEMP_DIR}" 2>/dev/null
    
    # Write message to temp file
    echo "[$timestamp] [$level] $message" > "$temp_log_file"
    
    # Atomically append to log file
    cat "$temp_log_file" >> "$MONITOR_LOG"
    
    # If it's a recovery action, also log to the recovery log
    if [[ "$level" == "RECOVERY" || "$level" == "REBOOT" ]]; then
        cat "$temp_log_file" >> "$RECOVERY_LOG"
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
    
    # Clean up temp file
    rm -f "$temp_log_file"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Atomic file write to avoid race conditions
atomic_write() {
    local file="$1"
    local content="$2"
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$file")" 2>/dev/null
    
    # Create temp file with unique name
    local temp_file="${TEMP_DIR}/atomic_write.${INSTANCE_ID}.tmp"
    
    # Write content to temp file
    echo "$content" > "$temp_file"
    
    # Move temp file to destination with atomic rename operation
    if ! mv -f "$temp_file" "$file"; then
        log "ERROR" "Failed to atomically write to $file"
        return 1
    fi
    
    return 0
}

# Atomic append to file (read current content, append, write atomically)
atomic_append() {
    local file="$1"
    local content="$2"
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$file")" 2>/dev/null
    
    # Create temp file with unique name
    local temp_file="${TEMP_DIR}/atomic_append.${INSTANCE_ID}.tmp"
    
    # Read existing content if file exists
    if [ -f "$file" ]; then
        cat "$file" > "$temp_file" 2>/dev/null
    else
        # Ensure temp file exists even if original doesn't
        touch "$temp_file"
    fi
    
    # Append new content to temp file
    echo "$content" >> "$temp_file"
    
    # Move temp file to destination with atomic rename operation
    if ! mv -f "$temp_file" "$file"; then
        log "ERROR" "Failed to atomically append to $file"
        return 1
    fi
    
    return 0
}

# ======================================================================
# Initialization Functions
# ======================================================================

# Load configuration from config file
load_config() {
    log "INFO" "Initializing MediaMTX Monitor v${SCRIPT_VERSION}"
    
    # Load configuration file if it exists
    if [ -f "$CONFIG_FILE" ]; then
        log "INFO" "Loading configuration from $CONFIG_FILE"
        
        # Source the config file in a safe way
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        
        log "INFO" "Configuration loaded: CPU threshold: ${CPU_THRESHOLD}%, Memory threshold: ${MEMORY_THRESHOLD}%"
    else
        log "WARNING" "Configuration file not found at $CONFIG_FILE, using defaults"
    fi
    
    # Create required directories
    mkdir -p "$TEMP_DIR" "$STATE_DIR" "$STATS_DIR" 2>/dev/null || {
        log "ERROR" "Failed to create required directories"
        # Try alternate locations if primary ones fail
        TEMP_DIR="/tmp/mediamtx-monitor-${INSTANCE_ID}"
        STATE_DIR="/tmp/mediamtx-monitor-state"
        STATS_DIR="/tmp/mediamtx-monitor-stats"
        mkdir -p "$TEMP_DIR" "$STATE_DIR" "$STATS_DIR" 2>/dev/null || {
            log "ERROR" "Failed to create even fallback directories. Cannot continue."
            exit 1
        }
    }
    
    # Set appropriate permissions
    chmod 755 "$STATE_DIR" "$STATS_DIR" 2>/dev/null || 
        log "WARNING" "Failed to set permissions on state directories"
    
    # Check if we can use systemctl to manage MediaMTX
    uses_systemd=false
    if command_exists systemctl; then
        if systemctl list-unit-files | grep -q "$MEDIAMTX_SERVICE"; then
            uses_systemd=true
            log "INFO" "Using systemd to manage MediaMTX service ($MEDIAMTX_SERVICE)"
        else
            log "WARNING" "MediaMTX service not found in systemd ($MEDIAMTX_SERVICE), falling back to process management"
        fi
    else
        log "WARNING" "systemd not available, using direct process management"
    fi
    
    # Load previous state if available
    load_previous_state
    
    # Set up traps for cleanup
    trap cleanup_handler SIGINT SIGTERM HUP
}

# Load previous state from state files - FIXED VERSION
load_previous_state() {
    local current_time=$(date +%s)
    
    # Handle last_restart_time
    if [ -f "${STATE_DIR}/last_restart_time" ]; then
        last_restart_time=$(cat "${STATE_DIR}/last_restart_time" 2>/dev/null || echo "0")
        # Validate timestamp is not zero or empty
        if [ -z "$last_restart_time" ] || [ "$last_restart_time" = "0" ] || ! [[ "$last_restart_time" =~ ^[0-9]+$ ]]; then
            log "WARNING" "Invalid last restart time found, initializing to current time"
            last_restart_time=$current_time
            atomic_write "${STATE_DIR}/last_restart_time" "$last_restart_time"
        fi
    else
        # Initialize with current time if file doesn't exist
        last_restart_time=$current_time
        atomic_write "${STATE_DIR}/last_restart_time" "$last_restart_time"
        log "INFO" "Initialized last restart time to current time"
    fi
    
    # Format and log the time in human-readable format
    local formatted_restart_time=$(date -d "@$last_restart_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$last_restart_time")
    log "INFO" "Loaded last restart time: $formatted_restart_time"
    
    # Handle last_reboot_time
    if [ -f "${STATE_DIR}/last_reboot_time" ]; then
        last_reboot_time=$(cat "${STATE_DIR}/last_reboot_time" 2>/dev/null || echo "0")
        # Validate timestamp is not zero or empty
        if [ -z "$last_reboot_time" ] || [ "$last_reboot_time" = "0" ] || ! [[ "$last_reboot_time" =~ ^[0-9]+$ ]]; then
            log "WARNING" "Invalid last reboot time found, initializing to current time"
            last_reboot_time=$current_time
            atomic_write "${STATE_DIR}/last_reboot_time" "$last_reboot_time"
        fi
    else
        # Initialize with current time if file doesn't exist
        last_reboot_time=$current_time
        atomic_write "${STATE_DIR}/last_reboot_time" "$last_reboot_time"
        log "INFO" "Initialized last reboot time to current time"
    fi
    
    # Format and log the time in human-readable format
    local formatted_reboot_time=$(date -d "@$last_reboot_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$last_reboot_time")
    log "INFO" "Loaded last reboot time: $formatted_reboot_time"
    
    # Handle consecutive_failed_restarts
    if [ -f "${STATE_DIR}/consecutive_failed_restarts" ]; then
        consecutive_failed_restarts=$(cat "${STATE_DIR}/consecutive_failed_restarts" 2>/dev/null || echo "0")
        # Validate number is not empty and is numeric
        if [ -z "$consecutive_failed_restarts" ] || ! [[ "$consecutive_failed_restarts" =~ ^[0-9]+$ ]]; then
            log "WARNING" "Invalid consecutive failed restarts count found, resetting to 0"
            consecutive_failed_restarts=0
            atomic_write "${STATE_DIR}/consecutive_failed_restarts" "0"
        fi
    else
        # Initialize with 0 if file doesn't exist
        consecutive_failed_restarts=0
        atomic_write "${STATE_DIR}/consecutive_failed_restarts" "0"
        log "INFO" "Initialized consecutive failed restarts to 0"
    fi
    
    log "INFO" "Loaded consecutive failed restarts: $consecutive_failed_restarts"
}

# Clean up function for exit
cleanup_handler() {
    log "INFO" "Received shutdown signal, performing cleanup"
    
    # Save current state
    atomic_write "${STATE_DIR}/last_restart_time" "$last_restart_time"
    atomic_write "${STATE_DIR}/last_reboot_time" "$last_reboot_time"
    atomic_write "${STATE_DIR}/consecutive_failed_restarts" "$consecutive_failed_restarts"
    
    # Clean up temporary files
    rm -rf "${TEMP_DIR}"
    
    log "INFO" "Cleanup completed, exiting"
    exit 0
}

# ======================================================================
# Process Monitoring Functions
# ======================================================================

# Check if MediaMTX is running
is_mediamtx_running() {
    if [ "$uses_systemd" = true ]; then
        if systemctl is-active --quiet "$MEDIAMTX_SERVICE"; then
            return 0  # Service is running
        else
            return 1  # Service is not running
        fi
    else
        # Fallback - check for process
        if pgrep -f "$MEDIAMTX_NAME" >/dev/null 2>&1; then
            return 0  # Process is running
        else
            return 1  # Process is not running
        fi
    fi
}

# Check if audio-rtsp service is running
is_audio_rtsp_running() {
    if [ "$uses_systemd" = true ]; then
        if systemctl is-active --quiet audio-rtsp.service; then
            return 0  # Service is running
        else
            return 1  # Service is not running
        fi
    else
        # Fallback method - check for startmic.sh
        if pgrep -f "startmic.sh" >/dev/null 2>&1; then
            return 0  # Process is running
        else
            return 1  # Process is not running
        fi
    fi
}

# Get MediaMTX process ID
get_mediamtx_pid() {
    local pid=""
    
    # Try different methods to get MediaMTX PID
    if [ "$uses_systemd" = true ]; then
        # First try to get PID from systemd
        pid=$(systemctl show -p MainPID --value "$MEDIAMTX_SERVICE" 2>/dev/null)
        if [[ -n "$pid" && "$pid" != "0" ]]; then
            echo "$pid"
            return 0
        fi
    fi
    
    # Fall back to pgrep
    pid=$(pgrep -f "$MEDIAMTX_NAME" | head -n1)
    if [[ -n "$pid" ]]; then
        echo "$pid"
        return 0
    fi
    
    # No PID found
    echo ""
    return 1
}

# Get MediaMTX uptime in seconds
get_mediamtx_uptime() {
    local pid=$1
    if [ -z "$pid" ] || ! ps -p "$pid" >/dev/null 2>&1; then
        echo "0"
        return
    fi
    
    local start_time
    local elapsed_seconds=0
    
    # Try method 1: Using /proc/PID/stat
    if [ -f "/proc/$pid/stat" ]; then
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
                # Calculate process uptime in seconds
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
    
    # Method 3: Use state file if both above methods fail
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

# Get MediaMTX CPU usage percentage
get_mediamtx_cpu() {
    local pid=$1
    local cpu_usage=0
    
    if [ -z "$pid" ] || ! ps -p "$pid" >/dev/null 2>&1; then
        echo "0"
        return
    fi
    
    # Method 1: Use top for more accurate measurement
    if command_exists top; then
        local top_output
        top_output=$(COLUMNS=512 top -b -n 2 -d 0.2 -p "$pid" 2>/dev/null | tail -1)
        if [ $? -eq 0 ]; then
            cpu_usage=$(echo "$top_output" | awk '{print $9}')
            # Remove decimal places if present
            cpu_usage=${cpu_usage%%.*}
        fi
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

# Get MediaMTX memory usage percentage
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

# Get number of open file descriptors
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

# Get combined CPU usage of MediaMTX and related processes
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
        if command_exists top; then
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
        else
            # Fallback if top isn't available
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
        
        # Store the component values for reference - FIXED: Using atomic_write
        atomic_write "${STATE_DIR}/mediamtx_cpu" "$mediamtx_cpu"
        atomic_write "${STATE_DIR}/ffmpeg_cpu" "$ffmpeg_cpu"
        atomic_write "${STATE_DIR}/ffmpeg_count" "$ffmpeg_count"
    fi
    
    echo "$total_cpu"
}

# ======================================================================
# Network and Health Checking Functions
# ======================================================================

# Check network health
check_network_health() {
    # Check if RTSP port is accessible using different methods
    local port_accessible=0
    
    # Method 1: Use netcat if available
    if command_exists nc; then
        if nc -z localhost "$RTSP_PORT" >/dev/null 2>&1; then
            port_accessible=1
        fi
    # Method 2: Use /dev/tcp if netcat not available
    elif bash -c "echo > /dev/tcp/localhost/$RTSP_PORT" >/dev/null 2>&1; then
        port_accessible=1
    # Method 3: Use netstat or ss as last resort
    elif command_exists netstat || command_exists ss; then
        if command_exists netstat; then
            if netstat -tuln | grep -q ":$RTSP_PORT\s"; then
                port_accessible=1
            fi
        elif command_exists ss; then
            if ss -tuln | grep -q ":$RTSP_PORT\s"; then
                port_accessible=1
            fi
        fi
    fi
    
    # Return failure if port not accessible
    if [ $port_accessible -eq 0 ]; then
        log "WARNING" "RTSP port $RTSP_PORT is not accessible"
        return 1
    fi
    
    # Check for established connections to MediaMTX
    local established_count=0
    
    if command_exists netstat; then
        established_count=$(netstat -tn 2>/dev/null | grep ":$RTSP_PORT" | grep ESTABLISHED | wc -l)
    elif command_exists ss; then
        established_count=$(ss -tn 2>/dev/null | grep ":$RTSP_PORT" | grep ESTAB | wc -l)
    fi
    
    # If there are many connections but no recent activity, it might be an issue
    if [ "$established_count" -gt 20 ]; then
        log "WARNING" "High number of established connections ($established_count) to RTSP port"
    fi
    
    # Check if MediaMTX is responding to basic requests (if curl is available)
    if command_exists curl; then
        if ! curl -s -I -X OPTIONS "rtsp://localhost:$RTSP_PORT" >/dev/null 2>&1; then
            log "WARNING" "MediaMTX not responding properly to RTSP requests"
            return 1
        fi
    fi
    
    return 0
}

# Analyze resource usage trends
analyze_trends() {
    local cpu_file="${STATS_DIR}/cpu_history.txt"
    local mem_file="${STATS_DIR}/mem_history.txt"
    local current_cpu=$1
    local current_mem=$2
    
    # Create files if they don't exist
    touch "$cpu_file" "$mem_file"
    
    # Add current values to history files atomically
    atomic_append "$cpu_file" "$current_cpu"
    atomic_append "$mem_file" "$current_mem"
    
    # Trim history files to keep only the last CPU_TREND_PERIODS values
    if [ "$(wc -l < "$cpu_file")" -gt "$CPU_TREND_PERIODS" ]; then
        # Using temp file for atomic operation
        local temp_cpu_file="${TEMP_DIR}/cpu_history.tmp"
        tail -n "$CPU_TREND_PERIODS" "$cpu_file" > "$temp_cpu_file" && mv "$temp_cpu_file" "$cpu_file"
    fi
    
    if [ "$(wc -l < "$mem_file")" -gt "$CPU_TREND_PERIODS" ]; then
        # Using temp file for atomic operation
        local temp_mem_file="${TEMP_DIR}/mem_history.tmp"
        tail -n "$CPU_TREND_PERIODS" "$mem_file" > "$temp_mem_file" && mv "$temp_mem_file" "$mem_file"
    fi
    
    # Analyze CPU trend
    local cpu_trend=0
    local cpu_data
    cpu_data=$(cat "$cpu_file")
    
    if [ "$(wc -l < "$cpu_file")" -ge 3 ]; then
        # Check for consistently increasing CPU usage over the last 3 samples
        local sample1
        local sample2
        local sample3
        
        sample1=$(tail -n 3 "$cpu_file" | head -n 1)
        sample2=$(tail -n 2 "$cpu_file" | head -n 1)
        sample3=$(tail -n 1 "$cpu_file")
        
        if [[ "$sample1" -lt "$sample2" && "$sample2" -lt "$sample3" ]]; then
            # Calculate the rate of increase
            local increase_rate=$(( (sample3 - sample1) / 2 ))
            cpu_trend=$increase_rate
            
            # Store trend value for monitoring
            atomic_write "${STATE_DIR}/cpu_trend" "$cpu_trend"
            
            if [ "$increase_rate" -gt 5 ]; then
                log "WARNING" "CPU usage is trending upward rapidly (rate: +${increase_rate}% per period)"
                return 1
            elif [ "$increase_rate" -gt 2 ]; then
                log "INFO" "CPU usage is trending upward (rate: +${increase_rate}% per period)"
            fi
        fi
    fi
    
    return 0
}

# ======================================================================
# Recovery Functions
# ======================================================================

# Cleanup before restart
cleanup_before_restart() {
    local pid=$1
    local force_kill=$2
    local stale_procs=()
    local cleanup_status=0
    
    log "INFO" "Cleaning up before MediaMTX restart..."
    
    # Find all child processes of the MediaMTX process
    if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
        # Get all child process IDs using multiple methods for reliability
        local child_pids=""
        
        # Method 1: pstree if available
        if command_exists pstree; then
            child_pids=$(pstree -p "$pid" 2>/dev/null | grep -o '([0-9]\+)' | tr -d '()')
        fi
        
        # Method 2: ps with ppid filter if pstree fails
        if [ -z "$child_pids" ] && command_exists ps; then
            child_pids=$(ps -o pid --no-headers --ppid "$pid" 2>/dev/null)
        fi
        
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

# Verify MediaMTX health after restart
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
        if check_network_health; then
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
    
    # Store the start time for future uptime calculations - FIXED: Using atomic_write
    atomic_write "${STATE_DIR}/mediamtx_start_time" "$(date +%s)"
    
    if [ "$success" = true ] && [ "$initial_cpu" -lt "$CPU_WARNING_THRESHOLD" ]; then
        log "INFO" "MediaMTX appears to be healthy after restart"
        return 0
    else
        log "ERROR" "MediaMTX health check failed after restart"
        return 1
    fi
}

# Restart ffmpeg processes
restart_ffmpeg_processes() {
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
            # Non-systemd restart approach - use more reliable method with pidfile
            log "INFO" "Using non-systemd approach to restart audio processes"
            
            # Find the startmic.sh process
            local startmic_pid
            startmic_pid=$(pgrep -f "startmic.sh" | head -1)
            
            if [ -n "$startmic_pid" ]; then
                log "INFO" "Found startmic.sh process (PID: $startmic_pid), sending restart signal"
                # Send SIGHUP for graceful restart if supported
                kill -1 "$startmic_pid" >/dev/null 2>&1
                
                # Wait a moment for restart
                sleep 3
                
                # Check if process is still running
                if kill -0 "$startmic_pid" 2>/dev/null; then
                    log "INFO" "startmic.sh process restarted successfully"
                    return 0
                else
                    log "WARNING" "startmic.sh process not found after restart signal"
                    # Try to start it again
                    if [ -x "/usr/local/bin/startmic.sh" ]; then
                        nohup /usr/local/bin/startmic.sh >/dev/null 2>&1 &
                        log "INFO" "Started new startmic.sh process"
                        return 0
                    else
                        log "ERROR" "Could not find startmic.sh to restart"
                        return 1
                    fi
                fi
            else
                log "ERROR" "No startmic.sh process found to restart"
                return 1
            fi
        fi
    else
        log "INFO" "Audio-RTSP service is not running, no streams to restart"
        return 0
    fi
}

# Progressive recovery with multiple levels
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
                    atomic_write "${STATE_DIR}/consecutive_failed_restarts" "$consecutive_failed_restarts"
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
                    atomic_write "${STATE_DIR}/consecutive_failed_restarts" "$consecutive_failed_restarts"
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
                    atomic_write "${STATE_DIR}/consecutive_failed_restarts" "$consecutive_failed_restarts"
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
                    atomic_write "${STATE_DIR}/consecutive_failed_restarts" "$consecutive_failed_restarts"
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
                atomic_write "${STATE_DIR}/consecutive_failed_restarts" "$consecutive_failed_restarts"
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
                    atomic_write "${STATE_DIR}/consecutive_failed_restarts" "$consecutive_failed_restarts"
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
                    atomic_write "${STATE_DIR}/consecutive_failed_restarts" "$consecutive_failed_restarts"
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
                atomic_write "${STATE_DIR}/consecutive_failed_restarts" "$consecutive_failed_restarts"
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
                        atomic_write "${STATE_DIR}/consecutive_failed_restarts" "0"
                        return 0
                    fi
                    
                    # If we got here, the final attempt failed
                    log "REBOOT" "Initiating system reboot after $consecutive_failed_restarts failed recoveries"
                    
                    # Record reboot in state file - FIXED: Using atomic_write
                    atomic_write "${STATE_DIR}/last_reboot_time" "$(date +%s)"
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
    
    # Update last restart time and save state atomically
    last_restart_time=$(date +%s)
    atomic_write "${STATE_DIR}/last_restart_time" "$last_restart_time"
    
    # Restart ffmpeg processes if needed
    if [ "$recovery_level" -ge 2 ]; then
        restart_ffmpeg_processes
    fi
    
    # Reset consecutive failed restarts counter on success
    consecutive_failed_restarts=0
    atomic_write "${STATE_DIR}/consecutive_failed_restarts" "0"
    
    log "RECOVERY" "Recovery level $recovery_level completed successfully"
    return 0
}

# ======================================================================
# Main Monitoring Loop
# ======================================================================

main() {
    # Initialize the monitor
    load_config
    
    # Track resource usage over time
    consecutive_high_cpu=0
    consecutive_high_memory=0
    previous_cpu=0
    previous_memory=0
    
    log "INFO" "Starting main monitoring loop with ${CPU_CHECK_INTERVAL}s interval"
    
    # Main monitoring loop
    while true; do
        # Check if MediaMTX is running
        if ! is_mediamtx_running; then
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
        
        # Record current state atomically
        atomic_write "${STATE_DIR}/current_cpu" "$cpu_usage"
        atomic_write "${STATE_DIR}/combined_cpu" "$combined_cpu_usage"
        atomic_write "${STATE_DIR}/current_memory" "$memory_usage"
        atomic_write "${STATE_DIR}/current_uptime" "$uptime"
        atomic_write "${STATE_DIR}/current_fd" "$file_descriptors"
        
        # Log current status at a regular interval (every 5 minutes)
        current_time=$(date +%s)
        if (( current_time % 300 < CPU_CHECK_INTERVAL )); then
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
            if [ $((current_time - last_resource_warning)) -gt 600 ]; then  # 10 minute cooldown for trend warnings
                log "WARNING" "Resource trend analysis indicates potential issue, scheduling preventive restart"
                last_resource_warning=$current_time
                atomic_write "${STATE_DIR}/last_resource_warning" "$last_resource_warning"
                
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
                # FIXED: Using atomic_write to store state
                atomic_write "${STATE_DIR}/consecutive_high_cpu" "0"
                sleep 10
                continue
            else
                # FIXED: Store the updated counter atomically
                atomic_write "${STATE_DIR}/consecutive_high_cpu" "$consecutive_high_cpu"
            fi
        else
            # Reset counter if CPU is normal
            if [ "$consecutive_high_cpu" -gt 0 ]; then
                if [ "$previous_cpu" -ge "$CPU_THRESHOLD" ] && [ "$cpu_usage" -lt "$previous_cpu" ]; then
                    log "INFO" "MediaMTX CPU usage normalized: ${cpu_usage}% (down from ${previous_cpu}%)"
                fi
                consecutive_high_cpu=0
                atomic_write "${STATE_DIR}/consecutive_high_cpu" "0"
            fi
        fi
        
        # Check for combined CPU warning level
        if [ "$combined_cpu_usage" -ge "$COMBINED_CPU_WARNING" ] && [ "$combined_cpu_usage" -lt "$COMBINED_CPU_THRESHOLD" ]; then
            # Only log warnings occasionally to avoid log spam
            if [ $((current_time - last_resource_warning)) -gt 300 ]; then  # 5 minute cooldown for warnings
                log "WARNING" "Combined CPU usage approaching threshold: ${combined_cpu_usage}% (warning: ${COMBINED_CPU_WARNING}%, critical: ${COMBINED_CPU_THRESHOLD}%)"
                last_resource_warning=$current_time
                atomic_write "${STATE_DIR}/last_resource_warning" "$last_resource_warning"
            fi
        fi
        
        # Check memory threshold
        if [ "$memory_usage" -ge "$MEMORY_THRESHOLD" ]; then
            consecutive_high_memory=$((consecutive_high_memory + 1))
            log "WARNING" "MediaMTX memory usage is high: ${memory_usage}% (threshold: ${MEMORY_THRESHOLD}%, consecutive periods: ${consecutive_high_memory}/2)"
            
            # Store the updated counter atomically
            atomic_write "${STATE_DIR}/consecutive_high_memory" "$consecutive_high_memory"
            
            # If memory has been high for consecutive periods, restart
            if [ "$consecutive_high_memory" -ge 2 ]; then
                recover_mediamtx "high memory usage (${memory_usage}%)"
                consecutive_high_memory=0
                atomic_write "${STATE_DIR}/consecutive_high_memory" "0"
                sleep 10
                continue
            fi
        else
            # Reset counter if memory is normal
            if [ "$consecutive_high_memory" -gt 0 ]; then
                log "INFO" "MediaMTX memory usage normalized: ${memory_usage}%"
                consecutive_high_memory=0
                atomic_write "${STATE_DIR}/consecutive_high_memory" "0"
            fi
        fi
        
        # Check for warning thresholds to provide early alerts
        if [ "$cpu_usage" -ge "$CPU_WARNING_THRESHOLD" ] && [ "$cpu_usage" -lt "$CPU_THRESHOLD" ]; then
            # Only log warnings occasionally to avoid log spam
            if [ $((current_time - last_resource_warning)) -gt 300 ]; then  # 5 minute cooldown for warnings
                log "WARNING" "MediaMTX CPU usage approaching threshold: ${cpu_usage}% (warning: ${CPU_WARNING_THRESHOLD}%, critical: ${CPU_THRESHOLD}%)"
                last_resource_warning=$current_time
                atomic_write "${STATE_DIR}/last_resource_warning" "$last_resource_warning"
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
}

# Start the monitoring process
main

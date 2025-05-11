#!/bin/bash
# Streamlined Audio RTSP Streaming Service Setup Script
#
# https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/setup_audio_rtsp.sh
#
# Version: 2.0.0
# Date: 2025-05-10

# Color codes for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script version
VERSION="2.0.0"

# Default paths
CONFIG_DIR="/etc/audio-rtsp"
CONFIG_FILE="${CONFIG_DIR}/config"
LOG_DIR="/var/log/audio-rtsp"
RTSP_PORT="18554"
RESTART_DELAY=10
MAX_RESTART_ATTEMPTS=5
LOG_LEVEL="info"

# Create a timestamp for backups
TIMESTAMP=$(date +"%Y%m%d%H%M%S")

# Log function to print with timestamps
log() {
    local level=$1
    shift
    local message="$*"
    
    case "$level" in
        INFO)  echo -e "${GREEN}[INFO]${NC} $message" ;;
        WARN)  echo -e "${YELLOW}[WARNING]${NC} $message" ;;
        ERROR) echo -e "${RED}[ERROR]${NC} $message" ;;
        *)     echo -e "[$level] $message" ;;
    esac
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to compare versions
version_greater_equal() {
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# Function to backup a file before modification
backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        local backup="${file}.backup-${TIMESTAMP}"
        log INFO "Backing up ${file} to ${backup}"
        cp "$file" "$backup"
        return $?
    fi
    return 0
}

# Function to create a directory if it doesn't exist
create_directory() {
    local dir=$1
    if [ ! -d "$dir" ]; then
        log INFO "Creating directory: $dir"
        mkdir -p "$dir" || {
            log ERROR "Failed to create directory: $dir"
            return 1
        }
    fi
    return 0
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log ERROR "Please run as root"
        exit 1
    fi
}

# Check required dependencies
check_dependencies() {
    log INFO "Checking dependencies..."
    
    # Check for ffmpeg
    if ! command_exists ffmpeg; then
        log ERROR "ffmpeg is not installed"
        read -p "Would you like to install ffmpeg now? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log INFO "Installing ffmpeg..."
            if command_exists apt-get; then
                apt-get update && apt-get install -y ffmpeg
            elif command_exists yum; then
                yum install -y ffmpeg
            elif command_exists dnf; then
                dnf install -y ffmpeg
            else
                log ERROR "Unable to install ffmpeg. Please install it manually."
                exit 1
            fi
        else
            log ERROR "ffmpeg is required. Exiting installation."
            exit 1
        fi
    fi
    
    # Check ffmpeg version
    FFMPEG_VERSION=$(ffmpeg -version | head -n1 | awk '{print $3}')
    REQUIRED_FFMPEG_VERSION="4.0.0"
    if ! version_greater_equal "$FFMPEG_VERSION" "$REQUIRED_FFMPEG_VERSION"; then
        log WARN "ffmpeg version $FFMPEG_VERSION may be too old. Recommended: $REQUIRED_FFMPEG_VERSION or newer."
        read -p "Continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log ERROR "Installation aborted."
            exit 1
        fi
    fi
}

# Check if startmic.sh exists in current directory
check_startmic() {
    if [ ! -f "startmic.sh" ]; then
        log ERROR "startmic.sh not found in current directory"
        exit 1
    fi
    
    # Create backup of original script
    backup_file "startmic.sh"
    log INFO "Original script backed up"
}

# Set up directories
setup_directories() {
    log INFO "Creating necessary directories..."
    create_directory "/usr/local/bin" || exit 1
    create_directory "$LOG_DIR" || exit 1
    create_directory "$CONFIG_DIR" || exit 1
}

# Create configuration file
create_config_file() {
    log INFO "Creating configuration file..."
    
    # If config exists, try to extract the RTSP port
    if [ -f "$CONFIG_FILE" ]; then
        local EXISTING_PORT=$(grep -o "RTSP_PORT=[0-9]\+" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2)
        if [ -n "$EXISTING_PORT" ]; then
            RTSP_PORT=$EXISTING_PORT
            log INFO "Using existing RTSP port: $RTSP_PORT"
        fi
        backup_file "$CONFIG_FILE"
    fi
    
    # Create config content
    cat > "$CONFIG_FILE" << EOF
# Audio RTSP Streaming Service Configuration
# Modified by setup_audio_rtsp.sh v${VERSION}
# Date: $(date)

# RTSP server port
RTSP_PORT=$RTSP_PORT

# Number of seconds to wait before restart attempts
RESTART_DELAY=$RESTART_DELAY

# Maximum number of restart attempts before giving up
MAX_RESTART_ATTEMPTS=$MAX_RESTART_ATTEMPTS

# Logging level (debug, info, warning, error)
LOG_LEVEL=$LOG_LEVEL

# Path to the log directory
LOG_DIR=$LOG_DIR

# Log rotation settings
LOG_ROTATE_DAYS=7

# Audio settings
AUDIO_BITRATE=192k
AUDIO_CODEC=libmp3lame
AUDIO_CHANNELS=1
AUDIO_SAMPLE_RATE=44100
EOF

    chmod 644 "$CONFIG_FILE"
    log INFO "Configuration file created successfully"
}

# Install the startmic.sh script
install_startmic_script() {
    log INFO "Installing startmic.sh script..."
    
    # First copy the original script
    local STARTMIC_ORIG="/usr/local/bin/startmic.sh.original"
    if [ -f "$STARTMIC_ORIG" ]; then
        backup_file "$STARTMIC_ORIG"
    fi
    cp "startmic.sh" "$STARTMIC_ORIG"
    chmod +x "$STARTMIC_ORIG"
    
    # Create the service version of the script
    local STARTMIC_SERVICE="/usr/local/bin/startmic.sh"
    if [ -f "$STARTMIC_SERVICE" ]; then
        backup_file "$STARTMIC_SERVICE"
    fi
    
    # Check for RTSP port in original script
    local ORIGINAL_PORT=$(grep -o "rtsp://[^:]*:[0-9]\+" "startmic.sh" | grep -o ":[0-9]\+" | grep -o "[0-9]\+" | head -1)
    if [ -n "$ORIGINAL_PORT" ]; then
        log INFO "Found RTSP port $ORIGINAL_PORT in original script"
        RTSP_PORT=$ORIGINAL_PORT
    else
        log INFO "No RTSP port found in original script, using default: $RTSP_PORT"
    fi
    
    # Create the script header
    cat > "$STARTMIC_SERVICE" << 'EOF'
#!/bin/bash
# Modified for use with systemd service

# Load configuration if available
CONFIG_FILE="/etc/audio-rtsp/config"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    # Default values if config not found
    RTSP_PORT=18554
    RESTART_DELAY=10
    MAX_RESTART_ATTEMPTS=5
    LOG_LEVEL=info
    LOG_DIR=/var/log/audio-rtsp
    AUDIO_BITRATE=192k
    AUDIO_CODEC=libmp3lame
    AUDIO_CHANNELS=1
    AUDIO_SAMPLE_RATE=44100
fi

# Setup logging based on level
log() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        debug)
            [[ "$LOG_LEVEL" =~ ^(debug)$ ]] && echo "[$timestamp] [DEBUG] $message"
            ;;
        info)
            [[ "$LOG_LEVEL" =~ ^(debug|info)$ ]] && echo "[$timestamp] [INFO] $message"
            ;;
        warning)
            [[ "$LOG_LEVEL" =~ ^(debug|info|warning)$ ]] && echo "[$timestamp] [WARNING] $message"
            ;;
        error)
            echo "[$timestamp] [ERROR] $message"
            ;;
    esac
}

# Redirect output to log file when running as a service
if systemctl is-active --quiet audio-rtsp.service; then
    mkdir -p "$LOG_DIR"
    exec >> "$LOG_DIR/audio-streams.log" 2>&1
    log info "----------------------------------------"
    log info "Service started at $(date)"
    log info "----------------------------------------"
    
    # Check system resources
    log debug "System memory: $(free -h | grep Mem | awk '{print $3"/"$2}' used)"
    log debug "System CPU load: $(uptime | awk -F'load average: ' '{print $2}')"
    log debug "Disk space: $(df -h /var/log | tail -1 | awk '{print $5}') used on log partition"
fi
EOF
    
    # Append the original script content with modifications
    cat "startmic.sh" | grep -v "^wait$" | \
        sed "s/rtsp:\/\/localhost:8554/rtsp:\/\/localhost:\$RTSP_PORT/g" | \
        sed "s/rtsp:\/\/127.0.0.1:8554/rtsp:\/\/127.0.0.1:\$RTSP_PORT/g" >> "$STARTMIC_SERVICE"
    
    # Add function for systemd monitoring
    cat >> "$STARTMIC_SERVICE" << 'EOF'

# Function to monitor and restart streams if needed
capture_and_wait_for_children() {
    log info "Starting monitor loop for child processes..."
    log info "Using RTSP port: $RTSP_PORT"
    
    # Get all child PIDs
    local children=$(pgrep -P $$)
    
    # Track restart attempts
    local restart_attempts=0
    
    if [ -z "$children" ]; then
        log warning "No child processes found. Keeping service alive anyway."
    else
        log info "Monitoring child processes: $children"
    fi
    
    # Check if RTSP server is accessible
    if nc -z localhost $RTSP_PORT >/dev/null 2>&1; then
        log info "RTSP server is accessible on port $RTSP_PORT"
    else
        log warning "RTSP server is not accessible on port $RTSP_PORT - streams may fail to connect"
    fi
    
    # Set up signal handling
    trap 'log info "Received termination signal. Shutting down..."; kill $(jobs -p) 2>/dev/null; exit 0' SIGTERM SIGINT
    
    # Keep the script running - this is crucial for systemd
    while true; do
        # Check if any ffmpeg processes are still running
        if ! pgrep -f "ffmpeg.*rtsp://" > /dev/null; then
            log warning "No ffmpeg RTSP processes found. Attempting to restart streams..."
            
            # Check if RTSP server is accessible before restart
            if ! nc -z localhost $RTSP_PORT >/dev/null 2>&1; then
                log error "RTSP server is not accessible on port $RTSP_PORT - cannot restart streams"
                log info "Checking if MediaMTX service is running..."
                if systemctl is-active --quiet mediamtx.service; then
                    log info "MediaMTX service is running but port $RTSP_PORT is not accessible"
                else
                    log warning "MediaMTX service is not running. Attempting to start it..."
                    if command -v systemctl >/dev/null 2>&1; then
                        systemctl start mediamtx.service
                        sleep 3
                    fi
                fi
            fi
            
            # Increment restart attempts
            restart_attempts=$((restart_attempts + 1))
            
            # Check if we've hit the maximum number of restart attempts
            if [ "$restart_attempts" -ge "$MAX_RESTART_ATTEMPTS" ]; then
                log error "Maximum restart attempts ($MAX_RESTART_ATTEMPTS) reached. Exiting..."
                break
            fi
            
            # Sleep to avoid rapid restart cycles
            log info "Waiting ${RESTART_DELAY}s before restart attempt ${restart_attempts}/${MAX_RESTART_ATTEMPTS}..."
            sleep "$RESTART_DELAY"
            
            # We'll break here to let systemd restart the entire service
            break
        else
            # Reset restart attempts counter when things are working
            if [ "$restart_attempts" -gt 0 ]; then
                log info "Streams appear to be running again. Resetting restart counter."
                restart_attempts=0
            fi
        fi
        
        # Sleep to avoid high CPU usage
        sleep 5
    done
}

# Start the monitor function at the end of the script
capture_and_wait_for_children
EOF
    
    chmod +x "$STARTMIC_SERVICE"
    log INFO "Service-compatible script created successfully"
}

# Create the systemd service file
create_systemd_service() {
    log INFO "Creating systemd service..."
    
    # Check for MediaMTX service
    local MEDIA_DEPENDENCY="Wants=mediamtx.service"
    if command_exists systemctl && systemctl list-unit-files | grep -q mediamtx.service; then
        log INFO "Found mediamtx.service, setting as a soft dependency."
        
        # Check MediaMTX version if possible
        if command_exists mediamtx; then
            local MEDIAMTX_VERSION=$(mediamtx --version 2>&1 | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
            log INFO "Found mediamtx version ${MEDIAMTX_VERSION}, setting as a soft dependency."
        fi
    else
        log WARN "mediamtx.service not found. This service will be set as 'Wants' rather than 'Requires'."
    fi
    
    # Create the service file
    local SERVICE_FILE="/etc/systemd/system/audio-rtsp.service"
    
    # Backup existing service file if it exists
    if [ -f "$SERVICE_FILE" ]; then
        backup_file "$SERVICE_FILE"
    fi
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Audio RTSP Streaming Service
Documentation=file:$CONFIG_DIR/config
After=network.target mediamtx.service
$MEDIA_DEPENDENCY
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/bin
ExecStart=/usr/local/bin/startmic.sh
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=$RESTART_DELAY
# Give the service time to properly start all streams
TimeoutStartSec=30
# Set resource limits to ensure stability
LimitNOFILE=65536
# Make sure the process group is killed when the service is stopped
KillMode=process
KillSignal=SIGTERM
# Ensure environment is properly set up
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StandardOutput=append:$LOG_DIR/service.log
StandardError=append:$LOG_DIR/service-error.log
# Give the service a chance to clean up when stopping
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$SERVICE_FILE"
    log INFO "Systemd service file created successfully"
}

# Set up log rotation
setup_log_rotation() {
    log INFO "Setting up log rotation..."
    
    local ROTATION_FILE="/etc/logrotate.d/audio-rtsp"
    if [ -f "$ROTATION_FILE" ]; then
        backup_file "$ROTATION_FILE"
    fi
    
    cat > "$ROTATION_FILE" << EOF
$LOG_DIR/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 root root
    # Restart the service to ensure log file handles are properly reopened
    postrotate
        systemctl is-active --quiet audio-rtsp.service && systemctl restart audio-rtsp.service
    endscript
}
EOF

    chmod 644 "$ROTATION_FILE"
    log INFO "Log rotation configured"
}

# Create the status script
create_status_script() {
    log INFO "Creating status checking script..."
    
    local STATUS_SCRIPT="/usr/local/bin/check-audio-rtsp.sh"
    if [ -f "$STATUS_SCRIPT" ]; then
        backup_file "$STATUS_SCRIPT"
    fi
    
    cat > "$STATUS_SCRIPT" << 'EOF'
#!/bin/bash
# Set color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load configuration if available
CONFIG_FILE="/etc/audio-rtsp/config"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    # Default values if config not found
    RTSP_PORT=18554
    LOG_DIR=/var/log/audio-rtsp
fi

echo -e "${BLUE}Audio RTSP Service Status Check${NC}"
echo -e "${YELLOW}Service Status:${NC}"
if systemctl is-active --quiet audio-rtsp.service; then
    echo -e "${GREEN}Service is running${NC}"
    SERVICE_UPTIME=$(systemctl show audio-rtsp.service -p ActiveEnterTimestamp --value | xargs -I{} date -d {} "+%Y-%m-%d %H:%M:%S")
    CURRENT_TIME=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "Running since: ${GREEN}$SERVICE_UPTIME${NC}"
else
    echo -e "${RED}Service is NOT running${NC}"
fi
systemctl status audio-rtsp.service

echo -e "\n${YELLOW}Running Audio Streams:${NC}"
STREAMS=$(ps aux | grep "[f]fmpeg" | grep -o "rtsp://[^ ]*" | sort)
if [ -z "$STREAMS" ]; then
    echo -e "${RED}No active audio streams found${NC}"
    
    # Check if RTSP server is running on configured port
    echo -e "\n${YELLOW}Checking RTSP Server:${NC}"
    if nc -z localhost $RTSP_PORT >/dev/null 2>&1; then
        echo -e "${GREEN}RTSP server is accessible on port $RTSP_PORT${NC}"
    else
        echo -e "${RED}RTSP server is NOT accessible on port $RTSP_PORT${NC}"
        echo -e "${YELLOW}This is likely why streams are failing to connect${NC}"
    fi
    
    # Provide troubleshooting tips
    echo -e "\n${YELLOW}Troubleshooting Tips:${NC}"
    echo -e "1. Check service logs: ${GREEN}journalctl -u audio-rtsp -n 50${NC}"
    echo -e "2. Check ffmpeg status: ${GREEN}which ffmpeg && ffmpeg -version${NC}"
    echo -e "3. Verify MediaMTX is running: ${GREEN}systemctl status mediamtx${NC}"
    echo -e "4. Check config file: ${GREEN}cat $CONFIG_FILE${NC}"
    echo -e "5. Check MediaMTX configuration: ${GREEN}cat /etc/mediamtx/mediamtx.yml | grep rtspAddress${NC}"
    echo -e "6. Manually restart the service: ${GREEN}sudo systemctl restart audio-rtsp${NC}"
else
    echo -e "${GREEN}Found $(echo "$STREAMS" | wc -l) active streams:${NC}"
    echo -e "${GREEN}$STREAMS${NC}"
fi

echo -e "\n${YELLOW}Available Sound Cards:${NC}"
cat /proc/asound/cards

# Get the machine's IP address
IP_ADDR=$(hostname -I | awk '{print $1}')
if [ -n "$IP_ADDR" ]; then
    echo -e "\n${YELLOW}Network Information:${NC}"
    echo -e "To access streams from other devices, use: ${GREEN}$IP_ADDR${NC} instead of localhost"
fi

# Check system resources
echo -e "\n${YELLOW}System Resources:${NC}"
echo -e "Memory Usage: $(free -h | grep Mem | awk '{print $3"/"$2}' used)"
echo -e "CPU Load: $(uptime | awk -F'load average: ' '{print $2}')"
echo -e "Disk Space: $(df -h $LOG_DIR | tail -1 | awk '{print $5}') used on log partition"

# Check logs
echo -e "\n${YELLOW}Recent Log Entries:${NC}"
if [ -f "$LOG_DIR/audio-streams.log" ]; then
    echo -e "${GREEN}Last 10 log entries:${NC}"
    tail -n 10 "$LOG_DIR/audio-streams.log"
else
    echo -e "${RED}No log file found${NC}"
fi

echo -e "\n${YELLOW}Error Log:${NC}"
if [ -f "$LOG_DIR/service-error.log" ]; then
    if [ -s "$LOG_DIR/service-error.log" ]; then
        echo -e "${RED}Last 10 error entries:${NC}"
        tail -n 10 "$LOG_DIR/service-error.log"
    else
        echo -e "${GREEN}Error log is empty. No errors reported.${NC}"
    fi
else
    echo -e "${RED}No error log file found${NC}"
fi

echo -e "\n${YELLOW}Disk Space for Logs:${NC}"
du -sh "$LOG_DIR/"
EOF

    chmod +x "$STATUS_SCRIPT"
    log INFO "Status script created successfully"
}

# Create the uninstall script
create_uninstall_script() {
    log INFO "Creating uninstall script..."
    
    local UNINSTALL_SCRIPT="/usr/local/bin/uninstall-audio-rtsp.sh"
    if [ -f "$UNINSTALL_SCRIPT" ]; then
        backup_file "$UNINSTALL_SCRIPT"
    fi
    
    cat > "$UNINSTALL_SCRIPT" << 'EOF'
#!/bin/bash
# Uninstall Audio RTSP Service

# Define color codes for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

# Ask for confirmation
echo -e "${YELLOW}This will uninstall the Audio RTSP Streaming Service.${NC}"
read -p "Are you sure you want to continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${GREEN}Uninstallation cancelled.${NC}"
  exit 0
fi

echo -e "${YELLOW}Stopping and disabling service...${NC}"
systemctl stop audio-rtsp.service
systemctl disable audio-rtsp.service

echo -e "${YELLOW}Removing service files...${NC}"
rm -f /etc/systemd/system/audio-rtsp.service
systemctl daemon-reload

echo -e "${YELLOW}Removing scripts...${NC}"
rm -f /usr/local/bin/startmic.sh
rm -f /usr/local/bin/startmic.sh.original
rm -f /usr/local/bin/check-audio-rtsp.sh
rm -f /usr/local/bin/uninstall-audio-rtsp.sh
rm -f /usr/local/bin/configure-audio-rtsp.sh

echo -e "${YELLOW}Removing log configuration...${NC}"
rm -f /etc/logrotate.d/audio-rtsp

# Ask about configuration and logs
read -p "Do you want to remove configuration files too? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${YELLOW}Removing configuration directory...${NC}"
  rm -rf /etc/audio-rtsp
fi

read -p "Do you want to remove log files too? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo -e "${YELLOW}Removing log directory...${NC}"
  rm -rf /var/log/audio-rtsp
else
  echo -e "${GREEN}Log files in /var/log/audio-rtsp/ have been preserved.${NC}"
  echo -e "To remove them later, run: ${YELLOW}sudo rm -rf /var/log/audio-rtsp/${NC}"
fi

echo -e "${GREEN}Uninstallation complete!${NC}"
EOF

    chmod +x "$UNINSTALL_SCRIPT"
    log INFO "Uninstall script created successfully"
}

# Create configuration editor script
create_config_editor() {
    log INFO "Creating configuration editor script..."
    
    local CONFIG_EDITOR="/usr/local/bin/configure-audio-rtsp.sh"
    if [ -f "$CONFIG_EDITOR" ]; then
        backup_file "$CONFIG_EDITOR"
    fi
    
    cat > "$CONFIG_EDITOR" << 'EOF'
#!/bin/bash
# Audio RTSP Configuration Editor

# Define color codes for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

CONFIG_DIR="/etc/audio-rtsp"
CONFIG_FILE="${CONFIG_DIR}/config"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Please run as root${NC}"
  exit 1
fi

# Check if configuration exists
if [ ! -f "$CONFIG_FILE" ]; then
  echo -e "${RED}Configuration file not found. Please run the installation script first.${NC}"
  exit 1
fi

# Function to display current configuration
show_config() {
  echo -e "${BLUE}Current Configuration:${NC}"
  grep -v "^#" "$CONFIG_FILE" | while read line; do
    if [[ ! -z "$line" ]]; then
      key=$(echo "$line" | cut -d= -f1)
      value=$(echo "$line" | cut -d= -f2)
      echo -e "${YELLOW}$key${NC}=${GREEN}$value${NC}"
    fi
  done
}

# Show current configuration
show_config

# Menu for configuration
while true; do
  echo -e "\n${BLUE}Configuration Menu:${NC}"
  echo -e "1. Edit RTSP port (RTSP_PORT)"
  echo -e "2. Edit restart delay (RESTART_DELAY)"
  echo -e "3. Edit maximum restart attempts (MAX_RESTART_ATTEMPTS)"
  echo -e "4. Edit logging level (LOG_LEVEL)"
  echo -e "5. Edit log rotation days (LOG_ROTATE_DAYS)"
  echo -e "6. Save and restart service"
  echo -e "7. Save and exit"
  echo -e "8. Exit without saving"
  
  read -p "Select an option (1-8): " option
  
  case $option in
    1)
      read -p "Enter new RTSP port (current: $(grep RTSP_PORT "$CONFIG_FILE" | cut -d= -f2)): " new_value
      if [[ "$new_value" =~ ^[0-9]+$ ]]; then
        sed -i "s/RTSP_PORT=.*/RTSP_PORT=$new_value/" "$CONFIG_FILE"
        echo -e "${GREEN}RTSP port updated.${NC}"
        
        # Check if port is available
        if nc -z localhost $new_value >/dev/null 2>&1; then
          echo -e "${GREEN}Port $new_value is accessible.${NC}"
        else
          echo -e "${YELLOW}Warning: Port $new_value is not currently accessible.${NC}"
          echo -e "${YELLOW}Check that MediaMTX is configured to use this port.${NC}"
        fi
      else
        echo -e "${RED}Invalid input. Please enter a number.${NC}"
      fi
      ;;
    2)
      read -p "Enter new restart delay in seconds (current: $(grep RESTART_DELAY "$CONFIG_FILE" | cut -d= -f2)): " new_value
      if [[ "$new_value" =~ ^[0-9]+$ ]]; then
        sed -i "s/RESTART_DELAY=.*/RESTART_DELAY=$new_value/" "$CONFIG_FILE"
        echo -e "${GREEN}Restart delay updated.${NC}"
      else
        echo -e "${RED}Invalid input. Please enter a number.${NC}"
      fi
      ;;
    3)
      read -p "Enter new maximum restart attempts (current: $(grep MAX_RESTART_ATTEMPTS "$CONFIG_FILE" | cut -d= -f2)): " new_value
      if [[ "$new_value" =~ ^[0-9]+$ ]]; then
        sed -i "s/MAX_RESTART_ATTEMPTS=.*/MAX_RESTART_ATTEMPTS=$new_value/" "$CONFIG_FILE"
        echo -e "${GREEN}Maximum restart attempts updated.${NC}"
      else
        echo -e "${RED}Invalid input. Please enter a number.${NC}"
      fi
      ;;
    4)
      echo -e "Available logging levels: debug, info, warning, error"
      read -p "Enter new logging level (current: $(grep LOG_LEVEL "$CONFIG_FILE" | cut -d= -f2)): " new_value
      if [[ "$new_value" =~ ^(debug|info|warning|error)$ ]]; then
        sed -i "s/LOG_LEVEL=.*/LOG_LEVEL=$new_value/" "$CONFIG_FILE"
        echo -e "${GREEN}Logging level updated.${NC}"
      else
        echo -e "${RED}Invalid input. Please enter a valid logging level.${NC}"
      fi
      ;;
    5)
      read -p "Enter new log rotation days (current: $(grep LOG_ROTATE_DAYS "$CONFIG_FILE" | cut -d= -f2)): " new_value
      if [[ "$new_value" =~ ^[0-9]+$ ]]; then
        sed -i "s/LOG_ROTATE_DAYS=.*/LOG_ROTATE_DAYS=$new_value/" "$CONFIG_FILE"
        # Update logrotate config too
        sed -i "s/rotate [0-9]*/rotate $new_value/" /etc/logrotate.d/audio-rtsp
        echo -e "${GREEN}Log rotation days updated.${NC}"
      else
        echo -e "${RED}Invalid input. Please enter a number.${NC}"
      fi
      ;;
    6)
      echo -e "${YELLOW}Restarting audio-rtsp service...${NC}"
      systemctl daemon-reload
      systemctl restart audio-rtsp.service
      echo -e "${GREEN}Configuration saved and service restarted.${NC}"
      show_config
      exit 0
      ;;
    7)
      echo -e "${GREEN}Configuration saved.${NC}"
      show_config
      exit 0
      ;;
    8)
      echo -e "${YELLOW}Exiting without saving.${NC}"
      exit 0
      ;;
    *)
      echo -e "${RED}Invalid option. Please select 1-8.${NC}"
      ;;
  esac
done
EOF

    chmod +x "$CONFIG_EDITOR"
    log INFO "Configuration editor script created successfully"
}

# Enable and start the service
enable_and_start_service() {
    log INFO "Enabling and starting service..."
    
    # Reload systemd to recognize the new service
    systemctl daemon-reload
    
    # Verify the service file is valid
    if systemctl cat audio-rtsp.service &>/dev/null; then
        log INFO "Service file validated successfully"
        systemctl enable audio-rtsp.service
        
        # Try to start the service but handle failure gracefully
        if systemctl start audio-rtsp.service; then
            log INFO "Service started successfully"
        else
            log ERROR "Service failed to start. Check logs with:"
            echo "journalctl -u audio-rtsp.service"
            log ERROR "You may need to check your startmic.sh script for errors"
            return 1
        fi
    else
        log ERROR "Error in service file. Installation incomplete."
        return 1
    fi
    
    return 0
}

# Print success message
print_success_message() {
    echo -e "${GREEN}Installation complete!${NC}"
    echo -e "Audio RTSP streaming service is now set up to start automatically on boot."
    echo -e "Service management commands:"
    echo -e "  Check status: ${YELLOW}sudo systemctl status audio-rtsp${NC}"
    echo -e "  Start service: ${YELLOW}sudo systemctl start audio-rtsp${NC}"
    echo -e "  Stop service: ${YELLOW}sudo systemctl stop audio-rtsp${NC}"
    echo -e "  Restart service: ${YELLOW}sudo systemctl restart audio-rtsp${NC}"
    echo -e "Helper scripts:"
    echo -e "  Check service status: ${YELLOW}sudo check-audio-rtsp.sh${NC}"
    echo -e "  Edit configuration: ${YELLOW}sudo configure-audio-rtsp.sh${NC}"
    echo -e "  Uninstall service: ${YELLOW}sudo uninstall-audio-rtsp.sh${NC}"
    echo -e "Configuration and logs:"
    echo -e "  Config file: ${YELLOW}$CONFIG_FILE${NC}"
    echo -e "  Log directory: ${YELLOW}$LOG_DIR${NC}"
    echo -e "  View logs: ${YELLOW}sudo tail -f $LOG_DIR/audio-streams.log${NC}"
}

# Main script execution
echo -e "${BLUE}Audio RTSP Streaming Service Setup v${VERSION}${NC}"
echo -e "${GREEN}Setting up Audio RTSP Streaming Service...${NC}"

# Check if running as root
check_root

# Check dependencies
check_dependencies

# Validate original script exists and create backup
check_startmic

# Set up directories with proper permissions
setup_directories

# Create or update configuration file
create_config_file

# Install startmic.sh script
install_startmic_script

# Create systemd service 
create_systemd_service

# Set up log rotation
setup_log_rotation

# Create helper scripts
create_status_script
create_uninstall_script
create_config_editor

# Enable and start the service
enable_and_start_service || exit 1

# Print success message
print_success_message

exit 0

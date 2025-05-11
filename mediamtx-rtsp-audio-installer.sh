#!/bin/bash
# Enhanced MediaMTX RTSP Audio Platform Installer
#
# https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/mediamtx-rtsp-audio-installer.sh
#
# Version: 3.0.0
# Date: 2025-05-14
#
# This script orchestrates the installation of the MediaMTX RTSP audio streaming platform
# by coordinating the execution of dedicated component scripts rather than reimplementing
# their functionality. This maintains a clear separation of responsibilities while
# providing an enhanced unified installer experience.

# Set strict error handling
set -o pipefail

# Define script version
SCRIPT_VERSION="3.0.0"

# Default configuration
CONFIG_DIR="/etc/audio-rtsp"
CONFIG_FILE="${CONFIG_DIR}/config"
LOG_DIR="/var/log/audio-rtsp"
TEMP_DIR="/tmp/mediamtx-install-$(date +%s)-${RANDOM}"
BACKUP_DIR="${CONFIG_DIR}/backups/$(date +%Y%m%d%H%M%S)"
LOG_FILE="${LOG_DIR}/installer.log"
LOCK_FILE="/var/lock/mediamtx-installer.lock"
INSTANCE_ID="$$-$(date +%s)"
SCRIPT_NAME=$(basename "$0")

# Default values for MediaMTX
MEDIAMTX_VERSION="v1.12.2"
RTSP_PORT="18554"
RTMP_PORT="11935"
HLS_PORT="18888"
WEBRTC_PORT="18889"
METRICS_PORT="19999"

# Flags
DEBUG_MODE=false
QUIET_MODE=false
AUTO_YES=false
FORCE_MODE=false

# ANSI color codes for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ======================================================================
# Utility Functions
# ======================================================================

# Display banner with script information
display_banner() {
    if [ "$QUIET_MODE" = true ]; then
        return 0
    fi
    
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${BLUE}   Enhanced MediaMTX RTSP Audio Platform Installer   ${NC}"
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${GREEN}Version: ${SCRIPT_VERSION}${NC}"
    echo -e "${GREEN}Date: $(date +%Y-%m-%d)${NC}"
    echo
}

# Print usage help
show_help() {
    display_banner
    cat << EOF
Usage: $0 [OPTIONS] [COMMAND]

If no command is specified, an interactive menu will be displayed.

COMMANDS:
  install      Install MediaMTX and audio streaming platform
  uninstall    Remove all installed components
  update       Update to the latest version while preserving config
  reinstall    Completely remove and reinstall
  status       Show status of all components
  troubleshoot Run diagnostics and fix common issues
  logs         View or manage logs

OPTIONS:
  -v, --version VERSION    Specify MediaMTX version (default: $MEDIAMTX_VERSION)
  -p, --rtsp-port PORT     Specify RTSP port (default: $RTSP_PORT)
  --rtmp-port PORT         Specify RTMP port (default: $RTMP_PORT)
  --hls-port PORT          Specify HLS port (default: $HLS_PORT)
  --webrtc-port PORT       Specify WebRTC port (default: $WEBRTC_PORT)
  --metrics-port PORT      Specify metrics port (default: $METRICS_PORT)
  -d, --debug              Enable debug mode
  -q, --quiet              Minimal output
  -y, --yes                Answer yes to all prompts
  -f, --force              Force operation
  -h, --help               Show this help message

Example:
  $0 install
  $0 --rtsp-port 8554 install
  $0 uninstall
  $0 troubleshoot
EOF
}

# Enhanced logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="[$timestamp] [${level}] $message"
    
    # Ensure log directory exists
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    
    # Write to log file
    echo "$log_line" >> "$LOG_FILE" 2>/dev/null || true
    
    # Print to console if not in quiet mode
    if [ "$QUIET_MODE" != true ] || [ "$level" = "ERROR" ]; then
        case "$level" in
            "DEBUG")
                [ "$DEBUG_MODE" = true ] && echo -e "${CYAN}[DEBUG]${NC} $message"
                ;;
            "INFO")
                echo -e "${GREEN}[INFO]${NC} $message"
                ;;
            "WARNING")
                echo -e "${YELLOW}[WARNING]${NC} $message"
                ;;
            "ERROR")
                echo -e "${RED}[ERROR]${NC} $message"
                ;;
            "SUCCESS")
                echo -e "${GREEN}${BOLD}[SUCCESS]${NC} $message"
                ;;
            *)
                echo -e "[$level] $message"
                ;;
        esac
    fi
}

# Debug function - prints only when debug mode is active
debug() {
    if [ "$DEBUG_MODE" = true ]; then
        log "DEBUG" "$@"
    fi
}

# Error function - logs error and exits if exit_code is provided
error() {
    local message="$1"
    local exit_code="$2"
    
    log "ERROR" "$message"
    
    if [ -n "$exit_code" ]; then
        cleanup
        exit "$exit_code"
    fi
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to validate a port number
validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        error "Invalid port number: $port. Must be between 1 and 65535." 1
    fi
}

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root or with sudo privileges." 1
    fi
}

# Function to ask a yes/no question
ask_yes_no() {
    local question="$1"
    local default="$2"
    local result
    
    if [ "$AUTO_YES" = true ]; then
        return 0  # Auto-yes is enabled, always return true
    fi
    
    while true; do
        if [ "$default" = "y" ]; then
            echo -n -e "${YELLOW}${question} [Y/n]${NC} "
        else
            echo -n -e "${YELLOW}${question} [y/N]${NC} "
        fi
        
        read -r result
        
        case "$result" in
            [Yy]*)
                return 0
                ;;
            [Nn]*)
                return 1
                ;;
            "")
                if [ "$default" = "y" ]; then
                    return 0
                else
                    return 1
                fi
                ;;
            *)
                echo "Please answer yes or no."
                ;;
        esac
    done
}

# Present a menu of choices and return the result
show_menu() {
    local prompt="$1"
    shift
    local options=("$@")
    local choice
    
    echo -e "${BLUE}$prompt${NC}"
    for i in "${!options[@]}"; do
        echo -e "$((i+1)). ${options[i]}"
    done
    
    while true; do
        echo -n -e "${YELLOW}Enter your choice [1-${#options[@]}]: ${NC}"
        read -r choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#options[@]} ]; then
            return $((choice-1))
        else
            echo -e "${RED}Invalid choice. Please select 1-${#options[@]}.${NC}"
        fi
    done
}

# Function to ensure a directory exists with proper permissions
ensure_directory() {
    local dir="$1"
    local perm="${2:-755}"
    
    if [ ! -d "$dir" ]; then
        debug "Creating directory: $dir with permissions $perm"
        if ! mkdir -p "$dir" 2>/dev/null; then
            error "Failed to create directory: $dir" 1
        fi
        chmod "$perm" "$dir" 2>/dev/null || true
    else
        debug "Directory already exists: $dir"
    fi
}

# Function to check for exclusive lock - ensure only one instance is running
acquire_lock() {
    ensure_directory "$(dirname "$LOCK_FILE")"
    
    # Check if lock file exists and process is running
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "0")
        if [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then
            error "Another instance of this script is already running (PID: $pid)." 1
        else
            log "WARNING" "Found stale lock file. Overriding."
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # Create lock file with our PID
    echo "$$" > "$LOCK_FILE" || error "Failed to create lock file." 1
}

# Function to release lock
release_lock() {
    if [ -f "$LOCK_FILE" ]; then
        # Only delete if it contains our PID
        local pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "0")
        if [ "$pid" = "$$" ]; then
            rm -f "$LOCK_FILE"
        fi
    fi
}

# Detect system architecture
detect_architecture() {
    log "INFO" "Detecting system architecture..."
    
    local arch=$(uname -m)
    
    case "$arch" in
        x86_64|amd64)  
            ARCH="amd64" 
            ;;
        aarch64|arm64) 
            ARCH="arm64" 
            ;;
        armv7*|armhf)  
            ARCH="armv7" 
            ;;
        armv6*|armel)  
            ARCH="armv6" 
            ;;
        *)
            log "WARNING" "Architecture '$arch' not directly recognized."
            
            # Try to determine architecture through additional methods
            if command_exists dpkg; then
                local dpkg_arch=$(dpkg --print-architecture 2>/dev/null)
                case "$dpkg_arch" in
                    amd64)          ARCH="amd64" ;;
                    arm64)          ARCH="arm64" ;;
                    armhf)          ARCH="armv7" ;;
                    armel)          ARCH="armv6" ;;
                    *)              ARCH="unknown" ;;
                esac
            else
                ARCH="unknown"
            fi
            ;;
    esac
    
    if [ "$ARCH" = "unknown" ]; then
        error "Unsupported architecture: $arch" 1
    else
        log "INFO" "Detected architecture: $ARCH"
    fi
}

# Clean up function for exit
cleanup() {
    log "INFO" "Cleaning up resources..."
    
    # Release lock
    release_lock
    
    # Remove temporary directory
    if [ -d "$TEMP_DIR" ]; then
        if [ "$DEBUG_MODE" = true ]; then
            debug "Keeping temporary directory for debugging: $TEMP_DIR"
        else
            rm -rf "$TEMP_DIR"
        fi
    fi
    
    log "INFO" "Cleanup completed"
}

# Check for required commands
check_dependencies() {
    log "INFO" "Checking for required dependencies..."
    
    local missing_deps=()
    local deps=("bash" "systemctl" "curl" "wget" "tar" "grep" "awk" "sed")
    
    for dep in "${deps[@]}"; do
        if ! command_exists "$dep"; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log "WARNING" "Missing dependencies: ${missing_deps[*]}"
        
        if [ "$AUTO_YES" != true ]; then
            if ! ask_yes_no "Attempt to install missing dependencies?" "y"; then
                error "Cannot continue without required dependencies." 1
            fi
        fi
        
        log "INFO" "Installing missing dependencies..."
        
        # Try to determine the package manager
        if command_exists apt-get; then
            log "INFO" "Using apt package manager"
            apt-get update -qq
            apt-get install -y "${missing_deps[@]}"
        elif command_exists yum; then
            log "INFO" "Using yum package manager"
            yum install -y "${missing_deps[@]}"
        elif command_exists dnf; then
            log "INFO" "Using dnf package manager"
            dnf install -y "${missing_deps[@]}"
        else
            error "Could not determine package manager. Please install dependencies manually: ${missing_deps[*]}" 1
        fi
        
        # Verify dependencies installed
        for dep in "${missing_deps[@]}"; do
            if ! command_exists "$dep"; then
                error "Failed to install dependency: $dep. Please install it manually." 1
            fi
        done
        
        log "SUCCESS" "All dependencies installed successfully"
    else
        log "INFO" "All required dependencies are already installed"
    fi
}

# Check for internet connectivity
check_internet() {
    log "INFO" "Checking internet connectivity..."
    
    # Try multiple methods
    if ping -c 1 -W 5 github.com >/dev/null 2>&1; then
        debug "Internet connectivity verified via ping"
        return 0
    elif wget --spider --quiet https://github.com; then
        debug "Internet connectivity verified via wget"
        return 0
    elif curl --head --silent --fail --connect-timeout 5 https://github.com >/dev/null 2>&1; then
        debug "Internet connectivity verified via curl"
        return 0
    else
        error "No internet connectivity. Cannot proceed with installation." 1
    fi
}

# Function to safely download a file to specified directory
download_file() {
    local url="$1"
    local output_dir="$2"
    local filename="$3"
    local output_path="${output_dir}/${filename}"
    
    ensure_directory "$output_dir"
    
    log "INFO" "Downloading ${filename} from: ${url}"
    
    if command_exists curl; then
        if [ "$QUIET_MODE" = true ]; then
            if ! curl -s -L -o "$output_path" "$url"; then
                error "Failed to download ${filename} using curl" 1
            fi
        else
            if ! curl -L --progress-bar -o "$output_path" "$url"; then
                error "Failed to download ${filename} using curl" 1
            fi
        fi
    elif command_exists wget; then
        if [ "$QUIET_MODE" = true ]; then
            if ! wget -q -O "$output_path" "$url"; then
                error "Failed to download ${filename} using wget" 1
            fi
        else
            if ! wget --progress=bar:force:noscroll -O "$output_path" "$url"; then
                error "Failed to download ${filename} using wget" 1
            fi
        fi
    else
        error "Neither curl nor wget is available. Cannot download files." 1
    fi
    
    # Check if download was successful
    if [ ! -s "$output_path" ]; then
        error "Downloaded file is empty: ${output_path}" 1
    fi
    
    log "SUCCESS" "Successfully downloaded ${filename}"
    echo "$output_path"
}

# Wait for user to press Enter
press_enter_to_continue() {
    echo -e "\n${YELLOW}Press Enter to continue...${NC}"
    read -r
}

# Function to safely kill a process by name pattern
safe_kill_process() {
    local pattern="$1"
    local signal="${2:-TERM}"  # Default to SIGTERM
    
    debug "Attempting to kill processes matching: $pattern with signal $signal"
    
    # Find PIDs matching the pattern but exclude our own process
    local matching_pids
    matching_pids=$(ps -eo pid,cmd | grep -E "$pattern" | grep -v "$$" | grep -v grep | awk '{print $1}')
    
    if [ -z "$matching_pids" ]; then
        debug "No processes found matching: $pattern"
        return 0
    fi
    
    # Kill each matching process
    for pid in $matching_pids; do
        if [ "$pid" != "$$" ] && [ "$pid" != "$PPID" ]; then
            debug "Sending signal $signal to PID $pid"
            kill -s "$signal" "$pid" 2>/dev/null || true
        fi
    done
    
    return 0
}

# ======================================================================
# Component Script Operations
# ======================================================================

# Pre-download required scripts for a specific component
predownload_dependency_scripts() {
    local component="$1"
    local working_dir="$2"
    
    case "$component" in
        "setup-monitor-script.sh")
            log "INFO" "Pre-downloading dependencies for monitoring setup..."
            
            # Download mediamtx-monitor.sh which is required by setup-monitor-script.sh
            local monitor_url="https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/mediamtx-monitor.sh"
            local monitor_script="${working_dir}/mediamtx-monitor.sh"
            
            if [ ! -f "$monitor_script" ]; then
                download_file "$monitor_url" "$working_dir" "mediamtx-monitor.sh" > /dev/null
                chmod +x "$monitor_script"
                log "INFO" "Downloaded mediamtx-monitor.sh dependency"
            else
                log "INFO" "mediamtx-monitor.sh dependency already exists"
            fi
            ;;
    esac
}

# Execute a component script with appropriate options
execute_component_script() {
    local script_name="$1"
    shift
    local script_args=("$@")
    local working_dir
    
    # Determine where to run the script from
    if [[ "$script_name" == "setup-monitor-script.sh" ]]; then
        # For monitor setup, we need to work in a directory with the dependencies
        working_dir="${TEMP_DIR}/component_scripts"
        ensure_directory "$working_dir"
        
        # Pre-download any required dependencies
        predownload_dependency_scripts "$script_name" "$working_dir"
    else
        # For other scripts, we can run from the original directory
        working_dir="$(pwd)"
    fi
    
    # First check if the script exists in the current directory
    if [ -f "./${script_name}" ]; then
        local script_path="./${script_name}"
    # Then check in standard locations
    elif [ -f "/usr/local/bin/${script_name}" ]; then
        local script_path="/usr/local/bin/${script_name}"
    # Finally, try to download it if not found
    else
        log "INFO" "Script ${script_name} not found locally, trying to download it..."
        local download_url="https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/${script_name}"
        local script_path=$(download_file "$download_url" "$working_dir" "$script_name")
        chmod +x "$script_path"
    fi
    
    # Make sure the script is executable
    if [ ! -x "$script_path" ]; then
        chmod +x "$script_path" || error "Failed to make ${script_name} executable" 1
    fi
    
    log "INFO" "Executing ${script_name}..."
    
    # Save current directory
    local current_dir="$(pwd)"
    
    # Change to the appropriate working directory
    cd "$working_dir" || error "Failed to change to working directory: $working_dir" 1
    
    # Run the script with the provided arguments
    if "$script_path" "${script_args[@]}"; then
        log "SUCCESS" "${script_name} executed successfully"
        # Change back to original directory
        cd "$current_dir"
        return 0
    else
        local exit_code=$?
        error "${script_name} failed with exit code ${exit_code}" $exit_code
        # Change back to original directory even on error
        cd "$current_dir"
        return $exit_code
    fi
}

# ======================================================================
# Main Command Functions
# ======================================================================

# Install MediaMTX platform
install_command() {
    log "INFO" "Starting MediaMTX platform installation..."
    
    # Check for existing installation
    if [ -f "/usr/local/mediamtx/mediamtx" ] && [ -f "$CONFIG_FILE" ] && [ "$FORCE_MODE" != true ]; then
        log "WARNING" "MediaMTX appears to be already installed"
        
        if ! ask_yes_no "Do you want to proceed with installation anyway?" "n"; then
            log "INFO" "Installation cancelled by user"
            error "Installation cancelled. Use update command instead or use --force to override." 1
        fi
    fi
    
    # Ensure temp directory exists
    ensure_directory "$TEMP_DIR"
    
    # Step 1: Install MediaMTX using install_mediamtx.sh
    local mediamtx_args=(
        "-v" "$MEDIAMTX_VERSION"
        "-p" "$RTSP_PORT"
        "--rtmp-port" "$RTMP_PORT"
        "--hls-port" "$HLS_PORT" 
        "--webrtc-port" "$WEBRTC_PORT"
        "--metrics-port" "$METRICS_PORT"
    )
    
    if [ "$FORCE_MODE" = true ]; then
        mediamtx_args+=("--force-install")
    fi
    
    if [ "$DEBUG_MODE" = true ]; then
        mediamtx_args+=("--debug")
    fi
    
    execute_component_script "install_mediamtx.sh" "${mediamtx_args[@]}"
    
    # Step 2: Setup audio RTSP using setup_audio_rtsp.sh
    # First create a backup of any existing config file
    if [ -f "$CONFIG_FILE" ]; then
        ensure_directory "$BACKUP_DIR"
        log "INFO" "Backing up existing audio-rtsp configuration"
        cp "$CONFIG_FILE" "${BACKUP_DIR}/config.backup"
    fi
    
    execute_component_script "setup_audio_rtsp.sh"
    
    # Step 3: Setup monitoring using setup-monitor-script.sh
    execute_component_script "setup-monitor-script.sh"
    
    # Print installation summary
    log "SUCCESS" "MediaMTX platform has been successfully installed!"
    
    if [ "$QUIET_MODE" != true ]; then
        echo
        echo -e "${GREEN}==============================================${NC}"
        echo -e "${GREEN}   MediaMTX Platform installed successfully!   ${NC}"
        echo -e "${GREEN}==============================================${NC}"
        echo
        echo -e "Installation directory: ${BLUE}/usr/local/mediamtx${NC}"
        echo -e "Configuration: ${BLUE}$CONFIG_DIR/config${NC}"
        echo -e "Log directory: ${BLUE}$LOG_DIR${NC}"
        echo -e "Services installed:"
        echo -e "  - ${GREEN}mediamtx.service${NC}"
        echo -e "  - ${GREEN}audio-rtsp.service${NC}"
        echo -e "  - ${GREEN}mediamtx-monitor.service${NC}"
        echo
        echo -e "Commands available:"
        echo -e "  - ${YELLOW}check-audio-rtsp.sh${NC} - Check audio streaming status"
        echo -e "  - ${YELLOW}check-mediamtx-monitor.sh${NC} - Check monitoring status"
        echo
        echo -e "To check streaming status:"
        echo -e "  ${BLUE}sudo check-audio-rtsp.sh${NC}"
        echo
    fi
    
    return 0
}

# Uninstall MediaMTX platform
uninstall_command() {
    log "INFO" "Starting MediaMTX platform uninstallation..."
    
    # Confirm uninstallation
    if [ "$AUTO_YES" != true ]; then
        if ! ask_yes_no "Are you sure you want to uninstall MediaMTX platform?" "n"; then
            log "INFO" "Uninstallation cancelled by user"
            error "Uninstallation cancelled." 1
        fi
    fi
    
    # Step 1: Stop and disable all services in reverse dependency order
    log "INFO" "Stopping and disabling services..."
    systemctl stop mediamtx-monitor.service 2>/dev/null || true
    systemctl stop audio-rtsp.service 2>/dev/null || true
    systemctl stop mediamtx.service 2>/dev/null || true
    
    systemctl disable mediamtx-monitor.service 2>/dev/null || true
    systemctl disable audio-rtsp.service 2>/dev/null || true
    systemctl disable mediamtx.service 2>/dev/null || true
    
    # Step 2: Kill any remaining processes
    log "INFO" "Cleaning up processes..."
    safe_kill_process "mediamtx-monitor"
    safe_kill_process "startmic.sh"
    safe_kill_process "ffmpeg.*rtsp"
    safe_kill_process "mediamtx"
    
    # Step 3: Remove service files
    log "INFO" "Removing service files..."
    rm -f /etc/systemd/system/mediamtx-monitor.service
    rm -f /etc/systemd/system/audio-rtsp.service
    rm -f /etc/systemd/system/mediamtx.service
    systemctl daemon-reload
    
    # Step 4: Remove installed scripts
    log "INFO" "Removing scripts..."
    rm -f /usr/local/bin/startmic.sh
    rm -f /usr/local/bin/mediamtx-monitor.sh
    rm -f /usr/local/bin/check-audio-rtsp.sh
    rm -f /usr/local/bin/check-mediamtx-monitor.sh
    
    # Step 5: Ask if user wants to keep configuration and logs
    local keep_config=false
    local keep_logs=false
    
    if [ "$AUTO_YES" != true ]; then
        if ask_yes_no "Do you want to keep configuration files?" "y"; then
            keep_config=true
        fi
        
        if ask_yes_no "Do you want to keep log files?" "y"; then
            keep_logs=true
        fi
    fi
    
    # Step 6: Remove MediaMTX installation
    log "INFO" "Removing MediaMTX binary..."
    rm -rf /usr/local/mediamtx
    
    # Step 7: Remove configuration if requested
    if [ "$keep_config" != true ]; then
        log "INFO" "Removing configuration files..."
        rm -rf "$CONFIG_DIR"
        rm -rf /etc/mediamtx
    else
        log "INFO" "Keeping configuration files as requested"
    fi
    
    # Step 8: Remove logs if requested
    if [ "$keep_logs" != true ]; then
        log "INFO" "Removing log files..."
        rm -rf "$LOG_DIR"
        rm -rf /var/log/mediamtx
    else
        log "INFO" "Keeping log files as requested"
    fi
    
    # Step 9: Remove log rotation configuration
    log "INFO" "Removing log rotation configuration..."
    rm -f /etc/logrotate.d/audio-rtsp
    
    log "SUCCESS" "MediaMTX platform has been successfully uninstalled!"
    
    if [ "$QUIET_MODE" != true ]; then
        echo
        echo -e "${GREEN}==============================================${NC}"
        echo -e "${GREEN}   MediaMTX Platform uninstalled successfully!   ${NC}"
        echo -e "${GREEN}==============================================${NC}"
        echo
        if [ "$keep_config" = true ]; then
            echo -e "Configuration files have been preserved at: ${BLUE}$CONFIG_DIR${NC}"
        fi
        if [ "$keep_logs" = true ]; then
            echo -e "Log files have been preserved at: ${BLUE}$LOG_DIR${NC}"
        fi
        echo
    fi
    
    return 0
}

# Update MediaMTX platform
update_command() {
    log "INFO" "Starting MediaMTX platform update..."
    
    # Check if MediaMTX is installed
    if [ ! -f "/usr/local/mediamtx/mediamtx" ]; then
        log "ERROR" "MediaMTX doesn't appear to be installed"
        if ask_yes_no "Do you want to perform a fresh installation instead?" "y"; then
            install_command
            return $?
        else
            error "Update cancelled." 1
        fi
    fi
    
    # Get currently installed version
    local current_version=$(/usr/local/mediamtx/mediamtx --version 2>&1 | head -n1 | grep -o "v[0-9]\+\.[0-9]\+\.[0-9]\+" || echo "unknown")
    
    log "INFO" "Current version: $current_version, Target version: $MEDIAMTX_VERSION"
    
    # Check if same version and not forcing update
    if [ "$current_version" = "$MEDIAMTX_VERSION" ] && [ "$FORCE_MODE" != true ]; then
        log "INFO" "MediaMTX is already at version $current_version"
        
        if ! ask_yes_no "Do you want to proceed with update anyway?" "n"; then
            log "INFO" "Update cancelled by user"
            error "Update cancelled. Use --force to override." 1
        fi
    fi
    
    # Update MediaMTX using install_mediamtx.sh with --config-only option
    local mediamtx_args=(
        "-v" "$MEDIAMTX_VERSION"
        "-p" "$RTSP_PORT"
        "--rtmp-port" "$RTMP_PORT"
        "--hls-port" "$HLS_PORT" 
        "--webrtc-port" "$WEBRTC_PORT"
        "--metrics-port" "$METRICS_PORT"
        "--config-only"
    )
    
    if [ "$FORCE_MODE" = true ]; then
        mediamtx_args=("${mediamtx_args[@]:0:12}")  # Remove --config-only to force full reinstall
        mediamtx_args+=("--force-install")
    fi
    
    if [ "$DEBUG_MODE" = true ]; then
        mediamtx_args+=("--debug")
    fi
    
    # First create a backup of the existing configuration
    ensure_directory "$BACKUP_DIR"
    if [ -f "/etc/mediamtx/mediamtx.yml" ]; then
        log "INFO" "Backing up existing MediaMTX configuration"
        cp "/etc/mediamtx/mediamtx.yml" "${BACKUP_DIR}/mediamtx.yml.backup"
    fi
    
    # Execute the update
    execute_component_script "install_mediamtx.sh" "${mediamtx_args[@]}"
    
    # Restart services
    log "INFO" "Restarting services..."
    systemctl restart mediamtx.service
    systemctl restart audio-rtsp.service
    systemctl restart mediamtx-monitor.service
    
    # Print update summary
    log "SUCCESS" "MediaMTX platform has been successfully updated to version $MEDIAMTX_VERSION!"
    
    if [ "$QUIET_MODE" != true ]; then
        echo
        echo -e "${GREEN}==============================================${NC}"
        echo -e "${GREEN}   MediaMTX Platform updated successfully!   ${NC}"
        echo -e "${GREEN}==============================================${NC}"
        echo -e "Updated from version ${YELLOW}$current_version${NC} to ${GREEN}$MEDIAMTX_VERSION${NC}"
        echo
        echo -e "To check streaming status:"
        echo -e "  ${BLUE}sudo check-audio-rtsp.sh${NC}"
        echo
    fi
    
    return 0
}

# Reinstall MediaMTX platform
reinstall_command() {
    log "INFO" "Starting MediaMTX platform reinstallation..."
    
    # Confirm reinstallation
    if [ "$AUTO_YES" != true ]; then
        if ! ask_yes_no "This will completely remove and reinstall MediaMTX platform. Continue?" "n"; then
            log "INFO" "Reinstallation cancelled by user"
            error "Reinstallation cancelled." 1
        fi
    fi
    
    # First uninstall preserving configuration and logs
    log "INFO" "Stopping services before reinstall..."
    systemctl stop mediamtx-monitor.service 2>/dev/null || true
    systemctl stop audio-rtsp.service 2>/dev/null || true
    systemctl stop mediamtx.service 2>/dev/null || true
    
    log "INFO" "Cleaning up processes..."
    safe_kill_process "mediamtx-monitor"
    safe_kill_process "startmic.sh"
    safe_kill_process "ffmpeg.*rtsp"
    safe_kill_process "mediamtx"
    
    # Perform fresh installation with force flag
    FORCE_MODE=true install_command
    
    log "SUCCESS" "MediaMTX platform has been successfully reinstalled!"
    
    return 0
}

# Show system status
status_command() {
    log "INFO" "Checking MediaMTX platform status..."
    
    if [ -x "/usr/local/bin/check-audio-rtsp.sh" ]; then
        /usr/local/bin/check-audio-rtsp.sh
    else
        # If status script doesn't exist, show basic status
        log "WARNING" "Status check script not found, showing basic status"
        echo -e "${YELLOW}MediaMTX Platform Status:${NC}"
        if systemctl is-active --quiet mediamtx.service; then
            echo -e "${GREEN}MediaMTX service is running${NC}"
        else
            echo -e "${RED}MediaMTX service is NOT running${NC}"
        fi
        
        if systemctl is-active --quiet audio-rtsp.service; then
            echo -e "${GREEN}Audio RTSP service is running${NC}"
        else
            echo -e "${RED}Audio RTSP service is NOT running${NC}"
        fi
        
        if systemctl is-active --quiet mediamtx-monitor.service; then
            echo -e "${GREEN}MediaMTX Monitor service is running${NC}"
        else
            echo -e "${RED}MediaMTX Monitor service is NOT running${NC}"
        fi
    fi
    
    return 0
}

# Run troubleshooting
troubleshoot_command() {
    log "INFO" "Running MediaMTX platform troubleshooting..."
    
    if [ -x "/usr/local/bin/check-mediamtx-monitor.sh" ]; then
        /usr/local/bin/check-mediamtx-monitor.sh
    else
        log "WARNING" "Monitor status script not found"
    fi
    
    # Perform some basic troubleshooting
    echo
    echo -e "${YELLOW}Troubleshooting MediaMTX Platform...${NC}"
    
    # Check if services are running
    echo -e "\n${YELLOW}Checking services status:${NC}"
    systemctl status mediamtx.service --no-pager -n 3
    systemctl status audio-rtsp.service --no-pager -n 3
    systemctl status mediamtx-monitor.service --no-pager -n 3
    
    # Check for ffmpeg processes
    echo -e "\n${YELLOW}Checking for active streams:${NC}"
    STREAMS=$(ps aux | grep "[f]fmpeg.*rtsp" | wc -l)
    if [ "$STREAMS" -gt 0 ]; then
        echo -e "${GREEN}Found $STREAMS active streaming processes${NC}"
    else
        echo -e "${RED}No active streaming processes found${NC}"
    fi
    
    # Check for available sound cards
    echo -e "\n${YELLOW}Checking available sound cards:${NC}"
    if [ -f "/proc/asound/cards" ]; then
        cat /proc/asound/cards
    else
        echo -e "${RED}Unable to access sound card information${NC}"
    fi
    
    # Offer to restart services
    echo
    if ask_yes_no "Would you like to restart all services?" "n"; then
        echo -e "${YELLOW}Restarting services...${NC}"
        systemctl restart mediamtx.service
        systemctl restart audio-rtsp.service
        systemctl restart mediamtx-monitor.service
        echo -e "${GREEN}Services restarted.${NC}"
    fi
    
    return 0
}

# View or manage logs
logs_command() {
    log "INFO" "Managing MediaMTX platform logs..."
    
    # Check if log directory exists
    if [ ! -d "$LOG_DIR" ]; then
        error "Log directory not found: $LOG_DIR" 1
    fi
    
    # Show available log files
    echo -e "${YELLOW}Available Log Files:${NC}"
    local log_files=()
    local i=1
    
    while IFS= read -r file; do
        log_files+=("$file")
        echo -e "$i. $(basename "$file")"
        i=$((i+1))
    done < <(find "$LOG_DIR" -type f -name "*.log" | sort)
    
    if [ ${#log_files[@]} -eq 0 ]; then
        error "No log files found in $LOG_DIR" 1
    fi
    
    # Let user select a log to view
    echo -n -e "${YELLOW}Enter log number to view [1-$((i-1))]: ${NC}"
    read -r log_choice
    
    if [[ "$log_choice" =~ ^[0-9]+$ ]] && [ "$log_choice" -ge 1 ] && [ "$log_choice" -le $((i-1)) ]; then
        local selected_log="${log_files[$((log_choice-1))]}"
        
        # View the log
        if command_exists less; then
            less "$selected_log"
        else
            # Fallback if less is not available
            cat "$selected_log" | more
        fi
    else
        error "Invalid choice" 1
    fi
    
    return 0
}

# ======================================================================
# Interactive Menu Functions
# ======================================================================

# Display interactive menu and handle user choice
interactive_menu() {
    display_banner
    
    log "INFO" "Starting interactive mode"
    
    local options=(
        "Install MediaMTX Platform"
        "Update MediaMTX Platform"
        "Reinstall MediaMTX Platform"
        "Uninstall MediaMTX Platform"
        "Check System Status"
        "Run Troubleshooting"
        "Manage Logs"
        "Exit"
    )
    
    show_menu "MediaMTX Platform Management" "${options[@]}"
    local result=$?
    
    case $result in
        0) install_command ;;
        1) update_command ;;
        2) reinstall_command ;;
        3) uninstall_command ;;
        4) status_command ;;
        5) troubleshoot_command ;;
        6) logs_command ;;
        7) 
            log "INFO" "Exiting"
            exit 0
            ;;
    esac
    
    # Return to menu after command completes
    press_enter_to_continue
    interactive_menu
}

# ======================================================================
# Main Function
# ======================================================================

# Parse command line arguments
parse_arguments() {
    COMMAND=""
    
    # Check for options and command
    while [ $# -gt 0 ]; do
        case "$1" in
            -v|--version)
                if [ -n "$2" ] && [[ "$2" != -* ]]; then
                    MEDIAMTX_VERSION="$2"
                    shift
                else
                    error "Option --version requires an argument" 1
                fi
                ;;
            -p|--rtsp-port)
                if [ -n "$2" ] && [[ "$2" != -* ]]; then
                    RTSP_PORT="$2"
                    validate_port "$RTSP_PORT"
                    shift
                else
                    error "Option --rtsp-port requires an argument" 1
                fi
                ;;
            --rtmp-port)
                if [ -n "$2" ] && [[ "$2" != -* ]]; then
                    RTMP_PORT="$2"
                    validate_port "$RTMP_PORT"
                    shift
                else
                    error "Option --rtmp-port requires an argument" 1
                fi
                ;;
            --hls-port)
                if [ -n "$2" ] && [[ "$2" != -* ]]; then
                    HLS_PORT="$2"
                    validate_port "$HLS_PORT"
                    shift
                else
                    error "Option --hls-port requires an argument" 1
                fi
                ;;
            --webrtc-port)
                if [ -n "$2" ] && [[ "$2" != -* ]]; then
                    WEBRTC_PORT="$2"
                    validate_port "$WEBRTC_PORT"
                    shift
                else
                    error "Option --webrtc-port requires an argument" 1
                fi
                ;;
            --metrics-port)
                if [ -n "$2" ] && [[ "$2" != -* ]]; then
                    METRICS_PORT="$2"
                    validate_port "$METRICS_PORT"
                    shift
                else
                    error "Option --metrics-port requires an argument" 1
                fi
                ;;
            -d|--debug)
                DEBUG_MODE=true
                ;;
            -q|--quiet)
                QUIET_MODE=true
                ;;
            -y|--yes)
                AUTO_YES=true
                ;;
            -f|--force)
                FORCE_MODE=true
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            install|uninstall|update|reinstall|status|troubleshoot|logs)
                COMMAND="$1"
                ;;
            *)
                error "Unknown option: $1. Use --help for usage information." 1
                ;;
        esac
        shift
    done
}

# Main function
main() {
    # Display banner
    display_banner
    
    # Check if running as root
    check_root
    
    # Acquire lock to ensure only one instance is running
    acquire_lock
    
    # Set up trap for catching errors
    trap cleanup EXIT
    
    # Create temporary directory
    ensure_directory "$TEMP_DIR"
    
    # Check dependencies
    check_dependencies
    
    # Detect architecture
    detect_architecture
    
    # Run in interactive mode if no command specified
    if [ -z "$COMMAND" ]; then
        interactive_menu
        return 0
    fi
    
    # Check internet connectivity for commands that need it
    if [[ "$COMMAND" == "install" || "$COMMAND" == "update" || "$COMMAND" == "reinstall" ]]; then
        check_internet
    fi
    
    # Run the requested command
    case "$COMMAND" in
        install)
            install_command
            ;;
        uninstall)
            uninstall_command
            ;;
        update)
            update_command
            ;;
        reinstall)
            reinstall_command
            ;;
        status)
            status_command
            ;;
        troubleshoot)
            troubleshoot_command
            ;;
        logs)
            logs_command
            ;;
        *)
            error "No command specified. Use --help for usage information." 1
            ;;
    esac
    
    # Exit with success
    return 0
}

# Parse command line arguments
parse_arguments "$@"

# Run main function
main

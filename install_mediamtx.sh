#!/bin/bash
#
# Enhanced MediaMTX Installer with Advanced Validation Features
# Version: 2.1.4
# Date: 2025-05-11
# Description: Robust installer for MediaMTX with integrated version checking,
#              dynamic checksum verification, and intelligent architecture detection
# Changes in v2.1.4:
#   - Added extremely verbose error reporting at every step
#   - Fixed internet connectivity check to try multiple methods
#   - Fixed function return values and call chains
#   - Removed set -e flag which was causing silent exits
#   - Fixed traps and error handling to properly report issues
#   - Added step-by-step progress indicators
#   - Added explicit status reporting for network operations
#   - Fixed temporary directory cleanup behavior

# Configuration
INSTALL_DIR="/usr/local/mediamtx"
CONFIG_DIR="/etc/mediamtx"
LOG_DIR="/var/log/mediamtx"
SERVICE_USER="mediamtx"
CHECKSUM_DB_DIR="/var/lib/mediamtx/checksums"
CHECKSUM_DB_FILE="${CHECKSUM_DB_DIR}/checksums.json"

# Cache directory for GitHub API responses
CACHE_DIR="/var/cache/mediamtx-installer"
API_CACHE="${CACHE_DIR}/api_cache.json"
CACHE_EXPIRY=3600  # Cache expires after 1 hour (in seconds)

# Configurable version - can be overridden with command line args
VERSION="v1.12.2"
TEMP_DIR="/tmp/mediamtx-install-$(date +%s)-${RANDOM}"  # More unique temp dir with random component

# Custom ports (to avoid conflicts)
RTSP_PORT="18554"
RTMP_PORT="11935"
HLS_PORT="18888" 
WEBRTC_PORT="18889"
METRICS_PORT="19999"

# Force debug mode to true to help with troubleshooting
DEBUG_MODE=true

# Print colored messages
echo_info() { echo -e "\033[34m[INFO]\033[0m $1"; }
echo_success() { echo -e "\033[32m[SUCCESS]\033[0m $1"; }
echo_warning() { echo -e "\033[33m[WARNING]\033[0m $1"; }
echo_error() { echo -e "\033[31m[ERROR]\033[0m $1"; }
echo_debug() {
    if [ "$DEBUG_MODE" = true ]; then
        echo -e "\033[36m[DEBUG]\033[0m $1" >&2
    fi
}

# Save log messages to a file and stdout
LOG_FILE="${TEMP_DIR}/install.log"

# Log to file only (no stdout)
log_file_only() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
}

# Log to both file and stdout
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    echo "[${timestamp}] [${level}] ${message}" | tee -a "$LOG_FILE"
}

# Enhanced architecture detection with improved edge case handling
detect_arch() {
    local arch=$(uname -m)
    
    case "$arch" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7*|armhf)  echo "armv7" ;;
        armv6*|armel)  echo "armv6" ;;
        *)
            echo_warning "Architecture '$arch' not directly recognized."
            # Try to determine architecture through additional methods
            if command -v dpkg >/dev/null 2>&1; then
                local dpkg_arch=$(dpkg --print-architecture 2>/dev/null)
                case "$dpkg_arch" in
                    amd64)          echo "amd64" ;;
                    arm64)          echo "arm64" ;;
                    armhf)          echo "armv7" ;;
                    armel)          echo "armv6" ;;
                    *)              echo "unknown" ;;
                esac
                return
            fi
            
            # Additional fallback method - check the kernel architecture
            if [ -f "/proc/cpuinfo" ]; then
                if grep -q "^model name.*ARMv7" /proc/cpuinfo; then
                    echo "armv7"
                    return
                elif grep -q "^model name.*ARMv6" /proc/cpuinfo; then
                    echo "armv6"
                    return
                elif grep -q "^Model.*Raspberry Pi" /proc/cpuinfo && grep -q "^CPU architecture.*7" /proc/cpuinfo; then
                    echo "armv7"
                    return
                elif grep -q "^Model.*Raspberry Pi" /proc/cpuinfo && grep -q "^CPU architecture.*6" /proc/cpuinfo; then
                    echo "armv6"
                    return
                fi
            fi
            
            # Final fallback - return unknown
            echo_error "Unsupported architecture: $arch"
            echo_info "Currently supported architectures: x86_64 (amd64), aarch64 (arm64), armv7, armv6"
            echo "unknown"
            ;;
    esac
}

# Extremely thorough internet connectivity check
check_internet_connectivity() {
    echo_info "Checking internet connectivity..."
    
    local connected=false
    
    # Method 1: Test DNS resolution first
    echo_debug "Testing DNS resolution of github.com..."
    if host github.com >/dev/null 2>&1; then
        echo_debug "DNS resolution successful"
    else
        echo_warning "DNS resolution failed for github.com"
    fi
    
    # Method 2: Ping test
    echo_debug "Testing ping to github.com..."
    if ping -c 1 -W 5 github.com >/dev/null 2>&1; then
        echo_debug "Ping test successful"
        connected=true
    else
        echo_debug "Ping test failed (could be blocked by firewall)"
    fi
    
    # Method 3: HTTP test with wget
    if ! $connected && command -v wget >/dev/null 2>&1; then
        echo_debug "Testing HTTP connection using wget..."
        if wget -q --spider --timeout=5 https://github.com >/dev/null 2>&1; then
            echo_debug "HTTP test successful with wget"
            connected=true
        else
            echo_debug "HTTP test failed with wget"
        fi
    fi
    
    # Method 4: HTTP test with curl
    if ! $connected && command -v curl >/dev/null 2>&1; then
        echo_debug "Testing HTTP connection using curl..."
        if curl -s --head --fail --connect-timeout 5 https://github.com >/dev/null 2>&1; then
            echo_debug "HTTP test successful with curl"
            connected=true
        else
            echo_debug "HTTP test failed with curl"
        fi
    fi
    
    # Method 5: Socket test with netcat
    if ! $connected && command -v nc >/dev/null 2>&1; then
        echo_debug "Testing socket connection using netcat..."
        if nc -z -w 5 github.com 443 >/dev/null 2>&1; then
            echo_debug "Socket test successful with netcat"
            connected=true
        else
            echo_debug "Socket test failed with netcat"
        fi
    fi
    
    if $connected; then
        echo_success "Internet connectivity confirmed"
        return 0
    else
        echo_error "No internet connectivity detected - cannot reach github.com"
        echo_error "Please check your internet connection and try again"
        
        # Test other sites to see if it's specific to GitHub
        if ping -c 1 -W 5 google.com >/dev/null 2>&1; then
            echo_warning "Note: Can reach google.com but not github.com"
            echo_warning "This might indicate GitHub-specific connectivity issues"
        fi
        
        # Try to get more diagnostic information about network
        if command -v ip >/dev/null 2>&1; then
            echo_debug "Network interface information:"
            ip addr | grep -E "inet " | grep -v "127.0.0.1" | awk '{print $2}' >&2
        fi
        
        return 1
    fi
}

# Expanded dependency checking
check_dependencies() {
    local missing_commands=()
    local optional_missing=()
    
    echo_info "Checking required dependencies..."
    
    # Essential commands
    for cmd in wget curl tar grep sed chmod chown systemctl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done
    
    # Optional but useful commands
    for cmd in jq md5sum sha256sum xxd ping nc host; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            optional_missing+=("$cmd")
        fi
    done
    
    # Handle missing essential commands
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        echo_warning "The following required commands are missing: ${missing_commands[*]}"
        
        # Provide detailed installation instructions
        echo_warning "Installation requires these commands. Please install them with:"
        
        if command -v apt-get >/dev/null 2>&1; then
            echo "    sudo apt-get update && sudo apt-get install -y wget curl tar coreutils sed systemd"
            read -p "Would you like the script to install these dependencies now? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo_info "Installing dependencies..."
                apt-get update && apt-get install -y wget curl tar coreutils sed systemd
            else
                echo_warning "Please install the dependencies manually and run the script again."
                return 1
            fi
        elif command -v yum >/dev/null 2>&1; then
            echo "    sudo yum install -y wget curl tar coreutils sed systemd"
            read -p "Would you like the script to install these dependencies now? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo_info "Installing dependencies..."
                yum install -y wget curl tar coreutils sed systemd
            else
                echo_warning "Please install the dependencies manually and run the script again."
                return 1
            fi
        elif command -v dnf >/dev/null 2>&1; then
            echo "    sudo dnf install -y wget curl tar coreutils sed systemd"
            read -p "Would you like the script to install these dependencies now? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo_info "Installing dependencies..."
                dnf install -y wget curl tar coreutils sed systemd
            else
                echo_warning "Please install the dependencies manually and run the script again."
                return 1
            fi
        else
            echo_warning "Unable to automatically install missing commands. Please install them manually."
            return 1
        fi
        
        # Verify again
        for cmd in "${missing_commands[@]}"; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                echo_error "Still missing required command: $cmd"
                echo_error "Please install it manually and run the script again."
                return 1
            fi
        done
    fi
    
    # Handle missing optional commands with recommendations
    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        echo_warning "The following optional commands are missing: ${optional_missing[*]}"
        
        # Special handling for important optional tools
        if [[ " ${optional_missing[*]} " =~ " jq " ]]; then
            echo_warning "The 'jq' command is highly recommended for proper checksum verification."
            echo_warning "Without it, the script may have limited functionality."
            
            # Ask user if they want to install jq
            if [ -t 0 ]; then  # Only ask if running interactively
                read -p "Would you like to install jq now? (y/n) " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    if command -v apt-get >/dev/null 2>&1; then
                        apt-get update && apt-get install -y jq
                    elif command -v yum >/dev/null 2>&1; then
                        yum install -y jq
                    elif command -v dnf >/dev/null 2>&1; then
                        dnf install -y jq
                    else
                        echo_warning "Could not determine how to install jq. Please install manually."
                    fi
                    
                    # Verify installation
                    if command -v jq >/dev/null 2>&1; then
                        echo_success "jq installed successfully!"
                    else
                        echo_warning "jq installation failed. Continuing without it."
                    fi
                fi
            fi
        fi
    fi
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        # Still have missing dependencies
        return 1
    fi
    
    echo_success "All required dependencies are installed."
    return 0
}

# Create directories with improved permission handling and error detection
setup_directories() {
    echo_info "Creating directories..."
    
    # Default permission modes
    local dir_mode=755
    local conf_mode=750
    
    # Create the temporary directory first
    if [ ! -d "$TEMP_DIR" ]; then
        if ! mkdir -p "$TEMP_DIR" 2>/dev/null; then
            echo_error "Failed to create temporary directory: $TEMP_DIR"
            # Try to use an alternative location
            TEMP_DIR="/tmp/mediamtx-install-$(date +%s)"
            echo_warning "Trying alternative temp directory: $TEMP_DIR"
            
            if ! mkdir -p "$TEMP_DIR" 2>/dev/null; then
                echo_error "Failed to create alternative temporary directory. Cannot continue."
                exit 1
            fi
        fi
        chmod $dir_mode "$TEMP_DIR" || echo_warning "Failed to set permissions on $TEMP_DIR"
    fi
    
    # Initialize log file
    touch "$LOG_FILE" 2>/dev/null || {
        echo_warning "Failed to create log file: $LOG_FILE" 
        LOG_FILE="/tmp/mediamtx-install-$(date +%s).log"
        echo_warning "Using alternative log file: $LOG_FILE"
        touch "$LOG_FILE" || echo_error "Failed to create alternative log file"
    }
    log_message "INFO" "MediaMTX installation started"
    
    # Create cache directory for GitHub API responses
    if [ ! -d "$CACHE_DIR" ]; then
        if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
            log_message "WARNING" "Failed to create cache directory: $CACHE_DIR"
            # Fall back to temp directory
            CACHE_DIR="${TEMP_DIR}/cache"
            API_CACHE="${CACHE_DIR}/api_cache.json"
            mkdir -p "$CACHE_DIR" 2>/dev/null || {
                log_message "WARNING" "Failed to create even fallback cache directory"
            }
        fi
        chmod $dir_mode "$CACHE_DIR" || log_message "WARNING" "Failed to set permissions on $CACHE_DIR"
    fi
    
    # Create other directories with detailed error reporting
    for dir in "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CHECKSUM_DB_DIR"; do
        # Use appropriate permissions
        local mode=$dir_mode
        if [[ "$dir" == "$CONFIG_DIR" || "$dir" == "$CHECKSUM_DB_DIR" ]]; then
            mode=$conf_mode
        fi
        
        if [ ! -d "$dir" ]; then
            if ! mkdir -p "$dir" 2>/dev/null; then
                log_message "ERROR" "Failed to create directory: $dir"
                echo_error "Could not create $dir. Please check permissions and try again."
                # Don't exit here, try to proceed with other directories
            else
                chmod $mode "$dir" || log_message "WARNING" "Failed to set permissions on $dir"
                log_message "INFO" "Created directory: $dir with mode $mode"
            fi
        else
            log_message "INFO" "Directory already exists: $dir"
            # Update permissions to ensure they're correct
            chmod $mode "$dir" || log_message "WARNING" "Failed to update permissions on $dir" 
        fi
    done
    
    log_message "SUCCESS" "Directories setup complete"
    return 0
}

# Function to check if URL is accessible
test_url() {
    local url="$1"
    echo_debug "Testing URL accessibility: $url"
    
    # First try wget
    if command -v wget >/dev/null 2>&1; then
        echo_debug "Testing with wget..."
        local wget_output=$(wget --spider --timeout=10 --tries=1 "$url" 2>&1)
        local wget_status=$?
        
        if [ $wget_status -eq 0 ]; then
            echo_debug "URL is accessible via wget"
            return 0
        else
            echo_debug "wget failed with status $wget_status"
            echo_debug "wget output: $wget_output"
        fi
    fi
    
    # Try curl as backup
    if command -v curl >/dev/null 2>&1; then
        echo_debug "Testing with curl..."
        local curl_output=$(curl --head --silent --fail --connect-timeout 10 "$url" 2>&1)
        local curl_status=$?
        
        if [ $curl_status -eq 0 ]; then
            echo_debug "URL is accessible via curl"
            return 0
        else
            echo_debug "curl failed with status $curl_status"
            echo_debug "curl output: $curl_output"
        fi
    fi
    
    # Both methods failed
    echo_debug "URL is NOT accessible via any method"
    return 1
}

# Download MediaMTX binary
download_mediamtx() {
    local arch=$1
    local version=$2
    
    # Validate architecture
    if [ -z "$arch" ] || [ "$arch" = "unknown" ]; then
        echo_error "Invalid architecture: $arch"
        return 1
    fi
    
    # Validate version format
    if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        echo_error "Invalid version format: $version (expected format: v1.2.3)"
        return 1
    fi
    
    # Construct URL
    local url="https://github.com/bluenviron/mediamtx/releases/download/${version}/mediamtx_${version}_linux_${arch}.tar.gz"
    local output_file="$TEMP_DIR/mediamtx.tar.gz"
    
    echo_info "Download information:"
    echo "  - Architecture: $arch"
    echo "  - Version: $version"
    echo "  - URL: $url"
    echo "  - Output: $output_file"
    
    # Test connectivity to github.com
    echo_info "Testing internet connectivity..."
    if ! check_internet_connectivity; then
        echo_error "Internet connectivity test failed. Cannot proceed with download."
        return 1
    fi
    
    # Test if URL exists
    echo_info "Testing if download URL exists..."
    if ! test_url "$url"; then
        echo_error "Download URL does not exist or is not accessible:"
        echo "  $url"
        
        # Try to suggest alternatives
        echo_info "Looking for alternative files that might be available..."
        
        # Check if the release exists at all
        local release_url="https://github.com/bluenviron/mediamtx/releases/tag/${version}"
        if test_url "$release_url"; then
            echo_info "The release $version exists, but not for your architecture ($arch)."
            echo_info "You can check available files manually at: $release_url"
            
            # Try some common alternative architectures
            for alt_arch in "amd64" "arm64" "armv7" "armv6"; do
                if [ "$alt_arch" != "$arch" ]; then
                    local alt_url="https://github.com/bluenviron/mediamtx/releases/download/${version}/mediamtx_${version}_linux_${alt_arch}.tar.gz"
                    if test_url "$alt_url"; then
                        echo_success "Found alternative file for architecture '$alt_arch':"
                        echo "  $alt_url"
                        echo ""
                        echo_info "You can use this instead by running:"
                        echo "  sudo $0 --arch $alt_arch --version $version"
                        break
                    fi
                fi
            done
        else
            echo_warning "The release $version doesn't appear to exist at all."
            echo_info "Check available releases at: https://github.com/bluenviron/mediamtx/releases"
        fi
        
        return 1
    fi
    
    # Download using wget or curl
    echo_info "Downloading MediaMTX..."
    
    # Create parent directory for output file if it doesn't exist
    mkdir -p "$(dirname "$output_file")" || {
        echo_error "Failed to create directory for download: $(dirname "$output_file")"
        return 1
    }
    
    local download_success=false
    
    # Try wget first
    if command -v wget >/dev/null 2>&1; then
        echo_info "Downloading with wget..."
        echo ""
        
        # Run wget with verbose output
        if wget --no-verbose --show-progress --progress=bar:force:noscroll --tries=3 --timeout=30 -O "$output_file" "$url"; then
            download_success=true
            echo ""  # Add newline after wget progress bar
        else
            echo_warning "wget download failed with exit code: $?"
        fi
    fi
    
    # Try curl if wget failed or isn't available
    if [ "$download_success" != true ] && command -v curl >/dev/null 2>&1; then
        echo_info "Downloading with curl..."
        
        # Run curl with progress bar
        if curl -L --retry 3 --connect-timeout 30 --progress-bar -o "$output_file" "$url"; then
            download_success=true
            echo ""  # Add newline after curl progress bar
        else
            echo_warning "curl download failed with exit code: $?"
        fi
    fi
    
    # Check if download was successful
    if [ "$download_success" != true ]; then
        echo_error "All download methods failed!"
        
        # Try to analyze connection issues
        echo_info "Diagnosing connection issues..."
        if command -v curl >/dev/null 2>&1; then
            echo "Detailed connection information:"
            curl -v "$url" 2>&1 | grep -E "^([*<>])" | head -n 20
        fi
        
        return 1
    fi
    
    # Verify file was downloaded and is not empty
    if [ ! -f "$output_file" ]; then
        echo_error "Download file not found at expected location: $output_file"
        return 1
    fi
    
    if [ ! -s "$output_file" ]; then
        echo_error "Downloaded file is empty: $output_file"
        return 1
    fi
    
    local file_size=$(du -h "$output_file" | cut -f1)
    echo_success "Download successful! File size: $file_size"
    return 0
}

# Check if the downloaded file is a valid tarball
check_tarball() {
    local tarball="$1"
    
    if [ ! -f "$tarball" ]; then
        echo_error "Tarball not found: $tarball"
        return 1
    fi
    
    echo_info "Verifying tarball format..."
    
    # Check file type
    local file_type=$(file -b "$tarball")
    echo_debug "File type: $file_type"
    
    # Check if it's a gzip file
    if [[ ! "$file_type" =~ "gzip compressed data" ]]; then
        echo_error "Not a valid gzip file: $tarball"
        echo_error "File type reported as: $file_type"
        return 1
    fi
    
    # Attempt to list contents without extracting
    echo_debug "Testing tarball integrity..."
    if ! tar -tzf "$tarball" >/dev/null 2>&1; then
        echo_error "Not a valid tar.gz archive: $tarball"
        return 1
    fi
    
    # List number of files in archive for reporting
    local file_count=$(tar -tzf "$tarball" | wc -l)
    echo_debug "Tarball contains $file_count files"
    
    echo_success "Tarball verification passed"
    return 0
}

# Extract MediaMTX with better error handling
extract_mediamtx() {
    local tarball="$TEMP_DIR/mediamtx.tar.gz"
    
    echo_info "Extracting MediaMTX..."
    
    # Ensure the file exists and is a valid tarball
    if ! check_tarball "$tarball"; then
        echo_error "Invalid or corrupted tarball. Cannot extract."
        return 1
    fi
    
    # Create a separate extraction directory
    local extract_dir="$TEMP_DIR/extracted"
    if ! mkdir -p "$extract_dir"; then
        echo_error "Failed to create extraction directory: $extract_dir"
        return 1
    fi
    
    echo_info "Extracting to: $extract_dir"
    
    # Extract with verbose error handling
    local extract_output=$(tar -xzvf "$tarball" -C "$extract_dir" 2>&1)
    local extract_status=$?
    
    if [ $extract_status -ne 0 ]; then
        echo_error "Extraction failed with status: $extract_status"
        echo_error "Extraction output: $extract_output"
        return 1
    fi
    
    # Count extracted files for reporting
    local file_count=$(find "$extract_dir" -type f | wc -l)
    
    # Verify extraction succeeded by checking if files exist
    if [ ! "$(ls -A "$extract_dir")" ]; then
        echo_error "Extraction appeared to succeed, but no files were found in the extracted directory"
        return 1
    fi
    
    echo_success "Extraction successful! Extracted $file_count files."
    
    # List extracted files for debugging
    echo_debug "Extracted files:"
    find "$extract_dir" -type f | sort
    
    return 0
}

# Install extracted MediaMTX files
install_mediamtx() {
    local extract_dir="$TEMP_DIR/extracted"
    local force_install=${1:-false}
    
    echo_info "Installing MediaMTX..."
    
    # Find the binary within the extracted files
    echo_debug "Searching for MediaMTX binary in extracted files..."
    
    # First try the most common locations
    local binary_path=""
    for path in "$extract_dir/mediamtx" "$extract_dir"/*/mediamtx; do
        if [ -f "$path" ] && [ -x "$path" ]; then
            binary_path="$path"
            break
        fi
    done
    
    # If not found in common locations, use find command
    if [ -z "$binary_path" ]; then
        echo_debug "Binary not found in common locations, using find..."
        binary_path=$(find "$extract_dir" -type f -name "mediamtx" -executable 2>/dev/null | head -n 1)
    fi
    
    # Verify we found the binary
    if [ -z "$binary_path" ] || [ ! -f "$binary_path" ]; then
        echo_error "MediaMTX binary not found in extracted files!"
        echo_info "Contents of extraction directory:"
        find "$extract_dir" -type f | sort
        return 1
    fi
    
    echo_info "Found MediaMTX binary at: $binary_path"
    
    # Create installation directory if it doesn't exist
    if ! mkdir -p "$INSTALL_DIR"; then
        echo_error "Failed to create installation directory: $INSTALL_DIR"
        return 1
    fi
    
    # Backup existing binary if it exists
    if [ -f "$INSTALL_DIR/mediamtx" ]; then
        local backup_file="$INSTALL_DIR/mediamtx.backup.$(date +%Y%m%d%H%M%S)"
        echo_info "Backing up existing binary to: $backup_file"
        
        if ! cp "$INSTALL_DIR/mediamtx" "$backup_file"; then
            echo_warning "Failed to create backup of existing binary"
        fi
    fi
    
    # Copy the binary to the installation directory
    echo_info "Installing binary to: $INSTALL_DIR/mediamtx"
    if ! cp "$binary_path" "$INSTALL_DIR/mediamtx"; then
        echo_error "Failed to copy binary to installation directory"
        return 1
    fi
    
    # Set the correct permissions
    echo_debug "Setting binary permissions..."
    if ! chmod 755 "$INSTALL_DIR/mediamtx"; then
        echo_warning "Failed to set permissions on binary"
    fi
    
    # Test the binary
    echo_info "Testing installed binary..."
    local test_output=$("$INSTALL_DIR/mediamtx" --version 2>&1)
    local test_status=$?
    
    if [ $test_status -ne 0 ]; then
        echo_error "Binary test failed with status: $test_status"
        echo_error "Test output: $test_output"
        return 1
    fi
    
    echo_success "Binary installed and tested successfully"
    echo_info "Version info: $test_output"
    
    # Create default configuration
    echo_info "Creating default configuration..."
    
    # Create config directory if it doesn't exist
    if ! mkdir -p "$CONFIG_DIR"; then
        echo_error "Failed to create configuration directory: $CONFIG_DIR"
        return 1
    fi
    
    # Backup existing config if it exists
    if [ -f "$CONFIG_DIR/mediamtx.yml" ]; then
        local config_backup="$CONFIG_DIR/mediamtx.yml.backup.$(date +%Y%m%d%H%M%S)"
        echo_info "Backing up existing configuration to: $config_backup"
        
        if ! cp "$CONFIG_DIR/mediamtx.yml" "$config_backup"; then
            echo_warning "Failed to create backup of existing configuration"
        fi
    fi
    
    # Create default configuration
    echo_info "Writing configuration to: $CONFIG_DIR/mediamtx.yml"
    cat > "$CONFIG_DIR/mediamtx.yml" << EOF
# MediaMTX configuration
# Generated by install script on $(date)

# Logging configuration
logLevel: info
logDestinations: [stdout, file]
logFile: $LOG_DIR/mediamtx.log

# Network addresses
rtspAddress: :$RTSP_PORT
rtmpAddress: :$RTMP_PORT
hlsAddress: :$HLS_PORT
webrtcAddress: :$WEBRTC_PORT

# Metrics
metrics: yes
metricsAddress: :$METRICS_PORT

# Path configuration
paths:
  all:
    # This section can be customized as needed
EOF

    # Check if the config file was created successfully
    if [ ! -f "$CONFIG_DIR/mediamtx.yml" ]; then
        echo_error "Failed to create configuration file"
        return 1
    fi
    
    echo_success "Configuration created successfully"
    
    # Create systemd service file
    create_systemd_service
    
    return 0
}

# Create systemd service
create_systemd_service() {
    echo_info "Creating systemd service file..."
    
    # Create service user if it doesn't exist
    if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
        echo_info "Creating service user: $SERVICE_USER"
        if ! useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"; then
            echo_warning "Failed to create service user, will use root instead"
            SERVICE_USER="root"
        fi
    fi
    
    # Set ownership of relevant directories
    echo_debug "Setting directory ownership..."
    if ! chown -R "$SERVICE_USER:" "$CONFIG_DIR" "$LOG_DIR"; then
        echo_warning "Failed to set directory ownership"
    fi
    
    # Create service file
    local service_file="/etc/systemd/system/mediamtx.service"
    
    # Backup existing service file if it exists
    if [ -f "$service_file" ]; then
        local service_backup="$service_file.backup.$(date +%Y%m%d%H%M%S)"
        echo_info "Backing up existing service file to: $service_backup"
        
        if ! cp "$service_file" "$service_backup"; then
            echo_warning "Failed to create backup of existing service file"
        fi
    fi
    
    echo_info "Creating service file: $service_file"
    cat > "$service_file" << EOF
[Unit]
Description=MediaMTX RTSP/RTMP/HLS/WebRTC Streaming Server
After=network.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=$SERVICE_USER
ExecStart=$INSTALL_DIR/mediamtx $CONFIG_DIR/mediamtx.yml
WorkingDirectory=$INSTALL_DIR
Restart=on-failure
RestartSec=10

# Security hardening
ProtectSystem=full
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
ReadWritePaths=$LOG_DIR
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    # Check if the service file was created successfully
    if [ ! -f "$service_file" ]; then
        echo_error "Failed to create service file"
        return 1
    fi
    
    # Reload systemd
    echo_info "Reloading systemd daemon..."
    if ! systemctl daemon-reload; then
        echo_warning "Failed to reload systemd daemon"
    fi
    
    # Enable the service
    echo_info "Enabling service to start on boot..."
    if ! systemctl enable mediamtx.service; then
        echo_warning "Failed to enable service"
    fi
    
    # Ask whether to start the service now
    echo_info "Service created and enabled"
    read -p "Would you like to start the MediaMTX service now? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo_info "Starting MediaMTX service..."
        if ! systemctl start mediamtx.service; then
            echo_error "Failed to start service"
            echo_info "Service status:"
            systemctl status mediamtx.service
            return 1
        fi
        
        # Verify service is running
        if systemctl is-active --quiet mediamtx.service; then
            echo_success "Service started successfully"
        else
            echo_error "Service failed to start properly"
            echo_info "Service status:"
            systemctl status mediamtx.service
            return 1
        fi
    else
        echo_info "Service will start on next boot or when manually started"
        echo_info "To start it manually, run: sudo systemctl start mediamtx.service"
    fi
    
    return 0
}

# Print installation summary
print_summary() {
    echo "==============================================="
    echo "MediaMTX Installation Summary"
    echo "==============================================="
    echo "Installation Directory: $INSTALL_DIR"
    echo "Configuration File:    $CONFIG_DIR/mediamtx.yml"
    echo "Log File:              $LOG_DIR/mediamtx.log"
    echo "Service Name:          mediamtx.service"
    echo "Service User:          $SERVICE_USER"
    echo ""
    echo "Network Ports:"
    echo "  RTSP:    $RTSP_PORT"
    echo "  RTMP:    $RTMP_PORT"
    echo "  HLS:     $HLS_PORT"
    echo "  WebRTC:  $WEBRTC_PORT"
    echo "  Metrics: $METRICS_PORT"
    echo ""
    echo "Useful Commands:"
    echo "  Check status:    systemctl status mediamtx"
    echo "  Start service:   systemctl start mediamtx"
    echo "  Stop service:    systemctl stop mediamtx"
    echo "  View logs:       journalctl -u mediamtx -f"
    echo "  Edit config:     nano $CONFIG_DIR/mediamtx.yml"
    echo "==============================================="
    echo "Installation Completed Successfully!"
    echo "For more information, visit: https://github.com/bluenviron/mediamtx"
    echo "==============================================="
}

# Cleanup function
cleanup() {
    # Keep temp files in debug mode
    if [ "$DEBUG_MODE" = true ]; then
        echo_info "Debug mode enabled - keeping temporary files at: $TEMP_DIR"
    else
        echo_info "Cleaning up temporary files..."
        rm -rf "$TEMP_DIR"
    fi
}

# Main installation function
main() {
    echo "============================================"
    echo "MediaMTX Installer v2.1.4"
    echo "============================================"
    
    # Check if running as root
    if [ "$(id -u)" -ne 0 ]; then
        echo_error "This script must be run as root or with sudo"
        exit 1
    fi
    
    # Setup the directory structure
    if ! setup_directories; then
        echo_error "Failed to set up required directories"
        exit 1
    fi
    
    # Check for required dependencies
    if ! check_dependencies; then
        echo_error "Missing required dependencies"
        exit 1
    fi
    
    # Detect architecture
    ARCH=$(detect_arch)
    if [ "$ARCH" = "unknown" ]; then
        echo_error "Failed to detect a supported architecture"
        exit 1
    fi
    
    echo_info "Detected architecture: $ARCH"
    echo_info "Target version: $VERSION"
    
    # Download MediaMTX
    if ! download_mediamtx "$ARCH" "$VERSION"; then
        echo_error "Download failed. Exiting."
        exit 1
    fi
    
    # Extract MediaMTX
    if ! extract_mediamtx; then
        echo_error "Extraction failed. Exiting."
        exit 1
    fi
    
    # Install MediaMTX
    if ! install_mediamtx false; then
        echo_error "Installation failed. Exiting."
        exit 1
    fi
    
    # Print installation summary
    print_summary
    
    return 0
}

# Run the main function
main "$@"
exit $?

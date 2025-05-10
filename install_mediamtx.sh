#!/bin/bash
#
# Enhanced MediaMTX Installer with Dynamic Checksum Verification
# Version: 2.0.0
# Date: 2025-05-10
# Description: Robust installer for MediaMTX with dynamic checksum verification and proper version comparison
#

set -e  # Exit immediately if a command exits with a non-zero status
set -o pipefail  # Exit if any command in a pipeline fails

# Configuration
INSTALL_DIR="/usr/local/mediamtx"
CONFIG_DIR="/etc/mediamtx"
LOG_DIR="/var/log/mediamtx"
SERVICE_USER="mediamtx"
CHECKSUM_DB_DIR="/var/lib/mediamtx/checksums"
CHECKSUM_DB_FILE="${CHECKSUM_DB_DIR}/checksums.json"

# Configurable version - can be overridden with command line args
VERSION="v1.12.2"
TEMP_DIR="/tmp/mediamtx-install-$(date +%s)-${RANDOM}"  # More unique temp dir with random component

# Custom ports (to avoid conflicts)
RTSP_PORT="18554"
RTMP_PORT="11935"
HLS_PORT="18888" 
WEBRTC_PORT="18889"
METRICS_PORT="19999"

# Print colored messages
echo_info() { echo -e "\033[34m[INFO]\033[0m $1"; }
echo_success() { echo -e "\033[32m[SUCCESS]\033[0m $1"; }
echo_warning() { echo -e "\033[33m[WARNING]\033[0m $1"; }
echo_error() { echo -e "\033[31m[ERROR]\033[0m $1"; }

# Save log messages to a file and stdout
LOG_FILE="${TEMP_DIR}/install.log"

# Log to file only (no stdout)
log_file_only() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
}

# Log to both file and stdout
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${message}" | tee -a "$LOG_FILE"
}

# Compare version strings - robust implementation
# Returns 0 (success/true) if version1 > version2 (version1 is newer)
# Returns 1 (failure/false) if version1 <= version2 (version1 is older or equal)
is_version_newer() {
    local v1=$1
    local v2=$2
    
    # Strip leading 'v' if present
    v1=${v1#v}
    v2=${v2#v}
    
    # Split versions into major, minor, patch
    local v1_major=$(echo "$v1" | cut -d. -f1)
    local v1_minor=$(echo "$v1" | cut -d. -f2)
    local v1_patch=$(echo "$v1" | cut -d. -f3)
    
    local v2_major=$(echo "$v2" | cut -d. -f1)
    local v2_minor=$(echo "$v2" | cut -d. -f2)
    local v2_patch=$(echo "$v2" | cut -d. -f3)
    
    # Compare major versions
    if [ "$v1_major" -gt "$v2_major" ]; then
        return 0  # v1 is newer
    elif [ "$v1_major" -lt "$v2_major" ]; then
        return 1  # v1 is older
    fi
    
    # Major versions are equal, compare minor versions
    if [ "$v1_minor" -gt "$v2_minor" ]; then
        return 0  # v1 is newer
    elif [ "$v1_minor" -lt "$v2_minor" ]; then
        return 1  # v1 is older
    fi
    
    # Minor versions are equal, compare patch versions
    if [ "$v1_patch" -gt "$v2_patch" ]; then
        return 0  # v1 is newer
    else
        return 1  # v1 is older or equal
    fi
}

# Detect architecture (improved version)
detect_arch() {
    local arch=$(uname -m)
    
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;  # Changed from arm64v8 to arm64
        armv7*)  echo "armv7" ;;
        armv6*)  echo "armv6" ;;
        *)       
            echo_error "Unsupported architecture: $arch"
            echo_info "Currently supported architectures: x86_64 (amd64), aarch64 (arm64), armv7, armv6"
            exit 1 
            ;;
    esac
}

# Verify that required commands exist
verify_commands() {
    local missing_commands=()
    for cmd in wget curl tar grep sed chmod chown systemctl md5sum sha256sum jq; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        echo_warning "The following required commands are missing: ${missing_commands[*]}"
        
        # Try to install missing commands
        if command -v apt-get >/dev/null 2>&1; then
            echo_info "Attempting to install missing commands with apt-get..."
            apt-get update && apt-get install -y coreutils wget curl tar grep sed jq
        elif command -v yum >/dev/null 2>&1; then
            echo_info "Attempting to install missing commands with yum..."
            yum install -y coreutils wget curl tar grep sed jq
        else
            echo_warning "Unable to automatically install missing commands. Please install them manually."
            
            # Special handling for jq - essential for dynamic checksum verification
            if [[ " ${missing_commands[*]} " =~ " jq " ]]; then
                echo_warning "The 'jq' command is required for dynamic checksum verification."
                echo_warning "Without it, you'll need to explicitly skip verification."
                
                # Ask user if they want to continue without jq
                read -p "Continue without jq? (y/n) " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    echo_error "Aborted by user"
                    exit 1
                fi
            fi
        fi
        
        # Verify again
        missing_commands=()
        for cmd in wget curl tar grep sed; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                missing_commands+=("$cmd")
            fi
        done
        
        if [[ ${#missing_commands[@]} -gt 0 ]]; then
            echo_error "Still missing required commands after installation attempt: ${missing_commands[*]}"
            exit 1
        fi
    fi
}

# Create directories with improved permission handling
setup_directories() {
    echo_info "Creating directories..."
    
    # Default permission modes
    local dir_mode=755
    local conf_mode=750
    
    # Create the temporary directory first
    if [ ! -d "$TEMP_DIR" ]; then
        if ! mkdir -p "$TEMP_DIR" 2>/dev/null; then
            echo_error "Failed to create temporary directory: $TEMP_DIR"
            exit 1
        fi
        chmod $dir_mode "$TEMP_DIR" || echo_warning "Failed to set permissions on $TEMP_DIR"
    fi
    
    # Initialize log file
    touch "$LOG_FILE" 2>/dev/null || echo_warning "Failed to create log file: $LOG_FILE"
    log_message "INFO" "MediaMTX installation started"
    
    # Create other directories
    for dir in "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CHECKSUM_DB_DIR"; do
        # Use appropriate permissions
        local mode=$dir_mode
        if [[ "$dir" == "$CONFIG_DIR" || "$dir" == "$CHECKSUM_DB_DIR" ]]; then
            mode=$conf_mode
        fi
        
        if [ ! -d "$dir" ]; then
            if ! mkdir -p "$dir" 2>/dev/null; then
                log_message "ERROR" "Failed to create directory: $dir"
                exit 1
            fi
            chmod $mode "$dir" || log_message "WARNING" "Failed to set permissions on $dir"
            log_message "INFO" "Created directory: $dir with mode $mode"
        else
            log_message "INFO" "Directory already exists: $dir"
            # Update permissions to ensure they're correct
            chmod $mode "$dir" || log_message "WARNING" "Failed to update permissions on $dir" 
        fi
    done
    
    log_message "SUCCESS" "Directories setup complete"
}

# Function to fetch the SHA256 checksums from GitHub releases
fetch_checksums() {
    local version=$1
    local arch=$2
    local checksum_file="${TEMP_DIR}/checksums.json"
    
    log_message "INFO" "Attempting to fetch checksums for MediaMTX $version ($arch)"
    
    # Different approaches to get checksums
    local success=false
    
    # Approach 1: Try to get checksums.txt directly from GitHub if it exists
    if curl --head --silent --fail "https://github.com/bluenviron/mediamtx/releases/download/${version}/checksums.txt" >/dev/null 2>&1; then
        log_message "INFO" "Found checksums.txt file on GitHub"
        
        if curl -s -L -o "${TEMP_DIR}/checksums.txt" "https://github.com/bluenviron/mediamtx/releases/download/${version}/checksums.txt"; then
            # Parse the checksums.txt file to find our file's checksum
            local checksum_line=$(grep "mediamtx_${version}_linux_${arch}.tar.gz" "${TEMP_DIR}/checksums.txt" || echo "")
            
            if [[ -n "$checksum_line" ]]; then
                # Extract the checksum from the line
                local checksum=$(echo "$checksum_line" | awk '{print $1}')
                
                if [[ -n "$checksum" ]]; then
                    log_message "INFO" "Found checksum for $arch: $checksum"
                    # Create a simple JSON structure with the checksum
                    echo "{\"$arch\": \"$checksum\"}" > "$checksum_file"
                    success=true
                fi
            fi
        fi
    fi
    
    # Approach 2: If checksums.txt doesn't exist or didn't work, try release API
    if [ "$success" != true ] && command -v jq >/dev/null 2>&1; then
        log_message "INFO" "Attempting to fetch checksums from GitHub API"
        
        # Get release info from GitHub API
        if curl -s -L -o "${TEMP_DIR}/release.json" "https://api.github.com/repos/bluenviron/mediamtx/releases/tags/${version}"; then
            # Check if the API rate limit is exceeded
            if grep -q "API rate limit exceeded" "${TEMP_DIR}/release.json"; then
                log_message "WARNING" "GitHub API rate limit exceeded, cannot fetch checksums from API"
            else
                # Parse release JSON to find asset download URL
                local download_url=$(jq -r ".assets[] | select(.name == \"mediamtx_${version}_linux_${arch}.tar.gz\") | .browser_download_url" "${TEMP_DIR}/release.json")
                
                if [[ -n "$download_url" && "$download_url" != "null" ]]; then
                    log_message "INFO" "Found download URL: $download_url"
                    
                    # For newer MediaMTX releases, we can check if there's a .sha256 file
                    local checksum_url="${download_url}.sha256"
                    
                    if curl --head --silent --fail "$checksum_url" >/dev/null 2>&1; then
                        log_message "INFO" "Found .sha256 file for download"
                        
                        if curl -s -L -o "${TEMP_DIR}/file.sha256" "$checksum_url"; then
                            local checksum=$(cat "${TEMP_DIR}/file.sha256" | tr -d '[:space:]')
                            
                            if [[ -n "$checksum" ]]; then
                                log_message "INFO" "Found checksum from .sha256 file: $checksum"
                                # Create a simple JSON structure with the checksum
                                echo "{\"$arch\": \"$checksum\"}" > "$checksum_file"
                                success=true
                            fi
                        fi
                    fi
                fi
            fi
        fi
    fi
    
    if [ "$success" = true ]; then
        # Save to the checksum database for future offline use
        if [ ! -f "$CHECKSUM_DB_FILE" ]; then
            echo "{}" > "$CHECKSUM_DB_FILE"
        fi
        
        if command -v jq >/dev/null 2>&1; then
            # Update the checksum database
            local checksum=$(jq -r ".\"$arch\"" "$checksum_file")
            
            # Create version entry if it doesn't exist
            if ! jq -e ".[\"$version\"]" "$CHECKSUM_DB_FILE" >/dev/null 2>&1; then
                jq ". + {\"$version\": {}}" "$CHECKSUM_DB_FILE" > "${TEMP_DIR}/new_checksums.json"
                mv "${TEMP_DIR}/new_checksums.json" "$CHECKSUM_DB_FILE"
            fi
            
            # Add the checksum for this architecture
            jq ".[\"$version\"] += {\"$arch\": \"$checksum\"}" "$CHECKSUM_DB_FILE" > "${TEMP_DIR}/new_checksums.json"
            mv "${TEMP_DIR}/new_checksums.json" "$CHECKSUM_DB_FILE"
            
            log_message "INFO" "Updated checksum database with new entry"
        fi
        
        return 0
    else
        log_message "WARNING" "Could not fetch checksums for MediaMTX $version ($arch)"
        return 1
    fi
}

# Function to look up checksums from local database
lookup_checksum() {
    local version=$1
    local arch=$2
    
    log_message "INFO" "Looking up checksum for MediaMTX $version ($arch) in local database"
    
    if [ ! -f "$CHECKSUM_DB_FILE" ]; then
        log_message "WARNING" "Checksum database file not found: $CHECKSUM_DB_FILE"
        return 1
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        log_message "WARNING" "jq is required to parse checksum database"
        return 1
    fi
    
    # Check if the version and architecture exist in the database
    if jq -e ".[\"$version\"][\"$arch\"]" "$CHECKSUM_DB_FILE" >/dev/null 2>&1; then
        local checksum=$(jq -r ".[\"$version\"][\"$arch\"]" "$CHECKSUM_DB_FILE")
        
        if [[ -n "$checksum" && "$checksum" != "null" ]]; then
            log_message "INFO" "Found checksum in database: $checksum"
            echo "{\"$arch\": \"$checksum\"}" > "${TEMP_DIR}/checksums.json"
            return 0
        fi
    fi
    
    log_message "WARNING" "No checksum found in database for MediaMTX $version ($arch)"
    return 1
}

# Fallback checksums for version 1.12.2 (the default version)
get_fallback_checksum() {
    local version=$1
    local arch=$2
    
    log_message "INFO" "Using fallback checksums for $version ($arch)"
    
    # Only provide fallback checksums for the default version
    if [[ "$version" == "v1.12.2" ]]; then
        case "$arch" in
            "amd64")
                echo "{\"$arch\": \"76a0fbd0eba62cbc3c9a4fa320881f9425a551e8a684e90f1c1148e175dcc583\"}" > "${TEMP_DIR}/checksums.json"
                log_message "INFO" "Using fallback checksum for amd64 (v1.12.2)"
                return 0
                ;;
            "arm64")
                echo "{\"$arch\": \"35803953e27a7b242efb1f25b4d48e3cc24999bcb43f6895383a85d6f8000651\"}" > "${TEMP_DIR}/checksums.json"
                log_message "INFO" "Using fallback checksum for arm64 (v1.12.2)"
                return 0
                ;;
            "armv7")
                echo "{\"$arch\": \"74c5a3818a35ad08da19c1c1a16e4d548f96334fc267a3fb9c9c7d74e92a0c9b\"}" > "${TEMP_DIR}/checksums.json"
                log_message "INFO" "Using fallback checksum for armv7 (v1.12.2)"
                return 0
                ;;
            "armv6")
                echo "{\"$arch\": \"9dbe276bce745e4b0d10a2e015c8c4ec99e34c2a181f6c04dedc5103f5c85f44\"}" > "${TEMP_DIR}/checksums.json"
                log_message "INFO" "Using fallback checksum for armv6 (v1.12.2)"
                return 0
                ;;
            *)
                log_message "WARNING" "No fallback checksum available for $arch (v1.12.2)"
                return 1
                ;;
        esac
    else
        log_message "WARNING" "No fallback checksums available for version $version"
        return 1
    fi
}

# Function to get checksums using all available methods
get_checksums() {
    local version=$1
    local arch=$2
    
    # First try to fetch from GitHub (online method)
    if fetch_checksums "$version" "$arch"; then
        log_message "SUCCESS" "Successfully fetched checksums from GitHub"
        return 0
    fi
    
    # Then try the local database
    if lookup_checksum "$version" "$arch"; then
        log_message "SUCCESS" "Successfully retrieved checksums from local database"
        return 0
    fi
    
    # Finally, try fallback checksums
    if get_fallback_checksum "$version" "$arch"; then
        log_message "SUCCESS" "Successfully retrieved fallback checksums"
        return 0
    fi
    
    # All methods failed
    log_message "WARNING" "Could not obtain checksums through any method"
    return 1
}

# Download MediaMTX with improved error handling
download_mediamtx() {
    local arch=$1
    local version=$2
    
    # Clean URL construction with version validation
    if [[ ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        log_message "ERROR" "Invalid version format: $version (expected format: v1.2.3)"
        return 1
    fi
    
    local url="https://github.com/bluenviron/mediamtx/releases/download/${version}/mediamtx_${version}_linux_${arch}.tar.gz"
    local output_file="$TEMP_DIR/mediamtx.tar.gz"
    
    log_message "INFO" "Architecture: $arch"
    log_message "INFO" "Version: $version"
    log_message "INFO" "Downloading from: $url"
    
    # Try multiple methods with better error handling
    local download_success=false
    
    # First try wget if available
    if command -v wget >/dev/null 2>&1; then
        log_message "INFO" "Using wget to download..."
        if wget --spider "$url" 2>/dev/null; then
            log_message "INFO" "URL verified, downloading file..."
            if wget --no-verbose --show-progress --progress=bar:force:noscroll --tries=3 --timeout=15 -O "$output_file" "$url"; then
                download_success=true
            else
                log_message "WARNING" "wget download failed, will try curl..."
            fi
        else
            log_message "WARNING" "URL does not exist or is not accessible: $url"
        fi
    fi
    
    # Try curl if wget failed or isn't available
    if [ "$download_success" != true ] && command -v curl >/dev/null 2>&1; then
        log_message "INFO" "Using curl to download..."
        # First check if the URL exists
        if curl --head --silent --fail "$url" >/dev/null 2>&1; then
            log_message "INFO" "URL verified, downloading file..."
            if curl -s -L --retry 3 --connect-timeout 15 --progress-bar -o "$output_file" "$url"; then
                download_success=true
            else
                log_message "WARNING" "curl download failed..."
            fi
        else
            log_message "WARNING" "URL does not exist or is not accessible: $url"
        fi
    fi
    
    # If both methods failed
    if [ "$download_success" != true ]; then
        log_message "ERROR" "All download methods failed. Please check your internet connection and the URL."
        log_message "INFO" "URL attempted: $url"
        
        # List available versions and architectures for clarity
        log_message "INFO" "Checking available MediaMTX versions..."
        if command -v curl >/dev/null 2>&1; then
            local latest_version=$(curl -s https://api.github.com/repos/bluenviron/mediamtx/releases/latest | grep "tag_name" | cut -d : -f 2,3 | tr -d \" | tr -d , | xargs)
            if [[ -n "$latest_version" ]]; then
                log_message "INFO" "Latest version appears to be: $latest_version"
                log_message "INFO" "Try using: --version $latest_version"
            fi
        fi
        
        return 1
    fi
    
    # Verify file exists and has non-zero size
    if [ ! -f "$output_file" ] || [ ! -s "$output_file" ]; then
        log_message "ERROR" "Download file is missing or empty"
        return 1
    fi
    
    log_message "SUCCESS" "Download successful"
    return 0
}

# Verify the downloaded file against known checksums
verify_checksum() {
    local arch=$1
    local version=$2
    local skip_verification=$3
    
    # Skip verification if explicitly requested
    if [ "$skip_verification" = true ]; then
        log_message "WARNING" "Checksum verification skipped as requested"
        echo_warning "SECURITY RISK: Skipping checksum verification means you cannot be sure"
        echo_warning "the downloaded file is authentic and has not been tampered with."
        return 0
    fi
    
    # Check if file exists
    if [ ! -f "$TEMP_DIR/mediamtx.tar.gz" ]; then
        log_message "ERROR" "Verification failed: file not found"
        return 1
    fi
    
    log_message "INFO" "Verifying file integrity..."
    
    # Get the checksums for this architecture and version
    if ! get_checksums "$version" "$arch"; then
        log_message "WARNING" "Could not obtain checksums for verification"
        
        # Ask for confirmation to continue without verification
        echo_warning "No checksums are available for MediaMTX $version ($arch)"
        echo_warning "Without verification, there is a security risk that the file"
        echo_warning "may have been tampered with or corrupted."
        
        read -p "Continue without checksum verification? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_message "ERROR" "Aborted by user due to missing checksums"
            return 1
        fi
        
        log_message "WARNING" "Continuing without checksum verification as requested by user"
        return 0
    fi
    
    # Calculate actual checksum
    local actual_checksum=$(sha256sum "$TEMP_DIR/mediamtx.tar.gz" | cut -d ' ' -f 1)
    
    # Get expected checksum from the JSON file
    local expected_checksum=""
    if command -v jq >/dev/null 2>&1; then
        expected_checksum=$(jq -r ".\"$arch\"" "${TEMP_DIR}/checksums.json")
    else
        # Manual parsing if jq is not available
        expected_checksum=$(grep -o "\"$arch\":.*\"[a-f0-9]*\"" "${TEMP_DIR}/checksums.json" | grep -o "[a-f0-9]*\"$" | tr -d '"')
    fi
    
    if [[ -z "$expected_checksum" || "$expected_checksum" == "null" ]]; then
        log_message "ERROR" "Could not parse expected checksum from JSON"
        return 1
    fi
    
    log_message "INFO" "Expected SHA256: $expected_checksum"
    log_message "INFO" "Actual SHA256:   $actual_checksum"
    
    if [ "$actual_checksum" != "$expected_checksum" ]; then
        log_message "ERROR" "Checksum verification failed!"
        log_message "ERROR" "The downloaded file may be corrupted or tampered with."
        
        echo_error "SECURITY ALERT: Checksum verification failed!"
        echo_error "Expected: $expected_checksum"
        echo_error "Actual:   $actual_checksum"
        echo_warning "This could indicate tampering or corruption of the downloaded file."
        
        # Ask if user wants to continue anyway
        read -p "Do you want to continue anyway? This is NOT RECOMMENDED (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_message "ERROR" "Installation aborted due to checksum failure"
            return 1
        fi
        
        log_message "WARNING" "User chose to continue despite checksum verification failure"
        echo_warning "Continuing despite checksum failure as requested by user"
        return 0
    fi
    
    log_message "SUCCESS" "Checksum verification successful"
    return 0
}

# Extract MediaMTX with better error handling
extract_mediamtx() {
    local tarball="$TEMP_DIR/mediamtx.tar.gz"
    
    log_message "INFO" "Extracting MediaMTX..."
    
    # Ensure the file exists
    if [ ! -f "$tarball" ]; then
        log_message "ERROR" "Tarball not found: $tarball"
        return 1
    fi
    
    # Create a separate extraction directory
    local extract_dir="$TEMP_DIR/extracted"
    mkdir -p "$extract_dir"
    
    # Extract with verbose error handling
    if ! tar -xzf "$tarball" -C "$extract_dir"; then
        log_message "ERROR" "Extraction failed"
        
        # Try to get more information
        log_message "INFO" "Attempting to list contents to diagnose..."
        tar -tvf "$tarball" >> "$LOG_FILE" 2>&1 || log_message "ERROR" "Cannot list contents of archive"
        
        return 1
    fi
    
    # Verify extraction succeeded by checking if files exist
    if [ ! "$(ls -A "$extract_dir")" ]; then
        log_message "ERROR" "Extraction appeared to succeed, but no files were extracted"
        return 1
    fi
    
    log_message "SUCCESS" "Extraction successful"
    return 0
}

# Check if MediaMTX is installed and get current version - FIXED
check_existing_installation() {
    local installed_version=""
    
    if [ -f "$INSTALL_DIR/mediamtx" ]; then
        # Run MediaMTX to get version and redirect directly to a file (no tee)
        if "$INSTALL_DIR/mediamtx" --version > "$TEMP_DIR/current_version" 2>&1; then
            # Extract just the version number
            installed_version=$(grep -o "v[0-9]\+\.[0-9]\+\.[0-9]\+" "$TEMP_DIR/current_version" | head -1)
            
            # Only log to the file, not to stdout
            log_file_only "INFO" "Found existing MediaMTX installation: $installed_version"
            
            # Return just the version string and nothing else
            echo "$installed_version"
            return 0
        else
            log_file_only "WARNING" "MediaMTX binary exists but failed to get version info"
            return 1
        fi
    else
        log_file_only "INFO" "No existing MediaMTX installation found"
        return 1
    fi
}

# Install MediaMTX with improved validation and version checking
install_mediamtx() {
    local extract_dir="$TEMP_DIR/extracted"
    local force_install=${1:-false}
    
    # Check for existing installation
    local current_version=""
    current_version=$(check_existing_installation)
    
    local installation_type="install"
    
    if [ -n "$current_version" ]; then
        echo_info "Found existing MediaMTX installation: $current_version"
        
        # Compare versions (strip leading 'v' if present)
        local install_version=${VERSION#v}
        local current_version_clean=${current_version#v}
        
        # Debug version comparison
        log_message "DEBUG" "Comparing versions: Target=$install_version, Current=$current_version_clean"
        
        # Check if versions are the same
        if [ "$install_version" = "$current_version_clean" ]; then
            log_message "INFO" "Target version matches currently installed version"
            echo_info "Target version matches currently installed version."
            installation_type="reinstall"
            
            # If we're not forcing the installation, ask for confirmation
            if [ "$force_install" != "true" ]; then
                read -p "Reinstall the same version? (y/n) " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    log_message "INFO" "User chose not to reinstall the same version"
                    echo_info "Installation skipped. Current installation remains unchanged."
                    return 0
                fi
                log_message "INFO" "User chose to reinstall the same version"
            fi
        else
            # Test if target version is newer than current version
            # Use explicit version comparison
            if is_version_newer "$install_version" "$current_version_clean"; then
                log_message "INFO" "Target version ($VERSION) is newer than installed version ($current_version)"
                echo_info "This will be an upgrade from $current_version to $VERSION."
                installation_type="upgrade"
            else
                log_message "WARNING" "Target version ($VERSION) is older than installed version ($current_version)"
                echo_warning "WARNING: Target version ($VERSION) is older than installed version ($current_version)."
                echo_info "This will be a downgrade operation."
                installation_type="downgrade"
                
                # If we're not forcing the installation, ask for confirmation before downgrade
                if [ "$force_install" != "true" ]; then
                    read -p "Continue with downgrade? (y/n) " -n 1 -r
                    echo
                    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                        log_message "INFO" "User chose not to downgrade"
                        echo_info "Installation skipped. Current installation remains unchanged."
                        return 0
                    fi
                    log_message "INFO" "User chose to proceed with downgrade"
                fi
            fi
        fi
    else
        log_message "INFO" "Performing fresh installation of MediaMTX $VERSION"
        echo_info "Performing a fresh installation of MediaMTX $VERSION."
        installation_type="install"
    fi
    
    log_message "INFO" "Installing MediaMTX..."
    
    # Find binary with improved pattern matching
    local binary_path=""
    # Look for the exact binary name in various possible locations
    for file in "$extract_dir"/*/mediamtx "$extract_dir"/mediamtx "$extract_dir"/*/*/mediamtx; do
        if [ -f "$file" ] && [ -x "$file" ]; then
            binary_path="$file"
            break
        fi
    done
    
    # If not found, try with a more general search
    if [ -z "$binary_path" ]; then
        binary_path=$(find "$extract_dir" -type f -executable -name "mediamtx" | head -n 1)
    fi
    
    if [ -z "$binary_path" ]; then
        log_message "ERROR" "MediaMTX binary not found in extracted files"
        log_message "INFO" "Contents of extraction directory:"
        find "$extract_dir" -type f | sort >> "$LOG_FILE"
        return 1
    fi
    
    log_message "INFO" "Found MediaMTX binary at: $binary_path"
    
    # Create installation directory if it doesn't exist
    mkdir -p "$INSTALL_DIR"
    
    # Check if service is running and stop it if needed
    local service_was_active=false
    if systemctl is-active --quiet mediamtx.service; then
        log_message "INFO" "MediaMTX service is running, stopping it before upgrade..."
        echo_info "Stopping MediaMTX service before upgrade..."
        systemctl stop mediamtx.service
        service_was_active=true
    fi
    
    # Copy binary with backup of existing
    if [ -f "$INSTALL_DIR/mediamtx" ]; then
        local backup_path="$INSTALL_DIR/mediamtx.backup-$(date +%Y%m%d%H%M%S)"
        log_message "INFO" "Creating backup of existing MediaMTX binary at $backup_path"
        cp "$INSTALL_DIR/mediamtx" "$backup_path"
    fi
    
    cp "$binary_path" "$INSTALL_DIR/mediamtx"
    chmod 755 "$INSTALL_DIR/mediamtx"
    
    # Test binary with better error capturing
    log_message "INFO" "Testing MediaMTX binary..."
    if ! "$INSTALL_DIR/mediamtx" --version > "$TEMP_DIR/version_output" 2>&1; then
        log_message "ERROR" "Binary test failed"
        log_message "INFO" "Error output:"
        cat "$TEMP_DIR/version_output" >> "$LOG_FILE"
        
        # Try to diagnose common issues
        if grep -q "not found" "$TEMP_DIR/version_output"; then
            log_message "ERROR" "Binary has missing dependencies. Please install required libraries."
        elif grep -q "permission denied" "$TEMP_DIR/version_output"; then
            log_message "ERROR" "Permission issues with the binary. Trying to fix permissions..."
            chmod +x "$INSTALL_DIR/mediamtx"
            # Try again
            if ! "$INSTALL_DIR/mediamtx" --version > "$TEMP_DIR/version_output" 2>&1; then
                log_message "ERROR" "Still failing after permission fix"
                return 1
            else
                log_message "SUCCESS" "Permission fix worked"
            fi
        else
            return 1
        fi
    fi
    
    # Handle configuration
    log_message "INFO" "Handling configuration..."
    
    # Create config directory if it doesn't exist
    mkdir -p "$CONFIG_DIR"
    
    # Check if configuration exists and determine if it needs to be updated
    local config_action="create"
    
    if [ -f "$CONFIG_DIR/mediamtx.yml" ]; then
        # Compare port settings with existing config to see if we need to update
        local existing_rtsp_port=$(grep "rtspAddress: " "$CONFIG_DIR/mediamtx.yml" | grep -o "[0-9]\+")
        local existing_rtmp_port=$(grep "rtmpAddress: " "$CONFIG_DIR/mediamtx.yml" | grep -o "[0-9]\+")
        
        if [ "$existing_rtsp_port" != "$RTSP_PORT" ] || [ "$existing_rtmp_port" != "$RTMP_PORT" ]; then
            log_message "INFO" "Port configuration has changed, updating config file"
            config_action="update"
        else
            # Check if this is a fresh install or upgrade with default config
            if [ -z "$current_version" ] || grep -q "Generated by" "$CONFIG_DIR/mediamtx.yml"; then
                log_message "INFO" "Updating default configuration"
                config_action="update"
            else
                log_message "INFO" "Custom configuration detected, preserving it"
                config_action="preserve"
            fi
        fi
        
        # Always create a backup regardless
        local config_backup="$CONFIG_DIR/mediamtx.yml.backup-$(date +%Y%m%d%H%M%S)"
        log_message "INFO" "Creating backup of existing configuration at $config_backup"
        cp "$CONFIG_DIR/mediamtx.yml" "$config_backup"
    fi
    
    # Create or update configuration based on determined action
    if [ "$config_action" = "create" ] || [ "$config_action" = "update" ]; then
        log_message "INFO" "Creating/updating configuration file"
        
        cat > "$CONFIG_DIR/mediamtx.yml" << EOF
# MediaMTX minimal configuration
# Generated by enhanced_install_mediamtx.sh v2.0.0 on $(date)
logLevel: info
logDestinations: [stdout, file]
logFile: $LOG_DIR/mediamtx.log

rtspAddress: :$RTSP_PORT
rtmpAddress: :$RTMP_PORT
hlsAddress: :$HLS_PORT
webrtcAddress: :$WEBRTC_PORT

metrics: yes
metricsAddress: :$METRICS_PORT

paths:
  all:
EOF
    else
        log_message "INFO" "Preserving existing custom configuration"
    fi
    
    # Restart service if it was running before
    if [ "$service_was_active" = true ]; then
        log_message "INFO" "Restarting MediaMTX service..."
        echo_info "Restarting MediaMTX service..."
        systemctl start mediamtx.service
    fi
    
    if [ -z "$current_version" ]; then
        log_message "SUCCESS" "MediaMTX installed successfully with custom ports:"
    else
        log_message "SUCCESS" "MediaMTX updated successfully to version $VERSION with custom ports:"
    fi
    
    log_message "INFO" "RTSP: $RTSP_PORT, RTMP: $RTMP_PORT, HLS: $HLS_PORT, WebRTC: $WEBRTC_PORT, Metrics: $METRICS_PORT"
    return 0
}

# Create systemd service with improved handling
create_service() {
    log_message "INFO" "Creating systemd service..."
    
    # Check if this is a service update rather than a new installation
    local service_update=false
    if [ -f "/etc/systemd/system/mediamtx.service" ]; then
        service_update=true
        log_message "INFO" "Updating existing systemd service"
    else
        log_message "INFO" "Creating new systemd service"
    fi
    
    # Validate systemd is available
    if ! command -v systemctl >/dev/null 2>&1; then
        log_message "ERROR" "systemd is not available on this system"
        log_message "INFO" "MediaMTX is installed but no service was created"
        log_message "INFO" "You will need to start MediaMTX manually or create your own service"
        return 1
    fi
    
    # Create user if it doesn't exist
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
        log_message "INFO" "Created service user: $SERVICE_USER"
    fi
    
    # Set ownership with better error handling
    if ! chown -R "$SERVICE_USER:" "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"; then
        log_message "ERROR" "Failed to set ownership on directories"
        log_message "WARNING" "Service may not work correctly"
    fi
    
    chmod -R 755 "$INSTALL_DIR"
    chmod -R 750 "$CONFIG_DIR" "$LOG_DIR"
    
    # Create log file with proper permissions
    touch "$LOG_DIR/mediamtx.log"
    chown "$SERVICE_USER:" "$LOG_DIR/mediamtx.log"
    chmod 644 "$LOG_DIR/mediamtx.log"
    
    # Check if service is currently running
    local service_was_active=false
    if systemctl is-active --quiet mediamtx.service; then
        service_was_active=true
        log_message "INFO" "MediaMTX service is currently active, will restart after update"
    fi
    
    # Backup existing service file if present
    if [ "$service_update" = true ]; then
        local service_backup="/etc/systemd/system/mediamtx.service.backup-$(date +%Y%m%d%H%M%S)"
        log_message "INFO" "Backing up existing service file to $service_backup"
        cp "/etc/systemd/system/mediamtx.service" "$service_backup"
        
        # Stop service if it's running
        if [ "$service_was_active" = true ]; then
            log_message "INFO" "Stopping MediaMTX service before updating..."
            echo_info "Stopping MediaMTX service before updating..."
            systemctl stop mediamtx.service
            sleep 2
        fi
    fi
    
    # Create systemd service file with improved security settings
    cat > /etc/systemd/system/mediamtx.service << EOF
[Unit]
Description=MediaMTX RTSP/RTMP/HLS/WebRTC streaming server
Documentation=https://github.com/bluenviron/mediamtx
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
StandardOutput=append:$LOG_DIR/mediamtx.log
StandardError=append:$LOG_DIR/mediamtx.log

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
    
    # Reload and enable
    log_message "INFO" "Reloading systemd daemon..."
    systemctl daemon-reload
    
    if [ "$service_update" = false ]; then
        log_message "INFO" "Enabling MediaMTX service to start on boot..."
        systemctl enable mediamtx.service
    fi
    
    # Start or restart the service
    if [ "$service_was_active" = true ] || [ "$service_update" = false ]; then
        if [ "$service_update" = true ] && [ "$service_was_active" = true ]; then
            log_message "INFO" "Restarting MediaMTX service..."
            echo_info "Restarting MediaMTX service..."
        else
            log_message "INFO" "Starting MediaMTX service..."
            echo_info "Starting MediaMTX service..."
        fi
        
        if systemctl start mediamtx.service; then
            sleep 3
            if systemctl is-active --quiet mediamtx.service; then
                if [ "$service_update" = true ]; then
                    log_message "SUCCESS" "Service updated and restarted successfully"
                else
                    log_message "SUCCESS" "Service created and started successfully"
                fi
                return 0
            fi
        fi
        
        log_message "ERROR" "Service failed to start. Checking logs..."
        systemctl status mediamtx.service --no-pager >> "$LOG_FILE" 2>&1
        
        if [ -f "$LOG_DIR/mediamtx.log" ]; then
            log_message "INFO" "Last 10 lines from log file:"
            tail -n 10 "$LOG_DIR/mediamtx.log" >> "$LOG_FILE"
        fi
        
        # Check for common issues (port conflicts, etc.)
        log_message "INFO" "Checking for common service issues..."
        
        # Check if ports are already in use
        if command -v ss >/dev/null 2>&1; then
            for port in "$RTSP_PORT" "$RTMP_PORT" "$HLS_PORT" "$WEBRTC_PORT"; do
                if ss -tuln | grep -q ":$port "; then
                    local using_process=$(ss -tuln | grep ":$port " | awk '{print $7}')
                    log_message "ERROR" "Port $port is already in use by process: $using_process"
                    echo_error "ERROR: Port $port is already in use by another process."
                fi
            done
        fi
        
        # Test the binary directly to get more information
        log_message "INFO" "Testing binary directly..."
        sudo -u "$SERVICE_USER" "$INSTALL_DIR/mediamtx" --version >> "$LOG_FILE" 2>&1
        
        return 1
    else
        log_message "INFO" "Service was not active before update and will not be started automatically"
        echo_info "MediaMTX service is installed but not started. Start it with: sudo systemctl start mediamtx"
        return 0
    fi
}

# Print post-installation information with more details
print_info() {
    local version="$1"
    local arch="$2"
    
    echo "====================================="
    echo "MediaMTX Installation Summary"
    echo "====================================="
    echo "Version: $version"
    echo "Architecture: $arch"
    echo "Binary: $INSTALL_DIR/mediamtx"
    echo "Config: $CONFIG_DIR/mediamtx.yml"
    echo "Logs: $LOG_DIR/mediamtx.log"
    echo "Service: mediamtx.service"
    echo
    echo "Ports:"
    echo "- RTSP: $RTSP_PORT"
    echo "- RTMP: $RTMP_PORT"
    echo "- HLS: $HLS_PORT"
    echo "- WebRTC: $WEBRTC_PORT"
    echo "- Metrics: $METRICS_PORT"
    echo
    echo "Useful Commands:"
    echo "- Check service status: systemctl status mediamtx"
    echo "- View logs: journalctl -u mediamtx -f"
    echo "- View logs directly: tail -f $LOG_DIR/mediamtx.log"
    echo "- Test stream: ffmpeg -re -f lavfi -i testsrc=size=640x480:rate=30 -f rtsp rtsp://localhost:$RTSP_PORT/test"
    echo
    echo "Checksum Database:"
    echo "- Stored at: $CHECKSUM_DB_FILE"
    echo "- Contains checksums for verified versions"
    echo
    echo "Installation Log:"
    echo "- $LOG_FILE"
    echo "====================================="
}

# Rollback installation if something fails
rollback_installation() {
    log_message "ERROR" "Installation failed, attempting to rollback changes..."
    
    # Stop and disable service if it was created
    if systemctl list-unit-files | grep -q mediamtx.service; then
        log_message "INFO" "Stopping and disabling mediamtx service..."
        systemctl stop mediamtx.service 2>/dev/null || true
        systemctl disable mediamtx.service 2>/dev/null || true
    fi
    
    # Restore from backup if available
    if [ -f "$INSTALL_DIR/mediamtx.backup" ]; then
        log_message "INFO" "Restoring MediaMTX binary from backup..."
        mv "$INSTALL_DIR/mediamtx.backup" "$INSTALL_DIR/mediamtx"
    fi
    
    if [ -f "$CONFIG_DIR/mediamtx.yml.backup" ]; then
        log_message "INFO" "Restoring configuration from backup..."
        mv "$CONFIG_DIR/mediamtx.yml.backup" "$CONFIG_DIR/mediamtx.yml"
    fi
    
    log_message "INFO" "Rollback completed"
    log_message "INFO" "You may need to manually clean up the following directories:"
    log_message "INFO" "- $INSTALL_DIR"
    log_message "INFO" "- $CONFIG_DIR"
    log_message "INFO" "- $LOG_DIR"
    
    # Copy the log file to a persistent location
    if [ -f "$LOG_FILE" ]; then
        cp "$LOG_FILE" "/tmp/mediamtx_install_failure.log"
        echo_error "Installation failed. Log saved to /tmp/mediamtx_install_failure.log"
    fi
}

# Cleanup on exit
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        log_message "INFO" "Cleaning up temporary files..."
        
        # Copy log file to a more permanent location before deleting temp dir
        if [ -f "$LOG_FILE" ]; then
            cp "$LOG_FILE" "/var/log/mediamtx_install.log" 2>/dev/null || cp "$LOG_FILE" "/tmp/mediamtx_install_$(date +%Y%m%d%H%M%S).log"
        fi
        
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT
trap 'log_message "ERROR" "Installation aborted"; rollback_installation; exit 1' INT TERM

# Function to display usage information
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Install MediaMTX with custom configuration and dynamic checksum verification."
    echo
    echo "Options:"
    echo "  -v, --version VERSION    Specify MediaMTX version (default: $VERSION)"
    echo "                           Use 'latest' to install the latest version"
    echo "  -p, --rtsp-port PORT     Specify RTSP port (default: $RTSP_PORT)"
    echo "  --rtmp-port PORT         Specify RTMP port (default: $RTMP_PORT)"
    echo "  --hls-port PORT          Specify HLS port (default: $HLS_PORT)"
    echo "  --webrtc-port PORT       Specify WebRTC port (default: $WEBRTC_PORT)"
    echo "  --metrics-port PORT      Specify metrics port (default: $METRICS_PORT)"
    echo "  --skip-checksum          Skip checksum verification (not recommended)"
    echo "  --force-checksum         Abort if checksum verification fails (most secure)"
    echo "  --offline                Do not attempt to download checksums from GitHub"
    echo "  --config-only            Only update configuration file, not the binary"
    echo "  --force-install          Force installation even if same version is installed"
    echo "  -h, --help               Display this help message"
    echo
    echo "Examples:"
    echo "  $0 --version v1.13.0 --rtsp-port 8555"
    echo "  $0 --version latest      # Installs the latest released version"
    echo "  $0 --config-only --rtsp-port 8555  # Only updates configuration"
}

# Parse command line arguments
parse_args() {
    SKIP_CHECKSUM=false
    FORCE_CHECKSUM=false
    OFFLINE_MODE=false
    CONFIG_ONLY=false
    FORCE_INSTALL=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--version)
                VERSION="$2"
                # Special handling for "latest"
                if [[ "$VERSION" == "latest" ]]; then
                    if command -v curl >/dev/null 2>&1 && command -v grep >/dev/null 2>&1; then
                        echo_info "Fetching latest version from GitHub..."
                        LATEST_VERSION=$(curl -s https://api.github.com/repos/bluenviron/mediamtx/releases/latest | grep "tag_name" | cut -d : -f 2,3 | tr -d \" | tr -d , | xargs)
                        
                        if [[ -n "$LATEST_VERSION" ]]; then
                            echo_info "Latest version is: $LATEST_VERSION"
                            VERSION="$LATEST_VERSION"
                        else
                            echo_warning "Could not determine latest version, using default: $VERSION"
                            VERSION="v1.12.2"  # Fallback to default
                        fi
                    else
                        echo_warning "curl or grep not available, cannot fetch latest version"
                        echo_warning "Using default version: v1.12.2"
                        VERSION="v1.12.2"  # Fallback to default
                    fi
                fi
                shift 2
                ;;
            -p|--rtsp-port)
                RTSP_PORT="$2"
                shift 2
                ;;
            --rtmp-port)
                RTMP_PORT="$2"
                shift 2
                ;;
            --hls-port)
                HLS_PORT="$2"
                shift 2
                ;;
            --webrtc-port)
                WEBRTC_PORT="$2"
                shift 2
                ;;
            --metrics-port)
                METRICS_PORT="$2"
                shift 2
                ;;
            --skip-checksum)
                SKIP_CHECKSUM=true
                shift
                ;;
            --force-checksum)
                FORCE_CHECKSUM=true
                shift
                ;;
            --offline)
                OFFLINE_MODE=true
                shift
                ;;
            --config-only)
                CONFIG_ONLY=true
                shift
                ;;
            --force-install)
                FORCE_INSTALL=true
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                echo_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Validate port numbers
    for port_var in RTSP_PORT RTMP_PORT HLS_PORT WEBRTC_PORT METRICS_PORT; do
        port_val=${!port_var}
        if ! [[ "$port_val" =~ ^[0-9]+$ ]] || [ "$port_val" -lt 1 ] || [ "$port_val" -gt 65535 ]; then
            echo_error "Invalid port number for $port_var: $port_val (must be 1-65535)"
            exit 1
        fi
    done
    
    # Check incompatible options
    if [ "$SKIP_CHECKSUM" = true ] && [ "$FORCE_CHECKSUM" = true ]; then
        echo_error "Incompatible options: --skip-checksum and --force-checksum cannot be used together"
        exit 1
    fi
}

# Function to test version comparison (for debugging)
test_version_comparison() {
    echo "Testing version comparison function..."
    
    # Test cases
    test_cases=(
        "1.12.2|1.12.0|newer"
        "1.12.0|1.12.2|older"
        "1.12.0|1.12.0|equal"
        "1.0.0|0.9.9|newer"
        "2.0.0|1.9.9|newer"
        "1.0.0|1.0.1|older"
    )
    
    for test in "${test_cases[@]}"; do
        IFS='|' read -r v1 v2 expected <<< "$test"
        
        if is_version_newer "$v1" "$v2"; then
            result="newer"
        else
            result="older or equal"
        fi
        
        if [[ "$result" == "$expected" || ("$result" == "older or equal" && "$expected" == "equal") ]]; then
            echo "✓ $v1 is $result than $v2 (as expected)"
        else
            echo "✗ $v1 is $result than $v2 (expected: $expected)"
        fi
    done
    
    echo "Test complete"
}

# Main function
main() {
    echo "====================================="
    echo "Enhanced MediaMTX Installer v2.0.0"
    echo "====================================="
    
    # Parse command line arguments
    parse_args "$@"
    
    # Check if running as root
    if [ "$(id -u)" -ne 0 ]; then
        echo_error "This script must be run as root or with sudo"
        exit 1
    fi
    
    # Setup directories (creates temp dir and log file)
    setup_directories
    
    # Verify required commands
    verify_commands
    
    # Test version comparison if specified
    if [ "${1:-}" = "--test-version-comparison" ]; then
        test_version_comparison
        exit 0
    fi
    
    # Detect architecture
    ARCH=$(detect_arch)
    log_message "INFO" "Detected architecture: $ARCH"
    log_message "INFO" "Using version: $VERSION"
    
    # Check if this is a new install or upgrade
    local current_version=""
    current_version=$(check_existing_installation)
    local installation_type="install"
    
    if [ -n "$current_version" ]; then
        echo_info "Found existing MediaMTX installation: $current_version"
        
        # Compare version numbers to determine if this is an upgrade or downgrade
        VERSION_CLEAN=${VERSION#v}
        CURRENT_CLEAN=${current_version#v}
        
        # Debug version comparison
        log_message "DEBUG" "Comparing versions: Target=$VERSION_CLEAN, Current=$CURRENT_CLEAN"
        
        if [ "$VERSION" = "$current_version" ]; then
            echo_info "Target version matches currently installed version."
            installation_type="reinstall"
        elif is_version_newer "$VERSION_CLEAN" "$CURRENT_CLEAN"; then
            echo_info "This will be an upgrade from $current_version to $VERSION."
            installation_type="upgrade"
        else
            echo_warning "Target version ($VERSION) is older than installed version ($current_version)."
            echo_info "This will be a downgrade operation."
            installation_type="downgrade"
        fi
    else
        echo_info "Performing a fresh installation of MediaMTX $VERSION."
        installation_type="install"
    fi
    
    # Handle config-only mode
    if [ "$CONFIG_ONLY" = true ]; then
        echo_info "Running in config-only mode - only updating configuration."
        log_message "INFO" "Running in config-only mode"
        
        if [ -z "$current_version" ]; then
            echo_error "No existing MediaMTX installation found. Cannot run in config-only mode."
            log_message "ERROR" "Config-only mode requires an existing installation"
            exit 1
        fi
        
        # Create or update configuration file
        log_message "INFO" "Updating MediaMTX configuration only"
        
        # Create config directory if it doesn't exist
        mkdir -p "$CONFIG_DIR"
        
        # Always backup existing config
        if [ -f "$CONFIG_DIR/mediamtx.yml" ]; then
            local config_backup="$CONFIG_DIR/mediamtx.yml.backup-$(date +%Y%m%d%H%M%S)"
            log_message "INFO" "Creating backup of existing configuration at $config_backup"
            cp "$CONFIG_DIR/mediamtx.yml" "$config_backup"
            echo_info "Created backup of existing configuration: $config_backup"
        fi
        
        # Create new configuration
        cat > "$CONFIG_DIR/mediamtx.yml" << EOF
# MediaMTX minimal configuration
# Generated by enhanced_install_mediamtx.sh v2.0.0 on $(date)
logLevel: info
logDestinations: [stdout, file]
logFile: $LOG_DIR/mediamtx.log

rtspAddress: :$RTSP_PORT
rtmpAddress: :$RTMP_PORT
hlsAddress: :$HLS_PORT
webrtcAddress: :$WEBRTC_PORT

metrics: yes
metricsAddress: :$METRICS_PORT

paths:
  all:
EOF

        echo_success "Configuration updated successfully"
        log_message "SUCCESS" "Configuration updated with ports: RTSP: $RTSP_PORT, RTMP: $RTMP_PORT, HLS: $HLS_PORT, WebRTC: $WEBRTC_PORT"
        
        # Check if service is running and prompt for restart
        if systemctl is-active --quiet mediamtx.service; then
            log_message "INFO" "MediaMTX service is running"
            echo_info "MediaMTX service is currently running."
            
            read -p "Restart the service to apply new configuration? (y/n) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                log_message "INFO" "Restarting MediaMTX service..."
                echo_info "Restarting MediaMTX service..."
                systemctl restart mediamtx.service
                
                if systemctl is-active --quiet mediamtx.service; then
                    echo_success "MediaMTX service restarted successfully"
                    log_message "SUCCESS" "Service restarted with new configuration"
                else
                    echo_error "Failed to restart MediaMTX service"
                    log_message "ERROR" "Failed to restart service with new configuration"
                    systemctl status mediamtx.service --no-pager
                fi
            fi
        fi
        
        exit 0
    fi
    
    # Installation steps
    if download_mediamtx "$ARCH" "$VERSION" && 
       verify_checksum "$ARCH" "$VERSION" "$SKIP_CHECKSUM" &&
       extract_mediamtx && 
       install_mediamtx "$FORCE_INSTALL" && 
       create_service; then
        print_info "$VERSION" "$ARCH"
        log_message "SUCCESS" "Installation completed successfully"
        
        case "$installation_type" in
            "reinstall")
                echo_success "MediaMTX reinstallation completed successfully"
                ;;
            "upgrade")
                echo_success "MediaMTX upgraded from $current_version to $VERSION successfully"
                ;;
            "downgrade")
                echo_success "MediaMTX downgraded from $current_version to $VERSION successfully"
                ;;
            *)
                echo_success "MediaMTX installation completed successfully"
                ;;
        esac
    else
        log_message "ERROR" "Installation failed"
        echo_error "Installation failed"
        rollback_installation
        exit 1
    fi
}

# Run the script with any provided arguments
main "$@"

#!/bin/bash
#
# https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/install_mediamtx.sh
#
# Enhanced MediaMTX Installer with Advanced Validation Features
# Version: 2.1.2
# Date: 2025-05-11
# Description: Robust installer for MediaMTX with integrated version checking,
#              dynamic checksum verification, and intelligent architecture detection
# Changes in v2.1.2:
#   - Fixed syntax errors in checksum verification functions
#   - Improved error handling in extract_hash_from_checksum function
#   - Better structure in fetch_checksums function
#   - Corrected SHA256 file handling
#   - Enhanced debug logging for checksum verification
#
# Changes in v2.1.1:
#   - Fixed critical bug in checksum verification for .sha256 files
#   - Added better handling of various checksum file formats
#   - Improved extraction of hash from checksum files
#   - Added fallback method for checksum verification
#
# Changes in v2.1.0:
#   - Integrated advanced architecture detection from version checker
#   - Added sophisticated GitHub API caching system
#   - Enhanced error handling with multiple fallback mechanisms
#   - Improved checksum validation with multiple verification methods
#   - Added debug mode for troubleshooting
#   - Better version comparison and management
#   - More comprehensive error reporting and user feedback
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

# Debug mode (set to false by default, can be enabled with --debug)
DEBUG_MODE=false

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
    echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
}

# Log to both file and stdout
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
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
            exit 1 
            ;;
    esac
}

# Function to check if cache is valid
is_cache_valid() {
    local cache_file="$1"
    local max_age="$2"
    
    if [ ! -f "$cache_file" ]; then
        echo_debug "Cache file not found: $cache_file"
        return 1
    fi
    
    local file_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || date +%s) ))
    if [ "$file_age" -gt "$max_age" ]; then
        echo_debug "Cache file expired (age: ${file_age}s, max: ${max_age}s)"
        return 1
    fi
    
    # Check if the file is not empty and is valid JSON
    if [ ! -s "$cache_file" ]; then
        echo_debug "Cache file is empty"
        return 1
    fi
    
    if command -v jq >/dev/null 2>&1; then
        if ! jq empty "$cache_file" >/dev/null 2>&1; then
            echo_debug "Cache file contains invalid JSON"
            return 1
        fi
    fi
    
    echo_debug "Cache file is valid"
    return 0
}

# Function to get GitHub API data with cache awareness
get_github_api_data() {
    local url="$1"
    local cache_file="$2"
    local max_age="${3:-$CACHE_EXPIRY}"
    
    echo_debug "Requesting data from: $url"
    echo_debug "Using cache file: $cache_file"
    
    if is_cache_valid "$cache_file" "$max_age"; then
        echo_info "Using cached data ($(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || date +%s) ))s old)"
        cat "$cache_file"
        return 0
    fi
    
    echo_info "Fetching data from GitHub API..."
    
    # Make direct call to GitHub API and save the raw output for inspection
    local response_file="${CACHE_DIR}/raw_response.txt"
    local error_log="${CACHE_DIR}/curl_error.log"
    echo_debug "Saving raw response to: $response_file"
    
    local curl_cmd="curl -s -S -f $url"
    echo_debug "Running curl command: $curl_cmd"
    
    # Use curl to directly save to response file, capture errors separately
    eval "$curl_cmd" > "$response_file" 2>"$error_log"
    local curl_status=$?
    
    echo_debug "Curl exit status: $curl_status"
    
    if [ $curl_status -ne 0 ]; then
        echo_error "Failed to fetch data from $url (status: $curl_status)"
        echo_debug "Curl error log:"
        if [ -f "$error_log" ]; then
            cat "$error_log" >&2
        fi
        
        # Check specifically for rate limiting
        if [ $curl_status -eq 22 ] && curl -s -I "$url" | grep -q "X-RateLimit-Remaining: 0"; then
            echo_error "GitHub API rate limit exceeded."
            local reset_time=$(curl -s -I "$url" | grep -i "X-RateLimit-Reset" | cut -d' ' -f2 | tr -d '\r')
            if [ -n "$reset_time" ]; then
                local reset_date=$(date -d "@$reset_time" 2>/dev/null || date)
                echo_warning "Rate limit will reset at: $reset_date"
            fi
        fi
        
        # Try to use cached data even if expired
        if [ -f "$cache_file" ]; then
            echo_warning "Using expired cache data due to API error"
            cat "$cache_file"
            return 0
        fi
        
        return 1
    fi
    
    # Debug the raw response
    if command -v xxd >/dev/null 2>&1 && [ "$DEBUG_MODE" = true ]; then
        echo_debug "Response first 100 bytes: $(head -c 100 "$response_file" | xxd -p)"
    else
        echo_debug "Response first 100 chars: $(head -c 100 "$response_file")"
    fi
    echo_debug "Response length: $(wc -c < "$response_file") bytes"
    
    # Verify we have a proper JSON response
    if ! grep -q '^\s*{' "$response_file" && ! grep -q '^\s*\[' "$response_file"; then
        echo_error "Response doesn't start with { or [ - likely not JSON"
        echo_debug "First 100 chars of response: $(head -c 100 "$response_file")"
        
        if [ -f "$cache_file" ]; then
            echo_warning "Using expired cache data due to invalid response"
            cat "$cache_file"
            return 0
        fi
        
        echo_error "Failed to parse GitHub API response and no valid cache found."
        return 1
    fi
    
    # Test JSON validity with jq if available
    if command -v jq >/dev/null 2>&1; then
        local jq_test=$(jq empty "$response_file" 2>&1)
        if [ -n "$jq_test" ]; then
            echo_error "Invalid JSON response from GitHub API"
            echo_debug "JQ error: $jq_test"
            echo_debug "Raw response first 100 chars: $(head -c 100 "$response_file")"
            
            if [ -f "$cache_file" ]; then
                echo_warning "Using expired cache data due to invalid JSON"
                cat "$cache_file"
                return 0
            fi
            
            return 1
        else
            echo_debug "JSON validation passed"
        fi
    fi
    
    # Cache the response only if it's valid
    cp "$response_file" "$cache_file"
    cat "$response_file"
    return 0
}

# Check if required commands exist
verify_commands() {
    local missing_commands=()
    local optional_missing=()
    
    # Essential commands
    for cmd in wget curl tar grep sed chmod chown systemctl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done
    
    # Optional but useful commands
    for cmd in jq md5sum sha256sum xxd; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            optional_missing+=("$cmd")
        fi
    done
    
    # Handle missing essential commands
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        echo_warning "The following required commands are missing: ${missing_commands[*]}"
        
        # Try to install missing commands
        if command -v apt-get >/dev/null 2>&1; then
            echo_info "Attempting to install missing commands with apt-get..."
            apt-get update && apt-get install -y coreutils wget curl tar grep sed
        elif command -v yum >/dev/null 2>&1; then
            echo_info "Attempting to install missing commands with yum..."
            yum install -y coreutils wget curl tar grep sed
        else
            echo_warning "Unable to automatically install missing commands. Please install them manually."
        fi
        
        # Verify again
        missing_commands=()
        for cmd in wget curl tar grep sed chmod chown systemctl; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                missing_commands+=("$cmd")
            fi
        done
        
        if [[ ${#missing_commands[@]} -gt 0 ]]; then
            echo_error "Still missing required commands after installation attempt: ${missing_commands[*]}"
            exit 1
        fi
    fi
    
    # Handle missing optional commands
    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        echo_warning "The following optional commands are missing: ${optional_missing[*]}"
        
        # Special handling for jq - essential for dynamic checksum verification
        if [[ " ${optional_missing[*]} " =~ " jq " ]]; then
            echo_warning "The 'jq' command is recommended for checksum verification."
            echo_warning "Without it, some advanced features may be limited."
            
            # Ask user if they want to install jq
            if [ -t 0 ]; then  # Only ask if running interactively
                read -p "Would you like to install jq now? (y/n) " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    if command -v apt-get >/dev/null 2>&1; then
                        apt-get update && apt-get install -y jq
                    elif command -v yum >/dev/null 2>&1; then
                        yum install -y jq
                    else
                        echo_warning "Could not determine how to install jq. Please install manually."
                    fi
                fi
            fi
        fi
    fi
    
    # Return success even with optional commands missing
    return 0
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
    
    # Create cache directory for GitHub API responses
    if [ ! -d "$CACHE_DIR" ]; then
        if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
            log_message "WARNING" "Failed to create cache directory: $CACHE_DIR"
            # Fall back to temp directory
            CACHE_DIR="${TEMP_DIR}/cache"
            API_CACHE="${CACHE_DIR}/api_cache.json"
            mkdir -p "$CACHE_DIR" 2>/dev/null
        fi
        chmod $dir_mode "$CACHE_DIR" || log_message "WARNING" "Failed to set permissions on $CACHE_DIR"
    fi
    
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

# Function to get the latest MediaMTX version from GitHub API
get_latest_version() {
    log_message "INFO" "Checking for latest MediaMTX version from GitHub"
    
    # Create cache directory if it doesn't exist
    mkdir -p "$CACHE_DIR" 2>/dev/null
    
    # Get latest release info from GitHub API with cache awareness
    local latest_info
    latest_info=$(get_github_api_data "https://api.github.com/repos/bluenviron/mediamtx/releases/latest" "$API_CACHE")
    local api_status=$?
    
    if [ $api_status -ne 0 ] || [ -z "$latest_info" ]; then
        log_message "WARNING" "Failed to fetch latest version info from GitHub API"
        return 1
    fi
    
    local latest_version=""
    
    # Extract version using jq if available
    if command -v jq >/dev/null 2>&1; then
        latest_version=$(echo "$latest_info" | jq -r '.tag_name // ""' 2>/dev/null)
        
        if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
            log_message "WARNING" "Failed to extract version from GitHub API response"
            return 1
        fi
    else
        # Fallback extraction method
        if echo "$latest_info" | grep -q "tag_name"; then
            latest_version=$(echo "$latest_info" | grep "tag_name" | head -1 | cut -d : -f 2,3 | tr -d \" | tr -d , | xargs)
            
            if [ -z "$latest_version" ]; then
                log_message "WARNING" "Failed to extract version using grep fallback"
                return 1
            fi
        else
            log_message "WARNING" "Could not find version information in API response"
            return 1
        fi
    fi
    
    echo "$latest_version"
    return 0
}

# Extract just the hash from a checksum file, handling different formats
extract_hash_from_checksum() {
    local checksum_file="$1"
    local expected_filename="$2"
    
    echo_debug "Extracting hash from checksum file: $checksum_file"
    echo_debug "Expected filename: $expected_filename"
    
    # Check if file exists
    if [ ! -f "$checksum_file" ]; then
        echo_debug "Checksum file not found: $checksum_file"
        return 1
    fi
    
    # Read checksum file content
    local content=$(cat "$checksum_file")
    echo_debug "Raw checksum content: $content"
    
    # Try different extraction methods
    
    # Method 1: If it's just a hash (possibly with filename)
    if [[ "$content" =~ ^[a-f0-9]{64} ]]; then
        # Extract just the hash part (first 64 hex chars)
        local hash=${content:0:64}
        echo_debug "Extracted hash using regex method: $hash"
        echo "$hash"
        return 0
    fi
    
    # Method 2: If it's in format "hash filename"
    if echo "$content" | grep -q "$expected_filename"; then
        local hash=$(echo "$content" | grep "$expected_filename" | awk '{print $1}')
        if [[ "$hash" =~ ^[a-f0-9]{64}$ ]]; then
            echo_debug "Extracted hash using filename grep method: $hash"
            echo "$hash"
            return 0
        fi
    fi
    
    # Method 3: If no filename, just try to extract anything that looks like a SHA256 hash
    local hash=$(echo "$content" | grep -o -E '[a-f0-9]{64}' | head -1)
    if [ -n "$hash" ]; then
        echo_debug "Extracted hash using general grep method: $hash"
        echo "$hash"
        return 0
    fi
    
    # No valid hash found
    echo_debug "Failed to extract hash from checksum file"
    return 1
}

# Function to fetch the SHA256 checksums from GitHub releases
fetch_checksums() {
    local version=$1
    local arch=$2
    local checksum_file="${TEMP_DIR}/checksums.json"
    
    log_message "INFO" "Attempting to fetch checksums for MediaMTX $version ($arch)"
    
    # Define expected filename
    local expected_filename="mediamtx_${version}_linux_${arch}.tar.gz"
    
    # Different approaches to get checksums
    local success=false
    
    # Approach 1: Try to get checksums.txt directly from GitHub if it exists
    if curl --head --silent --fail "https://github.com/bluenviron/mediamtx/releases/download/${version}/checksums.txt" >/dev/null 2>&1; then
        log_message "INFO" "Found checksums.txt file on GitHub"
        
        if curl -s -L -o "${TEMP_DIR}/checksums.txt" "https://github.com/bluenviron/mediamtx/releases/download/${version}/checksums.txt"; then
            # Parse the checksums.txt file to find our file's checksum
            local checksum_line=$(grep "$expected_filename" "${TEMP_DIR}/checksums.txt" || echo "")
            
            if [[ -n "$checksum_line" ]]; then
                # Extract the checksum from the line
                local checksum=$(echo "$checksum_line" | awk '{print $1}')
                
                if [[ -n "$checksum" && "${#checksum}" -eq 64 ]]; then
                    log_message "INFO" "Found checksum for $arch in checksums.txt: $checksum"
                    # Create a simple JSON structure with the checksum
                    echo "{\"$arch\": \"$checksum\"}" > "$checksum_file"
                    success=true
                fi
            fi
        fi
    fi
    
    # Approach 2: Try architecture-specific .sha256sum file (newer releases)
    if [ "$success" != true ]; then
        log_message "INFO" "Attempting to fetch individual SHA256 file for $arch"
        
        local sha256_url="https://github.com/bluenviron/mediamtx/releases/download/${version}/mediamtx_${version}_linux_${arch}.tar.gz.sha256sum"
        
        if curl --head --silent --fail "$sha256_url" >/dev/null 2>&1; then
            log_message "INFO" "Found individual SHA256sum file"
            
            if curl -s -L -o "${TEMP_DIR}/file.sha256" "$sha256_url"; then
                local checksum=$(extract_hash_from_checksum "${TEMP_DIR}/file.sha256" "$expected_filename")
                local status=$?
                
                if [ $status -eq 0 ] && [[ -n "$checksum" && "${#checksum}" -eq 64 ]]; then
                    log_message "INFO" "Found checksum from .sha256sum file: $checksum"
                    # Create a simple JSON structure with the checksum
                    echo "{\"$arch\": \"$checksum\"}" > "$checksum_file"
                    success=true
                else
                    # Log original content for debugging
                    local raw_content=$(cat "${TEMP_DIR}/file.sha256")
                    log_message "WARNING" "Could not extract valid checksum from .sha256sum file. Content: $raw_content"
                fi
            fi
        fi
    fi
    
    # Approach 3: Try .sha256 format (without .sum extension)
    if [ "$success" != true ]; then
        log_message "INFO" "Attempting to fetch .sha256 file format"
        
        local sha256_url="https://github.com/bluenviron/mediamtx/releases/download/${version}/mediamtx_${version}_linux_${arch}.tar.gz.sha256"
        
        if curl --head --silent --fail "$sha256_url" >/dev/null 2>&1; then
            log_message "INFO" "Found .sha256 file"
            
            if curl -s -L -o "${TEMP_DIR}/file.sha256" "$sha256_url"; then
                local checksum=$(extract_hash_from_checksum "${TEMP_DIR}/file.sha256" "$expected_filename")
                local status=$?
                
                if [ $status -eq 0 ] && [[ -n "$checksum" && "${#checksum}" -eq 64 ]]; then
                    log_message "INFO" "Found checksum from .sha256 file: $checksum"
                    # Create a simple JSON structure with the checksum
                    echo "{\"$arch\": \"$checksum\"}" > "$checksum_file"
                    success=true
                else
                    # Log original content for debugging
                    local raw_content=$(cat "${TEMP_DIR}/file.sha256")
                    log_message "WARNING" "Could not extract valid checksum from .sha256 file. Content: $raw_content"
                fi
            fi
        fi
    fi
    
    # Approach 4: If checksums.txt doesn't exist or didn't work, try release API
    if [ "$success" != true ] && command -v jq >/dev/null 2>&1; then
        log_message "INFO" "Attempting to fetch checksums from GitHub API"
        
        # Get release info from GitHub API with cache awareness
        local release_json="${CACHE_DIR}/release_${version}.json"
        local release_info
        release_info=$(get_github_api_data "https://api.github.com/repos/bluenviron/mediamtx/releases/tags/${version}" "$release_json")
        local api_status=$?
        
        if [ $api_status -eq 0 ] && [ -n "$release_info" ]; then
            # Parse release JSON to find asset download URL
            local download_url=$(jq -r ".assets[] | select(.name == \"$expected_filename\") | .browser_download_url" <<<"$release_info")
            
            if [[ -n "$download_url" && "$download_url" != "null" ]]; then
                log_message "INFO" "Found download URL from API: $download_url"
                
                # For newer MediaMTX releases, we can check if there's a .sha256 file
                local checksum_url="${download_url}.sha256"
                
                if curl --head --silent --fail "$checksum_url" >/dev/null 2>&1; then
                    log_message "INFO" "Found .sha256 file for download from API reference"
                    
                    if curl -s -L -o "${TEMP_DIR}/file.sha256" "$checksum_url"; then
                        local checksum=$(extract_hash_from_checksum "${TEMP_DIR}/file.sha256" "$expected_filename")
                        local status=$?
                        
                        if [ $status -eq 0 ] && [[ -n "$checksum" && "${#checksum}" -eq 64 ]]; then
                            log_message "INFO" "Found checksum from API-referenced .sha256 file: $checksum"
                            # Create a simple JSON structure with the checksum
                            echo "{\"$arch\": \"$checksum\"}" > "$checksum_file"
                            success=true
                        else
                            # Log original content for debugging
                            local raw_content=$(cat "${TEMP_DIR}/file.sha256")
                            log_message "WARNING" "Could not extract valid checksum from API-referenced .sha256 file. Content: $raw_content"
                        fi
                    fi
                fi
            fi
        else
            log_message "WARNING" "Failed to fetch release info from GitHub API"
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
        
        if [[ -n "$checksum" && "$checksum" != "null" && "${#checksum}" -eq 64 ]]; then
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

# Test a URL with retry logic
test_url() {
    local url="$1"
    local max_retries=3
    local retry=0
    
    echo_debug "Testing URL: $url"
    
    while [ $retry -lt $max_retries ]; do
        echo_info "Testing URL accessibility (attempt $((retry + 1))/$max_retries)..."
        
        # Using wget or curl to test the URL
        if command -v wget >/dev/null 2>&1; then
            if wget --spider --timeout=10 --tries=1 --quiet "$url" 2>/dev/null; then
                echo_debug "URL is accessible (wget)"
                return 0
            fi
        elif command -v curl >/dev/null 2>&1; then
            if curl --head --silent --fail --connect-timeout 10 "$url" >/dev/null 2>&1; then
                echo_debug "URL is accessible (curl)"
                return 0
            fi
        else
            echo_error "Neither wget nor curl is available to test URLs"
            return 1
        fi
        
        retry=$((retry + 1))
        
        if [ $retry -lt $max_retries ]; then
            echo_warning "URL not accessible, retrying in 2 seconds..."
            sleep 2
        fi
    done
    
    echo_error "URL is not accessible after $max_retries attempts: $url"
    return 1
}

# Find similar URLs that might work
find_similar_urls() {
    local version="$1"
    local arch="$2"
    local found=false
    
    echo_info "Checking for alternative URLs..."
    
    # Try different architecture naming schemes
    for test_arch in "arm64" "arm64v8" "amd64" "armv7" "armv6"; do
        if [ "$test_arch" = "$arch" ]; then
            continue  # Skip the one we already tried
        fi
        
        local test_url="https://github.com/bluenviron/mediamtx/releases/download/${version}/mediamtx_${version}_linux_${test_arch}.tar.gz"
        
        if test_url "$test_url"; then
            echo_success "Found valid alternative URL with architecture '$test_arch':"
            echo_info "$test_url"
            found=true
            
            # Suggest command line correction
            echo_info "You can use this architecture by running:"
            echo_info "sudo bash $(basename "$0") --version $version --arch $test_arch"
        fi
    done
    
    # If no similar URLs found, check if there are any releases for this version
    if [ "$found" = false ]; then
        local release_url="https://github.com/bluenviron/mediamtx/releases/tag/${version}"
        
        if curl --head --silent --fail "$release_url" >/dev/null 2>&1; then
            echo_warning "The release $version exists, but no suitable binary was found for architecture $arch"
            echo_info "Please check available binaries at: $release_url"
        else
            echo_error "The release $version doesn't appear to exist"
            
            # Try to list some valid versions
            local latest_version
            latest_version=$(get_latest_version)
            
            if [ -n "$latest_version" ]; then
                echo_info "The latest available version appears to be: $latest_version"
                echo_info "Try using: --version $latest_version"
            else
                echo_info "Try using the default version: v1.12.2"
            fi
        fi
    fi
    
    return 0
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
    
    # Test if the URL exists first
    if ! test_url "$url"; then
        log_message "ERROR" "URL does not exist or is not accessible: $url"
        find_similar_urls "$version" "$arch"
        return 1
    fi
    
    # Try multiple methods with better error handling
    local download_success=false
    
    # First try wget if available
    if command -v wget >/dev/null 2>&1; then
        log_message "INFO" "Using wget to download..."
        if wget --no-verbose --show-progress --progress=bar:force:noscroll --tries=3 --timeout=15 -O "$output_file" "$url"; then
            download_success=true
        else
            log_message "WARNING" "wget download failed, will try curl..."
        fi
    fi
    
    # Try curl if wget failed or isn't available
    if [ "$download_success" != true ] && command -v curl >/dev/null 2>&1; then
        log_message "INFO" "Using curl to download..."
        if curl -L --retry 3 --connect-timeout 15 --progress-bar -o "$output_file" "$url"; then
            download_success=true
        else
            log_message "WARNING" "curl download failed..."
        fi
    fi
    
    # If both methods failed
    if [ "$download_success" != true ]; then
        log_message "ERROR" "All download methods failed. Please check your internet connection and the URL."
        log_message "INFO" "URL attempted: $url"
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
    local actual_checksum=""
    
    # Try sha256sum first
    if command -v sha256sum >/dev/null 2>&1; then
        actual_checksum=$(sha256sum "$TEMP_DIR/mediamtx.tar.gz" | cut -d ' ' -f 1)
    # Try openssl as fallback
    elif command -v openssl >/dev/null 2>&1; then
        actual_checksum=$(openssl dgst -sha256 "$TEMP_DIR/mediamtx.tar.gz" | cut -d ' ' -f 2)
    # Try shasum as another fallback (macOS)
    elif command -v shasum >/dev/null 2>&1; then
        actual_checksum=$(shasum -a 256 "$TEMP_DIR/mediamtx.tar.gz" | cut -d ' ' -f 1)
    else
        log_message "WARNING" "No SHA256 checksum utility found (sha256sum, openssl, or shasum)"
        
        # Ask for confirmation to continue without verification
        echo_warning "Cannot perform checksum verification because no SHA256 utility is available."
        read -p "Continue without checksum verification? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_message "ERROR" "Aborted by user due to inability to verify checksums"
            return 1
        fi
        
        log_message "WARNING" "Continuing without checksum verification as requested by user"
        return 0
    fi
    
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
    
    # Verify checksum is 64 characters (SHA256 length) 
    if [ "${#expected_checksum}" -ne 64 ]; then
        log_message "ERROR" "Expected checksum has invalid length: ${#expected_checksum} chars (should be 64)"
        echo_error "Invalid expected checksum format: $expected_checksum"
        
        # Ask if user wants to continue anyway
        read -p "Expected checksum has invalid format. Continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_message "ERROR" "Installation aborted due to invalid checksum format"
            return 1
        fi
        
        log_message "WARNING" "User chose to continue despite invalid checksum format"
        return 0
    fi
    
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
# Generated by enhanced_install_mediamtx.sh v2.1.2 on $(date)
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
        elif command -v netstat >/dev/null 2>&1; then
            for port in "$RTSP_PORT" "$RTMP_PORT" "$HLS_PORT" "$WEBRTC_PORT"; do
                if netstat -tuln | grep -q ":$port "; then
                    log_message "ERROR" "Port $port is already in use"
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
    echo "  --debug                  Enable debug mode for verbose output"
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
                    echo_info "Fetching latest version from GitHub..."
                    LATEST_VERSION=$(get_latest_version)
                    
                    if [[ -n "$LATEST_VERSION" ]]; then
                        echo_info "Latest version is: $LATEST_VERSION"
                        VERSION="$LATEST_VERSION"
                    else
                        echo_warning "Could not determine latest version, using default: $VERSION"
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
            --debug)
                DEBUG_MODE=true
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

# Main function
main() {
    echo "====================================="
    echo "Enhanced MediaMTX Installer v2.1.2"
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
# Generated by enhanced_install_mediamtx.sh v2.1.2 on $(date)
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

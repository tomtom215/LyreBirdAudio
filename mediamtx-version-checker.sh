#!/bin/bash
# MediaMTX Version Checker with Debug Mode
#
# https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/mediamtx-version-checker.sh
#
# Version: 1.2.1
# Date: 2025-05-10
# This script queries GitHub API to find available MediaMTX versions
# and validates download URLs for your specific architecture

# Define color codes for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Debug mode (set to true to enable debugging)
DEBUG_MODE=true

# Cache file for GitHub API responses
# For consistent behavior regardless of sudo usage, don't rely on $HOME
if [ "$EUID" -eq 0 ]; then
    # Running as root/sudo
    CACHE_DIR="/var/cache/mediamtx-checker"
else
    # Running as regular user
    CACHE_DIR="${HOME}/.cache/mediamtx-checker"
fi
API_CACHE="${CACHE_DIR}/api_cache.json"
CACHE_EXPIRY=3600  # Cache expires after 1 hour

echo -e "${BLUE}MediaMTX Version Checker v1.2.1${NC}"
echo -e "This utility helps verify correct download URLs and checksums for MediaMTX"

# Debug function - logs only when DEBUG_MODE is true
debug() {
    if [ "$DEBUG_MODE" = true ]; then
        echo -e "${CYAN}[DEBUG] $*${NC}" >&2
    fi
}

# Detect architecture with improved edge case handling
detect_arch() {
    local arch=$(uname -m)
    
    case "$arch" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7*|armhf)  echo "armv7" ;;
        armv6*|armel)  echo "armv6" ;;
        *)
            echo -e "${YELLOW}Architecture '$arch' not directly recognized.${NC}"
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
            echo "unknown"
            ;;
    esac
}

ARCH=$(detect_arch)
echo -e "Detected architecture: ${GREEN}$ARCH${NC}"
debug "Running as user: $(whoami), EUID: $EUID"
debug "Cache directory: $CACHE_DIR"

# Check required commands with more detailed messages
check_command() {
    local cmd="$1"
    local install_hint="$2"
    if ! command -v "$cmd" &> /dev/null; then
        echo -e "${YELLOW}Warning: '$cmd' is not installed.${NC}"
        if [ -n "$install_hint" ]; then
            echo -e "  ${CYAN}→ $install_hint${NC}"
        fi
        return 1
    fi
    return 0
}

CMD_STATUS=true

if ! check_command curl "Install with: sudo apt-get install curl"; then
    echo -e "${RED}Error: curl is required for this script to function properly.${NC}"
    CMD_STATUS=false
fi

if ! check_command jq "Install with: sudo apt-get install jq"; then
    echo -e "${YELLOW}Warning: jq is not installed. Output will be less readable.${NC}"
    HAS_JQ=false
else
    HAS_JQ=true
fi

# Check for optional xxd command used for debugging
HAS_XXD=false
if check_command xxd "Install with: sudo apt-get install xxd" || check_command xxd "Install with: sudo apt-get install vim-common"; then
    HAS_XXD=true
fi

# Create cache directory if it doesn't exist
mkdir -p "$CACHE_DIR" 2>/dev/null || {
    echo -e "${YELLOW}Warning: Could not create cache directory $CACHE_DIR${NC}"
    # Fall back to /tmp if we can't create the preferred directory
    CACHE_DIR="/tmp/mediamtx-checker-$$"
    API_CACHE="$CACHE_DIR/api_cache.json"
    mkdir -p "$CACHE_DIR" 2>/dev/null
    debug "Falling back to temporary cache directory: $CACHE_DIR"
}

# Function to check if cache is valid
is_cache_valid() {
    local cache_file="$1"
    local max_age="$2"
    
    if [ ! -f "$cache_file" ]; then
        debug "Cache file not found: $cache_file"
        return 1
    fi
    
    local file_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || date +%s) ))
    if [ "$file_age" -gt "$max_age" ]; then
        debug "Cache file expired (age: ${file_age}s, max: ${max_age}s)"
        return 1
    fi
    
    # Check if the file is not empty and is valid JSON
    if [ ! -s "$cache_file" ]; then
        debug "Cache file is empty"
        return 1
    fi
    
    if [ "$HAS_JQ" = true ]; then
        if ! jq empty "$cache_file" >/dev/null 2>&1; then
            debug "Cache file contains invalid JSON"
            return 1
        fi
    fi
    
    debug "Cache file is valid"
    return 0
}

# Function to get data with cache awareness - FIXED to properly handle output
get_github_api_data() {
    local url="$1"
    local cache_file="$2"
    local max_age="${3:-$CACHE_EXPIRY}"
    
    debug "Requesting data from: $url"
    debug "Using cache file: $cache_file"
    
    if is_cache_valid "$cache_file" "$max_age"; then
        echo -e "${BLUE}Using cached data ($(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || date +%s) ))s old)${NC}" >&2
        cat "$cache_file"
        return 0
    fi
    
    echo -e "${BLUE}Fetching data from GitHub API...${NC}" >&2
    
    # Make direct call to GitHub API and save the raw output for inspection
    local response_file="${CACHE_DIR}/raw_response.txt"
    local error_log="${CACHE_DIR}/curl_error.log"
    debug "Saving raw response to: $response_file"
    
    local curl_cmd="curl -s -S -f $url"
    debug "Running curl command: $curl_cmd"
    
    # Use curl to directly save to response file, capture errors separately
    eval "$curl_cmd" > "$response_file" 2>"$error_log"
    local curl_status=$?
    
    debug "Curl exit status: $curl_status"
    
    if [ $curl_status -ne 0 ]; then
        echo -e "${RED}Error: Failed to fetch data from $url (status: $curl_status)${NC}" >&2
        debug "Curl error log:"
        if [ -f "$error_log" ]; then
            cat "$error_log" >&2
        fi
        
        # Check specifically for rate limiting
        if [ $curl_status -eq 22 ] && curl -s -I "$url" | grep -q "X-RateLimit-Remaining: 0"; then
            echo -e "${RED}Error: GitHub API rate limit exceeded.${NC}" >&2
            local reset_time=$(curl -s -I "$url" | grep -i "X-RateLimit-Reset" | cut -d' ' -f2 | tr -d '\r')
            if [ -n "$reset_time" ]; then
                local reset_date=$(date -d "@$reset_time" 2>/dev/null || date)
                echo -e "${YELLOW}Rate limit will reset at: $reset_date${NC}" >&2
            fi
        fi
        
        # Try to use cached data even if expired
        if [ -f "$cache_file" ]; then
            echo -e "${YELLOW}Using expired cache data due to API error${NC}" >&2
            cat "$cache_file"
            return 0
        fi
        
        return 1
    fi
    
    # Debug the raw response
    if [ "$HAS_XXD" = true ] && [ "$DEBUG_MODE" = true ]; then
        debug "Response first 100 bytes: $(head -c 100 "$response_file" | xxd -p)"
    else
        debug "Response first 100 chars: $(head -c 100 "$response_file")"
    fi
    debug "Response length: $(wc -c < "$response_file") bytes"
    
    # Verify we have a proper JSON response
    if ! grep -q '^\s*{' "$response_file" && ! grep -q '^\s*\[' "$response_file"; then
        echo -e "${RED}Error: Response doesn't start with { or [ - likely not JSON${NC}" >&2
        debug "First 100 chars of response: $(head -c 100 "$response_file")"
        
        if [ -f "$cache_file" ]; then
            echo -e "${YELLOW}Using expired cache data due to invalid response${NC}" >&2
            cat "$cache_file"
            return 0
        fi
        
        echo -e "${RED}Failed to parse GitHub API response and no valid cache found.${NC}" >&2
        return 1
    fi
    
    # Test JSON validity with jq if available
    if [ "$HAS_JQ" = true ]; then
        local jq_test=$(jq empty "$response_file" 2>&1)
        if [ -n "$jq_test" ]; then
            echo -e "${RED}Error: Invalid JSON response from GitHub API${NC}" >&2
            debug "JQ error: $jq_test"
            debug "Raw response first 100 chars: $(head -c 100 "$response_file")"
            
            if [ -f "$cache_file" ]; then
                echo -e "${YELLOW}Using expired cache data due to invalid JSON${NC}" >&2
                cat "$cache_file"
                return 0
            fi
            
            return 1
        else
            debug "JSON validation passed"
        fi
    fi
    
    # Cache the response only if it's valid
    cp "$response_file" "$cache_file"
    cat "$response_file"
    return 0
}

# Get latest release info
echo -e "${BLUE}Checking latest MediaMTX release...${NC}"

# Default version in case API call fails
DEFAULT_VERSION="v1.12.2"
LATEST_INFO=""
LATEST_VERSION=""

if [ $CMD_STATUS = true ]; then
    LATEST_INFO=$(get_github_api_data "https://api.github.com/repos/bluenviron/mediamtx/releases/latest" "$API_CACHE")
    API_STATUS=$?
    
    debug "API call status: $API_STATUS"
    debug "Response available: $([[ -n "$LATEST_INFO" ]] && echo "yes" || echo "no")"
    
    # Debug the raw response data to diagnose JSON issues
    if [ -n "$LATEST_INFO" ] && [ "$DEBUG_MODE" = true ]; then
        debug "First 100 chars of response: $(echo "$LATEST_INFO" | head -c 100)"
        if [ "$HAS_JQ" = true ]; then
            JQ_VALIDATION=$(echo "$LATEST_INFO" | jq empty 2>&1 || echo "valid")
            debug "JQ validation result: $JQ_VALIDATION"
        fi
    fi
    
    if [ $API_STATUS -ne 0 ] || [ -z "$LATEST_INFO" ]; then
        echo -e "${RED}Failed to fetch release information from GitHub API.${NC}"
        echo -e "${YELLOW}Using default version: $DEFAULT_VERSION${NC}"
        LATEST_VERSION="$DEFAULT_VERSION"
    else
        if [ "$HAS_JQ" = true ]; then
            # Safely extract version using jq with fallback
            debug "Extracting version using jq"
            LATEST_VERSION=$(echo "$LATEST_INFO" | jq -r '.tag_name // ""' 2>/dev/null)
            debug "JQ extracted version: '$LATEST_VERSION'"
            
            if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" = "null" ]; then
                echo -e "${RED}Failed to extract version from GitHub API response.${NC}"
                echo -e "${YELLOW}Using default version: $DEFAULT_VERSION${NC}"
                LATEST_VERSION="$DEFAULT_VERSION"
            else
                echo -e "Latest version: ${GREEN}$LATEST_VERSION${NC}"
                
                # Get available assets
                echo -e "${BLUE}Available download files for $LATEST_VERSION:${NC}"
                echo -e "${CYAN}---------------------------------------------------------------${NC}"
                ASSETS=$(echo "$LATEST_INFO" | jq -r '.assets[] | select(.name | contains("linux")) | "  " + .name + "\t(" + (.size|tostring) + " bytes)"' 2>/dev/null)
                if [ -n "$ASSETS" ]; then
                    if command -v column >/dev/null 2>&1; then
                        echo "$ASSETS" | column -t -s $'\t'
                    else
                        echo "$ASSETS" | tr '\t' '  '
                    fi
                else
                    echo -e "${YELLOW}  No assets found or error parsing asset list${NC}"
                    debug "JQ assets extraction error or no assets: $(echo "$LATEST_INFO" | jq -r '.assets[]' 2>&1 || echo "No assets or error")"
                fi
                echo -e "${CYAN}---------------------------------------------------------------${NC}"
            fi
        else
            # Fallback without jq - with more robust error checking
            debug "Extracting version using grep/sed"
            if echo "$LATEST_INFO" | grep -q "tag_name"; then
                LATEST_VERSION=$(echo "$LATEST_INFO" | grep "tag_name" | head -1 | cut -d : -f 2,3 | tr -d \" | tr -d , | xargs)
                debug "Grep extracted version: '$LATEST_VERSION'"
                
                if [ -z "$LATEST_VERSION" ]; then
                    echo -e "${RED}Failed to extract version using grep fallback.${NC}"
                    echo -e "${YELLOW}Using default version: $DEFAULT_VERSION${NC}"
                    LATEST_VERSION="$DEFAULT_VERSION"
                else
                    echo -e "Latest version: ${GREEN}$LATEST_VERSION${NC}"
                    
                    # Get available assets without jq (basic grep)
                    echo -e "${BLUE}Available download files (partial list):${NC}"
                    echo -e "${CYAN}---------------------------------------------------------------${NC}"
                    ASSETS=$(echo "$LATEST_INFO" | grep "browser_download_url.*linux" | cut -d : -f 2,3 | tr -d \" | xargs | tr ' ' '\n')
                    if [ -n "$ASSETS" ]; then
                        echo "$ASSETS" | while read -r url; do
                            filename=$(basename "$url")
                            echo "  $filename"
                        done
                    else
                        echo -e "${YELLOW}  No assets found or error parsing asset list${NC}"
                    fi
                    echo -e "${CYAN}---------------------------------------------------------------${NC}"
                fi
            else
                echo -e "${RED}GitHub API response doesn't contain version information.${NC}"
                echo -e "${YELLOW}Using default version: $DEFAULT_VERSION${NC}"
                LATEST_VERSION="$DEFAULT_VERSION"
            fi
        fi
    fi
else
    echo -e "${RED}Skipping GitHub API check due to missing required commands.${NC}"
    echo -e "${YELLOW}Using default version: $DEFAULT_VERSION${NC}"
    LATEST_VERSION="$DEFAULT_VERSION"
fi

# Check specific version if provided
if [ -n "$1" ]; then
    VERSION=$1
    echo -e "${BLUE}Checking specific version: $VERSION${NC}"
else
    # Ensure we have a valid version before continuing
    if [ -z "$LATEST_VERSION" ]; then
        VERSION="$DEFAULT_VERSION"
        echo -e "${YELLOW}No version available, falling back to default: $VERSION${NC}"
    else
        VERSION=$LATEST_VERSION
        echo -e "${BLUE}Using latest version: $VERSION${NC}"
    fi
fi

# Validate version format
if ! [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${YELLOW}Warning: Version format '$VERSION' doesn't match expected pattern (vX.Y.Z)${NC}"
    echo -e "${YELLOW}This may cause download issues if the version is incorrect${NC}"
fi

# Construct URL for this architecture
URL="https://github.com/bluenviron/mediamtx/releases/download/${VERSION}/mediamtx_${VERSION}_linux_${ARCH}.tar.gz"
echo -e "${BLUE}Testing URL for your architecture:${NC}"
echo -e "${GREEN}$URL${NC}"

# Function to test URL with retries
test_url() {
    local url="$1"
    local retries=3
    local attempt=1
    local success=false
    
    while [ $attempt -le $retries ] && [ "$success" = false ]; do
        echo -e "${BLUE}Connection attempt $attempt/$retries...${NC}"
        
        if curl --head --silent --fail --connect-timeout 10 "$url" >/dev/null 2>&1; then
            success=true
        else
            attempt=$((attempt + 1))
            if [ $attempt -le $retries ]; then
                echo -e "${YELLOW}Connection failed. Retrying in 2 seconds...${NC}"
                sleep 2
            fi
        fi
    done
    
    if [ "$success" = true ]; then
        return 0
    else
        return 1
    fi
}

# Test if URL exists
if test_url "$URL"; then
    echo -e "${GREEN}✓ URL is valid and accessible!${NC}"
    
    # Check if download should proceed
    if [ -t 0 ]; then  # Only ask if script is run interactively
        echo -ne "${YELLOW}Download file to calculate checksum? [Y/n] ${NC}"
        read -r response
        if [[ "$response" =~ ^[Nn]$ ]]; then
            echo -e "${BLUE}Skipping download as requested.${NC}"
            debug "Debug files available at: $CACHE_DIR"
            exit 0
        fi
    fi
    
    # Calculate checksum if the file is small enough
    echo -e "${BLUE}Downloading file to calculate checksum...${NC}"
    TEMP_FILE="/tmp/mediamtx_${VERSION}_test.tar.gz"
    
    if curl -s -L --progress-bar -o "$TEMP_FILE" "$URL"; then
        echo -e "${GREEN}Download successful${NC}"
        
        # Calculate checksums
        echo -e "${BLUE}File checksums:${NC}"
        echo -e "${CYAN}---------------------------------------------------------------${NC}"
        echo -e "  SHA256: ${GREEN}$(sha256sum "$TEMP_FILE" | cut -d ' ' -f 1)${NC}"
        echo -e "  MD5:    ${GREEN}$(md5sum "$TEMP_FILE" | cut -d ' ' -f 1)${NC}"
        echo -e "  Size:   $(du -h "$TEMP_FILE" | cut -f1)"
        echo -e "${CYAN}---------------------------------------------------------------${NC}"
        
        # Check if checksum info is available from GitHub
        echo -e "${BLUE}Checking for official checksums...${NC}"
        
        # First try individual arch-specific checksum file (new format)
        INDIVIDUAL_CHECKSUM_URL="https://github.com/bluenviron/mediamtx/releases/download/${VERSION}/mediamtx_${VERSION}_linux_${ARCH}.tar.gz.sha256sum"
        
        # Then try consolidated checksums file (old format)
        CONSOLIDATED_CHECKSUM_URL="https://github.com/bluenviron/mediamtx/releases/download/${VERSION}/checksums.txt"
        
        OFFICIAL_CHECKSUM=""
        
        # Try individual checksum file first
        if curl --head --silent --fail "$INDIVIDUAL_CHECKSUM_URL" >/dev/null 2>&1; then
            debug "Found individual checksum file: $INDIVIDUAL_CHECKSUM_URL"
            CHECKSUM_DATA=$(curl -s -L "$INDIVIDUAL_CHECKSUM_URL")
            # Extract just the hash (first field)
            OFFICIAL_CHECKSUM=$(echo "$CHECKSUM_DATA" | awk '{print $1}')
            
            if [ -z "$OFFICIAL_CHECKSUM" ]; then
                # Some .sha256sum files might contain the full line with filename
                OFFICIAL_CHECKSUM=$(echo "$CHECKSUM_DATA" | grep -o '^[a-f0-9]\{64\}')
            fi
        
        # Fall back to consolidated checksums file
        elif curl --head --silent --fail "$CONSOLIDATED_CHECKSUM_URL" >/dev/null 2>&1; then
            debug "Found consolidated checksum file: $CONSOLIDATED_CHECKSUM_URL"
            CHECKSUM_DATA=$(curl -s -L "$CONSOLIDATED_CHECKSUM_URL")
            OFFICIAL_CHECKSUM=$(echo "$CHECKSUM_DATA" | grep "mediamtx_${VERSION}_linux_${ARCH}.tar.gz" | awk '{print $1}')
        fi
        
        # If we have a checksum, verify it
        if [ -n "$OFFICIAL_CHECKSUM" ]; then
            LOCAL_CHECKSUM=$(sha256sum "$TEMP_FILE" | cut -d ' ' -f 1)
            echo -e "${BLUE}Official SHA256: ${GREEN}$OFFICIAL_CHECKSUM${NC}"
            
            if [ "$LOCAL_CHECKSUM" = "$OFFICIAL_CHECKSUM" ]; then
                echo -e "${GREEN}✓ Checksum verification PASSED!${NC}"
            else
                echo -e "${RED}✗ Checksum verification FAILED!${NC}"
                echo -e "${RED}  Expected: $OFFICIAL_CHECKSUM${NC}"
                echo -e "${RED}  Got:      $LOCAL_CHECKSUM${NC}"
                echo -e "${YELLOW}  This could indicate the file was corrupted during download.${NC}"
            fi
        else
            echo -e "${YELLOW}No official checksum found for your architecture.${NC}"
        fi
        
        # Offer to keep or delete the file
        if [ -t 0 ]; then  # Only ask if script is run interactively
            echo -ne "${YELLOW}Keep downloaded file? [y/N] ${NC}"
            read -r response
            if [[ "$response" =~ ^[Yy]$ ]]; then
                SAVE_PATH="$PWD/mediamtx_${VERSION}_linux_${ARCH}.tar.gz"
                cp "$TEMP_FILE" "$SAVE_PATH"
                echo -e "${GREEN}File saved to: $SAVE_PATH${NC}"
            else
                echo -e "${BLUE}Cleaning up temporary file.${NC}"
            fi
        fi
        
        # Cleanup
        rm -f "$TEMP_FILE"
    else
        echo -e "${RED}Download failed${NC}"
    fi
else
    echo -e "${RED}URL is not accessible!${NC}"
    echo -e "${YELLOW}Checking for similar URLs...${NC}"
    echo -e "${CYAN}---------------------------------------------------------------${NC}"
    
    # Try different architecture naming schemes
    for test_arch in "arm64" "arm64v8" "amd64" "armv7" "armv6"; do
        TEST_URL="https://github.com/bluenviron/mediamtx/releases/download/${VERSION}/mediamtx_${VERSION}_linux_${test_arch}.tar.gz"
        if curl --head --silent --fail "$TEST_URL" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓ Found valid URL with architecture '${test_arch}':${NC}"
            echo -e "  ${GREEN}$TEST_URL${NC}"
        fi
    done
    echo -e "${CYAN}---------------------------------------------------------------${NC}"
fi

echo -e "${BLUE}Use these findings to update your installation script${NC}"

# Print system information that might be helpful for debugging
echo -e "\n${BLUE}System Information:${NC}"
echo -e "${CYAN}---------------------------------------------------------------${NC}"
echo -e "  OS:          $(uname -s) $(uname -r)"
echo -e "  Distribution: $(cat /etc/*release 2>/dev/null | grep "PRETTY_NAME" | cut -d= -f2 | tr -d '"' || echo "Unknown")"
echo -e "  Architecture: $(uname -m)"
echo -e "  MediaMTX Arch: $ARCH"
echo -e "${CYAN}---------------------------------------------------------------${NC}"

echo -e "\n${BLUE}Debug Information:${NC}"
echo -e "${CYAN}---------------------------------------------------------------${NC}"
echo -e "  Debug files location: $CACHE_DIR"
echo -e "  Commands to examine debug files:"
echo -e "    cat $CACHE_DIR/raw_response.txt    # Raw API response"
echo -e "    cat $CACHE_DIR/curl_error.log      # Curl error output"
echo -e "    cat $CACHE_DIR/api_cache.json      # Cached API response"
echo -e "${CYAN}---------------------------------------------------------------${NC}"

# Cache management options
if [ -d "$CACHE_DIR" ] && [ -t 0 ]; then  # Only ask if script is run interactively
    echo -e "\n${BLUE}Cache Information:${NC}"
    CACHE_SIZE=$(du -sh "$CACHE_DIR" 2>/dev/null | cut -f1)
    echo -e "  Cache location: $CACHE_DIR"
    echo -e "  Cache size:     $CACHE_SIZE"
    
    echo -ne "${YELLOW}Clear cache data? [y/N] ${NC}"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        rm -rf "${CACHE_DIR:?}"/*
        echo -e "${GREEN}Cache cleared.${NC}"
    fi
fi

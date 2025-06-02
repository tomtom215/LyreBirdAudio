#!/usr/bin/env bash
#
# MediaMTX Installation Manager - Install/Update/Uninstall MediaMTX
# A production-ready utility for managing MediaMTX installations
# Version: 4.1.0
#
# Usage: ./mediamtx-manager.sh [install|update|uninstall|status|help]
#
# Requirements:
# - curl or wget
# - tar
# - sha256sum (or shasum for macOS)
# - systemctl (optional, for systemd service management)

set -euo pipefail

# Constants
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly GITHUB_API_URL="https://api.github.com/repos/bluenviron/mediamtx/releases/latest"
readonly INSTALL_DIR="/usr/local/bin"
readonly CONFIG_DIR="/etc/mediamtx"
readonly SERVICE_DIR="/etc/systemd/system"
readonly SERVICE_NAME="mediamtx.service"
readonly DEFAULT_CONFIG_NAME="mediamtx.yml"
readonly TEMP_DIR="/tmp/mediamtx-installer-$$"
readonly LOG_FILE="/tmp/mediamtx-installer-$$.log"
readonly USER_AGENT="MediaMTX-Manager/1.0"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Trap to ensure cleanup on exit
trap cleanup EXIT INT TERM

# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}" 2>/dev/null || true
    fi
    if [[ -f "${LOG_FILE}" ]] && [[ ${exit_code} -eq 0 ]]; then
        rm -f "${LOG_FILE}" 2>/dev/null || true
    elif [[ -f "${LOG_FILE}" ]] && [[ ${exit_code} -ne 0 ]]; then
        echo -e "${YELLOW}Debug log saved at: ${LOG_FILE}${NC}" >&2
    fi
    return ${exit_code}
}

# Logging functions
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}"
    
    case "${level}" in
        ERROR)
            echo -e "${RED}[ERROR]${NC} ${message}" >&2
            ;;
        WARN)
            echo -e "${YELLOW}[WARN]${NC} ${message}" >&2
            ;;
        INFO)
            echo -e "${GREEN}[INFO]${NC} ${message}"
            ;;
        DEBUG)
            # Only log to file, not stdout
            ;;
        *)
            echo "${message}"
            ;;
    esac
}

# Error handling
error_exit() {
    log ERROR "$1"
    exit "${2:-1}"
}

# Check if running as root
check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        error_exit "This script must be run as root (use sudo)" 2
    fi
}

# Detect operating system
detect_os() {
    local os=""
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        os="linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        os="darwin"
    else
        error_exit "Unsupported operating system: $OSTYPE" 3
    fi
    echo "${os}"
}

# Detect architecture
detect_arch() {
    local arch=""
    local machine
    machine="$(uname -m)"
    
    case "${machine}" in
        x86_64|amd64)
            arch="amd64"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        armv6*|armv7*)
            arch="armv6"
            ;;
        *)
            error_exit "Unsupported architecture: ${machine}" 4
            ;;
    esac
    echo "${arch}"
}

# Check for required commands
check_requirements() {
    local missing_tools=()
    
    # Check for download tool
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        missing_tools+=("curl or wget")
    fi
    
    # Check for tar
    if ! command -v tar &>/dev/null; then
        missing_tools+=("tar")
    fi
    
    # Check for checksum tool
    if [[ "$(detect_os)" == "linux" ]]; then
        if ! command -v sha256sum &>/dev/null; then
            missing_tools+=("sha256sum")
        fi
    elif [[ "$(detect_os)" == "darwin" ]]; then
        if ! command -v shasum &>/dev/null; then
            missing_tools+=("shasum")
        fi
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        error_exit "Missing required tools: ${missing_tools[*]}" 5
    fi
}

# Download file with fallback
download_file() {
    local url="$1"
    local output="$2"
    local max_retries=3
    local retry_count=0
    
    while [[ ${retry_count} -lt ${max_retries} ]]; do
        log DEBUG "Attempting download (try $((retry_count + 1))/${max_retries}): ${url}"
        
        if command -v curl &>/dev/null; then
            log DEBUG "Using curl with User-Agent: ${USER_AGENT}"
            if curl -fsSL \
                --connect-timeout 30 \
                --max-time 300 \
                --retry 2 \
                --retry-delay 2 \
                -H "User-Agent: ${USER_AGENT}" \
                -o "${output}" \
                "${url}" 2>>"${LOG_FILE}"; then
                log DEBUG "Download successful with curl"
                return 0
            else
                log DEBUG "curl failed with exit code: $?"
            fi
        elif command -v wget &>/dev/null; then
            log DEBUG "Using wget with User-Agent: ${USER_AGENT}"
            if wget -q \
                --timeout=30 \
                --tries=2 \
                --wait=2 \
                --user-agent="${USER_AGENT}" \
                -O "${output}" \
                "${url}" 2>>"${LOG_FILE}"; then
                log DEBUG "Download successful with wget"
                return 0
            else
                log DEBUG "wget failed with exit code: $?"
            fi
        fi
        
        retry_count=$((retry_count + 1))
        if [[ ${retry_count} -lt ${max_retries} ]]; then
            log WARN "Download failed, retrying in 5 seconds..."
            sleep 5
        fi
    done
    
    log ERROR "All download attempts failed for: ${url}"
    return 1
}

# Verify checksum
verify_checksum() {
    local file="$1"
    local checksum_file="$2"
    local os
    os="$(detect_os)"
    
    if [[ ! -f "${checksum_file}" ]]; then
        log WARN "Checksum file not found, skipping verification"
        return 0
    fi
    
    local expected_checksum
    expected_checksum="$(awk '{print $1}' "${checksum_file}")"
    
    local actual_checksum
    if [[ "${os}" == "linux" ]]; then
        actual_checksum="$(sha256sum "${file}" | awk '{print $1}')"
    elif [[ "${os}" == "darwin" ]]; then
        actual_checksum="$(shasum -a 256 "${file}" | awk '{print $1}')"
    fi
    
    if [[ "${expected_checksum}" != "${actual_checksum}" ]]; then
        error_exit "Checksum verification failed for ${file}" 6
    fi
    
    log INFO "Checksum verification passed"
    return 0
}

# Parse JSON without jq (basic but more robust)
parse_json_value() {
    local json="$1"
    local key="$2"
    
    # More robust JSON parsing that handles different formatting
    local value
    value=$(echo "${json}" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1)
    
    if [[ -z "${value}" ]]; then
        # Try alternative parsing method
        value=$(echo "${json}" | grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed 's/.*:\s*"\([^"]*\)".*/\1/' | head -1)
    fi
    
    echo "${value}"
}

# Get latest release info
get_latest_release() {
    local release_info="${TEMP_DIR}/release_info.json"
    
    log INFO "Fetching latest release information..."
    
    if ! download_file "${GITHUB_API_URL}" "${release_info}"; then
        error_exit "Failed to fetch release information from GitHub API" 7
    fi
    
    # Debug: Log first 500 chars of API response
    log DEBUG "API Response preview: $(head -c 500 "${release_info}" 2>/dev/null || echo "empty")"
    
    # Parse JSON for tag_name
    local version
    version="$(parse_json_value "$(cat "${release_info}")" "tag_name")"
    
    if [[ -z "${version}" ]]; then
        log ERROR "Failed to extract version from API response"
        log DEBUG "Full API response saved in: ${release_info}"
        error_exit "Failed to parse release version from GitHub API" 8
    fi
    
    log DEBUG "Extracted version: ${version}"
    echo "${version}"
}

# Get download URL for specific platform with version-aware naming
get_download_url() {
    local version="$1"
    local os="$2"
    local arch="$3"
    
    # Remove 'v' prefix if present
    local version_clean="${version#v}"
    
    # Handle ARM64 naming convention change at v1.12.1
    local arch_suffix="${arch}"
    if [[ "${arch}" == "arm64" ]] && [[ "${os}" == "linux" ]]; then
        # Compare versions - if older than 1.12.1, use arm64v8
        local major minor patch
        IFS='.' read -r major minor patch <<< "${version_clean}"
        
        # Convert to comparable number (1.12.0 = 11200, 1.12.1 = 11201)
        local version_num=$((major * 10000 + minor * 100 + patch))
        local cutoff_num=11201  # 1.12.1
        
        if [[ ${version_num} -lt ${cutoff_num} ]]; then
            arch_suffix="arm64v8"
            log DEBUG "Using legacy ARM64 naming (arm64v8) for version ${version}"
        fi
    fi
    
    local filename="mediamtx_v${version_clean}_${os}_${arch_suffix}.tar.gz"
    local url="https://github.com/bluenviron/mediamtx/releases/download/v${version_clean}/${filename}"
    
    log DEBUG "Constructed download URL: ${url}"
    echo "${url}"
}

# Try to find correct download URL from release assets
find_download_url_from_assets() {
    local version="$1"
    local os="$2"
    local arch="$3"
    local release_info="${TEMP_DIR}/release_info.json"
    
    log DEBUG "Searching for ${os}/${arch} asset in release ${version}"
    
    # Try to extract assets array and find matching URL
    local asset_url
    
    # Look for patterns like linux_arm64 or linux_arm64v8
    if [[ "${arch}" == "arm64" ]] && [[ "${os}" == "linux" ]]; then
        # Try both arm64 and arm64v8 patterns
        for pattern in "${os}_${arch}" "${os}_${arch}v8"; do
            asset_url=$(grep -o "\"browser_download_url\"[[:space:]]*:[[:space:]]*\"[^\"]*${pattern}[^\"]*\.tar\.gz\"" "${release_info}" 2>/dev/null | \
                        sed 's/.*"\(https[^"]*\)".*/\1/' | head -1)
            if [[ -n "${asset_url}" ]]; then
                log DEBUG "Found asset URL with pattern '${pattern}': ${asset_url}"
                echo "${asset_url}"
                return 0
            fi
        done
    else
        # Standard pattern search
        asset_url=$(grep -o "\"browser_download_url\"[[:space:]]*:[[:space:]]*\"[^\"]*${os}_${arch}[^\"]*\.tar\.gz\"" "${release_info}" 2>/dev/null | \
                    sed 's/.*"\(https[^"]*\)".*/\1/' | head -1)
        if [[ -n "${asset_url}" ]]; then
            log DEBUG "Found asset URL: ${asset_url}"
            echo "${asset_url}"
            return 0
        fi
    fi
    
    log WARN "Could not find ${os}/${arch} asset in API response"
    return 1
}

# Create minimal configuration
create_minimal_config() {
    cat > "${CONFIG_DIR}/${DEFAULT_CONFIG_NAME}" << 'EOF'
# mediamtx.yml - Minimal guaranteed-working configuration
###############################################
# Global settings
logLevel: info
logDestinations: [stdout]
# Essential timeouts
readTimeout: 10s
writeTimeout: 10s
# writeQueueSize replaces deprecated readBufferCount
writeQueueSize: 512
###############################################
# RTSP server (primary protocol)
rtsp: yes
rtspAddress: :18554
rtspEncryption: "no"
rtspTransports: [tcp]
rtspAuthMethods: [basic]
###############################################
# API (for monitoring and control)
api: yes
apiAddress: :9997
###############################################
# Path configuration
pathDefaults:
  # Minimal defaults to prevent errors
  source: publisher
  sourceOnDemand: no
  sourceOnDemandStartTimeout: 10s
  sourceOnDemandCloseAfter: 10s
  record: false
# Empty paths allowed - will accept any stream name
paths: {}
EOF
}

# Create systemd service
create_systemd_service() {
    if ! command -v systemctl &>/dev/null; then
        log WARN "systemd not available, skipping service creation"
        return 0
    fi
    
    cat > "${SERVICE_DIR}/${SERVICE_NAME}" << EOF
[Unit]
Description=MediaMTX Media Server
After=network.target

[Service]
Type=simple
User=mediamtx
Group=mediamtx
ExecStart=${INSTALL_DIR}/mediamtx ${CONFIG_DIR}/${DEFAULT_CONFIG_NAME}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mediamtx

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload || true
}

# Create service user
create_service_user() {
    if id "mediamtx" &>/dev/null; then
        log DEBUG "User 'mediamtx' already exists"
    else
        log INFO "Creating service user 'mediamtx'..."
        if command -v useradd &>/dev/null; then
            useradd --system --no-create-home --shell /bin/false mediamtx || true
        elif command -v adduser &>/dev/null; then
            adduser --system --no-create-home --shell /bin/false mediamtx || true
        else
            log WARN "Cannot create service user, running as root"
        fi
    fi
}

# Install MediaMTX
install_mediamtx() {
    log INFO "Starting MediaMTX installation..."
    
    # Check if already installed
    if [[ -f "${INSTALL_DIR}/mediamtx" ]]; then
        log WARN "MediaMTX is already installed. Use 'update' to upgrade or 'uninstall' first."
        return 1
    fi
    
    # Create temp directory
    mkdir -p "${TEMP_DIR}"
    
    # Get system info
    local os
    os="$(detect_os)"
    local arch
    arch="$(detect_arch)"
    local version
    version="$(get_latest_release)"
    
    log INFO "Installing MediaMTX ${version} for ${os}/${arch}..."
    
    # Try to get download URL from API assets first
    local download_url
    if download_url="$(find_download_url_from_assets "${version}" "${os}" "${arch}")"; then
        log DEBUG "Using asset URL from API"
    else
        # Fall back to constructed URL
        download_url="$(get_download_url "${version}" "${os}" "${arch}")"
        log DEBUG "Using constructed URL"
    fi
    
    local checksum_url="${download_url}.sha256sum"
    
    # Download files
    local archive="${TEMP_DIR}/mediamtx.tar.gz"
    local checksum="${TEMP_DIR}/mediamtx.tar.gz.sha256sum"
    
    log INFO "Downloading MediaMTX..."
    log INFO "URL: ${download_url}"
    
    if ! download_file "${download_url}" "${archive}"; then
        # If first method fails, try alternate naming for ARM64
        if [[ "${arch}" == "arm64" ]] && [[ "${os}" == "linux" ]]; then
            log WARN "Download failed, trying alternate ARM64 naming..."
            # Try the opposite naming convention
            local alt_version_clean="${version#v}"
            local alt_arch="arm64v8"
            if [[ "${download_url}" == *"arm64v8"* ]]; then
                alt_arch="arm64"
            fi
            local alt_url="https://github.com/bluenviron/mediamtx/releases/download/v${alt_version_clean}/mediamtx_v${alt_version_clean}_${os}_${alt_arch}.tar.gz"
            log DEBUG "Trying alternate URL: ${alt_url}"
            if ! download_file "${alt_url}" "${archive}"; then
                error_exit "Failed to download MediaMTX after trying multiple URLs" 9
            else
                download_url="${alt_url}"
                checksum_url="${alt_url}.sha256sum"
            fi
        else
            error_exit "Failed to download MediaMTX" 9
        fi
    fi
    
    log INFO "Downloading checksum..."
    if download_file "${checksum_url}" "${checksum}"; then
        verify_checksum "${archive}" "${checksum}"
    fi
    
    # Extract archive
    log INFO "Extracting archive..."
    if ! tar -xzf "${archive}" -C "${TEMP_DIR}"; then
        error_exit "Failed to extract archive" 10
    fi
    
    # Install binary
    log INFO "Installing binary to ${INSTALL_DIR}..."
    if ! install -m 755 "${TEMP_DIR}/mediamtx" "${INSTALL_DIR}/"; then
        error_exit "Failed to install binary" 11
    fi
    
    # Create config directory
    mkdir -p "${CONFIG_DIR}"
    
    # Create default config if not exists
    if [[ ! -f "${CONFIG_DIR}/${DEFAULT_CONFIG_NAME}" ]]; then
        log INFO "Creating default configuration..."
        create_minimal_config
    fi
    
    # Create service user
    create_service_user
    
    # Create systemd service
    if command -v systemctl &>/dev/null; then
        log INFO "Creating systemd service..."
        create_systemd_service
    fi
    
    # Set permissions
    chown -R mediamtx:mediamtx "${CONFIG_DIR}" 2>/dev/null || true
    
    log INFO "MediaMTX ${version} installed successfully!"
    log INFO ""
    log INFO "Configuration file: ${CONFIG_DIR}/${DEFAULT_CONFIG_NAME}"
    log INFO "Binary location: ${INSTALL_DIR}/mediamtx"
    
    if command -v systemctl &>/dev/null; then
        log INFO ""
        log INFO "To start MediaMTX:"
        log INFO "  sudo systemctl start mediamtx"
        log INFO "  sudo systemctl enable mediamtx  # To start at boot"
    else
        log INFO ""
        log INFO "To start MediaMTX manually:"
        log INFO "  ${INSTALL_DIR}/mediamtx ${CONFIG_DIR}/${DEFAULT_CONFIG_NAME}"
    fi
}

# Update MediaMTX
update_mediamtx() {
    log INFO "Starting MediaMTX update..."
    
    # Check if installed
    if [[ ! -f "${INSTALL_DIR}/mediamtx" ]]; then
        error_exit "MediaMTX is not installed. Use 'install' first." 12
    fi
    
    # Get current version
    local current_version="unknown"
    if "${INSTALL_DIR}/mediamtx" --version &>/dev/null; then
        current_version="$("${INSTALL_DIR}/mediamtx" --version 2>&1 | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "unknown")"
    fi
    
    # Create temp directory
    mkdir -p "${TEMP_DIR}"
    
    # Get system info
    local os
    os="$(detect_os)"
    local arch
    arch="$(detect_arch)"
    local version
    version="$(get_latest_release)"
    
    if [[ "${current_version}" == "${version}" ]]; then
        log INFO "MediaMTX is already at the latest version (${version})"
        return 0
    fi
    
    log INFO "Updating MediaMTX from ${current_version} to ${version}..."
    
    # Stop service if running
    if command -v systemctl &>/dev/null && systemctl is-active --quiet mediamtx; then
        log INFO "Stopping MediaMTX service..."
        systemctl stop mediamtx
    fi
    
    # Backup current binary
    local backup_file="${INSTALL_DIR}/mediamtx.backup-$(date +%Y%m%d-%H%M%S)"
    cp "${INSTALL_DIR}/mediamtx" "${backup_file}"
    log INFO "Current binary backed up to ${backup_file}"
    
    # Try to get download URL from API assets first
    local download_url
    if download_url="$(find_download_url_from_assets "${version}" "${os}" "${arch}")"; then
        log DEBUG "Using asset URL from API"
    else
        # Fall back to constructed URL
        download_url="$(get_download_url "${version}" "${os}" "${arch}")"
        log DEBUG "Using constructed URL"
    fi
    
    local checksum_url="${download_url}.sha256sum"
    
    # Download files
    local archive="${TEMP_DIR}/mediamtx.tar.gz"
    local checksum="${TEMP_DIR}/mediamtx.tar.gz.sha256sum"
    
    log INFO "Downloading MediaMTX..."
    log INFO "URL: ${download_url}"
    
    if ! download_file "${download_url}" "${archive}"; then
        # If first method fails, try alternate naming for ARM64
        if [[ "${arch}" == "arm64" ]] && [[ "${os}" == "linux" ]]; then
            log WARN "Download failed, trying alternate ARM64 naming..."
            # Try the opposite naming convention
            local alt_version_clean="${version#v}"
            local alt_arch="arm64v8"
            if [[ "${download_url}" == *"arm64v8"* ]]; then
                alt_arch="arm64"
            fi
            local alt_url="https://github.com/bluenviron/mediamtx/releases/download/v${alt_version_clean}/mediamtx_v${alt_version_clean}_${os}_${alt_arch}.tar.gz"
            log DEBUG "Trying alternate URL: ${alt_url}"
            if ! download_file "${alt_url}" "${archive}"; then
                error_exit "Failed to download MediaMTX after trying multiple URLs" 13
            else
                download_url="${alt_url}"
                checksum_url="${alt_url}.sha256sum"
            fi
        else
            error_exit "Failed to download MediaMTX" 13
        fi
    fi
    
    log INFO "Downloading checksum..."
    if download_file "${checksum_url}" "${checksum}"; then
        verify_checksum "${archive}" "${checksum}"
    fi
    
    # Extract archive
    log INFO "Extracting archive..."
    if ! tar -xzf "${archive}" -C "${TEMP_DIR}"; then
        error_exit "Failed to extract archive" 14
    fi
    
    # Install new binary
    log INFO "Installing new binary..."
    if ! install -m 755 "${TEMP_DIR}/mediamtx" "${INSTALL_DIR}/"; then
        # Restore backup on failure
        mv "${backup_file}" "${INSTALL_DIR}/mediamtx"
        error_exit "Failed to install new binary, restored backup" 15
    fi
    
    # Start service if it was running
    if command -v systemctl &>/dev/null && [[ -f "${SERVICE_DIR}/${SERVICE_NAME}" ]]; then
        log INFO "Starting MediaMTX service..."
        systemctl start mediamtx
    fi
    
    log INFO "MediaMTX updated successfully to ${version}!"
}

# Uninstall MediaMTX
uninstall_mediamtx() {
    log INFO "Starting MediaMTX uninstallation..."
    
    # Check if installed
    if [[ ! -f "${INSTALL_DIR}/mediamtx" ]]; then
        log WARN "MediaMTX is not installed"
        return 0
    fi
    
    # Stop and disable service
    if command -v systemctl &>/dev/null && [[ -f "${SERVICE_DIR}/${SERVICE_NAME}" ]]; then
        log INFO "Stopping and disabling MediaMTX service..."
        systemctl stop mediamtx 2>/dev/null || true
        systemctl disable mediamtx 2>/dev/null || true
        rm -f "${SERVICE_DIR}/${SERVICE_NAME}"
        systemctl daemon-reload || true
    fi
    
    # Remove binary
    log INFO "Removing MediaMTX binary..."
    rm -f "${INSTALL_DIR}/mediamtx"
    
    # Remove backups
    rm -f "${INSTALL_DIR}"/mediamtx.backup-* 2>/dev/null || true
    
    # Ask about config removal
    if [[ -d "${CONFIG_DIR}" ]]; then
        echo -e "${YELLOW}Remove configuration directory ${CONFIG_DIR}? [y/N]${NC} "
        read -r response
        if [[ "${response}" =~ ^[Yy]$ ]]; then
            rm -rf "${CONFIG_DIR}"
            log INFO "Configuration directory removed"
        else
            log INFO "Configuration directory preserved at ${CONFIG_DIR}"
        fi
    fi
    
    # Remove service user (optional)
    if id "mediamtx" &>/dev/null; then
        echo -e "${YELLOW}Remove service user 'mediamtx'? [y/N]${NC} "
        read -r response
        if [[ "${response}" =~ ^[Yy]$ ]]; then
            if command -v userdel &>/dev/null; then
                userdel mediamtx 2>/dev/null || true
            elif command -v deluser &>/dev/null; then
                deluser mediamtx 2>/dev/null || true
            fi
            log INFO "Service user removed"
        fi
    fi
    
    log INFO "MediaMTX uninstalled successfully!"
}

# Show status
show_status() {
    log INFO "MediaMTX Status:"
    echo ""
    
    # Check if installed
    if [[ -f "${INSTALL_DIR}/mediamtx" ]]; then
        echo -e "Installation: ${GREEN}Installed${NC}"
        echo "Binary: ${INSTALL_DIR}/mediamtx"
        
        # Get version
        local version="unknown"
        if "${INSTALL_DIR}/mediamtx" --version &>/dev/null; then
            version="$("${INSTALL_DIR}/mediamtx" --version 2>&1 | grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "unknown")"
        fi
        echo "Version: ${version}"
    else
        echo -e "Installation: ${RED}Not installed${NC}"
    fi
    
    # Check config
    if [[ -f "${CONFIG_DIR}/${DEFAULT_CONFIG_NAME}" ]]; then
        echo -e "Configuration: ${GREEN}Present${NC}"
        echo "Config file: ${CONFIG_DIR}/${DEFAULT_CONFIG_NAME}"
    else
        echo -e "Configuration: ${YELLOW}Not found${NC}"
    fi
    
    # Check service
    if command -v systemctl &>/dev/null && [[ -f "${SERVICE_DIR}/${SERVICE_NAME}" ]]; then
        if systemctl is-active --quiet mediamtx; then
            echo -e "Service: ${GREEN}Running${NC}"
        else
            echo -e "Service: ${RED}Stopped${NC}"
        fi
        
        if systemctl is-enabled --quiet mediamtx 2>/dev/null; then
            echo -e "Startup: ${GREEN}Enabled${NC}"
        else
            echo -e "Startup: ${YELLOW}Disabled${NC}"
        fi
    else
        echo -e "Service: ${YELLOW}Not configured${NC}"
    fi
    
    # Check latest version
    echo ""
    echo "Checking for updates..."
    
    # Create temp dir for version check
    local temp_status_dir="/tmp/mediamtx-status-$$"
    mkdir -p "${temp_status_dir}"
    export TEMP_DIR="${temp_status_dir}"
    
    local latest_version
    if latest_version="$(get_latest_release 2>/dev/null)"; then
        echo "Latest version: ${latest_version}"
        if [[ "${version}" != "${latest_version}" ]] && [[ "${version}" != "unknown" ]]; then
            echo -e "${YELLOW}Update available!${NC} Run '${SCRIPT_NAME} update' to upgrade."
        elif [[ "${version}" == "${latest_version}" ]]; then
            echo -e "${GREEN}You are running the latest version.${NC}"
        fi
    else
        echo "Could not check for updates"
    fi
    
    # Cleanup temp dir
    rm -rf "${temp_status_dir}" 2>/dev/null || true
}

# Show help
show_help() {
    cat << EOF
MediaMTX Manager - Install/Update/Uninstall MediaMTX

Usage: ${SCRIPT_NAME} [COMMAND]

Commands:
    install     Install MediaMTX
    update      Update MediaMTX to the latest version
    uninstall   Uninstall MediaMTX
    status      Show installation status
    help        Show this help message

Examples:
    sudo ${SCRIPT_NAME} install
    sudo ${SCRIPT_NAME} update
    sudo ${SCRIPT_NAME} status

Requirements:
    - Run with sudo (root access required)
    - curl or wget for downloading
    - tar for extraction
    - sha256sum for verification (optional)
    - systemctl for service management (optional)

Configuration:
    Config file: ${CONFIG_DIR}/${DEFAULT_CONFIG_NAME}
    Binary: ${INSTALL_DIR}/mediamtx

Service management (if systemd available):
    sudo systemctl start mediamtx    # Start service
    sudo systemctl stop mediamtx     # Stop service
    sudo systemctl restart mediamtx  # Restart service
    sudo systemctl status mediamtx   # Check status
    sudo systemctl enable mediamtx   # Enable at boot
    sudo systemctl disable mediamtx  # Disable at boot

Note: This script handles the ARM64 naming convention change in MediaMTX
      (arm64v8 for versions < 1.12.1, arm64 for versions >= 1.12.1)

EOF
}

# Main function
main() {
    # Check requirements first (before root check for help)
    if [[ "${1:-}" != "help" ]]; then
        check_requirements
        check_root
    fi
    
    case "${1:-}" in
        install)
            install_mediamtx
            ;;
        update)
            update_mediamtx
            ;;
        uninstall)
            uninstall_mediamtx
            ;;
        status)
            show_status
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            echo "Error: Invalid command '${1:-}'"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# Run main function
main "$@"

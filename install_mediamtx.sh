#!/usr/bin/env bash
#
# MediaMTX Installation Manager - Production-Ready Install/Update/Uninstall
# Version: 5.2.0
#
# This script provides a robust, secure, and configurable installation manager
# for MediaMTX with comprehensive error handling and validation.
#
# Enhancements in v5.2.0:
#   - Intelligent detection of management mode during updates
#   - Proper stop/start based on management mode (systemd/stream-manager/manual)
#   - Stream manager integration with automatic stream preservation
#   - Enhanced installation guidance for audio streaming setups
#
# Enhancements in v5.1.0:
#   - Enhanced status detection for processes managed by stream manager
#   - Better real-time scheduling detection
#   - Active stream enumeration with names
#   - Improved health checks with multiple API endpoint testing
#   - Smart detection of management mode (systemd vs stream manager)
#   - Process uptime display
#   - Last error preview in health check
#
# Usage: ./mediamtx-installer.sh [OPTIONS] COMMAND
#
# Commands:
#   install     Install MediaMTX
#   update      Update to latest version
#   uninstall   Remove MediaMTX
#   status      Show installation status
#   verify      Verify installation integrity
#   help        Show help message
#
# Options:
#   -c, --config FILE      Configuration file
#   -v, --verbose         Enable verbose output
#   -q, --quiet          Suppress non-error output
#   -n, --dry-run        Show what would be done
#   -f, --force          Force operation (skip confirmations)
#   -V, --version VER    Install specific version
#   -p, --prefix DIR     Installation prefix (default: /usr/local)
#   --no-service         Skip systemd service creation
#   --no-config          Skip configuration file creation
#   --verify-gpg         Verify GPG signatures (if available)
#
# Exit codes:
#   0  - Success
#   1  - General error
#   2  - Permission denied
#   3  - Unsupported platform
#   4  - Missing dependencies
#   5  - Download failed
#   6  - Verification failed
#   7  - Installation failed
#   8  - Service operation failed
#   9  - Configuration error
#   10 - Validation error

set -euo pipefail

# Strict error handling
set -o errtrace
set -o functrace

# Script metadata
readonly SCRIPT_VERSION="5.2.0"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_PID="$$"
readonly SCRIPT_PPID="$PPID"

# Default configuration (can be overridden via config file or environment)
readonly DEFAULT_INSTALL_PREFIX="${MEDIAMTX_PREFIX:-/usr/local}"
readonly DEFAULT_CONFIG_DIR="${MEDIAMTX_CONFIG_DIR:-/etc/mediamtx}"
readonly DEFAULT_SERVICE_USER="${MEDIAMTX_USER:-mediamtx}"
readonly DEFAULT_SERVICE_GROUP="${MEDIAMTX_GROUP:-mediamtx}"
readonly DEFAULT_RTSP_PORT="${MEDIAMTX_RTSP_PORT:-8554}"
readonly DEFAULT_API_PORT="${MEDIAMTX_API_PORT:-9997}"
readonly DEFAULT_METRICS_PORT="${MEDIAMTX_METRICS_PORT:-9998}"
readonly DEFAULT_DOWNLOAD_TIMEOUT="${MEDIAMTX_DOWNLOAD_TIMEOUT:-300}"
readonly DEFAULT_DOWNLOAD_RETRIES="${MEDIAMTX_DOWNLOAD_RETRIES:-3}"
readonly DEFAULT_GITHUB_REPO="${MEDIAMTX_REPO:-bluenviron/mediamtx}"

# Runtime configuration (set via command line)
INSTALL_PREFIX="${DEFAULT_INSTALL_PREFIX}"
CONFIG_DIR="${DEFAULT_CONFIG_DIR}"
SERVICE_USER="${DEFAULT_SERVICE_USER}"
SERVICE_GROUP="${DEFAULT_SERVICE_GROUP}"
VERBOSE_MODE=false
QUIET_MODE=false
DRY_RUN_MODE=false
FORCE_MODE=false
SKIP_SERVICE=false
SKIP_CONFIG=false
VERIFY_GPG=false
TARGET_VERSION=""
CONFIG_FILE=""

# Derived paths
INSTALL_DIR="${INSTALL_PREFIX}/bin"
SERVICE_DIR="/etc/systemd/system"
SERVICE_NAME="mediamtx.service"
CONFIG_NAME="mediamtx.yml"

# Temporary directory with secure creation
TEMP_BASE="${TMPDIR:-/tmp}"
TEMP_DIR=""
LOG_FILE=""
LOCK_FILE="/var/lock/mediamtx-installer.lock"

# GitHub API configuration
readonly GITHUB_API_BASE="https://api.github.com"
readonly GITHUB_API_TIMEOUT=30
readonly USER_AGENT="MediaMTX-Installer/${SCRIPT_VERSION}"

# Color codes (disabled in quiet mode or if not terminal)
if [[ -t 1 ]] && [[ "${QUIET_MODE}" != "true" ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly MAGENTA='\033[0;35m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly NC='\033[0m'
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly MAGENTA=''
    readonly CYAN=''
    readonly BOLD=''
    readonly NC=''
fi

# Arrays for cleanup tracking
declare -a CLEANUP_FILES=()
declare -a CLEANUP_DIRS=()
declare -a ROLLBACK_ACTIONS=()

# ============================================================================
# Utility Functions
# ============================================================================

# Enhanced error handler with stack trace
error_handler() {
    local line_no=$1
    local bash_lineno=$2
    local last_command=$3
    local code=$4
    local func_stack=()
    
    if [[ "${code}" -ne 0 ]]; then
        log_error "Command failed with exit code ${code}"
        log_error "Failed command: ${last_command}"
        log_error "Line ${line_no} in function ${FUNCNAME[1]}"
        
        if [[ "${VERBOSE_MODE}" == "true" ]]; then
            log_debug "Stack trace:"
            for ((i=1; i<${#FUNCNAME[@]}; i++)); do
                log_debug "  ${i}: ${FUNCNAME[$i]}() at line ${BASH_LINENO[$((i-1))]}"
            done
        fi
    fi
}

trap 'error_handler ${LINENO} ${BASH_LINENO} "${BASH_COMMAND}" $?' ERR

# Comprehensive cleanup handler
cleanup() {
    local exit_code=$?
    
    # Remove lock file
    if [[ -f "${LOCK_FILE}" ]] && [[ -f "${LOCK_FILE}.pid" ]]; then
        local lock_pid
        lock_pid=$(cat "${LOCK_FILE}.pid" 2>/dev/null || echo "0")
        if [[ "${lock_pid}" == "${SCRIPT_PID}" ]]; then
            rm -f "${LOCK_FILE}" "${LOCK_FILE}.pid" 2>/dev/null || true
        fi
    fi
    
    # Execute rollback actions if failed
    if [[ ${exit_code} -ne 0 ]] && [[ ${#ROLLBACK_ACTIONS[@]} -gt 0 ]]; then
        log_warn "Executing rollback actions..."
        for action in "${ROLLBACK_ACTIONS[@]}"; do
            eval "${action}" 2>/dev/null || true
        done
    fi
    
    # Clean up files
    for file in "${CLEANUP_FILES[@]}"; do
        [[ -f "${file}" ]] && rm -f "${file}" 2>/dev/null || true
    done
    
    # Clean up directories
    for dir in "${CLEANUP_DIRS[@]}"; do
        [[ -d "${dir}" ]] && rm -rf "${dir}" 2>/dev/null || true
    done
    
    # Clean up temp directory
    if [[ -n "${TEMP_DIR}" ]] && [[ -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}" 2>/dev/null || true
    fi
    
    # Save log on error
    if [[ ${exit_code} -ne 0 ]] && [[ -f "${LOG_FILE}" ]]; then
        local error_log="/tmp/mediamtx-installer-error-$(date +%Y%m%d-%H%M%S).log"
        cp "${LOG_FILE}" "${error_log}" 2>/dev/null || true
        [[ "${QUIET_MODE}" != "true" ]] && echo -e "${YELLOW}Error log saved to: ${error_log}${NC}" >&2
    fi
    
    return ${exit_code}
}

trap cleanup EXIT INT TERM

# Logging functions with levels
log_debug() {
    [[ "${VERBOSE_MODE}" == "true" ]] || return 0
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $*"
    echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
    [[ "${QUIET_MODE}" != "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $*" >&2
}

log_info() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
    echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
    [[ "${QUIET_MODE}" != "true" ]] && echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*"
    echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*"
    echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Fatal error with exit
fatal() {
    log_error "$1"
    exit "${2:-1}"
}

# Progress indicator for long operations
show_progress() {
    [[ "${QUIET_MODE}" == "true" ]] && return 0
    local pid=$1
    local message="${2:-Processing}"
    
    echo -n "${message}"
    while kill -0 "${pid}" 2>/dev/null; do
        echo -n "."
        sleep 1
    done
    echo " done"
}

# ============================================================================
# Validation Functions
# ============================================================================

# Validate required commands with version checking
check_requirements() {
    local missing=()
    local warnings=()
    
    # Required commands with minimum versions
    local -A required_commands=(
        ["bash"]="4.0"
        ["curl"]="7.0"
        ["tar"]="1.20"
    )
    
    # Optional but recommended commands
    local -A optional_commands=(
        ["jq"]="1.5"
        ["sha256sum"]=""
        ["systemctl"]=""
        ["gpg"]="2.0"
    )
    
    # Check required commands
    for cmd in "${!required_commands[@]}"; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        elif [[ -n "${required_commands[$cmd]}" ]]; then
            # Version check
            local version
            case "${cmd}" in
                bash)
                    version="${BASH_VERSION%%.*}.${BASH_VERSION#*.}"
                    version="${version%%.*}"
                    ;;
                curl)
                    version=$(curl --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
                    ;;
                tar)
                    version=$(tar --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
                    ;;
            esac
            
            if [[ -n "${version}" ]]; then
                if ! version_compare "${version}" "${required_commands[$cmd]}"; then
                    warnings+=("${cmd} version ${version} is below recommended ${required_commands[$cmd]}")
                fi
            fi
        fi
    done
    
    # Check optional commands
    for cmd in "${!optional_commands[@]}"; do
        if ! command -v "${cmd}" &>/dev/null; then
            warnings+=("Optional: ${cmd} not found")
        fi
    done
    
    # Report findings
    if [[ ${#missing[@]} -gt 0 ]]; then
        fatal "Missing required commands: ${missing[*]}" 4
    fi
    
    if [[ ${#warnings[@]} -gt 0 ]] && [[ "${VERBOSE_MODE}" == "true" ]]; then
        for warning in "${warnings[@]}"; do
            log_warn "${warning}"
        done
    fi
    
    # Check for download command preference
    if command -v curl &>/dev/null; then
        readonly DOWNLOAD_CMD="curl"
    elif command -v wget &>/dev/null; then
        readonly DOWNLOAD_CMD="wget"
    else
        fatal "Neither curl nor wget found" 4
    fi
    
    log_debug "Using ${DOWNLOAD_CMD} for downloads"
}

# Version comparison (returns 0 if v1 >= v2)
version_compare() {
    local v1="$1"
    local v2="$2"
    
    # Convert versions to comparable format
    local v1_major="${v1%%.*}"
    local v1_minor="${v1#*.}"
    v1_minor="${v1_minor%%.*}"
    
    local v2_major="${v2%%.*}"
    local v2_minor="${v2#*.}"
    v2_minor="${v2_minor%%.*}"
    
    if [[ ${v1_major} -gt ${v2_major} ]]; then
        return 0
    elif [[ ${v1_major} -eq ${v2_major} ]] && [[ ${v1_minor} -ge ${v2_minor} ]]; then
        return 0
    else
        return 1
    fi
}

# Validate URL format
validate_url() {
    local url="$1"
    local url_regex='^https?://[-A-Za-z0-9\+&@#/%?=~_|!:,.;]*[-A-Za-z0-9\+&@#/%=~_|]$'
    
    if [[ ! "${url}" =~ ${url_regex} ]]; then
        log_error "Invalid URL format: ${url}"
        return 1
    fi
    return 0
}

# Validate version format
validate_version() {
    local version="$1"
    local version_regex='^v?[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9\-\.]+)?$'
    
    if [[ ! "${version}" =~ ${version_regex} ]]; then
        log_error "Invalid version format: ${version}"
        return 1
    fi
    return 0
}

# ============================================================================
# Security Functions
# ============================================================================

# Acquire lock with timeout
acquire_lock() {
    local timeout="${1:-30}"
    local elapsed=0
    
    while [[ ${elapsed} -lt ${timeout} ]]; do
        if mkdir "${LOCK_FILE}.d" 2>/dev/null; then
            echo "${SCRIPT_PID}" > "${LOCK_FILE}.pid"
            log_debug "Lock acquired (PID: ${SCRIPT_PID})"
            return 0
        fi
        
        # Check if lock holder is still running
        if [[ -f "${LOCK_FILE}.pid" ]]; then
            local lock_pid
            lock_pid=$(cat "${LOCK_FILE}.pid" 2>/dev/null || echo "0")
            if ! kill -0 "${lock_pid}" 2>/dev/null; then
                log_warn "Removing stale lock (PID: ${lock_pid})"
                rm -rf "${LOCK_FILE}.d" "${LOCK_FILE}.pid" 2>/dev/null || true
                continue
            fi
        fi
        
        sleep 1
        ((elapsed++))
    done
    
    fatal "Failed to acquire lock after ${timeout} seconds" 1
}

# Create secure temporary directory
create_temp_dir() {
    local template="${TEMP_BASE}/mediamtx-installer-XXXXXX"
    
    if command -v mktemp &>/dev/null; then
        TEMP_DIR=$(mktemp -d "${template}")
    else
        # Fallback for systems without mktemp
        TEMP_DIR="${TEMP_BASE}/mediamtx-installer-${SCRIPT_PID}-$(date +%s)"
        mkdir -m 700 "${TEMP_DIR}"
    fi
    
    if [[ ! -d "${TEMP_DIR}" ]]; then
        fatal "Failed to create temporary directory" 1
    fi
    
    # Create log file in temp directory
    LOG_FILE="${TEMP_DIR}/install.log"
    touch "${LOG_FILE}"
    chmod 600 "${LOG_FILE}"
    
    CLEANUP_DIRS+=("${TEMP_DIR}")
    log_debug "Created temporary directory: ${TEMP_DIR}"
}

# Validate file checksum
verify_checksum() {
    local file="$1"
    local checksum_file="$2"
    local algorithm="${3:-sha256}"
    
    if [[ ! -f "${file}" ]]; then
        log_error "File not found: ${file}"
        return 1
    fi
    
    if [[ ! -f "${checksum_file}" ]]; then
        log_warn "Checksum file not found: ${checksum_file}"
        return 2
    fi
    
    local expected_checksum
    expected_checksum=$(awk '{print $1}' "${checksum_file}" | head -1)
    
    if [[ -z "${expected_checksum}" ]]; then
        log_error "Failed to extract checksum from file"
        return 1
    fi
    
    local actual_checksum
    case "${algorithm}" in
        sha256)
            if command -v sha256sum &>/dev/null; then
                actual_checksum=$(sha256sum "${file}" | awk '{print $1}')
            elif command -v shasum &>/dev/null; then
                actual_checksum=$(shasum -a 256 "${file}" | awk '{print $1}')
            else
                log_warn "No SHA256 tool available, skipping verification"
                return 2
            fi
            ;;
        *)
            log_error "Unsupported checksum algorithm: ${algorithm}"
            return 1
            ;;
    esac
    
    if [[ "${expected_checksum}" != "${actual_checksum}" ]]; then
        log_error "Checksum mismatch!"
        log_error "Expected: ${expected_checksum}"
        log_error "Actual:   ${actual_checksum}"
        return 1
    fi
    
    log_info "Checksum verified successfully"
    return 0
}

# Verify GPG signature (if available)
verify_gpg_signature() {
    local file="$1"
    local sig_file="$2"
    
    if [[ "${VERIFY_GPG}" != "true" ]]; then
        return 0
    fi
    
    if ! command -v gpg &>/dev/null; then
        log_warn "GPG not available, skipping signature verification"
        return 2
    fi
    
    if [[ ! -f "${sig_file}" ]]; then
        log_warn "Signature file not found: ${sig_file}"
        return 2
    fi
    
    # Import MediaMTX public key (would need to be provided)
    # This is a placeholder - actual implementation would need the real key
    local key_url="https://github.com/${DEFAULT_GITHUB_REPO}/releases/download/signing-key.asc"
    local key_file="${TEMP_DIR}/signing-key.asc"
    
    if download_file "${key_url}" "${key_file}"; then
        gpg --import "${key_file}" 2>/dev/null || true
    fi
    
    if gpg --verify "${sig_file}" "${file}" 2>/dev/null; then
        log_info "GPG signature verified successfully"
        return 0
    else
        log_error "GPG signature verification failed"
        return 1
    fi
}

# ============================================================================
# Platform Detection
# ============================================================================

# Detect operating system with detailed information
detect_platform() {
    local os=""
    local arch=""
    local distro=""
    local version=""
    
    # Detect OS
    case "${OSTYPE}" in
        linux*)
            os="linux"
            # Detect distribution
            if [[ -f /etc/os-release ]]; then
                source /etc/os-release
                distro="${ID:-unknown}"
                version="${VERSION_ID:-unknown}"
            elif [[ -f /etc/redhat-release ]]; then
                distro="rhel"
            elif [[ -f /etc/debian_version ]]; then
                distro="debian"
            fi
            ;;
        darwin*)
            os="darwin"
            distro="macos"
            version=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
            ;;
        freebsd*)
            os="freebsd"
            distro="freebsd"
            version=$(uname -r)
            ;;
        *)
            fatal "Unsupported operating system: ${OSTYPE}" 3
            ;;
    esac
    
    # Detect architecture
    local machine
    machine=$(uname -m)
    
    case "${machine}" in
        x86_64|amd64)
            arch="amd64"
            ;;
        i386|i686)
            arch="386"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        armv7*|armhf)
            arch="armv7"
            ;;
        armv6*)
            arch="armv6"
            ;;
        *)
            fatal "Unsupported architecture: ${machine}" 3
            ;;
    esac
    
    # Export platform information
    readonly PLATFORM_OS="${os}"
    readonly PLATFORM_ARCH="${arch}"
    readonly PLATFORM_DISTRO="${distro}"
    readonly PLATFORM_VERSION="${version}"
    
    log_debug "Platform: ${PLATFORM_OS}/${PLATFORM_ARCH} (${PLATFORM_DISTRO} ${PLATFORM_VERSION})"
}

# ============================================================================
# Download Functions
# ============================================================================

# Enhanced download with retry, resume, and failover
download_file() {
    local url="$1"
    local output="$2"
    local timeout="${3:-${DEFAULT_DOWNLOAD_TIMEOUT}}"
    local retries="${4:-${DEFAULT_DOWNLOAD_RETRIES}}"
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would download: ${url} -> ${output}"
        return 0
    fi
    
    # Validate URL
    if ! validate_url "${url}"; then
        return 1
    fi
    
    local attempt=0
    local success=false
    
    while [[ ${attempt} -lt ${retries} ]] && [[ "${success}" == "false" ]]; do
        ((attempt++))
        log_debug "Download attempt ${attempt}/${retries}: ${url}"
        
        # Create parent directory if needed
        local output_dir
        output_dir=$(dirname "${output}")
        [[ -d "${output_dir}" ]] || mkdir -p "${output_dir}"
        
        # Download based on available command
        case "${DOWNLOAD_CMD}" in
            curl)
                if curl -fsSL \
                    --connect-timeout 30 \
                    --max-time "${timeout}" \
                    --retry 2 \
                    --retry-delay 5 \
                    --retry-max-time 120 \
                    -C - \
                    -H "User-Agent: ${USER_AGENT}" \
                    -o "${output}" \
                    "${url}" 2>> "${LOG_FILE}"; then
                    success=true
                fi
                ;;
            wget)
                if wget -q \
                    --timeout="${timeout}" \
                    --tries=2 \
                    --wait=5 \
                    --continue \
                    --user-agent="${USER_AGENT}" \
                    -O "${output}" \
                    "${url}" 2>> "${LOG_FILE}"; then
                    success=true
                fi
                ;;
        esac
        
        if [[ "${success}" == "true" ]]; then
            # Verify downloaded file is not empty
            if [[ ! -s "${output}" ]]; then
                log_error "Downloaded file is empty: ${output}"
                rm -f "${output}"
                success=false
            else
                log_debug "Download successful: ${output} ($(stat -c%s "${output}" 2>/dev/null || stat -f%z "${output}" 2>/dev/null || echo "unknown") bytes)"
                return 0
            fi
        fi
        
        if [[ ${attempt} -lt ${retries} ]]; then
            log_warn "Download failed, retrying in 10 seconds..."
            sleep 10
        fi
    done
    
    log_error "Download failed after ${retries} attempts: ${url}"
    return 1
}

# Parse GitHub API response safely
parse_github_release() {
    local json_file="$1"
    local field="$2"
    
    # Use jq if available (most reliable)
    if command -v jq &>/dev/null; then
        jq -r ".${field} // empty" "${json_file}" 2>/dev/null || echo ""
        return
    fi
    
    # Fallback to Python if available
    if command -v python3 &>/dev/null; then
        python3 -c "
import json, sys
try:
    with open('${json_file}') as f:
        data = json.load(f)
        print(data.get('${field}', ''))
except:
    pass
" 2>/dev/null || echo ""
        return
    fi
    
    # Last resort: grep/sed (less reliable)
    grep -o "\"${field}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "${json_file}" 2>/dev/null | \
        sed 's/.*:\s*"\([^"]*\)".*/\1/' | head -1 || echo ""
}

# Get latest release information
get_release_info() {
    local version="${1:-latest}"
    local api_url
    
    if [[ "${version}" == "latest" ]]; then
        api_url="${GITHUB_API_BASE}/repos/${DEFAULT_GITHUB_REPO}/releases/latest"
    else
        api_url="${GITHUB_API_BASE}/repos/${DEFAULT_GITHUB_REPO}/releases/tags/${version}"
    fi
    
    local release_file="${TEMP_DIR}/release.json"
    
    log_info "Fetching release information..."
    if ! download_file "${api_url}" "${release_file}" "${GITHUB_API_TIMEOUT}"; then
        fatal "Failed to fetch release information" 5
    fi
    
    # Parse release information
    local tag_name
    tag_name=$(parse_github_release "${release_file}" "tag_name")
    
    if [[ -z "${tag_name}" ]]; then
        fatal "Failed to parse release information" 5
    fi
    
    # Validate version format
    if ! validate_version "${tag_name}"; then
        fatal "Invalid version format in release: ${tag_name}" 10
    fi
    
    readonly RELEASE_VERSION="${tag_name}"
    readonly RELEASE_FILE="${release_file}"
    
    log_info "Found release: ${RELEASE_VERSION}"
}

# ============================================================================
# Installation Functions
# ============================================================================

# Build asset URL based on platform
build_asset_url() {
    local version="${1#v}"  # Remove 'v' prefix
    local os="$2"
    local arch="$3"
    
    # Handle architecture naming variations
    local arch_suffix="${arch}"
    
    # Special handling for ARM64 (version-dependent naming)
    if [[ "${arch}" == "arm64" ]] && [[ "${os}" == "linux" ]]; then
        # Check version for naming convention
        local major minor patch
        IFS='.' read -r major minor patch <<< "${version}"
        local version_num=$((major * 10000 + minor * 100 + patch))
        
        if [[ ${version_num} -lt 11201 ]]; then  # v1.12.1
            arch_suffix="arm64v8"
        fi
    fi
    
    # Build filename
    local filename="mediamtx_v${version}_${os}_${arch_suffix}.tar.gz"
    local url="https://github.com/${DEFAULT_GITHUB_REPO}/releases/download/v${version}/${filename}"
    
    echo "${url}"
}

# Download and verify MediaMTX binary
download_mediamtx() {
    local version="$1"
    local os="$2"
    local arch="$3"
    
    local asset_url
    asset_url=$(build_asset_url "${version}" "${os}" "${arch}")
    
    local archive="${TEMP_DIR}/mediamtx.tar.gz"
    local checksum="${TEMP_DIR}/mediamtx.tar.gz.sha256sum"
    
    log_info "Downloading MediaMTX ${version} for ${os}/${arch}..."
    
    # Download archive
    if ! download_file "${asset_url}" "${archive}"; then
        # Try alternate naming for ARM64
        if [[ "${arch}" == "arm64" ]]; then
            log_warn "Trying alternate ARM64 naming..."
            local alt_arch="arm64v8"
            [[ "${asset_url}" == *"arm64v8"* ]] && alt_arch="arm64"
            
            asset_url=$(build_asset_url "${version}" "${os}" "${alt_arch}")
            if ! download_file "${asset_url}" "${archive}"; then
                fatal "Failed to download MediaMTX" 5
            fi
        else
            fatal "Failed to download MediaMTX" 5
        fi
    fi
    
    # Download and verify checksum
    log_info "Verifying download..."
    if download_file "${asset_url}.sha256sum" "${checksum}"; then
        if ! verify_checksum "${archive}" "${checksum}"; then
            fatal "Checksum verification failed" 6
        fi
    else
        log_warn "Checksum file not available, skipping verification"
    fi
    
    # Verify GPG signature if requested
    if [[ "${VERIFY_GPG}" == "true" ]]; then
        local sig_file="${TEMP_DIR}/mediamtx.tar.gz.sig"
        if download_file "${asset_url}.sig" "${sig_file}"; then
            verify_gpg_signature "${archive}" "${sig_file}" || true
        fi
    fi
    
    # Extract archive
    log_info "Extracting archive..."
    if ! tar -xzf "${archive}" -C "${TEMP_DIR}"; then
        fatal "Failed to extract archive" 7
    fi
    
    # Verify extracted binary
    if [[ ! -f "${TEMP_DIR}/mediamtx" ]]; then
        fatal "Binary not found in archive" 7
    fi
    
    # Test binary
    if ! "${TEMP_DIR}/mediamtx" --version &>/dev/null; then
        log_warn "Binary version check failed"
    fi
    
    log_debug "Binary extracted successfully"
}

# Create configuration file
create_config() {
    local config_file="${CONFIG_DIR}/${CONFIG_NAME}"
    
    if [[ "${SKIP_CONFIG}" == "true" ]]; then
        log_debug "Skipping configuration creation"
        return 0
    fi
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would create config: ${config_file}"
        return 0
    fi
    
    # Create config directory
    [[ -d "${CONFIG_DIR}" ]] || mkdir -p "${CONFIG_DIR}"
    
    # Backup existing config
    if [[ -f "${config_file}" ]]; then
        local backup="${config_file}.backup.$(date +%Y%m%d-%H%M%S)"
        cp "${config_file}" "${backup}"
        log_info "Existing config backed up to: ${backup}"
        ROLLBACK_ACTIONS+=("mv '${backup}' '${config_file}'")
    fi
    
    # Create minimal working configuration
    cat > "${config_file}" << EOF
###############################################
# MediaMTX Configuration
# Generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}
# Date: $(date -Iseconds)
###############################################

# Global settings
logLevel: info
logDestinations: [stdout]
logFile: /var/log/mediamtx.log

# API Configuration
api: yes
apiAddress: :${DEFAULT_API_PORT}

# Metrics
metrics: yes
metricsAddress: :${DEFAULT_METRICS_PORT}

# RTSP Server Configuration
rtsp: yes
rtspAddress: :${DEFAULT_RTSP_PORT}
rtspEncryption: "no"
rtspTransports: [tcp, udp]
rtspProtocols: [tcp, udp]
rtspAuthMethods: [basic]

# RTMP Server (disabled by default)
rtmp: no
rtmpAddress: :1935

# HLS Server (disabled by default)
hls: no
hlsAddress: :8888

# WebRTC (disabled by default)
webrtc: no
webrtcAddress: :8889

# Paths configuration
pathDefaults:
  source: publisher
  sourceOnDemand: no
  sourceOnDemandStartTimeout: 10s
  sourceOnDemandCloseAfter: 10s
  record: no

# Define your paths here
paths:
  # Example path:
  # mystream:
  #   source: rtsp://192.168.1.100:554/stream

EOF
    
    # Set secure permissions
    chmod 644 "${config_file}"
    chown root:root "${config_file}"
    
    log_info "Configuration created: ${config_file}"
}

# Create systemd service
create_service() {
    if [[ "${SKIP_SERVICE}" == "true" ]]; then
        log_debug "Skipping service creation"
        return 0
    fi
    
    if ! command -v systemctl &>/dev/null; then
        log_warn "systemd not available, skipping service creation"
        return 0
    fi
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would create service: ${SERVICE_NAME}"
        return 0
    fi
    
    local service_file="${SERVICE_DIR}/${SERVICE_NAME}"
    
    # Backup existing service
    if [[ -f "${service_file}" ]]; then
        local backup="${service_file}.backup.$(date +%Y%m%d-%H%M%S)"
        cp "${service_file}" "${backup}"
        ROLLBACK_ACTIONS+=("mv '${backup}' '${service_file}'")
    fi
    
    # Create service file
    cat > "${service_file}" << EOF
[Unit]
Description=MediaMTX Media Server
Documentation=https://github.com/${DEFAULT_GITHUB_REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
ExecStart=${INSTALL_DIR}/mediamtx ${CONFIG_DIR}/${CONFIG_NAME}
ExecReload=/bin/kill -USR1 \$MAINPID

# Restart configuration
Restart=always
RestartSec=10
StartLimitInterval=60
StartLimitBurst=3

# Environment
Environment="HOME=/var/lib/mediamtx"
WorkingDirectory=/var/lib/mediamtx

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mediamtx

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

# Capabilities
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE

# Resource limits
LimitNOFILE=65536
LimitNPROC=512

# Directories
ReadWritePaths=/var/log /var/lib/mediamtx
StateDirectory=mediamtx
LogsDirectory=mediamtx
RuntimeDirectory=mediamtx

[Install]
WantedBy=multi-user.target
EOF
    
    # Set permissions
    chmod 644 "${service_file}"
    
    # Reload systemd
    systemctl daemon-reload
    
    log_info "Service created: ${SERVICE_NAME}"
}

# Create service user
create_user() {
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would create user: ${SERVICE_USER}"
        return 0
    fi
    
    # Check if user exists
    if id "${SERVICE_USER}" &>/dev/null; then
        log_debug "User ${SERVICE_USER} already exists"
        return 0
    fi
    
    log_info "Creating service user: ${SERVICE_USER}"
    
    # Create system user
    if command -v useradd &>/dev/null; then
        useradd \
            --system \
            --home-dir /var/lib/mediamtx \
            --no-create-home \
            --shell /usr/sbin/nologin \
            --comment "MediaMTX service user" \
            "${SERVICE_USER}"
    elif command -v adduser &>/dev/null; then
        adduser \
            --system \
            --home /var/lib/mediamtx \
            --no-create-home \
            --shell /usr/sbin/nologin \
            --group \
            "${SERVICE_USER}"
    else
        log_warn "Cannot create user, no user management command found"
        return 1
    fi
    
    # Create home directory
    mkdir -p /var/lib/mediamtx
    chown "${SERVICE_USER}:${SERVICE_GROUP}" /var/lib/mediamtx
    chmod 755 /var/lib/mediamtx
    
    ROLLBACK_ACTIONS+=("userdel '${SERVICE_USER}' 2>/dev/null || true")
}

# Install MediaMTX (Enhanced with stream manager detection)
install_mediamtx() {
    log_info "Installing MediaMTX..."
    
    # Check if already installed
    if [[ -f "${INSTALL_DIR}/mediamtx" ]] && [[ "${FORCE_MODE}" != "true" ]]; then
        fatal "MediaMTX is already installed. Use --force to override or 'update' command" 7
    fi
    
    # Get release information
    get_release_info "${TARGET_VERSION}"
    
    # Download binary
    download_mediamtx "${RELEASE_VERSION}" "${PLATFORM_OS}" "${PLATFORM_ARCH}"
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would install MediaMTX ${RELEASE_VERSION}"
        return 0
    fi
    
    # Create installation directory
    [[ -d "${INSTALL_DIR}" ]] || mkdir -p "${INSTALL_DIR}"
    
    # Install binary
    log_info "Installing binary..."
    install -m 755 "${TEMP_DIR}/mediamtx" "${INSTALL_DIR}/"
    ROLLBACK_ACTIONS+=("rm -f '${INSTALL_DIR}/mediamtx'")
    
    # Create user
    create_user
    
    # Create configuration
    create_config
    
    # Create service
    create_service
    
    # Verify installation
    if "${INSTALL_DIR}/mediamtx" --version &>/dev/null; then
        log_info "Installation verified successfully"
    else
        log_warn "Could not verify installation"
    fi
    
    log_info "MediaMTX ${RELEASE_VERSION} installed successfully!"
    
    # ============================================================================
    # CHECK FOR STREAM MANAGER AND PROVIDE APPROPRIATE GUIDANCE
    # ============================================================================
    local stream_manager_found=false
    local stream_manager_path=""
    
    # Look for stream manager script
    if [[ -f "./mediamtx-stream-manager.sh" ]]; then
        stream_manager_found=true
        stream_manager_path="./mediamtx-stream-manager.sh"
    elif [[ -f "${SCRIPT_DIR}/mediamtx-stream-manager.sh" ]]; then
        stream_manager_found=true
        stream_manager_path="${SCRIPT_DIR}/mediamtx-stream-manager.sh"
    fi
    
    # Check for audio streaming configuration
    local audio_streaming_setup=false
    if [[ -f "/etc/mediamtx/audio-devices.conf" ]] || [[ -d "/var/lib/mediamtx-ffmpeg" ]]; then
        audio_streaming_setup=true
    fi
    
    echo ""
    if [[ "${stream_manager_found}" == "true" ]] || [[ "${audio_streaming_setup}" == "true" ]]; then
        echo "================================"
        echo "Audio Streaming Setup Detected!"
        echo "================================"
        echo ""
        echo "It appears you have an audio streaming setup with MediaMTX."
        echo "You can manage MediaMTX using EITHER:"
        echo ""
        echo "Option 1: Stream Manager (Recommended for audio streaming)"
        if [[ -n "${stream_manager_path}" ]]; then
            echo "  sudo ${stream_manager_path} start"
            echo "  sudo ${stream_manager_path} status"
        else
            echo "  sudo ./mediamtx-stream-manager.sh start"
            echo "  sudo ./mediamtx-stream-manager.sh status"
        fi
        echo ""
        echo "Option 2: Systemd Service (Standard management)"
        echo "  sudo systemctl start mediamtx"
        echo "  sudo systemctl enable mediamtx  # Auto-start at boot"
        echo "  sudo systemctl status mediamtx"
        echo ""
        echo "Note: Use only ONE management method at a time!"
    else
        # Standard output for non-audio-streaming setups
        if command -v systemctl &>/dev/null && [[ -f "${SERVICE_DIR}/${SERVICE_NAME}" ]]; then
            echo ""
            echo "To start MediaMTX:"
            echo "  sudo systemctl start mediamtx"
            echo "  sudo systemctl enable mediamtx  # Auto-start at boot"
            echo ""
            echo "To check status:"
            echo "  sudo systemctl status mediamtx"
        else
            echo ""
            echo "To start MediaMTX manually:"
            echo "  ${INSTALL_DIR}/mediamtx ${CONFIG_DIR}/${CONFIG_NAME}"
        fi
    fi
}

# Update MediaMTX (Enhanced with management mode detection)
update_mediamtx() {
    log_info "Updating MediaMTX..."
    
    # Check if installed
    if [[ ! -f "${INSTALL_DIR}/mediamtx" ]]; then
        fatal "MediaMTX is not installed. Use 'install' command first" 7
    fi
    
    # Get current version
    local current_version="unknown"
    if "${INSTALL_DIR}/mediamtx" --version &>/dev/null; then
        current_version=$("${INSTALL_DIR}/mediamtx" --version 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    
    # Get latest version
    get_release_info "${TARGET_VERSION}"
    
    if [[ "${current_version}" == "${RELEASE_VERSION}" ]] && [[ "${FORCE_MODE}" != "true" ]]; then
        log_info "Already at version ${RELEASE_VERSION}"
        return 0
    fi
    
    log_info "Updating from ${current_version} to ${RELEASE_VERSION}..."
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would update to ${RELEASE_VERSION}"
        return 0
    fi
    
    # ============================================================================
    # DETECT MANAGEMENT MODE BEFORE STOPPING
    # ============================================================================
    local management_mode="none"
    local was_running=false
    local stream_manager_script=""
    local active_streams=()
    
    # Check if running under systemd
    if command -v systemctl &>/dev/null && systemctl is-active --quiet mediamtx; then
        management_mode="systemd"
        was_running=true
        log_info "Detected: MediaMTX running under systemd"
    # Check if running under stream manager
    elif command -v pgrep &>/dev/null && pgrep -x "mediamtx" &>/dev/null; then
        # Check for stream manager indicators
        if [[ -d "/var/lib/mediamtx-ffmpeg" ]]; then
            # Count active FFmpeg streams
            local ffmpeg_count
            ffmpeg_count=$(pgrep -c -f "ffmpeg.*rtsp://localhost" 2>/dev/null || echo "0")
            
            if [[ ${ffmpeg_count} -gt 0 ]]; then
                management_mode="stream-manager"
                was_running=true
                
                # Collect active stream names
                if [[ -d "/var/lib/mediamtx-ffmpeg" ]]; then
                    for pid_file in /var/lib/mediamtx-ffmpeg/*.pid; do
                        if [[ -f "${pid_file}" ]]; then
                            local stream_name
                            stream_name=$(basename "${pid_file}" .pid)
                            local stream_pid
                            stream_pid=$(cat "${pid_file}" 2>/dev/null || echo "0")
                            if kill -0 "${stream_pid}" 2>/dev/null; then
                                active_streams+=("${stream_name}")
                            fi
                        fi
                    done
                fi
                
                log_info "Detected: MediaMTX running under stream manager with ${#active_streams[@]} active streams"
                
                # Try to find the stream manager script
                if [[ -f "./mediamtx-stream-manager.sh" ]]; then
                    stream_manager_script="./mediamtx-stream-manager.sh"
                elif [[ -f "${SCRIPT_DIR}/mediamtx-stream-manager.sh" ]]; then
                    stream_manager_script="${SCRIPT_DIR}/mediamtx-stream-manager.sh"
                elif [[ -f "/usr/local/bin/mediamtx-stream-manager.sh" ]]; then
                    stream_manager_script="/usr/local/bin/mediamtx-stream-manager.sh"
                else
                    log_warn "Stream manager script not found in common locations"
                fi
            fi
        # Check for audio configuration (another stream manager indicator)
        elif [[ -f "/etc/mediamtx/audio-devices.conf" ]]; then
            management_mode="stream-manager"
            was_running=true
            log_info "Detected: MediaMTX likely managed by stream manager (audio config present)"
        else
            # MediaMTX running but not managed
            management_mode="manual"
            was_running=true
            log_info "Detected: MediaMTX running manually/unmanaged"
        fi
    fi
    
    # ============================================================================
    # STOP MEDIAMTX BASED ON MANAGEMENT MODE
    # ============================================================================
    if [[ "${was_running}" == "true" ]]; then
        case "${management_mode}" in
            systemd)
                log_info "Stopping MediaMTX service (systemd)..."
                systemctl stop mediamtx
                ROLLBACK_ACTIONS+=("systemctl start mediamtx 2>/dev/null || true")
                ;;
            
            stream-manager)
                if [[ -n "${stream_manager_script}" ]] && [[ -x "${stream_manager_script}" ]]; then
                    log_info "Stopping MediaMTX and streams via stream manager..."
                    "${stream_manager_script}" stop || {
                        log_warn "Stream manager stop failed, falling back to manual stop"
                        # Fallback: stop FFmpeg streams manually
                        pkill -f "ffmpeg.*rtsp://localhost" 2>/dev/null || true
                        sleep 1
                        pkill mediamtx 2>/dev/null || true
                    }
                    ROLLBACK_ACTIONS+=("'${stream_manager_script}' start 2>/dev/null || true")
                else
                    log_info "Stopping MediaMTX and FFmpeg streams manually..."
                    # Stop FFmpeg streams first
                    pkill -f "ffmpeg.*rtsp://localhost" 2>/dev/null || true
                    sleep 1
                    # Then stop MediaMTX
                    pkill mediamtx 2>/dev/null || true
                fi
                ;;
            
            manual)
                log_info "Stopping manually-run MediaMTX..."
                pkill mediamtx 2>/dev/null || true
                ;;
        esac
        
        # Wait for processes to stop
        sleep 2
        
        # Verify stopped
        if pgrep -x "mediamtx" &>/dev/null; then
            log_warn "MediaMTX still running, forcing stop..."
            pkill -9 mediamtx 2>/dev/null || true
            sleep 1
        fi
    fi
    
    # ============================================================================
    # PERFORM UPDATE
    # ============================================================================
    
    # Backup current binary
    local backup="${INSTALL_DIR}/mediamtx.backup.$(date +%Y%m%d-%H%M%S)"
    cp "${INSTALL_DIR}/mediamtx" "${backup}"
    ROLLBACK_ACTIONS+=("mv '${backup}' '${INSTALL_DIR}/mediamtx'")
    log_info "Current binary backed up to: ${backup}"
    
    # Download new version
    download_mediamtx "${RELEASE_VERSION}" "${PLATFORM_OS}" "${PLATFORM_ARCH}"
    
    # Install new binary
    install -m 755 "${TEMP_DIR}/mediamtx" "${INSTALL_DIR}/"
    
    # ============================================================================
    # RESTART BASED ON ORIGINAL MANAGEMENT MODE
    # ============================================================================
    if [[ "${was_running}" == "true" ]]; then
        case "${management_mode}" in
            systemd)
                log_info "Starting MediaMTX service (systemd)..."
                systemctl start mediamtx
                ;;
            
            stream-manager)
                if [[ -n "${stream_manager_script}" ]] && [[ -x "${stream_manager_script}" ]]; then
                    log_info "Starting MediaMTX and streams via stream manager..."
                    "${stream_manager_script}" start || {
                        log_error "Failed to start via stream manager"
                        log_info "Please manually start with: sudo ${stream_manager_script} start"
                    }
                    
                    # Show which streams were restarted
                    if [[ ${#active_streams[@]} -gt 0 ]]; then
                        log_info "Restarted streams: ${active_streams[*]}"
                    fi
                else
                    log_warn "Stream manager script not found"
                    log_info "Please manually restart MediaMTX with your stream manager"
                    log_info "Typical command: sudo ./mediamtx-stream-manager.sh start"
                fi
                ;;
            
            manual)
                log_info "MediaMTX was running manually"
                log_info "Please restart it manually with your preferred method"
                ;;
            
            none)
                log_info "MediaMTX was not running before update"
                ;;
        esac
    else
        log_info "MediaMTX was not running before update"
    fi
    
    log_info "MediaMTX updated to ${RELEASE_VERSION} successfully!"
    
    # ============================================================================
    # POST-UPDATE RECOMMENDATIONS
    # ============================================================================
    if [[ "${management_mode}" == "stream-manager" ]]; then
        echo ""
        echo "Stream Manager Detected - Quick Commands:"
        echo "  • Check status: sudo ${stream_manager_script:-./mediamtx-stream-manager.sh} status"
        echo "  • View logs: tail -f /var/lib/mediamtx-ffmpeg/*.log"
        if [[ ${#active_streams[@]} -gt 0 ]]; then
            echo "  • Active streams before update: ${active_streams[*]}"
        fi
    elif [[ "${management_mode}" == "systemd" ]]; then
        echo ""
        echo "Systemd Management - Quick Commands:"
        echo "  • Check status: sudo systemctl status mediamtx"
        echo "  • View logs: sudo journalctl -u mediamtx -f"
    fi
}

# Uninstall MediaMTX
uninstall_mediamtx() {
    log_info "Uninstalling MediaMTX..."
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would uninstall MediaMTX"
        return 0
    fi
    
    # Stop and disable service
    if command -v systemctl &>/dev/null && [[ -f "${SERVICE_DIR}/${SERVICE_NAME}" ]]; then
        log_info "Stopping and disabling service..."
        systemctl stop mediamtx 2>/dev/null || true
        systemctl disable mediamtx 2>/dev/null || true
        rm -f "${SERVICE_DIR}/${SERVICE_NAME}"
        systemctl daemon-reload
    fi
    
    # Remove binary
    if [[ -f "${INSTALL_DIR}/mediamtx" ]]; then
        log_info "Removing binary..."
        rm -f "${INSTALL_DIR}/mediamtx"
        rm -f "${INSTALL_DIR}"/mediamtx.backup.* 2>/dev/null || true
    fi
    
    # Ask about config removal
    if [[ -d "${CONFIG_DIR}" ]] && [[ "${FORCE_MODE}" != "true" ]]; then
        echo -en "${YELLOW}Remove configuration directory ${CONFIG_DIR}? [y/N] ${NC}"
        read -r response
        if [[ "${response}" =~ ^[Yy]$ ]]; then
            rm -rf "${CONFIG_DIR}"
            log_info "Configuration removed"
        fi
    elif [[ "${FORCE_MODE}" == "true" ]] && [[ -d "${CONFIG_DIR}" ]]; then
        rm -rf "${CONFIG_DIR}"
        log_info "Configuration removed"
    fi
    
    # Remove user
    if id "${SERVICE_USER}" &>/dev/null && [[ "${FORCE_MODE}" == "true" ]]; then
        log_info "Removing service user..."
        userdel "${SERVICE_USER}" 2>/dev/null || true
        rm -rf /var/lib/mediamtx 2>/dev/null || true
    fi
    
    log_info "MediaMTX uninstalled successfully!"
}

# Show status with enhanced process detection
show_status() {
    echo -e "${BOLD}MediaMTX Installation Status${NC}"
    echo "================================"
    
    # Installation status
    if [[ -f "${INSTALL_DIR}/mediamtx" ]]; then
        echo -e "Installation: ${GREEN}✓ Installed${NC}"
        echo "Location: ${INSTALL_DIR}/mediamtx"
        
        # Version
        local installed_version="unknown"
        if "${INSTALL_DIR}/mediamtx" --version &>/dev/null; then
            installed_version=$("${INSTALL_DIR}/mediamtx" --version 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
            echo "Version: ${installed_version}"
        else
            echo "Version: ${installed_version}"
        fi
        
        # File info
        local file_size
        file_size=$(stat -c%s "${INSTALL_DIR}/mediamtx" 2>/dev/null || stat -f%z "${INSTALL_DIR}/mediamtx" 2>/dev/null || echo "unknown")
        echo "Binary size: ${file_size} bytes"
    else
        echo -e "Installation: ${RED}✗ Not installed${NC}"
    fi
    
    echo ""
    
    # Configuration
    if [[ -f "${CONFIG_DIR}/${CONFIG_NAME}" ]]; then
        echo -e "Configuration: ${GREEN}✓ Present${NC}"
        echo "Config file: ${CONFIG_DIR}/${CONFIG_NAME}"
    else
        echo -e "Configuration: ${YELLOW}⚠ Missing${NC}"
    fi
    
    echo ""
    
    # Enhanced service and process detection
    local process_running=false
    local systemd_running=false
    local process_pids=()
    local systemd_pid=""
    
    # Check for actual MediaMTX binary processes only (not scripts or this status command)
    if command -v pgrep &>/dev/null; then
        # Look specifically for the mediamtx binary, excluding scripts and this status check
        mapfile -t process_pids < <(pgrep -x "mediamtx" 2>/dev/null || true)
        
        # If that's too restrictive, look for the full path but exclude shell scripts
        if [[ ${#process_pids[@]} -eq 0 ]]; then
            local all_pids
            mapfile -t all_pids < <(pgrep -f "${INSTALL_DIR}/mediamtx" 2>/dev/null || true)
            for pid in "${all_pids[@]}"; do
                # Skip empty PIDs
                [[ -z "${pid}" ]] && continue
                # Skip if this is our own process or parent process
                if [[ "${pid}" != "$$" ]] && [[ "${pid}" != "$PPID" ]]; then
                    # Check if it's actually the mediamtx binary, not a script
                    if [[ -d "/proc/${pid}" ]]; then
                        local exe_path
                        exe_path=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || echo "")
                        if [[ "${exe_path}" == *"/mediamtx" ]] || [[ "${exe_path}" == "${INSTALL_DIR}/mediamtx" ]]; then
                            process_pids+=("${pid}")
                        fi
                    fi
                fi
            done
        fi
        
        if [[ ${#process_pids[@]} -gt 0 ]]; then
            process_running=true
        fi
    else
        # Fallback to ps if pgrep not available
        local mediamtx_procs
        mediamtx_procs=$(ps aux | grep -v grep | grep -E "^[^ ]+ +[0-9]+ .* ${INSTALL_DIR}/mediamtx" | grep -v "bash" | grep -v "${SCRIPT_NAME}" || echo "")
        if [[ -n "${mediamtx_procs}" ]]; then
            process_running=true
            process_pids=($(echo "${mediamtx_procs}" | awk '{print $2}'))
        fi
    fi
    
    # Check systemd service status
    local systemd_configured=false
    if command -v systemctl &>/dev/null && [[ -f "${SERVICE_DIR}/${SERVICE_NAME}" ]]; then
        systemd_configured=true
        if systemctl is-active --quiet mediamtx; then
            systemd_running=true
            systemd_pid=$(systemctl show mediamtx --property MainPID --value 2>/dev/null || echo "")
        fi
    fi
    
    # Report service configuration status
    if [[ "${systemd_configured}" == "true" ]]; then
        echo -e "Service: ${GREEN}✓ Configured${NC}"
    else
        echo -e "Service: ${YELLOW}⚠ Not configured${NC}"
    fi
    
    # Analyze and report process status
    if [[ "${process_running}" == "true" ]] && [[ "${systemd_running}" == "false" ]]; then
        # MediaMTX running outside systemd
        echo -e "Status: ${YELLOW}⚠ Running outside systemd${NC}"
        echo ""
        echo "Process Details:"
        
        # Only show details for the main MediaMTX process(es)
        for pid in "${process_pids[@]}"; do
            if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
                echo "  PID: ${pid}"
                
                # Get process details
                if command -v ps &>/dev/null; then
                    # Get command line
                    local cmd_line
                    cmd_line=$(ps -p "${pid}" -o args= 2>/dev/null || echo "unknown")
                    # Truncate very long command lines
                    if [[ ${#cmd_line} -gt 80 ]]; then
                        cmd_line="${cmd_line:0:77}..."
                    fi
                    echo "  Command: ${cmd_line}"
                    
                    # Get parent process
                    local parent_pid
                    parent_pid=$(ps -o ppid= -p "${pid}" 2>/dev/null | tr -d ' ' || echo "")
                    if [[ -n "${parent_pid}" ]] && [[ "${parent_pid}" != "1" ]]; then
                        local parent_cmd
                        parent_cmd=$(ps -p "${parent_pid}" -o comm= 2>/dev/null || echo "unknown")
                        echo "  Started by: ${parent_cmd} (PID: ${parent_pid})"
                    elif [[ "${parent_pid}" == "1" ]]; then
                        echo "  Started by: init/systemd at boot"
                    fi
                    
                    # Check scheduling class - YOUR SYSTEM SHOWS IT IN CLS COLUMN!
                    local scheduling_class
                    scheduling_class=$(ps -p "${pid}" -o cls= 2>/dev/null | tr -d ' ' || echo "")
                    if [[ "${scheduling_class}" == "RR" ]]; then
                        echo "  Scheduling: Real-time (SCHED_RR)"
                        echo -e "  ${CYAN}Note: Real-time scheduling indicates audio stream priority${NC}"
                    elif [[ "${scheduling_class}" == "FF" ]]; then
                        echo "  Scheduling: Real-time (SCHED_FIFO)"
                        echo -e "  ${CYAN}Note: Real-time scheduling indicates audio stream priority${NC}"
                    else
                        # Show normal priority
                        local priority
                        priority=$(ps -p "${pid}" -o pri= 2>/dev/null | tr -d ' ' || echo "")
                        if [[ -n "${priority}" ]]; then
                            echo "  Priority: ${priority} (normal)"
                        fi
                    fi
                    
                    # Get CPU and memory usage
                    local cpu_usage mem_usage
                    cpu_usage=$(ps -p "${pid}" -o %cpu= 2>/dev/null | tr -d ' ' || echo "")
                    mem_usage=$(ps -p "${pid}" -o %mem= 2>/dev/null | tr -d ' ' || echo "")
                    if [[ -n "${cpu_usage}" ]] && [[ -n "${mem_usage}" ]]; then
                        echo "  Resources: CPU ${cpu_usage}%, MEM ${mem_usage}%"
                    fi
                    
                    # Get uptime - THIS WORKS ON YOUR SYSTEM!
                    local etime
                    etime=$(ps -p "${pid}" -o etime= 2>/dev/null | tr -d ' ' || echo "")
                    if [[ -n "${etime}" ]]; then
                        echo "  Uptime: ${etime}"
                    fi
                fi
                
                # Only show details for first MediaMTX process
                break
            fi
        done
        
        echo ""
        
        # Check for FFmpeg streams and stream manager files
        local ffmpeg_count=0
        if command -v pgrep &>/dev/null; then
            ffmpeg_count=$(pgrep -c -f "ffmpeg.*rtsp://localhost" 2>/dev/null || echo "0")
        fi
        
        # Check for managed streams
        local managed_by_stream_manager=false
        local active_stream_names=()
        
        if [[ -d "/var/lib/mediamtx-ffmpeg" ]]; then
            for pid_file in /var/lib/mediamtx-ffmpeg/*.pid; do
                if [[ -f "${pid_file}" ]]; then
                    local stream_name
                    stream_name=$(basename "${pid_file}" .pid)
                    local stream_pid
                    stream_pid=$(cat "${pid_file}" 2>/dev/null || echo "0")
                    if kill -0 "${stream_pid}" 2>/dev/null; then
                        active_stream_names+=("${stream_name}")
                        managed_by_stream_manager=true
                    fi
                fi
            done
        fi
        
        # Check for audio config
        if [[ -f "/etc/mediamtx/audio-devices.conf" ]]; then
            managed_by_stream_manager=true
        fi
        
        # Display stream information
        if [[ "${ffmpeg_count}" -gt 0 ]] || [[ ${#active_stream_names[@]} -gt 0 ]]; then
            echo -e "${CYAN}Active Streams:${NC}"
            
            if [[ "${ffmpeg_count}" -gt 0 ]]; then
                echo "  FFmpeg processes: ${ffmpeg_count}"
            fi
            
            if [[ ${#active_stream_names[@]} -gt 0 ]]; then
                echo "  Managed streams: ${#active_stream_names[@]}"
                echo "  Stream names:"
                for stream in "${active_stream_names[@]}"; do
                    echo "    • ${stream}"
                done
            fi
            echo ""
        fi
        
        # Show management status
        if [[ "${managed_by_stream_manager}" == "true" ]]; then
            echo -e "${GREEN}Management: Controlled by MediaMTX Audio Stream Manager${NC}"
            echo "This is the expected configuration for your audio streaming setup."
            echo ""
            echo "Stream Manager Commands:"
            echo "  • Check status: sudo ./mediamtx-stream-manager.sh status"
            echo "  • Restart: sudo ./mediamtx-stream-manager.sh restart"
            echo "  • View logs: tail -f /var/lib/mediamtx-ffmpeg/*.log"
        else
            echo -e "${YELLOW}Warning: MediaMTX is running but not managed by systemd${NC}"
            echo ""
            echo "This could mean:"
            echo "  • Started manually from command line"
            echo "  • Started at boot via other mechanism"
            echo "  • Managed by a custom script"
            echo ""
            echo "To switch to systemd management:"
            echo "  1. Stop current instance: sudo pkill mediamtx"
            echo "  2. Start via systemd: sudo systemctl start mediamtx"
            echo "  3. Enable at boot: sudo systemctl enable mediamtx"
        fi
        
    elif [[ "${systemd_running}" == "true" ]]; then
        # MediaMTX running under systemd
        echo -e "Status: ${GREEN}● Running (systemd)${NC}"
        
        if [[ -n "${systemd_pid}" ]] && [[ "${systemd_pid}" != "0" ]]; then
            echo "PID: ${systemd_pid}"
            
            # Get systemd service details
            if command -v systemctl &>/dev/null; then
                # Uptime
                local active_since
                active_since=$(systemctl show mediamtx --property ActiveEnterTimestamp --value 2>/dev/null || echo "")
                if [[ -n "${active_since}" ]] && [[ "${active_since}" != "n/a" ]]; then
                    echo "Started: ${active_since}"
                    
                    # Calculate uptime if possible
                    if command -v date &>/dev/null; then
                        local start_epoch
                        start_epoch=$(date -d "${active_since}" +%s 2>/dev/null || echo "")
                        if [[ -n "${start_epoch}" ]]; then
                            local now_epoch
                            now_epoch=$(date +%s)
                            local uptime_seconds=$((now_epoch - start_epoch))
                            local days=$((uptime_seconds / 86400))
                            local hours=$(((uptime_seconds % 86400) / 3600))
                            local minutes=$(((uptime_seconds % 3600) / 60))
                            echo "Uptime: ${days}d ${hours}h ${minutes}m"
                        fi
                    fi
                fi
                
                # Memory usage
                local memory
                memory=$(systemctl show mediamtx --property MemoryCurrent --value 2>/dev/null || echo "")
                if [[ -n "${memory}" ]] && [[ "${memory}" != "[not set]" ]]; then
                    local memory_mb=$((memory / 1024 / 1024))
                    echo "Memory: ${memory_mb} MB"
                fi
                
                # Task count
                local tasks
                tasks=$(systemctl show mediamtx --property TasksCurrent --value 2>/dev/null || echo "")
                if [[ -n "${tasks}" ]] && [[ "${tasks}" != "[not set]" ]]; then
                    echo "Tasks: ${tasks}"
                fi
            fi
        fi
        
    elif [[ "${process_running}" == "false" ]]; then
        # Not running at all
        echo -e "Status: ${RED}○ Not running${NC}"
    fi
    
    # Check if service is enabled for auto-start
    if [[ "${systemd_configured}" == "true" ]]; then
        if systemctl is-enabled --quiet mediamtx 2>/dev/null; then
            echo -e "Auto-start: ${GREEN}Enabled${NC}"
        else
            echo -e "Auto-start: ${YELLOW}Disabled${NC}"
        fi
    fi
    
    echo ""
    
    # Check for port conflicts
    echo "Port Status:"
    
    # Check if we should use default ports or detect from config
    local rtsp_port="${DEFAULT_RTSP_PORT}"
    local api_port="${DEFAULT_API_PORT}"
    
    # Try to detect actual ports from config if available
    if [[ -f "${CONFIG_DIR}/${CONFIG_NAME}" ]]; then
        local config_rtsp_port
        local config_api_port
        config_rtsp_port=$(grep -E "^rtspAddress:" "${CONFIG_DIR}/${CONFIG_NAME}" 2>/dev/null | sed 's/.*:\([0-9]*\)$/\1/' || echo "")
        config_api_port=$(grep -E "^apiAddress:" "${CONFIG_DIR}/${CONFIG_NAME}" 2>/dev/null | sed 's/.*:\([0-9]*\)$/\1/' || echo "")
        
        [[ -n "${config_rtsp_port}" ]] && rtsp_port="${config_rtsp_port}"
        [[ -n "${config_api_port}" ]] && api_port="${config_api_port}"
    fi
    
    # Special case: Check common alternate ports if MediaMTX is running
    if [[ "${process_running}" == "true" ]] || [[ "${systemd_running}" == "true" ]]; then
        # Check if MediaMTX is actually listening on different ports
        if command -v lsof &>/dev/null; then
            # Check port 8554 (MediaMTX default RTSP)
            if lsof -i :8554 -sTCP:LISTEN 2>/dev/null | grep -q mediamtx; then
                rtsp_port="8554"
            # Check port 18554 (installer default)  
            elif lsof -i :18554 -sTCP:LISTEN 2>/dev/null | grep -q mediamtx; then
                rtsp_port="18554"
            fi
            
            # Check for API port
            if lsof -i :9997 -sTCP:LISTEN 2>/dev/null | grep -q mediamtx; then
                api_port="9997"
            fi
        fi
    fi
    
    local ports_to_check=("${rtsp_port}" "${api_port}" "${DEFAULT_METRICS_PORT}")
    local port_labels=("RTSP" "API" "Metrics")
    
    for i in "${!ports_to_check[@]}"; do
        local port="${ports_to_check[$i]}"
        local label="${port_labels[$i]}"
        
        if command -v lsof &>/dev/null; then
            local port_user
            port_user=$(lsof -i ":${port}" -sTCP:LISTEN 2>/dev/null | tail -n1 | awk '{print $1}' || echo "")
            if [[ -n "${port_user}" ]]; then
                if [[ "${port_user}" == "mediamtx" ]]; then
                    echo -e "  ${label} (${port}): ${GREEN}✓ In use by MediaMTX${NC}"
                else
                    echo -e "  ${label} (${port}): ${YELLOW}⚠ In use by ${port_user}${NC}"
                fi
            else
                echo -e "  ${label} (${port}): ${YELLOW}○ Not in use${NC}"
            fi
        elif command -v netstat &>/dev/null; then
            if netstat -tln 2>/dev/null | grep -q ":${port} "; then
                echo -e "  ${label} (${port}): ${GREEN}✓ In use${NC}"
            else
                echo -e "  ${label} (${port}): ${YELLOW}○ Not in use${NC}"
            fi
        fi
    done
    
    echo ""
    
    # Check for updates
    echo "Checking for updates..."
    local temp_status_dir="/tmp/mediamtx-status-$$"
    mkdir -p "${temp_status_dir}"
    TEMP_DIR="${temp_status_dir}"
    
    if get_release_info "latest" 2>/dev/null; then
        echo "Latest version: ${RELEASE_VERSION}"
        
        if [[ "${installed_version}" != "unknown" ]] && [[ "${installed_version}" != "${RELEASE_VERSION}" ]]; then
            echo -e "${YELLOW}Update available! Run '${SCRIPT_NAME} update' to upgrade${NC}"
            echo "  Current: ${installed_version}"
            echo "  Latest:  ${RELEASE_VERSION}"
        elif [[ "${installed_version}" == "${RELEASE_VERSION}" ]]; then
            echo -e "${GREEN}You are running the latest version${NC}"
        fi
    else
        echo "Could not check for updates"
    fi
    
    # Cleanup temp dir
    rm -rf "${temp_status_dir}" 2>/dev/null || true
    
    echo ""
    
    # Quick health check if running
    if [[ "${process_running}" == "true" ]] || [[ "${systemd_running}" == "true" ]]; then
        echo "Quick Health Check:"
        
        # Determine API port to use
        local api_port_to_check="${DEFAULT_API_PORT}"
        if [[ -f "${CONFIG_DIR}/${CONFIG_NAME}" ]]; then
            local config_api_port
            config_api_port=$(grep -E "^apiAddress:" "${CONFIG_DIR}/${CONFIG_NAME}" 2>/dev/null | sed 's/.*:\([0-9]*\)$/\1/' || echo "")
            [[ -n "${config_api_port}" ]] && api_port_to_check="${config_api_port}"
        fi
        
        # Check if API is responding
        if command -v curl &>/dev/null; then
            # Try multiple API endpoints for better detection
            local api_working=false
            
            # Try v3 paths endpoint first (most specific)
            if curl -s -f -m 2 "http://localhost:${api_port_to_check}/v3/paths/list" &>/dev/null; then
                echo -e "  API: ${GREEN}✓ Responding (v3 API)${NC}"
                api_working=true
            # Try v2 paths endpoint (older versions)
            elif curl -s -f -m 2 "http://localhost:${api_port_to_check}/v2/paths/list" &>/dev/null; then
                echo -e "  API: ${GREEN}✓ Responding (v2 API)${NC}"
                api_working=true
            # Try root endpoint as fallback
            elif curl -s -f -m 2 "http://localhost:${api_port_to_check}/" &>/dev/null; then
                echo -e "  API: ${GREEN}✓ Responding (root endpoint)${NC}"
                api_working=true
            else
                echo -e "  API: ${RED}✗ Not responding on port ${api_port_to_check}${NC}"
                # Suggest checking if using non-standard ports
                if [[ "${api_port_to_check}" != "9997" ]]; then
                    echo "       Note: Using non-standard API port ${api_port_to_check}"
                fi
            fi
            
            # If API is working, try to get stream count
            if [[ "${api_working}" == "true" ]]; then
                local stream_count
                stream_count=$(curl -s "http://localhost:${api_port_to_check}/v3/paths/list" 2>/dev/null | grep -o '"name"' | wc -l || echo "0")
                if [[ "${stream_count}" -gt 0 ]]; then
                    echo "  Active paths in API: ${stream_count}"
                fi
            fi
        fi
        
        # Check log file for recent errors
        local log_file="/var/log/mediamtx.log"
        if [[ -f "${log_file}" ]] && command -v tail &>/dev/null; then
            local recent_errors
            recent_errors=$(tail -100 "${log_file}" 2>/dev/null | grep -c -i "error" || echo "0")
            # Ensure we have a valid number - strip all non-digits
            recent_errors="${recent_errors//[^0-9]/}"
            # Default to 0 if empty
            [[ -z "${recent_errors}" ]] && recent_errors="0"
            
            if [[ "${recent_errors}" -gt 0 ]] 2>/dev/null; then
                echo -e "  Recent errors: ${YELLOW}${recent_errors} error(s) in last 100 log lines${NC}"
                
                # Show last error for context
                local last_error
                last_error=$(tail -100 "${log_file}" 2>/dev/null | grep -i "error" | tail -1 | cut -c1-80 || echo "")
                if [[ -n "${last_error}" ]]; then
                    echo "  Last error: ${last_error}..."
                fi
            else
                echo -e "  Recent errors: ${GREEN}None${NC}"
            fi
        else
            echo "  Log file: Not found or inaccessible"
        fi
    fi
    
    # Summary and recommendations
    echo ""
    echo "================================"
    
    # Check if managed by stream manager (using the flag set earlier)
    local is_stream_managed=false
    if [[ -d "/var/lib/mediamtx-ffmpeg" ]] && [[ -f "/etc/mediamtx/audio-devices.conf" ]]; then
        is_stream_managed=true
    fi
    
    if [[ "${process_running}" == "true" ]] && [[ "${systemd_running}" == "false" ]]; then
        if [[ "${is_stream_managed}" == "true" ]]; then
            echo -e "${GREEN}Summary: MediaMTX is running under Audio Stream Manager control${NC}"
            echo "This is the correct configuration for your audio streaming setup."
            echo ""
            echo "Quick Commands:"
            echo "  • Check streams: sudo ./mediamtx-stream-manager.sh status"
            echo "  • Restart streams: sudo ./mediamtx-stream-manager.sh restart"
            echo "  • View stream logs: tail -f /var/lib/mediamtx-ffmpeg/*.log"
        else
            echo -e "${YELLOW}Summary: MediaMTX is running but not under systemd control${NC}"
            echo "Consider using either systemd or mediamtx-stream-manager.sh for management."
        fi
    elif [[ "${systemd_running}" == "true" ]]; then
        echo -e "${GREEN}Summary: MediaMTX is properly managed by systemd${NC}"
        echo ""
        echo "Quick Commands:"
        echo "  • View logs: sudo journalctl -u mediamtx -f"
        echo "  • Restart: sudo systemctl restart mediamtx"
    elif [[ "${process_running}" == "false" ]]; then
        echo -e "${RED}Summary: MediaMTX is not running${NC}"
        if [[ -f "${INSTALL_DIR}/mediamtx" ]]; then
            echo ""
            echo "To start MediaMTX:"
            echo "  • With systemd: sudo systemctl start mediamtx"
            echo "  • With stream manager: sudo ./mediamtx-stream-manager.sh start"
            echo "  • Manually: ${INSTALL_DIR}/mediamtx ${CONFIG_DIR}/${CONFIG_NAME}"
        fi
    fi
}

# Verify installation integrity
verify_installation() {
    log_info "Verifying installation..."
    
    local errors=0
    local warnings=0
    
    # Check binary
    if [[ ! -f "${INSTALL_DIR}/mediamtx" ]]; then
        log_error "Binary not found: ${INSTALL_DIR}/mediamtx"
        ((errors++))
    elif [[ ! -x "${INSTALL_DIR}/mediamtx" ]]; then
        log_error "Binary not executable: ${INSTALL_DIR}/mediamtx"
        ((errors++))
    elif ! "${INSTALL_DIR}/mediamtx" --version &>/dev/null; then
        log_error "Binary verification failed"
        ((errors++))
    else
        log_info "Binary: OK"
    fi
    
    # Check configuration
    if [[ ! -f "${CONFIG_DIR}/${CONFIG_NAME}" ]]; then
        log_warn "Configuration not found: ${CONFIG_DIR}/${CONFIG_NAME}"
        ((warnings++))
    else
        log_info "Configuration: OK"
    fi
    
    # Check service
    if command -v systemctl &>/dev/null; then
        if [[ ! -f "${SERVICE_DIR}/${SERVICE_NAME}" ]]; then
            log_warn "Service not configured"
            ((warnings++))
        elif ! systemctl is-enabled mediamtx &>/dev/null; then
            log_warn "Service not enabled"
            ((warnings++))
        else
            log_info "Service: OK"
        fi
    fi
    
    # Check user
    if ! id "${SERVICE_USER}" &>/dev/null; then
        log_warn "Service user not found: ${SERVICE_USER}"
        ((warnings++))
    else
        log_info "Service user: OK"
    fi
    
    # Check for running processes
    local process_pids=()
    if command -v pgrep &>/dev/null; then
        # Look specifically for the mediamtx binary
        mapfile -t process_pids < <(pgrep -x "mediamtx" 2>/dev/null || true)
        
        # If that's too restrictive, check the full path
        if [[ ${#process_pids[@]} -eq 0 ]]; then
            local all_pids
            mapfile -t all_pids < <(pgrep -f "${INSTALL_DIR}/mediamtx" 2>/dev/null || true)
            for pid in "${all_pids[@]}"; do
                # Skip empty PIDs
                [[ -z "${pid}" ]] && continue
                # Check if it's actually the mediamtx binary
                if [[ -d "/proc/${pid}" ]]; then
                    local exe_path
                    exe_path=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || echo "")
                    if [[ "${exe_path}" == *"/mediamtx" ]]; then
                        process_pids+=("${pid}")
                    fi
                fi
            done
        fi
    fi
    
    if [[ ${#process_pids[@]} -gt 0 ]]; then
        local systemd_running=false
        if command -v systemctl &>/dev/null && systemctl is-active --quiet mediamtx; then
            systemd_running=true
        fi
        
        if [[ "${systemd_running}" == "false" ]]; then
            log_warn "MediaMTX is running outside of systemd control (PID: ${process_pids[0]})"
            ((warnings++))
        else
            log_info "Process: Running under systemd"
        fi
    else
        log_info "Process: Not running"
    fi
    
    # Check port availability
    local port_conflicts=false
    
    # Try to detect actual ports from config
    local rtsp_port="${DEFAULT_RTSP_PORT}"
    local api_port="${DEFAULT_API_PORT}"
    
    if [[ -f "${CONFIG_DIR}/${CONFIG_NAME}" ]]; then
        local config_rtsp_port
        local config_api_port
        config_rtsp_port=$(grep -E "^rtspAddress:" "${CONFIG_DIR}/${CONFIG_NAME}" 2>/dev/null | sed 's/.*:\([0-9]*\)$/\1/' || echo "")
        config_api_port=$(grep -E "^apiAddress:" "${CONFIG_DIR}/${CONFIG_NAME}" 2>/dev/null | sed 's/.*:\([0-9]*\)$/\1/' || echo "")
        
        [[ -n "${config_rtsp_port}" ]] && rtsp_port="${config_rtsp_port}"
        [[ -n "${config_api_port}" ]] && api_port="${config_api_port}"
    fi
    
    for port in "${rtsp_port}" "${api_port}" "${DEFAULT_METRICS_PORT}"; do
        if command -v lsof &>/dev/null; then
            local port_user
            port_user=$(lsof -i ":${port}" -sTCP:LISTEN 2>/dev/null | tail -n1 | awk '{print $1}' || echo "")
            if [[ -n "${port_user}" ]] && [[ "${port_user}" != "mediamtx" ]]; then
                log_warn "Port ${port} is in use by: ${port_user}"
                port_conflicts=true
                ((warnings++))
            fi
        fi
    done
    
    if [[ "${port_conflicts}" == "false" ]]; then
        log_info "Ports: Available or in use by MediaMTX"
    fi
    
    # Summary
    echo ""
    if [[ ${errors} -eq 0 ]] && [[ ${warnings} -eq 0 ]]; then
        log_info "✓ Installation verified successfully - no issues found"
        return 0
    elif [[ ${errors} -eq 0 ]]; then
        log_warn "Installation verified with ${warnings} warning(s)"
        return 0
    else
        log_error "Installation verification failed with ${errors} error(s) and ${warnings} warning(s)"
        return 1
    fi
}

# ============================================================================
# Help and Usage
# ============================================================================

show_help() {
    cat << EOF
${BOLD}MediaMTX Installation Manager v${SCRIPT_VERSION}${NC}

Production-ready installer for MediaMTX media server with comprehensive
error handling, validation, and security features.

Enhanced with intelligent management mode detection for seamless updates
of MediaMTX instances managed by systemd, stream-manager, or running manually.

${BOLD}USAGE:${NC}
    ${SCRIPT_NAME} [OPTIONS] COMMAND

${BOLD}COMMANDS:${NC}
    install     Install MediaMTX
    update      Update to latest version
    uninstall   Remove MediaMTX
    status      Show installation status
    verify      Verify installation integrity
    help        Show this help message

${BOLD}OPTIONS:${NC}
    -c, --config FILE      Use configuration file
    -v, --verbose         Enable verbose output
    -q, --quiet          Suppress non-error output
    -n, --dry-run        Show what would be done
    -f, --force          Force operation (skip confirmations)
    -V, --version VER    Install specific version
    -p, --prefix DIR     Installation prefix (default: ${DEFAULT_INSTALL_PREFIX})
    --no-service         Skip systemd service creation
    --no-config          Skip configuration file creation
    --verify-gpg         Verify GPG signatures

${BOLD}ENVIRONMENT VARIABLES:${NC}
    MEDIAMTX_PREFIX       Installation prefix
    MEDIAMTX_CONFIG_DIR   Configuration directory
    MEDIAMTX_USER         Service user name
    MEDIAMTX_GROUP        Service group name
    MEDIAMTX_RTSP_PORT    RTSP server port
    MEDIAMTX_API_PORT     API server port
    MEDIAMTX_METRICS_PORT Metrics server port

${BOLD}EXAMPLES:${NC}
    # Standard installation
    sudo ${SCRIPT_NAME} install

    # Install specific version
    sudo ${SCRIPT_NAME} -V v1.12.0 install

    # Update with verbose output
    sudo ${SCRIPT_NAME} -v update

    # Dry run to see what would happen
    sudo ${SCRIPT_NAME} -n install

    # Custom installation prefix
    sudo ${SCRIPT_NAME} -p /opt/mediamtx install

    # Force reinstall
    sudo ${SCRIPT_NAME} -f install

${BOLD}FILES:${NC}
    Binary:       ${INSTALL_DIR}/mediamtx
    Config:       ${CONFIG_DIR}/${CONFIG_NAME}
    Service:      ${SERVICE_DIR}/${SERVICE_NAME}
    Logs:         /var/log/mediamtx.log

${BOLD}SERVICE MANAGEMENT:${NC}
    Start:        sudo systemctl start mediamtx
    Stop:         sudo systemctl stop mediamtx
    Restart:      sudo systemctl restart mediamtx
    Status:       sudo systemctl status mediamtx
    Enable:       sudo systemctl enable mediamtx
    Disable:      sudo systemctl disable mediamtx
    Logs:         sudo journalctl -u mediamtx -f

${BOLD}ENHANCED FEATURES IN v5.2.0:${NC}
    - Automatic detection of management mode during updates
    - Preserves stream manager configuration and active streams
    - Intelligent stop/start based on current management
    - Stream manager integration for audio streaming setups
    - Real-time scheduling detection for audio applications
    - Comprehensive health checks with multiple API endpoints

${BOLD}NOTES:${NC}
    - Requires root/sudo for installation
    - Automatically handles ARM64 naming variations
    - Creates secure systemd service with hardening
    - Supports configuration backup and rollback
    - Enhanced detection for stream-manager controlled instances
    - Shows active audio streams when managed by stream manager
    - Detects real-time scheduling for audio applications

${BOLD}SUPPORT:${NC}
    GitHub: https://github.com/${DEFAULT_GITHUB_REPO}
    Version: ${SCRIPT_VERSION}
    
EOF
}

# ============================================================================
# Main Logic
# ============================================================================

# Parse command line arguments
parse_arguments() {
    local args=()
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE_MODE=true
                shift
                ;;
            -q|--quiet)
                QUIET_MODE=true
                shift
                ;;
            -n|--dry-run)
                DRY_RUN_MODE=true
                shift
                ;;
            -f|--force)
                FORCE_MODE=true
                shift
                ;;
            -V|--version)
                TARGET_VERSION="$2"
                shift 2
                ;;
            -p|--prefix)
                INSTALL_PREFIX="$2"
                INSTALL_DIR="${INSTALL_PREFIX}/bin"
                shift 2
                ;;
            --no-service)
                SKIP_SERVICE=true
                shift
                ;;
            --no-config)
                SKIP_CONFIG=true
                shift
                ;;
            --verify-gpg)
                VERIFY_GPG=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                fatal "Unknown option: $1" 1
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done
    
    # Set command
    readonly COMMAND="${args[0]:-}"
    
    # Validate command
    case "${COMMAND}" in
        install|update|uninstall|status|verify|help)
            ;;
        "")
            show_help
            exit 0
            ;;
        *)
            fatal "Unknown command: ${COMMAND}" 1
            ;;
    esac
}

# Load configuration file
load_config() {
    if [[ -n "${CONFIG_FILE}" ]] && [[ -f "${CONFIG_FILE}" ]]; then
        log_debug "Loading configuration from: ${CONFIG_FILE}"
        # shellcheck source=/dev/null
        source "${CONFIG_FILE}"
    fi
}

# Main function
main() {
    # Parse arguments first
    parse_arguments "$@"
    
    # Create temp directory early for logging
    create_temp_dir
    
    # Load configuration
    load_config
    
    # Check if help command
    if [[ "${COMMAND}" == "help" ]]; then
        show_help
        exit 0
    fi
    
    # Check root for operations requiring it
    if [[ "${COMMAND}" != "status" ]] && [[ "${DRY_RUN_MODE}" != "true" ]]; then
        if [[ ${EUID} -ne 0 ]]; then
            fatal "This operation requires root privileges. Please run with sudo." 2
        fi
    fi
    
    # Acquire lock for modifying operations
    if [[ "${COMMAND}" =~ ^(install|update|uninstall)$ ]]; then
        acquire_lock
    fi
    
    # Check requirements
    check_requirements
    
    # Detect platform
    detect_platform
    
    # Execute command
    case "${COMMAND}" in
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
        verify)
            verify_installation
            ;;
    esac
    
    log_debug "Operation completed successfully"
}

# Run main function
main "$@"

#!/usr/bin/env bash
#
# MediaMTX Installation Manager - Production-Ready Install/Update/Uninstall
# Version: 1.1.1
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# This script provides a robust, secure, and configurable installation manager
# for MediaMTX with comprehensive error handling and validation.
#
# Critical Fixes in v1.1.1:
#   - Fixed lock mechanism: proper FD handling without subshells
#   - Fixed rollback system: null-delimited storage for space handling
#   - Complete SemVer version comparison with pre-release support
#   - Fixed dry-run mode violations in uninstall
#   - Updated log configuration for systemd journal
#   - Improved JSON parsing fallbacks
#   - Commented systemd capabilities with explanation
#   - Fixed dry-run mode to allow metadata downloads (read-only operations)
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
set -o functrace  # Keep for debugging value

# Script metadata
readonly SCRIPT_VERSION="1.1.1"
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
LOCK_FD=""

# GitHub API configuration
readonly GITHUB_API_BASE="https://api.github.com"
readonly GITHUB_API_TIMEOUT=30
readonly USER_AGENT="MediaMTX-Installer/${SCRIPT_VERSION}"

# Color codes (will be set after argument parsing)
RED=''
GREEN=''
YELLOW=''
BLUE=''
MAGENTA=''
CYAN=''
BOLD=''
NC=''

# Arrays for cleanup tracking
declare -a CLEANUP_FILES=()
declare -a CLEANUP_DIRS=()

# Rollback registry - safer than eval
declare -A ROLLBACK_REGISTRY=(
    ["mv"]="rollback_mv"
    ["rm"]="rollback_rm"
    ["systemctl"]="rollback_systemctl"
    ["userdel"]="rollback_userdel"
)

# Rollback action queue file
ROLLBACK_QUEUE=""

# Download command (set in check_requirements)
DOWNLOAD_CMD=""

# Release information (set by get_release_info)
RELEASE_VERSION=""
RELEASE_FILE=""

# Platform information (set by detect_platform)
PLATFORM_OS=""
PLATFORM_ARCH=""
PLATFORM_DISTRO=""
PLATFORM_VERSION=""

# ============================================================================
# Rollback Functions (Security Hardened with Space Handling)
# ============================================================================

rollback_mv() {
    local src="$1"
    local dst="$2"
    mv "${src}" "${dst}" 2>/dev/null || true
}

rollback_rm() {
    rm -f "$@" 2>/dev/null || true
}

rollback_systemctl() {
    systemctl "$@" 2>/dev/null || true
}

rollback_userdel() {
    userdel "$@" 2>/dev/null || true
}

# Add rollback action with null-delimited storage for space handling
add_rollback() {
    local cmd="$1"
    shift
    
    if [[ -n "${ROLLBACK_REGISTRY[$cmd]:-}" ]]; then
        # Store command and arguments with null delimiters
        if [[ -n "${ROLLBACK_QUEUE}" ]] && [[ -f "${ROLLBACK_QUEUE}" ]]; then
            printf '%s\0' "${cmd}" "$@" >> "${ROLLBACK_QUEUE}"
        fi
    else
        log_warn "Invalid rollback command: ${cmd}"
    fi
}

# Execute rollback with proper space handling
execute_rollback() {
    [[ -z "${ROLLBACK_QUEUE}" ]] || [[ ! -f "${ROLLBACK_QUEUE}" ]] && return 0
    
    # Read null-delimited entries
    local entries=()
    while IFS= read -r -d '' entry; do
        entries+=("${entry}")
    done < "${ROLLBACK_QUEUE}"
    
    # Process in reverse order
    local i=${#entries[@]}
    while [[ $i -gt 0 ]]; do
        ((i--))
        local cmd="${entries[$i]}"
        local args=()
        
        # Collect arguments for this command
        while [[ $i -gt 0 ]]; do
            ((i--))
            local next="${entries[$i]}"
            # Check if this is a command or an argument
            if [[ -n "${ROLLBACK_REGISTRY[$next]:-}" ]]; then
                # This is the next command, put it back
                ((i++))
                break
            fi
            args=("${next}" "${args[@]}")  # Prepend to maintain order
        done
        
        # Execute rollback
        if [[ -n "${ROLLBACK_REGISTRY[$cmd]:-}" ]]; then
            "${ROLLBACK_REGISTRY[$cmd]}" "${args[@]}"
        fi
    done
}

# ============================================================================
# Utility Functions
# ============================================================================

# Initialize runtime variables after argument parsing
initialize_runtime_vars() {
    # Set color codes based on terminal and quiet mode
    if [[ -t 1 ]] && [[ "${QUIET_MODE}" != "true" ]]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        MAGENTA='\033[0;35m'
        CYAN='\033[0;36m'
        BOLD='\033[1m'
        NC='\033[0m'
    else
        RED=''
        GREEN=''
        YELLOW=''
        BLUE=''
        MAGENTA=''
        CYAN=''
        BOLD=''
        NC=''
    fi
}

# Enhanced error handler with stack trace
error_handler() {
    local code=$1
    local line_no=$2
    local bash_command=$3
    
    if [[ "${code}" -ne 0 ]]; then
        log_error "Command failed with exit code ${code}"
        log_error "Failed command: ${bash_command}"
        log_error "Line ${line_no} in function ${FUNCNAME[1]:-main}"
        
        if [[ "${VERBOSE_MODE}" == "true" ]]; then
            log_debug "Stack trace:"
            for ((i=1; i<${#FUNCNAME[@]}; i++)); do
                log_debug "  ${i}: ${FUNCNAME[$i]}() at line ${BASH_LINENO[$((i-1))]}"
            done
        fi
    fi
}

trap 'error_handler $? ${LINENO} "${BASH_COMMAND}"' ERR

# Comprehensive cleanup handler
cleanup() {
    local exit_code=$?
    
    # Release lock if held
    release_lock
    
    # Execute rollback actions if failed
    if [[ ${exit_code} -ne 0 ]]; then
        log_warn "Executing rollback actions..."
        execute_rollback
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
    [[ -n "${LOG_FILE}" ]] && [[ -f "${LOG_FILE}" ]] && echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
    [[ "${QUIET_MODE}" != "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $*" >&2
}

log_info() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
    [[ -n "${LOG_FILE}" ]] && [[ -f "${LOG_FILE}" ]] && echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
    [[ "${QUIET_MODE}" != "true" ]] && echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*"
    [[ -n "${LOG_FILE}" ]] && [[ -f "${LOG_FILE}" ]] && echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*"
    [[ -n "${LOG_FILE}" ]] && [[ -f "${LOG_FILE}" ]] && echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
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
# Security Functions
# ============================================================================

# FIXED: Atomic lock acquisition with proper FD handling
acquire_lock() {
    local timeout="${1:-30}"
    
    # Open lock file descriptor without subshell
    exec 200>"${LOCK_FILE}"
    LOCK_FD=200
    
    log_debug "Attempting to acquire lock (timeout: ${timeout}s)..."
    
    # Platform-specific lock acquisition
    if [[ "$(uname)" == "Darwin" ]] || [[ "$(uname)" == *"BSD"* ]]; then
        # BSD flock: use timeout wrapper
        if command -v timeout &>/dev/null; then
            if timeout "${timeout}" flock -x 200; then
                echo "${SCRIPT_PID}" > "${LOCK_FILE}.pid"
                log_debug "Lock acquired (PID: ${SCRIPT_PID})"
                return 0
            fi
        else
            # Fallback without timeout command
            if flock -x 200; then
                echo "${SCRIPT_PID}" > "${LOCK_FILE}.pid"
                log_debug "Lock acquired (PID: ${SCRIPT_PID})"
                return 0
            fi
        fi
    else
        # Linux flock: -w is timeout in seconds
        if flock -x -w "${timeout}" 200; then
            echo "${SCRIPT_PID}" > "${LOCK_FILE}.pid"
            log_debug "Lock acquired (PID: ${SCRIPT_PID})"
            return 0
        fi
    fi
    
    # Clean up on failure
    exec 200>&-
    LOCK_FD=""
    fatal "Failed to acquire lock after ${timeout} seconds" 1
}

# Release lock
release_lock() {
    if [[ -n "${LOCK_FD}" ]]; then
        flock -u "${LOCK_FD}" 2>/dev/null || true
        exec 200>&- 2>/dev/null || true
        rm -f "${LOCK_FILE}.pid" 2>/dev/null || true
        LOCK_FD=""
        log_debug "Lock released"
    fi
}

# Create secure temporary directory
create_temp_dir() {
    # Require mktemp for security
    if ! command -v mktemp &>/dev/null; then
        fatal "mktemp is required but not found. Please install coreutils." 4
    fi
    
    TEMP_DIR=$(mktemp -d "${TEMP_BASE}/mediamtx-installer-XXXXXX")
    
    if [[ ! -d "${TEMP_DIR}" ]]; then
        fatal "Failed to create temporary directory" 1
    fi
    
    # Create log file in temp directory
    LOG_FILE="${TEMP_DIR}/install.log"
    touch "${LOG_FILE}"
    chmod 600 "${LOG_FILE}"
    
    # Create rollback queue file
    ROLLBACK_QUEUE="${TEMP_DIR}/.rollback_queue"
    touch "${ROLLBACK_QUEUE}"
    chmod 600 "${ROLLBACK_QUEUE}"
    
    CLEANUP_DIRS+=("${TEMP_DIR}")
    log_debug "Created temporary directory: ${TEMP_DIR}"
}

# Safe configuration loading without source/eval
load_config() {
    [[ -z "${CONFIG_FILE}" || ! -f "${CONFIG_FILE}" ]] && return 0
    
    log_debug "Loading configuration from: ${CONFIG_FILE}"
    
    # Parse as key=value pairs, NOT as shell script
    while IFS='=' read -r key value || [[ -n "${key}" ]]; do
        # Skip comments and empty lines
        [[ -z "${key}" || "${key}" == \#* ]] && continue
        
        # Trim whitespace
        key=$(echo "${key}" | xargs)
        value=$(echo "${value}" | xargs)
        
        # Remove quotes
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"
        
        # Whitelist allowed configuration keys and validate values
        case "${key}" in
            INSTALL_PREFIX)
                if [[ "${value}" == /* ]]; then
                    INSTALL_PREFIX="${value}"
                    INSTALL_DIR="${INSTALL_PREFIX}/bin"
                else
                    log_warn "Invalid INSTALL_PREFIX in config (must be absolute path): ${value}"
                fi
                ;;
            CONFIG_DIR)
                if [[ "${value}" == /* ]]; then
                    CONFIG_DIR="${value}"
                else
                    log_warn "Invalid CONFIG_DIR in config (must be absolute path): ${value}"
                fi
                ;;
            SERVICE_USER)
                if [[ "${value}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                    SERVICE_USER="${value}"
                else
                    log_warn "Invalid SERVICE_USER in config: ${value}"
                fi
                ;;
            SERVICE_GROUP)
                if [[ "${value}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                    SERVICE_GROUP="${value}"
                else
                    log_warn "Invalid SERVICE_GROUP in config: ${value}"
                fi
                ;;
            *)
                log_warn "Ignoring unknown config key: ${key}"
                ;;
        esac
    done < "${CONFIG_FILE}"
}

# ============================================================================
# Validation Functions
# ============================================================================

# Validate input parameters
validate_input() {
    # Validate installation prefix
    if [[ "${INSTALL_PREFIX}" != /* ]]; then
        fatal "Installation prefix must be an absolute path" 10
    fi
    
    if [[ "${INSTALL_PREFIX}" == *..* ]]; then
        fatal "Installation prefix cannot contain .." 10
    fi
    
    # Validate version if specified
    if [[ -n "${TARGET_VERSION}" ]]; then
        if ! validate_version "${TARGET_VERSION}"; then
            fatal "Invalid version format: ${TARGET_VERSION}" 10
        fi
    fi
    
    # Validate config file if specified
    if [[ -n "${CONFIG_FILE}" ]]; then
        if [[ ! -f "${CONFIG_FILE}" ]]; then
            fatal "Config file not found: ${CONFIG_FILE}" 9
        fi
        if [[ ! -r "${CONFIG_FILE}" ]]; then
            fatal "Config file not readable: ${CONFIG_FILE}" 9
        fi
    fi
}

# Validate required commands with version checking
check_requirements() {
    local missing=()
    local warnings=()
    
    # Required commands with minimum versions
    local -A required_commands=(
        ["bash"]="4.0"
        ["curl"]="7.0"
        ["tar"]="1.20"
        ["mktemp"]=""
        ["flock"]=""
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
    
    # Warn if jq not found (improves JSON parsing)
    if ! command -v jq &>/dev/null; then
        log_warn "jq not found - using fallback JSON parsing (less reliable)"
    fi
    
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
        DOWNLOAD_CMD="curl"
    elif command -v wget &>/dev/null; then
        DOWNLOAD_CMD="wget"
    else
        fatal "Neither curl nor wget found" 4
    fi
    
    log_debug "Using ${DOWNLOAD_CMD} for downloads"
}

# FIXED: Complete SemVer version comparison with pre-release support
version_compare() {
    local v1="${1#v}"  # Remove v prefix if present
    local v2="${2#v}"
    
    # Try sort -V first (most reliable)
    if command -v sort &>/dev/null && sort --help 2>&1 | grep -q -- '-V'; then
        if [[ "$(printf '%s\n' "${v2}" "${v1}" | sort -V | head -n1)" == "${v2}" ]]; then
            return 0  # v1 >= v2
        else
            return 1
        fi
    fi
    
    # Robust fallback implementation
    local v1_base="${v1%%-*}"
    local v2_base="${v2%%-*}"
    
    # Compare numeric components
    local IFS=.
    local -a v1_parts=($v1_base)
    local -a v2_parts=($v2_base)
    
    for i in {0..2}; do
        local p1="${v1_parts[$i]:-0}"
        local p2="${v2_parts[$i]:-0}"
        
        if [[ ${p1} -gt ${p2} ]]; then return 0; fi
        if [[ ${p1} -lt ${p2} ]]; then return 1; fi
    done
    
    # Base versions equal, check pre-release
    # No pre-release > has pre-release (1.0.0 > 1.0.0-rc1)
    if [[ "$v1" == "$v1_base" ]] && [[ "$v2" != "$v2_base" ]]; then
        return 0  # v1 (final) > v2 (pre-release)
    elif [[ "$v1" != "$v1_base" ]] && [[ "$v2" == "$v2_base" ]]; then
        return 1  # v1 (pre-release) < v2 (final)
    elif [[ "$v1" != "$v1_base" ]] && [[ "$v2" != "$v2_base" ]]; then
        # Both have pre-release, compare lexically
        local v1_pre="${v1#*-}"
        local v2_pre="${v2#*-}"
        [[ "$v1_pre" > "$v2_pre" ]] && return 0 || return 1
    fi
    
    return 0  # Equal
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
                # shellcheck source=/dev/null
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
    PLATFORM_OS="${os}"
    PLATFORM_ARCH="${arch}"
    PLATFORM_DISTRO="${distro}"
    PLATFORM_VERSION="${version}"
    
    log_debug "Platform: ${PLATFORM_OS}/${PLATFORM_ARCH} (${PLATFORM_DISTRO} ${PLATFORM_VERSION})"
}

# ============================================================================
# Download Functions
# ============================================================================

# Enhanced download with retry, resume, and failover - FIXED for dry-run mode
download_file() {
    local url="$1"
    local output="$2"
    local timeout="${3:-${DEFAULT_DOWNLOAD_TIMEOUT}}"
    local retries="${4:-${DEFAULT_DOWNLOAD_RETRIES}}"
    
    # Determine if this is a metadata download (should be allowed in dry-run)
    local is_metadata=false
    if [[ "${url}" == *"api.github.com"* ]] || \
       [[ "${url}" == *".sha256sum" ]] || \
       [[ "${url}" == *".sig" ]] || \
       [[ "${output}" == *"/release.json" ]] || \
       [[ "${output}" == *"/checksum"* ]]; then
        is_metadata=true
    fi
    
    # Only skip non-metadata downloads in dry-run mode
    if [[ "${DRY_RUN_MODE}" == "true" ]] && [[ "${is_metadata}" == "false" ]]; then
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

# IMPROVED: Parse GitHub API response with better fallback
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
    
    # Improved grep/sed fallback for minified JSON
    local value=""
    
    # Handle minified JSON better
    if grep -q "\"${field}\"" "${json_file}" 2>/dev/null; then
        # Try to extract value even from minified JSON
        value=$(sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${json_file}" 2>/dev/null | head -1)
    fi
    
    echo "${value}"
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
    
    RELEASE_VERSION="${tag_name}"
    RELEASE_FILE="${release_file}"
    
    log_info "Found release: ${RELEASE_VERSION}"
}

# ============================================================================
# Common Detection Functions (Extracted for Reuse)
# ============================================================================

# Centralized process detection
detect_mediamtx_process() {
    local pids=()
    
    if command -v pgrep &>/dev/null; then
        mapfile -t pids < <(pgrep -x "mediamtx" 2>/dev/null || true)
        
        # If that's too restrictive, check the full path
        if [[ ${#pids[@]} -eq 0 ]]; then
            local all_pids
            mapfile -t all_pids < <(pgrep -f "${INSTALL_DIR}/mediamtx" 2>/dev/null || true)
            for pid in "${all_pids[@]}"; do
                [[ -z "${pid}" ]] && continue
                # Skip our own process
                if [[ "${pid}" != "$$" ]] && [[ "${pid}" != "$PPID" ]]; then
                    # Check if it's actually the mediamtx binary
                    if [[ -d "/proc/${pid}" ]]; then
                        local exe_path
                        exe_path=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || echo "")
                        if [[ "${exe_path}" == *"/mediamtx" ]]; then
                            pids+=("${pid}")
                        fi
                    fi
                fi
            done
        fi
    fi
    
    printf "%s\n" "${pids[@]}"
}

# FIXED: Centralized management mode detection
detect_management_mode() {
    # Check systemd first
    if command -v systemctl &>/dev/null && systemctl is-active --quiet mediamtx 2>/dev/null; then
        echo "systemd"
    # Check stream manager
    elif [[ -d "/var/lib/mediamtx-ffmpeg" ]] && pgrep -f "ffmpeg.*rtsp://localhost" &>/dev/null; then
        echo "stream-manager"
    # Check manual process
    elif pgrep -x "mediamtx" &>/dev/null; then
        echo "manual"
    else
        echo "none"
    fi
}

# Get active stream names from stream manager
get_active_streams() {
    local streams=()
    
    if [[ -d "/var/lib/mediamtx-ffmpeg" ]]; then
        for pid_file in /var/lib/mediamtx-ffmpeg/*.pid; do
            if [[ -f "${pid_file}" ]]; then
                local stream_name
                stream_name=$(basename "${pid_file}" .pid)
                local stream_pid
                stream_pid=$(cat "${pid_file}" 2>/dev/null || echo "0")
                if kill -0 "${stream_pid}" 2>/dev/null; then
                    streams+=("${stream_name}")
                fi
            fi
        done
    fi
    
    printf "%s\n" "${streams[@]}"
}

# Find stream manager script
find_stream_manager() {
    local locations=(
        "./mediamtx-stream-manager.sh"
        "${SCRIPT_DIR}/mediamtx-stream-manager.sh"
        "/usr/local/bin/mediamtx-stream-manager.sh"
    )
    
    for location in "${locations[@]}"; do
        if [[ -f "${location}" ]] && [[ -x "${location}" ]]; then
            echo "${location}"
            return 0
        fi
    done
    
    return 1
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
        local version_num=$((major * 10000 + minor * 100 + ${patch%%-*}))
        
        if [[ ${version_num} -lt 11201 ]]; then  # v1.12.1
            arch_suffix="arm64v8"
        fi
    fi
    
    # Build filename
    local filename="mediamtx_v${version}_${os}_${arch_suffix}.tar.gz"
    local url="https://github.com/${DEFAULT_GITHUB_REPO}/releases/download/v${version}/${filename}"
    
    echo "${url}"
}

# Download and verify MediaMTX binary - FIXED for dry-run mode
download_mediamtx() {
    local version="$1"
    local os="$2"
    local arch="$3"
    
    local asset_url
    asset_url=$(build_asset_url "${version}" "${os}" "${arch}")
    
    local archive="${TEMP_DIR}/mediamtx.tar.gz"
    local checksum="${TEMP_DIR}/mediamtx.tar.gz.sha256sum"
    
    log_info "Downloading MediaMTX ${version} for ${os}/${arch}..."
    
    # In dry-run mode, skip actual binary download but show what would happen
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would download: ${asset_url}"
        log_info "[DRY RUN] Would verify checksum if available"
        log_info "[DRY RUN] Would extract and install binary"
        return 0
    fi
    
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

# FIXED: Create configuration file with proper log settings
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
        add_rollback "mv" "${backup}" "${config_file}"
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
# Systemd captures stdout to journal automatically
# For manual runs, logs go to file
logDestinations: [stdout]
# Note: systemd captures stdout to journal automatically
# For manual runs, logs go to: /var/lib/mediamtx/mediamtx.log
logFile: /var/lib/mediamtx/mediamtx.log

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

# FIXED: Create systemd service with commented capabilities
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
        add_rollback "mv" "${backup}" "${service_file}"
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

# Capabilities (uncomment if using privileged ports < 1024)
# AmbientCapabilities=CAP_NET_BIND_SERVICE
# CapabilityBoundingSet=CAP_NET_BIND_SERVICE

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
    
    add_rollback "userdel" "${SERVICE_USER}"
}

# Install MediaMTX
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
    add_rollback "rm" "${INSTALL_DIR}/mediamtx"
    
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
    
    # Show appropriate guidance
    show_post_install_guidance
}

# Update MediaMTX
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
    
    # Detect management mode
    local management_mode
    management_mode=$(detect_management_mode)
    local was_running=false
    [[ "${management_mode}" != "none" ]] && was_running=true
    
    local active_streams=()
    if [[ "${management_mode}" == "stream-manager" ]]; then
        mapfile -t active_streams < <(get_active_streams)
        log_info "Detected ${#active_streams[@]} active streams"
    fi
    
    # Stop MediaMTX
    stop_mediamtx "${management_mode}"
    
    # Backup current binary
    local backup="${INSTALL_DIR}/mediamtx.backup.$(date +%Y%m%d-%H%M%S)"
    cp "${INSTALL_DIR}/mediamtx" "${backup}"
    add_rollback "mv" "${backup}" "${INSTALL_DIR}/mediamtx"
    log_info "Current binary backed up to: ${backup}"
    
    # Download new version
    download_mediamtx "${RELEASE_VERSION}" "${PLATFORM_OS}" "${PLATFORM_ARCH}"
    
    # Install new binary
    install -m 755 "${TEMP_DIR}/mediamtx" "${INSTALL_DIR}/"
    
    # Restart if was running
    if [[ "${was_running}" == "true" ]]; then
        start_mediamtx "${management_mode}"
        
        if [[ ${#active_streams[@]} -gt 0 ]]; then
            log_info "Restarted streams: ${active_streams[*]}"
        fi
    fi
    
    log_info "MediaMTX updated to ${RELEASE_VERSION} successfully!"
    
    # Show post-update recommendations
    show_post_update_guidance "${management_mode}"
}

# Stop MediaMTX based on management mode
stop_mediamtx() {
    local mode="$1"
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would stop MediaMTX (${mode})"
        return 0
    fi
    
    case "${mode}" in
        systemd)
            log_info "Stopping MediaMTX service (systemd)..."
            systemctl stop mediamtx
            add_rollback "systemctl" "start" "mediamtx"
            ;;
        
        stream-manager)
            local stream_manager
            if stream_manager=$(find_stream_manager); then
                log_info "Stopping MediaMTX via stream manager..."
                "${stream_manager}" stop || {
                    log_warn "Stream manager stop failed, falling back to manual stop"
                    pkill -f "ffmpeg.*rtsp://localhost" 2>/dev/null || true
                    sleep 1
                    pkill mediamtx 2>/dev/null || true
                }
            else
                log_info "Stopping MediaMTX and FFmpeg streams manually..."
                pkill -f "ffmpeg.*rtsp://localhost" 2>/dev/null || true
                sleep 1
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
}

# Start MediaMTX based on management mode
start_mediamtx() {
    local mode="$1"
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would start MediaMTX (${mode})"
        return 0
    fi
    
    case "${mode}" in
        systemd)
            log_info "Starting MediaMTX service (systemd)..."
            systemctl start mediamtx
            ;;
        
        stream-manager)
            local stream_manager
            if stream_manager=$(find_stream_manager); then
                log_info "Starting MediaMTX via stream manager..."
                "${stream_manager}" start || {
                    log_error "Failed to start via stream manager"
                    log_info "Please manually start with: sudo ${stream_manager} start"
                }
            else
                log_warn "Stream manager script not found"
                log_info "Please manually restart MediaMTX with your stream manager"
            fi
            ;;
        
        manual)
            log_info "MediaMTX was running manually"
            log_info "Please restart it manually with your preferred method"
            ;;
    esac
}

# FIXED: Uninstall MediaMTX with dry-run compliance
uninstall_mediamtx() {
    log_info "Uninstalling MediaMTX..."
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would uninstall MediaMTX"
        if [[ -f "${SERVICE_DIR}/${SERVICE_NAME}" ]]; then
            log_info "[DRY RUN] Would stop and disable service"
            log_info "[DRY RUN] Would remove service file"
        fi
        if [[ -f "${INSTALL_DIR}/mediamtx" ]]; then
            log_info "[DRY RUN] Would remove binary and backups"
        fi
        if [[ -d "${CONFIG_DIR}" ]]; then
            log_info "[DRY RUN] Would prompt to remove configuration"
        fi
        if id "${SERVICE_USER}" &>/dev/null; then
            log_info "[DRY RUN] Would prompt to remove service user"
        fi
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
    
    # Ask about user removal
    if id "${SERVICE_USER}" &>/dev/null && [[ "${FORCE_MODE}" != "true" ]]; then
        echo -en "${YELLOW}Remove service user ${SERVICE_USER}? [y/N] ${NC}"
        read -r response
        if [[ "${response}" =~ ^[Yy]$ ]]; then
            userdel "${SERVICE_USER}" 2>/dev/null || true
            rm -rf /var/lib/mediamtx 2>/dev/null || true
            log_info "Service user removed"
        fi
    elif [[ "${FORCE_MODE}" == "true" ]] && id "${SERVICE_USER}" &>/dev/null; then
        log_info "Removing service user..."
        userdel "${SERVICE_USER}" 2>/dev/null || true
        rm -rf /var/lib/mediamtx 2>/dev/null || true
    fi
    
    log_info "MediaMTX uninstalled successfully!"
}

# ============================================================================
# Status Functions (Modularized)
# ============================================================================

# Show status header
show_status_header() {
    echo -e "${BOLD}MediaMTX Installation Status${NC}"
    echo "================================"
}

# Show installation status
show_installation_status() {
    if [[ -f "${INSTALL_DIR}/mediamtx" ]]; then
        echo -e "Installation: ${GREEN}✓ Installed${NC}"
        echo "Location: ${INSTALL_DIR}/mediamtx"
        
        local version="unknown"
        if "${INSTALL_DIR}/mediamtx" --version &>/dev/null; then
            version=$("${INSTALL_DIR}/mediamtx" --version 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        fi
        echo "Version: ${version}"
        
        local file_size
        file_size=$(stat -c%s "${INSTALL_DIR}/mediamtx" 2>/dev/null || stat -f%z "${INSTALL_DIR}/mediamtx" 2>/dev/null || echo "unknown")
        echo "Binary size: ${file_size} bytes"
    else
        echo -e "Installation: ${RED}✗ Not installed${NC}"
    fi
}

# Show configuration status
show_configuration_status() {
    echo ""
    
    if [[ -f "${CONFIG_DIR}/${CONFIG_NAME}" ]]; then
        echo -e "Configuration: ${GREEN}✓ Present${NC}"
        echo "Config file: ${CONFIG_DIR}/${CONFIG_NAME}"
    else
        echo -e "Configuration: ${YELLOW}⚠ Missing${NC}"
    fi
}

# Show process status
show_process_status() {
    echo ""
    
    local management_mode
    management_mode=$(detect_management_mode)
    
    local systemd_configured=false
    if command -v systemctl &>/dev/null && [[ -f "${SERVICE_DIR}/${SERVICE_NAME}" ]]; then
        systemd_configured=true
        echo -e "Service: ${GREEN}✓ Configured${NC}"
    else
        echo -e "Service: ${YELLOW}⚠ Not configured${NC}"
    fi
    
    case "${management_mode}" in
        systemd)
            echo -e "Status: ${GREEN}● Running (systemd)${NC}"
            local pid
            pid=$(systemctl show mediamtx --property MainPID --value 2>/dev/null || echo "")
            [[ -n "${pid}" ]] && [[ "${pid}" != "0" ]] && echo "PID: ${pid}"
            ;;
        
        stream-manager)
            echo -e "Status: ${YELLOW}⚠ Running (stream manager)${NC}"
            local active_streams=()
            mapfile -t active_streams < <(get_active_streams)
            if [[ ${#active_streams[@]} -gt 0 ]]; then
                echo "Active streams: ${#active_streams[@]}"
                for stream in "${active_streams[@]}"; do
                    echo "  • ${stream}"
                done
            fi
            ;;
        
        manual)
            echo -e "Status: ${YELLOW}⚠ Running (manual)${NC}"
            ;;
        
        none)
            echo -e "Status: ${RED}○ Not running${NC}"
            ;;
    esac
    
    if [[ "${systemd_configured}" == "true" ]]; then
        if systemctl is-enabled --quiet mediamtx 2>/dev/null; then
            echo -e "Auto-start: ${GREEN}Enabled${NC}"
        else
            echo -e "Auto-start: ${YELLOW}Disabled${NC}"
        fi
    fi
}

# Show port status
show_port_status() {
    echo ""
    echo "Port Status:"
    
    local ports=("${DEFAULT_RTSP_PORT}" "${DEFAULT_API_PORT}" "${DEFAULT_METRICS_PORT}")
    local labels=("RTSP" "API" "Metrics")
    
    for i in "${!ports[@]}"; do
        local port="${ports[$i]}"
        local label="${labels[$i]}"
        
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
        fi
    done
}

# Show update check
show_update_check() {
    echo ""
    echo "Checking for updates..."
    
    local temp_status_dir="/tmp/mediamtx-status-$$"
    mkdir -p "${temp_status_dir}"
    local saved_temp_dir="${TEMP_DIR}"
    TEMP_DIR="${temp_status_dir}"
    
    if get_release_info "latest" 2>/dev/null; then
        echo "Latest version: ${RELEASE_VERSION}"
        
        local installed_version="unknown"
        if [[ -f "${INSTALL_DIR}/mediamtx" ]] && "${INSTALL_DIR}/mediamtx" --version &>/dev/null; then
            installed_version=$("${INSTALL_DIR}/mediamtx" --version 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        fi
        
        if [[ "${installed_version}" != "unknown" ]] && [[ "${installed_version}" != "${RELEASE_VERSION}" ]]; then
            echo -e "${YELLOW}Update available! Run '${SCRIPT_NAME} update' to upgrade${NC}"
        elif [[ "${installed_version}" == "${RELEASE_VERSION}" ]]; then
            echo -e "${GREEN}You are running the latest version${NC}"
        fi
    else
        echo "Could not check for updates"
    fi
    
    rm -rf "${temp_status_dir}" 2>/dev/null || true
    TEMP_DIR="${saved_temp_dir}"
}

# Show health check
show_health_check() {
    local management_mode
    management_mode=$(detect_management_mode)
    
    if [[ "${management_mode}" == "none" ]]; then
        return
    fi
    
    echo ""
    echo "Quick Health Check:"
    
    if command -v curl &>/dev/null; then
        local api_working=false
        
        if curl -s -f -m 2 "http://localhost:${DEFAULT_API_PORT}/v3/paths/list" &>/dev/null; then
            echo -e "  API: ${GREEN}✓ Responding${NC}"
            api_working=true
        elif curl -s -f -m 2 "http://localhost:${DEFAULT_API_PORT}/" &>/dev/null; then
            echo -e "  API: ${GREEN}✓ Responding${NC}"
            api_working=true
        else
            echo -e "  API: ${RED}✗ Not responding${NC}"
        fi
    fi
}

# Show status summary
show_status_summary() {
    echo ""
    echo "================================"
    
    local management_mode
    management_mode=$(detect_management_mode)
    
    case "${management_mode}" in
        systemd)
            echo -e "${GREEN}Summary: MediaMTX is properly managed by systemd${NC}"
            echo ""
            echo "Quick Commands:"
            echo "  • View logs: sudo journalctl -u mediamtx -f"
            echo "  • Restart: sudo systemctl restart mediamtx"
            ;;
        
        stream-manager)
            echo -e "${GREEN}Summary: MediaMTX is running under Audio Stream Manager control${NC}"
            echo ""
            echo "Quick Commands:"
            echo "  • Check streams: sudo ./mediamtx-stream-manager.sh status"
            echo "  • Restart: sudo ./mediamtx-stream-manager.sh restart"
            ;;
        
        manual)
            echo -e "${YELLOW}Summary: MediaMTX is running but not managed${NC}"
            echo "Consider using systemd or stream-manager for management."
            ;;
        
        none)
            echo -e "${RED}Summary: MediaMTX is not running${NC}"
            if [[ -f "${INSTALL_DIR}/mediamtx" ]]; then
                echo ""
                echo "To start MediaMTX:"
                echo "  • With systemd: sudo systemctl start mediamtx"
                echo "  • Manually: ${INSTALL_DIR}/mediamtx ${CONFIG_DIR}/${CONFIG_NAME}"
            fi
            ;;
    esac
}

# Main status function
show_status() {
    show_status_header
    show_installation_status
    show_configuration_status
    show_process_status
    show_port_status
    show_update_check
    show_health_check
    show_status_summary
}

# Verify installation integrity
verify_installation() {
    log_info "Verifying installation..."
    
    local errors=0
    local warnings=0
    
    # Check binary
    if [[ ! -f "${INSTALL_DIR}/mediamtx" ]]; then
        log_error "Binary not found: ${INSTALL_DIR}/mediamtx"
        errors=$((errors + 1))
    elif [[ ! -x "${INSTALL_DIR}/mediamtx" ]]; then
        log_error "Binary not executable: ${INSTALL_DIR}/mediamtx"
        errors=$((errors + 1))
    elif ! "${INSTALL_DIR}/mediamtx" --version &>/dev/null; then
        log_error "Binary verification failed"
        errors=$((errors + 1))
    else
        log_info "Binary: OK"
    fi
    
    # Check configuration
    if [[ ! -f "${CONFIG_DIR}/${CONFIG_NAME}" ]]; then
        log_warn "Configuration not found: ${CONFIG_DIR}/${CONFIG_NAME}"
        warnings=$((warnings + 1))
    else
        log_info "Configuration: OK"
    fi
    
    # Check service
    if command -v systemctl &>/dev/null; then
        if [[ ! -f "${SERVICE_DIR}/${SERVICE_NAME}" ]]; then
            log_warn "Service not configured"
            warnings=$((warnings + 1))
        elif ! systemctl is-enabled mediamtx &>/dev/null; then
            log_warn "Service not enabled"
            warnings=$((warnings + 1))
        else
            log_info "Service: OK"
        fi
    fi
    
    # Check user
    if ! id "${SERVICE_USER}" &>/dev/null; then
        log_warn "Service user not found: ${SERVICE_USER}"
        warnings=$((warnings + 1))
    else
        log_info "Service user: OK"
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
# Guidance Functions
# ============================================================================

# Show post-install guidance
show_post_install_guidance() {
    local stream_manager
    stream_manager=$(find_stream_manager 2>/dev/null || echo "")
    
    echo ""
    if [[ -n "${stream_manager}" ]] || [[ -f "/etc/mediamtx/audio-devices.conf" ]]; then
        echo "================================"
        echo "Audio Streaming Setup Detected!"
        echo "================================"
        echo ""
        echo "You can manage MediaMTX using EITHER:"
        echo ""
        echo "Option 1: Stream Manager (Recommended for audio streaming)"
        echo "  sudo ${stream_manager:-./mediamtx-stream-manager.sh} start"
        echo "  sudo ${stream_manager:-./mediamtx-stream-manager.sh} status"
        echo ""
        echo "Option 2: Systemd Service (Standard management)"
        echo "  sudo systemctl start mediamtx"
        echo "  sudo systemctl enable mediamtx"
        echo ""
        echo "Note: Use only ONE management method at a time!"
    else
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

# Show post-update guidance
show_post_update_guidance() {
    local mode="${1:-none}"
    
    case "${mode}" in
        stream-manager)
            echo ""
            echo "Stream Manager Detected - Quick Commands:"
            echo "  • Check status: sudo ./mediamtx-stream-manager.sh status"
            echo "  • View logs: tail -f /var/lib/mediamtx-ffmpeg/*.log"
            ;;
        
        systemd)
            echo ""
            echo "Systemd Management - Quick Commands:"
            echo "  • Check status: sudo systemctl status mediamtx"
            echo "  • View logs: sudo journalctl -u mediamtx -f"
            ;;
    esac
}

# ============================================================================
# Help and Usage
# ============================================================================

show_help() {
    cat << EOF
${BOLD}MediaMTX Installation Manager v${SCRIPT_VERSION}${NC}

Production-ready installer for MediaMTX media server with comprehensive
error handling, validation, and security features.

Critical fixes in v1.1.1:
  • Fixed lock mechanism for concurrent execution protection
  • Fixed rollback system to handle arguments with spaces
  • Complete SemVer version comparison with pre-release support
  • Fixed dry-run mode compliance in uninstall
  • Improved JSON parsing fallbacks
  • Updated log configuration for systemd journal
  • Fixed dry-run mode to allow metadata downloads

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

${BOLD}FILES:${NC}
    Binary:       ${INSTALL_DIR}/mediamtx
    Config:       ${CONFIG_DIR}/${CONFIG_NAME}
    Service:      ${SERVICE_DIR}/${SERVICE_NAME}
    Logs:         /var/lib/mediamtx/mediamtx.log (systemd: journalctl)

${BOLD}SERVICE MANAGEMENT:${NC}
    Start:        sudo systemctl start mediamtx
    Stop:         sudo systemctl stop mediamtx
    Restart:      sudo systemctl restart mediamtx
    Status:       sudo systemctl status mediamtx
    Enable:       sudo systemctl enable mediamtx
    Disable:      sudo systemctl disable mediamtx
    Logs:         sudo journalctl -u mediamtx -f

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
    COMMAND="${args[0]:-}"
    
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

# Main function
main() {
    # Parse arguments first
    parse_arguments "$@"
    
    # Initialize runtime variables after parsing
    initialize_runtime_vars
    
    # Create temp directory early for logging
    create_temp_dir
    
    # Load configuration safely
    load_config
    
    # Validate input parameters
    validate_input
    
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

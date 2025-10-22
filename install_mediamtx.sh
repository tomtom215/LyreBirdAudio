#!/usr/bin/env bash
#
# MediaMTX Installation Manager - Production-Ready Install/Update/Uninstall
# Version: 2.0.0
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# Changelog:
#   v2.0.0: Major rewrite with built-in --upgrade support (MediaMTX v1.15.0+), atomic binary
#           installation with simplified rollback, enforced checksum verification (--force to skip),
#           fixed BSD/macOS lock race conditions, improved SemVer comparison, state directory
#           management, enhanced JSON parsing, better error handling, full shellcheck compliance
#   v1.2.0: Fixed checksum URL to use unified checksums.sha256 file
#   v1.1.0: Added stream manager integration, dry-run mode, SemVer comparison
#
# Usage: ./mediamtx-installer.sh [OPTIONS] COMMAND

set -euo pipefail
set -o errtrace
set -o functrace

# Script metadata
readonly SCRIPT_VERSION="2.0.0"

SCRIPT_NAME=""
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

SCRIPT_DIR=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR

readonly SCRIPT_PID="$$"

# Default configuration
readonly DEFAULT_INSTALL_PREFIX="${MEDIAMTX_PREFIX:-/usr/local}"
readonly DEFAULT_CONFIG_DIR="${MEDIAMTX_CONFIG_DIR:-/etc/mediamtx}"
readonly DEFAULT_STATE_DIR="${MEDIAMTX_STATE_DIR:-/var/lib/mediamtx}"
readonly DEFAULT_SERVICE_USER="${MEDIAMTX_USER:-mediamtx}"
readonly DEFAULT_SERVICE_GROUP="${MEDIAMTX_GROUP:-mediamtx}"
readonly DEFAULT_RTSP_PORT="${MEDIAMTX_RTSP_PORT:-8554}"
readonly DEFAULT_API_PORT="${MEDIAMTX_API_PORT:-9997}"
readonly DEFAULT_METRICS_PORT="${MEDIAMTX_METRICS_PORT:-9998}"
readonly DEFAULT_DOWNLOAD_TIMEOUT="${MEDIAMTX_DOWNLOAD_TIMEOUT:-300}"
readonly DEFAULT_DOWNLOAD_RETRIES="${MEDIAMTX_DOWNLOAD_RETRIES:-3}"
readonly DEFAULT_GITHUB_REPO="${MEDIAMTX_REPO:-bluenviron/mediamtx}"

# Runtime configuration
INSTALL_PREFIX="${DEFAULT_INSTALL_PREFIX}"
CONFIG_DIR="${DEFAULT_CONFIG_DIR}"
STATE_DIR="${DEFAULT_STATE_DIR}"
SERVICE_USER="${DEFAULT_SERVICE_USER}"
SERVICE_GROUP="${DEFAULT_SERVICE_GROUP}"
VERBOSE_MODE=false
QUIET_MODE=false
DRY_RUN_MODE=false
FORCE_MODE=false
SKIP_SERVICE=false
SKIP_CONFIG=false
TARGET_VERSION=""
CONFIG_FILE=""
COMMAND=""

# Derived paths
INSTALL_DIR="${INSTALL_PREFIX}/bin"
readonly SERVICE_DIR="/etc/systemd/system"
readonly SERVICE_NAME="mediamtx.service"
readonly CONFIG_NAME="mediamtx.yml"

# Temporary directory and files
TEMP_BASE="${TMPDIR:-/tmp}"
TEMP_DIR=""
LOG_FILE=""
readonly LOCK_FILE="/var/lock/mediamtx-installer.lock"
LOCK_FD=""

# GitHub API configuration
readonly GITHUB_API_BASE="https://api.github.com"
readonly GITHUB_API_TIMEOUT=30
readonly USER_AGENT="MediaMTX-Installer/${SCRIPT_VERSION}"

# Color codes
RED=''
GREEN=''
YELLOW=''
BLUE=''
BOLD=''
NC=''

# Arrays for cleanup
declare -a CLEANUP_FILES=()
declare -a CLEANUP_DIRS=()

# Backup tracking for rollback
BINARY_BACKUP=""
SERVICE_BACKUP=""
CONFIG_BACKUP=""
STATE_DIR_CREATED=false

# Download command
DOWNLOAD_CMD=""

# Release information
RELEASE_VERSION=""

# Platform information
PLATFORM_OS=""
PLATFORM_ARCH=""

# Minimum version for --upgrade support (MediaMTX added this in v1.15.0)
readonly MIN_UPGRADE_VERSION="1.15.0"

# ============================================================================
# Utility Functions
# ============================================================================

initialize_runtime_vars() {
    if [[ -t 1 ]] && [[ "${QUIET_MODE}" != "true" ]]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        BOLD='\033[1m'
        NC='\033[0m'
    fi
}

error_handler() {
    local code=$1
    local line_no=$2
    local bash_command=$3
    
    if [[ "${code}" -ne 0 ]]; then
        log_error "Command failed with exit code ${code}"
        log_error "Failed command: ${bash_command}"
        local func_name="${FUNCNAME[1]:-main}"
        [[ -z "${func_name}" ]] && func_name="main"
        log_error "Line ${line_no} in function ${func_name}"
        
        if [[ "${VERBOSE_MODE}" == "true" ]]; then
            log_debug "Stack trace:"
            local i
            for ((i=1; i<${#FUNCNAME[@]}; i++)); do
                local fname="${FUNCNAME[$i]:-unknown}"
                local fline="${BASH_LINENO[$((i-1))]:-0}"
                log_debug "  ${i}: ${fname}() at line ${fline}"
            done
        fi
    fi
}

trap 'error_handler $? ${LINENO} "${BASH_COMMAND}"' ERR

cleanup() {
    local exit_code=$?
    
    release_lock
    
    # Rollback on failure
    if [[ ${exit_code} -ne 0 ]]; then
        log_warn "Executing rollback due to failure..."
        execute_rollback
    fi
    
    # Clean up temporary files
    local file
    for file in "${CLEANUP_FILES[@]}"; do
        if [[ -f "${file}" ]]; then
            rm -f "${file}" 2>/dev/null || true
        fi
    done
    
    local dir
    for dir in "${CLEANUP_DIRS[@]}"; do
        if [[ -d "${dir}" ]]; then
            rm -rf "${dir}" 2>/dev/null || true
        fi
    done
    
    if [[ -n "${TEMP_DIR}" ]] && [[ -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}" 2>/dev/null || true
    fi
    
    # Save error log
    if [[ ${exit_code} -ne 0 ]] && [[ -f "${LOG_FILE}" ]]; then
        local error_log
        error_log="/tmp/mediamtx-installer-error-$(date +%Y%m%d-%H%M%S).log"
        if cp "${LOG_FILE}" "${error_log}" 2>/dev/null; then
            [[ "${QUIET_MODE}" != "true" ]] && echo -e "${YELLOW}Error log saved to: ${error_log}${NC}" >&2
        fi
    fi
    
    return ${exit_code}
}

trap cleanup EXIT INT TERM

# Logging functions
log_debug() {
    [[ "${VERBOSE_MODE}" != "true" ]] && return 0
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $*"
    if [[ -n "${LOG_FILE}" ]] && [[ -f "${LOG_FILE}" ]]; then
        echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
    [[ "${QUIET_MODE}" != "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $*" >&2
}

log_info() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
    if [[ -n "${LOG_FILE}" ]] && [[ -f "${LOG_FILE}" ]]; then
        echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
    [[ "${QUIET_MODE}" != "true" ]] && echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*"
    if [[ -n "${LOG_FILE}" ]] && [[ -f "${LOG_FILE}" ]]; then
        echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*"
    if [[ -n "${LOG_FILE}" ]] && [[ -f "${LOG_FILE}" ]]; then
        echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

fatal() {
    log_error "$1"
    exit "${2:-1}"
}

# ============================================================================
# Security Functions
# ============================================================================

acquire_lock() {
    local timeout="${1:-30}"
    
    exec 200>"${LOCK_FILE}"
    LOCK_FD=200
    
    log_debug "Attempting to acquire lock (timeout: ${timeout}s)..."
    
    # Platform-specific flock handling
    if [[ "$(uname)" == "Darwin" ]] || [[ "$(uname)" == *"BSD"* ]]; then
        # BSD/macOS: flock doesn't support -w timeout, use manual loop
        local elapsed=0
        while ! flock -n -x 200 2>/dev/null; do
            sleep 1
            ((elapsed++))
            if [[ ${elapsed} -ge ${timeout} ]]; then
                exec 200>&- 2>/dev/null || true
                LOCK_FD=""
                fatal "Failed to acquire lock after ${timeout} seconds" 1
            fi
        done
    else
        # Linux: use native timeout support
        if ! flock -x -w "${timeout}" 200; then
            exec 200>&-
            LOCK_FD=""
            fatal "Failed to acquire lock after ${timeout} seconds" 1
        fi
    fi
    
    echo "${SCRIPT_PID}" > "${LOCK_FILE}.pid"
    log_debug "Lock acquired (PID: ${SCRIPT_PID})"
}

release_lock() {
    if [[ -n "${LOCK_FD}" ]]; then
        flock -u "${LOCK_FD}" 2>/dev/null || true
        exec 200>&- 2>/dev/null || true
        rm -f "${LOCK_FILE}.pid" 2>/dev/null || true
        LOCK_FD=""
        log_debug "Lock released"
    fi
}

create_temp_dir() {
    if ! command -v mktemp &>/dev/null; then
        fatal "mktemp is required but not found. Please install coreutils." 4
    fi
    
    TEMP_DIR=$(mktemp -d "${TEMP_BASE}/mediamtx-installer-XXXXXX")
    
    if [[ ! -d "${TEMP_DIR}" ]]; then
        fatal "Failed to create temporary directory" 1
    fi
    
    LOG_FILE="${TEMP_DIR}/install.log"
    touch "${LOG_FILE}"
    chmod 600 "${LOG_FILE}"
    
    CLEANUP_DIRS+=("${TEMP_DIR}")
    log_debug "Created temporary directory: ${TEMP_DIR}"
}

load_config() {
    [[ -z "${CONFIG_FILE}" ]] || [[ ! -f "${CONFIG_FILE}" ]] && return 0
    
    log_debug "Loading configuration from: ${CONFIG_FILE}"
    
    while IFS='=' read -r key value || [[ -n "${key}" ]]; do
        [[ -z "${key}" ]] || [[ "${key}" == \#* ]] && continue
        
        key=$(echo "${key}" | xargs)
        value=$(echo "${value}" | xargs | sed -e 's/^["\x27]//' -e 's/["\x27]$//')
        
        case "${key}" in
            INSTALL_PREFIX)
                if [[ "${value}" == /* ]]; then
                    INSTALL_PREFIX="${value}"
                    INSTALL_DIR="${INSTALL_PREFIX}/bin"
                else
                    log_warn "Invalid INSTALL_PREFIX in config: ${value}"
                fi
                ;;
            CONFIG_DIR)
                if [[ "${value}" == /* ]]; then
                    CONFIG_DIR="${value}"
                else
                    log_warn "Invalid CONFIG_DIR in config: ${value}"
                fi
                ;;
            STATE_DIR)
                if [[ "${value}" == /* ]]; then
                    STATE_DIR="${value}"
                else
                    log_warn "Invalid STATE_DIR in config: ${value}"
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
# Rollback Functions
# ============================================================================

execute_rollback() {
    # Restore binary backup (atomic)
    if [[ -n "${BINARY_BACKUP}" ]] && [[ -f "${BINARY_BACKUP}" ]]; then
        log_warn "Restoring binary backup..."
        mv -f "${BINARY_BACKUP}" "${INSTALL_DIR}/mediamtx" 2>/dev/null || true
    fi
    
    # Restore service backup (atomic)
    if [[ -n "${SERVICE_BACKUP}" ]] && [[ -f "${SERVICE_BACKUP}" ]]; then
        log_warn "Restoring service backup..."
        mv -f "${SERVICE_BACKUP}" "${SERVICE_DIR}/${SERVICE_NAME}" 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
    fi
    
    # Restore config backup (atomic)
    if [[ -n "${CONFIG_BACKUP}" ]] && [[ -f "${CONFIG_BACKUP}" ]]; then
        log_warn "Restoring config backup..."
        mv -f "${CONFIG_BACKUP}" "${CONFIG_DIR}/${CONFIG_NAME}" 2>/dev/null || true
    fi
    
    # Remove state directory if we created it
    if [[ "${STATE_DIR_CREATED}" == "true" ]] && [[ -d "${STATE_DIR}" ]]; then
        log_warn "Removing state directory created during failed operation..."
        rm -rf "${STATE_DIR}" 2>/dev/null || true
    fi
}

# ============================================================================
# Validation Functions
# ============================================================================

validate_input() {
    if [[ "${INSTALL_PREFIX}" != /* ]]; then
        fatal "Installation prefix must be an absolute path" 10
    fi
    
    if [[ "${INSTALL_PREFIX}" == *..* ]]; then
        fatal "Installation prefix cannot contain .." 10
    fi
    
    if [[ -n "${TARGET_VERSION}" ]] && ! validate_version "${TARGET_VERSION}"; then
        fatal "Invalid version format: ${TARGET_VERSION}" 10
    fi
    
    if [[ -n "${CONFIG_FILE}" ]]; then
        [[ ! -f "${CONFIG_FILE}" ]] && fatal "Config file not found: ${CONFIG_FILE}" 9
        [[ ! -r "${CONFIG_FILE}" ]] && fatal "Config file not readable: ${CONFIG_FILE}" 9
    fi
}

check_requirements() {
    local missing=()
    
    # Required commands
    local -a required=("bash" "curl" "tar" "mktemp" "flock")
    
    local cmd
    for cmd in "${required[@]}"; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done
    
    # Check bash version
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        fatal "Bash 4.0+ required (found ${BASH_VERSION})" 4
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        fatal "Missing required commands: ${missing[*]}" 4
    fi
    
    # Determine download command
    if command -v curl &>/dev/null; then
        DOWNLOAD_CMD="curl"
    elif command -v wget &>/dev/null; then
        DOWNLOAD_CMD="wget"
    else
        fatal "Neither curl nor wget found" 4
    fi
    
    log_debug "Using ${DOWNLOAD_CMD} for downloads"
    
    # Optional but recommended
    if ! command -v sha256sum &>/dev/null && ! command -v shasum &>/dev/null; then
        log_warn "No SHA256 tool available - checksum verification will require --force"
    fi
    
    if ! command -v jq &>/dev/null; then
        log_warn "jq not found - using fallback JSON parsing"
    fi
}

validate_version() {
    local version="$1"
    local version_regex='^v?[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9\.\-]+)?(\+[a-zA-Z0-9\.\-]+)?$'
    [[ "${version}" =~ ${version_regex} ]] && return 0 || return 1
}

validate_url() {
    local url="$1"
    local url_regex='^https?://[-A-Za-z0-9\+&@#/%?=~_|!:,.;]*[-A-Za-z0-9\+&@#/%=~_|]$'
    [[ "${url}" =~ ${url_regex} ]] && return 0 || return 1
}

version_compare() {
    # Returns 0 if v1 >= v2, 1 otherwise
    local v1="${1#v}"
    local v2="${2#v}"
    
    # Require sort -V for reliable SemVer comparison (handles numeric pre-releases)
    if command -v sort &>/dev/null && sort --version 2>&1 | grep -q 'GNU\|BusyBox'; then
        if sort --help 2>&1 | grep -q -- '-V'; then
            [[ "$(printf '%s\n' "${v2}" "${v1}" | sort -V | head -n1)" == "${v2}" ]] && return 0 || return 1
        fi
    fi
    
    # Fallback: manual comparison with normalization
    log_debug "Using fallback version comparison"
    
    # Warn if pre-releases detected (may not compare correctly)
    if [[ "${v1}" == *-* ]] || [[ "${v2}" == *-* ]]; then
        log_warn "Pre-release versions detected - comparison may be unreliable without GNU sort -V"
    fi
    
    # Extract base version and normalize to 3 parts
    local v1_base="${v1%%-*}"
    local v2_base="${v2%%-*}"
    
    # Normalize to exactly 3 parts (X.Y.Z)
    while [[ $(tr -dc '.' <<< "${v1_base}" | wc -c) -lt 2 ]]; do
        v1_base="${v1_base}.0"
    done
    while [[ $(tr -dc '.' <<< "${v2_base}" | wc -c) -lt 2 ]]; do
        v2_base="${v2_base}.0"
    done
    
    local IFS=.
    local -a v1_parts v2_parts
    read -r -a v1_parts <<< "${v1_base}"
    read -r -a v2_parts <<< "${v2_base}"
    
    local i
    for i in 0 1 2; do
        local p1="${v1_parts[$i]:-0}"
        local p2="${v2_parts[$i]:-0}"
        
        if [[ ${p1} -gt ${p2} ]]; then
            return 0
        elif [[ ${p1} -lt ${p2} ]]; then
            return 1
        fi
    done
    
    # Equal base versions - check pre-release
    local v1_pre="${v1#*-}"
    local v2_pre="${v2#*-}"
    
    if [[ "$v1" == "$v1_pre" ]] && [[ "$v2" != "$v2_pre" ]]; then
        return 0
    elif [[ "$v1" != "$v1_pre" ]] && [[ "$v2" == "$v2_pre" ]]; then
        return 1
    elif [[ "$v1" != "$v1_pre" ]] && [[ "$v2" != "$v2_pre" ]]; then
        [[ "$v1_pre" > "$v2_pre" ]] && return 0 || return 1
    fi
    
    return 0
}

verify_checksum() {
    local file="$1"
    local checksum_file="$2"
    local filename="$3"
    
    if [[ ! -f "${file}" ]]; then
        log_error "File not found: ${file}"
        return 1
    fi
    
    if [[ ! -f "${checksum_file}" ]]; then
        if [[ "${FORCE_MODE}" == "true" ]]; then
            log_warn "Checksum file not found - skipping verification (--force enabled)"
            return 0
        else
            log_error "Checksum file not found and --force not specified"
            return 1
        fi
    fi
    
    # Extract checksum
    local expected_checksum
    expected_checksum=$(grep -F "${filename}" "${checksum_file}" 2>/dev/null | head -1 | awk '{print $1}')
    
    if [[ -z "${expected_checksum}" ]] || [[ ! "${expected_checksum}" =~ ^[a-f0-9]{64}$ ]]; then
        if [[ "${FORCE_MODE}" == "true" ]]; then
            log_warn "No valid checksum found for ${filename} - skipping verification (--force enabled)"
            return 0
        fi
        log_error "Failed to find valid checksum for ${filename}"
        return 1
    fi
    
    # Calculate actual checksum
    local actual_checksum
    if command -v sha256sum &>/dev/null; then
        actual_checksum=$(sha256sum "${file}" | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        actual_checksum=$(shasum -a 256 "${file}" | awk '{print $1}')
    else
        if [[ "${FORCE_MODE}" == "true" ]]; then
            log_warn "No SHA256 tool available - skipping verification (--force enabled)"
            return 0
        else
            log_error "No SHA256 tool available and --force not specified"
            return 1
        fi
    fi
    
    if [[ "${expected_checksum}" != "${actual_checksum}" ]]; then
        log_error "Checksum mismatch!"
        log_error "Expected: ${expected_checksum}"
        log_error "Actual:   ${actual_checksum}"
        return 1
    fi
    
    log_info "Checksum verified successfully"
    return 0
}

# ============================================================================
# Platform Detection
# ============================================================================

detect_platform() {
    local os=""
    local arch=""
    
    case "${OSTYPE}" in
        linux*)
            os="linux"
            ;;
        darwin*)
            os="darwin"
            ;;
        freebsd*)
            os="freebsd"
            ;;
        *)
            fatal "Unsupported operating system: ${OSTYPE}" 3
            ;;
    esac
    
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
    
    PLATFORM_OS="${os}"
    PLATFORM_ARCH="${arch}"
    
    log_debug "Platform: ${PLATFORM_OS}/${PLATFORM_ARCH}"
}

# ============================================================================
# Download Functions
# ============================================================================

download_file() {
    local url="$1"
    local output="$2"
    local timeout="${3:-${DEFAULT_DOWNLOAD_TIMEOUT}}"
    local retries="${4:-${DEFAULT_DOWNLOAD_RETRIES}}"
    
    # Allow metadata downloads in dry-run mode
    local is_metadata=false
    if [[ "${url}" == *"api.github.com"* ]] || \
       [[ "${url}" == *"checksums.sha256" ]] || \
       [[ "${output}" == *"/release.json" ]]; then
        is_metadata=true
    fi
    
    if [[ "${DRY_RUN_MODE}" == "true" ]] && [[ "${is_metadata}" == "false" ]]; then
        log_info "[DRY RUN] Would download: ${url} -> ${output}"
        return 0
    fi
    
    if ! validate_url "${url}"; then
        return 1
    fi
    
    local output_dir
    output_dir=$(dirname "${output}")
    [[ -d "${output_dir}" ]] || mkdir -p "${output_dir}"
    
    local attempt=0
    while [[ ${attempt} -lt ${retries} ]]; do
        ((attempt++))
        log_debug "Download attempt ${attempt}/${retries}: ${url}"
        
        local success=false
        case "${DOWNLOAD_CMD}" in
            curl)
                if curl -fsSL \
                    --connect-timeout 30 \
                    --max-time "${timeout}" \
                    --retry 2 \
                    --retry-delay 5 \
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
        
        if [[ "${success}" == "true" ]] && [[ -s "${output}" ]]; then
            log_debug "Download successful: ${output}"
            return 0
        fi
        
        rm -f "${output}" 2>/dev/null || true
        
        if [[ ${attempt} -lt ${retries} ]]; then
            log_warn "Download failed, retrying in 10 seconds..."
            sleep 10
        fi
    done
    
    log_error "Download failed after ${retries} attempts: ${url}"
    return 1
}

parse_github_release() {
    local json_file="$1"
    local field="$2"
    
    # Validate JSON file exists and is readable
    if [[ ! -f "${json_file}" ]] || [[ ! -r "${json_file}" ]]; then
        log_error "JSON file not found or not readable: ${json_file}"
        return 1
    fi
    
    # Basic JSON validation
    if ! grep -q '^[[:space:]]*{' "${json_file}"; then
        log_error "Invalid JSON format in ${json_file}"
        return 1
    fi
    
    # Try jq first
    if command -v jq &>/dev/null; then
        local result
        result=$(jq -r ".${field} // empty" "${json_file}" 2>/dev/null)
        if [[ -n "${result}" ]]; then
            echo "${result}"
            return 0
        fi
    fi
    
    # Try python3
    if command -v python3 &>/dev/null; then
        local result
        result=$(python3 -c "import sys, json; data=json.load(open('${json_file}')); print(data.get('${field}', ''))" 2>/dev/null)
        if [[ -n "${result}" ]]; then
            echo "${result}"
            return 0
        fi
    fi
    
    # Fallback: basic sed parsing with pre-check
    if ! grep -q "\"${field}\"" "${json_file}"; then
        return 1
    fi
    
    local result
    result=$(sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${json_file}" 2>/dev/null | head -1)
    if [[ -n "${result}" ]]; then
        echo "${result}"
        return 0
    fi
    
    return 1
}

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
    
    local tag_name
    tag_name=$(parse_github_release "${release_file}" "tag_name")
    
    if [[ -z "${tag_name}" ]]; then
        fatal "Failed to parse release information" 5
    fi
    
    if ! validate_version "${tag_name}"; then
        fatal "Invalid version format in release: ${tag_name}" 10
    fi
    
    RELEASE_VERSION="${tag_name}"
    log_info "Found release: ${RELEASE_VERSION}"
}

# ============================================================================
# Detection Functions
# ============================================================================

detect_management_mode() {
    if command -v systemctl &>/dev/null && systemctl is-active --quiet mediamtx 2>/dev/null; then
        echo "systemd"
    elif [[ -d "/var/lib/mediamtx-ffmpeg" ]] && pgrep -f "ffmpeg.*rtsp://localhost" &>/dev/null; then
        echo "stream-manager"
    elif pgrep -x "mediamtx" &>/dev/null; then
        echo "manual"
    else
        echo "none"
    fi
}

find_stream_manager() {
    local locations=(
        "./mediamtx-stream-manager.sh"
        "${SCRIPT_DIR}/mediamtx-stream-manager.sh"
        "/usr/local/bin/mediamtx-stream-manager.sh"
    )
    
    local location
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

build_asset_url() {
    local version="${1#v}"
    local os="$2"
    local arch="$3"
    
    local filename="mediamtx_v${version}_${os}_${arch}.tar.gz"
    echo "https://github.com/${DEFAULT_GITHUB_REPO}/releases/download/v${version}/${filename}"
}

download_mediamtx() {
    local version="$1"
    local os="$2"
    local arch="$3"
    
    local asset_url
    asset_url=$(build_asset_url "${version}" "${os}" "${arch}")
    local archive="${TEMP_DIR}/mediamtx.tar.gz"
    local checksum="${TEMP_DIR}/checksums.sha256"
    local archive_filename
    archive_filename=$(basename "${asset_url}")
    
    log_info "Downloading MediaMTX ${version} for ${os}/${arch}..."
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would download: ${asset_url}"
        log_info "[DRY RUN] Would verify checksum and extract"
        return 0
    fi
    
    # Try primary architecture
    if ! download_file "${asset_url}" "${archive}"; then
        # Fallback for ARM64 alternate naming
        if [[ "${arch}" == "arm64" ]]; then
            log_warn "Trying alternate ARM64 naming (arm64v8)..."
            asset_url=$(build_asset_url "${version}" "${os}" "arm64v8")
            archive_filename=$(basename "${asset_url}")
            if ! download_file "${asset_url}" "${archive}"; then
                fatal "Failed to download MediaMTX" 5
            fi
        else
            fatal "Failed to download MediaMTX" 5
        fi
    fi
    
    # Verify checksum (enforced by default)
    log_info "Verifying download..."
    local checksum_url="https://github.com/${DEFAULT_GITHUB_REPO}/releases/download/v${version}/checksums.sha256"
    if ! download_file "${checksum_url}" "${checksum}"; then
        if [[ "${FORCE_MODE}" != "true" ]]; then
            fatal "Failed to download checksum file (use --force to skip verification)" 6
        fi
        log_warn "Checksum download failed - skipping verification (--force enabled)"
    else
        if ! verify_checksum "${archive}" "${checksum}" "${archive_filename}"; then
            fatal "Checksum verification failed" 6
        fi
    fi
    
    # Extract
    log_info "Extracting archive..."
    if ! tar -xzf "${archive}" -C "${TEMP_DIR}"; then
        fatal "Failed to extract archive" 7
    fi
    
    if [[ ! -f "${TEMP_DIR}/mediamtx" ]]; then
        fatal "Binary not found in archive" 7
    fi
    
    # Verify binary
    if ! "${TEMP_DIR}/mediamtx" --version &>/dev/null; then
        log_warn "Binary version check failed - may not be compatible"
    fi
    
    log_debug "Binary extracted and verified"
}

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
    
    [[ -d "${CONFIG_DIR}" ]] || mkdir -p "${CONFIG_DIR}"
    
    # Backup existing config
    if [[ -f "${config_file}" ]]; then
        CONFIG_BACKUP="${config_file}.backup.$(date +%Y%m%d-%H%M%S)"
        cp "${config_file}" "${CONFIG_BACKUP}"
        log_info "Existing config backed up to: ${CONFIG_BACKUP}"
    fi
    
    cat > "${config_file}" << EOF
###############################################
# MediaMTX Configuration
# Generated by ${SCRIPT_NAME} v${SCRIPT_VERSION}
# Date: $(date -Iseconds)
###############################################

# Global settings
logLevel: info
logDestinations: [stdout]
logFile: ${STATE_DIR}/mediamtx.log

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

paths: {}
  # Define your paths here
EOF
    
    chmod 644 "${config_file}"
    chown root:root "${config_file}" 2>/dev/null || true
    
    log_info "Configuration created: ${config_file}"
}

create_service() {
    if [[ "${SKIP_SERVICE}" == "true" ]]; then
        log_debug "Skipping service creation"
        return 0
    fi
    
    if ! command -v systemctl &>/dev/null; then
        log_warn "systemd not available, skipping service creation"
        return 0
    fi
    
    # Check systemd version for StateDirectory support
    local systemd_version=""
    if systemd_version=$(systemctl --version 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1); then
        if [[ ${systemd_version} -lt 235 ]]; then
            log_warn "systemd ${systemd_version} detected - StateDirectory may not work correctly (requires ≥235)"
        fi
    fi
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would create service: ${SERVICE_NAME}"
        return 0
    fi
    
    local service_file="${SERVICE_DIR}/${SERVICE_NAME}"
    
    # Backup existing service
    if [[ -f "${service_file}" ]]; then
        SERVICE_BACKUP="${service_file}.backup.$(date +%Y%m%d-%H%M%S)"
        cp "${service_file}" "${SERVICE_BACKUP}"
    fi
    
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
Environment="HOME=${STATE_DIR}"
WorkingDirectory=${STATE_DIR}

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mediamtx

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log ${STATE_DIR}
StateDirectory=mediamtx
RuntimeDirectory=mediamtx

# Resource limits
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
    
    chmod 644 "${service_file}"
    systemctl daemon-reload
    
    log_info "Service created: ${SERVICE_NAME}"
}

create_user() {
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would create user: ${SERVICE_USER}"
        return 0
    fi
    
    if id "${SERVICE_USER}" &>/dev/null; then
        log_debug "User ${SERVICE_USER} already exists"
        return 0
    fi
    
    log_info "Creating service user: ${SERVICE_USER}"
    
    if command -v useradd &>/dev/null; then
        useradd --system --home-dir "${STATE_DIR}" --no-create-home \
                --shell /usr/sbin/nologin --comment "MediaMTX service user" "${SERVICE_USER}"
    elif command -v adduser &>/dev/null; then
        adduser --system --home "${STATE_DIR}" --no-create-home \
                --shell /usr/sbin/nologin --group "${SERVICE_USER}"
    else
        log_warn "Cannot create user, no user management command found"
        return 1
    fi
    
    # Create and track state directory
    if [[ ! -d "${STATE_DIR}" ]]; then
        mkdir -p "${STATE_DIR}"
        STATE_DIR_CREATED=true
    fi
    
    chown "${SERVICE_USER}:${SERVICE_GROUP}" "${STATE_DIR}"
    chmod 755 "${STATE_DIR}"
}

# ============================================================================
# Command Functions
# ============================================================================

install_mediamtx() {
    log_info "Installing MediaMTX..."
    
    if [[ -f "${INSTALL_DIR}/mediamtx" ]] && [[ "${FORCE_MODE}" != "true" ]]; then
        fatal "MediaMTX is already installed. Use --force to override or 'update' command" 7
    fi
    
    # Early writability check
    if [[ "${DRY_RUN_MODE}" != "true" ]]; then
        if [[ ! -d "${INSTALL_PREFIX}" ]]; then
            if ! mkdir -p "${INSTALL_PREFIX}" 2>/dev/null; then
                fatal "Cannot create installation prefix: ${INSTALL_PREFIX}" 8
            fi
        fi
        
        if [[ ! -w "${INSTALL_PREFIX}" ]]; then
            fatal "Installation prefix not writable: ${INSTALL_PREFIX}" 8
        fi
        
        # Test actual write access
        local test_file="${INSTALL_PREFIX}/.write_test.$$"
        if ! touch "${test_file}" 2>/dev/null; then
            fatal "Cannot write to installation prefix: ${INSTALL_PREFIX}" 8
        fi
        rm -f "${test_file}"
        log_debug "Write access to ${INSTALL_PREFIX} verified"
    fi
    
    get_release_info "${TARGET_VERSION}"
    download_mediamtx "${RELEASE_VERSION}" "${PLATFORM_OS}" "${PLATFORM_ARCH}"
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would install MediaMTX ${RELEASE_VERSION}"
        return 0
    fi
    
    [[ -d "${INSTALL_DIR}" ]] || mkdir -p "${INSTALL_DIR}"
    
    # Atomic binary installation with cleanup on failure
    log_info "Installing binary..."
    local temp_binary="${INSTALL_DIR}/mediamtx.new.$$"
    if ! install -m 755 "${TEMP_DIR}/mediamtx" "${temp_binary}"; then
        fatal "Failed to prepare binary for installation" 7
    fi
    if ! mv -f "${temp_binary}" "${INSTALL_DIR}/mediamtx"; then
        rm -f "${temp_binary}"
        fatal "Failed to atomically install binary" 7
    fi
    
    create_user
    create_config
    create_service
    
    log_info "MediaMTX ${RELEASE_VERSION} installed successfully!"
    show_post_install_guidance
}

update_mediamtx() {
    log_info "Updating MediaMTX..."
    
    if [[ ! -f "${INSTALL_DIR}/mediamtx" ]]; then
        fatal "MediaMTX is not installed. Use 'install' command first" 7
    fi
    
    # Get current version
    local current_version="unknown"
    if "${INSTALL_DIR}/mediamtx" --version &>/dev/null; then
        current_version=$("${INSTALL_DIR}/mediamtx" --version 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    
    # Get target version
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
    
    # Stop MediaMTX
    stop_mediamtx "${management_mode}"
    
    # Create backup
    BINARY_BACKUP="${INSTALL_DIR}/mediamtx.backup.$(date +%Y%m%d-%H%M%S)"
    cp "${INSTALL_DIR}/mediamtx" "${BINARY_BACKUP}"
    log_info "Current binary backed up to: ${BINARY_BACKUP}"
    
    # Try built-in upgrade if supported
    local upgrade_success=false
    if version_compare "${current_version}" "${MIN_UPGRADE_VERSION}"; then
        log_info "Attempting built-in upgrade (--upgrade)..."
        
        if "${INSTALL_DIR}/mediamtx" --upgrade 2>&1 | tee -a "${LOG_FILE}"; then
            # Verify the upgrade actually worked
            local new_version
            if new_version=$("${INSTALL_DIR}/mediamtx" --version 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1); then
                if [[ "${new_version}" != "${current_version}" ]]; then
                    upgrade_success=true
                    log_info "Built-in upgrade completed successfully (${current_version} → ${new_version})"
                else
                    log_warn "Built-in upgrade reported success but version unchanged"
                fi
            else
                log_warn "Could not verify new version after upgrade"
            fi
        else
            log_warn "Built-in upgrade failed, falling back to manual update"
        fi
    else
        log_debug "Version ${current_version} does not support --upgrade (requires ${MIN_UPGRADE_VERSION}+), using manual update"
    fi
    
    # Manual update if upgrade failed or not supported
    if [[ "${upgrade_success}" != "true" ]]; then
        log_info "Performing manual update..."
        download_mediamtx "${RELEASE_VERSION}" "${PLATFORM_OS}" "${PLATFORM_ARCH}"
        
        # Atomic binary replacement with cleanup on failure
        local temp_binary="${INSTALL_DIR}/mediamtx.new.$$"
        if ! install -m 755 "${TEMP_DIR}/mediamtx" "${temp_binary}"; then
            fatal "Failed to prepare binary for update" 7
        fi
        if ! mv -f "${temp_binary}" "${INSTALL_DIR}/mediamtx"; then
            rm -f "${temp_binary}"
            fatal "Failed to atomically update binary" 7
        fi
    fi
    
    # Verify new version
    if "${INSTALL_DIR}/mediamtx" --version &>/dev/null; then
        local new_version
        new_version=$("${INSTALL_DIR}/mediamtx" --version 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        log_info "Updated to version: ${new_version}"
    fi
    
    # Restart if it was running
    if [[ "${was_running}" == "true" ]]; then
        start_mediamtx "${management_mode}"
    fi
    
    log_info "MediaMTX updated successfully!"
    show_post_update_guidance "${management_mode}"
}

stop_mediamtx() {
    local mode="$1"
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would stop MediaMTX (${mode})"
        return 0
    fi
    
    case "${mode}" in
        systemd)
            log_info "Stopping MediaMTX service..."
            systemctl stop mediamtx || log_warn "Failed to stop service cleanly"
            ;;
        
        stream-manager)
            local stream_manager
            if stream_manager=$(find_stream_manager); then
                log_info "Stopping MediaMTX via stream manager..."
                if ! "${stream_manager}" stop; then
                    log_warn "Stream manager stop failed, using manual stop"
                    pkill -f "ffmpeg.*rtsp://localhost" 2>/dev/null || true
                    pkill mediamtx 2>/dev/null || true
                fi
            else
                log_info "Stopping MediaMTX manually..."
                pkill -f "ffmpeg.*rtsp://localhost" 2>/dev/null || true
                pkill mediamtx 2>/dev/null || true
            fi
            ;;
        
        manual|*)
            log_info "Stopping MediaMTX..."
            pkill mediamtx 2>/dev/null || true
            ;;
    esac
    
    # Wait for processes to stop
    sleep 2
    
    # Force kill if still running
    if pgrep -x "mediamtx" &>/dev/null; then
        log_warn "MediaMTX still running, forcing stop..."
        pkill -9 mediamtx 2>/dev/null || true
        sleep 1
    fi
}

start_mediamtx() {
    local mode="$1"
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would start MediaMTX (${mode})"
        return 0
    fi
    
    case "${mode}" in
        systemd)
            log_info "Starting MediaMTX service..."
            systemctl start mediamtx || log_error "Failed to start service"
            ;;
        
        stream-manager)
            local stream_manager
            if stream_manager=$(find_stream_manager); then
                log_info "Starting MediaMTX via stream manager..."
                if ! "${stream_manager}" start; then
                    log_warn "Please manually start with: sudo ${stream_manager} start"
                fi
            else
                log_warn "Please manually restart MediaMTX with your stream manager"
            fi
            ;;
        
        manual|*)
            log_info "Please manually restart MediaMTX"
            ;;
    esac
}

uninstall_mediamtx() {
    log_info "Uninstalling MediaMTX..."
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would uninstall MediaMTX"
        return 0
    fi
    
    # Stop and remove service
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
        rm -f "${INSTALL_DIR}"/mediamtx.new.* 2>/dev/null || true
    fi
    
    # Remove config (with confirmation)
    if [[ -d "${CONFIG_DIR}" ]]; then
        if [[ "${FORCE_MODE}" == "true" ]]; then
            rm -rf "${CONFIG_DIR}"
            log_info "Configuration removed"
        else
            echo -en "${YELLOW}Remove configuration directory ${CONFIG_DIR}? [y/N] ${NC}"
            read -r response
            if [[ "${response}" =~ ^[Yy]$ ]]; then
                rm -rf "${CONFIG_DIR}"
                log_info "Configuration removed"
            fi
        fi
    fi
    
    # Remove state directory (with confirmation)
    if [[ -d "${STATE_DIR}" ]]; then
        if [[ "${FORCE_MODE}" == "true" ]]; then
            rm -rf "${STATE_DIR}"
            log_info "State directory removed"
        else
            echo -en "${YELLOW}Remove state directory ${STATE_DIR}? [y/N] ${NC}"
            read -r response
            if [[ "${response}" =~ ^[Yy]$ ]]; then
                rm -rf "${STATE_DIR}"
                log_info "State directory removed"
            fi
        fi
    fi
    
    # Remove user (with confirmation)
    if id "${SERVICE_USER}" &>/dev/null; then
        if [[ "${FORCE_MODE}" == "true" ]]; then
            userdel "${SERVICE_USER}" 2>/dev/null || true
            log_info "Service user removed"
        else
            echo -en "${YELLOW}Remove service user ${SERVICE_USER}? [y/N] ${NC}"
            read -r response
            if [[ "${response}" =~ ^[Yy]$ ]]; then
                userdel "${SERVICE_USER}" 2>/dev/null || true
                log_info "Service user removed"
            fi
        fi
    fi
    
    log_info "MediaMTX uninstalled successfully!"
}

# ============================================================================
# Status Functions
# ============================================================================

show_status() {
    echo -e "${BOLD}MediaMTX Installation Status${NC}"
    echo "================================"
    
    # Installation
    if [[ -f "${INSTALL_DIR}/mediamtx" ]]; then
        echo -e "Installation: ${GREEN}✓ Installed${NC}"
        echo "Location: ${INSTALL_DIR}/mediamtx"
        
        local version="unknown"
        if "${INSTALL_DIR}/mediamtx" --version &>/dev/null; then
            version=$("${INSTALL_DIR}/mediamtx" --version 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        fi
        echo "Version: ${version}"
    else
        echo -e "Installation: ${RED}✗ Not installed${NC}"
    fi
    
    # Configuration
    echo ""
    if [[ -f "${CONFIG_DIR}/${CONFIG_NAME}" ]]; then
        echo -e "Configuration: ${GREEN}✓ Present${NC}"
        echo "Config file: ${CONFIG_DIR}/${CONFIG_NAME}"
    else
        echo -e "Configuration: ${YELLOW}⚠ Missing${NC}"
    fi
    
    # Service and process status
    echo ""
    local management_mode
    management_mode=$(detect_management_mode)
    
    if command -v systemctl &>/dev/null && [[ -f "${SERVICE_DIR}/${SERVICE_NAME}" ]]; then
        echo -e "Service: ${GREEN}✓ Configured${NC}"
    else
        echo -e "Service: ${YELLOW}⚠ Not configured${NC}"
    fi
    
    case "${management_mode}" in
        systemd)
            echo -e "Status: ${GREEN}● Running (systemd)${NC}"
            ;;
        stream-manager)
            echo -e "Status: ${YELLOW}⚠ Running (stream manager)${NC}"
            ;;
        manual)
            echo -e "Status: ${YELLOW}⚠ Running (manual)${NC}"
            ;;
        none)
            echo -e "Status: ${RED}○ Not running${NC}"
            ;;
    esac
    
    # Port status
    if command -v lsof &>/dev/null || command -v ss &>/dev/null; then
        echo ""
        echo "Port Status:"
        local ports=("${DEFAULT_RTSP_PORT}" "${DEFAULT_API_PORT}" "${DEFAULT_METRICS_PORT}")
        local labels=("RTSP" "API" "Metrics")
        
        local i
        for i in "${!ports[@]}"; do
            local port="${ports[$i]}"
            local label="${labels[$i]}"
            local port_status=""
            local port_user=""
            
            # Try lsof first
            if command -v lsof &>/dev/null; then
                port_user=$(lsof -i ":${port}" -sTCP:LISTEN 2>/dev/null | tail -n1 | awk '{print $1}' || echo "")
            fi
            
            # Fallback to ss if lsof didn't find anything
            if [[ -z "${port_user}" ]] && command -v ss &>/dev/null; then
                port_status=$(ss -ltn "sport = :${port}" 2>/dev/null | grep -v "State" || echo "")
            fi
            
            if [[ -n "${port_user}" ]]; then
                if [[ "${port_user}" == "mediamtx" ]]; then
                    echo -e "  ${label} (${port}): ${GREEN}✓ In use by MediaMTX${NC}"
                else
                    echo -e "  ${label} (${port}): ${GREEN}✓ In use by ${port_user}${NC}"
                fi
            elif [[ -n "${port_status}" ]]; then
                echo -e "  ${label} (${port}): ${GREEN}✓ In use${NC}"
            else
                if [[ "${management_mode}" == "stream-manager" ]] || [[ "${management_mode}" == "systemd" ]]; then
                    echo -e "  ${label} (${port}): ${YELLOW}⚠ Status unknown${NC}"
                else
                    echo -e "  ${label} (${port}): ${YELLOW}○ Not in use${NC}"
                fi
            fi
        done
    fi
}

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
    
    # Check config
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
    
    echo ""
    if [[ ${errors} -eq 0 ]] && [[ ${warnings} -eq 0 ]]; then
        log_info "✓ Installation verified successfully"
        return 0
    elif [[ ${errors} -eq 0 ]]; then
        log_warn "Installation verified with ${warnings} warning(s)"
        return 0
    else
        log_error "Verification failed: ${errors} error(s), ${warnings} warning(s)"
        return 1
    fi
}

# ============================================================================
# Guidance Functions
# ============================================================================

show_post_install_guidance() {
    local stream_manager
    stream_manager=$(find_stream_manager 2>/dev/null || echo "")
    
    echo ""
    if [[ -n "${stream_manager}" ]]; then
        echo "================================"
        echo "Audio Streaming Setup Detected!"
        echo "================================"
        echo ""
        echo "Option 1: Stream Manager (Recommended)"
        echo "  sudo ${stream_manager} start"
        echo ""
        echo "Option 2: Systemd Service"
        echo "  sudo systemctl start mediamtx"
        echo "  sudo systemctl enable mediamtx"
    else
        if command -v systemctl &>/dev/null && [[ -f "${SERVICE_DIR}/${SERVICE_NAME}" ]]; then
            echo ""
            echo "To start MediaMTX:"
            echo "  sudo systemctl start mediamtx"
            echo "  sudo systemctl enable mediamtx"
        else
            echo ""
            echo "To start MediaMTX:"
            echo "  ${INSTALL_DIR}/mediamtx ${CONFIG_DIR}/${CONFIG_NAME}"
        fi
    fi
}

show_post_update_guidance() {
    local mode="${1:-none}"
    
    case "${mode}" in
        systemd)
            echo ""
            echo "Quick Commands:"
            echo "  • Status: sudo systemctl status mediamtx"
            echo "  • Logs:   sudo journalctl -u mediamtx -f"
            ;;
        stream-manager)
            echo ""
            echo "Quick Commands:"
            echo "  • Status: sudo ./mediamtx-stream-manager.sh status"
            echo "  • Logs:   tail -f /var/lib/mediamtx-ffmpeg/*.log"
            ;;
    esac
}

show_help() {
    cat << EOF
${BOLD}MediaMTX Installation Manager v${SCRIPT_VERSION}${NC}

Production-ready installer for MediaMTX with built-in upgrade support.

${BOLD}USAGE:${NC}
    ${SCRIPT_NAME} [OPTIONS] COMMAND

${BOLD}COMMANDS:${NC}
    install     Install MediaMTX
    update      Update to latest version (uses built-in --upgrade when available)
    uninstall   Remove MediaMTX
    status      Show installation status
    verify      Verify installation integrity
    help        Show this help message

${BOLD}OPTIONS:${NC}
    -c, --config FILE           Use configuration file
    -v, --verbose              Enable verbose output
    -q, --quiet                Suppress non-error output
    -n, --dry-run              Show what would be done
    -f, --force                Force operation (skip confirmations/checksums)
    -V, --target-version VER   Install specific version
    -p, --prefix DIR           Installation prefix (default: ${DEFAULT_INSTALL_PREFIX})
    --version                  Show script version
    --no-service               Skip systemd service creation
    --no-config                Skip configuration file creation

${BOLD}EXAMPLES:${NC}
    # Install latest version
    sudo ${SCRIPT_NAME} install

    # Update using built-in upgrade (MediaMTX v${MIN_UPGRADE_VERSION}+)
    sudo ${SCRIPT_NAME} update

    # Install specific version
    sudo ${SCRIPT_NAME} -V v1.15.0 install

    # Dry run
    sudo ${SCRIPT_NAME} -n update

    # Show script version
    ${SCRIPT_NAME} --version

${BOLD}FILES:${NC}
    Binary:  ${INSTALL_DIR}/mediamtx
    Config:  ${CONFIG_DIR}/${CONFIG_NAME}
    State:   ${STATE_DIR}
    Service: ${SERVICE_DIR}/${SERVICE_NAME}

${BOLD}ENVIRONMENT VARIABLES:${NC}
    MEDIAMTX_PREFIX       Installation prefix
    MEDIAMTX_CONFIG_DIR   Configuration directory
    MEDIAMTX_STATE_DIR    State directory
    MEDIAMTX_USER         Service user name
    MEDIAMTX_GROUP        Service group name

${BOLD}UPDATE NOTES:${NC}
    The update command uses MediaMTX's built-in --upgrade functionality
    when available (v${MIN_UPGRADE_VERSION}+). This simplifies updates and ensures
    platform compatibility. Falls back to manual update for older versions.

${BOLD}GITHUB:${NC}
    https://github.com/${DEFAULT_GITHUB_REPO}
    
EOF
}

# ============================================================================
# Main
# ============================================================================

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
            -V|--target-version)
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
            --version)
                echo "${SCRIPT_NAME} version ${SCRIPT_VERSION}"
                exit 0
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
    
    COMMAND="${args[0]:-}"
    
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

main() {
    parse_arguments "$@"
    initialize_runtime_vars
    create_temp_dir
    load_config
    validate_input
    
    if [[ "${COMMAND}" == "help" ]]; then
        show_help
        exit 0
    fi
    
    # Root check for destructive operations
    if [[ "${COMMAND}" =~ ^(install|update|uninstall)$ ]] && [[ "${DRY_RUN_MODE}" != "true" ]]; then
        if [[ ${EUID} -ne 0 ]]; then
            fatal "This operation requires root privileges. Please run with sudo." 2
        fi
    fi
    
    # Lock for install/update/uninstall
    if [[ "${COMMAND}" =~ ^(install|update|uninstall)$ ]]; then
        acquire_lock 30
    fi
    
    check_requirements
    detect_platform
    
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

main "$@"

#!/usr/bin/env bash
#
# MediaMTX Installation Manager - Production-Ready Install/Update/Uninstall
# Version: 1.2.0
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# Changelog:
#   v1.2.0: Fixed checksum URL to use unified checksums.sha256 file
#   v1.1.x: Resolved shellcheck warnings, fixed readonly vars, added rollback system
#   v1.1.0: Added stream manager integration, dry-run mode, SemVer comparison
#
# Usage: ./mediamtx-installer.sh [OPTIONS] COMMAND

set -euo pipefail

# Strict error handling
set -o errtrace
set -o functrace

# Script metadata - CRITICAL: assign BEFORE making readonly
SCRIPT_VERSION="1.2.0"
readonly SCRIPT_VERSION

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR

SCRIPT_PID="$$"
readonly SCRIPT_PID

# SCRIPT_PPID kept for process tracking
SCRIPT_PPID="$PPID"
# shellcheck disable=SC2034
readonly SCRIPT_PPID

# Default configuration
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

# Runtime configuration
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
COMMAND=""

# Derived paths
INSTALL_DIR="${INSTALL_PREFIX}/bin"
SERVICE_DIR="/etc/systemd/system"
SERVICE_NAME="mediamtx.service"
CONFIG_NAME="mediamtx.yml"

# Temporary directory
TEMP_BASE="${TMPDIR:-/tmp}"
TEMP_DIR=""
LOG_FILE=""
LOCK_FILE="/var/lock/mediamtx-installer.lock"
LOCK_FD=""

# GitHub API configuration
readonly GITHUB_API_BASE="https://api.github.com"
readonly GITHUB_API_TIMEOUT=30
USER_AGENT="MediaMTX-Installer/${SCRIPT_VERSION}"
readonly USER_AGENT

# Color codes (set after argument parsing)
RED=''
GREEN=''
YELLOW=''
BLUE=''
# MAGENTA and CYAN for future use
# shellcheck disable=SC2034
MAGENTA=''
# shellcheck disable=SC2034
CYAN=''
BOLD=''
NC=''

# Arrays for cleanup
declare -a CLEANUP_FILES=()
declare -a CLEANUP_DIRS=()

# Rollback registry
declare -A ROLLBACK_REGISTRY=(
    ["mv"]="rollback_mv"
    ["rm"]="rollback_rm"
    ["systemctl"]="rollback_systemctl"
    ["userdel"]="rollback_userdel"
)

# Rollback queue file
ROLLBACK_QUEUE=""

# Download command (set in check_requirements)
DOWNLOAD_CMD=""

# Release information
RELEASE_VERSION=""
# shellcheck disable=SC2034
RELEASE_FILE=""

# Platform information
PLATFORM_OS=""
PLATFORM_ARCH=""
PLATFORM_DISTRO=""
PLATFORM_VERSION=""

# ============================================================================
# Rollback Functions
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

add_rollback() {
    local cmd="$1"
    shift
    
    if [[ -n "${ROLLBACK_REGISTRY[$cmd]:-}" ]]; then
        if [[ -n "${ROLLBACK_QUEUE}" ]] && [[ -f "${ROLLBACK_QUEUE}" ]]; then
            printf '%s\0' "${cmd}" "$@" >> "${ROLLBACK_QUEUE}"
        fi
    else
        log_warn "Invalid rollback command: ${cmd}"
    fi
}

execute_rollback() {
    [[ -z "${ROLLBACK_QUEUE}" ]] || [[ ! -f "${ROLLBACK_QUEUE}" ]] && return 0
    
    local entries=()
    while IFS= read -r -d '' entry; do
        entries+=("${entry}")
    done < "${ROLLBACK_QUEUE}"
    
    local i=${#entries[@]}
    while [[ $i -gt 0 ]]; do
        ((i--))
        local cmd="${entries[$i]}"
        local args=()
        
        while [[ $i -gt 0 ]]; do
            ((i--))
            local next="${entries[$i]}"
            if [[ -n "${ROLLBACK_REGISTRY[$next]:-}" ]]; then
                ((i++))
                break
            fi
            args=("${next}" "${args[@]}")
        done
        
        if [[ -n "${ROLLBACK_REGISTRY[$cmd]:-}" ]]; then
            "${ROLLBACK_REGISTRY[$cmd]}" "${args[@]}"
        fi
    done
}

# ============================================================================
# Utility Functions
# ============================================================================

initialize_runtime_vars() {
    if [[ -t 1 ]] && [[ "${QUIET_MODE}" != "true" ]]; then
        RED='\033[0;31m'
        GREEN='\033[0;32m'
        YELLOW='\033[1;33m'
        BLUE='\033[0;34m'
        # shellcheck disable=SC2034
        MAGENTA='\033[0;35m'
        # shellcheck disable=SC2034
        CYAN='\033[0;36m'
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

cleanup() {
    local exit_code=$?
    
    release_lock
    
    if [[ ${exit_code} -ne 0 ]]; then
        log_warn "Executing rollback actions..."
        execute_rollback
    fi
    
    for file in "${CLEANUP_FILES[@]}"; do
        if [[ -f "${file}" ]]; then
            rm -f "${file}" 2>/dev/null || true
        fi
    done
    
    for dir in "${CLEANUP_DIRS[@]}"; do
        if [[ -d "${dir}" ]]; then
            rm -rf "${dir}" 2>/dev/null || true
        fi
    done
    
    if [[ -n "${TEMP_DIR}" ]] && [[ -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}" 2>/dev/null || true
    fi
    
    if [[ ${exit_code} -ne 0 ]] && [[ -f "${LOG_FILE}" ]]; then
        local error_log
        error_log="/tmp/mediamtx-installer-error-$(date +%Y%m%d-%H%M%S).log"
        cp "${LOG_FILE}" "${error_log}" 2>/dev/null || true
        [[ "${QUIET_MODE}" != "true" ]] && echo -e "${YELLOW}Error log saved to: ${error_log}${NC}" >&2
    fi
    
    return ${exit_code}
}

trap cleanup EXIT INT TERM

# Logging functions
log_debug() {
    [[ "${VERBOSE_MODE}" == "true" ]] || return 0
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
    
    if [[ "$(uname)" == "Darwin" ]] || [[ "$(uname)" == *"BSD"* ]]; then
        if command -v timeout &>/dev/null; then
            if timeout "${timeout}" flock -x 200; then
                echo "${SCRIPT_PID}" > "${LOCK_FILE}.pid"
                log_debug "Lock acquired (PID: ${SCRIPT_PID})"
                return 0
            fi
        else
            if flock -x 200; then
                echo "${SCRIPT_PID}" > "${LOCK_FILE}.pid"
                log_debug "Lock acquired (PID: ${SCRIPT_PID})"
                return 0
            fi
        fi
    else
        if flock -x -w "${timeout}" 200; then
            echo "${SCRIPT_PID}" > "${LOCK_FILE}.pid"
            log_debug "Lock acquired (PID: ${SCRIPT_PID})"
            return 0
        fi
    fi
    
    exec 200>&-
    LOCK_FD=""
    fatal "Failed to acquire lock after ${timeout} seconds" 1
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
    
    ROLLBACK_QUEUE="${TEMP_DIR}/.rollback_queue"
    touch "${ROLLBACK_QUEUE}"
    chmod 600 "${ROLLBACK_QUEUE}"
    
    CLEANUP_DIRS+=("${TEMP_DIR}")
    log_debug "Created temporary directory: ${TEMP_DIR}"
}

load_config() {
    [[ -z "${CONFIG_FILE}" || ! -f "${CONFIG_FILE}" ]] && return 0
    
    log_debug "Loading configuration from: ${CONFIG_FILE}"
    
    while IFS='=' read -r key value || [[ -n "${key}" ]]; do
        [[ -z "${key}" || "${key}" == \#* ]] && continue
        
        key=$(echo "${key}" | xargs)
        value=$(echo "${value}" | xargs)
        
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"
        
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

validate_input() {
    if [[ "${INSTALL_PREFIX}" != /* ]]; then
        fatal "Installation prefix must be an absolute path" 10
    fi
    
    if [[ "${INSTALL_PREFIX}" == *..* ]]; then
        fatal "Installation prefix cannot contain .." 10
    fi
    
    if [[ -n "${TARGET_VERSION}" ]]; then
        if ! validate_version "${TARGET_VERSION}"; then
            fatal "Invalid version format: ${TARGET_VERSION}" 10
        fi
    fi
    
    if [[ -n "${CONFIG_FILE}" ]]; then
        if [[ ! -f "${CONFIG_FILE}" ]]; then
            fatal "Config file not found: ${CONFIG_FILE}" 9
        fi
        if [[ ! -r "${CONFIG_FILE}" ]]; then
            fatal "Config file not readable: ${CONFIG_FILE}" 9
        fi
    fi
}

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
    
    # Optional commands
    local -A optional_commands=(
        ["jq"]="1.5"
        ["sha256sum"]=""
        ["systemctl"]=""
        ["gpg"]="2.0"
        ["lsof"]=""
    )
    
    for cmd in "${!required_commands[@]}"; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        elif [[ -n "${required_commands[$cmd]}" ]]; then
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
    
    for cmd in "${!optional_commands[@]}"; do
        if ! command -v "${cmd}" &>/dev/null; then
            warnings+=("Optional: ${cmd} not found")
        fi
    done
    
    if ! command -v jq &>/dev/null; then
        log_warn "jq not found - using fallback JSON parsing"
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        fatal "Missing required commands: ${missing[*]}" 4
    fi
    
    if [[ ${#warnings[@]} -gt 0 ]] && [[ "${VERBOSE_MODE}" == "true" ]]; then
        for warning in "${warnings[@]}"; do
            log_warn "${warning}"
        done
    fi
    
    if command -v curl &>/dev/null; then
        DOWNLOAD_CMD="curl"
    elif command -v wget &>/dev/null; then
        DOWNLOAD_CMD="wget"
    else
        fatal "Neither curl nor wget found" 4
    fi
    
    log_debug "Using ${DOWNLOAD_CMD} for downloads"
}

version_compare() {
    local v1="${1#v}"
    local v2="${2#v}"
    
    if command -v sort &>/dev/null && sort --help 2>&1 | grep -q -- '-V'; then
        if [[ "$(printf '%s\n' "${v2}" "${v1}" | sort -V | head -n1)" == "${v2}" ]]; then
            return 0
        else
            return 1
        fi
    fi
    
    local v1_base="${v1%%-*}"
    local v2_base="${v2%%-*}"
    
    local IFS=.
    local -a v1_parts
    local -a v2_parts
    read -r -a v1_parts <<< "$v1_base"
    read -r -a v2_parts <<< "$v2_base"
    
    for i in {0..2}; do
        local p1="${v1_parts[$i]:-0}"
        local p2="${v2_parts[$i]:-0}"
        
        if [[ ${p1} -gt ${p2} ]]; then return 0; fi
        if [[ ${p1} -lt ${p2} ]]; then return 1; fi
    done
    
    # Handle pre-release versions
    if [[ "$v1" == "$v1_base" ]] && [[ "$v2" != "$v2_base" ]]; then
        return 0
    elif [[ "$v1" != "$v1_base" ]] && [[ "$v2" == "$v2_base" ]]; then
        return 1
    elif [[ "$v1" != "$v1_base" ]] && [[ "$v2" != "$v2_base" ]]; then
        local v1_pre="${v1#*-}"
        local v2_pre="${v2#*-}"
        [[ "$v1_pre" > "$v2_pre" ]] && return 0 || return 1
    fi
    
    return 0
}

validate_url() {
    local url="$1"
    local url_regex='^https?://[-A-Za-z0-9\+&@#/%?=~_|!:,.;]*[-A-Za-z0-9\+&@#/%=~_|]$'
    
    if [[ ! "${url}" =~ ${url_regex} ]]; then
        log_error "Invalid URL format: ${url}"
        return 1
    fi
    return 0
}

validate_version() {
    local version="$1"
    local version_regex='^v?[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9\-\.]+)?$'
    
    if [[ ! "${version}" =~ ${version_regex} ]]; then
        log_error "Invalid version format: ${version}"
        return 1
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
        log_warn "Checksum file not found: ${checksum_file}"
        return 2
    fi
    
    # Extract checksum for our specific file from the unified checksums file
    local expected_checksum
    expected_checksum=$(grep "${filename}" "${checksum_file}" 2>/dev/null | awk '{print $1}' | head -1)
    
    if [[ -z "${expected_checksum}" ]]; then
        log_error "Failed to find checksum for ${filename} in checksums file"
        return 1
    fi
    
    local actual_checksum
    if command -v sha256sum &>/dev/null; then
        actual_checksum=$(sha256sum "${file}" | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        actual_checksum=$(shasum -a 256 "${file}" | awk '{print $1}')
    else
        log_warn "No SHA256 tool available, skipping verification"
        return 2
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

detect_platform() {
    local os=""
    local arch=""
    local distro=""
    local version=""
    
    case "${OSTYPE}" in
        linux*)
            os="linux"
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
    PLATFORM_DISTRO="${distro}"
    PLATFORM_VERSION="${version}"
    
    log_debug "Platform: ${PLATFORM_OS}/${PLATFORM_ARCH} (${PLATFORM_DISTRO} ${PLATFORM_VERSION})"
}

# ============================================================================
# Download Functions
# ============================================================================

download_file() {
    local url="$1"
    local output="$2"
    local timeout="${3:-${DEFAULT_DOWNLOAD_TIMEOUT}}"
    local retries="${4:-${DEFAULT_DOWNLOAD_RETRIES}}"
    
    local is_metadata=false
    if [[ "${url}" == *"api.github.com"* ]] || \
       [[ "${url}" == *"checksums.sha256" ]] || \
       [[ "${url}" == *".sig" ]] || \
       [[ "${output}" == *"/release.json" ]] || \
       [[ "${output}" == *"/checksum"* ]]; then
        is_metadata=true
    fi
    
    if [[ "${DRY_RUN_MODE}" == "true" ]] && [[ "${is_metadata}" == "false" ]]; then
        log_info "[DRY RUN] Would download: ${url} -> ${output}"
        return 0
    fi
    
    if ! validate_url "${url}"; then
        return 1
    fi
    
    local attempt=0
    local success=false
    
    while [[ ${attempt} -lt ${retries} ]] && [[ "${success}" == "false" ]]; do
        ((attempt++))
        log_debug "Download attempt ${attempt}/${retries}: ${url}"
        
        local output_dir
        output_dir=$(dirname "${output}")
        [[ -d "${output_dir}" ]] || mkdir -p "${output_dir}"
        
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

parse_github_release() {
    local json_file="$1"
    local field="$2"
    
    if command -v jq &>/dev/null; then
        jq -r ".${field} // empty" "${json_file}" 2>/dev/null || echo ""
        return
    fi
    
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
    
    local value=""
    if grep -q "\"${field}\"" "${json_file}" 2>/dev/null; then
        value=$(sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${json_file}" 2>/dev/null | head -1)
    fi
    
    echo "${value}"
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
    # shellcheck disable=SC2034
    RELEASE_FILE="${release_file}"
    
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

build_asset_url() {
    local version="${1#v}"
    local os="$2"
    local arch="$3"
    
    local arch_suffix="${arch}"
    
    if [[ "${arch}" == "arm64" ]] && [[ "${os}" == "linux" ]]; then
        local major minor patch
        IFS='.' read -r major minor patch <<< "${version}"
        local version_num=$((major * 10000 + minor * 100 + ${patch%%-*}))
        
        if [[ ${version_num} -lt 11201 ]]; then
            arch_suffix="arm64v8"
        fi
    fi
    
    local filename="mediamtx_v${version}_${os}_${arch_suffix}.tar.gz"
    local url="https://github.com/${DEFAULT_GITHUB_REPO}/releases/download/v${version}/${filename}"
    
    echo "${url}"
}

download_mediamtx() {
    local version="$1"
    local os="$2"
    local arch="$3"
    
    local asset_url
    asset_url=$(build_asset_url "${version}" "${os}" "${arch}")
    
    local archive="${TEMP_DIR}/mediamtx.tar.gz"
    local checksum="${TEMP_DIR}/checksums.sha256"
    
    # Extract just the filename for checksum verification
    local archive_filename
    archive_filename=$(basename "${asset_url}")
    
    log_info "Downloading MediaMTX ${version} for ${os}/${arch}..."
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would download: ${asset_url}"
        log_info "[DRY RUN] Would verify checksum if available"
        log_info "[DRY RUN] Would extract and install binary"
        return 0
    fi
    
    if ! download_file "${asset_url}" "${archive}"; then
        if [[ "${arch}" == "arm64" ]]; then
            log_warn "Trying alternate ARM64 naming..."
            local alt_arch="arm64v8"
            [[ "${asset_url}" == *"arm64v8"* ]] && alt_arch="arm64"
            
            asset_url=$(build_asset_url "${version}" "${os}" "${alt_arch}")
            archive_filename=$(basename "${asset_url}")
            if ! download_file "${asset_url}" "${archive}"; then
                fatal "Failed to download MediaMTX" 5
            fi
        else
            fatal "Failed to download MediaMTX" 5
        fi
    fi
    
    # Download the unified checksums file
    log_info "Verifying download..."
    local checksum_url="https://github.com/${DEFAULT_GITHUB_REPO}/releases/download/${version}/checksums.sha256"
    if download_file "${checksum_url}" "${checksum}"; then
        if ! verify_checksum "${archive}" "${checksum}" "${archive_filename}"; then
            fatal "Checksum verification failed" 6
        fi
    else
        log_warn "Checksum file not available, skipping verification"
    fi
    
    if [[ "${VERIFY_GPG}" == "true" ]]; then
        local sig_file="${TEMP_DIR}/mediamtx.tar.gz.sig"
        if download_file "${asset_url}.sig" "${sig_file}"; then
            verify_gpg_signature "${archive}" "${sig_file}" || true
        fi
    fi
    
    log_info "Extracting archive..."
    if ! tar -xzf "${archive}" -C "${TEMP_DIR}"; then
        fatal "Failed to extract archive" 7
    fi
    
    if [[ ! -f "${TEMP_DIR}/mediamtx" ]]; then
        fatal "Binary not found in archive" 7
    fi
    
    if ! "${TEMP_DIR}/mediamtx" --version &>/dev/null; then
        log_warn "Binary version check failed"
    fi
    
    log_debug "Binary extracted successfully"
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
    
    if [[ -f "${config_file}" ]]; then
        local backup
        backup="${config_file}.backup.$(date +%Y%m%d-%H%M%S)"
        cp "${config_file}" "${backup}"
        log_info "Existing config backed up to: ${backup}"
        add_rollback "mv" "${backup}" "${config_file}"
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

paths:
  # Define your paths here
  # Example:
  # mystream:
  #   source: rtsp://192.168.1.100:554/stream
EOF
    
    chmod 644 "${config_file}"
    chown root:root "${config_file}"
    
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
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would create service: ${SERVICE_NAME}"
        return 0
    fi
    
    local service_file="${SERVICE_DIR}/${SERVICE_NAME}"
    
    if [[ -f "${service_file}" ]]; then
        local backup
        backup="${service_file}.backup.$(date +%Y%m%d-%H%M%S)"
        cp "${service_file}" "${backup}"
        add_rollback "mv" "${backup}" "${service_file}"
    fi
    
    # Create service with full security hardening
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
    
    mkdir -p /var/lib/mediamtx
    chown "${SERVICE_USER}:${SERVICE_GROUP}" /var/lib/mediamtx
    chmod 755 /var/lib/mediamtx
    
    add_rollback "userdel" "${SERVICE_USER}"
}

# ============================================================================
# Command Functions
# ============================================================================

install_mediamtx() {
    log_info "Installing MediaMTX..."
    
    if [[ -f "${INSTALL_DIR}/mediamtx" ]] && [[ "${FORCE_MODE}" != "true" ]]; then
        fatal "MediaMTX is already installed. Use --force to override or 'update' command" 7
    fi
    
    get_release_info "${TARGET_VERSION}"
    download_mediamtx "${RELEASE_VERSION}" "${PLATFORM_OS}" "${PLATFORM_ARCH}"
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would install MediaMTX ${RELEASE_VERSION}"
        return 0
    fi
    
    [[ -d "${INSTALL_DIR}" ]] || mkdir -p "${INSTALL_DIR}"
    
    log_info "Installing binary..."
    install -m 755 "${TEMP_DIR}/mediamtx" "${INSTALL_DIR}/"
    add_rollback "rm" "${INSTALL_DIR}/mediamtx"
    
    create_user
    create_config
    create_service
    
    if "${INSTALL_DIR}/mediamtx" --version &>/dev/null; then
        log_info "Installation verified successfully"
    else
        log_warn "Could not verify installation"
    fi
    
    log_info "MediaMTX ${RELEASE_VERSION} installed successfully!"
    
    show_post_install_guidance
}

update_mediamtx() {
    log_info "Updating MediaMTX..."
    
    if [[ ! -f "${INSTALL_DIR}/mediamtx" ]]; then
        fatal "MediaMTX is not installed. Use 'install' command first" 7
    fi
    
    local current_version="unknown"
    if "${INSTALL_DIR}/mediamtx" --version &>/dev/null; then
        current_version=$("${INSTALL_DIR}/mediamtx" --version 2>&1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    
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
    
    local management_mode
    management_mode=$(detect_management_mode)
    local was_running=false
    [[ "${management_mode}" != "none" ]] && was_running=true
    
    local active_streams=()
    if [[ "${management_mode}" == "stream-manager" ]]; then
        mapfile -t active_streams < <(get_active_streams)
        log_info "Detected ${#active_streams[@]} active streams"
    fi
    
    stop_mediamtx "${management_mode}"
    
    local backup
    backup="${INSTALL_DIR}/mediamtx.backup.$(date +%Y%m%d-%H%M%S)"
    cp "${INSTALL_DIR}/mediamtx" "${backup}"
    add_rollback "mv" "${backup}" "${INSTALL_DIR}/mediamtx"
    log_info "Current binary backed up to: ${backup}"
    
    download_mediamtx "${RELEASE_VERSION}" "${PLATFORM_OS}" "${PLATFORM_ARCH}"
    
    install -m 755 "${TEMP_DIR}/mediamtx" "${INSTALL_DIR}/"
    
    if [[ "${was_running}" == "true" ]]; then
        start_mediamtx "${management_mode}"
        
        if [[ ${#active_streams[@]} -gt 0 ]]; then
            log_info "Restarted streams: ${active_streams[*]}"
        fi
    fi
    
    log_info "MediaMTX updated to ${RELEASE_VERSION} successfully!"
    
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
    
    sleep 2
    
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

uninstall_mediamtx() {
    log_info "Uninstalling MediaMTX..."
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        log_info "[DRY RUN] Would uninstall MediaMTX"
        return 0
    fi
    
    if command -v systemctl &>/dev/null && [[ -f "${SERVICE_DIR}/${SERVICE_NAME}" ]]; then
        log_info "Stopping and disabling service..."
        systemctl stop mediamtx 2>/dev/null || true
        systemctl disable mediamtx 2>/dev/null || true
        rm -f "${SERVICE_DIR}/${SERVICE_NAME}"
        systemctl daemon-reload
    fi
    
    if [[ -f "${INSTALL_DIR}/mediamtx" ]]; then
        log_info "Removing binary..."
        rm -f "${INSTALL_DIR}/mediamtx"
        rm -f "${INSTALL_DIR}"/mediamtx.backup.* 2>/dev/null || true
    fi
    
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
# Status Functions
# ============================================================================

show_status() {
    echo -e "${BOLD}MediaMTX Installation Status${NC}"
    echo "================================"
    
    # Installation status
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
    
    # Configuration status
    echo ""
    if [[ -f "${CONFIG_DIR}/${CONFIG_NAME}" ]]; then
        echo -e "Configuration: ${GREEN}✓ Present${NC}"
        echo "Config file: ${CONFIG_DIR}/${CONFIG_NAME}"
    else
        echo -e "Configuration: ${YELLOW}⚠ Missing${NC}"
    fi
    
    # Process status
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
    
    # Port status
    if command -v lsof &>/dev/null; then
        echo ""
        echo "Port Status:"
        
        local ports=("${DEFAULT_RTSP_PORT}" "${DEFAULT_API_PORT}" "${DEFAULT_METRICS_PORT}")
        local labels=("RTSP" "API" "Metrics")
        
        for i in "${!ports[@]}"; do
            local port="${ports[$i]}"
            local label="${labels[$i]}"
            
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
        done
    fi
    
    # Summary
    echo ""
    echo "================================"
    
    case "${management_mode}" in
        systemd)
            echo -e "${GREEN}Summary: MediaMTX is properly managed by systemd${NC}"
            echo ""
            echo "Quick Commands:"
            echo "  • View logs: sudo journalctl -u mediamtx -f"
            echo "  • Restart: sudo systemctl restart mediamtx"
            ;;
        stream-manager)
            echo -e "${GREEN}Summary: MediaMTX is running under Stream Manager control${NC}"
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

verify_installation() {
    log_info "Verifying installation..."
    
    local errors=0
    local warning_count=0
    
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
    
    if [[ ! -f "${CONFIG_DIR}/${CONFIG_NAME}" ]]; then
        log_warn "Configuration not found: ${CONFIG_DIR}/${CONFIG_NAME}"
        warning_count=$((warning_count + 1))
    else
        log_info "Configuration: OK"
    fi
    
    if command -v systemctl &>/dev/null; then
        if [[ ! -f "${SERVICE_DIR}/${SERVICE_NAME}" ]]; then
            log_warn "Service not configured"
            warning_count=$((warning_count + 1))
        elif ! systemctl is-enabled mediamtx &>/dev/null; then
            log_warn "Service not enabled"
            warning_count=$((warning_count + 1))
        else
            log_info "Service: OK"
        fi
    fi
    
    if ! id "${SERVICE_USER}" &>/dev/null; then
        log_warn "Service user not found: ${SERVICE_USER}"
        warning_count=$((warning_count + 1))
    else
        log_info "Service user: OK"
    fi
    
    echo ""
    if [[ ${errors} -eq 0 ]] && [[ ${warning_count} -eq 0 ]]; then
        log_info "✓ Installation verified successfully - no issues found"
        return 0
    elif [[ ${errors} -eq 0 ]]; then
        log_warn "Installation verified with ${warning_count} warning(s)"
        return 0
    else
        log_error "Installation verification failed with ${errors} error(s) and ${warning_count} warning(s)"
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

show_help() {
    cat << EOF
${BOLD}MediaMTX Installation Manager v${SCRIPT_VERSION}${NC}

Production-ready installer for MediaMTX media server with comprehensive
error handling, validation, and security features.

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
    
    if [[ "${COMMAND}" != "status" ]] && [[ "${DRY_RUN_MODE}" != "true" ]]; then
        if [[ ${EUID} -ne 0 ]]; then
            fatal "This operation requires root privileges. Please run with sudo." 2
        fi
    fi
    
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

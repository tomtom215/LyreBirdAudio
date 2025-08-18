#!/bin/bash
# lyrebird-wizard.sh - Unified management interface for LyreBirdAudio
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# This wizard provides a comprehensive interface for managing all aspects
# of the LyreBirdAudio system by orchestrating the existing scripts.
#
# Version: 1.0.0
# Requirements: bash 4.0+, existing LyreBirdAudio scripts

# Check bash version
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "Error: This script requires bash 4.0 or higher" >&2
    echo "Your version: ${BASH_VERSION}" >&2
    exit 3
fi

# Set safer bash options
set -u
set -o pipefail

# Script metadata
readonly WIZARD_VERSION="1.0.0"
readonly WIZARD_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly WIZARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly WIZARD_PID="$$"

# State files
readonly STATE_DIR="/var/lib/lyrebird-wizard"
readonly STATE_FILE="${STATE_DIR}/wizard.state"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly HEALTH_CHECK_FILE="${STATE_DIR}/health.check"

# Script paths (will be found during initialization)
USB_MAPPER_SCRIPT=""
MEDIAMTX_INSTALLER=""
STREAM_MANAGER=""

# Configuration paths
readonly MEDIAMTX_CONFIG="/etc/mediamtx/mediamtx.yml"
readonly AUDIO_DEVICES_CONFIG="/etc/mediamtx/audio-devices.conf"
readonly UDEV_RULES="/etc/udev/rules.d/99-usb-soundcards.rules"
readonly SYSTEMD_SERVICE="/etc/systemd/system/mediamtx-audio.service"

# Color codes
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly NC='\033[0m'
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly CYAN=''
    readonly BOLD=''
    readonly NC=''
fi

# Logging
readonly LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/lyrebird-wizard.log"
readonly MAX_LOG_SIZE=$((10 * 1024 * 1024))  # 10MB

# Global state variables (updated by detect_system_state)
MEDIAMTX_INSTALLED=false
MEDIAMTX_RUNNING=false
MEDIAMTX_VERSION="unknown"
STREAM_MANAGER_INSTALLED=false
STREAMS_RUNNING=false
USB_DEVICES_MAPPED=false
USB_DEVICES_COUNT=0
USB_DEVICES_NAMES=()
ACTIVE_STREAMS_COUNT=0
ACTIVE_STREAM_NAMES=()
MANAGEMENT_MODE="none"
SYSTEM_HEALTH="unknown"

# Error tracking
LAST_ERROR=""
LAST_ERROR_CODE=0

# Cleanup flag to prevent double execution
CLEANUP_DONE=false

# Dry run mode
DRY_RUN_MODE=false

# Monitor mode flag - when true, don't exit on SIGINT
MONITOR_MODE=false

# ============================================================================
# Core Functions
# ============================================================================

init_logging() {
    # Try to create log directory if it doesn't exist
    if [[ ! -d "${LOG_DIR}" ]]; then
        if ! mkdir -p "${LOG_DIR}" 2>/dev/null; then
            LOG_FILE="/tmp/lyrebird-wizard-${WIZARD_PID}.log"
        fi
    fi
    
    # Test if we can write to the log file
    if ! touch "${LOG_FILE}" 2>/dev/null; then
        LOG_FILE="/tmp/lyrebird-wizard-${WIZARD_PID}.log"
        if ! touch "${LOG_FILE}" 2>/dev/null; then
            # If we can't even write to /tmp, disable file logging
            LOG_FILE=""
        fi
    fi
    
    # Rotate log if too large
    if [[ -n "${LOG_FILE}" ]] && [[ -f "${LOG_FILE}" ]]; then
        local log_size
        log_size=$(stat -c%s "${LOG_FILE}" 2>/dev/null || stat -f%z "${LOG_FILE}" 2>/dev/null || echo "0")
        if [[ ${log_size} -gt ${MAX_LOG_SIZE} ]]; then
            mv "${LOG_FILE}" "${LOG_FILE}.old" 2>/dev/null || true
            touch "${LOG_FILE}" 2>/dev/null || true
        fi
    fi
    
    # Log initialization
    log_message INFO "LyreBirdAudio Wizard v${WIZARD_VERSION} started"
    log_message DEBUG "Log file: ${LOG_FILE:-'disabled'}"
}

log_message() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    # Log to file if available
    if [[ -n "${LOG_FILE}" ]] && [[ -w "${LOG_FILE}" ]]; then
        echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
    
    # Display to console based on level
    case "${level}" in
        ERROR)
            echo -e "${RED}[ERROR]${NC} ${message}" >&2
            LAST_ERROR="${message}"
            ;;
        WARN)
            echo -e "${YELLOW}[WARN]${NC} ${message}" >&2
            ;;
        INFO)
            echo -e "${GREEN}[INFO]${NC} ${message}"
            ;;
        DEBUG)
            [[ "${DEBUG:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} ${message}"
            ;;
        *)
            echo "${message}"
            ;;
    esac
}

check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        echo -e "${RED}Error: This wizard must be run as root (use sudo)${NC}" >&2
        echo "Example: sudo $0" >&2
        exit 2
    fi
}

check_terminal() {
    if [[ ! -t 0 ]] || [[ ! -t 1 ]]; then
        echo "Error: This wizard must be run in an interactive terminal" >&2
        exit 1
    fi
    
    # Check terminal size
    local cols
    cols=$(tput cols 2>/dev/null || echo "80")
    if [[ ${cols} -lt 60 ]]; then
        log_message WARN "Terminal width is less than 60 columns, display may be affected"
    fi
}

check_network_connectivity() {
    log_message DEBUG "Checking network connectivity..."
    
    # Try to ping a reliable host
    if command -v ping &>/dev/null; then
        if ping -c 1 -W 2 8.8.8.8 &>/dev/null || ping -c 1 -W 2 1.1.1.1 &>/dev/null; then
            return 0
        fi
    fi
    
    # Try curl as fallback
    if command -v curl &>/dev/null; then
        if curl -s --connect-timeout 2 --max-time 5 https://github.com &>/dev/null; then
            return 0
        fi
    fi
    
    log_message WARN "Network connectivity check failed"
    return 1
}

check_dependencies() {
    local missing=()
    local optional_missing=()
    
    # Required commands (added lsof, pgrep, pkill)
    local required_cmds=("bash" "grep" "sed" "awk" "systemctl" "lsusb" "arecord" "lsof" "pgrep" "pkill")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing+=("${cmd}")
        fi
    done
    
    # Optional but recommended
    local optional_cmds=("ffmpeg" "curl" "jq" "udevadm" "flock")
    for cmd in "${optional_cmds[@]}"; do
        if ! command -v "${cmd}" &>/dev/null; then
            optional_missing+=("${cmd}")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_message ERROR "Missing required commands: ${missing[*]}"
        echo "Please install: sudo apt-get install ${missing[*]}" >&2
        exit 4
    fi
    
    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        log_message WARN "Missing optional commands: ${optional_missing[*]}"
    fi
}

validate_scripts() {
    local missing=()
    local not_executable=()
    local search_paths=("${WIZARD_DIR}" "/usr/local/bin" "/opt/lyrebird" ".")
    
    log_message INFO "Validating required scripts..."
    
    # Define required scripts and their variables
    local -A script_map=(
        ["usb-audio-mapper.sh"]="USB_MAPPER_SCRIPT"
        ["install_mediamtx.sh"]="MEDIAMTX_INSTALLER"
        ["mediamtx-stream-manager.sh"]="STREAM_MANAGER"
    )
    
    for script in "${!script_map[@]}"; do
        local found=false
        local var_name="${script_map[$script]}"
        
        for path in "${search_paths[@]}"; do
            local full_path="${path}/${script}"
            if [[ -f "${full_path}" ]]; then
                if [[ -x "${full_path}" ]]; then
                    # Safe variable assignment
                    case "${var_name}" in
                        USB_MAPPER_SCRIPT) USB_MAPPER_SCRIPT="${full_path}" ;;
                        MEDIAMTX_INSTALLER) MEDIAMTX_INSTALLER="${full_path}" ;;
                        STREAM_MANAGER) STREAM_MANAGER="${full_path}" ;;
                    esac
                    log_message DEBUG "Found ${script} at ${full_path}"
                    found=true
                    break
                else
                    not_executable+=("${full_path}")
                    log_message WARN "${full_path} exists but is not executable"
                fi
            fi
        done
        
        if [[ "${found}" == "false" ]]; then
            missing+=("${script}")
        fi
    done
    
    # Try to fix non-executable scripts
    if [[ ${#not_executable[@]} -gt 0 ]]; then
        log_message INFO "Attempting to fix non-executable scripts..."
        for script in "${not_executable[@]}"; do
            if chmod +x "${script}" 2>/dev/null; then
                log_message INFO "Made ${script} executable"
                # Re-run validation for this script
                local basename
                basename=$(basename "${script}")
                local var_name="${script_map[$basename]}"
                case "${var_name}" in
                    USB_MAPPER_SCRIPT) USB_MAPPER_SCRIPT="${script}" ;;
                    MEDIAMTX_INSTALLER) MEDIAMTX_INSTALLER="${script}" ;;
                    STREAM_MANAGER) STREAM_MANAGER="${script}" ;;
                esac
            else
                log_message ERROR "Could not make ${script} executable"
            fi
        done
    fi
    
    # Final check
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_message ERROR "Required scripts not found: ${missing[*]}"
        echo "Please ensure all LyreBirdAudio scripts are in the same directory" >&2
        exit 5
    fi
    
    # Verify scripts work by testing help output
    log_message DEBUG "Testing script functionality..."
    
    if ! "${MEDIAMTX_INSTALLER}" help >/dev/null 2>&1; then
        log_message WARN "MediaMTX installer may have issues, some functions may not work"
    fi
    
    if ! "${STREAM_MANAGER}" help >/dev/null 2>&1; then
        log_message WARN "Stream manager may have issues, some functions may not work"
    fi
    
    # USB mapper doesn't have a help command, so we skip testing it
}

setup_directories() {
    local dirs=("${STATE_DIR}" "${BACKUP_DIR}")
    for dir in "${dirs[@]}"; do
        if [[ ! -d "${dir}" ]]; then
            if ! mkdir -p "${dir}" 2>/dev/null; then
                log_message WARN "Could not create directory: ${dir}"
            fi
        fi
    done
}

# Atomic state file operations with flock
save_state() {
    local key="$1"
    local value="$2"
    
    [[ -d "${STATE_DIR}" ]] || mkdir -p "${STATE_DIR}" 2>/dev/null || return 1
    
    # Use flock if available for atomic operations
    if command -v flock &>/dev/null; then
        (
            flock -x 200 || return 1
            local temp_file="${STATE_FILE}.tmp.$$"
            
            if [[ -f "${STATE_FILE}" ]]; then
                grep -v "^${key}=" "${STATE_FILE}" > "${temp_file}" 2>/dev/null || true
            fi
            
            echo "${key}=${value}" >> "${temp_file}"
            mv -f "${temp_file}" "${STATE_FILE}" 2>/dev/null || {
                rm -f "${temp_file}"
                return 1
            }
        ) 200>"${STATE_FILE}.lock"
    else
        # Fallback without flock
        local temp_file="${STATE_FILE}.tmp.$$"
        
        if [[ -f "${STATE_FILE}" ]]; then
            grep -v "^${key}=" "${STATE_FILE}" > "${temp_file}" 2>/dev/null || true
        fi
        
        echo "${key}=${value}" >> "${temp_file}"
        mv -f "${temp_file}" "${STATE_FILE}" 2>/dev/null || {
            rm -f "${temp_file}"
            return 1
        }
    fi
}

load_state() {
    local key="$1"
    local default="${2:-}"
    
    if [[ -f "${STATE_FILE}" ]]; then
        local value
        value=$(grep "^${key}=" "${STATE_FILE}" 2>/dev/null | cut -d= -f2- || echo "${default}")
        echo "${value}"
    else
        echo "${default}"
    fi
}

# Enhanced PID validation - fixed to check wrapper scripts properly
validate_pid() {
    local pid="$1"
    local expected_name="${2:-}"
    
    if [[ -z "${pid}" ]] || [[ "${pid}" == "0" ]]; then
        return 1
    fi
    
    if ! kill -0 "${pid}" 2>/dev/null; then
        return 1
    fi
    
    # If no expected name provided, just check if process exists
    if [[ -z "${expected_name}" ]]; then
        return 0
    fi
    
    # For wrapper scripts, check if it's a bash script running our wrapper
    local proc_cmd
    proc_cmd=$(ps -p "${pid}" -o args= 2>/dev/null || echo "")
    
    # Check if it's running a bash script or if it has ffmpeg as a child
    if [[ "${proc_cmd}" == *"bash"* ]] || [[ "${proc_cmd}" == *"sh"* ]]; then
        # It's a wrapper script, check for child ffmpeg processes
        if pgrep -P "${pid}" -f "ffmpeg" >/dev/null 2>&1; then
            return 0
        fi
        # Or check if the script file exists and is our wrapper
        if [[ "${proc_cmd}" == *"/var/lib/mediamtx-ffmpeg/"* ]]; then
            return 0
        fi
    fi
    
    # Direct process name check
    local proc_name
    proc_name=$(ps -p "${pid}" -o comm= 2>/dev/null || echo "")
    
    if [[ "${proc_name}" == *"${expected_name}"* ]]; then
        return 0
    fi
    
    return 1
}

# Enhanced error recovery
handle_script_error() {
    local script="$1"
    local operation="$2"
    local exit_code="$3"
    
    case ${exit_code} in
        0) return 0 ;;
        2) echo -e "${RED}Permission denied. Please run with sudo.${NC}" ;;
        3) echo -e "${RED}Unsupported platform.${NC}" ;;
        4) echo -e "${RED}Missing dependencies.${NC}" ;;
        5) echo -e "${RED}Download failed. Check internet connection.${NC}" ;;
        127) echo -e "${RED}Script not found: ${script}${NC}" ;;
        *) echo -e "${RED}Operation failed with code ${exit_code}${NC}" ;;
    esac
    
    # Offer recovery options
    echo
    echo "Recovery options:"
    echo "1. Retry operation"
    echo "2. Skip and continue"
    echo "3. Return to main menu"
    read -p "Select option: " recovery_choice
    
    case "${recovery_choice}" in
        1) return 1 ;;  # Retry
        2) return 0 ;;  # Skip
        3) return 3 ;;  # Menu
        *) return 2 ;;  # Default to skip
    esac
}

execute_external_script() {
    local script="$1"
    shift
    local args=("$@")
    
    log_message DEBUG "Executing: ${script} ${args[*]}"
    
    if [[ "${DRY_RUN_MODE}" == "true" ]]; then
        echo "[DRY RUN] Would execute: ${script} ${args[*]}"
        return 0
    fi
    
    # Special handling for monitor command
    if [[ "${args[0]:-}" == "monitor" ]]; then
        echo "Starting stream monitor (Press 'q' then Enter to return to menu)..."
        echo
        
        # Run monitor in background and capture its PID
        "${script}" "${args[@]}" &
        local monitor_pid=$!
        
        # Wait for user to press 'q'
        while true; do
            read -n 1 -s key
            if [[ "${key}" == "q" ]] || [[ "${key}" == "Q" ]]; then
                # Kill the monitor process
                kill "${monitor_pid}" 2>/dev/null || true
                wait "${monitor_pid}" 2>/dev/null || true
                echo
                echo "Returning to menu..."
                break
            fi
        done
        
        return 0
    fi
    
    # Create a temp file for capturing output
    local temp_output="/tmp/wizard-exec-${WIZARD_PID}-$$.out"
    local temp_error="/tmp/wizard-exec-${WIZARD_PID}-$$.err"
    
    # Execute the script and capture output
    local exit_code=0
    if "${script}" "${args[@]}" > "${temp_output}" 2> "${temp_error}"; then
        # Success - show output
        cat "${temp_output}"
        rm -f "${temp_output}" "${temp_error}"
        return 0
    else
        exit_code=$?
        LAST_ERROR_CODE=${exit_code}
        
        # Show any output that was produced
        if [[ -s "${temp_output}" ]]; then
            cat "${temp_output}"
        fi
        
        # Log errors but don't always show them to user
        if [[ -s "${temp_error}" ]]; then
            local error_content
            error_content=$(cat "${temp_error}")
            log_message ERROR "Script failed with exit code ${exit_code}: ${error_content}"
            
            # Only show critical errors to user
            if [[ ${exit_code} -ne 0 ]] && [[ ${exit_code} -ne 1 ]]; then
                echo -e "${RED}Command failed (exit code ${exit_code})${NC}" >&2
            fi
        fi
        
        rm -f "${temp_output}" "${temp_error}"
        
        # Handle error with recovery options
        handle_script_error "${script}" "${args[*]}" ${exit_code}
        local recovery=$?
        
        case ${recovery} in
            1) # Retry
                execute_external_script "${script}" "${args[@]}"
                return $?
                ;;
            3) # Return to menu
                return ${exit_code}
                ;;
            *) # Skip or continue
                return ${exit_code}
                ;;
        esac
    fi
}

# ============================================================================
# System Detection (Enhanced)
# ============================================================================

# Portable disk space check
check_disk_space() {
    local path="$1"
    local min_mb="${2:-100}"
    
    local available
    # More portable df parsing using POSIX output
    available=$(df -P "${path}" 2>/dev/null | awk 'NR==2 {print $4}')
    
    # Handle both KB and 1K-blocks output
    if [[ -n "${available}" ]]; then
        local available_mb=$((available / 1024))
        if [[ ${available_mb} -lt ${min_mb} ]]; then
            return 1
        fi
    fi
    return 0
}

detect_usb_audio_devices() {
    USB_DEVICES_COUNT=0
    USB_DEVICES_NAMES=()
    
    # Parse /proc/asound/cards directly for better accuracy
    if [[ -f "/proc/asound/cards" ]]; then
        while IFS= read -r line; do
            if [[ "${line}" =~ ^\ *([0-9]+)\ \[([^\]]+)\]:.*-\ (.+)$ ]]; then
                local card_num="${BASH_REMATCH[1]}"
                local card_id="${BASH_REMATCH[2]}"
                local card_desc="${BASH_REMATCH[3]}"
                
                # Check if it's a USB device
                if [[ -f "/proc/asound/card${card_num}/usbid" ]]; then
                    local display_name=""
                    
                    # If the card_id looks like a friendly name (lowercase alphanumeric),
                    # use it as the primary display name
                    if [[ "${card_id}" =~ ^[a-z][a-z0-9_-]*$ ]] && 
                       [[ "${card_id}" != "device" ]] && 
                       [[ "${card_id}" != "usb_audio" ]]; then
                        display_name="${card_id} (Card ${card_num})"
                    else
                        # It's a generic name, try to make it more descriptive
                        local usb_id=""
                        if [[ -f "/proc/asound/card${card_num}/usbid" ]]; then
                            usb_id=$(cat "/proc/asound/card${card_num}/usbid" 2>/dev/null || echo "")
                        fi
                        
                        if [[ -n "${usb_id}" ]]; then
                            display_name="${card_desc} [${usb_id}] (Card ${card_num})"
                        else
                            display_name="${card_desc} (Card ${card_num})"
                        fi
                    fi
                    
                    USB_DEVICES_NAMES+=("${display_name}")
                    ((USB_DEVICES_COUNT++))
                fi
            fi
        done < "/proc/asound/cards"
    fi
    
    # Sort device names for consistent display
    if [[ ${#USB_DEVICES_NAMES[@]} -gt 0 ]]; then
        readarray -t USB_DEVICES_NAMES < <(printf '%s\n' "${USB_DEVICES_NAMES[@]}" | sort -V)
    fi
    
    log_message DEBUG "Found ${USB_DEVICES_COUNT} USB audio devices: ${USB_DEVICES_NAMES[*]}"
}

# Fixed stream detection to properly handle wrapper scripts
detect_active_streams() {
    ACTIVE_STREAMS_COUNT=0
    ACTIVE_STREAM_NAMES=()
    
    if [[ -d "/var/lib/mediamtx-ffmpeg" ]]; then
        for pid_file in /var/lib/mediamtx-ffmpeg/*.pid; do
            if [[ -f "${pid_file}" ]]; then
                local stream_name
                stream_name=$(basename "${pid_file}" .pid)
                local pid
                pid=$(cat "${pid_file}" 2>/dev/null || echo "0")
                
                # Check if PID is valid and running
                if [[ "${pid}" != "0" ]] && kill -0 "${pid}" 2>/dev/null; then
                    # Check if it's a wrapper script or has ffmpeg children
                    local is_active=false
                    
                    # Check if the process itself exists
                    if ps -p "${pid}" >/dev/null 2>&1; then
                        # Check for child ffmpeg processes
                        if pgrep -P "${pid}" -f "ffmpeg" >/dev/null 2>&1; then
                            is_active=true
                        else
                            # Check if it's a wrapper script (might be starting up)
                            local proc_cmd
                            proc_cmd=$(ps -p "${pid}" -o args= 2>/dev/null || echo "")
                            if [[ "${proc_cmd}" == *"/var/lib/mediamtx-ffmpeg/${stream_name}.sh"* ]] || 
                               [[ "${proc_cmd}" == *"bash"* ]]; then
                                is_active=true
                            fi
                        fi
                    fi
                    
                    if [[ "${is_active}" == "true" ]]; then
                        ACTIVE_STREAM_NAMES+=("${stream_name}")
                        ((ACTIVE_STREAMS_COUNT++))
                    fi
                fi
            fi
        done
    fi
    
    # Sort stream names for consistent display
    if [[ ${#ACTIVE_STREAM_NAMES[@]} -gt 0 ]]; then
        readarray -t ACTIVE_STREAM_NAMES < <(printf '%s\n' "${ACTIVE_STREAM_NAMES[@]}" | sort)
    fi
    
    log_message DEBUG "Found ${ACTIVE_STREAMS_COUNT} active streams: ${ACTIVE_STREAM_NAMES[*]}"
}

detect_management_mode() {
    MANAGEMENT_MODE="none"
    
    if pgrep -x "mediamtx" > /dev/null 2>&1; then
        if systemctl is-active --quiet mediamtx 2>/dev/null; then
            MANAGEMENT_MODE="systemd"
        elif systemctl is-active --quiet mediamtx-audio 2>/dev/null; then
            MANAGEMENT_MODE="stream-manager-systemd"
        elif [[ -f "/var/run/mediamtx-audio.pid" ]]; then
            local pid
            pid=$(cat "/var/run/mediamtx-audio.pid" 2>/dev/null || echo "0")
            if [[ "${pid}" != "0" ]] && kill -0 "${pid}" 2>/dev/null; then
                MANAGEMENT_MODE="stream-manager"
            fi
        else
            MANAGEMENT_MODE="manual"
        fi
    fi
    
    log_message DEBUG "Management mode: ${MANAGEMENT_MODE}"
}

get_mediamtx_version() {
    MEDIAMTX_VERSION="unknown"
    
    if [[ -f "/usr/local/bin/mediamtx" ]]; then
        local version_output
        version_output=$(/usr/local/bin/mediamtx --version 2>&1 || true)
        if [[ "${version_output}" =~ v[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            MEDIAMTX_VERSION="${BASH_REMATCH[0]}"
        fi
    fi
    
    log_message DEBUG "MediaMTX version: ${MEDIAMTX_VERSION}"
}

check_system_health() {
    SYSTEM_HEALTH="healthy"
    local issues=()
    
    # Check port conflicts
    for port in 8554 9997 9998; do
        if lsof -i ":${port}" 2>/dev/null | grep -v mediamtx | grep -q LISTEN; then
            issues+=("Port ${port} conflict")
        fi
    done
    
    # Check disk space
    if ! check_disk_space "/var/log" 100; then
        issues+=("Low disk space in /var/log")
    fi
    
    if ! check_disk_space "/tmp" 50; then
        issues+=("Low disk space in /tmp")
    fi
    
    # Check for stale PID files
    for pid_file in /var/run/mediamtx*.pid /var/lib/mediamtx-ffmpeg/*.pid; do
        if [[ -f "${pid_file}" ]]; then
            local pid
            pid=$(cat "${pid_file}" 2>/dev/null || echo "0")
            if [[ "${pid}" != "0" ]] && ! kill -0 "${pid}" 2>/dev/null; then
                issues+=("Stale PID: ${pid_file}")
            fi
        fi
    done
    
    if [[ ${#issues[@]} -gt 0 ]]; then
        SYSTEM_HEALTH="issues"
        log_message WARN "System health issues: ${issues[*]}"
    fi
}

detect_system_state() {
    log_message DEBUG "Detecting system state..."
    
    # Reset state variables
    MEDIAMTX_INSTALLED=false
    MEDIAMTX_RUNNING=false
    STREAM_MANAGER_INSTALLED=false
    STREAMS_RUNNING=false
    USB_DEVICES_MAPPED=false
    
    # Check MediaMTX installation
    if [[ -f "/usr/local/bin/mediamtx" ]]; then
        MEDIAMTX_INSTALLED=true
        get_mediamtx_version
        
        if pgrep -x "mediamtx" > /dev/null 2>&1; then
            MEDIAMTX_RUNNING=true
        fi
    fi
    
    # Check stream manager
    if [[ -f "${SYSTEMD_SERVICE}" ]] || [[ -x "${STREAM_MANAGER}" ]]; then
        STREAM_MANAGER_INSTALLED=true
    fi
    
    # Detect management mode
    detect_management_mode
    
    # Check USB devices
    detect_usb_audio_devices
    
    # Check device mappings
    if [[ -f "${UDEV_RULES}" ]]; then
        USB_DEVICES_MAPPED=true
    fi
    
    # Check active streams
    detect_active_streams
    if [[ ${ACTIVE_STREAMS_COUNT} -gt 0 ]]; then
        STREAMS_RUNNING=true
    fi
    
    # Check system health
    check_system_health
    
    # Save current state
    save_state "last_check" "$(date -Iseconds)"
    save_state "mediamtx_version" "${MEDIAMTX_VERSION}"
    save_state "management_mode" "${MANAGEMENT_MODE}"
}

# ============================================================================
# Display Functions
# ============================================================================

display_header() {
    if [[ "${1:-}" == "clear" ]]; then
        clear
    fi
    echo -e "${BOLD}${CYAN}========================================${NC}"
    echo -e "${BOLD}${CYAN}    LyreBirdAudio Setup Wizard v${WIZARD_VERSION}${NC}"
    echo -e "${BOLD}${CYAN}========================================${NC}"
    echo
}

display_status() {
    echo -e "${BOLD}Current System Status:${NC}"
    echo "----------------------------------------"
    
    # MediaMTX Status
    if [[ "${MEDIAMTX_INSTALLED}" == "true" ]]; then
        echo -e "MediaMTX: ${GREEN}Installed${NC} (${MEDIAMTX_VERSION})"
        if [[ "${MEDIAMTX_RUNNING}" == "true" ]]; then
            local mode_display="${MANAGEMENT_MODE}"
            case "${MANAGEMENT_MODE}" in
                stream-manager-systemd)
                    mode_display="stream manager (systemd)"
                    ;;
                stream-manager)
                    mode_display="stream manager"
                    ;;
            esac
            echo -e "  Status: ${GREEN}Running${NC} (${mode_display})"
        else
            echo -e "  Status: ${YELLOW}Stopped${NC}"
        fi
    else
        echo -e "MediaMTX: ${RED}Not installed${NC}"
    fi
    
    # Stream Manager Status
    if [[ "${STREAM_MANAGER_INSTALLED}" == "true" ]]; then
        echo -e "Stream Manager: ${GREEN}Configured${NC}"
        if [[ ${ACTIVE_STREAMS_COUNT} -gt 0 ]]; then
            echo -e "  Active Streams: ${GREEN}${ACTIVE_STREAMS_COUNT}${NC}"
            # Show first 3 stream names for context
            local shown=0
            for stream in "${ACTIVE_STREAM_NAMES[@]}"; do
                if [[ ${shown} -lt 3 ]]; then
                    echo "    • ${stream}"
                    ((shown++))
                else
                    echo "    • ... and $((ACTIVE_STREAMS_COUNT - 3)) more"
                    break
                fi
            done
        else
            echo -e "  Active Streams: ${YELLOW}0${NC}"
        fi
    else
        echo -e "Stream Manager: ${YELLOW}Not configured${NC}"
    fi
    
    # USB Devices Status with better formatting
    echo -e "USB Audio Devices: ${USB_DEVICES_COUNT} detected"
    if [[ "${USB_DEVICES_MAPPED}" == "true" ]]; then
        echo -e "  Device Mapping: ${GREEN}Configured${NC}"
    else
        echo -e "  Device Mapping: ${YELLOW}Not configured${NC}"
    fi
    
    # Show first few devices if not too many
    if [[ ${USB_DEVICES_COUNT} -gt 0 ]] && [[ ${USB_DEVICES_COUNT} -le 8 ]]; then
        for device in "${USB_DEVICES_NAMES[@]}"; do
            echo "  • ${device}"
        done
    elif [[ ${USB_DEVICES_COUNT} -gt 8 ]]; then
        # Too many devices, show first 5
        local shown=0
        for device in "${USB_DEVICES_NAMES[@]}"; do
            if [[ ${shown} -lt 5 ]]; then
                echo "  • ${device}"
                ((shown++))
            else
                echo "  • ... and $((USB_DEVICES_COUNT - 5)) more"
                break
            fi
        done
    fi
    
    # System Health
    if [[ "${SYSTEM_HEALTH}" == "healthy" ]]; then
        echo -e "System Health: ${GREEN}Good${NC}"
    else
        echo -e "System Health: ${YELLOW}Issues detected${NC}"
    fi
    
    echo "----------------------------------------"
    echo
}

display_error() {
    if [[ -n "${LAST_ERROR}" ]]; then
        echo -e "${RED}Last Error: ${LAST_ERROR}${NC}"
        echo
    fi
}

# ============================================================================
# Backup and Restore Functions
# ============================================================================

create_backup() {
    local backup_name="${1:-backup-$(date +%Y%m%d-%H%M%S)}"
    local backup_path="${BACKUP_DIR}/${backup_name}"
    
    log_message INFO "Creating backup: ${backup_name}"
    
    if [[ -d "${backup_path}" ]]; then
        log_message ERROR "Backup already exists: ${backup_name}"
        return 1
    fi
    
    mkdir -p "${backup_path}"
    
    # Backup configurations
    local files_to_backup=(
        "${MEDIAMTX_CONFIG}"
        "${AUDIO_DEVICES_CONFIG}"
        "${UDEV_RULES}"
        "${SYSTEMD_SERVICE}"
        "/var/log/mediamtx.log"
        "/var/log/mediamtx-audio-manager.log"
    )
    
    local backed_up=0
    for file in "${files_to_backup[@]}"; do
        if [[ -f "${file}" ]]; then
            local basename
            basename=$(basename "${file}")
            if cp -p "${file}" "${backup_path}/${basename}" 2>/dev/null; then
                ((backed_up++))
                log_message DEBUG "Backed up: ${file}"
            fi
        fi
    done
    
    # Save backup metadata
    cat > "${backup_path}/metadata.txt" << EOF
Backup Date: $(date -Iseconds)
MediaMTX Version: ${MEDIAMTX_VERSION}
Management Mode: ${MANAGEMENT_MODE}
Active Streams: ${ACTIVE_STREAMS_COUNT}
Files Backed Up: ${backed_up}
Wizard Version: ${WIZARD_VERSION}
EOF
    
    log_message INFO "Backup created with ${backed_up} files"
    echo -e "${GREEN}Backup created: ${backup_name}${NC}"
    
    return 0
}

list_backups() {
    if [[ ! -d "${BACKUP_DIR}" ]]; then
        echo "No backups found"
        return 1
    fi
    
    local backups=()
    for backup in "${BACKUP_DIR}"/*; do
        if [[ -d "${backup}" ]] && [[ -f "${backup}/metadata.txt" ]]; then
            backups+=("$(basename "${backup}")")
        fi
    done
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        echo "No backups found"
        return 1
    fi
    
    echo -e "${BOLD}Available Backups:${NC}"
    for backup in "${backups[@]}"; do
        echo "  - ${backup}"
        if [[ -f "${BACKUP_DIR}/${backup}/metadata.txt" ]]; then
            grep "Backup Date:" "${BACKUP_DIR}/${backup}/metadata.txt" | sed 's/^/    /'
            grep "MediaMTX Version:" "${BACKUP_DIR}/${backup}/metadata.txt" | sed 's/^/    /'
        fi
    done
    
    return 0
}

restore_backup() {
    local backup_name="$1"
    local backup_path="${BACKUP_DIR}/${backup_name}"
    
    if [[ ! -d "${backup_path}" ]]; then
        log_message ERROR "Backup not found: ${backup_name}"
        return 1
    fi
    
    log_message INFO "Restoring backup: ${backup_name}"
    
    # Check version compatibility
    if [[ -f "${backup_path}/metadata.txt" ]]; then
        local backup_version
        backup_version=$(grep "MediaMTX Version:" "${backup_path}/metadata.txt" | cut -d: -f2 | tr -d ' ')
        
        if [[ -n "${backup_version}" ]] && [[ "${backup_version}" != "${MEDIAMTX_VERSION}" ]]; then
            echo -e "${YELLOW}Warning: Backup is from different MediaMTX version${NC}"
            echo "  Backup version: ${backup_version}"
            echo "  Current version: ${MEDIAMTX_VERSION}"
            read -p "Continue anyway? (y/n): " -n 1 -r
            echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && return 1
        fi
    fi
    
    # Stop services before restore
    echo "Stopping services..."
    if [[ "${MANAGEMENT_MODE}" == "stream-manager" ]] || [[ "${MANAGEMENT_MODE}" == "stream-manager-systemd" ]]; then
        execute_external_script "${STREAM_MANAGER}" stop >/dev/null 2>&1 || true
    elif [[ "${MANAGEMENT_MODE}" == "systemd" ]]; then
        systemctl stop mediamtx 2>/dev/null || true
    fi
    
    # Restore files
    local restored=0
    for file in "${backup_path}"/*; do
        if [[ -f "${file}" ]] && [[ "$(basename "${file}")" != "metadata.txt" ]]; then
            local basename
            basename=$(basename "${file}")
            local target=""
            
            case "${basename}" in
                mediamtx.yml)
                    target="${MEDIAMTX_CONFIG}"
                    ;;
                audio-devices.conf)
                    target="${AUDIO_DEVICES_CONFIG}"
                    ;;
                99-usb-soundcards.rules)
                    target="${UDEV_RULES}"
                    ;;
                mediamtx-audio.service)
                    target="${SYSTEMD_SERVICE}"
                    ;;
                *)
                    continue
                    ;;
            esac
            
            if [[ -n "${target}" ]]; then
                # Backup current file
                if [[ -f "${target}" ]]; then
                    cp -p "${target}" "${target}.before-restore" 2>/dev/null || true
                fi
                
                # Restore file
                if cp -p "${file}" "${target}" 2>/dev/null; then
                    ((restored++))
                    log_message DEBUG "Restored: ${target}"
                fi
            fi
        fi
    done
    
    # Reload systemd if service was restored
    if [[ -f "${SYSTEMD_SERVICE}" ]]; then
        systemctl daemon-reload 2>/dev/null || true
    fi
    
    # Reload udev rules if restored
    if [[ -f "${UDEV_RULES}" ]]; then
        udevadm control --reload-rules 2>/dev/null || true
    fi
    
    log_message INFO "Restored ${restored} files from backup"
    echo -e "${GREEN}Backup restored: ${restored} files${NC}"
    
    return 0
}

# ============================================================================
# Menu Functions (Enhanced with error handling)
# ============================================================================

menu_quick_setup() {
    display_header "clear"
    echo -e "${BOLD}Quick Setup - First Time Installation${NC}"
    echo
    echo "This will guide you through the complete setup process:"
    echo "1. Install MediaMTX"
    echo "2. Map USB audio devices (requires reboot)"
    echo "3. Configure stream manager"
    echo "4. Start audio streams"
    echo
    read -p "Continue with quick setup? (y/n): " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        return
    fi
    
    # Check network connectivity for downloads
    if ! check_network_connectivity; then
        echo -e "${YELLOW}Warning: Network connectivity issues detected${NC}"
        echo "MediaMTX installation may fail without internet access"
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && return
    fi
    
    # Step 1: Install MediaMTX
    if [[ "${MEDIAMTX_INSTALLED}" != "true" ]]; then
        echo
        echo -e "${BOLD}Step 1: Installing MediaMTX...${NC}"
        if execute_external_script "${MEDIAMTX_INSTALLER}" install; then
            echo -e "${GREEN}MediaMTX installed successfully${NC}"
            MEDIAMTX_INSTALLED=true
        else
            echo -e "${RED}MediaMTX installation failed${NC}"
            read -p "Continue anyway? (y/n): " -n 1 -r
            echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && return
        fi
    else
        echo -e "${GREEN}MediaMTX already installed${NC}"
    fi
    
    # Step 2: Map USB devices
    if [[ ${USB_DEVICES_COUNT} -gt 0 ]]; then
        if [[ "${USB_DEVICES_MAPPED}" != "true" ]]; then
            echo
            echo -e "${BOLD}Step 2: Mapping USB audio devices...${NC}"
            echo -e "${YELLOW}Note: You will need to reboot after mapping each device${NC}"
            echo "Found ${USB_DEVICES_COUNT} USB audio device(s)"
            read -p "Map devices now? (y/n): " -n 1 -r
            echo
            
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                execute_external_script "${USB_MAPPER_SCRIPT}" -i
                echo
                echo -e "${YELLOW}IMPORTANT: Please reboot now and run this wizard again${NC}"
                echo "The wizard will resume from where it left off."
                save_state "quick_setup_resume" "step3"
                exit 0
            fi
        else
            echo -e "${GREEN}USB devices already mapped${NC}"
        fi
    else
        echo -e "${YELLOW}No USB audio devices detected${NC}"
    fi
    
    # Step 3: Configure stream manager
    if [[ "${STREAM_MANAGER_INSTALLED}" != "true" ]]; then
        echo
        echo -e "${BOLD}Step 3: Configuring stream manager...${NC}"
        if execute_external_script "${STREAM_MANAGER}" install; then
            echo -e "${GREEN}Stream manager configured${NC}"
            systemctl enable mediamtx-audio 2>/dev/null || true
            STREAM_MANAGER_INSTALLED=true
        else
            echo -e "${RED}Stream manager configuration failed${NC}"
            read -p "Continue anyway? (y/n): " -n 1 -r
            echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && return
        fi
    else
        echo -e "${GREEN}Stream manager already configured${NC}"
    fi
    
    # Step 4: Start streams
    echo
    echo -e "${BOLD}Step 4: Starting audio streams...${NC}"
    if execute_external_script "${STREAM_MANAGER}" start; then
        echo -e "${GREEN}Audio streams started successfully${NC}"
    else
        echo -e "${RED}Failed to start audio streams${NC}"
        echo "You can try starting them manually from the Stream Management menu"
    fi
    
    echo
    echo -e "${GREEN}${BOLD}Setup complete!${NC}"
    echo
    echo "Next steps:"
    echo "1. Check stream status in the Stream Management menu"
    echo "2. Configure device settings in the Configuration menu"
    echo "3. Monitor streams for stability"
    
    save_state "quick_setup_complete" "$(date -Iseconds)"
    read -p "Press Enter to continue..."
}

menu_mediamtx() {
    while true; do
        detect_system_state
        display_header "clear"
        echo -e "${BOLD}MediaMTX Management${NC}"
        echo
        display_status
        display_error
        
        echo "1. Install MediaMTX"
        echo "2. Update MediaMTX"  
        echo "3. Uninstall MediaMTX"
        echo "4. Check Status"
        echo "5. Verify Installation"
        echo "0. Back to Main Menu"
        echo
        read -p "Select option: " choice
        
        case ${choice} in
            1)
                if execute_external_script "${MEDIAMTX_INSTALLER}" install; then
                    echo -e "${GREEN}Installation successful${NC}"
                else
                    echo -e "${RED}Installation failed${NC}"
                fi
                ;;
            2)
                if execute_external_script "${MEDIAMTX_INSTALLER}" update; then
                    echo -e "${GREEN}Update successful${NC}"
                else
                    echo -e "${RED}Update failed${NC}"
                fi
                ;;
            3)
                read -p "Are you sure you want to uninstall? (y/n): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    if execute_external_script "${MEDIAMTX_INSTALLER}" uninstall; then
                        echo -e "${GREEN}Uninstall successful${NC}"
                    else
                        echo -e "${RED}Uninstall failed${NC}"
                    fi
                fi
                ;;
            4)
                execute_external_script "${MEDIAMTX_INSTALLER}" status || true
                ;;
            5)
                # The verify command has issues in the installer, so we do our own check
                echo "Verifying MediaMTX installation..."
                local issues=0
                
                if [[ -f "/usr/local/bin/mediamtx" ]]; then
                    echo -e "  Binary: ${GREEN}Present${NC}"
                    if /usr/local/bin/mediamtx --version >/dev/null 2>&1; then
                        echo -e "  Version check: ${GREEN}OK${NC}"
                    else
                        echo -e "  Version check: ${RED}Failed${NC}"
                        ((issues++))
                    fi
                else
                    echo -e "  Binary: ${RED}Missing${NC}"
                    ((issues++))
                fi
                
                if [[ -f "${MEDIAMTX_CONFIG}" ]]; then
                    echo -e "  Configuration: ${GREEN}Present${NC}"
                else
                    echo -e "  Configuration: ${YELLOW}Missing${NC}"
                fi
                
                if [[ -f "${SYSTEMD_SERVICE}" ]] || [[ -f "/etc/systemd/system/mediamtx.service" ]]; then
                    echo -e "  Service: ${GREEN}Configured${NC}"
                else
                    echo -e "  Service: ${YELLOW}Not configured${NC}"
                fi
                
                if [[ ${issues} -eq 0 ]]; then
                    echo -e "\n${GREEN}Verification passed${NC}"
                else
                    echo -e "\n${YELLOW}Verification completed with ${issues} issue(s)${NC}"
                fi
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                ;;
        esac
        
        echo
        read -p "Press Enter to continue..."
        LAST_ERROR=""
    done
}

menu_streams() {
    while true; do
        detect_system_state
        display_header "clear"
        echo -e "${BOLD}Stream Management${NC}"
        echo
        display_status
        display_error
        
        echo "1. Start Streams"
        echo "2. Stop Streams"
        echo "3. Restart Streams"
        echo "4. Stream Status"
        echo "5. Monitor Streams (live)"
        echo "6. Debug Streams"
        echo "7. Show Stream Configuration"
        echo "8. Test Stream Playback"
        echo "0. Back to Main Menu"
        echo
        read -p "Select option: " choice
        
        case ${choice} in
            1)
                if execute_external_script "${STREAM_MANAGER}" start; then
                    echo -e "${GREEN}Streams started${NC}"
                else
                    echo -e "${RED}Failed to start streams${NC}"
                fi
                ;;
            2)
                if execute_external_script "${STREAM_MANAGER}" stop; then
                    echo -e "${GREEN}Streams stopped${NC}"
                else
                    echo -e "${RED}Failed to stop streams${NC}"
                fi
                ;;
            3)
                if execute_external_script "${STREAM_MANAGER}" restart; then
                    echo -e "${GREEN}Streams restarted${NC}"
                else
                    echo -e "${RED}Failed to restart streams${NC}"
                fi
                ;;
            4)
                execute_external_script "${STREAM_MANAGER}" status || true
                ;;
            5)
                # Special handling for monitor command
                execute_external_script "${STREAM_MANAGER}" monitor || true
                ;;
            6)
                execute_external_script "${STREAM_MANAGER}" debug || true
                ;;
            7)
                execute_external_script "${STREAM_MANAGER}" config || true
                ;;
            8)
                execute_external_script "${STREAM_MANAGER}" test || true
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                ;;
        esac
        
        echo
        read -p "Press Enter to continue..."
        LAST_ERROR=""
    done
}

menu_devices() {
    while true; do
        detect_system_state
        display_header "clear"
        echo -e "${BOLD}USB Device Management${NC}"
        echo
        display_status
        display_error
        
        echo "1. Map USB Audio Device (Interactive)"
        echo "2. Test USB Port Detection"
        echo "3. View Current Device Mappings"
        echo "4. Remove All Device Mappings"
        echo "5. Show Detailed Device Information"
        echo "6. Show Device to Stream Mapping"
        echo "0. Back to Main Menu"
        echo
        read -p "Select option: " choice
        
        case ${choice} in
            1)
                echo -e "${YELLOW}Note: You must reboot after mapping each device${NC}"
                read -p "Continue? (y/n): " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    if execute_external_script "${USB_MAPPER_SCRIPT}" -i; then
                        echo -e "${GREEN}Device mapping complete${NC}"
                        echo -e "${YELLOW}Please reboot for changes to take effect${NC}"
                    else
                        echo -e "${RED}Device mapping failed${NC}"
                    fi
                fi
                ;;
            2)
                execute_external_script "${USB_MAPPER_SCRIPT}" --test || true
                ;;
            3)
                if [[ -f "${UDEV_RULES}" ]]; then
                    echo -e "${BOLD}Current udev rules:${NC}"
                    cat "${UDEV_RULES}"
                else
                    echo "No device mappings found"
                fi
                ;;
            4)
                if [[ -f "${UDEV_RULES}" ]]; then
                    read -p "Remove all device mappings? This cannot be undone. (y/n): " -n 1 -r
                    echo
                    if [[ $REPLY =~ ^[Yy]$ ]]; then
                        # Create backup first
                        cp "${UDEV_RULES}" "${UDEV_RULES}.backup.$(date +%Y%m%d-%H%M%S)"
                        rm -f "${UDEV_RULES}"
                        udevadm control --reload-rules 2>/dev/null || true
                        echo -e "${GREEN}Device mappings removed${NC}"
                    fi
                else
                    echo "No mappings to remove"
                fi
                ;;
            5)
                echo -e "${BOLD}Detailed USB Audio Device Information:${NC}"
                echo
                
                # Show devices from /proc/asound/cards with friendly names
                if [[ -f "/proc/asound/cards" ]]; then
                    local card_num=0
                    while IFS= read -r line; do
                        if [[ "${line}" =~ ^\ *([0-9]+)\ \[([^\]]+)\]:.*-\ (.+)$ ]]; then
                            card_num="${BASH_REMATCH[1]}"
                            local card_id="${BASH_REMATCH[2]}"
                            local card_desc="${BASH_REMATCH[3]}"
                            
                            # Check if USB
                            if [[ -f "/proc/asound/card${card_num}/usbid" ]]; then
                                echo "Card ${card_num}: ${card_id}"
                                echo "  Description: ${card_desc}"
                                
                                # Get USB ID
                                local usb_id
                                usb_id=$(cat "/proc/asound/card${card_num}/usbid" 2>/dev/null || echo "unknown")
                                echo "  USB ID: ${usb_id}"
                                
                                # Check if mapped with friendly name
                                if [[ "${card_id}" =~ ^[a-z][a-z0-9_-]*$ ]] && 
                                   [[ "${card_id}" != "device" ]] && 
                                   [[ "${card_id}" != "usb_audio" ]]; then
                                    echo -e "  Friendly Name: ${GREEN}${card_id}${NC} (mapped)"
                                else
                                    echo -e "  Friendly Name: ${YELLOW}Not mapped${NC} (using default: ${card_id})"
                                fi
                                
                                # Check for active stream
                                local stream_found=false
                                local matching_stream=""
                                for stream in "${ACTIVE_STREAM_NAMES[@]}"; do
                                    if [[ "${stream}" == "${card_id}" ]]; then
                                        matching_stream="${stream}"
                                        stream_found=true
                                        break
                                    fi
                                done
                                
                                if [[ "${stream_found}" == "true" ]]; then
                                    echo -e "  Stream: ${GREEN}Active${NC} (rtsp://localhost:8554/${matching_stream})"
                                else
                                    echo -e "  Stream: ${YELLOW}Not active${NC}"
                                fi
                                echo
                            fi
                        fi
                    done < "/proc/asound/cards"
                fi
                
                echo -e "${BOLD}Raw USB device list:${NC}"
                lsusb | grep -i "audio\|microphone\|sound" || echo "No matches in lsusb"
                ;;
            6)
                echo -e "${BOLD}Device to Stream Mapping:${NC}"
                echo
                
                if [[ ${ACTIVE_STREAMS_COUNT} -gt 0 ]]; then
                    for stream in "${ACTIVE_STREAM_NAMES[@]}"; do
                        echo "Stream: ${stream}"
                        echo "  URL: rtsp://localhost:8554/${stream}"
                        
                        # Try to find which card this stream is using
                        if [[ -f "/var/lib/mediamtx-ffmpeg/${stream}.sh" ]]; then
                            local card_num
                            card_num=$(grep "^CARD_NUM=" "/var/lib/mediamtx-ffmpeg/${stream}.sh" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "")
                            if [[ -n "${card_num}" ]]; then
                                echo "  Using: Card ${card_num}"
                                
                                # Get card name
                                if [[ -f "/proc/asound/card${card_num}/id" ]]; then
                                    local card_name
                                    card_name=$(cat "/proc/asound/card${card_num}/id" 2>/dev/null || echo "")
                                    [[ -n "${card_name}" ]] && echo "  Device: ${card_name}"
                                fi
                            fi
                        fi
                        echo
                    done
                else
                    echo "No active streams"
                fi
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                ;;
        esac
        
        echo
        read -p "Press Enter to continue..."
        LAST_ERROR=""
    done
}

menu_config() {
    while true; do
        detect_system_state
        display_header "clear"
        echo -e "${BOLD}Configuration Management${NC}"
        echo
        
        echo "1. View Device Configuration"
        echo "2. Edit Audio Device Settings"
        echo "3. Edit MediaMTX Configuration"
        echo "4. View Environment Variables"
        echo "5. Set Environment Variables"
        echo "6. Backup Configuration"
        echo "7. Restore Configuration"
        echo "8. List Backups"
        echo "0. Back to Main Menu"
        echo
        read -p "Select option: " choice
        
        case ${choice} in
            1)
                execute_external_script "${STREAM_MANAGER}" config || true
                ;;
            2)
                if [[ -f "${AUDIO_DEVICES_CONFIG}" ]]; then
                    # Create backup before editing
                    cp "${AUDIO_DEVICES_CONFIG}" "${AUDIO_DEVICES_CONFIG}.backup.$(date +%Y%m%d-%H%M%S)"
                    ${EDITOR:-nano} "${AUDIO_DEVICES_CONFIG}"
                    echo -e "${GREEN}Configuration saved${NC}"
                else
                    echo "Audio devices configuration not found"
                    echo "It will be created when you first run the stream manager"
                fi
                ;;
            3)
                if [[ -f "${MEDIAMTX_CONFIG}" ]]; then
                    # Create backup before editing
                    cp "${MEDIAMTX_CONFIG}" "${MEDIAMTX_CONFIG}.backup.$(date +%Y%m%d-%H%M%S)"
                    ${EDITOR:-nano} "${MEDIAMTX_CONFIG}"
                    echo -e "${GREEN}Configuration saved${NC}"
                else
                    echo "MediaMTX configuration not found"
                fi
                ;;
            4)
                echo -e "${BOLD}Current Environment Variables:${NC}"
                echo
                
                # Better parsing that handles quotes and spaces
                if systemctl is-active --quiet mediamtx-audio 2>/dev/null; then
                    echo "Active Service Environment:"
                    local env_output
                    env_output=$(systemctl show mediamtx-audio --property=Environment 2>/dev/null)
                    
                    if [[ "${env_output}" =~ ^Environment=(.+)$ ]]; then
                        # Parse the environment string properly
                        local IFS=' '
                        local env_array
                        read -ra env_array <<< "${BASH_REMATCH[1]}"
                        
                        for var in "${env_array[@]}"; do
                            # Remove surrounding quotes if present
                            var="${var%\"}"
                            var="${var#\"}"
                            [[ -n "${var}" ]] && echo "  ${var}"
                        done
                    else
                        echo "  No custom environment variables set"
                    fi
                    echo
                fi
                
                # Check service file
                if [[ -f "${SYSTEMD_SERVICE}" ]]; then
                    echo "Service File Configuration:"
                    grep -E "^\s*Environment=" "${SYSTEMD_SERVICE}" 2>/dev/null | sed 's/^\s*/  /' || echo "  No Environment lines"
                    echo
                fi
                
                # Check for override files
                local override_dir="/etc/systemd/system/mediamtx-audio.service.d"
                if [[ -d "${override_dir}" ]]; then
                    echo "Override Files:"
                    for override_file in "${override_dir}"/*.conf; do
                        if [[ -f "${override_file}" ]]; then
                            echo "  From $(basename "${override_file}"):"
                            grep -E "^\s*Environment=" "${override_file}" 2>/dev/null | sed 's/^\s*/    /' || echo "    No Environment lines"
                        fi
                    done
                    echo
                fi
                
                echo -e "${BOLD}Recommended Production Values:${NC}"
                echo "  Environment=\"USB_STABILIZATION_DELAY=10\""
                echo "  Environment=\"RESTART_STABILIZATION_DELAY=15\""
                echo "  Environment=\"DEVICE_TEST_ENABLED=false\""
                echo "  Environment=\"STREAM_STARTUP_DELAY=10\""
                echo "  Environment=\"PARALLEL_STREAM_START=false\""
                ;;
            5)
                if [[ ! -f "${SYSTEMD_SERVICE}" ]]; then
                    echo "Service not configured. Please install the stream manager first."
                else
                    echo -e "${BOLD}Set Environment Variables${NC}"
                    echo
                    echo "Choose method:"
                    echo "1. Quick setup with recommended production values"
                    echo "2. Edit override file manually"
                    echo "3. Show current configuration"
                    echo "0. Cancel"
                    echo
                    read -p "Select option: " env_choice
                    
                    case ${env_choice} in
                        1)
                            echo "Creating override with recommended production values..."
                            
                            # Create override directory if it doesn't exist
                            local override_dir="/etc/systemd/system/mediamtx-audio.service.d"
                            mkdir -p "${override_dir}"
                            
                            # Create override file with recommended settings
                            cat > "${override_dir}/environment.conf" << 'EOF'
[Service]
# LyreBirdAudio recommended production environment variables
Environment="USB_STABILIZATION_DELAY=10"
Environment="RESTART_STABILIZATION_DELAY=15"
Environment="DEVICE_TEST_ENABLED=false"
Environment="STREAM_STARTUP_DELAY=10"
Environment="PARALLEL_STREAM_START=false"
Environment="DEBUG=false"
EOF
                            
                            systemctl daemon-reload
                            echo -e "${GREEN}Production environment variables configured${NC}"
                            echo
                            echo "The following values were set:"
                            cat "${override_dir}/environment.conf" | grep "^Environment=" | sed 's/^/  /'
                            
                            if systemctl is-active --quiet mediamtx-audio; then
                                echo
                                read -p "Restart service now to apply changes? (y/n): " -n 1 -r
                                echo
                                if [[ $REPLY =~ ^[Yy]$ ]]; then
                                    systemctl restart mediamtx-audio
                                    echo -e "${GREEN}Service restarted${NC}"
                                fi
                            fi
                            ;;
                        2)
                            echo "Opening systemd edit interface..."
                            echo "Add Environment=\"VARIABLE=value\" lines in the [Service] section"
                            echo
                            read -p "Press Enter to continue..."
                            systemctl edit mediamtx-audio
                            systemctl daemon-reload
                            echo -e "${GREEN}Service configuration updated${NC}"
                            ;;
                        3)
                            # Reuse option 4 logic
                            if systemctl is-active --quiet mediamtx-audio 2>/dev/null; then
                                echo "Current Active Environment:"
                                local env_output
                                env_output=$(systemctl show mediamtx-audio --property=Environment 2>/dev/null)
                                
                                if [[ "${env_output}" =~ ^Environment=(.+)$ ]]; then
                                    local IFS=' '
                                    local env_array
                                    read -ra env_array <<< "${BASH_REMATCH[1]}"
                                    
                                    for var in "${env_array[@]}"; do
                                        var="${var%\"}"
                                        var="${var#\"}"
                                        [[ -n "${var}" ]] && echo "  ${var}"
                                    done
                                else
                                    echo "  No custom environment variables"
                                fi
                            else
                                echo "Service not running"
                            fi
                            ;;
                        0)
                            echo "Cancelled"
                            ;;
                        *)
                            echo -e "${RED}Invalid option${NC}"
                            ;;
                    esac
                fi
                ;;
            6)
                read -p "Enter backup name (or press Enter for timestamp): " backup_name
                if [[ -z "${backup_name}" ]]; then
                    backup_name="backup-$(date +%Y%m%d-%H%M%S)"
                fi
                create_backup "${backup_name}"
                ;;
            7)
                if list_backups; then
                    echo
                    read -p "Enter backup name to restore: " backup_name
                    if [[ -n "${backup_name}" ]]; then
                        restore_backup "${backup_name}"
                    fi
                fi
                ;;
            8)
                list_backups || echo "No backups found"
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                ;;
        esac
        
        echo
        read -p "Press Enter to continue..."
    done
}

menu_troubleshoot() {
    while true; do
        detect_system_state
        display_header "clear"
        echo -e "${BOLD}Troubleshooting${NC}"
        echo
        display_status
        
        echo "1. View MediaMTX Logs"
        echo "2. View Stream Manager Logs"
        echo "3. View System Logs"
        echo "4. Check Port Availability"
        echo "5. Clean Stale Processes"
        echo "6. Clean PID Files"
        echo "7. Run Full Diagnostics"
        echo "8. Check Disk Space"
        echo "9. Test Audio Devices"
        echo "10. System Health Details"
        echo "0. Back to Main Menu"
        echo
        read -p "Select option: " choice
        
        case ${choice} in
            1)
                echo -e "${BOLD}MediaMTX Logs (last 50 lines):${NC}"
                if [[ -f "/var/log/mediamtx.log" ]]; then
                    tail -n 50 /var/log/mediamtx.log
                elif [[ -f "/var/log/mediamtx.out" ]]; then
                    tail -n 50 /var/log/mediamtx.out
                else
                    echo "Log file not found"
                fi
                ;;
            2)
                echo -e "${BOLD}Stream Manager Logs (last 50 lines):${NC}"
                if [[ -f "/var/log/mediamtx-audio-manager.log" ]]; then
                    tail -n 50 /var/log/mediamtx-audio-manager.log
                else
                    echo "Log file not found"
                fi
                ;;
            3)
                echo -e "${BOLD}System Logs (MediaMTX related):${NC}"
                journalctl -u mediamtx-audio --no-pager -n 50 2>/dev/null || \
                journalctl -u mediamtx --no-pager -n 50 2>/dev/null || \
                echo "No systemd logs found"
                ;;
            4)
                echo -e "${BOLD}Port Availability Check:${NC}"
                for port in 8554 9997 9998; do
                    echo -n "Port ${port}: "
                    if lsof -i ":${port}" 2>/dev/null | grep -q LISTEN; then
                        local process
                        process=$(lsof -i ":${port}" 2>/dev/null | grep LISTEN | awk '{print $1}' | head -1)
                        echo -e "${YELLOW}In use by ${process}${NC}"
                    else
                        echo -e "${GREEN}Available${NC}"
                    fi
                done
                ;;
            5)
                echo "Cleaning stale processes..."
                
                # Stop all managed processes properly first
                if [[ "${MANAGEMENT_MODE}" == "stream-manager" ]] || [[ "${MANAGEMENT_MODE}" == "stream-manager-systemd" ]]; then
                    execute_external_script "${STREAM_MANAGER}" stop >/dev/null 2>&1 || true
                fi
                
                # Kill stragglers
                pkill -f "ffmpeg.*rtsp://localhost" 2>/dev/null || true
                pkill -x mediamtx 2>/dev/null || true
                
                echo -e "${GREEN}Cleanup completed${NC}"
                ;;
            6)
                echo "Cleaning PID files..."
                local cleaned=0
                
                for pid_file in /var/run/mediamtx*.pid /var/lib/mediamtx-ffmpeg/*.pid; do
                    if [[ -f "${pid_file}" ]]; then
                        local pid
                        pid=$(cat "${pid_file}" 2>/dev/null || echo "0")
                        if [[ "${pid}" != "0" ]] && ! kill -0 "${pid}" 2>/dev/null; then
                            rm -f "${pid_file}"
                            ((cleaned++))
                            echo "  Removed stale PID file: ${pid_file}"
                        fi
                    fi
                done
                
                echo -e "${GREEN}Cleaned ${cleaned} stale PID files${NC}"
                ;;
            7)
                echo -e "${BOLD}Running Full Diagnostics...${NC}"
                echo
                
                echo "=== System Information ==="
                uname -a
                echo
                
                echo "=== USB Audio Devices ==="
                lsusb | grep -i "audio\|microphone\|sound" || echo "No USB audio devices in lsusb"
                echo
                
                echo "=== ALSA Devices ==="
                arecord -l 2>/dev/null || echo "No ALSA recording devices"
                echo
                
                echo "=== Process Status ==="
                ps aux | grep -E "(mediamtx|ffmpeg)" | grep -v grep || echo "No related processes"
                echo
                
                echo "=== Network Ports ==="
                netstat -tlnp 2>/dev/null | grep -E "(8554|9997|9998)" || \
                lsof -i :8554 -i :9997 -i :9998 2>/dev/null || \
                echo "Could not check ports"
                echo
                
                echo "=== Disk Space ==="
                df -h /var/log /var/lib /tmp
                echo
                
                echo "=== Memory Usage ==="
                free -h
                ;;
            8)
                echo -e "${BOLD}Disk Space Analysis:${NC}"
                df -h | grep -E "^/|Filesystem"
                echo
                echo -e "${BOLD}Large log files:${NC}"
                find /var/log -type f -size +10M 2>/dev/null | head -10 || echo "No large log files"
                ;;
            9)
                echo -e "${BOLD}Testing Audio Devices:${NC}"
                echo
                
                # Parse /proc/asound/cards directly for accurate info
                if [[ -f "/proc/asound/cards" ]]; then
                    while IFS= read -r line; do
                        if [[ "${line}" =~ ^\ *([0-9]+)\ \[([^\]]+)\]:.*-\ (.+)$ ]]; then
                            local card_num="${BASH_REMATCH[1]}"
                            local card_id="${BASH_REMATCH[2]}"
                            local card_desc="${BASH_REMATCH[3]}"
                            
                            # Check if USB
                            if [[ -f "/proc/asound/card${card_num}/usbid" ]]; then
                                echo "Testing Card ${card_num}: ${card_id} (${card_desc})"
                                
                                # Test with direct hw access
                                if timeout 1 arecord -D "hw:${card_num},0" -f S16_LE -r 48000 -c 2 -d 1 /dev/null 2>/dev/null; then
                                    echo -e "  ${GREEN}✓ Device test passed (hw:${card_num},0)${NC}"
                                else
                                    # Try with plughw for format conversion
                                    if timeout 1 arecord -D "plughw:${card_num},0" -f S16_LE -r 48000 -c 2 -d 1 /dev/null 2>/dev/null; then
                                        echo -e "  ${GREEN}✓ Device test passed (plughw:${card_num},0)${NC}"
                                    else
                                        echo -e "  ${YELLOW}✗ Device test failed or timed out${NC}"
                                    fi
                                fi
                                echo
                            fi
                        fi
                    done < "/proc/asound/cards"
                else
                    echo "Could not read /proc/asound/cards"
                fi
                ;;
            10)
                echo -e "${BOLD}System Health Details:${NC}"
                echo
                
                # Re-run health check to get fresh data
                local old_health="${SYSTEM_HEALTH}"
                check_system_health
                
                if [[ "${SYSTEM_HEALTH}" == "healthy" ]]; then
                    echo -e "${GREEN}✓ System is healthy${NC}"
                    echo
                    echo "All checks passed:"
                    echo "  • No port conflicts"
                    echo "  • Adequate disk space"
                    echo "  • No stale PID files"
                    if [[ "${STREAM_MANAGER_INSTALLED}" == "true" ]]; then
                        echo "  • Environment variables configured"
                    fi
                else
                    echo -e "${YELLOW}⚠ Issues detected:${NC}"
                    echo
                    
                    # Check each potential issue and report
                    
                    # Port conflicts
                    for port in 8554 9997 9998; do
                        if lsof -i ":${port}" 2>/dev/null | grep -v mediamtx | grep -q LISTEN; then
                            local process
                            process=$(lsof -i ":${port}" 2>/dev/null | grep -v mediamtx | grep LISTEN | awk '{print $1}' | head -1)
                            echo -e "  ${RED}✗${NC} Port ${port} conflict: used by ${process}"
                        fi
                    done
                    
                    # Disk space
                    if ! check_disk_space "/var/log" 100; then
                        local available
                        available=$(df -P "/var/log" 2>/dev/null | awk 'NR==2 {print $4}')
                        local space_mb=$((available / 1024))
                        echo -e "  ${RED}✗${NC} Low disk space: ${space_mb}MB available in /var/log"
                    fi
                    
                    # Stale PID files
                    for pid_file in /var/run/mediamtx*.pid /var/lib/mediamtx-ffmpeg/*.pid; do
                        if [[ -f "${pid_file}" ]]; then
                            local pid
                            pid=$(cat "${pid_file}" 2>/dev/null || echo "0")
                            if [[ "${pid}" != "0" ]] && ! kill -0 "${pid}" 2>/dev/null; then
                                echo -e "  ${YELLOW}⚠${NC} Stale PID file: $(basename "${pid_file}")"
                            fi
                        fi
                    done
                    
                    # Environment variables
                    if [[ "${STREAM_MANAGER_INSTALLED}" == "true" ]] && systemctl is-active --quiet mediamtx-audio 2>/dev/null; then
                        local env_vars
                        env_vars=$(systemctl show mediamtx-audio --property=Environment 2>/dev/null | sed 's/^Environment=//' || echo "")
                        
                        if [[ "${env_vars}" != *"USB_STABILIZATION_DELAY"* ]]; then
                            echo -e "  ${YELLOW}⚠${NC} Missing USB_STABILIZATION_DELAY environment variable"
                            echo "     Recommended: USB_STABILIZATION_DELAY=10"
                        fi
                        
                        if [[ "${env_vars}" != *"DEVICE_TEST_ENABLED=false"* ]]; then
                            echo -e "  ${YELLOW}⚠${NC} Device testing not disabled"
                            echo "     Recommended: DEVICE_TEST_ENABLED=false"
                        fi
                    fi
                fi
                
                echo
                echo "To fix issues:"
                echo "  • Port conflicts: Stop conflicting services"
                echo "  • Low disk space: Clean up log files (option 8)"
                echo "  • Stale PID files: Clean PID files (option 6)"
                echo "  • Missing env vars: Use Configuration menu option 5"
                ;;
            0)
                return
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                ;;
        esac
        
        echo
        read -p "Press Enter to continue..."
    done
}

menu_main() {
    # Check for resume from quick setup with validation
    local resume_step
    resume_step=$(load_state "quick_setup_resume" "")
    if [[ -n "${resume_step}" ]]; then
        # Validate that resuming makes sense
        detect_system_state
        
        case "${resume_step}" in
            step3)
                if [[ "${MEDIAMTX_INSTALLED}" != "true" ]]; then
                    log_message WARN "Cannot resume quick setup - MediaMTX not installed"
                    save_state "quick_setup_resume" ""
                else
                    echo -e "${CYAN}Resuming quick setup from ${resume_step}...${NC}"
                    save_state "quick_setup_resume" ""
                    menu_quick_setup
                fi
                ;;
            *)
                save_state "quick_setup_resume" ""
                ;;
        esac
    fi
    
    while true; do
        detect_system_state
        display_header "clear"
        display_status
        
        echo -e "${BOLD}Main Menu:${NC}"
        echo "1. Quick Setup (First Time)"
        echo "2. MediaMTX Management"
        echo "3. Stream Management"
        echo "4. USB Device Management"
        echo "5. Configuration & Backup"
        echo "6. Troubleshooting"
        echo "7. Refresh Status"
        echo "0. Exit"
        echo
        
        # Show hints based on current state
        if [[ "${MEDIAMTX_INSTALLED}" != "true" ]]; then
            echo -e "${YELLOW}Hint: Start with Quick Setup or install MediaMTX${NC}"
        elif [[ ${USB_DEVICES_COUNT} -gt 0 ]]; then
            # Check if all devices have friendly names
            local unmapped_count=0
            if [[ -f "/proc/asound/cards" ]]; then
                while IFS= read -r line; do
                    if [[ "${line}" =~ ^\ *([0-9]+)\ \[([^\]]+)\]: ]]; then
                        local card_id="${BASH_REMATCH[2]}"
                        local card_num="${BASH_REMATCH[1]}"
                        if [[ -f "/proc/asound/card${card_num}/usbid" ]]; then
                            # Check if it has a generic name
                            if [[ "${card_id}" == "Device" ]] || [[ "${card_id}" == "USB_Audio" ]] || 
                               [[ "${card_id}" =~ ^usb_ ]]; then
                                ((unmapped_count++))
                            fi
                        fi
                    fi
                done < "/proc/asound/cards"
            fi
            
            if [[ ${unmapped_count} -gt 0 ]]; then
                echo -e "${YELLOW}Hint: ${unmapped_count} device(s) without friendly names. Use Device Management to map them.${NC}"
            elif [[ "${STREAMS_RUNNING}" != "true" ]]; then
                echo -e "${YELLOW}Hint: All devices mapped! Start your audio streams.${NC}"
            elif [[ ${ACTIVE_STREAMS_COUNT} -lt ${USB_DEVICES_COUNT} ]]; then
                echo -e "${YELLOW}Hint: Only ${ACTIVE_STREAMS_COUNT}/${USB_DEVICES_COUNT} devices streaming.${NC}"
            else
                echo -e "${GREEN}System fully configured: ${USB_DEVICES_COUNT} devices mapped and streaming!${NC}"
            fi
        elif [[ ${USB_DEVICES_COUNT} -eq 0 ]]; then
            echo -e "${YELLOW}Hint: No USB audio devices detected. Connect your devices.${NC}"
        fi
        
        echo
        read -p "Select option: " choice
        
        case ${choice} in
            1) menu_quick_setup ;;
            2) menu_mediamtx ;;
            3) menu_streams ;;
            4) menu_devices ;;
            5) menu_config ;;
            6) menu_troubleshoot ;;
            7) 
                echo "Refreshing status..."
                detect_system_state
                ;;
            0)
                echo
                echo "Thank you for using LyreBirdAudio Setup Wizard"
                log_message INFO "Wizard exited normally"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                read -p "Press Enter to continue..."
                ;;
        esac
    done
}

# ============================================================================
# Enhanced cleanup function
# ============================================================================

cleanup() {
    local exit_code=$?
    
    # Only run cleanup once
    if [[ "${CLEANUP_DONE:-false}" == "true" ]]; then
        return
    fi
    CLEANUP_DONE=true
    
    # Clean up any temp files from execute_external_script
    rm -f /tmp/wizard-exec-${WIZARD_PID}-*.{out,err} 2>/dev/null || true
    
    # Clean up state lock file
    rm -f "${STATE_FILE}.lock" 2>/dev/null || true
    
    # Log exit
    log_message INFO "Wizard cleanup completed (exit code: ${exit_code})"
    
    exit ${exit_code}
}

# ============================================================================
# Main Execution
# ============================================================================

main() {
    # Handle command line arguments
    case "${1:-}" in
        --version|-v)
            echo "LyreBirdAudio Setup Wizard v${WIZARD_VERSION}"
            exit 0
            ;;
        --help|-h)
            echo "LyreBirdAudio Setup Wizard v${WIZARD_VERSION}"
            echo ""
            echo "Usage: sudo ${WIZARD_NAME} [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --version, -v    Show version"
            echo "  --help, -h       Show this help"
            echo "  --debug          Enable debug mode"
            echo "  --dry-run        Perform dry run without making changes"
            echo ""
            echo "This wizard provides a unified interface for managing all aspects"
            echo "of the LyreBirdAudio RTSP audio streaming system."
            echo ""
            echo "Features:"
            echo "  - Quick setup for first-time users"
            echo "  - MediaMTX installation and updates"
            echo "  - Stream management and monitoring"
            echo "  - USB device mapping and configuration"
            echo "  - Configuration backup and restore"
            echo "  - Comprehensive troubleshooting tools"
            exit 0
            ;;
        --debug)
            export DEBUG=true
            shift
            ;;
        --dry-run)
            DRY_RUN_MODE=true
            shift
            ;;
        "")
            # No arguments, continue normally
            ;;
        *)
            echo "Unknown option: ${1}" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
    
    # Initialize
    check_terminal
    check_root
    init_logging
    check_dependencies
    
    # Setup environment
    setup_directories
    
    # Find and validate scripts
    validate_scripts
    
    # Initial system detection
    detect_system_state
    
    # Start interactive menu
    menu_main
}

# Trap for clean exit
trap cleanup EXIT INT TERM

# Run main function
main "$@"

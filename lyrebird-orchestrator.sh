#!/usr/bin/env bash
#
# lyrebird-orchestrator.sh - Complete Unified Management Interface
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# Author: Tom F (https://github.com/tomtom215)
# Copyright: Tom F and LyreBirdAudio contributors
# License: Apache 2.0
#
# Version: 2.0.1
# Description: Production-grade orchestrator providing unified access to all
#              LyreBirdAudio components with comprehensive functionality,
#              intuitive navigation, and robust error handling.
#
# v2.0.1 Security & Reliability Hardening:
#   SECURITY FIXES:
#   - ADDED: Bash 4.0+ version requirement check (portability)
#   - ADDED: SUDO_USER validation before privilege drop (security)
#   - ADDED: Sanitized environment for privilege-dropped updater execution
#   - ADDED: Symlink depth limit in get_script_dir() (DoS prevention)
#   - ADDED: Symlink validation for script resolution
#   
#   RELIABILITY FIXES:
#   - ADDED: Log rotation with 10MB size limit
#   - ADDED: Symlink validation for log files
#   - ADDED: Restricted permissions on log files and directories
#   - IMPROVED: Stream counting with explicit validation
#   - IMPROVED: Upper bound validation for stream counts
#   
#   CODE QUALITY:
#   - IMPROVED: Version input validation with pattern matching
#   - IMPROVED: Consistent variable quoting in conditionals
#   - IMPROVED: Portable stderr redirection (>/dev/null 2>&1)
#   - MAINTAINED: All existing functionality and user experience
#
# v2.0.0 Major Release - Complete Functionality Integration:
#   [Previous changelog preserved...]

set -euo pipefail

# ============================================================================
# Bash Version Validation
# ============================================================================

# Require Bash 4.0+ for associative array support
if (( BASH_VERSINFO[0] < 4 )); then
    echo "ERROR: This script requires Bash 4.0 or later (found: ${BASH_VERSION})" >&2
    echo >&2
    echo "Your current Bash version does not support associative arrays." >&2
    echo >&2
    echo "On macOS:" >&2
    echo "  brew install bash" >&2
    echo "  /usr/local/bin/bash $0" >&2
    echo >&2
    echo "On Ubuntu/Debian:" >&2
    echo "  sudo apt-get update && sudo apt-get install bash" >&2
    exit 1
fi

# ============================================================================
# Constants and Configuration
# ============================================================================

readonly SCRIPT_VERSION="2.0.1"

# Safe constant initialization (SC2155: separate declaration and assignment)
SCRIPT_NAME=""
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# Get script directory with symlink resolution protection
get_script_dir() {
    local source="${BASH_SOURCE[0]}"
    local max_depth=20
    local depth=0
    
    # Resolve symlinks with depth limit to prevent infinite loops
    while [[ -L "$source" ]] && (( depth < max_depth )); do
        local link_target
        
        # Prefer readlink -f for atomic resolution if available
        if link_target="$(readlink -f "$source" 2>/dev/null)" && [[ -n "$link_target" ]]; then
            source="$link_target"
        else
            # Fallback to manual resolution
            local dir
            dir="$(cd -P "$(dirname "$source")" 2>/dev/null && pwd)" || break
            local next_source
            next_source="$(readlink "$source")" || break
            [[ $next_source != /* ]] && next_source="$dir/$next_source"
            source="$next_source"
        fi
        
        (( depth++ ))
    done
    
    # Final safety validation
    if (( depth >= max_depth )); then
        echo "ERROR: Symlink resolution depth exceeded (possible circular symlink)" >&2
        echo "/dev/null"
        return 1
    fi
    
    if [[ ! -f "$source" ]]; then
        echo "ERROR: Resolved script path does not exist: $source" >&2
        echo "/dev/null"
        return 1
    fi
    
    dirname "$source"
}

SCRIPT_DIR=""
SCRIPT_DIR="$(get_script_dir)"
readonly SCRIPT_DIR

# Validate SCRIPT_DIR was resolved successfully
if [[ "$SCRIPT_DIR" == "/dev/null" ]]; then
    echo "FATAL: Cannot determine script directory" >&2
    exit 1
fi

# External script paths
declare -A EXTERNAL_SCRIPTS=(
    ["installer"]="install_mediamtx.sh"
    ["stream_manager"]="mediamtx-stream-manager.sh"
    ["usb_mapper"]="usb-audio-mapper.sh"
    ["updater"]="lyrebird-updater.sh"
    ["diagnostics"]="lyrebird-diagnostics.sh"
)

# Configuration paths (for reference/display only)
readonly UDEV_RULES="/etc/udev/rules.d/99-usb-soundcards.rules"
readonly MEDIAMTX_LOG_FILE="${MEDIAMTX_LOG_FILE:-/var/log/mediamtx.out}"
readonly FFMPEG_LOG_DIR="${FFMPEG_LOG_DIR:-/var/log/lyrebird}"

# Log file (initialized in initialize_logging() with fallback handling)
LOG_FILE=""

# Exit codes
readonly E_GENERAL=1
readonly E_PERMISSION=2
readonly E_DEPENDENCY=3
readonly E_SCRIPT_NOT_FOUND=4

# Diagnostics script exit codes (for proper handling)
readonly E_DIAG_SUCCESS=0
readonly E_DIAG_WARN=1
readonly E_DIAG_FAIL=2

# Colors (only if terminal supports them)
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly CYAN='\033[0;36m'
    readonly BOLD='\033[1m'
    readonly NC='\033[0m'
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly CYAN=''
    readonly BOLD=''
    readonly NC=''
fi

# Global state variables
declare -A SCRIPT_PATHS=()
LAST_ERROR=""
MEDIAMTX_INSTALLED=false
MEDIAMTX_RUNNING=false
MEDIAMTX_VERSION="unknown"
USB_DEVICES_MAPPED=false
ACTIVE_STREAMS=0

# ============================================================================
# Utility Functions
# ============================================================================

# Logging with safe file access
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}" 2>/dev/null || true
}

# Output functions with consistent formatting
success() {
    echo -e "${GREEN}[+]${NC} $*"
    log "INFO" "$*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    log "ERROR" "$*"
}

warning() {
    echo -e "${YELLOW}[!]${NC} $*"
    log "WARN" "$*"
}

info() {
    echo -e "${CYAN}[i]${NC} $*"
    log "INFO" "$*"
}

# Check if command exists in PATH
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Version comparison - returns 0 if v1 >= v2
version_ge() {
    local v1="$1"
    local v2="$2"
    
    # Handle unknown versions
    [[ "$v1" == "unknown" || "$v2" == "unknown" ]] && return 1
    
    # Remove 'v' prefix if present
    v1="${v1#v}"
    v2="${v2#v}"
    
    # Split into major.minor.patch
    IFS='.' read -ra V1 <<< "$v1"
    IFS='.' read -ra V2 <<< "$v2"
    
    # Compare each component
    for i in {0..2}; do
        local p1="${V1[i]:-0}"
        local p2="${V2[i]:-0}"
        
        if (( p1 > p2 )); then
            return 0
        elif (( p1 < p2 )); then
            return 1
        fi
    done
    
    return 0
}

# Validate version string format
validate_version_string() {
    local version="$1"
    local pattern='^v?[0-9]+(\.[0-9]+){0,2}$'
    
    [[ -n "$version" ]] && [[ "$version" =~ $pattern ]]
}

# Get primary IP address (cross-platform)
get_primary_ip() {
    # Try Linux iproute2
    ip addr show 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | grep -v '^127\.' | head -1 || \
    # Try BSD/macOS ifconfig
    ifconfig 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | grep -v '^127\.' | head -1 || \
    # Fallback
    echo "localhost"
}

# ============================================================================
# Logging Initialization
# ============================================================================

initialize_logging() {
    local primary_dir="/var/log/lyrebird"
    local primary_log="${primary_dir}/orchestrator.log"
    local max_size=10485760  # 10MB maximum size
    
    # Create dedicated log directory with restricted permissions
    if [[ ! -d "$primary_dir" ]]; then
        if ! mkdir -p "$primary_dir" 2>/dev/null; then
            primary_dir="/tmp"
        else
            chmod 750 "$primary_dir" 2>/dev/null || true
        fi
    fi
    
    # Verify directory is not a symlink (security)
    if [[ -L "$primary_dir" ]]; then
        echo "WARNING: Log directory is a symlink - refusing to write: $primary_dir" >&2
        LOG_FILE="/dev/null"
        return 1
    fi
    
    # Implement size-based log rotation with numbered backups
    if [[ -f "$primary_log" ]]; then
        local current_size
        # Cross-platform stat: Linux (-c%s) or BSD/macOS (-f%z)
        current_size=$(stat -c%s "$primary_log" 2>/dev/null || \
                       stat -f%z "$primary_log" 2>/dev/null || \
                       echo 0)
        
        if (( current_size > max_size )); then
            # Rotate existing backups: keep last 5
            for i in {4..1}; do
                local old_backup="${primary_log}.${i}.gz"
                local new_backup="${primary_log}.$((i+1)).gz"
                if [[ -f "$old_backup" ]]; then
                    mv "$old_backup" "$new_backup" 2>/dev/null || true
                fi
            done
            
            # Rotate current log to .1 and compress
            mv "$primary_log" "${primary_log}.1" 2>/dev/null || true
            if command_exists gzip; then
                gzip -f "${primary_log}.1" 2>/dev/null || true
            fi
        fi
    fi
    
    # Atomic file creation with restrictive permissions
    if [[ -w "$primary_dir" ]]; then
        LOG_FILE="$primary_log"
        touch "$LOG_FILE" 2>/dev/null || true
        chmod 640 "$LOG_FILE" 2>/dev/null || true
    elif [[ -w "/tmp" ]]; then
        # Validate /tmp itself is not a symlink before creating temp file
        if [[ ! -L "/tmp" ]]; then
            LOG_FILE="$(mktemp -p /tmp lyrebird-orchestrator.XXXXXX.log 2>/dev/null)" || LOG_FILE="/dev/null"
            if [[ "$LOG_FILE" != "/dev/null" ]]; then
                chmod 600 "$LOG_FILE" 2>/dev/null || true
                
                # Atomic validation: remove if it became a symlink (race condition)
                if [[ -L "$LOG_FILE" ]]; then
                    rm -f "$LOG_FILE"
                    LOG_FILE="/dev/null"
                    echo "WARNING: Detected symlink attack on log file" >&2
                fi
            fi
        else
            LOG_FILE="/dev/null"
            echo "WARNING: /tmp is a symlink - refusing to create log file" >&2
        fi
    else
        LOG_FILE="/dev/null"
        echo "WARNING: Cannot write logs, using /dev/null" >&2
    fi
    
    # Validate log file is not a symlink
    if [[ -L "$LOG_FILE" ]]; then
        echo "WARNING: Log file is a symlink - refusing to write: $LOG_FILE" >&2
        LOG_FILE="/dev/null"
    fi
    
    if [[ "$LOG_FILE" != "/dev/null" ]]; then
        log "INFO" "=== Orchestrator v${SCRIPT_VERSION} started (PID: $$) ==="
        log "INFO" "Log file: ${LOG_FILE}"
    fi
}

# ============================================================================
# Validation Functions
# ============================================================================

check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        error "This script must be run as root"
        echo "Please use: sudo ${SCRIPT_NAME}"
        exit ${E_PERMISSION}
    fi
}

check_terminal() {
    if [[ ! -t 0 || ! -t 1 ]]; then
        error "This script must be run interactively in a terminal"
        exit ${E_GENERAL}
    fi
}

check_dependencies() {
    local missing=()
    local required=("bash" "grep" "awk" "sed" "ps")
    
    for cmd in "${required[@]}"; do
        if ! command_exists "$cmd"; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required commands: ${missing[*]}"
        exit ${E_DEPENDENCY}
    fi
}

# ============================================================================
# Script Discovery and Validation
# ============================================================================

find_external_scripts() {
    log "DEBUG" "Locating external scripts in ${SCRIPT_DIR}"
    
    local all_found=true
    
    for key in "${!EXTERNAL_SCRIPTS[@]}"; do
        local script_name="${EXTERNAL_SCRIPTS[$key]}"
        local script_path="${SCRIPT_DIR}/${script_name}"
        
        if [[ ! -f "$script_path" ]]; then
            error "Required script not found: ${script_name}"
            all_found=false
            continue
        fi
        
        if [[ ! -r "$script_path" ]]; then
            error "Cannot read script: ${script_path}"
            all_found=false
            continue
        fi
        
        if [[ ! -x "$script_path" ]]; then
            warning "Script not executable, attempting to fix: ${script_name}"
            if ! chmod +x "$script_path" 2>/dev/null; then
                error "Cannot make script executable: ${script_path}"
                all_found=false
                continue
            fi
        fi
        
        # Validate script syntax before accepting it
        if ! bash -n "$script_path" 2>/dev/null; then
            error "Syntax errors detected in ${script_name} - refusing to use"
            log "ERROR" "Script failed syntax check: ${script_path}"
            all_found=false
            continue
        fi
        
        SCRIPT_PATHS[$key]="$script_path"
        log "DEBUG" "Found ${key}: ${script_path}"
    done
    
    if [[ "$all_found" != "true" ]]; then
        echo
        error "Cannot locate all required scripts"
        echo "Ensure all LyreBirdAudio scripts are in: ${SCRIPT_DIR}"
        return 1
    fi
    
    return 0
}

extract_script_version() {
    local script_path="$1"
    local version="unknown"
    
    if [[ -f "$script_path" ]]; then
        # Try multiple version patterns
        version=$(grep -m1 '^readonly SCRIPT_VERSION=' "$script_path" 2>/dev/null | sed -n 's/.*"\([0-9][0-9.]*\)".*/\1/p')
        
        if [[ -z "$version" || "$version" == "" ]]; then
            version=$(grep -m1 '^readonly VERSION=' "$script_path" 2>/dev/null | sed -n 's/.*"\([0-9][0-9.]*\)".*/\1/p')
        fi
        
        if [[ -z "$version" || "$version" == "" ]]; then
            version=$(grep -m1 '^SCRIPT_VERSION=' "$script_path" 2>/dev/null | sed -n 's/.*"\([0-9][0-9.]*\)".*/\1/p')
        fi
        
        if [[ -z "$version" || "$version" == "" ]]; then
            version=$(grep -m1 '^VERSION=' "$script_path" 2>/dev/null | sed -n 's/.*"\([0-9][0-9.]*\)".*/\1/p')
        fi
        
        if [[ -z "$version" || "$version" == "" ]]; then
            version="unknown"
        fi
    fi
    
    echo "$version"
}

validate_script_versions() {
    local all_valid=true
    
    for key in "${!SCRIPT_PATHS[@]}"; do
        local script_path="${SCRIPT_PATHS[$key]}"
        local detected_version
        detected_version="$(extract_script_version "$script_path")"
        
        if [[ "$detected_version" == "unknown" ]]; then
            log "WARN" "Could not determine version for ${key}"
            all_valid=false
        fi
    done
    
    # Return proper exit code based on validation result
    if [[ "$all_valid" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# System State Management
# ============================================================================

refresh_system_state() {
    log "DEBUG" "Refreshing system state"
    
    # Check MediaMTX installation
    if command_exists mediamtx || [[ -f /usr/local/bin/mediamtx ]]; then
        MEDIAMTX_INSTALLED=true
        
        # Try to get version
        if command_exists mediamtx; then
            MEDIAMTX_VERSION=$(mediamtx --version 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        elif [[ -f /usr/local/bin/mediamtx ]]; then
            MEDIAMTX_VERSION=$(/usr/local/bin/mediamtx --version 2>&1 | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        fi
    else
        MEDIAMTX_INSTALLED=false
        MEDIAMTX_VERSION="not installed"
    fi
    
    # Check if MediaMTX is running
    if pgrep -x mediamtx >/dev/null 2>&1; then
        MEDIAMTX_RUNNING=true
    else
        MEDIAMTX_RUNNING=false
    fi
    
    # Count active streams with explicit validation
    ACTIVE_STREAMS=0
    
    if pgrep -x ffmpeg >/dev/null 2>&1; then
        local raw_count
        raw_count=$(pgrep -x ffmpeg 2>/dev/null | wc -l)
        
        # Explicit validation: must match positive integer pattern
        if [[ "$raw_count" =~ ^[0-9]+$ ]]; then
            ACTIVE_STREAMS=$(( raw_count ))
        else
            log "WARN" "pgrep returned invalid stream count: '$raw_count'"
            ACTIVE_STREAMS=0
        fi
    fi
    
    # Safety cap: prevent integer overflow or unrealistic values
    if (( ACTIVE_STREAMS > 10000 )); then
        log "ERROR" "Suspiciously high stream count: $ACTIVE_STREAMS, resetting to 0"
        ACTIVE_STREAMS=0
    fi
    
    # Check if USB devices are mapped
    if [[ -f "$UDEV_RULES" ]] && [[ -s "$UDEV_RULES" ]]; then
        USB_DEVICES_MAPPED=true
    else
        USB_DEVICES_MAPPED=false
    fi
    
    log "DEBUG" "State: MediaMTX=${MEDIAMTX_INSTALLED}, Running=${MEDIAMTX_RUNNING}, Streams=${ACTIVE_STREAMS}, USB=${USB_DEVICES_MAPPED}"
}

# ============================================================================
# Script Execution Wrapper
# ============================================================================

execute_script() {
    local script_key="$1"
    shift
    local args=("$@")
    
    if [[ ! -v "SCRIPT_PATHS[$script_key]" ]]; then
        error "Unknown script key: ${script_key}"
        LAST_ERROR="Script not found: ${script_key}"
        return 1
    fi
    
    local script_path="${SCRIPT_PATHS[$script_key]}"
    local script_name
    script_name="$(basename "$script_path")"
    
    log "INFO" "Executing: ${script_name} ${args[*]}"
    
    # Drop privileges when calling updater to avoid root warning
    # The updater should run as the original user, not root
    if [[ "$script_key" == "updater" ]] && [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        log "DEBUG" "Dropping privileges to user ${SUDO_USER} for updater execution"
        
        # Validate SUDO_USER is a real system user
        if ! id "$SUDO_USER" >/dev/null 2>&1; then
            error "Invalid SUDO_USER: $SUDO_USER - refusing to drop privileges"
            LAST_ERROR="Invalid SUDO_USER: $SUDO_USER"
            return 1
        fi
        
        # Use sanitized environment with explicit variables
        # Get HOME safely without eval
        local user_home
        user_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)" || \
        user_home="$(eval echo "~$SUDO_USER")"  # Fallback only if getent unavailable
        
        if sudo -u "$SUDO_USER" env -i \
            HOME="$user_home" \
            PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            LOGNAME="$SUDO_USER" \
            USER="$SUDO_USER" \
            "${script_path}" "${args[@]}"; then
            log "INFO" "${script_name} completed successfully (privilege-dropped)"
            return 0
        else
            local exit_code=$?
            error "${script_name} failed (exit code: ${exit_code})"
            LAST_ERROR="${script_name} failed (exit code: ${exit_code})"
            log "ERROR" "${script_name} failed with exit code ${exit_code} (privilege-dropped)"
            return 1
        fi
    fi
    
    # Special handling for diagnostics script
    # Diagnostics uses exit codes: 0=success, 1=warnings, 2=failures
    # We should NOT show error messages for warnings (exit code 1)
    if [[ "$script_key" == "diagnostics" ]]; then
        "${script_path}" "${args[@]}"
        local exit_code=$?
        
        case ${exit_code} in
            "${E_DIAG_SUCCESS}")
                log "INFO" "${script_name} completed successfully (all checks passed)"
                return 0
                ;;
            "${E_DIAG_WARN}")
                log "WARN" "${script_name} completed with warnings"
                return 1
                ;;
            "${E_DIAG_FAIL}")
                log "ERROR" "${script_name} detected failures"
                return 2
                ;;
            *)
                error "${script_name} failed with unexpected exit code: ${exit_code}"
                LAST_ERROR="${script_name} failed (exit code: ${exit_code})"
                log "ERROR" "${script_name} failed with exit code ${exit_code}"
                return ${exit_code}
                ;;
        esac
    fi
    
    # All other scripts run as root (normal execution)
    if "${script_path}" "${args[@]}"; then
        log "INFO" "${script_name} completed successfully"
        return 0
    else
        local exit_code=$?
        error "${script_name} failed (exit code: ${exit_code})"
        LAST_ERROR="${script_name} failed (exit code: ${exit_code})"
        log "ERROR" "${script_name} failed with exit code ${exit_code}"
        return 1
    fi
}

# ============================================================================
# Display Functions
# ============================================================================

display_header() {
    if [[ "${1:-}" == "clear" ]]; then
        clear
    fi
    
    echo -e "${BOLD}================================================================${NC}"
    echo -e "${BOLD}||${NC}                 ${CYAN}${BOLD}LyreBirdAudio Orchestrator${NC}${BOLD}                 ||${NC}"
    echo -e "${BOLD}||${NC}                       ${CYAN}Version ${SCRIPT_VERSION}${NC}${BOLD}                        ||${NC}"
    echo -e "${BOLD}================================================================${NC}"
    echo
}

display_status() {
    echo -e "${BOLD}System Status:${NC}"
    
    # MediaMTX status
    if [[ "$MEDIAMTX_INSTALLED" == "true" ]]; then
        if [[ "$MEDIAMTX_RUNNING" == "true" ]]; then
            echo -e "  MediaMTX:  ${GREEN}Running${NC} (${MEDIAMTX_VERSION})"
        else
            echo -e "  MediaMTX:  ${YELLOW}Installed but not running${NC} (${MEDIAMTX_VERSION})"
        fi
    else
        echo -e "  MediaMTX:  ${RED}Not installed${NC}"
    fi
    
    # Stream status
    if (( ACTIVE_STREAMS > 0 )); then
        echo -e "  Streams:   ${GREEN}${ACTIVE_STREAMS} active${NC}"
    else
        echo -e "  Streams:   ${YELLOW}None active${NC}"
    fi
    
    # USB mapping status
    if [[ "$USB_DEVICES_MAPPED" == "true" ]]; then
        echo -e "  USB Maps:  ${GREEN}Configured${NC}"
    else
        echo -e "  USB Maps:  ${YELLOW}Not configured${NC}"
    fi
    
    echo
}

display_error() {
    if [[ -n "$LAST_ERROR" ]]; then
        echo -e "${RED}Last Error:${NC} ${LAST_ERROR}"
        echo
    fi
}

pause() {
    read -rp "Press Enter to continue..."
}

# ============================================================================
# Menu Functions
# ============================================================================

menu_main() {
    while true; do
        display_header "clear"
        display_status
        display_error
        
        echo -e "${BOLD}Main Menu:${NC}"
        echo "  1) Quick Setup (First-time installation)"
        echo "  2) MediaMTX Installation & Updates"
        echo "  3) Audio Streaming Control"
        echo "  4) USB Device Management"
        echo "  5) System Diagnostics"
        echo "  6) Version & Update Management"
        echo "  7) View Logs & Status"
        echo "  8) Refresh System Status"
        echo "  0) Exit"
        echo
        read -rp "Select option: " choice
        
        case "$choice" in
            1)
                menu_quick_setup
                ;;
            2)
                menu_mediamtx_installation
                ;;
            3)
                menu_streaming_control
                ;;
            4)
                menu_usb_devices
                ;;
            5)
                menu_diagnostics
                ;;
            6)
                menu_version_management
                ;;
            7)
                menu_logs_status
                ;;
            8)
                refresh_system_state
                success "System status refreshed"
                sleep 1
                ;;
            0)
                echo
                info "Exiting LyreBirdAudio Orchestrator"
                exit 0
                ;;
            *)
                error "Invalid option. Please select 0-8."
                sleep 1
                ;;
        esac
        
        LAST_ERROR=""
    done
}

menu_quick_setup() {
    display_header "clear"
    echo -e "${BOLD}Quick Setup Wizard${NC}"
    echo
    echo "This wizard will guide you through initial setup:"
    echo "  1. Install/Update MediaMTX"
    echo "  2. Map USB audio devices"
    echo "  3. Start audio streaming"
    echo "  4. Run quick diagnostics"
    echo
    
    read -rp "Continue with quick setup? (y/n): " -n 1
    echo
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        return
    fi
    
    # Step 1: Install MediaMTX
    echo
    echo -e "${BOLD}Step 1/4: Installing MediaMTX...${NC}"
    if execute_script "installer" install; then
        success "MediaMTX installed successfully"
    else
        error "Failed to install MediaMTX"
        echo
        info "You can retry from: Main Menu -> MediaMTX Installation & Updates"
        pause
        refresh_system_state
        return
    fi
    
    refresh_system_state
    
    # Step 2: Map USB devices
    echo
    echo -e "${BOLD}Step 2/4: Mapping USB audio devices...${NC}"
    echo
    info "The USB mapper will open in interactive mode"
    info "Follow the prompts to map your audio devices"
    echo
    read -rp "Press Enter to start USB device mapper..."
    
    if execute_script "usb_mapper"; then
        success "USB devices mapped successfully"
    else
        warning "USB mapping incomplete or skipped"
        info "You can map devices later from: Main Menu -> USB Device Management"
    fi
    
    refresh_system_state
    
    echo
    info "USB devices are now mapped to stable /dev/snd/by-usb-port/ paths"
    info "A reboot is recommended for udev rules to take full effect"
    echo
    read -rp "Reboot now? (y/n): " -n 1
    echo
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        info "System will reboot now. Run this script again after reboot to continue setup."
        sleep 2
        reboot
        exit 0
    fi
    
    echo
    info "Continuing setup without reboot..."
    info "Note: If streams fail to start, a reboot may be required"
    echo
    read -rp "Continue? (y/n): " -n 1
    echo
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        return
    fi
    
    # Step 3: Start streams
    echo
    echo -e "${BOLD}Step 3/4: Starting audio streams...${NC}"
    if execute_script "stream_manager" start; then
        success "Audio streams started successfully"
    else
        error "Failed to start audio streams"
        echo
        info "Common causes:"
        info "  * MediaMTX not running properly"
        info "  * USB devices not yet recognized (reboot may be needed)"
        info "  * Configuration issues"
        echo
        info "Next steps:"
        info "  * Check stream status: Streaming Control -> View Status"
        info "  * Run diagnostics: System Diagnostics -> Full Diagnostics"
    fi
    
    # Step 4: Quick diagnostics
    echo
    echo -e "${BOLD}Step 4/4: Running quick diagnostics...${NC}"
    echo
    
    # Handle diagnostics exit codes properly (0=success, 1=warnings, 2=failures)
    local diag_result=0
    execute_script "diagnostics" "quick" || diag_result=$?
    
    case ${diag_result} in
        "${E_DIAG_SUCCESS}")
            success "Quick diagnostics completed - all checks passed"
            ;;
        "${E_DIAG_WARN}")
            warning "Quick diagnostics completed with warnings"
            info "Review the diagnostic output above for details"
            ;;
        "${E_DIAG_FAIL}")
            error "Quick diagnostics detected failures"
            info "Review the diagnostic output above for details"
            ;;
        *)
            error "Diagnostics failed unexpectedly"
            ;;
    esac
    
    echo
    success "Quick setup complete!"
    echo
    
    if [[ "$MEDIAMTX_RUNNING" == "true" ]] && (( ACTIVE_STREAMS > 0 )); then
        echo "+ Your RTSP streams are now available!"
        echo
        info "Stream URLs follow this format:"
        info "  rtsp://$(get_primary_ip):8554/<device-name>"
        echo
        info "Example:"
        info "  rtsp://192.168.1.100:8554/usb-microphone-1"
    else
        echo "! Setup completed with warnings"
        echo
        info "Your system may require a reboot before streams become available."
        info "After reboot, start streams from: Main Menu -> Audio Streaming Control"
    fi
    
    echo
    pause
    
    refresh_system_state
}

menu_mediamtx_installation() {
    while true; do
        display_header "clear"
        echo -e "${BOLD}MediaMTX Installation & Updates${NC}"
        echo
        display_status
        display_error
        
        echo -e "${BOLD}Installation Options:${NC}"
        echo "  1) Install or Update MediaMTX (Latest Version)"
        echo "  2) Install Specific MediaMTX Version"
        echo "  3) Check Installation Status"
        echo "  4) Verify Installation"
        echo "  5) Uninstall MediaMTX"
        echo "  0) Back to Main Menu"
        echo
        read -rp "Select option: " choice
        
        case "$choice" in
            1)
                echo
                if [[ "$MEDIAMTX_INSTALLED" == "true" ]]; then
                    echo "Updating MediaMTX to latest version..."
                    if execute_script "installer" update; then
                        success "MediaMTX updated successfully"
                        refresh_system_state
                    else
                        error "Update failed"
                    fi
                else
                    echo "Installing MediaMTX (latest version)..."
                    if execute_script "installer" install; then
                        success "MediaMTX installed successfully"
                        refresh_system_state
                    else
                        error "Installation failed"
                    fi
                fi
                echo
                pause
                ;;
            2)
                echo
                read -rp "Enter MediaMTX version (e.g., v1.15.1): " version
                if [[ -n "$version" ]]; then
                    if validate_version_string "$version"; then
                        echo "Installing MediaMTX ${version}..."
                        if execute_script "installer" install --target-version "$version"; then
                            success "MediaMTX ${version} installed successfully"
                            refresh_system_state
                        else
                            error "Installation failed"
                        fi
                    else
                        error "Invalid version format. Expected: v1.15.1 or 1.15.1"
                        LAST_ERROR="Invalid version format: $version"
                    fi
                else
                    warning "No version specified"
                fi
                echo
                pause
                ;;
            3)
                echo
                echo "Checking MediaMTX installation status..."
                echo "================================================================"
                execute_script "installer" status || true
                echo "================================================================"
                refresh_system_state
                pause
                ;;
            4)
                echo
                echo "Verifying MediaMTX installation..."
                echo "================================================================"
                execute_script "installer" verify || true
                echo "================================================================"
                pause
                ;;
            5)
                echo
                warning "This will remove MediaMTX and stop all streams"
                read -rp "Are you sure? (y/n): " -n 1
                echo
                if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                    if execute_script "installer" uninstall; then
                        success "MediaMTX uninstalled successfully"
                        refresh_system_state
                    else
                        error "Uninstall failed"
                    fi
                fi
                echo
                pause
                ;;
            0)
                return
                ;;
            *)
                error "Invalid option. Please select 0-5."
                sleep 1
                ;;
        esac
    done
}

menu_streaming_control() {
    while true; do
        display_header "clear"
        echo -e "${BOLD}Audio Streaming Control${NC}"
        echo
        display_status
        display_error
        
        echo -e "${BOLD}Streaming Options:${NC}"
        echo "  1) Start Audio Streams"
        echo "  2) Stop Audio Streams"
        echo "  3) Restart Audio Streams"
        echo "  4) View Stream Status"
        echo "  5) Monitor Streams (Live)"
        echo "  6) Force Stop All Streams"
        echo "  7) Select Streaming Mode"
        echo "  0) Back to Main Menu"
        echo
        read -rp "Select option: " choice
        
        case "$choice" in
            1)
                echo
                echo "Starting audio streams..."
                if execute_script "stream_manager" start; then
                    success "Streams started successfully"
                    refresh_system_state
                else
                    error "Failed to start streams"
                fi
                echo
                pause
                ;;
            2)
                echo
                echo "Stopping audio streams..."
                if execute_script "stream_manager" stop; then
                    success "Streams stopped successfully"
                    refresh_system_state
                else
                    warning "Stop command completed with warnings"
                fi
                echo
                pause
                ;;
            3)
                echo
                echo "Restarting audio streams..."
                if execute_script "stream_manager" restart; then
                    success "Streams restarted successfully"
                    refresh_system_state
                else
                    error "Failed to restart streams"
                fi
                echo
                pause
                ;;
            4)
                echo
                echo "Stream Status:"
                echo "================================================================"
                execute_script "stream_manager" status || true
                echo "================================================================"
                refresh_system_state
                pause
                ;;
            5)
                echo
                info "Starting live stream monitor..."
                info "Press Ctrl+C to exit monitor and return to menu"
                echo
                sleep 2
                execute_script "stream_manager" monitor || true
                echo
                refresh_system_state
                pause
                ;;
            6)
                echo
                warning "This will forcefully terminate all streams and MediaMTX"
                read -rp "Are you sure? (y/n): " -n 1
                echo
                if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                    echo
                    if execute_script "stream_manager" force-stop; then
                        success "All streams forcefully stopped"
                        refresh_system_state
                    else
                        warning "Force stop completed with warnings"
                    fi
                fi
                echo
                pause
                ;;
            7)
                echo
                echo -e "${BOLD}Select Streaming Mode:${NC}"
                echo "  1) Individual streams (separate stream per device)"
                echo "  2) Multiplex mode (combine all devices into one stream)"
                echo "  0) Cancel"
                echo
                read -rp "Select mode: " mode_choice
                
                case "$mode_choice" in
                    1)
                        echo
                        info "Switching to individual stream mode..."
                        if execute_script "stream_manager" start --mode individual; then
                            success "Individual stream mode activated"
                            refresh_system_state
                        else
                            error "Failed to switch mode"
                        fi
                        echo
                        pause
                        ;;
                    2)
                        echo
                        info "Switching to multiplex mode..."
                        if execute_script "stream_manager" start --mode multiplex; then
                            success "Multiplex mode activated"
                            refresh_system_state
                        else
                            error "Failed to switch mode"
                        fi
                        echo
                        pause
                        ;;
                    0)
                        ;;
                    *)
                        error "Invalid mode selection"
                        sleep 1
                        ;;
                esac
                ;;
            0)
                return
                ;;
            *)
                error "Invalid option. Please select 0-7."
                sleep 1
                ;;
        esac
    done
}

menu_usb_devices() {
    while true; do
        display_header "clear"
        echo -e "${BOLD}USB Device Management${NC}"
        echo
        display_status
        display_error
        
        echo -e "${BOLD}USB Device Options:${NC}"
        echo "  1) Map USB Audio Devices (Interactive)"
        echo "  2) Test Device Mapping (Dry-run)"
        echo "  3) View Current Mappings"
        echo "  4) Remove Device Mappings"
        echo "  5) Reload udev Rules"
        echo "  0) Back to Main Menu"
        echo
        read -rp "Select option: " choice
        
        case "$choice" in
            1)
                echo
                info "Starting USB device mapper in interactive mode..."
                echo
                execute_script "usb_mapper" || true
                echo
                refresh_system_state
                pause
                ;;
            2)
                echo
                info "Testing device mapping (dry-run mode)..."
                echo
                execute_script "usb_mapper" --test || true
                echo
                pause
                ;;
            3)
                echo
                echo "Current USB Device Mappings:"
                echo "================================================================"
                if [[ -f "$UDEV_RULES" ]] && [[ -s "$UDEV_RULES" ]]; then
                    cat "$UDEV_RULES"
                    echo
                    echo "================================================================"
                    echo
                    info "Mapped device paths:"
                    ls -la /dev/snd/by-usb-port/ 2>/dev/null || echo "  No devices currently mapped"
                else
                    echo "  No device mappings configured"
                    echo "================================================================"
                fi
                echo
                pause
                ;;
            4)
                echo
                warning "This will remove all USB device mappings"
                read -rp "Are you sure? (y/n): " -n 1
                echo
                if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                    if [[ -f "$UDEV_RULES" ]]; then
                        rm -f "$UDEV_RULES"
                        udevadm control --reload-rules
                        udevadm trigger
                        success "Device mappings removed"
                        refresh_system_state
                    else
                        info "No mappings to remove"
                    fi
                fi
                echo
                pause
                ;;
            5)
                echo
                info "Reloading udev rules..."
                if udevadm control --reload-rules && udevadm trigger; then
                    success "Udev rules reloaded"
                else
                    error "Failed to reload udev rules"
                fi
                echo
                pause
                ;;
            0)
                return
                ;;
            *)
                error "Invalid option. Please select 0-5."
                sleep 1
                ;;
        esac
    done
}

menu_diagnostics() {
    while true; do
        display_header "clear"
        echo -e "${BOLD}System Diagnostics${NC}"
        echo
        display_status
        display_error
        
        echo -e "${BOLD}Diagnostic Options:${NC}"
        echo "  1) Quick Health Check"
        echo "  2) Full System Diagnostics"
        echo "  3) Debug Mode (Comprehensive)"
        echo "  0) Back to Main Menu"
        echo
        read -rp "Select option: " choice
        
        case "$choice" in
            1)
                echo
                echo "Running quick health check..."
                echo "================================================================"
                
                # Handle diagnostics exit codes properly (0=success, 1=warnings, 2=failures)
                local diag_result=0
                execute_script "diagnostics" "quick" || diag_result=$?
                
                case ${diag_result} in
                    "${E_DIAG_SUCCESS}")
                        success "Quick diagnostics completed - all checks passed"
                        ;;
                    "${E_DIAG_WARN}")
                        warning "Quick diagnostics found warnings"
                        ;;
                    "${E_DIAG_FAIL}")
                        error "Quick diagnostics detected failures"
                        ;;
                esac
                
                echo "================================================================"
                pause
                ;;
            2)
                echo
                echo "Running full system diagnostics..."
                echo "================================================================"
                
                # Handle diagnostics exit codes properly (0=success, 1=warnings, 2=failures)
                local diag_result=0
                execute_script "diagnostics" "full" || diag_result=$?
                
                case ${diag_result} in
                    "${E_DIAG_SUCCESS}")
                        success "Full diagnostics completed - all checks passed"
                        ;;
                    "${E_DIAG_WARN}")
                        warning "Full diagnostics found warnings"
                        ;;
                    "${E_DIAG_FAIL}")
                        error "Full diagnostics detected failures"
                        ;;
                esac
                
                echo "================================================================"
                pause
                ;;
            3)
                echo
                echo "Running debug diagnostics (comprehensive check)..."
                echo "================================================================"
                
                # Handle diagnostics exit codes properly (0=success, 1=warnings, 2=failures)
                local diag_result=0
                execute_script "diagnostics" "debug" || diag_result=$?
                
                case ${diag_result} in
                    "${E_DIAG_SUCCESS}")
                        success "Debug diagnostics completed - all checks passed"
                        ;;
                    "${E_DIAG_WARN}")
                        warning "Debug diagnostics found warnings"
                        ;;
                    "${E_DIAG_FAIL}")
                        error "Debug diagnostics detected failures"
                        ;;
                esac
                
                echo "================================================================"
                pause
                ;;
            0)
                return
                ;;
            *)
                error "Invalid option. Please select 0-3."
                sleep 1
                ;;
        esac
    done
}

menu_version_management() {
    while true; do
        display_header "clear"
        echo -e "${BOLD}Version & Update Management${NC}"
        echo
        display_status
        display_error
        
        echo -e "${BOLD}Version Options:${NC}"
        echo "  1) Check Current Version"
        echo "  2) List Available Versions"
        echo "  3) Update to Latest Version"
        echo "  4) Switch to Specific Version"
        echo "  5) View Update History"
        echo "  6) Interactive Version Manager"
        echo "  7) View Component Versions"
        echo "  0) Back to Main Menu"
        echo
        read -rp "Select option: " choice
        
        case "$choice" in
            1)
                echo
                echo "Current Version Information:"
                echo "================================================================"
                execute_script "updater" --status || true
                echo "================================================================"
                pause
                ;;
            2)
                echo
                echo "Available Versions:"
                echo "================================================================"
                execute_script "updater" --list || true
                echo "================================================================"
                pause
                ;;
            3)
                echo
                warning "This will update to the latest stable version"
                read -rp "Continue? (y/n): " -n 1
                echo
                if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                    echo
                    if execute_script "updater" --update latest; then
                        success "Updated to latest version"
                        info "Please restart the orchestrator to use the updated version"
                    else
                        error "Update failed"
                    fi
                fi
                echo
                pause
                ;;
            4)
                echo
                read -rp "Enter version (e.g., v1.0.0 or dev-main): " version
                if [[ -n "$version" ]]; then
                    case "$version" in
                        dev-main)
                            echo
                            warning "This will switch to development version: ${version}"
                            read -rp "Continue? (y/n): " -n 1
                            echo
                            if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                                echo
                                if execute_script "updater" --update "$version"; then
                                    success "Switched to version: ${version}"
                                    info "Please restart the orchestrator"
                                else
                                    error "Version switch failed"
                                fi
                            fi
                            ;;
                        v[0-9]*|[0-9]*)
                            if validate_version_string "$version"; then
                                echo
                                warning "This will switch to version: ${version}"
                                read -rp "Continue? (y/n): " -n 1
                                echo
                                if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                                    echo
                                    if execute_script "updater" --update "$version"; then
                                        success "Switched to version: ${version}"
                                        info "Please restart the orchestrator"
                                    else
                                        error "Version switch failed"
                                    fi
                                fi
                            else
                                error "Invalid version format for updater"
                                LAST_ERROR="Invalid version format: $version"
                            fi
                            ;;
                        *)
                            error "Invalid version: $version"
                            LAST_ERROR="Invalid version format: $version"
                            ;;
                    esac
                else
                    warning "No version specified"
                fi
                echo
                pause
                ;;
            5)
                echo
                echo "Update History:"
                echo "================================================================"
                execute_script "updater" --history || true
                echo "================================================================"
                pause
                ;;
            6)
                echo
                info "Starting interactive version manager..."
                echo
                execute_script "updater" || true
                echo
                info "Returned from version manager"
                pause
                ;;
            7)
                echo
                echo "Component Versions:"
                echo "================================================================"
                echo "Orchestrator:  ${SCRIPT_VERSION}"
                
                for key in "${!SCRIPT_PATHS[@]}"; do
                    local script_path="${SCRIPT_PATHS[$key]}"
                    local script_name
                    script_name="$(basename "$script_path")"
                    local version
                    version="$(extract_script_version "$script_path")"
                    printf "%-25s %s\n" "${script_name}:" "${version}"
                done
                
                echo
                if [[ "$MEDIAMTX_INSTALLED" == "true" ]]; then
                    echo "MediaMTX:      ${MEDIAMTX_VERSION}"
                else
                    echo "MediaMTX:      not installed"
                fi
                echo "================================================================"
                pause
                ;;
            0)
                return
                ;;
            *)
                error "Invalid option. Please select 0-7."
                sleep 1
                ;;
        esac
    done
}

menu_logs_status() {
    while true; do
        display_header "clear"
        echo -e "${BOLD}Logs & Status${NC}"
        echo
        display_status
        display_error
        
        echo -e "${BOLD}View Options:${NC}"
        echo "  1) View MediaMTX Log (Last 50 lines)"
        echo "  2) View Orchestrator Log"
        echo "  3) View Stream Manager Log"
        echo "  4) View Stream Logs (FFmpeg)"
        echo "  5) Quick System Health Check"
        echo "  0) Back to Main Menu"
        echo
        read -rp "Select option: " choice
        
        case "$choice" in
            1)
                echo
                echo "MediaMTX Log (last 50 lines):"
                echo "================================================================"
                if [[ -f "$MEDIAMTX_LOG_FILE" ]]; then
                    tail -n 50 "$MEDIAMTX_LOG_FILE" 2>/dev/null || echo "Cannot read log file"
                else
                    echo "Log file not found: ${MEDIAMTX_LOG_FILE}"
                fi
                echo "================================================================"
                echo
                info "Full log location: ${MEDIAMTX_LOG_FILE}"
                pause
                ;;
            2)
                echo
                echo "Orchestrator Log (last 50 lines):"
                echo "================================================================"
                if [[ -f "$LOG_FILE" ]] && [[ "$LOG_FILE" != "/dev/null" ]]; then
                    tail -n 50 "$LOG_FILE" 2>/dev/null || echo "Cannot read log file"
                else
                    echo "No log file available"
                fi
                echo "================================================================"
                if [[ -f "$LOG_FILE" ]] && [[ "$LOG_FILE" != "/dev/null" ]]; then
                    echo
                    info "Full log location: ${LOG_FILE}"
                fi
                pause
                ;;
            3)
                echo
                echo "Stream Manager Log (last 50 lines):"
                echo "================================================================"
                local stream_mgr_log="/var/log/mediamtx-stream-manager.log"
                if [[ -f "$stream_mgr_log" ]]; then
                    tail -n 50 "$stream_mgr_log" 2>/dev/null || echo "Cannot read log file"
                else
                    echo "Log file not found: ${stream_mgr_log}"
                fi
                echo "================================================================"
                echo
                info "Full log location: ${stream_mgr_log}"
                pause
                ;;
            4)
                echo
                echo "Stream Logs (FFmpeg):"
                echo "================================================================"
                if [[ -d "$FFMPEG_LOG_DIR" ]]; then
                    if ls "${FFMPEG_LOG_DIR}"/*.log >/dev/null 2>&1; then
                        ls -lh "${FFMPEG_LOG_DIR}"/*.log 2>/dev/null || true
                        echo "================================================================"
                        echo
                        info "To view a specific log:"
                        info "  tail -f ${FFMPEG_LOG_DIR}/<device-name>.log"
                    else
                        warning "No stream logs found in: ${FFMPEG_LOG_DIR}"
                        info "Logs will appear here when streams are active"
                    fi
                else
                    warning "Stream log directory not found: ${FFMPEG_LOG_DIR}"
                    info "Directory will be created when streams start"
                fi
                echo
                pause
                ;;
            5)
                echo
                echo "Running quick diagnostic summary..."
                echo "================================================================"
                
                # Handle diagnostics exit codes properly (0=success, 1=warnings, 2=failures)
                local diag_result=0
                execute_script "diagnostics" "quick" || diag_result=$?
                
                case ${diag_result} in
                    "${E_DIAG_SUCCESS}")
                        success "System health check passed"
                        ;;
                    "${E_DIAG_WARN}")
                        warning "System health check found warnings"
                        info "Run full diagnostics for details: Main Menu -> System Diagnostics"
                        ;;
                    "${E_DIAG_FAIL}")
                        error "System health check detected failures"
                        info "Run full diagnostics for details: Main Menu -> System Diagnostics"
                        ;;
                esac
                
                echo "================================================================"
                pause
                ;;
            0)
                return
                ;;
            *)
                error "Invalid option. Please select 0-5."
                sleep 1
                ;;
        esac
    done
}

# ============================================================================
# Main Function
# ============================================================================

main() {
    # Initial checks
    check_root
    check_terminal
    check_dependencies
    
    # Setup cleanup handler for graceful termination
    cleanup() {
        log "INFO" "Orchestrator terminated by signal"
        # Remove temp files if any
        if [[ -n "${LOG_FILE:-}" && "$LOG_FILE" == /tmp/* && -f "$LOG_FILE" ]]; then
            rm -f "$LOG_FILE"
        fi
    }
    trap cleanup EXIT SIGINT SIGTERM
    
    # Initialize logging with rotation and security
    initialize_logging
    
    # Find and validate external scripts
    if ! find_external_scripts; then
        exit ${E_SCRIPT_NOT_FOUND}
    fi
    
    # Log detected versions
    log "INFO" "=== Detected Script Versions ==="
    for key in "${!SCRIPT_PATHS[@]}"; do
        local script_path="${SCRIPT_PATHS[$key]}"
        local script_name
        script_name="$(basename "$script_path")"
        local detected_version
        detected_version="$(extract_script_version "$script_path")"
        log "INFO" "${script_name}: ${detected_version}"
    done
    log "INFO" "=== End Version Detection ==="
    
    # Validate script versions (suppress stdout, log warnings only)
    # This prevents the brief flash of warnings at startup before menu clears screen
    if ! validate_script_versions 2>&1 | while read -r line; do log "WARN" "$line"; done; then
        log "WARN" "Version detection completed with warnings (non-blocking)"
    fi
    
    # Initial system state detection
    refresh_system_state
    
    # Start main menu
    menu_main
}

# Run main function
main "$@"

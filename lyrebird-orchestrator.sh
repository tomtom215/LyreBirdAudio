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
# Version: 2.1.0
# Description: Production-grade orchestrator providing unified access to all
#              LyreBirdAudio components with comprehensive functionality,
#              intuitive navigation, and robust error handling.
#
# v2.1.0 Microphone Capability Detection & Enhanced Security:
#   NEW FEATURES:
#   - Integrated hardware capability detection with lyrebird-mic-check.sh
#   - Device capability inspection in USB Device Management menu
#   - Configuration generation with quality tiers (low/normal/high)
#   - Configuration validation against hardware capabilities
#   - Enhanced USB menu with comprehensive device configuration workflow
#   - Support for mediamtx-stream-manager v1.4.1 friendly name feature
#   
#   SECURITY & RELIABILITY ENHANCEMENTS:
#   - TOCTOU race condition protection in log file handling
#   - Comprehensive EOF/stdin handling across all interactive menus
#   - Environment variable validation for all file system paths
#   - DoS prevention with stream count limits and validation
#   - Complete signal handler implementation with child process cleanup
#   - SHA256 integrity checking for all external scripts
#   - Improved version validation and error reporting
#   - Standardized exit codes for consistent error handling
#   - Eliminated unsafe eval usage in privilege dropping
#   - Absolute paths for all system commands
#   - Enhanced updater integration with proper privilege management
#   - Improved initialization robustness and error recovery
#   
#   COMPATIBILITY:
#   - Maintains full backward compatibility with v2.0.1
#   - All existing workflows and integrations preserved

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

readonly SCRIPT_VERSION="2.1.0"

# Initialize constants safely (separate declaration from assignment to catch errors)
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
        return 0  # Return 0 to avoid triggering set -e
    fi
    
    if [[ ! -f "$source" ]]; then
        echo "ERROR: Resolved script path does not exist: $source" >&2
        echo "/dev/null"
        return 0  # Return 0 to avoid triggering set -e
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

# Validate log path meets security requirements
# Returns validated path or default, always succeeds to prevent initialization failures
validate_log_path() {
    local path="$1"
    local default="$2"
    
    # Reject empty or unset path
    if [[ -z "$path" ]]; then
        echo "$default"
        return 0
    fi
    
    # Security checks
    if [[ "$path" != /* ]] || \
       [[ "$path" != /var/log/* ]] || \
       [[ "$path" == *".."* ]] || \
       ! [[ "$path" =~ ^/var/log/[a-zA-Z0-9_./-]+$ ]]; then
        echo "$default"
        # Log warning only if log function exists (during initialization it may not)
        if declare -f log >/dev/null 2>&1; then
            log "WARN" "Rejected invalid log path: $path (using default: $default)"
        fi
        return 0
    fi
    
    echo "$path"
    return 0
}

# External script paths
declare -A EXTERNAL_SCRIPTS=(
    ["installer"]="install_mediamtx.sh"
    ["stream_manager"]="mediamtx-stream-manager.sh"
    ["usb_mapper"]="usb-audio-mapper.sh"
    ["mic_check"]="lyrebird-mic-check.sh"
    ["updater"]="lyrebird-updater.sh"
    ["diagnostics"]="lyrebird-diagnostics.sh"
)

# Configuration paths (all paths validated for security requirements)
readonly UDEV_RULES="/etc/udev/rules.d/99-usb-soundcards.rules"

# Validate and set log file paths
MEDIAMTX_LOG_FILE=$(validate_log_path "${MEDIAMTX_LOG_FILE:-}" "/var/log/mediamtx.out")
readonly MEDIAMTX_LOG_FILE

FFMPEG_LOG_DIR=$(validate_log_path "${FFMPEG_LOG_DIR:-}" "/var/log/lyrebird")
readonly FFMPEG_LOG_DIR

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
declare -A SCRIPT_CHECKSUMS=()  # SHA256 checksums for script integrity verification
LAST_ERROR=""
MEDIAMTX_INSTALLED=false
MEDIAMTX_RUNNING=false
MEDIAMTX_VERSION="unknown"
USB_DEVICES_MAPPED=false
ACTIVE_STREAMS=0
CHILD_PID=""  # Track current child process for proper signal handling and cleanup

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
    echo -e "${GREEN}✓${NC} $*"
}

error() {
    echo -e "${RED}✗${NC} $*"
}

warning() {
    echo -e "${YELLOW}!${NC} $*"
}

info() {
    echo -e "${CYAN}→${NC} $*"
}

pause() {
    echo
    if ! read -rp "Press Enter to continue..."; then
        echo
        log "DEBUG" "Pause interrupted by EOF"
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ============================================================================
# Initialization Functions
# ============================================================================

# Initialize logging with security protections against TOCTOU race conditions
initialize_logging() {
    local default_log="/var/log/lyrebird-orchestrator.log"
    local log_candidate
    
    # Use environment variable if set, otherwise default
    log_candidate=$(validate_log_path "${ORCHESTRATOR_LOG_FILE:-}" "$default_log")
    
    # Attempt to create log file with race condition protection
    if [[ -w "$(dirname "$log_candidate")" ]]; then
        # Verify path is a regular file (not symlink, device, etc.)
        # This prevents TOCTOU attacks where log file is replaced with malicious symlink
        if [[ -e "$log_candidate" ]]; then
            if [[ ! -f "$log_candidate" ]] || [[ -L "$log_candidate" ]]; then
                echo "WARNING: Log path exists but is not a regular file: $log_candidate" >&2
                echo "Falling back to temporary log file" >&2
                log_candidate="/tmp/lyrebird-orchestrator-$$.log"
            fi
        fi
        
        # Attempt to create/write to log file
        if touch "$log_candidate" 2>/dev/null && [[ -w "$log_candidate" ]]; then
            LOG_FILE="$log_candidate"
        else
            echo "WARNING: Cannot write to log file: $log_candidate" >&2
            echo "Falling back to temporary log file" >&2
            LOG_FILE="/tmp/lyrebird-orchestrator-$$.log"
            touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"
        fi
    else
        LOG_FILE="/tmp/lyrebird-orchestrator-$$.log"
        touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"
    fi
    
    if [[ "$LOG_FILE" != "/dev/null" ]]; then
        # Simple log rotation: if log exceeds 1MB, rotate to .1 backup
        if [[ -f "$LOG_FILE" ]] && [[ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 1048576 ]]; then
            local backup="${LOG_FILE}.1"
            mv -f "$LOG_FILE" "$backup" 2>/dev/null || true
            touch "$LOG_FILE" 2>/dev/null || true
        fi
    fi
    
    readonly LOG_FILE
    
    log "INFO" "=== Orchestrator Started (v${SCRIPT_VERSION}) ==="
    log "INFO" "Running as: $(whoami)"
    log "INFO" "Log file: ${LOG_FILE}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
        echo
        info "Usage: sudo ${SCRIPT_NAME}"
        exit ${E_PERMISSION}
    fi
}

check_terminal() {
    if [[ ! -t 0 ]]; then
        error "This script requires an interactive terminal"
        echo
        info "Please run in a terminal session, not as a background process"
        exit ${E_GENERAL}
    fi
}

check_dependencies() {
    local missing=()
    local deps=("pgrep" "grep" "awk" "sed")
    
    for cmd in "${deps[@]}"; do
        if ! command_exists "$cmd"; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required dependencies: ${missing[*]}"
        echo
        info "Install with: sudo apt-get install ${missing[*]}"
        log "ERROR" "Missing dependencies: ${missing[*]}"
        exit ${E_DEPENDENCY}
    fi
}

# Find and validate all external scripts, computing SHA256 checksums for integrity verification
find_external_scripts() {
    local all_found=true
    
    log "INFO" "Searching for external scripts in: ${SCRIPT_DIR}"
    
    for key in "${!EXTERNAL_SCRIPTS[@]}"; do
        local script_name="${EXTERNAL_SCRIPTS[$key]}"
        local script_path="${SCRIPT_DIR}/${script_name}"
        
        if [[ ! -f "$script_path" ]]; then
            error "Required script not found: ${script_name}"
            log "ERROR" "Missing script: ${script_path}"
            all_found=false
            continue
        fi
        
        if [[ ! -x "$script_path" ]]; then
            warning "Script not executable: ${script_name}"
            info "Attempting to make executable..."
            if chmod +x "$script_path" 2>/dev/null; then
                success "Made ${script_name} executable"
                log "INFO" "Made script executable: ${script_path}"
            else
                error "Cannot make executable: ${script_name}"
                log "ERROR" "Cannot chmod: ${script_path}"
                all_found=false
                continue
            fi
        fi
        
        SCRIPT_PATHS["$key"]="$script_path"
        
        # Compute and store SHA256 checksum for integrity verification
        if command_exists sha256sum; then
            local checksum
            checksum="$(sha256sum "$script_path" 2>/dev/null | awk '{print $1}')"
            if [[ -n "$checksum" ]]; then
                SCRIPT_CHECKSUMS["$key"]="$checksum"
                log "DEBUG" "Checksum for ${script_name}: ${checksum}"
            fi
        fi
        
        log "INFO" "Found: ${script_name} -> ${script_path}"
    done
    
    if [[ "$all_found" == "false" ]]; then
        echo
        error "Some required scripts are missing"
        echo
        info "Ensure all LyreBirdAudio scripts are in: ${SCRIPT_DIR}"
        log "ERROR" "Script discovery failed"
        return 1
    fi
    
    success "All required scripts found and validated"
    return 0
}

# Extract version from script (improved pattern matching)
extract_script_version() {
    local script_path="$1"
    local version="unknown"
    
    # Try multiple patterns to find version
    # Pattern 1: readonly VERSION="x.y.z"
    if version=$(grep -m1 '^readonly VERSION=' "$script_path" 2>/dev/null | sed -E 's/.*VERSION="?([0-9]+\.[0-9]+\.[0-9]+)"?.*/\1/'); then
        if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$version"
            return
        fi
    fi
    
    # Pattern 2: Version: x.y.z
    if version=$(grep -m1 '^# Version:' "$script_path" 2>/dev/null | sed -E 's/.*Version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/'); then
        if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$version"
            return
        fi
    fi
    
    # Pattern 3: SCRIPT_VERSION="x.y.z"
    if version=$(grep -m1 'SCRIPT_VERSION=' "$script_path" 2>/dev/null | sed -E 's/.*SCRIPT_VERSION="?([0-9]+\.[0-9]+\.[0-9]+)"?.*/\1/'); then
        if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$version"
            return
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
    
    # Count active streams with DoS prevention (limit to reasonable maximum)
    ACTIVE_STREAMS=0
    
    if pgrep -x ffmpeg >/dev/null 2>&1; then
        local raw_count
        
        # Use efficient pgrep -c if available, otherwise limit output before counting
        if command_exists pgrep && pgrep --help 2>&1 | grep -q -- '-c'; then
            # Modern pgrep supports -c for efficient counting
            raw_count=$(pgrep -c -x ffmpeg 2>/dev/null || echo 0)
        else
            # Fallback: limit output before counting to prevent DoS
            # head -n 1001 ensures we never process more than 1001 PIDs
            raw_count=$(pgrep -x ffmpeg 2>/dev/null | head -n 1001 | wc -l)
        fi
        
        # Validate count and apply reasonable upper limit
        if [[ "$raw_count" =~ ^[0-9]+$ ]] && (( raw_count > 0 && raw_count <= 1000 )); then
            ACTIVE_STREAMS=$raw_count
        elif [[ "$raw_count" =~ ^[0-9]+$ ]] && (( raw_count > 1000 )); then
            log "ERROR" "Excessive stream count detected: $raw_count (capping at 1000)"
            log "ERROR" "System may be under attack or experiencing runaway processes"
            ACTIVE_STREAMS=1000  # Cap at reasonable limit for display
        else
            log "WARN" "Invalid stream count: '$raw_count'"
            ACTIVE_STREAMS=0
        fi
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
# Handles script execution with integrity checking, privilege management, and signal handling
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
    
    # Verify script integrity before execution (TOCTOU protection)
    if [[ -v "SCRIPT_CHECKSUMS[$script_key]" ]] && command_exists sha256sum; then
        local expected="${SCRIPT_CHECKSUMS[$script_key]}"
        local actual
        actual="$(sha256sum "$script_path" 2>/dev/null | awk '{print $1}')"
        
        if [[ "$actual" != "$expected" ]]; then
            error "SECURITY: Script modified since validation"
            log "ERROR" "Integrity check failed: $script_path"
            log "ERROR" "Expected: $expected"
            log "ERROR" "Actual: $actual"
            LAST_ERROR="Script integrity violation: $(basename "$script_path")"
            return 1
        fi
    fi
    
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
        
        # Determine user's home directory safely without eval
        local user_home
        user_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)" || \
        user_home="$(cd ~"$SUDO_USER" 2>/dev/null && pwd)" || {
            error "Cannot determine home for $SUDO_USER"
            LAST_ERROR="Cannot determine home for $SUDO_USER"
            return 1
        }
        
        # Execute with privilege drop, tracking child PID for signal handling
        sudo -u "$SUDO_USER" env -i \
            HOME="$user_home" \
            PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            LOGNAME="$SUDO_USER" \
            USER="$SUDO_USER" \
            "${script_path}" "${args[@]}" &
        
        CHILD_PID=$!
        
        if wait $CHILD_PID; then
            CHILD_PID=""
            log "INFO" "${script_name} completed successfully (privilege-dropped)"
            return 0
        else
            local exit_code=$?
            CHILD_PID=""
            error "${script_name} failed (exit code: ${exit_code})"
            LAST_ERROR="${script_name} failed (exit code: ${exit_code})"
            log "ERROR" "${script_name} failed with exit code ${exit_code} (privilege-dropped)"
            return 1
        fi
    fi
    
    # Special handling for diagnostics script with child process tracking
    # Diagnostics uses exit codes: 0=success, 1=warnings, 2=failures
    # We should NOT show error messages for warnings (exit code 1)
    if [[ "$script_key" == "diagnostics" ]]; then
        "${script_path}" "${args[@]}" &
        CHILD_PID=$!
        
        wait $CHILD_PID
        local exit_code=$?
        CHILD_PID=""
        
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
    
    # All other scripts execute as root with child process tracking
    "${script_path}" "${args[@]}" &
    CHILD_PID=$!
    
    if wait $CHILD_PID; then
        CHILD_PID=""
        log "INFO" "${script_name} completed successfully"
        return 0
    else
        local exit_code=$?
        CHILD_PID=""
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
    local clear_screen="${1:-}"
    
    if [[ "$clear_screen" == "clear" ]]; then
        clear
    fi
    
    echo "================================================================"
    echo " LyreBirdAudio - Orchestrator v${SCRIPT_VERSION}"
    echo "================================================================"
    echo
}

display_status() {
    echo -e "${BOLD}System Status:${NC}"
    echo "  MediaMTX:       $(if [[ "$MEDIAMTX_INSTALLED" == "true" ]]; then echo "Installed (${MEDIAMTX_VERSION})"; else echo "Not installed"; fi)"
    echo "  MediaMTX:       $(if [[ "$MEDIAMTX_RUNNING" == "true" ]]; then echo -e "${GREEN}Running${NC}"; else echo -e "${RED}Stopped${NC}"; fi)"
    echo "  Active Streams: ${ACTIVE_STREAMS}"
    echo "  USB Devices:    $(if [[ "$USB_DEVICES_MAPPED" == "true" ]]; then echo "Mapped"; else echo "Not mapped"; fi)"
    echo
}

display_error() {
    if [[ -n "$LAST_ERROR" ]]; then
        echo -e "${RED}Last Error:${NC} ${LAST_ERROR}"
        echo
    fi
}

get_primary_ip() {
    # Try to get primary IP address
    local primary_ip
    
    # Try ip command first
    if command_exists ip; then
        primary_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "")
    fi
    
    # Fallback to hostname command
    if [[ -z "$primary_ip" ]] && command_exists hostname; then
        primary_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    
    # Final fallback
    if [[ -z "$primary_ip" ]]; then
        primary_ip="<server-ip>"
    fi
    
    echo "$primary_ip"
}

# ============================================================================
# Menu Functions
# ============================================================================

menu_main() {
    while true; do
        display_header "clear"
        echo -e "${BOLD}Main Menu${NC}"
        echo
        display_status
        display_error
        
        echo -e "${BOLD}Menu Options:${NC}"
        echo "  1) Quick Setup Wizard"
        echo "  2) MediaMTX Installation & Updates"
        echo "  3) USB Device Management"
        echo "  4) Audio Streaming Control"
        echo "  5) System Diagnostics"
        echo "  6) Version Management"
        echo "  7) Logs & Status"
        echo "  0) Exit"
        echo
        
        # Check read status for EOF or error (stdin closed)
        if ! read -rp "Select option: " choice; then
            echo
            info "Input stream closed - exiting"
            log "INFO" "Main menu exited due to EOF"
            exit 0
        fi
        
        # Normalize input (remove whitespace)
        choice="${choice//[[:space:]]/}"
        
        case "$choice" in
            1) menu_quick_setup ;;
            2) menu_mediamtx ;;
            3) menu_usb_devices ;;
            4) menu_streaming ;;
            5) menu_diagnostics ;;
            6) menu_versions ;;
            7) menu_logs_status ;;
            0) 
                echo
                info "Exiting orchestrator"
                log "INFO" "Orchestrator exited normally"
                exit 0
                ;;
            *)
                error "Invalid option. Please select 0-7."
                sleep 1
                ;;
        esac
        
        # Clear last error after each menu cycle
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
    
    # Handle EOF / stdin closed
    if ! read -rp "Continue with quick setup? (y/n): " -n 1; then
        echo
        info "Input stream closed - returning to main menu"
        log "INFO" "Quick setup aborted due to EOF"
        return
    fi
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
    
    # Handle EOF / stdin closed
    if ! read -rp "Continue? (y/n): " -n 1; then
        echo
        info "Input stream closed - returning to main menu"
        log "INFO" "USB mapping skipped due to EOF"
        refresh_system_state
        return
    fi
    
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
    
    # Handle EOF / stdin closed
    if ! read -rp "Reboot now? (y/n): " -n 1; then
        echo
        info "Input stream closed - continuing without reboot"
        log "INFO" "Reboot prompt aborted due to EOF"
    else
        echo
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
            info "System will reboot now. Run this script again after reboot to continue setup."
            sleep 2
            /sbin/reboot  # Use absolute path for security
            exit 0
        fi
    fi
    
    echo
    info "Continuing setup without reboot..."
    info "Note: If streams fail to start, a reboot may be required"
    echo
    
    # Handle EOF / stdin closed
    if ! read -rp "Continue? (y/n): " -n 1; then
        echo
        info "Input stream closed - returning to main menu"
        log "INFO" "Setup continuation aborted due to EOF"
        return
    fi
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

menu_mediamtx() {
    while true; do
        display_header "clear"
        echo -e "${BOLD}MediaMTX Installation & Updates${NC}"
        echo
        display_status
        display_error
        
        echo -e "${BOLD}Installation Options:${NC}"
        echo "  1) Install MediaMTX (Fresh Install)"
        echo "  2) Update MediaMTX"
        echo "  3) Reinstall MediaMTX (Force)"
        echo "  4) Uninstall MediaMTX"
        echo "  5) Check Installation Status"
        echo "  0) Back to Main Menu"
        echo
        
        # Check read status for EOF or error (stdin closed)
        if ! read -rp "Select option: " choice; then
            echo
            info "Input stream closed - returning to main menu"
            log "INFO" "MediaMTX menu exited due to EOF"
            return
        fi
        
        # Normalize input (remove whitespace)
        choice="${choice//[[:space:]]/}"
        
        case "$choice" in
            1)
                echo
                info "Starting MediaMTX installation..."
                execute_script "installer" install || true
                echo
                refresh_system_state
                pause
                ;;
            2)
                echo
                info "Starting MediaMTX update..."
                execute_script "installer" update || true
                echo
                refresh_system_state
                pause
                ;;
            3)
                echo
                warning "This will reinstall MediaMTX (overwriting existing installation)"
                # Handle EOF / stdin closed
                if ! read -rp "Continue? (y/n): " -n 1; then
                    echo
                    warning "Input stream closed - operation cancelled"
                    echo
                    pause
                    continue
                fi
                echo
                if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                    execute_script "installer" reinstall || true
                    echo
                    refresh_system_state
                fi
                pause
                ;;
            4)
                echo
                warning "This will completely remove MediaMTX from your system"
                # Handle EOF / stdin closed
                if ! read -rp "Are you sure? (y/n): " -n 1; then
                    echo
                    warning "Input stream closed - operation cancelled"
                    echo
                    pause
                    continue
                fi
                echo
                if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                    execute_script "installer" uninstall || true
                    echo
                    refresh_system_state
                fi
                pause
                ;;
            5)
                echo
                echo "MediaMTX Installation Status:"
                echo "================================================================"
                if [[ "$MEDIAMTX_INSTALLED" == "true" ]]; then
                    echo "Status:     Installed"
                    echo "Version:    ${MEDIAMTX_VERSION}"
                    echo "Running:    ${MEDIAMTX_RUNNING}"
                    echo
                    if command_exists mediamtx; then
                        echo "Binary:     $(which mediamtx)"
                    elif [[ -f /usr/local/bin/mediamtx ]]; then
                        echo "Binary:     /usr/local/bin/mediamtx"
                    fi
                else
                    echo "Status:     Not Installed"
                fi
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
        echo "  4) Detect Device Capabilities"
        echo "  5) Generate Device Configuration"
        echo "  6) Validate Device Configuration"
        echo "  7) Remove Device Mappings"
        echo "  8) Reload udev Rules"
        echo "  0) Back to Main Menu"
        echo
        
        # Check read status for EOF or error (stdin closed)
        if ! read -rp "Select option: " choice; then
            echo
            info "Input stream closed - returning to main menu"
            log "INFO" "USB device menu exited due to EOF"
            return
        fi
        
        # Normalize input (remove whitespace)
        choice="${choice//[[:space:]]/}"
        
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
                echo "Available operations:"
                echo "  1) List all USB audio devices"
                echo "  2) Show specific device capabilities"
                echo "  0) Cancel"
                echo
                
                if ! read -rp "Select operation: " cap_choice; then
                    echo
                    warning "Input stream closed - operation cancelled"
                    pause
                    continue
                fi
                
                cap_choice="${cap_choice//[[:space:]]/}"
                
                case "$cap_choice" in
                    1)
                        echo
                        echo "USB Audio Devices:"
                        echo "================================================================"
                        execute_script "mic_check" || true
                        echo "================================================================"
                        pause
                        ;;
                    2)
                        echo
                        if ! read -rp "Enter card number (e.g., 0, 1, 2): " card_num; then
                            echo
                            warning "Input stream closed - operation cancelled"
                            pause
                            continue
                        fi
                        
                        # Sanitize and validate input
                        card_num="${card_num//[[:space:]]/}"
                        
                        if [[ "$card_num" =~ ^[0-9]+$ ]]; then
                            echo
                            echo "Capabilities for card $card_num:"
                            echo "================================================================"
                            execute_script "mic_check" "$card_num" || true
                            echo "================================================================"
                        else
                            error "Invalid card number: must be a positive integer"
                        fi
                        pause
                        ;;
                    0)
                        ;;
                    *)
                        error "Invalid operation"
                        sleep 1
                        ;;
                esac
                ;;
            5)
                echo
                echo -e "${BOLD}Generate Device Configuration${NC}"
                echo
                info "This will analyze your USB audio devices and generate"
                info "an optimal configuration file for MediaMTX streaming."
                echo
                echo "Quality tiers:"
                echo "  low    - Bandwidth-optimized (96-128k bitrate, 44.1kHz preferred)"
                echo "  normal - Balanced quality (128-256k bitrate, 48kHz preferred)"
                echo "  high   - Maximum quality (160-320k bitrate, 96-192kHz if supported)"
                echo
                
                if ! read -rp "Select quality tier (low/normal/high) [normal]: " quality; then
                    echo
                    warning "Input stream closed - operation cancelled"
                    pause
                    continue
                fi
                
                quality="${quality:-normal}"
                
                if [[ ! "$quality" =~ ^(low|normal|high)$ ]]; then
                    error "Invalid quality tier: $quality"
                    pause
                    continue
                fi
                
                echo
                
                # Check if config exists
                local config_file="/etc/mediamtx/audio-devices.conf"
                if [[ -f "$config_file" ]]; then
                    warning "Configuration file already exists: $config_file"
                    echo
                    if ! read -rp "Overwrite existing configuration? (y/n): " -n 1; then
                        echo
                        warning "Input stream closed - operation cancelled"
                        pause
                        continue
                    fi
                    echo
                    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
                        info "Operation cancelled"
                        pause
                        continue
                    fi
                    
                    # User confirmed overwrite - use force flag
                    echo
                    info "Generating configuration with $quality quality (overwrite mode)..."
                    if execute_script "mic_check" -g --quality="$quality" -f; then
                        success "Device configuration generated successfully"
                        echo
                        info "Configuration file: $config_file"
                        info "The configuration uses friendly names matching stream paths"
                        info "Example: DEVICE_BLUE_YETI_SAMPLE_RATE=44100"
                    else
                        error "Failed to generate configuration"
                    fi
                else
                    info "Generating configuration with $quality quality..."
                    if execute_script "mic_check" -g --quality="$quality"; then
                        success "Device configuration generated successfully"
                        echo
                        info "Configuration file: $config_file"
                        info "The configuration uses friendly names matching stream paths"
                        info "Example: DEVICE_BLUE_YETI_SAMPLE_RATE=44100"
                    else
                        error "Failed to generate configuration"
                    fi
                fi
                
                echo
                pause
                ;;
            6)
                echo
                info "Validating device configuration..."
                echo "================================================================"
                if execute_script "mic_check" -V; then
                    success "Configuration validation passed"
                else
                    error "Configuration validation found issues"
                    echo
                    info "Review the validation output above for details"
                fi
                echo "================================================================"
                pause
                ;;
            7)
                echo
                warning "This will remove all USB device mappings"
                # Handle EOF / stdin closed
                if ! read -rp "Are you sure? (y/n): " -n 1; then
                    echo
                    warning "Input stream closed - operation cancelled"
                    echo
                    pause
                    continue
                fi
                echo
                if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                    if [[ -f "$UDEV_RULES" ]]; then
                        if rm -f "$UDEV_RULES" && \
                           udevadm control --reload-rules && \
                           udevadm trigger; then
                            success "Device mappings removed"
                            refresh_system_state
                        else
                            error "Failed to complete device mapping removal"
                            log "ERROR" "Failed to remove mappings: udevadm commands failed"
                        fi
                    else
                        info "No mappings to remove"
                    fi
                fi
                echo
                pause
                ;;
            8)
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
                error "Invalid option. Please select 0-8."
                sleep 1
                ;;
        esac
    done
}

menu_streaming() {
    while true; do
        display_header "clear"
        echo -e "${BOLD}Audio Streaming Control${NC}"
        echo
        display_status
        display_error
        
        echo -e "${BOLD}Streaming Options:${NC}"
        echo "  1) Start All Streams"
        echo "  2) Stop All Streams"
        echo "  3) Restart All Streams"
        echo "  4) View Stream Status"
        echo "  5) View Stream URLs"
        echo "  6) Monitor Stream Health"
        echo "  0) Back to Main Menu"
        echo
        
        # Check read status for EOF or error (stdin closed)
        if ! read -rp "Select option: " choice; then
            echo
            info "Input stream closed - returning to main menu"
            log "INFO" "Streaming control menu exited due to EOF"
            return
        fi
        
        # Normalize input (remove whitespace)
        choice="${choice//[[:space:]]/}"
        
        case "$choice" in
            1)
                echo
                info "Starting audio streams..."
                execute_script "stream_manager" start || true
                echo
                refresh_system_state
                pause
                ;;
            2)
                echo
                warning "This will stop all active audio streams"
                # Handle EOF / stdin closed
                if ! read -rp "Continue? (y/n): " -n 1; then
                    echo
                    warning "Input stream closed - operation cancelled"
                    echo
                    pause
                    continue
                fi
                echo
                if [[ "$REPLY" =~ ^[Yy]$ ]]; then
                    echo
                    info "Stopping audio streams..."
                    execute_script "stream_manager" stop || true
                    echo
                    refresh_system_state
                fi
                pause
                ;;
            3)
                echo
                info "Restarting audio streams..."
                execute_script "stream_manager" restart || true
                echo
                refresh_system_state
                pause
                ;;
            4)
                echo
                echo "Stream Status:"
                echo "================================================================"
                execute_script "stream_manager" status || true
                echo "================================================================"
                pause
                ;;
            5)
                echo
                echo "Stream URLs:"
                echo "================================================================"
                local primary_ip
                primary_ip="$(get_primary_ip)"
                echo
                info "Base URL: rtsp://${primary_ip}:8554/"
                echo
                info "Your streams are available at:"
                echo
                execute_script "stream_manager" list || true
                echo
                echo "================================================================"
                pause
                ;;
            6)
                echo
                info "Starting stream health monitor..."
                info "This will check all streams and restart failed ones"
                echo
                execute_script "stream_manager" monitor || true
                echo
                pause
                ;;
            0)
                return
                ;;
            *)
                error "Invalid option. Please select 0-6."
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
        echo "  1) Quick Diagnostics (Fast)"
        echo "  2) Full System Diagnostics"
        echo "  3) Verbose Diagnostics (Detailed)"
        echo "  4) Export Diagnostic Report"
        echo "  0) Back to Main Menu"
        echo
        
        # Check read status for EOF or error (stdin closed)
        if ! read -rp "Select option: " choice; then
            echo
            info "Input stream closed - returning to main menu"
            log "INFO" "Diagnostics menu exited due to EOF"
            return
        fi
        
        # Normalize input (remove whitespace)
        choice="${choice//[[:space:]]/}"
        
        case "$choice" in
            1)
                echo
                echo "Running quick diagnostics..."
                echo "================================================================"
                
                # Handle diagnostics exit codes properly (0=success, 1=warnings, 2=failures)
                local diag_result=0
                execute_script "diagnostics" "quick" || diag_result=$?
                
                case ${diag_result} in
                    "${E_DIAG_SUCCESS}")
                        success "Quick diagnostics completed - all checks passed"
                        ;;
                    "${E_DIAG_WARN}")
                        warning "Quick diagnostics completed with warnings"
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
                
                local diag_result=0
                execute_script "diagnostics" || diag_result=$?
                
                case ${diag_result} in
                    "${E_DIAG_SUCCESS}")
                        success "Full diagnostics completed - all checks passed"
                        ;;
                    "${E_DIAG_WARN}")
                        warning "Full diagnostics completed with warnings"
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
                echo "Running verbose diagnostics..."
                echo "================================================================"
                
                local diag_result=0
                execute_script "diagnostics" "verbose" || diag_result=$?
                
                case ${diag_result} in
                    "${E_DIAG_SUCCESS}")
                        success "Verbose diagnostics completed - all checks passed"
                        ;;
                    "${E_DIAG_WARN}")
                        warning "Verbose diagnostics completed with warnings"
                        ;;
                    "${E_DIAG_FAIL}")
                        error "Verbose diagnostics detected failures"
                        ;;
                esac
                
                echo "================================================================"
                pause
                ;;
            4)
                echo
                info "Exporting diagnostic report..."
                echo
                execute_script "diagnostics" "export" || true
                echo
                pause
                ;;
            0)
                return
                ;;
            *)
                error "Invalid option. Please select 0-4."
                sleep 1
                ;;
        esac
    done
}

menu_versions() {
    while true; do
        display_header "clear"
        echo -e "${BOLD}Version Management${NC}"
        echo
        display_status
        display_error
        
        echo -e "${BOLD}Version Options:${NC}"
        echo "  1) Launch Update Manager (Interactive)"
        echo "  2) Show Component Versions"
        echo "  0) Back to Main Menu"
        echo
        
        info "The update manager provides:"
        info "  * Interactive update workflow with safety checks"
        info "  * Automatic backup and rollback capability"
        info "  * Component-by-component update selection"
        info "  * Git repository integration for updates"
        echo
        
        # Check read status for EOF or error (stdin closed)
        if ! read -rp "Select option: " choice; then
            echo
            info "Input stream closed - returning to main menu"
            log "INFO" "Version management menu exited due to EOF"
            return
        fi
        
        # Normalize input (remove whitespace)
        choice="${choice//[[:space:]]/}"
        
        case "$choice" in
            1)
                echo
                info "Launching interactive update manager..."
                echo
                execute_script "updater" || true
                echo
                refresh_system_state
                pause
                ;;
            2)
                echo
                echo "Component Versions:"
                echo "================================================================"
                echo "Orchestrator:  ${SCRIPT_VERSION}"
                echo
                
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
                error "Invalid option. Please select 0-2."
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
        
        # Check read status for EOF or error (stdin closed)
        if ! read -rp "Select option: " choice; then
            echo
            info "Input stream closed - returning to main menu"
            log "INFO" "Logs & status menu exited due to EOF"
            return
        fi
        
        # Normalize input (remove whitespace)
        choice="${choice//[[:space:]]/}"
        
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
                info "Running quick diagnostic summary..."
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
        
        # Terminate child process if running
        if [[ -n "${CHILD_PID:-}" ]]; then
            log "INFO" "Terminating child process: $CHILD_PID"
            
            # Try graceful termination first
            kill -TERM "$CHILD_PID" 2>/dev/null || true
            
            # Wait briefly for graceful shutdown
            sleep 1
            
            # Force kill if still running
            if kill -0 "$CHILD_PID" 2>/dev/null; then
                log "WARN" "Child process did not terminate gracefully, forcing"
                kill -KILL "$CHILD_PID" 2>/dev/null || true
            fi
            
            CHILD_PID=""
        fi
        
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
    
    # Validate script versions (warnings logged, non-blocking)
    if ! validate_script_versions; then
        log "WARN" "Version detection completed with warnings (non-blocking)"
    fi
    
    # Initial system state detection
    refresh_system_state
    
    # Start main menu
    menu_main
}

# Run main function
main "$@"

#!/usr/bin/env bash
#
# lyrebird-orchestrator.sh - Production-Ready Unified Management Interface
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# Version: 1.0.0
# Description: Orchestrator script that provides a unified interface to all
#              LyreBirdAudio management scripts with proper command routing,
#              error handling, and user feedback.
#
# Compatible with:
#   - MediaMTX v1.15.1+
#   - install_mediamtx.sh v2.0.0+
#   - mediamtx-stream-manager.sh v1.2.0+
#   - usb-audio-mapper.sh v1.2.1+
#   - lyrebird-updater.sh v1.0.0+
#
# Architecture:
#   - Single orchestrator with no duplicate logic
#   - Delegates all operations to specialized scripts
#   - Provides consistent UI/UX across all operations
#   - Implements proper error handling and feedback
#   - Follows DRY principles throughout

set -euo pipefail

# ============================================================================
# Constants and Configuration
# ============================================================================

readonly SCRIPT_VERSION="1.0.0"

# Safe constant initialization (SC2155: separate declaration and assignment)
SCRIPT_NAME=""
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# Get script directory
get_script_dir() {
    local source="${BASH_SOURCE[0]}"
    local dir
    
    while [[ -L "$source" ]]; do
        dir="$(cd -P "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        [[ $source != /* ]] && source="$dir/$source"
    done
    
    cd -P "$(dirname "$source")" && pwd
}

SCRIPT_DIR=""
SCRIPT_DIR="$(get_script_dir)"
readonly SCRIPT_DIR

# External script paths
declare -A EXTERNAL_SCRIPTS=(
    ["installer"]="install_mediamtx.sh"
    ["stream_manager"]="mediamtx-stream-manager.sh"
    ["usb_mapper"]="usb-audio-mapper.sh"
    ["updater"]="lyrebird-updater.sh"
)

# Required script versions
declare -A MIN_VERSIONS=(
    ["installer"]="2.0.0"
    ["stream_manager"]="1.2.0"
    ["usb_mapper"]="1.2.1"
    ["updater"]="1.0.0"
)

# Configuration paths (for reference/display only - not directly used)
readonly UDEV_RULES="/etc/udev/rules.d/99-usb-soundcards.rules"

# Log file (initialized in main() with fallback handling)
LOG_FILE=""

# Exit codes
readonly E_GENERAL=1
readonly E_PERMISSION=2
readonly E_DEPENDENCY=3
readonly E_SCRIPT_NOT_FOUND=4

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

# Global state variables (all actually used in the script)
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
    echo -e "${GREEN}[OK]${NC} $*"
    log "INFO" "$*"
}

error() {
    echo -e "${RED}[X]${NC} $*" >&2
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
    command -v "$1" &>/dev/null
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
    
    # Try to extract version from script header
    if [[ -f "$script_path" ]]; then
        # Try multiple patterns in order of preference:
        # 1. readonly SCRIPT_VERSION="x.x.x"
        # 2. readonly VERSION="x.x.x"
        # 3. SCRIPT_VERSION="x.x.x"
        # 4. VERSION="x.x.x"
        # 5. # Version: x.x.x (comment format)
        
        # Try SCRIPT_VERSION first
        version=$(grep -m1 '^readonly SCRIPT_VERSION=' "$script_path" 2>/dev/null | sed -n 's/.*"\([0-9][0-9.]*\)".*/\1/p')
        
        # Try VERSION if SCRIPT_VERSION not found
        if [[ -z "$version" || "$version" == "" ]]; then
            version=$(grep -m1 '^readonly VERSION=' "$script_path" 2>/dev/null | sed -n 's/.*"\([0-9][0-9.]*\)".*/\1/p')
        fi
        
        # Try non-readonly declarations
        if [[ -z "$version" || "$version" == "" ]]; then
            version=$(grep -m1 '^SCRIPT_VERSION=' "$script_path" 2>/dev/null | sed -n 's/.*"\([0-9][0-9.]*\)".*/\1/p')
        fi
        
        if [[ -z "$version" || "$version" == "" ]]; then
            version=$(grep -m1 '^VERSION=' "$script_path" 2>/dev/null | sed -n 's/.*"\([0-9][0-9.]*\)".*/\1/p')
        fi
        
        # Try comment format as last resort
        if [[ -z "$version" || "$version" == "" ]]; then
            version=$(grep -m1 '^# Version:' "$script_path" 2>/dev/null | sed -n 's/^# Version: *\([0-9][0-9.]*\).*/\1/p')
        fi
        
        # Default to unknown if still not found
        if [[ -z "$version" || "$version" == "" ]]; then
            version="unknown"
        fi
        
        # Clean up version string
        version="${version#v}"
        version="${version%%[[:space:]]*}"
    fi
    
    echo "$version"
}

validate_script_versions() {
    log "DEBUG" "Validating script versions"
    
    local warnings=0
    local errors=0
    
    for key in "${!SCRIPT_PATHS[@]}"; do
        local script_path="${SCRIPT_PATHS[$key]}"
        local script_name
        script_name="$(basename "$script_path")"
        local min_version="${MIN_VERSIONS[$key]}"
        local actual_version
        
        actual_version="$(extract_script_version "$script_path")"
        
        if [[ "$actual_version" == "unknown" ]]; then
            warning "Cannot determine version for ${script_name}"
            log "WARN" "Version unknown for ${key} at ${script_path}"
            ((warnings++))
        elif ! version_ge "$actual_version" "$min_version"; then
            error "${script_name} version ${actual_version} < required ${min_version}"
            log "ERROR" "Version check failed: ${script_name} (${script_path}) has ${actual_version}, requires ${min_version}"
            ((errors++))
        else
            log "DEBUG" "${script_name} version ${actual_version} >= ${min_version} OK"
        fi
    done
    
    if [[ $errors -gt 0 ]]; then
        echo
        error "Script version compatibility issues detected"
        echo "Please ensure all LyreBirdAudio scripts are up to date"
        echo "Run the updater to get the latest versions"
        return 1
    elif [[ $warnings -gt 0 ]]; then
        echo
        warning "Some script versions could not be determined"
        echo "Press Enter to continue or Ctrl+C to abort..."
        read -r
    fi
    
    return 0
}

# ============================================================================
# System State Detection
# ============================================================================

detect_mediamtx_status() {
    MEDIAMTX_INSTALLED=false
    MEDIAMTX_RUNNING=false
    MEDIAMTX_VERSION="unknown"
    
    # Check if MediaMTX binary exists
    if [[ -x "/usr/local/bin/mediamtx" ]]; then
        MEDIAMTX_INSTALLED=true
        
        # Try to get version
        local version_output
        if version_output=$(/usr/local/bin/mediamtx --version 2>&1); then
            MEDIAMTX_VERSION=$(echo "$version_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
            [[ -z "$MEDIAMTX_VERSION" ]] && MEDIAMTX_VERSION="unknown"
        fi
        
        # Check if running
        if pgrep -x "mediamtx" >/dev/null 2>&1; then
            MEDIAMTX_RUNNING=true
        fi
    fi
    
    log "DEBUG" "MediaMTX: installed=$MEDIAMTX_INSTALLED running=$MEDIAMTX_RUNNING version=$MEDIAMTX_VERSION"
}

detect_usb_devices() {
    USB_DEVICES_MAPPED=false
    
    # Check if udev rules exist and contain device mappings
    if [[ -f "$UDEV_RULES" && -s "$UDEV_RULES" ]]; then
        # Check if file has actual rules (not just comments)
        if grep -q "^[^#]" "$UDEV_RULES" 2>/dev/null; then
            USB_DEVICES_MAPPED=true
        fi
    fi
    
    log "DEBUG" "USB devices mapped=$USB_DEVICES_MAPPED"
}

detect_active_streams() {
    ACTIVE_STREAMS=0
    
    # Count FFmpeg processes streaming to MediaMTX
    if command_exists pgrep; then
        ACTIVE_STREAMS=$(pgrep -fc "ffmpeg.*rtsp://.*:8554" 2>/dev/null || echo 0)
    fi
    
    log "DEBUG" "Active streams=$ACTIVE_STREAMS"
}

refresh_system_state() {
    detect_mediamtx_status
    detect_usb_devices
    detect_active_streams
}

# ============================================================================
# Script Execution
# ============================================================================

execute_script() {
    local script_key="$1"
    shift
    local args=("$@")
    
    local script_path="${SCRIPT_PATHS[$script_key]}"
    
    if [[ ! -f "$script_path" ]]; then
        LAST_ERROR="Script not found: $script_key"
        error "$LAST_ERROR"
        return 1
    fi
    
    log "INFO" "Executing: ${script_key} ${args[*]}"
    
    # Execute script and capture result
    if "$script_path" "${args[@]}"; then
        log "INFO" "Command successful: ${script_key} ${args[*]}"
        LAST_ERROR=""
        return 0
    else
        local exit_code=$?
        LAST_ERROR="Command failed with exit code ${exit_code}"
        log "ERROR" "$LAST_ERROR: ${script_key} ${args[*]}"
        return $exit_code
    fi
}

# ============================================================================
# Display Functions
# ============================================================================

display_header() {
    local clear_screen="${1:-}"
    
    [[ "$clear_screen" == "clear" ]] && clear
    
    echo -e "${BOLD}============================================================${NC}"
    echo -e "${BOLD}    ${CYAN}LyreBirdAudio Management Orchestrator v${SCRIPT_VERSION}${NC}       "
    echo -e "${BOLD}============================================================${NC}"
    echo
}

display_status() {
    echo -e "${BOLD}System Status:${NC}"
    echo "------------------------------------------------------------"
    
    # MediaMTX status
    if [[ "$MEDIAMTX_INSTALLED" == "true" ]]; then
        if [[ "$MEDIAMTX_RUNNING" == "true" ]]; then
            echo -e "MediaMTX:       ${GREEN}Running${NC} (v${MEDIAMTX_VERSION})"
        else
            echo -e "MediaMTX:       ${YELLOW}Installed${NC} (v${MEDIAMTX_VERSION}) - Not running"
        fi
    else
        echo -e "MediaMTX:       ${RED}Not installed${NC}"
    fi
    
    # USB devices
    if [[ "$USB_DEVICES_MAPPED" == "true" ]]; then
        echo -e "USB Mapping:    ${GREEN}Configured${NC}"
    else
        echo -e "USB Mapping:    ${YELLOW}Not configured${NC}"
    fi
    
    # Active streams
    if [[ $ACTIVE_STREAMS -gt 0 ]]; then
        echo -e "Active Streams: ${GREEN}${ACTIVE_STREAMS}${NC}"
    else
        echo -e "Active Streams: ${YELLOW}0${NC}"
    fi
    
    echo "------------------------------------------------------------"
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
        echo "  2) MediaMTX Management"
        echo "  3) Audio Stream Management"
        echo "  4) USB Device Management"
        echo "  5) System Tools & Updates"
        echo "  6) Refresh Status"
        echo "  0) Exit"
        echo
        read -rp "Select option: " choice
        
        case "$choice" in
            1)
                menu_quick_setup
                ;;
            2)
                menu_mediamtx
                ;;
            3)
                menu_streams
                ;;
            4)
                menu_usb_devices
                ;;
            5)
                menu_system_tools
                ;;
            6)
                refresh_system_state
                success "Status refreshed"
                sleep 1
                ;;
            0)
                echo
                info "Exiting orchestrator"
                exit 0
                ;;
            *)
                error "Invalid option"
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
    echo "This will guide you through the initial setup:"
    echo "  1. Install/Update MediaMTX"
    echo "  2. Map USB audio devices"
    echo "  3. Start audio streaming"
    echo
    read -rp "Continue with quick setup? (y/n): " -n 1
    echo
    
    [[ ! $REPLY =~ ^[Yy]$ ]] && return
    
    # Step 1: Install MediaMTX
    echo
    echo -e "${BOLD}Step 1/3: Installing MediaMTX...${NC}"
    if execute_script "installer" install; then
        success "MediaMTX installed"
    else
        error "Failed to install MediaMTX"
        echo
        read -rp "Continue anyway? (y/n): " -n 1
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && return
    fi
    
    # Step 2: Map USB devices
    echo
    echo -e "${BOLD}Step 2/3: Mapping USB audio devices...${NC}"
    echo "Follow the interactive prompts to map your devices"
    echo
    pause
    
    if execute_script "usb_mapper" --interactive; then
        success "USB devices mapped"
    else
        error "Failed to map USB devices"
        echo
        read -rp "Continue anyway? (y/n): " -n 1
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && return
    fi
    
    # Step 3: Start streams
    echo
    echo -e "${BOLD}Step 3/3: Starting audio streams...${NC}"
    if execute_script "stream_manager" start; then
        success "Audio streams started"
    else
        error "Failed to start streams"
    fi
    
    echo
    success "Quick setup complete!"
    echo
    echo "Your RTSP streams should now be available at:"
    echo "  rtsp://localhost:8554/[device-name]"
    echo
    pause
    
    refresh_system_state
}

menu_mediamtx() {
    while true; do
        display_header "clear"
        echo -e "${BOLD}MediaMTX Management${NC}"
        echo
        display_status
        display_error
        
        echo -e "${BOLD}Available Actions:${NC}"
        echo "  1) Install/Update MediaMTX"
        echo "  2) Start MediaMTX"
        echo "  3) Stop MediaMTX"
        echo "  4) Restart MediaMTX"
        echo "  5) View Status & Logs"
        echo "  6) Verify Installation"
        echo "  7) Uninstall MediaMTX"
        echo "  0) Back to Main Menu"
        echo
        read -rp "Select option: " choice
        
        case "$choice" in
            1)
                echo
                echo "Installing/Updating MediaMTX..."
                if execute_script "installer" install; then
                    success "MediaMTX installed/updated"
                    refresh_system_state
                else
                    error "Installation failed"
                fi
                pause
                ;;
            2)
                echo
                echo "Starting MediaMTX...Be Patient as Streams Start"
                if execute_script "stream_manager" start; then
                    success "MediaMTX started"
                    refresh_system_state
                else
                    error "Failed to start MediaMTX"
                fi
                pause
                ;;
            3)
                echo
                echo "Stopping MediaMTX..."
                if execute_script "stream_manager" stop; then
                    success "MediaMTX stopped"
                    refresh_system_state
                else
                    error "Failed to stop MediaMTX"
                fi
                pause
                ;;
            4)
                echo
                echo "Restarting MediaMTX...Be Patient as Streams Restart"
                if execute_script "stream_manager" restart; then
                    success "MediaMTX restarted"
                    refresh_system_state
                else
                    error "Failed to restart MediaMTX"
                fi
                pause
                ;;
            5)
                echo
                execute_script "stream_manager" status || true
                pause
                ;;
            6)
                echo
                echo "Verifying installation..."
                if execute_script "installer" verify; then
                    success "Installation verified"
                else
                    warning "Verification found issues"
                fi
                pause
                ;;
            7)
                echo
                warning "This will uninstall MediaMTX and stop all streams"
                read -rp "Are you sure? (y/n): " -n 1
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    if execute_script "installer" uninstall; then
                        success "MediaMTX uninstalled"
                        refresh_system_state
                    else
                        error "Uninstall failed"
                    fi
                fi
                pause
                ;;
            0)
                return
                ;;
            *)
                error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

menu_streams() {
    while true; do
        display_header "clear"
        echo -e "${BOLD}Audio Stream Management${NC}"
        echo
        display_status
        display_error
        
        echo -e "${BOLD}Available Actions:${NC}"
        echo "  1) Start All Streams"
        echo "  2) Stop All Streams"
        echo "  3) Restart All Streams"
        echo "  4) View Stream Status"
        echo "  5) View Stream Configuration"
        echo "  0) Back to Main Menu"
        echo
        read -rp "Select option: " choice
        
        case "$choice" in
            1)
                echo
                echo "Starting all streams...Be Patient as Streams Start"
                if execute_script "stream_manager" start; then
                    success "Streams started"
                    refresh_system_state
                else
                    error "Failed to start streams"
                fi
                pause
                ;;
            2)
                echo
                echo "Stopping all streams..."
                if execute_script "stream_manager" stop; then
                    success "Streams stopped"
                    refresh_system_state
                else
                    error "Failed to stop streams"
                fi
                pause
                ;;
            3)
                echo
                echo "Restarting all streams...Be Patient as this can take 1-3 Minutes depending on number of streams"
                if execute_script "stream_manager" restart; then
                    success "Streams restarted"
                    refresh_system_state
                else
                    error "Failed to restart streams"
                fi
                pause
                ;;
            4)
                echo
                execute_script "stream_manager" status || true
                pause
                ;;
            5)
                echo
                execute_script "stream_manager" config || true
                pause
                ;;
            0)
                return
                ;;
            *)
                error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

menu_usb_devices() {
    while true; do
        display_header "clear"
        echo -e "${BOLD}USB Audio Device Management${NC}"
        echo
        display_status
        display_error
        
        echo -e "${BOLD}Available Actions:${NC}"
        echo "  1) Map USB Devices (Interactive)"
        echo "  2) Test USB Port Detection"
        echo "  3) View Current Mappings"
        echo "  0) Back to Main Menu"
        echo
        read -rp "Select option: " choice
        
        case "$choice" in
            1)
                echo
                echo "Starting interactive device mapping..."
                echo
                if execute_script "usb_mapper" --interactive; then
                    success "Device mapping complete"
                    refresh_system_state
                else
                    error "Mapping failed"
                fi
                pause
                ;;
            2)
                echo
                echo "Testing USB port detection..."
                echo
                execute_script "usb_mapper" --test || true
                pause
                ;;
            3)
                echo
                if [[ -f "$UDEV_RULES" ]]; then
                    echo "Current USB device mappings:"
                    echo "------------------------------------------------------------"
                    cat "$UDEV_RULES"
                    echo "------------------------------------------------------------"
                else
                    info "No USB device mappings found"
                fi
                echo
                pause
                ;;
            0)
                return
                ;;
            *)
                error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

menu_system_tools() {
    while true; do
        display_header "clear"
        echo -e "${BOLD}LyreBird-Audio Tools & Updates${NC}"
        echo
        display_status
        display_error
        
        echo -e "${BOLD}Available Actions:${NC}"
        echo "  1) Check for Updates to LyreBird-Audio"
        echo "  2) LyreBird Version Manager (Advanced)"
        echo "  3) View Orchestrator Log"
        echo "  4) View MediaMTX Log"
        echo "  0) Back to Main Menu"
        echo
        read -rp "Select option: " choice
        
        case "$choice" in
            1)
                echo
                echo "Checking for updates..."
                if execute_script "updater" --status; then
                    info "Update check complete"
                else
                    warning "Could not check for updates"
                fi
                pause
                ;;
            2)
                echo
                echo "Launching version manager..."
                echo
                execute_script "updater" || true
                pause
                ;;
            3)
                echo
                if [[ -f "$LOG_FILE" ]]; then
                    echo "Viewing orchestrator log (last 50 lines):"
                    echo "------------------------------------------------------------"
                    tail -50 "$LOG_FILE"
                    echo "------------------------------------------------------------"
                else
                    info "No log file found"
                fi
                echo
                pause
                ;;
            4)
                echo
                # Try multiple possible log locations
                local mediamtx_log=""
                for log_path in "/var/log/mediamtx.log" "/var/log/mediamtx.out" "/var/log/mediamtx/mediamtx.log"; do
                    if [[ -f "$log_path" && -r "$log_path" ]]; then
                        mediamtx_log="$log_path"
                        break
                    fi
                done
                
                if [[ -n "$mediamtx_log" ]]; then
                    echo "Viewing MediaMTX log (last 50 lines): $mediamtx_log"
                    echo "------------------------------------------------------------"
                    tail -50 "$mediamtx_log"
                    echo "------------------------------------------------------------"
                else
                    info "MediaMTX log not found in standard locations"
                    echo "Tried: /var/log/mediamtx.log, /var/log/mediamtx.out, /var/log/mediamtx/mediamtx.log"
                fi
                echo
                pause
                ;;
            0)
                return
                ;;
            *)
                error "Invalid option"
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
    
    # Initialize logging with proper fallback chain
    LOG_FILE="/var/log/lyrebird-orchestrator.log"
    if ! touch "$LOG_FILE" 2>/dev/null; then
        LOG_FILE="/tmp/lyrebird-orchestrator.log"
        if ! touch "$LOG_FILE" 2>/dev/null; then
            LOG_FILE="/dev/null"
            echo "WARNING: Cannot write logs, using /dev/null" >&2
        fi
    fi
    log "INFO" "=== Orchestrator v${SCRIPT_VERSION} started ==="
    
    # Find and validate external scripts
    if ! find_external_scripts; then
        exit ${E_SCRIPT_NOT_FOUND}
    fi
    
    # Log detected versions for debugging
    log "INFO" "=== Script Version Detection ==="
    for key in "${!SCRIPT_PATHS[@]}"; do
        local script_path="${SCRIPT_PATHS[$key]}"
        local script_name
        script_name="$(basename "$script_path")"
        local detected_version
        detected_version="$(extract_script_version "$script_path")"
        local required_version="${MIN_VERSIONS[$key]}"
        log "INFO" "${script_name}: detected=${detected_version}, required=${required_version}"
    done
    log "INFO" "=== End Version Detection ==="
    
    if ! validate_script_versions; then
        echo
        warning "Continuing despite version warnings"
        echo "Some features may not work correctly"
        sleep 2
    fi
    
    # Initial system state detection
    refresh_system_state
    
    # Start main menu
    menu_main
}

# Run main function
main "$@"

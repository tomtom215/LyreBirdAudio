#!/bin/bash
# usb-soundcard-mapper.sh - Automatically map USB sound cards to persistent names
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# This script creates udev rules for USB sound cards to ensure they maintain 
# consistent names across reboots, with symlinks for easy access.
#
# Version: 1.2.1
# Changes: Fixed v1.0.0 backwards compatibility
#          - Removed serial number suffixes from port paths for udev rules
#          - Maintained all production-ready improvements
#          - Enhanced error handling and validation
#          - Added comprehensive exception handling

# Set bash pipefail for better error handling
set -o pipefail

# Constants
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly RULES_FILE="/etc/udev/rules.d/99-usb-soundcards.rules"
readonly PROC_ASOUND_CARDS="/proc/asound/cards"
readonly DEFAULT_DEBUG="false"
readonly MAX_CARD_NUMBER=99
readonly MAX_NAME_LENGTH=32
readonly TEMP_DIR="${TMPDIR:-/tmp}"

# Global variables
DEBUG="${DEBUG:-$DEFAULT_DEBUG}"
CLEANUP_FILES=()
USE_COLOR=false

# Check if output is to a terminal for color support
if [ -t 1 ] && [ -t 2 ]; then
    if command -v tput >/dev/null 2>&1; then
        if [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
            USE_COLOR=true
        fi
    fi
fi

# Signal handler for cleanup
cleanup() {
    local exit_code=$?
    local file
    # Remove any temporary files
    for file in "${CLEANUP_FILES[@]}"; do
        if [ -f "$file" ]; then
            rm -f "$file" 2>/dev/null || true
        fi
    done
    exit $exit_code
}

# Set up signal handlers
trap cleanup EXIT INT TERM HUP QUIT

# Function to print error messages and exit
error_exit() {
    local message="${1:-Unknown error occurred}"
    local exit_code="${2:-1}"
    
    if [ "$USE_COLOR" = "true" ]; then
        printf '\033[31mERROR: %s\033[0m\n' "$message" >&2
    else
        printf 'ERROR: %s\n' "$message" >&2
    fi
    exit "$exit_code"
}

# Function to print information messages
info() {
    local message="${1:-}"
    if [ "$USE_COLOR" = "true" ]; then
        printf '\033[34mINFO: %s\033[0m\n' "$message"
    else
        printf 'INFO: %s\n' "$message"
    fi
}

# Function to print success messages
success() {
    local message="${1:-}"
    if [ "$USE_COLOR" = "true" ]; then
        printf '\033[32mSUCCESS: %s\033[0m\n' "$message"
    else
        printf 'SUCCESS: %s\n' "$message"
    fi
}

# Function to print warning messages
warning() {
    local message="${1:-}"
    if [ "$USE_COLOR" = "true" ]; then
        printf '\033[33mWARNING: %s\033[0m\n' "$message" >&2
    else
        printf 'WARNING: %s\n' "$message" >&2
    fi
}

# Function to print debug messages if debug mode is enabled
debug() {
    local message="${1:-}"
    if [ "$DEBUG" = "true" ]; then
        if [ "$USE_COLOR" = "true" ]; then
            printf '\033[35mDEBUG: %s\033[0m\n' "$message" >&2
        else
            printf 'DEBUG: %s\n' "$message" >&2
        fi
    fi
}

# Helper function for safe base-10 conversion (prevents octal interpretation)
safe_base10() {
    local val="${1:-}"
    
    # Check if empty
    if [ -z "$val" ]; then
        return 1
    fi
    
    # Check if valid number
    if ! [[ "$val" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    # Remove leading zeros and convert
    val="${val#"${val%%[!0]*}"}"
    [ -z "$val" ] && val="0"
    
    printf "%d" "$val"
    return 0
}

# Portable hash function for systems without md5sum
get_portable_hash() {
    local input="${1:-}"
    local length="${2:-8}"
    
    if [ -z "$input" ]; then
        printf "00000000"
        return 0
    fi
    
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$input" | sha256sum | head -c "$length"
    elif command -v sha1sum >/dev/null 2>&1; then
        printf '%s' "$input" | sha1sum | head -c "$length"
    elif command -v cksum >/dev/null 2>&1; then
        printf "%0${length}x" "$(printf '%s' "$input" | cksum | cut -d' ' -f1)"
    else
        # Fallback: simple string manipulation hash
        local hash=0
        local i
        for (( i=0; i<${#input}; i++ )); do
            hash=$(( (hash * 31 + $(printf "%d" "'${input:$i:1}")) % 16777216 ))
        done
        printf "%0${length}x" "$hash"
    fi
}

# Check for required dependencies
check_dependencies() {
    local required_deps=("lsusb" "udevadm" "grep" "sed" "cat")
    local optional_deps=("aplay")
    local missing_deps=()
    local cmd
    
    for cmd in "${required_deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        error_exit "Required commands not found: ${missing_deps[*]}. Please install them."
    fi
    
    for cmd in "${optional_deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            warning "Optional command '$cmd' not found. Some features may be limited."
        fi
    done
}

# Check if script is run as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root. Please use sudo."
    fi
}

# Function to check if a string is valid USB path
is_valid_usb_path() {
    local path="${1:-}"
    
    if [ -z "$path" ]; then
        return 1
    fi
    
    # Check if path contains expected USB path components
    if [[ "$path" == *"usb"* ]] && [[ "$path" == *":"* ]]; then
        return 0
    elif [[ "$path" =~ ^(usb-)?[0-9]+-[0-9]+(\.[0-9]+)*$ ]]; then
        return 0
    elif [[ "$path" == *"-"* ]]; then
        # More permissive for compatibility
        return 0
    else
        return 1
    fi
}

# Function to get USB physical port path for a device (v1.0.0 logic - FIXED)
# Returns clean port path for v1.0.0 compatibility (no serial suffix)
get_usb_physical_port() {
    local bus_num="${1:-}"
    local dev_num="${2:-}"
    
    # Validate inputs
    if [ -z "$bus_num" ] || [ -z "$dev_num" ]; then
        debug "Missing bus or device number for port detection"
        return 1
    fi
    
    bus_num=$(safe_base10 "$bus_num") || return 1
    dev_num=$(safe_base10 "$dev_num") || return 1
    
    local base_port_path=""
    local serial=""
    local product_name=""
    
    debug "Looking for device with bus=$bus_num dev=$dev_num"
    
    # Method 1: Search through ALL USB devices in sysfs to find the correct one
    # This avoids the incorrect path guessing that causes Device 5 to match the hub
    local devices_dir="/sys/bus/usb/devices"
    local found_device=""
    
    for device in "$devices_dir"/*; do
        [ ! -d "$device" ] && continue
        
        # Only check directories with USB port naming pattern
        local basename
        basename=$(basename "$device")
        [[ "$basename" =~ ^[0-9]+-[0-9]+(\.[0-9]+)*$ ]] || continue
        
        # Check if this device has the bus/dev numbers we're looking for
        if [ -f "$device/busnum" ] && [ -f "$device/devnum" ]; then
            local check_bus
            local check_dev
            check_bus=$(cat "$device/busnum" 2>/dev/null) || continue
            check_dev=$(cat "$device/devnum" 2>/dev/null) || continue
            
            check_bus=$(safe_base10 "$check_bus") || continue
            check_dev=$(safe_base10 "$check_dev") || continue
            
            if [ "$check_bus" = "$bus_num" ] && [ "$check_dev" = "$dev_num" ]; then
                found_device="$device"
                base_port_path="$basename"
                debug "Found correct device at: $found_device"
                debug "Port path from sysfs: $base_port_path"
                
                # Get serial number (for logging only, not used in port path)
                if [ -f "$device/serial" ]; then
                    serial=$(cat "$device/serial" 2>/dev/null | tr -d '[:space:]') || true
                    debug "Found serial: ${serial:-none}"
                fi
                
                # Get product name
                if [ -f "$device/product" ]; then
                    product_name=$(cat "$device/product" 2>/dev/null | tr -d '[:space:]') || true
                    debug "Found product: ${product_name:-none}"
                fi
                
                break
            fi
        fi
    done
    
    # Method 2: Use udevadm as fallback if sysfs search didn't work
    if [ -z "$base_port_path" ]; then
        debug "Sysfs search failed, trying udevadm method"
        local bus_num_padded
        local dev_num_padded
        bus_num_padded=$(printf "%03d" "$bus_num")
        dev_num_padded=$(printf "%03d" "$dev_num")
        local dev_bus_path="/dev/bus/usb/${bus_num_padded}/${dev_num_padded}"
        
        if [ -e "$dev_bus_path" ]; then
            local udevadm_props
            udevadm_props=$(udevadm info -n "$dev_bus_path" --query=property 2>/dev/null) || true
            
            if [ -n "$udevadm_props" ]; then
                # Try to get DEVPATH
                local devpath_from_udev
                devpath_from_udev=$(printf '%s' "$udevadm_props" | grep "^DEVPATH=" | head -n1 | cut -d= -f2) || true
                
                if [ -n "$devpath_from_udev" ]; then
                    debug "Processing udevadm DEVPATH: $devpath_from_udev"
                    
                    # Extract the LAST USB port pattern (most specific)
                    base_port_path=$(echo "$devpath_from_udev" | grep -oE '[0-9]+-[0-9]+(\.[0-9]+)*' | tail -n1)
                    
                    if [ -n "$base_port_path" ]; then
                        debug "Extracted port from udevadm: $base_port_path"
                    else
                        debug "No USB port pattern found in DEVPATH"
                    fi
                fi
                
                # Get serial if not already found (for logging only)
                if [ -z "$serial" ]; then
                    local id_serial_short
                    id_serial_short=$(printf '%s' "$udevadm_props" | grep "^ID_SERIAL_SHORT=" | head -n1 | cut -d= -f2) || true
                    if [ -n "$id_serial_short" ]; then
                        serial="$id_serial_short"
                        debug "Found serial from udevadm: ${serial:-none}"
                    fi
                fi
            fi
        fi
    fi
    
    # Build the final port path
    if [ -n "$base_port_path" ]; then
        # Return clean port path (v1.0.0 compatible - no serial suffix)
        printf '%s' "$base_port_path"
        return 0
    else
        # Fallback: create synthetic port identifier
        local fallback="bus${bus_num}-dev${dev_num}"
        debug "Using fallback port identifier: $fallback"
        printf '%s' "$fallback"
        return 0
    fi
}

# Function to get platform path for ID_PATH rule
get_platform_id_path() {
    local bus_num="${1:-}"
    local dev_num="${2:-}"
    local usb_path="${3:-}"
    local card_num="${4:-}"
    
    if [ -z "$bus_num" ] || [ -z "$dev_num" ]; then
        return 1
    fi
    
    bus_num=$(safe_base10 "$bus_num") || return 1
    dev_num=$(safe_base10 "$dev_num") || return 1
    
    local id_path=""
    local bus_num_padded
    local dev_num_padded
    
    bus_num_padded=$(printf "%03d" "$bus_num")
    dev_num_padded=$(printf "%03d" "$dev_num")
    local dev_path="/dev/bus/usb/${bus_num_padded}/${dev_num_padded}"
    
    if [ -e "$dev_path" ]; then
        local udevadm_output
        udevadm_output=$(udevadm info -n "$dev_path" --query=property 2>/dev/null) || true
        
        if [ -n "$udevadm_output" ]; then
            id_path=$(printf '%s' "$udevadm_output" | grep "^ID_PATH=" | head -n1 | cut -d= -f2) || true
            
            if [ -n "$id_path" ]; then
                debug "Found ID_PATH from udevadm: $id_path"
                printf '%s' "$id_path"
                return 0
            fi
        fi
    fi
    
    # Try sound card device if card number provided
    if [ -n "$card_num" ]; then
        local card_dev_path="/dev/snd/controlC${card_num}"
        if [ -e "$card_dev_path" ]; then
            local card_udevadm_output
            card_udevadm_output=$(udevadm info -n "$card_dev_path" --query=property 2>/dev/null) || true
            
            if [ -n "$card_udevadm_output" ]; then
                id_path=$(printf '%s' "$card_udevadm_output" | grep "^ID_PATH=" | head -n1 | cut -d= -f2) || true
                
                if [ -n "$id_path" ]; then
                    debug "Found ID_PATH from sound card device: $id_path"
                    printf '%s' "$id_path"
                    return 0
                fi
            fi
        fi
    fi
    
    return 1
}

# Function to get available USB sound cards
get_card_info() {
    info "Getting USB device information..."
    
    # Check lsusb
    local lsusb_output
    if ! lsusb_output=$(lsusb 2>&1); then
        error_exit "Failed to run lsusb command: ${lsusb_output:-unknown error}"
    fi
    
    printf 'USB devices:\n%s\n\n' "$lsusb_output"
    
    # Check sound cards
    info "Getting sound card information..."
    if [ ! -f "$PROC_ASOUND_CARDS" ]; then
        error_exit "Cannot access $PROC_ASOUND_CARDS. Is ALSA installed properly?"
    fi
    
    local cards_output
    if ! cards_output=$(cat "$PROC_ASOUND_CARDS" 2>&1); then
        error_exit "Failed to read $PROC_ASOUND_CARDS: ${cards_output:-unknown error}"
    fi
    
    printf 'Sound cards:\n%s\n\n' "$cards_output"
    
    # Extract USB paths
    printf 'Card USB paths:\n'
    while IFS= read -r line; do
        if [[ "$line" =~ at\ (usb-[^ ,]+) ]]; then
            printf '  %s\n' "$line"
            printf '  Path: %s\n' "${BASH_REMATCH[1]}"
        fi
    done <<< "$cards_output"
    printf '\n'
    
    # Display aplay output if available
    if command -v aplay >/dev/null 2>&1; then
        local aplay_output
        aplay_output=$(aplay -l 2>/dev/null) || true
        if [ -n "$aplay_output" ]; then
            printf 'ALSA playback devices:\n%s\n\n' "$aplay_output"
        fi
    fi
}

# Function to get detailed card info
get_detailed_card_info() {
    local card_num="${1:-}"
    
    # Validate card number
    if [ -z "$card_num" ]; then
        error_exit "Card number not provided"
    fi
    
    card_num=$(safe_base10 "$card_num") || error_exit "Invalid card number format: $1"
    
    if [ "$card_num" -gt "$MAX_CARD_NUMBER" ]; then
        error_exit "Invalid card number: $card_num. Must be 0-$MAX_CARD_NUMBER."
    fi
    
    # Check card directory
    local card_dir="/proc/asound/card${card_num}"
    if [ ! -d "$card_dir" ]; then
        error_exit "Cannot find directory $card_dir. Card $card_num does not exist."
    fi
    
    info "Getting detailed USB information for sound card $card_num..."
    
    # Variables for device info
    local bus_num=""
    local dev_num=""
    local physical_port=""
    local vendor_id=""
    local product_id=""
    local platform_id_path=""
    
    # Try to get USB info from card directory
    if [ -f "${card_dir}/usbbus" ]; then
        bus_num=$(cat "${card_dir}/usbbus" 2>/dev/null) || true
        [ -n "$bus_num" ] && bus_num=$(safe_base10 "$bus_num") || bus_num=""
        [ -n "$bus_num" ] && debug "Found USB bus: $bus_num"
    fi
    
    if [ -f "${card_dir}/usbdev" ]; then
        dev_num=$(cat "${card_dir}/usbdev" 2>/dev/null) || true
        [ -n "$dev_num" ] && dev_num=$(safe_base10 "$dev_num") || dev_num=""
        [ -n "$dev_num" ] && debug "Found USB device: $dev_num"
    fi
    
    if [ -f "${card_dir}/usbid" ]; then
        local usbid
        usbid=$(cat "${card_dir}/usbid" 2>/dev/null) || true
        if [[ "$usbid" =~ ([0-9a-fA-F]{4}):([0-9a-fA-F]{4}) ]]; then
            vendor_id="${BASH_REMATCH[1]}"
            product_id="${BASH_REMATCH[2]}"
            debug "Found USB IDs: vendor=$vendor_id, product=$product_id"
        fi
    fi
    
    # Get USB path from cards file
    local card_usb_path=""
    local cards_output
    if cards_output=$(cat "$PROC_ASOUND_CARDS" 2>&1); then
        while IFS= read -r line; do
            if [[ "$line" =~ ^\ *$card_num\ .*at\ (usb-[^ ,]+) ]]; then
                card_usb_path="${BASH_REMATCH[1]}"
                debug "Found USB path: $card_usb_path"
                physical_port="$card_usb_path"
                break
            fi
        done <<< "$cards_output"
    fi
    
    # Get additional info if we have bus and device numbers
    if [ -n "$bus_num" ] && [ -n "$dev_num" ]; then
        # Get platform ID path
        platform_id_path=$(get_platform_id_path "$bus_num" "$dev_num" "$physical_port" "$card_num") || true
        
        # Get unique physical port
        local unique_port
        unique_port=$(get_usb_physical_port "$bus_num" "$dev_num") || true
        if [ -n "$unique_port" ]; then
            physical_port="$unique_port"
        fi
    fi
    
    # Output information
    if [ -n "$bus_num" ] || [ -n "$dev_num" ] || [ -n "$physical_port" ] || [ -n "$vendor_id" ]; then
        printf 'USB Device Information for card %s:\n' "$card_num"
        [ -n "$bus_num" ] && printf '  Bus: %s\n' "$bus_num"
        [ -n "$dev_num" ] && printf '  Device: %s\n' "$dev_num"
        [ -n "$physical_port" ] && printf '  USB Path: %s\n' "$physical_port"
        [ -n "$platform_id_path" ] && printf '  Platform ID Path: %s\n' "$platform_id_path"
        [ -n "$vendor_id" ] && printf '  Vendor ID: %s\n' "$vendor_id"
        [ -n "$product_id" ] && printf '  Product ID: %s\n' "$product_id"
        printf '\n'
        return 0
    fi
    
    warning "Could not get complete USB information for card $card_num."
    return 1
}

# Function to check existing udev rules
check_existing_rules() {
    info "Checking existing udev rules..."
    
    if [ -f "$RULES_FILE" ]; then
        printf 'Existing rules in %s:\n' "$RULES_FILE"
        cat "$RULES_FILE" || warning "Could not read existing rules file"
        printf '\n'
    else
        info "No existing rules file found. A new one will be created."
    fi
}

# Function to reload udev rules
reload_udev_rules() {
    info "Reloading udev rules..."
    
    if ! udevadm control --reload-rules 2>&1; then
        error_exit "Failed to reload udev rules."
    fi
    
    # Trigger udev for sound subsystem
    udevadm trigger --subsystem-match=sound 2>/dev/null || true
    
    success "Rules reloaded successfully."
}

# Function to generate udev rules
generate_udev_rules() {
    local vendor_id="${1:-}"
    local product_id="${2:-}"
    local friendly_name="${3:-}"
    local card_name="${4:-}"
    local simple_port="${5:-}"
    local platform_id_path="${6:-}"
    
    # Validate required parameters
    if [ -z "$vendor_id" ] || [ -z "$product_id" ] || [ -z "$friendly_name" ]; then
        error_exit "Missing required parameters for rule generation"
    fi
    
    # Sanitize card name
    local safe_card_name
    safe_card_name=$(printf '%s' "$card_name" | tr -cd '[:alnum:] \t-_.' | tr -s ' ')
    
    # Build rule comment
    local rules="# USB Sound Card: ${safe_card_name:-$friendly_name}\n"
    
    # Build rule content
    local rules_content="SUBSYSTEM==\"sound\", ATTRS{idVendor}==\"$vendor_id\", ATTRS{idProduct}==\"$product_id\""
    
    # Add port criteria if available
    if [ -n "$platform_id_path" ]; then
        debug "Using platform ID path for rule: $platform_id_path"
        rules_content+=", ENV{ID_PATH}==\"$platform_id_path\""
    elif [ -n "$simple_port" ] && is_valid_usb_path "$simple_port"; then
        debug "Using USB port path for rule: $simple_port"
        rules_content+=", KERNELS==\"$simple_port\""
    else
        debug "No port criteria available - matching by vendor/product ID only"
    fi
    
    # Complete the rule
    rules_content+=", ATTR{id}=\"$friendly_name\", SYMLINK+=\"sound/by-id/$friendly_name\""
    
    rules+="$rules_content"
    printf '%s' "$rules"
}

# Function to write rules atomically with deduplication
write_rules_atomic() {
    local rules_file="${1:-}"
    shift
    local rules_content="$*"
    local friendly_name=""
    
    if [ -z "$rules_file" ]; then
        error_exit "Rules file path not provided"
    fi
    
    # Extract friendly name for deduplication
    if [[ "$rules_content" =~ ATTR\{id\}=\"([^\"]+)\" ]]; then
        friendly_name="${BASH_REMATCH[1]}"
    fi
    
    # Create temporary file
    local temp_file
    if ! temp_file=$(mktemp "${TEMP_DIR}/usb-soundcard-rules.XXXXXX" 2>&1); then
        error_exit "Failed to create temporary file: ${temp_file:-unknown error}"
    fi
    CLEANUP_FILES+=("$temp_file")
    
    # Handle existing rules
    if [ -f "$rules_file" ] && [ -n "$friendly_name" ]; then
        # Copy non-matching rules
        if ! grep -Fv "ATTR{id}=\"$friendly_name\"" "$rules_file" > "$temp_file" 2>/dev/null; then
            # File might be empty, that's ok
            true
        fi
    elif [ -f "$rules_file" ]; then
        # Copy entire file if no deduplication needed
        if ! cp "$rules_file" "$temp_file"; then
            error_exit "Failed to copy existing rules"
        fi
    fi
    
    # Append new rules
    if ! printf '%s\n' "$rules_content" >> "$temp_file"; then
        error_exit "Failed to write rules to temporary file"
    fi
    
    # Set proper permissions
    if ! chmod 644 "$temp_file"; then
        error_exit "Failed to set permissions on temporary file"
    fi
    
    # Atomically move to final location
    if ! mv -f "$temp_file" "$rules_file"; then
        error_exit "Failed to install rules file"
    fi
    
    # Remove from cleanup list
    local new_array=()
    local file
    for file in "${CLEANUP_FILES[@]}"; do
        if [ "$file" != "$temp_file" ]; then
            new_array+=("$file")
        fi
    done
    CLEANUP_FILES=("${new_array[@]}")
    
    success "Rules written successfully to $rules_file"
}

# Function to prompt for reboot
prompt_reboot() {
    printf 'A reboot is recommended for the changes to take effect.\n'
    printf 'Do you want to reboot now? (y/n): '
    
    local response
    if read -t 30 -n 1 -r response; then
        printf '\n'
        if [[ $response =~ ^[Yy]$ ]]; then
            printf 'Please confirm reboot (type YES): '
            local confirm
            read -r confirm
            if [ "$confirm" = "YES" ]; then
                info "Rebooting system..."
                sleep 2
                reboot
            else
                info "Reboot cancelled. Remember to reboot later for changes to take effect."
            fi
        else
            info "Remember to reboot later for changes to take effect."
        fi
    else
        printf '\n'
        info "No response received. Remember to reboot later for changes to take effect."
    fi
}

# Interactive mapping function
interactive_mapping() {
    printf '\033[1m===== USB Sound Card Mapper =====\033[0m\n'
    printf 'This wizard will guide you through mapping your USB sound card to a consistent name.\n\n'
    
    # Get card information
    get_card_info
    
    # Get card number from user
    printf 'Enter the number of the sound card you want to map: '
    local card_num
    read -r card_num
    
    if ! card_num=$(safe_base10 "$card_num"); then
        error_exit "Invalid input. Please enter a number between 0 and $MAX_CARD_NUMBER."
    fi
    
    if [ "$card_num" -gt "$MAX_CARD_NUMBER" ]; then
        error_exit "Invalid input. Please enter a number between 0 and $MAX_CARD_NUMBER."
    fi
    
    # Get card information
    local card_line
    if ! card_line=$(grep -E "^ *$card_num " "$PROC_ASOUND_CARDS"); then
        error_exit "No sound card found with number $card_num."
    fi
    
    # Extract card name
    local card_name
    card_name=$(printf '%s' "$card_line" | sed -n 's/.*\[\([^]]*\)\].*/\1/p' | xargs) || true
    if [ -z "$card_name" ]; then
        error_exit "Could not extract card name from: $card_line"
    fi
    
    printf 'Selected card: %s - %s\n' "$card_num" "$card_name"
    
    # Get detailed card info
    get_detailed_card_info "$card_num" || true
    
    # Get USB device list
    printf '\nSelect the USB device that corresponds to this sound card:\n'
    local usb_devices=()
    local line
    while IFS= read -r line; do
        usb_devices+=("$line")
    done < <(lsusb)
    
    # Display USB devices
    local i
    for i in "${!usb_devices[@]}"; do
        printf '%2d. %s\n' "$((i+1))" "${usb_devices[i]}"
    done
    
    # Get selection
    local usb_num
    read -r usb_num
    
    if ! usb_num=$(safe_base10 "$usb_num"); then
        error_exit "Invalid input. Please enter a valid number."
    fi
    
    if [ "$usb_num" -lt 1 ] || [ "$usb_num" -gt "${#usb_devices[@]}" ]; then
        error_exit "Invalid selection. Please enter a number between 1 and ${#usb_devices[@]}."
    fi
    
    # Get selected USB device
    local usb_line="${usb_devices[$((usb_num-1))]}"
    if [ -z "$usb_line" ]; then
        error_exit "No USB device found at position $usb_num."
    fi
    
    # Extract vendor and product IDs
    local vendor_id=""
    local product_id=""
    if [[ "$usb_line" =~ ID\ ([0-9a-fA-F]{4}):([0-9a-fA-F]{4}) ]]; then
        vendor_id="${BASH_REMATCH[1],,}"
        product_id="${BASH_REMATCH[2],,}"
    else
        error_exit "Could not extract vendor and product IDs from: $usb_line"
    fi
    
    # Extract bus and device numbers
    local bus_num=""
    local dev_num=""
    local physical_port=""
    local simple_port=""
    local platform_id_path=""
    
    if [[ "$usb_line" =~ Bus\ ([0-9]{3})\ Device\ ([0-9]{3}) ]]; then
        bus_num=$(safe_base10 "${BASH_REMATCH[1]}") || bus_num=""
        dev_num=$(safe_base10 "${BASH_REMATCH[2]}") || dev_num=""
        
        if [ -n "$bus_num" ] && [ -n "$dev_num" ]; then
            printf 'Selected USB device: %s\n' "$usb_line"
            printf 'Vendor ID: %s\n' "$vendor_id"
            printf 'Product ID: %s\n' "$product_id"
            printf 'Bus: %s, Device: %s\n' "$bus_num" "$dev_num"
            
            # Get platform ID path
            platform_id_path=$(get_platform_id_path "$bus_num" "$dev_num" "" "$card_num") || true
            [ -n "$platform_id_path" ] && printf 'Platform ID path: %s\n' "$platform_id_path"
            
            # Get physical port
            physical_port=$(get_usb_physical_port "$bus_num" "$dev_num") || true
            if [ -n "$physical_port" ]; then
                printf 'USB unique physical port: %s\n' "$physical_port"
                simple_port="$physical_port"
            fi
        fi
    fi
    
    # Get friendly name
    printf '\nEnter a friendly name for the sound card (lowercase letters, numbers, and hyphens only):\n'
    printf 'Leave empty to auto-generate from card name: '
    local friendly_name
    read -r friendly_name
    
    # Auto-generate if empty
    if [ -z "$friendly_name" ]; then
        friendly_name=$(printf '%s' "$card_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
        
        # Ensure name starts with letter
        if ! [[ "$friendly_name" =~ ^[a-z] ]]; then
            friendly_name="card-$friendly_name"
        fi
        
        # Truncate to max length
        friendly_name="${friendly_name:0:$MAX_NAME_LENGTH}"
        
        info "Using auto-generated name: $friendly_name"
    fi
    
    # Validate friendly name
    if ! [[ "$friendly_name" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; then
        error_exit "Invalid friendly name. Must start with lowercase letter, max $MAX_NAME_LENGTH chars, use only lowercase letters, numbers, and hyphens."
    fi
    
    # Check existing rules
    check_existing_rules
    
    # Create rules directory if needed
    mkdir -p /etc/udev/rules.d/
    
    printf 'Creating mapping rules...\n'
    
    # Generate rules
    local rules_content
    rules_content=$(generate_udev_rules "$vendor_id" "$product_id" "$friendly_name" "$card_name" "$simple_port" "$platform_id_path")
    
    # Write rules
    write_rules_atomic "$RULES_FILE" "$rules_content"
    
    # Reload rules
    reload_udev_rules
    
    # Prompt for reboot
    prompt_reboot
    
    success "Sound card mapping created successfully."
}

# Non-interactive mapping function
non_interactive_mapping() {
    local device_name="${1:-}"
    local vendor_id="${2:-}"
    local product_id="${3:-}"
    local port="${4:-}"
    local friendly_name="${5:-}"
    
    # Validate required parameters
    if [ -z "$device_name" ] || [ -z "$vendor_id" ] || [ -z "$product_id" ] || [ -z "$friendly_name" ]; then
        error_exit "Device name, vendor ID, product ID, and friendly name are required for non-interactive mode."
    fi
    
    # Validate vendor ID
    if ! [[ "$vendor_id" =~ ^[0-9a-fA-F]{4}$ ]]; then
        error_exit "Invalid vendor ID: $vendor_id. Must be exactly 4 hexadecimal digits."
    fi
    vendor_id="${vendor_id,,}"
    
    # Validate product ID
    if ! [[ "$product_id" =~ ^[0-9a-fA-F]{4}$ ]]; then
        error_exit "Invalid product ID: $product_id. Must be exactly 4 hexadecimal digits."
    fi
    product_id="${product_id,,}"
    
    # Validate friendly name
    if ! [[ "$friendly_name" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; then
        error_exit "Invalid friendly name: $friendly_name. Must start with lowercase letter, max $MAX_NAME_LENGTH chars."
    fi
    
    # Look for device in system
    info "Looking for device in current system..."
    local simple_port=""
    local platform_id_path=""
    
    # Check if port is valid
    if [ -n "$port" ] && is_valid_usb_path "$port"; then
        simple_port="$port"
        info "Using provided port path: $simple_port"
    elif [ -n "$port" ]; then
        warning "Provided USB port path '$port' appears invalid. Ignoring port parameter."
        port=""
    fi
    
    # Try to find device in lsusb
    local lsusb_output
    if lsusb_output=$(lsusb 2>&1); then
        if [[ "$lsusb_output" =~ Bus\ ([0-9]{3})\ Device\ ([0-9]{3}):\ ID\ $vendor_id:$product_id ]]; then
            local bus_num
            local dev_num
            bus_num=$(safe_base10 "${BASH_REMATCH[1]}") || bus_num=""
            dev_num=$(safe_base10 "${BASH_REMATCH[2]}") || dev_num=""
            
            if [ -n "$bus_num" ] && [ -n "$dev_num" ]; then
                info "Found device in lsusb: bus=$bus_num, dev=$dev_num"
                
                # Get platform ID path
                platform_id_path=$(get_platform_id_path "$bus_num" "$dev_num" "$simple_port" "") || true
                [ -n "$platform_id_path" ] && info "Found platform ID path: $platform_id_path"
                
                # Get unique port if not provided
                if [ -z "$simple_port" ]; then
                    local unique_port
                    unique_port=$(get_usb_physical_port "$bus_num" "$dev_num") || true
                    if [ -n "$unique_port" ]; then
                        info "USB unique physical port: $unique_port"
                        simple_port="$unique_port"
                    fi
                fi
            fi
        fi
    fi
    
    # Create rule
    info "Creating rule for $device_name..."
    
    mkdir -p /etc/udev/rules.d/
    
    # Generate rules
    local rules_content
    rules_content=$(generate_udev_rules "$vendor_id" "$product_id" "$friendly_name" "$device_name" "$simple_port" "$platform_id_path")
    
    # Write rules
    write_rules_atomic "$RULES_FILE" "$rules_content"
    
    # Reload rules
    reload_udev_rules
    
    success "Sound card mapping created successfully."
    info "Remember to reboot for changes to take effect."
}

# Test USB port detection
test_usb_port_detection() {
    local old_debug="${DEBUG:-false}"
    
    info "Testing USB port detection..."
    
    # Get USB devices
    local usb_devices
    if ! usb_devices=$(lsusb 2>&1); then
        warning "Failed to get USB devices"
        DEBUG="$old_debug"
        return 1
    fi
    
    if [ -z "$usb_devices" ]; then
        warning "No USB devices found"
        DEBUG="$old_debug"
        return 1
    fi
    
    printf 'Found USB devices:\n%s\n\n' "$usb_devices"
    
    local success_count=0
    local total_count=0
    
    # Test each device
    while read -r line; do
        if [[ "$line" =~ Bus\ ([0-9]{3})\ Device\ ([0-9]{3}) ]]; then
            local bus_num
            local dev_num
            bus_num=$(safe_base10 "${BASH_REMATCH[1]}") || continue
            dev_num=$(safe_base10 "${BASH_REMATCH[2]}") || continue
            
            total_count=$((total_count + 1))
            
            # Try to get port info
            local port_path
            port_path=$(get_usb_physical_port "$bus_num" "$dev_num") || true
            
            # Try to get platform ID
            local platform_path
            platform_path=$(get_platform_id_path "$bus_num" "$dev_num" "" "") || true
            
            if [ -n "$port_path" ]; then
                printf 'Device on Bus %s Device %s:\n' "$bus_num" "$dev_num"
                printf '  USB Port path = %s\n' "$port_path"
                [ -n "$platform_path" ] && printf '  Platform ID_PATH = %s\n' "$platform_path"
                success_count=$((success_count + 1))
            else
                printf 'Device on Bus %s Device %s: Could not determine port path\n' "$bus_num" "$dev_num"
            fi
        fi
    done <<< "$usb_devices"
    
    printf '\nPort detection test results: %d of %d devices mapped successfully.\n' "$success_count" "$total_count"
    
    DEBUG="$old_debug"
    
    if [ $success_count -eq 0 ]; then
        warning "Port detection test failed. No port paths could be determined."
        return 1
    elif [ $success_count -lt $total_count ]; then
        warning "Port detection partially successful. Some devices could not be mapped."
        return 0
    else
        success "Port detection test successful! All device ports were mapped."
        return 0
    fi
}

# Display help
show_help() {
    cat << EOF
USB Sound Card Mapper V1.2.1 - Create persistent names for USB sound devices
Part of LyreBirdAudio - RTSP Audio Streaming Suite

Usage: $SCRIPT_NAME [options]

Options:
  -i, --interactive       Run in interactive mode (default)
  -n, --non-interactive   Run in non-interactive mode (requires parameters)
  -d, --device NAME       Device name (for logging)
  -v, --vendor ID         Vendor ID (4-digit hex)
  -p, --product ID        Product ID (4-digit hex)
  -u, --usb-port PORT     USB port path (for multiple identical devices)
  -f, --friendly NAME     Friendly name to assign
  -t, --test              Test USB port detection
  -D, --debug             Enable debug output
  -h, --help              Show this help

Examples:
  $SCRIPT_NAME                      
    Run in interactive mode

  $SCRIPT_NAME -n -d "MOVO X1" -v 2e88 -p 4610 -f movo-x1
    Non-interactive mapping

  $SCRIPT_NAME -n -d "MOVO X1" -v 2e88 -p 4610 -u "usb-3.4" -f movo-x1
    Map to specific USB port

  $SCRIPT_NAME -t
    Test port detection capabilities

Report bugs to: https://github.com/tomtom215/LyreBirdAudio/issues
EOF
    exit 0
}

# Main function
main() {
    # Check dependencies first
    check_dependencies
    
    # Set defaults
    DEBUG="${DEBUG:-$DEFAULT_DEBUG}"
    
    # Quick scan for test mode and debug
    local arg
    for arg in "$@"; do
        case "$arg" in
            -t|--test)
                check_root
                test_usb_port_detection
                exit $?
                ;;
            -D|--debug)
                DEBUG="true"
                info "Debug mode enabled"
                ;;
        esac
    done
    
    # Check root
    check_root
    
    # Default to interactive if no args
    if [ $# -eq 0 ]; then
        interactive_mapping
        exit 0
    fi
    
    # Parse arguments
    local device_name=""
    local vendor_id=""
    local product_id=""
    local port=""
    local friendly_name=""
    local mode="interactive"
    
    while [ $# -gt 0 ]; do
        case "$1" in
            -i|--interactive)
                mode="interactive"
                shift
                ;;
            -n|--non-interactive)
                mode="non-interactive"
                shift
                ;;
            -d|--device)
                if [ -z "${2:-}" ]; then
                    error_exit "Option '$1' requires an argument"
                fi
                device_name="$2"
                shift 2
                ;;
            -v|--vendor)
                if [ -z "${2:-}" ]; then
                    error_exit "Option '$1' requires an argument"
                fi
                vendor_id="$2"
                shift 2
                ;;
            -p|--product)
                if [ -z "${2:-}" ]; then
                    error_exit "Option '$1' requires an argument"
                fi
                product_id="$2"
                shift 2
                ;;
            -u|--usb-port)
                if [ -z "${2:-}" ]; then
                    error_exit "Option '$1' requires an argument"
                fi
                port="$2"
                shift 2
                ;;
            -f|--friendly)
                if [ -z "${2:-}" ]; then
                    error_exit "Option '$1' requires an argument"
                fi
                friendly_name="$2"
                shift 2
                ;;
            -t|--test)
                shift
                ;;
            -D|--debug)
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                error_exit "Unknown option: $1. Use -h for help."
                ;;
        esac
    done
    
    # Execute based on mode
    if [ "$mode" = "interactive" ]; then
        interactive_mapping
    else
        non_interactive_mapping "$device_name" "$vendor_id" "$product_id" "$port" "$friendly_name"
    fi
}

# Entry point
main "$@"

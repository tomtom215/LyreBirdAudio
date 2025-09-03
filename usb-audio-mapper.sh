#!/bin/bash
# usb-soundcard-mapper.sh - Automatically map USB sound cards to persistent names
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# This script creates udev rules for USB sound cards to ensure they maintain 
# consistent names across reboots, with symlinks for easy access.
#
# Version: 1.2.0
# Changes: Maintained v1.0.0 compatibility while incorporating safe improvements from v1.1.1
#          - Restored original error handling (removed set -e and set -u)
#          - Restored timestamp-based device identifiers for uniqueness
#          - Restored complex device detection logic
#          - Kept beneficial improvements: safe_base10, portable hash, color detection
#          - Fixed array cleanup, nullglob handling, and validation

# Set bash pipefail for better error handling (removed -e and -u for compatibility)
set -o pipefail

# Constants
readonly RULES_FILE="/etc/udev/rules.d/99-usb-soundcards.rules"
readonly PROC_ASOUND_CARDS="/proc/asound/cards"
readonly DEFAULT_DEBUG="false"

# Global variables
DEBUG="${DEBUG:-$DEFAULT_DEBUG}"
CLEANUP_FILES=()
USE_COLOR=false

# Check if output is to a terminal for color support
if [ -t 1 ] && [ -t 2 ]; then
    USE_COLOR=true
fi

# Signal handler for cleanup
cleanup() {
    local exit_code=$?
    # Remove any temporary files
    for file in "${CLEANUP_FILES[@]}"; do
        [ -f "$file" ] && rm -f "$file" 2>/dev/null
    done
    exit $exit_code
}

# Set up signal handlers
trap cleanup EXIT INT TERM HUP

# Function to print error messages and exit
error_exit() {
    if [ "$USE_COLOR" = "true" ]; then
        printf '\033[31mERROR: %s\033[0m\n' "$1" >&2
    else
        printf 'ERROR: %s\n' "$1" >&2
    fi
    exit 1
}

# Function to print information messages
info() {
    if [ "$USE_COLOR" = "true" ]; then
        printf '\033[34mINFO: %s\033[0m\n' "$1"
    else
        printf 'INFO: %s\n' "$1"
    fi
}

# Function to print success messages
success() {
    if [ "$USE_COLOR" = "true" ]; then
        printf '\033[32mSUCCESS: %s\033[0m\n' "$1"
    else
        printf 'SUCCESS: %s\n' "$1"
    fi
}

# Function to print warning messages
warning() {
    if [ "$USE_COLOR" = "true" ]; then
        printf '\033[33mWARNING: %s\033[0m\n' "$1" >&2
    else
        printf 'WARNING: %s\n' "$1" >&2
    fi
}

# Function to print debug messages if debug mode is enabled
debug() {
    if [ "$DEBUG" = "true" ]; then
        if [ "$USE_COLOR" = "true" ]; then
            printf '\033[35mDEBUG: %s\033[0m\n' "$1" >&2
        else
            printf 'DEBUG: %s\n' "$1" >&2
        fi
    fi
}

# Helper function for safe base-10 conversion (prevents octal interpretation)
safe_base10() {
    local val="$1"
    [[ "$val" =~ ^[0-9]+$ ]] || return 1
    printf "%d" "$((10#$val))"
}

# Portable hash function for systems without md5sum
get_portable_hash() {
    local input="$1"
    local length="${2:-8}"
    
    if command -v sha256sum &> /dev/null; then
        printf '%s' "$input" | sha256sum | head -c "$length"
    elif command -v sha1sum &> /dev/null; then
        printf '%s' "$input" | sha1sum | head -c "$length"
    elif command -v cksum &> /dev/null; then
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
    
    for cmd in "${required_deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        error_exit "Required commands not found: ${missing_deps[*]}. Please install them."
    fi
    
    for cmd in "${optional_deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
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

# Function to get available USB sound cards
get_card_info() {
    # Get lsusb output
    info "Getting USB device information..."
    local lsusb_output
    lsusb_output=$(lsusb 2>&1)
    if [ $? -ne 0 ]; then
        error_exit "Failed to run lsusb command: $lsusb_output"
    fi
    
    printf 'USB devices:\n%s\n\n' "$lsusb_output"
    
    # Get sound card information
    info "Getting sound card information..."
    if [ ! -f "$PROC_ASOUND_CARDS" ]; then
        error_exit "Cannot access $PROC_ASOUND_CARDS. Is ALSA installed properly?"
    fi
    
    local cards_output
    cards_output=$(cat "$PROC_ASOUND_CARDS" 2>&1)
    if [ $? -ne 0 ]; then
        error_exit "Failed to read $PROC_ASOUND_CARDS: $cards_output"
    fi
    
    printf 'Sound cards:\n%s\n\n' "$cards_output"
    
    # Extract and display detailed card paths if available
    printf 'Card USB paths:\n'
    while IFS= read -r line; do
        if [[ "$line" =~ at\ (usb-[^ ,]+) ]]; then
            local card_path="${BASH_REMATCH[1]}"
            printf '  %s\n' "$line"
            printf '  Path: %s\n' "$card_path"
        fi
    done <<< "$cards_output"
    printf '\n'
    
    # Display aplay output for reference
    if command -v aplay &> /dev/null; then
        local aplay_output
        aplay_output=$(aplay -l 2>/dev/null) || true
        if [ -n "$aplay_output" ]; then
            printf 'ALSA playback devices:\n%s\n\n' "$aplay_output"
        fi
    done
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
    
    success "Rules reloaded successfully."
}

# Function to prompt for reboot
prompt_reboot() {
    printf 'A reboot is recommended for the changes to take effect.\n'
    printf 'Do you want to reboot now? (y/n): '
    
    # Set timeout for response
    local response
    if read -t 30 -n 1 -r response; then
        printf '\n'
        if [[ $response =~ ^[Yy]$ ]]; then
            printf 'Please confirm reboot (type YES): '
            local confirm
            read -r confirm
            if [ "$confirm" = "YES" ]; then
                info "Rebooting system..."
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

# Function to check if a string is valid USB path (more permissive for v1.0.0 compatibility)
is_valid_usb_path() {
    local path="$1"
    
    if [ -z "$path" ]; then
        return 1
    fi
    
    # Check if path contains expected USB path components
    if [[ "$path" == *"usb"* ]] && [[ "$path" == *":"* ]]; then
        return 0
    elif [[ "$path" =~ ^(usb-)?[0-9]+-[0-9]+(\.[0-9]+)*$ ]]; then
        return 0
    else
        # Accept paths that v1.0.0 would have accepted (more permissive)
        if [[ "$path" == *"-"* ]]; then
            return 0
        fi
        return 1
    fi
}

# Function to get USB physical port path for a device
# This function creates unique identifiers for USB devices, critical for handling
# multiple identical devices (e.g., 4x same model microphone)
# Returns: unique-identifier combining port path and device-specific hash
get_usb_physical_port() {
    local bus_num="$1"
    local dev_num="$2"
    
    # Validate inputs - Force base-10 interpretation
    if [ -z "$bus_num" ] || [ -z "$dev_num" ]; then
        debug "Missing bus or device number for port detection"
        return 1
    fi
    
    bus_num=$(safe_base10 "$bus_num") || return 1
    dev_num=$(safe_base10 "$dev_num") || return 1
    
    # Use sysfs directly - this is the most reliable method across distributions
    
    # Method 1: Get the device path from sysfs
    local sysfs_path="/sys/bus/usb/devices/${bus_num}-${dev_num}"
    if [ ! -d "$sysfs_path" ]; then
        # Try alternate format 
        sysfs_path="/sys/bus/usb/devices/${bus_num}-${bus_num}.${dev_num}"
        if [ ! -d "$sysfs_path" ]; then
            # Try finding it through a search
            local possible_path
            possible_path=$(find /sys/bus/usb/devices -maxdepth 1 -name "${bus_num}-*" 2>/dev/null | head -n1) || true
            if [ -n "$possible_path" ]; then
                sysfs_path="$possible_path"
            else
                debug "Could not find sysfs path for bus:$bus_num dev:$dev_num"
            fi
        fi
    fi
    
    debug "Checking sysfs path: $sysfs_path"
    
    # Create variables to build a unique identifier
    local base_port_path=""
    local serial=""
    local product_name=""
    
    # Method 2: Try to get the devpath directly
    local devpath=""
    if [ -f "$sysfs_path/devpath" ]; then
        devpath=$(cat "$sysfs_path/devpath" 2>/dev/null) || true
        if [ -n "$devpath" ]; then
            debug "Found devpath: $devpath"
            base_port_path="usb-$devpath"
        fi
    fi
    
    # Check for a serial number
    if [ -f "$sysfs_path/serial" ]; then
        serial=$(cat "$sysfs_path/serial" 2>/dev/null) || true
        debug "Found serial from sysfs: $serial"
    fi
    
    # Check for a product name
    if [ -f "$sysfs_path/product" ]; then
        product_name=$(cat "$sysfs_path/product" 2>/dev/null) || true
        debug "Found product name: $product_name"
    fi
    
    # Method 3: Get USB device path from sysfs structure
    local sys_device_path=""
    # This gets the canonical path with all symlinks resolved
    if [ -d "$sysfs_path" ]; then
        sys_device_path=$(readlink -f "$sysfs_path" 2>/dev/null) || true
        debug "Found sysfs device path: $sys_device_path"
    else
        # Try another approach - look through all devices to find matching bus.dev
        local devices_dir="/sys/bus/usb/devices"
        # Add nullglob protection for glob expansion
        local old_nullglob=$(shopt -p nullglob)
        shopt -s nullglob
        for device in "$devices_dir"/*; do
            if [ -f "$device/busnum" ] && [ -f "$device/devnum" ]; then
                local dev_busnum
                local dev_devnum
                dev_busnum=$(cat "$device/busnum" 2>/dev/null) || continue
                dev_devnum=$(cat "$device/devnum" 2>/dev/null) || continue
                
                dev_busnum=$(safe_base10 "$dev_busnum") || continue
                dev_devnum=$(safe_base10 "$dev_devnum") || continue
                
                if [ "$dev_busnum" = "$bus_num" ] && [ "$dev_devnum" = "$dev_num" ]; then
                    sys_device_path=$(readlink -f "$device" 2>/dev/null) || true
                    debug "Found device through scan: $sys_device_path"
                    
                    # If we found the device this way, also check for serial
                    if [ -z "$serial" ] && [ -f "$device/serial" ]; then
                        serial=$(cat "$device/serial" 2>/dev/null) || true
                        debug "Found serial through scan: $serial"
                    fi
                    
                    # Check for product name too
                    if [ -z "$product_name" ] && [ -f "$device/product" ]; then
                        product_name=$(cat "$device/product" 2>/dev/null) || true
                        debug "Found product name through scan: $product_name"
                    fi
                    
                    break
                fi
            fi
        done
        eval "$old_nullglob"  # Restore original setting
    fi
    
    # Extract the port path from the device path if we don't have one yet
    if [ -z "$base_port_path" ] && [ -n "$sys_device_path" ]; then
        # Extract the port information from the path
        
        # Method A: Try to get the device path structure
        if [[ "$sys_device_path" =~ /[0-9]+-[0-9]+(\.[0-9]+)*$ ]]; then
            base_port_path="${BASH_REMATCH[0]}"
            base_port_path="${base_port_path#/}"  # Remove leading slash
            debug "Extracted port path from device path: $base_port_path"
        fi
        
        # Method B: Use the directory name itself which often has port info
        if [ -z "$base_port_path" ]; then
            local dirname
            dirname=$(basename "$sys_device_path")
            if [[ "$dirname" == *"-"* ]]; then
                debug "Using directory name as port identifier: $dirname"
                base_port_path="$dirname"
            fi
        fi
    fi
    
    # Method 4: Use udevadm as a last resort for port path
    if [ -z "$base_port_path" ]; then
        debug "Trying udevadm method as last resort"
        local device_path=""
        local dev_bus_path="/dev/bus/usb/${bus_num}/${dev_num}"
        
        # Format device numbers with leading zeros
        local bus_num_padded
        local dev_num_padded
        bus_num_padded=$(printf "%03d" "$bus_num")
        dev_num_padded=$(printf "%03d" "$dev_num")
        dev_bus_path="/dev/bus/usb/${bus_num_padded}/${dev_num_padded}"
        
        if [ -e "$dev_bus_path" ]; then
            device_path=$(udevadm info -q path -n "$dev_bus_path" 2>/dev/null) || true
        fi
        
        if [ -n "$device_path" ]; then
            debug "Found udevadm path: $device_path"
            
            # Get full properties
            local udevadm_props
            udevadm_props=$(udevadm info -n "$dev_bus_path" --query=property 2>/dev/null) || true
            
            # Try to get serial number if we don't have it
            if [ -z "$serial" ] && [ -n "$udevadm_props" ]; then
                serial=$(printf '%s' "$udevadm_props" | grep "^ID_SERIAL=" | head -n1 | cut -d= -f2) || true
                debug "Found serial from udevadm: $serial"
            fi
            
            # Try to get product name if we don't have it
            if [ -z "$product_name" ] && [ -n "$udevadm_props" ]; then
                product_name=$(printf '%s' "$udevadm_props" | grep "^ID_MODEL=" | head -n1 | cut -d= -f2) || true
                debug "Found product name from udevadm: $product_name"
            fi
            
            # Look for DEVPATH
            local devpath_from_udev=""
            if [ -n "$udevadm_props" ]; then
                devpath_from_udev=$(printf '%s' "$udevadm_props" | grep "^DEVPATH=" | head -n1 | cut -d= -f2) || true
            fi
            
            if [ -n "$devpath_from_udev" ]; then
                # Extract meaningful part of path
                if [[ "$devpath_from_udev" =~ /([0-9]+-[0-9]+(\.[0-9]+)*)$ ]]; then
                    base_port_path="${BASH_REMATCH[1]}"
                    debug "Extracted port from DEVPATH: $base_port_path"
                fi
                
                # If we still have nothing, use the last part of the path
                if [ -z "$base_port_path" ]; then
                    local last_part
                    last_part=$(basename "$devpath_from_udev")
                    if [[ "$last_part" == *"-"* ]]; then
                        debug "Using last part of DEVPATH: $last_part"
                        base_port_path="$last_part"
                    fi
                fi
            fi
            
            # Try to extract port info from the device path itself if still nothing
            if [ -z "$base_port_path" ] && [[ "$device_path" =~ ([0-9]+-[0-9]+(\.[0-9]+)*) ]]; then
                base_port_path="${BASH_REMATCH[1]}"
                debug "Extracted port from device path: $base_port_path"
            fi
        fi
    fi
    
    # Method 5: Last fallback - just create a unique identifier from bus and device
    if [ -z "$base_port_path" ]; then
        debug "Using fallback method - creating synthetic port identifier"
        base_port_path="usb-bus${bus_num}-port${dev_num}"
    fi
    
    # Now build a unique identifier using all information we have
    
    # First, use base port path
    local uniqueness="$base_port_path"
    
    # Always create a fallback uniqueness tag based on device-specific information
    # This ensures even identical devices on the same port get unique identifiers
    local uuid_fragment=""
    
    # Try using serial number first (most reliable)
    if [ -n "$serial" ]; then
        # Use first 8 chars of serial or the whole thing if shorter
        if [ ${#serial} -gt 8 ]; then
            uuid_fragment="${serial:0:8}"
        else
            uuid_fragment="$serial"
        fi
    else
        # RESTORED FROM v1.0.0: Use timestamp-based hash for uniqueness
        # If no serial number, create a hash based on bus/dev and product info
        local hash_input="bus${bus_num}dev${dev_num}"
        # Add product name if available
        [ -n "$product_name" ] && hash_input="${hash_input}${product_name}"
        # Add current timestamp to ensure uniqueness
        hash_input="${hash_input}$(date +%s%N)"
        # Create a 8-char hash
        if command -v md5sum &> /dev/null; then
            uuid_fragment=$(echo "$hash_input" | md5sum | head -c 8)
        else
            # Fallback to get_portable_hash if md5sum not available
            uuid_fragment=$(get_portable_hash "$hash_input" 8)
        fi
        [ -z "$uuid_fragment" ] && uuid_fragment="fallback"
    fi
    
    # Append uuid fragment to ensure uniqueness
    printf '%s-%s' "$uniqueness" "$uuid_fragment"
    return 0
}

# Function to get platform path for ID_PATH rule
get_platform_id_path() {
    local bus_num="$1"
    local dev_num="$2"
    local usb_path="$3"
    local card_num="$4"
    
    bus_num=$(safe_base10 "$bus_num") || return 1
    dev_num=$(safe_base10 "$dev_num") || return 1
    
    # Try to get ID_PATH from udevadm
    local id_path=""
    local bus_num_padded
    local dev_num_padded
    bus_num_padded=$(printf "%03d" "$bus_num")
    dev_num_padded=$(printf "%03d" "$dev_num")
    local dev_path="/dev/bus/usb/${bus_num_padded}/${dev_num_padded}"
    
    if [ -e "$dev_path" ]; then
        local udevadm_output
        udevadm_output=$(udevadm info -n "$dev_path" --query=property 2>/dev/null) || true
        
        # Extract ID_PATH if available
        if [ -n "$udevadm_output" ]; then
            id_path=$(printf '%s' "$udevadm_output" | grep "^ID_PATH=" | head -n1 | cut -d= -f2) || true
        fi
        
        if [ -n "$id_path" ]; then
            debug "Found ID_PATH from udevadm: $id_path"
            printf '%s' "$id_path"
            return 0
        fi
    fi
    
    # Alternative method: Try to extract platform path from sound card device
    if [ -n "$card_num" ]; then
        local card_dev_path="/dev/snd/controlC${card_num}"
        if [ -e "$card_dev_path" ]; then
            local card_udevadm_output
            card_udevadm_output=$(udevadm info -n "$card_dev_path" --query=property 2>/dev/null) || true
            
            # Extract ID_PATH if available
            if [ -n "$card_udevadm_output" ]; then
                id_path=$(printf '%s' "$card_udevadm_output" | grep "^ID_PATH=" | head -n1 | cut -d= -f2) || true
            fi
            
            if [ -n "$id_path" ]; then
                debug "Found ID_PATH from sound card device: $id_path"
                printf '%s' "$id_path"
                return 0
            fi
        fi
    fi
    
    # Only return what we found from udevadm - no manual reconstruction
    return 1
}

# Function to test USB port detection
test_usb_port_detection() {
    local old_debug="${DEBUG:-false}"
    
    info "Testing USB port detection..."
    
    # Get all USB devices
    local usb_devices
    usb_devices=$(lsusb 2>&1)
    if [ $? -ne 0 ]; then
        warning "Failed to get USB devices: $usb_devices"
        DEBUG="$old_debug"
        return 1
    fi
    
    if [ -z "$usb_devices" ]; then
        warning "No USB devices found during test."
        DEBUG="$old_debug"
        return 1
    fi
    
    printf 'Found USB devices:\n%s\n\n' "$usb_devices"
    
    # Show debug info for the first device to help troubleshoot
    if [[ "$usb_devices" =~ Bus\ ([0-9]{3})\ Device\ ([0-9]{3}) ]]; then
        local bus_num="${BASH_REMATCH[1]}"
        local dev_num="${BASH_REMATCH[2]}"
        
        bus_num=$(safe_base10 "$bus_num") || {
            DEBUG="$old_debug"
            return 1
        }
        dev_num=$(safe_base10 "$dev_num") || {
            DEBUG="$old_debug"
            return 1
        }
        
        printf 'Detailed information for first device (Bus %s Device %s):\n' "$bus_num" "$dev_num"
        
        # Show USB sysfs paths for debugging
        printf 'Checking for USB device in sysfs:\n'
        printf '1. Standard path: /sys/bus/usb/devices/%s-%s\n' "$bus_num" "$dev_num"
        [ -d "/sys/bus/usb/devices/${bus_num}-${dev_num}" ] && printf '   - Path exists\n' || printf '   - Path does not exist\n'
        
        printf '2. Alternate path: /sys/bus/usb/devices/%s-%s.%s\n' "$bus_num" "$bus_num" "$dev_num"
        [ -d "/sys/bus/usb/devices/${bus_num}-${bus_num}.${dev_num}" ] && printf '   - Path exists\n' || printf '   - Path does not exist\n'
        
        printf '3. Search results:\n'
        find /sys/bus/usb/devices -maxdepth 1 -name "${bus_num}-*" 2>/dev/null | head -n 3 || true
        
        # Check for devpath attribute
        local found_devpath=""
        for potential_path in "/sys/bus/usb/devices/${bus_num}-${dev_num}" "/sys/bus/usb/devices/${bus_num}-${bus_num}.${dev_num}" $(find /sys/bus/usb/devices -maxdepth 1 -name "${bus_num}-*" 2>/dev/null | head -n 1); do
            if [ -f "$potential_path/devpath" ]; then
                found_devpath=$(cat "$potential_path/devpath" 2>/dev/null) || true
                printf '4. Found devpath attribute at %s/devpath: %s\n' "$potential_path" "$found_devpath"
                break
            fi
        done
        
        if [ -z "$found_devpath" ]; then
            printf '4. No devpath attribute found in any potential path\n'
        fi
        
        # Show udevadm info
        printf '5. udevadm information:\n'
        local bus_num_padded
        local dev_num_padded
        bus_num_padded=$(printf "%03d" "$bus_num")
        dev_num_padded=$(printf "%03d" "$dev_num")
        local dev_path_test="/dev/bus/usb/${bus_num_padded}/${dev_num_padded}"
        
        if [ -e "$dev_path_test" ]; then
            local dev_path_info
            dev_path_info=$(udevadm info -q path -n "$dev_path_test" 2>/dev/null) || true
            if [ -n "$dev_path_info" ]; then
                printf '   - Device path: %s\n' "$dev_path_info"
                printf '   - First 5 lines of udevadm property info:\n'
                udevadm info -n "$dev_path_test" --query=property 2>/dev/null | head -n 5 || true
            else
                printf '   - Could not get udevadm device path\n'
            fi
        else
            printf '   - Device node %s does not exist\n' "$dev_path_test"
        fi
        
        printf '\n'
    fi
    
    # Continue with regular testing
    local success_count=0
    local total_count=0
    
    # Process each USB device
    while read -r line; do
        if [[ "$line" =~ Bus\ ([0-9]{3})\ Device\ ([0-9]{3}) ]]; then
            local bus_num="${BASH_REMATCH[1]}"
            local dev_num="${BASH_REMATCH[2]}"
            
            bus_num=$(safe_base10 "$bus_num") || continue
            dev_num=$(safe_base10 "$dev_num") || continue
            
            total_count=$((total_count + 1))
            
            # Disable verbose debug output during tests to keep output clean
            DEBUG="false"
            
            # Try to get port info
            local port_path
            port_path=$(get_usb_physical_port "$bus_num" "$dev_num")
            local result=$?
            
            # Try to get platform ID path
            local platform_path
            platform_path=$(get_platform_id_path "$bus_num" "$dev_num" "$port_path" "") || true
            
            if [ $result -eq 0 ] && [ -n "$port_path" ]; then
                printf 'Device on Bus %s Device %s:\n' "$bus_num" "$dev_num"
                printf '  USB Port path = %s\n' "$port_path"
                if [ -n "$platform_path" ]; then
                    printf '  Platform ID_PATH = %s\n' "$platform_path"
                fi
                success_count=$((success_count + 1))
            else
                printf 'Device on Bus %s Device %s: Could not determine port path\n' "$bus_num" "$dev_num"
            fi
        fi
    done <<< "$usb_devices"
    
    printf '\nPort detection test results: %d of %d devices mapped successfully.\n' "$success_count" "$total_count"
    
    # Restore debug setting
    DEBUG="$old_debug"
    
    if [ $success_count -eq 0 ]; then
        warning "Port detection test failed. No port paths could be determined."
        return 1
    elif [ $success_count -lt $total_count ]; then
        warning "Port detection partially successful. Some devices could not be mapped."
        return 2
    else
        success "Port detection test successful! All device ports were mapped."
        return 0
    fi
}

# Function to get more detailed card info including port path
get_detailed_card_info() {
    local card_num="$1"
    
    # Validate card number
    card_num=$(safe_base10 "$card_num") || error_exit "Invalid card number format: $1"
    if [ "$card_num" -gt 99 ]; then
        error_exit "Invalid card number: $card_num. Must be 0-99."
    fi
    
    # Get card directory path
    local card_dir="/proc/asound/card${card_num}"
    if [ ! -d "$card_dir" ]; then
        error_exit "Cannot find directory $card_dir. Card $card_num does not exist."
    fi
    
    # Check for files (not directories) for USB device detection
    if [ ! -f "${card_dir}/usbbus" ] && [ ! -f "${card_dir}/usbdev" ] && [ ! -f "${card_dir}/usbid" ]; then
        warning "Card $card_num may not be a USB device. Continuing anyway..."
    fi
    
    # Try to get USB info from udevadm
    info "Getting detailed USB information for sound card $card_num..."
    
    # Variables to store device info
    local bus_num=""
    local dev_num=""
    local physical_port=""
    local vendor_id=""
    local product_id=""
    local platform_id_path=""
    
    # Try to get USB bus and device number directly from ALSA
    if [ -f "${card_dir}/usbbus" ]; then
        bus_num=$(cat "${card_dir}/usbbus" 2>/dev/null) || true
        [ -n "$bus_num" ] && bus_num=$(safe_base10 "$bus_num") || bus_num=""
        info "Found USB bus from card directory: $bus_num"
    fi
    
    if [ -f "${card_dir}/usbdev" ]; then
        dev_num=$(cat "${card_dir}/usbdev" 2>/dev/null) || true
        [ -n "$dev_num" ] && dev_num=$(safe_base10 "$dev_num") || dev_num=""
        info "Found USB device from card directory: $dev_num"
    fi
    
    # Try to get vendor and product ID from usbid file
    if [ -f "${card_dir}/usbid" ]; then
        local usbid
        usbid=$(cat "${card_dir}/usbid" 2>/dev/null) || true
        if [[ "$usbid" =~ ([0-9a-f]{4}):([0-9a-f]{4}) ]]; then
            vendor_id="${BASH_REMATCH[1]}"
            product_id="${BASH_REMATCH[2]}"
            info "Found USB IDs from card directory: vendor=$vendor_id, product=$product_id"
        fi
    fi
    
    # Try to get the USB path from the cards file
    local card_usb_path=""
    local cards_output
    cards_output=$(cat "$PROC_ASOUND_CARDS" 2>&1)
    if [ $? -eq 0 ]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^\ *$card_num\ .*at\ (usb-[^ ,]+) ]]; then
                card_usb_path="${BASH_REMATCH[1]}"
                info "Found USB path from cards file: $card_usb_path"
                
                # Extract simplified USB path for rule creation
                if [[ "$card_usb_path" =~ usb-([0-9]+\.[0-9]+) ]]; then
                    physical_port="usb-${BASH_REMATCH[1]}"
                    info "Extracted simplified USB path: $physical_port"
                else
                    physical_port="$card_usb_path"
                fi
                break
            fi
        done <<< "$cards_output"
    else
        warning "Could not read cards file"
    fi
    
    # If we have both bus and device number, try to get additional information
    if [ -n "$bus_num" ] && [ -n "$dev_num" ]; then
        info "Using direct ALSA info: bus=$bus_num, device=$dev_num"
        
        # Try to get platform ID path
        platform_id_path=$(get_platform_id_path "$bus_num" "$dev_num" "$physical_port" "$card_num") || true
        if [ -n "$platform_id_path" ]; then
            info "Found platform ID path: $platform_id_path"
        fi
        
        # Prioritize unique identifiers - always get physical port
        local unique_port
        unique_port=$(get_usb_physical_port "$bus_num" "$dev_num") || true
        if [ -n "$unique_port" ]; then
            info "USB unique physical port: $unique_port"
            # Prefer unique port over simple path
            physical_port="$unique_port"
        fi
        
        printf 'USB Device Information for card %s:\n' "$card_num"
        printf '  Bus: %s\n' "$bus_num"
        printf '  Device: %s\n' "$dev_num"
        [ -n "$physical_port" ] && printf '  USB Path: %s\n' "$physical_port"
        [ -n "$platform_id_path" ] && printf '  Platform ID Path: %s\n' "$platform_id_path"
        [ -n "$vendor_id" ] && printf '  Vendor ID: %s\n' "$vendor_id"
        [ -n "$product_id" ] && printf '  Product ID: %s\n' "$product_id"
        printf '\n'
        
        return 0
    fi
    
    # If we have the USB path from the cards file but not bus/dev, that's still success
    if [ -n "$physical_port" ]; then
        printf 'USB Device Information for card %s:\n' "$card_num"
        [ -n "$physical_port" ] && printf '  USB Path: %s\n' "$physical_port"
        [ -n "$vendor_id" ] && printf '  Vendor ID: %s\n' "$vendor_id"
        [ -n "$product_id" ] && printf '  Product ID: %s\n' "$product_id"
        printf '\n'
        
        return 0
    fi
    
    # RESTORED FROM v1.0.0: Complex device detection logic
    # If direct approach failed, try using device nodes
    info "Trying alternative approach with device nodes..."
    
    # Find a USB device in the card's directory using various possible paths
    local device_paths=()
    
    # Add common PCM device paths
    if [ -d "${card_dir}/pcm0p" ]; then
        device_paths+=("${card_dir}/pcm0p/sub0")
    fi
    if [ -d "${card_dir}/pcm0c" ]; then
        device_paths+=("${card_dir}/pcm0c/sub0")
    fi
    
    # Add any other pcm devices
    for pcm_dir in "${card_dir}"/pcm*; do
        if [ -d "$pcm_dir" ]; then
            for sub_dir in "$pcm_dir"/sub*; do
                if [ -d "$sub_dir" ]; then
                    device_paths+=("$sub_dir")
                fi
            done
        fi
    done
    
    # Try to find MIDI devices too
    if [ -d "${card_dir}/midi" ]; then
        for midi_dir in "${card_dir}"/midi*; do
            if [ -d "$midi_dir" ]; then
                device_paths+=("$midi_dir")
            fi
        done
    fi
    
    # Try each device path
    for device_path in "${device_paths[@]}"; do
        if [ -d "$device_path" ]; then
            debug "Checking device path: $device_path"
            local dev_node
            dev_node=$(ls -l "$device_path" 2>/dev/null | grep -o "/dev/snd/[^ ]*" | head -1) || true
            
            if [ -n "$dev_node" ] && [ -e "$dev_node" ]; then
                info "Using device node: $dev_node"
                
                local udevadm_output
                udevadm_output=$(udevadm info -a -n "$dev_node" 2>/dev/null) || true
                
                if [ -n "$udevadm_output" ]; then
                    # Get USB device info from udevadm output
                    local new_bus_num
                    local new_dev_num
                    new_bus_num=$(printf '%s' "$udevadm_output" | grep "ATTR{busnum}" | head -n1 | grep -o "[0-9]*$") || true
                    new_dev_num=$(printf '%s' "$udevadm_output" | grep "ATTR{devnum}" | head -n1 | grep -o "[0-9]*$") || true
                    
                    if [ -n "$new_bus_num" ] && [ -n "$new_dev_num" ]; then
                        bus_num=$(safe_base10 "$new_bus_num") || bus_num=""
                        dev_num=$(safe_base10 "$new_dev_num") || dev_num=""
                        
                        if [ -n "$bus_num" ] && [ -n "$dev_num" ]; then
                            info "Found USB bus:device = $bus_num:$dev_num from device node"
                            
                            # Extract vendor and product ID if we don't have them
                            if [ -z "$vendor_id" ] || [ -z "$product_id" ]; then
                                local new_vendor
                                local new_product
                                new_vendor=$(printf '%s' "$udevadm_output" | grep "ATTR{idVendor}" | head -n1 | grep -o '"[^"]*"' | tr -d '"') || true
                                new_product=$(printf '%s' "$udevadm_output" | grep "ATTR{idProduct}" | head -n1 | grep -o '"[^"]*"' | tr -d '"') || true
                                
                                if [ -n "$new_vendor" ] && [ -n "$new_product" ]; then
                                    vendor_id="$new_vendor"
                                    product_id="$new_product"
                                    info "Found USB IDs from udevadm: vendor=$vendor_id, product=$product_id"
                                fi
                            fi
                            
                            # Try to get platform ID path
                            if [ -z "$platform_id_path" ]; then
                                platform_id_path=$(get_platform_id_path "$bus_num" "$dev_num" "$physical_port" "$card_num") || true
                                if [ -n "$platform_id_path" ]; then
                                    info "Found platform ID path: $platform_id_path"
                                fi
                            fi
                            
                            # Prioritize unique port identifier
                            local unique_port
                            unique_port=$(get_usb_physical_port "$bus_num" "$dev_num") || true
                            if [ -n "$unique_port" ]; then
                                info "USB unique physical port: $unique_port"
                                physical_port="$unique_port"
                            fi
                            
                            break
                        fi
                    fi
                fi
            fi
        fi
    done
    
    # Fallback: Try control device if nothing else worked
    if [ -z "$bus_num" ] && [ -z "$dev_num" ]; then
        info "Trying control device node as last resort..."
        
        local control_dev_node="/dev/snd/controlC${card_num}"
        if [ -e "$control_dev_node" ]; then
            debug "Checking control device node: $control_dev_node"
            
            local udevadm_output
            udevadm_output=$(udevadm info -a -n "$control_dev_node" 2>/dev/null) || true
            
            if [ -n "$udevadm_output" ]; then
                # Get USB device info from udevadm output
                local new_bus_num
                local new_dev_num
                new_bus_num=$(printf '%s' "$udevadm_output" | grep "ATTR{busnum}" | head -n1 | grep -o "[0-9]*$") || true
                new_dev_num=$(printf '%s' "$udevadm_output" | grep "ATTR{devnum}" | head -n1 | grep -o "[0-9]*$") || true
                
                if [ -n "$new_bus_num" ] && [ -n "$new_dev_num" ]; then
                    bus_num=$(safe_base10 "$new_bus_num") || bus_num=""
                    dev_num=$(safe_base10 "$new_dev_num") || dev_num=""
                    
                    if [ -n "$bus_num" ] && [ -n "$dev_num" ]; then
                        info "Found USB bus:device = $bus_num:$dev_num from control device node"
                        
                        # Extract vendor and product ID if we don't have them
                        if [ -z "$vendor_id" ] || [ -z "$product_id" ]; then
                            local new_vendor
                            local new_product
                            new_vendor=$(printf '%s' "$udevadm_output" | grep "ATTR{idVendor}" | head -n1 | grep -o '"[^"]*"' | tr -d '"') || true
                            new_product=$(printf '%s' "$udevadm_output" | grep "ATTR{idProduct}" | head -n1 | grep -o '"[^"]*"' | tr -d '"') || true
                            
                            if [ -n "$new_vendor" ] && [ -n "$new_product" ]; then
                                vendor_id="$new_vendor"
                                product_id="$new_product"
                                info "Found USB IDs from udevadm: vendor=$vendor_id, product=$product_id"
                            fi
                        fi
                        
                        # Try to get platform ID path
                        if [ -z "$platform_id_path" ]; then
                            platform_id_path=$(get_platform_id_path "$bus_num" "$dev_num" "$physical_port" "$card_num") || true
                            if [ -n "$platform_id_path" ]; then
                                info "Found platform ID path: $platform_id_path"
                            fi
                        fi
                        
                        # Prioritize unique port identifier
                        local unique_port
                        unique_port=$(get_usb_physical_port "$bus_num" "$dev_num") || true
                        if [ -n "$unique_port" ]; then
                            info "USB unique physical port: $unique_port"
                            physical_port="$unique_port"
                        fi
                    fi
                fi
            fi
        else
            debug "Control device node $control_dev_node does not exist"
        fi
    fi
    
    # Output the information we found
    if [ -n "$bus_num" ] || [ -n "$dev_num" ] || [ -n "$physical_port" ] || [ -n "$platform_id_path" ] || [ -n "$vendor_id" ] || [ -n "$product_id" ]; then
        printf 'USB Device Information for card %s:\n' "$card_num"
        [ -n "$bus_num" ] && printf '  Bus: %s\n' "$bus_num"
        [ -n "$dev_num" ] && printf '  Device: %s\n' "$dev_num"
        [ -n "$physical_port" ] && printf '  USB Path: %s\n' "$physical_port"
        [ -n "$platform_id_path" ] && printf '  Platform ID Path: %s\n' "$platform_id_path"
        [ -n "$vendor_id" ] && printf '  Vendor ID: %s\n' "$vendor_id"
        [ -n "$product_id" ] && printf '  Product ID: %s\n' "$product_id"
        printf '\n'
        
        # If we at least have usb path or bus and device, return success
        if [ -n "$physical_port" ] || ([ -n "$bus_num" ] && [ -n "$dev_num" ]); then
            return 0
        fi
    fi
    
    # Last resort - look for hardware info in proc filesystem
    if [ -f "/proc/asound/card${card_num}/id" ]; then
        local card_id
        card_id=$(cat "/proc/asound/card${card_num}/id" 2>/dev/null) || true
        info "Card ID: $card_id"
    fi
    
    warning "Could not get complete USB information for card $card_num."
    warning "Limited port detection might be available for this device."
    
    return 1
}

# Function to generate udev rules
generate_udev_rules() {
    local vendor_id="$1"
    local product_id="$2"
    local friendly_name="$3"
    local card_name="${4:-}"
    local simple_port="${5:-}"
    local platform_id_path="${6:-}"
    
    # Improved sanitization - exclude newlines and other special characters
    local safe_card_name
    safe_card_name=$(printf '%s' "$card_name" | tr -cd '[:alnum:] \t-_.' | tr -s ' ')
    
    local rules=""
    rules+="# USB Sound Card: ${safe_card_name:-$friendly_name}"$'\n'
    
    # Generate single comprehensive rule with all criteria
    local rules_content="SUBSYSTEM==\"sound\", ATTRS{idVendor}==\"$vendor_id\", ATTRS{idProduct}==\"$product_id\""
    
    # Only add valid port criteria to rules
    if [ -n "$platform_id_path" ]; then
        rules_content+=", ENV{ID_PATH}==\"$platform_id_path\""
    elif [ -n "$simple_port" ] && is_valid_usb_path "$simple_port"; then
        # Only add KERNELS if it's a valid USB path
        rules_content+=", KERNELS==\"$simple_port\""
    fi
    # If neither are valid, rule will match by vendor/product ID only
    
    rules_content+=", ATTR{id}=\"$friendly_name\", SYMLINK+=\"sound/by-id/$friendly_name\""
    
    rules+="$rules_content"$'\n'
    
    printf '%s' "$rules"
}

# Function to write rules atomically with deduplication
write_rules_atomic() {
    local rules_file="$1"
    shift
    local rules_content="$*"
    local friendly_name=""
    
    # Extract friendly_name from rules_content for deduplication
    if [[ "$rules_content" =~ ATTR\{id\}=\"([^\"]+)\" ]]; then
        friendly_name="${BASH_REMATCH[1]}"
    fi
    
    # Create temporary file
    local temp_file
    temp_file=$(mktemp /tmp/usb-soundcard-rules.XXXXXX) || error_exit "Failed to create temporary file"
    CLEANUP_FILES+=("$temp_file")
    
    # If rules file exists and we have a friendly_name, copy non-matching rules
    if [ -f "$rules_file" ] && [ -n "$friendly_name" ]; then
        # Use fixed-string grep for deduplication
        grep -Fv "ATTR{id}=\"$friendly_name\"" "$rules_file" > "$temp_file" 2>/dev/null || true
    elif [ -f "$rules_file" ]; then
        # If no friendly_name, copy entire file
        cp "$rules_file" "$temp_file" || error_exit "Failed to copy existing rules"
    fi
    
    # Append new rules
    printf '%s\n' "$rules_content" >> "$temp_file" || error_exit "Failed to write rules to temporary file"
    
    # Set proper permissions
    chmod 644 "$temp_file" || error_exit "Failed to set permissions on temporary file"
    
    # Atomically move to final location
    if ! mv -f "$temp_file" "$rules_file"; then
        error_exit "Failed to install rules file"
    fi
    
    # Safer array element removal (without set -e issues)
    local new_array=()
    for file in "${CLEANUP_FILES[@]}"; do
        if [ "$file" != "$temp_file" ]; then
            new_array+=("$file")
        fi
    done
    CLEANUP_FILES=("${new_array[@]}")
    
    success "Rules written successfully to $rules_file"
}

# Enhanced interactive mapping function
interactive_mapping() {
    printf '\033[1m===== USB Sound Card Mapper =====\033[0m\n' 
    printf 'This wizard will guide you through mapping your USB sound card to a consistent name.\n\n'
    
    # Get card information
    get_card_info
    
    # Let user select a card by number
    printf 'Enter the number of the sound card you want to map: '
    read -r card_num
    
    card_num=$(safe_base10 "$card_num") || error_exit "Invalid input. Please enter a number between 0 and 99."
    if [ "$card_num" -gt 99 ]; then
        error_exit "Invalid input. Please enter a number between 0 and 99."
    fi
    
    # Get the card information line
    local card_line
    card_line=$(grep -E "^ *$card_num " "$PROC_ASOUND_CARDS") || error_exit "No sound card found with number $card_num."
    
    # Extract card name
    local card_name
    card_name=$(printf '%s' "$card_line" | sed -n 's/.*\[\([^]]*\)\].*/\1/p' | xargs) || true
    if [ -z "$card_name" ]; then
        error_exit "Could not extract card name from line: $card_line"
    fi
    
    printf 'Selected card: %s - %s\n' "$card_num" "$card_name"
    
    # Extract card device info from proc/asound/cards - this is the most reliable approach
    local card_device_info=""
    # Look at full card information to get the full USB path
    local full_card_info
    full_card_info=$(cat "$PROC_ASOUND_CARDS" 2>/dev/null | grep -A1 "^ *$card_num ") || true
    
    if [[ "$full_card_info" =~ at\ (usb-[^ ,]+) ]]; then
        card_device_info="${BASH_REMATCH[1]}"
        info "Found actual USB path from card info: $card_device_info"
        
        # This is super important - the path format varies between distributions
        # Extract just the relevant part for broader matching
        if [[ "$card_device_info" =~ usb-([^,]+) ]]; then
            info "Extracted clean path: ${BASH_REMATCH[1]}"
        fi
    fi
    
    # Get platform ID path if available
    local platform_id_path=""
    
    # Try to get detailed card info including USB device path
    get_detailed_card_info "$card_num" || true
    
    # Capture lsusb once to avoid race condition
    printf '\nSelect the USB device that corresponds to this sound card:\n'
    local usb_devices=()
    while IFS= read -r line; do
        usb_devices+=("$line")
    done < <(lsusb)
    
    # Display from captured array
    local i
    for i in "${!usb_devices[@]}"; do
        printf '%2d. %s\n' "$((i+1))" "${usb_devices[i]}"
    done
    
    read -r usb_num
    
    usb_num=$(safe_base10 "$usb_num") || error_exit "Invalid input. Please enter a valid number."
    if [ "$usb_num" -lt 1 ] || [ "$usb_num" -gt "${#usb_devices[@]}" ]; then
        error_exit "Invalid input. Please enter a number between 1 and ${#usb_devices[@]}."
    fi
    
    # Get the USB device line from our captured array
    local usb_line="${usb_devices[$((usb_num-1))]}"
    if [ -z "$usb_line" ]; then
        error_exit "No USB device found at position $usb_num."
    fi
    
    # Extract vendor and product IDs
    local vendor_id=""
    local product_id=""
    if [[ "$usb_line" =~ ID\ ([0-9a-fA-F]{4}):([0-9a-fA-F]{4}) ]]; then
        vendor_id="${BASH_REMATCH[1]}"
        product_id="${BASH_REMATCH[2]}"
        # Convert IDs to lowercase for udev compatibility
        vendor_id="${vendor_id,,}"
        product_id="${product_id,,}"
    else
        error_exit "Could not extract vendor and product IDs from: $usb_line"
    fi
    
    # Extract bus and device numbers for port identification
    local physical_port=""
    local simple_port=""
    local bus_num=""
    local dev_num=""
    
    if [[ "$usb_line" =~ Bus\ ([0-9]{3})\ Device\ ([0-9]{3}) ]]; then
        bus_num="${BASH_REMATCH[1]}"
        dev_num="${BASH_REMATCH[2]}"
        bus_num=$(safe_base10 "$bus_num") || bus_num=""
        dev_num=$(safe_base10 "$dev_num") || dev_num=""
        
        if [ -n "$bus_num" ] && [ -n "$dev_num" ]; then
            printf 'Selected USB device: %s\n' "$usb_line"
            printf 'Vendor ID: %s\n' "$vendor_id"
            printf 'Product ID: %s\n' "$product_id"
            printf 'Bus: %s, Device: %s\n' "$bus_num" "$dev_num"
            
            # Try to get platform ID path
            platform_id_path=$(get_platform_id_path "$bus_num" "$dev_num" "$card_device_info" "$card_num") || true
            if [ -n "$platform_id_path" ]; then
                printf 'Platform ID path: %s\n' "$platform_id_path"
            fi
            
            # Get unique physical port path - always prioritize this
            physical_port=$(get_usb_physical_port "$bus_num" "$dev_num") || true
            if [ -n "$physical_port" ]; then
                printf 'USB unique physical port: %s\n' "$physical_port"
                simple_port="$physical_port"
            else
                # If card_device_info is available, use it as fallback
                if [ -n "$card_device_info" ]; then
                    physical_port="$card_device_info"
                    simple_port="$card_device_info"
                    printf 'Using USB path from card info: %s\n' "$physical_port"
                else
                    # Don't create invalid KERNELS values
                    warning "Could not determine physical USB port. Rule will match by vendor/product ID only."
                    physical_port=""
                    simple_port=""
                fi
            fi
        fi
    else
        warning "Could not extract bus and device numbers. Rule will match by vendor/product ID only."
        physical_port=""
        simple_port=""
    fi
    
    # Get friendly name from user
    printf '\nEnter a friendly name for the sound card (lowercase letters, numbers, and hyphens only):\n'
    read -r friendly_name
    
    # Validate and fix auto-generated names
    if [ -z "$friendly_name" ]; then
        friendly_name=$(printf '%s' "$card_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
        
        # Ensure name starts with letter
        if ! [[ "$friendly_name" =~ ^[a-z] ]]; then
            friendly_name="card-$friendly_name"
        fi
        
        # Truncate to 32 characters maximum
        friendly_name="${friendly_name:0:32}"
        
        info "Using default name: $friendly_name"
    fi
    
    if ! [[ "$friendly_name" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; then
        error_exit "Invalid friendly name. Must start with lowercase letter, max 32 chars, use only lowercase letters, numbers, and hyphens."
    fi
    
    # Check existing rules
    check_existing_rules
    
    # Create rule file
    mkdir -p /etc/udev/rules.d/
    
    printf 'Creating comprehensive mapping rules...\n'
    
    # Generate rules using extracted function
    local rules_content
    rules_content=$(generate_udev_rules "$vendor_id" "$product_id" "$friendly_name" "$card_name" "$simple_port" "$platform_id_path")
    
    # Write rules atomically
    write_rules_atomic "$RULES_FILE" "$rules_content"
    
    # Reload udev rules
    reload_udev_rules
    
    # Prompt for reboot
    prompt_reboot
    
    success "Sound card mapping created successfully."
}

# Non-interactive mapping function
non_interactive_mapping() {
    local device_name="$1"
    local vendor_id="$2"
    local product_id="$3"
    local port="$4"
    local friendly_name="$5"
    
    if [ -z "$device_name" ] || [ -z "$vendor_id" ] || [ -z "$product_id" ] || [ -z "$friendly_name" ]; then
        error_exit "Device name, vendor ID, product ID, and friendly name must be provided for non-interactive mode."
    fi
    
    # Validate and normalize vendor ID
    if ! [[ "$vendor_id" =~ ^[0-9a-fA-F]{4}$ ]]; then
        error_exit "Invalid vendor ID: $vendor_id. Must be exactly 4 hexadecimal digits."
    fi
    vendor_id="${vendor_id,,}"  # Convert to lowercase
    
    # Validate and normalize product ID
    if ! [[ "$product_id" =~ ^[0-9a-fA-F]{4}$ ]]; then
        error_exit "Invalid product ID: $product_id. Must be exactly 4 hexadecimal digits."
    fi
    product_id="${product_id,,}"  # Convert to lowercase
    
    # Validate friendly name
    if ! [[ "$friendly_name" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; then
        error_exit "Invalid friendly name: $friendly_name. Must start with lowercase letter, max 32 chars, use only lowercase letters, numbers, and hyphens."
    fi
    
    # Capture lsusb once at start to avoid race conditions
    local lsusb_output
    lsusb_output=$(lsusb 2>&1) || error_exit "Failed to run lsusb"
    
    # See if we can find the actual device in the system
    info "Looking for device in current system..."
    local found_card=""
    local card_device_info=""
    local simple_port=""
    local platform_id_path=""
    
    # Get sound card information
    if [ -f "$PROC_ASOUND_CARDS" ]; then
        while IFS= read -r line; do
            # Check if this could be our device based on name similarities
            if [[ "$line" =~ \[$device_name\]|\[.*$device_name.*\] ]]; then
                found_card="$line"
                info "Found potential matching card: $line"
                
                # Try to extract USB path
                if [[ "$line" =~ at\ (usb-[^ ,]+) ]]; then
                    card_device_info="${BASH_REMATCH[1]}"
                    info "Found actual USB path: $card_device_info"
                    
                    # Extract simplified port
                    if [[ "$card_device_info" =~ usb-([0-9]+\.[0-9]+) ]]; then
                        simple_port="usb-${BASH_REMATCH[1]}"
                    else
                        simple_port="$card_device_info"
                    fi
                    
                    # Try to extract card number
                    if [[ "$line" =~ ^\ *([0-9]+) ]]; then
                        local card_num="${BASH_REMATCH[1]}"
                        card_num=$(safe_base10 "$card_num") || card_num=""
                        if [ -n "$card_num" ]; then
                            info "Found card number: $card_num"
                            
                            # Try to get bus and device from detailed info
                            get_detailed_card_info "$card_num" || true
                        fi
                    fi
                fi
                break
            fi
        done < "$PROC_ASOUND_CARDS"
    fi
    
    # Handle port parameter properly
    if [ -n "$port" ]; then
        # Check if port is valid
        if is_valid_usb_path "$port"; then
            card_device_info="$port"
            simple_port="$port"
            info "Using provided port path: $simple_port"
        else
            warning "Provided USB port path '$port' appears invalid. Ignoring port parameter."
            port=""  # Clear invalid port
            card_device_info=""
            simple_port=""
        fi
    fi
    
    # Try to find the device in captured lsusb output to get bus and device number
    local bus_num=""
    local dev_num=""
    if [[ "$lsusb_output" =~ Bus\ ([0-9]{3})\ Device\ ([0-9]{3}):\ ID\ $vendor_id:$product_id ]]; then
        bus_num=$(safe_base10 "${BASH_REMATCH[1]}") || bus_num=""
        dev_num=$(safe_base10 "${BASH_REMATCH[2]}") || dev_num=""
        
        if [ -n "$bus_num" ] && [ -n "$dev_num" ]; then
            info "Found device in lsusb: bus=$bus_num, dev=$dev_num"
            
            # Try to get platform ID path
            platform_id_path=$(get_platform_id_path "$bus_num" "$dev_num" "$simple_port" "") || true
            if [ -n "$platform_id_path" ]; then
                info "Found platform ID path: $platform_id_path"
            fi
            
            # Get unique port identifier
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
    
    # Create the rule
    info "Creating rule for $device_name..."
    
    mkdir -p /etc/udev/rules.d/
    
    # Generate rules using extracted function
    local rules_content
    rules_content=$(generate_udev_rules "$vendor_id" "$product_id" "$friendly_name" "$device_name" "$simple_port" "$platform_id_path")
    
    # Write rules atomically
    write_rules_atomic "$RULES_FILE" "$rules_content"
    
    # Reload udev rules
    reload_udev_rules
    
    success "Sound card mapping created successfully."
    info "Remember to reboot for changes to take effect."
}

# Display help with enhanced options
show_help() {
    cat << EOF
USB Sound Card Mapper V1.2.0 - Create persistent names for USB sound devices
Part of LyreBirdAudio - RTSP Audio Streaming Suite

Usage: $0 [options]
Options:
  -i, --interactive       Run in interactive mode (default)
  -n, --non-interactive   Run in non-interactive mode (requires all other parameters)
  -d, --device NAME       Device name (for logging only)
  -v, --vendor ID         Vendor ID (4-digit hex)
  -p, --product ID        Product ID (4-digit hex)
  -u, --usb-port PORT     USB port path (recommended for multiple identical devices)
  -f, --friendly NAME     Friendly name to assign
  -t, --test              Test USB port detection on current system
  -D, --debug             Enable debug output
  -h, --help              Show this help

Examples:
  $0                      Run in interactive mode
  $0 -n -d "MOVO X1 MINI" -v 2e88 -p 4610 -f movo-x1-mini
  $0 -n -d "MOVO X1 MINI" -v 2e88 -p 4610 -u "usb-3.4" -f movo-x1-mini
  $0 -t                   Test USB port detection capabilities
EOF
    exit 0
}

# Main function with enhanced options
main() {
    # Check dependencies first
    check_dependencies
    
    # Set DEBUG to false by default
    DEBUG="${DEBUG:-$DEFAULT_DEBUG}"
    
    # Parse command line arguments and check for test mode
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
    
    check_root
    
    # Parse command line arguments
    if [ $# -eq 0 ]; then
        interactive_mapping
        exit 0
    fi
    
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
                [ -z "${2:-}" ] && error_exit "Option '$1' requires an argument"
                device_name="$2"
                shift 2
                ;;
            -v|--vendor)
                [ -z "${2:-}" ] && error_exit "Option '$1' requires an argument"
                vendor_id="$2"
                shift 2
                ;;
            -p|--product)
                [ -z "${2:-}" ] && error_exit "Option '$1' requires an argument"
                product_id="$2"
                shift 2
                ;;
            -u|--usb-port)
                [ -z "${2:-}" ] && error_exit "Option '$1' requires an argument"
                port="$2"
                shift 2
                ;;
            -f|--friendly)
                [ -z "${2:-}" ] && error_exit "Option '$1' requires an argument"
                friendly_name="$2"
                shift 2
                ;;
            -t|--test)
                # Already handled above
                shift
                ;;
            -D|--debug)
                # Already handled above
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
    
    if [ "$mode" = "interactive" ]; then
        interactive_mapping
    else
        non_interactive_mapping "$device_name" "$vendor_id" "$product_id" "$port" "$friendly_name"
    fi
}

# Run the main function
main "$@"

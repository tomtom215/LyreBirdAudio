#!/bin/bash
# usb-soundcard-mapper.sh - Automatically map USB sound cards to persistent names
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# This script creates udev rules for USB sound cards to ensure they maintain 
# consistent names across reboots, with symlinks for easy access.
#
# Version: 1.0.0
# Changes: Added error checking, atomic file operations, dependency checks

# Set bash strict mode for better error handling
set -o pipefail

# Global variables
DEBUG="${DEBUG:-false}"
TEMP_DIR=""
CLEANUP_FILES=()

# Signal handler for cleanup
cleanup() {
    local exit_code=$?
    # Remove any temporary files
    for file in "${CLEANUP_FILES[@]}"; do
        [ -f "$file" ] && rm -f "$file" 2>/dev/null
    done
    [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ] && rmdir "$TEMP_DIR" 2>/dev/null
    exit $exit_code
}

# Set up signal handlers
trap cleanup EXIT INT TERM

# Function to print error messages and exit
error_exit() {
    echo -e "\e[31mERROR: $1\e[0m" >&2
    exit 1
}

# Function to print information messages
info() {
    echo -e "\e[34mINFO: $1\e[0m"
}

# Function to print success messages
success() {
    echo -e "\e[32mSUCCESS: $1\e[0m"
}

# Function to print warning messages
warning() {
    echo -e "\e[33mWARNING: $1\e[0m" >&2
}

# Function to print debug messages if debug mode is enabled
debug() {
    if [ "$DEBUG" = "true" ]; then
        echo -e "\e[35mDEBUG: $1\e[0m" >&2
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
    if ! lsusb_output=$(lsusb 2>&1); then
        error_exit "Failed to run lsusb command: $lsusb_output"
    fi
    
    echo "USB devices:"
    echo "$lsusb_output"
    echo
    
    # Get sound card information
    info "Getting sound card information..."
    local cards_file="/proc/asound/cards"
    if [ ! -f "$cards_file" ]; then
        error_exit "Cannot access $cards_file. Is ALSA installed properly?"
    fi
    
    local cards_output
    if ! cards_output=$(cat "$cards_file" 2>&1); then
        error_exit "Failed to read $cards_file: $cards_output"
    fi
    
    echo "Sound cards:"
    echo "$cards_output"
    echo
    
    # Extract and display detailed card paths if available
    echo "Card USB paths:"
    while IFS= read -r line; do
        if [[ "$line" =~ at\ (usb-[^ ,]+) ]]; then
            local card_path="${BASH_REMATCH[1]}"
            echo "  $line"
            echo "  Path: $card_path"
        fi
    done <<< "$cards_output"
    echo
    
    # Display aplay output for reference
    if command -v aplay &> /dev/null; then
        local aplay_output
        aplay_output=$(aplay -l 2>/dev/null) || true
        if [ -n "$aplay_output" ]; then
            echo "ALSA playback devices:"
            echo "$aplay_output"
            echo
        fi
    fi
}

# Function to check existing udev rules
check_existing_rules() {
    info "Checking existing udev rules..."
    
    local rules_file="/etc/udev/rules.d/99-usb-soundcards.rules"
    
    if [ -f "$rules_file" ]; then
        echo "Existing rules in $rules_file:"
        cat "$rules_file" || warning "Could not read existing rules file"
        echo
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
    echo "A reboot is recommended for the changes to take effect."
    read -p "Do you want to reboot now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        info "Rebooting system..."
        reboot
    else
        info "Remember to reboot later for changes to take effect."
    fi
}

# Function to check if a string is valid USB path
is_valid_usb_path() {
    local path="$1"
    
    # Basic validation - check if it's not empty and contains usb
    if [ -z "$path" ]; then
        return 1
    fi
    
    # Check if path contains expected USB path components
    if [[ "$path" == *"usb"* ]] && [[ "$path" == *":"* ]]; then
        return 0
    else
        return 1
    fi
}

# Function to get USB physical port path for a device
get_usb_physical_port() {
    local bus_num="$1"
    local dev_num="$2"
    
    # Validate inputs
    if [ -z "$bus_num" ] || [ -z "$dev_num" ]; then
        debug "Missing bus or device number for port detection"
        return 1
    fi
    
    # Use sysfs directly - this is the most reliable method across distributions
    
    # Method 1: Get the device path from sysfs
    local sysfs_path="/sys/bus/usb/devices/${bus_num}-${dev_num}"
    if [ ! -d "$sysfs_path" ]; then
        # Try alternate format 
        sysfs_path="/sys/bus/usb/devices/${bus_num}-${bus_num}.${dev_num}"
        if [ ! -d "$sysfs_path" ]; then
            # Try finding it through a search
            local possible_path
            possible_path=$(find /sys/bus/usb/devices -maxdepth 1 -name "${bus_num}-*" 2>/dev/null | grep -m1 "") || true
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
    local uniqueness=""
    
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
        for device in "$devices_dir"/*; do
            if [ -f "$device/busnum" ] && [ -f "$device/devnum" ]; then
                local dev_busnum
                local dev_devnum
                dev_busnum=$(cat "$device/busnum" 2>/dev/null) || continue
                dev_devnum=$(cat "$device/devnum" 2>/dev/null) || continue
                
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
                serial=$(echo "$udevadm_props" | grep -m1 "ID_SERIAL=" | cut -d= -f2) || true
                debug "Found serial from udevadm: $serial"
            fi
            
            # Try to get product name if we don't have it
            if [ -z "$product_name" ] && [ -n "$udevadm_props" ]; then
                product_name=$(echo "$udevadm_props" | grep -m1 "ID_MODEL=" | cut -d= -f2) || true
                debug "Found product name from udevadm: $product_name"
            fi
            
            # Look for DEVPATH
            local devpath_from_udev=""
            if [ -n "$udevadm_props" ]; then
                devpath_from_udev=$(echo "$udevadm_props" | grep -m1 "DEVPATH=" | cut -d= -f2) || true
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
    uniqueness="$base_port_path"
    
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
        # If no serial number, create a hash based on bus/dev and product info
        local hash_input="bus${bus_num}dev${dev_num}"
        # Add product name if available
        [ -n "$product_name" ] && hash_input="${hash_input}${product_name}"
        # Add current timestamp to ensure uniqueness
        hash_input="${hash_input}$(date +%s%N)"
        # Create a 8-char hash
        uuid_fragment=$(echo "$hash_input" | md5sum | head -c 8) || uuid_fragment="fallback"
    fi
    
    # Append uuid fragment to ensure uniqueness
    echo "${uniqueness}-${uuid_fragment}"
    return 0
}

# Function to get platform path for ID_PATH rule
get_platform_id_path() {
    local bus_num="$1"
    local dev_num="$2"
    local usb_path="$3"
    local card_num="$4"
    
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
            id_path=$(echo "$udevadm_output" | grep -m1 "ID_PATH=" | cut -d= -f2) || true
        fi
        
        if [ -n "$id_path" ]; then
            debug "Found ID_PATH from udevadm: $id_path"
            echo "$id_path"
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
                id_path=$(echo "$card_udevadm_output" | grep -m1 "ID_PATH=" | cut -d= -f2) || true
            fi
            
            if [ -n "$id_path" ]; then
                debug "Found ID_PATH from sound card device: $id_path"
                echo "$id_path"
                return 0
            fi
        fi
    fi
    
    # Reconstruct platform path from USB path if we have it
    if [ -n "$usb_path" ]; then
        # Extract the port numbers from usb-X.Y format
        if [[ "$usb_path" =~ usb-([0-9]+\.[0-9]+) ]]; then
            local port_nums="${BASH_REMATCH[1]}"
            
            # Look for platform identifiers in sysfs paths
            for platform_path in /sys/bus/usb/devices/usb*; do
                if [ -d "$platform_path" ]; then
                    local parent_dir
                    parent_dir=$(dirname "$platform_path" 2>/dev/null) || continue
                    local platform_id
                    platform_id=$(basename "$parent_dir" 2>/dev/null) || continue
                    if [[ "$platform_id" == *"usb"* ]]; then
                        # Construct a platform-style path
                        echo "platform-${platform_id}-usb-0:${port_nums}:1.0"
                        return 0
                    fi
                fi
            done
            
            # Fallback: Check all USB controller devices
            for platform_dev in /sys/bus/platform/devices/*.usb; do
                if [ -d "$platform_dev" ]; then
                    local platform_id
                    platform_id=$(basename "$platform_dev")
                    # Construct a platform-style path
                    echo "platform-${platform_id}-usb-0:${port_nums}:1.0"
                    return 0
                fi
            done
        fi
    fi
    
    # If we still can't get it, return empty
    return 1
}

# Function to test USB port detection
test_usb_port_detection() {
    info "Testing USB port detection..."
    
    # Get all USB devices
    local usb_devices
    if ! usb_devices=$(lsusb 2>&1); then
        warning "Failed to get USB devices: $usb_devices"
        return 1
    fi
    
    if [ -z "$usb_devices" ]; then
        warning "No USB devices found during test."
        return 1
    fi
    
    echo "Found USB devices:"
    echo "$usb_devices"
    echo
    
    # Show debug info for the first device to help troubleshoot
    if [[ "$usb_devices" =~ Bus\ ([0-9]{3})\ Device\ ([0-9]{3}) ]]; then
        local bus_num="${BASH_REMATCH[1]}"
        local dev_num="${BASH_REMATCH[2]}"
        
        # Remove leading zeros
        bus_num=$(echo "$bus_num" | sed 's/^0*//')
        dev_num=$(echo "$dev_num" | sed 's/^0*//')
        
        echo "Detailed information for first device (Bus $bus_num Device $dev_num):"
        
        # Show USB sysfs paths for debugging
        echo "Checking for USB device in sysfs:"
        echo "1. Standard path: /sys/bus/usb/devices/${bus_num}-${dev_num}"
        [ -d "/sys/bus/usb/devices/${bus_num}-${dev_num}" ] && echo "   - Path exists" || echo "   - Path does not exist"
        
        echo "2. Alternate path: /sys/bus/usb/devices/${bus_num}-${bus_num}.${dev_num}"
        [ -d "/sys/bus/usb/devices/${bus_num}-${bus_num}.${dev_num}" ] && echo "   - Path exists" || echo "   - Path does not exist"
        
        echo "3. Search results:"
        find /sys/bus/usb/devices -maxdepth 1 -name "${bus_num}-*" 2>/dev/null | head -n 3 || true
        
        # Check for devpath attribute
        local found_devpath=""
        for potential_path in "/sys/bus/usb/devices/${bus_num}-${dev_num}" "/sys/bus/usb/devices/${bus_num}-${bus_num}.${dev_num}" $(find /sys/bus/usb/devices -maxdepth 1 -name "${bus_num}-*" 2>/dev/null | head -n 1); do
            if [ -f "$potential_path/devpath" ]; then
                found_devpath=$(cat "$potential_path/devpath" 2>/dev/null) || true
                echo "4. Found devpath attribute at $potential_path/devpath: $found_devpath"
                break
            fi
        done
        
        if [ -z "$found_devpath" ]; then
            echo "4. No devpath attribute found in any potential path"
        fi
        
        # Show udevadm info
        echo "5. udevadm information:"
        local bus_num_padded
        local dev_num_padded
        bus_num_padded=$(printf "%03d" "$bus_num")
        dev_num_padded=$(printf "%03d" "$dev_num")
        local dev_path_test="/dev/bus/usb/${bus_num_padded}/${dev_num_padded}"
        
        if [ -e "$dev_path_test" ]; then
            local dev_path_info
            dev_path_info=$(udevadm info -q path -n "$dev_path_test" 2>/dev/null) || true
            if [ -n "$dev_path_info" ]; then
                echo "   - Device path: $dev_path_info"
                echo "   - First 5 lines of udevadm property info:"
                udevadm info -n "$dev_path_test" --query=property 2>/dev/null | head -n 5 || true
            else
                echo "   - Could not get udevadm device path"
            fi
        else
            echo "   - Device node $dev_path_test does not exist"
        fi
        
        echo
    fi
    
    # Continue with regular testing
    local success_count=0
    local total_count=0
    
    # Process each USB device
    while read -r line; do
        if [[ "$line" =~ Bus\ ([0-9]{3})\ Device\ ([0-9]{3}) ]]; then
            local bus_num="${BASH_REMATCH[1]}"
            local dev_num="${BASH_REMATCH[2]}"
            
            # Remove leading zeros
            bus_num=$(echo "$bus_num" | sed 's/^0*//')
            dev_num=$(echo "$dev_num" | sed 's/^0*//')
            
            total_count=$((total_count + 1))
            
            # Enable debug for the test function
            local old_debug="$DEBUG"
            DEBUG="false"  # Disable verbose debug output during tests to keep output clean
            
            # Try to get port info
            local port_path
            port_path=$(get_usb_physical_port "$bus_num" "$dev_num")
            local result=$?
            
            # Try to get platform ID path
            local platform_path
            platform_path=$(get_platform_id_path "$bus_num" "$dev_num" "$port_path" "") || true
            
            # Restore debug setting
            DEBUG="${old_debug:-false}"
            
            if [ $result -eq 0 ] && [ -n "$port_path" ]; then
                echo "Device on Bus $bus_num Device $dev_num:"
                echo "  USB Port path = $port_path"
                if [ -n "$platform_path" ]; then
                    echo "  Platform ID_PATH = $platform_path"
                fi
                success_count=$((success_count + 1))
            else
                echo "Device on Bus $bus_num Device $dev_num: Could not determine port path"
            fi
        fi
    done <<< "$usb_devices"
    
    echo
    echo "Port detection test results: $success_count of $total_count devices mapped successfully."
    
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
    if ! [[ "$card_num" =~ ^[0-9]+$ ]] || [ "$card_num" -gt 99 ]; then
        error_exit "Invalid card number: $card_num. Must be 0-99."
    fi
    
    # Get card directory path
    local card_dir="/proc/asound/card${card_num}"
    if [ ! -d "$card_dir" ]; then
        error_exit "Cannot find directory $card_dir. Card $card_num does not exist."
    fi
    
    # Check if it's a USB device
    if [ ! -d "${card_dir}/usbbus" ] && [ ! -d "${card_dir}/usbid" ] && [ ! -f "${card_dir}/usbid" ]; then
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
        info "Found USB bus from card directory: $bus_num"
    fi
    
    if [ -f "${card_dir}/usbdev" ]; then
        dev_num=$(cat "${card_dir}/usbdev" 2>/dev/null) || true
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
    if ! cards_output=$(cat "/proc/asound/cards" 2>&1); then
        warning "Could not read cards file"
    else
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
    fi
    
    # If we have both bus and device number, try to get additional information
    if [ -n "$bus_num" ] && [ -n "$dev_num" ]; then
        info "Using direct ALSA info: bus=$bus_num, device=$dev_num"
        
        # Try to get platform ID path
        platform_id_path=$(get_platform_id_path "$bus_num" "$dev_num" "$physical_port" "$card_num") || true
        if [ -n "$platform_id_path" ]; then
            info "Found platform ID path: $platform_id_path"
        fi
        
        # Only get the physical port if we don't already have it from cards file
        if [ -z "$physical_port" ]; then
            physical_port=$(get_usb_physical_port "$bus_num" "$dev_num") || true
            if [ -n "$physical_port" ]; then
                info "USB physical port: $physical_port"
            fi
        fi
        
        echo "USB Device Information for card $card_num:"
        echo "  Bus: $bus_num"
        echo "  Device: $dev_num"
        [ -n "$physical_port" ] && echo "  USB Path: $physical_port"
        [ -n "$platform_id_path" ] && echo "  Platform ID Path: $platform_id_path"
        [ -n "$vendor_id" ] && echo "  Vendor ID: $vendor_id"
        [ -n "$product_id" ] && echo "  Product ID: $product_id"
        echo
        
        return 0
    fi
    
    # If we have the USB path from the cards file but not bus/dev, that's still success
    if [ -n "$physical_port" ]; then
        echo "USB Device Information for card $card_num:"
        [ -n "$physical_port" ] && echo "  USB Path: $physical_port"
        [ -n "$vendor_id" ] && echo "  Vendor ID: $vendor_id"
        [ -n "$product_id" ] && echo "  Product ID: $product_id"
        echo
        
        return 0
    fi
    
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
            
            if [ -n "$dev_node" ]; then
                info "Using device node: $dev_node"
                
                if [ -e "$dev_node" ]; then
                    local udevadm_output
                    udevadm_output=$(udevadm info -a -n "$dev_node" 2>/dev/null) || true
                    
                    if [ -n "$udevadm_output" ]; then
                        # Get USB device info from udevadm output
                        local new_bus_num
                        local new_dev_num
                        new_bus_num=$(echo "$udevadm_output" | grep -m1 "ATTR{busnum}" | grep -o "[0-9]*$") || true
                        new_dev_num=$(echo "$udevadm_output" | grep -m1 "ATTR{devnum}" | grep -o "[0-9]*$") || true
                        
                        if [ -n "$new_bus_num" ] && [ -n "$new_dev_num" ]; then
                            bus_num="$new_bus_num"
                            dev_num="$new_dev_num"
                            info "Found USB bus:device = $bus_num:$dev_num from device node"
                            
                            # Extract vendor and product ID if we don't have them
                            if [ -z "$vendor_id" ] || [ -z "$product_id" ]; then
                                local new_vendor
                                local new_product
                                new_vendor=$(echo "$udevadm_output" | grep -m1 "ATTR{idVendor}" | grep -o '"[^"]*"' | tr -d '"') || true
                                new_product=$(echo "$udevadm_output" | grep -m1 "ATTR{idProduct}" | grep -o '"[^"]*"' | tr -d '"') || true
                                
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
                            
                            # Try to get physical port again with the new bus/dev
                            if [ -z "$physical_port" ]; then
                                physical_port=$(get_usb_physical_port "$bus_num" "$dev_num") || true
                                if [ -n "$physical_port" ]; then
                                    info "USB physical port: $physical_port"
                                fi
                            fi
                            break
                        fi
                    fi
                else
                    debug "Device node $dev_node does not exist"
                fi
            fi
        fi
    done
    
    # Output the information we found
    if [ -n "$bus_num" ] || [ -n "$dev_num" ] || [ -n "$physical_port" ] || [ -n "$platform_id_path" ] || [ -n "$vendor_id" ] || [ -n "$product_id" ]; then
        echo "USB Device Information for card $card_num:"
        [ -n "$bus_num" ] && echo "  Bus: $bus_num"
        [ -n "$dev_num" ] && echo "  Device: $dev_num"
        [ -n "$physical_port" ] && echo "  USB Path: $physical_port"
        [ -n "$platform_id_path" ] && echo "  Platform ID Path: $platform_id_path"
        [ -n "$vendor_id" ] && echo "  Vendor ID: $vendor_id"
        [ -n "$product_id" ] && echo "  Product ID: $product_id"
        echo
        
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

# Function to write rules atomically
write_rules_atomic() {
    local rules_file="$1"
    shift
    local rules_content="$*"
    
    # Create temporary file
    local temp_file
    temp_file=$(mktemp /tmp/usb-soundcard-rules.XXXXXX) || error_exit "Failed to create temporary file"
    CLEANUP_FILES+=("$temp_file")
    
    # If rules file exists, copy existing content
    if [ -f "$rules_file" ]; then
        if ! cp "$rules_file" "$temp_file"; then
            error_exit "Failed to copy existing rules to temporary file"
        fi
    fi
    
    # Append new rules
    echo "$rules_content" >> "$temp_file" || error_exit "Failed to write rules to temporary file"
    
    # Set proper permissions
    chmod 644 "$temp_file" || error_exit "Failed to set permissions on temporary file"
    
    # Atomically move to final location
    if ! mv -f "$temp_file" "$rules_file"; then
        error_exit "Failed to install rules file"
    fi
    
    # Remove from cleanup list since it was successfully moved
    unset 'CLEANUP_FILES[-1]'
    
    success "Rules written successfully to $rules_file"
}

# Enhanced interactive mapping function
interactive_mapping() {
    echo -e "\e[1m===== USB Sound Card Mapper =====\e[0m"
    echo "This wizard will guide you through mapping your USB sound card to a consistent name."
    echo
    
    # Get card information
    get_card_info
    
    # Let user select a card by number
    echo "Enter the number of the sound card you want to map:"
    read -r card_num
    
    if ! [[ "$card_num" =~ ^[0-9]+$ ]] || [ "$card_num" -gt 99 ]; then
        error_exit "Invalid input. Please enter a number between 0 and 99."
    fi
    
    # Get the card information line
    local card_line
    card_line=$(grep -E "^ *$card_num " /proc/asound/cards) || error_exit "No sound card found with number $card_num."
    
    # Extract card name
    local card_name
    card_name=$(echo "$card_line" | sed -n 's/.*\[\([^]]*\)\].*/\1/p' | xargs) || true
    if [ -z "$card_name" ]; then
        error_exit "Could not extract card name from line: $card_line"
    fi
    
    echo "Selected card: $card_num - $card_name"
    
    # Extract card device info from proc/asound/cards - this is the most reliable approach
    local card_device_info=""
    # Look at full card information to get the full USB path
    local full_card_info
    full_card_info=$(cat /proc/asound/cards 2>/dev/null | grep -A1 "^ *$card_num ") || true
    
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
    
    # Let user select USB device
    echo
    echo "Select the USB device that corresponds to this sound card:"
    local usb_list
    if ! usb_list=$(lsusb | nl -w2 -s". "); then
        error_exit "Failed to list USB devices"
    fi
    echo "$usb_list"
    read -r usb_num
    
    if ! [[ "$usb_num" =~ ^[0-9]+$ ]]; then
        error_exit "Invalid input. Please enter a number."
    fi
    
    # Get the USB device line
    local usb_line
    usb_line=$(lsusb | sed -n "${usb_num}p") || true
    if [ -z "$usb_line" ]; then
        error_exit "No USB device found at position $usb_num."
    fi
    
    # Extract vendor and product IDs
    local vendor_id=""
    local product_id=""
    if [[ "$usb_line" =~ ID\ ([0-9a-f]{4}):([0-9a-f]{4}) ]]; then
        vendor_id="${BASH_REMATCH[1]}"
        product_id="${BASH_REMATCH[2]}"
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
        # Remove leading zeros
        bus_num=$(echo "$bus_num" | sed 's/^0*//')
        dev_num=$(echo "$dev_num" | sed 's/^0*//')
        
        echo "Selected USB device: $usb_line"
        echo "Vendor ID: $vendor_id"
        echo "Product ID: $product_id"
        echo "Bus: $bus_num, Device: $dev_num"
        
        # Try to get platform ID path
        platform_id_path=$(get_platform_id_path "$bus_num" "$dev_num" "$card_device_info" "$card_num") || true
        if [ -n "$platform_id_path" ]; then
            echo "Platform ID path: $platform_id_path"
        fi
        
        # Get physical port path - but prefer the one from card info if available
        if [ -z "$card_device_info" ]; then
            physical_port=$(get_usb_physical_port "$bus_num" "$dev_num") || true
            if [ -n "$physical_port" ]; then
                echo "USB physical port: $physical_port"
                
                # Extract simplified port
                if [[ "$physical_port" =~ ([0-9]+-[0-9]+(\.[0-9]+)*) ]]; then
                    simple_port="${BASH_REMATCH[1]}"
                elif [[ "$physical_port" =~ usb-([0-9]+\.[0-9]+) ]]; then
                    simple_port="usb-${BASH_REMATCH[1]}"
                else
                    simple_port="$physical_port"
                fi
            else
                warning "Could not determine physical USB port. Using device ID only for mapping."
                
                # Always create a unique identifier even without port detection
                physical_port="usb-fallback-bus${bus_num}-dev${dev_num}-${RANDOM}"
                simple_port="$physical_port"
                echo "Created fallback identifier: $physical_port"
                
                # Ask if user wants to continue with this fallback
                echo
                echo "A fallback identifier has been created for your device."
                read -p "Continue with this identifier? (y/n): " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    error_exit "Mapping canceled."
                fi
            fi
        else
            # Use the path from card info instead - this is more reliable!
            physical_port="$card_device_info"
            
            # Extract simplified port
            if [[ "$card_device_info" =~ usb-([0-9]+\.[0-9]+) ]]; then
                simple_port="usb-${BASH_REMATCH[1]}"
            else
                simple_port="$card_device_info"
            fi
            
            echo "Using USB path from card info: $physical_port"
        fi
    else
        warning "Could not extract bus and device numbers. This may affect rule creation."
        # Create a fallback unique identifier
        physical_port="usb-fallback-${RANDOM}-${RANDOM}"
        simple_port="$physical_port"
        echo "Created emergency fallback identifier: $physical_port"
    fi
    
    # Get friendly name from user
    echo
    echo "Enter a friendly name for the sound card (lowercase letters, numbers, and hyphens only):"
    read -r friendly_name
    
    if [ -z "$friendly_name" ]; then
        friendly_name=$(echo "$card_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
        info "Using default name: $friendly_name"
    fi
    
    if ! [[ "$friendly_name" =~ ^[a-z][a-z0-9-]{0,31}$ ]]; then
        error_exit "Invalid friendly name. Must start with lowercase letter, max 32 chars, use only lowercase letters, numbers, and hyphens."
    fi
    
    # Check existing rules
    check_existing_rules
    
    # Create rule file
    local rules_file="/etc/udev/rules.d/99-usb-soundcards.rules"
    mkdir -p /etc/udev/rules.d/
    
    # Sanitize card name for comments
    local safe_card_name
    safe_card_name=$(echo "$card_name" | tr -cd '[:alnum:][:space:]-_.')
    
    # Create comprehensive rule set
    echo "Creating comprehensive mapping rules..."
    
    # Build rules content
    local rules_content=""
    rules_content+="# USB Sound Card: $safe_card_name"$'\n'
    rules_content+="SUBSYSTEM==\"sound\", ATTRS{idVendor}==\"$vendor_id\", ATTRS{idProduct}==\"$product_id\", SYMLINK+=\"sound/by-id/$friendly_name\", ATTR{id}=\"$friendly_name\""$'\n'
    
    # Write the rule with device path if available
    if [ -n "$simple_port" ]; then
        rules_content+="# Alternative rule with device path"$'\n'
        rules_content+="SUBSYSTEM==\"sound\", KERNELS==\"$simple_port\", ATTRS{idVendor}==\"$vendor_id\", ATTRS{idProduct}==\"$product_id\", SYMLINK+=\"sound/by-id/$friendly_name\", ATTR{id}=\"$friendly_name\""$'\n'
    fi
    
    # Write the rule with platform ID_PATH if available
    if [ -n "$platform_id_path" ]; then
        rules_content+="# Another alternative without wildcards"$'\n'
        rules_content+="SUBSYSTEM==\"sound\", ENV{ID_PATH}==\"$platform_id_path\", ATTRS{idVendor}==\"$vendor_id\", ATTRS{idProduct}==\"$product_id\", SYMLINK+=\"sound/by-id/$friendly_name\", ATTR{id}=\"$friendly_name\""$'\n'
    fi
    
    # Write rules atomically
    write_rules_atomic "$rules_file" "$rules_content"
    
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
    
    # See if we can find the actual device in the system
    info "Looking for device in current system..."
    local found_card=""
    local card_device_info=""
    local simple_port=""
    local platform_id_path=""
    
    # Get sound card information
    local cards_file="/proc/asound/cards"
    if [ -f "$cards_file" ]; then
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
                        info "Found card number: $card_num"
                        
                        # Try to get bus and device from detailed info
                        get_detailed_card_info "$card_num" || true
                    fi
                fi
                break
            fi
        done < "$cards_file"
    fi
    
    # If port was provided, use it or extract a simplified port pattern
    if [ -n "$port" ]; then
        # Check if port is valid
        if is_valid_usb_path "$port"; then
            card_device_info="$port"
            
            # Extract simplified port pattern for better matching
            if [[ "$port" =~ usb-([0-9]+\.[0-9]+) ]]; then
                simple_port="usb-${BASH_REMATCH[1]}"
                info "Extracted simple port pattern from provided port: $simple_port"
            else
                simple_port="$port"
                info "Using provided port as pattern: $simple_port"
            fi
        else
            warning "Provided USB port path '$port' appears invalid. Looking for alternatives."
        fi
    fi
    
    # Try to find the device in lsusb to get bus and device number
    local bus_num=""
    local dev_num=""
    local lsusb_output
    if lsusb_output=$(lsusb 2>&1); then
        if [[ "$lsusb_output" =~ Bus\ ([0-9]{3})\ Device\ ([0-9]{3}):\ ID\ $vendor_id:$product_id ]]; then
            bus_num=$(echo "${BASH_REMATCH[1]}" | sed 's/^0*//')
            dev_num=$(echo "${BASH_REMATCH[2]}" | sed 's/^0*//')
            info "Found device in lsusb: bus=$bus_num, dev=$dev_num"
            
            # Try to get platform ID path
            platform_id_path=$(get_platform_id_path "$bus_num" "$dev_num" "$simple_port" "") || true
            if [ -n "$platform_id_path" ]; then
                info "Found platform ID path: $platform_id_path"
            fi
        fi
    fi
    
    # Sanitize device name for comments
    local safe_device_name
    safe_device_name=$(echo "$device_name" | tr -cd '[:alnum:][:space:]-_.')
    
    # Create the rule
    info "Creating rule for $device_name..."
    
    local rules_file="/etc/udev/rules.d/99-usb-soundcards.rules"
    mkdir -p /etc/udev/rules.d/
    
    # Build rules content
    local rules_content=""
    rules_content+="# USB Sound Card: $safe_device_name"$'\n'
    rules_content+="SUBSYSTEM==\"sound\", ATTRS{idVendor}==\"$vendor_id\", ATTRS{idProduct}==\"$product_id\", SYMLINK+=\"sound/by-id/$friendly_name\", ATTR{id}=\"$friendly_name\""$'\n'
    
    # Rule with port path if available
    if [ -n "$simple_port" ]; then
        rules_content+="# Alternative rule with device path"$'\n'
        rules_content+="SUBSYSTEM==\"sound\", KERNELS==\"$simple_port\", ATTRS{idVendor}==\"$vendor_id\", ATTRS{idProduct}==\"$product_id\", SYMLINK+=\"sound/by-id/$friendly_name\", ATTR{id}=\"$friendly_name\""$'\n'
    fi
    
    # Rule with platform ID_PATH if available
    if [ -n "$platform_id_path" ]; then
        rules_content+="# Another alternative without wildcards"$'\n'
        rules_content+="SUBSYSTEM==\"sound\", ENV{ID_PATH}==\"$platform_id_path\", ATTRS{idVendor}==\"$vendor_id\", ATTRS{idProduct}==\"$product_id\", SYMLINK+=\"sound/by-id/$friendly_name\", ATTR{id}=\"$friendly_name\""$'\n'
    fi
    
    # Write rules atomically
    write_rules_atomic "$rules_file" "$rules_content"
    
    # Reload udev rules
    reload_udev_rules
    
    success "Sound card mapping created successfully."
    info "Remember to reboot for changes to take effect."
}

# Display help with enhanced options
show_help() {
    echo "USB Sound Card Mapper v1.0.0 - Create persistent names for USB sound devices"
    echo "Part of LyreBirdAudio - RTSP Audio Streaming Suite"
    echo
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -i, --interactive       Run in interactive mode (default)"
    echo "  -n, --non-interactive   Run in non-interactive mode (requires all other parameters)"
    echo "  -d, --device NAME       Device name (for logging only)"
    echo "  -v, --vendor ID         Vendor ID (4-digit hex)"
    echo "  -p, --product ID        Product ID (4-digit hex)"
    echo "  -u, --usb-port PORT     USB port path (recommended for multiple identical devices)"
    echo "  -f, --friendly NAME     Friendly name to assign"
    echo "  -t, --test              Test USB port detection on current system"
    echo "  -D, --debug             Enable debug output"
    echo "  -h, --help              Show this help"
    echo
    echo "Examples:"
    echo "  $0                      Run in interactive mode"
    echo "  $0 -n -d \"MOVO X1 MINI\" -v 2e88 -p 4610 -f movo-x1-mini"
    echo "  $0 -n -d \"MOVO X1 MINI\" -v 2e88 -p 4610 -u \"usb-3.4\" -f movo-x1-mini"
    echo "  $0 -t                   Test USB port detection capabilities"
    exit 0
}

# Main function with enhanced options
main() {
    # Check dependencies first
    check_dependencies
    
    # Set DEBUG to false by default
    DEBUG="${DEBUG:-false}"
    
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
                device_name="${2:-}"
                if [ -z "$device_name" ]; then
                    error_exit "Option -d requires an argument"
                fi
                shift 2
                ;;
            -v|--vendor)
                vendor_id="${2:-}"
                if [ -z "$vendor_id" ]; then
                    error_exit "Option -v requires an argument"
                fi
                shift 2
                ;;
            -p|--product)
                product_id="${2:-}"
                if [ -z "$product_id" ]; then
                    error_exit "Option -p requires an argument"
                fi
                shift 2
                ;;
            -u|--usb-port)
                port="${2:-}"
                if [ -z "$port" ]; then
                    error_exit "Option -u requires an argument"
                fi
                shift 2
                ;;
            -f|--friendly)
                friendly_name="${2:-}"
                if [ -z "$friendly_name" ]; then
                    error_exit "Option -f requires an argument"
                fi
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
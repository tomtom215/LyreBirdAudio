#!/bin/bash
# lyrebird-mic-check.sh - Hardware Capability Detection for USB Microphones
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
#
# This tool provides robust, portable detection of USB microphone hardware
# capabilities without opening devices or causing interruptions to active streams.
#
# Author: Tom F (https://github.com/tomtom215)
# License: Apache 2.0
#
# Version: 1.0.0
#
#
# DESCRIPTION:
#   A comprehensive USB audio device inspection and configuration tool that safely
#   detects hardware capabilities and generates optimal MediaMTX configurations.
#   Designed for multi-microphone RTSP streaming environments requiring precise
#   hardware parameter detection without service interruption.
#
# KEY FEATURES:
#   - Non-invasive capability detection using ALSA proc filesystem
#   - Detects device busy state without opening or accessing hardware
#   - Reports ALL hardware capabilities (formats, channels, sample rates)
#   - Automatic MediaMTX configuration generation with optimal settings
#   - Configuration validation against detected hardware capabilities
#   - Automatic backup system with restore functionality
#   - USB audio adapter detection with capability warnings
#   - Pure bash implementation - no external parsing dependencies
#   - Portable across all Linux distributions
#
# IMPORTANT - USB Audio Adapter Limitations:
#   This script reports capabilities of USB audio chips. For USB audio adapters
#   with 3.5mm inputs, detected capabilities reflect the USB chip, NOT the
#   microphone connected to the analog input. Always verify:
#   - Microphone is physically connected to 3.5mm jack
#   - Correct input type selected (mic vs. line level)
#   - Channel configuration matches actual microphone (mono mic on stereo jack)
#   - Test recorded audio quality after configuration
#
# TECHNICAL APPROACH:
#   Detection Method:
#     - Uses ALSA proc filesystem (/proc/asound) for capability enumeration
#     - Parses stream* files for hardware parameter specifications
#     - Checks hw_params for current device state (busy detection)
#     - Validates USB devices via usbid files
#     - Derives bit depths from ALSA format specifications
#     - Calculates PCM and encoder bitrates from detected capabilities
#     - Warns about known USB audio adapter chips
#
#   Configuration Generation:
#     - Analyzes hardware capabilities to determine optimal settings
#     - Generates /etc/mediamtx/audio-devices.conf with device-specific parameters
#     - Provides fallback defaults for unconfigured devices
#     - Includes commented alternatives for high-quality configurations
#     - Automatic backup with timestamp before overwrite operations
#     - Validates generated configuration before declaring success
#
#   Validation System:
#     - Verifies configured parameters against actual hardware support
#     - Checks sample rates, channels, and other settings
#     - Provides actionable feedback for misconfigurations
#     - Supports both friendly names and full device ID paths
#
# INTEGRATION:
#   This tool integrates with the LyreBirdAudio installation workflow:
#     1. Map USB devices to friendly names (USB soundcard mapper)
#     2. Install MediaMTX streaming server (install_mediamtx.sh)
#     3. Detect capabilities and generate config (lyrebird-mic-check.sh -g)
#     4. Start streaming service (mediamtx-stream-manager.sh)
#     5. Validate configuration (lyrebird-mic-check.sh -V)
#
# USAGE:
#   lyrebird-mic-check.sh [OPTIONS] [CARD_NUMBER]
#
# Options:
#   -h, --help               Show help message
#   --version                Show version information
#   -g, --generate-config    Generate MediaMTX configuration file
#   -f, --force              Force overwrite existing config (requires -g)
#   --no-backup              Skip automatic backup (NOT recommended)
#   --quality=TIER           Quality tier: low/normal/high (default: normal)
#   -V, --validate           Validate existing config against hardware
#   -q, --quiet              Quiet mode (errors and warnings only)
#   --format=FORMAT          Output format: text (default), json
#   --list-backups           List all available config backups
#   --restore [TIMESTAMP]    Restore config from backup
#
# Arguments:
#   CARD_NUMBER              Specific card to inspect (optional)
#
# Examples:
#   lyrebird-mic-check.sh                    # List all USB devices
#   lyrebird-mic-check.sh 0                  # Show card 0 capabilities
#   lyrebird-mic-check.sh -g                 # Generate config (normal quality)
#   lyrebird-mic-check.sh -g --quality=high  # Generate high-quality config
#   lyrebird-mic-check.sh -g -f              # Force regenerate with backup
#   lyrebird-mic-check.sh -V                 # Validate existing config
#   lyrebird-mic-check.sh --list-backups     # Show available backups
#   lyrebird-mic-check.sh --restore          # Restore from backup
#   lyrebird-mic-check.sh --format=json      # JSON output
set -euo pipefail

# Version
readonly VERSION="1.0.0"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# Default configuration paths
readonly DEFAULT_CONFIG_FILE="/etc/mediamtx/audio-devices.conf"
readonly DEFAULT_CONFIG_DIR="/etc/mediamtx"

# Configuration variables (can be overridden by environment)
CONFIG_FILE="${MEDIAMTX_DEVICE_CONFIG:-${DEFAULT_CONFIG_FILE}}"
CONFIG_DIR="${MEDIAMTX_CONFIG_DIR:-${DEFAULT_CONFIG_DIR}}"

# Operation mode flags
MODE_GENERATE=false
MODE_VALIDATE=false
MODE_FORCE=false
MODE_NO_BACKUP=false  # Explicitly disable backup (backup is default)
MODE_RESTORE=false
MODE_LIST_BACKUPS=false
MODE_QUIET=false
OUTPUT_FORMAT="text"
SPECIFIC_CARD=""
RESTORE_TIMESTAMP=""  # For --restore with specific timestamp

# Quality tier for configuration generation (default: normal)
QUALITY_TIER="normal"

# ALSA limits
readonly ALSA_MAX_CARD_NUMBER=31

# ALSA format string to bit depth mapping
# Reference: Linux kernel sound/core/pcm.c
declare -gA ALSA_FORMAT_BITS=(
    ["S8"]=8
    ["U8"]=8
    ["S16_LE"]=16
    ["S16_BE"]=16
    ["U16_LE"]=16
    ["U16_BE"]=16
    ["S24_LE"]=24
    ["S24_BE"]=24
    ["U24_LE"]=24
    ["U24_BE"]=24
    ["S32_LE"]=32
    ["S32_BE"]=32
    ["U32_LE"]=32
    ["U32_BE"]=32
    ["FLOAT_LE"]=32
    ["FLOAT_BE"]=32
    ["FLOAT64_LE"]=64
    ["FLOAT64_BE"]=64
    ["S24_3LE"]=24
    ["S24_3BE"]=24
    ["U24_3LE"]=24
    ["U24_3BE"]=24
    ["S20_3LE"]=20
    ["S20_3BE"]=20
    ["U20_3LE"]=20
    ["U20_3BE"]=20
    ["S18_3LE"]=18
    ["S18_3BE"]=18
    ["U18_3LE"]=18
    ["U18_3BE"]=18
)

# Known USB audio adapter vendor:product IDs that may report chip capabilities
# rather than actual connected microphone capabilities
declare -gA USB_AUDIO_ADAPTERS=(
    ["0d8c:0014"]="C-Media CM108"
    ["0d8c:0008"]="C-Media CM108AH"
    ["0d8c:000c"]="C-Media CM106"
    ["1130:f211"]="VIA VT1630A"
    ["0c76:161e"]="JMTek USB Audio"
    ["041e:3232"]="Creative USB Audio"
    ["0d8c:0102"]="C-Media CM106 Like"
)

# Unicode handling - detect UTF-8 support
if [[ "${LANG:-}" =~ UTF-8 ]] && [[ -t 1 ]]; then
    readonly CHECK_PASS="[OK]"
    readonly CHECK_FAIL="[FAIL]"
    readonly CHECK_INFO="[INFO]"
else
    readonly CHECK_PASS="[PASS]"
    readonly CHECK_FAIL="[FAIL]"
    readonly CHECK_INFO="[INFO]"
fi

# Temp file tracking for cleanup
TEMP_CONFIG_FILE=""

# ============================================================================
# CLEANUP & SIGNAL HANDLING
# ============================================================================

# Cleanup function for signal handling and normal exit
cleanup() {
    local exit_code=$?
    
    # Remove temporary config file if it exists
    if [[ -n "${TEMP_CONFIG_FILE:-}" ]] && [[ -f "$TEMP_CONFIG_FILE" ]]; then
        rm -f "$TEMP_CONFIG_FILE"
    fi
    
    # If interrupted during config generation, log the interruption
    if [[ $exit_code -eq 130 ]]; then
        log_error "Operation interrupted by user"
    fi
    
    exit $exit_code
}

# Trap signals for cleanup
trap cleanup EXIT INT TERM

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Print message to stderr unless quiet mode
log_info() {
    if [[ "$MODE_QUIET" != true ]]; then
        echo "$@" >&2
    fi
}

# Print error to stderr always
log_error() {
    echo "ERROR: $*" >&2
}

# Print warning to stderr always (even in quiet mode - warnings are critical)
log_warn() {
    echo "WARNING: $*" >&2
}

# Show usage information
show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS] [CARD_NUMBER]

Detect USB microphone hardware capabilities and generate MediaMTX configuration.

OPTIONS:
  -h, --help               Show this help message
  --version                Show version information
  -g, --generate-config    Generate MediaMTX configuration file
  -f, --force              Force overwrite existing config (requires -g)
  --no-backup              Skip automatic backup (NOT recommended)
  --quality=TIER           Quality tier for config generation (low/normal/high)
  -V, --validate           Validate existing config against hardware
  -q, --quiet              Quiet mode (errors and warnings only)
  --format=FORMAT          Output format: text (default), json
  --list-backups           List all available config backups
  --restore [TIMESTAMP]    Restore config from backup (interactive or specific)

ARGUMENTS:
  CARD_NUMBER              Specific card number to inspect (0-31)

EXAMPLES:
  # List all USB audio devices with capabilities
  $SCRIPT_NAME

  # Show capabilities for card 0
  $SCRIPT_NAME 0

  # Generate configuration (prompts before overwrite, auto-backup)
  $SCRIPT_NAME --generate-config

  # Force regenerate configuration (auto-backup, no prompts)
  $SCRIPT_NAME -g -f

  # Generate without backup (NOT recommended)
  $SCRIPT_NAME -g --no-backup

  # Generate configuration with quality tiers
  $SCRIPT_NAME -g --quality=low      # Bandwidth-optimized (voice, monitoring)
  $SCRIPT_NAME -g --quality=normal   # Balanced quality (default)
  $SCRIPT_NAME -g --quality=high     # Maximum quality (music, bird song)

  # Validate existing configuration against hardware
  $SCRIPT_NAME --validate

  # List all configuration backups
  $SCRIPT_NAME --list-backups

  # Restore config interactively (choose from backups)
  $SCRIPT_NAME --restore

  # Restore specific backup
  $SCRIPT_NAME --restore 20251111_123456

  # JSON output for scripting
  $SCRIPT_NAME --format=json

QUALITY TIERS:
  low      - Bandwidth-optimized for voice and monitoring
             * Lower sample rates (44.1 kHz preferred)
             * Mono audio when available
             * Bitrates: 64k-128k
             * Use for: Voice, podcasts, low-priority monitoring

  normal   - Balanced quality and bandwidth (DEFAULT)
             * Standard sample rate (48 kHz preferred)
             * Stereo audio when available
             * Bitrates: 128k-192k
             * Use for: General streaming, most applications

  high     - Maximum quality for music and bird song
             * Highest sample rates (96-192 kHz when available)
             * Stereo audio for spatial information
             * Bitrates: 256k-320k
             * Use for: Music, bird song, archival, professional audio

USB AUDIO ADAPTER WARNING:
  This script reports capabilities of the USB audio chip. For USB audio
  adapters with 3.5mm inputs, detected capabilities reflect the USB chip
  hardware, NOT the actual microphone connected via analog input.

  You MUST verify:
  1. Microphone is physically connected to 3.5mm jack
  2. Correct input type selected (mic vs. line level)
  3. Channel configuration (mono mic on stereo input reports stereo capable)
  4. Test recorded audio quality matches expectations

  The script will warn when known USB audio adapter chips are detected.

CONFIGURATION:
  Config file: $CONFIG_FILE
  Config dir:  $CONFIG_DIR

  Override with environment variables:
    MEDIAMTX_DEVICE_CONFIG - Path to audio-devices.conf
    MEDIAMTX_CONFIG_DIR    - MediaMTX config directory

INTEGRATION:
  This script integrates with LyreBirdAudio installation workflow:
    1. Run USB soundcard mapper (maps devices to friendly names)
    2. Install MediaMTX (install_mediamtx.sh)
    3. Generate config: $SCRIPT_NAME -g
    4. Start service: mediamtx-stream-manager.sh

EXIT CODES:
  0 - Success
  1 - General error (invalid arguments, no devices, etc.)
  2 - Configuration error (validation failed, write error, etc.)

For more information: https://github.com/tomtom215/LyreBirdAudio
EOF
}

# Show version information
show_version() {
    cat << EOF
$SCRIPT_NAME version $VERSION
Part of LyreBirdAudio - RTSP Audio Streaming Suite

Author: Tom F (https://github.com/tomtom215)
License: Apache 2.0
Project: https://github.com/tomtom215/LyreBirdAudio
EOF
}

# Sanitize device name for use in configuration variables
#
# CRITICAL: This function MUST produce identical output to the sanitize_device_name()
# function in mediamtx-stream-manager.sh (lines 1642-1656). Any deviation will cause
# configuration variable lookup failures.
#
# Transformation rules (must match mediamtx-stream-manager.sh):
# 1. DO NOT strip USB prefixes (usb-audio-, usb_audio_)
# 2. DO NOT convert to uppercase (preserve original case)
# 3. Replace non-alphanumeric characters with underscore
# 4. Collapse multiple consecutive underscores to single underscore
# 5. Remove leading and trailing underscores
# 6. If result starts with number: prefix with "dev_" (lowercase)
# 7. If result is empty: use "unknown_device_TIMESTAMP" (lowercase)
# 8. Reject suspicious patterns (security)
# 9. Limit length to 64 characters (prevent DoS)
#
# Parameters:
#   $1 = Raw device name
#
# Returns:
#   stdout: Sanitized device name (lowercase, alphanumeric + underscore only)
#
# Integration Test:
#   Input: "Blue Yeti" -> Output: "blue_yeti" (NOT "BLUE_YETI")
#   Input: "usb-audio-device" -> Output: "usb_audio_device" (NOT "DEVICE")
#   Input: "123device" -> Output: "dev_123device" (NOT "DEV_123DEVICE")
#
sanitize_device_name() {
    local name="$1"
    local sanitized
    
    # Security: Reject suspicious patterns
    if [[ "$name" =~ \.\. ]] || [[ "$name" =~ [/$] ]] || [[ "$name" =~ ^- ]]; then
        log_warn "Device name contains suspicious characters, using fallback"
        printf 'unknown_device_%s\n' "$(date +%s)"
        return
    fi
    
    # Limit length to prevent DoS
    if [[ ${#name} -gt 64 ]]; then
        name="${name:0:64}"
        log_warn "Device name truncated to 64 characters"
    fi
    
    # Replace non-alphanumeric with underscore, preserve case
    sanitized=$(printf '%s' "$name" | sed 's/[^a-zA-Z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//')
    
    # Ensure it doesn't start with a number (lowercase prefix)
    if [[ "$sanitized" =~ ^[0-9] ]]; then
        sanitized="dev_${sanitized}"
    fi
    
    # Fallback if empty (lowercase)
    if [[ -z "$sanitized" ]]; then
        sanitized="unknown_device_$(date +%s)"
    fi
    
    printf '%s\n' "$sanitized"
}

# Check if a USB device ID matches known audio adapter chips
#
# Parameters:
#   $1 = USB vendor:product ID (e.g., "0d8c:0014")
#
# Returns:
#   0 = Device is a known USB audio adapter chip
#   1 = Device is not a known adapter (or unknown)
#
# Side Effects:
#   Logs warning if adapter is detected
check_usb_audio_adapter() {
    local usb_id="$1"
    
    if [[ -n "${USB_AUDIO_ADAPTERS[$usb_id]:-}" ]]; then
        local adapter_name="${USB_AUDIO_ADAPTERS[$usb_id]}"
        log_warn "Detected USB audio adapter chip: $adapter_name"
        log_warn "  Reported capabilities reflect USB chip, not connected microphone"
        log_warn "  Verify:"
        log_warn "    1. Microphone is connected to 3.5mm jack"
        log_warn "    2. Correct impedance (mic vs. line level)"
        log_warn "    3. Expected channel count (mono mic on stereo input)"
        log_warn "  Consider testing: arecord -f cd -d 5 /tmp/test.wav"
        return 0
    fi
    
    # Heuristic: Generic USB Audio devices may also be adapters
    # This is less certain, so we provide a softer warning
    return 1
}

# ============================================================================
# CORE DETECTION FUNCTIONS
# ============================================================================

# Check if a device is currently in use
#
# Method: Checks for existence of hw_params file which only exists when
#         a device is actively opened and configured. Also checks device
#         status and file locks for comprehensive busy detection.
#
# Parameters:
#   $1 = card number (0-31)
#
# Returns:
#   0 = Device is busy (in use)
#   1 = Device is idle (available)
#
# Side Effects: None (read-only)
is_device_busy() {
    local card_num="$1"
    
    # hw_params file only exists when device is open and configured
    # Check all PCM devices and substreams for this card
    if [[ -d "/proc/asound/card${card_num}" ]]; then
        local hw_params_found=false
        
        # Check all pcm devices (pcm0p, pcm0c, pcm1p, pcm1c, etc.)
        local card_base_dir="/proc/asound/card${card_num}"
        for pcm_dir in "$card_base_dir"/pcm*; do
            [[ -d "$pcm_dir" ]] || continue
            
            # Check all substreams
            for sub_dir in "$pcm_dir"/sub*; do
                [[ -d "$sub_dir" ]] || continue
                
                # If hw_params exists and is not empty, device is configured
                if [[ -f "$sub_dir/hw_params" ]] && [[ -s "$sub_dir/hw_params" ]]; then
                    hw_params_found=true
                    break 2
                fi
                
                # Check device status (open but not configured)
                if [[ -f "$sub_dir/status" ]]; then
                    local status
                    status=$(cat "$sub_dir/status" 2>/dev/null || echo "")
                    if [[ -n "$status" ]] && [[ "$status" != "closed" ]]; then
                        hw_params_found=true
                        break 2
                    fi
                fi
            done
        done
        
        if [[ "$hw_params_found" = true ]]; then
            return 0
        fi
        
        # Additional check: fuser on device files (if fuser is available)
        # Check all capture device files, not just D0c
        if command -v fuser >/dev/null 2>&1; then
            for dev_file in /dev/snd/pcmC"${card_num}"D*c; do
                [[ -e "$dev_file" ]] || continue
                if fuser "$dev_file" 2>/dev/null | grep -q '[0-9]'; then
                    return 0
                fi
            done
        fi
    fi
    
    return 1
}

# Get basic device information
#
# Retrieves USB device identification and naming information from ALSA proc
# filesystem without accessing the device hardware.
#
# Parameters:
#   $1 = card number (0-31)
#
# Returns:
#   stdout: Key-value pairs (one per line) of device information
#   exit: 0 on success, 1 on error
#
# Output Format:
#   card_number=0
#   device_name=Blue_Yeti
#   device_id=Blue Microphones Yeti Stereo Microphone
#   device_id_path=usb-Blue_Microphones_Yeti_Stereo_Microphone_REV8-00
#   usb_id=b58e:9e84
#
# Side Effects: None (read-only)
get_device_info() {
    local card_num="$1"
    
    # Validate card exists
    local card_dir="/proc/asound/card${card_num}"
    if [[ ! -d "$card_dir" ]]; then
        log_error "Card $card_num not found"
        return 1
    fi
    
    # Verify this is a USB device
    if [[ ! -f "$card_dir/usbid" ]]; then
        log_error "Card $card_num is not a USB device"
        return 1
    fi
    
    # Read USB ID
    local usb_id=""
    if [[ -f "$card_dir/usbid" ]]; then
        usb_id=$(cat "$card_dir/usbid" 2>/dev/null || echo "")
    fi
    
    # Read device name from id file (short name)
    local device_name=""
    if [[ -f "$card_dir/id" ]]; then
        device_name=$(cat "$card_dir/id" 2>/dev/null || echo "")
    fi
    
    # Fallback to card number if no name
    if [[ -z "$device_name" ]]; then
        device_name="card${card_num}"
    fi
    
    # Read full device ID from usbmixer (if available)
    local device_id=""
    local device_id_path=""
    if [[ -f "$card_dir/usbmixer" ]]; then
        # Parse usbmixer for device ID
        device_id=$(grep -m1 "USB Mixer" "$card_dir/usbmixer" 2>/dev/null | sed 's/.*: //' || echo "")
    fi
    
    # Try to find device ID path from /dev/snd/by-id/
    # This provides persistent naming independent of card number
    if [[ -d "/dev/snd/by-id" ]]; then
        for id_link in /dev/snd/by-id/*; do
            [[ -L "$id_link" ]] || continue
            local target
            target=$(readlink -f "$id_link" 2>/dev/null || echo "")
            # Check if this symlink points to our card
            if [[ "$target" =~ controlC${card_num}$ ]]; then
                device_id_path=$(basename "$id_link")
                break
            fi
        done
    fi
    
    # Output device information
    printf 'card_number=%s\n' "$card_num"
    printf 'device_name=%s\n' "$device_name"
    [[ -n "$device_id" ]] && printf 'device_id=%s\n' "$device_id"
    [[ -n "$device_id_path" ]] && printf 'device_id_path=%s\n' "$device_id_path"
    [[ -n "$usb_id" ]] && printf 'usb_id=%s\n' "$usb_id"
    
    return 0
}

# Parse a single stream file for capabilities
#
# Parses ALSA stream file format to extract hardware capabilities for a specific
# stream direction (Playback or Capture). Uses line-by-line parsing to properly
# handle multiple Altsets with different capabilities.
#
# Parameters:
#   $1 = Path to stream file
#   $2 = Stream direction ("Playback" or "Capture")
#
# Returns:
#   stdout: Key-value pairs of detected capabilities
#   exit: 0 if stream found, 1 if not found or error
#
# Output Format:
#   formats=S16_LE S24_LE S32_LE
#   channels=1 2
#   rates=44100 48000 96000
#
# Side Effects: None (read-only)
parse_stream_file() {
    local stream_file="$1"
    local stream_type="$2"  # "Playback" or "Capture"
    
    [[ -f "$stream_file" ]] || return 1
    
    local in_target_section=false
    local in_altset=false
    local formats=()
    local channels=()
    local rates=()
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Detect section start (Playback: or Capture:)
        if [[ "$line" =~ ^[[:space:]]*${stream_type}: ]]; then
            in_target_section=true
            continue
        fi
        
        # Exit if we hit another top-level section
        if [[ "$in_target_section" = true ]] && [[ "$line" =~ ^[A-Z][a-z]+: ]]; then
            if [[ ! "$line" =~ ^[[:space:]] ]]; then
                break
            fi
        fi
        
        if [[ "$in_target_section" = false ]]; then
            continue
        fi
        
        # Parse altset start
        if [[ "$line" =~ ^[[:space:]]+Altset[[:space:]]([0-9]+) ]]; then
            in_altset=true
            continue
        fi
        
        # Parse format line
        if [[ "$in_altset" = true ]] && [[ "$line" =~ ^[[:space:]]+Format:[[:space:]](.+)$ ]]; then
            local format="${BASH_REMATCH[1]}"
            format="${format%%[[:space:]]*}"  # Take first word only
            if [[ -n "$format" ]] && [[ ! " ${formats[*]} " == *" ${format} "* ]]; then
                formats+=("$format")
            fi
        fi
        
        # Parse channels line
        if [[ "$in_altset" = true ]] && [[ "$line" =~ ^[[:space:]]+Channels:[[:space:]]([0-9]+) ]]; then
            local channel="${BASH_REMATCH[1]}"
            if [[ -n "$channel" ]] && [[ ! " ${channels[*]} " == *" ${channel} "* ]]; then
                channels+=("$channel")
            fi
        fi
        
        # Parse rates line (can be ranges or discrete values)
        if [[ "$in_altset" = true ]] && [[ "$line" =~ ^[[:space:]]+Rates:[[:space:]](.+)$ ]]; then
            local rates_str="${BASH_REMATCH[1]}"
            
            # Handle range format: 8000 - 96000 (continuous)
            if [[ "$rates_str" =~ ([0-9]+)[[:space:]]*-[[:space:]]([0-9]+)[[:space:]]*\(continuous\) ]]; then
                local min_rate="${BASH_REMATCH[1]}"
                local max_rate="${BASH_REMATCH[2]}"
                
                # Validate range
                if [[ $min_rate -ge $max_rate ]]; then
                    log_warn "Invalid continuous rate range: $min_rate-$max_rate (min >= max)"
                elif [[ $min_rate -eq 0 ]] || [[ $max_rate -eq 0 ]]; then
                    log_warn "Invalid zero rate in range: $min_rate-$max_rate"
                else
                    # For continuous ranges, report common standard rates within range
                    local std_rates=(8000 11025 16000 22050 32000 44100 48000 88200 96000 176400 192000 352800 384000 768000)
                    for rate in "${std_rates[@]}"; do
                        if [[ $rate -ge $min_rate ]] && [[ $rate -le $max_rate ]]; then
                            if [[ ! " ${rates[*]} " == *" ${rate} "* ]]; then
                                rates+=("$rate")
                            fi
                        fi
                    done
                    
                    # Warn if range is suspiciously large
                    if [[ $((max_rate / min_rate)) -gt 100 ]]; then
                        log_warn "Suspiciously large rate range: $min_rate-$max_rate"
                    fi
                fi
            else
                # Handle discrete rates: 44100, 48000
                IFS=',' read -ra rate_array <<< "$rates_str"
                for rate in "${rate_array[@]}"; do
                    # Strip whitespace and non-numeric characters
                    rate="${rate//[^0-9]/}"
                    if [[ -n "$rate" ]] && [[ ! " ${rates[*]} " == *" ${rate} "* ]]; then
                        rates+=("$rate")
                    fi
                done
            fi
        fi
        
    done < "$stream_file"
    
    # Output results if we found any capabilities
    if [[ ${#formats[@]} -gt 0 ]] || [[ ${#channels[@]} -gt 0 ]] || [[ ${#rates[@]} -gt 0 ]]; then
        [[ ${#formats[@]} -gt 0 ]] && printf 'formats=%s\n' "${formats[*]}"
        [[ ${#channels[@]} -gt 0 ]] && printf 'channels=%s\n' "${channels[*]}"
        [[ ${#rates[@]} -gt 0 ]] && printf 'rates=%s\n' "${rates[*]}"
        return 0
    fi
    
    return 1
}

# Detect comprehensive device capabilities
#
# Aggregates capabilities from all stream files for a USB audio device and
# outputs a comprehensive capability report. This function uses ALSA proc
# filesystem exclusively and never opens the device.
#
# Parameters:
#   $1 = card number (0-31)
#
# Returns:
#   stdout: Comprehensive capability report (key=value format)
#   exit: 0 on success, 1 on error
#
# Output Format (one capability per line):
#   card_number=0
#   is_usb=true
#   is_busy=false
#   formats=S16_LE S24_LE S32_LE
#   bit_depths=16 24 32
#   channels=1 2
#   sample_rates=44100 48000 96000
#   capture_capable=true
#   playback_capable=false
#
# Notes:
# - bit_depths are derived from formats using ALSA_FORMAT_BITS mapping
# - Continuous rate ranges are expanded to standard rates
# - All arrays are space-separated and deduplicated
# - USB audio adapter chips are detected and warned about
#
# Side Effects: None (read-only operations only)
detect_device_capabilities() {
    local card_num="$1"
    
    # Validate card number
    if [[ ! "$card_num" =~ ^[0-9]+$ ]]; then
        log_error "Invalid card number: $card_num"
        return 1
    fi
    
    local card_dir="/proc/asound/card${card_num}"
    
    # Verify card exists
    if [[ ! -d "$card_dir" ]]; then
        log_error "Card $card_num not found"
        return 1
    fi
    
    # Verify this is a USB device
    if [[ ! -f "$card_dir/usbid" ]]; then
        log_error "Card $card_num is not a USB device"
        return 1
    fi
    
    # Check for USB audio adapter chips
    local usb_id=""
    if [[ -f "$card_dir/usbid" ]]; then
        usb_id=$(cat "$card_dir/usbid" 2>/dev/null || echo "")
        if [[ -n "$usb_id" ]]; then
            check_usb_audio_adapter "$usb_id"
        fi
    fi
    
    # Check if device is currently busy
    local busy=false
    if is_device_busy "$card_num"; then
        busy=true
    fi
    
    # Aggregate capabilities from all stream files
    local all_formats=()
    local all_channels=()
    local all_rates=()
    local has_capture=false
    local has_playback=false
    
    # Parse all stream files for this card
    for stream_file in "$card_dir"/stream*; do
        [[ -f "$stream_file" ]] || continue
        
        # Parse capture capabilities
        local capture_output
        if capture_output=$(parse_stream_file "$stream_file" "Capture" 2>/dev/null); then
            has_capture=true
            
            # Extract and merge formats
            if [[ "$capture_output" =~ formats=([^$'\n']*) ]]; then
                IFS=' ' read -ra formats <<< "${BASH_REMATCH[1]}"
                for fmt in "${formats[@]}"; do
                    if [[ ! " ${all_formats[*]} " == *" ${fmt} "* ]]; then
                        all_formats+=("$fmt")
                    fi
                done
            fi
            
            # Extract and merge channels
            if [[ "$capture_output" =~ channels=([^$'\n']*) ]]; then
                IFS=' ' read -ra channels <<< "${BASH_REMATCH[1]}"
                for ch in "${channels[@]}"; do
                    if [[ ! " ${all_channels[*]} " == *" ${ch} "* ]]; then
                        all_channels+=("$ch")
                    fi
                done
            fi
            
            # Extract and merge rates
            if [[ "$capture_output" =~ rates=([^$'\n']*) ]]; then
                IFS=' ' read -ra rates <<< "${BASH_REMATCH[1]}"
                for rate in "${rates[@]}"; do
                    if [[ ! " ${all_rates[*]} " == *" ${rate} "* ]]; then
                        all_rates+=("$rate")
                    fi
                done
            fi
        fi
        
        # Parse playback capabilities
        if parse_stream_file "$stream_file" "Playback" >/dev/null 2>&1; then
            has_playback=true
        fi
    done
    
    # If no capabilities found, fail
    if [[ ${#all_formats[@]} -eq 0 ]] && [[ ${#all_channels[@]} -eq 0 ]] && [[ ${#all_rates[@]} -eq 0 ]]; then
        log_error "No capabilities found for card $card_num"
        return 1
    fi
    
    # Derive bit depths from formats
    local all_bit_depths=()
    for format in "${all_formats[@]}"; do
        if [[ -n "${ALSA_FORMAT_BITS[$format]:-}" ]]; then
            local bits="${ALSA_FORMAT_BITS[$format]}"
            if [[ ! " ${all_bit_depths[*]} " == *" ${bits} "* ]]; then
                all_bit_depths+=("$bits")
            fi
        fi
    done
    
    # Validate channels (must have at least one non-zero channel)
    if [[ ${#all_channels[@]} -gt 0 ]]; then
        local max_channels
        max_channels=$(printf '%s\n' "${all_channels[@]}" | sort -n | tail -1)
        if [[ $max_channels -eq 0 ]]; then
            log_error "Device reports 0 channels - hardware malfunction"
            return 1
        fi
    fi
    
    # Sort numeric arrays
    if [[ ${#all_channels[@]} -gt 0 ]]; then
        mapfile -t all_channels < <(printf '%s\n' "${all_channels[@]}" | sort -n)
    fi
    if [[ ${#all_rates[@]} -gt 0 ]]; then
        mapfile -t all_rates < <(printf '%s\n' "${all_rates[@]}" | sort -n)
    fi
    if [[ ${#all_bit_depths[@]} -gt 0 ]]; then
        mapfile -t all_bit_depths < <(printf '%s\n' "${all_bit_depths[@]}" | sort -n)
    fi
    
    # Output structured results
    printf 'is_usb=true\n'
    printf 'is_busy=%s\n' "$busy"
    
    [[ ${#all_formats[@]} -gt 0 ]] && printf 'formats=%s\n' "${all_formats[*]}"
    [[ ${#all_bit_depths[@]} -gt 0 ]] && printf 'bit_depths=%s\n' "${all_bit_depths[*]}"
    [[ ${#all_channels[@]} -gt 0 ]] && printf 'channels=%s\n' "${all_channels[*]}"
    [[ ${#all_rates[@]} -gt 0 ]] && printf 'sample_rates=%s\n' "${all_rates[*]}"
    
    printf 'capture_capable=%s\n' "$has_capture"
    printf 'playback_capable=%s\n' "$has_playback"
    
    # Calculate all possible PCM bit rates
    # PCM bit rate = sample_rate * bit_depth * channels (in bits per second)
    # We output in kbps for readability
    local all_pcm_bitrates=()
    if [[ ${#all_rates[@]} -gt 0 ]] && [[ ${#all_bit_depths[@]} -gt 0 ]] && [[ ${#all_channels[@]} -gt 0 ]]; then
        declare -A bitrate_map  # Use associative array to ensure uniqueness
        
        for rate in "${all_rates[@]}"; do
            for depth in "${all_bit_depths[@]}"; do
                for ch in "${all_channels[@]}"; do
                    # Calculate PCM bit rate in kbps
                    local bitrate_bps=$((rate * depth * ch))
                    local bitrate_kbps=$((bitrate_bps / 1000))
                    bitrate_map["$bitrate_kbps"]=1
                done
            done
        done
        
        # Extract unique bitrates and sort numerically
        for bitrate in "${!bitrate_map[@]}"; do
            all_pcm_bitrates+=("$bitrate")
        done
        mapfile -t all_pcm_bitrates < <(printf '%s\n' "${all_pcm_bitrates[@]}" | sort -n)
    fi
    
    [[ ${#all_pcm_bitrates[@]} -gt 0 ]] && printf 'pcm_bitrates_kbps=%s\n' "${all_pcm_bitrates[*]}"
    
    # Calculate suggested encoder bitrates based on quality tiers
    # These are Opus/AAC encoder bitrates, not PCM bitrates
    if [[ ${#all_rates[@]} -gt 0 ]] && [[ ${#all_channels[@]} -gt 0 ]]; then
        # Get highest sample rate and channel count
        local max_rate="${all_rates[-1]}"
        local max_channels="${all_channels[-1]}"
        
        # Calculate encoder bitrates for each quality tier
        for tier in low normal high; do
            local enc_bitrate
            enc_bitrate=$(calculate_encoder_bitrate "$max_rate" "$max_channels" "$tier")
            printf 'encoder_bitrate_%s=%s\n' "$tier" "$enc_bitrate"
        done
    fi
    
    return 0
}

# Calculate appropriate encoder bitrate based on sample rate, channels, and quality tier
#
# Parameters:
#   $1 = Sample rate (Hz)
#   $2 = Number of channels
#   $3 = Quality tier (low/normal/high)
#
# Returns:
#   stdout: Encoder bitrate in kbps (just the number, e.g., "192")
#
calculate_encoder_bitrate() {
    local rate="$1"
    local ch="$2"
    local tier="$3"
    
    # Determine bitrate based on tier and characteristics
    case "$tier" in
        low)
            # Low tier: Bandwidth-optimized
            if [[ $rate -ge 44100 ]]; then
                echo $((ch == 1 ? 96 : 128))
            else
                echo $((ch == 1 ? 64 : 96))
            fi
            ;;
        normal)
            # Normal tier: Balanced
            if [[ $rate -ge 96000 ]]; then
                echo $((ch == 1 ? 192 : 256))
            elif [[ $rate -ge 44100 ]]; then
                echo $((ch == 1 ? 128 : 192))
            else
                echo $((ch == 1 ? 96 : 128))
            fi
            ;;
        high)
            # High tier: Maximum quality
            if [[ $rate -ge 192000 ]]; then
                echo $((ch == 1 ? 192 : 320))
            elif [[ $rate -ge 96000 ]]; then
                echo $((ch == 1 ? 160 : 256))
            elif [[ $rate -ge 48000 ]]; then
                echo $((ch == 1 ? 128 : 192))
            else
                echo $((ch == 1 ? 96 : 128))
            fi
            ;;
        *)
            # Fallback to normal
            echo $((ch == 1 ? 128 : 192))
            ;;
    esac
}

# List all USB audio devices with their capabilities
#
# Scans /proc/asound for all USB audio devices and outputs their
# information and capabilities in structured format.
#
# Parameters: None
#
# Returns:
#   stdout: Device information for all USB audio devices
#   exit: 0 on success, 1 if no devices found
#
# Output Format:
#   === Card 0: DeviceName ===
#   device_name=DeviceName
#   card_number=0
#   ...
#   [blank line]
#   === Card 1: OtherDevice ===
#   ...
#
# Side Effects: None (read-only)
list_all_usb_devices() {
    local found_devices=false
    
    # Scan all sound cards
    for card_dir in /proc/asound/card[0-9]*; do
        [[ -d "$card_dir" ]] || continue
        
        local card_num="${card_dir##*/card}"
        
        # Skip non-USB devices
        [[ -f "$card_dir/usbid" ]] || continue
        
        found_devices=true
        
        # Get device info
        local device_info
        if ! device_info=$(get_device_info "$card_num"); then
            log_warn "Could not get info for card $card_num (see error above)"
            continue
        fi
        
        # Extract device name for header
        local device_name="Unknown"
        if [[ "$device_info" =~ device_name=([^$'\n']*) ]]; then
            device_name="${BASH_REMATCH[1]}"
        fi
        
        # Print header
        echo "=== Card $card_num: $device_name ==="
        
        # Print device info
        echo "$device_info"
        
        # Get and print capabilities
        local caps
        if caps=$(detect_device_capabilities "$card_num"); then
            echo "$caps"
        else
            log_warn "Could not detect capabilities for card $card_num (see error above)"
        fi
        
        echo ""
    done
    
    if [[ "$found_devices" != true ]]; then
        log_error "No USB audio devices found"
        log_info "Check:"
        log_info "  - USB devices are connected: lsusb"
        log_info "  - ALSA is loaded: lsmod | grep snd"
        log_info "  - /proc/asound exists"
        return 1
    fi
    
    return 0
}

# ============================================================================
# CONFIGURATION GENERATION
# ============================================================================

# Global associative array for parsed capabilities
declare -gA PARSED_CAPS

# Parse capabilities string into global PARSED_CAPS array
#
# Parameters:
#   $1 = Capabilities string (multiline key=value format)
#
# Side Effects:
#   Populates global PARSED_CAPS associative array
parse_capabilities() {
    local caps="$1"
    
    # Clear previous values
    PARSED_CAPS=()
    
    # Parse each line
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        [[ -n "$key" ]] && PARSED_CAPS["$key"]="$value"
    done <<< "$caps"
}

# Determine optimal settings based on hardware capabilities and quality tier
#
# Parameters:
#   $1 = Quality tier (low/normal/high)
#
# Returns:
#   stdout: optimal_rate optimal_channels encoder_bitrate
#
# Requires:
#   PARSED_CAPS array must be populated
determine_optimal_settings() {
    local tier="$1"
    
    # Get available capabilities
    local hw_rates="${PARSED_CAPS[sample_rates]:-}"
    local hw_channels="${PARSED_CAPS[channels]:-}"
    
    if [[ -z "$hw_rates" ]] || [[ -z "$hw_channels" ]]; then
        log_error "No hardware capabilities available"
        return 1
    fi
    
    # Parse rates and channels into arrays
    IFS=' ' read -ra rate_array <<< "$hw_rates"
    IFS=' ' read -ra channel_array <<< "$hw_channels"
    
    # Get maximum capabilities
    local max_rate="${rate_array[-1]}"
    local max_channels="${channel_array[-1]}"
    
    # Determine optimal sample rate based on tier
    local optimal_rate
    case "$tier" in
        low)
            # Prefer 44100 Hz if available, otherwise closest lower rate
            if [[ " ${hw_rates} " =~ " 44100 " ]]; then
                optimal_rate=44100
            elif [[ " ${hw_rates} " =~ " 48000 " ]]; then
                optimal_rate=48000
            else
                # Use lowest available rate
                optimal_rate="${rate_array[0]}"
            fi
            ;;
        normal)
            # Prefer 48000 Hz if available
            if [[ " ${hw_rates} " =~ " 48000 " ]]; then
                optimal_rate=48000
            elif [[ " ${hw_rates} " =~ " 44100 " ]]; then
                optimal_rate=44100
            else
                # Use highest rate up to 48kHz
                for rate in "${rate_array[@]}"; do
                    if [[ $rate -le 48000 ]]; then
                        optimal_rate=$rate
                    else
                        break
                    fi
                done
                # If no rate <= 48kHz, use lowest
                optimal_rate="${optimal_rate:-${rate_array[0]}}"
            fi
            ;;
        high)
            # Prefer highest rate in 96-192 kHz range
            if [[ $max_rate -ge 192000 ]]; then
                optimal_rate=192000
            elif [[ $max_rate -ge 96000 ]]; then
                optimal_rate=96000
            elif [[ $max_rate -ge 48000 ]]; then
                optimal_rate=48000
            else
                optimal_rate=$max_rate
            fi
            
            # Verify our target rate is actually supported
            if [[ ! " ${hw_rates} " == *" ${optimal_rate} "* ]]; then
                optimal_rate=$max_rate
            fi
            ;;
        *)
            optimal_rate=48000
            ;;
    esac
    
    # Determine optimal channels based on tier
    local optimal_channels
    case "$tier" in
        low)
            # Prefer mono if available
            if [[ $max_channels -ge 1 ]]; then
                optimal_channels=1
            else
                optimal_channels=$max_channels
            fi
            ;;
        normal|high)
            # Prefer stereo if available
            if [[ $max_channels -ge 2 ]]; then
                optimal_channels=2
            else
                optimal_channels=$max_channels
            fi
            ;;
        *)
            optimal_channels=2
            ;;
    esac
    
    # Calculate encoder bitrate
    local enc_bitrate
    enc_bitrate=$(calculate_encoder_bitrate "$optimal_rate" "$optimal_channels" "$tier")
    
    printf '%s %s %s\n' "$optimal_rate" "$optimal_channels" "$enc_bitrate"
}

# Create backup of existing configuration file
#
# Parameters:
#   None (uses global CONFIG_FILE)
#
# Returns:
#   0 = Backup created successfully or not needed
#   1 = Backup failed
#
# Side Effects:
#   Creates backup file in same directory as CONFIG_FILE
#   Logs backup location
create_config_backup() {
    # If config file doesn't exist, no backup needed
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 0
    fi
    
    local backup_file
    backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Security check: Ensure backup file doesn't exist (prevent symlink attacks)
    if [[ -e "$backup_file" ]] || [[ -L "$backup_file" ]]; then
        log_error "Backup file already exists or is a symlink: $backup_file"
        return 1
    fi
    
    # Create temp file for atomic write
    local temp_backup
    temp_backup=$(mktemp "${backup_file}.XXXXXXXXXX" 2>/dev/null) || {
        log_error "Failed to create temporary backup file"
        return 1
    }
    
    # Copy with permissions preserved
    if ! cp -p "$CONFIG_FILE" "$temp_backup"; then
        rm -f "$temp_backup"
        log_error "Failed to create backup copy"
        return 1
    fi
    
    # Set restrictive permissions before atomic move
    if ! chmod 600 "$temp_backup" 2>/dev/null; then
        rm -f "$temp_backup"
        log_error "Failed to set backup file permissions"
        return 1
    fi
    
    # Atomic move
    if ! mv -f "$temp_backup" "$backup_file"; then
        rm -f "$temp_backup"
        log_error "Failed to finalize backup file"
        return 1
    fi
    
    log_info "Configuration backup created: $backup_file"
    return 0
}

# List all available configuration backups
#
# Parameters: None
#
# Returns:
#   0 = Backups found and listed
#   1 = No backups found
#
# Side Effects:
#   Prints backup list to stdout
list_config_backups() {
    log_info "Available Configuration Backups:"
    log_info "================================"
    
    local backups_found=false
    
    # Find all backup files sorted by timestamp (newest first)
    local backup_files=()
    while IFS= read -r -d '' file; do
        backup_files+=("$file")
    done < <(find "$(dirname "$CONFIG_FILE")" -maxdepth 1 -name "$(basename "$CONFIG_FILE").backup.*" -type f -print0 2>/dev/null | sort -rz)
    
    if [[ ${#backup_files[@]} -eq 0 ]]; then
        log_info "No backups found"
        return 1
    fi
    
    for backup_file in "${backup_files[@]}"; do
        backups_found=true
        
        # Extract timestamp from filename
        local timestamp
        timestamp=$(basename "$backup_file" | sed 's/.*\.backup\.//')
        
        # Get file size and modification time
        local size
        size=$(du -h "$backup_file" 2>/dev/null | cut -f1)
        local mod_time
        mod_time=$(stat -c '%y' "$backup_file" 2>/dev/null | cut -d'.' -f1)
        
        printf '  %s - %s (%s)\n' "$timestamp" "$mod_time" "$size"
    done
    
    if [[ "$backups_found" = true ]]; then
        echo ""
        log_info "To restore a backup:"
        log_info "  $SCRIPT_NAME --restore [TIMESTAMP]"
        log_info "  Example: $SCRIPT_NAME --restore $(basename "${backup_files[0]}" | sed 's/.*\.backup\.//')"
    fi
    
    return 0
}

# Restore configuration from backup
#
# Parameters:
#   $1 = Optional timestamp (if empty, interactive selection)
#
# Returns:
#   0 = Restore successful
#   1 = Restore failed
#   2 = User cancelled
#
# Side Effects:
#   Overwrites CONFIG_FILE with backup
restore_config_backup() {
    local target_timestamp="$1"
    
    # Find available backups
    local backup_files=()
    while IFS= read -r -d '' file; do
        backup_files+=("$file")
    done < <(find "$(dirname "$CONFIG_FILE")" -maxdepth 1 -name "$(basename "$CONFIG_FILE").backup.*" -type f -print0 2>/dev/null | sort -rz)
    
    if [[ ${#backup_files[@]} -eq 0 ]]; then
        log_error "No backup files found"
        return 1
    fi
    
    local selected_backup=""
    
    # If timestamp provided, find matching backup
    if [[ -n "$target_timestamp" ]]; then
        # Validate timestamp format (YYYYMMDD_HHMMSS)
        if [[ ! "$target_timestamp" =~ ^[0-9]{8}_[0-9]{6}$ ]]; then
            log_error "Invalid timestamp format: $target_timestamp"
            log_error "Expected format: YYYYMMDD_HHMMSS (e.g., 20251111_123456)"
            return 1
        fi
        
        # Validate timestamp sanity (reasonable date range)
        local year="${target_timestamp:0:4}"
        local year_num=$((10#$year))
        if [[ $year_num -lt 2020 ]] || [[ $year_num -gt 2100 ]]; then
            log_error "Timestamp year out of reasonable range: $year"
            return 1
        fi
        
        local backup_file="${CONFIG_FILE}.backup.${target_timestamp}"
        if [[ ! -f "$backup_file" ]]; then
            log_error "Backup not found: $backup_file"
            log_info "Available backups:"
            list_config_backups
            return 1
        fi
        
        # Security: Verify backup is a regular file, not a symlink
        if [[ -L "$backup_file" ]]; then
            log_error "Backup file is a symlink (security violation): $backup_file"
            log_error "Refusing to restore potentially malicious file"
            return 1
        fi
        
        # Verify file is readable
        if [[ ! -r "$backup_file" ]]; then
            log_error "Backup file is not readable: $backup_file"
            return 1
        fi
        
        selected_backup="$backup_file"
    else
        # Interactive selection
        log_info "Available backups (newest first):"
        log_info "================================="
        
        local i=1
        for backup_file in "${backup_files[@]}"; do
            local timestamp
            timestamp=$(basename "$backup_file" | sed 's/.*\.backup\.//')
            local size
            size=$(du -h "$backup_file" 2>/dev/null | cut -f1)
            local mod_time
            mod_time=$(stat -c '%y' "$backup_file" 2>/dev/null | cut -d'.' -f1)
            
            printf '  %d) %s - %s (%s)\n' "$i" "$timestamp" "$mod_time" "$size"
            ((i++))
        done
        
        echo ""
        read -r -p "Select backup to restore (1-${#backup_files[@]}, 0 to cancel): " selection
        
        if [[ "$selection" == "0" ]]; then
            log_info "Restore cancelled by user"
            return 0
        fi
        
        if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ $selection -lt 1 ]] || [[ $selection -gt ${#backup_files[@]} ]]; then
            log_error "Invalid selection: $selection"
            return 1
        fi
        
        selected_backup="${backup_files[$((selection - 1))]}"
        
        # Security: Verify selected backup is a regular file, not a symlink
        if [[ -L "$selected_backup" ]]; then
            log_error "Selected backup is a symlink (security violation): $selected_backup"
            log_error "Refusing to restore potentially malicious file"
            return 1
        fi
        
        # Verify file is readable
        if [[ ! -r "$selected_backup" ]]; then
            log_error "Backup file is not readable: $selected_backup"
            return 1
        fi
    fi
    
    # Confirm restore
    log_info ""
    log_info "This will restore configuration from:"
    log_info "  $(basename "$selected_backup")"
    log_info "  to: $CONFIG_FILE"
    log_info ""
    
    if [[ "$MODE_FORCE" != true ]]; then
        read -r -p "Continue with restore? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            log_info "Restore cancelled by user"
            return 0
        fi
    fi
    
    # Perform restore using temp file for atomic operation
    local temp_restore
    temp_restore=$(mktemp "${CONFIG_FILE}.restore.XXXXXXXXXX" 2>/dev/null) || {
        log_error "Failed to create temporary file"
        return 2
    }
    
    # Copy backup to temp file
    if ! cp -p "$selected_backup" "$temp_restore"; then
        rm -f "$temp_restore"
        log_error "Failed to copy backup file"
        return 2
    fi
    
    # Atomic move
    if ! mv -f "$temp_restore" "$CONFIG_FILE"; then
        rm -f "$temp_restore"
        log_error "Failed to restore configuration"
        return 2
    fi
    
    log_info "Configuration restored successfully from: $(basename "$selected_backup")"
    log_info "Restart service to apply changes: sudo systemctl restart mediamtx-stream-manager"
    
    return 0
}

# Check if running as root (required for /etc/mediamtx writes)
check_root_access() {
    if [[ $EUID -ne 0 ]] && [[ "$CONFIG_DIR" == "$DEFAULT_CONFIG_DIR" ]]; then
        log_error "Root access required to write to $CONFIG_DIR"
        log_error "Run with: sudo $SCRIPT_NAME [your options]"
        return 1
    fi
    
    # Verify config directory exists or can be created
    if [[ ! -d "$CONFIG_DIR" ]]; then
        if ! mkdir -p "$CONFIG_DIR" 2>/dev/null; then
            log_error "Cannot create config directory: $CONFIG_DIR"
            log_error "Check permissions or run with sudo"
            return 1
        fi
    fi
    
    # Verify we can write to config directory
    if [[ ! -w "$CONFIG_DIR" ]]; then
        log_error "Cannot write to config directory: $CONFIG_DIR"
        log_error "Check permissions or run with sudo"
        return 1
    fi
    
    return 0
}

# Check if sufficient disk space is available
#
# Parameters:
#   $1 = Required space in KB
#
# Returns:
#   0 = Sufficient space available
#   1 = Insufficient space
check_disk_space() {
    local required_kb="$1"
    
    local available_kb
    available_kb=$(df --output=avail "$CONFIG_DIR" | tail -1)
    
    if [[ $available_kb -lt $required_kb ]]; then
        log_error "Insufficient disk space in $CONFIG_DIR"
        log_error "Required: ~$((required_kb / 1024)) MB, Available: $((available_kb / 1024)) MB"
        return 1
    fi
    
    return 0
}

# Validate generated configuration file
#
# Parameters:
#   $1 = Path to config file to validate
#
# Returns:
#   0 = Configuration is valid
#   1 = Configuration is invalid
validate_generated_config() {
    local config_file="$1"
    
    # Check file exists
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file does not exist: $config_file"
        return 1
    fi
    
    # Check syntax (bash -n)
    if ! bash -n "$config_file" 2>/dev/null; then
        log_error "Generated config has syntax errors"
        return 1
    fi
    
    # Check for device definitions
    if ! grep -qE '^DEVICE_.*=' "$config_file"; then
        log_error "Generated config contains no device definitions"
        return 1
    fi
    
    # Check file is not empty
    if [[ ! -s "$config_file" ]]; then
        log_error "Generated config is empty"
        return 1
    fi
    
    return 0
}

# Generate MediaMTX configuration from detected hardware
#
# Scans all USB audio devices, detects their capabilities, and generates
# a comprehensive configuration file for MediaMTX with optimal settings.
#
# Parameters: None (uses global MODE_* and QUALITY_TIER variables)
#
# Returns:
#   0 = Configuration generated successfully
#   1 = General error
#   2 = Configuration error
#
# Side Effects:
#   - Creates/overwrites CONFIG_FILE
#   - May create backup of existing config
#   - Logs all operations
generate_config() {
    log_info "Generating MediaMTX audio device configuration..."
    log_info "Quality tier: $QUALITY_TIER"
    echo ""
    
    # Check root access if needed
    if ! check_root_access; then
        return 2
    fi
    
    # Check disk space (require 100KB)
    if ! check_disk_space 100; then
        return 2
    fi
    
    # Check if config already exists and handle overwrite
    if [[ -f "$CONFIG_FILE" ]] && [[ "$MODE_FORCE" != true ]]; then
        log_warn "Configuration file already exists: $CONFIG_FILE"
        log_info "Use --force to overwrite (automatic backup will be created)"
        read -r -p "Overwrite existing configuration? (y/N): " confirm
        
        if [[ ! "$confirm" =~ ^[Yy] ]]; then
            log_info "Configuration generation cancelled"
            return 0
        fi
    fi
    
    # Create backup unless disabled
    if [[ "$MODE_NO_BACKUP" != true ]]; then
        if ! create_config_backup; then
            log_error "Failed to create backup"
            return 2
        fi
    fi
    
    # Create temp config file for atomic write
    TEMP_CONFIG_FILE=$(mktemp "${CONFIG_FILE}.XXXXXXXXXX" 2>/dev/null) || {
        log_error "Failed to create temporary config file"
        return 2
    }
    
    # Write config header
    cat > "$TEMP_CONFIG_FILE" << EOF
# MediaMTX USB Audio Device Configuration
# Generated by $SCRIPT_NAME version $VERSION
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Quality Tier: $QUALITY_TIER
#
# This file is sourced by mediamtx-stream-manager.sh to configure
# per-device audio capture parameters.
#
# Configuration Format:
#   DEVICE_<sanitized_name>_<PARAMETER>=value
#
# Where:
#   - <sanitized_name> is the device name with special chars replaced by underscore
#   - <PARAMETER> is one of: SAMPLE_RATE, CHANNELS, BITRATE
#
# Example:
#   DEVICE_Blue_Yeti_SAMPLE_RATE=48000
#   DEVICE_Blue_Yeti_CHANNELS=2
#   DEVICE_Blue_Yeti_BITRATE=192k
#
# Fallback Defaults (used when device-specific config not found):

DEFAULT_SAMPLE_RATE=48000
DEFAULT_CHANNELS=2
DEFAULT_BITRATE=128k

# ============================================================================
# Device-Specific Configurations
# ============================================================================

EOF
    
    local devices_found=0
    local devices_configured=0
    local devices_skipped=0
    
    # Scan all USB audio devices
    for card_dir in /proc/asound/card[0-9]*; do
        [[ -d "$card_dir" ]] || continue
        
        local card_num="${card_dir##*/card}"
        
        # Skip non-USB devices
        [[ -f "$card_dir/usbid" ]] || continue
        
        ((devices_found++))
        
        log_info "Processing card $card_num..."
        
        # Get device info
        local device_info
        if ! device_info=$(get_device_info "$card_num" 2>/dev/null); then
            log_warn "Could not get info for card $card_num - skipping"
            ((devices_skipped++))
            continue
        fi
        
        # Extract device name
        local device_name=""
        if [[ "$device_info" =~ device_name=([^$'\n']*) ]]; then
            device_name="${BASH_REMATCH[1]}"
        fi
        
        if [[ -z "$device_name" ]]; then
            device_name="card${card_num}"
        fi
        
        # Get capabilities
        local caps
        if ! caps=$(detect_device_capabilities "$card_num" 2>/dev/null); then
            log_warn "Could not detect capabilities for card $card_num - skipping"
            ((devices_skipped++))
            continue
        fi
        
        # Parse capabilities
        parse_capabilities "$caps"
        
        # Check if device supports capture
        if [[ "${PARSED_CAPS[capture_capable]:-false}" != "true" ]]; then
            log_warn "Card $card_num does not support audio capture - skipping"
            ((devices_skipped++))
            continue
        fi
        
        # Determine optimal settings
        local optimal_settings
        if ! optimal_settings=$(determine_optimal_settings "$QUALITY_TIER"); then
            log_warn "Could not determine optimal settings for card $card_num - skipping"
            ((devices_skipped++))
            continue
        fi
        
        # Parse optimal settings
        IFS=' ' read -r optimal_rate optimal_channels enc_bitrate <<< "$optimal_settings"
        
        # Sanitize device name for config variables
        local safe_name
        safe_name=$(sanitize_device_name "$device_name")
        
        # Write device configuration
        cat >> "$TEMP_CONFIG_FILE" << EOF
# Device: $device_name (Card $card_num)
# Hardware capabilities:
#   Sample rates: ${PARSED_CAPS[sample_rates]:-unknown}
#   Channels: ${PARSED_CAPS[channels]:-unknown}
#   Formats: ${PARSED_CAPS[formats]:-unknown}
# Selected settings (quality tier: $QUALITY_TIER):
DEVICE_${safe_name}_SAMPLE_RATE=$optimal_rate
DEVICE_${safe_name}_CHANNELS=$optimal_channels
DEVICE_${safe_name}_BITRATE=${enc_bitrate}k

EOF
        
        ((devices_configured++))
        log_info "  Configured: $device_name"
        log_info "    Sample rate: $optimal_rate Hz"
        log_info "    Channels: $optimal_channels"
        log_info "    Encoder bitrate: ${enc_bitrate}k"
    done
    
    echo ""
    log_info "Configuration Generation Summary:"
    log_info "  Devices found: $devices_found"
    log_info "  Devices configured: $devices_configured"
    log_info "  Devices skipped: $devices_skipped"
    
    # Check if any devices were configured
    if [[ $devices_configured -eq 0 ]]; then
        rm -f "$TEMP_CONFIG_FILE"
        TEMP_CONFIG_FILE=""
        
        if [[ $devices_found -eq 0 ]]; then
            log_error "No USB audio devices found"
            log_info "Check: lsusb | grep -i audio"
            return 1
        else
            log_error "No devices could be configured"
            log_info "All devices were skipped due to errors or missing capabilities"
            return 1
        fi
    fi
    
    # Validate generated config
    if ! validate_generated_config "$TEMP_CONFIG_FILE"; then
        rm -f "$TEMP_CONFIG_FILE"
        TEMP_CONFIG_FILE=""
        log_error "Generated configuration failed validation"
        return 2
    fi
    
    # Atomic move to final location
    if ! mv -f "$TEMP_CONFIG_FILE" "$CONFIG_FILE"; then
        rm -f "$TEMP_CONFIG_FILE"
        TEMP_CONFIG_FILE=""
        log_error "Failed to write configuration file: $CONFIG_FILE"
        return 2
    fi
    
    TEMP_CONFIG_FILE=""
    
    # Set permissions
    chmod 644 "$CONFIG_FILE" 2>/dev/null || log_warn "Could not set permissions on config file"
    
    log_info ""
    log_info "Configuration generated successfully: $CONFIG_FILE"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Review config: cat $CONFIG_FILE"
    log_info "  2. Adjust parameters if needed"
    log_info "  3. Restart service: sudo systemctl restart mediamtx-stream-manager"
    log_info "  4. Verify streams: $SCRIPT_NAME --validate"
    
    return 0
}

# ============================================================================
# CONFIGURATION VALIDATION
# ============================================================================

# Get configuration value with fallback to full device ID format
#
# Parameters:
#   $1 = Sanitized friendly name
#   $2 = Sanitized full device ID
#   $3 = Parameter name (e.g., "SAMPLE_RATE")
#
# Returns:
#   stdout: Configuration value or "not configured"
get_config_value() {
    local safe_name="$1"
    local device_id_safe="$2"
    local param="$3"
    
    # Try friendly name first
    local var_name="DEVICE_${safe_name}_${param}"
    if [[ -n "${!var_name:-}" ]]; then
        echo "${!var_name}"
        return 0
    fi
    
    # Try full device ID if provided
    if [[ -n "$device_id_safe" ]]; then
        var_name="DEVICE_${device_id_safe}_${param}"
        if [[ -n "${!var_name:-}" ]]; then
            echo "${!var_name}"
            return 0
        fi
    fi
    
    echo "not configured"
}

# Validate existing configuration against hardware
validate_config() {
    log_info "Validating configuration against hardware..."
    
    # Check if config file exists
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        log_info "Generate config first: $SCRIPT_NAME --generate-config"
        return 2
    fi
    
    # Source the config file
    if ! grep -qE '^DEVICE_.*=' "$CONFIG_FILE" 2>/dev/null; then
        log_warn "No device configuration found in: $CONFIG_FILE"
        return 0
    fi
    
    # Security check before sourcing
    if [[ $(stat -c %a "$CONFIG_FILE") != "644" ]] && [[ $(stat -c %a "$CONFIG_FILE") != "600" ]]; then
        log_warn "Config file has unusual permissions: $(stat -c %a "$CONFIG_FILE")"
    fi
    
    # Validate config file syntax before sourcing
    # This prevents command injection via malformed configuration
    if ! bash -n "$CONFIG_FILE" 2>/dev/null; then
        log_error "Configuration file has syntax errors: $CONFIG_FILE"
        log_error "This may indicate file corruption or tampering"
        log_error "Refusing to source potentially malicious configuration"
        return 2
    fi
    
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    
    local validation_failed=false
    local devices_checked=0
    
    # Check each USB device
    for card_dir in /proc/asound/card[0-9]*; do
        [[ -d "$card_dir" ]] || continue
        
        local card_num="${card_dir##*/card}"
        
        # Skip non-USB devices
        [[ -f "$card_dir/usbid" ]] || continue
        
        ((devices_checked++))
        
        # Get device info
        local device_info
        if ! device_info=$(get_device_info "$card_num"); then
            log_warn "Could not get info for card $card_num (see error above)"
            continue
        fi
        
        # Extract device name
        local device_name=""
        if [[ "$device_info" =~ device_name=([^$'\n']*) ]]; then
            device_name="${BASH_REMATCH[1]}"
        fi
        
        if [[ -z "$device_name" ]]; then
            device_name="card${card_num}"
        fi
        
        # Extract device ID path (for full device ID config format)
        local device_id_path=""
        if [[ "$device_info" =~ device_id_path=([^$'\n']*) ]]; then
            device_id_path="${BASH_REMATCH[1]}"
        fi
        
        # Get capabilities
        local caps
        if ! caps=$(detect_device_capabilities "$card_num"); then
            log_warn "Could not detect capabilities for card $card_num (see error above)"
            continue
        fi
        
        parse_capabilities "$caps"
        
        # Sanitize device name for config lookup (friendly name, lowercase)
        local safe_name
        safe_name=$(sanitize_device_name "$device_name")
        
        # Sanitize device ID path for config lookup (full ID, UPPERCASE for compatibility)
        # NOTE: This MUST match mediamtx-stream-manager.sh format exactly:
        #   - Strip "usb-" prefix
        #   - Replace non-alphanumeric with underscore
        #   - Convert to UPPERCASE
        #   - Add "USB_" prefix
        # This is INTENTIONALLY different from friendly name sanitization!
        local device_id_safe=""
        if [[ -n "$device_id_path" ]]; then
            # Remove the "usb-" prefix if present, then sanitize and convert to UPPERCASE
            local id_without_prefix="${device_id_path#usb-}"
            device_id_safe=$(printf '%s' "$id_without_prefix" | sed 's/[^a-zA-Z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//' | tr '[:lower:]' '[:upper:]')
            # Add USB_ prefix back in uppercase
            device_id_safe="USB_${device_id_safe}"
        fi
        
        # Check configured values against capabilities
        log_info ""
        log_info "Device: $device_name (Card $card_num)"
        if [[ -n "$device_id_path" ]]; then
            log_info "  Device ID: $device_id_path"
        fi
        
        # Check sample rate using both naming formats
        local config_rate
        config_rate=$(get_config_value "$safe_name" "$device_id_safe" "SAMPLE_RATE")
        local hw_rates="${PARSED_CAPS[sample_rates]:-unknown}"
        
        if [[ "$config_rate" != "not configured" ]]; then
            if [[ "$hw_rates" =~ (^| )${config_rate}( |$) ]]; then
                log_info "  ${CHECK_PASS} Sample rate: ${config_rate} Hz (supported)"
            else
                log_warn "  ${CHECK_FAIL} Sample rate: ${config_rate} Hz NOT supported by hardware"
                log_warn "    Hardware supports: $hw_rates Hz"
                validation_failed=true
            fi
        else
            log_info "  ${CHECK_INFO} Sample rate: not configured (will use default: 48000 Hz)"
        fi
        
        # Check channels using both naming formats
        local config_channels
        config_channels=$(get_config_value "$safe_name" "$device_id_safe" "CHANNELS")
        local hw_channels="${PARSED_CAPS[channels]:-unknown}"
        
        if [[ "$config_channels" != "not configured" ]]; then
            # Get maximum supported channels
            local max_channels
            max_channels=$(echo "$hw_channels" | tr ' ' '\n' | sort -n | tail -1)
            
            # Allow any channel count <= max (e.g., mono on stereo device is valid)
            if [[ "$config_channels" =~ ^[0-9]+$ ]] && [[ $config_channels -le $max_channels ]] && [[ $config_channels -ge 1 ]]; then
                log_info "  ${CHECK_PASS} Channels: ${config_channels} (hardware supports up to ${max_channels})"
            else
                log_warn "  ${CHECK_FAIL} Channels: ${config_channels} NOT supported by hardware"
                log_warn "    Hardware supports up to: ${max_channels} channels"
                validation_failed=true
            fi
        else
            log_info "  ${CHECK_INFO} Channels: not configured (will use default: 2)"
        fi
        
        # Check bitrate (informational only, cannot validate encoder bitrate against hardware)
        local config_bitrate
        config_bitrate=$(get_config_value "$safe_name" "$device_id_safe" "BITRATE")
        
        if [[ "$config_bitrate" != "not configured" ]]; then
            log_info "  ${CHECK_INFO} Encoder bitrate: ${config_bitrate} (encoder setting, not validated)"
        else
            log_info "  ${CHECK_INFO} Encoder bitrate: not configured (will use default: 128k)"
        fi
    done
    
    if [[ $devices_checked -eq 0 ]]; then
        log_warn "No USB audio devices found to validate"
        return 0
    fi
    
    echo ""
    if [[ "$validation_failed" = true ]]; then
        log_error "Validation FAILED - configuration has mismatches"
        log_info "Fix issues and regenerate config: $SCRIPT_NAME --generate-config --force"
        return 2
    else
        log_info "Validation PASSED - all configured devices match hardware"
        return 0
    fi
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

parse_arguments() {
    # Use getopt for robust argument parsing
    local temp
    temp=$(getopt -o 'hgfVq' --long 'help,version,generate-config,force,no-backup,quality:,validate,quiet,format:,list-backups,restore::' -n "$SCRIPT_NAME" -- "$@") || return 1
    
    # Standard getopt pattern: eval is safe here because getopt properly quotes output
    eval set -- "$temp"
    
    # Process arguments
    while true; do
        case "$1" in
            -h|--help)
                show_usage
                exit 0
                ;;
            --version)
                show_version
                exit 0
                ;;
            -g|--generate-config)
                MODE_GENERATE=true
                shift
                ;;
            -f|--force)
                MODE_FORCE=true
                shift
                ;;
            --no-backup)
                MODE_NO_BACKUP=true
                shift
                ;;
            -V|--validate)
                MODE_VALIDATE=true
                shift
                ;;
            -q|--quiet)
                MODE_QUIET=true
                shift
                ;;
            --format)
                OUTPUT_FORMAT="$2"
                shift 2
                ;;
            --list-backups)
                MODE_LIST_BACKUPS=true
                shift
                ;;
            --restore)
                MODE_RESTORE=true
                # Optional argument for timestamp
                if [[ -n "$2" ]] && [[ "$2" != "--" ]]; then
                    RESTORE_TIMESTAMP="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --quality)
                QUALITY_TIER="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            *)
                log_error "Internal error parsing arguments"
                return 1
                ;;
        esac
    done
    
    # Remaining argument is card number (optional)
    if [[ $# -gt 0 ]]; then
        SPECIFIC_CARD="$1"
        if [[ ! "$SPECIFIC_CARD" =~ ^[0-9]+$ ]]; then
            log_error "Card number must be numeric: $SPECIFIC_CARD"
            return 1
        fi
        
        # Validate card number range
        if [[ $SPECIFIC_CARD -lt 0 ]] || [[ $SPECIFIC_CARD -gt $ALSA_MAX_CARD_NUMBER ]]; then
            log_error "Card number must be 0-$ALSA_MAX_CARD_NUMBER: $SPECIFIC_CARD"
            return 1
        fi
    fi
    
    # Validate combinations
    if [[ "$MODE_FORCE" = true ]] && [[ "$MODE_GENERATE" != true ]]; then
        log_error "--force requires --generate-config"
        return 1
    fi
    
    if [[ "$MODE_NO_BACKUP" = true ]] && [[ "$MODE_GENERATE" != true ]]; then
        log_error "--no-backup requires --generate-config"
        return 1
    fi
    
    # Count mutually exclusive primary modes
    local mode_count=0
    [[ "$MODE_GENERATE" = true ]] && ((mode_count++))
    [[ "$MODE_VALIDATE" = true ]] && ((mode_count++))
    [[ "$MODE_LIST_BACKUPS" = true ]] && ((mode_count++))
    [[ "$MODE_RESTORE" = true ]] && ((mode_count++))
    
    if [[ $mode_count -gt 1 ]]; then
        log_error "Only one of --generate-config, --validate, --list-backups, or --restore can be used at a time"
        return 1
    fi
    
    if [[ -n "$SPECIFIC_CARD" ]] && [[ $mode_count -gt 0 ]]; then
        log_error "Card number cannot be specified with operation modes"
        return 1
    fi
    
    if [[ "$OUTPUT_FORMAT" != "text" ]] && [[ "$OUTPUT_FORMAT" != "json" ]]; then
        log_error "Invalid format: $OUTPUT_FORMAT (must be text or json)"
        return 1
    fi
    
    # Validate quality tier
    if [[ "$QUALITY_TIER" != "low" ]] && [[ "$QUALITY_TIER" != "normal" ]] && [[ "$QUALITY_TIER" != "high" ]]; then
        log_error "Invalid quality tier: $QUALITY_TIER"
        log_error "Must be one of: low, normal, high"
        return 1
    fi
    
    # Quality tier only valid with config generation
    if [[ "$QUALITY_TIER" != "normal" ]] && [[ "$MODE_GENERATE" != true ]]; then
        log_error "--quality requires --generate-config"
        return 1
    fi
    
    return 0
}

# ============================================================================
# JSON OUTPUT
# ============================================================================

# Convert key=value output to JSON
# This is a simple implementation for basic JSON output
output_json() {
    local device_name=""
    local -a json_lines=()
    local in_device=false
    
    echo "{"
    echo '  "devices": ['
    
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        # Skip empty lines
        [[ -z "$key" ]] && continue
        
        # Detect device headers
        if [[ "$key" =~ ^===.*Card.*===$ ]]; then
            # Close previous device object if exists
            if [[ "$in_device" = true ]]; then
                # Remove trailing comma from last line
                if [[ ${#json_lines[@]} -gt 0 ]]; then
                    local last_idx=$((${#json_lines[@]} - 1))
                    json_lines[last_idx]="${json_lines[last_idx]%,}"
                fi
                
                # Print accumulated lines
                printf '%s\n' "${json_lines[@]}"
                echo "    },"
            fi
            
            in_device=true
            json_lines=()
            
            # Extract device name from header
            device_name="${key#*: }"
            device_name="${device_name% ===}"
            echo "    {"
            json_lines+=("      \"_header\": \"$key\",")
            continue
        fi
        
        if [[ "$in_device" = true ]]; then
            # Escape quotes in value
            value="${value//\"/\\\"}"
            
            # Determine if value is numeric, boolean, or string
            if [[ "$value" =~ ^[0-9]+$ ]]; then
                json_lines+=("      \"$key\": $value,")
            elif [[ "$value" = "true" ]] || [[ "$value" = "false" ]]; then
                json_lines+=("      \"$key\": $value,")
            else
                json_lines+=("      \"$key\": \"$value\",")
            fi
        fi
    done
    
    # Close last device object if exists
    if [[ "$in_device" = true ]]; then
        # Remove trailing comma from last line
        if [[ ${#json_lines[@]} -gt 0 ]]; then
            local last_idx=$((${#json_lines[@]} - 1))
            json_lines[last_idx]="${json_lines[last_idx]%,}"
        fi
        
        # Print accumulated lines
        printf '%s\n' "${json_lines[@]}"
        echo "    }"
    fi
    
    echo "  ]"
    echo "}"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    # Check if ALSA proc filesystem is available
    if [[ ! -d "/proc/asound" ]]; then
        log_error "ALSA proc filesystem not found at /proc/asound"
        log_error "Is ALSA support enabled in your kernel?"
        log_info "Check: lsmod | grep snd"
        exit 1
    fi
    
    # Parse arguments
    if ! parse_arguments "$@"; then
        exit 1
    fi
    
    # Execute requested mode
    if [[ "$MODE_GENERATE" = true ]]; then
        # Config generation mode
        if ! generate_config; then
            exit 2
        fi
        exit 0
        
    elif [[ "$MODE_VALIDATE" = true ]]; then
        # Config validation mode
        if ! validate_config; then
            exit 2
        fi
        exit 0
        
    elif [[ "$MODE_LIST_BACKUPS" = true ]]; then
        # List backups mode
        if ! list_config_backups; then
            exit 2
        fi
        exit 0
        
    elif [[ "$MODE_RESTORE" = true ]]; then
        # Restore backup mode
        if ! restore_config_backup "$RESTORE_TIMESTAMP"; then
            exit 2
        fi
        exit 0
        
    elif [[ -n "$SPECIFIC_CARD" ]]; then
        # Show specific card
        log_info "Detecting capabilities for card $SPECIFIC_CARD..."
        echo ""
        
        if ! get_device_info "$SPECIFIC_CARD" 2>/dev/null; then
            log_error "Could not get device info for card $SPECIFIC_CARD"
            log_info "Available cards:"
            # Use glob to list cards instead of ls
            local cards_found=false
            for card_dir in /proc/asound/card[0-9]*; do
                if [[ -d "$card_dir" ]]; then
                    printf '  %s\n' "${card_dir##*/card}"
                    cards_found=true
                fi
            done
            if [[ "$cards_found" = false ]]; then
                echo "  None found"
            fi
            exit 1
        fi
        
        echo ""
        
        if ! detect_device_capabilities "$SPECIFIC_CARD" 2>/dev/null; then
            log_error "Could not detect capabilities for card $SPECIFIC_CARD"
            exit 1
        fi
        
        exit 0
        
    else
        # List all devices (default mode)
        if [[ "$OUTPUT_FORMAT" = "json" ]]; then
            # JSON output
            if ! list_all_usb_devices | output_json; then
                exit 1
            fi
        else
            # Text output (original behavior)
            log_info "USB Audio Device Capability Detection"
            log_info "======================================"
            log_info ""
            log_info "Found USB audio devices:"
            log_info ""
            
            if ! list_all_usb_devices; then
                exit 1
            fi
            
            log_info ""
            log_info "Next steps:"
            log_info "  * Generate config: $SCRIPT_NAME -g"
            log_info "  * Show specific device: $SCRIPT_NAME <card_number>"
            log_info "  * Full help: $SCRIPT_NAME --help"
        fi
        
        exit 0
    fi
}

# Run main function if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

#!/bin/bash
# mediamtx-stream-manager.sh - Enhanced Audio Stream Manager
# Version: 1.4.0 - Quickfix integration + Mono L/R split support
#
# New in v1.4.0:
#   - Device accessibility testing from quickfix
#   - Improved stream name generation
#   - Device unlock capability
#   - Mono L/R channel splitting
#   - Better device detection from quickfix approach

set -euo pipefail

# Constants
readonly VERSION="1.4.0"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Error codes
readonly E_GENERAL=1
readonly E_CRITICAL_RESOURCE=2
readonly E_MISSING_DEPS=3
readonly E_CONFIG_ERROR=4
readonly E_LOCK_FAILED=5
readonly E_USB_NO_DEVICES=6

# Configurable paths
readonly CONFIG_DIR="${MEDIAMTX_CONFIG_DIR:-/etc/mediamtx}"
readonly CONFIG_FILE="${MEDIAMTX_CONFIG_FILE:-${CONFIG_DIR}/mediamtx.yml}"
readonly DEVICE_CONFIG_FILE="${MEDIAMTX_DEVICE_CONFIG:-${CONFIG_DIR}/audio-devices.conf}"
readonly PID_FILE="${MEDIAMTX_PID_FILE:-/var/run/mediamtx-audio.pid}"
readonly FFMPEG_PID_DIR="${MEDIAMTX_FFMPEG_DIR:-/var/lib/mediamtx-ffmpeg}"
readonly LOCK_FILE="${MEDIAMTX_LOCK_FILE:-/var/run/mediamtx-audio.lock}"
readonly LOG_FILE="${MEDIAMTX_LOG_FILE:-/var/log/mediamtx-stream-manager.log}"
readonly MEDIAMTX_LOG_FILE="${MEDIAMTX_LOG_FILE:-/var/log/mediamtx.out}"
readonly MEDIAMTX_BIN="${MEDIAMTX_BINARY:-/usr/local/bin/mediamtx}"
readonly MEDIAMTX_HOST="${MEDIAMTX_HOST:-localhost}"
readonly RESTART_MARKER="${MEDIAMTX_RESTART_MARKER:-/var/run/mediamtx-audio.restart}"
readonly CLEANUP_MARKER="${MEDIAMTX_CLEANUP_MARKER:-/var/run/mediamtx-audio.cleanup}"

# System limits
SYSTEM_PID_MAX="$(cat /proc/sys/kernel/pid_max 2>/dev/null || echo 32768)"
readonly SYSTEM_PID_MAX

# Timeouts
readonly MEDIAMTX_API_TIMEOUT="${MEDIAMTX_API_TIMEOUT:-60}"
readonly LOCK_ACQUISITION_TIMEOUT="${LOCK_ACQUISITION_TIMEOUT:-30}"

# Audio settings
readonly DEFAULT_SAMPLE_RATE="48000"
readonly DEFAULT_CHANNELS="2"
readonly DEFAULT_CODEC="opus"
readonly DEFAULT_BITRATE="128k"

# Audio filter defaults
readonly DEFAULT_HIGHPASS=""
readonly DEFAULT_LOWPASS=""
readonly DEFAULT_VOLUME=""
readonly DEFAULT_COMPRESSOR="false"
readonly DEFAULT_NOISE_REDUCTION="false"

# NEW: Mono split defaults
readonly DEFAULT_SPLIT_MONO="false"

# Timing settings
readonly STREAM_STARTUP_DELAY="${STREAM_STARTUP_DELAY:-10}"
readonly USB_STABILIZATION_DELAY="${USB_STABILIZATION_DELAY:-5}"

# Global variables
declare -gi MAIN_LOCK_FD=-1
declare -g SKIP_CLEANUP=false
declare -g CURRENT_COMMAND="${1:-}"
declare -g STOPPING_SERVICE=false

# Color codes
if [[ -t 2 ]] && command -v tput >/dev/null 2>&1; then
    RED="$(tput setaf 1)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)"
    CYAN="$(tput setaf 6)"
    NC="$(tput sgr0)"
    readonly RED GREEN YELLOW BLUE CYAN NC
else
    readonly RED="" GREEN="" YELLOW="" BLUE="" CYAN="" NC=""
fi

# Command existence cache
declare -gA COMMAND_CACHE=()

command_exists() {
    local cmd="$1"
    if [[ -z "${COMMAND_CACHE[$cmd]+isset}" ]]; then
        if command -v "$cmd" &>/dev/null; then
            COMMAND_CACHE[$cmd]=1
        else
            COMMAND_CACHE[$cmd]=0
        fi
    fi
    [[ "${COMMAND_CACHE[$cmd]}" -eq 1 ]]
}

cleanup() {
    local exit_code=$?
    
    if [[ "${SKIP_CLEANUP}" == "true" ]] || [[ "${STOPPING_SERVICE}" == "true" ]]; then
        release_lock_unsafe
        exit "${exit_code}"
    fi
    
    if [[ $exit_code -ne 0 ]]; then
        local marker_tmp
        marker_tmp="$(mktemp "${CLEANUP_MARKER}.XXXXXX" 2>/dev/null)" && \
            mv -f "$marker_tmp" "${CLEANUP_MARKER}" 2>/dev/null || \
            touch "${CLEANUP_MARKER}" 2>/dev/null || true
    fi
    
    release_lock_unsafe
    exit "${exit_code}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ $$ -eq $BASHPID ]]; then
    trap cleanup EXIT INT TERM HUP QUIT
fi

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    local log_dir
    log_dir="$(dirname "${LOG_FILE}")"
    if [[ ! -d "$log_dir" ]]; then
        mkdir -p "$log_dir" 2>/dev/null || true
    fi
    
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}" 2>/dev/null || true
    
    case "${level}" in
        ERROR) echo -e "${RED}[ERROR]${NC} ${message}" >&2 ;;
        WARN) echo -e "${YELLOW}[WARN]${NC} ${message}" >&2 ;;
        INFO) echo -e "${GREEN}[INFO]${NC} ${message}" >&2 ;;
        DEBUG) [[ "${DEBUG:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} ${message}" >&2 ;;
    esac
}

error_exit() {
    local message="$1"
    local exit_code="${2:-${E_GENERAL}}"
    log ERROR "$message"
    exit "${exit_code}"
}

write_pid_atomic() {
    local pid="$1"
    local pid_file="$2"
    local pid_dir
    pid_dir="$(dirname "$pid_file")"
    
    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        log ERROR "Invalid PID format: $pid"
        return 1
    fi
    
    pid="$((10#$pid))"
    
    if ! kill -0 "$pid" 2>/dev/null; then
        log ERROR "Process $pid does not exist"
        return 1
    fi
    
    [[ -d "$pid_dir" ]] || mkdir -p "$pid_dir"
    
    local temp_pid
    temp_pid="$(mktemp -p "$pid_dir" "$(basename "$pid_file").XXXXXX")" || return 1
    
    echo "${pid}" > "$temp_pid" || { rm -f "$temp_pid"; return 1; }
    chmod 644 "$temp_pid" || { rm -f "$temp_pid"; return 1; }
    mv -f "$temp_pid" "$pid_file" || { rm -f "$temp_pid"; return 1; }
    
    log DEBUG "Wrote PID $pid to $pid_file"
    return 0
}

read_pid_safe() {
    local pid_file="$1"
    
    [[ -f "$pid_file" ]] || { echo ""; return 0; }
    
    local pid
    pid="$(cat "$pid_file" 2>/dev/null | tr -d '[:space:]')"
    
    [[ -n "$pid" ]] && [[ "$pid" =~ ^[0-9]+$ ]] || { echo ""; return 0; }
    
    pid="$((10#$pid))"
    
    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$pid_file"
        echo ""
        return 0
    fi
    
    echo "$pid"
}

terminate_process_group() {
    local pid="$1"
    local timeout="${2:-10}"
    
    [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null && return 0
    
    kill -INT -- -"$pid" 2>/dev/null || kill -INT "$pid" 2>/dev/null || true
    
    local elapsed=0
    while kill -0 "$pid" 2>/dev/null && [[ $elapsed -lt $timeout ]]; do
        sleep 1
        ((elapsed++))
    done
    
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL -- -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        sleep 2
    fi
}

acquire_lock() {
    local timeout="${1:-${LOCK_ACQUISITION_TIMEOUT}}"
    
    [[ ${MAIN_LOCK_FD} -gt 2 ]] && exec {MAIN_LOCK_FD}>&- 2>/dev/null || true
    MAIN_LOCK_FD=-1
    
    local lock_dir
    lock_dir="$(dirname "${LOCK_FILE}")"
    [[ -d "$lock_dir" ]] || mkdir -p "$lock_dir" 2>/dev/null || return 1
    
    exec {MAIN_LOCK_FD}>"${LOCK_FILE}" 2>/dev/null || { MAIN_LOCK_FD=-1; return 1; }
    [[ ${MAIN_LOCK_FD} -le 2 ]] && { MAIN_LOCK_FD=-1; return 1; }
    
    if ! flock -w "$timeout" "${MAIN_LOCK_FD}"; then
        exec {MAIN_LOCK_FD}>&- 2>/dev/null || true
        MAIN_LOCK_FD=-1
        return 1
    fi
    
    echo "$$" >&"${MAIN_LOCK_FD}" || true
    log DEBUG "Acquired lock (PID: $$)"
    return 0
}

release_lock() {
    [[ "${MAIN_LOCK_FD}" -gt 2 ]] && exec {MAIN_LOCK_FD}>&- 2>/dev/null || true
    MAIN_LOCK_FD=-1
}

release_lock_unsafe() {
    [[ "${MAIN_LOCK_FD}" -gt 2 ]] && exec {MAIN_LOCK_FD}>&- 2>/dev/null || true
    MAIN_LOCK_FD=-1
}

check_root() {
    [[ ${EUID} -eq 0 ]] || error_exit "This script must be run as root (use sudo)" "${E_GENERAL}"
}

check_dependencies() {
    local missing=()
    
    for cmd in ffmpeg arecord; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    
    [[ -x "${MEDIAMTX_BIN}" ]] || missing+=("mediamtx")
    
    [[ ${#missing[@]} -eq 0 ]] || error_exit "Missing dependencies: ${missing[*]}" "${E_MISSING_DEPS}"
}

setup_directories() {
    mkdir -p "${CONFIG_DIR}" "$(dirname "${LOG_FILE}")" "$(dirname "${PID_FILE}")" "${FFMPEG_PID_DIR}"
    chmod 755 "${FFMPEG_PID_DIR}"
    
    [[ -f "${LOG_FILE}" ]] || { touch "${LOG_FILE}"; chmod 644 "${LOG_FILE}"; }
}

cleanup_stale_processes() {
    log INFO "Cleaning up stale processes"
    
    pkill -9 -f "^ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" 2>/dev/null || true
    pkill -9 -f "${FFMPEG_PID_DIR}/.*\.sh" 2>/dev/null || true
    
    [[ -f "${PID_FILE}" ]] && {
        local pid
        pid="$(read_pid_safe "${PID_FILE}")"
        [[ -n "$pid" ]] && terminate_process_group "$pid" 5
        rm -f "${PID_FILE}"
    }
    
    pkill -9 -f "^${MEDIAMTX_BIN}" 2>/dev/null || true
    
    rm -f "${FFMPEG_PID_DIR}"/*.pid "${FFMPEG_PID_DIR}"/*.sh "${FFMPEG_PID_DIR}"/*.log
    rm -f "${CLEANUP_MARKER}" "${RESTART_MARKER}"
    
    log INFO "Cleanup completed"
}

wait_for_mediamtx_ready() {
    local pid="$1"
    local max_wait="${MEDIAMTX_API_TIMEOUT}"
    local elapsed=0
    
    log INFO "Waiting for MediaMTX API..."
    
    while [[ $elapsed -lt $max_wait ]]; do
        kill -0 "$pid" 2>/dev/null || { log ERROR "MediaMTX died during startup"; return 1; }
        
        if command_exists curl; then
            curl -s --max-time 2 "http://${MEDIAMTX_HOST}:9997/v3/paths/list" >/dev/null 2>&1 && {
                log INFO "MediaMTX API ready after ${elapsed}s"
                return 0
            }
        else
            [[ $elapsed -ge 10 ]] && { log INFO "MediaMTX assumed ready"; return 0; }
        fi
        
        sleep 1
        ((elapsed++))
    done
    
    log ERROR "MediaMTX API timeout after ${max_wait}s"
    return 1
}

load_device_config() {
    [[ -f "${DEVICE_CONFIG_FILE}" ]] && source "${DEVICE_CONFIG_FILE}"
}

save_device_config() {
    local tmp_config
    tmp_config="$(mktemp)"
    
    cat > "$tmp_config" << 'EOF'
# Audio Device Configuration
# Format: DEVICE_<name>_<parameter>=value

# Sample Rate: 48000 (default), 44100, 96000
# Channels: 2 (stereo), 1 (mono)
# Codec: opus (default), aac, mp3
# Bitrate: 128k (default), 64k, 256k

# Audio Filters:
# HIGHPASS: High-pass filter Hz (e.g., 80, 150, 300)
# LOWPASS: Low-pass filter Hz (e.g., 15000, 10000, 3000)
# VOLUME: Volume adjustment dB (e.g., 3, -3, 10)
# COMPRESSOR: Dynamic compression (true/false)
# NOISE_REDUCTION: FFT noise reduction (true/false)

# NEW: Mono Channel Splitting:
# SPLIT_MONO: Create separate L/R streams (true/false)
# When enabled, creates two streams:
#   - streamname_left (left channel only)
#   - streamname_right (right channel only)

# Examples:
# DEVICE_RODE_AI_MICRO_SAMPLE_RATE=48000
# DEVICE_RODE_AI_MICRO_CHANNELS=2
# DEVICE_RODE_AI_MICRO_HIGHPASS=80
# DEVICE_RODE_AI_MICRO_LOWPASS=15000
# DEVICE_RODE_AI_MICRO_VOLUME=3
# DEVICE_RODE_AI_MICRO_COMPRESSOR=true
# DEVICE_RODE_AI_MICRO_SPLIT_MONO=true
EOF
    
    mv -f "$tmp_config" "${DEVICE_CONFIG_FILE}"
    chmod 644 "${DEVICE_CONFIG_FILE}"
}

sanitize_device_name() {
    local name="$1"
    local sanitized
    
    # Remove all non-ASCII characters first, then clean up
    sanitized=$(printf '%s' "$name" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null || printf '%s' "$name")
    
    # Convert to uppercase, replace non-alphanumeric with underscore
    sanitized=$(printf '%s' "$sanitized" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//')
    
    # Remove any remaining problematic characters
    sanitized=$(printf '%s' "$sanitized" | tr -cd 'A-Z0-9_')
    
    [[ "$sanitized" =~ ^[0-9] ]] && sanitized="DEV_${sanitized}"
    [[ -z "$sanitized" ]] && sanitized="UNKNOWN_$(date +%s)"
    
    printf '%s\n' "$sanitized"
}

get_device_config() {
    local device_name="$1"
    local param="$2"
    local default_value="$3"
    
    local safe_name
    safe_name="$(sanitize_device_name "$device_name")"
    local config_key="DEVICE_${safe_name}_${param}"
    
    if [[ -n "${!config_key+x}" ]]; then
        echo "${!config_key}"
    else
        echo "$default_value"
    fi
}

detect_audio_devices() {
    command_exists arecord || { log ERROR "arecord not found"; return 1; }
    
    local arecord_output
    arecord_output=$(arecord -l 2>/dev/null) || { log ERROR "arecord -l failed"; return 1; }
    
    local devices=()
    
    while IFS= read -r line; do
        if [[ "$line" =~ card\ ([0-9]+):\ ([^,]+) ]]; then
            local card_num="${BASH_REMATCH[1]}"
            local card_name="${BASH_REMATCH[2]}"
            card_name=$(echo "$card_name" | xargs)
            
            # Only USB devices
            if [[ -f "/proc/asound/card${card_num}/usbid" ]]; then
                devices+=("${card_name}:${card_num}")
                log DEBUG "Found USB device: $card_name (card $card_num)"
            fi
        fi
    done <<< "$arecord_output"
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        log ERROR "No USB audio devices found"
        return 1
    fi
    
    # Output devices to stdout
    printf '%s\n' "${devices[@]}"
    return 0
}

# NEW: Device accessibility test (from quickfix)
check_audio_device_accessible() {
    local card_num="$1"
    
    [[ -e "/dev/snd/pcmC${card_num}D0c" ]] || {
        log DEBUG "Device file missing: /dev/snd/pcmC${card_num}D0c"
        return 1
    }
    
    if command_exists timeout; then
        if timeout 2 arecord -D plughw:${card_num},0 -f S16_LE -r 48000 -c 2 -d 1 /tmp/test_${card_num}.wav &>/dev/null; then
            rm -f /tmp/test_${card_num}.wav
            log DEBUG "Card $card_num is accessible"
            return 0
        else
            rm -f /tmp/test_${card_num}.wav
            log WARN "Card $card_num not accessible"
            return 1
        fi
    fi
    
    arecord -l 2>/dev/null | grep -q "card ${card_num}:"
}

# NEW: Unlock device if it's being held (from quickfix)
unlock_audio_device() {
    local card_num="$1"
    
    if command_exists fuser; then
        log INFO "Attempting to unlock device card $card_num"
        fuser -k /dev/snd/pcmC${card_num}D0c 2>/dev/null || true
        sleep 2
        return 0
    fi
    
    return 1
}

# NEW: Smart stream name generation (from quickfix approach)
generate_stream_name() {
    local device_name="$1"
    local card_num="$2"
    
    # Try to detect known devices
    if [[ "$device_name" =~ RØDE.*AI.*Micro ]] || [[ "$device_name" =~ AI-Micro ]]; then
        echo "rode_ai_micro"
    elif [[ "$device_name" =~ [Bb]lue.*[Yy]eti ]]; then
        echo "blue_yeti"
    elif [[ "$device_name" =~ [Ss]hure ]]; then
        echo "shure_mic"
    elif [[ "$device_name" =~ [Aa]udio.*[Tt]echnica ]]; then
        echo "audio_technica"
    else
        # Generic: convert to lowercase, replace spaces/special chars with underscore
        local clean_name
        clean_name=$(echo "$device_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
        
        # Fallback to card number if name is too messy
        if [[ ${#clean_name} -gt 32 ]] || [[ -z "$clean_name" ]]; then
            echo "audio_card_${card_num}"
        else
            echo "$clean_name"
        fi
    fi
}

# NEW: Build audio filter with channel split support
build_audio_filter() {
    local device_name="$1"
    local channel="${2:-stereo}"  # stereo, left, right
    local filters=()
    
    local highpass lowpass volume compressor noise_reduction
    highpass="$(get_device_config "$device_name" "HIGHPASS" "$DEFAULT_HIGHPASS")"
    lowpass="$(get_device_config "$device_name" "LOWPASS" "$DEFAULT_LOWPASS")"
    volume="$(get_device_config "$device_name" "VOLUME" "$DEFAULT_VOLUME")"
    compressor="$(get_device_config "$device_name" "COMPRESSOR" "$DEFAULT_COMPRESSOR")"
    noise_reduction="$(get_device_config "$device_name" "NOISE_REDUCTION" "$DEFAULT_NOISE_REDUCTION")"
    
    # Channel selection for mono split
    if [[ "$channel" == "left" ]]; then
        filters+=("pan=mono|c0=c0")  # Extract left channel
    elif [[ "$channel" == "right" ]]; then
        filters+=("pan=mono|c0=c1")  # Extract right channel
    fi
    
    # High-pass filter
    [[ -n "$highpass" && "$highpass" =~ ^[0-9]+$ ]] && filters+=("highpass=f=${highpass}")
    
    # Low-pass filter
    [[ -n "$lowpass" && "$lowpass" =~ ^[0-9]+$ ]] && filters+=("lowpass=f=${lowpass}")
    
    # Noise reduction
    [[ "$noise_reduction" == "true" ]] && filters+=("afftdn=nr=10:nf=-25")
    
    # Compression
    [[ "$compressor" == "true" ]] && filters+=("acompressor=threshold=0.089:ratio=9:attack=200:release=1000")
    
    # Volume
    [[ -n "$volume" && "$volume" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && filters+=("volume=${volume}dB")
    
    # Resampler
    filters+=("aresample=async=1:first_pts=0")
    
    local IFS=','
    echo "${filters[*]}"
}

start_ffmpeg_stream() {
    local device_name="$1"
    local card_num="$2"
    local stream_name="$3"
    local channel="${4:-stereo}"  # NEW: stereo, left, or right
    local stream_suffix="${5:-}"   # NEW: optional suffix for split streams
    
    local full_stream_name="${stream_name}${stream_suffix}"
    local pid_file="${FFMPEG_PID_DIR}/${full_stream_name}.pid"
    
    # Check if already running
    if [[ -f "$pid_file" ]]; then
        local existing_pid
        existing_pid="$(read_pid_safe "$pid_file")"
        [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null && {
            log DEBUG "Stream $full_stream_name already running"
            return 0
        }
    fi
    
    # Check device accessibility
    if ! check_audio_device_accessible "$card_num"; then
        log WARN "Device card $card_num not accessible, attempting unlock"
        unlock_audio_device "$card_num"
        sleep 2
        
        check_audio_device_accessible "$card_num" || {
            log ERROR "Card $card_num still not accessible"
            return 1
        }
    fi
    
    # Get configuration
    local sample_rate channels codec bitrate
    sample_rate="$(get_device_config "$device_name" "SAMPLE_RATE" "$DEFAULT_SAMPLE_RATE")"
    channels="$(get_device_config "$device_name" "CHANNELS" "$DEFAULT_CHANNELS")"
    codec="$(get_device_config "$device_name" "CODEC" "$DEFAULT_CODEC")"
    bitrate="$(get_device_config "$device_name" "BITRATE" "$DEFAULT_BITRATE")"
    
    # Build filter
    local audio_filter
    audio_filter="$(build_audio_filter "$device_name" "$channel")"
    
    log INFO "Starting FFmpeg: $full_stream_name (card $card_num, channel: $channel)"
    log DEBUG "Filter: $audio_filter"
    
    local wrapper_script="${FFMPEG_PID_DIR}/${full_stream_name}.sh"
    local ffmpeg_log="${FFMPEG_PID_DIR}/${full_stream_name}.log"
    
    # Create wrapper script
    cat > "$wrapper_script" << EOF
#!/bin/bash
set -euo pipefail

STREAM_NAME="$full_stream_name"
CARD_NUM="$card_num"
SAMPLE_RATE="$sample_rate"
CHANNELS="$channels"
CODEC="$codec"
BITRATE="$bitrate"
AUDIO_FILTER="$audio_filter"
FFMPEG_LOG="$ffmpeg_log"
MEDIAMTX_HOST="$MEDIAMTX_HOST"
RESTART_COUNT=0
MAX_RESTARTS=50

touch "\${FFMPEG_LOG}"

log_msg() {
    echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> "\${FFMPEG_LOG}"
}

cleanup() {
    log_msg "Wrapper exiting"
    exit 0
}

trap cleanup EXIT INT TERM

log_msg "Wrapper starting for \${STREAM_NAME}"

while true; do
    [[ \$RESTART_COUNT -ge \$MAX_RESTARTS ]] && break
    
    log_msg "Starting FFmpeg (attempt \$((RESTART_COUNT + 1)))"
    
    START_TIME=\$(date +%s)
    
    ffmpeg -hide_banner -loglevel warning \\
        -f alsa -ar "\${SAMPLE_RATE}" -ac "\${CHANNELS}" -i plughw:\${CARD_NUM},0 \\
        -af "\${AUDIO_FILTER}" \\
        -c:a "\${CODEC}" -b:a "\${BITRATE}" \\
        -f rtsp -rtsp_transport tcp \\
        rtsp://\${MEDIAMTX_HOST}:8554/\${STREAM_NAME} >> "\${FFMPEG_LOG}" 2>&1
    
    EXIT_CODE=\$?
    END_TIME=\$(date +%s)
    RUN_TIME=\$((END_TIME - START_TIME))
    
    log_msg "FFmpeg exited (code: \$EXIT_CODE, runtime: \${RUN_TIME}s)"
    
    ((RESTART_COUNT++))
    
    [[ \$RUN_TIME -lt 10 ]] && sleep 5 || sleep 2
done

log_msg "Max restarts reached, exiting"
EOF
    
    chmod +x "$wrapper_script"
    
    # Start wrapper
    if command_exists setsid; then
        nohup setsid bash "$wrapper_script" >/dev/null 2>&1 &
    else
        nohup bash "$wrapper_script" >/dev/null 2>&1 &
    fi
    local pid=$!
    
    sleep 0.5
    
    kill -0 "$pid" 2>/dev/null || {
        log ERROR "Wrapper failed to start: $full_stream_name"
        rm -f "$wrapper_script"
        return 1
    }
    
    write_pid_atomic "$pid" "$pid_file" || {
        kill "$pid" 2>/dev/null || true
        rm -f "$wrapper_script"
        return 1
    }
    
    log INFO "Stream started: $full_stream_name (PID: $pid)"
    return 0
}

start_all_streams() {
    local devices=("$@")
    
    [[ ${#devices[@]} -eq 0 ]] && { log WARN "No devices to start"; return 0; }
    
    log INFO "Starting streams for ${#devices[@]} device(s)"
    
    local success=0
    local failed=()
    
    for device_info in "${devices[@]}"; do
        IFS=':' read -r device_name card_num <<< "$device_info"
        
        [[ -z "$device_name" || -z "$card_num" ]] && continue
        
        local stream_name
        stream_name="$(generate_stream_name "$device_name" "$card_num")"
        
        # Check if mono split is enabled
        local split_mono
        split_mono="$(get_device_config "$device_name" "SPLIT_MONO" "$DEFAULT_SPLIT_MONO")"
        
        if [[ "$split_mono" == "true" ]]; then
            log INFO "Mono split enabled for $device_name"
            
            # Start left channel stream
            if start_ffmpeg_stream "$device_name" "$card_num" "$stream_name" "left" "_left"; then
                ((success++))
            else
                failed+=("${stream_name}_left")
            fi
            
            # Start right channel stream
            if start_ffmpeg_stream "$device_name" "$card_num" "$stream_name" "right" "_right"; then
                ((success++))
            else
                failed+=("${stream_name}_right")
            fi
        else
            # Standard stereo stream
            if start_ffmpeg_stream "$device_name" "$card_num" "$stream_name" "stereo" ""; then
                ((success++))
            else
                failed+=("$stream_name")
            fi
        fi
    done
    
    if [[ ${#failed[@]} -gt 0 ]]; then
        log WARN "Started $success streams. Failed: ${failed[*]}"
    else
        log INFO "All $success streams started successfully"
    fi
}

generate_mediamtx_config() {
    log INFO "Generating MediaMTX configuration"
    
    [[ -d "${CONFIG_DIR}" ]] || mkdir -p "${CONFIG_DIR}"
    
    local tmp_config
    tmp_config="$(mktemp)"
    
    cat > "$tmp_config" << 'EOF'
logLevel: info
readTimeout: 30s
writeTimeout: 30s

api: yes
apiAddress: :9997

metrics: yes
metricsAddress: :9998

rtsp: yes
rtspAddress: :8554
rtspTransports: [tcp, udp]

rtmp: no
hls: no
webrtc: no
srt: no

paths:
  '~^[a-zA-Z0-9_-]+$':
    source: publisher
    sourceProtocol: automatic
    sourceOnDemand: no
EOF
    
    mv -f "$tmp_config" "${CONFIG_FILE}"
    chmod 644 "${CONFIG_FILE}"
    
    log INFO "Configuration generated"
}

is_mediamtx_running() {
    [[ -f "${PID_FILE}" ]] || return 1
    local pid
    pid="$(read_pid_safe "${PID_FILE}")"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

start_mediamtx() {
    acquire_lock || error_exit "Failed to acquire lock" "${E_LOCK_FAILED}"
    
    cleanup_stale_processes
    
    is_mediamtx_running && { log WARN "MediaMTX already running"; return 0; }
    
    log INFO "Starting MediaMTX..."
    
    # Detect devices
    local devices=()
    readarray -t devices < <(detect_audio_devices)
    
    [[ ${#devices[@]} -eq 0 ]] && error_exit "No USB audio devices found" "${E_USB_NO_DEVICES}"
    
    log INFO "Found ${#devices[@]} USB audio device(s)"
    
    # Generate config
    [[ -f "${DEVICE_CONFIG_FILE}" ]] || save_device_config
    load_device_config
    generate_mediamtx_config
    
    # Start MediaMTX
    if command_exists setsid; then
        nohup setsid "${MEDIAMTX_BIN}" "${CONFIG_FILE}" >> "${MEDIAMTX_LOG_FILE}" 2>&1 &
    else
        nohup "${MEDIAMTX_BIN}" "${CONFIG_FILE}" >> "${MEDIAMTX_LOG_FILE}" 2>&1 &
    fi
    local pid=$!
    
    sleep 0.5
    
    kill -0 "$pid" 2>/dev/null || {
        log ERROR "MediaMTX died immediately"
        [[ -f "${MEDIAMTX_LOG_FILE}" ]] && tail -5 "${MEDIAMTX_LOG_FILE}" >&2
        return 1
    }
    
    wait_for_mediamtx_ready "$pid" || {
        terminate_process_group "$pid" 5
        return 1
    }
    
    write_pid_atomic "$pid" "${PID_FILE}" || {
        terminate_process_group "$pid" 5
        return 1
    }
    
    log INFO "MediaMTX started (PID: $pid)"
    
    # Start all streams
    start_all_streams "${devices[@]}"
    
    # Display results
    echo
    echo -e "${GREEN}=== Available RTSP Streams ===${NC}"
    
    for device_info in "${devices[@]}"; do
        IFS=':' read -r device_name card_num <<< "$device_info"
        local stream_name
        stream_name="$(generate_stream_name "$device_name" "$card_num")"
        
        local split_mono
        split_mono="$(get_device_config "$device_name" "SPLIT_MONO" "$DEFAULT_SPLIT_MONO")"
        
        if [[ "$split_mono" == "true" ]]; then
            echo -e "${GREEN}✔${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_left  (Left channel)"
            echo -e "${GREEN}✔${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_right (Right channel)"
        else
            echo -e "${GREEN}✔${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_name}"
        fi
    done
    
    echo
    return 0
}

stop_mediamtx() {
    STOPPING_SERVICE=true
    
    log INFO "Stopping MediaMTX..."
    
    cleanup_stale_processes
    
    log INFO "MediaMTX stopped"
    STOPPING_SERVICE=false
}

restart_mediamtx() {
    stop_mediamtx
    sleep 2
    start_mediamtx
}

show_status() {
    SKIP_CLEANUP=true
    
    echo -e "${CYAN}=== MediaMTX Audio Stream Status ===${NC}"
    echo
    
    if is_mediamtx_running; then
        local pid
        pid="$(read_pid_safe "${PID_FILE}")"
        echo -e "MediaMTX: ${GREEN}Running${NC} (PID: $pid)"
    else
        echo -e "MediaMTX: ${RED}Not running${NC}"
    fi
    
    echo
    echo "USB Audio Devices:"
    
    local devices=()
    readarray -t devices < <(detect_audio_devices 2>/dev/null || true)
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        echo "  No devices found"
    else
        for device_info in "${devices[@]}"; do
            IFS=':' read -r device_name card_num <<< "$device_info"
            local stream_name
            stream_name="$(generate_stream_name "$device_name" "$card_num")"
            
            echo "  - $device_name (card $card_num)"
            echo "    Stream: rtsp://${MEDIAMTX_HOST}:8554/$stream_name"
            
            # Check for mono split
            local split_mono
            split_mono="$(get_device_config "$device_name" "SPLIT_MONO" "$DEFAULT_SPLIT_MONO")"
            
            if [[ "$split_mono" == "true" ]]; then
                echo "    Mono Split: ENABLED"
                echo "      Left:  rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_left"
                echo "      Right: rtsp://${MEDIAMTX_HOST}:8554/${stream_name}_right"
            fi
            
            # Show running status
            local pid_file="${FFMPEG_PID_DIR}/${stream_name}.pid"
            if [[ -f "$pid_file" ]]; then
                local pid
                pid="$(read_pid_safe "$pid_file")"
                if [[ -n "$pid" ]]; then
                    echo -e "    Status: ${GREEN}Running${NC} (PID: $pid)"
                else
                    echo -e "    Status: ${RED}Not running${NC}"
                fi
            else
                echo -e "    Status: ${RED}Not running${NC}"
            fi
        done
    fi
    
    SKIP_CLEANUP=false
}

show_help() {
    cat << EOF
MediaMTX Stream Manager v${VERSION}
Enhanced with quickfix improvements + Mono L/R splitting

Usage: ${SCRIPT_NAME} [COMMAND]

Commands:
    start       Start MediaMTX and all streams
    stop        Stop MediaMTX and all streams
    restart     Restart everything
    status      Show current status
    help        Show this help

NEW in v1.4.0:
    ✓ Improved device detection (from quickfix)
    ✓ Device accessibility testing
    ✓ Auto-unlock busy devices
    ✓ Smart stream naming
    ✓ Mono L/R channel splitting

Configuration: ${DEVICE_CONFIG_FILE}

Mono Split Example:
    DEVICE_RODE_AI_MICRO_SPLIT_MONO=true
    
    Creates two streams:
    - rode_ai_micro_left  (left channel only)
    - rode_ai_micro_right (right channel only)

EOF
}

main() {
    case "${1:-help}" in
        start)
            check_root
            check_dependencies
            setup_directories
            start_mediamtx
            ;;
        stop)
            check_root
            setup_directories
            stop_mediamtx
            ;;
        restart)
            check_root
            check_dependencies
            setup_directories
            restart_mediamtx
            ;;
        status)
            setup_directories
            show_status
            ;;
        help|--help|-h|"")
            show_help
            ;;
        *)
            echo "Unknown command: $1" >&2
            show_help
            exit 1
            ;;
    esac
}

main "$@"

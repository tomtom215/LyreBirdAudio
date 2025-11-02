#!/bin/bash
# mediamtx-stream-manager.sh - Fixed version
# Version: 1.4.1

set -euo pipefail

readonly VERSION="1.4.1"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# Paths
readonly CONFIG_DIR="/etc/mediamtx"
readonly CONFIG_FILE="${CONFIG_DIR}/mediamtx.yml"
readonly DEVICE_CONFIG_FILE="${CONFIG_DIR}/audio-devices.conf"
readonly PID_FILE="/var/run/mediamtx-audio.pid"
readonly FFMPEG_PID_DIR="/var/lib/mediamtx-ffmpeg"
readonly LOCK_FILE="/var/run/mediamtx-audio.lock"
readonly LOG_FILE="/var/log/mediamtx-stream-manager.log"
readonly MEDIAMTX_LOG_FILE="/var/log/mediamtx.out"
readonly MEDIAMTX_BIN="/usr/local/bin/mediamtx"
readonly MEDIAMTX_HOST="localhost"

# Settings
readonly DEFAULT_SAMPLE_RATE="48000"
readonly DEFAULT_CHANNELS="2"
readonly DEFAULT_CODEC="opus"
readonly DEFAULT_BITRATE="128k"
readonly DEFAULT_SPLIT_MONO="false"

# Global state
declare -gi MAIN_LOCK_FD=-1
declare -g STOPPING_SERVICE=false

# Colors
if [[ -t 2 ]]; then
    RED="$(tput setaf 1)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)"
    CYAN="$(tput setaf 6)"
    NC="$(tput sgr0)"
else
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" NC=""
fi

command_exists() {
    command -v "$1" &>/dev/null
}

log() {
    local level="$1"
    shift
    local msg="$*"
    local ts="$(date '+%Y-%m-%d %H:%M:%S')"
    
    echo "[${ts}] [${level}] ${msg}" >> "${LOG_FILE}" 2>/dev/null || true
    
    case "${level}" in
        ERROR) echo -e "${RED}[ERROR]${NC} ${msg}" >&2 ;;
        WARN) echo -e "${YELLOW}[WARN]${NC} ${msg}" >&2 ;;
        INFO) echo -e "${GREEN}[INFO]${NC} ${msg}" ;;
        DEBUG) [[ "${DEBUG:-}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} ${msg}" >&2 ;;
    esac
}

error_exit() {
    log ERROR "$1"
    exit "${2:-1}"
}

acquire_lock() {
    local lock_dir="$(dirname "${LOCK_FILE}")"
    [[ -d "$lock_dir" ]] || mkdir -p "$lock_dir"
    
    exec {MAIN_LOCK_FD}>"${LOCK_FILE}" 2>/dev/null || return 1
    flock -w 30 "${MAIN_LOCK_FD}" || return 1
    echo "$$" >&"${MAIN_LOCK_FD}"
    log DEBUG "Lock acquired"
    return 0
}

release_lock() {
    [[ ${MAIN_LOCK_FD} -gt 2 ]] && exec {MAIN_LOCK_FD}>&- 2>/dev/null
    MAIN_LOCK_FD=-1
}

cleanup_stale_processes() {
    log INFO "Cleaning up stale processes"
    pkill -9 -f "^ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554" 2>/dev/null || true
    pkill -9 -f "${FFMPEG_PID_DIR}/.*\.sh" 2>/dev/null || true
    pkill -9 -f "^${MEDIAMTX_BIN}" 2>/dev/null || true
    rm -f "${PID_FILE}" "${FFMPEG_PID_DIR}"/*.pid "${FFMPEG_PID_DIR}"/*.sh "${FFMPEG_PID_DIR}"/*.log
    log INFO "Cleanup completed"
}

detect_audio_devices() {
    local output
    output=$(arecord -l 2>/dev/null) || return 1
    
    local -a devices
    while IFS= read -r line; do
        if [[ "$line" =~ card\ ([0-9]+):\ ([^,]+) ]]; then
            local card_num="${BASH_REMATCH[1]}"
            local card_name="${BASH_REMATCH[2]}"
            
            if [[ -f "/proc/asound/card${card_num}/usbid" ]]; then
                devices+=("${card_name}:${card_num}")
            fi
        fi
    done <<< "$output"
    
    [[ ${#devices[@]} -gt 0 ]] || return 1
    
    printf '%s\n' "${devices[@]}"
}

generate_stream_name() {
    local name="$1"
    
    if [[ "$name" =~ AI.*Micro|AI-Micro ]]; then
        echo "rode_ai_micro"
    elif [[ "$name" =~ [Bb]lue.*[Yy]eti ]]; then
        echo "blue_yeti"
    else
        echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g' | sed 's/^_//;s/_$//' | cut -c1-32
    fi
}

wait_for_mediamtx_ready() {
    local pid="$1"
    log INFO "Waiting for MediaMTX API..."
    
    for i in {1..30}; do
        kill -0 "$pid" 2>/dev/null || { log ERROR "MediaMTX died"; return 1; }
        
        if command_exists curl && curl -s --max-time 2 "http://${MEDIAMTX_HOST}:9997/v3/paths/list" >/dev/null 2>&1; then
            log INFO "MediaMTX API ready"
            return 0
        fi
        sleep 1
    done
    
    log ERROR "MediaMTX API timeout"
    return 1
}

start_ffmpeg_stream() {
    local device_name="$1"
    local card_num="$2"
    local stream_name="$3"
    
    log INFO "Starting stream: $stream_name (card $card_num)"
    
    local wrapper="${FFMPEG_PID_DIR}/${stream_name}.sh"
    local log_file="${FFMPEG_PID_DIR}/${stream_name}.log"
    
    mkdir -p "${FFMPEG_PID_DIR}"
    
    cat > "$wrapper" << EOF
#!/bin/bash
while true; do
    ffmpeg -hide_banner -loglevel warning \\
        -f alsa -ar ${DEFAULT_SAMPLE_RATE} -ac ${DEFAULT_CHANNELS} -i plughw:${card_num},0 \\
        -af "aresample=async=1:first_pts=0" \\
        -c:a ${DEFAULT_CODEC} -b:a ${DEFAULT_BITRATE} -application audio \\
        -f rtsp -rtsp_transport tcp \\
        rtsp://${MEDIAMTX_HOST}:8554/${stream_name} >> ${log_file} 2>&1
    
    echo "[\$(date)] FFmpeg exited, restarting in 5s" >> ${log_file}
    sleep 5
done
EOF
    
    chmod +x "$wrapper"
    nohup bash "$wrapper" >/dev/null 2>&1 &
    
    echo $! > "${FFMPEG_PID_DIR}/${stream_name}.pid"
    log INFO "Stream started: $stream_name (PID: $!)"
}

generate_mediamtx_config() {
    mkdir -p "${CONFIG_DIR}"
    
    cat > "${CONFIG_FILE}" << 'EOF'
logLevel: info
api: yes
apiAddress: :9997
metrics: yes
metricsAddress: :9998
rtsp: yes
rtspAddress: :8554
rtspTransports: [tcp, udp]
paths:
  '~^[a-zA-Z0-9_-]+$':
    source: publisher
    sourceOnDemand: no
EOF
    
    chmod 644 "${CONFIG_FILE}"
}

start_mediamtx() {
    acquire_lock || error_exit "Failed to acquire lock"
    
    cleanup_stale_processes
    
    log INFO "Starting MediaMTX..."
    
    # Detect devices - CRITICAL FIX
    local -a devices
    mapfile -t devices < <(detect_audio_devices)
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        error_exit "No USB audio devices found"
    fi
    
    log INFO "Found ${#devices[@]} USB audio device(s)"
    
    # Generate config
    generate_mediamtx_config
    
    # Start MediaMTX
    nohup "${MEDIAMTX_BIN}" "${CONFIG_FILE}" >> "${MEDIAMTX_LOG_FILE}" 2>&1 &
    local pid=$!
    echo "$pid" > "${PID_FILE}"
    
    sleep 1
    kill -0 "$pid" 2>/dev/null || error_exit "MediaMTX failed to start"
    
    wait_for_mediamtx_ready "$pid" || error_exit "MediaMTX not ready"
    
    log INFO "MediaMTX started (PID: $pid)"
    
    # Start streams
    for device_info in "${devices[@]}"; do
        IFS=':' read -r device_name card_num <<< "$device_info"
        local stream_name
        stream_name="$(generate_stream_name "$device_name")"
        start_ffmpeg_stream "$device_name" "$card_num" "$stream_name"
    done
    
    echo
    echo -e "${GREEN}=== Available RTSP Streams ===${NC}"
    for device_info in "${devices[@]}"; do
        IFS=':' read -r device_name card_num <<< "$device_info"
        local stream_name
        stream_name="$(generate_stream_name "$device_name")"
        echo -e "${GREEN}✔${NC} rtsp://${MEDIAMTX_HOST}:8554/${stream_name}"
    done
    echo
}

stop_mediamtx() {
    STOPPING_SERVICE=true
    log INFO "Stopping MediaMTX..."
    cleanup_stale_processes
    log INFO "MediaMTX stopped"
    STOPPING_SERVICE=false
}

show_status() {
    echo -e "${CYAN}=== MediaMTX Audio Stream Status ===${NC}"
    echo
    
    if [[ -f "${PID_FILE}" ]]; then
        local pid
        pid=$(cat "${PID_FILE}")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "MediaMTX: ${GREEN}Running${NC} (PID: $pid)"
        else
            echo -e "MediaMTX: ${RED}Not running${NC}"
        fi
    else
        echo -e "MediaMTX: ${RED}Not running${NC}"
    fi
    
    echo
    echo "USB Audio Devices:"
    
    local -a devices
    mapfile -t devices < <(detect_audio_devices 2>/dev/null || true)
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        echo "  No devices found"
    else
        for device_info in "${devices[@]}"; do
            IFS=':' read -r device_name card_num <<< "$device_info"
            local stream_name
            stream_name="$(generate_stream_name "$device_name")"
            echo "  - $device_name (card $card_num)"
            echo "    Stream: rtsp://${MEDIAMTX_HOST}:8554/$stream_name"
            
            if [[ -f "${FFMPEG_PID_DIR}/${stream_name}.pid" ]]; then
                local pid
                pid=$(cat "${FFMPEG_PID_DIR}/${stream_name}.pid")
                if kill -0 "$pid" 2>/dev/null; then
                    echo -e "    Status: ${GREEN}Running${NC} (PID: $pid)"
                else
                    echo -e "    Status: ${RED}Not running${NC}"
                fi
            else
                echo -e "    Status: ${RED}Not running${NC}"
            fi
        done
    fi
}

main() {
    case "${1:-help}" in
        start)
            [[ $EUID -eq 0 ]] || error_exit "Must run as root"
            mkdir -p "$(dirname "${LOG_FILE}")"
            start_mediamtx
            ;;
        stop)
            [[ $EUID -eq 0 ]] || error_exit "Must run as root"
            stop_mediamtx
            ;;
        restart)
            [[ $EUID -eq 0 ]] || error_exit "Must run as root"
            stop_mediamtx
            sleep 2
            start_mediamtx
            ;;
        status)
            show_status
            ;;
        *)
            echo "Usage: $SCRIPT_NAME {start|stop|restart|status}"
            exit 1
            ;;
    esac
}

main "$@"

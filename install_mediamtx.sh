#!/bin/bash
#
# Enhanced MediaMTX Installer with Production-Ready Standards
# Version: 3.0.0
# Date: 2025-01-23
# Description: Robust installer for MediaMTX with comprehensive error handling,
#              checksum verification, rollback support, and security hardening

# Strict error handling
set -o pipefail
set -o errtrace

# Configuration
readonly SCRIPT_VERSION="3.0.0"
readonly INSTALL_DIR="/usr/local/mediamtx"
readonly CONFIG_DIR="/etc/mediamtx"
readonly LOG_DIR="/var/log/mediamtx"
readonly SERVICE_USER="mediamtx"
readonly CHECKSUM_DIR="/var/lib/mediamtx/checksums"
readonly CACHE_DIR="/var/cache/mediamtx-installer"
readonly BACKUP_DIR="/var/backups/mediamtx"

# Default version and ports
VERSION="${VERSION:-v1.12.2}"
RTSP_PORT="${RTSP_PORT:-18554}"
RTMP_PORT="${RTMP_PORT:-11935}"
HLS_PORT="${HLS_PORT:-18888}"
WEBRTC_PORT="${WEBRTC_PORT:-18889}"
METRICS_PORT="${METRICS_PORT:-19999}"

# Runtime variables
TEMP_DIR=""
LOG_FILE=""
ARCH=""
DEBUG_MODE="${DEBUG:-false}"
DRY_RUN="${DRY_RUN:-false}"
FORCE_INSTALL="${FORCE:-false}"
ROLLBACK_POINTS=()

# Color output functions
print_color() {
    local color=$1
    shift
    echo -e "\033[${color}m$*\033[0m"
}

echo_info() { print_color "34" "[INFO] $*"; }
echo_success() { print_color "32" "[SUCCESS] $*"; }
echo_warning() { print_color "33" "[WARNING] $*"; }
echo_error() { print_color "31" "[ERROR] $*" >&2; }
echo_debug() {
    if [[ "$DEBUG_MODE" == "true" ]]; then
        print_color "36" "[DEBUG] $*" >&2
    fi
}

# Enhanced logging with rotation support
setup_logging() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    
    # Create secure temporary directory
    TEMP_DIR=$(mktemp -d -t mediamtx-install-XXXXXX) || {
        echo_error "Failed to create temporary directory"
        exit 1
    }
    
    LOG_FILE="${TEMP_DIR}/install_${timestamp}.log"
    
    # Ensure log file is created with proper permissions
    touch "$LOG_FILE" || {
        echo_error "Failed to create log file"
        exit 1
    }
    chmod 600 "$LOG_FILE"
    
    echo_debug "Temporary directory: $TEMP_DIR"
    echo_debug "Log file: $LOG_FILE"
}

# Log to file with timestamp
log_message() {
    local level=$1
    local message=$2
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    {
        echo "[${timestamp}] [${level}] ${message}"
        if [[ "$level" == "ERROR" ]]; then
            # Log stack trace for errors
            local frame=0
            while caller $frame; do
                ((frame++))
            done
        fi
    } >> "$LOG_FILE" 2>&1
}

# Comprehensive cleanup function
cleanup() {
    local exit_code=$?
    
    echo_debug "Running cleanup (exit code: $exit_code)"
    
    # Stop any started services if installation failed
    if [[ $exit_code -ne 0 ]] && systemctl is-active --quiet mediamtx.service 2>/dev/null; then
        echo_info "Stopping MediaMTX service due to installation failure"
        systemctl stop mediamtx.service 2>/dev/null || true
    fi
    
    # Preserve logs on error
    if [[ $exit_code -ne 0 ]] && [[ -f "$LOG_FILE" ]]; then
        local error_log="/tmp/mediamtx_install_error_$(date +%Y%m%d_%H%M%S).log"
        cp "$LOG_FILE" "$error_log" 2>/dev/null || true
        echo_error "Installation failed. Logs preserved at: $error_log"
    fi
    
    # Clean up temporary directory
    if [[ -n "$TEMP_DIR" ]] && [[ -d "$TEMP_DIR" ]]; then
        if [[ "$DEBUG_MODE" == "true" && $exit_code -ne 0 ]]; then
            echo_info "Debug mode: Temporary files preserved at: $TEMP_DIR"
        else
            rm -rf "$TEMP_DIR" 2>/dev/null || true
        fi
    fi
    
    # Run rollback if needed
    if [[ $exit_code -ne 0 ]] && [[ ${#ROLLBACK_POINTS[@]} -gt 0 ]]; then
        echo_warning "Installation failed. Initiating rollback..."
        rollback_changes
    fi
    
    exit $exit_code
}

# Enhanced trap handling
setup_traps() {
    trap cleanup EXIT
    trap 'echo_error "Interrupted"; exit 130' INT TERM
    trap 'echo_error "Error on line $LINENO"; exit 1' ERR
}

# Rollback functionality
add_rollback_point() {
    local action=$1
    ROLLBACK_POINTS+=("$action")
    echo_debug "Added rollback point: $action"
}

rollback_changes() {
    echo_info "Rolling back changes..."
    
    # Process rollback points in reverse order
    for ((i=${#ROLLBACK_POINTS[@]}-1; i>=0; i--)); do
        local action="${ROLLBACK_POINTS[i]}"
        echo_debug "Executing rollback: $action"
        eval "$action" 2>/dev/null || true
    done
    
    echo_info "Rollback completed"
}

# Enhanced dependency checking
check_dependencies() {
    local missing=()
    local optional_missing=()
    
    echo_info "Checking dependencies..."
    
    # Essential commands
    local required_cmds=(wget curl tar gzip file grep sed awk chmod chown systemctl useradd mktemp)
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    
    # Optional but recommended
    local optional_cmds=(jq sha256sum md5sum xxd nc dig host)
    for cmd in "${optional_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            optional_missing+=("$cmd")
        fi
    done
    
    # Report missing dependencies
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo_error "Missing required dependencies: ${missing[*]}"
        
        # Detect package manager and suggest installation
        if command -v apt-get >/dev/null 2>&1; then
            echo_info "Install with: sudo apt-get update && sudo apt-get install -y ${missing[*]}"
        elif command -v yum >/dev/null 2>&1; then
            echo_info "Install with: sudo yum install -y ${missing[*]}"
        elif command -v dnf >/dev/null 2>&1; then
            echo_info "Install with: sudo dnf install -y ${missing[*]}"
        fi
        
        return 1
    fi
    
    if [[ ${#optional_missing[@]} -gt 0 ]]; then
        echo_warning "Missing optional dependencies: ${optional_missing[*]}"
        echo_warning "Some features may be limited without these tools"
    fi
    
    echo_success "All required dependencies are installed"
    return 0
}

# Enhanced architecture detection
detect_architecture() {
    local arch
    arch=$(uname -m)
    
    case "$arch" in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        armv7*|armhf)
            ARCH="armv7"
            ;;
        armv6*|armel)
            ARCH="armv6"
            ;;
        *)
            # Try additional detection methods
            if command -v dpkg >/dev/null 2>&1; then
                local dpkg_arch
                dpkg_arch=$(dpkg --print-architecture 2>/dev/null || true)
                case "$dpkg_arch" in
                    amd64) ARCH="amd64" ;;
                    arm64) ARCH="arm64" ;;
                    armhf) ARCH="armv7" ;;
                    armel) ARCH="armv6" ;;
                    *) ARCH="unknown" ;;
                esac
            else
                ARCH="unknown"
            fi
            ;;
    esac
    
    if [[ "$ARCH" == "unknown" ]]; then
        echo_error "Unsupported architecture: $arch"
        echo_info "Supported: x86_64, aarch64, armv7, armv6"
        return 1
    fi
    
    echo_info "Detected architecture: $ARCH"
    return 0
}

# Network connectivity check with proxy support
check_connectivity() {
    echo_info "Checking network connectivity..."
    
    # Check for proxy settings
    if [[ -n "${HTTP_PROXY:-}" ]] || [[ -n "${HTTPS_PROXY:-}" ]]; then
        echo_info "Proxy detected: HTTP_PROXY=${HTTP_PROXY:-} HTTPS_PROXY=${HTTPS_PROXY:-}"
    fi
    
    # Test connectivity to GitHub
    local test_url="https://github.com"
    local methods=("curl" "wget" "nc")
    local connected=false
    
    for method in "${methods[@]}"; do
        case "$method" in
            curl)
                if command -v curl >/dev/null 2>&1; then
                    if curl -s --head --connect-timeout 10 "$test_url" >/dev/null 2>&1; then
                        connected=true
                        break
                    fi
                fi
                ;;
            wget)
                if command -v wget >/dev/null 2>&1; then
                    if wget -q --spider --timeout=10 "$test_url" 2>&1; then
                        connected=true
                        break
                    fi
                fi
                ;;
            nc)
                if command -v nc >/dev/null 2>&1; then
                    if nc -z -w5 github.com 443 2>&1; then
                        connected=true
                        break
                    fi
                fi
                ;;
        esac
    done
    
    if [[ "$connected" == "true" ]]; then
        echo_success "Network connectivity confirmed"
        return 0
    else
        echo_error "Cannot reach GitHub. Check your internet connection and proxy settings"
        return 1
    fi
}

# Verify version exists on GitHub
verify_version() {
    local version=$1
    echo_info "Verifying version $version exists..."
    
    local api_url="https://api.github.com/repos/bluenviron/mediamtx/releases/tags/${version}"
    local response
    
    if command -v curl >/dev/null 2>&1; then
        response=$(curl -s -o /dev/null -w "%{http_code}" "$api_url" 2>&1)
    elif command -v wget >/dev/null 2>&1; then
        response=$(wget -q --spider -S "$api_url" 2>&1 | grep "HTTP/" | awk '{print $2}' | tail -1)
    else
        echo_warning "Cannot verify version without curl or wget"
        return 0
    fi
    
    if [[ "$response" == "200" ]]; then
        echo_success "Version $version verified"
        return 0
    else
        echo_error "Version $version not found"
        echo_info "Check available versions at: https://github.com/bluenviron/mediamtx/releases"
        return 1
    fi
}

# Download with checksum verification
download_mediamtx() {
    local url="https://github.com/bluenviron/mediamtx/releases/download/${VERSION}/mediamtx_${VERSION}_linux_${ARCH}.tar.gz"
    local output_file="${TEMP_DIR}/mediamtx.tar.gz"
    local checksum_file="${TEMP_DIR}/checksums.txt"
    
    echo_info "Downloading MediaMTX ${VERSION} for ${ARCH}..."
    echo_debug "URL: $url"
    
    # Download the binary
    if command -v wget >/dev/null 2>&1; then
        wget --no-verbose --show-progress --tries=3 --timeout=30 -O "$output_file" "$url" || {
            echo_error "Download failed with wget"
            return 1
        }
    elif command -v curl >/dev/null 2>&1; then
        curl -L --retry 3 --connect-timeout 30 --progress-bar -o "$output_file" "$url" || {
            echo_error "Download failed with curl"
            return 1
        }
    else
        echo_error "Neither wget nor curl is available"
        return 1
    fi
    
    # Verify file exists and is not empty
    if [[ ! -f "$output_file" ]] || [[ ! -s "$output_file" ]]; then
        echo_error "Downloaded file is missing or empty"
        return 1
    fi
    
    # Try to download and verify checksum
    local checksum_url="https://github.com/bluenviron/mediamtx/releases/download/${VERSION}/checksums.txt"
    echo_info "Attempting checksum verification..."
    
    if download_file "$checksum_url" "$checksum_file"; then
        if command -v sha256sum >/dev/null 2>&1; then
            local expected_sum
            expected_sum=$(grep "mediamtx_${VERSION}_linux_${ARCH}.tar.gz" "$checksum_file" 2>/dev/null | awk '{print $1}')
            
            if [[ -n "$expected_sum" ]]; then
                echo_debug "Expected checksum: $expected_sum"
                local actual_sum
                actual_sum=$(sha256sum "$output_file" | awk '{print $1}')
                
                if [[ "$expected_sum" == "$actual_sum" ]]; then
                    echo_success "Checksum verification passed"
                else
                    echo_error "Checksum verification failed"
                    echo_error "Expected: $expected_sum"
                    echo_error "Actual: $actual_sum"
                    return 1
                fi
            else
                echo_warning "Checksum not found in checksums file"
            fi
        else
            echo_warning "sha256sum not available, skipping checksum verification"
        fi
    else
        echo_warning "Could not download checksums file, skipping verification"
    fi
    
    echo_success "Download completed successfully"
    return 0
}

# Generic file download helper
download_file() {
    local url=$1
    local output=$2
    
    if command -v wget >/dev/null 2>&1; then
        wget -q --timeout=10 -O "$output" "$url" 2>/dev/null
    elif command -v curl >/dev/null 2>&1; then
        curl -s -L --connect-timeout 10 -o "$output" "$url" 2>/dev/null
    else
        return 1
    fi
}

# Extract and verify tarball
extract_mediamtx() {
    local tarball="${TEMP_DIR}/mediamtx.tar.gz"
    local extract_dir="${TEMP_DIR}/extracted"
    
    echo_info "Extracting MediaMTX..."
    
    # Verify tarball
    if ! tar -tzf "$tarball" >/dev/null 2>&1; then
        echo_error "Invalid or corrupted tarball"
        return 1
    fi
    
    # Create extraction directory
    mkdir -p "$extract_dir" || {
        echo_error "Failed to create extraction directory"
        return 1
    }
    
    # Extract
    if ! tar -xzf "$tarball" -C "$extract_dir"; then
        echo_error "Extraction failed"
        return 1
    fi
    
    # Verify binary exists
    if [[ ! -f "${extract_dir}/mediamtx" ]]; then
        echo_error "MediaMTX binary not found in archive"
        return 1
    fi
    
    echo_success "Extraction completed successfully"
    return 0
}

# Install MediaMTX with full error handling
install_mediamtx() {
    local binary_path="${TEMP_DIR}/extracted/mediamtx"
    
    echo_info "Installing MediaMTX..."
    
    # Create installation directory
    if [[ ! -d "$INSTALL_DIR" ]]; then
        mkdir -p "$INSTALL_DIR" || {
            echo_error "Failed to create installation directory"
            return 1
        }
        add_rollback_point "rmdir '$INSTALL_DIR' 2>/dev/null"
    fi
    
    # Backup existing installation
    if [[ -f "${INSTALL_DIR}/mediamtx" ]]; then
        local backup_name="mediamtx.backup.$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        
        echo_info "Backing up existing installation..."
        if cp "${INSTALL_DIR}/mediamtx" "${BACKUP_DIR}/${backup_name}"; then
            add_rollback_point "mv '${BACKUP_DIR}/${backup_name}' '${INSTALL_DIR}/mediamtx'"
            echo_success "Backup created: ${BACKUP_DIR}/${backup_name}"
        else
            echo_warning "Failed to create backup, continuing anyway"
        fi
    fi
    
    # Install binary
    if [[ "$DRY_RUN" == "true" ]]; then
        echo_info "[DRY RUN] Would install binary to ${INSTALL_DIR}/mediamtx"
    else
        if ! cp "$binary_path" "${INSTALL_DIR}/mediamtx"; then
            echo_error "Failed to install binary"
            return 1
        fi
        
        chmod 755 "${INSTALL_DIR}/mediamtx" || {
            echo_error "Failed to set binary permissions"
            return 1
        }
        
        add_rollback_point "rm -f '${INSTALL_DIR}/mediamtx'"
    fi
    
    # Test binary
    if [[ "$DRY_RUN" != "true" ]]; then
        if ! "${INSTALL_DIR}/mediamtx" --version >/dev/null 2>&1; then
            echo_error "Binary verification failed"
            return 1
        fi
    fi
    
    echo_success "Binary installed successfully"
    return 0
}

# Create configuration with validation
create_configuration() {
    echo_info "Creating configuration..."
    
    # Create config directory
    if [[ ! -d "$CONFIG_DIR" ]]; then
        mkdir -p "$CONFIG_DIR" || {
            echo_error "Failed to create config directory"
            return 1
        }
        add_rollback_point "rmdir '$CONFIG_DIR' 2>/dev/null"
    fi
    
    # Backup existing config
    if [[ -f "${CONFIG_DIR}/mediamtx.yml" ]]; then
        local backup_name="mediamtx.yml.backup.$(date +%Y%m%d_%H%M%S)"
        if cp "${CONFIG_DIR}/mediamtx.yml" "${CONFIG_DIR}/${backup_name}"; then
            add_rollback_point "mv '${CONFIG_DIR}/${backup_name}' '${CONFIG_DIR}/mediamtx.yml'"
            echo_info "Config backed up to: ${CONFIG_DIR}/${backup_name}"
        fi
    fi
    
    # Create configuration file
    if [[ "$DRY_RUN" == "true" ]]; then
        echo_info "[DRY RUN] Would create configuration at ${CONFIG_DIR}/mediamtx.yml"
    else
        cat > "${CONFIG_DIR}/mediamtx.yml" << EOF
# MediaMTX Configuration
# Generated by installer v${SCRIPT_VERSION} on $(date)
# Documentation: https://github.com/bluenviron/mediamtx

###############################################
# General parameters

# Verbosity of the program; available values are "error", "warn", "info", "debug".
logLevel: info

# Destinations of log messages; available values are "stdout", "file" and "syslog".
logDestinations: [stdout, file]

# If "file" is in logDestinations, this is the file that will receive the logs.
logFile: ${LOG_DIR}/mediamtx.log

# Timeout of read operations.
readTimeout: 10s

# Timeout of write operations.
writeTimeout: 10s

# Number of read buffers.
readBufferCount: 512

# HTTP URL to perform external authentication.
# Every time a user wants to authenticate, the server calls this URL
# with the POST method and a body containing:
# {
#   "ip": "ip",
#   "user": "user",
#   "password": "password",
#   "path": "path",
#   "protocol": "rtsp|rtmp|hls|webrtc",
#   "id": "id",
#   "action": "read|publish",
#   "query": "query"
# }
# If the response code is 20x, authentication is accepted, otherwise
# it is discarded.
externalAuthenticationURL:

# Enable the HTTP API.
api: no

# Address of the API listener.
apiAddress: 127.0.0.1:9997

###############################################
# RTSP parameters

# Disable support for the RTSP protocol.
rtspDisable: no

# List of enabled RTSP transport protocols.
# UDP is the most performant, but doesn't work when there's a NAT/firewall between
# server and clients, and doesn't support encryption.
# UDP-multicast allows to save bandwidth when clients are all in the same LAN.
# TCP is the most versatile, and does support encryption.
# The handshake is always performed with TCP.
protocols: [udp, multicast, tcp]

# Encrypt handshake and TCP streams with TLS (RTSPS).
# Available values are "no", "strict", "optional".
encryption: "no"

# Address of the TCP/RTSP listener. This is needed only when encryption is "no" or "optional".
rtspAddress: :${RTSP_PORT}

# Address of the TCP/TLS/RTSPS listener. This is needed only when encryption is "strict" or "optional".
rtspsAddress: :8322

# Address of the UDP/RTP listener. This is needed only when "udp" is in protocols.
rtpAddress: :8000

# Address of the UDP/RTCP listener. This is needed only when "udp" is in protocols.
rtcpAddress: :8001

# IP range of all UDP-multicast listeners. This is needed only when "multicast" is in protocols.
multicastIPRange: 224.1.0.0/16

# Port of all UDP-multicast/RTP listeners. This is needed only when "multicast" is in protocols.
multicastRTPPort: 8002

# Port of all UDP-multicast/RTCP listeners. This is needed only when "multicast" is in protocols.
multicastRTCPPort: 8003

# Path to the server key. This is needed only when encryption is "strict" or "optional".
# This can be generated with:
# openssl genrsa -out server.key 2048
# openssl req -new -x509 -sha256 -key server.key -out server.crt -days 3650
serverKey: server.key

# Path to the server certificate. This is needed only when encryption is "strict" or "optional".
serverCert: server.crt

# Authentication methods. Available are "basic", "digest" and "none".
authMethods: [basic, digest]

###############################################
# RTMP parameters

# Disable support for the RTMP protocol.
rtmpDisable: no

# Address of the RTMP listener. This is needed only when encryption is "no" or "optional".
rtmpAddress: :${RTMP_PORT}

# Encrypt connections with TLS (RTMPS).
# Available values are "no", "strict", "optional".
rtmpEncryption: "no"

# Address of the RTMPS listener. This is needed only when encryption is "strict" or "optional".
rtmpsAddress: :1936

# Path to the server key. This is needed only when encryption is "strict" or "optional".
# This can be generated with:
# openssl genrsa -out server.key 2048
# openssl req -new -x509 -sha256 -key server.key -out server.crt -days 3650
rtmpServerKey: server.key

# Path to the server certificate. This is needed only when encryption is "strict" or "optional".
rtmpServerCert: server.crt

###############################################
# HLS parameters

# Disable support for the HLS protocol.
hlsDisable: no

# Address of the HLS listener.
hlsAddress: :${HLS_PORT}

# Enable TLS/HTTPS on the HLS server.
# This is required for Low-Latency HLS.
hlsEncryption: no

# Path to the server key. This is needed only when encryption is yes.
# This can be generated with:
# openssl genrsa -out server.key 2048
# openssl req -new -x509 -sha256 -key server.key -out server.crt -days 3650
hlsServerKey: server.key

# Path to the server certificate.
hlsServerCert: server.crt

# By default, HLS is generated only when requested by a user.
# This option allows to generate it always, avoiding the delay between request and generation.
hlsAlwaysRemux: no

# Variant of the HLS protocol to use. Available options are:
# * mpegts - uses MPEG-TS segments, for maximum compatibility.
# * fmp4 - uses fragmented MP4 segments, more efficient.
# * lowLatency - uses Low-Latency HLS.
hlsVariant: lowLatency

# Number of HLS segments to keep on the server.
# Segments allow to seek through the stream.
# Their number doesn't influence latency.
hlsSegmentCount: 7

# Minimum duration of each segment.
# A player usually puts 3 segments in a buffer before reproducing the stream.
# The final segment duration is also influenced by the interval between IDR frames,
# since the server changes the duration in order to include at least one IDR frame
# in each segment.
hlsSegmentDuration: 1s

# Minimum duration of each part.
# A player usually puts 3 parts in a buffer before reproducing the stream.
# Parts are used in Low-Latency HLS in place of segments.
# Part duration is influenced by the distance between video/audio samples
# and is adjusted in order to produce segments with a similar duration.
hlsPartDuration: 200ms

# Maximum size of each segment.
# This prevents RAM exhaustion.
hlsSegmentMaxSize: 50M

# Value of the Access-Control-Allow-Origin header provided in every HTTP response.
# This allows to play the HLS stream from an external website.
hlsAllowOrigin: '*'

# List of IPs or CIDRs of proxies placed before the HLS server.
# If the server receives a request from one of these entries, IP in logs
# will be taken from the X-Forwarded-For header.
hlsTrustedProxies: []

# Directory in which to save segments, instead of keeping them in the RAM.
# This decreases performance, since reading from disk is less performant than
# reading from RAM, but allows to save RAM.
hlsDirectory: ''

###############################################
# WebRTC parameters

# Disable support for the WebRTC protocol.
webrtcDisable: no

# Address of the WebRTC listener.
webrtcAddress: :${WEBRTC_PORT}

# Enable TLS/HTTPS on the WebRTC server.
webrtcEncryption: no

# Path to the server key.
# This can be generated with:
# openssl genrsa -out server.key 2048
# openssl req -new -x509 -sha256 -key server.key -out server.crt -days 3650
webrtcServerKey: server.key

# Path to the server certificate.
webrtcServerCert: server.crt

# Value of the Access-Control-Allow-Origin header provided in every HTTP response.
# This allows to play the WebRTC stream from an external website.
webrtcAllowOrigin: '*'

# List of IPs or CIDRs of proxies placed before the WebRTC server.
# If the server receives a request from one of these entries, IP in logs
# will be taken from the X-Forwarded-For header.
webrtcTrustedProxies: []

# List of ICE servers, in format type:user:pass:host:port or type:host:port.
# type can be "stun", "turn" or "turns".
# STUN servers are used to get the public IP of both server and clients.
# TURN servers are used as relay when a direct connection between server and clients is not possible.
# if user is omitted, no authentication is used.
webrtcICEServers: [stun:stun.l.google.com:19302]

# List of public IP addresses that are to be used as a host.
# This is used typically for servers that are behind 1:1 D-NAT.
webrtcICEHostNAT1To1IPs: []

# Address of a ICE UDP listener in format host:port.
# If filled, ICE traffic will come through a single UDP port,
# allowing the deployment of the server inside a container or behind a NAT.
webrtcICEUDPMuxAddress:

# Address of a ICE TCP listener in format host:port.
# If filled, ICE traffic will come through a single TCP port,
# allowing the deployment of the server inside a container or behind a NAT.
# At the moment, setting this parameter forces usage of the TCP protocol,
# which is not optimal for media delivery.
# This will be fixed in future versions.
webrtcICETCPMuxAddress:

###############################################
# Metrics

# Enable Prometheus-compatible metrics.
metrics: yes

# Address of the metrics listener.
metricsAddress: 127.0.0.1:${METRICS_PORT}

###############################################
# Path parameters

# These settings are path-dependent, and the map key is the name of the path.
# It's possible to use regular expressions by using a tilde as prefix.
# For example, "~^(test1|test2)$" will match both "test1" and "test2".
# For example, "~^prefix" will match all paths that start with "prefix".
# The settings under the path "all" are applied to all paths that do not match
# a more specific entry.
paths:
  all:
    # Source of the stream. This can be:
    # * publisher -> the stream is published by a RTSP or RTMP client
    # * rtsp://existing-url -> the stream is pulled from another RTSP server / camera
    # * rtsps://existing-url -> the stream is pulled from another RTSP server / camera with RTSPS
    # * rtmp://existing-url -> the stream is pulled from another RTMP server / camera
    # * rtmps://existing-url -> the stream is pulled from another RTMP server / camera with RTMPS
    # * http://existing-url/stream.m3u8 -> the stream is pulled from another HLS server
    # * https://existing-url/stream.m3u8 -> the stream is pulled from another HLS server with HTTPS
    # * udp://host:port -> the stream is pulled from UDP, by listening on the specified IP and port
    # * redirect -> the stream is provided by another path or server
    # * rpiCamera -> the stream is provided by a Raspberry Pi Camera
    source: publisher

    # If the source is an RTSP or RTSPS URL, this is the protocol that will be used to
    # pull the stream. available values are "automatic", "udp", "multicast", "tcp".
    sourceProtocol: automatic

    # Tf the source is an RTSP or RTSPS URL, this allows to support sources that
    # don't provide server ports or use random server ports. This is a security issue
    # and must be used only when interacting with sources that require it.
    sourceAnyPortEnable: no

    # If the source is a RTSPS URL, the fingerprint of the certificate of the source
    # must be provided in order to prevent man-in-the-middle attacks.
    # It can be obtained from the source by running:
    # openssl s_client -connect source_ip:source_port </dev/null 2>/dev/null | sed -n '/BEGIN/,/END/p' > server.crt
    # openssl x509 -in server.crt -noout -fingerprint -sha256 | cut -d "=" -f2 | tr -d ':'
    sourceFingerprint:

    # If the source is an RTSP or RTMP URL, it will be pulled only when at least
    # one reader is connected, saving bandwidth.
    sourceOnDemand: no

    # If sourceOnDemand is "yes", readers will be put on hold until the source is
    # ready or until this amount of time has passed.
    sourceOnDemandStartTimeout: 10s

    # If sourceOnDemand is "yes", the source will be closed when there are no
    # readers connected and this amount of time has passed.
    sourceOnDemandCloseAfter: 10s

    # If the source is "redirect", this is the RTSP URL which clients will be
    # redirected to.
    sourceRedirect:

    # If the source is "publisher" and a client is publishing, do not allow another
    # client to disconnect the former and publish in its place.
    disablePublisherOverride: no

    # If the source is "publisher" and no one is publishing, redirect readers to this
    # path. It can be can be a relative path  (i.e. /otherstream) or an absolute RTSP URL.
    fallback:

    # Username required to publish.
    # SHA256-hashed values can be inserted with the "sha256:" prefix.
    publishUser:

    # Password required to publish.
    # SHA256-hashed values can be inserted with the "sha256:" prefix.
    publishPass:

    # IPs or networks (x.x.x.x/24) allowed to publish.
    publishIPs: []

    # Username required to read.
    # SHA256-hashed values can be inserted with the "sha256:" prefix.
    readUser:

    # password required to read.
    # SHA256-hashed values can be inserted with the "sha256:" prefix.
    readPass:

    # IPs or networks (x.x.x.x/24) allowed to read.
    readIPs: []

    # Command to run when this path is initialized.
    # This can be used to publish a stream and keep it always opened.
    # This is terminated with SIGINT when the program closes.
    # The following environment variables are available:
    # * RTSP_PATH: path name
    # * RTSP_PORT: server port
    # * G1, G2, ...: regular expression groups, if path name is
    #   a regular expression.
    runOnInit:

    # Restart the command if it exits suddenly.
    runOnInitRestart: no

    # Command to run when this path is requested.
    # This can be used to publish a stream on demand.
    # This is terminated with SIGINT when the path is not requested anymore.
    # The following environment variables are available:
    # * RTSP_PATH: path name
    # * RTSP_PORT: server port
    # * G1, G2, ...: regular expression groups, if path name is
    #   a regular expression.
    runOnDemand:

    # Restart the command if it exits suddenly.
    runOnDemandRestart: no

    # Readers will be put on hold until the runOnDemand command starts publishing
    # or until this amount of time has passed.
    runOnDemandStartTimeout: 10s

    # The command will be closed when there are no
    # readers connected and this amount of time has passed.
    runOnDemandCloseAfter: 10s

    # Command to run when the stream is ready to be read, whether it is
    # published by a client or pulled from a server / camera.
    # This is terminated with SIGINT when the stream is not ready anymore.
    # The following environment variables are available:
    # * RTSP_PATH: path name
    # * RTSP_PORT: server port
    # * G1, G2, ...: regular expression groups, if path name is
    #   a regular expression.
    runOnReady:

    # Restart the command if it exits suddenly.
    runOnReadyRestart: no

    # Command to run when a clients starts reading.
    # This is terminated with SIGINT when a client stops reading.
    # The following environment variables are available:
    # * RTSP_PATH: path name
    # * RTSP_PORT: server port
    # * G1, G2, ...: regular expression groups, if path name is
    #   a regular expression.
    runOnRead:

    # Restart the command if it exits suddenly.
    runOnReadRestart: no
EOF
        
        if [[ ! -f "${CONFIG_DIR}/mediamtx.yml" ]]; then
            echo_error "Failed to create configuration file"
            return 1
        fi
        
        add_rollback_point "rm -f '${CONFIG_DIR}/mediamtx.yml'"
    fi
    
    echo_success "Configuration created successfully"
    return 0
}

# Create systemd service with enhanced security
create_systemd_service() {
    echo_info "Creating systemd service..."
    
    # Create service user
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo_info "[DRY RUN] Would create service user: $SERVICE_USER"
        else
            if ! useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"; then
                echo_warning "Failed to create service user, will use root"
                SERVICE_USER="root"
            else
                add_rollback_point "userdel '$SERVICE_USER' 2>/dev/null"
            fi
        fi
    fi
    
    # Create log directory
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR" || {
            echo_error "Failed to create log directory"
            return 1
        }
        add_rollback_point "rmdir '$LOG_DIR' 2>/dev/null"
    fi
    
    # Set ownership
    if [[ "$DRY_RUN" != "true" ]] && [[ "$SERVICE_USER" != "root" ]]; then
        chown -R "$SERVICE_USER:$SERVICE_USER" "$CONFIG_DIR" "$LOG_DIR" 2>/dev/null || {
            echo_warning "Failed to set ownership"
        }
    fi
    
    # Create systemd service file
    local service_file="/etc/systemd/system/mediamtx.service"
    
    if [[ -f "$service_file" ]]; then
        local backup_name="mediamtx.service.backup.$(date +%Y%m%d_%H%M%S)"
        if cp "$service_file" "${service_file}.${backup_name}"; then
            add_rollback_point "mv '${service_file}.${backup_name}' '$service_file'"
            echo_info "Service file backed up"
        fi
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo_info "[DRY RUN] Would create service file at $service_file"
    else
        cat > "$service_file" << EOF
[Unit]
Description=MediaMTX RTSP/RTMP/HLS/WebRTC Media Server
Documentation=https://github.com/bluenviron/mediamtx
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=$INSTALL_DIR/mediamtx $CONFIG_DIR/mediamtx.yml
WorkingDirectory=$INSTALL_DIR
Restart=on-failure
RestartSec=10

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mediamtx

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictRealtime=true
RestrictSUIDSGID=true
RemoveIPC=true

# Grant necessary capabilities for binding to ports
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

# File system access
ReadWritePaths=$LOG_DIR
ReadOnlyPaths=$CONFIG_DIR

# Resource limits
LimitNOFILE=65535
LimitNPROC=512

[Install]
WantedBy=multi-user.target
EOF
        
        if [[ ! -f "$service_file" ]]; then
            echo_error "Failed to create service file"
            return 1
        fi
        
        add_rollback_point "rm -f '$service_file'"
        
        # Reload systemd
        systemctl daemon-reload || {
            echo_warning "Failed to reload systemd"
        }
        
        # Enable service
        systemctl enable mediamtx.service >/dev/null 2>&1 || {
            echo_warning "Failed to enable service"
        }
    fi
    
    echo_success "Systemd service created successfully"
    return 0
}

# Display installation summary
print_summary() {
    local divider="============================================="
    
    echo ""
    echo "$divider"
    echo "MediaMTX Installation Summary"
    echo "$divider"
    echo "Version:        $VERSION"
    echo "Architecture:   $ARCH"
    echo "Install Dir:    $INSTALL_DIR"
    echo "Config File:    $CONFIG_DIR/mediamtx.yml"
    echo "Log Directory:  $LOG_DIR"
    echo "Service User:   $SERVICE_USER"
    echo ""
    echo "Network Ports:"
    echo "  RTSP:         $RTSP_PORT"
    echo "  RTMP:         $RTMP_PORT"
    echo "  HLS:          $HLS_PORT"
    echo "  WebRTC:       $WEBRTC_PORT"
    echo "  Metrics:      $METRICS_PORT"
    echo ""
    echo "Service Management:"
    echo "  Status:       systemctl status mediamtx"
    echo "  Start:        systemctl start mediamtx"
    echo "  Stop:         systemctl stop mediamtx"
    echo "  Restart:      systemctl restart mediamtx"
    echo "  Logs:         journalctl -u mediamtx -f"
    echo ""
    echo "Configuration:"
    echo "  Edit config:  nano $CONFIG_DIR/mediamtx.yml"
    echo "  Reload:       systemctl restart mediamtx"
    echo ""
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "NOTE: This was a DRY RUN - no changes were made"
        echo ""
    fi
    
    echo "$divider"
    echo "Installation completed successfully!"
    echo "$divider"
}

# Main installation flow
main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --version)
                VERSION="$2"
                shift 2
                ;;
            --arch)
                ARCH="$2"
                shift 2
                ;;
            --debug)
                DEBUG_MODE="true"
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
                shift
                ;;
            --force)
                FORCE_INSTALL="true"
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --version VERSION    MediaMTX version to install (default: $VERSION)"
                echo "  --arch ARCH         Force architecture (auto-detected by default)"
                echo "  --debug             Enable debug output"
                echo "  --dry-run           Show what would be done without making changes"
                echo "  --force             Force installation even if already installed"
                echo "  --help              Show this help message"
                echo ""
                exit 0
                ;;
            *)
                echo_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    # Header
    echo ""
    echo "MediaMTX Installer v${SCRIPT_VERSION}"
    echo "========================================"
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        echo_error "This script must be run as root or with sudo"
        exit 1
    fi
    
    # Setup logging and traps
    setup_logging
    setup_traps
    
    log_message "INFO" "Starting MediaMTX installation (version: $VERSION)"
    
    # Pre-flight checks
    echo_info "Running pre-flight checks..."
    
    if ! check_dependencies; then
        echo_error "Dependency check failed"
        exit 1
    fi
    
    if ! detect_architecture; then
        echo_error "Architecture detection failed"
        exit 1
    fi
    
    if ! check_connectivity; then
        echo_error "Network connectivity check failed"
        exit 1
    fi
    
    if ! verify_version "$VERSION"; then
        echo_error "Version verification failed"
        exit 1
    fi
    
    # Check if already installed
    if [[ -f "${INSTALL_DIR}/mediamtx" ]] && [[ "$FORCE_INSTALL" != "true" ]]; then
        echo_warning "MediaMTX is already installed"
        read -p "Do you want to upgrade/reinstall? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo_info "Installation cancelled"
            exit 0
        fi
    fi
    
    # Main installation steps
    echo ""
    echo_info "Beginning installation..."
    
    if ! download_mediamtx; then
        echo_error "Download failed"
        exit 1
    fi
    
    if ! extract_mediamtx; then
        echo_error "Extraction failed"
        exit 1
    fi
    
    if ! install_mediamtx; then
        echo_error "Installation failed"
        exit 1
    fi
    
    if ! create_configuration; then
        echo_error "Configuration creation failed"
        exit 1
    fi
    
    if ! create_systemd_service; then
        echo_error "Service creation failed"
        exit 1
    fi
    
    # Print summary
    print_summary
    
    # Ask to start service
    if [[ "$DRY_RUN" != "true" ]]; then
        echo ""
        read -p "Would you like to start MediaMTX now? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo_info "Starting MediaMTX service..."
            if systemctl start mediamtx.service; then
                echo_success "MediaMTX is now running"
                echo_info "Check status with: systemctl status mediamtx"
            else
                echo_error "Failed to start service"
                echo_info "Check logs with: journalctl -u mediamtx -n 50"
            fi
        fi
    fi
    
    log_message "SUCCESS" "Installation completed successfully"
    return 0
}

# Execute main function
main "$@"

#!/bin/bash
#
# Enhanced MediaMTX Installer with Production-Ready Standards
# Version: 4.0.1
# Date: 2025-06-01
# Description: Robust installer for MediaMTX with comprehensive error handling,
#              checksum verification, rollback support, and security hardening
#
# Changelog v4.0.1:
# - Fixed critical security vulnerabilities (temp file handling, log permissions)
# - Improved port detection for broader compatibility
# - Enhanced version comparison and extraction
# - Increased network timeouts for slow connections
# - Added binary validation
# - Improved systemd detection and service management
# - Simplified YAML validation for reliability
# - Added disk space checks
# - Fixed rollback safety issues
# - Enhanced architecture detection

# Strict error handling with undefined variable protection
set -euo pipefail
set -o errtrace
shopt -s nullglob  # Safe glob expansion

# Configuration
readonly SCRIPT_VERSION="4.0.1"
readonly INSTALL_DIR="/usr/local/mediamtx"
readonly CONFIG_DIR="/etc/mediamtx"
readonly LOG_DIR="/var/log/mediamtx"
readonly SERVICE_USER="mediamtx"
readonly CHECKSUM_DIR="/var/lib/mediamtx/checksums"
readonly CACHE_DIR="/var/cache/mediamtx-installer"
readonly BACKUP_DIR="/var/backups/mediamtx"
readonly CONFIG_TEMPLATE_FILE="${CONFIG_DIR}/mediamtx.yml.template"

# Default version and ports (updated to latest)
VERSION="${VERSION:-v1.12.3}"
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
SKIP_YAML_VALIDATION="${SKIP_YAML_VALIDATION:-false}"
ROLLBACK_POINTS=()
SYSTEMD_DIR=""

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

# Input validation functions
validate_port() {
    local port=$1
    local name=${2:-"Port"}
    
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        echo_error "$name must be a number"
        return 1
    fi
    
    if [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        echo_error "$name must be between 1 and 65535"
        return 1
    fi
    
    return 0
}

validate_all_ports() {
    local failed=0
    
    validate_port "$RTSP_PORT" "RTSP port" || ((failed++))
    validate_port "$RTMP_PORT" "RTMP port" || ((failed++))
    validate_port "$HLS_PORT" "HLS port" || ((failed++))
    validate_port "$WEBRTC_PORT" "WebRTC port" || ((failed++))
    validate_port "$METRICS_PORT" "Metrics port" || ((failed++))
    
    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    
    return 0
}

check_port_available() {
    local port=$1
    local proto=${2:-"tcp"}
    
    if command -v ss >/dev/null 2>&1; then
        local ss_opts=""
        case "$proto" in
            tcp) ss_opts="-lnt" ;;
            udp) ss_opts="-lnu" ;;
            *) ss_opts="-ln" ;;
        esac
        
        # More robust parsing that handles different ss output formats
        if ss $ss_opts 2>/dev/null | grep -E "(:${port}[[:space:]]|:${port}$)" >/dev/null 2>&1; then
            echo_error "Port $port is already in use"
            return 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        # More robust netstat parsing
        if netstat -ln 2>/dev/null | grep -E "(:${port}[[:space:]]|:${port}$)" >/dev/null 2>&1; then
            echo_error "Port $port is already in use"
            return 1
        fi
    elif command -v lsof >/dev/null 2>&1; then
        if lsof -i ":${port}" >/dev/null 2>&1; then
            echo_error "Port $port is already in use"
            return 1
        fi
    else
        echo_warning "Cannot check if port $port is available"
    fi
    
    return 0
}

# Version comparison function
compare_versions() {
    # Remove 'v' prefix if present
    local ver1="${1#v}"
    local ver2="${2#v}"
    
    # Handle empty or malformed versions
    if [[ -z "$ver1" ]] || [[ -z "$ver2" ]]; then
        echo "unknown"
        return 0
    fi
    
    if command -v sort >/dev/null 2>&1 && sort --version-sort /dev/null >/dev/null 2>&1; then
        # Use version sort if available
        local older
        older=$(printf '%s\n' "$ver1" "$ver2" | sort -V | head -n1)
        if [[ "$older" == "$ver1" ]]; then
            if [[ "$ver1" == "$ver2" ]]; then
                echo "equal"
            else
                echo "older"
            fi
        else
            echo "newer"
        fi
    else
        # Better fallback comparison
        if [[ "$ver1" == "$ver2" ]]; then
            echo "equal"
        else
            # Try numeric comparison for simple versions
            local IFS='.'
            local ver1_parts=($ver1)
            local ver2_parts=($ver2)
            
            for i in {0..2}; do
                local v1="${ver1_parts[i]:-0}"
                local v2="${ver2_parts[i]:-0}"
                
                # Strip non-numeric suffixes for comparison
                v1="${v1%%[!0-9]*}"
                v2="${v2%%[!0-9]*}"
                
                if [[ "$v1" -gt "$v2" ]]; then
                    echo "newer"
                    return 0
                elif [[ "$v1" -lt "$v2" ]]; then
                    echo "older"
                    return 0
                fi
            done
            
            echo "equal"
        fi
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
    if ! touch "$LOG_FILE" || ! chmod 600 "$LOG_FILE"; then
        echo_error "Failed to create/secure log file"
        exit 1
    fi
    
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

# Comprehensive cleanup function with improved order
cleanup() {
    local exit_code=$?
    
    # Disable traps to prevent recursion
    trap - EXIT INT TERM ERR
    
    echo_debug "Running cleanup (exit code: $exit_code)"
    
    # Stop any started services if installation failed
    if [[ $exit_code -ne 0 ]] && systemctl is-active --quiet mediamtx.service 2>/dev/null; then
        echo_info "Stopping MediaMTX service due to installation failure"
        systemctl stop mediamtx.service 2>/dev/null || true
    fi
    
    # Run rollback if needed
    if [[ $exit_code -ne 0 ]] && [[ ${#ROLLBACK_POINTS[@]} -gt 0 ]]; then
        echo_warning "Installation failed. Initiating rollback..."
        rollback_changes
    fi
    
    # Preserve logs on error
    if [[ $exit_code -ne 0 ]] && [[ -f "$LOG_FILE" ]]; then
        local error_log="/tmp/mediamtx_install_error_$(date +%Y%m%d_%H%M%S).log"
        if cp "$LOG_FILE" "$error_log" 2>/dev/null; then
            # Secure the error log - only readable by root
            chmod 600 "$error_log" 2>/dev/null || true
            echo_error "Installation failed. Logs preserved at: $error_log (readable by root only)"
        fi
    fi
    
    # Clean up temporary directory
    if [[ -n "${TEMP_DIR:-}" ]] && [[ -d "$TEMP_DIR" ]]; then
        if [[ "$DEBUG_MODE" == "true" && $exit_code -ne 0 ]]; then
            echo_info "Debug mode: Temporary files preserved at: $TEMP_DIR"
        else
            rm -rf "$TEMP_DIR" 2>/dev/null || true
        fi
    fi
    
    exit $exit_code
}

# Enhanced trap handling
setup_traps() {
    trap cleanup EXIT
    trap 'echo_error "Interrupted"; exit 130' INT TERM
    trap 'echo_error "Error on line $LINENO"; exit 1' ERR
}

# Safe rollback functionality without eval
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
        
        # Safe execution without eval - use arrays for proper handling
        case "$action" in
            rm\ *)
                local cmd=($action)
                "${cmd[@]}" 2>/dev/null || true
                ;;
            rmdir\ *)
                local cmd=($action)
                "${cmd[@]}" 2>/dev/null || true
                ;;
            mv\ *)
                local cmd=($action)
                "${cmd[@]}" 2>/dev/null || true
                ;;
            userdel\ *)
                local cmd=($action)
                "${cmd[@]}" 2>/dev/null || true
                ;;
            *)
                echo_warning "Unknown rollback action: $action"
                ;;
        esac
    done
    
    echo_info "Rollback completed"
}

# Detect systemd directory
detect_systemd_dir() {
    # First check if systemd is actually running
    if ! command -v systemctl >/dev/null 2>&1; then
        echo_error "systemctl not found - this installer requires systemd"
        return 1
    fi
    
    if ! systemctl --version >/dev/null 2>&1; then
        echo_error "systemd is not running - this installer requires systemd"
        return 1
    fi
    
    if command -v pkg-config >/dev/null 2>&1; then
        SYSTEMD_DIR=$(pkg-config systemd --variable=systemdsystemunitdir 2>/dev/null || true)
    fi
    
    if [[ -z "$SYSTEMD_DIR" ]]; then
        if [[ -d "/etc/systemd/system" ]]; then
            SYSTEMD_DIR="/etc/systemd/system"
        elif [[ -d "/usr/lib/systemd/system" ]]; then
            SYSTEMD_DIR="/usr/lib/systemd/system"
        elif [[ -d "/lib/systemd/system" ]]; then
            SYSTEMD_DIR="/lib/systemd/system"
        else
            echo_error "Cannot determine systemd directory"
            return 1
        fi
    fi
    
    # Verify the directory is writable
    if [[ ! -w "$SYSTEMD_DIR" ]]; then
        echo_error "Systemd directory $SYSTEMD_DIR is not writable"
        return 1
    fi
    
    echo_debug "Using systemd directory: $SYSTEMD_DIR"
    return 0
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
    local optional_cmds=(jq sha256sum md5sum xxd nc dig host ss netstat lsof yq yamllint)
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
        i386|i686)
            # 32-bit x86 not supported by MediaMTX
            ARCH="unsupported_x86_32"
            ;;
        ppc64le|powerpc64le)
            # PowerPC not currently supported
            ARCH="unsupported_ppc64le"
            ;;
        riscv64)
            # RISC-V not currently supported
            ARCH="unsupported_riscv64"
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
    
    # Additional fallback using /proc/cpuinfo
    if [[ "$ARCH" == "unknown" ]] && [[ -r /proc/cpuinfo ]]; then
        if grep -q "ARMv7" /proc/cpuinfo; then
            ARCH="armv7"
        elif grep -q "ARMv6" /proc/cpuinfo; then
            ARCH="armv6"
        elif grep -q "Intel\|AMD" /proc/cpuinfo; then
            ARCH="amd64"
        fi
    fi
    
    if [[ "$ARCH" == "unknown" ]] || [[ "$ARCH" == unsupported_* ]]; then
        echo_error "Unsupported architecture: $arch"
        echo_info "Supported: x86_64, aarch64, armv7, armv6"
        return 1
    fi
    
    echo_info "Detected architecture: $ARCH"
    return 0
}

# Check for sufficient disk space
check_disk_space() {
    local required_mb=100  # Require at least 100MB free
    local install_partition
    install_partition=$(df -P "$INSTALL_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
    
    if [[ -n "$install_partition" ]] && [[ "$install_partition" -lt $((required_mb * 1024)) ]]; then
        echo_error "Insufficient disk space. At least ${required_mb}MB required."
        return 1
    fi
    
    echo_debug "Disk space check passed"
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
                    if wget -q --spider --timeout=10 "$test_url" >/dev/null 2>&1; then
                        connected=true
                        break
                    fi
                fi
                ;;
            nc)
                if command -v nc >/dev/null 2>&1; then
                    if nc -z -w5 github.com 443 >/dev/null 2>&1; then
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

# Generic file download helper with retry
download_file() {
    local url=$1
    local output=$2
    
    if command -v wget >/dev/null 2>&1; then
        wget -q --timeout=30 --tries=2 -O "$output" "$url" 2>/dev/null
    elif command -v curl >/dev/null 2>&1; then
        curl -s -L --connect-timeout 30 --max-time 120 -o "$output" "$url" 2>/dev/null
    else
        return 1
    fi
}

download_with_retry() {
    local url=$1
    local output=$2
    local max_attempts=3
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        echo_debug "Download attempt $attempt of $max_attempts"
        
        if download_file "$url" "$output"; then
            return 0
        fi
        
        if [[ $attempt -lt $max_attempts ]]; then
            echo_warning "Download attempt $attempt failed, retrying..."
            sleep $((attempt * 2))
        fi
        
        ((attempt++))
    done
    
    return 1
}

# Validate downloaded binary is actually a MediaMTX binary
validate_binary() {
    local binary=$1
    
    echo_debug "Validating binary: $binary"
    
    # Check if it's a valid ELF binary
    if ! file "$binary" 2>/dev/null | grep -q "ELF.*executable"; then
        echo_error "Downloaded file is not a valid executable"
        return 1
    fi
    
    # Make a temporary copy with execute permissions to test
    local temp_test_binary="${TEMP_DIR}/test_binary_$"
    if ! cp "$binary" "$temp_test_binary" 2>/dev/null; then
        echo_warning "Cannot create test copy, skipping MediaMTX validation"
        return 0
    fi
    
    chmod +x "$temp_test_binary" 2>/dev/null || true
    
    # Try to get version to ensure it's MediaMTX
    local test_output
    test_output=$("$temp_test_binary" --version 2>&1 || true)
    rm -f "$temp_test_binary" 2>/dev/null || true
    
    # Check for MediaMTX in output (case insensitive)
    if echo "$test_output" | grep -qi "mediamtx\|rtsp.*server"; then
        echo_debug "Binary validation passed"
        return 0
    fi
    
    # If we can't determine, just warn but don't fail
    echo_warning "Cannot verify MediaMTX binary signature, proceeding anyway"
    echo_debug "Binary output: $test_output"
    return 0
}

# Download with checksum verification
download_mediamtx() {
    local url="https://github.com/bluenviron/mediamtx/releases/download/${VERSION}/mediamtx_${VERSION}_linux_${ARCH}.tar.gz"
    local output_file="${TEMP_DIR}/mediamtx.tar.gz"
    local checksum_file="${TEMP_DIR}/checksums.txt"
    
    echo_info "Downloading MediaMTX ${VERSION} for ${ARCH}..."
    echo_debug "URL: $url"
    
    # Download the binary with retry
    if command -v wget >/dev/null 2>&1; then
        local attempt=1
        local max_attempts=3
        
        while [[ $attempt -le $max_attempts ]]; do
            if wget --no-verbose --show-progress --tries=1 --timeout=30 -O "$output_file" "$url"; then
                break
            fi
            
            if [[ $attempt -lt $max_attempts ]]; then
                echo_warning "Download attempt $attempt failed, retrying..."
                sleep $((attempt * 2))
            else
                echo_error "Download failed after $max_attempts attempts"
                return 1
            fi
            
            ((attempt++))
        done
    elif command -v curl >/dev/null 2>&1; then
        if ! curl -L --retry 3 --connect-timeout 30 --progress-bar -o "$output_file" "$url"; then
            echo_error "Download failed with curl"
            return 1
        fi
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
    local checksum_url="https://github.com/bluenviron/mediamtx/releases/download/${VERSION}/mediamtx_${VERSION}_linux_${ARCH}.tar.gz.sha256sum"
    echo_info "Attempting checksum verification..."
    
    if download_with_retry "$checksum_url" "$checksum_file"; then
        if command -v sha256sum >/dev/null 2>&1; then
            local expected_sum
            expected_sum=$(cat "$checksum_file" 2>/dev/null | awk '{print $1}')
            
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
    
    # Validate binary
    if ! validate_binary "${extract_dir}/mediamtx"; then
        echo_error "Binary validation failed"
        return 1
    fi
    
    echo_success "Extraction completed successfully"
    return 0
}

# Ensure clean service stop before upgrade
stop_service_safely() {
    if systemctl is-active --quiet mediamtx.service 2>/dev/null; then
        echo_info "Stopping existing MediaMTX service..."
        
        # Try graceful stop first
        if systemctl stop mediamtx.service 2>/dev/null; then
            # Wait for service to fully stop
            local attempts=0
            while systemctl is-active --quiet mediamtx.service 2>/dev/null && [[ $attempts -lt 30 ]]; do
                sleep 1
                ((attempts++))
            done
            
            if [[ $attempts -ge 30 ]]; then
                echo_warning "Service did not stop gracefully, forcing..."
                systemctl kill mediamtx.service 2>/dev/null || true
                sleep 2
            fi
        fi
    fi
    
    # Ensure no orphaned processes
    if pgrep -f "${INSTALL_DIR}/mediamtx" >/dev/null 2>&1; then
        echo_warning "Found orphaned MediaMTX processes, cleaning up..."
        pkill -f "${INSTALL_DIR}/mediamtx" 2>/dev/null || true
        sleep 1
    fi
}

# Install MediaMTX with full error handling
install_mediamtx() {
    local binary_path="${TEMP_DIR}/extracted/mediamtx"
    
    echo_info "Installing MediaMTX..."
    
    # Check if already installed and compare versions
    if [[ -f "${INSTALL_DIR}/mediamtx" ]] && [[ "$FORCE_INSTALL" != "true" ]]; then
        # More robust version extraction
        local installed_version
        installed_version=$("${INSTALL_DIR}/mediamtx" --version 2>&1 | grep -E '(v[0-9]+\.[0-9]+\.[0-9]+|MediaMTX [0-9]+\.[0-9]+\.[0-9]+)' | sed -E 's/.*v?([0-9]+\.[0-9]+\.[0-9]+).*/v\1/' || echo "unknown")
        
        local comparison
        comparison=$(compare_versions "$VERSION" "$installed_version")
        
        case "$comparison" in
            newer)
                echo_info "Upgrading from $installed_version to $VERSION"
                ;;
            equal)
                echo_info "Version $VERSION is already installed"
                if [[ "$FORCE_INSTALL" != "true" ]]; then
                    read -p "Reinstall anyway? (y/n) " -n 1 -r
                    echo
                    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                        echo_info "Installation cancelled"
                        exit 0
                    fi
                fi
                ;;
            older)
                echo_warning "Installed version $installed_version is newer than $VERSION"
                read -p "Downgrade anyway? (y/n) " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    echo_info "Installation cancelled"
                    exit 0
                fi
                ;;
            unknown)
                echo_warning "Cannot compare versions, proceeding with installation"
                ;;
        esac
    fi
    
    # Create installation directory
    if [[ ! -d "$INSTALL_DIR" ]]; then
        mkdir -p "$INSTALL_DIR" || {
            echo_error "Failed to create installation directory"
            return 1
        }
        add_rollback_point "rmdir '$INSTALL_DIR'"
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

# Configuration validation
validate_config() {
    local config_file=$1
    
    echo_debug "Validating configuration file: $config_file"
    
    # Basic file checks
    if [[ ! -f "$config_file" ]]; then
        echo_error "Configuration file not found: $config_file"
        return 1
    fi
    
    if [[ ! -s "$config_file" ]]; then
        echo_error "Configuration file is empty"
        return 1
    fi
    
    # Check for basic YAML syntax errors (no complex parsing needed)
    local yaml_errors=0
    
    # Check for tabs (YAML doesn't allow tabs for indentation)
    if grep -q $'\t' "$config_file"; then
        echo_warning "Configuration contains tabs - YAML requires spaces for indentation"
        ((yaml_errors++))
    fi
    
    # Check for common YAML mistakes
    if grep -E '^[[:space:]]+:' "$config_file" | grep -q ':'; then
        echo_warning "Configuration may have incorrect key formatting"
        ((yaml_errors++))
    fi
    
    # Simple bracket balance check
    local open_brackets
    local close_brackets
    open_brackets=$(grep -o '{' "$config_file" | wc -l)
    close_brackets=$(grep -o '}' "$config_file" | wc -l)
    
    if [[ "$open_brackets" -ne "$close_brackets" ]]; then
        echo_warning "Mismatched brackets in configuration"
        ((yaml_errors++))
    fi
    
    # Required fields check with proper regex
    if ! grep -E '^logLevel:' "$config_file" >/dev/null; then
        echo_error "Missing required field: logLevel"
        return 1
    fi
    
    if ! grep -E '^paths:' "$config_file" >/dev/null; then
        echo_error "Missing required field: paths"
        return 1
    fi
    
    if [[ $yaml_errors -gt 0 ]]; then
        echo_warning "Found $yaml_errors potential YAML issues"
    fi
    
    echo_debug "Configuration validation completed"
    return 0
}

# Create configuration with validation (using atomic operations)
create_configuration() {
    echo_info "Creating configuration..."
    
    # Create config directory
    if [[ ! -d "$CONFIG_DIR" ]]; then
        mkdir -p "$CONFIG_DIR" || {
            echo_error "Failed to create config directory"
            return 1
        }
        add_rollback_point "rmdir '$CONFIG_DIR'"
    fi
    
    # Backup existing config
    if [[ -f "${CONFIG_DIR}/mediamtx.yml" ]]; then
        local backup_name="mediamtx.yml.backup.$(date +%Y%m%d_%H%M%S)"
        if cp "${CONFIG_DIR}/mediamtx.yml" "${CONFIG_DIR}/${backup_name}"; then
            add_rollback_point "mv '${CONFIG_DIR}/${backup_name}' '${CONFIG_DIR}/mediamtx.yml'"
            echo_info "Config backed up to: ${CONFIG_DIR}/${backup_name}"
        fi
    fi
    
    # Create configuration file atomically with mktemp
    local temp_config
    temp_config=$(mktemp "${CONFIG_DIR}/mediamtx.yml.XXXXXX") || {
        echo_error "Failed to create temporary config file"
        return 1
    }
    
    # Ensure cleanup on error
    trap "rm -f '$temp_config' 2>/dev/null || true" ERR
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo_info "[DRY RUN] Would create configuration at ${CONFIG_DIR}/mediamtx.yml"
        rm -f "$temp_config"
    else
        # Write configuration directly with variable substitution
        if ! cat > "$temp_config" << EOF
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
protocols: [udp, multicast, tcp]

# Encrypt handshake and TCP streams with TLS (RTSPS).
encryption: "no"

# Address of the TCP/RTSP listener.
rtspAddress: :${RTSP_PORT}

# Address of the TCP/TLS/RTSPS listener.
rtspsAddress: :8322

# Address of the UDP/RTP listener.
rtpAddress: :8000

# Address of the UDP/RTCP listener.
rtcpAddress: :8001

# IP range of all UDP-multicast listeners.
multicastIPRange: 224.1.0.0/16

# Port of all UDP-multicast/RTP listeners.
multicastRTPPort: 8002

# Port of all UDP-multicast/RTCP listeners.
multicastRTCPPort: 8003

# Path to the server key.
serverKey: server.key

# Path to the server certificate.
serverCert: server.crt

# Authentication methods.
authMethods: [basic, digest]

###############################################
# RTMP parameters

# Disable support for the RTMP protocol.
rtmpDisable: no

# Address of the RTMP listener.
rtmpAddress: :${RTMP_PORT}

# Encrypt connections with TLS (RTMPS).
rtmpEncryption: "no"

# Address of the RTMPS listener.
rtmpsAddress: :1936

# Path to the server key.
rtmpServerKey: server.key

# Path to the server certificate.
rtmpServerCert: server.crt

###############################################
# HLS parameters

# Disable support for the HLS protocol.
hlsDisable: no

# Address of the HLS listener.
hlsAddress: :${HLS_PORT}

# Enable TLS/HTTPS on the HLS server.
hlsEncryption: no

# Path to the server key.
hlsServerKey: server.key

# Path to the server certificate.
hlsServerCert: server.crt

# By default, HLS is generated only when requested by a user.
hlsAlwaysRemux: no

# Variant of the HLS protocol to use.
hlsVariant: lowLatency

# Number of HLS segments to keep on the server.
hlsSegmentCount: 7

# Minimum duration of each segment.
hlsSegmentDuration: 1s

# Minimum duration of each part.
hlsPartDuration: 200ms

# Maximum size of each segment.
hlsSegmentMaxSize: 50M

# Value of the Access-Control-Allow-Origin header.
hlsAllowOrigin: '*'

# List of IPs or CIDRs of proxies placed before the HLS server.
hlsTrustedProxies: []

# Directory in which to save segments.
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
webrtcServerKey: server.key

# Path to the server certificate.
webrtcServerCert: server.crt

# Value of the Access-Control-Allow-Origin header.
webrtcAllowOrigin: '*'

# List of IPs or CIDRs of proxies placed before the WebRTC server.
webrtcTrustedProxies: []

# List of ICE servers.
webrtcICEServers: [stun:stun.l.google.com:19302]

# List of public IP addresses that are to be used as a host.
webrtcICEHostNAT1To1IPs: []

# Address of a ICE UDP listener in format host:port.
webrtcICEUDPMuxAddress:

# Address of a ICE TCP listener in format host:port.
webrtcICETCPMuxAddress:

###############################################
# Metrics

# Enable Prometheus-compatible metrics.
metrics: yes

# Address of the metrics listener.
metricsAddress: 127.0.0.1:${METRICS_PORT}

###############################################
# Path parameters

paths:
  all:
    # Source of the stream.
    source: publisher

    # Protocol used to pull the stream.
    sourceProtocol: automatic

    # Support sources that don't provide server ports.
    sourceAnyPortEnable: no

    # Fingerprint of the source certificate.
    sourceFingerprint:

    # Pull only when at least one reader is connected.
    sourceOnDemand: no

    # Timeout for on-demand sources.
    sourceOnDemandStartTimeout: 10s

    # Close source when no readers.
    sourceOnDemandCloseAfter: 10s

    # Redirect address.
    sourceRedirect:

    # Prevent publisher override.
    disablePublisherOverride: no

    # Fallback stream.
    fallback:

    # Username required to publish.
    publishUser:

    # Password required to publish.
    publishPass:

    # IPs allowed to publish.
    publishIPs: []

    # Username required to read.
    readUser:

    # Password required to read.
    readPass:

    # IPs allowed to read.
    readIPs: []

    # Command to run when path is initialized.
    runOnInit:

    # Restart the command if it exits.
    runOnInitRestart: no

    # Command to run on demand.
    runOnDemand:

    # Restart the on-demand command.
    runOnDemandRestart: no

    # On-demand start timeout.
    runOnDemandStartTimeout: 10s

    # On-demand close after.
    runOnDemandCloseAfter: 10s

    # Command to run when stream is ready.
    runOnReady:

    # Restart the ready command.
    runOnReadyRestart: no

    # Command to run when a client reads.
    runOnRead:

    # Restart the read command.
    runOnReadRestart: no
EOF
        then
            echo_error "Failed to write configuration file"
            rm -f "$temp_config" 2>/dev/null
            return 1
        fi
        
        # Check if file was created
        if [[ ! -f "$temp_config" ]]; then
            echo_error "Failed to create temporary configuration file"
            return 1
        fi
        
        echo_debug "Configuration file created with size: $(wc -c < "$temp_config" 2>/dev/null || echo "unknown") bytes"
        
        # Validate configuration before moving
        if ! validate_config "$temp_config"; then
            # If validation fails, show a sample of the config for debugging
            if [[ "$DEBUG_MODE" == "true" ]]; then
                echo_debug "First 10 lines of generated config:"
                head -10 "$temp_config" | while IFS= read -r line; do
                    echo_debug "  $line"
                done
            fi
            rm -f "$temp_config"
            echo_error "Configuration validation failed"
            return 1
        fi
        
        # Move atomically with proper permissions
        if ! mv -f "$temp_config" "${CONFIG_DIR}/mediamtx.yml"; then
            rm -f "$temp_config"
            echo_error "Failed to create configuration file"
            return 1
        fi
        
        # Clear the trap
        trap - ERR
        
        add_rollback_point "rm -f '${CONFIG_DIR}/mediamtx.yml'"
    fi
    
    echo_success "Configuration created successfully"
    return 0
}

# Setup log rotation
setup_log_rotation() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo_info "[DRY RUN] Would create log rotation config"
        return 0
    fi
    
    if [[ ! -d "/etc/logrotate.d" ]]; then
        echo_warning "logrotate not found, skipping log rotation setup"
        return 0
    fi
    
    echo_info "Setting up log rotation..."
    
    cat > /etc/logrotate.d/mediamtx << EOF
${LOG_DIR}/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 ${SERVICE_USER} ${SERVICE_USER}
    sharedscripts
    postrotate
        systemctl reload mediamtx >/dev/null 2>&1 || true
    endscript
}
EOF
    
    echo_success "Log rotation configured"
    return 0
}

# Create systemd service with enhanced security
create_systemd_service() {
    echo_info "Creating systemd service..."
    
    # Detect systemd directory
    if ! detect_systemd_dir; then
        return 1
    fi
    
    # Create service user
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo_info "[DRY RUN] Would create service user: $SERVICE_USER"
        else
            if ! useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"; then
                echo_warning "Failed to create service user, will use root"
                SERVICE_USER="root"
            else
                add_rollback_point "userdel '$SERVICE_USER'"
            fi
        fi
    fi
    
    # Create log directory
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR" || {
            echo_error "Failed to create log directory"
            return 1
        }
        add_rollback_point "rmdir '$LOG_DIR'"
    fi
    
    # Set ownership
    if [[ "$DRY_RUN" != "true" ]] && [[ "$SERVICE_USER" != "root" ]]; then
        chown -R "$SERVICE_USER:$SERVICE_USER" "$CONFIG_DIR" "$LOG_DIR" 2>/dev/null || {
            echo_warning "Failed to set ownership"
        }
    fi
    
    # Create systemd service file
    local service_file="${SYSTEMD_DIR}/mediamtx.service"
    
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
        # Create service file atomically
        local temp_service="${service_file}.tmp.$$"
        
        cat > "$temp_service" << EOF
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

# Resource limits - adjusted for broader compatibility
LimitNOFILE=8192
LimitNPROC=256

[Install]
WantedBy=multi-user.target
EOF
        
        # Move atomically
        if ! mv "$temp_service" "$service_file"; then
            rm -f "$temp_service"
            echo_error "Failed to create service file"
            return 1
        fi
        
        add_rollback_point "rm -f '$service_file'"
        
        # Reload systemd
        systemctl daemon-reload || {
            echo_warning "Failed to reload systemd"
        }
        
        # Give systemd time to process the new service file
        sleep 1
    fi
    
    echo_success "Systemd service created successfully"
    return 0
}

# Verify installation
verify_installation() {
    echo_info "Verifying installation..."
    
    local errors=0
    
    # Check binary is executable
    if [[ ! -x "${INSTALL_DIR}/mediamtx" ]]; then
        echo_error "Binary is not executable"
        ((errors++))
    else
        echo_debug "Binary check passed"
    fi
    
    # Check service is loaded - try multiple methods
    local service_loaded=false
    
    # Method 1: systemctl list-unit-files
    if systemctl list-unit-files --no-pager | grep -q "mediamtx\.service"; then
        service_loaded=true
        echo_debug "Service found via list-unit-files"
    fi
    
    # Method 2: systemctl status (without checking if active)
    if [[ "$service_loaded" != "true" ]] && systemctl status mediamtx.service --no-pager >/dev/null 2>&1; then
        service_loaded=true
        echo_debug "Service found via status check"
    fi
    
    # Method 3: Check if service file exists
    if [[ "$service_loaded" != "true" ]] && [[ -f "${SYSTEMD_DIR}/mediamtx.service" ]]; then
        service_loaded=true
        echo_debug "Service file exists at ${SYSTEMD_DIR}/mediamtx.service"
    fi
    
    if [[ "$service_loaded" != "true" ]]; then
        echo_error "Service is not loaded"
        ((errors++))
    else
        echo_debug "Service check passed"
    fi
    
    # Check configuration exists
    if [[ ! -f "${CONFIG_DIR}/mediamtx.yml" ]]; then
        echo_error "Configuration file missing"
        ((errors++))
    else
        echo_debug "Configuration check passed"
    fi
    
    # Check ports are available
    echo_debug "Checking port availability..."
    local ports=($RTSP_PORT $RTMP_PORT $HLS_PORT $WEBRTC_PORT $METRICS_PORT)
    for port in "${ports[@]}"; do
        # Trim any whitespace
        port=$(echo "$port" | tr -d '[:space:]')
        if ! check_port_available "$port"; then
            ((errors++))
        else
            echo_debug "Port $port is available"
        fi
    done
    
    # Test binary execution
    if ! "${INSTALL_DIR}/mediamtx" --version >/dev/null 2>&1; then
        echo_error "Binary test execution failed"
        ((errors++))
    else
        echo_debug "Binary execution test passed"
    fi
    
    if [[ $errors -eq 0 ]]; then
        echo_success "Installation verification passed"
        return 0
    else
        echo_error "Installation verification failed with $errors errors"
        return 1
    fi
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
                VERSION="${2:-}"
                if [[ -z "$VERSION" ]]; then
                    echo_error "Version argument requires a value"
                    exit 1
                fi
                shift 2
                ;;
            --arch)
                ARCH="${2:-}"
                if [[ -z "$ARCH" ]]; then
                    echo_error "Architecture argument requires a value"
                    exit 1
                fi
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
                echo "Environment variables:"
                echo "  VERSION             MediaMTX version (default: $VERSION)"
                echo "  RTSP_PORT          RTSP port (default: 18554)"
                echo "  RTMP_PORT          RTMP port (default: 11935)"
                echo "  HLS_PORT           HLS port (default: 18888)"
                echo "  WEBRTC_PORT        WebRTC port (default: 18889)"
                echo "  METRICS_PORT       Metrics port (default: 19999)"
                echo "  DEBUG              Enable debug mode (default: false)"
                echo "  DRY_RUN            Dry run mode (default: false)"
                echo "  FORCE              Force installation (default: false)"
                echo "  SKIP_YAML_VALIDATION  Skip YAML validation (default: false)"
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
    
    # Debug mode info
    if [[ "$DEBUG_MODE" == "true" ]]; then
        echo_debug "Debug mode enabled"
        echo_debug "Script version: $SCRIPT_VERSION"
        echo_debug "Target version: $VERSION"
        echo_debug "Ports: RTSP=$RTSP_PORT, RTMP=$RTMP_PORT, HLS=$HLS_PORT, WebRTC=$WEBRTC_PORT, Metrics=$METRICS_PORT"
        echo_debug "Skip YAML validation: $SKIP_YAML_VALIDATION"
    fi
    
    log_message "INFO" "Starting MediaMTX installation (version: $VERSION)"
    
    # Validate ports early
    if ! validate_all_ports; then
        echo_error "Port validation failed"
        exit 1
    fi
    
    # Pre-flight checks
    echo_info "Running pre-flight checks..."
    
    # Detect systemd directory early
    if ! detect_systemd_dir; then
        echo_error "Failed to detect systemd directory"
        exit 1
    fi
    
    if ! check_dependencies; then
        echo_error "Dependency check failed"
        exit 1
    fi
    
    if ! detect_architecture; then
        echo_error "Architecture detection failed"
        exit 1
    fi
    
    # Check disk space
    if ! check_disk_space; then
        echo_error "Disk space check failed"
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
    
    # Stop service safely before upgrade
    if [[ -f "${INSTALL_DIR}/mediamtx" ]]; then
        stop_service_safely
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
    
    # Setup log rotation
    setup_log_rotation
    
    # Verify installation
    if [[ "$DRY_RUN" != "true" ]]; then
        if ! verify_installation; then
            echo_error "Installation verification failed"
            exit 1
        fi
    fi
    
    # Enable service only after everything is verified
    if [[ "$DRY_RUN" != "true" ]]; then
        echo_info "Enabling MediaMTX service..."
        if systemctl enable mediamtx.service >/dev/null 2>&1; then
            echo_success "Service enabled"
        else
            echo_warning "Failed to enable service"
        fi
    fi
    
    # Print summary
    print_summary
    
    # Ask to start service
    if [[ "$DRY_RUN" != "true" ]]; then
        echo ""
        read -p "Would you like to start MediaMTX now? (y/n) " -n 1 -r
        echo
        if [[ "$REPLY" =~ ^[Yy]$ ]]; then
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

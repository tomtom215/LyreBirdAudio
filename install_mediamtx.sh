#!/bin/bash
#
# Minimal MediaMTX Installer
# This script installs MediaMTX with custom ports and minimal configuration
#

set -e  # Exit immediately if a command exits with a non-zero status

# Configuration
INSTALL_DIR="/usr/local/mediamtx"
CONFIG_DIR="/etc/mediamtx"
LOG_DIR="/var/log/mediamtx"
SERVICE_USER="mediamtx"

# Latest version
VERSION="v1.12.0"
TEMP_DIR="/tmp/mediamtx-install-$(date +%s)"  # Unique temp dir

# Custom ports (to avoid conflicts)
RTSP_PORT="18554"
RTMP_PORT="11935"
HLS_PORT="18888" 
WEBRTC_PORT="18889"
METRICS_PORT="19999"

# Print colored messages
echo_info() { echo -e "\033[34m[INFO]\033[0m $1"; }
echo_success() { echo -e "\033[32m[SUCCESS]\033[0m $1"; }
echo_warning() { echo -e "\033[33m[WARNING]\033[0m $1"; }
echo_error() { echo -e "\033[31m[ERROR]\033[0m $1"; }

# Detect architecture (simplified)
detect_arch() {
    local arch=$(uname -m)
    
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64v8" ;;
        armv7*)  echo "armv7" ;;
        armv6*)  echo "armv6" ;;
        *)       echo_error "Unsupported architecture: $arch"; exit 1 ;;
    esac
}

# Create directories
setup_directories() {
    echo_info "Creating directories..."
    
    for dir in "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" "$TEMP_DIR"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir" || { echo_error "Failed to create directory: $dir"; exit 1; }
            echo_info "Created directory: $dir"
        else
            echo_info "Directory already exists: $dir"
        fi
    done
    
    echo_success "Directories setup complete"
}

# Download MediaMTX
download_mediamtx() {
    local arch=$1
    local version=$2
    
    # Clean URL construction
    local url="https://github.com/bluenviron/mediamtx/releases/download/${version}/mediamtx_${version}_linux_${arch}.tar.gz"
    local output_file="$TEMP_DIR/mediamtx.tar.gz"
    
    echo_info "Architecture: $arch"
    echo_info "Version: $version"
    echo_info "Downloading from: $url"
    
    if command -v wget >/dev/null 2>&1; then
        echo_info "Using wget to download..."
        wget -q --show-progress -O "$output_file" "$url" || {
            echo_error "wget download failed"
            return 1
        }
    elif command -v curl >/dev/null 2>&1; then
        echo_info "Using curl to download..."
        curl -s -L --progress-bar -o "$output_file" "$url" || {
            echo_error "curl download failed"
            return 1
        }
    else
        echo_error "Neither wget nor curl is available"
        return 1
    fi
    
    echo_success "Download successful"
    return 0
}

# Extract MediaMTX
extract_mediamtx() {
    local tarball="$TEMP_DIR/mediamtx.tar.gz"
    
    echo_info "Extracting MediaMTX..."
    
    if ! tar -xzf "$tarball" -C "$TEMP_DIR"; then
        echo_error "Extraction failed"
        return 1
    fi
    
    echo_success "Extraction successful"
    return 0
}

# Install MediaMTX
install_mediamtx() {
    echo_info "Installing MediaMTX..."
    
    # Find binary
    local binary_path=""
    for file in "$TEMP_DIR"/*/mediamtx "$TEMP_DIR"/mediamtx*; do
        if [ -f "$file" ] && [ -x "$file" ]; then
            binary_path="$file"
            break
        fi
    done
    
    if [ -z "$binary_path" ]; then
        echo_error "MediaMTX binary not found in extracted files"
        find "$TEMP_DIR" -type f | sort
        return 1
    fi
    
    # Copy binary
    cp "$binary_path" "$INSTALL_DIR/mediamtx"
    chmod 755 "$INSTALL_DIR/mediamtx"
    
    # Test binary
    echo_info "Testing MediaMTX binary..."
    if ! "$INSTALL_DIR/mediamtx" --version; then
        echo_error "Binary test failed"
        return 1
    fi
    
    # Create minimal config file
    echo_info "Creating minimal configuration..."
    cat > "$CONFIG_DIR/mediamtx.yml" << EOF
# MediaMTX minimal configuration
logLevel: info
logDestinations: [stdout, file]
logFile: $LOG_DIR/mediamtx.log

rtspAddress: :$RTSP_PORT
rtmpAddress: :$RTMP_PORT
hlsAddress: :$HLS_PORT
webrtcAddress: :$WEBRTC_PORT

metrics: yes
metricsAddress: :$METRICS_PORT

paths:
  all:
EOF

    echo_success "MediaMTX installed successfully with custom ports:"
    echo_info "RTSP: $RTSP_PORT, RTMP: $RTMP_PORT, HLS: $HLS_PORT, WebRTC: $WEBRTC_PORT, Metrics: $METRICS_PORT"
    return 0
}

# Create systemd service
create_service() {
    echo_info "Creating systemd service..."
    
    # Create user if it doesn't exist
    if ! id "$SERVICE_USER" >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
        echo_info "Created service user: $SERVICE_USER"
    fi
    
    # Set ownership
    chown -R "$SERVICE_USER:" "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"
    chmod -R 755 "$INSTALL_DIR"
    chmod -R 750 "$CONFIG_DIR" "$LOG_DIR"
    
    # Create log file with proper permissions
    touch "$LOG_DIR/mediamtx.log"
    chown "$SERVICE_USER:" "$LOG_DIR/mediamtx.log"
    chmod 644 "$LOG_DIR/mediamtx.log"
    
    # Create systemd service file
    cat > /etc/systemd/system/mediamtx.service << EOF
[Unit]
Description=MediaMTX RTSP/RTMP/HLS/WebRTC streaming server
After=network.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=$SERVICE_USER
ExecStart=$INSTALL_DIR/mediamtx $CONFIG_DIR/mediamtx.yml
WorkingDirectory=$INSTALL_DIR
Restart=on-failure
RestartSec=10
StandardOutput=append:$LOG_DIR/mediamtx.log
StandardError=append:$LOG_DIR/mediamtx.log

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload and enable
    systemctl daemon-reload
    systemctl enable mediamtx.service
    
    echo_info "Starting service..."
    if systemctl start mediamtx.service; then
        sleep 3
        if systemctl is-active --quiet mediamtx.service; then
            echo_success "Service started successfully"
            return 0
        fi
    fi
    
    echo_error "Service failed to start. Checking logs..."
    systemctl status mediamtx.service --no-pager
    
    if [ -f "$LOG_DIR/mediamtx.log" ]; then
        echo_info "Last 10 lines from log file:"
        tail -n 10 "$LOG_DIR/mediamtx.log"
    fi
    
    # Get default configuration help if possible
    echo_info "Attempting to get default configuration format..."
    "$INSTALL_DIR/mediamtx" --help
    
    # Try to run the binary directly with minimal args to see if it works
    echo_info "Testing binary directly..."
    sudo -u "$SERVICE_USER" "$INSTALL_DIR/mediamtx" || true
    
    return 1
}

# Print post-installation information
print_info() {
    echo "====================================="
    echo "MediaMTX Installation Summary"
    echo "====================================="
    echo "Version: $VERSION"
    echo "Binary: $INSTALL_DIR/mediamtx"
    echo "Config: $CONFIG_DIR/mediamtx.yml"
    echo "Logs: $LOG_DIR/mediamtx.log"
    echo "Service: mediamtx.service"
    echo
    echo "Ports:"
    echo "- RTSP: $RTSP_PORT"
    echo "- RTMP: $RTMP_PORT"
    echo "- HLS: $HLS_PORT"
    echo "- WebRTC: $WEBRTC_PORT"
    echo "- Metrics: $METRICS_PORT"
    echo
    echo "Useful Commands:"
    echo "- Check service status: systemctl status mediamtx"
    echo "- View logs: journalctl -u mediamtx -f"
    echo "- Test stream: ffmpeg -re -f lavfi -i testsrc=size=640x480:rate=30 -f rtsp rtsp://localhost:$RTSP_PORT/test"
    echo "====================================="
}

# Cleanup on exit
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        echo_info "Cleaning up temporary files..."
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT

# Main function
main() {
    echo "====================================="
    echo "Minimal MediaMTX Installer"
    echo "====================================="
    
    # Check if running as root
    if [ "$(id -u)" -ne 0 ]; then
        echo_error "This script must be run as root or with sudo"
        exit 1
    fi
    
    # Detect architecture
    ARCH=$(detect_arch)
    echo_info "Detected architecture: $ARCH"
    
    # Setup directories
    setup_directories
    
    # Installation steps
    if download_mediamtx "$ARCH" "$VERSION" && extract_mediamtx && install_mediamtx && create_service; then
        print_info
        echo_success "Installation completed successfully"
    else
        echo_error "Installation failed"
        exit 1
    fi
}

# Run the script
main

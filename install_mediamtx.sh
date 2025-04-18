#!/bin/bash

# Exit on error
set -e

echo "Installing FFmpeg..."
sudo apt update && sudo apt install ffmpeg -y

# Function to get the latest release version
get_latest_release() {
  curl --silent "https://api.github.com/repos/bluenviron/mediamtx/releases/latest" | 
  grep '"tag_name":' | 
  sed -E 's/.*"([^"]+)".*/\1/'
}

# Get the latest release version
VERSION=$(get_latest_release)
echo "Latest MediaMTX version is: $VERSION"

# Determine CPU architecture
ARCH=$(uname -m)
echo "Detected CPU architecture: $ARCH"

# Map architecture to MediaMTX naming convention
case $ARCH in
  x86_64)
    MTX_ARCH="amd64"
    ;;
  aarch64|arm64)
    MTX_ARCH="arm64v8"
    ;;
  armv6*|armv6l)
    MTX_ARCH="armv6"
    ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

# Construct download URL
DOWNLOAD_URL="https://github.com/bluenviron/mediamtx/releases/download/${VERSION}/mediamtx_${VERSION}_linux_${MTX_ARCH}.tar.gz"
echo "Download URL: $DOWNLOAD_URL"

# Download and extract
echo "Downloading and extracting MediaMTX..."
wget -c "$DOWNLOAD_URL" -O - | sudo tar -xz -C /usr/local

echo "MediaMTX has been installed to /usr/local/mediamtx"
echo "To start MediaMTX, run: /usr/local/mediamtx/mediamtx"

# Create a systemd service file for MediaMTX (optional)
echo "Creating MediaMTX systemd service..."
cat << EOF | sudo tee /etc/systemd/system/mediamtx.service
[Unit]
Description=MediaMTX RTSP server
After=network.target

[Service]
ExecStart=/usr/local/mediamtx/mediamtx
WorkingDirectory=/usr/local/mediamtx
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
echo "Enabling and starting MediaMTX service..."
sudo systemctl enable mediamtx.service
sudo systemctl start mediamtx.service

echo "MediaMTX installation complete and service started!"
echo "To check service status: sudo systemctl status mediamtx"

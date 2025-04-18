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

# Create a temporary directory for extraction
TEMP_DIR=$(mktemp -d)
echo "Using temporary directory: $TEMP_DIR"

# Download and extract to temporary directory first
echo "Downloading and extracting MediaMTX..."
wget -c "$DOWNLOAD_URL" -O - | tar -xz -C "$TEMP_DIR"

# List extracted contents to debug
echo "Extracted files:"
ls -la "$TEMP_DIR"

# Create destination directory if it doesn't exist
sudo mkdir -p /usr/local/mediamtx

# Copy all files to final location
sudo cp -R "$TEMP_DIR"/* /usr/local/mediamtx/

# Remove temporary directory
rm -rf "$TEMP_DIR"

# Verify binary exists and set proper permissions
if [ -f "/usr/local/mediamtx/mediamtx" ]; then
  BINARY_PATH="/usr/local/mediamtx/mediamtx"
  echo "MediaMTX binary found at: $BINARY_PATH"
  sudo chmod +x "$BINARY_PATH"
else
  echo "ERROR: MediaMTX binary not found after extraction!"
  echo "Contents of /usr/local/mediamtx:"
  ls -la /usr/local/mediamtx/
  exit 1
fi

echo "MediaMTX has been installed to /usr/local/mediamtx"
echo "To start MediaMTX, run: $BINARY_PATH"

# Create a systemd service file for MediaMTX
echo "Creating MediaMTX systemd service..."
cat << EOF | sudo tee /etc/systemd/system/mediamtx.service
[Unit]
Description=MediaMTX RTSP server
After=network.target

[Service]
ExecStart=$BINARY_PATH
WorkingDirectory=/usr/local/mediamtx
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd to recognize the new service
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

# Enable and start the service
echo "Enabling and starting MediaMTX service..."
sudo systemctl enable mediamtx.service
sudo systemctl start mediamtx.service

echo "MediaMTX installation complete and service started!"
echo "To check service status: sudo systemctl status mediamtx"

#!/bin/bash

# Exit on error
set -e

echo "Setting up Audio RTSP Streaming Service..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Set up directories
echo "Creating necessary directories..."
mkdir -p /usr/local/bin
mkdir -p /var/log/audio-rtsp

# Copy startmic.sh to /usr/local/bin
echo "Installing startmic.sh script..."
cp startmic.sh /usr/local/bin/
chmod +x /usr/local/bin/startmic.sh

# Make sure startmic.sh doesn't have 'wait' at the end when run as a service
sed -i '/^wait$/d' /usr/local/bin/startmic.sh

# Create systemd service file
echo "Creating systemd service..."
cat > /etc/systemd/system/audio-rtsp.service << 'EOF'
[Unit]
Description=Audio RTSP Streaming Service
After=network.target mediamtx.service
Requires=mediamtx.service
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/bin
ExecStart=/usr/local/bin/startmic.sh
Restart=always
RestartSec=10
# Give the service time to properly start all streams
TimeoutStartSec=30
# Set resource limits to ensure stability
LimitNOFILE=65536

# Make sure the process group is killed when the service is stopped
KillMode=mixed
KillSignal=SIGTERM

# Ensure environment is properly set up
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

# Create a log rotation config to prevent logs from filling up disk
echo "Setting up log rotation..."
cat > /etc/logrotate.d/audio-rtsp << 'EOF'
/var/log/audio-rtsp/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 root root
}
EOF

# Create a helper script to check the status
echo "Creating status checking script..."
cat > /usr/local/bin/check-audio-rtsp.sh << 'EOF'
#!/bin/bash

echo "Audio RTSP Service Status:"
systemctl status audio-rtsp.service

echo -e "\nRunning Audio Streams:"
ps aux | grep "[f]fmpeg" | grep -o "rtsp://[^ ]*" | sort

echo -e "\nAvailable Sound Cards:"
cat /proc/asound/cards

# Get the machine's IP address
IP_ADDR=$(hostname -I | awk '{print $1}')
if [ -n "$IP_ADDR" ]; then
    echo -e "\nTo access streams from other devices, use: $IP_ADDR instead of localhost"
fi
EOF
chmod +x /usr/local/bin/check-audio-rtsp.sh

# Modify startmic.sh to redirect output to a log file when running as a service
echo "Modifying startmic.sh for service usage..."
cat > /usr/local/bin/startmic.sh.new << 'EOF'
#!/bin/bash

# Redirect output to log file when running as a service
if systemctl is-active --quiet audio-rtsp.service; then
    exec >> /var/log/audio-rtsp/audio-streams.log 2>&1
    echo "----------------------------------------"
    echo "Service started at $(date)"
    echo "----------------------------------------"
fi

# Rest of your original startmic.sh script content goes here
EOF

# Append the original script without the trailing wait
sed '/^wait$/d' startmic.sh >> /usr/local/bin/startmic.sh.new
mv /usr/local/bin/startmic.sh.new /usr/local/bin/startmic.sh
chmod +x /usr/local/bin/startmic.sh

# Enable and start the service
echo "Enabling and starting service..."
systemctl daemon-reload
systemctl enable audio-rtsp.service
systemctl start audio-rtsp.service

echo "Installation complete!"
echo "Audio RTSP streaming service is now set up to start automatically on boot."
echo "You can check the status with: sudo systemctl status audio-rtsp"
echo "Or use the helper script: sudo check-audio-rtsp.sh"
echo "The service logs are stored in /var/log/audio-rtsp/"

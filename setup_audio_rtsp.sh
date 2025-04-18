#!/bin/bash
# Enhanced Audio RTSP Streaming Service Setup Script

# Exit on error, enable error tracing
set -e
trap 'echo "Error occurred at line $LINENO. Command: $BASH_COMMAND"' ERR

# Define color codes for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Setting up Audio RTSP Streaming Service...${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Please run as root${NC}"
  exit 1
fi

# Validate original script exists
if [ ! -f "startmic.sh" ]; then
  echo -e "${RED}Error: startmic.sh not found in current directory${NC}"
  exit 1
fi

# Create backup of original script
echo -e "${YELLOW}Creating backup of original script...${NC}"
cp startmic.sh startmic.sh.backup
echo -e "${GREEN}Backup created as startmic.sh.backup${NC}"

# Set up directories with proper permissions
echo -e "${YELLOW}Creating necessary directories...${NC}"
mkdir -p /usr/local/bin
mkdir -p /var/log/audio-rtsp
chmod 755 /var/log/audio-rtsp

# Validate mediamtx.service exists if we're going to depend on it
if ! systemctl list-unit-files | grep -q mediamtx.service; then
  echo -e "${YELLOW}Warning: mediamtx.service not found. This service will be set as 'Wants' rather than 'Requires'.${NC}"
  MEDIA_DEPENDENCY="Wants=mediamtx.service"
else
  MEDIA_DEPENDENCY="Wants=mediamtx.service"
  echo -e "${GREEN}Found mediamtx.service, setting as a soft dependency.${NC}"
fi

# Copy startmic.sh to /usr/local/bin
echo -e "${YELLOW}Installing startmic.sh script...${NC}"
cp startmic.sh /usr/local/bin/startmic.sh.original
chmod +x /usr/local/bin/startmic.sh.original

# Create a proper modified version of startmic.sh instead of using sed directly
echo -e "${YELLOW}Creating service-compatible version of startmic.sh...${NC}"
cat > /usr/local/bin/startmic.sh << 'EOF'
#!/bin/bash
# Modified for use with systemd service

# Redirect output to log file when running as a service
if systemctl is-active --quiet audio-rtsp.service; then
    exec >> /var/log/audio-rtsp/audio-streams.log 2>&1
    echo "----------------------------------------"
    echo "Service started at $(date)"
    echo "----------------------------------------"
fi

EOF

# Append the original script content and add a proper wait mechanism at the end
grep -v "^wait$" /usr/local/bin/startmic.sh.original >> /usr/local/bin/startmic.sh

# Add a function to capture and handle termination signals
cat >> /usr/local/bin/startmic.sh << 'EOF'

# Add a function to capture child processes and wait for them
capture_and_wait_for_children() {
    echo "Starting monitor loop for child processes..."
    
    # Get all child PIDs
    local children=$(pgrep -P $)
    
    if [ -z "$children" ]; then
        echo "No child processes found. Keeping service alive anyway."
    else
        echo "Monitoring child processes: $children"
    fi
    
    # Set up signal handling
    trap 'echo "Received termination signal. Shutting down..."; kill $(jobs -p) 2>/dev/null; exit 0' SIGTERM SIGINT
    
    # Keep the script running - this is crucial for systemd
    while true; do
        # Check if any ffmpeg processes are still running
        if ! pgrep -f "ffmpeg.*rtsp://" > /dev/null; then
            echo "No ffmpeg RTSP processes found. Attempting to restart streams..."
            # Sleep to avoid rapid restart cycles
            sleep 10
            # We'll break here to let systemd restart the entire service
            break
        fi
        
        # Sleep to avoid high CPU usage
        sleep 5
    done
}

# Start the monitor function at the end of the script
capture_and_wait_for_children
EOF

chmod +x /usr/local/bin/startmic.sh

# Create systemd service file
echo -e "${YELLOW}Creating systemd service...${NC}"
cat > /etc/systemd/system/audio-rtsp.service << EOF
[Unit]
Description=Audio RTSP Streaming Service
After=network.target mediamtx.service
$MEDIA_DEPENDENCY
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
KillMode=process
KillSignal=SIGTERM
# Ensure environment is properly set up
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
StandardOutput=append:/var/log/audio-rtsp/service.log
StandardError=append:/var/log/audio-rtsp/service-error.log
# Give the service a chance to clean up when stopping
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF

# Create a log rotation config to prevent logs from filling up disk
echo -e "${YELLOW}Setting up log rotation...${NC}"
cat > /etc/logrotate.d/audio-rtsp << 'EOF'
/var/log/audio-rtsp/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 root root
    # Restart the service to ensure log file handles are properly reopened
    postrotate
        systemctl is-active --quiet audio-rtsp.service && systemctl restart audio-rtsp.service
    endscript
}
EOF

# Create a helper script to check the status
echo -e "${YELLOW}Creating status checking script...${NC}"
cat > /usr/local/bin/check-audio-rtsp.sh << 'EOF'
#!/bin/bash
# Set color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Audio RTSP Service Status:${NC}"
if systemctl is-active --quiet audio-rtsp.service; then
    echo -e "${GREEN}Service is running${NC}"
else
    echo -e "${RED}Service is NOT running${NC}"
fi
systemctl status audio-rtsp.service

echo -e "\n${YELLOW}Running Audio Streams:${NC}"
STREAMS=$(ps aux | grep "[f]fmpeg" | grep -o "rtsp://[^ ]*" | sort)
if [ -z "$STREAMS" ]; then
    echo -e "${RED}No active audio streams found${NC}"
    
    # Provide troubleshooting tips
    echo -e "\n${YELLOW}Troubleshooting Tips:${NC}"
    echo -e "1. Check service logs: ${GREEN}journalctl -u audio-rtsp -n 50${NC}"
    echo -e "2. Check if ffmpeg is installed: ${GREEN}which ffmpeg${NC}"
    echo -e "3. Verify MediaMTX is running: ${GREEN}systemctl status mediamtx${NC}"
    echo -e "4. Manually restart the service: ${GREEN}sudo systemctl restart audio-rtsp${NC}"
else
    echo -e "${GREEN}$STREAMS${NC}"
fi

echo -e "\n${YELLOW}Available Sound Cards:${NC}"
cat /proc/asound/cards

# Get the machine's IP address
IP_ADDR=$(hostname -I | awk '{print $1}')
if [ -n "$IP_ADDR" ]; then
    echo -e "\n${YELLOW}Network Information:${NC}"
    echo -e "To access streams from other devices, use: ${GREEN}$IP_ADDR${NC} instead of localhost"
fi

# Check logs
echo -e "\n${YELLOW}Recent Log Entries:${NC}"
if [ -f "/var/log/audio-rtsp/audio-streams.log" ]; then
    tail -n 10 /var/log/audio-rtsp/audio-streams.log
else
    echo -e "${RED}No log file found${NC}"
fi

echo -e "\n${YELLOW}Disk Space for Logs:${NC}"
du -sh /var/log/audio-rtsp/
EOF
chmod +x /usr/local/bin/check-audio-rtsp.sh

# Enable and start the service
echo -e "${YELLOW}Enabling and starting service...${NC}"
systemctl daemon-reload

# Verify the service file is valid before enabling
if systemctl cat audio-rtsp.service &>/dev/null; then
    echo -e "${GREEN}Service file validated successfully${NC}"
    systemctl enable audio-rtsp.service
    
    # Try to start the service but handle failure gracefully
    if systemctl start audio-rtsp.service; then
        echo -e "${GREEN}Service started successfully${NC}"
    else
        echo -e "${RED}Service failed to start. Check logs with:${NC}"
        echo "journalctl -u audio-rtsp.service"
        echo -e "${YELLOW}You may need to check your startmic.sh script for errors${NC}"
    fi
else
    echo -e "${RED}Error in service file. Installation incomplete.${NC}"
    exit 1
fi

# Create a simple uninstall script for future use
echo -e "${YELLOW}Creating uninstall script...${NC}"
cat > /usr/local/bin/uninstall-audio-rtsp.sh << 'EOF'
#!/bin/bash
# Uninstall Audio RTSP Service
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

echo "Stopping and disabling service..."
systemctl stop audio-rtsp.service
systemctl disable audio-rtsp.service

echo "Removing service files..."
rm -f /etc/systemd/system/audio-rtsp.service
systemctl daemon-reload

echo "Removing scripts..."
rm -f /usr/local/bin/startmic.sh
rm -f /usr/local/bin/startmic.sh.original
rm -f /usr/local/bin/check-audio-rtsp.sh
rm -f /usr/local/bin/uninstall-audio-rtsp.sh

echo "Removing log configuration..."
rm -f /etc/logrotate.d/audio-rtsp

echo "Log files in /var/log/audio-rtsp/ have been preserved."
echo "To remove them completely, run: rm -rf /var/log/audio-rtsp/"

echo "Uninstallation complete!"
EOF
chmod +x /usr/local/bin/uninstall-audio-rtsp.sh

echo -e "${GREEN}Installation complete!${NC}"
echo -e "Audio RTSP streaming service is now set up to start automatically on boot."
echo -e "You can check the status with: ${YELLOW}sudo systemctl status audio-rtsp${NC}"
echo -e "Or use the helper script: ${YELLOW}sudo check-audio-rtsp.sh${NC}"
echo -e "The service logs are stored in ${YELLOW}/var/log/audio-rtsp/${NC}"
echo -e "To uninstall the service, run: ${YELLOW}sudo /usr/local/bin/uninstall-audio-rtsp.sh${NC}"

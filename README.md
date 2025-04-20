# MediaMTX RTSP Audio Setup

This repository contains a set of scripts for setting up a production-ready RTSP audio streaming server using MediaMTX. The scripts automate the installation of MediaMTX and configure it to stream audio from all available USB audio capture devices on a Linux host.

## Overview

This solution provides:
- Automated installation of MediaMTX with custom ports to avoid conflicts
- Automatic detection and streaming of all connected USB audio devices
- Systemd service integration for auto-start on boot
- Robust error handling and automatic stream recovery
- Comprehensive logging with log rotation
- Status monitoring tools and configuration utilities

## Requirements

- Linux operating system (tested on Debian/Ubuntu/Raspberry Pi OS)
- Root/sudo access
- Basic audio devices connected via USB
- Internet connection (for initial download)
- Git or WGET
- If you are on a newly imaged Raspberry Pi, it is suggested to use sudo raspi-config and go to advanced options to expand your filesystem before continuing
- Run sudo apt update && sudo apt upgrade -y before starting

- It is highly recommended to use my other project before this project to map your USB microphones/sound cards to be persistently named
- For details check it out here before continuing https://github.com/tomtom215/usb-audio-mapper

## Quick Start

1. Clone this repository:
   ```bash
   git clone https://github.com/tomtom215/mediamtx-rtsp-setup.git
   cd mediamtx-rtsp-setup
   ```
   or use WGET if git is not installed
   ```bash
   mkdir mediamtx-rtsp-setup && cd mediamtx-rtsp-setup &&
   wget https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/blob/main/install_mediamtx.sh &&
   wget https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/blob/main/setup_audio_rtsp.sh &&
   wget https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/blob/main/startmic.sh
   ```
   Make the scripts executable
   ```bash
   chmod +x install_mediamtx.sh setup_audio_rtsp.sh startmic.sh
   ```

3. Run the scripts in order:
   ```bash
   sudo bash install_mediamtx.sh
   sudo bash setup_audio_rtsp.sh
   ```

4. Check the status of your streams:
   ```bash
   sudo check-audio-rtsp.sh
   ```

## Installation Process

### Step 1: Install MediaMTX

The `install_mediamtx.sh` script:
- Detects your system architecture automatically
- Downloads the appropriate MediaMTX binary
- Configures MediaMTX with custom ports to avoid conflicts:
  - RTSP: 18554 (default: 8554)
  - RTMP: 11935 (default: 1935)
  - HLS: 18888
  - WebRTC: 18889
  - Metrics: 19999
- Creates a systemd service for automatic startup
- Sets up proper logging and permissions

To install MediaMTX:
```bash
sudo bash install_mediamtx.sh
```

### Step 2: Set Up Audio RTSP Streaming

The `setup_audio_rtsp.sh` script:
- Creates a robust systemd service for audio streaming
- Configures automatic discovery of USB audio devices
- Sets up monitoring and automatic restart of failed streams
- Creates helper scripts for management and troubleshooting
- Configures log rotation to prevent disk space issues

To set up the audio streaming service:
```bash
sudo bash setup_audio_rtsp.sh
```

## Usage

### Checking Stream Status

A status checking script is installed that provides detailed information about your streaming setup:

```bash
sudo check-audio-rtsp.sh
```

This will show:
- Service status and uptime
- Active audio streams with their RTSP URLs
- Available sound cards
- System resource usage
- Recent log entries

### Editing Configuration

You can modify the configuration using the included configuration editor:

```bash
sudo configure-audio-rtsp.sh
```

This allows you to change:
- RTSP port
- Restart delay and attempts
- Logging level
- Log rotation settings

### Managing the Service

Standard systemd commands can be used to manage the service:

```bash
# Check service status
sudo systemctl status audio-rtsp

# Start the service
sudo systemctl start audio-rtsp

# Stop the service
sudo systemctl stop audio-rtsp

# Restart the service
sudo systemctl restart audio-rtsp
```

## Streaming URLs and Access

Once running, the audio streams will be available at:

```
rtsp://[SERVER_IP]:18554/[DEVICE_NAME]
```

Where:
- `[SERVER_IP]` is your server's IP address (or `localhost` for local access)
- `[DEVICE_NAME]` is a sanitized version of the sound card name

To find all available stream URLs, run:
```bash
sudo check-audio-rtsp.sh
```

## Troubleshooting

### Common Issues

1. **No streams appear**
   - Check if audio devices are connected using `arecord -l`
   - Ensure MediaMTX is running: `systemctl status mediamtx`
   - Check port availability: `netstat -tuln | grep 18554`

2. **Streams disconnect frequently**
   - Check the logs: `sudo tail -f /var/log/audio-rtsp/audio-streams.log`
   - Increase restart delay in configuration: `sudo configure-audio-rtsp.sh`

3. **Service fails to start**
   - Check errors: `journalctl -u audio-rtsp -n 50`
   - Verify MediaMTX is running: `systemctl status mediamtx`

### Logs

Log files are stored in `/var/log/audio-rtsp/`:

```bash
# View service logs
sudo tail -f /var/log/audio-rtsp/audio-streams.log

# View error logs
sudo tail -f /var/log/audio-rtsp/service-error.log
```

## Uninstallation

If you need to remove the service:

```bash
sudo uninstall-audio-rtsp.sh
```

This script will:
- Stop and disable the service
- Remove all created scripts and configuration
- Optionally remove log files

## Understanding the Scripts

### install_mediamtx.sh
This script installs MediaMTX with custom ports to avoid conflicts with other services. It creates a systemd service, sets up proper permissions, and configures a minimal configuration suitable for audio streaming.

### setup_audio_rtsp.sh
This script sets up the audio streaming service. It creates a robust systemd service, configures automatic detection of USB audio devices, and sets up monitoring and automatic restart of failed streams.

### startmic.sh
This is the core script that:
1. Detects all connected sound cards with capture capabilities
2. Creates RTSP streams for each device
3. Prints a table of available streams with URLs
4. Maintains the streams and handles errors

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Acknowledgments

- [MediaMTX](https://github.com/bluenviron/mediamtx) for the excellent RTSP server
- All contributors and testers of this project that join this project
- [Cberge908](https://github.com/cberge908) for his [original gist that got me started](https://gist.github.com/cberge908/ab7ddc1ac46fd63bb6935cd1f4341112)

## License

This installer script and other scripts in this repo are software are provided under the Apache 2.0 License. That does not carry on to external or related projects involved.

## Disclaimer

This script is not officially affiliated with the MediaMTX project. Always review scripts before running them with sudo privileges.

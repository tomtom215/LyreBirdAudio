# MediaMTX RTSP Audio Streaming Setup

A set of Linux utilities for creating reliable 24/7 RTSP audio streams from USB microphones using MediaMTX and FFmpeg.

## This is currently in development - expect bugs until this banner is removed

## Overview

This repository provides three scripts that work together to create persistent, automatically-managed RTSP audio streams from USB audio devices:

- **usb-audio-mapper.sh** - Creates persistent device names for USB audio devices using udev rules
- **install_mediamtx.sh** - Installs, updates, and manages MediaMTX
- **mediamtx-stream-manager.sh** - Automatically configures and manages RTSP audio streams

The system is designed for unattended operation with automatic recovery from device disconnections and process failures.

## Requirements

- Linux system with systemd
- Root access (sudo)
- USB audio devices
- Required packages:
  - `ffmpeg`
  - `curl` or `wget`
  - `tar`
  - `jq`
  - `arecord` (part of alsa-utils)
  - `lsusb` (part of usbutils)
  - `udevadm` (part of systemd)

## Pre-Installation Cleanup

Ideally, this would be deployed on a fresh operating system (OS) installation and, if possible, on a dedicated device, such as a Raspberry Pi for one to two microphones or an x86 PC for two or more microphones, to avoid port conflicts, service issues, and resource contention. However, if you have existing MediaMTX installations or audio streaming setups, run these cleanup steps.

### 1. Check for Existing MediaMTX Services

```bash
# Check if MediaMTX systemd service is running
if systemctl is-active --quiet mediamtx; then
    echo "MediaMTX service is running. Stopping..."
    sudo systemctl stop mediamtx
    sudo systemctl disable mediamtx
fi

# Check for mediamtx-audio service from this toolset
if systemctl is-active --quiet mediamtx-audio; then
    echo "MediaMTX audio service is running. Stopping..."
    sudo systemctl stop mediamtx-audio
    sudo systemctl disable mediamtx-audio
fi
```

### 2. Stop Existing MediaMTX Processes

```bash
# Kill any running MediaMTX processes
sudo pkill -f mediamtx || true

# Kill any FFmpeg processes streaming to MediaMTX
sudo pkill -f "ffmpeg.*rtsp://localhost:8554" || true
```

### 3. Check for Port Conflicts

```bash
# Check if RTSP port 8554 is in use
sudo lsof -i :8554 && echo "Port 8554 is in use. Please stop the process using it."

# Check if API port 9997 is in use
sudo lsof -i :9997 && echo "Port 9997 is in use. Please stop the process using it."
```

### 4. Release Audio Devices

```bash
# Check what's using audio devices
lsof /dev/snd/* 2>/dev/null || echo "No processes using audio devices"

# If PulseAudio is monopolizing USB devices, temporarily suspend it
systemctl --user stop pulseaudio.socket pulseaudio.service 2>/dev/null || true
```

### 5. Check for Existing Configuration

```bash
# Backup existing MediaMTX configuration if present
if [ -d "/etc/mediamtx" ]; then
    echo "Found existing MediaMTX configuration"
    sudo cp -r /etc/mediamtx /etc/mediamtx.backup.$(date +%Y%m%d-%H%M%S)
fi

# Check for existing udev rules and create a backup
if [ -f "/etc/udev/rules.d/99-usb-soundcards.rules" ]; then
    echo "Found existing USB soundcard rules"
    sudo cp /etc/udev/rules.d/99-usb-soundcards.rules \
         /etc/udev/rules.d/99-usb-soundcards.rules.backup.$(date +%Y%m%d-%H%M%S)
fi
```

## Installation

### 1. Install Dependencies

```bash
# Debian/Ubuntu
sudo apt-get update
sudo apt-get install ffmpeg curl wget tar jq alsa-utils usbutils

# RHEL/CentOS/Fedora
sudo yum install ffmpeg curl wget tar jq alsa-utils usbutils
```

### 2. Clone Repository

```bash
git clone https://github.com/tomtom215/mediamtx-rtsp-setup/
cd mediamtx-rtsp-setup
chmod +x *.sh
```

### 3. Map USB Audio Devices

Run the USB audio mapper for each microphone to create persistent device names:

```bash
sudo ./usb-audio-mapper.sh
```

Follow the interactive prompts to:
1. Select your sound card number
2. Select the corresponding USB device
3. Provide a friendly name (e.g., `conference-mic-1`)

**Important**: Reboot after mapping each device to ensure proper detection.

For non-interactive mapping:
```bash
sudo ./usb-audio-mapper.sh -n -d "Device Name" -v 1234 -p 5678 -f friendly-name
```

### 4. Install MediaMTX

```bash
sudo ./install_mediamtx.sh install
```

This will:
- Download the latest MediaMTX release
- Install the binary to `/usr/local/bin/`
- Create configuration directory at `/etc/mediamtx/`
- Create systemd service (optional)

### 5. Configure and Start Audio Streams

```bash
sudo ./mediamtx-stream-manager.sh start
```

This will:
- Detect all USB audio devices
- Generate MediaMTX configuration
- Start MediaMTX server on port 8554
- Start FFmpeg processes for each audio device
- Display available RTSP stream URLs

## Operation

### Basic Commands

```bash
# Start all streams
sudo ./mediamtx-stream-manager.sh start

# Stop all streams
sudo ./mediamtx-stream-manager.sh stop

# Restart all streams
sudo ./mediamtx-stream-manager.sh restart

# Check status
sudo ./mediamtx-stream-manager.sh status

# Monitor streams in real-time
sudo ./mediamtx-stream-manager.sh monitor

# Show configuration
sudo ./mediamtx-stream-manager.sh config
```

### Accessing Streams

Once running, streams are available at:
```
rtsp://localhost:8554/<device-name>
```

Example playback commands:
```bash
# FFplay
ffplay rtsp://localhost:8554/conference_mic_1

# VLC
vlc rtsp://localhost:8554/conference_mic_1

# MPV
mpv rtsp://localhost:8554/conference_mic_1
```

### Service Management

To run as a system service:

```bash
# Create systemd service
sudo ./mediamtx-stream-manager.sh install

# Enable and start service
sudo systemctl enable mediamtx-audio
sudo systemctl start mediamtx-audio
```

## Configuration

### Audio Device Settings

Edit `/etc/mediamtx/audio-devices.conf` to customize per-device settings:

```bash
# Device-specific overrides
DEVICE_CONFERENCE_MIC_1_SAMPLE_RATE=44100
DEVICE_CONFERENCE_MIC_1_CHANNELS=1
DEVICE_CONFERENCE_MIC_1_CODEC=opus
DEVICE_CONFERENCE_MIC_1_BITRATE=96k
```

Available parameters:
- `SAMPLE_RATE`: Audio sample rate (default: 48000)
- `CHANNELS`: Number of channels (default: 2)
- `FORMAT`: Audio format (default: s16le)
- `CODEC`: Output codec - opus, aac, mp3, pcm (default: opus)
- `BITRATE`: Encoding bitrate (default: 128k)
- `ALSA_BUFFER`: ALSA buffer size in microseconds (default: 100000)
- `ALSA_PERIOD`: ALSA period size in microseconds (default: 20000)
- `THREAD_QUEUE`: FFmpeg thread queue size (default: 8192)

### MediaMTX Configuration

The MediaMTX configuration is automatically generated at `/etc/mediamtx/mediamtx.yml`. Manual edits will be overwritten on restart.

## Troubleshooting

### Check Logs

```bash
# Stream manager log
tail -f /var/log/mediamtx-audio-manager.log

# MediaMTX log
tail -f /var/log/mediamtx.log

# FFmpeg logs for specific stream
tail -f /var/lib/mediamtx-ffmpeg/<stream-name>.log
```

### Common Issues

**No audio devices detected**
```bash
# Check USB devices
lsusb
# Check ALSA devices
arecord -l
# Test USB port detection
sudo ./usb-audio-mapper.sh --test
```

**Stream not working**
```bash
# Debug specific stream
sudo ./mediamtx-stream-manager.sh debug

# Test audio device
arecord -D hw:0,0 -f S16_LE -r 48000 -c 2 -d 5 test.wav
```

**High CPU usage**
- Switch from PCM to compressed codec (opus/aac)
- Reduce sample rate or channels
- Increase ALSA buffer size

**Audio crackling or dropouts**
- Increase `ALSA_BUFFER` in device configuration
- Increase `THREAD_QUEUE` for the device
- Check USB bandwidth and try different USB ports

**Port conflicts**
```bash
# Find what's using MediaMTX ports
sudo lsof -i :8554  # RTSP port
sudo lsof -i :9997  # API port
sudo lsof -i :9998  # Metrics port
```

**PulseAudio interference**
```bash
# Temporarily disable PulseAudio
systemctl --user stop pulseaudio.socket pulseaudio.service

# Re-enable after setup
systemctl --user start pulseaudio.socket pulseaudio.service
```

## Uninstallation

### Remove MediaMTX
```bash
sudo ./install_mediamtx.sh uninstall
```

### Remove Audio Stream Service
```bash
sudo systemctl stop mediamtx-audio
sudo systemctl disable mediamtx-audio
sudo rm /etc/systemd/system/mediamtx-audio.service
```

### Remove USB Device Mappings
```bash
sudo rm /etc/udev/rules.d/99-usb-soundcards.rules
sudo udevadm control --reload-rules
```

### Clean Configuration and Logs
```bash
sudo rm -rf /etc/mediamtx
sudo rm -rf /var/lib/mediamtx-ffmpeg
sudo rm -f /var/log/mediamtx*
```

## Limitations and Future Improvements

### Current Limitations

- No built-in authentication or encryption for RTSP streams
- Audio-only (no video support)
- Limited to USB audio devices
- No web-based management interface
- Manual device mapping required for each microphone
- No built-in stream recording functionality
- Single-user system (no multi-tenancy)
- No automatic codec negotiation with clients

### Potential Future Enhancements - Not Promised or Currently Planned

- RTSP authentication and TLS encryption support
- Web-based monitoring and configuration interface
- Automatic USB device discovery and mapping
- Stream recording with configurable retention
- Support for network audio devices (not just USB)
- REST API for programmatic control
- Prometheus metrics export
- Stream health monitoring and alerting
- Dynamic codec selection based on client capabilities

## Support

Please keep in mind that this is a personal project that was created out of a desire to listen to more birds. I will do my best to support issues, but I cannot make guarantees.

For issues and feature requests, please use the [GitHub issue tracker](https://github.com/tomtom215/mediamtx-rtsp-setup/issues).

## Confirmed deployments

Did this project help you? Did you use it to do something cool? Are you an organization that uses this?

Let me know! I am super curious if this gets put to use in some real-world scenarios beyond my back yard deployment and would love to hear from you!

## License and Contributors

This software is released under the Apache 2.0 License.

### Contributors

- Main project development and maintenance - [Tom F](https://github.com/tomtom215)
- Based on original concept by Cberge908 [GitHub gist](https://gist.github.com/cberge908/ab7ddc1ac46fd63bb6935cd1f4341112)

### Acknowledgments

- [MediaMTX](https://github.com/bluenviron/mediamtx) for the excellent RTSP server
- All testers and users who provided feedback

### Disclaimer

This project is not officially affiliated with the MediaMTX project.

Always review scripts before running them with sudo privileges.

I assume no liability for use, assume no responsibility for support and promise no additional maintainence if life changes happen, major dependency changes, etc.

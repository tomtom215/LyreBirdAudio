# MediaMTX RTSP Audio Streaming Setup

A set of Linux utilities for creating reliable 24/7 RTSP audio streams from USB microphones using MediaMTX and FFmpeg.

## This is currently in development - expect bugs until this banner is removed

## Overview

This repository provides three scripts that work together to create persistent, automatically-managed RTSP audio streams from USB audio devices:

- **usb-audio-mapper.sh** - Creates persistent device names for USB audio devices using udev rules
- **install_mediamtx.sh** - Installs, updates, and manages MediaMTX
- **mediamtx-stream-manager.sh** - Automatically configures and manages RTSP audio streams

The system is designed for unattended operation with automatic recovery from device disconnections and process failures.

## Key Features (v8.0.2)

- **Automatic Friendly Names**: When udev rules are configured via `usb-audio-mapper.sh`, streams automatically use friendly names (e.g., `rtsp://localhost:8554/mic1` instead of `rtsp://localhost:8554/usb_audio_device_12345678`)
- **Smart Stream Path Management**: Automatic collision detection prevents duplicate stream names
- **Persistent Device Mapping**: USB devices maintain consistent names across reboots
- **Auto-Recovery**: Streams automatically restart after device disconnections or failures
- **24/7 Operation**: Designed for continuous, unattended streaming

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

Ideally this is deployed on a fresh OS installation, and if possible on a dedicated device (like a Raspberry Pi) to avoid port conflicts, service issues and resource contention. However if you want to continue on an existing system, run these cleanup steps:

### 1. Check and Stop Existing MediaMTX Services

```bash
# Check if MediaMTX systemd service exists and stop it
sudo systemctl status mediamtx
sudo systemctl stop mediamtx
sudo systemctl disable mediamtx

# Check for mediamtx-audio service from this toolset
sudo systemctl status mediamtx-audio
sudo systemctl stop mediamtx-audio
sudo systemctl disable mediamtx-audio
```

### 2. Stop Existing MediaMTX Processes

```bash
# List any running MediaMTX processes
ps aux | grep mediamtx

# Kill any running MediaMTX processes
sudo pkill -f mediamtx

# List any FFmpeg processes streaming to MediaMTX
ps aux | grep "ffmpeg.*rtsp://localhost:8554"

# Kill any FFmpeg processes streaming to MediaMTX
sudo pkill -f "ffmpeg.*rtsp://localhost:8554"
```

### 3. Check for Port Conflicts

```bash
# Check if RTSP port 8554 is in use
sudo lsof -i :8554

# Check if API port 9997 is in use
sudo lsof -i :9997

# Check if metrics port 9998 is in use
sudo lsof -i :9998

# If any ports are in use, note the process IDs and stop them:
# sudo kill <PID>
```

### 4. Release Audio Devices

```bash
# Check what's using audio devices
lsof /dev/snd/* 2>/dev/null

# If PulseAudio is monopolizing USB devices, temporarily suspend it
systemctl --user stop pulseaudio.socket
systemctl --user stop pulseaudio.service
```

### 5. Backup Existing Configuration

```bash
# Check if MediaMTX configuration exists
ls -la /etc/mediamtx/

# Backup existing MediaMTX configuration if present
sudo cp -r /etc/mediamtx /etc/mediamtx.backup.$(date +%Y%m%d-%H%M%S)

# Check for existing USB soundcard udev rules
ls -la /etc/udev/rules.d/*usb*sound*

# Backup existing udev rules if present
sudo cp /etc/udev/rules.d/99-usb-soundcards.rules \
     /etc/udev/rules.d/99-usb-soundcards.rules.backup.$(date +%Y%m%d-%H%M%S)
```

## Installation

### 1. Install Dependencies

```bash
# Debian/Ubuntu
sudo apt-get update && sudo apt-get install ffmpeg curl wget tar jq alsa-utils usbutils

# RHEL/CentOS/Fedora
sudo yum install ffmpeg curl wget tar jq alsa-utils usbutils
```

### 2. Clone Repository

```bash
git clone https://github.com/tomtom215/mediamtx-rtsp-setup/ && cd mediamtx-rtsp-setup && chmod +x *.sh
```

### 3. Map USB Audio Devices (Recommended for Friendly Names)

Run the USB audio mapper for each microphone to create persistent device names:

```bash
sudo ./usb-audio-mapper.sh
```

Follow the interactive prompts to:
1. Select your sound card number
2. Select the corresponding USB device
3. Provide a friendly name (e.g., `mic1`, `conference-room`, `front-desk`)

**Important**: 
- Keep names short and simple (lowercase letters, numbers, hyphens only)
- Reboot after mapping all devices to ensure proper detection
- If you skip this step, streams will use device-generated names

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
- Use friendly names from udev rules when available
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
rtsp://localhost:8554/<stream-name>
```

Stream names depend on your configuration:
- **With udev rules**: Your chosen friendly names (e.g., `mic1`, `conference-room`)
- **Without udev rules**: Auto-generated names based on device info

Example playback commands:
```bash
# FFplay
ffplay rtsp://localhost:8554/mic1

# VLC
vlc rtsp://localhost:8554/conference-room

# MPV
mpv rtsp://localhost:8554/front-desk

# Test stream with verbose output
ffmpeg -loglevel verbose -i rtsp://localhost:8554/mic1 -t 10 -f null -
```

### Service Management

To run as a system service:

```bash
# Create systemd service
sudo ./mediamtx-stream-manager.sh install

# Enable and start service
sudo systemctl enable mediamtx-audio
sudo systemctl start mediamtx-audio

# Check service status
sudo systemctl status mediamtx-audio

# View service logs
sudo journalctl -u mediamtx-audio -f
```

## Configuration

### Audio Device Settings

Edit `/etc/mediamtx/audio-devices.conf` to customize per-device settings:

```bash
# Device-specific overrides
# Use the FULL device name as shown in status output
DEVICE_USB_AUDIO_DEVICE_SAMPLE_RATE=44100
DEVICE_USB_AUDIO_DEVICE_CHANNELS=1
DEVICE_USB_AUDIO_DEVICE_CODEC=opus
DEVICE_USB_AUDIO_DEVICE_BITRATE=96k

# For devices with friendly names via udev
DEVICE_MIC1_SAMPLE_RATE=48000
DEVICE_MIC1_CHANNELS=2
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

# All FFmpeg logs
tail -f /var/lib/mediamtx-ffmpeg/*.log
```

### Debug Commands

```bash
# Show detailed stream status
sudo ./mediamtx-stream-manager.sh status

# Debug all streams
sudo ./mediamtx-stream-manager.sh debug

# Monitor streams in real-time
sudo ./mediamtx-stream-manager.sh monitor

# Test stream connectivity
sudo ./mediamtx-stream-manager.sh test
```

### Common Issues

**Stream names are long and ugly**
```bash
# This means udev rules aren't configured
# Run the USB audio mapper to assign friendly names
sudo ./usb-audio-mapper.sh

# After mapping all devices, reboot
sudo reboot
```

**No audio devices detected**
```bash
# Check USB devices
lsusb

# Check ALSA devices
arecord -l

# Test USB port detection
sudo ./usb-audio-mapper.sh --test

# Check device permissions
ls -la /dev/snd/
```

**Stream not working**
```bash
# Check if device is accessible
arecord -D hw:0,0 -f S16_LE -r 48000 -c 2 -d 5 test.wav
aplay test.wav

# Check stream-specific log
sudo tail -f /var/lib/mediamtx-ffmpeg/<stream-name>.log

# Test with different codec
# Edit /etc/mediamtx/audio-devices.conf
# Set DEVICE_<NAME>_CODEC=aac
sudo ./mediamtx-stream-manager.sh restart
```

**High CPU usage**
- Switch from PCM to compressed codec (opus/aac)
- Reduce sample rate or channels
- Increase ALSA buffer size
- Check for multiple instances of the same stream

**Audio crackling or dropouts**
```bash
# Increase buffer sizes in /etc/mediamtx/audio-devices.conf
DEVICE_<NAME>_ALSA_BUFFER=200000
DEVICE_<NAME>_THREAD_QUEUE=16384

# Restart streams
sudo ./mediamtx-stream-manager.sh restart
```

**Port conflicts**
```bash
# Find what's using MediaMTX ports
sudo lsof -i :8554  # RTSP port
sudo lsof -i :9997  # API port
sudo lsof -i :9998  # Metrics port

# Kill conflicting process
sudo kill <PID>
```

**PulseAudio interference**
```bash
# Temporarily disable PulseAudio
systemctl --user stop pulseaudio.socket pulseaudio.service

# Test your streams
sudo ./mediamtx-stream-manager.sh restart

# Re-enable PulseAudio after setup
systemctl --user start pulseaudio.socket pulseaudio.service
```

**Duplicate stream names**
- This is automatically handled in v8.0.2+
- The script will add suffixes (_1, _2) to prevent collisions
- Check status to see actual stream names being used

## Uninstallation

### Stop and Remove Services
```bash
# Stop the audio streaming service
sudo systemctl stop mediamtx-audio
sudo systemctl disable mediamtx-audio
sudo rm /etc/systemd/system/mediamtx-audio.service
sudo systemctl daemon-reload
```

### Remove MediaMTX
```bash
sudo ./install_mediamtx.sh uninstall
```

### Remove USB Device Mappings
```bash
# Remove udev rules
sudo rm /etc/udev/rules.d/99-usb-soundcards.rules
sudo udevadm control --reload-rules

# Note: This will cause streams to revert to auto-generated names
```

### Clean Configuration and Logs
```bash
# Remove configuration
sudo rm -rf /etc/mediamtx

# Remove FFmpeg working directory
sudo rm -rf /var/lib/mediamtx-ffmpeg

# Remove logs
sudo rm -f /var/log/mediamtx*
```

## Version History

### v8.0.2
- Added automatic detection of udev-assigned friendly names
- Stream paths now use friendly names when available
- Fixed collision detection during config generation
- Improved status display to show actual running stream names
- Enhanced stream path generation with fallback strategies

### v7.3.0
- Total re-write
- Basic USB audio streaming functionality
- Automatic device detection and configuration
- 48+ Hour test completed on Raspberry Pi 4 with two USB Microphones

## Limitations and Future Improvements

### Current Limitations

- No built-in authentication or encryption for RTSP streams
- Audio-only (no video support)
- Limited to USB audio devices
- No web-based management interface
- Manual device mapping required for friendly names
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
- Stream health monitoring and alerting
- Dynamic codec selection based on client capabilities
- Multi-user support with access control

## Support

For issues and feature requests, please use the [GitHub issue tracker](https://github.com/tomtom215/mediamtx-rtsp-setup/issues).

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

This is a hobby project for me to listen to birds, I plan to make it work as best as possible for my needs. Support and updates are not guaranteed.

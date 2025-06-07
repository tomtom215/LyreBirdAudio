# MediaMTX RTSP Audio Streaming Setup

A set of Linux utilities for creating reliable 24/7 RTSP audio streams from USB microphones using MediaMTX and FFmpeg.

## This is currently in development - expect bugs until this banner is removed

## Overview

This repository provides three scripts that work together to create persistent, automatically-managed RTSP audio streams from USB audio devices:

- **usb-audio-mapper.sh** - Creates persistent device names for USB audio devices using udev rules
- **install_mediamtx.sh** - Installs, updates, and manages MediaMTX
- **mediamtx-stream-manager.sh** - Automatically configures and manages RTSP audio streams

The system is designed for unattended operation with automatic recovery from device disconnections and process failures.

## What's New in mediamtx-stream-manager.sh v8.0.4

- **Human-Readable Stream Names**: Streams now use friendly names (e.g., `conference-mic-1`) when devices are mapped with usb-audio-mapper.sh
- **Improved Compatibility**: Device testing disabled by default for better compatibility
- **Better Fallback Support**: Enhanced format detection and automatic fallback to plughw
- **Cleaner Operation**: Reduced unnecessary warnings during startup
- **Environmental Control**: New environment variables for fine-tuning behavior

## Requirements

- Linux system with systemd
- Root access (sudo)
- USB audio devices
- Required packages: `ffmpeg`, `curl` or `wget`, `tar`, `jq`, `arecord` (alsa-utils), `lsusb` (usbutils), `udevadm` (systemd)

## Pre-Installation Cleanup

If you are on a fresh OS installation, you can skip this part. If you have existing MediaMTX installations or audio streaming setups, run these cleanup commands:

```bash
# Stop MediaMTX systemd service if running
sudo systemctl stop mediamtx 2>/dev/null || true
sudo systemctl disable mediamtx 2>/dev/null || true

# Stop mediamtx-audio service if running
sudo systemctl stop mediamtx-audio 2>/dev/null || true
sudo systemctl disable mediamtx-audio 2>/dev/null || true

# Kill any running MediaMTX processes
sudo pkill -f mediamtx || true

# Kill any FFmpeg processes streaming to MediaMTX
sudo pkill -f "ffmpeg.*rtsp://localhost:8554" || true

# Check if ports are in use
sudo lsof -i :8554 || echo "Port 8554 is free"
sudo lsof -i :9997 || echo "Port 9997 is free"

# Stop PulseAudio temporarily (if it's monopolizing USB devices)
systemctl --user stop pulseaudio.socket pulseaudio.service 2>/dev/null || true

# Backup existing configurations
[ -d "/etc/mediamtx" ] && sudo cp -r /etc/mediamtx "/etc/mediamtx.backup.$(date +%Y%m%d-%H%M%S)"
[ -f "/etc/udev/rules.d/99-usb-soundcards.rules" ] && sudo cp /etc/udev/rules.d/99-usb-soundcards.rules "/etc/udev/rules.d/99-usb-soundcards.rules.backup.$(date +%Y%m%d-%H%M%S)"
```

## Installation

### 1. Install Dependencies

```bash
# Debian/Ubuntu
sudo apt-get update && sudo apt-get install -y ffmpeg curl wget tar jq alsa-utils usbutils

# RHEL/CentOS/Fedora
sudo yum install -y ffmpeg curl wget tar jq alsa-utils usbutils
```

### 2. Clone Repository

```bash
git clone https://github.com/tomtom215/mediamtx-rtsp-setup/ && cd mediamtx-rtsp-setup && chmod +x *.sh
```

### 3. Map USB Audio Devices (Recommended for Friendly Names)

For each USB microphone, run the mapper to create persistent, friendly names:

```bash
sudo ./usb-audio-mapper.sh
```

Follow the interactive prompts to:
1. Select your sound card number
2. Select the corresponding USB device
3. Provide a friendly name (e.g., `conference-mic-1`)

**Important**: Reboot after mapping each device:

```bash
sudo reboot
```

For non-interactive mapping (useful for automation):

```bash
# Example: Map a MOVO X1 MINI microphone
sudo ./usb-audio-mapper.sh -n -d "MOVO X1 MINI" -v 2e88 -p 4610 -f conference-mic-1
sudo reboot
```

### 4. Install MediaMTX

```bash
sudo ./install_mediamtx.sh install
```

This command will:
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

# Show test commands
sudo ./mediamtx-stream-manager.sh test

# Debug stream issues
sudo ./mediamtx-stream-manager.sh debug
```

### Accessing Streams

Once running, streams are available at:

**With friendly names (devices mapped with usb-audio-mapper.sh):**
```
rtsp://localhost:8554/conference-mic-1
rtsp://localhost:8554/meeting-room-mic
rtsp://localhost:8554/podcast-mic
```

**Without friendly names (automatic fallback):**
```
rtsp://localhost:8554/usb_0d8c_0134_00
rtsp://localhost:8554/usb_audio_device
```

Example playback commands:

```bash
# FFplay
ffplay rtsp://localhost:8554/conference-mic-1

# VLC
vlc rtsp://localhost:8554/conference-mic-1

# MPV
mpv rtsp://localhost:8554/conference-mic-1

# Test with FFmpeg
ffmpeg -i rtsp://localhost:8554/conference-mic-1 -t 10 -f null -
```

### Service Management

To run as a system service:

```bash
# Create systemd service
sudo ./mediamtx-stream-manager.sh install

# Enable service to start at boot
sudo systemctl enable mediamtx-audio

# Start service
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
# Device-specific overrides (use UPPERCASE variable names)
# Get the variable prefix from 'mediamtx-stream-manager.sh config'

# Example for a device with friendly name "conference-mic-1"
DEVICE_CONFERENCE_MIC_1_SAMPLE_RATE=44100
DEVICE_CONFERENCE_MIC_1_CHANNELS=1
DEVICE_CONFERENCE_MIC_1_CODEC=opus
DEVICE_CONFERENCE_MIC_1_BITRATE=96k

# Example for a device without friendly name
DEVICE_USB_0D8C_0134_00_SAMPLE_RATE=48000
DEVICE_USB_0D8C_0134_00_ALSA_BUFFER=200000
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

### Environment Variables

Control script behavior with environment variables:

```bash
# Disable device testing (recommended for production)
export DEVICE_TEST_ENABLED=false  # Default: false

# Adjust stream startup delay
export STREAM_STARTUP_DELAY=5     # Default: 10 seconds

# Enable parallel stream starts (faster with many devices)
export PARALLEL_STREAM_START=true # Default: false

# Set device test timeout
export DEVICE_TEST_TIMEOUT=5      # Default: 3 seconds

# Enable debug logging
export DEBUG=true                 # Default: false
```

For systemd service, add environment variables:

```bash
sudo systemctl edit mediamtx-audio

# Add in the editor:
[Service]
Environment="DEVICE_TEST_ENABLED=false"
Environment="STREAM_STARTUP_DELAY=5"
Environment="PARALLEL_STREAM_START=true"
```

### MediaMTX Configuration

The MediaMTX configuration is automatically generated at `/etc/mediamtx/mediamtx.yml`. Manual edits will be overwritten on restart.

## Troubleshooting

### Check Logs

```bash
# Stream manager log
sudo tail -f /var/log/mediamtx-audio-manager.log

# MediaMTX log
sudo tail -f /var/log/mediamtx.log

# FFmpeg logs for specific stream
sudo tail -f /var/lib/mediamtx-ffmpeg/<stream-name>.log

# All logs at once
sudo tail -f /var/log/mediamtx*.log /var/lib/mediamtx-ffmpeg/*.log
```

### Common Issues and Solutions

**Ugly stream names like `usb_0d8c_0134_00`**
```bash
# Map your devices to friendly names
sudo ./usb-audio-mapper.sh
# Follow prompts and reboot
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
```

**Stream not working**
```bash
# Debug all streams
sudo ./mediamtx-stream-manager.sh debug

# Test specific audio device (replace N with card number)
arecord -D hw:N,0 -f S16_LE -r 48000 -c 2 -d 5 test.wav
aplay test.wav
```

**High CPU usage**
```bash
# Edit device configuration
sudo nano /etc/mediamtx/audio-devices.conf

# Add these lines (replace DEVICE_NAME with your device's variable prefix)
DEVICE_YOUR_DEVICE_CODEC=opus
DEVICE_YOUR_DEVICE_BITRATE=64k
```

**Audio crackling or dropouts**
```bash
# Edit device configuration
sudo nano /etc/mediamtx/audio-devices.conf

# Increase buffer size (replace DEVICE_NAME appropriately)
DEVICE_YOUR_DEVICE_ALSA_BUFFER=200000
DEVICE_YOUR_DEVICE_THREAD_QUEUE=16384
```

**Port conflicts**
```bash
# Find what's using MediaMTX ports
sudo lsof -i :8554  # RTSP port
sudo lsof -i :9997  # API port
sudo lsof -i :9998  # Metrics port

# Kill the process using the port
sudo kill -9 <PID>
```

**PulseAudio interference**
```bash
# Temporarily disable PulseAudio
systemctl --user stop pulseaudio.socket pulseaudio.service

# Re-enable after setup
systemctl --user start pulseaudio.socket pulseaudio.service
```

**Device format warnings during startup**
```bash
# These are harmless if streams work - disable testing:
export DEVICE_TEST_ENABLED=false
sudo ./mediamtx-stream-manager.sh restart
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
sudo systemctl daemon-reload
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
- Manual device mapping required for friendly names
- No built-in stream recording functionality
- Single-user system (no multi-tenancy)
- No automatic codec negotiation with clients

### Possible Enhancements (Not Planned)

- RTSP authentication and TLS encryption support
- Web-based monitoring and configuration interface
- Automatic USB device discovery and mapping
- Stream recording with configurable retention
- Support for network audio devices (not just USB)
- REST API for programmatic control
- Prometheus metrics export
- Stream health monitoring and alerting
- Dynamic codec selection based on client capabilities

## Tips for Production Use

1. **Always use friendly names** - Run usb-audio-mapper.sh for each device
2. **Disable device testing** - Set `DEVICE_TEST_ENABLED=false`
3. **Use compressed codecs** - Opus or AAC instead of PCM
4. **Monitor logs regularly** - Set up log rotation for long-term operation
5. **Use systemd service** - For automatic startup and recovery
6. **Test failover** - Verify streams recover after unplugging/replugging devices

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

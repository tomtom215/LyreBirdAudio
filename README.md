# LyreBirdAudio - RTSP Audio Streaming Suite

A robust Linux solution for creating reliable 24/7 RTSP audio streams from USB microphones using MediaMTX and FFmpeg, with automatic recovery and service management.

## Overview

LyreBirdAudio provides three integrated scripts that work together to create persistent, automatically-managed RTSP audio streams from USB audio devices:

- **usb-audio-mapper.sh** - Creates persistent device names for USB audio devices using udev rules
- **install_mediamtx.sh** - Installs, updates, and manages MediaMTX with intelligent service detection
- **mediamtx-stream-manager.sh** - Automatically configures and manages RTSP audio streams with enhanced restart handling

The system is designed for unattended operation with automatic recovery from device disconnections, process failures, and system updates.

## Problem This Solves

### Service Restart Issues During System Updates
When system services restart (during updates, reboots, or manual restarts), USB audio streaming setups often face:
- Stale processes that prevent clean restarts
- USB devices not being ready when services start
- PID file conflicts from previous runs
- FFmpeg processes not terminating properly
- Race conditions between cleanup and restart operations
- Loss of stream configuration during ungraceful shutdowns

### LyreBirdAudio v1.0.0 addresses these issues with:
- **Enhanced cleanup procedures** that properly terminate all child processes
- **USB stabilization detection** that waits for devices to be ready
- **Restart scenario detection** that applies special handling during service restarts
- **Atomic cleanup operations** using marker files to prevent race conditions
- **ALSA state reset** to recover from device conflicts
- **Graceful process termination** with proper signal cascading

**For users upgrading from v8.0.4 or earlier**: These enhancements were introduced in v8.1.0 and are now part of LyreBirdAudio v1.0.0. See the [Upgrading from Previous Versions](#upgrading-from-previous-versions) section for detailed upgrade instructions.

## Version History and Migration

### LyreBirdAudio v1.0.0 (Current)
This is a rebrand and version reset of the former mediamtx-rtsp-setup project. All functionality from v8.1.0 is preserved.

### Previous Version Mapping
If you're upgrading from mediamtx-rtsp-setup:
- **mediamtx-stream-manager.sh v8.1.0** → LyreBirdAudio v1.0.0 (all features included)
- **mediamtx-stream-manager.sh v8.0.4** → Upgrade to LyreBirdAudio v1.0.0 recommended
- **install_mediamtx.sh v5.2.0** → Now part of LyreBirdAudio v1.0.0
- **usb-audio-mapper.sh v2.0** → Now part of LyreBirdAudio v1.0.0

### Important Notes for v8.0.4 Users
Version 8.0.4 users upgrading to LyreBirdAudio v1.0.0 will gain:
- Enhanced service restart handling during system updates
- Automatic cleanup of stale processes
- USB stabilization detection
- Restart scenario detection
- ALSA state reset on cleanup
- Better handling of forced service restarts
- Cleanup markers to prevent race conditions

**Note**: While there are no breaking configuration changes, the improved restart handling includes additional delays for stability. If your automation scripts depend on precise timing, you may need to adjust for the new USB_STABILIZATION_DELAY (10 seconds) and RESTART_STABILIZATION_DELAY (15 seconds) when services restart.

## Features

### Core Capabilities
- **Automatic USB Audio Detection**: Discovers and configures all connected USB audio devices
- **Persistent Device Naming**: Maps USB devices to friendly, consistent names across reboots
- **24/7 Reliability**: Auto-restart on failures with intelligent backoff strategies
- **Service Management**: Full systemd integration with proper dependency handling
- **Multiple Codec Support**: Opus (default), AAC, MP3, and PCM
- **Real-time Monitoring**: Live stream status and health monitoring
- **Graceful Recovery**: Handles USB disconnections and reconnections seamlessly

### v1.0.0 - Production Release

LyreBirdAudio v1.0.0 is a rebrand of mediamtx-rtsp-setup with all features from v8.1.0 included.

**Key Features (includes all v8.1.0 enhancements):**
- **Enhanced Service Restart Handling**: Automatic detection and special handling of restart scenarios
- **Comprehensive Process Cleanup**: Ensures all FFmpeg wrappers and child processes terminate properly
- **USB Stabilization Detection**: Waits for USB audio subsystem to stabilize before starting streams
- **Restart Markers**: Prevents race conditions during rapid stop/start cycles
- **ALSA State Management**: Resets ALSA state during cleanup to resolve device conflicts
- **Cleanup Markers**: Atomic operations to prevent interference during cleanup
- **Improved Signal Handling**: Proper cascading of termination signals to all child processes
- **Extended Timeouts**: Configurable delays for USB stabilization and restart scenarios
- **Human-readable stream names**: When devices are mapped with usb-audio-mapper.sh
- **Improved compatibility**: Device testing disabled by default
- **Better fallback support**: Automatic format detection
- **Environmental control**: For fine-tuning behavior

**Important Upgrade Note**: If upgrading from v8.0.4 or earlier, you MUST configure the new environment variables for stability. The enhanced restart handling requires USB_STABILIZATION_DELAY=10 and RESTART_STABILIZATION_DELAY=15. See [Upgrading from Previous Versions](#upgrading-from-previous-versions) for detailed instructions.

## Requirements

- Linux system with systemd
- Root access (sudo)
- USB audio devices
- Required packages: `ffmpeg`, `curl` or `wget`, `tar`, `jq`, `arecord` (alsa-utils), `lsusb` (usbutils), `udevadm` (systemd)

## Hardware Recommendations and Limitations

### Raspberry Pi Limitations

Due to USB bandwidth and power constraints, Raspberry Pi devices have the following practical limits for simultaneous USB microphone streaming:

- **Raspberry Pi Zero W**: Maximum 1 USB microphone
  - Limited USB bandwidth and processing power
  - Suitable for single-stream applications only
  
- **Raspberry Pi 3B/4/5**: Maximum 2 USB microphones
  - USB bandwidth becomes saturated with more than 2 audio streams
  - Power delivery limitations may cause device dropouts with multiple microphones
  - CPU may struggle with more than 2 simultaneous encoding streams

### Recommended Hardware for Multiple Microphones

For deployments requiring more than 2 simultaneous microphone streams:

- **Linux Mini PCs** (Recommended for 3+ microphones)
  - Intel N100 processor-based systems work excellently
  - Dedicated USB controllers provide better bandwidth
  - More stable power delivery for multiple devices
  - Can reliably handle 4-8 simultaneous streams depending on model

### USB Hub Considerations

If you must use USB hubs for connecting multiple microphones:

1. **Always use powered USB hubs**
   - Bus-powered hubs cannot provide sufficient power for multiple audio devices
   - Inadequate power causes random disconnections and audio dropouts

2. **Choose high-quality hubs**
   - Cheap hubs introduce electrical interference and noise
   - Look for hubs with individual port power switches
   - Industrial-grade hubs recommended for production deployments

3. **Avoid daisy-chaining**
   - Connect hubs directly to the host computer
   - Multiple hub levels increase latency and reduce reliability

4. **Consider USB bandwidth**
   - Even with powered hubs, you're still limited by the host's USB controller bandwidth
   - Spreading devices across multiple USB controllers (if available) improves performance

### Production Deployment Guidelines

- **1-2 microphones**: Raspberry Pi 4 or 5 (with good cooling)
- **3-4 microphones**: Intel N100 mini PC or equivalent
- **5-8 microphones**: Higher-spec mini PC with multiple USB controllers
- **9+ microphones**: Consider multiple streaming servers or professional audio interfaces

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
git clone https://github.com/tomtom215/LyreBirdAudio.git && cd LyreBirdAudio && chmod +x *.sh
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
- Detect existing stream management setups

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

## Upgrading from Previous Versions

### For Users Upgrading from mediamtx-rtsp-setup (v8.0.4, v8.1.0, or earlier)

**IMPORTANT**: LyreBirdAudio v1.0.0 is fully backward compatible. Your existing configurations and stream names will be preserved.

#### 1. Stop Current Services
```bash
# If using systemd service
sudo systemctl stop mediamtx-audio

# If using stream manager directly
sudo ./mediamtx-stream-manager.sh stop

# Wait for complete shutdown
sleep 10
```

#### 2. Backup Current Configuration
```bash
# Create backup directory
sudo mkdir -p /etc/mediamtx/backup-$(date +%Y%m%d)

# Backup configurations
sudo cp /etc/mediamtx/*.conf /etc/mediamtx/backup-$(date +%Y%m%d)/
sudo cp /etc/mediamtx/*.yml /etc/mediamtx/backup-$(date +%Y%m%d)/

# Backup any custom scripts
[ -f ./mediamtx-stream-manager.sh ] && cp ./mediamtx-stream-manager.sh ./mediamtx-stream-manager.sh.backup
```

#### 3. Update Scripts
```bash
# Clone or pull latest LyreBirdAudio version
git clone https://github.com/tomtom215/LyreBirdAudio.git
cd LyreBirdAudio

# Or if updating existing clone
git pull origin main

# Make scripts executable
chmod +x *.sh
```

#### 4. Update MediaMTX Binary (Optional but Recommended)
```bash
# The installer now handles running instances intelligently
sudo ./install_mediamtx.sh update
```

#### 5. Update Systemd Service (If Using Systemd)
```bash
# Recreate service with new parameters
sudo ./mediamtx-stream-manager.sh install

# Reload systemd
sudo systemctl daemon-reload

# The new service includes enhanced restart parameters
```

#### 6. Configure Environment Variables (Critical for Stability)
```bash
# Edit service for optimal production settings
sudo systemctl edit mediamtx-audio

# Add these recommended production values:
[Service]
Environment="USB_STABILIZATION_DELAY=10"
Environment="RESTART_STABILIZATION_DELAY=15"
Environment="DEVICE_TEST_ENABLED=false"
Environment="STREAM_STARTUP_DELAY=10"
Environment="PARALLEL_STREAM_START=false"

# Note: These are the optimal values used by the installer
# when creating a new systemd service. If you forget to set
# these, the script will use less optimal defaults.
```

#### 7. Start Services
```bash
# If using systemd
sudo systemctl start mediamtx-audio
sudo systemctl status mediamtx-audio

# If using stream manager directly
sudo ./mediamtx-stream-manager.sh start
```

#### 8. Verify Streams and Configuration
```bash
# Check all streams are running
sudo ./mediamtx-stream-manager.sh status

# Verify environment variables are set correctly
sudo systemctl show mediamtx-audio | grep Environment

# Expected output should include:
# Environment=USB_STABILIZATION_DELAY=10
# Environment=RESTART_STABILIZATION_DELAY=15
# Environment=DEVICE_TEST_ENABLED=false

# If these values are missing or different, update them:
sudo systemctl edit mediamtx-audio
# Add the Environment lines shown above

# Monitor for stability
sudo journalctl -u mediamtx-audio -f
```

**Critical**: Ensure USB_STABILIZATION_DELAY is 10 (not 5) and RESTART_STABILIZATION_DELAY is 15 (not 10) for optimal production performance. These higher values prevent race conditions during service restarts.

### Rollback Procedure (If Needed)

If you encounter issues after upgrading:

```bash
# Stop services
sudo systemctl stop mediamtx-audio

# Restore backup script
[ -f ./mediamtx-stream-manager.sh.backup ] && mv ./mediamtx-stream-manager.sh.backup ./mediamtx-stream-manager.sh

# Restore configurations
sudo cp /etc/mediamtx/backup-$(date +%Y%m%d)/* /etc/mediamtx/

# Restart with old version
sudo systemctl start mediamtx-audio
```

### What's Preserved During Upgrade

- ✅ All device configurations in `/etc/mediamtx/audio-devices.conf`
- ✅ Your custom device names and mappings
- ✅ Udev rules for USB devices
- ✅ Stream names and paths
- ✅ All your audio device settings (sample rates, codecs, etc.)
- ✅ Systemd service configurations (with updates for new features)

### What's New After Upgrade

- Version numbers unified to v1.0.0
- Enhanced restart handling (if environment variables are configured)
- Better cleanup procedures
- Improved USB stabilization detection
- Project rebranded as LyreBirdAudio

## Pre-Installation Cleanup

If you need to completely remove existing installations and start fresh, run these cleanup commands:

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

Control script behavior with environment variables. The values shown below are the **optimal production settings** that are automatically configured when using systemd service:

```bash
# Core Settings (Optimal Production Values)
export DEVICE_TEST_ENABLED=false          # Disable device testing (critical for production)
export STREAM_STARTUP_DELAY=10            # Seconds to wait after starting each stream
export PARALLEL_STREAM_START=false        # Sequential starts are more reliable
export DEVICE_TEST_TIMEOUT=3              # Device test timeout if testing enabled
export DEBUG=false                         # Disable debug logging in production

# v1.0.0 Restart Handling Settings (Optimal Production Values)
export USB_STABILIZATION_DELAY=10         # Wait for USB to stabilize (systemd default: 10)
export RESTART_STABILIZATION_DELAY=15     # Extra delay on restart (systemd default: 15)
export CLEANUP_MARKER=/var/run/mediamtx-audio.cleanup  # Cleanup coordination file
export RESTART_MARKER=/var/run/mediamtx-audio.restart  # Restart detection file

# IMPORTANT: The systemd service automatically uses these optimal values.
# Manual runs use lower defaults (5 and 10 respectively) unless you export these.
```

For systemd service, these are automatically set, but you can override them:

```bash
sudo systemctl edit mediamtx-audio

# Add in the editor to override defaults:
[Service]
Environment="DEVICE_TEST_ENABLED=false"
Environment="USB_STABILIZATION_DELAY=10"
Environment="RESTART_STABILIZATION_DELAY=15"
Environment="STREAM_STARTUP_DELAY=10"
Environment="PARALLEL_STREAM_START=false"
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

#### Service Restart Problems (Resolved in v1.0.0)
Previous versions had issues with:
- Stale processes preventing clean restarts
- USB devices not ready after restart
- PID file conflicts

LyreBirdAudio v1.0.0 automatically handles these scenarios with enhanced cleanup and USB stabilization detection.

#### Ugly Stream Names
```bash
# Map your devices to friendly names
sudo ./usb-audio-mapper.sh
# Follow prompts and reboot
sudo reboot
```

#### No Audio Devices Detected
```bash
# Check USB devices
lsusb

# Check ALSA devices
arecord -l

# Test USB port detection
sudo ./usb-audio-mapper.sh --test

# If devices missing after reboot, increase stabilization delay
export USB_STABILIZATION_DELAY=20
sudo ./mediamtx-stream-manager.sh restart
```

#### Stream Not Working
```bash
# Debug all streams
sudo ./mediamtx-stream-manager.sh debug

# Test specific audio device (replace N with card number)
arecord -D hw:N,0 -f S16_LE -r 48000 -c 2 -d 5 test.wav
aplay test.wav
```

#### High CPU Usage
```bash
# Edit device configuration
sudo nano /etc/mediamtx/audio-devices.conf

# Add these lines (replace DEVICE_NAME with your device's variable prefix)
DEVICE_YOUR_DEVICE_CODEC=opus
DEVICE_YOUR_DEVICE_BITRATE=64k
```

#### Audio Crackling or Dropouts
```bash
# Edit device configuration
sudo nano /etc/mediamtx/audio-devices.conf

# Increase buffer size (replace DEVICE_NAME appropriately)
DEVICE_YOUR_DEVICE_ALSA_BUFFER=200000
DEVICE_YOUR_DEVICE_THREAD_QUEUE=16384
```

#### Port Conflicts
```bash
# Find what's using MediaMTX ports
sudo lsof -i :8554  # RTSP port
sudo lsof -i :9997  # API port
sudo lsof -i :9998  # Metrics port

# Kill the process using the port
sudo kill -9 <PID>
```

#### PulseAudio Interference
```bash
# Temporarily disable PulseAudio
systemctl --user stop pulseaudio.socket pulseaudio.service

# Re-enable after setup
systemctl --user start pulseaudio.socket pulseaudio.service
```

#### Device Format Warnings During Startup
```bash
# These are harmless if streams work - disable testing:
export DEVICE_TEST_ENABLED=false
sudo ./mediamtx-stream-manager.sh restart
```

#### Manual Cleanup After Failed Service Stop
```bash
# Force cleanup if automatic cleanup fails
sudo pkill -9 mediamtx ffmpeg
sudo rm -f /var/run/mediamtx*
sudo rm -f /var/lib/mediamtx-ffmpeg/*.pid

# Clean up v1.0.0 marker files if present
sudo rm -f /var/run/mediamtx-audio.cleanup
sudo rm -f /var/run/mediamtx-audio.restart

# Then start fresh
sudo ./mediamtx-stream-manager.sh start
```

**Note**: LyreBirdAudio v1.0.0 uses marker files (.cleanup and .restart) to coordinate cleanup operations and prevent race conditions. These are automatically managed but can be manually removed if needed during troubleshooting.

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

## Tips for Production Use

1. **Always use friendly names** - Run usb-audio-mapper.sh for each device
2. **Disable device testing** - Set `DEVICE_TEST_ENABLED=false` (critical for stability)
3. **Use optimal delay settings** - Set `USB_STABILIZATION_DELAY=10` and `RESTART_STABILIZATION_DELAY=15`
4. **Use compressed codecs** - Opus or AAC instead of PCM for network efficiency
5. **Sequential stream startup** - Keep `PARALLEL_STREAM_START=false` for reliability
6. **Monitor logs regularly** - Set up log rotation for long-term operation
7. **Use systemd service** - For automatic startup and recovery with optimal settings
8. **Test failover** - Verify streams recover after unplugging/replugging devices
9. **Configure appropriate delays** - The systemd defaults (10/15 seconds) work well for most hardware
10. **Regular updates** - Keep MediaMTX and scripts updated for bug fixes and improvements

### Critical for Upgrading Users

**If you're upgrading from v8.0.4 or earlier**, the most important change is setting the correct environment variables. The old defaults were:
- USB_STABILIZATION_DELAY=5 (old default)
- RESTART_STABILIZATION_DELAY=10 (old default)

**You MUST update these to the new optimal values**:
- USB_STABILIZATION_DELAY=10 (new optimal)
- RESTART_STABILIZATION_DELAY=15 (new optimal)

These longer delays are critical for preventing race conditions during service restarts, especially during system updates. Users who don't update these values may experience:
- Streams failing to start after reboot
- USB devices not being detected
- Service restart failures during system updates

### Optimal Production Configuration

When running in production, ensure these settings are configured:

```bash
# For systemd service (automatically set by v1.0.0 installer)
USB_STABILIZATION_DELAY=10        # Not 5 (the script default)
RESTART_STABILIZATION_DELAY=15    # Not 10 (the script default)
DEVICE_TEST_ENABLED=false         # Critical for stability
STREAM_STARTUP_DELAY=10           # Allow time for device initialization
PARALLEL_STREAM_START=false       # Sequential is more reliable
```

These values are automatically configured when installing the systemd service with LyreBirdAudio v1.0.0, but if you're running the script manually or upgrading from an older version, make sure to export these values or add them to your systemd service configuration.

## Known Limitations

### Current Limitations

- No built-in authentication or encryption for RTSP streams
- Audio-only (no video support)
- Limited to USB audio devices
- No web-based management interface
- Manual device mapping required for friendly names
- No built-in stream recording functionality
- Single-user system (no multi-tenancy)
- No automatic codec negotiation with clients

### Possible Future Enhancements

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

For issues and feature requests, please use the [GitHub issue tracker](https://github.com/tomtom215/LyreBirdAudio/issues).

## License and Contributors

This software is released under the Apache 2.0 License.

### Project Name
LyreBirdAudio - Named after the Lyrebird, known for its extraordinary ability to accurately reproduce sounds.

### Contributors

- Main project development and maintenance - [Tom F](https://github.com/tomtom215)
- Based on original concept by Cberge908 [GitHub gist](https://gist.github.com/cberge908/ab7ddc1ac46fd63bb6935cd1f4341112)

### Acknowledgments

- [MediaMTX](https://github.com/bluenviron/mediamtx) for the excellent RTSP server
- All testers and users who provided feedback

### Disclaimer

This project is not officially affiliated with the MediaMTX project.

Always review scripts before running them with sudo privileges.
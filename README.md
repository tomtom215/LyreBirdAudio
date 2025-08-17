# LyreBirdAudio - RTSP Audio Streaming Suite

A robust Linux solution for creating lightweight and reliable 24/7 RTSP audio streams from USB microphones using MediaMTX and FFmpeg, with automatic recovery and service management.

#### Original problem statement - "I have a linux mini PC and one or more USB microphones that I want to use to setup streams to listen to birds." 

This turns out to be way more complex than originally anticipated and a lightweight solution to run all day unattended was not easily found.

Named after the Australian lyrebird, a remarkable bird that can perfectly mimic and reproduce any sound it hears - just as LyreBirdAudio faithfully captures and streams audio from any USB microphone

## What Problem Does This Solve?

USB audio streaming on Linux faces numerous challenges:
- **Device Naming Chaos**: USB devices get different names after each reboot (card0, card1, etc.)
- **Stream Reliability**: Manual FFmpeg processes die and don't restart automatically
- **Complex Configuration**: Setting up MediaMTX with multiple audio devices requires deep technical knowledge
- **No Recovery**: When USB devices disconnect/reconnect, streams don't automatically resume
- **Service Management**: No easy way to manage multiple audio streams as system services
- **Scalability Issues**: Managing multiple USB microphones becomes exponentially complex

**LyreBirdAudio solves these problems by providing:**
- Persistent device naming through udev rules
- Automatic stream recovery with intelligent retry logic
- Zero-configuration setup for MediaMTX audio streaming
- Full systemd integration for 24/7 operation
- Friendly device names instead of cryptic USB identifiers
- Centralized management of multiple audio streams

## Key Features

### Core Capabilities
- **Automatic USB Audio Detection**: Discovers and configures all connected USB audio devices
- **Persistent Device Naming**: Maps USB devices to friendly, consistent names across reboots
- **24/7 Reliability**: Auto-restart on failures with intelligent backoff strategies
- **Service Management**: Full systemd integration with proper dependency handling
- **Multiple Codec Support**: Opus (default), AAC, MP3, and PCM
- **Real-time Monitoring**: Live stream status and health monitoring
- **Graceful Recovery**: Handles USB disconnections and reconnections seamlessly

### Production Features (v1.0.0)
- **Enhanced Service Restart Handling**: Automatic detection and special handling of restart scenarios
- **Comprehensive Process Cleanup**: Ensures all FFmpeg wrappers and child processes terminate properly
- **USB Stabilization Detection**: Waits for USB audio subsystem to stabilize before starting streams
- **ALSA State Management**: Resets ALSA state during cleanup to resolve device conflicts
- **Human-readable Stream Names**: When devices are mapped with usb-audio-mapper.sh
- **Environmental Control**: Fine-tuning behavior through environment variables

## Hardware Requirements and Recommendations

### System Requirements
- Linux system with systemd
- Root access (sudo)
- USB audio devices
- Required packages: `ffmpeg`, `curl` or `wget`, `tar`, `jq`, `arecord` (alsa-utils), `lsusb` (usbutils), `udevadm` (systemd)

### Hardware Limitations

#### Raspberry Pi Limitations
Due to USB bandwidth and power constraints, Raspberry Pi devices have practical limits:

- **Raspberry Pi Zero W**: Maximum 1 USB microphone
  - Limited USB bandwidth and processing power
  - Suitable for single-stream applications only
  
- **Raspberry Pi 3B/4/5**: Maximum 2 USB microphones
  - USB bandwidth becomes saturated with more than 2 audio streams
  - Power delivery limitations may cause device dropouts
  - CPU may struggle with more than 2 simultaneous encoding streams

#### Recommended Hardware for Multiple Microphones
For deployments requiring more than 2 simultaneous microphone streams:

- **Linux Mini PCs** (Recommended for 3+ microphones)
  - Intel N100 processor-based systems work excellently
  - Dedicated USB controllers provide better bandwidth
  - More stable power delivery for multiple devices
  - Can reliably handle 4-8 simultaneous streams

### USB Hub Considerations
If using USB hubs:
1. **Always use powered USB hubs** - Bus-powered hubs cannot provide sufficient power
2. **Choose high-quality hubs** - Look for hubs with individual port power switches
3. **Avoid daisy-chaining** - Connect hubs directly to the host computer
4. **Consider USB bandwidth** - Even with powered hubs, you're limited by the host's USB controller

### Production Deployment Guidelines
- **1-2 microphones**: Raspberry Pi 4 or 5 (with good cooling)
- **3-4 microphones**: Intel N100 mini PC or equivalent
- **5-8 microphones**: Higher-spec mini PC with multiple USB controllers
- **9+ microphones**: Consider multiple streaming servers or professional audio interfaces

## Quick Start Installation

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

### 3. Map USB Audio Devices (Recommended)

For each USB microphone, create persistent friendly names:

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

### 4. Install MediaMTX

```bash
sudo ./install_mediamtx.sh install
```

### 5. Start Audio Streams

```bash
sudo ./mediamtx-stream-manager.sh start
```

Your streams will be available at:
```
rtsp://localhost:8554/conference-mic-1
rtsp://localhost:8554/meeting-room-mic
```

## Basic Operation

### Stream Management Commands

```bash
# Start all streams
sudo ./mediamtx-stream-manager.sh start

# Stop all streams
sudo ./mediamtx-stream-manager.sh stop

# Check status
sudo ./mediamtx-stream-manager.sh status

# Monitor streams in real-time
sudo ./mediamtx-stream-manager.sh monitor
```

### Run as System Service

```bash
# Create systemd service
sudo ./mediamtx-stream-manager.sh install

# Enable service to start at boot
sudo systemctl enable mediamtx-audio

# Start service
sudo systemctl start mediamtx-audio

# Check service status
sudo systemctl status mediamtx-audio
```

### Test Your Streams

```bash
# FFplay
ffplay rtsp://localhost:8554/conference-mic-1

# VLC
vlc rtsp://localhost:8554/conference-mic-1

# MPV
mpv rtsp://localhost:8554/conference-mic-1
```

## Configuration

### Audio Device Settings

Edit `/etc/mediamtx/audio-devices.conf` to customize per-device settings:

```bash
# Example for a device with friendly name "conference-mic-1"
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

### Environment Variables for Production

Critical settings for production deployments:

```bash
# For systemd service, edit the service:
sudo systemctl edit mediamtx-audio

# Add these optimal production values:
[Service]
Environment="USB_STABILIZATION_DELAY=10"
Environment="RESTART_STABILIZATION_DELAY=15"
Environment="DEVICE_TEST_ENABLED=false"
Environment="STREAM_STARTUP_DELAY=10"
Environment="PARALLEL_STREAM_START=false"
```

## Version History and Upgrading

### Current Version: LyreBirdAudio v1.0.0

This is a rebrand and version reset of the former mediamtx-rtsp-setup project. All functionality from v8.1.0 is preserved.

### Previous Version Mapping
If upgrading from mediamtx-rtsp-setup:
- **mediamtx-stream-manager.sh v8.1.0** → LyreBirdAudio v1.0.0 (all features included)
- **mediamtx-stream-manager.sh v8.0.4** → Upgrade to LyreBirdAudio v1.0.0 recommended
- **install_mediamtx.sh v5.2.0** → Now part of LyreBirdAudio v1.0.0
- **usb-audio-mapper.sh v2.0** → Now part of LyreBirdAudio v1.0.0

### Enhancements in v1.0.0 (from v8.0.4)

#### Service Restart Reliability
When system services restart (during updates, reboots, or manual restarts), older versions faced:
- Stale processes that prevent clean restarts
- USB devices not being ready when services start
- PID file conflicts from previous runs
- FFmpeg processes not terminating properly
- Race conditions between cleanup and restart operations

**v1.0.0 addresses these with:**
- Enhanced cleanup procedures that properly terminate all child processes
- USB stabilization detection that waits for devices to be ready
- Restart scenario detection that applies special handling during service restarts
- Atomic cleanup operations using marker files to prevent race conditions
- ALSA state reset to recover from device conflicts
- Graceful process termination with proper signal cascading

### Upgrading from Previous Versions

#### For Users Upgrading from mediamtx-rtsp-setup (v8.0.4 or earlier)

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
```

#### 3. Update Scripts
```bash
# Clone or pull latest LyreBirdAudio version
git clone https://github.com/tomtom215/LyreBirdAudio.git
cd LyreBirdAudio
chmod +x *.sh
```

#### 4. Update MediaMTX Binary (Optional but Recommended)
```bash
sudo ./install_mediamtx.sh update
```

#### 5. Update Systemd Service
```bash
# Recreate service with new parameters
sudo ./mediamtx-stream-manager.sh install
sudo systemctl daemon-reload
```

#### 6. Configure Environment Variables (Critical)
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
```

**Critical**: Ensure USB_STABILIZATION_DELAY is 10 (not 5) and RESTART_STABILIZATION_DELAY is 15 (not 10) for optimal production performance.

#### 7. Start Services
```bash
sudo systemctl start mediamtx-audio
sudo systemctl status mediamtx-audio
```

#### 8. Verify Configuration
```bash
# Check all streams are running
sudo ./mediamtx-stream-manager.sh status

# Verify environment variables
sudo systemctl show mediamtx-audio | grep Environment

# Monitor for stability
sudo journalctl -u mediamtx-audio -f
```

### What's Preserved During Upgrade
- ✅ All device configurations in `/etc/mediamtx/audio-devices.conf`
- ✅ Your custom device names and mappings
- ✅ Udev rules for USB devices
- ✅ Stream names and paths
- ✅ All your audio device settings
- ✅ Systemd service configurations (with updates for new features)

### Rollback Procedure (If Needed)
```bash
# Stop services
sudo systemctl stop mediamtx-audio

# Restore backup configurations
sudo cp /etc/mediamtx/backup-$(date +%Y%m%d)/* /etc/mediamtx/

# Restart with old version (if you kept backups)
sudo systemctl start mediamtx-audio
```

## Troubleshooting

### Common Issues and Solutions

#### Ugly Stream Names
Map your devices to friendly names:
```bash
sudo ./usb-audio-mapper.sh
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
Edit `/etc/mediamtx/audio-devices.conf`:
```bash
DEVICE_YOUR_DEVICE_CODEC=opus
DEVICE_YOUR_DEVICE_BITRATE=64k
```

#### Audio Crackling or Dropouts
Increase buffer sizes in `/etc/mediamtx/audio-devices.conf`:
```bash
DEVICE_YOUR_DEVICE_ALSA_BUFFER=200000
DEVICE_YOUR_DEVICE_THREAD_QUEUE=16384
```

#### Port Conflicts
```bash
# Find what's using MediaMTX ports
sudo lsof -i :8554  # RTSP port
sudo lsof -i :9997  # API port

# Kill the process using the port
sudo kill -9 <PID>
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

## Advanced Topics

### Pre-Installation Cleanup

If you need to completely remove existing installations:

```bash
# Stop all services
sudo systemctl stop mediamtx mediamtx-audio 2>/dev/null || true
sudo systemctl disable mediamtx mediamtx-audio 2>/dev/null || true

# Kill any running processes
sudo pkill -f mediamtx || true
sudo pkill -f "ffmpeg.*rtsp://localhost:8554" || true

# Check if ports are free
sudo lsof -i :8554 || echo "Port 8554 is free"
sudo lsof -i :9997 || echo "Port 9997 is free"

# Backup existing configurations
[ -d "/etc/mediamtx" ] && sudo cp -r /etc/mediamtx "/etc/mediamtx.backup.$(date +%Y%m%d-%H%M%S)"
```

### Non-Interactive Device Mapping

For automation, use non-interactive mapping:

```bash
# Example: Map a MOVO X1 MINI microphone
sudo ./usb-audio-mapper.sh -n -d "MOVO X1 MINI" -v 2e88 -p 4610 -f conference-mic-1
sudo reboot
```

### Tips for Production Use

1. **Always use friendly names** - Run usb-audio-mapper.sh for each device
2. **Disable device testing** - Set `DEVICE_TEST_ENABLED=false`
3. **Use optimal delay settings** - Set `USB_STABILIZATION_DELAY=10` and `RESTART_STABILIZATION_DELAY=15`
4. **Use compressed codecs** - Opus or AAC instead of PCM
5. **Sequential stream startup** - Keep `PARALLEL_STREAM_START=false`
6. **Monitor logs regularly** - Set up log rotation for long-term operation
7. **Use systemd service** - For automatic startup and recovery
8. **Test failover** - Verify streams recover after unplugging/replugging devices
9. **Configure appropriate delays** - The systemd defaults (10/15 seconds) work well
10. **Regular updates** - Keep MediaMTX and scripts updated

### Optimal Production Configuration

```bash
# Critical settings for production
USB_STABILIZATION_DELAY=10        # Not 5 (the script default)
RESTART_STABILIZATION_DELAY=15    # Not 10 (the script default)
DEVICE_TEST_ENABLED=false         # Critical for stability
STREAM_STARTUP_DELAY=10           # Allow time for device initialization
PARALLEL_STREAM_START=false       # Sequential is more reliable
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

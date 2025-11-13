# LyreBirdAudio

Production-hardened RTSP audio streaming suite for USB microphones with 24/7 reliability.

Turn USB microphones into reliable RTSP streams for continuous monitoring and recording. Built on MediaMTX with automatic recovery, device persistence, and comprehensive diagnostics for unattended operation.

**If you like or use this project, please "star" this repository!**

If you are using it in a cool or interesting way or at a large scale, please tell me about it in our GitHub Discussions for this repository!

**License:** Apache 2.0  
**Platform:** Linux (Ubuntu/Debian/Raspberry Pi OS)  
**Author:** Tom F - https://github.com/tomtom215  
**GitHub:** https://github.com/tomtom215/LyreBirdAudio

---

## Table of Contents

- [Quick Start](#quick-start)
- [Features & Capabilities](#features--capabilities)
- [System Overview](#system-overview)
- [System Requirements](#system-requirements)
- [Installation](#installation)
- [Basic Usage](#basic-usage)
- [Configuration Guide](#configuration-guide)
- [MediaMTX Integration](#mediamtx-integration)
- [Troubleshooting](#troubleshooting)
- [Diagnostics & Monitoring](#diagnostics--monitoring)
- [Version Management](#version-management)
- [Performance & Optimization](#performance--optimization)
- [Architecture & Design](#architecture--design)
- [Component Reference](#component-reference)
- [Advanced Topics](#advanced-topics)
- [Uninstallation & Cleanup](#uninstallation--cleanup)
- [Development & Contributing](#development--contributing)
- [License & Credits](#license--credits)

---

## Quick Start

Get streaming in 5 minutes:

```bash
# 1. Clone and setup, this will clone the Main branch which has the most up to date features
git clone https://github.com/tomtom215/LyreBirdAudio.git
cd LyreBirdAudio

# If you want to use a tagged release insted of the Main branch: Checkout latest stable release
git checkout $(git describe --tags --abbrev=0)

chmod +x *.sh

# 2. Run guided setup (installs MediaMTX, maps devices, starts streams)
sudo ./lyrebird-orchestrator.sh
# Select: Quick Setup Wizard

# 3. Access your streams
# rtsp://your-ip:8554/device-name
```

That's it! The Orechestrator will act as a wizard that guides you through installation, device mapping, configuration, and stream startup.

**For Production Deployments:** Use tagged releases (shown above) for maximum stability. The main branch contains the latest features but may be work-in-progress. Tagged releases are normally tested for atleast 72 hours before releasing. Tests are performed on an Intel N100 mini-PC with 5 USB microphones running Ubuntu.

For manual installation, see [Installation](#installation).

---

## Features & Capabilities

### What This Project Does

**Core Functionality:**
- Transforms USB microphones into reliable RTSP streams
- Provides persistent device naming across reboots
- Automatically detects hardware capabilities and generates optimal configurations
- Monitors stream health and restarts failed streams automatically
- Offers unified management through interactive orchestrator or individual scripts

**Key Advantages:**
- **No Configuration Guesswork**: Automatically detects what your hardware supports
- **Survives Reboots**: USB devices maintain consistent names via udev rules
- **Self-Healing**: Automatic recovery from crashes and failures
- **Easy Updates**: Git-based version management with rollback capability
- **Production-Ready**: Designed for unattended 24/7 operation

### Project Origin

This project was inspired by monitoring bird activity using USB microphones and spare Mini PCs. After discovering cberge908's original MediaMTX launcher script, it became clear that 24/7 reliable operation required handling numerous edge cases. LyreBirdAudio is the result -- a production-hardened solution for long-term unattended operation.

### Technical Approach

**USB Device Persistence:**
- Maps devices to physical USB ports using udev rules
- Eliminates naming conflicts from USB enumeration order
- Supports multiple identical devices on different ports

**Stream Management:**
- Wrapper-based process supervision with exponential backoff (10s to 300s)
- Health monitoring via MediaMTX API
- Graceful shutdown with process tree termination
- Cron-based monitoring for production deployments

**Hardware Detection:**
- Non-invasive capability detection via `/proc/asound`
- Avoids opening devices (won't interrupt active streams)
- Detects sample rates, channels, formats automatically
- Warns about USB audio adapter chip limitations

**Resource Monitoring:**
- Tracks CPU, memory, file descriptors
- Configurable warning/critical thresholds
- Detects audio subsystem conflicts
- Provides actionable remediation steps

---

## System Overview

These diagrams show how LyreBirdAudio components work together to transform USB microphones into reliable RTSP streams.

### System Architecture Overview

```
+----------------------------------------------------------+
|                     Client Applications                  |
|            (VLC, FFplay, OBS, Custom RTSP Clients)       |
+--------------------+-------------------------------------+
                     | RTSP://host:8554/DeviceName
                     v
+----------------------------------------------------------+
|                       MediaMTX                           |
|                  (Real-time Media Server)                |
|  +----------------------------------------------------+  |
|  | * RTSP Server (port 8554)                          |  |
|  | * RTP/RTCP (ports 8000-8001)                       |  |
|  | * HTTP API (port 9997)                             |  |
|  | * WebRTC Support                                   |  |
|  +----------------------------------------------------+  |
+--------------------+-------------------------------------+
                     | Managed by
                     v
+----------------------------------------------------------+
|              Stream Manager / systemd                    |
|  +----------------------------------------------------+  |
|  | * Process lifecycle management                     |  |
|  | * Automatic stream recovery                        |  |
|  | * Health monitoring                                |  |
|  | * Real-time scheduling                             |  |
|  +----------------------------------------------------+  |
+--------------------+-------------------------------------+
                     | Captures from
                     v
+----------------------------------------------------------+
|                  FFmpeg Audio Pipeline                   |
|  +----------------------------------------------------+  |
|  | * ALSA capture (hw:Device_N)                       |  |
|  | * Audio encoding (Opus/AAC/PCM)                    |  |
|  | * RTSP publishing to MediaMTX                      |  |
|  | * Buffer management & thread queues                |  |
|  +----------------------------------------------------+  |
+--------------------+-------------------------------------+
                     | Reads from
                     v
+----------------------------------------------------------+
|              Persistent Device Layer (udev)              |
|  +----------------------------------------------------+  |
|  | * /dev/snd/by-usb-port/Device_1 -> /dev/snd/pcmC0D0c |
|  | * /dev/snd/by-usb-port/Device_2 -> /dev/snd/pcmC1D0c |
|  | * Consistent naming across reboots                 |  |
|  +----------------------------------------------------+  |
+--------------------+-------------------------------------+
                     | Maps
                     v
+----------------------------------------------------------+
|               Physical USB Audio Devices                 |
|  +----------------------------------------------------+  |
|  | * USB Port 1-1.4: USB Microphone                   |  |
|  | * USB Port 1-1.5: USB Audio Interface              |  |
|  | * USB Port 2-1.2: USB Microphone                   |  |
|  +----------------------------------------------------+  |
+----------------------------------------------------------+
```

### Management Component Architecture

```
+----------------------------------------------------------+
|                 lyrebird-orchestrator.sh                 |
|                 (Unified Management Interface)           |
|  * Interactive TUI for all operations                    |
|  * Delegates to specialized scripts                      |
|  * No duplicate business logic                           |
|  * Consistent error handling & feedback                  |
|  * Hardware capability detection integration             |
+----------------------------------------------------------+
          |
          +----> install_mediamtx.sh
          |       * MediaMTX installation & updates
          |       * Binary management with checksums
          |       * Service configuration
          |       * Built-in upgrade support (v1.15.0+)
          |       * Atomic installation with rollback
          |
          +----> mediamtx-stream-manager.sh
          |       * FFmpeg process lifecycle management
          |       * Stream health monitoring via API
          |       * Automatic recovery with exponential backoff
          |       * Individual & multiplex streaming modes
          |       * Resource monitoring (CPU, FDs)
          |       * Cron-based health checking
          |
          +----> usb-audio-mapper.sh
          |       * USB device detection via lsusb
          |       * udev rule generation
          |       * Physical port mapping
          |       * Persistent naming across reboots
          |       * Interactive & non-interactive modes
          |
          +----> lyrebird-mic-check.sh
          |       * Hardware capability detection
          |       * ALSA format enumeration
          |       * Quality tier recommendations
          |       * Configuration generation & validation
          |       * Backup management
          |
          +----> lyrebird-updater.sh
          |       * Script version management
          |       * Git-based updates
          |       * Branch and tag support
          |       * Rollback capabilities
          |       * Service update coordination
          |
          +----> lyrebird-diagnostics.sh
                  * Comprehensive system health checks
                  * USB device validation
                  * MediaMTX service monitoring
                  * RTSP connectivity testing
                  * Resource constraint detection
                  * Quick/full/debug diagnostic modes
```
---

## System Requirements

### Minimum Requirements

- **Operating System**: Linux kernel 4.0+ (Ubuntu 20.04+, Debian 11+, Raspberry Pi OS)
- **Architecture**: x86_64, ARM64, ARMv7, ARMv6
- **Processor**: 1 CPU core (2+ recommended for multiple streams)
- **Memory**: 512MB RAM (1GB+ recommended for multiple streams)
- **Storage**: 100MB for MediaMTX and scripts
- **Bash**: Version 4.0+ (for associative array support)

### Hardware Recommendations

**Raspberry Pi Limitations:**
- Maximum 2 USB microphones due to USB bandwidth/power constraints
- Pi Zero and 3B+ should use 1 microphone maximum for stability
- Not recommended for multi-microphone production deployments

**Recommended: Intel N100/N150 Mini PCs**
- More reliable USB architecture without shared bandwidth issues
- Support for 4+ simultaneous USB audio devices
- Better performance and stability under load
- Cost-effective ($100-150 range)

### Software Dependencies

**Required:**
- bash 4.0+ (check: `bash --version`)
- ffmpeg with ALSA support
- curl or wget
- tar, gzip
- systemd (for service management)
- udev
- git 2.0+ (for version management)
- lsusb (usbutils package)
- arecord, alsamixer (alsa-utils package)

**Optional but Recommended:**
- jq (JSON parsing for MediaMTX API)
- lsof or ss (port monitoring)
- shellcheck (development/validation)
- logrotate (log management)

**Verification:**
```bash
# Check Bash version (must be 4.0+)
bash --version

# Check root access
sudo -v

# Verify required commands
command -v lsusb udevadm git ffmpeg arecord
```

### Audio Requirements

- USB audio device with ALSA driver support
- Sufficient USB bandwidth for desired sample rates
- ALSA utilities installed (arecord, alsamixer)

---

## Installation

### Prerequisites

```bash
# Verify Bash version (must be 4.0+)
bash --version

# Check root access
sudo -v

# Verify required commands
command -v lsusb udevadm git
```

### Using the Orchestrator (Recommended)

The orchestrator provides a guided wizard that handles everything:

```bash
# 1. Clone repository
git clone https://github.com/tomtom215/LyreBirdAudio.git
cd LyreBirdAudio

# RECOMMENDED FOR PRODUCTION: Use latest stable release
git checkout $(git describe --tags --abbrev=0)

chmod +x *.sh

# 2. Launch orchestrator
sudo ./lyrebird-orchestrator.sh

# 3. Select "Quick Setup Wizard" from menu
# The wizard will:
#   - Install MediaMTX
#   - Map your USB audio devices
#   - Generate optimal configuration
#   - Start streams
#   - Run diagnostics
```

**Production Note:** Using tagged releases ensures maximum stability. Skip the `git checkout` command to use the main branch with latest features (may be less stable).

### Manual Installation

For automation or when you prefer manual control:

```bash
# 1. Install MediaMTX
sudo ./install_mediamtx.sh install

# 2. Map USB devices (interactive)
sudo ./usb-audio-mapper.sh

# 3. Generate configuration
sudo ./lyrebird-mic-check.sh -g

# 4. Start streams
sudo ./mediamtx-stream-manager.sh start

# Optional: Install as systemd service
sudo ./mediamtx-stream-manager.sh install
sudo systemctl enable mediamtx-audio
```

### Verification

```bash
# Check system health
sudo ./lyrebird-diagnostics.sh quick

# View stream status
./mediamtx-stream-manager.sh status

# Access your streams
# rtsp://your-ip:8554/device-name
```

**Reboot Recommended:** After initial USB device mapping, reboot for udev rules to take full effect.

### Post-Installation

Access your streams at:
```
rtsp://hostname:8554/Device_1
rtsp://hostname:8554/Device_2
```

Test with VLC or ffplay:
```bash
ffplay rtsp://localhost:8554/Device_1
vlc rtsp://localhost:8554/Device_1
```

---

## Basic Usage

### Managing Streams

```bash
# Start all streams
sudo ./mediamtx-stream-manager.sh start

# Stop all streams
sudo ./mediamtx-stream-manager.sh stop

# Restart streams
sudo ./mediamtx-stream-manager.sh restart

# Check status
./mediamtx-stream-manager.sh status
```

### Using the Orchestrator

```bash
sudo ./lyrebird-orchestrator.sh
```

**Main Menu:**
- Quick Setup Wizard - Initial configuration
- MediaMTX Installation & Updates - Install/update MediaMTX
- USB Device Management - Map devices, check capabilities
- Audio Streaming Control - Start/stop streams
- System Diagnostics - Health checks
- Version Management - Update scripts
- Logs & Status - View logs

### Accessing Streams

Streams are accessible via RTSP:
```
rtsp://your-server-ip:8554/device-name
```

**Example:**
```
rtsp://192.168.1.100:8554/usb-microphone-1
rtsp://192.168.1.100:8554/usb-microphone-2
```

**VLC Player:**
```bash
vlc rtsp://192.168.1.100:8554/usb-microphone-1
```

**FFmpeg Recording:**
```bash
ffmpeg -i rtsp://192.168.1.100:8554/usb-microphone-1 -c copy recording.mkv
```

### Health Monitoring

```bash
# Quick health check
sudo ./lyrebird-diagnostics.sh quick

# Full diagnostics
sudo ./lyrebird-diagnostics.sh full

# Enable automatic monitoring (cron)
sudo ./mediamtx-stream-manager.sh install  # Creates cron job
```

---

## Configuration Guide

### Audio Device Configuration

Configuration file: `/etc/mediamtx/audio-devices.conf`

**Generate automatically (recommended):**
```bash
# Normal quality (48kHz, 128kbps)
sudo ./lyrebird-mic-check.sh -g

# High quality (48kHz, 256kbps)
sudo ./lyrebird-mic-check.sh -g --quality=high

# Low quality (16kHz, 64kbps)
sudo ./lyrebird-mic-check.sh -g --quality=low
```

**Manual configuration format:**
```bash
# Device-specific settings (friendly name)
DEVICE_USB_MICROPHONE_SAMPLE_RATE=48000
DEVICE_USB_MICROPHONE_CHANNELS=2
DEVICE_USB_MICROPHONE_BITRATE=192k
DEVICE_USB_MICROPHONE_CODEC=opus

# Device-specific settings (full device ID)
DEVICE_USB_MANUFACTURER_MODEL_SERIAL_00000000_SAMPLE_RATE=48000
DEVICE_USB_MANUFACTURER_MODEL_SERIAL_00000000_CHANNELS=2

# Fallback defaults
DEFAULT_SAMPLE_RATE=48000
DEFAULT_CHANNELS=2
DEFAULT_BITRATE=128k
DEFAULT_CODEC=opus
```

**Available settings:**
- `SAMPLE_RATE` - Sample rate in Hz (e.g., 48000, 44100, 16000)
- `CHANNELS` - Channel count (1=mono, 2=stereo)
- `BITRATE` - Encoder bitrate (e.g., 128k, 192k, 256k)
- `CODEC` - Audio codec (opus, aac, mp3, pcm)
- `THREAD_QUEUE` - Buffer size (default: 8192)

**Validate configuration:**
```bash
sudo ./lyrebird-mic-check.sh -V
```

### System Configuration Files

| File | Purpose | Format |
|------|---------|--------|
| `/etc/mediamtx/mediamtx.yml` | MediaMTX main configuration | YAML |
| `/etc/mediamtx/audio-devices.conf` | Audio device mappings | Text (bash environment variables) |
| `/etc/udev/rules.d/99-usb-soundcards.rules` | USB device persistence rules | udev syntax |
| `/etc/systemd/system/mediamtx.service` | MediaMTX systemd service | INI-style |
| `/etc/systemd/system/mediamtx-audio.service` | Stream manager systemd service | INI-style |

### Runtime State Files

| File/Directory | Purpose |
|----------------|---------|
| `/run/mediamtx-audio.pid` | Stream manager PID file |
| `/run/mediamtx-audio.lock` | Stream manager lock file |
| `/var/lib/mediamtx-ffmpeg/` | FFmpeg PID files and wrapper scripts |
| `/var/log/mediamtx.out` | MediaMTX output log |
| `/var/log/mediamtx-stream-manager.log` | Stream manager log |
| `/var/log/lyrebird/` | FFmpeg per-device logs |
| `/var/log/lyrebird-orchestrator.log` | Orchestrator log |
| `/var/log/lyrebird-diagnostics.log` | Diagnostics log |

### Environment Variables

Override defaults with environment variables:

**Stream Manager Configuration:**
```bash
# MediaMTX paths
MEDIAMTX_BINARY="/usr/local/bin/mediamtx"
MEDIAMTX_CONFIG_DIR="/etc/mediamtx"
MEDIAMTX_CONFIG_FILE="/etc/mediamtx/mediamtx.yml"
MEDIAMTX_DEVICE_CONFIG="/etc/mediamtx/audio-devices.conf"
MEDIAMTX_LOG_FILE="/var/log/mediamtx.out"
MEDIAMTX_HOST="localhost"
MEDIAMTX_API_PORT="9997"

# Process management
MEDIAMTX_PID_FILE="/run/mediamtx-audio.pid"
MEDIAMTX_LOCK_FILE="/run/mediamtx-audio.lock"
MEDIAMTX_FFMPEG_DIR="/var/lib/mediamtx-ffmpeg"

# Timing and delays
STREAM_STARTUP_DELAY=10
USB_STABILIZATION_DELAY=5
RESTART_STABILIZATION_DELAY=15
STREAM_VALIDATION_ATTEMPTS=3
STREAM_VALIDATION_DELAY=5

# Resource thresholds
MAX_FD_WARNING=500
MAX_FD_CRITICAL=1000
MAX_CPU_WARNING=20
MAX_CPU_CRITICAL=40

# Recovery settings
MAX_WRAPPER_RESTARTS=50
WRAPPER_SUCCESS_DURATION=300
MAX_CONSECUTIVE_FAILURES=5
INITIAL_RESTART_DELAY=10
MAX_RESTART_DELAY=300

# Audio defaults (when not in config file)
DEFAULT_SAMPLE_RATE=48000
DEFAULT_CHANNELS=2
DEFAULT_CODEC=opus
DEFAULT_BITRATE=128k
DEFAULT_THREAD_QUEUE=8192
```

**Installer Configuration:**
```bash
MEDIAMTX_PREFIX="/usr/local"
MEDIAMTX_CONFIG_DIR="/etc/mediamtx"
MEDIAMTX_STATE_DIR="/var/lib/mediamtx"
MEDIAMTX_USER="mediamtx"
MEDIAMTX_GROUP="mediamtx"
MEDIAMTX_RTSP_PORT=8554
MEDIAMTX_API_PORT=9997
MEDIAMTX_DOWNLOAD_TIMEOUT=300
MEDIAMTX_DOWNLOAD_RETRIES=3
```

**Debug Mode:**
```bash
export DEBUG=1  # Enable debug output for all scripts
```

**Example usage:**
```bash
# Use custom log location
FFMPEG_LOG_DIR=/mnt/storage/logs ./mediamtx-stream-manager.sh start

# Increase startup delay for slow USB devices
STREAM_STARTUP_DELAY=20 ./mediamtx-stream-manager.sh start
```

### Multiplex Streaming

Combine multiple microphones into a single RTSP stream using FFmpeg audio filters. This is useful for centralized monitoring, recording all microphones together, or creating composite audio feeds.

#### amix Filter (Audio Mixing)

**Purpose:** Mix multiple audio inputs into a single output stream (downmix to stereo/mono).

```bash
# Mix all devices into one stereo stream
sudo ./mediamtx-stream-manager.sh -m multiplex -f amix start
```

**How it works:**
- Takes N audio inputs and mixes them down to a single audio stream
- All inputs are combined with equal weight by default
- Output format: Typically stereo (2 channels) regardless of input count
- Use case: When you want to hear all microphones together as one audio feed

**FFmpeg amix filter documentation:**  
https://ffmpeg.org/ffmpeg-filters.html#amix

**Technical details:**
- Default behavior mixes all inputs with equal weights
- Automatically handles different sample rates through resampling
- Output level is normalized to prevent clipping
- Ideal for: Monitoring multiple rooms, creating composite audio, simple multi-mic recording

**Example output:**
- Input: 3 USB mics (Device_1, Device_2, Device_3)
- Output: `rtsp://host:8554/all_mics` (single stereo stream with mixed audio)

---

#### amerge Filter (Channel Merging)

**Purpose:** Merge multiple audio inputs while keeping channels separate (preserve spatial information).

```bash
# Merge channels while keeping them separate
sudo ./mediamtx-stream-manager.sh -m multiplex -f amerge start
```

**How it works:**
- Concatenates audio inputs into a single stream with more channels
- Each input's channels are preserved in the output
- Output format: (num_devices x channels_per_device) total channels
- Use case: When you need to preserve which audio came from which microphone

**FFmpeg amerge filter documentation:**  
https://ffmpeg.org/ffmpeg-filters.html#amerge-1

**Technical details:**
- Maintains channel separation for post-processing
- All inputs must have the same sample rate and format
- Enables individual channel analysis after streaming
- Ideal for: Professional audio recording, forensic monitoring, spatial audio analysis

**Example output:**
- Input: 3 stereo USB mics (each with 2 channels)
- Output: `rtsp://host:8554/all_mics` (single stream with 6 channels total)
- Channel mapping: Ch1-2: Device_1, Ch3-4: Device_2, Ch5-6: Device_3

---

#### Custom Stream Names

```bash
# Use a custom name instead of default "all_mics"
sudo ./mediamtx-stream-manager.sh -m multiplex -n studio start
# Output: rtsp://host:8554/studio
```

---

#### Comparison: amix vs amerge

| Feature | amix (Mixing) | amerge (Merging) |
|---------|---------------|------------------|
| Output channels | Fixed (typically 2) | Sum of all inputs |
| Channel separation | Lost (mixed together) | Preserved |
| Bandwidth usage | Lower | Higher |
| Post-processing | Limited | Full individual channel access |
| Best for | Monitoring, simple recording | Professional audio, analysis |
| Playback complexity | Simple (standard stereo) | Requires multi-channel player |

---

**Stream URLs:**
- Individual mode: `rtsp://ip:8554/device-name`
- Multiplex mode: `rtsp://ip:8554/all_mics` (or custom name)

---

## MediaMTX Integration

### Service Management Modes

LyreBirdAudio supports three MediaMTX management modes:

1. **Stream Manager Mode** (Recommended for audio streaming)
   - Managed by `mediamtx-stream-manager.sh`
   - Automatic FFmpeg process management
   - Stream health monitoring and recovery
   - Start/stop/restart via stream manager commands
   - Systemd service: `mediamtx-audio.service`

2. **Systemd Mode** (Recommended for general use)
   - Managed by systemd service directly
   - `systemctl start/stop/restart mediamtx`
   - Automatic startup on boot
   - System-level integration
   - Systemd service: `mediamtx.service`

3. **Manual Mode** (Advanced users)
   - Direct binary execution
   - Manual process management
   - Custom configuration

### Mode Selection

The orchestrator and stream manager automatically detect and use the appropriate mode. Manual switching:

```bash
# Install stream manager systemd service
sudo ./mediamtx-stream-manager.sh install

# Or use MediaMTX systemd service directly
sudo systemctl enable mediamtx
sudo systemctl start mediamtx
```

### Configuration

**MediaMTX main configuration:** `/etc/mediamtx/mediamtx.yml`

**Audio device configuration:** `/etc/mediamtx/audio-devices.conf`

Example audio device configuration (dual-lookup format):
```bash
# Friendly name configuration (easier to use)
DEVICE_USB_MICROPHONE_SAMPLE_RATE=48000
DEVICE_USB_MICROPHONE_CHANNELS=2
DEVICE_USB_MICROPHONE_BITRATE=128k

# Full device ID configuration (guaranteed unique)
DEVICE_USB_MANUFACTURER_MODEL_SERIAL_00000000_SAMPLE_RATE=48000
DEVICE_USB_MANUFACTURER_MODEL_SERIAL_00000000_CHANNELS=2
DEVICE_USB_MANUFACTURER_MODEL_SERIAL_00000000_BITRATE=128k

# Fallback defaults (used when device-specific config not found)
DEFAULT_SAMPLE_RATE=48000
DEFAULT_CHANNELS=2
DEFAULT_BITRATE=128k
DEFAULT_CODEC=opus
```

Format explanation:
- Device names are sanitized: special characters become underscores, converted to UPPERCASE
- Friendly names: `DEVICE_<sanitized_name>_<PARAMETER>=value`
- Full IDs: `DEVICE_<sanitized_full_id>_<PARAMETER>=value`
- Stream manager tries friendly name first, then full ID, then defaults

---

## Troubleshooting

### Quick Diagnostics

```bash
# Run health check
sudo ./lyrebird-diagnostics.sh quick

# Check specific components
./mediamtx-stream-manager.sh status
./lyrebird-mic-check.sh
```

### Common Issues

#### No USB Devices Found

```bash
# Check device detection
lsusb | grep -i audio
arecord -l

# Verify udev rules
sudo cat /etc/udev/rules.d/99-usb-soundcards.rules

# Remap devices
sudo ./usb-audio-mapper.sh

# Reload udev and reboot
sudo udevadm control --reload-rules
sudo reboot
```

#### Streams Won't Start

```bash
# Check logs
sudo tail -f /var/log/mediamtx-stream-manager.log
sudo tail -f /var/log/lyrebird/*.log

# Validate configuration
sudo ./lyrebird-mic-check.sh -V

# Force restart
sudo ./mediamtx-stream-manager.sh force-stop
sudo ./mediamtx-stream-manager.sh start

# Check for device conflicts
sudo lsof /dev/snd/*
```

#### Device Names Change After Reboot

**Symptoms**: Device_1 becomes Device_2 after reboot

**Diagnosis:**
```bash
cat /etc/udev/rules.d/99-usb-soundcards.rules
udevadm control --reload-rules
udevadm trigger
ls -la /dev/snd/by-usb-port/
```

**Solutions:**
- Re-run USB mapper: `sudo ./usb-audio-mapper.sh`
- Reboot system for udev rules to take effect
- Verify physical USB port hasn't changed

#### Permission Errors

```bash
# Add user to audio group
sudo usermod -a -G audio $USER

# Fix directory permissions
sudo mkdir -p /var/log/lyrebird
sudo chmod 755 /var/log/lyrebird

# Reboot to apply group changes
sudo reboot
```

#### MediaMTX Crashes

```bash
# Check system resources
free -h
df -h

# View crash logs
sudo journalctl -u mediamtx -n 100

# Increase system limits
sudo bash -c 'echo "* soft nofile 4096" >> /etc/security/limits.conf'
sudo bash -c 'echo "* hard nofile 8192" >> /etc/security/limits.conf'

# Restart service
sudo systemctl restart mediamtx
```

#### High CPU Usage

**Symptoms**: System becomes unresponsive

**Diagnosis:**
```bash
sudo ./mediamtx-stream-manager.sh monitor
top -p $(pgrep -f ffmpeg | tr '\n' ',')
```

**Solutions:**
- Reduce sample rate in audio-devices.conf
- Use lower bitrate encoding
- Reduce number of simultaneous streams
- Check for FFmpeg process accumulation

#### MediaMTX Won't Update

**Symptoms**: Update command fails

**Diagnosis:**
```bash
sudo ./install_mediamtx.sh status
curl -I https://api.github.com/repos/bluenviron/mediamtx/releases/latest
```

**Solutions:**
- Check network connectivity
- Verify GitHub is accessible
- Try specific version: `sudo ./install_mediamtx.sh -V v1.15.0 update`
- Use force flag: `sudo ./install_mediamtx.sh -f update`

#### Version Update Failed

**Symptoms**: Git update errors or conflicts

**Diagnosis:**
```bash
git status
git stash list
./lyrebird-updater.sh --status
```

**Solutions:**
- Stash local changes: `git stash`
- Reset to clean state: `git reset --hard origin/main`
- Switch to known good version via updater
- Check repository ownership: `stat -c %U .git/config`

### Debug Procedures

**Enable Verbose Logging:**
```bash
export DEBUG=1
sudo ./mediamtx-stream-manager.sh start
```

**Check All Logs:**
```bash
sudo tail -f /var/log/mediamtx.out
sudo tail -f /var/log/mediamtx-stream-manager.log
sudo tail -f /var/log/lyrebird/*.log
```

**Validate Configuration:**
```bash
/usr/local/bin/mediamtx --check /etc/mediamtx/mediamtx.yml
cat /etc/mediamtx/audio-devices.conf
```

**Test RTSP Manually:**
```bash
ffplay -i rtsp://localhost:8554/Device_1 -loglevel debug
```

**Check System Resources:**
```bash
sudo ./lyrebird-diagnostics.sh full
sudo ./mediamtx-stream-manager.sh monitor
```

### Log Locations

**Service logs:**
- MediaMTX: `/var/log/mediamtx.out`
- Stream Manager: `/var/log/mediamtx-stream-manager.log`
- Orchestrator: `/var/log/lyrebird-orchestrator.log`
- Diagnostics: `/var/log/lyrebird-diagnostics.log`

**Stream logs:**
- FFmpeg per-device: `/var/log/lyrebird/<device-name>.log`

**System logs:**
```bash
# Systemd services
sudo journalctl -u mediamtx -f
sudo journalctl -u mediamtx-audio -f

# USB events
sudo dmesg | grep -i usb
```

### Collecting Debug Information

For bug reports, collect:

```bash
# 1. Run full diagnostics
sudo ./lyrebird-diagnostics.sh full > diagnostics.txt 2>&1

# 2. Collect logs
tar -czf lyrebird-logs-$(date +%Y%m%d).tar.gz \
  /var/log/mediamtx.out \
  /var/log/mediamtx-stream-manager.log \
  /var/log/lyrebird/*.log \
  /etc/mediamtx/audio-devices.conf \
  /etc/udev/rules.d/99-usb-soundcards.rules

# 3. System info
cat /etc/os-release > system-info.txt
uname -a >> system-info.txt
lsusb >> system-info.txt
```

Include diagnostics.txt, logs tarball, and system-info.txt in your issue report.

**GitHub Issues:** https://github.com/tomtom215/LyreBirdAudio/issues

---

## Diagnostics & Monitoring

### Health Checking

LyreBirdAudio includes comprehensive diagnostics via `lyrebird-diagnostics.sh`:

**Quick Check** (essential systems):
```bash
sudo ./lyrebird-diagnostics.sh quick
```

**Full Check** (comprehensive analysis):
```bash
sudo ./lyrebird-diagnostics.sh full
```

**Debug Check** (maximum verbosity):
```bash
sudo ./lyrebird-diagnostics.sh debug
```

### What Gets Checked

**System Health:**
- OS type and kernel version
- System uptime and load
- Memory and CPU utilization
- Required utilities (ffmpeg, arecord, jq)

**USB Audio Devices:**
- Device detection and enumeration
- ALSA card availability
- Device mapping status
- Port path validation
- Device busy state

**MediaMTX Service:**
- Binary installation and version
- Configuration file validity
- Service status (systemd/stream-manager)
- API accessibility
- Port availability (8554, 9997)

**Stream Status:**
- Active stream count
- FFmpeg process validation
- Stream health and uptime
- Resource usage per stream

**RTSP Connectivity:**
- Port 8554 accessibility
- RTSP protocol validation
- Stream connection testing

**Log Analysis:**
- Error detection in logs
- Recent warnings and failures
- Log file accessibility

**System Resources:**
- File descriptor usage
- CPU usage by process
- Memory availability
- Disk space

**Time Synchronization:**
- NTP service status
- Chrony service status
- Time drift detection

### Diagnostic Exit Codes

- `0`: All checks passed
- `1`: Warnings detected (system functional but needs attention)
- `2`: Failures detected (system degraded or non-functional)
- `127`: Prerequisites missing (cannot complete diagnostics)

### Integration with Orchestrator

The orchestrator integrates diagnostics into multiple workflows:

1. **Quick Health Check** (Main Menu -> 7 -> 5)
   - Fast system health verification
   - Run before major operations

2. **Full Diagnostic** (Main Menu -> 5 -> 2)
   - Comprehensive system analysis
   - Recommended for troubleshooting

3. **Debug Diagnostic** (Main Menu -> 5 -> 3)
   - Maximum verbosity
   - Detailed failure analysis

### Monitoring Best Practices

1. Run quick diagnostics daily:
   ```bash
   sudo ./lyrebird-diagnostics.sh quick
   ```

2. Run full diagnostics weekly:
   ```bash
   sudo ./lyrebird-diagnostics.sh full
   ```

3. Run debug diagnostics when troubleshooting:
   ```bash
   sudo ./lyrebird-diagnostics.sh debug --verbose
   ```

4. Monitor resource usage:
   ```bash
   sudo ./mediamtx-stream-manager.sh monitor
   ```

5. Check logs regularly:
   ```bash
   sudo tail -f /var/log/mediamtx-stream-manager.log
   ```

---

## Version Management

### Update Process

LyreBirdAudio uses git-based version management via `lyrebird-updater.sh`:

1. **Check for Updates**
   ```bash
   ./lyrebird-updater.sh --status
   ```

2. **List Available Versions**
   ```bash
   ./lyrebird-updater.sh --list
   ```

3. **Upgrade to Latest**
   ```bash
   ./lyrebird-updater.sh
   # Select option 2: Upgrade to Latest Version
   ```

4. **Switch to Specific Version**
   ```bash
   ./lyrebird-updater.sh
   # Select option 3: Switch to Specific Version
   ```

### Branch Structure

**Recommended for Production:**
- **Tags** (v1.0.0, v1.1.0, etc.): Stable releases - **Use these for production deployments**
  - Thoroughly tested and validated
  - Production-ready with known behavior
  - Recommended for 24/7 operations

**For Latest Features:**
- **main**: Latest features and fixes - Use with caution
  - Contains newest functionality
  - Generally stable but may be work-in-progress
  - Suitable for testing new features
  - May have minor issues being resolved

**Unstable/Testing Only:**
- **development** and other branches: Nightly builds - Not recommended for production
  - Active development code
  - May contain breaking changes
  - For testing and development only
  - Stability not guaranteed

**Best Practice:** Pin to a specific tagged release for production systems, then test newer versions in a staging environment before upgrading.

### Update Behavior

- Automatically stashes local changes before switching versions
- Restores stashed changes after version switch (with conflict detection)
- Preserves executable permissions on all scripts
- Self-update capability when updater script changes
- Transaction-based operations with automatic rollback on failure
- Lock file prevents concurrent executions
- Systemd service coordination (stops before update, reinstalls after)
- Cron job update handling

### Version Requirements

- Requires git clone of repository (not compatible with standalone tarball installations)
- Git 2.0+ must be installed
- Repository must have remote origin configured
- Recommended to run as normal user (not root)

### Rollback

If an update causes issues:
```bash
./lyrebird-updater.sh
# Select option 3: Switch to Specific Version
# Choose previous stable version
```

The updater maintains transaction logs for debugging:
```bash
git reflog  # View recent operations
git stash list  # View stashed changes
```

### Manual Version Management

```bash
# Use the version manager (handles complexity)
sudo ./lyrebird-updater.sh

# Or manually (not recommended)
git fetch origin
git checkout <tag-name>  # e.g., v1.2.0
chmod +x *.sh
```

---

## Performance & Optimization

### Stream Optimization

**Codec Selection:**
- **Opus**: Best quality/bitrate ratio, low latency (recommended)
- **AAC**: Wider compatibility, moderate latency
- **PCM**: Lossless, high bandwidth

**Sample Rate Selection:**
- **48000 Hz**: Standard for professional audio (recommended)
- **44100 Hz**: CD quality, slightly lower bandwidth
- **96000 Hz**: High-res audio, double bandwidth

**Bitrate Tuning:**
- **128k**: Good quality for speech/music (recommended)
- **96k**: Acceptable for speech
- **256k**: High quality music

**Example Configuration:**
```bash
# High quality music streaming
DEVICE_USB_MICROPHONE_1_SAMPLE_RATE=96000
DEVICE_USB_MICROPHONE_1_CHANNELS=2
DEVICE_USB_MICROPHONE_1_BITRATE=256k
DEVICE_USB_MICROPHONE_1_CODEC=opus

# Speech/monitoring (bandwidth-constrained)
DEVICE_USB_MICROPHONE_2_SAMPLE_RATE=44100
DEVICE_USB_MICROPHONE_2_CHANNELS=1
DEVICE_USB_MICROPHONE_2_BITRATE=96k
DEVICE_USB_MICROPHONE_2_CODEC=opus
```

### Resource Management

**CPU Usage:**
- Monitor with: `sudo ./mediamtx-stream-manager.sh monitor`
- Warning threshold: 20% per stream
- Critical threshold: 40% per stream
- Optimization: Lower sample rate or bitrate

**Memory Usage:**
- Each FFmpeg stream uses ~50-100MB
- MediaMTX uses ~50-100MB base + ~10MB per stream
- Recommended: 1GB+ RAM for 10+ streams

**Network Bandwidth:**
- 128kbps audio = ~16KB/s per stream per client
- 256kbps audio = ~32KB/s per stream per client
- Consider bandwidth when choosing bitrate

### System Tuning

**File Descriptor Limits:**
```bash
# Check current limits
ulimit -n

# Increase for mediamtx user
echo "mediamtx soft nofile 4096" | sudo tee -a /etc/security/limits.conf
echo "mediamtx hard nofile 8192" | sudo tee -a /etc/security/limits.conf

# Increase for stream manager
echo "* soft nofile 8192" | sudo tee -a /etc/security/limits.conf
echo "* hard nofile 16384" | sudo tee -a /etc/security/limits.conf

# Reboot to apply
sudo reboot
```

**Network Buffer Sizes:**
```bash
# Increase UDP buffer sizes for streaming
sudo sysctl -w net.core.rmem_max=26214400
sudo sysctl -w net.core.wmem_max=26214400

# Make permanent
echo "net.core.rmem_max=26214400" | sudo tee -a /etc/sysctl.conf
echo "net.core.wmem_max=26214400" | sudo tee -a /etc/sysctl.conf
```

**USB Latency Optimization:**
```bash
# Reduce USB polling interval (if supported by device)
echo 1 | sudo tee /sys/bus/usb/devices/*/power/autosuspend
```

**Thread Queue Size:**
```bash
# For high stream counts (4+)
echo 'DEFAULT_THREAD_QUEUE=16384' >> /etc/mediamtx/audio-devices.conf
```

### For Raspberry Pi

```bash
# Use lower quality settings
sudo ./lyrebird-mic-check.sh -g --quality=low

# Reduce stream count to 1-2 maximum
# Consider switching to Intel N100 mini PC for stability
```

### Monitoring and Alerting

**Resource Monitoring:**
```bash
# Automated monitoring via cron (installed with systemd service)
# Configured at: /etc/cron.d/mediamtx-monitor
*/5 * * * * root /path/to/mediamtx-stream-manager.sh monitor
```

**Log Rotation:**
```bash
# Configure logrotate for MediaMTX logs (auto-configured during install)
# Location: /etc/logrotate.d/mediamtx

# Manual configuration:
sudo tee /etc/logrotate.d/mediamtx << EOF
/var/log/mediamtx*.log {
    daily
    rotate 7
    compress
    delaycompress
    notifempty
    create 0644 root root
    size 100M
}

/var/log/lyrebird/*.log {
    daily
    rotate 3
    compress
    delaycompress
    notifempty
    create 0644 root root
    size 50M
}
EOF
```

---

## Architecture & Design

For system architecture diagrams, see the [System Overview](#system-overview) section.

### Architecture Philosophy

**Why Bash?**

Bash provides universal availability, zero runtime dependencies, and eliminates entire classes of deployment failures. No pip/npm/gem conflicts, no version mismatches, no build processes. Deployment is: copy, chmod +x, run.

**Why No Docker?**

USB device management requires host-level udev rule creation and direct USB subsystem access. Containers add complexity that conflicts with physical USB port mapping (a core feature). Designed for dedicated bare-metal hosts where simple systemd services provide sufficient process isolation.

**Single-Responsibility Principle:**

Each script handles one specific domain:
- Orchestrator: User interface and delegation only
- Installer: MediaMTX installation lifecycle
- Stream Manager: FFmpeg process management
- USB Mapper: Device persistence via udev
- Mic Check: Hardware capability detection
- Updater: Version management
- Diagnostics: System health validation

This modular design prevents duplicate business logic and ensures maintainability.

---


---

## Component Reference

### Quick Reference Table

| Script | Version | Purpose |
|--------|---------|---------|
| lyrebird-orchestrator.sh | 2.1.0 | Unified management interface |
| lyrebird-updater.sh | 1.5.1 | Version management with rollback |
| mediamtx-stream-manager.sh | 1.4.1 | Stream lifecycle management |
| usb-audio-mapper.sh | 1.2.1 | USB device persistence via udev |
| lyrebird-mic-check.sh | 1.0.0 | Hardware capability detection |
| lyrebird-diagnostics.sh | 1.0.2 | System diagnostics |
| install_mediamtx.sh | 2.0.1 | MediaMTX installation/upgrade |

### Orchestrator (lyrebird-orchestrator.sh)

**Purpose:** Interactive menu-driven management interface

**Usage:**
```bash
sudo ./lyrebird-orchestrator.sh
```

**Features:**
- Quick Setup Wizard for initial configuration
- Device capability inspection and configuration generation
- Real-time system status display
- SHA256 integrity checking for external scripts
- EOF/stdin handling for all interactive menus
- Comprehensive logging with automatic rotation

**When to Use:** Initial setup, interactive troubleshooting, log viewing

**Exit Codes:**
- 0: Success
- 1: General error
- 2: Permission denied
- 3: Missing dependencies
- 4: Script not found

---

### Version Manager (lyrebird-updater.sh)

**Purpose:** Safe version management with git-based rollback

**Usage:**
```bash
# Interactive menu
sudo ./lyrebird-updater.sh

# Check status
./lyrebird-updater.sh --status

# List versions
./lyrebird-updater.sh --list
```

**Features:**
- Switch between branches and tags
- Transaction-based updates with automatic rollback
- Systemd service coordination
- Self-update with syntax validation
- Stash management for local changes
- Lock file protection against concurrent execution

**Exit Codes:**
- 0: Success
- 1: General error
- 2: Prerequisites not met
- 3: Not a git repository
- 4: No remote configured
- 5: Permission error
- 7: Locked (another instance running)
- 8: Bad git state
- 9: User aborted

**Requirements:**
- Git 2.0+ installed
- Must run from within git clone (not standalone installation)
- Repository must have remote origin configured
- Recommended to run as normal user (not root)

---

### Stream Manager (mediamtx-stream-manager.sh)

**Purpose:** Automatic stream configuration and lifecycle management

**Usage:**
```bash
# Individual streams
sudo ./mediamtx-stream-manager.sh start

# Multiplex mode
sudo ./mediamtx-stream-manager.sh -m multiplex -f amix start

# Monitor health (cron)
sudo ./mediamtx-stream-manager.sh monitor

# Check status
sudo ./mediamtx-stream-manager.sh status

# View configuration
sudo ./mediamtx-stream-manager.sh config

# Install systemd service
sudo ./mediamtx-stream-manager.sh install
```

**Configuration:** `/etc/mediamtx/audio-devices.conf`

**Exit Codes:**
- 0: Success
- 1: General error
- 2: Critical resource state (triggers restart)
- 3: Missing dependencies
- 4: Configuration error
- 5: Lock acquisition failed
- 6: No USB devices found
- 7: MediaMTX not running
- 10: Stream monitoring degraded

**Features:**
- Individual or multiplex streaming modes
- Automatic health monitoring and restart
- FFmpeg log rotation
- Dual-lookup config system (friendly names and full device IDs)
- Wrapper-based process supervision with exponential backoff
- Lock-based concurrency control
- CPU and file descriptor monitoring

**Streaming Modes:**

**Individual Mode** (default):
```bash
sudo ./mediamtx-stream-manager.sh start
# Creates: rtsp://host:8554/device1, rtsp://host:8554/device2, etc.
```

**Multiplex Mode with Audio Mixing**:
```bash
sudo ./mediamtx-stream-manager.sh -m multiplex -f amix start
# Creates: rtsp://host:8554/all_mics (mixed audio)
```

**Multiplex Mode with Channel Separation**:
```bash
sudo ./mediamtx-stream-manager.sh -m multiplex -f amerge start
# Creates: rtsp://host:8554/all_mics (separate channels)
```

### Systemd Service Installation (Critical for Long-Term Deployments)

**WARNING - IMPORTANT:** For production deployments (continuous monitoring, bird song recording, 24/7 operation), you MUST install the stream manager as a systemd service rather than running the script directly.

**Why systemd is essential:**

1. **Automatic Startup on Boot**
   - Direct script execution: Streams stop when system reboots (data loss)
   - Systemd service: Automatically starts streams after every reboot

2. **Automatic Recovery from Crashes**
   - Direct script execution: If process dies, streams remain down until manual restart
   - Systemd service: Automatically restarts failed streams with configured delays

3. **Process Supervision**
   - Direct script execution: No monitoring of process health
   - Systemd service: Continuous health monitoring, resource limits, automatic recovery

4. **Scheduled Health Monitoring**
   - Systemd service includes automatic cron job installation for periodic health checks
   - Detects and recovers from degraded states (e.g., FFmpeg process accumulation)

5. **System Integration**
   - Proper logging to journald
   - Integration with system shutdown/restart procedures
   - Resource limits and security hardening
   - Graceful termination of child processes

**Installation:**
```bash
# Install as systemd service (one-time setup)
sudo ./mediamtx-stream-manager.sh install

# Enable automatic startup on boot
sudo systemctl enable mediamtx-audio

# Start the service
sudo systemctl start mediamtx-audio

# Verify service is running
sudo systemctl status mediamtx-audio
```

**Service Management:**
```bash
# View live logs
sudo journalctl -u mediamtx-audio -f

# Restart service (apply configuration changes)
sudo systemctl restart mediamtx-audio

# Stop service
sudo systemctl stop mediamtx-audio

# Disable automatic startup
sudo systemctl disable mediamtx-audio
```

**Cron Monitoring:**
The systemd installation automatically creates a cron job at `/etc/cron.d/mediamtx-monitor` that runs health checks every 5 minutes, ensuring continuous operation.

**When direct script execution is acceptable:**
- One-time testing
- Development and debugging
- Short-term manual recording sessions
- Troubleshooting with immediate control

**For all other use cases (especially bird song recording or continuous monitoring), systemd service installation is required.**

---

### USB Audio Mapper (usb-audio-mapper.sh)

**Purpose:** Create persistent udev rules for USB audio devices

**Usage:**
```bash
# Interactive mode
sudo ./usb-audio-mapper.sh

# Non-interactive
sudo ./usb-audio-mapper.sh -n -d "Device" -v XXXX -p YYYY -f friendly-name

# Test detection
sudo ./usb-audio-mapper.sh --test
```

**Output:** `/etc/udev/rules.d/99-usb-soundcards.rules`

**Options:**
- `-i, --interactive`: Run in interactive mode (default)
- `-n, --non-interactive`: Run in non-interactive mode
- `-d, --device <name>`: Device name for logging
- `-v, --vendor <id>`: Vendor ID (4-digit hex)
- `-p, --product <id>`: Product ID (4-digit hex)
- `-u, --usb-port <path>`: USB port path (optional)
- `-f, --friendly <name>`: Friendly device name
- `-t, --test`: Test USB port detection
- `-D, --debug`: Enable debug output

**Features:**
- Physical USB port mapping
- Platform ID path support for complex topologies
- Handles multiple identical devices
- Interactive device selection wizard
- Non-interactive mode for automation
- Backwards compatibility (no serial number suffixes)

**Generated Files:**
- `/etc/udev/rules.d/99-usb-soundcards.rules`: udev rules
- `/dev/snd/by-usb-port/Device_N`: Device symlinks (post-reboot)

---

### Capability Checker (lyrebird-mic-check.sh)

**Purpose:** Detect hardware capabilities and generate configuration

**Usage:**
```bash
# List devices
./lyrebird-mic-check.sh

# Show specific device
./lyrebird-mic-check.sh 0

# Generate config
sudo ./lyrebird-mic-check.sh -g --quality=normal

# Validate config
sudo ./lyrebird-mic-check.sh -V

# JSON output
./lyrebird-mic-check.sh --json

# Restore from backup
sudo ./lyrebird-mic-check.sh --restore
```

**Quality Tiers:**
- `low`: 16kHz sample rate, 64kbps bitrate (speech/monitoring)
- `normal`: 48kHz sample rate, 128kbps bitrate (default, balanced)
- `high`: 48kHz+ sample rate, 256kbps+ bitrate (music/high-quality)

**Features:**
- Non-invasive detection via `/proc/asound`
- Device busy detection without opening hardware
- Automatic backup and restore
- JSON output support
- USB audio adapter chip detection with warnings
- Comprehensive capability reporting (formats, sample rates, channels)
- Configuration validation against hardware capabilities

**Technical Approach:**
- Uses ALSA proc filesystem (`/proc/asound`) for capability enumeration
- Parses stream* files for hardware parameter specifications
- Checks hw_params for current device state (busy detection)
- Validates USB devices via usbid files
- Derives bit depths from ALSA format specifications

**Important Note - USB Audio Adapter Limitations:**
For USB audio adapters with 3.5mm inputs, detected capabilities reflect the USB chip, NOT the microphone connected to the analog input. Always verify:
- Microphone is physically connected to 3.5mm jack
- Correct input type selected (mic vs. line level)
- Channel configuration matches actual microphone (mono mic on stereo jack)
- Test recorded audio quality after configuration

---

### Diagnostics (lyrebird-diagnostics.sh)

**Purpose:** Comprehensive system health checks

**Usage:**
```bash
# Quick check
sudo ./lyrebird-diagnostics.sh quick

# Full diagnostics
sudo ./lyrebird-diagnostics.sh full

# Debug mode
sudo ./lyrebird-diagnostics.sh debug
```

**Options:**
- `--config <path>`: Specify alternate MediaMTX config file
- `--timeout <seconds>`: Set command timeout (default: 30)
- `--debug`: Enable verbose debug output
- `--quiet`: Suppress non-error output
- `--no-color`: Disable color output

**Exit Codes:**
- 0: All checks passed
- 1: Warnings detected
- 2: Failures detected
- 127: Prerequisites missing

**Features:**
- 20+ diagnostic checks
- Three diagnostic modes (quick/full/debug)
- Resource constraint detection
- Process stability analysis
- Audio subsystem conflict detection
- Actionable error reporting
- GitHub issue submission guidance

**Check Categories:**
- System information (OS, kernel, uptime)
- Required utilities (ffmpeg, arecord, jq)
- USB audio devices (detection, ALSA status)
- MediaMTX installation (binary, config, service)
- Stream status (active streams, FFmpeg processes)
- RTSP connectivity (port availability, connection testing)
- System resources (CPU, memory, file descriptors)
- Log analysis (error detection, recent issues)
- Time synchronization (NTP/Chrony status)

---

### MediaMTX Installer (install_mediamtx.sh)

**Purpose:** Install/update MediaMTX with rollback capability

**Usage:**
```bash
# Install latest version
sudo ./install_mediamtx.sh install

# Install specific version
sudo ./install_mediamtx.sh -V v1.15.0 install

# Update existing installation
sudo ./install_mediamtx.sh update

# Check status
./install_mediamtx.sh status

# Verify installation
sudo ./install_mediamtx.sh verify

# Uninstall
sudo ./install_mediamtx.sh uninstall
```

**Options:**
- `-V <version>`: Install specific MediaMTX version
- `-p <prefix>`: Custom installation prefix (default: /usr/local)
- `-c <config>`: Load configuration from file
- `-f, --force`: Force installation and skip verification
- `-n, --dry-run`: Show what would be done without making changes
- `-q, --quiet`: Suppress non-error output
- `-v, --verbose`: Enable debug output
- `--no-service`: Skip systemd service creation

**Features:**
- Platform-aware installation (Linux/Darwin/FreeBSD, x86_64/ARM64/ARMv7/ARMv6)
- Automatic platform detection
- GitHub release fetching with fallback parsers
- SHA256 checksum verification
- Atomic updates with automatic rollback
- Built-in upgrade support for MediaMTX 1.15.0+
- Systemd service creation and management
- Configuration file generation
- Service user creation
- Dry-run mode for testing

---

## Advanced Topics

### Custom Integration

**Automation Example:**
```bash
#!/bin/bash
# Auto-restart on USB disconnect

while true; do
    if ! ./mediamtx-stream-manager.sh status | grep -q "running"; then
        echo "Streams down, restarting..."
        sudo ./mediamtx-stream-manager.sh restart
    fi
    sleep 30
done
```

**API Integration:**
```bash
# Check MediaMTX API
curl http://localhost:9997/v3/paths/list

# Stream statistics
curl http://localhost:9997/v3/paths/get/device-name

# Programmatic stream control
curl -X POST http://localhost:9997/v3/config/paths/patch \
  -H "Content-Type: application/json" \
  -d '{"device-name": {"source": "publisher"}}'
```

### Custom Audio Configuration

Edit device configuration:
```bash
sudo nano /etc/mediamtx/audio-devices.conf
```

Format: Device-specific settings override defaults

After editing, restart streams:
```bash
sudo ./mediamtx-stream-manager.sh restart
```

### MediaMTX Configuration

Edit main configuration:
```bash
sudo nano /etc/mediamtx/mediamtx.yml
```

Validate configuration:
```bash
/usr/local/bin/mediamtx --check /etc/mediamtx/mediamtx.yml
```

Apply changes:
```bash
sudo ./mediamtx-stream-manager.sh restart
```

### Backup and Restore

```bash
# Backup configuration
sudo tar -czf lyrebird-backup-$(date +%Y%m%d).tar.gz \
  /etc/mediamtx/ \
  /etc/udev/rules.d/99-usb-soundcards.rules \
  /var/lib/mediamtx/

# Restore from backup
sudo tar -xzf lyrebird-backup-20250101.tar.gz -C /
sudo udevadm control --reload-rules
sudo udevadm trigger
sudo ./mediamtx-stream-manager.sh restart
```

### Debug Mode

Enable debug output for all scripts:
```bash
export DEBUG=1

# Now run any command
sudo ./mediamtx-stream-manager.sh status
sudo ./usb-audio-mapper.sh --test
```

---


## Uninstallation & Cleanup

### Complete Removal

To completely remove LyreBirdAudio and all components:

**1. Stop all streams and services:**
```bash
# Stop streaming service
sudo ./mediamtx-stream-manager.sh stop

# Stop systemd service if enabled
sudo systemctl stop mediamtx-audio
sudo systemctl disable mediamtx-audio
```

**2. Uninstall MediaMTX:**
```bash
# Uninstall MediaMTX server
sudo ./install_mediamtx.sh uninstall

# This removes:
# - /usr/local/bin/mediamtx binary
# - /etc/systemd/system/mediamtx.service (if using native MediaMTX service)
# - Configuration files (with confirmation unless --force)
```

**3. Remove systemd service and cron jobs:**
```bash
# Remove audio streaming service
sudo systemctl stop mediamtx-audio
sudo systemctl disable mediamtx-audio
sudo rm -f /etc/systemd/system/mediamtx-audio.service
sudo systemctl daemon-reload

# Remove monitoring cron job
sudo rm -f /etc/cron.d/mediamtx-monitor
```

**4. Remove USB device mappings:**
```bash
# Remove udev rules
sudo rm -f /etc/udev/rules.d/99-usb-soundcards.rules

# Reload udev rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

**5. Remove configuration files:**
```bash
# Remove MediaMTX configuration
sudo rm -rf /etc/mediamtx/

# Remove configuration backup directory (if exists)
sudo rm -rf /etc/mediamtx.backup.*
```

**6. Remove state and runtime files:**
```bash
# Remove PID and lock files
sudo rm -f /run/mediamtx-audio.pid
sudo rm -f /run/mediamtx-audio.lock
sudo rm -f /run/mediamtx-monitor.lock
sudo rm -f /run/mediamtx-audio.restart
sudo rm -f /run/mediamtx-audio.cleanup

# Remove FFmpeg state directory
sudo rm -rf /var/lib/mediamtx-ffmpeg/

# Remove MediaMTX state directory (if exists)
sudo rm -rf /var/lib/mediamtx/
```

**7. Remove log files:**
```bash
# Remove logs
sudo rm -f /var/log/mediamtx.out
sudo rm -f /var/log/mediamtx-stream-manager.log
sudo rm -rf /var/log/lyrebird/

# Remove logrotate configuration
sudo rm -f /etc/logrotate.d/mediamtx
```

**8. Remove script directory:**
```bash
# Navigate out of the directory first
cd ~

# Remove the cloned repository
rm -rf /path/to/LyreBirdAudio
```

### Partial Cleanup

**Reset to clean state (keep MediaMTX):**
```bash
# Stop streams but keep MediaMTX installed
sudo ./mediamtx-stream-manager.sh stop

# Remove only stream-related files
sudo rm -rf /var/lib/mediamtx-ffmpeg/
sudo rm -f /run/mediamtx-audio.*
sudo rm -f /var/log/mediamtx-stream-manager.log
```

**Remove only device mappings:**
```bash
# Remove udev rules only
sudo rm -f /etc/udev/rules.d/99-usb-soundcards.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

**Reset configuration only:**
```bash
# Backup current configuration
sudo cp /etc/mediamtx/audio-devices.conf /etc/mediamtx/audio-devices.conf.backup

# Remove configuration
sudo rm -f /etc/mediamtx/audio-devices.conf

# Regenerate fresh configuration
sudo ./lyrebird-mic-check.sh -g
```

### Verification After Removal

Verify complete removal:
```bash
# Check for remaining processes
ps aux | grep -E "mediamtx|ffmpeg" | grep -v grep

# Check for remaining services
systemctl list-units | grep mediamtx

# Check for remaining configuration
ls -la /etc/mediamtx/ 2>/dev/null || echo "Config directory removed"

# Check for remaining udev rules
ls -la /etc/udev/rules.d/99-usb-soundcards.rules 2>/dev/null || echo "Udev rules removed"

# Check for remaining state files
ls -la /var/lib/mediamtx-ffmpeg/ 2>/dev/null || echo "State directory removed"
```

### Troubleshooting Uninstallation

**If processes won't stop:**
```bash
# Force kill all related processes
sudo pkill -9 mediamtx
sudo pkill -9 ffmpeg

# Remove stale PID files
sudo rm -f /run/mediamtx*.pid
```

**If service won't disable:**
```bash
# Force remove service files
sudo systemctl stop mediamtx-audio
sudo rm -f /etc/systemd/system/mediamtx-audio.service
sudo systemctl daemon-reload
sudo systemctl reset-failed
```

**If udev rules persist:**
```bash
# Force reload udev
sudo udevadm control --reload-rules
sudo udevadm trigger
sudo reboot  # If still not working
```

---

## Development & Contributing

### Code Standards

- Bash 4.0+ required (associative arrays)
- Pass `shellcheck` with minimal suppressions
- Use `set -euo pipefail` for strict error handling
- Document complex logic with comments
- Implement proper signal handlers
- Validate all user inputs
- Use absolute paths for system commands

### Testing Requirements

Test on:
- Fresh installation
- Upgrade from previous version
- Multiple USB device configurations
- Both Raspberry Pi and x86_64

**Validation:**
- [ ] `bash -n script.sh` (syntax check)
- [ ] `shellcheck script.sh` (linting)
- [ ] Backward compatibility maintained
- [ ] Documentation updated
- [ ] Exit codes documented

### Development Setup

```bash
# Enable debug mode
export DEBUG=1

# Run shellcheck on all scripts
for script in *.sh; do
    echo "Checking $script..."
    shellcheck "$script"
done

# Test syntax
for script in *.sh; do
    bash -n "$script" || echo "$script has syntax errors"
done

# Make scripts executable
chmod +x *.sh
```

### Code Style Guidelines

- Use 4 spaces for indentation (no tabs)
- Maximum line length: 100 characters
- Function names: lowercase with underscores
- Variables: UPPERCASE for constants, lowercase for local
- Always quote variables: `"${variable}"`
- Use `readonly` for constants
- Prefer `[[ ]]` over `[ ]` for tests
- Use `local` for function-scoped variables
- Add comments for complex logic

### Contribution Workflow

1. **Fork the repository**
   ```bash
   git clone https://github.com/YOUR_USERNAME/LyreBirdAudio.git
   cd LyreBirdAudio
   ```

2. **Create a feature branch**
   ```bash
   git checkout -b feature/improvement
   ```

3. **Make your changes following standards**
   - All scripts must pass `bash -n` syntax check
   - All scripts must pass `shellcheck` with no errors
   - Use comprehensive error handling with try/catch patterns
   - Add debug output for troubleshooting
   - Update relevant documentation
   - Follow the single-responsibility principle
   - Maintain backwards compatibility where possible

4. **Test thoroughly on target platforms**
   - Ubuntu 20.04+
   - Debian 11+
   - Raspberry Pi OS (if applicable)
   - Test with multiple USB devices
   - Verify all commands and menu options

5. **Submit a pull request**
   - Provide clear description of changes
   - Reference any related issues
   - Include test results
   - Update documentation as needed

### Submitting Issues

Include:
1. System info (`cat /etc/os-release`, `uname -a`)
2. Script versions (from orchestrator menu)
3. Diagnostics output (`./lyrebird-diagnostics.sh full`)
4. Relevant logs (last 50 lines showing error)
5. Hardware info (`lsusb`, `./lyrebird-mic-check.sh`)

**GitHub:** https://github.com/tomtom215/LyreBirdAudio/issues

---

## License & Credits

**License:** Apache 2.0

Copyright 2024 LyreBirdAudio Contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

### Original Inspiration

This project was inspired by [cberge908's gist](https://gist.github.com/cberge908/ab7ddc1ac46fd63bb6935cd1f4341112) which provided the foundational concept for USB audio device streaming with MediaMTX. LyreBirdAudio extends this concept into a production-ready system with comprehensive error handling, persistent device management, and professional-grade reliability.

**Author:** Tom F (tomtom215)  
**GitHub:** https://github.com/tomtom215/LyreBirdAudio

**Acknowledgments:** Inspired by cberge908's original MediaMTX launcher script. The codebase has been completely rewritten for production reliability, but the original concept provided the foundation.

### Dependencies

- **[MediaMTX](https://github.com/bluenviron/mediamtx)** - High-performance real-time media server by bluenviron
- **[FFmpeg](https://ffmpeg.org/)** - Complete multimedia framework
- **Linux kernel udev** - Device management
- **ALSA Project** - Linux audio subsystem

### Contributors

Special thanks to all contributors who have helped improve LyreBirdAudio.

---

**Project Links:**
- GitHub: https://github.com/tomtom215/LyreBirdAudio
- Issues: https://github.com/tomtom215/LyreBirdAudio/issues
- Discussions: https://github.com/tomtom215/LyreBirdAudio/discussions

**MediaMTX:**
- GitHub: https://github.com/bluenviron/mediamtx
- Documentation: https://github.com/bluenviron/mediamtx#documentation

---

*LyreBirdAudio - Production-hardened RTSP audio streaming for 24/7 reliability*

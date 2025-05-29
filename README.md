# MediaMTX RTSP Audio Streaming Platform

# Currently this is not in a working state, please do not expect it to work until this meesage has been removed. 

A comprehensive production-grade platform for setting up and managing robust RTSP audio streaming with MediaMTX. This project includes automated installation, configuration, monitoring, and recovery components designed for reliability in mission-critical environments.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
  - [All-in-One Installation (Recommended)](#all-in-one-installation-recommended)
  - [Manual Component Installation](#manual-component-installation)
  - [Advanced Installation Options](#advanced-installation-options)
- [Configuration](#configuration)
  - [Global Configuration](#global-configuration)
  - [Device-Specific Configuration](#device-specific-configuration)
  - [Device Mapping and Blacklisting](#device-mapping-and-blacklisting)
  - [Recovery Configuration](#recovery-configuration)
- [Usage](#usage)
  - [Service Management](#service-management)
  - [Stream Management](#stream-management)
  - [Status Monitoring](#status-monitoring)
  - [Accessing Streams](#accessing-streams)
- [Monitoring System](#monitoring-system)
  - [Resource Monitoring](#resource-monitoring)
  - [Recovery Strategies](#recovery-strategies)
- [Logging](#logging)
  - [Log Locations](#log-locations)
  - [Log Rotation](#log-rotation)
  - [Real-time Monitoring](#real-time-monitoring)
- [Troubleshooting](#troubleshooting)
  - [Common Issues](#common-issues)
  - [Diagnostic Tools](#diagnostic-tools)
  - [Recovery Steps](#recovery-steps)
- [Uninstallation](#uninstallation)
- [Advanced Topics](#advanced-topics)
  - [Audio Processing](#audio-processing)
  - [Performance Tuning](#performance-tuning)
  - [Security Considerations](#security-considerations)
- [Technical Details](#technical-details)
  - [Version Management](#version-management)
  - [Failover Mechanisms](#failover-mechanisms)
  - [File Operations](#file-operations)
- [License and Contributors](#license-and-contributors)

## Overview

This platform provides a complete solution for setting up audio streaming from various capture devices (USB microphones, audio interfaces, etc.) to RTSP endpoints. It handles the complexities of audio device management, streaming configuration, and system monitoring with production-grade reliability features.

The platform is designed for:
- Multi-room audio streaming installations
- Conference room audio distribution
- Network audio monitoring systems
- Studio setups with multiple audio sources
- Broadcast monitoring and ingest systems

## Architecture

The platform consists of the following core components:

1. **MediaMTX Installer** (`install_mediamtx.sh`)
   - Secure and robust installation of the MediaMTX RTSP server
   - Architecture detection and checksum verification
   - Custom port configuration
   - Systemd integration

2. **Audio RTSP Setup** (`setup_audio_rtsp.sh`)
   - Audio streaming service configuration
   - Log rotation setup
   - Helper scripts creation

3. **Stream Management** (`startmic.sh`)
   - Audio device detection and stream configuration
   - Device mapping for consistent stream naming
   - Stream monitoring and auto-recovery
   - Per-device configuration options

4. **System Monitoring** (`mediamtx-monitor.sh`)
   - Resource usage monitoring (CPU, memory, file descriptors)
   - Four-level progressive recovery system
   - Trend analysis for predictive maintenance
   - System-wide health checks

5. **Version Checker** (`MediaMTX-Version-Checker.sh`)
   - Version availability validation
   - Checksum verification
   - Architecture compatibility checking

6. **All-in-One Installer** (`mediamtx-rtsp-audio-installer.sh`)
   - Single script to manage all aspects of installation
   - Interactive menus for configuration
   - Update, reinstall, and uninstall capabilities
   - Troubleshooting and log management

## Features

- **Secure Installation**: Cryptographic verification of downloaded binaries
- **Automatic Device Discovery**: Detects all connected audio capture devices 
- **Persistent Device Naming**: Maintains consistent stream names across reboots
- **Granular Configuration**: Per-device audio settings (channels, bitrate, codec, etc.)
- **Production-Grade Reliability**: Proper error handling, atomic operations, and resource monitoring
- **Self-Healing**: Multi-level recovery system with automatic service restoration
- **Comprehensive Logging**: Detailed logs with rotation and retention policies
- **Device Blacklisting**: Exclude specific devices from streaming
- **Advanced Resource Monitoring**: Tracks CPU, memory, and network with trend analysis
- **Audio Processing**: Support for custom FFmpeg filters per device
- **Deadman Switch Protection**: Prevents excessive reboot cycles
- **Disk Space Monitoring**: Emergency cleanup for low disk space conditions

## Requirements

### System Requirements

- **Operating System**: Linux (Debian/Ubuntu/Raspberry Pi OS recommended)
- **Processor**: 1GHz or faster (ARM or x86_64)
- **Memory**: 512MB minimum, 1GB+ recommended
- **Storage**: 100MB free space minimum
- **Network**: Ethernet or WiFi connection

### Software Requirements

- **Base System**: Systemd-based Linux distribution
- **Required Packages**:
  - bash (4.0+)
  - systemd
  - ffmpeg (4.0+)
  - curl or wget
  - Optional but recommended: jq

### Hardware Requirements

- **Audio Devices**: USB audio interfaces, microphones or capture cards with ALSA support
- For Raspberry Pi installations:
  - Raspberry Pi 3 or newer recommended
  - Proper USB power supply (2.5A+ recommended)

### Preparation

Before installation:
1. Ensure system is up to date: `sudo apt update && sudo apt upgrade -y`
2. Install required packages: `sudo apt install ffmpeg curl jq`
3. Expand filesystem if on Raspberry Pi: `sudo raspi-config` → Advanced Options → Expand Filesystem

## Installation

This platform provides two installation methods:

1. **All-in-One Installer**: A single script that handles the complete installation process with interactive menus
2. **Manual Installation**: Step-by-step installation of individual components for more control

### All-in-One Installation (Recommended)

> **⚠️ SECURITY WARNING**: Always review scripts before downloading and running them with sudo privileges. The installation scripts require root access to configure system services and modify system directories.

The simplest way to install the MediaMTX RTSP Audio Platform is using the all-in-one installer script:

```bash
# Download the installer script
wget https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/mediamtx-rtsp-audio-installer.sh

# Make it executable
chmod +x mediamtx-rtsp-audio-installer.sh

# Run the installer
sudo ./mediamtx-rtsp-audio-installer.sh
```

This will guide you through an interactive installation process, handling all the component setup automatically.

For non-interactive installation with default settings:
```bash
sudo ./mediamtx-rtsp-audio-installer.sh install -y -q
```

### Manual Component Installation

If you prefer to install components individually or want more control over the installation process:

1. First, download all necessary scripts:
   ```bash
   # Create a directory for the scripts
   mkdir -p mediamtx-rtsp-setup && cd mediamtx-rtsp-setup
   
   # Download all required scripts
   wget --progress=bar:force:noscroll \
     https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/install_mediamtx.sh \
     https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/setup_audio_rtsp.sh \
     https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/startmic.sh \
     https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/setup-monitor-script.sh \
     https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/mediamtx-monitor.sh
   
   # Make all scripts executable
   chmod +x *.sh
   ```

   Alternatively, if you prefer git:
   ```bash
   git clone https://github.com/tomtom215/mediamtx-rtsp-setup.git
   cd mediamtx-rtsp-setup
   chmod +x *.sh
   ```

2. Install each component in sequence:
   ```bash
   # Step 1: Install MediaMTX RTSP server
   sudo ./install_mediamtx.sh
   
   # Step 2: Set up audio RTSP streaming
   sudo ./setup_audio_rtsp.sh
   
   # Step 3: Set up monitoring system (recommended)
   sudo ./setup-monitor-script.sh
   ```

3. Verify installation:
   ```bash
   # Check streaming status
   sudo check-audio-rtsp.sh
   
   # Check monitoring system
   sudo check-mediamtx-monitor.sh
   ```

### Advanced Installation Options

For customized installations, the MediaMTX installer supports various options:

```bash
sudo ./install_mediamtx.sh [OPTIONS]
```

Available options:
- `-v, --version VERSION` - Specify MediaMTX version (default: v1.12.2)
- `-p, --rtsp-port PORT` - Specify RTSP port (default: 18554)
- `--rtmp-port PORT` - Specify RTMP port (default: 11935)
- `--hls-port PORT` - Specify HLS port (default: 18888)
- `--webrtc-port PORT` - Specify WebRTC port (default: 18889)
- `--metrics-port PORT` - Specify metrics port (default: 19999)
- And other options for checksum verification and installation modes

Examples:
```bash
# Install latest version with custom RTSP port
sudo ./install_mediamtx.sh --version latest --rtsp-port 8554

# Only update configuration
sudo ./install_mediamtx.sh --config-only --rtsp-port 8554
```

The all-in-one installer also supports various commands and options:

```bash
sudo ./mediamtx-rtsp-audio-installer.sh [COMMAND] [OPTIONS]
```

Commands:
- `install` - Install MediaMTX and audio streaming platform
- `uninstall` - Remove all installed components
- `update` - Update to the latest version while preserving config
- `reinstall` - Completely remove and reinstall
- `status` - Show status of all components
- `troubleshoot` - Run diagnostics and fix common issues
- `logs` - View or manage logs

Options:
- `-v, --version VERSION` - Specify MediaMTX version
- `-p, --rtsp-port PORT` - Specify RTSP port
- `-d, --debug` - Enable debug mode
- `-q, --quiet` - Minimal output
- `-y, --yes` - Answer yes to all prompts
- `-f, --force` - Force operation
- `-h, --help` - Show help message

## Configuration

The platform uses a hierarchy of configuration files for different aspects of the system.

### Global Configuration

The main configuration file is located at `/etc/audio-rtsp/config` and contains system-wide settings:

```
# Audio RTSP Streaming Service Configuration
RTSP_PORT=18554
RESTART_DELAY=10
MAX_RESTART_ATTEMPTS=5
LOG_LEVEL=info
LOG_DIR=/var/log/audio-rtsp
LOG_ROTATE_DAYS=7

# Audio Settings
AUDIO_BITRATE=192k
AUDIO_CODEC=libmp3lame
AUDIO_CHANNELS=1
AUDIO_SAMPLE_RATE=44100

# Recovery Settings
CPU_THRESHOLD=80
MEMORY_THRESHOLD=15
MAX_UPTIME=86400
ENABLE_AUTO_REBOOT=false
```

#### Key Configuration Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| RTSP_PORT | Port for RTSP streaming | 18554 |
| RESTART_DELAY | Seconds to wait before restarting failed streams | 10 |
| MAX_RESTART_ATTEMPTS | Maximum number of restart attempts | 5 |
| LOG_LEVEL | Logging level (debug, info, warning, error) | info |
| LOG_ROTATE_DAYS | Number of days to keep logs | 7 |
| AUDIO_BITRATE | Audio bitrate for streams | 192k |
| AUDIO_CODEC | Audio codec for streams | libmp3lame |
| AUDIO_CHANNELS | Number of audio channels | 1 |
| AUDIO_SAMPLE_RATE | Audio sample rate | 44100 |
| CPU_THRESHOLD | CPU usage percentage that triggers restart | 80 |
| MEMORY_THRESHOLD | Memory usage percentage that triggers restart | 15 |
| MAX_UPTIME | Force restart after this many seconds (24h) | 86400 |
| ENABLE_AUTO_REBOOT | Whether to allow system reboot for recovery | false |

### Device-Specific Configuration

Each audio device can have its own configuration file in the `/etc/audio-rtsp/devices/` directory. Files are named after the device's stream name with a `.conf` extension.

Example device configuration (`/etc/audio-rtsp/devices/conference_room_mic.conf`):

```bash
# Device-specific configuration for conference_room_mic

# Custom audio settings - override global configuration
AUDIO_CHANNELS=2                   # Use stereo for this device
AUDIO_SAMPLE_RATE=48000            # Higher sample rate
AUDIO_BITRATE=256k                 # Higher bitrate
AUDIO_CODEC="libmp3lame"           # MP3 codec

# Advanced FFmpeg settings
FFMPEG_ADDITIONAL_OPTS="-af highpass=f=100,lowpass=f=8000,volume=2.0"
```

#### Available Device-Specific Options

| Parameter | Description | Example Values |
|-----------|-------------|---------------|
| AUDIO_CHANNELS | Number of audio channels | 1 (mono), 2 (stereo) |
| AUDIO_SAMPLE_RATE | Sample rate in Hz | 44100, 48000, 96000 |
| AUDIO_BITRATE | Audio encoding bitrate | 128k, 192k, 256k, 320k |
| AUDIO_CODEC | FFmpeg audio codec to use | libmp3lame, aac, libopus, flac |
| FFMPEG_ADDITIONAL_OPTS | Additional FFmpeg parameters | "-af ..." (audio filters) |

#### Audio Processing Examples

You can use the `FFMPEG_ADDITIONAL_OPTS` parameter to apply audio processing using FFmpeg filters:

- **Noise reduction**: `-af highpass=f=200,lowpass=f=3000`
- **Volume boost**: `-af volume=1.5`
- **Compression**: `-af acompressor=threshold=0.05:ratio=4`
- **Normalization**: `-af dynaudnorm`
- **Multiple filters**: `-af highpass=f=100,dynaudnorm,volume=1.2`

Example with detailed compression:
```
FFMPEG_ADDITIONAL_OPTS="-af acompressor=threshold=0.05:ratio=4:attack=200:release=1000:makeup=2"
```

### Device Mapping and Blacklisting

#### Device Map

The device map file (`/etc/audio-rtsp/device_map.conf`) provides persistent naming for audio devices across reboots:

```
# Format: DEVICE_UUID=friendly_name
usb_audio_c13487=conference_room_mic
usb_audio_a98712=reception_desk
usb_audio_046d041e=wireless_lapel_mic
```

This ensures the same device always gets the same stream name, even if the device order changes after a reboot.

#### Device Blacklist

The blacklist file (`/etc/audio-rtsp/device_blacklist.conf`) allows excluding specific devices from being streamed:

```
# Audio Device Blacklist - Add devices you want to exclude from streaming
bcm2835_headpho  # Raspberry Pi onboard audio output (no capture)
HDMI             # Generic HDMI audio output (no capture)
broken_webcam    # Device with issues
```

### Recovery Configuration

The monitoring system has its own configuration parameters in the global config file:

```
# Recovery Thresholds
CPU_THRESHOLD=80
CPU_WARNING_THRESHOLD=70
CPU_SUSTAINED_PERIODS=3
MEMORY_THRESHOLD=15
MEMORY_WARNING_THRESHOLD=12
EMERGENCY_CPU_THRESHOLD=95
EMERGENCY_MEMORY_THRESHOLD=20
FILE_DESCRIPTOR_THRESHOLD=1000
COMBINED_CPU_THRESHOLD=200

# Recovery Settings
MAX_RESTART_ATTEMPTS=5
RESTART_COOLDOWN=300
REBOOT_THRESHOLD=3
ENABLE_AUTO_REBOOT=false
REBOOT_COOLDOWN=1800
MAX_REBOOTS_IN_DAY=5
```

#### Key Recovery Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| CPU_THRESHOLD | CPU usage % that triggers recovery | 80 |
| CPU_SUSTAINED_PERIODS | Number of periods before action | 3 |
| MEMORY_THRESHOLD | Memory usage % that triggers recovery | 15 |
| EMERGENCY_CPU_THRESHOLD | CPU % for immediate recovery | 95 |
| FILE_DESCRIPTOR_THRESHOLD | FD count that triggers recovery | 1000 |
| MAX_RESTART_ATTEMPTS | Max attempts before escalation | 5 |
| RESTART_COOLDOWN | Seconds between restarts | 300 |
| REBOOT_THRESHOLD | Failed recoveries before reboot | 3 |
| ENABLE_AUTO_REBOOT | Whether to allow system reboots | false |
| MAX_REBOOTS_IN_DAY | Maximum allowed reboots in 24 hours | 5 |

## Usage

### Service Management

The platform creates three systemd services that can be managed using standard systemd commands:

#### MediaMTX Service

```bash
# Check service status
sudo systemctl status mediamtx

# Start the service
sudo systemctl start mediamtx

# Stop the service
sudo systemctl stop mediamtx

# Restart the service
sudo systemctl restart mediamtx

# View logs
sudo journalctl -u mediamtx -f
```

#### Audio RTSP Service

```bash
# Check service status
sudo systemctl status audio-rtsp

# Start the service
sudo systemctl start audio-rtsp

# Stop the service
sudo systemctl stop audio-rtsp

# Restart the service
sudo systemctl restart audio-rtsp

# View logs
sudo journalctl -u audio-rtsp -f
```

#### Monitoring Service

```bash
# Check monitoring service status
sudo systemctl status mediamtx-monitor

# Start the monitoring service
sudo systemctl start mediamtx-monitor

# Stop the monitoring service
sudo systemctl stop mediamtx-monitor

# View monitoring logs
sudo journalctl -u mediamtx-monitor -f
```

### Stream Management

#### Configuring Streams

To edit the global configuration:
```bash
sudo nano /etc/audio-rtsp/config
```

Or use the interactive configuration editor:
```bash
sudo configure-audio-rtsp.sh
```

To configure a specific device:
```bash
sudo nano /etc/audio-rtsp/devices/device_name.conf
```

To edit device mapping (for persistent naming):
```bash
sudo nano /etc/audio-rtsp/device_map.conf
```

To edit device blacklist:
```bash
sudo nano /etc/audio-rtsp/device_blacklist.conf
```

After making configuration changes, restart the audio-rtsp service:
```bash
sudo systemctl restart audio-rtsp
```

### Status Monitoring

#### Audio RTSP Status

Check the status of your audio streams:
```bash
sudo check-audio-rtsp.sh
```

This shows:
- Service status and uptime
- Running audio streams with their RTSP URLs
- Available sound cards
- System resource usage
- Recent log entries

#### Monitoring System Status

Check the health of the MediaMTX server and monitoring system:
```bash
sudo check-mediamtx-monitor.sh
```

This shows:
- Monitoring service status
- MediaMTX resource usage (CPU, memory, file descriptors)
- Combined CPU usage (MediaMTX + ffmpeg processes)
- Recent recovery actions
- Performance trends and metrics

### Accessing Streams

Audio streams are available at:
```
rtsp://[SERVER_IP]:18554/[DEVICE_NAME]
```

Where:
- `[SERVER_IP]` is your server's IP address (or `localhost` for local access)
- `[DEVICE_NAME]` is the device name from the device mapping or the automatically generated name

Example:
```
rtsp://192.168.1.100:18554/conference_room_mic
```

#### Stream Access with VLC

Open a stream in VLC:
1. Open VLC
2. Go to Media > Open Network Stream
3. Enter the RTSP URL, e.g., `rtsp://192.168.1.100:18554/conference_room_mic`
4. Click Play

#### Stream Access with FFplay

```bash
ffplay rtsp://192.168.1.100:18554/conference_room_mic
```

#### Testing with FFmpeg

To test streaming to your RTSP server:
```bash
ffmpeg -f lavfi -i sine=frequency=440:sample_rate=44100 -f rtsp rtsp://localhost:18554/test_tone
```

## Monitoring System

### Resource Monitoring

The monitoring system tracks several key resources:

- **CPU Usage**: Both MediaMTX process CPU and combined CPU (MediaMTX + all ffmpeg processes)
- **Memory Usage**: MediaMTX process memory consumption
- **File Descriptors**: Open file handles for detecting resource leaks
- **Process Uptime**: To enforce periodic restarts if needed
- **Network Connectivity**: RTSP port accessibility
- **Disk Space**: Monitors disk space and performs emergency cleanup if needed

These metrics are tracked over time to detect trends and predict potential issues before they cause service interruptions.

### Recovery Strategies

The system employs a progressive recovery approach with four levels:

#### Level 1: Basic Restart

- Gentle systemd-based restart
- Minimal service disruption
- Used for first recovery attempt

#### Level 2: Thorough Restart with Cleanup

- Stops related processes
- Cleans up resources
- Performs more thorough service restart
- Used after Level 1 fails

#### Level 3: Aggressive Recovery

- Force kills problematic processes
- Cleans shared memory and socket files
- Performs deep resource cleanup
- Restarts full service chain
- Used when levels 1-2 fail

#### Level 4: System Reboot (If Enabled)

- Only triggered after multiple Level 3 failures
- Makes one final recovery attempt
- Initiates system reboot if all else fails
- Requires `ENABLE_AUTO_REBOOT=true` in config
- Protected by deadman switch to prevent reboot loops

## Logging

### Log Locations

The platform maintains several log files for different components:

```
# Audio streaming logs
/var/log/audio-rtsp/audio-streams.log    # Main streaming log
/var/log/audio-rtsp/service.log          # Service operation log
/var/log/audio-rtsp/service-error.log    # Error log

# MediaMTX logs
/var/log/mediamtx/mediamtx.log           # MediaMTX server log

# Monitoring system logs
/var/log/audio-rtsp/mediamtx-monitor.log      # Main monitor log
/var/log/audio-rtsp/recovery-actions.log      # Recovery action log
/var/log/audio-rtsp/state/                    # System state information
```

### Log Rotation

Logs are automatically rotated to prevent disk space issues:

- Default rotation period: 7 days (configurable)
- Compression of rotated logs
- Service restart after rotation to ensure proper file handles

To customize log rotation settings:
```bash
sudo nano /etc/logrotate.d/audio-rtsp
```

### Real-time Monitoring

```bash
# Monitor audio streaming logs
sudo tail -f /var/log/audio-rtsp/audio-streams.log

# Monitor MediaMTX server logs
sudo tail -f /var/log/mediamtx/mediamtx.log

# Monitor recovery actions
sudo tail -f /var/log/audio-rtsp/recovery-actions.log

# Follow all logs in real-time
sudo journalctl -f -u mediamtx -u audio-rtsp -u mediamtx-monitor
```

## Troubleshooting

### Common Issues

#### No Streams Appear

1. Check if audio devices are detected:
   ```bash
   arecord -l
   ```

2. Verify MediaMTX is running:
   ```bash
   systemctl status mediamtx
   ```

3. Check port availability:
   ```bash
   sudo ss -tuln | grep 18554
   ```

4. Check logs for errors:
   ```bash
   sudo tail -f /var/log/audio-rtsp/audio-streams.log
   ```

#### Streams Disconnect or Audio Quality Issues

1. Check audio levels:
   ```bash
   alsamixer     # Use F6 to select the right card
   ```

2. Verify USB power is sufficient (especially on Raspberry Pi)

3. Check CPU usage:
   ```bash
   top
   ```
   High CPU can cause audio glitches

4. Check for specific stream issues:
   ```bash
   sudo grep "device_name" /var/log/audio-rtsp/audio-streams.log
   ```

#### MediaMTX Crashes or High Resource Usage

1. Check monitoring status:
   ```bash
   sudo check-mediamtx-monitor.sh
   ```

2. Review recovery logs:
   ```bash
   sudo cat /var/log/audio-rtsp/recovery-actions.log
   ```

3. Check for resource leaks:
   ```bash
   sudo lsof -p $(pgrep mediamtx) | wc -l
   ```

4. Adjust threshold settings in config if needed.

### Diagnostic Tools

The platform includes several diagnostic tools:

#### All-in-One Troubleshooter

```bash
sudo ./mediamtx-rtsp-audio-installer.sh troubleshoot
```

This interactive tool will:
- Check system status
- Verify services
- Look for common issues
- Offer to fix detected problems

#### Stream Status Check

```bash
sudo check-audio-rtsp.sh
```

This provides comprehensive information about:
- Current streams
- Available audio devices
- Service status
- Recent log entries

#### Monitor Status Check

```bash
sudo check-mediamtx-monitor.sh
```

This shows:
- Monitoring service status
- Resource usage metrics
- Recovery history
- Performance trends

#### Monitor Diagnostic Fix Tool

```bash
sudo mediamtx-monitor-diagnostic-fix.sh
```

This tool:
- Diagnoses issues with the monitoring service
- Fixes common configuration problems
- Creates a simplified monitor script if needed
- Updates service configuration

#### Version Checker

```bash
sudo ./mediamtx-version-checker.sh
```

Verifies:
- Latest available version
- Download URL validity
- Checksum verification
- Architecture compatibility

### Recovery Steps

#### For Audio Streams Not Working

1. Restart the audio streaming service:
   ```bash
   sudo systemctl restart audio-rtsp
   ```

2. If that doesn't work, check devices:
   ```bash
   arecord -l
   ```

3. Verify MediaMTX is running:
   ```bash
   sudo systemctl status mediamtx
   ```

4. Check if device is blacklisted:
   ```bash
   sudo cat /etc/audio-rtsp/device_blacklist.conf
   ```

#### For MediaMTX Issues

1. Check resource usage:
   ```bash
   sudo check-mediamtx-monitor.sh
   ```

2. Force recovery at level 2:
   ```bash
   sudo systemctl restart mediamtx-monitor
   sudo systemctl restart mediamtx
   sudo systemctl restart audio-rtsp
   ```

3. Check logs for specific errors:
   ```bash
   grep ERROR /var/log/audio-rtsp/mediamtx-monitor.log
   ```

4. Use the diagnostic fix tool for monitor issues:
   ```bash
   sudo mediamtx-monitor-diagnostic-fix.sh
   ```

## Uninstallation

### Automated Uninstallation

The platform includes an uninstallation script:

```bash
sudo uninstall-audio-rtsp.sh
```

This interactive script will:
1. Stop and disable all services
2. Remove scripts and configuration
3. Ask if you want to remove log files
4. Clean up systemd service files

Alternatively, use the all-in-one installer:
```bash
sudo ./mediamtx-rtsp-audio-installer.sh uninstall
```

### Manual Uninstallation

If needed, you can manually remove components:

```bash
# Stop and disable services
sudo systemctl stop mediamtx-monitor audio-rtsp mediamtx
sudo systemctl disable mediamtx-monitor audio-rtsp mediamtx

# Remove service files
sudo rm /etc/systemd/system/mediamtx.service
sudo rm /etc/systemd/system/audio-rtsp.service
sudo rm /etc/systemd/system/mediamtx-monitor.service
sudo systemctl daemon-reload

# Remove scripts
sudo rm -f /usr/local/bin/startmic.sh
sudo rm -f /usr/local/bin/check-audio-rtsp.sh
sudo rm -f /usr/local/bin/check-mediamtx-monitor.sh
sudo rm -f /usr/local/bin/uninstall-audio-rtsp.sh
sudo rm -f /usr/local/bin/configure-audio-rtsp.sh
sudo rm -f /usr/local/bin/mediamtx-monitor.sh

# Remove configuration (optional)
sudo rm -rf /etc/audio-rtsp
sudo rm -rf /etc/mediamtx

# Remove binaries (optional)
sudo rm -rf /usr/local/mediamtx

# Remove log files (optional)
sudo rm -rf /var/log/audio-rtsp
sudo rm -rf /var/log/mediamtx

# Remove log rotation configuration
sudo rm -f /etc/logrotate.d/audio-rtsp
```

## Advanced Topics

### Audio Processing

The platform supports advanced audio processing using FFmpeg filters in the device-specific configuration files:

#### Audio Enhancement Example

```bash
# Add to device config file
FFMPEG_ADDITIONAL_OPTS="-af highpass=f=100,lowpass=f=7500,volume=1.5,dynaudnorm"
```

This applies:
1. High-pass filter at 100Hz (removes low rumble)
2. Low-pass filter at 7.5kHz (removes high hiss)
3. Volume boost of 1.5x
4. Dynamic audio normalization

#### Audio Compression Example

```bash
# Add to device config file
FFMPEG_ADDITIONAL_OPTS="-af acompressor=threshold=0.05:ratio=4:attack=200:release=1000:makeup=2"
```

This applies:
1. Threshold of -26dB (0.05)
2. Compression ratio of 4:1
3. 200ms attack time
4. 1000ms release time
5. 2dB makeup gain

#### Noise Reduction Example

```bash
# Add to device config file
FFMPEG_ADDITIONAL_OPTS="-af highpass=f=200,afftdn=nr=10:nf=-25"
```

This applies:
1. High-pass filter at 200Hz
2. FFT-based noise reduction with 10dB reduction and -25dB noise floor

### Performance Tuning

For systems handling multiple audio streams, consider these performance optimizations:

#### CPU Optimization

1. Adjust codec settings for lower CPU usage:
   ```
   AUDIO_CODEC="libmp3lame"  # Generally more efficient than AAC
   AUDIO_BITRATE="128k"      # Lower bitrate reduces CPU load
   ```

2. Reduce sample rate for non-critical audio:
   ```
   AUDIO_SAMPLE_RATE=22050   # Half of CD quality, sufficient for voice
   ```

3. Adjust monitoring thresholds:
   ```
   CPU_THRESHOLD=90          # Allow more CPU headroom
   CPU_SUSTAINED_PERIODS=5   # Wait longer before taking action
   ```

4. Set a maximum number of streams:
   ```
   MAX_STREAMS=16            # Prevent resource exhaustion
   ```

#### Memory Optimization

1. Limit maximum number of streams:
   ```
   MAX_STREAMS=16            # Prevent resource exhaustion
   ```

2. Consider lower bitrates for multiple streams:
   ```
   AUDIO_BITRATE="96k"       # Lower quality but more efficient
   ```

### Security Considerations

The platform includes several security features, but consider these additional measures:

1. **Access Control**: Use firewall rules to restrict RTSP access:
   ```bash
   sudo ufw allow from 192.168.1.0/24 to any port 18554 proto tcp
   ```

2. **Secure Installation**: Always use checksum verification:
   ```bash
   sudo ./install_mediamtx.sh --force-checksum
   ```

3. **RTSP Authentication**: Configure MediaMTX with authentication:
   ```yaml
   # Add to /etc/mediamtx/mediamtx.yml
   paths:
     secure:
       readUser: myuser
       readPass: mypassword
   ```

4. **Service Hardening**: The systemd service already includes security directives:
   - ProtectSystem=full
   - ProtectHome=true
   - PrivateTmp=true
   - NoNewPrivileges=true

## Technical Details

### Version Management

The system implements robust version comparison and management:

- **Semantic Versioning**: Properly parses and compares version numbers (major.minor.patch)
- **Version Checking**: Validates available versions against GitHub releases
- **Upgrade Path**: Handles upgrades, downgrades, and reinstallations correctly
- **Backup Creation**: Automatically creates backups before upgrading

### Failover Mechanisms

Multiple levels of failure detection and recovery are implemented:

1. **Process Monitoring**: Tracks process health and resource usage
2. **Stream Monitoring**: Detects and restarts failed streams
3. **Progressive Recovery**: Escalates through recovery levels as needed
4. **Optional Auto-Reboot**: Can trigger system reboot as last resort
5. **Deadman Switch**: Prevents excessive reboot cycles
6. **Trend Analysis**: Detects gradually increasing resource usage before failure
7. **Disk Space Monitoring**: Emergency cleanup for low disk space conditions

### File Operations

The platform uses production-grade file handling techniques:

- **Atomic Writes**: All critical file operations use atomic write patterns
- **Proper Locking**: File locks to prevent race conditions
- **Temporary Files**: Uses unique temporary files for safer operations
- **State Management**: Persistent state tracking across restarts
- **Safe Configuration Updates**: Maintains backups of all configuration files

## License and Contributors

This software is released under the Apache 2.0 License.

### Contributors

- Main project development and maintenance
- Based on original concept by Cberge908 [GitHub gist](https://gist.github.com/cberge908/ab7ddc1ac46fd63bb6935cd1f4341112)

### Acknowledgments

- [MediaMTX](https://github.com/bluenviron/mediamtx) for the excellent RTSP server
- All testers and users who provided feedback

### Disclaimer

This project is not officially affiliated with the MediaMTX project.

Always review scripts before running them with sudo privileges.

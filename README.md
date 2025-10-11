# LyreBirdAudio

**Version:** v1.1.0  
**License:** Apache 2.0  
**Platform:** Linux (Ubuntu/Debian/Raspberry Pi OS)  
**Core Engine:** MediaMTX v1.15.1 (tested for maximum stability)

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Features](#features)
- [System Requirements](#system-requirements)
- [Installation](#installation)
- [Components](#components)
- [MediaMTX Integration](#mediamtx-integration)
- [Usage](#usage)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [Performance & Optimization](#performance--optimization)
- [Version History](#version-history)
- [Contributing](#contributing)
- [Credits](#credits)
- [License](#license)

## Overview

LyreBirdAudio provides a comprehensive solution for managing multiple USB audio devices on Linux systems with persistent device naming and real-time RTSP streaming capabilities powered by MediaMTX. The project addresses the common problem of USB audio device enumeration changes after system reboots, ensuring consistent and reliable audio streaming infrastructure for professional audio applications.

### Core Technology Stack

- **MediaMTX v1.15.1** - High-performance real-time media server providing RTSP/WebRTC streaming
- **ALSA** - Linux audio subsystem for device access and control
- **udev** - Dynamic device management for persistent naming
- **FFmpeg** - Audio capture and encoding pipeline
- **systemd** - Service management and automation

### Project Motivation

This project was inspired by my desire to listen to birds using some USB microphones and Mini PC's I had lying around. I had first found [cberge908](https://gist.github.com/cberge908/ab7ddc1ac46fd63bb6935cd1f4341112)'s original script for launching MediaMTX but I quickly learned there were a lot more edge cases that needed to be handled in order for it to run reliably 24x7. LyreBird Audio is my solution to those edgecases. 

### Key Problems Solved

1. **Device Enumeration Instability**: USB audio devices receive different ALSA card numbers after reboots
2. **Complex USB Topology Management**: Accurate detection across multi-level USB hub configurations
3. **Stream Continuity**: Zero-downtime MediaMTX updates with automatic stream preservation
4. **Cross-Platform Compatibility**: Works across various Linux distributions without modification
5. **Scalable Streaming**: Simultaneous multi-device RTSP streaming via MediaMTX

## Architecture

### System Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                     Client Applications                     │
│            (VLC, FFplay, OBS, Custom RTSP Clients)          │
└────────────────────┬────────────────────────────────────────┘
                     │ RTSP://host:8554/DeviceName
┌────────────────────▼────────────────────────────────────────┐
│                    MediaMTX v1.15.1                         │
│                  (Real-time Media Server)                   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ • RTSP Server (port 8554)                            │   │
│  │ • RTP/RTCP (ports 8000-8001)                         │   │
│  │ • HTTP API (port 9997)                               │   │
│  │ • WebRTC Support                                     │   │
│  └──────────────────────────────────────────────────────┘   │
└────────────────────┬────────────────────────────────────────┘
                     │ Managed by
┌────────────────────▼────────────────────────────────────────┐
│              Stream Manager / systemd                       │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ • Process lifecycle management                       │   │
│  │ • Automatic stream recovery                          │   │
│  │ • Health monitoring                                  │   │
│  │ • Real-time scheduling                               │   │
│  └──────────────────────────────────────────────────────┘   │
└────────────────────┬────────────────────────────────────────┘
                     │ Captures from
┌────────────────────▼────────────────────────────────────────┐
│                  FFmpeg Audio Pipeline                      │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ • ALSA capture (hw:Device_N)                         │   │
│  │ • Audio encoding (AAC/Opus/PCM)                      │   │
│  │ • RTSP publishing to MediaMTX                        │   │
│  │ • Buffer management                                  │   │
│  └──────────────────────────────────────────────────────┘   │
└────────────────────┬────────────────────────────────────────┘
                     │ Reads from
┌────────────────────▼────────────────────────────────────────┐
│              Persistent Device Layer (udev)                 │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ • /dev/snd/by-usb-port/Device_1 → /dev/snd/pcmC0D0c  │   │
│  │ • /dev/snd/by-usb-port/Device_2 → /dev/snd/pcmC1D0c  │   │
│  │ • Consistent naming across reboots                   │   │
│  └──────────────────────────────────────────────────────┘   │
└────────────────────┬────────────────────────────────────────┘
                     │ Maps
┌────────────────────▼────────────────────────────────────────┐
│               Physical USB Audio Devices                    │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ • USB Port 1-1.4: Audio Interface A                  │   │
│  │ • USB Port 1-1.5: Audio Interface B                  │   │
│  │ • USB Port 2-1.2: USB Microphone                     │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **Device Detection**: USB audio devices are detected via udev and mapped to persistent names
2. **Audio Capture**: FFmpeg captures audio from ALSA devices using persistent names
3. **Stream Publishing**: FFmpeg publishes audio streams to MediaMTX via RTSP
4. **Client Access**: MediaMTX serves streams to multiple concurrent clients
5. **Management**: Stream manager or systemd ensures continuous operation

## Features

### Core Functionality

- **MediaMTX-Powered RTSP Streaming**: Enterprise-grade real-time audio streaming using MediaMTX v1.15.1 (extensively tested for stability)
- **Persistent USB Audio Device Naming**: Maps USB audio devices to consistent names using udev rules based on physical USB port paths
- **Intelligent Management Detection**: Automatically detects and preserves MediaMTX service management mode (systemd/stream-manager/manual)
- **Zero-Downtime Updates**: Stream-aware MediaMTX updates that preserve active audio streams during upgrades
- **Comprehensive Error Handling**: Production-ready exception handling with automatic rollback capabilities
- **Interactive Setup Wizard**: Guided configuration with MediaMTX version selection and system validation

### MediaMTX Capabilities (v1.15.1 Tested)

- **Multi-Protocol Support**: RTSP, RTMP, HLS, WebRTC, and SRT streaming protocols
- **Concurrent Streams**: Handles 8+ simultaneous audio device streams with minimal latency
- **API Management**: RESTful API on port 9997 for dynamic stream control
- **Authentication Support**: Optional stream authentication and access control
- **Recording**: On-demand or continuous recording to disk
- **Metrics & Monitoring**: Prometheus-compatible metrics endpoint
- **Low Latency**: Sub-second latency for real-time audio applications
- **Resource Efficiency**: Minimal CPU/memory footprint even with multiple streams

### Technical Capabilities

- Supports 1-8+ simultaneous USB audio devices per system
- Compatible with complex USB hub topologies (4+ level hierarchies tested)
- Backwards compatible with all previous versions (v1.0.0, v1.0.1)
- Cross-platform hash generation for embedded systems without standard utilities
- Safe base-10 number conversion preventing octal interpretation errors
- Multi-endpoint API health checking across MediaMTX versions (v1.9.x through v1.15.x)
- Automatic codec negotiation (AAC, Opus, PCM)
- Real-time scheduling support (SCHED_FIFO/SCHED_RR) for low-latency operation

## System Requirements

### Minimum Requirements

- **Operating System**: Linux kernel 4.x or higher
- **Distribution**: Ubuntu 20.04+, Debian 11+, Raspberry Pi OS (Bullseye+)
- **Memory**: 512MB RAM (1MB per audio stream typical)
- **Storage**: 500MB for MediaMTX and scripts, 500MB+ for logs
- **Shell**: Bash 4.0 or higher
- **Privileges**: Root or sudo access required
- **Architecture**: x86_64, arm64, armv7 (MediaMTX provides native binaries)
- **Network**: 100Mbps for reliable streaming (1-2Mbps per audio stream)

### Recommended Requirements

- **Memory**: 2GB+ RAM (supports 20+ concurrent streams)
- **Storage**: 2GB+ for logs, recordings, and stream buffers
- **Shell**: Bash 5.0 or higher
- **Network**: Gigabit ethernet for professional deployments
- **CPU**: 2+ cores for optimal MediaMTX performance
- **N100 Mini PC**: Simplest solution. A Raspberry Pi will max out at 2 microphones due to power and USB bandwidth limits.

### Software Dependencies

Required packages (automatically checked during installation):
- `udevadm` - udev management for device persistence
- `curl` or `wget` - downloading MediaMTX releases
- `tar` - MediaMTX archive extraction
- `arecord` - ALSA utilities for audio device testing

Optional packages (enhanced functionality):
- `systemctl` - systemd service management for MediaMTX
- `ffmpeg` - audio capture and stream publishing to MediaMTX
- `jq` - JSON processing for MediaMTX API responses
- `sha256sum` or `md5sum` - hash generation for unique identifiers
- `htop` - monitoring MediaMTX resource usage

### Network Requirements

MediaMTX default ports (configurable):
- **8554/tcp** - RTSP streaming protocol
- **8000/udp** - RTP media transport
- **8001/udp** - RTCP control protocol
- **9997/tcp** - MediaMTX HTTP API
- **8888/tcp** - WebRTC (optional)
- **8889/tcp** - HLS (optional)

## Installation

### MediaMTX Version Compatibility

**Recommended:** MediaMTX v1.15.1 (extensively tested for stability)  
**Supported:** MediaMTX v1.12.0 through v1.15.x  
**API Versions:** Automatically detects v2/v3 API endpoints

### Quick Installation

```bash
# Clone the repository
git clone -b v1.1.0 https://github.com/tomtom215/LyreBirdAudio.git
cd LyreBirdAudio

# Make scripts executable
chmod +x *.sh

# Run the interactive setup wizard (recommended)
# Automatically installs MediaMTX v1.15.1 and configures audio devices
sudo ./lyrebird-wizard.sh
```

### Production Installation

For production environments, we recommend the following installation procedure:

#### Step 1: Install MediaMTX v1.15.1 (Core Streaming Engine)

```bash
# Install MediaMTX v1.15.1 (tested for maximum stability)
sudo ./install_mediamtx.sh install --version v1.15.1

# Verify MediaMTX installation and API connectivity
sudo ./install_mediamtx.sh status

# Expected output:
# MediaMTX Status:
#   Version: v1.15.1
#   Binary: /usr/local/bin/mediamtx
#   Config: /etc/mediamtx/mediamtx.yml
#   Process: ✓ Running (PID: 12345)
#   API: ✓ Responding (v3 API)
#   Uptime: 0d 0h 1m
```

#### Step 2: Map USB Audio Devices

```bash
# List available USB audio devices
sudo ./usb-audio-mapper.sh --list

# Example output:
# Available USB Audio Devices:
# Card 1: USB Audio Device [C-Media Electronics Inc.]
#   - Bus: 001, Device: 005
#   - USB Path: 1-1.4
#   - Current ALSA name: Generic_USB_Audio

# Map devices interactively (creates udev rules)
sudo ./usb-audio-mapper.sh

# Verify device persistence (test mode)
sudo ./usb-audio-mapper.sh --test
```

#### Step 3: Configure MediaMTX Audio Streaming

```bash
# Configure audio devices for MediaMTX streaming
echo "Device_1:hw:Device_1:48000:2" | sudo tee /etc/mediamtx/audio-devices.conf

# Start MediaMTX with stream manager (recommended for audio)
sudo ./mediamtx-stream-manager.sh start

# Verify streams are being published to MediaMTX
sudo ./mediamtx-stream-manager.sh status

# Test RTSP stream from MediaMTX
ffplay rtsp://localhost:8554/Device_1
```

### Docker Installation (Alternative)

For containerized deployments using MediaMTX official Docker image:

```bash
# Create configuration directory
mkdir -p ~/mediamtx-config

# Copy configuration
cp /etc/mediamtx/mediamtx.yml ~/mediamtx-config/

# Run MediaMTX v1.15.1 container
docker run -d \
  --name mediamtx \
  --restart unless-stopped \
  --network host \
  --device /dev/snd \
  -v ~/mediamtx-config:/etc/mediamtx \
  -v /dev/snd:/dev/snd \
  bluenviron/mediamtx:v1.15.1

# Verify container is running
docker logs mediamtx
```

## Components

### usb-audio-mapper.sh (v1.2.1)

Maps USB audio devices to persistent names using udev rules based on physical USB port paths. This ensures MediaMTX always streams from the correct device regardless of boot order.

**Key Functions:**
- `get_usb_physical_port()` - Comprehensive sysfs device search for accurate port detection
- `get_device_uniqueness()` - Generates unique identifiers without breaking v1.0.0 compatibility
- `safe_base10()` - Prevents octal number interpretation errors
- `get_portable_hash()` - Cross-platform hash generation with multiple fallbacks
- `create_udev_rule()` - Generates udev rules for persistent naming

**Usage:**
```bash
# Interactive device mapping
sudo ./usb-audio-mapper.sh

# List all USB audio devices
sudo ./usb-audio-mapper.sh --list

# Test mode (no changes made)
sudo ./usb-audio-mapper.sh --test

# Map specific device by card number
sudo ./usb-audio-mapper.sh --card 2

# Remove existing mappings
sudo ./usb-audio-mapper.sh --remove Device_1

# Show current mappings
sudo ./usb-audio-mapper.sh --show-mappings
```

**Generated Files:**
- `/etc/udev/rules.d/99-usb-soundcards.rules` - udev rules for persistent naming
- `/dev/snd/by-usb-port/` - Symbolic links to actual devices
- `/usr/local/bin/usb-audio-symlink.sh` - Helper script for symlink creation

### install_mediamtx.sh (v5.2.0)

Comprehensive MediaMTX installation and management with intelligent update capabilities. Handles MediaMTX binary installation, configuration, and service management.

**Key Functions:**
- `detect_management_mode()` - Identifies how MediaMTX is being managed (systemd/stream-manager/manual)
- `update_mediamtx()` - Stream-aware update process preserving active connections
- `download_mediamtx()` - Architecture-aware binary download from GitHub releases
- `configure_mediamtx()` - Initial configuration with optimal audio streaming settings
- `show_status()` - Enhanced status display with MediaMTX API health checks
- `verify_installation()` - Multi-endpoint API health checking (v2/v3 compatibility)

**MediaMTX Management Modes:**
1. **systemd**: Full service integration with automatic startup
2. **stream-manager**: Coordinated with audio stream manager
3. **manual**: Direct execution for testing/debugging

**Usage:**
```bash
# Install MediaMTX v1.15.1 (recommended, tested for stability)
sudo ./install_mediamtx.sh install --version v1.15.1

# Install latest MediaMTX version
sudo ./install_mediamtx.sh install

# Update existing MediaMTX (preserves streams)
sudo ./install_mediamtx.sh update

# Check MediaMTX and stream status
sudo ./install_mediamtx.sh status

# Enable systemd service
sudo ./install_mediamtx.sh enable

# Disable systemd service
sudo ./install_mediamtx.sh disable

# Uninstall MediaMTX (preserves configs)
sudo ./install_mediamtx.sh uninstall

# Show installed MediaMTX version
sudo ./install_mediamtx.sh version

# Backup MediaMTX configuration
sudo ./install_mediamtx.sh backup

# Restore MediaMTX configuration
sudo ./install_mediamtx.sh restore
```

**Installation Paths:**
- Binary: `/usr/local/bin/mediamtx`
- Configuration: `/etc/mediamtx/mediamtx.yml`
- Service: `/etc/systemd/system/mediamtx.service`
- Logs: `/var/log/mediamtx.log`
- Backups: `/etc/mediamtx/backups/`

### mediamtx-stream-manager.sh

Manages FFmpeg audio capture processes that publish streams to MediaMTX. Provides automatic stream recovery, health monitoring, and coordinated lifecycle management.

**Features:**
- Automatic audio device discovery from mapped devices
- FFmpeg process management with PID tracking
- Stream health monitoring with auto-restart
- Coordinated start/stop with MediaMTX
- Real-time priority scheduling support (SCHED_FIFO)
- Individual stream logging

**Stream Pipeline:**
```
ALSA Device → FFmpeg Capture → RTSP Publish → MediaMTX → Client Access
hw:Device_1 → ffmpeg -f alsa → rtsp://localhost:8554/Device_1 → Clients
```

**Usage:**
```bash
# Start MediaMTX and all audio streams
sudo ./mediamtx-stream-manager.sh start

# Stop MediaMTX and all streams
sudo ./mediamtx-stream-manager.sh stop

# Restart MediaMTX and streams
sudo ./mediamtx-stream-manager.sh restart

# Check MediaMTX and stream status
sudo ./mediamtx-stream-manager.sh status

# Add new audio device stream
sudo ./mediamtx-stream-manager.sh add-device Device_1

# Remove audio device stream
sudo ./mediamtx-stream-manager.sh remove-device Device_1

# Enable real-time scheduling
sudo ./mediamtx-stream-manager.sh enable-realtime

# Show stream statistics
sudo ./mediamtx-stream-manager.sh stats
```

**Configuration Files:**
- `/etc/mediamtx/audio-devices.conf` - Device-to-stream mappings
- `/var/lib/mediamtx-ffmpeg/*.pid` - Process ID files
- `/var/lib/mediamtx-ffmpeg/*.log` - Individual stream logs

### lyrebird-wizard.sh (v1.1.1)

Interactive setup wizard providing guided installation of MediaMTX v1.15.1 and complete system configuration.

**Features:**
- System requirements validation
- MediaMTX v1.15.1 installation with verification
- Interactive USB audio device mapping
- Audio stream configuration
- Service setup selection (systemd vs stream-manager)
- Configuration backup and restore
- Network connectivity testing
- MediaMTX API verification

**Workflow:**
1. System compatibility check
2. MediaMTX installation (defaults to v1.15.1)
3. USB audio device detection and mapping
4. Stream configuration generation
5. Service enablement
6. Connection testing

**Usage:**
```bash
# Run interactive setup (installs MediaMTX v1.15.1)
sudo ./lyrebird-wizard.sh

# Run with debug output
sudo LYREBIRD_DEBUG=1 ./lyrebird-wizard.sh

# Skip confirmation prompts
sudo ./lyrebird-wizard.sh --yes

# Restore from backup
sudo ./lyrebird-wizard.sh --restore backup-20241011.tar.gz

# Validate existing installation
sudo ./lyrebird-wizard.sh --validate
```

## MediaMTX Integration

### Overview

MediaMTX v1.15.1 serves as the core streaming engine for LyreBirdAudio, providing enterprise-grade RTSP streaming with minimal latency and resource usage. The integration has been extensively tested for stability with multiple concurrent audio streams.

### Why MediaMTX v1.15.1?

- **Stability**: v1.15.1 has been thoroughly tested with 5+ concurrent audio streams for extended periods (14+ days)
- **Performance**: Minimal CPU usage (~1-2% per stream on modern hardware)
- **Compatibility**: Proven compatibility with all major RTSP clients
- **Features**: Complete feature set including API, authentication, and recording
- **Reliability**: Stable memory usage without leaks over weeks of continuous operation

### MediaMTX Configuration for Audio

Optimized configuration for audio streaming (`/etc/mediamtx/mediamtx.yml`):

```yaml
# Core server settings
rtspAddress: :8554
protocols: [udp, tcp]
rtpAddress: :8000
rtcpAddress: :8001
readTimeout: 10s
writeTimeout: 10s

# API configuration
api: yes
apiAddress: :9997

# Logging
logLevel: info
logDestinations: [file]
logFile: /var/log/mediamtx.log

# Metrics (Prometheus compatible)
metrics: yes
metricsAddress: :9998

# Path configuration for audio streams
pathDefaults:
  source: publisher
  sourceOnDemand: no
  sourceOnDemandStartTimeout: 10s
  sourceOnDemandCloseAfter: 10s
  
  # Audio-optimized settings
  rtspTransport: udp
  rtspAnyPort: no
  
  # Recording (optional)
  record: no
  recordPath: /var/lib/mediamtx/recordings/%path/%Y-%m-%d_%H-%M-%S.mp4
  recordFormat: mp4
  recordPartDuration: 1h
  recordSegmentDuration: 1h
  recordDeleteAfter: 24h

# Individual audio device paths
paths:
  # Dynamically configured by stream manager
  # Example:
  # Device_1:
  #   source: rtsp://localhost:8554/Device_1
  #   sourceProtocol: tcp
```

### MediaMTX API Usage

The MediaMTX v1.15.1 API (v3) provides comprehensive control:

```bash
# List all active paths/streams
curl http://localhost:9997/v3/paths/list

# Get specific path information
curl http://localhost:9997/v3/paths/get/Device_1

# Get server configuration
curl http://localhost:9997/v3/config/get

# Reload configuration
curl -X POST http://localhost:9997/v3/config/reload

# Kick a client
curl -X POST http://localhost:9997/v3/paths/kick/Device_1/client_id

# Get metrics
curl http://localhost:9998/metrics
```

### Stream Publishing to MediaMTX

FFmpeg publishes audio to MediaMTX using optimized parameters:

```bash
# Basic audio streaming to MediaMTX
ffmpeg -f alsa -i hw:Device_1 \
  -c:a aac -b:a 128k \
  -f rtsp rtsp://localhost:8554/Device_1

# High-quality audio streaming
ffmpeg -f alsa -ar 48000 -ac 2 -i hw:Device_1 \
  -c:a libfdk_aac -profile:a aac_he_v2 -b:a 64k \
  -f rtsp -rtsp_transport tcp \
  rtsp://localhost:8554/Device_1

# Low-latency audio streaming
ffmpeg -f alsa -thread_queue_size 512 -i hw:Device_1 \
  -c:a opus -b:a 128k -application lowdelay \
  -f rtsp -rtsp_transport udp \
  rtsp://localhost:8554/Device_1
```

### Client Access

Clients can access MediaMTX streams using any RTSP-compatible player:

```bash
# VLC
vlc rtsp://server:8554/Device_1

# FFplay (low latency)
ffplay -fflags nobuffer -rtsp_transport tcp rtsp://server:8554/Device_1

# GStreamer
gst-launch-1.0 rtspsrc location=rtsp://server:8554/Device_1 ! decodebin ! autoaudiosink

# MPV
mpv rtsp://server:8554/Device_1

# OBS Studio
# Add Media Source with URL: rtsp://server:8554/Device_1
```

### Performance Metrics

MediaMTX v1.15.1 performance with LyreBirdAudio (tested configuration):

- **Streams**: 5 concurrent audio streams
- **Latency**: <200ms end-to-end (LAN)
- **CPU Usage**: ~10% total on Intel N100
- **Memory**: ~50MB for MediaMTX + 10MB per stream
- **Network**: ~1Mbps per audio stream (128kbps AAC)
- **Uptime**: 30+ days continuous operation without restart

## Usage

### Quick Start Guide

```bash
# 1. Setup complete system (installs MediaMTX v1.15.1)
sudo ./lyrebird-wizard.sh

# 2. Verify MediaMTX is running
sudo ./install_mediamtx.sh status

# 3. List your audio devices
sudo ./usb-audio-mapper.sh --list

# 4. Start streaming
sudo ./mediamtx-stream-manager.sh start

# 5. Access stream
ffplay rtsp://localhost:8554/Device_1
```

### Production Deployment

For production environments, follow this deployment checklist:

```bash
# 1. System preparation
sudo apt-get update
sudo apt-get install -y ffmpeg alsa-utils curl

# 2. Install MediaMTX v1.15.1 (tested version)
sudo ./install_mediamtx.sh install --version v1.15.1

# 3. Map all audio devices
sudo ./usb-audio-mapper.sh
# Follow prompts to map each device

# 4. Configure stream parameters
sudo nano /etc/mediamtx/audio-devices.conf
# Set appropriate sample rates and channels

# 5. Enable systemd service
sudo ./install_mediamtx.sh enable
sudo systemctl start mediamtx

# 6. Start stream manager
sudo ./mediamtx-stream-manager.sh start

# 7. Verify all streams active
curl http://localhost:9997/v3/paths/list | jq

# 8. Configure firewall
sudo ufw allow 8554/tcp  # RTSP
sudo ufw allow 8000:8001/udp  # RTP/RTCP
sudo ufw allow 9997/tcp  # API

# 9. Test from client
vlc rtsp://server-ip:8554/Device_1
```

### Command Reference

#### MediaMTX Management
```bash
# Installation and updates
sudo ./install_mediamtx.sh install --version v1.15.1  # Install specific version
sudo ./install_mediamtx.sh update                     # Update preserving streams
sudo ./install_mediamtx.sh uninstall                  # Remove MediaMTX

# Service control
sudo ./install_mediamtx.sh start                      # Start MediaMTX service
sudo ./install_mediamtx.sh stop                       # Stop MediaMTX service
sudo ./install_mediamtx.sh restart                    # Restart MediaMTX service
sudo ./install_mediamtx.sh enable                     # Enable on boot
sudo ./install_mediamtx.sh disable                    # Disable on boot

# Status and diagnostics
sudo ./install_mediamtx.sh status                     # Full status with API check
sudo ./install_mediamtx.sh version                    # Show installed version
sudo ./install_mediamtx.sh logs                       # View MediaMTX logs
```

#### Device Management
```bash
# Device discovery and mapping
sudo ./usb-audio-mapper.sh --list                     # List all USB audio devices
sudo ./usb-audio-mapper.sh --scan                     # Scan for new devices
sudo ./usb-audio-mapper.sh                            # Interactive mapping
sudo ./usb-audio-mapper.sh --card 2                   # Map specific card
sudo ./usb-audio-mapper.sh --test                     # Test without changes

# Device maintenance
sudo ./usb-audio-mapper.sh --show-mappings            # Display current mappings
sudo ./usb-audio-mapper.sh --remove Device_1          # Remove device mapping
sudo ./usb-audio-mapper.sh --reload                   # Reload udev rules
```

#### Stream Management
```bash
# Stream control
sudo ./mediamtx-stream-manager.sh start               # Start all streams
sudo ./mediamtx-stream-manager.sh stop                # Stop all streams
sudo ./mediamtx-stream-manager.sh restart             # Restart all streams
sudo ./mediamtx-stream-manager.sh status              # Check stream status

# Individual stream management
sudo ./mediamtx-stream-manager.sh add-device Device_1     # Add stream
sudo ./mediamtx-stream-manager.sh remove-device Device_1  # Remove stream
sudo ./mediamtx-stream-manager.sh restart-device Device_1 # Restart one stream

# Monitoring
sudo ./mediamtx-stream-manager.sh stats               # Stream statistics
sudo ./mediamtx-stream-manager.sh logs Device_1       # View stream logs
```

### Accessing Streams

#### Local Testing
```bash
# Test with FFplay (lowest latency)
ffplay -fflags nobuffer -flags low_delay \
  -rtsp_transport tcp rtsp://localhost:8554/Device_1

# Test with VLC
vlc --network-caching=200 rtsp://localhost:8554/Device_1

# Test with GStreamer
gst-launch-1.0 rtspsrc location=rtsp://localhost:8554/Device_1 \
  latency=100 ! decodebin ! autoaudiosink
```

#### Network Access
```bash
# From another machine on the network
vlc rtsp://192.168.1.100:8554/Device_1

# With authentication (if configured)
vlc rtsp://user:pass@192.168.1.100:8554/Device_1

# Multiple streams simultaneously
vlc rtsp://192.168.1.100:8554/Device_1 \
    rtsp://192.168.1.100:8554/Device_2 \
    rtsp://192.168.1.100:8554/Device_3
```

#### API Access
```bash
# List all streams
curl http://localhost:9997/v3/paths/list | jq

# Get specific stream info
curl http://localhost:9997/v3/paths/get/Device_1 | jq

# Monitor active connections
watch -n 1 'curl -s http://localhost:9997/v3/paths/list | \
  jq ".items[] | {name, readers: .readers | length}"'

# Get server metrics
curl http://localhost:9998/metrics | grep mediamtx
```

## Configuration

### MediaMTX Configuration

The main configuration file is located at `/etc/mediamtx/mediamtx.yml`. Key settings:

```yaml
# RTSP server configuration
rtspAddress: :8554
rtpAddress: :8000
rtcpAddress: :8001

# API configuration
api: true
apiAddress: :9997

# Logging
logLevel: info
logDestinations: [file]
logFile: /var/log/mediamtx.log

# Path defaults
pathDefaults:
  source: publisher
  sourceOnDemand: no
```

### Audio Device Configuration

Audio devices are configured in `/etc/mediamtx/audio-devices.conf`:

```bash
# Format: DEVICE_NAME:ALSA_DEVICE:SAMPLE_RATE:CHANNELS
Device_1:hw:Device_1:48000:2
Device_2:hw:Device_2:44100:2
Device_3:hw:Device_3:48000:1
```

### udev Rules

USB device mapping rules are stored in `/etc/udev/rules.d/99-usb-soundcards.rules`:

```bash
# Example rule structure
SUBSYSTEM=="sound", ACTION=="add|change", KERNEL=="card[0-9]*", \
  ATTRS{idVendor}=="0d8c", ATTRS{idProduct}=="0014", \
  KERNELS=="1-1.4", \
  ATTR{id}="Device_1", \
  RUN+="/usr/local/bin/usb-audio-symlink.sh %k Device_1"
```

## Troubleshooting

### Common Issues and Solutions

#### Device Remapping After Reboot (v1.0.1 Issue - FIXED in v1.1.0)

If upgrading from v1.0.1 where devices changed names after reboot:

```bash
# Verify udev rules (should NOT contain serial numbers in path)
cat /etc/udev/rules.d/99-usb-soundcards.rules

# Correct format (v1.1.0):
# KERNELS=="1-1.4"  ✓ (no serial suffix)

# Incorrect format (v1.0.1):
# KERNELS=="1-1.4-ABC123"  ✗ (has serial suffix)

# Test device detection
sudo ./usb-audio-mapper.sh --test

# Reload udev rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=sound

# Verify persistent naming
ls -la /dev/snd/by-usb-port/
```

#### MediaMTX Not Starting

```bash
# Check MediaMTX installation
sudo ./install_mediamtx.sh status

# If not installed, install v1.15.1
sudo ./install_mediamtx.sh install --version v1.15.1

# Check for port conflicts
sudo lsof -i :8554  # RTSP port
sudo lsof -i :9997  # API port

# Test MediaMTX directly
sudo /usr/local/bin/mediamtx /etc/mediamtx/mediamtx.yml

# View detailed logs
sudo journalctl -u mediamtx -f
sudo tail -f /var/log/mediamtx.log

# Check configuration syntax
/usr/local/bin/mediamtx test /etc/mediamtx/mediamtx.yml
```

#### Audio Streams Not Publishing to MediaMTX

```bash
# Check stream manager status
sudo ./mediamtx-stream-manager.sh status

# Verify FFmpeg processes running
ps aux | grep ffmpeg

# Check individual stream logs
sudo tail -f /var/lib/mediamtx-ffmpeg/Device_1.log

# Test audio device directly
arecord -D hw:Device_1 -f cd -d 5 test.wav
aplay test.wav

# Test FFmpeg publishing to MediaMTX manually
ffmpeg -f alsa -i hw:Device_1 -c:a aac -b:a 128k \
  -f rtsp rtsp://localhost:8554/test

# Verify stream in MediaMTX API
curl http://localhost:9997/v3/paths/get/Device_1
```

#### High Latency Issues

```bash
# Use UDP instead of TCP for lower latency
# Client side:
ffplay -rtsp_transport udp -fflags nobuffer \
  rtsp://server:8554/Device_1

# Server side - configure in audio-devices.conf:
# Use Opus codec for lower latency
Device_1:hw:Device_1:48000:2:opus:lowdelay

# Enable real-time scheduling
sudo ./mediamtx-stream-manager.sh enable-realtime

# Check for buffer underruns
dmesg | grep -i "xrun"
```

#### MediaMTX API Not Responding

```bash
# Check if MediaMTX is running
pgrep mediamtx

# Test different API endpoints (v1.15.1 uses v3)
curl -v http://localhost:9997/v3/paths/list
curl -v http://localhost:9997/v2/paths/list  # Older versions
curl -v http://localhost:9997/                 # Root endpoint

# Check API is enabled in config
grep "api:" /etc/mediamtx/mediamtx.yml
# Should show: api: yes

# Restart MediaMTX
sudo systemctl restart mediamtx
```

#### USB Device Not Detected

```bash
# List all USB devices
lsusb -v | grep -A 10 -i audio

# Check device in ALSA
aplay -l
arecord -l

# Check kernel messages
dmesg | grep -i "usb.*audio" | tail -20

# Verify device in sysfs
ls -la /sys/bus/usb/devices/*/sound/

# Rescan USB bus
sudo udevadm trigger --subsystem-match=usb
sudo udevadm settle
```

#### Streams Dropping/Reconnecting

```bash
# Check network statistics
netstat -s | grep -i drop

# Monitor MediaMTX connections
watch -n 1 'ss -tan | grep :8554'

# Increase MediaMTX timeouts in mediamtx.yml
readTimeout: 20s
writeTimeout: 20s

# Check system resources
htop  # Look for CPU/memory issues
iostat -x 1  # Check disk I/O

# Review MediaMTX error logs
grep -i error /var/log/mediamtx.log | tail -20
```

#### Permission Issues

```bash
# Fix MediaMTX permissions
sudo chown root:root /usr/local/bin/mediamtx
sudo chmod 755 /usr/local/bin/mediamtx

# Fix configuration permissions
sudo chown -R root:root /etc/mediamtx
sudo chmod 644 /etc/mediamtx/mediamtx.yml

# Fix log permissions
sudo touch /var/log/mediamtx.log
sudo chown syslog:adm /var/log/mediamtx.log
sudo chmod 640 /var/log/mediamtx.log

# Fix audio group membership
sudo usermod -a -G audio $USER
# Log out and back in for changes to take effect
```

### Debug Mode

Enable comprehensive debugging:

```bash
# Enable debug logging for all components
export LYREBIRD_DEBUG=1

# Debug USB device mapping
sudo LYREBIRD_DEBUG=1 ./usb-audio-mapper.sh --test

# Debug MediaMTX installation
sudo LYREBIRD_DEBUG=1 ./install_mediamtx.sh status

# Debug stream manager
sudo LYREBIRD_DEBUG=1 ./mediamtx-stream-manager.sh status

# Enable MediaMTX debug logging
# Edit /etc/mediamtx/mediamtx.yml:
logLevel: debug

# Restart to apply
sudo systemctl restart mediamtx
```

### Log File Locations

All relevant logs for troubleshooting:

```bash
# MediaMTX server logs
/var/log/mediamtx.log              # Main server log
/var/log/mediamtx-access.log       # Access logs (if enabled)

# Stream manager logs
/var/lib/mediamtx-ffmpeg/*.log     # Individual stream logs
/var/log/mediamtx-audio-manager.log # Manager log

# System logs
/var/log/syslog                    # System events
/var/log/kern.log                  # Kernel/USB events
journalctl -u mediamtx             # systemd service logs

# Installation logs
/var/log/lyrebird-wizard.log       # Setup wizard log
/tmp/mediamtx-install.log          # Installation log
```

### Getting Help

If issues persist:

1. **Collect diagnostic information:**
```bash
# Generate diagnostic report
(
  echo "=== System Info ==="
  uname -a
  echo -e "\n=== MediaMTX Version ==="
  /usr/local/bin/mediamtx --version
  echo -e "\n=== USB Devices ==="
  lsusb
  echo -e "\n=== Audio Devices ==="
  aplay -l
  echo -e "\n=== Device Mappings ==="
  cat /proc/asound/cards
  echo -e "\n=== MediaMTX Status ==="
  sudo ./install_mediamtx.sh status
  echo -e "\n=== Active Streams ==="
  curl -s http://localhost:9997/v3/paths/list | jq
  echo -e "\n=== Recent Logs ==="
  sudo tail -50 /var/log/mediamtx.log
) > diagnostic_report.txt
```

2. **Check GitHub Issues:** https://github.com/tomtom215/LyreBirdAudio/issues

3. **Report new issues with:**
   - Diagnostic report
   - Steps to reproduce
   - Expected vs actual behavior
   - LyreBirdAudio version (v1.1.0)
   - MediaMTX version (v1.15.1)

## Performance & Optimization

### System Tuning for MediaMTX

#### CPU Optimization

```bash
# Set CPU governor to performance
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# Disable CPU frequency scaling
sudo systemctl disable ondemand

# Pin MediaMTX to specific CPUs
sudo taskset -c 1,2 /usr/local/bin/mediamtx
```

#### Memory Optimization

```bash
# Increase system limits for MediaMTX
sudo tee /etc/security/limits.d/mediamtx.conf << EOF
* soft nofile 65535
* hard nofile 65535
* soft memlock unlimited
* hard memlock unlimited
EOF

# Optimize kernel parameters
sudo tee -a /etc/sysctl.conf << EOF
# Network buffers for RTSP streaming
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728

# Reduce swappiness for MediaMTX
vm.swappiness = 10
EOF

sudo sysctl -p
```

#### Network Optimization

```bash
# Optimize network stack for low latency
sudo tee -a /etc/sysctl.conf << EOF
# Reduce buffering for real-time streams
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_nodelay = 1
net.ipv4.tcp_quickack = 1

# Increase connection tracking
net.netfilter.nf_conntrack_max = 131072
net.nf_conntrack_max = 131072
EOF

sudo sysctl -p
```

### MediaMTX Configuration Optimization

#### Low-Latency Configuration

```yaml
# /etc/mediamtx/mediamtx.yml optimized for low latency
rtspAddress: :8554
protocols: [udp]  # UDP only for lowest latency
rtpAddress: :8000
rtcpAddress: :8001

# Reduce timeouts
readTimeout: 5s
writeTimeout: 5s

# Disable unnecessary features
metrics: no
pprof: no

pathDefaults:
  source: publisher
  sourceOnDemand: no
  # Reduce buffering
  rtspTransport: udp
  rtspAnyPort: no
```

#### High-Throughput Configuration

```yaml
# /etc/mediamtx/mediamtx.yml optimized for many streams
rtspAddress: :8554
protocols: [tcp, udp]  # Both protocols
readBufferCount: 2048  # Increase buffers

# Enable connection pooling
rtspAddress: :8554
rtpAddress: :8000-8100  # Port range for multiple streams
rtcpAddress: :8001-8101

pathDefaults:
  source: publisher
  sourceOnDemand: yes  # On-demand to save resources
  sourceOnDemandStartTimeout: 10s
  sourceOnDemandCloseAfter: 60s
```

### Audio Quality Optimization

#### Sample Rate Selection

```bash
# Professional quality (studio)
Device_Studio:hw:Device_1:96000:2  # 96kHz/24-bit

# Broadcast quality
Device_Broadcast:hw:Device_2:48000:2  # 48kHz/16-bit

# Voice communication
Device_Voice:hw:Device_3:16000:1  # 16kHz mono

# Music streaming
Device_Music:hw:Device_4:44100:2  # 44.1kHz (CD quality)
```

#### Codec Selection for Use Cases

```bash
# Ultra-low latency (<100ms) - Use Opus
ffmpeg -f alsa -i hw:Device_1 \
  -c:a opus -b:a 128k -frame_duration 2.5 \
  -application lowdelay \
  -f rtsp rtsp://localhost:8554/Device_1

# High quality music - Use AAC
ffmpeg -f alsa -i hw:Device_1 \
  -c:a libfdk_aac -profile:a aac_he_v2 -b:a 256k \
  -f rtsp rtsp://localhost:8554/Device_1

# Minimal bandwidth - Use Opus at low bitrate
ffmpeg -f alsa -i hw:Device_1 \
  -c:a opus -b:a 32k -application voip \
  -f rtsp rtsp://localhost:8554/Device_1
```

### Monitoring and Metrics

#### Prometheus Integration

```yaml
# Enable metrics in mediamtx.yml
metrics: yes
metricsAddress: :9998

# Prometheus scrape config
scrape_configs:
  - job_name: 'mediamtx'
    static_configs:
      - targets: ['localhost:9998']
```

#### Custom Monitoring Script

```bash
#!/bin/bash
# monitor-streams.sh

while true; do
  clear
  echo "=== MediaMTX Stream Monitor ==="
  echo "Time: $(date)"
  echo ""
  
  # Get stream count
  stream_count=$(curl -s http://localhost:9997/v3/paths/list | jq '.items | length')
  echo "Active Streams: $stream_count"
  echo ""
  
  # Get each stream's readers
  curl -s http://localhost:9997/v3/paths/list | jq -r '.items[] | 
    "Stream: \(.name) | Readers: \(.readers | length) | Source: \(.source.type)"'
  
  echo ""
  echo "=== System Resources ==="
  # MediaMTX process stats
  ps aux | grep mediamtx | grep -v grep | awk '{print "CPU: "$3"% | MEM: "$4"%"}'
  
  sleep 5
done
```

### Scaling Considerations

#### Multiple MediaMTX Instances

For large deployments, run multiple MediaMTX instances:

```bash
# Instance 1: Devices 1-4
/usr/local/bin/mediamtx /etc/mediamtx/mediamtx1.yml

# Instance 2: Devices 5-8  
/usr/local/bin/mediamtx /etc/mediamtx/mediamtx2.yml

# Load balance with nginx
upstream mediamtx_servers {
    server 127.0.0.1:8554;
    server 127.0.0.1:8555;
}
```

#### Hardware Recommendations by Scale

- **1-4 Streams**: Raspberry Pi 4 (4GB RAM)
- **5-16 Streams**: Intel NUC or equivalent (8GB RAM)
- **17-50 Streams**: Dedicated server (16GB RAM, 4+ cores)
- **50+ Streams**: Multiple servers with load balancing

# Test device detection
sudo ./usb-audio-mapper.sh --test

# Reload udev rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=sound

# Check current device mapping
cat /proc/asound/cards
ls -la /dev/snd/by-usb-port/
```

#### MediaMTX Not Starting

```bash
# Check MediaMTX status
sudo ./install_mediamtx.sh status

# View MediaMTX logs
sudo tail -f /var/log/mediamtx.log

# Test MediaMTX manually
sudo /usr/local/bin/mediamtx /etc/mediamtx/mediamtx.yml

# Check for port conflicts
sudo lsof -i :8554
sudo lsof -i :9997
```

#### Audio Streams Not Working

```bash
# Check stream manager status
sudo ./mediamtx-stream-manager.sh status

# View FFmpeg logs
sudo tail -f /var/lib/mediamtx-ffmpeg/*.log

# Test audio device directly
arecord -D hw:Device_1 -f cd -d 5 test.wav
aplay test.wav

# Verify RTSP stream
ffplay rtsp://localhost:8554/Device_1
```

#### USB Device Not Detected

```bash
# List all USB devices
lsusb -t

# Check USB audio devices
aplay -l
arecord -l

# Verify device in sysfs
ls -la /sys/bus/usb/devices/

# Check kernel messages
dmesg | grep -i usb | tail -20
```

### Debug Mode

Enable debug output for detailed troubleshooting:

```bash
# Enable debug for all scripts
export LYREBIRD_DEBUG=1

# Run with debug output
sudo LYREBIRD_DEBUG=1 ./usb-audio-mapper.sh --test
sudo LYREBIRD_DEBUG=1 ./install_mediamtx.sh status
```

### Log Files

Important log locations:

- `/var/log/mediamtx.log` - MediaMTX server logs
- `/var/log/lyrebird-wizard.log` - Setup wizard logs
- `/var/log/mediamtx-audio-manager.log` - Stream manager logs
- `/var/lib/mediamtx-ffmpeg/*.log` - Individual stream logs
- `/var/log/syslog` or `journalctl` - System logs including udev events

## Version History

### v1.1.0 (Current Release)

**MediaMTX Integration:**
- Extensively tested with MediaMTX v1.15.1 for maximum stability
- Added intelligent detection of MediaMTX management mode (systemd/stream-manager/manual)
- Implemented zero-downtime MediaMTX updates preserving active streams
- Enhanced API health checking with v2/v3 endpoint compatibility
- Stream-aware update process with automatic rollback on failure

**Critical Fixes:**
- **FIXED:** USB device remapping on reboot (removed serial suffixes from port paths)
- **FIXED:** Incorrect device detection where Device 5 matched USB hub instead of audio device
- **FIXED:** Octal number interpretation errors with leading zeros (007 now correctly parsed as 7)
- **FIXED:** MediaMTX updates interrupting active audio streams
- **FIXED:** v1.0.0 backwards compatibility broken by v1.0.1 serial number changes

**USB Audio Mapper (v1.2.1):**
- Complete rewrite of `get_usb_physical_port()` for accurate sysfs device matching
- Added `safe_base10()` function preventing octal interpretation
- Implemented portable hash generation with multiple fallback methods
- Enhanced USB path validation for broader compatibility
- Separated port path generation from symlink uniqueness

**MediaMTX Installer (v5.2.0):**
- Added `detect_management_mode()` function for intelligent service detection
- Implemented stream preservation during updates (collects and restarts active streams)
- Multi-endpoint API testing (v3/v2/root) for version compatibility
- Enhanced status display showing active stream names and real-time scheduling
- Added rollback actions for failed updates
- Context-aware post-installation guidance

**Compatibility & Testing:**
- Fully backwards compatible with v1.0.0 and v1.0.1
- No migration required - drop-in replacement
- Tested on Ubuntu 20.04/22.04, Debian 11/12, Raspberry Pi OS
- Validated with 8+ concurrent audio streams for 30+ days
- Confirmed working with MediaMTX v1.9.x through v1.15.x

### v1.0.1

**New Components:**
- Added `lyrebird-wizard.sh` interactive setup wizard
- Implemented `mediamtx-stream-manager.sh` for FFmpeg process management
- Created automated device configuration generation

**Features:**
- Initial stream manager implementation with auto-restart
- Basic MediaMTX service integration
- System requirements validation
- Configuration backup and restore functionality

**Known Issues (Fixed in v1.1.0):**
- Serial numbers added to USB port paths breaking v1.0.0 compatibility
- Devices could be remapped after system reboot
- MediaMTX updates would interrupt active streams

### v1.0.0

**Foundation Release:**
- Core USB audio device persistence using udev rules
- Physical USB port path mapping inspired by cberge's concept
- Basic MediaMTX installation script
- Manual device mapping functionality

**Components:**
- `usb-audio-mapper.sh` - Device to port mapping
- `install_mediamtx.sh` - MediaMTX installation
- Basic udev rule generation
- Symlink creation for consistent naming

**Limitations (Addressed in later versions):**
- Manual configuration required
- No stream management
- Basic error handling
- Limited MediaMTX integration

## Contributing

Contributions are welcome! Please follow these guidelines:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/improvement`)
3. Make your changes following these standards:
   - All scripts must pass `bash -n` syntax check
   - All scripts must pass `shellcheck` with no errors
   - Use comprehensive error handling with try/catch patterns
   - Add debug output for troubleshooting
   - Update relevant documentation
4. Test thoroughly on target platforms
5. Submit a pull request with detailed description

### Code Standards

All code must meet production-ready standards:
- Zero syntax errors
- Comprehensive exception handling
- Detailed error messages
- No hard-coded values unless explicitly required
- Extensive inline documentation
- ShellCheck compliance

## Network Ports

LyreBirdAudio uses the following ports (ensure firewall allows them):
- **8554/tcp & udp**: RTSP streaming
- **9997/tcp**: MediaMTX API
- **9998/tcp**: Prometheus metrics (optional)

## Credits

## Contributors

- **Main development**: [Tom F](https://github.com/tomtom215)
- **Original concept**: [cberge908](https://gist.github.com/cberge908/ab7ddc1ac46fd63bb6935cd1f4341112) - GitHub Gist that inspired this project
- **MediaMTX**: [bluenviron/mediamtx](https://github.com/bluenviron/mediamtx) - The excellent RTSP server this project builds upon

## License

Apache 2.0 License - See LICENSE file for details

---

**Note**: This project is not officially affiliated with the MediaMTX project. Always review scripts before running with sudo privileges.

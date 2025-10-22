# LyreBirdAudio

**License:** Apache 2.0  
**Platform:** Linux (Ubuntu/Debian/Raspberry Pi OS)  
**Core Engine:** MediaMTX (latest stable recommended)

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Features](#features)
- [System Requirements](#system-requirements)
- [Installation](#installation)
- [Components](#components)
- [MediaMTX Integration](#mediamtx-integration)
- [Usage](#usage)
  - [Orchestrator Interface](#orchestrator-interface)
  - [Command Reference](#command-reference)
  - [Advanced Operations](#advanced-operations)
- [Configuration](#configuration)
- [Version Management](#version-management)
- [Troubleshooting](#troubleshooting)
- [Performance & Optimization](#performance--optimization)
- [Version History](#version-history)
- [Contributing](#contributing)
- [Credits](#credits)
- [License](#license)

## Overview

LyreBirdAudio provides a comprehensive solution for managing multiple USB audio devices on Linux systems with persistent device naming and real-time RTSP streaming capabilities powered by MediaMTX. The project addresses the common problem of USB audio device enumeration changes after system reboots, ensuring consistent and reliable audio streaming infrastructure for professional audio applications.

### Core Technology Stack

- **MediaMTX** - High-performance real-time media server providing RTSP/WebRTC streaming
- **ALSA** - Linux audio subsystem for device access and control
- **udev** - Dynamic device management for persistent naming
- **FFmpeg** - Audio capture and encoding pipeline
- **systemd** - Service management and automation

### Project Motivation

This project was inspired by my desire to listen to birds using some USB microphones and Mini PC's I had lying around. I had first found [cberge908](https://gist.github.com/cberge908/ab7ddc1ac46fd63bb6935cd1f4341112)'s original script for launching MediaMTX but I quickly learned there were a lot more edge cases that needed to be handled in order for it to run reliably 24x7. LyreBird Audio is my solution to those edgecases. 

**If you like this project, please "star" the repo!** 

**If you use it in any cool or large deployments, please let me know! I'm curious to see where this project goes.**

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
│                       MediaMTX                              │
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

### Management Architecture

LyreBirdAudio uses a modular, single-responsibility architecture where each script handles one specific domain:

```
┌─────────────────────────────────────────────────────────────┐
│                 lyrebird-orchestrator.sh                    │
│                 (Unified Interface)                         │
│  • Interactive TUI for all operations                       │
│  • Delegates to specialized scripts                         │
│  • No duplicate business logic                              │
│  • Consistent error handling & feedback                     │
└─────────┬───────────────────────────────────────────────────┘
          │
          ├─────> install_mediamtx.sh
          │       • MediaMTX installation & updates
          │       • Binary management
          │       • Service configuration
          │       • Built-in --upgrade support
          │
          ├─────> mediamtx-stream-manager.sh
          │       • FFmpeg process lifecycle
          │       • Stream health monitoring
          │       • Automatic recovery
          │       • MediaMTX start/stop/restart
          │
          ├─────> usb-audio-mapper.sh
          │       • USB device detection
          │       • udev rule generation
          │       • Persistent naming
          │
          └─────> lyrebird-updater.sh
                  • Git-based version management
                  • Safe version switching
                  • Update checking
                  • Rollback capabilities
```

### Data Flow

1. **Device Detection**: USB audio devices are detected via udev and mapped to persistent names
2. **Audio Capture**: FFmpeg captures audio from ALSA devices using persistent names
3. **Stream Publishing**: FFmpeg publishes audio streams to MediaMTX via RTSP
4. **Client Access**: MediaMTX serves streams to multiple concurrent clients
5. **Management**: Stream manager or systemd ensures continuous operation

## Features

### Core Functionality

- **MediaMTX-Powered RTSP Streaming**: Enterprise-grade real-time audio streaming
- **Persistent USB Audio Device Naming**: Maps USB audio devices to consistent names using udev rules based on physical USB port paths
- **Unified Orchestrator Interface**: Single interactive TUI for all system management operations
- **Intelligent Management Detection**: Automatically detects and preserves MediaMTX service management mode (systemd/stream-manager/manual)
- **Zero-Downtime Updates**: Stream-aware MediaMTX updates that preserve active audio streams during upgrades
- **Comprehensive Error Handling**: Production-ready exception handling with automatic rollback capabilities
- **Version Management**: Git-based version control with safe switching and rollback

### MediaMTX Capabilities

- **Multi-Protocol Support**: RTSP, RTMP, HLS, WebRTC, and SRT streaming protocols
- **Concurrent Streams**: Handles multiple simultaneous audio device streams with minimal latency
- **API Management**: RESTful API on port 9997 for dynamic stream control
- **Authentication Support**: Optional stream authentication and access control
- **Recording**: On-demand or continuous recording to disk
- **Metrics & Monitoring**: Prometheus-compatible metrics endpoint
- **Low Latency**: Sub-second latency for real-time audio applications
- **Resource Efficiency**: Minimal CPU/memory footprint even with multiple streams

### Technical Capabilities

- Supports multiple simultaneous USB audio devices per system
- Compatible with complex USB hub topologies
- Backwards compatible with previous versions
- Cross-platform hash generation for embedded systems
- Safe base-10 number conversion preventing octal interpretation errors
- Multi-endpoint API health checking across MediaMTX versions
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
- **Raspberry Pi Warning**: Due to USB bandiwdth, power and compute limitations, even the best Raspberry Pi is limited to 2 microphones max

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
- `git` - version management (if using lyrebird-updater.sh)

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

### Migrating from Non-Git Installation

If you previously installed LyreBirdAudio without git (e.g., downloaded as ZIP, manual copy, or installed in a custom location), you can migrate to use the orchestrator and version management features.

**Important**: The orchestrator works with any installation, but `lyrebird-updater.sh` requires a git repository.

#### Option 1: Keep Current Installation (Orchestrator Only)

If you don't need version management, your current installation works fine:

```bash
# Navigate to your existing installation
cd /path/to/your/lyrebird/scripts

# Make scripts executable if needed
chmod +x *.sh

# Launch orchestrator
sudo ./lyrebird-orchestrator.sh
```

The orchestrator will work from any directory containing the LyreBirdAudio scripts.

#### Option 2: Clone Repository Alongside (Recommended)

Keep your working installation separate and use a git clone for updates:

```bash
# Clone to a standard location (recommended: home directory)
git clone https://github.com/tomtom215/LyreBirdAudio.git ~/LyreBirdAudio

# Your existing installation remains at its current location
# Example: /opt/lyrebird or /usr/local/scripts/lyrebird

# Use the git clone for version management
cd ~/LyreBirdAudio
./lyrebird-updater.sh

# Copy updated scripts to your working location when needed
sudo cp ~/LyreBirdAudio/*.sh /path/to/your/installation/
```

**What gets preserved automatically:**
- MediaMTX configuration: `/etc/mediamtx/`
- USB device mappings: `/etc/udev/rules.d/99-usb-soundcards.rules`
- Stream configurations: `/etc/mediamtx/audio-devices.conf`
- MediaMTX binary: `/usr/local/bin/mediamtx`
- State and logs: `/var/lib/mediamtx/`, `/var/log/`

These system files are independent of where you keep the scripts.

#### Option 3: Convert Current Directory to Git Repository (Advanced)

Only do this if you're comfortable with git and understand the risks:

```bash
# 1. BACKUP YOUR CURRENT DIRECTORY FIRST
sudo cp -r /path/to/current/installation /path/to/backup-$(date +%Y%m%d)

# 2. Navigate to current installation
cd /path/to/current/installation

# 3. Check for uncommitted changes or custom files
ls -la

# 4. Initialize git and connect to remote
git init
git remote add origin https://github.com/tomtom215/LyreBirdAudio.git
git fetch origin

# 5. View what will change
git diff HEAD..origin/main

# 6. IMPORTANT: Stash or commit any local changes
git add .
git commit -m "Local changes before sync"

# 7. Reset to repository version (this will overwrite local files)
git reset --hard origin/main

# 8. Verify scripts are executable
chmod +x *.sh

# 9. Run updater
./lyrebird-updater.sh
```

**Warnings for Option 3:**
- This will overwrite any modified scripts in your directory
- Custom changes will be lost unless committed first
- Only do this if your directory contains only LyreBirdAudio scripts
- If you have a mix of files, use Option 2 instead

#### After Migration

Regardless of which option you choose:

1. **Verify MediaMTX is still running:**
   ```bash
   sudo ./mediamtx-stream-manager.sh status
   # or
   sudo systemctl status mediamtx
   ```

2. **Check USB device mappings:**
   ```bash
   ls -la /dev/snd/by-usb-port/
   cat /etc/udev/rules.d/99-usb-soundcards.rules
   ```

3. **Test orchestrator:**
   ```bash
   sudo ./lyrebird-orchestrator.sh
   ```

Your audio streams and MediaMTX configuration are unaffected by where you keep the scripts.

### MediaMTX Compatibility

**Recommended:** Latest stable MediaMTX release  
**Minimum:** MediaMTX v1.12.0 or later  
**API Support:** Automatically detects and uses v2 or v3 API endpoints

### Quick Installation

```bash
# Clone the repository
git clone https://github.com/tomtom215/LyreBirdAudio.git
cd LyreBirdAudio

# Make scripts executable
chmod +x *.sh

# Launch the orchestrator (provides interactive setup)
sudo ./lyrebird-orchestrator.sh
```

### Production Installation

For production environments, we recommend the following installation procedure:

#### Step 1: Install MediaMTX (Core Streaming Engine)

```bash
# Install latest MediaMTX
sudo ./install_mediamtx.sh install

# Or install a specific version
sudo ./install_mediamtx.sh install --target-version v1.15.1

# Verify MediaMTX installation and API connectivity
sudo ./install_mediamtx.sh status

# Expected output shows version, paths, process status, and API connectivity
```

#### Step 2: Map USB Audio Devices

```bash
# Run interactive device mapper
sudo ./usb-audio-mapper.sh

# Or enable debug mode for troubleshooting
sudo DEBUG=true ./usb-audio-mapper.sh

# Test device persistence (dry-run mode)
sudo ./usb-audio-mapper.sh --test

# View help for non-interactive options
sudo ./usb-audio-mapper.sh --help
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

## Components

### lyrebird-orchestrator.sh

**Role**: Unified interactive interface for all LyreBirdAudio operations

The orchestrator is the primary user interface for LyreBirdAudio. It provides an interactive menu system that delegates all operations to specialized scripts without duplicating any business logic.

**Key Features:**
- Interactive TUI with status dashboard
- Consistent error handling and user feedback
- Automatic detection of system state
- Script version compatibility checking
- Real-time system status display

**Usage:**
```bash
# Launch orchestrator (interactive mode)
sudo ./lyrebird-orchestrator.sh
```

### install_mediamtx.sh

**Role**: MediaMTX binary installation and lifecycle management

Handles all MediaMTX binary operations including installation, updates, and uninstallation.

**Usage:**
```bash
# Install latest MediaMTX
sudo ./install_mediamtx.sh install

# Install specific version
sudo ./install_mediamtx.sh install --target-version v1.15.1

# Update to latest
sudo ./install_mediamtx.sh update

# Check status
sudo ./install_mediamtx.sh status

# Verify installation
sudo ./install_mediamtx.sh verify

# Uninstall
sudo ./install_mediamtx.sh uninstall
```

**Common Options:**
- `-v, --verbose` - Enable verbose output
- `-q, --quiet` - Suppress non-error output
- `-n, --dry-run` - Show what would be done
- `-f, --force` - Skip confirmations and checksum verification
- `-V, --target-version VER` - Install specific version

### mediamtx-stream-manager.sh

**Role**: FFmpeg process lifecycle and MediaMTX service management

Manages FFmpeg streaming processes and MediaMTX service operations with automatic recovery and health monitoring.

**Usage:**
```bash
# Start MediaMTX and audio streams
sudo ./mediamtx-stream-manager.sh start

# Stop everything gracefully
sudo ./mediamtx-stream-manager.sh stop

# Force stop (immediate termination)
sudo ./mediamtx-stream-manager.sh force-stop

# Restart MediaMTX and streams
sudo ./mediamtx-stream-manager.sh restart

# Check status
sudo ./mediamtx-stream-manager.sh status

# Monitor resources in real-time
sudo ./mediamtx-stream-manager.sh monitor

# Show configuration
sudo ./mediamtx-stream-manager.sh config
```

**Configuration:**
Device configuration file: `/etc/mediamtx/audio-devices.conf`

Format: `StreamName:ALSADevice:SampleRate:Channels`

Example:
```
Device_1:hw:Device_1:48000:2
Device_2:hw:Device_2:48000:2
```

**Key Environment Variables:**
- `MEDIAMTX_CONFIG_DIR` - Configuration directory (default: /etc/mediamtx)
- `MEDIAMTX_BINARY` - MediaMTX binary path (default: /usr/local/bin/mediamtx)
- `STREAM_STARTUP_DELAY` - Startup delay in seconds (default: 10)

### usb-audio-mapper.sh

**Role**: USB device detection and persistent naming via udev

Maps USB audio devices to consistent names based on physical USB port paths to ensure devices maintain the same ALSA names across reboots.

**Usage:**
```bash
# Interactive device mapping (recommended)
sudo ./usb-audio-mapper.sh

# Test device persistence (dry-run)
sudo ./usb-audio-mapper.sh --test

# Non-interactive mapping
sudo ./usb-audio-mapper.sh --non-interactive --vendor 2e88 --product 4610 --friendly movo-x1

# Enable debug output
sudo DEBUG=true ./usb-audio-mapper.sh

# Show help
sudo ./usb-audio-mapper.sh --help
```

**Generated Files:**
- udev rules: `/etc/udev/rules.d/99-usb-soundcards.rules`
- Device symlinks: `/dev/snd/by-usb-port/Device_N`

### lyrebird-updater.sh

**Role**: Git-based version management

Provides interactive version management for the LyreBirdAudio repository. **Requires a git clone of the repository.**

**Usage:**
```bash
# Check for updates (non-interactive)
./lyrebird-updater.sh --status

# List available versions
./lyrebird-updater.sh --list

# Launch interactive version manager
./lyrebird-updater.sh

# Show version
./lyrebird-updater.sh --version
```

**Interactive Menu Options:**
- Check for Updates
- Upgrade to Latest Version
- Switch to Specific Version
- View Available Versions
- Show Current Version

**Requirements:**
- Git 2.0+ must be installed
- Must be run from within a git clone
- Internet connection for fetching updates

## MediaMTX Integration

### Service Management Modes

LyreBirdAudio supports three MediaMTX management modes:

1. **Stream Manager Mode** (Recommended for audio streaming)
   - Managed by `mediamtx-stream-manager.sh`
   - Automatic FFmpeg process management
   - Stream health monitoring and recovery
   - Start/stop/restart via stream manager commands

2. **Systemd Mode** (Recommended for general use)
   - Managed by systemd service
   - `systemctl start/stop/restart mediamtx`
   - Automatic startup on boot
   - System-level integration

3. **Manual Mode** (Advanced users)
   - Direct binary execution
   - Full control over process
   - No automatic recovery

### MediaMTX Configuration

Default configuration location: `/etc/mediamtx/mediamtx.yml`

**Key Settings for Audio Streaming:**
```yaml
# API Configuration
api: yes
apiAddress: :9997

# RTSP Configuration
rtspAddress: :8554
rtp: yes
rtpAddress: :8000
rtcp: yes
rtcpAddress: :8001

# Path Configuration for Audio Devices
paths:
  Device_1:
    source: publisher
    sourceOnDemand: no
  Device_2:
    source: publisher
    sourceOnDemand: no
```

### API Integration

MediaMTX provides a REST API on port 9997 (default) for runtime control:

```bash
# Get server configuration
curl http://localhost:9997/v3/config/global/get

# List active paths (streams)
curl http://localhost:9997/v3/paths/list

# Get path (stream) information
curl http://localhost:9997/v3/paths/get/Device_1

# Set log level
curl -X POST http://localhost:9997/v3/config/global/patch \
  -H "Content-Type: application/json" \
  -d '{"logLevel": "debug"}'
```

**API Versions:**
- v3 API: MediaMTX v1.15.0+
- v2 API: Earlier MediaMTX versions

LyreBirdAudio automatically detects and uses the appropriate API version.

## Usage

### Orchestrator Interface

The orchestrator provides the primary user interface for all operations:

```bash
# Launch orchestrator
sudo ./lyrebird-orchestrator.sh
```

**Main Menu Navigation:**
- Use number keys to select menu options
- Status dashboard shows current system state
- Error messages displayed at bottom of screen
- Press 0 to return to previous menu

**Status Indicators:**
- ✓ (green) - Service/component running and healthy
- ✗ (red) - Service/component stopped or failed
- ⚠ (yellow) - Warning or degraded state
- ℹ (blue) - Informational message

### Command Reference

#### MediaMTX Operations

```bash
# Installation
sudo ./install_mediamtx.sh install                           # Install latest
sudo ./install_mediamtx.sh install --target-version v1.XX.X  # Install specific version

# Service Control (via stream manager)
sudo ./mediamtx-stream-manager.sh start               # Start MediaMTX + streams
sudo ./mediamtx-stream-manager.sh stop                # Stop gracefully
sudo ./mediamtx-stream-manager.sh restart             # Restart everything
sudo ./mediamtx-stream-manager.sh force-stop          # Force termination

# Status and Monitoring
sudo ./install_mediamtx.sh status                     # Installation status
sudo ./mediamtx-stream-manager.sh status              # Service status
sudo ./mediamtx-stream-manager.sh monitor             # Real-time monitoring

# Updates
sudo ./install_mediamtx.sh update                     # Update MediaMTX
sudo ./install_mediamtx.sh verify                     # Verify installation
```

#### USB Device Management

```bash
# Device Detection and Mapping
sudo ./usb-audio-mapper.sh                            # Interactive mapping
sudo ./usb-audio-mapper.sh --list                     # List devices
sudo ./usb-audio-mapper.sh --test                     # Test persistence

# View Device Configuration
cat /etc/udev/rules.d/99-usb-soundcards.rules         # View udev rules
ls -la /dev/snd/by-usb-port/                          # View symlinks
```

#### Stream Management

```bash
# Stream Operations
sudo ./mediamtx-stream-manager.sh start               # Start all streams
sudo ./mediamtx-stream-manager.sh stop                # Stop all streams
sudo ./mediamtx-stream-manager.sh list-streams        # List active streams

# Stream Testing
ffplay rtsp://localhost:8554/Device_1                 # Test playback
ffprobe rtsp://localhost:8554/Device_1                # Probe stream info
```

#### Version Management

```bash
# Update Checking
./lyrebird-updater.sh --status                        # Check for updates

# Version Operations
./lyrebird-updater.sh                                 # Interactive manager
./lyrebird-updater.sh --upgrade                       # Upgrade to latest
```

### Advanced Operations

#### Manual MediaMTX Configuration

For advanced users who need custom MediaMTX configuration:

```bash
# Edit MediaMTX configuration
sudo nano /etc/mediamtx/mediamtx.yml

# Validate configuration
sudo /usr/local/bin/mediamtx --check /etc/mediamtx/mediamtx.yml

# Restart to apply changes
sudo ./mediamtx-stream-manager.sh restart
```

#### Custom Stream Configuration

Create custom audio device configurations:

```bash
# Edit device configuration
sudo nano /etc/mediamtx/audio-devices.conf

# Format: StreamName:ALSADevice:SampleRate:Channels
# Examples:
Device_1:hw:Device_1:48000:2        # Standard stereo at 48kHz
Device_2:hw:Device_2:44100:1        # Mono at 44.1kHz
HighQuality:hw:Device_3:96000:2     # High sample rate stereo
```

#### Backup and Restore

```bash
# Backup current configuration
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

#### Debugging

```bash
# Enable debug mode for all scripts
export DEBUG=1

# View detailed logs
sudo tail -f /var/log/mediamtx-stream-manager.log
sudo tail -f /var/lib/mediamtx-ffmpeg/*.log
sudo journalctl -u mediamtx -f

# Check MediaMTX API
curl -v http://localhost:9997/v3/config/global/get

# Test USB device detection
sudo DEBUG=true ./usb-audio-mapper.sh --list
```

## Configuration

### System Configuration Files

| File | Purpose | Format |
|------|---------|--------|
| `/etc/mediamtx/mediamtx.yml` | MediaMTX main configuration | YAML |
| `/etc/mediamtx/audio-devices.conf` | Audio device mappings | Text (colon-separated) |
| `/etc/udev/rules.d/99-usb-soundcards.rules` | USB device persistence rules | udev syntax |
| `/etc/systemd/system/mediamtx.service` | Systemd service file | INI-style |

### Runtime State Files

| File/Directory | Purpose |
|----------------|---------|
| `/var/run/mediamtx-audio.pid` | Stream manager PID file |
| `/var/lib/mediamtx-ffmpeg/` | FFmpeg PID files and logs |
| `/var/log/mediamtx-stream-manager.log` | Stream manager log |
| `/var/log/mediamtx.out` | MediaMTX output log |

### Environment Variables

Stream manager behavior can be customized via environment variables:

```bash
# MediaMTX Configuration
export MEDIAMTX_CONFIG_DIR=/etc/mediamtx
export MEDIAMTX_BINARY=/usr/local/bin/mediamtx
export MEDIAMTX_HOST=localhost
export MEDIAMTX_API_PORT=9997

# Timing Configuration
export STREAM_STARTUP_DELAY=10
export USB_STABILIZATION_DELAY=5
export RESTART_STABILIZATION_DELAY=15

# Resource Limits
export MAX_CPU_WARNING=20
export MAX_CPU_CRITICAL=40
export MAX_FD_WARNING=500
export MAX_FD_CRITICAL=1000
```

### Audio Configuration

Default audio settings in `mediamtx-stream-manager.sh`:

```bash
DEFAULT_SAMPLE_RATE="48000"
DEFAULT_CHANNELS="2"
DEFAULT_CODEC="opus"
DEFAULT_BITRATE="128k"
```

Override via device configuration:
```
# Custom sample rate and channels
Device_1:hw:Device_1:96000:2
Device_2:hw:Device_2:44100:1
```

## Version Management

### Update Process

LyreBirdAudio uses git-based version management:

1. **Check for Updates**
   ```bash
   ./lyrebird-updater.sh --status
   ```

2. **Upgrade to Latest**
   ```bash
   ./lyrebird-updater.sh --upgrade
   ```
   - Automatically stashes local changes
   - Fetches latest version
   - Switches to new version
   - Preserves executable permissions

3. **Switch to Specific Version**
   ```bash
   ./lyrebird-updater.sh
   # Select "Switch to Specific Version" from menu
   ```

## Troubleshooting

### Common Issues

#### MediaMTX Won't Start

**Symptoms:** MediaMTX fails to start or exits immediately

**Solutions:**
```bash
# Check for port conflicts
sudo lsof -i :8554    # RTSP port
sudo lsof -i :9997    # API port

# Verify binary
sudo /usr/local/bin/mediamtx --version

# Check configuration syntax
sudo /usr/local/bin/mediamtx --check /etc/mediamtx/mediamtx.yml

# Review logs
sudo journalctl -u mediamtx -n 50
sudo tail -50 /var/log/mediamtx.out
```

#### USB Devices Not Mapped

**Symptoms:** Devices don't appear in `/dev/snd/by-usb-port/`

**Solutions:**
```bash
# Verify udev rules exist
cat /etc/udev/rules.d/99-usb-soundcards.rules

# Reload udev rules
sudo udevadm control --reload-rules
sudo udevadm trigger

# Check device detection
sudo ./usb-audio-mapper.sh --list

# Enable debug mode
sudo DEBUG=true ./usb-audio-mapper.sh --test
```

#### Streams Not Publishing

**Symptoms:** FFmpeg processes running but streams not available

**Solutions:**
```bash
# Check stream manager status
sudo ./mediamtx-stream-manager.sh status

# Verify MediaMTX is running
curl http://localhost:9997/v3/paths/list

# Check FFmpeg logs
sudo tail -f /var/lib/mediamtx-ffmpeg/*.log

# Test ALSA device directly
arecord -D hw:Device_1 -f S16_LE -r 48000 -c 2 -d 5 test.wav

# Restart streams
sudo ./mediamtx-stream-manager.sh restart
```

#### Permission Denied Errors

**Symptoms:** Scripts fail with permission errors

**Solutions:**
```bash
# Ensure running with sudo
sudo ./lyrebird-orchestrator.sh

# Check file permissions
ls -la /etc/mediamtx/
ls -la /var/run/mediamtx-*

# Verify user exists
id mediamtx

# Fix ownership
sudo chown -R mediamtx:mediamtx /var/lib/mediamtx
```

#### Version Mismatch Warnings

**Symptoms:** Orchestrator shows version compatibility warnings

**Solutions:**
```bash
# Check current versions
./install_mediamtx.sh --version
grep "readonly VERSION=" mediamtx-stream-manager.sh
grep "readonly VERSION=" usb-audio-mapper.sh

# Update to latest
./lyrebird-updater.sh --upgrade

# If using custom branch, ensure compatibility
cd /path/to/LyreBirdAudio
git status
git branch -v
```

### Performance Issues

#### High CPU Usage

```bash
# Monitor resource usage
sudo ./mediamtx-stream-manager.sh monitor

# Check FFmpeg processes
ps aux | grep ffmpeg

# Reduce bitrate or sample rate
sudo nano /etc/mediamtx/audio-devices.conf
# Change: Device_1:hw:Device_1:96000:2
# To:     Device_1:hw:Device_1:48000:2
```

#### Stream Latency

```bash
# Reduce buffer sizes in FFmpeg (advanced)
# Edit stream manager and adjust:
# -thread_queue_size 8192  # Reduce from default
# -analyzeduration 1000000 # Reduce analysis time
```

#### Network Congestion

```bash
# Monitor bandwidth
iftop -i eth0

# Check active connections
ss -tupn | grep 8554

# Limit concurrent clients in MediaMTX config
sudo nano /etc/mediamtx/mediamtx.yml
# Add under paths:
#   Device_1:
#     maxReaders: 5
```

### Diagnostic Commands

```bash
# System Health Check
sudo ./lyrebird-orchestrator.sh    # Check status dashboard

# MediaMTX Health
curl http://localhost:9997/v3/config/global/get
curl http://localhost:9997/v3/paths/list

# Stream Health
sudo ./mediamtx-stream-manager.sh status
sudo ./mediamtx-stream-manager.sh list-streams

# Device Health
sudo ./usb-audio-mapper.sh --list
ls -la /dev/snd/by-usb-port/
aplay -l

# Log Analysis
sudo tail -100 /var/log/mediamtx-stream-manager.log
sudo journalctl -u mediamtx --since "1 hour ago"
sudo tail -50 /var/lib/mediamtx-ffmpeg/*.log
```

### Getting Help

If you encounter issues not covered here:

1. Enable debug mode: `export DEBUG=1`
2. Collect logs from:
   - `/var/log/mediamtx-stream-manager.log`
   - `/var/lib/mediamtx-ffmpeg/*.log`
   - `journalctl -u mediamtx`
3. Check system status with orchestrator
4. Open an issue on GitHub with:
   - LyreBirdAudio version
   - MediaMTX version
   - Operating system and version
   - Complete error messages and logs
   - Steps to reproduce

## Performance & Optimization

### Hardware Optimization

**Recommended Hardware for Different Scales:**

| Scale | CPU | RAM | Network | Storage | Max Devices |
|-------|-----|-----|---------|---------|-------------|
| Small (1-2 devices) | 1 core | 512MB | 100Mbps | 1GB | 2 |
| Medium (3-5 devices) | 2 cores | 1GB | 1Gbps | 5GB | 5 |
| Large (6-10 devices) | 4 cores | 2GB | 1Gbps | 10GB | 10 |
| Enterprise (10+ devices) | 8+ cores | 4GB+ | 1Gbps | 20GB+ | 20+ |

### Audio Quality vs Performance

```bash
# Low bandwidth (96 kbps per stream)
Device_1:hw:Device_1:22050:1

# Standard quality (256 kbps per stream)
Device_1:hw:Device_1:48000:2

# High quality (512 kbps per stream)
Device_1:hw:Device_1:96000:2
```

### MediaMTX Tuning

Edit `/etc/mediamtx/mediamtx.yml`:

```yaml
# Performance tuning
readTimeout: 10s
writeTimeout: 10s
readBufferCount: 512
maxReaders: 50  # Limit concurrent clients

# Resource optimization
logLevel: info  # Use 'warn' in production for less I/O
metrics: yes
metricsAddress: :9998

# Path-specific tuning
paths:
  Device_1:
    source: publisher
    sourceOnDemand: no
    record: no  # Disable if not needed
    maxReaders: 10
```

### System Tuning

```bash
# Increase file descriptor limits
sudo nano /etc/security/limits.conf
# Add:
mediamtx soft nofile 65536
mediamtx hard nofile 65536

# Enable real-time scheduling (requires configuration)
sudo setcap 'cap_sys_nice=eip' /usr/local/bin/mediamtx

# Optimize network buffers
sudo sysctl -w net.core.rmem_max=134217728
sudo sysctl -w net.core.wmem_max=134217728
```

### Monitoring

```bash
# Real-time resource monitoring
sudo ./mediamtx-stream-manager.sh monitor

# System-wide monitoring
htop -u mediamtx

# Network monitoring
iftop -i eth0 -f "port 8554"

# Stream-specific monitoring
ffprobe -show_streams rtsp://localhost:8554/Device_1
```

## Version History

### Current Architecture

**Orchestrator-Based Design:**
- `lyrebird-orchestrator.sh` provides unified TUI interface for all operations
- Single-responsibility principle: each component script manages one domain
- Orchestrator delegates to specialized scripts without logic duplication

**Key Components:**
- **install_mediamtx.sh** - MediaMTX installation and lifecycle management
- **mediamtx-stream-manager.sh** - FFmpeg processes and MediaMTX service control  
- **usb-audio-mapper.sh** - USB device persistence via udev rules
- **lyrebird-updater.sh** - Git-based version management

### Important Behavioral Changes

**USB Device Mapping:**
- Device mapping uses physical USB port paths (not serial numbers)
- Ensures backwards compatibility with v1.0.0 installations
- Device names remain consistent across reboots

**MediaMTX Management:**
- Automatic detection of management mode (systemd/stream-manager/manual)
- Stream-aware updates preserve active streams during MediaMTX upgrades
- Service control unified through stream manager (start/stop/restart)

**Version Management:**
- Git-based updates via `lyrebird-updater.sh`
- Requires git clone of repository (not compatible with standalone installations)
- Automatic stashing of local changes during updates

### Breaking Changes to Note

**usb-audio-mapper.sh:**
- If upgrading from v1.0.1, devices may need remapping after update
- Serial number suffixes removed from port paths (restores v1.0.0 compatibility)

**install_mediamtx.sh:**
- Checksum verification now required by default (use --force to skip)
- Update command uses MediaMTX's native --upgrade when available

**lyrebird-wizard.sh:**
- Deprecated in favor of lyrebird-orchestrator.sh
- Wizard maintained for backwards compatibility but not actively developed

## Contributing

Contributions are welcome! Please follow these guidelines:

1. **Fork the repository**
   ```bash
   git clone https://github.com/YOUR_USERNAME/LyreBirdAudio.git
   cd LyreBirdAudio
   ```

2. **Create a feature branch**
   ```bash
   git checkout -b feature/improvement
   ```

3. **Make your changes following these standards:**
   - All scripts must pass `bash -n` syntax check
   - All scripts must pass `shellcheck` with no errors
   - Use comprehensive error handling with try/catch patterns
   - Add debug output for troubleshooting
   - Update relevant documentation
   - Follow the single-responsibility principle
   - Maintain backwards compatibility where possible

4. **Test thoroughly on target platforms:**
   - Ubuntu 20.04+
   - Debian 11+
   - Raspberry Pi OS (if applicable)
   - Test with multiple USB devices
   - Verify all commands and menu options

5. **Submit a pull request:**
   - Provide clear description of changes
   - Reference any related issues
   - Include test results
   - Update version history in README

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

## Credits

### Original Inspiration

This project was inspired by [cberge908's gist](https://gist.github.com/cberge908/ab7ddc1ac46fd63bb6935cd1f4341112) which provided the foundational concept for USB audio device streaming with MediaMTX. LyreBirdAudio extends this concept into a production-ready system with comprehensive error handling, persistent device management, and professional-grade reliability.

### Dependencies

- **[MediaMTX](https://github.com/bluenviron/mediamtx)** - High-performance real-time media server by bluenviron
- **[FFmpeg](https://ffmpeg.org/)** - Complete multimedia framework
- **Linux kernel udev** - Device management
- **ALSA Project** - Linux audio subsystem

### Contributors

Special thanks to all contributors who have helped improve LyreBirdAudio.

## License

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

---

**Project Links:**
- GitHub: https://github.com/tomtom215/LyreBirdAudio
- Issues: https://github.com/tomtom215/LyreBirdAudio/issues
- Discussions: https://github.com/tomtom215/LyreBirdAudio/discussions

**MediaMTX:**
- GitHub: https://github.com/bluenviron/mediamtx
- Documentation: https://github.com/bluenviron/mediamtx#documentation

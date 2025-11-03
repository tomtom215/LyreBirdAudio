# LyreBirdAudio

**License:** Apache 2.0  
**Platform:** Linux (Ubuntu/Debian/Raspberry Pi OS)  
**Core Engine:** MediaMTX (latest stable recommended)

**Author:** Tom F - https://github.com/tomtom215 

**Copyright:** Tom F & LyreBirdAudio contributors

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
- [Diagnostics & Monitoring](#diagnostics--monitoring)
- [Troubleshooting](#troubleshooting)
- [Performance & Optimization](#performance--optimization)
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

This project was inspired by my desire to listen to birds using some USB microphones and Mini PCs I had lying around. I had first found [cberge908](https://gist.github.com/cberge908/ab7ddc1ac46fd63bb6935cd1f4341112)'s original script for launching MediaMTX but I quickly learned there were a lot more edge cases that needed to be handled in order for it to run reliably 24x7. LyreBird Audio is my solution to those edge cases.

**If you like this project, please star the repo!**

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
┌────────────────────────────────────────────────────────────┐
│                     Client Applications                    │
│            (VLC, FFplay, OBS, Custom RTSP Clients)         │
└────────────────────┬───────────────────────────────────────┘
                     │ RTSP://host:8554/DeviceName
┌────────────────────▼───────────────────────────────────────┐
│                       MediaMTX                             │
│                  (Real-time Media Server)                  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ • RTSP Server (port 8554)                            │  │
│  │ • RTP/RTCP (ports 8000-8001)                         │  │
│  │ • HTTP API (port 9997)                               │  │
│  │ • WebRTC Support                                     │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────┬───────────────────────────────────────┘
                     │ Managed by
┌────────────────────▼───────────────────────────────────────┐
│              Stream Manager / systemd                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ • Process lifecycle management                       │  │
│  │ • Automatic stream recovery                          │  │
│  │ • Health monitoring                                  │  │
│  │ • Real-time scheduling                               │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────┬───────────────────────────────────────┘
                     │ Captures from
┌────────────────────▼───────────────────────────────────────┐
│                  FFmpeg Audio Pipeline                     │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ • ALSA capture (hw:Device_N)                         │  │
│  │ • Audio encoding (AAC/Opus/PCM)                      │  │
│  │ • RTSP publishing to MediaMTX                        │  │
│  │ • Buffer management                                  │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────┬───────────────────────────────────────┘
                     │ Reads from
┌────────────────────▼───────────────────────────────────────┐
│              Persistent Device Layer (udev)                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ • /dev/snd/by-usb-port/Device_1 → /dev/snd/pcmC0D0c  │  │
│  │ • /dev/snd/by-usb-port/Device_2 → /dev/snd/pcmC1D0c  │  │
│  │ • Consistent naming across reboots                   │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────┬───────────────────────────────────────┘
                     │ Maps
┌────────────────────▼───────────────────────────────────────┐
│               Physical USB Audio Devices                   │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ • USB Port 1-1.4: Audio Interface A                  │  │
│  │ • USB Port 1-1.5: Audio Interface B                  │  │
│  │ • USB Port 2-1.2: USB Microphone                     │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
```

### Management Architecture

LyreBirdAudio uses a modular, single-responsibility architecture where each script handles one specific domain:

```
┌─────────────────────────────────────────────────────────────┐
│                 lyrebird-orchestrator.sh v2.0.0             │
│                 (Unified Interface)                         │
│  • Interactive TUI for all operations                       │
│  • Delegates to specialized scripts                         │
│  • No duplicate business logic                              │
│  • Consistent error handling & feedback                     │
└─────────┬───────────────────────────────────────────────────┘
          │
          ├────> install_mediamtx.sh v2.0.0
          │       • MediaMTX installation & updates
          │       • Binary management
          │       • Service configuration
          │       • Built-in upgrade support
          │
          ├────> mediamtx-stream-manager.sh v1.3.2
          │       • FFmpeg process lifecycle
          │       • Stream health monitoring
          │       • Automatic recovery
          │       • MediaMTX start/stop/restart
          │       • Individual & multiplex streaming modes
          │
          ├────> usb-audio-mapper.sh v1.2.1
          │       • USB device detection
          │       • udev rule generation
          │       • Persistent naming
          │       • Interactive & non-interactive modes
          │
          ├────> lyrebird-updater.sh v1.4.2
          │       • Git-based version management
          │       • Safe version switching
          │       • Update checking
          │       • Rollback capabilities
          │
          └────> lyrebird-diagnostics.sh v1.0.0
                  • Comprehensive system health checks
                  • USB device validation
                  • MediaMTX service monitoring
                  • RTSP connectivity testing
                  • Quick/full/debug diagnostic modes
```

## Features

### Core Capabilities

- **Persistent USB Audio Device Management**: Consistent ALSA device naming across reboots using udev rules based on physical USB port topology
- **Real-time RTSP Streaming**: Low-latency audio streaming via MediaMTX with AAC/Opus/PCM codec support
- **Automatic Stream Recovery**: Self-healing FFmpeg processes that restart on failure with exponential backoff
- **Zero-Downtime Updates**: MediaMTX updates preserve active streams with automatic restart
- **Multi-Device Streaming**: Simultaneous streaming from multiple USB audio devices
- **Flexible Streaming Modes**: Individual per-device streams or multiplexed combined streams

### Management Features

- **Unified Management Interface**: Interactive orchestrator provides consistent access to all components
- **Comprehensive Diagnostics**: Built-in health checking with quick, full, and debug modes
- **Git-Based Version Control**: Safe version switching with automatic stashing and rollback
- **Resource Monitoring**: CPU, memory, and file descriptor tracking with threshold alerting
- **Extensive Logging**: Structured logs for all components with troubleshooting support

### Production Quality

- **Enterprise-Grade Error Handling**: Comprehensive error detection with graceful degradation
- **Lock-Based Concurrency Control**: Prevents race conditions in multi-process scenarios
- **Atomic Operations**: File writes and state transitions use atomic operations
- **Signal Handling**: Clean shutdown on SIGTERM/SIGINT/SIGHUP/SIGQUIT
- **Platform Detection**: Automatic OS and architecture detection for MediaMTX installation

## System Requirements

### Minimum Requirements

- **Operating System**: Linux kernel 4.0+ (Ubuntu 20.04+, Debian 11+, Raspberry Pi OS)
- **Architecture**: x86_64, ARM64, ARMv7, ARMv6
- **Processor**: 1 CPU core (2+ recommended for multiple streams)
- **Memory**: 512MB RAM (1GB+ recommended for multiple streams)
- **Storage**: 100MB for MediaMTX and scripts

### Software Dependencies

**Required:**
- bash 4.0+
- ffmpeg with ALSA support
- curl or wget
- tar, gzip
- systemd (for service management)
- udev
- git 2.0+ (for version management)

**Optional but Recommended:**
- jq (JSON parsing for MediaMTX API)
- lsof or ss (port monitoring)
- shellcheck (development)
- logrotate (log management)

### Audio Requirements

- USB audio device with ALSA driver support
- ALSA utilities (arecord, alsamixer)
- Sufficient USB bandwidth for desired sample rates

## Installation

### Quick Start

```bash
# Clone the repository
git clone https://github.com/tomtom215/LyreBirdAudio.git
cd LyreBirdAudio

# Make scripts executable
chmod +x *.sh

# Launch the orchestrator (recommended)
sudo ./lyrebird-orchestrator.sh
```

### Using the Orchestrator

The orchestrator provides a guided setup workflow:

1. **Install MediaMTX** (Main Menu → 1)
2. **Configure USB Devices** (Main Menu → 3)
3. **Start Audio Streams** (Main Menu → 2)
4. **Verify with Diagnostics** (Main Menu → 4)

### Manual Installation

```bash
# Install MediaMTX
sudo ./install_mediamtx.sh install

# Map USB audio devices
sudo ./usb-audio-mapper.sh

# Start streams
sudo ./mediamtx-stream-manager.sh start

# Verify installation
sudo ./lyrebird-diagnostics.sh quick
```

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

## Components

### lyrebird-orchestrator.sh v2.0.0

**Purpose**: Unified management interface for all LyreBirdAudio operations

**Key Features:**
- Interactive menu system with intuitive navigation
- MediaMTX installation, updates, and service control
- Stream lifecycle management (start/stop/restart/status)
- USB device configuration with interactive and non-interactive modes
- Version management operations (check updates, upgrade, switch versions)
- Comprehensive diagnostics (quick/full/debug modes)
- Centralized log viewing for all components
- System state monitoring and display

**Usage:**
```bash
sudo ./lyrebird-orchestrator.sh
```

**Requirements:**
- Must run as root
- Requires interactive terminal
- Locates component scripts automatically

### install_mediamtx.sh v2.0.0

**Purpose**: MediaMTX installation and lifecycle management

**Key Features:**
- Automatic platform detection (Linux/Darwin/FreeBSD, multiple architectures)
- GitHub release fetching with fallback parsers
- Checksum verification (SHA256)
- Built-in upgrade support for MediaMTX 1.15.0+
- Systemd service creation and management
- Configuration file generation
- Service user creation
- Dry-run mode for testing

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

### mediamtx-stream-manager.sh v1.3.2

**Purpose**: Automated audio stream configuration and lifecycle management

**Key Features:**
- Automatic USB audio device detection
- Individual and multiplex streaming modes
- FFmpeg process management with wrapper scripts
- Automatic stream recovery on failure
- Resource monitoring (CPU, file descriptors)
- Lock-based concurrency control
- Systemd service integration
- Health monitoring with threshold alerting
- Dynamic MediaMTX configuration generation

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

**Usage:**
```bash
# Start streams
sudo ./mediamtx-stream-manager.sh start

# Stop streams
sudo ./mediamtx-stream-manager.sh stop

# Emergency stop
sudo ./mediamtx-stream-manager.sh force-stop

# Restart
sudo ./mediamtx-stream-manager.sh restart

# Check status
sudo ./mediamtx-stream-manager.sh status

# View configuration
sudo ./mediamtx-stream-manager.sh config

# Monitor resources
sudo ./mediamtx-stream-manager.sh monitor

# Install systemd service
sudo ./mediamtx-stream-manager.sh install
```

**Options:**
- `-m <mode>`: Stream mode (individual or multiplex)
- `-f <filter>`: Multiplex filter type (amix or amerge)
- `-n <name>`: Custom multiplex stream name
- `-d, --debug`: Enable debug output

### usb-audio-mapper.sh v1.2.1

**Purpose**: Create persistent udev rules for USB audio devices

**Key Features:**
- Interactive device selection wizard
- Non-interactive mode for automation
- Physical USB port path detection
- Vendor/Product ID validation
- Friendly name generation
- Duplicate rule prevention
- Backwards compatibility with v1.0.0 (no serial number suffixes)
- Test mode for port detection validation

**Usage:**

**Interactive Mode** (recommended for first-time setup):
```bash
sudo ./usb-audio-mapper.sh
```

**Non-Interactive Mode** (for automation):
```bash
sudo ./usb-audio-mapper.sh -n \
  -d "MOVO X1" \
  -v 2e88 \
  -p 4610 \
  -f movo-x1
```

**Test Mode**:
```bash
sudo ./usb-audio-mapper.sh --test
```

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

**Generated Files:**
- `/etc/udev/rules.d/99-usb-soundcards.rules`: udev rules
- `/dev/snd/by-usb-port/Device_N`: Device symlinks (post-reboot)

### lyrebird-updater.sh v1.4.2

**Purpose**: Git-based version management for LyreBirdAudio repository

**Key Features:**
- Interactive version selection menu
- Automatic stashing of local changes
- Transaction-based operations with rollback
- Lock file protection against concurrent execution
- Self-update capability with process restart
- Network resilience with retries
- Git state validation and recovery
- Support for stable releases and development branches

**Usage:**

**Interactive Mode**:
```bash
./lyrebird-updater.sh
```

**Check for Updates**:
```bash
./lyrebird-updater.sh --status
```

**List Available Versions**:
```bash
./lyrebird-updater.sh --list
```

**Options:**
- `-v, --version`: Display version number
- `-h, --help`: Show help information
- `-s, --status`: Show repository status
- `-l, --list`: List available versions

**Requirements:**
- Git 2.0+ installed
- Must run from within git clone (not standalone installation)
- Repository must have remote origin configured
- Recommended to run as normal user (not root/sudo)

**Interactive Menu:**
1. Check for Updates
2. Upgrade to Latest Version
3. Switch to Specific Version
4. View Available Versions
5. Show Current Version
6. System Information

### lyrebird-diagnostics.sh v1.0.0

**Purpose**: Comprehensive system health checking and diagnostics

**Key Features:**
- Three diagnostic modes (quick/full/debug)
- USB audio device detection and validation
- MediaMTX service health monitoring
- RTSP connectivity testing
- FFmpeg process validation
- System resource utilization
- Log file analysis
- Actionable error reporting
- GitHub issue submission guidance

**Diagnostic Modes:**

**Quick Mode** (essential checks only):
```bash
sudo ./lyrebird-diagnostics.sh quick
```

**Full Mode** (comprehensive analysis):
```bash
sudo ./lyrebird-diagnostics.sh full
```

**Debug Mode** (maximum verbosity):
```bash
sudo ./lyrebird-diagnostics.sh debug
```

**Usage:**
```bash
# Run quick diagnostic
sudo ./lyrebird-diagnostics.sh quick

# Run full diagnostic
sudo ./lyrebird-diagnostics.sh full

# Run debug diagnostic with increased timeout
sudo ./lyrebird-diagnostics.sh debug --timeout 120

# Quiet mode (errors only)
sudo ./lyrebird-diagnostics.sh full --quiet

# No color output
sudo ./lyrebird-diagnostics.sh full --no-color
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

MediaMTX configuration files:
- `/etc/mediamtx/mediamtx.yml`: Main configuration
- `/etc/mediamtx/audio-devices.conf`: Audio device mappings

Example audio device configuration:
```
Device_1:hw:Device_1:48000:2
Device_2:hw:Device_2:44100:1
HighQuality:hw:Device_3:96000:2
```

Format: `StreamName:ALSADevice:SampleRate:Channels`

## Usage

### Orchestrator Interface

The recommended way to use LyreBirdAudio is through the unified orchestrator interface:

```bash
sudo ./lyrebird-orchestrator.sh
```

**Main Menu:**
1. MediaMTX Management (install, update, service control)
2. Stream Management (start, stop, restart, status, modes)
3. USB Device Configuration (interactive/non-interactive mapping)
4. System Diagnostics (quick/full/debug health checks)
5. Version Management (check updates, upgrade, switch versions)
6. Logs & Status (view component logs, system health)
7. Exit

**Navigation:**
- Enter menu number and press Enter
- Use "Back" options to return to previous menus
- Press Ctrl+C to exit at any time

### Command Reference

#### MediaMTX Management

```bash
# Install MediaMTX
sudo ./install_mediamtx.sh install

# Install specific version
sudo ./install_mediamtx.sh -V v1.15.0 install

# Update to latest
sudo ./install_mediamtx.sh update

# Check installation status
./install_mediamtx.sh status

# Verify installation integrity
sudo ./install_mediamtx.sh verify

# Uninstall (with prompts)
sudo ./install_mediamtx.sh uninstall

# Force uninstall (no prompts)
sudo ./install_mediamtx.sh -f uninstall
```

#### Stream Management

```bash
# Start individual streams
sudo ./mediamtx-stream-manager.sh start

# Start multiplex stream with mixing
sudo ./mediamtx-stream-manager.sh -m multiplex -f amix start

# Stop all streams
sudo ./mediamtx-stream-manager.sh stop

# Emergency stop (force kill)
sudo ./mediamtx-stream-manager.sh force-stop

# Restart gracefully
sudo ./mediamtx-stream-manager.sh restart

# Check status
sudo ./mediamtx-stream-manager.sh status

# Monitor resources
sudo ./mediamtx-stream-manager.sh monitor
```

#### USB Device Configuration

```bash
# Interactive mapping wizard
sudo ./usb-audio-mapper.sh

# Non-interactive mapping
sudo ./usb-audio-mapper.sh -n \
  --device "USB Microphone" \
  --vendor 0d8c \
  --product 0014 \
  --friendly usb-mic-1

# Test port detection
sudo ./usb-audio-mapper.sh --test

# Enable debug output
sudo DEBUG=true ./usb-audio-mapper.sh
```

#### Version Management

```bash
# Check for updates
./lyrebird-updater.sh --status

# List available versions
./lyrebird-updater.sh --list

# Interactive version manager
./lyrebird-updater.sh

# Show version
./lyrebird-updater.sh --version
```

#### Diagnostics

```bash
# Quick health check
sudo ./lyrebird-diagnostics.sh quick

# Full system diagnostic
sudo ./lyrebird-diagnostics.sh full

# Debug mode with verbose output
sudo ./lyrebird-diagnostics.sh debug --verbose

# Quiet mode for scripts
sudo ./lyrebird-diagnostics.sh full --quiet
```

### Advanced Operations

#### Custom Audio Configuration

Edit device configuration:
```bash
sudo nano /etc/mediamtx/audio-devices.conf
```

Format: `StreamName:ALSADevice:SampleRate:Channels`

Example configurations:
```
Device_1:hw:Device_1:48000:2        # Standard stereo at 48kHz
Device_2:hw:Device_2:44100:1        # Mono at 44.1kHz
HighQuality:hw:Device_3:96000:2     # High sample rate stereo
Studio:hw:Device_4:48000:8          # Multi-channel interface
```

After editing, restart streams:
```bash
sudo ./mediamtx-stream-manager.sh restart
```

#### MediaMTX Configuration

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

#### Backup and Restore

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

#### Debug Mode

Enable debug output for all scripts:
```bash
export DEBUG=1

# Now run any command
sudo ./mediamtx-stream-manager.sh status
sudo ./usb-audio-mapper.sh --test
```

#### Log Viewing

```bash
# View MediaMTX output
sudo tail -f /var/log/mediamtx.out

# View stream manager log
sudo tail -f /var/log/mediamtx-stream-manager.log

# View FFmpeg stream logs
sudo tail -f /var/lib/mediamtx-ffmpeg/*.log

# View orchestrator log
sudo tail -f /var/log/lyrebird-orchestrator.log

# View diagnostics log
sudo tail -f /var/log/lyrebird-diagnostics.log
```

## Configuration

### System Configuration Files

| File | Purpose | Format |
|------|---------|--------|
| `/etc/mediamtx/mediamtx.yml` | MediaMTX main configuration | YAML |
| `/etc/mediamtx/audio-devices.conf` | Audio device mappings | Text (colon-separated) |
| `/etc/udev/rules.d/99-usb-soundcards.rules` | USB device persistence rules | udev syntax |
| `/etc/systemd/system/mediamtx.service` | MediaMTX systemd service | INI-style |
| `/etc/systemd/system/mediamtx-audio.service` | Stream manager systemd service | INI-style |

### Runtime State Files

| File/Directory | Purpose |
|----------------|---------|
| `/var/run/mediamtx-audio.pid` | Stream manager PID file |
| `/var/run/mediamtx-audio.lock` | Stream manager lock file |
| `/var/lib/mediamtx-ffmpeg/` | FFmpeg PID files and wrapper scripts |
| `/var/log/mediamtx.out` | MediaMTX output log |
| `/var/log/mediamtx-stream-manager.log` | Stream manager log |
| `/var/log/lyrebird-orchestrator.log` | Orchestrator log |
| `/var/log/lyrebird-diagnostics.log` | Diagnostics log |

### Environment Variables

**Stream Manager Configuration:**
```bash
export MEDIAMTX_CONFIG_DIR=/etc/mediamtx
export MEDIAMTX_BINARY=/usr/local/bin/mediamtx
export MEDIAMTX_HOST=localhost
export MEDIAMTX_API_PORT=9997
export STREAM_STARTUP_DELAY=10
export USB_STABILIZATION_DELAY=5
export RESTART_STABILIZATION_DELAY=15
export MAX_CPU_WARNING=20
export MAX_CPU_CRITICAL=40
export MAX_FD_WARNING=500
export MAX_FD_CRITICAL=1000
```

**Installer Configuration:**
```bash
export INSTALL_PREFIX=/usr/local
export CONFIG_DIR=/etc/mediamtx
export STATE_DIR=/var/lib/mediamtx
export SERVICE_USER=mediamtx
export SERVICE_GROUP=mediamtx
```

**Debug Mode:**
```bash
export DEBUG=1  # Enable debug output for all scripts
```

### Audio Configuration Defaults

Default audio settings in `mediamtx-stream-manager.sh`:
- Sample Rate: 48000 Hz
- Channels: 2 (stereo)
- Codec: opus
- Bitrate: 128k

Override via `/etc/mediamtx/audio-devices.conf`:
```
CustomStream:hw:Device_1:96000:2
MonoMic:hw:Device_2:44100:1
```

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

### Update Behavior

- Automatically stashes local changes before switching versions
- Restores stashed changes after version switch (with conflict detection)
- Preserves executable permissions on all scripts
- Self-update capability when updater script changes
- Transaction-based operations with automatic rollback on failure
- Lock file prevents concurrent executions

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

### Diagnostic Exit Codes

- `0`: All checks passed
- `1`: Warnings detected (system functional but needs attention)
- `2`: Failures detected (system degraded or non-functional)
- `127`: Prerequisites missing (cannot complete diagnostics)

### Integration with Orchestrator

The orchestrator integrates diagnostics into multiple workflows:

1. **Quick Health Check** (Main Menu → 6 → 5)
   - Fast system health verification
   - Run before major operations

2. **Full Diagnostic** (Main Menu → 4 → 2)
   - Comprehensive system analysis
   - Recommended for troubleshooting

3. **Debug Diagnostic** (Main Menu → 4 → 3)
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

## Troubleshooting

### Common Issues

#### No USB Audio Devices Detected

**Symptoms**: Stream manager reports no devices found

**Diagnosis**:
```bash
arecord -l  # List ALSA devices
lsusb       # List USB devices
```

**Solutions**:
- Verify USB device is connected
- Check ALSA drivers are loaded: `lsmod | grep snd`
- Ensure device has audio capture capability
- Try different USB port

#### Streams Not Starting

**Symptoms**: Stream manager starts but streams don't appear

**Diagnosis**:
```bash
sudo ./lyrebird-diagnostics.sh quick
ps aux | grep ffmpeg
sudo tail /var/lib/mediamtx-ffmpeg/*.log
```

**Solutions**:
- Check FFmpeg logs for errors
- Verify MediaMTX is running: `systemctl status mediamtx`
- Ensure USB devices are mapped: `ls -la /dev/snd/by-usb-port/`
- Restart streams: `sudo ./mediamtx-stream-manager.sh restart`

#### RTSP Connection Refused

**Symptoms**: Cannot connect to RTSP streams

**Diagnosis**:
```bash
sudo lsof -i :8554
curl -v http://localhost:9997/v3/paths/list
```

**Solutions**:
- Verify MediaMTX is running
- Check firewall rules: `sudo ufw status`
- Test local connection: `ffplay rtsp://localhost:8554/Device_1`
- Check MediaMTX logs: `sudo tail /var/log/mediamtx.out`

#### Device Names Change After Reboot

**Symptoms**: Device_1 becomes Device_2 after reboot

**Diagnosis**:
```bash
cat /etc/udev/rules.d/99-usb-soundcards.rules
udevadm control --reload-rules
udevadm trigger
ls -la /dev/snd/by-usb-port/
```

**Solutions**:
- Re-run USB mapper: `sudo ./usb-audio-mapper.sh`
- Reboot system for udev rules to take effect
- Verify physical USB port hasn't changed

#### High CPU Usage

**Symptoms**: System becomes unresponsive

**Diagnosis**:
```bash
sudo ./mediamtx-stream-manager.sh monitor
top -p $(pgrep -f ffmpeg | tr '\n' ',')
```

**Solutions**:
- Reduce sample rate in audio-devices.conf
- Use lower bitrate encoding
- Reduce number of simultaneous streams
- Check for FFmpeg process accumulation

#### MediaMTX Won't Update

**Symptoms**: Update command fails

**Diagnosis**:
```bash
sudo ./install_mediamtx.sh status
curl -I https://api.github.com/repos/bluenviron/mediamtx/releases/latest
```

**Solutions**:
- Check network connectivity
- Verify GitHub is accessible
- Try specific version: `sudo ./install_mediamtx.sh -V v1.15.0 update`
- Use force flag: `sudo ./install_mediamtx.sh -f update`

#### Version Update Failed

**Symptoms**: Git update errors or conflicts

**Diagnosis**:
```bash
git status
git stash list
./lyrebird-updater.sh --status
```

**Solutions**:
- Stash local changes: `git stash`
- Reset to clean state: `git reset --hard origin/main`
- Switch to known good version via updater
- Check repository ownership: `stat -c %U .git/config`

### Debug Procedures

**Enable Verbose Logging**:
```bash
export DEBUG=1
sudo ./mediamtx-stream-manager.sh start
```

**Check All Logs**:
```bash
sudo tail -f /var/log/mediamtx.out
sudo tail -f /var/log/mediamtx-stream-manager.log
sudo tail -f /var/lib/mediamtx-ffmpeg/*.log
```

**Validate Configuration**:
```bash
/usr/local/bin/mediamtx --check /etc/mediamtx/mediamtx.yml
cat /etc/mediamtx/audio-devices.conf
```

**Test RTSP Manually**:
```bash
ffplay -i rtsp://localhost:8554/Device_1 -loglevel debug
```

**Check System Resources**:
```bash
sudo ./lyrebird-diagnostics.sh full
sudo ./mediamtx-stream-manager.sh monitor
```

### Getting Help

1. Run full diagnostics and save output:
   ```bash
   sudo ./lyrebird-diagnostics.sh full > diagnostics.txt 2>&1
   ```

2. Gather relevant logs:
   ```bash
   sudo tar -czf lyrebird-logs.tar.gz /var/log/mediamtx* /var/log/lyrebird*
   ```

3. Open GitHub issue with:
   - Diagnostic output
   - Log archive
   - System information (OS, kernel version)
   - Steps to reproduce

**Project Links:**
- Issues: https://github.com/tomtom215/LyreBirdAudio/issues
- Discussions: https://github.com/tomtom215/LyreBirdAudio/discussions

## Performance & Optimization

### Stream Optimization

**Codec Selection:**
- Opus: Best quality/bitrate ratio, low latency
- AAC: Wider compatibility, moderate latency
- PCM: Lossless, high bandwidth

**Sample Rate Selection:**
- 48000 Hz: Standard for professional audio
- 44100 Hz: CD quality, slightly lower bandwidth
- 96000 Hz: High-res audio, double bandwidth

**Bitrate Tuning:**
- 128k: Good quality for speech/music
- 96k: Acceptable for speech
- 256k: High quality music

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

# Increase for user
echo "mediamtx soft nofile 4096" | sudo tee -a /etc/security/limits.conf
echo "mediamtx hard nofile 8192" | sudo tee -a /etc/security/limits.conf
```

**Network Buffer Sizes:**
```bash
# Increase UDP buffer sizes
sudo sysctl -w net.core.rmem_max=26214400
sudo sysctl -w net.core.wmem_max=26214400
```

**USB Latency Optimization:**
```bash
# Reduce USB polling interval (if supported by device)
echo 1 | sudo tee /sys/bus/usb/devices/*/power/autosuspend
```

### Monitoring and Alerting

**Resource Monitoring:**
```bash
# Automated monitoring via cron
echo "*/5 * * * * /path/to/mediamtx-stream-manager.sh monitor" | sudo crontab -
```

**Log Rotation:**
```bash
# Configure logrotate for MediaMTX logs
sudo tee /etc/logrotate.d/mediamtx << EOF
/var/log/mediamtx*.log {
    daily
    rotate 7
    compress
    delaycompress
    notifempty
    create 0644 root root
}
EOF
```

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
   - Update documentation as needed

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

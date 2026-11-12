# LyreBirdAudio

RTSP audio streaming for USB microphones, built on MediaMTX and FFmpeg. A set of Bash scripts installs MediaMTX, gives every USB sound card a name that follows its USB port, publishes each microphone as an RTSP stream, and checks the streams from cron and systemd. It is meant for unattended use, for example monitoring bird activity with spare mini PCs. What has and has not been tested is listed under [System Requirements](#system-requirements) and [Testing](#testing).

**If you like or use this project, please "star" this repository!**

If you are using it in a cool or interesting way or at a large scale, please tell me about it in our GitHub Discussions for this repository!

**License:** Apache 2.0  
**Platform:** Linux with systemd (see [System Requirements](#system-requirements))  
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
- [Upgrading an Existing Node](#upgrading-an-existing-node)
- [Performance & Optimization](#performance--optimization)
- [Architecture & Design](#architecture--design)
- [Component Reference](#component-reference)
- [Advanced Topics](#advanced-topics)
- [Security Hardening](#security-hardening)
- [Recovery Procedures](#recovery-procedures)
- [Uninstallation & Cleanup](#uninstallation--cleanup)
- [Development & Contributing](#development--contributing)
- [License & Credits](#license--credits)

---

## Quick Start

**Which version this README describes.** It describes the `main` branch. The newest release tag, `v1.3.0`, was cut before the 2026-11 audit fixes and does not contain them: it has no `lyrebird-updater.sh --rollback`, no stream manager exit codes 8 and 9, no `/run/lyrebird/status.json`, and the MediaMTX configuration it writes puts the API and the metrics endpoint on every network interface (each of these can be checked with `git show v1.3.0:<file>`). Until a release that contains the fixes is tagged, install from `main` as shown below. `git describe --tags --abbrev=0` and the updater's "Switch to Latest Stable Release" both select `v1.3.0`, so do not use them to get what this README describes. [Version Management](#version-management) says how to pin a release later.

```bash
# 1. Clone and use the main branch
git clone https://github.com/tomtom215/LyreBirdAudio.git
cd LyreBirdAudio
git checkout main
chmod +x *.sh

# 2. Run guided setup (installs MediaMTX, maps devices, starts streams)
sudo ./lyrebird-orchestrator.sh
# Select: Quick Setup Wizard

# 3. Access your streams
# rtsp://your-ip:8554/device-name
```

The wizard has four steps: install MediaMTX, map the USB audio devices, start the streams, run quick diagnostics. At the end it reports, stream by stream, whether the stream is publishing and, if it is not, why.

Two things the wizard does not do:

- It does not install the systemd unit or the monitor cron job. Streams it starts run until the next reboot. For unattended use run `sudo ./lyrebird-stream-manager.sh install` afterwards ([Installation](#manual-installation)).
- It does not protect the streams. By default anyone who can reach port 8554 can publish to and read from them ([Security Hardening](#security-hardening)).

For manual installation, see [Installation](#installation).

---

## Features & Capabilities

### What This Project Does

- Publishes each USB microphone as its own RTSP stream through MediaMTX, or mixes several into one (multiplex mode).
- Keeps device names stable across reboots with udev rules tied to the USB port the card is plugged into.
- Reads what each card supports from `/proc/asound` and can write a matching audio configuration.
- Says, per stream, whether MediaMTX sees it publishing and whether bytes are flowing: `lyrebird-stream-manager.sh status`, or the document `/run/lyrebird/status.json`.
- Checks the streams every 5 minutes from cron and restarts the ones that stopped, within a per-hour budget.
- Updates from git, with history and rollback.

### Reliability: what recovers and what does not

| What goes wrong | What the suite does about it | Limit |
|-----------------|-------------------------------|-------|
| One stream's FFmpeg exits | Its wrapper restarts it after 10 s, doubling the wait up to 300 s; a run longer than 300 s resets the wait | After 5 failures in a row (`MAX_CONSECUTIVE_FAILURES`) or 50 restarts without a 300 s run (`MAX_WRAPPER_RESTARTS`) the wrapper stops. The monitor starts it again, at most `CRON_RESTART_MAX_PER_HOUR` (6) times per hour per stream |
| A wrapper died, or a microphone appeared or came back | The monitor starts the stream on its next run | The monitor is the cron job `install` writes (every 5 minutes). Without it, nothing does |
| A wrapper is alive but its MediaMTX path is not ready | After `DEEP_HEALTH_MAX_STRIKES` (3) monitor runs in a row, the monitor restarts the stream | Needs an API that answers. A refused connection, a 401/403 or a 5xx never counts against a stream |
| MediaMTX exits | Under systemd, `Restart=always` starts the unit again after 30 s (at most 10 starts in 20 minutes). The monitor also starts MediaMTX when it is gone and `start` was run and `stop` was not | The monitor's restarts share the 6-per-hour budget; when it is used up the monitor exits 7 and logs that it did not start MediaMTX |
| The file descriptors or CPU of MediaMTX or FFmpeg pass the critical level, or there are more wrapper processes than streams | The monitor exits 2 and the cron job restarts `mediamtx-audio` | Thresholds are settings (`MAX_FD_CRITICAL`, `MAX_CPU_CRITICAL`). A full disk, low memory or a lost network are logged and make the monitor exit 1, but restarting would not help, so nothing is restarted |
| A microphone delivers silence | The monitor reads the published stream for 3 seconds on each run and logs a `DEAD MIC` error once per silence episode (60 seconds of silence by default) | Log line only: no restart, no metric, no alert. The -60 dB threshold was checked against digital silence and a test tone, not against a real dead microphone |
| The machine hangs | Nothing in this project | There is **no watchdog**: no software watchdog, no hardware watchdog code and no `WatchdogSec=` in the unit. A hardware watchdog is systemd's `RuntimeWatchdogSec=` in `/etc/systemd/system.conf` or a watchdog daemon; this project neither configures nor tests either |
| Power is cut | The unit starts at boot if it was enabled | Recording kept in RAM (the default) is gone; nothing in the suite tests power-cut durability |

The "heartbeat" is the Unix time of the last monitor run, written to `/run/mediamtx-audio.heartbeat` on every run (also while MediaMTX is down). It shows that the monitor ran; it does not show that any stream is up (`lyrebird_stream_up` and `lyrebird_api_up` do). No heartbeat service exists. A node whose cron job is missing or whose monitor never runs gets none of the recoveries above that depend on it.

### Project Origin

This project was inspired by monitoring bird activity using USB microphones and spare Mini PCs. After discovering cberge908's original MediaMTX launcher script, it became clear that unattended operation needed many edge cases handled. LyreBirdAudio is the result of that work.

### Technical Approach

**USB Device Persistence:**
- Maps devices to physical USB ports using udev rules
- Removes naming conflicts caused by USB enumeration order
- Supports multiple identical devices on different ports

**Stream Management:**
- A generated wrapper script per stream runs FFmpeg and restarts it with exponential backoff (10 s to 300 s)
- MediaMTX health is read from its API; stream state is written to the status document
- Processes are identified by PID and start time, never by name; shutdown is SIGTERM, then SIGKILL after a timeout, for the whole process tree
- A cron job runs the monitor every 5 minutes

**Hardware Detection:**
- `lyrebird-mic-check.sh` reads `/proc/asound` and does not open the devices, so it does not interrupt a running stream
- Detects sample rates, channels and formats
- Warns about USB audio adapter chips whose capabilities are not the microphone's

**Resource Monitoring:**
- The monitor checks CPU and file descriptors of its own processes, system memory, disk space and network reachability against configurable thresholds, and logs what it finds
- `lyrebird-diagnostics.sh` reports audio subsystem conflicts and suggests remediation steps

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
|  | * card id mic-left -> hw:CARD=mic-left             |  |
|  | * /dev/sound/by-id/mic-left -> ../snd/controlC0    |  |
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
          +----> lyrebird-stream-manager.sh
          |       * FFmpeg process lifecycle management
          |       * Stream health monitoring via API
          |       * Automatic recovery with exponential backoff
          |       * Individual & multiplex streaming modes
          |       * Resource monitoring (CPU, FDs)
          |       * Cron-based health checking
          |
          +----> usb-audio-mapper.sh
          |       * USB device detection via sysfs
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

This section keeps three things apart: what the scripts check when they start, what the test suite ran on, and what nobody has tested.

### What the test suite ran on

- **Linux, x86_64, Bash 5.2, FFmpeg 6.1.1, systemd-analyze 255.** The suite also runs in CI on the `ubuntu-latest` runner.
- **MediaMTX 1.15.0, 1.18.0, 1.19.0, 1.21.1, 1.21.2 and 1.21.3**: the live tests start each of these real binaries (checksum-pinned by `tests/fetch_mediamtx.sh`). Other versions are not part of the suite.
- **No real systemd manager.** Unit files are checked with `systemd-analyze verify`; nothing starts a unit, so boot ordering, `Conflicts=`, the start limit and the sandbox directives have not been exercised on a running system.
- **No real USB hardware.** The stream manager is tested against fake `/proc/asound` and `/dev/snd` trees. Only `usb-audio-mapper.sh` was tested end to end on real Linux kernels with a real `systemd-udevd` (in QEMU: [docs/ENGINEERING-REVIEW-2026-07.md](docs/ENGINEERING-REVIEW-2026-07.md), section 9).
- **No ARM, no Bash 4.x, no macOS or BSD.** Nothing in this README about those is a test result.

### Operating system and architecture

- **Linux with systemd.** `usb-audio-mapper.sh` refuses to run on anything else (exit 4); the stream manager reads `/proc/asound` and manages a systemd unit.
- **Distributions.** The suite ran on Ubuntu (24.04). Debian and Raspberry Pi OS are the intended targets but nothing in the suite runs on them.
- **Architecture.** `install_mediamtx.sh` maps `uname -m` (`x86_64`, `i386`/`i686`, `aarch64`/`arm64`, `armv7*`/`armhf`, `armv6*`) to the name of a MediaMTX release asset (`amd64`, `386`, `arm64`, `armv7`, `armv6`) and downloads that asset. The suite ran on x86_64 only. That the installer picks the right name on an ARM board, that MediaMTX publishes an asset for every one of those names, and that FFmpeg and the scripts perform acceptably on a Pi Zero or other ARMv6 hardware were not checked. The installer also recognises macOS and FreeBSD, but the rest of the suite does not run there.

### Bash

Every script that checks its Bash version checks for 4.0 or newer (the diagnostics for 4.4), but several use features that appeared later. This table comes from searching the scripts for the features by version; the suite ran on Bash 5.2 only, so every figure below is read from the code and none was run.

| Script | Version it checks for | Newest Bash feature found in its code |
|--------|-----------------------|---------------------------------------|
| `usb-audio-mapper.sh` | 4.0 | 4.0 (`${var^^}`) |
| `lyrebird-updater.sh` | 4.0 | 4.1 (`exec {fd}>` redirections) |
| `lyrebird-metrics.sh` | none | 4.1 (`{fd}` redirections) |
| `install_mediamtx.sh` | 4.0 | 4.0 by itself; 4.2 once it loads `lyrebird-common.sh` (`install` does) |
| `lyrebird-common.sh` | 4.0 | 4.2 (`declare -gA`) |
| `lyrebird-alerts.sh`, `lyrebird-storage.sh` | none | 4.2 (`declare -gA`) |
| `lyrebird-stream-manager.sh` | none | 4.2 (`declare -g`, `[[ -v`), 4.1 (`{fd}`) |
| `lyrebird-orchestrator.sh` | 4.0 | 4.2 (`[[ -v`) |
| `lyrebird-mic-check.sh` | none | 4.3 (`${array[-1]}`) |
| `lyrebird-diagnostics.sh` | 4.4 | 4.2 (`declare -g`) |

Treat 4.4 as the lowest version for the whole suite and 5.2 as the only one that has been run. Check yours with `bash --version`.

### Software

Required by the stream manager (`start` stops with exit 3 and names what is missing): `ffmpeg` (with ALSA input), `jq`, `arecord` (`alsa-utils`), `curl`, and the MediaMTX binary. Also needed:

| Needed by | Tool |
|-----------|------|
| stream manager | `flock` (`util-linux`), systemd (for the unit), cron (for the monitor job); `setsid`, `lsof` or `ss` are optional (without `lsof` and `ss`, `start` warns and does not check that the ports are free) |
| `usb-audio-mapper.sh` | `udevadm`, root; `awk grep sed sort tr mktemp readlink dirname basename head` |
| `lyrebird-updater.sh` | `git` 2.0 or newer, `awk`, `sed`, `grep`, `tput`, `flock`; the working copy must be a git clone of this repository with a remote named `origin` |
| `install_mediamtx.sh` | `curl`, `tar`, `mktemp`, `flock`, root; `sha256sum` or `shasum` (without one, the checksum cannot be verified and `install` needs `--force`); `jq` is optional (a fallback parser is used); systemd for the unit |
| `lyrebird-metrics.sh serve` | a netcat (OpenBSD `nc`, `ncat`, traditional/GNU `nc` or BusyBox `nc`) |
| `lyrebird-alerts.sh` | `curl`; `flock` for duplicate protection (without it alerts are still sent) |
| troubleshooting | `lsusb` (`usbutils`), `alsamixer` (`alsa-utils`) |
| optional | `logrotate` (the stream manager writes `/etc/logrotate.d/mediamtx` when it is present); `shellcheck`, `shfmt`, `bashate`, `bats` for development |

FFmpeg: the amix `normalize` option exists from FFmpeg 4.4; the manager asks FFmpeg whether it has it, and leaves it out for older versions. That path was tested with a stand-in `ffmpeg`, not with a real 4.2 or 4.3. No minimum FFmpeg version is claimed.

Hardware: a USB audio device with an ALSA driver and enough USB bandwidth for the sample rates you choose. No minimum CPU, memory or disk size was measured; see [Performance & Optimization](#performance--optimization) for what is and is not known. The stream manager's disk, memory and CPU thresholds are settings ([Environment Variables](#environment-variables)).

**Raspberry Pi and other small boards.** No limit on the number of microphones per board is claimed, because none was measured. Shared USB bandwidth and power are the usual limits; find yours by soak-testing the board with `tools/soak/` (see [Testing](#testing)) before relying on it.

---

## Installation

### Prerequisites

```bash
# Verify Bash version (see System Requirements; 4.4 or newer, 5.2 is the one that was tested)
bash --version

# Check root access
sudo -v

# Verify required commands
command -v lsusb udevadm git ffmpeg arecord jq curl flock
```

### Using the Orchestrator (Recommended)

The orchestrator is a menu that runs the other scripts. Its Quick Setup Wizard has four steps:

1. Install MediaMTX (`install_mediamtx.sh install`). An installer exit status of 7 ("already installed") does not stop the wizard.
2. Map the USB audio devices (`usb-audio-mapper.sh`, interactive).
3. Start the streams (`lyrebird-stream-manager.sh start`) and report the outcome per stream.
4. Run quick diagnostics.

```bash
# 1. Clone the repository (use main: see Quick Start for why not the newest tag)
git clone https://github.com/tomtom215/LyreBirdAudio.git
cd LyreBirdAudio
git checkout main
chmod +x *.sh

# 2. Launch the orchestrator
sudo ./lyrebird-orchestrator.sh

# 3. Select "Quick Setup Wizard" from the menu
```

The wizard does not generate an audio device configuration, does not detect hardware capabilities (both are in the menu under USB Device Management, options 4 to 6), and does not install the systemd unit or the monitor cron job. Streams it starts stop at the next reboot unless you run the `install` step below.

The scripts need to be executable after a clone (`chmod +x *.sh`): the repository does not store the executable bit for all of them.

### Manual Installation

For automation or when you prefer manual control:

```bash
# 1. Install MediaMTX (writes /etc/mediamtx/mediamtx.yml and mediamtx.service)
sudo ./install_mediamtx.sh install

# 2. Map USB devices (interactive)
sudo ./usb-audio-mapper.sh

# 3. Generate the audio device configuration (optional: without it every
#    stream uses the defaults)
sudo ./lyrebird-mic-check.sh -g

# 4. Run the streams under systemd, with the monitor cron job
sudo ./lyrebird-stream-manager.sh install
sudo systemctl enable --now mediamtx-audio
```

Instead of step 4 you can start the streams by hand with `sudo ./lyrebird-stream-manager.sh start`; they then run until the next reboot and nothing monitors them.

Notes on `install`:

- It writes `/etc/systemd/system/mediamtx-audio.service` and `/etc/cron.d/mediamtx-monitor`, both rendered from `config/` next to the script, and `/etc/logrotate.d/mediamtx` when `logrotate` is installed. It stops with exit 4 if `config/mediamtx-audio.service` is missing, so run it from the checkout.
- The unit and the cron job name the script by its absolute path at the time of `install`. If you move the checkout, run `install` again.
- It carries `-m`, `-f` and `-n` (stream mode, multiplex filter, multiplex name) into both files. Other settings (the ports, `RTSP_AUTH_MODE`, `LYREBIRD_START_POLICY` and so on) are not written into either file; [Environment Variables](#environment-variables) says how to give them to the service and to the cron job.
- `install` does not enable or start anything. The standalone `mediamtx.service` that step 1 wrote and `mediamtx-audio.service` cannot run together ([MediaMTX Integration](#which-unit-runs-mediamtx)).

### Verification

```bash
# Check system health
sudo ./lyrebird-diagnostics.sh quick

# View stream status (works without root, but then cannot identify the stream processes)
sudo ./lyrebird-stream-manager.sh status

# Access your streams
# rtsp://your-ip:8554/device-name
```

`device-name` is the name the card has in `/proc/asound/cards` when it is a lower-case name such as one given by `usb-audio-mapper.sh` (`mic-left` gives `rtsp://your-ip:8554/mic-left`); otherwise it is the device name made lower-case with every other character turned into `_`. `lyrebird-stream-manager.sh status` prints the real URLs.

**No reboot needed for USB mapping:** `usb-audio-mapper.sh` (4.0.0+) applies each name immediately and confirms it with the kernel. Check the result with `./usb-audio-mapper.sh --list`.

### Post-Installation

Access your streams at:
```
rtsp://hostname:8554/mic-left
rtsp://hostname:8554/mic-right
```

Test with VLC or ffplay:
```bash
ffplay rtsp://localhost:8554/mic-left
vlc rtsp://localhost:8554/mic-left
```

---

## Basic Usage

### Managing Streams

```bash
# Start all streams
sudo ./lyrebird-stream-manager.sh start

# Stop all streams
sudo ./lyrebird-stream-manager.sh stop

# Restart streams
sudo ./lyrebird-stream-manager.sh restart

# Check status
./lyrebird-stream-manager.sh status
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
sudo ./lyrebird-stream-manager.sh install  # Creates cron job
```

The cron monitor performs a **deep** health check: besides verifying each
stream's supervisor process exists, it asks the MediaMTX API whether the
stream is actually publishing audio. A stream that stays silent-side-up for
three consecutive checks (a hung FFmpeg, a stuck retry loop) is automatically
restarted, within a per-hour budget that prevents restart storms. No
configuration is needed — it is on by default and does nothing when the API
is briefly unreachable, so it never adds churn.

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

```

Settings without a device-specific value fall back to `DEFAULT_SAMPLE_RATE`,
`DEFAULT_CHANNELS`, `DEFAULT_BITRATE` and `DEFAULT_CODEC`. These are read from
the stream manager's environment (see
[Environment Variables](#environment-variables)), not from this file; setting
them here has no effect.

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
| `/var/log/lyrebird-stream-manager.log` | Stream manager log |
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

# Health monitoring (cron monitor)
DEEP_HEALTH_CHECK_ENABLED=true   # Also verify each stream is actually
                                 # publishing via the MediaMTX API, not just
                                 # that its supervisor process exists
DEEP_HEALTH_MAX_STRIKES=3        # Consecutive "not publishing" checks before
                                 # a stuck stream is restarted
CRON_RESTART_MAX_PER_HOUR=6      # Per-stream restart budget under cron
                                 # (prevents restart storms)

# Audio defaults (when not in config file)
DEFAULT_SAMPLE_RATE=48000
DEFAULT_CHANNELS=2
DEFAULT_CODEC=opus
DEFAULT_BITRATE=128k
DEFAULT_THREAD_QUEUE=8192
DEFAULT_ANALYZEDURATION=5000000
DEFAULT_PROBESIZE=5000000

# API and logging
MEDIAMTX_API_TIMEOUT=60
MEDIAMTX_LOG_MAX_SIZE=52428800  # 50MB
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
FFMPEG_LOG_DIR=/mnt/storage/logs ./lyrebird-stream-manager.sh start

# Increase startup delay for slow USB devices
STREAM_STARTUP_DELAY=20 ./lyrebird-stream-manager.sh start
```

**Typo-safe:** every numeric setting above is validated when the scripts
start. A value that isn't a plain number (e.g. `MAX_RESTART_DELAY=5min` or
`CRON_RESTART_MAX_PER_HOUR=unlimited`) is ignored and the built-in default is
used instead — a mistyped setting can never stop monitoring or streaming. The
same applies to the device config file: if it is ever corrupted (power loss
mid-write, SD-card wear), streams still start with safe defaults rather than
failing to come up.

### Multiplex Streaming

Combine multiple microphones into a single RTSP stream using FFmpeg audio filters. This is useful for centralized monitoring, recording all microphones together, or creating composite audio feeds.

#### amix Filter (Audio Mixing)

**Purpose:** Mix multiple audio inputs into a single output stream (downmix to stereo/mono).

```bash
# Mix all devices into one stereo stream
sudo ./lyrebird-stream-manager.sh -m multiplex -f amix start
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
sudo ./lyrebird-stream-manager.sh -m multiplex -f amerge start
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
sudo ./lyrebird-stream-manager.sh -m multiplex -n studio start
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
   - Managed by `lyrebird-stream-manager.sh`
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
sudo ./lyrebird-stream-manager.sh install

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
```

Fallback defaults (`DEFAULT_SAMPLE_RATE` and so on) come from the stream
manager's environment, not from this file.

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
./lyrebird-stream-manager.sh status
./lyrebird-mic-check.sh
```

### Common Issues

#### No USB Devices Found

```bash
# Check device detection
lsusb | grep -i audio
arecord -l

# Show USB sound cards, their ports and mappings
./usb-audio-mapper.sh --list

# Remap devices (applied and verified immediately)
sudo ./usb-audio-mapper.sh
```

#### Streams Won't Start

```bash
# Check logs
sudo tail -f /var/log/lyrebird-stream-manager.log
sudo tail -f /var/log/lyrebird/*.log

# Validate configuration
sudo ./lyrebird-mic-check.sh -V

# Force restart
sudo ./lyrebird-stream-manager.sh force-stop
sudo ./lyrebird-stream-manager.sh start

# Check for device conflicts
sudo lsof /dev/snd/*
```

#### Device Names Change After Reboot

**Symptoms**: Device_1 becomes Device_2 after reboot

**Diagnosis:**
```bash
./usb-audio-mapper.sh --list     # cards, ports, mappings; flags pre-4.0 rules
cat /proc/asound/cards           # mapped cards show their names here
ls -la /dev/sound/by-id/
```

**Solutions:**
- Re-run the USB mapper for each device: `sudo ./usb-audio-mapper.sh -n --card N -f NAME`.
  Rules written by mapper 1.2.1 and earlier never renamed any device; re-running replaces them.
- Verify the physical USB port hasn't changed (names are tied to the port)

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
sudo ./lyrebird-stream-manager.sh monitor
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
sudo ./lyrebird-stream-manager.sh start
```

**Check All Logs:**
```bash
sudo tail -f /var/log/mediamtx.out
sudo tail -f /var/log/lyrebird-stream-manager.log
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
sudo ./lyrebird-stream-manager.sh monitor
```

### Log Locations

**Service logs:**
- MediaMTX: `/var/log/mediamtx.out`
- Stream Manager: `/var/log/lyrebird-stream-manager.log`
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
  /var/log/lyrebird-stream-manager.log \
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
   sudo ./lyrebird-stream-manager.sh monitor
   ```

5. Check logs regularly:
   ```bash
   sudo tail -f /var/log/lyrebird-stream-manager.log
   ```

---

## Version Management

### Choosing a version

| Source | What it is | Use it for |
|--------|------------|------------|
| `main` | the development line; contains every fix this README describes | installing now |
| a release tag (`v1.3.0`, ...) | one fixed commit | pinning, once a release that has the fixes exists |
| any other branch | whatever its author pushed | testing only |

The newest tag, `v1.3.0`, does not contain the 2026-11 fixes ([Quick Start](#quick-start)). Whether a tag has them can be checked before you switch to it: `git ls-tree -r --name-only <tag> docs | grep REMEDIATION-2026-11` prints a file name for a tag that has them and nothing for `v1.3.0`. Pin a tag in production only after that check, then try newer versions on a spare node before upgrading the real one.

A release built by the current release workflow carries a source tarball (`LyreBirdAudio-<version>.tar.gz`, made with `git archive` of the tagged commit) and `SHA256SUMS`. Download both into one directory and run `sha256sum -c SHA256SUMS`. That proves the tarball is the published file; it is not a signature and says nothing about who published it, because releases are not signed. The updater needs a git clone, so a tarball install cannot be updated with it.

### The updater

`lyrebird-updater.sh` switches a git clone between versions and undoes an update that went wrong.

```bash
./lyrebird-updater.sh --status        # current version, branch and sync state
./lyrebird-updater.sh --list          # fetch and list available versions (needs the network)
./lyrebird-updater.sh --history       # past updates, rollbacks and failed updates (local, no network)
./lyrebird-updater.sh --rollback      # back to the version before the last update
./lyrebird-updater.sh --rollback v1.3.0   # to a release tag or a commit already in the clone
./lyrebird-updater.sh --migrate       # run the post-update migrations by hand
./lyrebird-updater.sh                 # the interactive menu
```

Run it as the user who owns the clone, not with `sudo`: started as root it asks for confirmation (declining exits with 9), and a clone owned by root is refused (exit 5). The menu:

| Key | Action |
|-----|--------|
| 1 | Switch to Latest Stable Release: the newest tag (today `v1.3.0`, which lacks the fixes) |
| 2 | Switch to Development Version: the repository's default branch (`main`; if both `main` and `develop` exist, `develop`) |
| 3 | Switch to Specific Version or Branch |
| 4 | Check for New Updates |
| 5 | Show Detailed Status |
| 6 | Discard All Changes & Reset |
| H, Q | Help, quit |

To follow `main`, use 2.

**What an update does**

- Asks to save your local changes in a git stash (`lyrebird-tx-...`), switches, and puts them back. If they conflict with the new version they stay in the stash and the exit status is 10; declining the question changes nothing and exits 9.
- Stops `mediamtx-audio` first when it is running, and starts it afterwards. When `lyrebird-stream-manager.sh` changed between the two versions, it runs that script's `install` again (keeping `Environment=` lines you added to the unit). That `install` is run without `-m`, `-f` and `-n`, so on a multiplex node run it again by hand with them afterwards, or the cron file is left in individual mode.
- Makes every tracked `*.sh` executable, and runs the migrations for renamed files (below).
- Keeps a journal in `<git-dir>/lyrebird-updater/` while it works. If it is killed or the power fails, the next run undoes the unfinished update (or, for a self-update, completes it). Your uncommitted changes are never discarded.
- Checks that the files it wrote match the target version, and syntax-checks its own new version before it re-runs itself.

The service handling was tested against a stand-in `systemctl`; it has not run against a real systemd manager.

**Rollback and history.** `--history` reads `<git-dir>/lyrebird-updater/history.log` (UTC time, kind, result, from, to). `--rollback` with no argument goes back to the version the last completed update came from; with an argument it goes to that release tag or commit, which must already be in the clone (a branch name is refused: exit 1; not in the clone: exit 6; no network is used). It is the update's own transaction, so it stops and restarts the service the same way. Rolling back to a release whose updater is older than 1.7.0 (`v1.3.0` ships 1.6.0) puts that updater in place, and that one has neither `--history` nor `--rollback`.

**Lock.** Every command except `--history` takes a kernel `flock` on `<git-dir>/lyrebird-updater/updater.lock` (never removed: there is no stale lock to clean up). "Lock held by process ..." means another updater is running; wait or stop that process. After `LYREBIRD_UPDATER_LOCK_WAIT` seconds (30) the run exits 7. `flock` must be installed (exit 2 if not).

**Network.** `--list` and the menu's checks fetch from `origin` (30 s per attempt, three attempts; `LYREBIRD_FETCH_TIMEOUT`, `LYREBIRD_FETCH_RETRIES`, `LYREBIRD_FETCH_RETRY_DELAY`). Offline, `--list` shows what the last fetch found and exits 4. `--version`, `--help`, `--status`, `--migrate`, `--history` and `--rollback` do not use the network.

**Exit codes**

| Code | Meaning |
|------|---------|
| 0 | success |
| 1 | general error (a failed switch, an invalid version, an unknown option) |
| 2 | prerequisites not met (git, awk, sed, grep, tput or flock missing; git or Bash too old) |
| 3 | not a git repository |
| 4 | could not reach the remote (fetch failed) or no remote; `--list` then shows cached data |
| 5 | permission (repository not writable or owned by root; state directory or lock file cannot be written) |
| 6 | the requested or previous version is not available in this clone |
| 7 | locked by another updater |
| 8 | bad git state (merge or rebase in progress, unreadable journal) |
| 9 | user aborted (declined a prompt, input ended at a confirmation, SIGINT, SIGTERM) |
| 10 | switch done, but your saved changes conflict with the new version and were not re-applied; they are in the stash |
| 11 | the automatic rollback could not restore everything; the message names the `git checkout --force <sha>` to run |
| 12 | standard input ended at a menu prompt (Ctrl-D, closed pipe) |

In the menu a failed switch is reported and the menu stays open; `Q` leaves with the status of the last switch or reset.

### Migration Notes

Releases before the rename called the stream manager `mediamtx-stream-manager.sh` (log `/var/log/mediamtx-stream-manager.log`). The updater's migration, run after an update or with `--migrate`, rewrites the unit and cron references to `lyrebird-stream-manager.sh`, removes the old script from `/usr/local/bin`, installs the new one there, links the old log name to the new log, and records completion in `/var/lib/lyrebird/migrations/`. A switch to a release whose updater predates the hand-over (before 1.5) is finished by the current updater and does not run that release's migrations; run `--migrate` after it.

### Manual Version Management

```bash
# The updater handles the stash, the service and the checks above; by hand:
git fetch origin
git checkout main && git pull --ff-only     # or: git checkout <tag>
chmod +x *.sh
```

A manual checkout does not stop or restart the service and does not run the migrations. After it, follow [Upgrading an Existing Node](#upgrading-an-existing-node).

---

## Upgrading an Existing Node

Read this before moving a node that already streams to the code on `main`. Do the steps in order; each one says what it refreshes, because several files are not refreshed by an update.

1. **Find out who runs MediaMTX now.** `systemctl is-active mediamtx mediamtx-audio` and, as root, `./install_mediamtx.sh status` (`Running (systemd)` is the standalone `mediamtx.service`, `Running (stream manager service)` is `mediamtx-audio.service`). Only one of them should be active ([Which unit runs MediaMTX](#which-unit-runs-mediamtx)).
2. **Keep a copy of what you have**: `sudo cp -a /etc/mediamtx /root/mediamtx.before-upgrade`, and a copy of `/etc/systemd/system/mediamtx-audio.service` (or `mediamtx.service`) and `/etc/cron.d/mediamtx-monitor`.
3. **Get the code**, as the clone's owner: `./lyrebird-updater.sh` and key `2`, or `git fetch origin && git checkout main && git pull --ff-only` followed by `chmod +x *.sh`. The newest tag does not have these changes.
4. **Refresh the unit and the cron job** (nodes run by the stream manager). Neither is rewritten by anything but `install`:
   `sudo ./lyrebird-stream-manager.sh install` (add `-m multiplex -f amix -n NAME` on a multiplex node), then `sudo systemctl restart mediamtx-audio`. The restart interrupts the streams for the length of a start. The new unit has `Conflicts=mediamtx.service`, `Restart=always` and a real `ExecReload` (`systemctl reload mediamtx-audio` applies a changed MediaMTX configuration without a restart).
5. **Refresh the standalone `mediamtx.service`** (nodes without the stream manager). `install_mediamtx.sh update` replaces the binary only. To get the new unit and configuration run `sudo ./install_mediamtx.sh --force install` (add `-V vX.Y.Z` to keep your MediaMTX version, otherwise it installs the latest), then `sudo systemctl restart mediamtx`. The old configuration and unit are saved as `mediamtx.yml.backup.<time>` and `mediamtx.service.backup.<time>`.
6. **Know what happens to `/etc/mediamtx/mediamtx.yml`** ([Configuration ownership](#configuration-ownership)):
   - Written by an earlier stream manager (first line `# MediaMTX Configuration - Audio Streams`): the first `start` or `reload` replaces it with the current rendering after a timestamped backup (`mediamtx.yml.<UTC time>.<nn>.bak`). Edits you made to it by hand are in the backup, not in the new file.
   - Written by the earlier installer, or edited by you so that its first line differs: it is yours, so it is never rewritten, and each start warns. Its API and metrics keep listening on every interface and SRT and MoQ stay on. To move it to the new defaults run `sudo ./lyrebird-stream-manager.sh --regenerate-config restart` (stream manager nodes) or step 5 (standalone nodes); both save a backup first.
7. **Check the result.** `sudo ./lyrebird-stream-manager.sh status` (or `status --json | jq .overall`), `ss -ltn | grep -E ':(9997|9998) '` (both on `127.0.0.1`), and `systemctl cat mediamtx-audio | grep Conflicts`.

**What can break after an upgrade**

- Anything that used MediaMTX's API (port 9997) or metrics (9998) from another host. They listen on `127.0.0.1` now. `lyrebird-metrics.sh serve` also listens on `127.0.0.1` by default; a Prometheus on another host needs `--bind` ([Prometheus Metrics](#prometheus-metrics-lyrebird-metricssh)).
- Scripts that read the exit status of `start`. `0` now means the start policy is met; `9` is new and means no stream is publishing (before, `start` printed `[FAIL]` and still exited `0`). With no microphone plugged in, `start` used to exit `6` and not start MediaMTX; it now exits `0`, starts MediaMTX and reports `waiting_for_devices` (set `LYREBIRD_ALLOW_EMPTY_START=false` for the old behaviour). `monitor` with no microphone likewise exits `0`, not `6`. See [Stream Manager exit codes](#stream-manager-lyrebird-stream-managersh).
- `/etc/lyrebird/storage.conf`. Earlier releases documented it but never read it; `lyrebird-storage.sh` reads it now, so retention and directory settings in an old file start to apply. Run `lyrebird-storage.sh --dry-run cleanup` before the next cron run.
- `AUDIO_DISK_PERSIST`, `AUDIO_DISK_PATH`, `HEARTBEAT_INTERVAL`, `HARDWARE_WATCHDOG_*` and `ENABLE_HARDWARE_WATCHDOG` no longer exist. If one is set, every run logs one warning and ignores it.
- `MEDIAMTX_LOG_FILE` no longer moves the stream manager's own log (it names MediaMTX's output file only). Set `STREAM_MANAGER_LOG_FILE` if you relied on the old behaviour.
- The device configuration is read as data. Mixed-case keys written by an old `lyrebird-mic-check.sh` start to apply; `DEFAULT_*=` lines in the file, a `CODEC` other than `opus`, `aac` or `mp3`, and values outside the documented ranges are reported as errors and skipped (`lyrebird-stream-manager.sh validate` lists them). Per-device settings are no longer taken from the environment.
- A multiplex stream name is made lower-case with every character outside `a-z 0-9 _ -` replaced by `_` (`Studio Mix` becomes `studio_mix`), so its URL can change.
- A USB card that cannot capture (a speaker or DAC) is skipped; it no longer counts as a failed stream.
- `curl` is now required by the stream manager (exit 3 if it is missing) and `flock` by the updater (exit 2) and the installer (exit 4).
- `systemctl reload mediamtx` on a standalone install never reloaded anything; MediaMTX picks up a changed configuration file by itself, and the new unit has no `ExecReload=`.
- The first `stop` or `force-stop` after an in-place upgrade can refuse with exit 5 when the node was started by an older release, because the old processes held the manager's lock file open. `sudo systemctl restart mediamtx-audio` still works; by hand, stop the processes the message lists.

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
- Monitor with: `sudo ./lyrebird-stream-manager.sh monitor`
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
*/5 * * * * root /path/to/lyrebird-stream-manager.sh monitor
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

## Component Reference

### Quick Reference Table

Versions are the values in the scripts (`grep -m1 VERSION= <script>`).

| Script | Version | Purpose |
|--------|---------|---------|
| lyrebird-orchestrator.sh | 2.2.0 | Unified management interface |
| lyrebird-updater.sh | 1.8.0 | Version management with rollback |
| lyrebird-stream-manager.sh | 2.0.0 | Stream lifecycle management |
| usb-audio-mapper.sh | 4.0.1 | USB device persistence via udev |
| lyrebird-mic-check.sh | 1.0.2 | Hardware capability detection |
| lyrebird-diagnostics.sh | 1.0.2 | System diagnostics |
| install_mediamtx.sh | 2.1.0 | MediaMTX installation/upgrade |
| lyrebird-metrics.sh | 1.4.0 | Prometheus metrics export |
| lyrebird-storage.sh | 1.3.0 | Storage management & cleanup |
| lyrebird-alerts.sh | 1.1.0 | Webhook alerting (called by you; nothing else in the suite sends alerts) |
| lyrebird-common.sh | 1.1.0 | Shared library (logging, atomic writes, the MediaMTX configuration renderer) |

### Configuration Files

| File | Purpose |
|------|---------|
| `config/mediamtx.service` | Template of the standalone MediaMTX unit (`mediamtx.service`); `install_mediamtx.sh` renders it |
| `config/mediamtx-audio.service` | Template of the stream manager unit (`mediamtx-audio.service`); `lyrebird-stream-manager.sh install` renders it. No watchdog (see [Reliability](#reliability-what-recovers-and-what-does-not)) |
| `config/lyrebird-logrotate.conf` | Log rotation example for `/etc/logrotate.d/`. Its FFmpeg stanza names `/var/log/lyrebird/*.log`, but the stream manager keeps FFmpeg logs in `/var/lib/mediamtx-ffmpeg/`; the file `install` writes (`/etc/logrotate.d/mediamtx`) names the right directory |
| `docs/SECURITY-GUIDE.md` | Security configuration guide (optional features) |

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

### Stream Manager (lyrebird-stream-manager.sh)

**Purpose:** Automatic stream configuration and lifecycle management

**Usage:**
```bash
# Individual streams
sudo ./lyrebird-stream-manager.sh start

# Multiplex mode
sudo ./lyrebird-stream-manager.sh -m multiplex -f amix start

# Monitor health (cron)
sudo ./lyrebird-stream-manager.sh monitor

# Check status
sudo ./lyrebird-stream-manager.sh status

# View configuration
sudo ./lyrebird-stream-manager.sh config

# Install systemd service
sudo ./lyrebird-stream-manager.sh install
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
sudo ./lyrebird-stream-manager.sh start
# Creates: rtsp://host:8554/device1, rtsp://host:8554/device2, etc.
```

**Multiplex Mode with Audio Mixing**:
```bash
sudo ./lyrebird-stream-manager.sh -m multiplex -f amix start
# Creates: rtsp://host:8554/all_mics (mixed audio)
```

**Multiplex Mode with Channel Separation**:
```bash
sudo ./lyrebird-stream-manager.sh -m multiplex -f amerge start
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
sudo ./lyrebird-stream-manager.sh install

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

**Purpose:** Give each USB sound card a permanent ALSA name, tied to the USB port it is plugged into, so identical microphones keep their names across reboots.

Shared with the standalone [usb-audio-mapper](https://github.com/tomtom215/usb-audio-mapper) project, whose README and DOCUMENTATION.md cover it in full.

**Usage:**
```bash
# List USB sound cards, ports and mappings (no root needed)
./usb-audio-mapper.sh --list

# Interactive mode
sudo ./usb-audio-mapper.sh

# Non-interactive: name ALSA card 1 (vendor, product and port read from it)
sudo ./usb-audio-mapper.sh -n --card 1 -f mic-left

# Non-interactive by vendor/product id, choosing the port
sudo ./usb-audio-mapper.sh -n -v XXXX -p YYYY -u 1-2 -f mic-right

# Remove a mapping
sudo ./usb-audio-mapper.sh --remove mic-left
```

**Options:**
- `-i, --interactive`: Run in interactive mode (default)
- `-n, --non-interactive`: Run in non-interactive mode
- `-c, --card <N>`: ALSA card number of a connected USB device
- `-v, --vendor <id>`: Vendor ID (4-digit hex)
- `-p, --product <id>`: Product ID (4-digit hex)
- `-u, --usb-port <port>`: Physical port such as `1-2` or `1-2.3` (see `--list`)
- `--any-port`: Match the device on any port (only with a single such device)
- `-f, --friendly <name>`: Name: lowercase letters, digits, hyphens; starts with a letter; at most 15 characters
- `-d, --device <text>`: Description stored in the rule comment (optional)
- `-l, --list`: List USB sound cards, ports and mappings
- `-t, --test`: List every USB device with its port
- `-r, --remove <name>`: Remove a mapping
- `--dry-run`, `--no-apply`: Print rules only / write without triggering udev
- `-D, --debug`: Enable debug output

**Features:**
- Names follow the physical USB port, so identical devices are told apart (also behind hubs)
- Applies each name immediately and verifies it with the kernel (exit 6 if it did not take)
- Refuses ambiguous requests (several identical devices, no port given)
- Replaces rules from older versions automatically; atomic, locked writes

**Generated Files:**
- `/etc/udev/rules.d/99-usb-soundcards.rules`: udev rules
- ALSA card id `<name>` (in `/proc/asound/cards`, usable as `hw:CARD=<name>`)
- `/dev/sound/by-id/<name>`: symlink to the card's control device

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

### Webhook Alerts (lyrebird-alerts.sh)

**Purpose:** Remote monitoring via webhook notifications (pure bash, no new dependencies)

**Usage:**
```bash
# Interactive setup wizard
./lyrebird-alerts.sh setup

# Send a test alert
./lyrebird-alerts.sh test

# Send custom alert
./lyrebird-alerts.sh send --level warning --title "Alert" --message "Something happened"

# Check status
./lyrebird-alerts.sh status

# Show current configuration
./lyrebird-alerts.sh config
```

**Supported Webhook Types:**
- **Discord** - Discord channel webhooks
- **Slack** - Slack incoming webhooks
- **ntfy.sh** - Free, open-source notification service
- **Pushover** - Mobile push notifications
- **Generic** - Any HTTP POST endpoint

**Configuration:** `/etc/lyrebird/alerts.conf`
```bash
LYREBIRD_ALERT_ENABLED=true
LYREBIRD_WEBHOOK_URL="https://your-webhook-url"
LYREBIRD_WEBHOOK_TYPE="discord"  # discord, slack, ntfy, pushover, generic
LYREBIRD_ALERT_RATE_LIMIT=300    # Seconds between duplicate alerts
LYREBIRD_HOSTNAME="field-unit-1"
LYREBIRD_LOCATION="North Forest"
```

**Features:**
- Rate limiting prevents alert spam
- Alert deduplication within configurable window
- Multiple webhook destinations
- Pre-built functions for common alerts:
  - `alert_stream_down` / `alert_stream_up`
  - `alert_device_disconnect` / `alert_device_connect`
  - `alert_disk_warning` / `alert_disk_critical`
  - `alert_mediamtx_down` / `alert_mediamtx_up`
  - `alert_network_down` / `alert_network_up`

**Integration with other scripts:**
```bash
# Source alerts in your monitoring script
source ./lyrebird-alerts.sh

# Send alert when stream fails
if ! check_stream_health "mic1"; then
    alert_stream_down "mic1" "FFmpeg process died"
fi
```

---

### Prometheus Metrics (lyrebird-metrics.sh)

**Purpose:** Export system and stream metrics in Prometheus format

**Usage:**
```bash
# One-time metrics output
./lyrebird-metrics.sh

# Start HTTP metrics server (for Prometheus scraping)
./lyrebird-metrics.sh serve --port 9100

# Output specific metrics only
./lyrebird-metrics.sh --streams-only
./lyrebird-metrics.sh --system-only
```

**Metrics Exported:**
```
# MediaMTX service status
lyrebird_mediamtx_up 1
lyrebird_mediamtx_uptime_seconds 3600

# Stream status (per stream)
lyrebird_stream_active{name="mic1"} 1
lyrebird_stream_uptime_seconds{name="mic1"} 1800

# USB audio devices
lyrebird_usb_devices_total 3
lyrebird_usb_device_connected{name="mic1"} 1

# System resources
lyrebird_cpu_usage_percent 15.5
lyrebird_memory_usage_percent 45.2
lyrebird_disk_usage_percent{mount="/"} 62
lyrebird_load_average_1m 0.5
```

**Prometheus Configuration:**
```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'lyrebird'
    static_configs:
      - targets: ['field-unit-1:9100']
    scrape_interval: 30s
```

**Features:**
- Prometheus-compatible text format
- HTTP server mode for remote scraping
- Per-stream metrics with labels
- System resource monitoring
- MediaMTX API integration

---

### Storage Management (lyrebird-storage.sh)

**Purpose:** Manage disk space and recording retention for long-term deployments

**Usage:**
```bash
# Check storage status
./lyrebird-storage.sh status

# Clean up old recordings (respects retention policy)
sudo ./lyrebird-storage.sh cleanup

# Emergency cleanup (aggressive, ignores some limits)
sudo ./lyrebird-storage.sh emergency

# Monitor mode (continuous)
./lyrebird-storage.sh monitor --interval 300
```

**Configuration:** Environment variables or `/etc/lyrebird/storage.conf`
```bash
# Retention settings
RECORDING_RETENTION_DAYS=30      # Keep recordings for 30 days
LOG_RETENTION_DAYS=7             # Keep logs for 7 days

# Disk thresholds
DISK_WARNING_PERCENT=80          # Warn at 80% usage
DISK_CRITICAL_PERCENT=90         # Critical at 90% usage

# Directories to manage
RECORDING_DIR="/var/recordings"
LOG_DIR="/var/log/lyrebird"
```

**Features:**
- Configurable retention policies
- Automatic cleanup of old recordings and logs
- Disk usage monitoring with thresholds — including **inode** exhaustion,
  which many small recording files can hit long before disk space runs out
- Emergency cleanup mode for critical situations
- Integration with alerting system
- Dry-run mode for testing
- **Broken-clock protection**: a Pi without a battery-backed clock boots
  thinking it is 1970 until it gets network time. Recordings captured in that
  window are never deleted as "too old" once the clock corrects itself, and
  age-based cleanup waits until the clock is sane

**Automated Cleanup via Cron:**
```bash
# Add to /etc/cron.d/lyrebird-storage
0 3 * * * root /path/to/lyrebird-storage.sh cleanup --quiet
*/15 * * * * root /path/to/lyrebird-storage.sh monitor --once
```

---

## Advanced Topics

### Custom Integration

**Automation Example:**
```bash
#!/bin/bash
# Auto-restart on USB disconnect

while true; do
    if ! ./lyrebird-stream-manager.sh status | grep -q "running"; then
        echo "Streams down, restarting..."
        sudo ./lyrebird-stream-manager.sh restart
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
sudo ./lyrebird-stream-manager.sh restart
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
sudo ./lyrebird-stream-manager.sh restart
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
sudo ./lyrebird-stream-manager.sh restart
```

### Debug Mode

Enable debug output for all scripts:
```bash
export DEBUG=1

# Now run any command
sudo ./lyrebird-stream-manager.sh status
sudo ./usb-audio-mapper.sh --test
```

---

## Security Hardening

### Default Security Posture

LyreBirdAudio is designed with security in mind:

- **No Hardcoded Credentials**: All authentication is delegated to MediaMTX
- **Restrictive Permissions**: Configuration files are mode 640, state directories 750
- **Service User Isolation**: MediaMTX runs as dedicated `mediamtx` user
- **systemd Hardening**: NoNewPrivileges, PrivateTmp, ProtectSystem enabled
- **Input Validation**: All user inputs are sanitized to prevent injection
- **Safe Temporary Files**: Uses `mktemp` for secure temp file creation
- **Download Verification**: SHA256 checksums verify downloaded binaries

### Network Security

**Default Configuration Warning**: By default, RTSP streams are accessible without authentication. For production deployments in sensitive environments:

**1. Enable MediaMTX Authentication:**
```yaml
# Edit /etc/mediamtx/mediamtx.yml
authMethod: internal
authInternalUsers:
  - user: myuser
    pass: mypassword
    permissions:
      - action: read
        path: ""
```

**2. Firewall Configuration:**
```bash
# Allow only specific IPs to access streams
sudo ufw allow from 192.168.1.0/24 to any port 8554 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 9997 proto tcp

# Or block external access entirely (local only)
sudo ufw deny 8554
sudo ufw deny 9997
```

**3. Bind to Specific Interface:**
```yaml
# In /etc/mediamtx/mediamtx.yml
rtspAddress: 192.168.1.100:8554  # Instead of :8554 (all interfaces)
apiAddress: 127.0.0.1:9997       # Localhost only for API
```

### Library Integrity Verification

For high-security deployments, enable library checksum verification:

```bash
# Generate hash of lyrebird-common.sh
HASH=$(sha256sum lyrebird-common.sh | cut -d' ' -f1)

# Set in environment or systemd service
export LYREBIRD_COMMON_EXPECTED_HASH="$HASH"

# Now sourcing will verify integrity before loading
sudo ./lyrebird-stream-manager.sh start
```

### Recommendations for Field Deployments

1. **Use VPN**: Connect remote devices through VPN rather than exposing RTSP directly
2. **Disable API Access**: If not needed, disable the MediaMTX API endpoint
3. **Audit Logs Regularly**: Check `/var/log/lyrebird/mediamtx-audio.log` for anomalies
4. **Keep Updated**: Run `lyrebird-updater.sh` monthly to get security fixes
5. **Physical Security**: Secure physical access to prevent USB device tampering

---

## Recovery Procedures

### Stream Not Starting

**Quick Recovery:**
```bash
# Check service status
sudo ./lyrebird-stream-manager.sh status

# Force restart
sudo ./lyrebird-stream-manager.sh restart

# If that fails, force stop and clean start
sudo ./lyrebird-stream-manager.sh force-stop
sudo ./lyrebird-stream-manager.sh start
```

### Device Not Found After Reboot

```bash
# Show USB sound cards, their ports and mappings
./usb-audio-mapper.sh --list

# Re-map a card that lost its name (applied and verified immediately)
sudo ./usb-audio-mapper.sh -n --card N -f NAME

# Verify
cat /proc/asound/cards
ls -la /dev/sound/by-id/
```

### Complete System Recovery

If the system is in an unknown state:

```bash
# 1. Stop everything
sudo systemctl stop mediamtx-audio 2>/dev/null || true
sudo ./lyrebird-stream-manager.sh force-stop

# 2. Clean up stale files
sudo rm -f /run/mediamtx-audio.*
sudo rm -f /var/lib/mediamtx-ffmpeg/*.pid

# 3. Verify MediaMTX installation
sudo ./install_mediamtx.sh status
# If corrupted: sudo ./install_mediamtx.sh update

# 4. Verify device mapping
sudo ./usb-audio-mapper.sh --test

# 5. Run full diagnostics
sudo ./lyrebird-diagnostics.sh full

# 6. Fresh start
sudo ./lyrebird-stream-manager.sh start
```

### Rollback After Failed Update

```bash
# List available versions
./lyrebird-updater.sh --history

# Rollback to previous version
./lyrebird-updater.sh --rollback

# Or rollback to specific version
./lyrebird-updater.sh --rollback v1.3.0
```

### Emergency Field Recovery (No Internet)

If you're in the field without internet access:

1. **Use local backups**: Keep a USB drive with known-good configuration
2. **Config backup location**: `/etc/mediamtx/audio-devices.conf.bak`
3. **Restore config**: `sudo cp /etc/mediamtx/audio-devices.conf.bak /etc/mediamtx/audio-devices.conf`
4. **Restart service**: `sudo systemctl restart mediamtx-audio`

---

## Uninstallation & Cleanup

### Complete Removal

To completely remove LyreBirdAudio and all components:

**1. Stop all streams and services:**
```bash
# Stop streaming service
sudo ./lyrebird-stream-manager.sh stop

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
sudo rm -f /var/log/lyrebird-stream-manager.log
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
sudo ./lyrebird-stream-manager.sh stop

# Remove only stream-related files
sudo rm -rf /var/lib/mediamtx-ffmpeg/
sudo rm -f /run/mediamtx-audio.*
sudo rm -f /var/log/lyrebird-stream-manager.log
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

For detailed contribution guidelines, see **[CONTRIBUTING.md](CONTRIBUTING.md)**.

For version history and release notes, see **[CHANGELOG.md](CHANGELOG.md)**.

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

Before trusting a node in the field, soak-test it on the same hardware for
weeks with faults injected: see [tools/soak/README.md](tools/soak/README.md).

**Validation:**
- [ ] `bash -n script.sh` (syntax check)
- [ ] `shellcheck script.sh` (linting)
- [ ] `tests/check_tmp_leaks.sh` (bats suite, no leaked temp files)
- [ ] `LYREBIRD_TEST_MEDIAMTX_BINS="$(tests/fetch_mediamtx.sh)" bats tests/test_mediamtx_live.bats tests/test_soak_live.bats tests/test_soak_observer.bats` (real MediaMTX)
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

Copyright 2024-2025 LyreBirdAudio Contributors

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

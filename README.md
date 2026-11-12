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

These diagrams show how LyreBirdAudio components work together to turn USB microphones into RTSP streams. `lyrebird-metrics.sh`, `lyrebird-storage.sh` and `lyrebird-alerts.sh` are separate tools that are not part of the stream path ([Component Reference](#component-reference)).

### System Architecture Overview

```
+----------------------------------------------------------+
|                     Client Applications                  |
|            (VLC, FFplay, OBS, Custom RTSP Clients)       |
+--------------------+-------------------------------------+
                     | rtsp://host:8554/<stream name>
                     v
+----------------------------------------------------------+
|                         MediaMTX                         |
|                 (Real-time Media Server)                 |
|  +----------------------------------------------------+  |
|  | * RTSP server, port 8554 (every interface)         |  |
|  | * RTP/RTCP over UDP, ports 8000 and 8001           |  |
|  | * HTTP API, 127.0.0.1:9997                         |  |
|  | * Prometheus metrics, 127.0.0.1:9998               |  |
|  | * SRT, RTMP, HLS, WebRTC and MoQ switched off      |  |
|  +----------------------------------------------------+  |
+--------------------+-------------------------------------+
                     | Started and watched by
                     v
+----------------------------------------------------------+
|                 Stream Manager / systemd                 |
|  +----------------------------------------------------+  |
|  | * One owner of MediaMTX and its FFmpeg processes   |  |
|  | * Restarts failed streams (wrapper, cron monitor)  |  |
|  | * Health from the MediaMTX API, status.json        |  |
|  | * Processes identified by PID and start time       |  |
|  +----------------------------------------------------+  |
+--------------------+-------------------------------------+
                     | Captures from
                     v
+----------------------------------------------------------+
|                  FFmpeg Audio Pipeline                   |
|  +----------------------------------------------------+  |
|  | * ALSA capture (plughw:<card>,<pcm>)               |  |
|  | * Audio encoding (Opus, AAC or MP3)                |  |
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
|  | * Same name after a reboot, tied to the USB port   |  |
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
|  * Interactive menus for all operations                  |
|  * Delegates to specialized scripts                      |
|  * Explains each script's exit status                    |
|  * Reads the stream manager's status document            |
+----------------------------------------------------------+
          |
          +----> install_mediamtx.sh
          |       * MediaMTX installation & updates
          |       * Checksum-verified download, atomic replace
          |       * Rollback if the new binary does not run
          |       * Writes the standalone mediamtx.service
          |
          +----> lyrebird-stream-manager.sh
          |       * MediaMTX and FFmpeg process lifecycle
          |       * Stream health via the MediaMTX API
          |       * FFmpeg restart with exponential backoff
          |       * Individual & multiplex streaming modes
          |       * Resource monitoring (CPU, FDs)
          |       * Writes mediamtx-audio.service and the cron job
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
          |       * History and rollback
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
# Start MediaMTX and all streams (safe to repeat)
sudo ./lyrebird-stream-manager.sh start

# Stop streams and MediaMTX
sudo ./lyrebird-stream-manager.sh stop

# Restart everything (the streams are interrupted)
sudo ./lyrebird-stream-manager.sh restart

# Apply a changed MediaMTX configuration without restarting running streams
sudo ./lyrebird-stream-manager.sh reload

# Check status (add --json for the machine-readable document)
./lyrebird-stream-manager.sh status
```

If the node runs under systemd ([Manual Installation](#manual-installation)), use `systemctl start`, `stop`, `restart` and `reload` on `mediamtx-audio` instead: the unit runs the same commands.

`start` leaves a MediaMTX that this manager started alone: same process IDs, no outage, only streams that are missing are started. Its exit status says whether the start policy was met (`0`) or no stream is publishing (`9`); `8` means another MediaMTX owns the node and nothing was changed. All exit codes are in [Stream Manager](#stream-manager-lyrebird-stream-managersh).

### Using the Orchestrator

```bash
sudo ./lyrebird-orchestrator.sh
```

**Main Menu:**
- Quick Setup Wizard - four steps: install MediaMTX, map devices, start streams, quick diagnostics
- MediaMTX Installation & Updates - install, update, reinstall, uninstall, status
- USB Device Management - map devices, test the mapping, view mappings, detect capabilities, generate and validate the device configuration, remove mappings, reload udev rules
- Audio Streaming Control - start, stop, restart (start and restart report the outcome per stream), status, URLs, monitor
- System Diagnostics - quick, full and verbose diagnostics, export a report
- Version Management - launch the updater, show component versions, show update history, roll back
- Logs & Status - MediaMTX, orchestrator, stream manager and FFmpeg logs, quick health check

### Accessing Streams

Streams are accessible via RTSP:
```
rtsp://your-server-ip:8554/device-name
```

**Example:**
```
rtsp://192.168.1.100:8554/mic-left
rtsp://192.168.1.100:8554/mic-right
```

**VLC Player:**
```bash
vlc rtsp://192.168.1.100:8554/mic-left
```

**FFmpeg Recording:**
```bash
ffmpeg -i rtsp://192.168.1.100:8554/mic-left -c copy recording.mkv
```

Anyone who can reach the RTSP port can read (and publish) unless you configure authentication; see [Security Hardening](#security-hardening).

### Health Monitoring

```bash
# Quick health check
sudo ./lyrebird-diagnostics.sh quick

# Full diagnostics
sudo ./lyrebird-diagnostics.sh full

# Install the monitor cron job (with the systemd unit)
sudo ./lyrebird-stream-manager.sh install
```

The cron job (`/etc/cron.d/mediamtx-monitor`, every 5 minutes) runs `lyrebird-stream-manager.sh monitor`. Besides checking that each stream's wrapper process exists, the monitor asks the MediaMTX API whether each stream's path is ready. A path that stays not ready for three monitor runs in a row (a hung FFmpeg, a stuck retry loop) gets its stream restarted, at most six times per hour per stream. When the API cannot be asked (not running, behind authentication, an error) nothing counts against a stream. On each run the monitor also reads a few seconds of every published stream back to look for silence, and starts the stream of a microphone that has appeared. What recovers and what does not is in [Reliability](#reliability-what-recovers-and-what-does-not).

---

## Configuration Guide

### Audio Device Configuration

Configuration file: `/etc/mediamtx/audio-devices.conf` (`MEDIAMTX_DEVICE_CONFIG` names another). The file is optional: without it, or for a setting it does not name, a stream uses the defaults in [Environment Variables](#environment-variables). `lyrebird-stream-manager.sh config` and `start` write a commented template when the file is missing. The file is read as data: nothing in it is run or expanded.

**Generate automatically (recommended):**
```bash
# Normal quality (the default)
sudo ./lyrebird-mic-check.sh -g

# High quality
sudo ./lyrebird-mic-check.sh -g --quality=high

# Low quality
sudo ./lyrebird-mic-check.sh -g --quality=low
```

What each tier picks (read from `lyrebird-mic-check.sh`; it chooses only from what the card reports):

| Tier | Sample rate | Channels | Bitrate, stereo / mono, at 44.1 kHz and above |
|------|-------------|----------|-----------------------------------------------|
| `low` | 44100 if offered, else 48000, else the lowest | 1 if offered | 128k / 96k |
| `normal` (default) | 48000 if offered, else 44100, else the highest up to 48000 | 2 if offered | 192k / 128k (256k / 192k from 96 kHz) |
| `high` | 192000 if offered, else 96000, else 48000, else the highest | 2 if offered | 192k / 128k at 48 kHz, 256k / 160k at 96 kHz, 320k / 192k at 192 kHz |

`-g` backs up an existing file first as `audio-devices.conf.backup.<YYYYmmdd_HHMMSS>` (mode 0600) and writes the new one atomically; `--list-backups` and `--restore=<timestamp>` use those backups.

**Manual configuration format:**
```bash
# Settings for one stream, by its stream name (the card name, upper-cased,
# every other character written as _): mic-left -> MIC_LEFT
DEVICE_MIC_LEFT_SAMPLE_RATE=48000
DEVICE_MIC_LEFT_CHANNELS=2
DEVICE_MIC_LEFT_BITRATE=192k
DEVICE_MIC_LEFT_CODEC=opus

# The full device name works too (friendly name first, then device name, then the default)
DEVICE_USB_MANUFACTURER_MODEL_SERIAL_00000000_SAMPLE_RATE=48000
```

One `DEVICE_<NAME>_<SETTING>=value` per line; blank lines and `#` comments are ignored; a value is bare, `'single-quoted'` or `"double-quoted"` and is taken literally; there are no spaces around `=`.

**Available settings** and the values accepted:

| Setting | Values |
|---------|--------|
| `SAMPLE_RATE` | 8000 11025 12000 16000 22050 24000 32000 44100 48000 88200 96000 176400 192000 352800 384000 705600 768000 (the card's own limits apply) |
| `CHANNELS` | 1 to 32 (the codec must be able to encode that many: Opus refuses 4 and 9 or more with FFmpeg 6.1.1; a refused count stops that stream with an error in the manager log) |
| `CODEC` | `opus`, `aac` or `mp3` (`pcm` is not supported) |
| `BITRATE` | `1k` to `9999k`, written like `128k` |
| `THREAD_QUEUE` | 1 to 1048576 (default 8192) |
| `PCM` | 0 to 255: the capture PCM of the card to record from; the default is the first capture PCM the card has, usually 0 |

An invalid line is skipped, logged with its file, line and key, and the setting keeps its default: streams still start. `DEFAULT_*=` lines in this file are errors (those defaults come from the environment). A key written in mixed case is read as upper case with a warning. Check the file with:

```bash
./lyrebird-stream-manager.sh validate     # exit 0 if every line is usable, 4 if not
sudo ./lyrebird-mic-check.sh -V           # checks the file against what the cards report
```

### System Configuration Files

| File | Purpose | Format |
|------|---------|--------|
| `/etc/mediamtx/mediamtx.yml` | MediaMTX main configuration | YAML; generated (carries the managed marker, see [Configuration ownership](#configuration-ownership)) or yours |
| `/etc/mediamtx/audio-devices.conf` | Per-device audio settings | Text: `DEVICE_<NAME>_<SETTING>=value` lines, read as data |
| `/etc/mediamtx/rtsp-users.conf` | Read-only RTSP users, only with `RTSP_AUTH_MODE=local-only-publish` (optional) | `user:sha256:<base64>` lines |
| `/etc/lyrebird/alerts.conf` | Webhook alerts (optional) | `LYREBIRD_*=value` lines |
| `/etc/lyrebird/storage.conf` | Storage retention and paths (optional) | `KEY=value` lines, read as data |
| `/etc/udev/rules.d/99-usb-soundcards.rules` | USB device persistence rules | udev syntax |
| `/etc/systemd/system/mediamtx.service` | Standalone MediaMTX unit (`install_mediamtx.sh`) | INI-style |
| `/etc/systemd/system/mediamtx-audio.service` | Stream manager unit (`lyrebird-stream-manager.sh install`) | INI-style |
| `/etc/cron.d/mediamtx-monitor` | The monitor cron job (`install`) | cron |
| `/etc/logrotate.d/mediamtx` | Rotation of MediaMTX's output, the manager log and the FFmpeg logs (`install`, when `logrotate` is present) | logrotate |

### Runtime State Files

| File/Directory | Purpose |
|----------------|---------|
| `/run/mediamtx-audio.pid` | PID of the MediaMTX the manager started; `/run/mediamtx-audio.pid.id` records its PID and start time |
| `/run/mediamtx-audio.lock` | Lifecycle lock of the stream manager. Never delete it: see [Recovery Procedures](#recovery-procedures) |
| `/run/mediamtx-monitor.lock` | Lock of the cron monitor job |
| `/run/lyrebird/status.json` | Status document ([Status document](#status-document)) |
| `/run/lyrebird/desired-running` | Present while the node is meant to run: `start` writes it, `stop` removes it |
| `/run/lyrebird/` (`cron-restarts/`, `deep-health/`, `silence/`) | Monitor state: restart budgets, not-ready strikes, silence episodes. Cleared at boot |
| `/run/mediamtx-audio.heartbeat` | Unix time of the last monitor run |
| `/run/mediamtx-audio.restart`, `/run/mediamtx-audio.cleanup` | Short-lived markers; the cleanup marker is left only by an interrupted run |
| `/var/lib/mediamtx-ffmpeg/` | Per stream: `<stream>.pid` (and `.pid.id`), `<stream>.sh` (the generated wrapper), `<stream>.log`, and the previous runs' logs `<stream>.log.prev.1` ... (`FFMPEG_LOG_KEEP`, default 3) |
| `/var/log/mediamtx.out` | MediaMTX output (`MEDIAMTX_LOG_FILE`) |
| `/var/log/lyrebird-stream-manager.log` | Stream manager log (`STREAM_MANAGER_LOG_FILE`) |
| `/var/log/lyrebird-orchestrator.log` | Orchestrator log |
| `/var/log/lyrebird-diagnostics.log` | Diagnostics log |
| `/var/log/lyrebird/alerts.log`, `/var/lib/lyrebird/alerts/` | Alert log and delivery state |
| `/dev/shm/lyrebird-buffer/` | Local recording ring buffer, only with `AUDIO_LOCAL_RECORDING=true`; RAM, lost at reboot |

### Environment Variables

The stream manager reads these from its environment. Set them in one of three places, depending on how it runs:

- A manual run: `sudo env STREAM_STARTUP_DELAY=20 ./lyrebird-stream-manager.sh start`.
- The systemd service: `sudo systemctl edit mediamtx-audio`, then `[Service]` and `Environment="NAME=value"` lines, then `sudo systemctl restart mediamtx-audio`. `install` writes only `STREAM_MODE`, `MULTIPLEX_FILTER_TYPE` and `MULTIPLEX_STREAM_NAME` into the unit.
- The monitor cron job: `NAME=value` lines above the job line of `/etc/cron.d/mediamtx-monitor`. The cron job does not inherit the unit's environment. A stream the monitor restarts is rebuilt from the monitor's environment, so a setting that changes what streams or MediaMTX do (the ports, `RTSP_AUTH_MODE`, `AUDIO_*`, `LYREBIRD_START_POLICY`) belongs in both places, or a restarted stream would use the defaults. Running `install` again (the updater does it after an update that changes the manager) rewrites the cron file, so add the lines again afterwards.

| Variable | Default | Meaning |
|----------|---------|---------|
| `MEDIAMTX_BINARY` | `/usr/local/bin/mediamtx` | MediaMTX executable |
| `MEDIAMTX_CONFIG_DIR` | `/etc/mediamtx` | Configuration directory |
| `MEDIAMTX_CONFIG_FILE` | `<config dir>/mediamtx.yml` | MediaMTX configuration |
| `MEDIAMTX_DEVICE_CONFIG` | `<config dir>/audio-devices.conf` | Device configuration |
| `MEDIAMTX_LOG_FILE` | `/var/log/mediamtx.out` | Where MediaMTX's own output goes (only that) |
| `STREAM_MANAGER_LOG_FILE` | `/var/log/lyrebird-stream-manager.log` | The stream manager's log |
| `MEDIAMTX_PID_FILE` | `/run/mediamtx-audio.pid` | PID file |
| `MEDIAMTX_LOCK_FILE` | `/run/mediamtx-audio.lock` | Lifecycle lock file |
| `MEDIAMTX_FFMPEG_DIR` | `/var/lib/mediamtx-ffmpeg` | Wrapper scripts, PID files, FFmpeg logs |
| `LYREBIRD_STATE_DIR` | `/run/lyrebird` | Status document and desired-running marker |
| `LYREBIRD_STATUS_FILE` | `<state dir>/status.json` | Status document |
| `MEDIAMTX_HOST` | `localhost` | Host the manager's publishers and probes connect to |
| `MEDIAMTX_RTSP_PORT` | `8554` | RTSP port |
| `MEDIAMTX_API_PORT` | `9997` | Control API port |
| `MEDIAMTX_METRICS_PORT` | `9998` | MediaMTX metrics port |
| `MEDIAMTX_API_BIND` | `127.0.0.1` | Address the API listens on (empty: every interface) |
| `MEDIAMTX_METRICS_BIND` | `127.0.0.1` | Address the metrics endpoint listens on (empty: every interface) |
| `RTSP_AUTH_MODE` | `open` | `open` or `local-only-publish` ([Security Hardening](#security-hardening)) |
| `RTSP_USERS_FILE` | `<config dir>/rtsp-users.conf` | Users for `local-only-publish` |
| `MEDIAMTX_CONFIG_BACKUPS` | `5` | Timestamped backups of `mediamtx.yml` kept (at least 1) |
| `LYREBIRD_START_POLICY` | `degraded` | `degraded`: `start` succeeds when one stream publishes; `strict`: when every detected device's stream does |
| `LYREBIRD_ALLOW_EMPTY_START` | `true` | With no USB audio device, `start` brings MediaMTX up and exits 0 (`waiting_for_devices`); `false`: exit 6, MediaMTX not started |
| `LYREBIRD_FLOW_SAMPLE_SECONDS` | `3` | Seconds between the two byte-counter samples behind `bytes_flowing` (0 skips the sample) |
| `STREAM_STARTUP_DELAY` | `10` | Seconds a stream gets to settle after launch |
| `USB_STABILIZATION_DELAY` | `5` | Seconds to wait for USB devices to settle (the unit sets 10) |
| `RESTART_STABILIZATION_DELAY` | `15` | The same, after a restart |
| `STREAM_VALIDATION_ATTEMPTS`, `STREAM_VALIDATION_DELAY` | `3`, `5` | Attempts and seconds between them while waiting for a stream to publish |
| `MEDIAMTX_API_TIMEOUT` | `60` | Seconds to wait for the MediaMTX API at start |
| `LOCK_ACQUISITION_TIMEOUT`, `STOP_LOCK_TIMEOUT`, `MONITOR_LOCK_TIMEOUT` | `30`, `5`, `5` | Seconds `start`/`restart`, `stop`/`force-stop` and `monitor` wait for the lifecycle lock |
| `MAX_FD_WARNING`, `MAX_FD_CRITICAL` | `500`, `1000` | File descriptor thresholds (critical: the monitor exits 2) |
| `MAX_CPU_WARNING`, `MAX_CPU_CRITICAL` | `20`, `40` | CPU percent thresholds (critical: the monitor exits 2) |
| `DISK_SPACE_WARNING_PERCENT`, `DISK_SPACE_CRITICAL_PERCENT`, `DISK_SPACE_MIN_FREE_MB` | `80`, `95`, `100` | Disk thresholds (logged; exit 1) |
| `MEM_WARNING_PERCENT`, `MEM_CRITICAL_PERCENT` | `80`, `95` | System memory thresholds (logged; exit 1) |
| `MAX_WRAPPER_RESTARTS` | `50` | Wrapper gives up after this many FFmpeg restarts without a long run |
| `WRAPPER_SUCCESS_DURATION` | `300` | A run this long (seconds) resets the wrapper's failure count and delay |
| `MAX_CONSECUTIVE_FAILURES` | `5` | Wrapper gives up after this many failures in a row |
| `INITIAL_RESTART_DELAY`, `MAX_RESTART_DELAY` | `10`, `300` | Wrapper back-off, seconds |
| `DEEP_HEALTH_CHECK_ENABLED` | `true` | Ask the API whether each stream's path is ready |
| `DEEP_HEALTH_MAX_STRIKES` | `3` | Monitor runs with a not-ready path before the stream is restarted |
| `CRON_RESTART_MAX_PER_HOUR` | `6` | Restarts per hour the monitor may make per stream (and for MediaMTX) |
| `AUDIO_LEVEL_CHECK_ENABLED` | `true` | Read each published stream back for silence on every monitor run |
| `AUDIO_LEVEL_SAMPLE_DURATION`, `AUDIO_LEVEL_CHECK_INTERVAL` | `3`, `240` | Seconds measured, and least seconds between two probes of one stream |
| `AUDIO_SILENCE_THRESHOLD_DB`, `AUDIO_SILENCE_WARN_DURATION` | `-60`, `60` | Level at or below which a probe counts as silent, and seconds of silence before the `DEAD MIC` error |
| `NETWORK_CHECK_ENABLED` | `true` | Ping check of the gateway in the monitor |
| `DEFAULT_SAMPLE_RATE`, `DEFAULT_CHANNELS`, `DEFAULT_CODEC`, `DEFAULT_BITRATE` | `48000`, `2`, `opus`, `128k` | Audio defaults for settings the device file does not give |
| `DEFAULT_THREAD_QUEUE`, `DEFAULT_ANALYZEDURATION`, `DEFAULT_PROBESIZE` | `8192`, `5000000`, `5000000` | FFmpeg input buffering defaults |
| `AUDIO_LOCAL_RECORDING` | `false` | Also write a ring of segments to disk while streaming |
| `AUDIO_RECORDING_PATH` | `/dev/shm/lyrebird-buffer` | Where the ring is written. The default is RAM: lost at reboot and at power loss. Point it at persistent storage to keep it |
| `AUDIO_RECORDING_SEGMENT_TIME`, `AUDIO_RECORDING_SEGMENTS` | `300`, `12` | Seconds per segment and number of segments kept per stream (one hour); FFmpeg overwrites them in place, so the order of the slot numbers is not chronological after a restart: order by modification time |
| `MAIN_LOG_MAX_SIZE`, `FFMPEG_LOG_MAX_SIZE`, `MEDIAMTX_LOG_MAX_SIZE` | `104857600`, `10485760`, `52428800` | Sizes used in the logrotate file `install` writes |
| `FFMPEG_LOG_KEEP` | `3` | Previous runs of each stream's FFmpeg log kept (0 to 20) |
| `DEBUG` | `false` | `DEBUG=true` turns on debug output (`1` does not); the stream manager also prints a trace of every command. Its `-d` option turns on the debug messages without the trace |

**Installer settings** (`install_mediamtx.sh`; `--help` lists them): `MEDIAMTX_PREFIX` (`/usr/local`), `MEDIAMTX_CONFIG_DIR`, `MEDIAMTX_STATE_DIR` (`/var/lib/mediamtx`), `MEDIAMTX_USER` and `MEDIAMTX_GROUP` (`mediamtx`), `MEDIAMTX_RTSP_PORT`, `MEDIAMTX_API_PORT`, `MEDIAMTX_METRICS_PORT`, `MEDIAMTX_DOWNLOAD_TIMEOUT` (300), `MEDIAMTX_DOWNLOAD_RETRIES` (3), `MEDIAMTX_STOP_TIMEOUT` (10), `MEDIAMTX_PID_FILE`, `MEDIAMTX_SERVICE_DIR`, `MEDIAMTX_UNIT_TEMPLATE`. The ports must be whole numbers from 1 to 65535 and differ: the installer stops with exit 10 otherwise, the stream manager with exit 4.

**Examples:**
```bash
# Increase startup delay for slow USB devices
sudo env STREAM_STARTUP_DELAY=20 ./lyrebird-stream-manager.sh start

# Keep the stream manager's log somewhere else
sudo env STREAM_MANAGER_LOG_FILE=/mnt/storage/lyrebird-stream-manager.log ./lyrebird-stream-manager.sh start
```

**Invalid values.** A whole-number setting that is not a plain number (`MAX_RESTART_DELAY=5min`, `CRON_RESTART_MAX_PER_HOUR=unlimited`) is ignored and the built-in default is used, so a typo cannot stop monitoring. Four settings are the exception and stop the run with exit 4 instead of falling back: the three port variables, `LYREBIRD_START_POLICY` and `LYREBIRD_ALLOW_EMPTY_START` (a manager that publishes to the wrong port looks like a healthy node that records nothing). A damaged device configuration cannot stop streams either: a bad line is skipped and logged, and the file itself is replaced atomically, so a power cut does not leave half of it.

Removed settings: `AUDIO_DISK_PERSIST`, `AUDIO_DISK_PATH`, `HEARTBEAT_INTERVAL`, `HARDWARE_WATCHDOG_TIMEOUT`, `HARDWARE_WATCHDOG_DEVICE`, `ENABLE_HARDWARE_WATCHDOG`, `LYREBIRD_WATCHDOG_ENABLED`, `LYREBIRD_WATCHDOG_INTERVAL` and `LOCK_STALE_THRESHOLD` do nothing. When one is set, each run logs one warning saying so.

### Multiplex Streaming

Combine multiple microphones into a single RTSP stream using FFmpeg audio filters, for centralized monitoring or a combined recording. Options come before the command:

```bash
sudo ./lyrebird-stream-manager.sh -m multiplex -f amix start      # mix (the default filter)
sudo ./lyrebird-stream-manager.sh -m multiplex -f amerge start    # keep channels separate
sudo ./lyrebird-stream-manager.sh -m multiplex -n studio start    # name the stream (default: all_mics)
```

Under systemd, give the options to `install` so the unit and the cron job carry them: `sudo ./lyrebird-stream-manager.sh -m multiplex -f amix -n studio install`, then `sudo systemctl restart mediamtx-audio`.

The stream name is made lower-case with every run of characters outside `a-z 0-9 _ -` replaced by one `_` (`Studio Mix` becomes `studio_mix`, and the log says so). It must start with a letter or digit, be at most 64 characters and not be one of `control`, `stats`, `api`, `metrics`, `health`, `all` or `all_others`; otherwise the command stops with exit 4. Only microphones are mixed: a USB speaker or DAC without a capture PCM is left out. A microphone that is added makes the monitor restart the multiplex stream; one that disappears ends the wrapper, and the monitor restarts it with the rest.

#### amix Filter (Audio Mixing)

**Purpose:** mix several inputs into one stream with the channel layout of the inputs.

**How it works:**
- N inputs are mixed with equal weight into one stream; two stereo inputs give a stereo stream
- With FFmpeg 4.4 or newer the manager passes `normalize=0`, so the mix is the plain sum of the inputs. Measured with FFmpeg 6.1.1, two equal inputs come out 6 dB louder than amix's default scaling (20·log10 N for N inputs), and loud inputs can clip. With FFmpeg 4.2 and 4.3, which have no `normalize` option, the option is left out and amix's default scaling by 1/N applies. (The 4.2 and 4.3 path was tested with a stand-in `ffmpeg`, not a real one.)
- Output: `rtsp://host:8554/all_mics`

FFmpeg documentation: https://ffmpeg.org/ffmpeg-filters.html#amix

---

#### amerge Filter (Channel Merging)

**Purpose:** put all inputs into one stream with more channels, so each microphone stays on its own channel(s).

**How it works:**
- The output has (number of devices x channels per device) channels: three stereo microphones give 6 channels (channels 1-2 from the first, 3-4 from the second, 5-6 from the third)
- The codec has to be able to encode that many channels. The manager asks FFmpeg before it starts the stream; if FFmpeg refuses, nothing is started and the log says which combination failed and suggests `amix` or a different codec. Measured with FFmpeg 6.1.1: Opus refuses 2 stereo microphones (4 channels), 5 and 6 stereo (10 and 12 channels) and 3 or 4 mono; it accepts 1, 3 and 4 stereo and 1, 2, 5 and 6 mono. AAC refuses 5 and 6 stereo and accepts up to 4. MP3 accepted every count tried (FFmpeg downmixes to 2). Other FFmpeg versions or real ALSA layouts may differ, which is why FFmpeg is asked.
- Playback needs a player that handles multi-channel audio
- USB clock drift between independent microphones was not evaluated (it needs hardware)

FFmpeg documentation: https://ffmpeg.org/ffmpeg-filters.html#amerge-1

---

#### Comparison: amix vs amerge

| Feature | amix (Mixing) | amerge (Merging) |
|---------|---------------|------------------|
| Output channels | Same as one input | Sum of all inputs (the codec must accept it) |
| Channel separation | Lost (mixed together) | Preserved |
| Bandwidth usage | Lower | Higher |
| Level | Plain sum with FFmpeg 4.4+: can clip | Unchanged per channel |
| Playback complexity | Simple | Needs a multi-channel player |

**Stream URLs:**
- Individual mode: `rtsp://ip:8554/device-name`
- Multiplex mode: `rtsp://ip:8554/all_mics` (or the name you gave)

---

## MediaMTX Integration

### Which unit runs MediaMTX

Exactly one program owns MediaMTX on a node. There are two owners, and they exclude each other:

| | Stream manager | Standalone |
|---|---|---|
| Unit | `mediamtx-audio.service` | `mediamtx.service` |
| Written by | `lyrebird-stream-manager.sh install` | `install_mediamtx.sh install` |
| Runs | MediaMTX and the FFmpeg streams, as root | MediaMTX only, as the `mediamtx` user the installer creates |
| Use it for | audio streaming: this project's purpose | MediaMTX-only installs |
| MediaMTX configuration | rendered at every start (see below) | rendered once, by `install` |
| Where the log goes | `/var/log/lyrebird-stream-manager.log` and `/var/log/mediamtx.out`; `journalctl -u mediamtx-audio` shows only systemd's own start and stop messages | the journal: `journalctl -u mediamtx` |
| Reload | `systemctl reload mediamtx-audio` | none: MediaMTX re-reads its configuration file by itself |

Each unit has `Conflicts=` on the other, so starting one stops the other, and the stream manager refuses to start (exit 8, nothing changed) while `mediamtx.service` is active or while another process runs the configured MediaMTX binary on the configured configuration file. It never signals a process it did not start. The installer's closing message offers `systemctl start mediamtx` as an alternative to the stream manager; use one of them, not both.

A node can also run the stream manager without systemd (`sudo ./lyrebird-stream-manager.sh start`). The manager then owns MediaMTX, but nothing restarts it at boot.

**To tell who owns a node:**
```bash
systemctl is-active mediamtx mediamtx-audio
sudo ./install_mediamtx.sh status      # "Running (systemd)", "(stream manager service)", "(stream manager)" or "(manual)"
sudo ./lyrebird-stream-manager.sh status
```

**To move from the standalone unit to the stream manager:**
```bash
sudo systemctl disable --now mediamtx
sudo ./lyrebird-stream-manager.sh install
sudo systemctl enable --now mediamtx-audio
```

### Configuration ownership

The stream manager renders `/etc/mediamtx/mediamtx.yml` itself. The first line of a file it may rewrite is exactly:

```
# Managed by LyreBirdAudio
```

- **A file with that first line is the project's.** When the manager's rendering of it changes (at `start`, `restart` or `reload`) the old file is saved next to it as `mediamtx.yml.<UTC time>.<nn>.bak` (same mode and owner; the newest `MEDIAMTX_CONFIG_BACKUPS`, default 5, are kept) and the new one is written atomically (temporary file, `fsync`, rename, `fsync` of the directory). An unchanged rendering touches nothing.
- **A file without it is yours.** It is used as it is, checked, and never rewritten; each start logs one warning that names `--regenerate-config`. `RTSP_AUTH_MODE` has no effect on it.
- **To keep hand edits in a generated file, delete the first line.** From then on neither the stream manager nor `install_mediamtx.sh` (without `--force`) rewrites it.
- **To hand a file back**, run `sudo ./lyrebird-stream-manager.sh --regenerate-config start` (or `restart`). A backup is saved first. (`install_mediamtx.sh --force install` does the same for the standalone installation.)
- **Checking before replacing.** A changed rendering is checked with MediaMTX's own `--validate-conf` where the binary has it (of the tested versions, 1.21.1 and later; the flag does not exist in 1.15.0, 1.18.0 or 1.19.0), and a file MediaMTX rejects never replaces the old one. Older binaries get only a structural check (readable, not empty, no tab indentation, a top-level key); an unknown key or invalid path name then shows up when MediaMTX refuses to start (the reason is in `MEDIAMTX_LOG_FILE`).
- **The installer writes the same file.** Both generate it with the same function in `lyrebird-common.sh`, so a manager start on a file the installer wrote changes nothing. `install_mediamtx.sh update` does not rewrite it, except that crossing MediaMTX 1.19 adds the one line `moq: no` to a file that carries the marker.
- **Files written by earlier releases** are handled as described in [Upgrading an Existing Node](#upgrading-an-existing-node), step 6.

What the generator writes (MediaMTX 1.19 or later, individual mode, default ports):

```yaml
# Managed by LyreBirdAudio
logLevel: info
readTimeout: 30s
writeTimeout: 30s

api: yes
apiAddress: 127.0.0.1:9997

metrics: yes
metricsAddress: 127.0.0.1:9998

rtsp: yes
rtspAddress: :8554
rtspTransports: [tcp, udp]

rtmp: no
hls: no
webrtc: no
srt: no
moq: no                # written only for MediaMTX 1.19.0 and later: older versions reject the key

paths:
  '~^[a-zA-Z0-9_-]+$': # multiplex mode: one quoted path, the stream name
    source: publisher
    sourceProtocol: automatic
    sourceOnDemand: no
```

(The first lines of the real file also carry a comment that explains the marker.)

### Listeners and who can connect

| Listener | Default | Who can use it |
|----------|---------|----------------|
| RTSP | TCP `:8554` on every interface, plus UDP `8000` (RTP) and `8001` (RTCP) | **Anyone who can reach the port can publish and read, without a password,** unless `RTSP_AUTH_MODE=local-only-publish` |
| Control API | `127.0.0.1:9997` | This machine. MediaMTX also answers 401 to a caller from another address when the API is bound wider |
| Metrics | `127.0.0.1:9998` | The same |
| SRT, RTMP, HLS, WebRTC | off | - |
| MoQ (MediaMTX 1.19 and later) | off | - |

That is the exact set of sockets MediaMTX opens with the generated configuration, checked by the live tests on MediaMTX 1.15.0, 1.18.0, 1.19.0, 1.21.1, 1.21.2 and 1.21.3. A connection from the machine's own non-loopback address could not reach the API or the metrics endpoint; a client on a second host and IPv6 (`::1`) were not tested.

The ports are `MEDIAMTX_RTSP_PORT`, `MEDIAMTX_API_PORT` and `MEDIAMTX_METRICS_PORT`; the bind addresses are `MEDIAMTX_API_BIND` and `MEDIAMTX_METRICS_BIND` (an address, or an empty string for every interface). A port that is not a whole number from 1 to 65535 stops the stream manager with exit 4 and the installer with exit 10. Authentication and the other hardening steps are in [Security Hardening](#security-hardening).

### Reading MediaMTX's state

The manager asks the MediaMTX API where it listens (`MEDIAMTX_API_BIND`, else `MEDIAMTX_HOST`). A start waits (`MEDIAMTX_API_TIMEOUT`, 60 s) for an answer that is HTTP 200 with a list of paths; 404 on `/v3` moves on to older API versions. An API behind authentication (401 or 403) is treated as "MediaMTX is up, but stream health cannot be read through it": `start` continues with one warning, and no stream is counted against.

### Reload

`sudo ./lyrebird-stream-manager.sh reload` (what `systemctl reload mediamtx-audio` runs) renders the configuration again and lets the running MediaMTX apply it; MediaMTX watches its file. Nothing is stopped, and a stream whose wrapper runs is left alone. The log names each changed key. Changes to `api`, `apiAddress`, `rtmp`, `hls`, `webrtc` or `srt`, and a path that is added, leave publishers connected. Changes to `logLevel`, the timeouts, `metrics`, `metricsAddress`, `rtsp`, `rtspAddress` or `rtspTransports` make MediaMTX disconnect every publisher, whose wrappers then reconnect them (a gap per stream); a changed path entry disconnects that path's publishers. Per-device audio settings are part of a running wrapper, so `reload` does not apply them; `restart` does. Exit 7 means MediaMTX is not running (use `start`); exit 8 means another owner has it. A configuration MediaMTX cannot load makes the running MediaMTX log the error and exit, which is why `reload` installs only what the generator wrote and never an operator's file.

---

## Troubleshooting

### Quick Diagnostics

```bash
# Run health check
sudo ./lyrebird-diagnostics.sh quick

# What the stream manager sees, per stream, with the reason for each failure
./lyrebird-stream-manager.sh status

# What each USB sound card supports
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

With no microphone detected, `start` by default still brings MediaMTX up and exits 0; `status` then shows `Overall: waiting_for_devices` and the monitor starts a stream when a microphone appears. With `LYREBIRD_ALLOW_EMPTY_START=false`, `start` exits 6 instead. A USB speaker or DAC has no capture PCM and is skipped, so a node with only speakers also waits for devices.

#### Streams Won't Start

```bash
# The exit status says what happened (see the table in "Stream Manager"):
#   3 a dependency is missing, 4 a setting or the configuration is invalid,
#   5 another start/stop is running, 8 another MediaMTX owns the node,
#   9 no stream is publishing
sudo ./lyrebird-stream-manager.sh start; echo "exit status: $?"

# The reason for each stream that is not publishing
./lyrebird-stream-manager.sh status --json | jq '.streams[] | {path, last_error}'

# Logs: the manager, MediaMTX, and each stream's FFmpeg
sudo tail -n 100 /var/log/lyrebird-stream-manager.log
sudo tail -n 100 /var/log/mediamtx.out
sudo tail -n 50 /var/lib/mediamtx-ffmpeg/*.log

# Validate configuration
./lyrebird-stream-manager.sh validate
sudo ./lyrebird-mic-check.sh -V

# Clean restart: stops only the processes this manager started
sudo ./lyrebird-stream-manager.sh force-stop
sudo ./lyrebird-stream-manager.sh start

# Check for processes holding the capture devices
sudo lsof /dev/snd/*
```

Exit 8 means `mediamtx.service` is running or a MediaMTX was started by hand on the same binary and configuration; stop it (`sudo systemctl stop mediamtx`) or use it instead ([Which unit runs MediaMTX](#which-unit-runs-mediamtx)). A MediaMTX that cannot load its configuration logs the error to `/var/log/mediamtx.out` and exits.

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

- `lyrebird-stream-manager.sh`, `install_mediamtx.sh` and `usb-audio-mapper.sh` (except `--list`) need root; run them with `sudo`. The stream manager's unit runs as root.
- `lyrebird-updater.sh` must **not** run as root. If it says the repository is owned by root (exit 5), give the clone back to your user: `sudo chown -R $USER:$USER /path/to/LyreBirdAudio`.
- Without root, `lyrebird-stream-manager.sh status` shows a stream wrapper it cannot identify as `Unknown (... run as root)`, and `lyrebird-metrics.sh` leaves out what it cannot read and reports `lyrebird_scrape_success 0`. Run both as root for a complete answer.

#### MediaMTX Crashes

```bash
# Check system resources
free -h
df -h

# MediaMTX's own output
sudo tail -n 100 /var/log/mediamtx.out

# systemd's view of the unit that runs it
sudo systemctl status mediamtx-audio      # or: mediamtx, for the standalone unit
sudo journalctl -u mediamtx -n 100        # standalone unit only: its output goes to the journal

# The open-file limit the unit gives its process
systemctl show mediamtx-audio -p LimitNOFILE

# Restart
sudo systemctl restart mediamtx-audio
```

Both shipped units set `LimitNOFILE` themselves (65536 for the stream manager, 65535 for the standalone unit); `/etc/security/limits.conf` applies to login sessions, not to services that systemd starts.

#### High CPU Usage

**Symptoms**: System becomes unresponsive

**Diagnosis:**
```bash
# MediaMTX's file descriptors, CPU and threads, and the state of every stream
sudo ./lyrebird-stream-manager.sh status

# Thresholds, warnings and restarts are logged by the monitor
sudo grep -E 'CPU|Critical|Warning' /var/log/lyrebird-stream-manager.log | tail -n 20
```

**Solutions:**
- Reduce sample rate in audio-devices.conf
- Use lower bitrate encoding
- Reduce number of simultaneous streams
- Check that there are not more FFmpeg processes than streams (the monitor reports extra wrapper processes and exits 2)

#### MediaMTX Won't Update

**Symptoms**: Update command fails

**Diagnosis:**
```bash
sudo ./install_mediamtx.sh status
curl -I https://api.github.com/repos/bluenviron/mediamtx/releases/latest
```

**Solutions:**
- Check network connectivity and that GitHub is reachable (exit 5 is a failed download or release lookup)
- Try a specific version: `sudo ./install_mediamtx.sh -V v1.21.3 update`
- A checksum mismatch (exit 6) is never accepted, not even with `--force`; `--force` only skips the check when the release has no checksum file
- Exit 7 means the new binary did not run or the service did not come back up and the previous binary was restored; a MediaMTX that nobody supervises (started by hand) is stopped and left stopped, and the command to start it is printed

#### Version Update Failed

**Symptoms**: Update errors, a conflict, or an update that was interrupted

**Diagnosis:**
```bash
./lyrebird-updater.sh --status
./lyrebird-updater.sh --history        # shows an update that did not finish
git status
git stash list                         # your saved changes: entries named lyrebird-tx-... or lyrebird-recovery-...
```

**Solutions:**
- Run `./lyrebird-updater.sh` again: it finds an unfinished update and undoes it (or completes a self-update); your local changes come back from the stash
- Exit 10 means the switch is done but your saved changes conflicted with the new version; they are in the stash (`git stash list`, then `git stash show -p` and apply what you need)
- Go back: `./lyrebird-updater.sh --rollback`
- Menu option 6, "Discard All Changes & Reset", resets to a clean state after a confirmation and throws local modifications away
- Check repository ownership: `stat -c %U .git/config` must not print `root` ([Version Management](#version-management))

### Debug Procedures

**Enable Verbose Logging:**
```bash
sudo ./lyrebird-stream-manager.sh -d start        # debug messages
sudo env DEBUG=true ./lyrebird-stream-manager.sh start   # also traces every command
```
`DEBUG=1` does nothing: the value must be `true`.

**Check All Logs:**
```bash
sudo tail -f /var/log/mediamtx.out
sudo tail -f /var/log/lyrebird-stream-manager.log
sudo tail -f /var/lib/mediamtx-ffmpeg/*.log
```

**Validate Configuration:**
```bash
# MediaMTX's own check; exists from MediaMTX 1.21.1 (older binaries have no such flag)
/usr/local/bin/mediamtx --validate-conf=/etc/mediamtx/mediamtx.yml
./lyrebird-stream-manager.sh validate
cat /etc/mediamtx/audio-devices.conf
```

**Test RTSP Manually:**
```bash
ffplay -i rtsp://localhost:8554/mic-left -loglevel debug
```

**Check System Resources:**
```bash
sudo ./lyrebird-diagnostics.sh full
sudo ./lyrebird-stream-manager.sh status
```

### Log Locations

**Service logs:**
- MediaMTX: `/var/log/mediamtx.out`
- Stream Manager: `/var/log/lyrebird-stream-manager.log`
- Orchestrator: `/var/log/lyrebird-orchestrator.log`
- Diagnostics: `/var/log/lyrebird-diagnostics.log`
- Alerts: `/var/log/lyrebird/alerts.log`

**Stream logs:**
- FFmpeg, per stream: `/var/lib/mediamtx-ffmpeg/<stream>.log`; the runs before it are `<stream>.log.prev.1`, `.prev.2`, ... (`FFMPEG_LOG_KEEP`, default 3). `start`, `stop` and `force-stop` never delete them.

**System logs:**
```bash
# The standalone MediaMTX unit logs to the journal
sudo journalctl -u mediamtx -f

# The stream manager unit logs to its file; the journal has systemd's start and stop messages
sudo journalctl -u mediamtx-audio -n 50

# USB events
sudo dmesg | grep -i usb
```

### Collecting Debug Information

For bug reports, collect:

```bash
# 1. Run full diagnostics
sudo ./lyrebird-diagnostics.sh full > diagnostics.txt 2>&1

# 2. What the stream manager sees
./lyrebird-stream-manager.sh status --json > status.json

# 3. Collect logs
sudo tar -czf lyrebird-logs-$(date +%Y%m%d).tar.gz \
  /var/log/mediamtx.out \
  /var/log/lyrebird-stream-manager.log \
  /var/lib/mediamtx-ffmpeg/*.log* \
  /etc/mediamtx/audio-devices.conf \
  /etc/udev/rules.d/99-usb-soundcards.rules

# 4. System info
cat /etc/os-release > system-info.txt
uname -a >> system-info.txt
lsusb >> system-info.txt
```

Include diagnostics.txt, status.json, the logs tarball, and system-info.txt in your issue report. Do not add `/etc/mediamtx/mediamtx.yml`, `/etc/mediamtx/rtsp-users.conf` or `/etc/lyrebird/alerts.conf` unless you have removed password hashes and webhook URLs from them.

**GitHub Issues:** https://github.com/tomtom215/LyreBirdAudio/issues

---

## Diagnostics & Monitoring

### Health Checking

`lyrebird-diagnostics.sh` runs a series of checks and prints `[PASS]`, `[WARN]`, `[FAIL]` and `[INFO]` lines.

**Quick Check** (prerequisites, project versions and files, log locations, USB devices, the MediaMTX service, the RTSP port and server, inotify and entropy):
```bash
sudo ./lyrebird-diagnostics.sh quick
```

**Full Check** (the default; all numbered sections below):
```bash
sudo ./lyrebird-diagnostics.sh full
```

**Debug Check** (the full check with debug output; `verbose` is another name for the same command):
```bash
sudo ./lyrebird-diagnostics.sh debug
```

### What Gets Checked

The full and debug runs print 24 numbered sections:

- Prerequisites and dependencies; project information and versions; system information
- USB audio devices and audio capabilities (ALSA status, device busy state)
- The MediaMTX service: binary, configuration file, device configuration, service state, whether the RTSP port is listening
- Stream health and status; RTSP connectivity (the RTSP port; the API is not checked)
- Resource usage, system limits, disk and storage, file permissions and ownership
- Log analysis; configuration validation; service configuration and dependencies
- Time and clock synchronization (NTP, chrony)
- Process stability and crash detection; file descriptor leak detection; audio subsystem conflicts; inotify and entropy; network resources

The RTSP port checked is `MEDIAMTX_PORT` (default 8554). The diagnostics do not read `MEDIAMTX_RTSP_PORT`, which the other scripts use, so on a node with a different RTSP port set both. The FFmpeg log directory it looks at (`FFMPEG_LOG_DIR`, default `/var/log/lyrebird`) is not where the stream manager writes the FFmpeg logs (`/var/lib/mediamtx-ffmpeg/`).

### Diagnostic Exit Codes

- `0`: All checks passed
- `1`: Warnings detected (the system works but needs attention)
- `2`: Failures detected (the system is degraded or not working)
- `127`: The script itself could not run: missing dependencies, an unknown option, an unreadable `--config` file

### Integration with Orchestrator

The orchestrator runs diagnostics from three places:

1. **Quick Health Check** (Main Menu -> 7 -> 5): fast check; the wizard runs it as its last step.
2. **Full Diagnostic** (Main Menu -> 5 -> 2): the full run; use it for troubleshooting.
3. **Verbose Diagnostic** (Main Menu -> 5 -> 3): the debug run.

### The Monitor

`lyrebird-stream-manager.sh monitor` is what the cron job runs every 5 minutes. Run by hand it does the same work, including restarting what it finds dead. Each run, in this order:

1. Checks the resources of MediaMTX and FFmpeg (file descriptors, CPU, extra wrapper processes) and the system's disk, memory and network. Critical resource use makes it exit 2 at once, without the steps below, and the cron job then restarts `mediamtx-audio`; the other findings are logged.
2. Writes the heartbeat (`/run/mediamtx-audio.heartbeat`): the Unix time of this run, nothing more.
3. Reads each published stream back for `AUDIO_LEVEL_SAMPLE_DURATION` seconds (default 3) with FFmpeg's `volumedetect`, at most once per `AUDIO_LEVEL_CHECK_INTERVAL` seconds per stream. A level at or below `AUDIO_SILENCE_THRESHOLD_DB` (-60) logs a warning and starts a silence episode; after `AUDIO_SILENCE_WARN_DURATION` seconds (60) one `DEAD MIC` error is logged for the episode, and a later signal logs that the audio recovered. It opens no ALSA device, restarts nothing and raises no metric or alert: the log line in `/var/log/lyrebird-stream-manager.log` is the signal. A MediaMTX that requires credentials for reading answers the probe with 401, which is logged as a probe error and never counted as silence.
4. Takes the lifecycle lock for at most `MONITOR_LOCK_TIMEOUT` seconds (5). If `start`, `stop`, `restart` or `force-stop` is running it skips the rest of the cycle and exits 0.
5. Starts a stream whose wrapper died or whose microphone appeared, restarts a stream whose path stayed not ready for `DEEP_HEALTH_MAX_STRIKES` runs, and starts MediaMTX again when it is gone and `start` was run and `stop` was not. All restarts share the budget of `CRON_RESTART_MAX_PER_HOUR` per hour (per stream, and one for MediaMTX). A microphone whose card cannot be opened does not use up the budget.
6. Refreshes `/run/lyrebird/status.json`.

Exit status of `monitor`: `0` healthy, waiting for devices, or skipped because a lifecycle command was running; `2` critical resource use; `6` no USB devices (only with `LYREBIRD_ALLOW_EMPTY_START=false`); `7` MediaMTX not running and not started again (not meant to run, budget used up, or the restart failed); `10` some streams degraded. The cron job restarts the service on 2 and only logs the others.

### Status document

Every command that changes or checks state (`start`, `stop`, `force-stop`, `monitor`, `status`) writes `/run/lyrebird/status.json` atomically; `status --json` prints the same document computed live. It describes the node as of the last command that ran: use `timestamp_epoch` to judge how old it is (the monitor refreshes it every cycle). A reader must treat a missing file as "unknown". The file is mode 0644; an unwritable location never fails the command.

```json
{"schema_version":1,"timestamp":"2026-11-11T22:10:44Z","timestamp_epoch":1794435044,
 "command":"monitor","overall":"degraded","policy":"degraded","stream_mode":"individual",
 "mediamtx":{"running":true,"pid":1234},
 "streams":[{"device":"usb-Blue_Yeti","card":"3","path":"yeti","configured":true,
             "process_alive":true,"path_ready":true,"bytes_flowing":true,"last_error":null},
            {"device":"usb-Mic2","card":"4","path":"mic2","configured":false,
             "process_alive":false,"path_ready":false,"bytes_flowing":false,
             "last_error":"no stream wrapper is running for this stream"}]}
```

| Field | Meaning |
|-------|---------|
| `command` | The command that wrote the file |
| `overall` | `ok`: every expected stream is publishing. `degraded`: some are. `failed`: none is, or MediaMTX is down although the node is meant to run. `waiting_for_devices`: MediaMTX is up and no capture-capable device is detected. `stopped`: down on purpose. It does not depend on the policy |
| `policy` | `degraded` or `strict` (`invalid` if `LYREBIRD_START_POLICY` is wrong): decides `start`'s exit status only |
| `stream_mode` | `individual` or `multiplex` |
| `mediamtx` | `running` and `pid` |
| `streams[]` | One entry per detected capture-capable device (one for the whole set in multiplex mode, with `device` and `card` comma-joined). A stopped node lists none |
| `configured` | The stream's wrapper script exists and a wrapper was launched |
| `process_alive` | That wrapper runs and is provably this manager's |
| `path_ready` | MediaMTX's API reports the path ready |
| `bytes_flowing` | The path's inbound byte counter grew between two samples `LYREBIRD_FLOW_SAMPLE_SECONDS` apart |
| `last_error` | `null` while the stream publishes with bytes flowing; otherwise the reason the writing command found, as text for a person (not an enumeration, and not remembered between commands) |
| `skipped` | Present, and `true`, only for a card with no capture PCM (a speaker or DAC); consumers that count streams must ignore those entries |

`configured`, `process_alive`, `path_ready` and `bytes_flowing` are `true`, `false` or `null`. `null` means not known (the API did not answer, or answered 401/403 or an error), and `last_error` then says so. A path nobody publishes to is `false`, not `null`. `lyrebird-stream-manager.sh status` (human form) shows the same per stream and ends with `Overall: <state> (start policy: <policy>)`; it exits 0 whatever the state, so use `status --json` or the file to decide. A `status` run takes `LYREBIRD_FLOW_SAMPLE_SECONDS` seconds longer when a stream is ready.

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
   sudo ./lyrebird-diagnostics.sh debug
   ```

4. Check what the stream manager sees:
   ```bash
   ./lyrebird-stream-manager.sh status --json | jq .overall
   ```

5. Check logs regularly:
   ```bash
   sudo tail -f /var/log/lyrebird-stream-manager.log
   ```

6. Scrape `lyrebird-metrics.sh` and alert on `lyrebird_scrape_success == 0` ([Prometheus Metrics](#prometheus-metrics-lyrebird-metricssh)); use [Webhook Alerts](#webhook-alerts-lyrebird-alertssh) from your own scripts.

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

No CPU, memory or bandwidth figures were measured for this release. What follows is how the settings trade quality against load, plus arithmetic you can check yourself. To measure your own node, use `lyrebird-stream-manager.sh status`, the metrics in [Prometheus Metrics](#prometheus-metrics-lyrebird-metricssh), and the soak harness in `tools/soak/`.

### Stream Optimization

**Codec Selection** (`CODEC`: `opus`, `aac` or `mp3`):
- **Opus**: libopus, the default
- **AAC**: FFmpeg's native AAC encoder
- **MP3**: encoded with libmp3lame
- PCM is not supported: a `CODEC` outside these three is an error and the setting keeps its default

**Sample Rate Selection:**
- **48000 Hz**: standard for professional audio (the default)
- **44100 Hz**: CD quality, slightly lower bandwidth
- **96000 Hz**: high-resolution audio, double the data before encoding

**Bitrate Tuning:**
- **96k**: acceptable for speech
- **128k**: the default
- **256k**: high quality music

**Example Configuration** (`/etc/mediamtx/audio-devices.conf`):
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
- Look at it with `sudo ./lyrebird-stream-manager.sh status` (MediaMTX) or `top`
- The monitor warns above 20% and treats 40% as critical (`MAX_CPU_WARNING`, `MAX_CPU_CRITICAL`); a critical value makes it exit 2 and the cron job restart the service
- Lowering the sample rate or the bitrate lowers the encoder's work

**Memory Usage:** not measured. The monitor reports system memory and logs when it passes `MEM_WARNING_PERCENT` (80) and `MEM_CRITICAL_PERCENT` (95); `lyrebird_stream_memory_bytes{stream=...}` and `lyrebird_mediamtx_memory_bytes` give the per-process numbers.

**Network Bandwidth:**
- The encoded bitrate divided by 8 gives the data rate: 128 kbit/s is 16 kB/s and 256 kbit/s is 32 kB/s, per stream per client, before container and network overhead
- Consider bandwidth when choosing a bitrate

### System Tuning

**File Descriptor Limits:** the shipped units set `LimitNOFILE` (65536 for `mediamtx-audio.service`, 65535 for `mediamtx.service`). Check what a running unit has with `systemctl show mediamtx-audio -p LimitNOFILE`. `/etc/security/limits.conf` applies to login sessions, not to services started by systemd. To change a unit's limit use `sudo systemctl edit mediamtx-audio` and set `LimitNOFILE=` under `[Service]`.

**Thread Queue Size** (FFmpeg input buffering; default 8192):
```bash
# For one device, in /etc/mediamtx/audio-devices.conf
DEVICE_USB_MICROPHONE_1_THREAD_QUEUE=16384

# For every device: set DEFAULT_THREAD_QUEUE in the environment (see Environment Variables).
# A DEFAULT_THREAD_QUEUE line in audio-devices.conf is an error and is ignored.
```

**Network Buffer Sizes** (not measured on this project; MediaMTX's own documentation discusses UDP receive buffers):
```bash
sudo sysctl -w net.core.rmem_max=26214400
# Persist in a file under /etc/sysctl.d/ if you decide to keep it
```

### For Raspberry Pi

```bash
# Use lower quality settings
sudo ./lyrebird-mic-check.sh -g --quality=low
```

How many microphones a given board sustains was not measured: soak-test it ([Testing](#testing)).

### Monitoring and Alerting

**Resource Monitoring:** `lyrebird-stream-manager.sh install` writes the cron job `/etc/cron.d/mediamtx-monitor` (every 5 minutes, under `flock`); see [The Monitor](#the-monitor) for what each run does. For metrics and alerts see [Prometheus Metrics](#prometheus-metrics-lyrebird-metricssh) and [Webhook Alerts](#webhook-alerts-lyrebird-alertssh).

**Log Rotation:** `install` writes `/etc/logrotate.d/mediamtx` when `logrotate` is installed. It rotates three things with `copytruncate` and compression, keeping seven rotations (three for the FFmpeg logs), with these size limits:

| Log | Size limit (variable) |
|-----|-----------------------|
| `MEDIAMTX_LOG_FILE` (`/var/log/mediamtx.out`) | 50 MiB (`MEDIAMTX_LOG_MAX_SIZE`) |
| `STREAM_MANAGER_LOG_FILE` | 100 MiB (`MAIN_LOG_MAX_SIZE`) |
| `/var/lib/mediamtx-ffmpeg/*.log` | 10 MiB (`FFMPEG_LOG_MAX_SIZE`) |

The sizes are the values in the environment of the shell that ran `install`. `config/lyrebird-logrotate.conf` is an example you can copy to `/etc/logrotate.d/` instead; its FFmpeg stanza names `/var/log/lyrebird/`, where the stream manager does not write.

---

## Architecture & Design

For system architecture diagrams, see the [System Overview](#system-overview) section.

### Architecture Philosophy

**Why Bash?**

Bash is on every target system and needs no runtime beyond the tools listed under [System Requirements](#system-requirements): no pip/npm/gem conflicts, no build process. Deployment is: clone, `chmod +x`, run.

**Why No Docker?**

USB device management requires host-level udev rule creation and direct USB subsystem access. Containers add complexity that conflicts with physical USB port mapping (a core feature). Designed for dedicated hosts where simple systemd services provide the process management.

**Single-Responsibility Principle:**

Each script handles one specific domain:
- Orchestrator: user interface and delegation only
- Installer: MediaMTX installation lifecycle
- Stream Manager: MediaMTX and FFmpeg process management
- USB Mapper: device persistence via udev
- Mic Check: hardware capability detection
- Updater: version management
- Diagnostics: system health validation
- Metrics, Storage, Alerts: optional tools next to the stream path
- `lyrebird-common.sh`: the code the scripts share (logging, atomic and durable file writes, the MediaMTX configuration renderer)

Some design rules the code follows, with the decision numbers of `docs/REMEDIATION-2026-11.md`: one owner of MediaMTX (D1); locks are `flock` on files that are never deleted (D2); configuration files are parsed as data and never sourced (D3); `start` reports what is publishing, not what was launched (D4); processes are identified by executable, argument and start time, never by name (D11); there is one canonical stream name (D13); files are replaced with write, `fsync`, rename, `fsync` of the directory (D14).

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

**Purpose:** a menu that runs the other scripts and explains what they report.

**Usage:**
```bash
sudo ./lyrebird-orchestrator.sh
```
Options: `-h, --help`, `-v, --version`. It must run as root; it starts the updater as the user who invoked `sudo`.

**Features:**
- Quick Setup Wizard: install MediaMTX, map devices, start streams, quick diagnostics. Its closing summary is decided by what the start reported (the status document and exit status), not by a process count
- After Start All Streams or Restart All Streams: one line per stream (publishing, bytes flowing or not, the manager's `last_error`) and the next step for the exit status
- When a delegated script fails, shows its exit status with a meaning: the stream manager's 1 to 10 and signals, the updater's 1 to 11, the installer's 7
- Device capability inspection and configuration generation (USB Device Management)
- Version Management: launch the updater, show component versions, show the update history, roll back to a previous version
- SHA256 integrity check of the scripts it delegates to (the baseline is refreshed after an update or rollback)
- Handles end of input on every menu; its log is rotated at 1 MiB

**Limits:** the `MediaMTX:` and `Active Streams:` lines in the menu header come from a process-name scan (a process called `mediamtx`; every `ffmpeg` on the host counts as a stream), so another FFmpeg on the machine is counted. The status document is the authoritative state. The "View Stream URLs" entry prints port 8554 whatever `MEDIAMTX_RTSP_PORT` says, and "View Stream Logs (FFmpeg)" looks in `/var/log/lyrebird`, while the manager keeps those logs in `/var/lib/mediamtx-ffmpeg`.

**When to Use:** initial setup, interactive troubleshooting, log viewing

**Exit Codes** (of the orchestrator itself):
- 0: Success
- 1: General error
- 2: Permission denied
- 3: Missing dependencies
- 4: Script not found

---

### Version Manager (lyrebird-updater.sh)

**Purpose:** switch a git clone between versions, with history and rollback. [Version Management](#version-management) has the commands, the menu, what an update does, the lock and every exit code (0 to 12).

**Usage:**
```bash
./lyrebird-updater.sh                  # interactive menu
./lyrebird-updater.sh --status         # current version and sync state
./lyrebird-updater.sh --list           # list versions (needs the network)
./lyrebird-updater.sh --history        # past updates (local)
./lyrebird-updater.sh --rollback       # back to the previous version
```

**Requirements:**
- `git` 2.0 or newer, `flock`, `awk`, `sed`, `grep`, `tput`
- A git clone of this repository with a remote `origin` (not a tarball install)
- Run as the clone's owner, not as root

---

### Stream Manager (lyrebird-stream-manager.sh)

**Purpose:** start, stop, check and recover MediaMTX and one FFmpeg stream per microphone. `lyrebird-stream-manager.sh help` prints the same exit codes and settings as this section.

**Usage** (options come before the command):
```bash
# Individual streams (the default)
sudo ./lyrebird-stream-manager.sh start

# Multiplex mode
sudo ./lyrebird-stream-manager.sh -m multiplex -f amix start

# Machine-readable status
./lyrebird-stream-manager.sh status --json

# Install the systemd unit and the monitor cron job
sudo ./lyrebird-stream-manager.sh install
```

**Commands**

| Command | What it does |
|---------|--------------|
| `start` | Starts MediaMTX and a stream per capture-capable USB audio device. Exit 0 when the start policy is met, 9 when it is not. Safe to repeat: a MediaMTX this manager started is left alone (same PIDs, no outage) and only missing streams are started. Refused with exit 8 while another MediaMTX owns the node. A start that fails stops what that run started and never touches a stack that was already running |
| `stop` | Stops the streams and MediaMTX. Only processes this manager started are signalled (PID files and process start time); SIGTERM first, SIGKILL after a timeout. Exit 1 if something could not be stopped |
| `force-stop` | SIGKILL at once to the processes this manager started (emergency use; FFmpeg logs are kept) |
| `force-stop --kill-all [--yes]` | The only broad kill: every process whose executable is the configured MediaMTX binary (another configuration's MediaMTX too), whose command line names a file in the wrapper directory, or that is an FFmpeg logging there. Without `--yes` it prints those processes and why, signals nothing and exits 1 |
| `restart` | Stops and starts everything; the streams are interrupted |
| `reload` | Re-renders the MediaMTX configuration and lets the running MediaMTX apply it; stops nothing ([Reload](#reload)) |
| `status`, `status --json` | Shows MediaMTX, every stream and the overall state; `--json` prints the [status document](#status-document) |
| `config` | Shows the device configuration (writes the template if the file is missing) |
| `validate` | Checks the device configuration file; exit 0, or 4 if a line cannot be used. Needs no root |
| `monitor` | The cron job's command ([The Monitor](#the-monitor)) |
| `install` | Writes the systemd unit and the monitor cron job ([Systemd Service Installation](#systemd-service-installation)) |

**Options:** `-m, --mode individual|multiplex`, `-f, --filter amix|amerge`, `-n, --name NAME` (multiplex stream name), `--regenerate-config` (with `start` or `restart`: replace a MediaMTX configuration that is not managed, after a backup), `-d, --debug`, `-h, --help`.

**Start policy.** `LYREBIRD_START_POLICY` decides when `start` counts as successful. `degraded` (the default): at least one stream is publishing. `strict`: the stream of every detected device is. "Publishing" means MediaMTX's API says the path is ready after the stream had `STREAM_VALIDATION_ATTEMPTS` x `STREAM_VALIDATION_DELAY` seconds (15 by default) to appear: a running FFmpeg is not enough. A USB speaker or DAC without a capture PCM is not counted. Any other value stops the run with exit 4.

**Empty start.** With no USB audio device, `start` by default (`LYREBIRD_ALLOW_EMPTY_START=true`) brings MediaMTX up with no stream, logs "waiting for devices", reports `waiting_for_devices` and exits 0; the monitor starts a stream for each device that appears. With `false`, `start` exits 6 and does not start MediaMTX.

**Exit codes**

| Code | Name | Meaning |
|------|------|---------|
| 0 | | Success. `start`: the start policy is met (also: no device and empty start allowed). `monitor`: healthy, waiting for devices, or skipped because a lifecycle command was running. `status`, `config`, `help`: always |
| 1 | `E_GENERAL` | General error: unknown option, MediaMTX did not come up, a port in use, `stop` could not stop something, not run as root, `force-stop --kill-all` without `--yes` |
| 2 | `E_CRITICAL_RESOURCE` | Critical resource state (`monitor`; the cron job restarts the service) |
| 3 | `E_MISSING_DEPS` | A dependency is missing (`ffmpeg`, `jq`, `arecord`, `curl`, the MediaMTX binary) |
| 4 | `E_CONFIG_ERROR` | An invalid port, `LYREBIRD_START_POLICY` or `LYREBIRD_ALLOW_EMPTY_START`; an invalid device configuration (`validate`); an invalid multiplex stream name; configuration or unit generation failed |
| 5 | `E_LOCK_FAILED` | Another lifecycle command holds the lock; nothing was changed |
| 6 | `E_USB_NO_DEVICES` | No USB audio device that can capture: `start` or `monitor` with `LYREBIRD_ALLOW_EMPTY_START=false` |
| 7 | `E_MEDIAMTX_DOWN` | `monitor`: MediaMTX is not running and was not started again (not meant to run, restart budget used up, or the restart failed); `reload`: not running |
| 8 | `E_OWNERSHIP` | Another MediaMTX owns the node: `start`, `restart` or `reload` refused, nothing changed |
| 9 | `E_STREAMS_FAILED` | `start` did not meet `LYREBIRD_START_POLICY`; what that run started was stopped again |
| 10 | `E_MONITOR_DEGRADED` | `monitor`: some streams are degraded |
| 128+N | | Terminated by signal N (130 for SIGINT, 143 for SIGTERM, 131 for SIGQUIT) |

**What a script that calls the manager should do with 5, 8 and 9**

- **5**: another `start`, `stop`, `restart` or `force-stop` is running. Nothing was changed, so wait a few seconds and try again. Do not delete the lock file ([Recovery Procedures](#recovery-procedures)).
- **8**: a different program owns MediaMTX (`mediamtx.service`, or a MediaMTX started by hand). This does not clear by itself; retrying changes nothing. Stop the other owner or use it ([Which unit runs MediaMTX](#which-unit-runs-mediamtx)).
- **9**: nothing met the start policy; no stream is publishing and MediaMTX was stopped again. Treat it as a failure, not as "started". Read `status --json` (or the file) for each stream's `last_error`. Under systemd the unit fails and `Restart=always` retries after 30 seconds, within the start limit.
- **6**: only with `LYREBIRD_ALLOW_EMPTY_START=false`; plug in a microphone. **0** after an empty start means MediaMTX is running with no stream: check `overall` for `waiting_for_devices`.

**Features:**
- Individual or multiplex streaming
- Truthful start: the exit status and the status document say whether streams publish
- One owner of MediaMTX; processes found and stopped by identity (executable, argument, start time), never by name
- Health monitoring and restart by a cron job ([The Monitor](#the-monitor))
- Wrapper-based FFmpeg supervision with exponential backoff
- Dual-lookup device configuration (stream name, then device name), parsed as data
- Previous FFmpeg logs kept per stream (`<stream>.log.prev.1`, ...)
- Lock-based concurrency control: a kernel `flock` that is never removed

**Streaming Modes:**

**Individual Mode** (default):
```bash
sudo ./lyrebird-stream-manager.sh start
# Creates one stream per microphone, for example rtsp://host:8554/mic-left
```

**Multiplex Mode with Audio Mixing:**
```bash
sudo ./lyrebird-stream-manager.sh -m multiplex -f amix start
# Creates rtsp://host:8554/all_mics (mixed audio)
```

**Multiplex Mode with Channel Separation:**
```bash
sudo ./lyrebird-stream-manager.sh -m multiplex -f amerge start
# Creates rtsp://host:8554/all_mics (one channel group per microphone)
```

### Systemd Service Installation

For unattended use, run the stream manager under systemd instead of by hand. Run by hand, `start` leaves MediaMTX and the streams running, but nothing starts them after a reboot, and only the cron monitor (if you installed it) restarts MediaMTX when it exits.

**What the unit gives you**
- Start at boot (after `systemctl enable`)
- `Restart=always` with a 30-second delay: a MediaMTX that exits is started again, within a limit of 10 starts in 20 minutes
- `ExecStop` stops the streams and MediaMTX; `ExecReload` runs `reload`
- A sandbox (`ProtectSystem=strict`, `NoNewPrivileges`, `PrivateTmp`, and others) makes the file system read-only except the directories the manager writes, which the unit lists or creates; it runs as root
- `Conflicts=mediamtx.service`: the standalone MediaMTX unit and this one never run together
- The unit appends the manager's output to `/var/log/lyrebird-stream-manager.log`; `journalctl -u mediamtx-audio` shows only systemd's own messages about the unit

It has no `WatchdogSec=`: the manager sends no systemd watchdog keep-alives, and the setting would make systemd kill the service every interval. See [Reliability](#reliability-what-recovers-and-what-does-not).

**Installation:**
```bash
# One-time setup, from the checkout: writes the unit and the monitor cron job
sudo ./lyrebird-stream-manager.sh install

# Enable at boot and start now
sudo systemctl enable --now mediamtx-audio

# Verify
sudo systemctl status mediamtx-audio
```

For a multiplex node give the options to `install`: `sudo ./lyrebird-stream-manager.sh -m multiplex -f amix -n studio install`. To change the mode later, run `install` again with the new options and restart the service. `systemctl edit mediamtx-audio` is for local overrides such as extra `Environment=` lines ([Environment Variables](#environment-variables)).

**Service Management:**
```bash
# Follow the manager's log
sudo tail -f /var/log/lyrebird-stream-manager.log

# Restart (applies code and device-configuration changes; the streams are interrupted)
sudo systemctl restart mediamtx-audio

# Apply a changed MediaMTX configuration without an outage for running streams
sudo systemctl reload mediamtx-audio

# Stop, and do not start at boot
sudo systemctl disable --now mediamtx-audio
```

**Cron Monitoring:**
`install` also writes `/etc/cron.d/mediamtx-monitor`. It runs `monitor` every 5 minutes under `flock -n /run/mediamtx-monitor.lock`, restarts `mediamtx-audio` when the monitor exits 2, and logs other non-zero exits with `logger -t mediamtx-monitor`. The file carries `STREAM_MODE`, `MULTIPLEX_FILTER_TYPE` and `MULTIPLEX_STREAM_NAME` as `NAME=value` lines so that the monitor runs in the unit's mode.

**Not tested:** the unit has been parsed by `systemd-analyze verify` and its write paths exercised in a mount-namespace emulation of `ProtectSystem=strict`; it has not been run by a real systemd manager (boot ordering, `Conflicts=`, `StateDirectory=`, the start limit with a late USB hub).

**When direct execution is acceptable:**
- One-time testing
- Development and debugging
- Short manual recording sessions
- Troubleshooting with immediate control

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
sudo ./usb-audio-mapper.sh -n -v 2e88 -p 4610 -u 1-2 -f mic-right

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
- `--rules-file <path>`: Rules file (default `/etc/udev/rules.d/99-usb-soundcards.rules`)
- `-V, --version`, `-h, --help`

**Exit status:** 0 ok, 1 error, 2 usage, 3 permission, 4 missing dependency (or not Linux), 5 device not found or ambiguous, 6 rule written but not applied by the kernel.

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

# Validate config against the hardware
sudo ./lyrebird-mic-check.sh -V

# JSON output
./lyrebird-mic-check.sh --format=json

# List and restore backups
./lyrebird-mic-check.sh --list-backups
sudo ./lyrebird-mic-check.sh --restore=20251111_123456
```

Options: `-g, --generate-config`, `-f, --force` (with `-g`: no prompt), `--no-backup`, `--quality=low|normal|high`, `-V, --validate`, `-q, --quiet`, `--format=text|json`, `--list-backups`, `--restore[=TIMESTAMP]`, `--version`, `-h, --help`. The optional timestamp must be attached with `=`.

**Quality tiers:** what each picks is in the table under [Audio Device Configuration](#audio-device-configuration).

**Features:**
- Non-invasive detection via `/proc/asound`; it needs ALSA's proc files, so it exits 1 on a machine without `/proc/asound` (even for `--help`)
- Device busy detection without opening hardware
- Automatic backup and restore of the device configuration
- JSON output support
- USB audio adapter chip detection with warnings
- Capability reporting (formats, sample rates, channels)
- Configuration validation against hardware capabilities

**Technical Approach:**
- Uses the ALSA proc filesystem (`/proc/asound`) for capability enumeration
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

**Purpose:** Read-only health checks with a PASS/WARN/FAIL summary. The checks, the exit codes and the monitor are described under [Diagnostics & Monitoring](#diagnostics--monitoring).

**Usage:**
```bash
sudo ./lyrebird-diagnostics.sh quick
sudo ./lyrebird-diagnostics.sh full
sudo ./lyrebird-diagnostics.sh debug
```

**Options:**
- `-c, --config <file>`: Use an alternate MediaMTX configuration file
- `--timeout <seconds>`: Set the operation timeout (default 30, 1 to 3600)
- `-d, --debug`: Verbose debug output
- `-q, --quiet`: Suppress non-error output
- `--no-color`: Disable color output
- `-v, --version`

**Exit Codes:** 0 passed, 1 warnings, 2 failures, 127 the script could not run.

**Settings it reads:** `MEDIAMTX_CONFIG_DIR`, `MEDIAMTX_BINARY`, `MEDIAMTX_PORT` (the RTSP port, default 8554; not `MEDIAMTX_RTSP_PORT`), `FFMPEG_LOG_DIR` (default `/var/log/lyrebird`), `DIAGNOSTIC_LOG_FILE`, `DIAGNOSTIC_TIMEOUT`, `NO_COLOR`. It supports systemd fully, and OpenRC and other init systems with limits.

---

### MediaMTX Installer (install_mediamtx.sh)

**Purpose:** Install, update and remove MediaMTX with checksum verification and rollback

**Usage:**
```bash
# Install latest version (writes the binary, the configuration and mediamtx.service)
sudo ./install_mediamtx.sh install

# Install specific version
sudo ./install_mediamtx.sh -V v1.21.3 install

# Update an existing installation (verified download, atomic replace, rollback)
sudo ./install_mediamtx.sh update

# Check status (as root it also names who runs MediaMTX)
./install_mediamtx.sh status

# Verify installation
sudo ./install_mediamtx.sh verify

# Uninstall
sudo ./install_mediamtx.sh uninstall
```

**Options:**
- `-V, --target-version <version>`: Install a specific MediaMTX version
- `-p, --prefix <dir>`: Installation prefix (default: /usr/local)
- `-c, --config <file>`: Load settings from a file
- `-f, --force`: Replace an existing installation, and a configuration file that is not LyreBirdAudio's (after a backup). Skips the checksum check only when the release has no checksum file; a mismatch is never accepted
- `-n, --dry-run`: Show what would be done without making changes
- `-q, --quiet`: Suppress non-error output
- `-v, --verbose`: Enable debug output
- `--no-service`: Skip systemd unit creation
- `--no-config`: Skip configuration file creation
- `--version`: Print the script version

**What it does:**
- Downloads the release tarball for this machine from GitHub and verifies it against the release's `checksums.sha256` (a mismatch is fatal)
- Installs the binary atomically; creates the service user `mediamtx`
- Writes `/etc/mediamtx/mediamtx.yml` with the same generator the stream manager uses: managed marker first line, API and metrics on `127.0.0.1`, every other protocol off ([Configuration ownership](#configuration-ownership)). A file that is not LyreBirdAudio's is left alone without `--force`
- Writes `/etc/systemd/system/mediamtx.service` rendered from `config/mediamtx.service`; it conflicts with `mediamtx-audio.service`. It does not enable or start it. `install` therefore needs `lyrebird-common.sh` and `config/` next to the script: run it from the checkout (`--no-config --no-service` needs neither)
- `update` downloads and verifies before it stops MediaMTX, stops it through its owner (systemd, the stream manager unit, or the stream manager), installs the new binary, starts it again and checks that it came up; if the new binary does not run or the service does not return, the previous binary is restored. MediaMTX's own `--upgrade` is not used, because it replaces the executable without a checksum check. A MediaMTX that nobody supervises (started by hand) is stopped and not started again; the command is printed and the exit status is 0. `update` does not rewrite the configuration or the unit, except that crossing MediaMTX 1.19 adds `moq: no` to a generated configuration
- `uninstall` stops MediaMTX the same way and removes the unit, the binary and its backups; it asks before it removes the configuration directory (which also holds `audio-devices.conf` and `rtsp-users.conf`), the state directory and the service user, or removes them without asking with `--force`
- Never selects a process by name: it signals only a process whose executable is the installed binary and whose first argument is the installed configuration, and never signals FFmpeg. If it cannot stop an active unit it stops with exit 7 instead
- Platform detection maps the machine to the release asset name ([System Requirements](#system-requirements)); only Linux is supported by the rest of the suite

**Exit Codes:** 0 success; 1 general error (unknown option or command, a write failed); 2 root required; 3 unsupported operating system or architecture; 4 a required command or `lyrebird-common.sh` is missing, or Bash older than 4; 5 download or release lookup failed; 6 checksum file missing (without `--force`) or checksum mismatch; 7 already installed, not installed, a step of the install or update failed, MediaMTX could not be stopped, or the update was rolled back; 8 the installation prefix cannot be created or written; 9 the configuration file given with `-c` is missing, or MediaMTX rejected the generated configuration; 10 an invalid port, path, account name, version or prefix.

---

### Webhook Alerts (lyrebird-alerts.sh)

**Purpose:** Webhook notifications from your own scripts (pure Bash, `curl` only). **Nothing else in the suite calls it**: the stream manager, the monitor, the storage script and the orchestrator send no alerts. You call `lyrebird-alerts.sh` or source it, for example from a cron job or from the exit-status handling in your own monitoring script.

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

`send` takes `--level info|warning|error|critical`, `--title`, `--message` and `--type` (the type is part of the duplicate key).

**Supported Webhook Types:**
- **Discord** - Discord channel webhooks
- **Slack** - Slack incoming webhooks
- **ntfy.sh** - Free, open-source notification service (`LYREBIRD_NTFY_TOPIC`, `LYREBIRD_NTFY_SERVER`)
- **Pushover** - Mobile push notifications (`LYREBIRD_PUSHOVER_TOKEN`, `LYREBIRD_PUSHOVER_USER`)
- **Generic** - Any HTTP POST endpoint

All deliveries were checked against a stand-in for `curl`; no real webhook endpoint was used.

**Configuration:** `/etc/lyrebird/alerts.conf` (`LYREBIRD_ALERT_CONFIG` names another)
```bash
LYREBIRD_ALERT_ENABLED=true
LYREBIRD_WEBHOOK_URL="https://your-webhook-url"
LYREBIRD_WEBHOOK_TYPE="discord"  # discord, slack, ntfy, pushover, generic
LYREBIRD_ALERT_RATE_LIMIT=300    # Seconds a destination is not sent the same alert again
LYREBIRD_HOSTNAME="field-unit-1"
LYREBIRD_LOCATION="North Forest"
```
Also read: `LYREBIRD_WEBHOOK_URLS` (more URLs, space separated), `LYREBIRD_ALERT_DEDUP_WINDOW` (3600: how long delivery state is kept; the larger of it and the rate limit applies), `LYREBIRD_ALERT_TIMEOUT` (30, limited to 5 to 120 s), `LYREBIRD_ALERT_RETRIES` (3), `LYREBIRD_ALERT_STATE_DIR` (`/var/lib/lyrebird/alerts`), `LYREBIRD_ALERT_LOG` (`/var/log/lyrebird/alerts.log`). Alerts are off until `LYREBIRD_ALERT_ENABLED=true`; while they are off, or no destination is configured, `send` returns 0 without sending anything.

**How repeats are handled (per destination):**
- An identical alert (same type and same message text) is not sent again to a destination that already confirmed it (HTTP 2xx) within `LYREBIRD_ALERT_RATE_LIMIT` seconds. A destination that failed has no record and is retried by the next identical alert; destinations that succeeded are not sent it again
- Identical alerts sent at the same moment are delivered once per destination: a destination is claimed with `flock` before the first request, and a second sender that finds it claimed skips it
- A message that differs ("87%" and "88%") is a different alert
- Without `flock` or a usable state directory, alerts are still sent, without duplicate protection, with a warning

**Exit status of `send` and of `send_alert`:** 0 delivered (every destination that needed the alert received it; also returned when alerts are disabled); 1 usage error; 3 total failure (no destination has it and at least one failed; nothing is recorded, the next identical alert retries); 4 suppressed (every destination already has it within the window, or another process is delivering it); 5 partial failure (some destinations have it, at least one failed; the failure is logged with the URL masked). `test` returns 0 or 1.

**Calling it from a script:**
```bash
#!/bin/bash
# Sourcing defines the functions. send_alert returns 3, 4 or 5 in the cases above, so a
# script running under "set -e" must not call it bare: use "|| rc=$?".
source /path/to/LyreBirdAudio/lyrebird-alerts.sh

overall="$(/path/to/LyreBirdAudio/lyrebird-stream-manager.sh status --json | jq -r .overall)"
if [[ "$overall" != "ok" ]]; then
    rc=0
    alert_stream_down "all streams" "The stream manager reports: ${overall}" || rc=$?
fi
```

Ready-made functions (they call `send_alert` with a level, a title and a type): `alert_stream_down` / `alert_stream_up`, `alert_device_disconnect` / `alert_device_connect`, `alert_disk_warning` / `alert_disk_critical`, `alert_mediamtx_down` / `alert_mediamtx_up`, `alert_network_down` / `alert_network_up`, `alert_memory_warning`, `alert_cpu_warning`.

---

### Prometheus Metrics (lyrebird-metrics.sh)

**Purpose:** Export node and stream metrics in the Prometheus text format

**Usage:**
```bash
# One document on stdout
./lyrebird-metrics.sh

# HTTP server for Prometheus to scrape (127.0.0.1:9100 by default)
./lyrebird-metrics.sh serve --port 9100

# The same on every interface (no authentication, no TLS: trusted networks only)
./lyrebird-metrics.sh serve --port 9100 --bind 0.0.0.0

# A file for node_exporter's textfile collector (replaced atomically)
./lyrebird-metrics.sh --file /var/lib/node_exporter/textfile_collector/lyrebird.prom
```

`--serve [PORT]` is the older spelling of `serve --port PORT`. There are no `--streams-only` or `--system-only` options. `--port` and `--bind` without `serve` are errors.

**Run it as root** (a cron job or a root unit) for a complete answer: an unprivileged exporter cannot look at root's processes closely enough, so what it cannot read is left out of the document, its collector is reported failed (`lyrebird_collector_success`), and the exit status is 3.

**Metrics** (every name starts with `lyrebird_`):

| Collector | Metrics |
|-----------|---------|
| (document) | `build_info{version}`, `scrape_timestamp_seconds`, `scrape_success` (1 only if every collector completed: alert on `== 0`), `collector_success{collector}` |
| `mediamtx` | `mediamtx_up`, `mediamtx_memory_bytes`, `mediamtx_cpu_percent`, `mediamtx_open_fds`, `mediamtx_uptime_seconds` (this installation's MediaMTX: the configured binary run on the configured configuration, not any process called "mediamtx") |
| `stream_manager` | `stream_manager_up` (whether the MediaMTX process the manager recorded in its PID file is running; the name is historical), `active_streams`, `configured_devices`, `heartbeat_age_seconds` (-1 when there is no file), `heartbeat_healthy` (1 if the monitor ran within `LYREBIRD_HEARTBEAT_MAX_AGE`, 900 s: it proves only that the monitor ran) |
| `usb_audio` | `usb_audio_devices`, `total_audio_cards` |
| `system` | `disk_usage_percent{mount}`, `system_memory_total_bytes`, `system_memory_available_bytes`, `system_load_1m`, `system_entropy_available` |
| `api` | `api_up`, `api_info{version}`, `api_uptime_seconds`, `api_paths_total`, `api_paths_ready`, `api_rtsp_sessions`, `api_rtsp_connections`, `api_rtsps_sessions`, `api_rtmp_connections`, `api_rtmps_connections`, `api_webrtc_sessions`, `api_srt_connections`, `api_hls_muxers`, `api_recordings_total`, `api_total_connections` |
| `streams` | `stream_up{stream}`, `stream_memory_bytes{stream}`, `stream_cpu_percent{stream}` |

A source that cannot be read leaves its metrics out (they are not published as 0) and makes its collector fail, so an alert on `lyrebird_mediamtx_up == 0` does not fire for an unreadable source; use `lyrebird_scrape_success == 0` for that. The HTTP server's `/metrics` is generated when the request arrives.

**Prometheus Configuration:**
```yaml
# prometheus.yml: Prometheus on the same machine
scrape_configs:
  - job_name: 'lyrebird'
    static_configs:
      - targets: ['localhost:9100']
    scrape_interval: 30s
```
For a Prometheus on another host, either start the server with `--bind <address of this machine>` (and firewall the port), or use `--file` with node_exporter's textfile collector, which needs no listening port.

**The HTTP server** answers `GET /` and `GET /metrics`; any other path gets 404 and any other method 405. It is made for a poller (Prometheus scrapes every few seconds): it serves one connection at a time, each from its own `nc`, so a client that connects while another is being served, or within a few milliseconds after it, can be reset and has to try again. It needs a netcat (OpenBSD `nc`, `ncat`, traditional/GNU `nc` or BusyBox `nc`; only OpenBSD `nc` was tested against real connections), `SIGTERM` or `SIGINT` stops it, and a port that is already in use ends it with exit 2 after five attempts. For several scrapers, or anything beyond loopback, prefer `--file`.

**Settings:** `LYREBIRD_API_TIMEOUT` (seconds all MediaMTX API requests of one scrape may take together; default 5; keep it below Prometheus's `scrape_timeout`), `LYREBIRD_HEARTBEAT_MAX_AGE` (900), `MEDIAMTX_BINARY`, `MEDIAMTX_CONFIG_FILE` (else `MEDIAMTX_CONFIG_DIR`/`mediamtx.yml`), `PID_FILE` (else `MEDIAMTX_PID_FILE`), `HEARTBEAT_FILE`, `FFMPEG_PID_DIR`. The exporter reads `FFMPEG_PID_DIR` while the stream manager's variable is `MEDIAMTX_FFMPEG_DIR`: if you moved that directory, set both, or the exporter finds no streams.

**Exit status:** 0 every collector completed (the server: stopped by a signal); 1 command-line error; 2 nothing could be delivered (`--file` could not publish, in which case the previous file is kept; or the server cannot run); 3 the output was delivered but at least one collector failed.

---

### Storage Management (lyrebird-storage.sh)

**Purpose:** Disk space and retention for long-term deployments

**Usage:**
```bash
# Check storage status
./lyrebird-storage.sh status

# Clean up old recordings and logs (retention policy); --dry-run only lists
sudo ./lyrebird-storage.sh cleanup
sudo ./lyrebird-storage.sh --dry-run cleanup

# Emergency cleanup (deletes the oldest recordings and rotated logs)
sudo ./lyrebird-storage.sh emergency

# One disk check, acting if a threshold is passed (run it from cron; it never loops)
sudo ./lyrebird-storage.sh monitor --once
```

`-q, --quiet` (for `cleanup` and `monitor`) prints only warnings, errors and one summary line per run, all to stderr. There is no `--interval` option and no way to make `monitor` loop: run it from cron or a timer. `monitor` prints nothing while the disk is fine.

**Configuration:** environment variables, or the file `/etc/lyrebird/storage.conf` (`LYREBIRD_STORAGE_CONFIG=FILE` names another; empty means none). The file is read as data, never run: `KEY=value` lines, `#` comments, values bare or in quotes and taken literally. An environment variable wins over the file, and the file over the default. The file is not read when anyone can write it or when it belongs to a user other than root or the one running the script. A line that is not accepted is reported and ignored and the run finishes with exit 4.

```bash
# /etc/lyrebird/storage.conf
RECORDING_RETENTION_DAYS=30      # Keep recordings for 30 days (default)
LOG_RETENTION_DAYS=7             # Keep logs for 7 days (default)
DISK_WARNING_PERCENT=80          # Warn at 80% usage (default)
DISK_CRITICAL_PERCENT=90         # Critical at 90% usage (default)
DISK_EMERGENCY_PERCENT=95        # Emergency at 95% usage (default)
MIN_FREE_SPACE_MB=500            # Emergency below this much free space (default)

# Directories to manage (absolute paths in the file); the defaults are shown
RECORDING_DIR="/var/lib/mediamtx-ffmpeg/recordings"
LOG_DIR="/var/log/lyrebird"
```

The keys are the names of the script's environment variables, with one difference: `RECORDING_DIR` and `LOG_DIR` are accepted **only in the file**, as other names for `LYREBIRD_RECORDING_DIR` and `LYREBIRD_LOG_DIR`. As environment variables use the `LYREBIRD_` names, together with `LYREBIRD_TEMP_DIR`, `LYREBIRD_BUFFER_DIR`, `MEDIAMTX_LOG`, `TEMP_RETENTION_HOURS`, `MAX_LOG_SIZE`, `LYREBIRD_CLOCK_SANE_EPOCH` and `LYREBIRD_ACTIVE_SEGMENT_SECONDS` (`--help` lists them). `lyrebird-storage.sh status` prints which file it read.

**What the stream manager's recording means for it:** with `AUDIO_LOCAL_RECORDING=true` the manager writes a ring of 12 segments per stream to `AUDIO_RECORDING_PATH` (default `/dev/shm/lyrebird-buffer`, RAM) and FFmpeg overwrites them in place, so that directory never holds more than the last hour per stream and the retention days do not govern it. The storage script never reads `AUDIO_RECORDING_PATH`: retention works on `LYREBIRD_RECORDING_DIR`, and the emergency clearing of the ring on `LYREBIRD_BUFFER_DIR` (which must resolve under `/dev/shm`, `/tmp`, `/var/tmp` or `/run`). If you move `AUDIO_RECORDING_PATH`, set the matching storage variable.

**Features:**
- Recordings are files ending in `opus ogg aac adts m4a mp3 flac wav`; nothing else in those directories is touched
- Retention by age for recordings, logs and temporary files; empty segments left by a killed FFmpeg are removed
- `monitor` checks the filesystem mounted at `/` (blocks, inodes and free space): above `DISK_WARNING_PERCENT` it removes temporary files and truncates very large logs, above `DISK_CRITICAL_PERCENT` it runs the standard cleanup, and above `DISK_EMERGENCY_PERCENT`, or below `MIN_FREE_SPACE_MB`, the emergency cleanup. A recording volume mounted elsewhere is not watched
- Emergency cleanup deletes up to 100 empty segments, then up to 100 of the oldest non-empty recordings, per run, never a file written within `LYREBIRD_ACTIVE_SEGMENT_SECONDS` (900); then rotated logs and temporary files
- Broken-clock protection: a Pi without a battery-backed clock boots thinking it is 1970. Recordings with a modification time before `LYREBIRD_CLOCK_SANE_EPOCH` (2025-01-01) are never deleted as too old, and age-based cleanup waits until the clock is sane
- `--dry-run` lists what would be removed and changes nothing
- It has no connection to `lyrebird-alerts.sh`: nothing is sent when a threshold is passed

**Exit status:** 0 success; 1 usage error; 3 finished, but a deletion failed or a directory could not be listed; 4 finished, but lines of the configuration file were ignored.

**Automated cleanup via cron** (`/etc/cron.d/lyrebird-storage`; the output of a run is its log, so send it to a file outside `LYREBIRD_LOG_DIR`):
```bash
0 3 * * * root /path/to/lyrebird-storage.sh cleanup --quiet >>/var/log/lyrebird-storage.log 2>&1
*/15 * * * * root /path/to/lyrebird-storage.sh monitor --once >>/var/log/lyrebird-storage.log 2>&1
```

---

## Advanced Topics

### Custom Integration

**Reading the node's state from a script:**
```bash
#!/bin/bash
# overall is one of: ok, degraded, failed, waiting_for_devices, stopped
overall="$(./lyrebird-stream-manager.sh status --json | jq -r .overall)"
echo "Node state: ${overall}"

# Every stream that is not publishing, with the reason
./lyrebird-stream-manager.sh status --json | jq -r '.streams[] | select(.path_ready != true) | "\(.path): \(.last_error)"'
```
A `status` run takes `LYREBIRD_FLOW_SAMPLE_SECONDS` (3) seconds longer when a stream is ready; set it to 0 to skip the byte-flow sample (`bytes_flowing` is then `null`). Restarting failed streams is the monitor's job ([The Monitor](#the-monitor)); do not add a second restart loop next to it. To be told when something is wrong, send an alert from your script ([Webhook Alerts](#webhook-alerts-lyrebird-alertssh)).

**API Integration** (from the machine itself: the API listens on `127.0.0.1`):
```bash
# Paths MediaMTX knows
curl -s http://127.0.0.1:9997/v3/paths/list | jq .

# One stream. While nobody publishes it, MediaMTX answers 404 {"status":"error","error":"path not found"}
curl -s http://127.0.0.1:9997/v3/paths/get/mic-left | jq .
```
Use `MEDIAMTX_API_PORT` if you changed the port. The field names in the answers differ between MediaMTX versions (`ready` and `available`; `bytesReceived` and `inboundBytes`). The control API can also change configuration (see MediaMTX's own documentation), but changing paths behind the stream manager's back is not supported: the manager rewrites a generated configuration.

### Custom Audio Configuration

Edit the device configuration:
```bash
sudo nano /etc/mediamtx/audio-devices.conf
./lyrebird-stream-manager.sh validate
```

Format: `DEVICE_<NAME>_<SETTING>=value` ([Audio Device Configuration](#audio-device-configuration)); device-specific settings override the defaults.

After editing, restart so the streams pick the settings up (`reload` does not apply them):
```bash
sudo ./lyrebird-stream-manager.sh restart      # or: sudo systemctl restart mediamtx-audio
```

### MediaMTX Configuration

A generated file (first line `# Managed by LyreBirdAudio`) is rewritten whenever the manager's rendering changes, so an edit you want to keep needs the first line deleted first ([Configuration ownership](#configuration-ownership)). MediaMTX applies a changed file by itself, and a file it cannot load makes the running MediaMTX log the error and exit, so check an edit before it goes live:

```bash
sudo cp /etc/mediamtx/mediamtx.yml /root/mediamtx.yml.new
sudo nano /root/mediamtx.yml.new                      # delete the first line to keep your edits
# MediaMTX 1.21.1 and later; older versions have no such flag
/usr/local/bin/mediamtx --validate-conf=/root/mediamtx.yml.new && sudo cp /root/mediamtx.yml.new /etc/mediamtx/mediamtx.yml
```

For a generated file, `sudo ./lyrebird-stream-manager.sh reload` applies a change to the settings the manager owns (ports, bind addresses, `RTSP_AUTH_MODE`) without restarting the streams; see [Reload](#reload) for which changes disconnect publishers.

### Backup and Restore

```bash
# Backup configuration
sudo tar -czf lyrebird-backup-$(date +%Y%m%d).tar.gz \
  /etc/mediamtx/ \
  /etc/lyrebird/ \
  /etc/udev/rules.d/99-usb-soundcards.rules \
  /etc/systemd/system/mediamtx-audio.service \
  /etc/cron.d/mediamtx-monitor

# Restore from backup (use the file name of your backup)
sudo tar -xzf lyrebird-backup-20250101.tar.gz -C /
sudo udevadm control --reload-rules
sudo udevadm trigger
sudo systemctl daemon-reload
sudo systemctl restart mediamtx-audio
```

`/etc/lyrebird/` may not exist on your node (it holds the optional alerts and storage configuration); remove it from the list if `tar` complains. Add `/etc/systemd/system/mediamtx.service` on a standalone installation. Recordings are not part of this backup.

### Debug Mode

Enable debug output for the scripts that support it:
```bash
export DEBUG=true      # "1" does not enable it

# Now run any command
./lyrebird-stream-manager.sh status
sudo ./usb-audio-mapper.sh --debug --test    # the mapper has its own option
```
In the stream manager `DEBUG=true` also prints a trace of every command; its `-d` option prints the debug messages only.

---

## Security Hardening

[docs/SECURITY-GUIDE.md](docs/SECURITY-GUIDE.md) has the full guide (authentication options with MediaMTX's own settings, which listeners exist, firewall examples). This section is the short version, and it states the defaults first.

### Default Security Posture

**Who can do what, out of the box:**

| | Default |
|---|---|
| RTSP (TCP 8554, UDP 8000 and 8001) | Listens on **every interface**. **Anyone who can reach it can read any stream and publish to any path, with no password.** `RTSP_AUTH_MODE=local-only-publish` changes that (below) |
| MediaMTX control API (9997) and metrics (9998) | Listen on `127.0.0.1` only (`MEDIAMTX_API_BIND`, `MEDIAMTX_METRICS_BIND`) |
| SRT, RTMP, HLS, WebRTC, MoQ | Off in every generated configuration |
| `lyrebird-metrics.sh serve` | `127.0.0.1`; `--bind` changes it; no authentication or TLS |
| RTSP traffic | Not encrypted |

The generated configuration is only as strict as these defaults. A configuration file that is not generated (an operator's file, or one written by an earlier installer) keeps whatever it says: check it ([Upgrading an Existing Node](#upgrading-an-existing-node), step 6).

**What the code does for safety:**
- **No hard-coded credentials.** Authentication is MediaMTX's own; the suite adds one helper (`RTSP_AUTH_MODE`) that writes MediaMTX's internal-user settings for you.
- **Device configuration, `storage.conf` and `alerts.conf` are read as data, never run as shell.** Wrapper scripts are generated with every value quoted and syntax-checked before they are used; stream names are reduced to `a-z 0-9 _ -` and quoted in the YAML; the unit and cron file generators refuse paths and names they cannot carry safely.
- **Processes are identified by executable, arguments and start time**, and only processes the manager started are signalled (the one broad kill, `force-stop --kill-all --yes`, shows its list first).
- **Downloads are verified.** `install_mediamtx.sh` checks the SHA256 checksum published with the release; a mismatch is fatal. `tests/fetch_mediamtx.sh` and the CI tools are pinned to checksums.
- **Atomic writes.** Configuration, unit and state files are replaced by write, `fsync`, rename.
- **systemd sandboxing**, with different users: the standalone `mediamtx.service` runs as the unprivileged `mediamtx` user the installer creates (`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, a memory limit). `mediamtx-audio.service` runs **as root** (the manager signals its processes and opens `/dev/snd`) with `NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp` and other directives; FFmpeg therefore also runs as root there.

**What it does not restrict:** `mediamtx.yml` is mode 0644 (0640 when it carries password hashes), `audio-devices.conf`, the manager log and `status.json` are 0644: any local user can read them. Webhook URLs in `/etc/lyrebird/alerts.conf` are secrets; keep that file readable by root only.

### Network Security

For production deployments in sensitive environments:

**1. Require authentication for RTSP.** `RTSP_AUTH_MODE=local-only-publish` makes this machine (loopback) the only place that needs no password; every other client must be a user from `/etc/mediamtx/rtsp-users.conf`, with read-only access:

```bash
# One line per user: user:sha256:<base64 of the raw SHA-256 digest of the password>
printf '%s:sha256:%s\n' viewer "$(printf '%s' 'the password' | openssl dgst -sha256 -binary | base64)" \
  | sudo tee /etc/mediamtx/rtsp-users.conf >/dev/null
# keep the file readable by root only: it holds password hashes
```
Then give the setting to the service and to the monitor ([Environment Variables](#environment-variables)): `RTSP_AUTH_MODE=local-only-publish` in a `systemctl edit mediamtx-audio` drop-in and as a line in `/etc/cron.d/mediamtx-monitor`, and restart the service. What to know:
- A user name is `A-Za-z0-9._@-` up to 64 characters; `any` is reserved. A plaintext password, a bad hash or a duplicate stops `start` without echoing the line. A missing users file is a warning and leaves only this machine with access.
- Publishers must connect from loopback, so `MEDIAMTX_HOST` must be `localhost`, `127.x` or `::1`; otherwise the manager warns that MediaMTX will refuse them.
- It applies to a generated file only. For a file of your own, write MediaMTX's `authInternalUsers` yourself and **keep a password-less user restricted to `127.0.0.1` and `::1`** with publish, read, API and metrics permissions: the manager's own publishers and probes connect without credentials, and a configuration without that user stops them. [docs/SECURITY-GUIDE.md](docs/SECURITY-GUIDE.md) shows a verified example.
- Verified against MediaMTX 1.15.0, 1.18.0, 1.19.0, 1.21.1, 1.21.2 and 1.21.3 on this machine's own non-loopback address; a client on a second host was not tested.
- The stream manager's silence check (`AUDIO_LEVEL_CHECK_ENABLED`) reads each stream without credentials, so with read authentication on a path it logs a probe error on every run; there is no credential setting for it.

**2. Firewall Configuration** (the API and the metrics endpoint are on loopback: do not open 9997 or 9998). The `ufw` lines are examples; they were not run here:
```bash
# Allow only your network to reach the streams
sudo ufw allow from 192.168.1.0/24 to any port 8554 proto tcp
sudo ufw allow from 192.168.1.0/24 to any port 8000:8001 proto udp   # only for clients that use UDP
sudo ufw deny 8554/tcp
```

**3. Bind RTSP to one interface.** The generator has no setting for the RTSP address, so this needs a configuration file of your own: delete the first line of `/etc/mediamtx/mediamtx.yml` ([Configuration ownership](#configuration-ownership)) and set
```yaml
rtspAddress: 192.168.1.100:8554   # instead of :8554 (every interface)
```
Check the file with `mediamtx --validate-conf` (1.21.1 and later) before MediaMTX reads it. The manager's own publishers use `MEDIAMTX_HOST` (`localhost` by default), so they must still be able to reach that address: bind to one address and set `MEDIAMTX_HOST` to it for the service and the cron job.

### Library Integrity Verification

For high-security deployments the stream manager can refuse to run if `lyrebird-common.sh` has changed (the other scripts do not check it):

```bash
# Generate the hash of lyrebird-common.sh
sha256sum lyrebird-common.sh | cut -d' ' -f1

# Give it to the stream manager's environment, for example in the unit
# (sudo systemctl edit mediamtx-audio):  Environment="LYREBIRD_COMMON_EXPECTED_HASH=<hash>"
# and as a line in /etc/cron.d/mediamtx-monitor. After every update the hash changes.
# Try it by hand: a wrong hash stops the manager with exit 1 and an integrity error
sudo env LYREBIRD_COMMON_EXPECTED_HASH=<hash> ./lyrebird-stream-manager.sh status
```
It guards one file, not the manager script itself.

### Recommendations for Field Deployments

1. **Use a VPN**: connect remote devices through a VPN rather than exposing RTSP directly
2. **Keep the API on loopback.** Do not disable it: the stream manager reads stream state from it, and `start` waits for it
3. **Audit logs regularly**: `/var/log/lyrebird-stream-manager.log` records starts, restarts and refusals
4. **Keep updated**: see [Version Management](#version-management)
5. **Physical security**: secure physical access to prevent USB device tampering

---

## Recovery Procedures

### Stream Not Starting

**Quick Recovery:**
```bash
# What the manager sees, and why each stream that is not publishing is not
sudo ./lyrebird-stream-manager.sh status

# Restart everything
sudo ./lyrebird-stream-manager.sh restart

# If that fails: stop the processes this manager started, then start cleanly
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
# 1. Stop everything the manager owns
sudo systemctl stop mediamtx-audio 2>/dev/null || true
sudo ./lyrebird-stream-manager.sh force-stop

# 2. If processes of this installation are still running, see what would be killed
sudo ./lyrebird-stream-manager.sh force-stop --kill-all
#    read the list; only if it is what you want:
#    sudo ./lyrebird-stream-manager.sh force-stop --kill-all --yes

# 3. Verify the MediaMTX installation
sudo ./install_mediamtx.sh verify
# If it is damaged: sudo ./install_mediamtx.sh -V v1.21.3 --force install

# 4. Verify device mapping
./usb-audio-mapper.sh --list

# 5. Run full diagnostics
sudo ./lyrebird-diagnostics.sh full

# 6. Fresh start
sudo ./lyrebird-stream-manager.sh start      # or: sudo systemctl start mediamtx-audio
```

**Which stop to use**

- **`stop`** (or `systemctl stop mediamtx-audio`): the normal way. SIGTERM first, SIGKILL after a timeout, only for processes this manager started.
- **`force-stop`**: SIGKILL at once to those same processes, and removes the PID files, the generated wrapper scripts and the markers. Use it when `stop` hangs or reports that it could not stop something.
- **`force-stop --kill-all`**: the one broad kill. Use it only when something of this installation is left that the manager has no record of, for example a MediaMTX it refuses to take over (exit 8, "was not started by this script"), or an FFmpeg left by a wrapper that died. Without `--yes` it prints every process it would signal and why, and signals nothing. With `--yes` it sends SIGKILL to exactly that list. It matches by executable and by files in the wrapper directory, never by name, so another installation's MediaMTX or an unrelated FFmpeg is not on the list; but a MediaMTX that is `mediamtx.service`'s (same binary) is, so stop that unit with `systemctl` first.

Do not delete `/run/mediamtx-audio.lock` or the PID files by hand: the lock is a kernel `flock` that the kernel releases when its holder dies, so there is never a stale lock to remove, and deleting the file out from under a running process gives the next process a different lock; `force-stop` removes the PID files properly. If `start`, `stop` or `restart` exit 5 ("Failed to acquire lock"), the message names the process holding it: wait for it or stop it.

### Rollback After Failed Update

```bash
# What was installed, and any update that did not finish
./lyrebird-updater.sh --history

# Back to the version before the last update
./lyrebird-updater.sh --rollback

# Or to a release tag or commit that is already in the clone
./lyrebird-updater.sh --rollback v1.3.0
```

`--history` lists past updates, rollbacks and resets; it does not list available versions (that is `--list`, which needs the network). `--rollback` needs no network when the version is already in the clone. `v1.3.0` is the newest tag but predates the fixes this README describes ([Version Management](#version-management)); prefer `--rollback` without an argument.

### Emergency Field Recovery (No Internet)

If you are in the field without internet access:

1. **Use local backups.** Keep a USB drive with a copy of `/etc/mediamtx/`, `/etc/lyrebird/` and the udev rules file.
2. **Backups the software makes itself:**
   - `/etc/mediamtx/mediamtx.yml.<UTC time>.<nn>.bak`: the stream manager saves the old file whenever it replaces a generated one (the newest `MEDIAMTX_CONFIG_BACKUPS`, default 5)
   - `/etc/mediamtx/audio-devices.conf.backup.<YYYYmmdd_HHMMSS>`: `lyrebird-mic-check.sh -g` saves the old file first; `--list-backups` lists them, `--restore=<timestamp>` restores one
   - `mediamtx.yml.backup.<time>` and `mediamtx.service.backup.<time>`, written by `install_mediamtx.sh` next to what it replaced; `/usr/local/bin/mediamtx.backup.<time>` (the last three) before an update
3. **Restore a MediaMTX configuration:** `sudo cp /etc/mediamtx/mediamtx.yml.<time>.<nn>.bak /etc/mediamtx/mediamtx.yml`. A restored copy of a generated file still carries the managed marker, so the manager rewrites it again when its rendering differs; delete the first line if the restored file must stay as it is.
4. **Restart the service:** `sudo systemctl restart mediamtx-audio`
5. **Go back to a previous version:** `./lyrebird-updater.sh --rollback` and `--history` need no network. `install_mediamtx.sh update` does.

---

## Uninstallation & Cleanup

### Complete Removal

To completely remove LyreBirdAudio and all components:

**1. Stop all streams and services:**
```bash
# Streams started by hand
sudo ./lyrebird-stream-manager.sh stop

# The stream manager unit, if you installed it
sudo systemctl disable --now mediamtx-audio

# The standalone MediaMTX unit, if you use it
sudo systemctl disable --now mediamtx
```

**2. Uninstall MediaMTX:**
```bash
sudo ./install_mediamtx.sh uninstall

# This stops MediaMTX through its owner (systemd or the stream manager) and removes:
# - /usr/local/bin/mediamtx and its backups
# - /etc/systemd/system/mediamtx.service
# It asks before removing (--force removes without asking):
# - /etc/mediamtx/ (all of it: mediamtx.yml, audio-devices.conf, rtsp-users.conf, backups)
# - /var/lib/mediamtx/
# - the mediamtx user
```

**3. Remove the stream manager unit and the monitor cron job:**
```bash
sudo rm -f /etc/systemd/system/mediamtx-audio.service
sudo rm -rf /etc/systemd/system/mediamtx-audio.service.d    # only if you made a drop-in
sudo systemctl daemon-reload
sudo rm -f /etc/cron.d/mediamtx-monitor
```

**4. Remove USB device mappings:**
```bash
# One mapping at a time
sudo ./usb-audio-mapper.sh --list
sudo ./usb-audio-mapper.sh --remove NAME

# Or remove the whole rules file and reload udev
sudo rm -f /etc/udev/rules.d/99-usb-soundcards.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

**5. Remove configuration files:**
```bash
# MediaMTX configuration (step 2 asked about this already)
sudo rm -rf /etc/mediamtx/

# Optional alerts and storage configuration
sudo rm -rf /etc/lyrebird/
```

**6. Remove state files:**
```bash
# Per-stream wrapper scripts, PID files and FFmpeg logs
sudo rm -rf /var/lib/mediamtx-ffmpeg/

# MediaMTX state, alert state and updater migration markers
sudo rm -rf /var/lib/mediamtx/ /var/lib/lyrebird/
```
Everything under `/run` (`/run/mediamtx-*`, `/run/lyrebird/`) is in memory and disappears at the next reboot. Do not delete the lock files in it while anything that uses them is still running.

**7. Remove log files:**
```bash
sudo rm -f /var/log/mediamtx.out* /var/log/lyrebird-stream-manager.log* \
  /var/log/lyrebird-orchestrator.log* /var/log/lyrebird-diagnostics.log*
sudo rm -rf /var/log/lyrebird/

# Remove logrotate configuration
sudo rm -f /etc/logrotate.d/mediamtx /etc/logrotate.d/lyrebird
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
sudo rm -f /var/log/lyrebird-stream-manager.log
```

**Remove only device mappings:**
```bash
# Remove udev rules only
sudo rm -f /etc/udev/rules.d/99-usb-soundcards.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

**Reset audio configuration only:**
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
# Stop through their owners
sudo systemctl stop mediamtx mediamtx-audio
sudo ./lyrebird-stream-manager.sh force-stop

# Still running? See what the emergency kill would take (it signals nothing without --yes)
sudo ./lyrebird-stream-manager.sh force-stop --kill-all

# A MediaMTX or FFmpeg that is not on that list is not from this installation:
# find it, then signal that one process id, not every process with the name
ps -o pid,args -C mediamtx
sudo kill <pid>
```
Killing by name (`pkill`, `killall`) is not a recovery step: it stops every MediaMTX and every FFmpeg on the host, including other installations' and other programs'. `force-stop --kill-all --yes` is the identity-based broad kill ([Recovery Procedures](#complete-system-recovery)).

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

- Keep to the Bash versions in [System Requirements](#system-requirements): the suite runs on 5.2 only, so a newer feature fails for users on older Bash without any test noticing
- Pass `shellcheck` (CI uses 0.11.0, `--severity=warning`) with minimal suppressions, each with a reason
- Use `set -euo pipefail` for strict error handling
- Document complex logic with comments
- Implement proper signal handlers
- Validate all user inputs
- Use absolute paths for system commands
- Never identify or signal a process by name; use the identity helpers the stream manager and installer use (executable, argument, start time)
- Read configuration files as data; never `source` a file an operator or another program can write

### Testing

The tests are [bats](https://github.com/bats-core/bats-core) files in `tests/`. At the time of this README, `tests/` held **1732 tests in 85 files**, not counting the documentation checks in `tests/test_docs_*.bats` (`bats --count tests/` gives the current number including them). They run the real scripts: against fake `/proc/asound`, `/dev/snd` and sysfs trees, stand-ins for `systemctl`, `curl` and `arecord`, real `git` repositories with injected failures, real FFmpeg, and, in the live tests, real MediaMTX binaries.

```bash
bats tests/                                      # everything that does not need the live setup
tests/check_tmp_leaks.sh                         # the same, and fails if the run leaves temporary files behind
LYREBIRD_LEAK_CHECK_HOST=1 tests/check_tmp_leaks.sh   # also fails if the run changes host state (what CI's bats job does)
```

**Live tests.** The files that start real MediaMTX binaries are skipped unless `LYREBIRD_TEST_MEDIAMTX_BINS` names them:
```bash
LYREBIRD_TEST_MEDIAMTX_BINS="$(tests/fetch_mediamtx.sh)" bats tests/test_mediamtx_live.bats tests/test_soak_live.bats \
    tests/test_soak_observer.bats tests/test_mediamtx_config_live.bats tests/test_mediamtx_api_live.bats \
    tests/test_mediamtx_e2e_ports.bats tests/test_install_mediamtx_live.bats
```
`tests/fetch_mediamtx.sh` downloads MediaMTX 1.15.0, 1.18.0, 1.19.0, 1.21.1, 1.21.2 and 1.21.3 for linux/amd64 and checks each against a pinned SHA-256; with `latest` it fetches the newest upstream release and verifies it against the checksum file published with that release. The live tests need `ffmpeg`, `curl`, `jq`, `openssl` and `python3`. Some also need root or passwordless `sudo` for `unshare --net --pid --fork --mount-proc` and overlay mounts, and skip with a message without them. The two soak live files need the default ports 8554 and 9997 free and refuse to run while another MediaMTX or RTSP FFmpeg is running; the other live files take free ports (`LYREBIRD_TEST_PORT_BASE=N` pins them to `N`..`N+12`).

**The host-state check.** `LYREBIRD_LEAK_CHECK_HOST=1` makes `tests/check_tmp_leaks.sh` record the LyreBird paths of the machine (`/var/log/lyrebird*`, `/var/log/mediamtx*`, `/var/lib/lyrebird`, `/var/lib/mediamtx-ffmpeg`, `/run/lyrebird*`, `/run/mediamtx*`, `/etc/lyrebird`, `/etc/mediamtx`, `/etc/cron.d/mediamtx*`, `/etc/systemd/system/mediamtx*`, `/etc/logrotate.d/*`, `/dev/shm/lyrebird*`, the repository working tree) before and after the run and fail with a diff if anything changed. It cannot tell the suite's writes from anyone else's, so use it on CI and disposable machines; it refuses to run (exit 2) where a LyreBird unit is active or the monitor cron job is installed. Any value other than unset, `0` or `1` is refused.

**What the suite cannot prove:**
- Real USB hardware: capture PCM layouts, hot-plug timing, a second open of a busy capture device, USB clock drift between microphones
- A real systemd manager: boot ordering, `Conflicts=`, the start limit with a late USB hub, `StateDirectory=`, the sandbox directives (units are only checked with `systemd-analyze verify`)
- Power cuts: the order of the durable-write steps is tested, not whether a medium honours them
- Hardware watchdog drivers
- RTSP from a separate host, IPv6, real webhook endpoints, FFmpeg 4.x at run time
- ARM and ARMv6, Bash older than 5.2, macOS and BSD
- Whether GitHub accepts and runs the workflow files as written; release signing and branch protection settings

To find a node's own limits, soak-test it on the same hardware for weeks with faults injected: see [tools/soak/README.md](tools/soak/README.md).

**CI.** `.github/workflows/bash-ci.yml` runs on every pull request to `main` or `master`, on every push to them, weekly, and on demand, with no path filter: `bash -n`, ShellCheck, shfmt (`-d -i 4 -bn -ci`), bashate (`--ignore E001,E006,E040,E042,E043`), actionlint, a heuristic security scan (it only warns), the bats suite with the host-state check, and one live job per pinned MediaMTX version. The job `CI Summary` fails unless every one of those succeeded, so it is the one check to require. An advisory canary runs the live tests against the newest upstream MediaMTX. Downloaded tools are checked against pinned hashes and every action is pinned to a commit SHA. The workflow files were checked statically and their steps run locally; whether the repository requires `CI Summary` is a repository setting this README cannot show.

**Validation checklist for a change:**
- [ ] `bash -n script.sh` (syntax check)
- [ ] `shellcheck --severity=warning script.sh` (linting)
- [ ] `shfmt -d -i 4 -bn -ci script.sh` and `bashate --ignore E001,E006,E040,E042,E043 script.sh`
- [ ] `LYREBIRD_LEAK_CHECK_HOST=1 tests/check_tmp_leaks.sh` (the suite, no leaked temp files, no host changes)
- [ ] `LYREBIRD_TEST_MEDIAMTX_BINS="$(tests/fetch_mediamtx.sh)" bats tests/test_mediamtx_live.bats ...` when you touched anything MediaMTX-facing (real MediaMTX)
- [ ] Backward compatibility maintained, and upgrade from the previous release tried ([Upgrading an Existing Node](#upgrading-an-existing-node))
- [ ] Documentation updated, exit codes documented
- [ ] A test that fails without your change (revert the fix, watch the test fail, restore it)

### Development Setup

```bash
# Enable debug mode
export DEBUG=true

# Run shellcheck on all scripts
for script in *.sh; do
    echo "Checking $script..."
    shellcheck --severity=warning "$script"
done

# Test syntax
for script in *.sh; do
    bash -n "$script" || echo "$script has syntax errors"
done

# Make scripts executable
chmod +x *.sh
```

### Code Style Guidelines

- Use 4 spaces for indentation (no tabs); `shfmt -i 4 -bn -ci` decides formatting
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
   - All scripts must pass `bash -n`, ShellCheck, `shfmt` and `bashate` (CI blocks on all four)
   - Use comprehensive error handling
   - Add debug output for troubleshooting
   - Update relevant documentation
   - Follow the single-responsibility principle
   - Maintain backwards compatibility where possible

4. **Test**
   - Run the suite (above) and add a test for what you changed
   - Say which platforms you tried it on: the suite itself covers Linux x86_64 and Bash 5.2 only
   - Test with real USB devices where the change touches them

5. **Submit a pull request**
   - Provide clear description of changes
   - Reference any related issues
   - Include test results
   - Update documentation as needed

### Submitting Issues

Include:
1. System info (`cat /etc/os-release`, `uname -a`)
2. Script versions (from the orchestrator menu, or `grep -m1 VERSION= <script>`)
3. Diagnostics output (`./lyrebird-diagnostics.sh full`) and `./lyrebird-stream-manager.sh status --json`
4. Relevant logs (last 50 lines showing the error)
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

This project was inspired by [cberge908's gist](https://gist.github.com/cberge908/ab7ddc1ac46fd63bb6935cd1f4341112) which provided the foundational concept for USB audio device streaming with MediaMTX. LyreBirdAudio extends this concept with error handling, persistent device naming and monitoring for unattended use.

**Author:** Tom F (tomtom215)  
**GitHub:** https://github.com/tomtom215/LyreBirdAudio

**Acknowledgments:** Inspired by cberge908's original MediaMTX launcher script. The codebase has been rewritten since, but the original concept provided the foundation.

### Dependencies

- **[MediaMTX](https://github.com/bluenviron/mediamtx)** - Real-time media server by bluenviron
- **[FFmpeg](https://ffmpeg.org/)** - Multimedia framework
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

*LyreBirdAudio - RTSP audio streaming for USB microphones*

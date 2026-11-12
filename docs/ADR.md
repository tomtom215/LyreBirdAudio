# Architecture Decision Records (ADR)

This document records significant architectural decisions made during the development of LyreBirdAudio.

## ADR-001: Bash as Primary Implementation Language

**Date**: April 2025
**Status**: Accepted
**Note (2026-11)**: Most scripts refuse to start on a Bash older than 4.0, the soak harness on one older than 4.2, and the diagnostics report one older than 4.4 as a failure. `lyrebird-mic-check.sh` uses `${array[-1]}`, which needs Bash 4.3. Only Bash 5.2 has been run by the test suite and CI, so nothing proves the older range.

### Context
We needed to choose an implementation language for LyreBirdAudio's automation and management scripts.

### Decision
Use Bash (4.0+) as the primary implementation language for all scripts.

### Rationale
- **Universal Availability**: Bash is pre-installed on virtually all Linux distributions
- **No Dependencies**: No additional runtime or package installation required
- **System Integration**: Native access to system commands, process management, and file operations
- **Sysadmin Familiarity**: Target users are comfortable reading and modifying Bash scripts
- **Transparency**: Easy to audit and understand what the scripts do

### Consequences
- Limited to Linux/Unix systems (acceptable for target use case)
- More verbose than Python for complex logic
- Requires careful handling of edge cases (quoting, spaces in paths)
- Must enforce `set -euo pipefail` for safety

---

## ADR-002: MediaMTX as RTSP Server

**Date**: April 2025
**Status**: Accepted
**Note (2026-11)**: MediaMTX can serve other protocols; the configurations LyreBirdAudio generates enable RTSP only (ADR-015).

### Context
We needed an RTSP server that could handle audio streams from USB microphones.

### Decision
Use MediaMTX (formerly rtsp-simple-server) as the RTSP streaming server.

### Rationale
- **Single Binary**: No complex installation or dependencies
- **Low Resource Usage**: Suitable for Raspberry Pi and similar devices
- **REST API**: Enables programmatic stream management
- **Active Development**: Regular updates and security patches
- **Multi-Protocol**: Supports RTSP, RTMP, HLS, WebRTC

### Consequences
- Dependency on external project's release schedule
- Must handle API version changes
- Need to implement download verification (SHA256)

---

## ADR-003: FFmpeg for Audio Transcoding

**Date**: April 2025
**Status**: Accepted

### Context
Need to capture audio from ALSA devices and stream to MediaMTX.

### Decision
Use FFmpeg as the audio capture and transcoding pipeline.

### Rationale
- **ALSA Support**: Native Linux audio device support
- **Codec Flexibility**: Supports all common audio codecs
- **Stability**: Battle-tested in production environments
- **Configurability**: Extensive options for quality tuning

### Consequences
- FFmpeg must be installed (usually available in package managers)
- FFmpeg process management complexity
- Need to handle FFmpeg crashes and restarts

---

## ADR-004: Shared Library Pattern (lyrebird-common.sh)

**Date**: April 2025
**Status**: Accepted

### Context
Multiple scripts needed common functionality (logging, colors, error handling).

### Decision
Create a shared library (`lyrebird-common.sh`) that scripts can source.

### Rationale
- **DRY Principle**: Avoid duplicating utility functions
- **Consistency**: Uniform logging format and error handling
- **Backward Compatibility**: Scripts can define functions before sourcing (override pattern)
- **Optional**: Scripts work without the library (fallback definitions)

### Consequences
- Must maintain backward compatibility
- Order of sourcing matters
- Need to guard against multiple inclusion

---

## ADR-005: Atomic File Operations

**Date**: April 2025
**Status**: Accepted; superseded in part by ADR-017 (the rename alone does not survive a power cut)

### Context
Scripts modify configuration files and state files that could be read by other processes.

### Decision
Use atomic file operations: write to `.tmp` file, then `mv` to final location.

### Rationale
- **No Partial Reads**: Readers never see half-written files
- **Crash Safety**: Original file preserved if write fails
- **POSIX Guarantee**: `mv` on same filesystem is atomic

### Consequences
- Slightly more complex code
- Need to clean up stale `.tmp` files
- Requires write access to target directory

---

## ADR-006: USB Device Persistence via udev

**Date**: April 2025
**Status**: Accepted
**Note (2026-11)**: Since usb-audio-mapper 4.0.0 the rule matches the sound card's own `ID_PATH` (it holds no USB bus number, which changes between boots), and the name is applied and verified at once, so no reboot is needed.

### Context
USB audio devices have non-deterministic device names (`/dev/snd/...`) that change on reboot.

### Decision
Use udev rules to create persistent symlinks based on USB topology (bus/port path).

### Rationale
- **Kernel Integration**: udev is the standard Linux device manager
- **Persistence**: Symlinks survive reboots and device reconnection
- **No Daemon**: Rules are processed by udev automatically

### Consequences
- Requires root to install udev rules
- May need reboot for rules to take effect
- USB hub changes require remapping

---

## ADR-007: Webhook-Based Alerting

**Date**: April 2025
**Status**: Accepted

### Context
Need to notify users of stream failures and system issues.

### Decision
Implement webhook-based alerting with support for Discord, Slack, Pushover, and generic endpoints.

### Rationale
- **Flexibility**: Users choose their preferred notification platform
- **No Infrastructure**: No email server or SMS gateway required
- **Extensibility**: Easy to add new webhook formats
- **Modern**: Integrates with existing monitoring stacks

### Consequences
- Requires network connectivity for alerts
- Need to implement rate limiting
- Must handle webhook delivery failures

---

## ADR-008: Prometheus Metrics Format

**Date**: April 2025
**Status**: Accepted

### Context
Need to expose operational metrics for monitoring dashboards.

### Decision
Export metrics in Prometheus/OpenMetrics text format.

### Rationale
- **Industry Standard**: Prometheus is widely adopted
- **Simple Format**: Plain text, easy to debug
- **Ecosystem**: Works with Grafana, AlertManager, etc.
- **Pull Model**: No push infrastructure required

### Consequences
- Must maintain metric naming conventions
- Need HTTP server or textfile collector integration
- Metric cardinality must be controlled

---

## ADR-009: Lockfile-Based Concurrency Control

**Date**: April 2025
**Status**: Accepted; superseded in part by ADR-013 (no stale-lock detection, no removal of lock files)

### Context
Multiple script invocations could interfere with each other.

### Decision
Use lockfiles with timeout and stale lock detection.

### Rationale
- **Simple**: Well-understood mechanism
- **Debuggable**: Can inspect lock state
- **Atomic**: Uses `flock` for atomic acquisition

### Consequences
- Lockfiles can become stale on crashes
- Need to implement timeout and cleanup
- Path to lockfile must be consistent

---

## ADR-010: Signal Handler Pattern

**Date**: April 2025
**Status**: Accepted

### Context
Scripts must clean up resources (processes, temp files) on termination.

### Decision
Use `trap` to register cleanup functions for EXIT, INT, and TERM signals.

### Rationale
- **Reliable Cleanup**: Runs regardless of exit cause
- **Process Management**: Can kill child processes
- **State Reset**: Can remove PID files and locks

### Consequences
- Cleanup must be idempotent (may run multiple times)
- Signal handlers should be simple (avoid complex logic)
- Exit code must be preserved

---

## ADR-011: One Owner for MediaMTX

**Date**: November 2026
**Status**: Accepted

### Context
Two units could own MediaMTX: `mediamtx.service` (the standalone unit the installer writes) and `mediamtx-audio.service` (the stream manager, which starts its own MediaMTX on the same configuration file and ports). The manager's sample unit declared `Wants=` and `PartOf=mediamtx.service`, and the manager's cleanup stopped the standalone unit's process and rewrote the shared file (LB-02, D1 in `docs/REMEDIATION-2026-11.md`).

### Decision
The stream manager owns MediaMTX and its FFmpeg children through one unit, `mediamtx-audio.service` (the name is kept so installed units keep working). The standalone unit stays for MediaMTX-only installs and is mutually exclusive with it: both units have `Conflicts=` on the other, the manager's unit also has `After=mediamtx.service`, and neither has `Wants=`, `Requires=`, `BindsTo=` or `PartOf=`. `start`, `restart` and `reload` refuse with exit 8 and change nothing while `mediamtx.service` is active or a MediaMTX the manager did not start runs on its configuration file. The manager never signals a process it did not start.

### Rationale
- **Rejected: the manager's unit depending on the standalone unit.** Two supervisors then act on one process, one file and one port, and the manager's restart logic fights systemd's.
- **Rejected: taking over the other owner's process.** Stopping or adopting a process whose life systemd owns, or a MediaMTX someone started by hand, cannot be done safely by name.
- **A refusal with a reason beats a silent takeover**: nothing changed, and the exit status says who owns the node.

### Consequences
- A node that enables both units gets whichever started last; `start` fails with exit 8 while the standalone unit is active.
- `install_mediamtx.sh` stops MediaMTX through its owner (systemd or the manager), not by name.
- The `Conflicts=` and `After=` transaction at boot has been checked with `systemd-analyze verify` only, not under a real systemd manager.

---

## ADR-012: `start` Reports Whether Streams Publish; No Device Is Not a Failure

**Date**: November 2026
**Status**: Accepted

### Context
`start` printed `[FAIL]` lines for streams that did not come up and still exited 0 ("best effort"). With no USB audio device it exited 6 before starting MediaMTX, so a hub that appeared late used up systemd's start limit and the node never recovered (LB-03, LB-07, X-03; D4 and D5).

### Decision
`start` exits 0 when its policy is met and fails with exit 9 when it is not. `LYREBIRD_START_POLICY=degraded` (the default) requires one stream to be publishing, `strict` the stream of every detected device. A stream is publishing when MediaMTX's API says its path is ready, not when FFmpeg is running. A failed start stops what that run started and never touches a stack that was already running. With no device, `start` starts MediaMTX, reports `waiting_for_devices` and exits 0 (`LYREBIRD_ALLOW_EMPTY_START=false` gives the old exit 6); the monitor then starts the stream of each device that appears and restarts a MediaMTX that is gone while the node is meant to run, within the cron restart budget. Every command that changes or checks state writes `/run/lyrebird/status.json` (per stream: `configured`, `process_alive`, `path_ready`, `bytes_flowing`, each true, false or null for "not known", and `last_error`).

### Rationale
- **Rejected: success when the processes run.** A live FFmpeg that cannot reach MediaMTX, or a wrapper in back-off, is not a published stream.
- **Rejected: `strict` as the default.** One broken microphone would take every other stream down with the start.
- **Rejected: exit 6 for no device.** It turns a transient condition into a failed unit.

### Consequences
- A node whose microphones all fail now has a failed `start`, which `Restart=always` retries.
- The orchestrator and the wizard read the status document instead of state captured before the start.
- The file describes the node as of the last command that ran; it keeps no history of errors.
- The real USB hot-plug sequence and a late hub against systemd's start limit were not tested (LB-07).

---

## ADR-013: Locks and Process Control Do Not Guess

**Date**: November 2026
**Status**: Accepted; supersedes the stale-lock detection of ADR-009

### Context
`acquire_lock` removed a lock it judged stale (older than 300 s, or whose owner's command name did not match, which never matched when the script was run directly), so a live owner was treated as dead and two lifecycle commands could run at once; MediaMTX and FFmpeg inherited the lock descriptor. Processes were found and killed by name and command line (`pkill -f '^ffmpeg.*rtsp://localhost:8554'`, `pgrep -x mediamtx`), which also hit other installations' processes and other programs reading a stream (LB-05, X-02, LB-10, X-26; D2 and D11).

### Decision
- **Locks**: a `flock` on a stable path. The file is opened without truncation and never removed; the kernel releases the lock when the holder dies. After winning it, the holder writes `<pid> <start time>` (field 22 of `/proc/<pid>/stat`) into it as information for the message of a command that has to give up; it is never used to decide whether the lock is held. Every long-lived child is started with its inherited descriptors closed. The installer, the updater (X-31) and the alert state also lock with `flock` on files they never remove.
- **Processes**: the manager signals only a PID recorded in its own PID files whose start time (kept in `<pid file>.id`) still matches and whose running image is the expected one (MediaMTX: the configured binary with the configuration file as its first argument; a wrapper: `bash` with the stream's generated script as its first argument). `force-stop` signals only those; `force-stop --kill-all --yes` is the only broad kill and prints what it will kill first. The first signal is SIGTERM, then SIGKILL after a timeout.

### Rationale
- **Rejected: age- or name-based staleness.** Reproduced: a live owner was judged stale and its lock replaced. Unlinking a held lock gives the next process a different inode, so nothing excludes anything.
- **Rejected: a PID, or a program name, as identity.** A PID is reused, and a name matches look-alikes (an editor with the wrapper open, another installation's MediaMTX).
- **SIGTERM first**: a background job of a non-interactive shell inherits "ignore SIGINT", so SIGINT could end a wrapper only by the SIGKILL after the timeout.

### Consequences
- There is no stale lock to clean up, and lock files are never deleted by hand; "Failed to acquire lock" names the holder.
- `stop` and `force-stop` refuse with exit 5, changing nothing, after `STOP_LOCK_TIMEOUT` seconds (default 5); the monitor skips its cycle while a lifecycle command runs.
- On a node started by code from before this change, the first `stop` can refuse because MediaMTX and FFmpeg hold the old lock; `systemctl restart` works.
- After a SIGKILL of the manager the lock is free at once, except while an external command it was running at that instant (`sleep`, `curl`) still holds the descriptor.
- Without `/proc` nothing can be proven, so the installer signals nothing there. The metrics exporter needs root to identify other users' processes.

---

## ADR-014: Configuration Values and Names Are Data

**Date**: November 2026
**Status**: Accepted

### Context
The device configuration was `source`d: `exit 0` in it ended the manager, an unbound variable killed it under `set -u`, a `trap` line removed its cleanup trap, and `$(...)` ran as root. Generated stream wrappers pasted values between double quotes (a `"`, `$(...)`, backtick or trailing backslash executed or broke them). A stream name reached the YAML key raw, the publisher URL sanitized, and the PID file, the systemd `Environment=` line and the cron file in other forms: `Studio Mix` made MediaMTX refuse to start, and a newline injected YAML (LB-08, X-09, LB-09, X-10, LB-04, X-11; D3 and D13).

### Decision
- **Device configuration** is read by an allowlist parser and never `source`d or `eval`ed: `DEVICE_<NAME>_<SETTING>=value`, `<SETTING>` one of `SAMPLE_RATE`, `CHANNELS`, `CODEC`, `BITRATE`, `THREAD_QUEUE`, `PCM`; a value is bare, `'...'` or `"..."`, taken literally. One loader serves `validate`, `start`, `restart`, `monitor` and `status`. A line it cannot use is reported with file, line and key and skipped, so the setting keeps its default and streams still start; `validate` exits 4 for such a file.
- **Wrappers** stay generated per-stream scripts, but every value in the header passes through `printf %q`, the script is checked with `bash -n` and installed by rename.
- **Stream names** pass through one rule, `canonical_stream_name`, applied once: lower case, `[a-z0-9_-]`, starting with a letter or digit, at most 64 characters; the reserved words `control`, `stats`, `api`, `metrics`, `health`, `all` and `all_others`, and a name with no letter or digit, are refused (exit 4). The YAML path key is quoted.

### Rationale
- **Rejected: check the syntax, then `source`** (the 2026-07 approach). A valid file still runs code.
- **Rejected: sanitizing where a name is used.** The publisher URL and the YAML key then disagreed.
- **Rejected: truncating a long name.** Two names could collide.
- **Not chosen, and still open: one fixed wrapper program** that receives validated arguments. It needs another installed file and changes the command line the monitor matches on.

### Consequences
- Keys in mixed case, which `lyrebird-mic-check.sh` once wrote, are read (with a warning) and so now apply; `DEVICE_*` environment variables are not read; `DEFAULT_*=` lines in the file are an error (the environment sets them); `BITRATE` must be `NNNk`; `CODEC` must be `opus`, `aac` or `mp3`.
- A writable configuration can no longer run code as root, but a bad line still degrades the stream it names. The file's mode and owner are not checked.
- `lyrebird-storage.sh` reads `/etc/lyrebird/storage.conf` with the same forms, and refuses a file anyone can write.

---

## ADR-015: Loopback Listeners by Default; Authentication Is the Operator's

**Date**: November 2026
**Status**: Accepted

### Context
The generated configuration bound the API (9997) and metrics (9998) on every interface; the installer's also left SRT, and from MediaMTX 1.19.0 MoQ, listening. RTSP accepts anonymous publishers and readers from any address (LB-06; D9).

### Decision
API and metrics bind `127.0.0.1` (`MEDIAMTX_API_BIND` and `MEDIAMTX_METRICS_BIND` change that; an empty value means every interface). RTMP, HLS, WebRTC and SRT are off in every generated configuration, and MoQ is off from 1.19.0 (the key is invalid before); no option turns them on. RTSP stays on every interface and anonymous. Authentication is the operator's: `RTSP_AUTH_MODE=local-only-publish` renders the pattern that was verified (this machine needs no password, every other client must be a listed read-only user from `RTSP_USERS_FILE`); anything else is written by hand in a file the operator owns (ADR-016).

### Rationale
- **Rejected: authentication on by default.** Every existing publisher and reader would stop working, and credentials would have to be distributed.
- **Rejected: relying on MediaMTX's default policy** (it already answers 401 to a non-loopback caller of the API or metrics). A bind address does not depend on a default that a configuration can change.

### Consequences
- RTSP is open to whoever can reach the port until the operator closes it. A test asserts this, so that a change is deliberate.
- The manager asks the API where it listens (`MEDIAMTX_API_BIND`, else `MEDIAMTX_HOST`).
- The set of listening sockets was checked on MediaMTX 1.15.0, 1.18.0, 1.19.0, 1.21.1, 1.21.2 and 1.21.3 (RTSP on every interface, API and metrics on loopback, the two UDP ports of RTSP). A remote client on another host and IPv6 were not tested.
- Nodes installed by the earlier installer keep their file until it is replaced.

---

## ADR-016: The Project Rewrites Only the MediaMTX Configuration It Owns

**Date**: November 2026
**Status**: Accepted

### Context
The manager regenerated `mediamtx.yml` on every `start`, with no backup and before the port check, so a password, bind address or file mode set by the operator was lost; the installer had a generator of its own that differed (LB-22; D10).

### Decision
One renderer, `lyrebird_render_mediamtx_config` in `lyrebird-common.sh`, serves the manager and the installer. A first line `# Managed by LyreBirdAudio` marks a file as the project's. Only a marked, missing or empty file is rewritten, and only when the rendering changes, after the new text has been validated (by MediaMTX's own `--validate-conf` where the binary has it, from 1.21.1) and after a timestamped backup: the manager keeps `mediamtx.yml.<UTC time>.<nn>.bak`, the newest `MEDIAMTX_CONFIG_BACKUPS` (default 5); the installer writes `mediamtx.yml.backup.<time>`. A file without the marker is the operator's: used as it is, never written, a warning at every start. `--regenerate-config` (manager) and `--force` (installer) hand it over after a backup; deleting the first line takes a marked file back. One narrow exception: a first line of exactly `# MediaMTX Configuration - Audio Streams`, which the earlier manager wrote at every start, is adopted (X-38).

### Rationale
- **Rejected: always regenerate.** It is the defect.
- **Rejected: never write.** The file has to follow the ports, the file mode and the version-dependent `moq` key.
- **Rejected: adopting any file that looks generated.** The earlier installer's file has a different first line and may have been edited on purpose; only the one text that the earlier manager rewrote at each start, so that no edit could have survived it, is adopted.

### Consequences
- The first `start` after an upgrade replaces the earlier manager's file (its old text is in the backup); a file the earlier installer wrote stays as it is, with its every-interface API, until `--regenerate-config` or `install_mediamtx.sh --force install`.
- MediaMTX before 1.21.1 has no `--validate-conf`: an unknown key or an invalid path name is found only when MediaMTX refuses to start.
- The installer keeps every `mediamtx.yml.backup.*`; it has no retention.

---

## ADR-017: Durable Atomic Writes

**Date**: November 2026
**Status**: Accepted; supersedes ADR-005 in part

### Context
ADR-005 chose a temporary file and `mv`. That is atomic for readers but not durable: after a power cut the new file can be empty or missing on some filesystems and on flash media, and the directory entry may not have been written (LB-23; D14).

### Decision
One helper, `lyrebird_atomic_write DEST [MODE [OWNER_REFERENCE_FILE]]` in `lyrebird-common.sh`, writes a hidden temporary file in the destination's directory, fsyncs it, renames it over the destination and fsyncs the directory. The MediaMTX configuration, the device configuration (manager and `lyrebird-mic-check.sh`), the installer's configuration and unit, and the alert delivery stamps go through it. Where the library is missing, mic-check and the alerts define a local fallback that has no fsync. The status file (on tmpfs), the heartbeat and `lyrebird-metrics.sh --file` (regenerated every interval) are still replaced by rename alone, on purpose.

### Rationale
- **Rejected: temporary file plus `mv`.** A reader never sees a torn file, but a crash can leave an empty one.
- **Not used everywhere**: a file that is rewritten within minutes and describes a moment gains nothing from the cost of an fsync.

### Consequences
- Whether the medium honours the flush is up to the storage stack; a real power cut on real storage is not tested here, only the order of the operations (temporary file, rename, directory).
- `sync -- PATH` syncs one path from coreutils 8.24; older systems fall back to a global `sync`.

---

## ADR-018: Ports Are Configuration

**Date**: November 2026
**Status**: Accepted

### Context
The README documented `MEDIAMTX_RTSP_PORT`, `MEDIAMTX_API_PORT` and `MEDIAMTX_METRICS_PORT`, while the manager hard-coded 8554, 9997 and 9998 in the generator, the readiness check, the probes and the port check, so a node that moved a port stopped working and tests could not run beside a real MediaMTX (X-19; D15).

### Decision
The three variables are read once and used by the renderer, the readiness and stream probes, the port-in-use check, the wrappers' publish URL and every URL the manager prints. A value that is not a decimal integer from 1 to 65535 ends every manager command with exit 4 (the installer: exit 10, before anything is downloaded); an empty value means the default. The three must differ. The port-in-use check counts listening TCP sockets only.

### Rationale
- **Rejected: documenting the ports as fixed.** Operators have conflicts, and the live tests need private ports.
- **Rejected: falling back to the default on an invalid value.** A typo would move a listener without a word.

### Consequences
- `lyrebird-stream-manager.sh install` writes no port variable into the unit or the cron file, and rewrites the cron file each time: a node with other ports must repeat that by hand after each `install`.
- Live tests allocate free ports per test (`tests/mediamtx_live_helper.bash`) and move MediaMTX's other listeners with its `MTX_*` environment overrides; only the two soak live test files still bind 8554 and 9997.

---

## ADR-019: Silence Is Measured on the Published Stream

**Date**: November 2026
**Status**: Accepted

### Context
`check_all_audio_levels` had no caller, so `AUDIO_LEVEL_CHECK_ENABLED=true` did nothing and the only dead-microphone signal was the API's `ready` flag, which sees "no publisher", not "a publisher that is silent". Wired up as written, it would have opened `plughw:<card>,0` a second time next to the capture FFmpeg and counted "the probe failed" as silence (LB-14, X-05; D6).

### Decision
`probe_stream_level` reads `AUDIO_LEVEL_SAMPLE_DURATION` seconds of `rtsp://127.0.0.1:<MEDIAMTX_RTSP_PORT>/<path>` through FFmpeg's `volumedetect`; no ALSA device is opened. Its verdict is `ok`, `silent` (`max_volume` at or below `AUDIO_SILENCE_THRESHOLD_DB`), `no_audio_data`, `unreachable` or `probe_error`, and only `silent` counts as silence. A silence episode logs `DEAD MIC` once, when it has lasted `AUDIO_SILENCE_WARN_DURATION` seconds; a probe that cannot decide neither starts, extends, ends nor alerts one. Four signals stay apart: the path is ready and bytes move (both in the status file), the level, and prolonged silence (the log).

### Rationale
- **Rejected: a second open of the sound card.** It contends with the capture process, and what a real USB card does on a second open is not known here.
- **Rejected: the API's `ready` flag as proof of audio.** A publisher can be connected and silent.

### Consequences
- Each monitor run opens at most one short RTSP reader per stream; the probe reads anonymously, so a MediaMTX that requires authentication to read gives a failed probe at every run, never silence.
- The signal is a log line: no metric and no alert type exist for it. The monitor runs every 5 minutes as installed, so the first `DEAD MIC` comes at the second silent probe.
- The -60 dB default was checked against digital silence and an FFmpeg test tone, not against real microphones.

---

## ADR-020: No Setting Without an Implementation

**Date**: November 2026
**Status**: Accepted

### Context
`HEARTBEAT_INTERVAL` and `HARDWARE_WATCHDOG_TIMEOUT` were never used; `init_hardware_watchdog` logged "initialized" without ever opening the device, and the code that would have written to it was unreachable. `AUDIO_DISK_PERSIST` only created a directory while the segments went to `/dev/shm` (LB-15, LB-16; D7 and D8).

### Decision
The watchdog code and its settings (`HEARTBEAT_INTERVAL`, `HARDWARE_WATCHDOG_TIMEOUT`, `ENABLE_HARDWARE_WATCHDOG`, `HARDWARE_WATCHDOG_DEVICE`, and the sample unit's `LYREBIRD_WATCHDOG_ENABLED` and `LYREBIRD_WATCHDOG_INTERVAL`) and `AUDIO_DISK_PERSIST` and `AUDIO_DISK_PATH` are removed. A removed name that is still set is ignored with one warning per run, which says what replaces it. The heartbeat stays and means exactly "the time of the last monitor run". A hardware watchdog is systemd's `RuntimeWatchdogSec=` or a watchdog daemon, set up by the operator. Recording is RAM-only by default; durable recording is `AUDIO_RECORDING_PATH` on persistent storage.

### Rationale
- **Rejected: implementing a hardware watchdog in the manager.** A device that is closed wrongly resets a field node, it cannot be tested here, and systemd already has one.
- **Rejected: implementing `AUDIO_DISK_PERSIST`.** It was never specified, and a persistent default wears an SD card.
- **Rejected: keeping the names as "reserved".** A setting that does nothing reads as a feature.

### Consequences
- `lyrebird_heartbeat_healthy` proves that the monitor ran, not that any stream is up.
- The recording is a ring of `AUDIO_RECORDING_SEGMENTS` segments overwritten in place: even on persistent storage it holds the last hour (by default), and the retention days of `lyrebird-storage.sh` do not govern it.
- Neither unit has `WatchdogSec=`: the manager sends no keep-alives, so one would restart the service at every interval.

---

## ADR-021: One Template per Unit, Rendered and Never Signalled

**Date**: November 2026
**Status**: Accepted

### Context
The sample `mediamtx-audio.service` and the unit the manager's `install` wrote differed in a dozen directives. The sample's `ExecReload` ran a command that did not exist; the installer's sent USR1, which MediaMTX ignores; the standalone sample sent HUP, which ends MediaMTX. `ProtectSystem=strict` lacked `/var/lib/mediamtx-ffmpeg`, so `start` failed in its own sandbox; `Group=audio` fails the unit with status 216/GROUP on a system without that group (read from systemd's behaviour, not run here); the start limit sat in `[Service]` (LB-11, LB-12, X-12; D12).

### Decision
`config/mediamtx-audio.service` (the manager) and `config/mediamtx.service` (the standalone MediaMTX) are each a complete, valid unit with default paths. The manager's `install` and `install_mediamtx.sh install` render them, replacing only the lines the template's header lists, and refuse a value a unit cannot carry before writing anything. The start limit is `StartLimitIntervalSec=` and `StartLimitBurst=` in `[Unit]`. `ExecReload=` exists only where a real `reload` does (the manager's, `lyrebird-stream-manager.sh reload`); MediaMTX re-reads its changed file by itself, so the standalone unit has none. The manager's unit uses `ProtectSystem=strict` with every path the manager writes made writable (`StateDirectory=`, `RuntimeDirectory=`, `ConfigurationDirectory=`, `ReadWritePaths=`), `Restart=always`, and start and stop timeouts computed from the manager's own timings.

### Rationale
- **Rejected: two hand-kept texts.** They drifted.
- **Rejected: a signal as reload.** Measured on real MediaMTX 1.21.1: HUP ends it, USR1 and USR2 are ignored.
- **Rejected: waiting for `network-online.target`.** The streams need no address, and the wait delays the audio stack on a node with no uplink.
- **Rejected: `PrivateDevices=`, `DevicePolicy=` and `ProtectClock=`.** USB audio needs `/dev/snd` and new device nodes at any time.

### Consequences
- `install` must be run from a checkout (it needs `config/` next to the script); a node keeps the unit it has until `install` runs again, which the updater does.
- `Restart=always` is also what restarts a MediaMTX that exits with status 0, as it does when it cannot load its file.
- The paths the manager writes were audited in a mount-namespace emulation of `ProtectSystem=strict`, and the units with `systemd-analyze verify`; none of it ran under a real systemd manager (start-limit timing with a late hub, the order in which the directories are created, `Conflicts=` at boot).

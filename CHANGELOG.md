# Changelog

All notable changes to LyreBirdAudio will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### ⚠️ Breaking Changes
- **Script Renamed**: `mediamtx-stream-manager.sh` → `lyrebird-stream-manager.sh`
  - Log file path changed: `/var/log/mediamtx-stream-manager.log` → `/var/log/lyrebird-stream-manager.log`
  - **Automatic migration**: Running `lyrebird-updater.sh` will automatically update:
    - Systemd service files
    - Cron jobs
    - `/usr/local/bin` installations
    - Log file symlinks for backward compatibility
  - **Manual migration**: Run `sudo ./lyrebird-updater.sh --migrate`

### Added
- Automatic migration system in `lyrebird-updater.sh` v1.6.0
  - Post-update migrations for breaking changes
  - Idempotent migration tracking in `/var/lib/lyrebird/migrations/`
  - CLI flag `--migrate` for manual migration runs
- Migration detection in `lyrebird-orchestrator.sh`
  - Startup warning when old script names detected
  - Clear remediation steps for users
- Webhook alerting system (`lyrebird-alerts.sh`) for remote monitoring
  - Supports Discord, Slack, ntfy.sh, Pushover, and generic HTTP webhooks
  - Rate limiting and alert deduplication
  - Pure bash implementation with no new dependencies
- `CHANGELOG.md` to track version history
- `CONTRIBUTING.md` with contribution guidelines

### Changed
- Improved inline documentation in `usb-audio-mapper.sh`
- Enhanced error messages with remediation steps
- `lyrebird-stream-manager.sh` updated to v1.4.4
  - Restructured API validation to preserve curl exit status for better error detection
  - Replaced `curl|grep` pattern with explicit exit code checking
- CI now runs the `bats` test suite as a required check (previously never run)
- Documented MediaMTX support through v1.19.x (endpoints/assets unchanged from v1.15.x)

### Fixed (Engineering Excellence Review, 2026-07)
Full line-by-line audit; see `docs/ENGINEERING-REVIEW-2026-07.md`. Each fix ships
with a regression test. Highlights (all verified against the code):
- **USB persistent naming never worked** — `usb-audio-mapper.sh` emitted every
  udev rule as a comment (a literal `\n` collapsed the comment and rule onto one
  `#`-prefixed line). Also fixed an injection-prone card-name sanitizer.
- **FFmpeg streams did not auto-restart** — the supervisor wrapper died on the
  first FFmpeg failure (bare `wait` under `set -euo pipefail`) and again when the
  transient launcher PID exited. Restored the wrapper's backoff-restart loop.
- **Per-device audio config was ignored** — `lyrebird-mic-check.sh` wrote
  `DEVICE_<name>_*` keys in the wrong case for the stream manager's uppercase
  lookup; a "high quality" mic silently ran at defaults (and `--validate` passed).
- **ntfy/Pushover alerts were silently dropped** and falsely reported as sent.
- **Prometheus scrape was rejected** — duplicate `# HELP`/`# TYPE` lines.
- **Self-update always failed** — the updater deadlocked on its own lock after
  `exec`.
- **Orchestrator interactive delegations couldn't read input** (backgrounded
  child stdin was `/dev/null`) — the Quick Setup Wizard could not map devices.
- **Storage cleanup halted on a 0-byte file** (disk fill risk); emergency cleanup
  no longer deletes unrelated `/var/log/*.gz` or ignores `--dry-run`.
- **Diagnostics aborted on a healthy host** — `grep -c … || echo 0` produced a
  `0\n0` arithmetic error under `set -e`.
- **Webhook/JSON output is now valid** for control characters and backslashes.
- **Test suite repaired** — 159 tests silently never ran; source guards + `set -e`
  handling restored so all tests execute (and CI enforces them).

### Fixed (Reliability Hardening pass, 2026-07)
Deeper follow-up audit (6 parallel reviewers, every finding reproduced) closing
the pending HIGH items and a large MEDIUM/LOW sweep. Every fix ships with a
regression test; the suite is green (528 tests) and ShellCheck-clean.

- **Storage / data-loss:** `df` output was misparsed on wrapped long device
  names (LVM/`/dev/mapper`), so a FULL disk read as "OK" and cleanup never ran;
  empty-dir cleanup could delete the recording directory itself; oversized-log
  truncation swapped the inode out from under the writer (invisible unbounded
  growth); a non-integer retention env value aborted the script at load (crons
  silently stopped). Now POSIX `df -P` with guards, `-mindepth 1`, in-place
  truncation, and validated numeric inputs.
- **Metrics:** the Prometheus scrape silently aborted in the normal "streams up,
  no listeners" state (unguarded `curl`/`grep|wc` under `set -euo pipefail`), so
  `--file` mode served a STALE `.prom` with `up=1` — a dead recorder looked alive
  for months. Guarded all collectors; label values are now escaped.
- **Stream supervision:** the wrapper gave up after a LIFETIME (not windowed)
  restart count, so streams died off one by one over weeks; a dead stream was
  never resurrected under cron (now bounded per-stream resurrection); disk/memory
  pressure triggered a 5-minute service-restart storm that freed nothing (now
  degraded/alert-only). Generated logrotate now uses `copytruncate`.
- **Installer/updater:** a failed `update` left MediaMTX stopped indefinitely
  (rollback never restarted it); `update -V <ver>` ignored the pin and jumped to
  latest; a branch switch never fast-forwarded (no-op "success"); a self-update
  re-exec could strand the service on a prompt.
- **Alerts:** every CRITICAL Pushover alert was rejected (missing retry/expire);
  ntfy titles containing a colon were truncated. **Diagnostics:** a healthy-host
  run could abort mid-way; several checks read false "healthy" (inotify, disk,
  world-writable config perms, "recent crash", BusyBox reachability).
- **USB mapper:** closed a udev-rule injection via `-u`; made VID:PID-only naming
  visible; atomic rules-file write. **mic-check:** `--format=json` always emitted
  an empty list; config could pick an unsupported channel count.
- **Sample configs:** removed systemd `WatchdogSec` restart-loop traps (MediaMTX
  can't feed it; the manager's ping is rejected under default `NotifyAccess`),
  fixed the audio unit's `Type` (forking) and `StartLimit` placement, and made
  logrotate use `copytruncate`. Added config-file validation tests.
- **Tests/CI:** added a hardware-free end-to-end integration suite (stub MediaMTX
  API, mock webhook, disk-full, device-config round-trip); bumped ShellCheck
  0.10→0.11 (verified clean), shfmt 3.8→3.13.1, actions/checkout v4→v5.

See `docs/ENGINEERING-REVIEW-2026-07.md` for the full finding-by-finding detail.

## [1.4.2] - 2025-12-19

### Added
- Prometheus metrics export (`lyrebird-metrics.sh`)
- Storage management with configurable retention (`lyrebird-storage.sh`)
- Comprehensive test suite (~90 tests, ~50% coverage)
  - `test_usb_audio_mapper.bats` - 15 tests
  - `test_lyrebird_diagnostics.bats` - 16 tests
  - `test_lyrebird_orchestrator.bats` - 14 tests
  - Enhanced `test_stream_manager.bats` - 32 tests
- systemd service files with watchdog support
  - `config/mediamtx.service`
  - `config/mediamtx-audio.service`
- Log rotation configuration (`config/lyrebird-logrotate.conf`)
- Security documentation (`docs/SECURITY-GUIDE.md`) with optional TLS/auth guides
- `.gitignore` file to prevent accidental sensitive data commits

### Changed
- Updated stream manager version to 1.4.2
- README updated with new scripts and configuration files
- Comprehensive audit report documenting 64 issues

## [1.4.1] - 2025-12

### Added
- Friendly name support for device configuration in stream manager
- Dual-lookup config system (friendly names and full device IDs)

### Fixed
- Device configuration lookup now tries friendly name first, then full ID

## [1.4.0] - 2025-12

### Added
- Production stability and monitoring enhancements
- Heartbeat/watchdog integration with systemd
- Network connectivity monitoring
- Resource threshold monitoring (CPU, memory, file descriptors)

### Changed
- Improved stream recovery with exponential backoff
- Better cron-based health monitoring

## [1.3.4] - 2025-12

### Fixed
- Resolved persistent stream failure issues
- Improved FFmpeg process lifecycle management

## [2.1.2] - 2025-12 (Orchestrator)

### Fixed
- Fixed broken integrations found in verification testing
- Improved menu navigation and user feedback

## [2.1.1] - 2025-12 (Orchestrator)

### Fixed
- Various bugs in menu handling
- Improved UI/UX responsiveness

## [2.1.0] - 2025-12 (Orchestrator)

### Added
- Microphone capability detection integration
- Security hardening for external script calls
- SHA256 integrity checking for sourced scripts

### Changed
- Improved hardware capability display
- Better error handling throughout

## [2.0.1] - 2025-12 (Orchestrator)

### Added
- Cross-platform support improvements
- Security fixes for input handling

## [1.5.1] - 2025-12 (Updater)

### Added
- Pre-execution syntax validation for self-updates
- Self-update safety checks

### Fixed
- Improved rollback reliability

## [1.5.0] - 2025-12 (Updater)

### Added
- Automatic systemd service lifecycle management
- Stop services before update, reinstall after
- Cron job update handling

## [1.2.1] - 2025-12 (USB Audio Mapper)

### Fixed
- USB port detection bug causing incorrect device-to-port mapping
- Improved physical port path resolution

## [1.0.2] - 2025-12 (Diagnostics)

### Added
- Cross-platform compatibility improvements

### Fixed
- Reliability fixes for various system configurations

## [2.0.1] - 2025-12 (MediaMTX Installer)

### Added
- Platform-aware installation (Linux/Darwin/FreeBSD)
- Automatic architecture detection (x86_64, ARM64, ARMv7, ARMv6)
- SHA256 checksum verification
- Atomic updates with automatic rollback
- Dry-run mode for testing

### Changed
- Built-in upgrade support for MediaMTX 1.15.0+

## [1.0.0] - 2025-12 (Mic Check)

### Added
- Hardware capability detection via `/proc/asound`
- Non-invasive detection (won't interrupt active streams)
- Automatic sample rate, channel, and format detection
- Quality tier recommendations (low/normal/high)
- Configuration generation and validation
- JSON output support

## [1.0.0] - 2025-12 (Common Library)

### Added
- Shared utility library (`lyrebird-common.sh`)
- Standardized color handling
- Common logging functions (debug, info, warn, error)
- Command existence checking with caching
- Portable hash computation
- Standard exit codes

---

## Version Numbering

Each component maintains its own version:

| Component | Current Version |
|-----------|-----------------|
| lyrebird-orchestrator.sh | 2.1.2 |
| lyrebird-stream-manager.sh | 1.4.4 |
| lyrebird-updater.sh | 1.6.0 |
| usb-audio-mapper.sh | 1.2.1 |
| lyrebird-diagnostics.sh | 1.0.2 |
| install_mediamtx.sh | 2.0.1 |
| lyrebird-mic-check.sh | 1.0.0 |
| lyrebird-common.sh | 1.0.0 |
| lyrebird-metrics.sh | 1.0.0 |
| lyrebird-storage.sh | 1.0.0 |
| lyrebird-alerts.sh | 1.0.0 |

## Links

- [GitHub Repository](https://github.com/tomtom215/LyreBirdAudio)
- [Issue Tracker](https://github.com/tomtom215/LyreBirdAudio/issues)
- [Discussions](https://github.com/tomtom215/LyreBirdAudio/discussions)

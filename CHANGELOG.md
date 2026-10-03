# Changelog

All notable changes to LyreBirdAudio will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Soak testing and current MediaMTX (2026-10)

Component versions bumped: `lyrebird-stream-manager.sh` 1.5.0 → 1.5.1.

#### Added
- `tools/soak/`: a soak-test harness for field-like long runs.
  `lyrebird-soak.sh` runs on the node (systemd service), checks device names
  against the usb-audio-mapper rules, stream liveness and stalls, services and
  resource trends, injects faults on a seeded schedule (process kills, udev
  restarts, USB unplug, network loss, full disk, clock steps, reboots and
  hard resets; each undo armed as a systemd timer before the fault), and
  reports PASS/FAIL. `lyrebird-soak-observer.sh` watches the streams from a
  second machine (bash 3.2 or later), can cut the node's power through
  commands you supply, and reports gaps and time to audio. See
  `tools/soak/README.md`.
- Live tests against real MediaMTX releases (`tests/fetch_mediamtx.sh`
  downloads checksum-pinned 1.15.0, 1.18.0, 1.19.0 and 1.21.1), run by a new
  CI job.

#### Fixed
- **MediaMTX 1.19.0 and later opened three extra ports.** Those versions start
  a MoQ (Media over QUIC) server unless told not to, so the generated
  `mediamtx.yml` left `:8892/tcp`, `:8892/udp` and `:8893/udp` listening on
  every interface (allowed origins `*`), and MediaMTX wrote a generated
  key/certificate pair into its working directory. The installer installs the
  latest release by default, so new installs were affected. The config now
  says `moq: no` when the installed MediaMTX is 1.19.0 or later; 1.15–1.18
  refuse to start with that key, so it is left out for them and when the
  version cannot be read. Verified with the real binaries of every release
  from 1.15.0 to 1.21.1.

### USB Audio Mapper 4.0.0 (2026-10)

`usb-audio-mapper.sh` is now the same file as the standalone
[usb-audio-mapper](https://github.com/tomtom215/usb-audio-mapper) 4.0.0 (its
version number replaces this repository's 1.2.1). Tested end to end with real
Linux kernels and real systemd-udevd in QEMU; see
`docs/ENGINEERING-REVIEW-2026-07.md` §9.

Component versions bumped: `usb-audio-mapper.sh` 1.2.1 → 4.0.0,
`lyrebird-orchestrator.sh` 2.1.2 → 2.1.3, `lyrebird-updater.sh` 1.6.0 → 1.6.1,
`lyrebird-mic-check.sh` 1.0.0 → 1.0.1, `lyrebird-alerts.sh` 1.0.0 → 1.0.1.

#### Fixed
- **USB persistent naming still never worked (critical).** The 2026-07 fix (C1)
  made the rule an active line, but whenever udev knew the device's `ID_PATH`
  the rule matched `ENV{ID_PATH}` taken from the USB *device* node, which never
  equals the sound card's `ID_PATH` (the card's carries the interface suffix,
  e.g. `-usb-0:1:1.0`). In non-interactive mode the value also came from the
  first `lsusb` line with the vendor/product id, so identical devices all got
  the first device's rule and `-u` was ignored. Reproduced with three identical
  devices: 0 of 3 renamed. Rules now match the sound card's own `ID_PATH`
  (imported in the rule), gated to the card device; 3 of 3 renamed, immediately,
  after replug, after udevd restarts and system-wide triggers, and at boot.
- **Wrong microphone named after USB bus renumbering (critical).** A port rule
  such as `KERNELS=="1-1"` contains the USB bus number, which changes between
  boots when host-controller drivers register in a different order; in a test
  with two controllers one microphone got the other's name. `ID_PATH` omits the
  bus number and kept both names in every load order.
- **Names the kernel truncates or refuses**: ALSA card ids hold 15 characters
  (longer names were silently cut), and ids starting with `card` (the
  wizard's own fallback suggestion) or reserved words like `pcm` are refused.
- **Rule side effects**: the rule also matched `controlC*`/`pcm*` nodes, so
  udev logged failed `ATTR{id}` writes on every event and several nodes
  competed for the symlink; re-applying an unchanged id fails with `EEXIST`.
  Rules are now gated (`KERNEL=="card*"` / `"controlC*"`,
  `ACTION=="add|change"`) with an `ATTR{id}!=` guard.
- An invalid `-u` value no longer silently falls back to a vendor/product rule
  that names every identical device the same; several identical devices with
  no port given are refused (exit 5).
- Concurrent mapper runs no longer lose updates (`flock`).
- `-u usb-<controller>-<port>` (the form in `/proc/asound/cards`) was refused
  when the controller name contains `-`, as on dwc3 ARM boards
  (`usb-xhci-hcd.0.auto-1.2`).

- **Test suite could delete recordings and logs.** `tests/test_lyrebird_storage.bats`
  exported `RECORDING_DIR`/`LOG_DIR`/`TEMP_DIR`, which `lyrebird-storage.sh`
  overwrites with its readonly defaults when sourced, so the teardown's
  `rm -rf` hit `/var/lib/mediamtx-ffmpeg/recordings`, `/var/log/lyrebird` and
  `/tmp`. Run as root on a node, the test suite deleted all recordings and
  logs. The setup now uses the `LYREBIRD_*_DIR` variables; regression test in
  `tests/test_storage_suite_safety.bats`.

- **321 tests could not fail.** Six test files sourced a script in `setup()`
  that replaced bats' `EXIT` trap and then switched errexit off, so a failing
  assertion was ignored. A helper now restores bats' traps and options after
  sourcing, and `tests/test_suite_can_fail.bats` checks every test file.
  This surfaced 28 failures; 25 were wrong tests, corrected to the scripts'
  actual behaviour (`docs/ENGINEERING-REVIEW-2026-07.md` §9, U9–U13).
- The test suite left 27 temp files and directories behind per run. Test files
  that create temp files now give each test a private `TMPDIR`
  (`tests/scratch_tmpdir.bash`), and CI runs `tests/check_tmp_leaks.sh`, which
  fails on any leftover.
- `lyrebird-mic-check.sh -g` wrote `DEFAULT_SAMPLE_RATE`, `DEFAULT_CHANNELS`
  and `DEFAULT_BITRATE` into `audio-devices.conf`, where the stream manager
  ignores them (they are readonly by then) and logs `readonly variable` on
  every load. They are now written as comments; set them in the stream
  manager's environment instead. README corrected.
- `lyrebird-alerts.sh`: level colours and prefixes were lost when the script
  was sourced from a function.
- `lyrebird-updater.sh --help` now lists the command-line options.
- `lyrebird-stream-manager.sh` header said version 1.4.4 (it is 1.5.0), which
  `lyrebird-diagnostics.sh` reported.

#### Added
- `--card N`, `--list`, `--remove NAME`, `--dry-run`, `--no-apply`,
  `--any-port`; immediate application with kernel verification (exit 6 when
  the name did not take, naming the card that holds it); automatic migration
  of rules written by earlier versions; documented exit codes.

#### Changed
- Orchestrator: no reboot prompt after mapping (not needed any more); messages
  name the real outputs (`/proc/asound/cards`, `/dev/sound/by-id/`); "show
  mappings" uses `usb-audio-mapper.sh --list`.
- Docs: removed references to `/dev/snd/by-usb-port/Device_N` and
  `--rescan`, neither of which existed, and to reboots after mapping.
- `tests/test_usb_audio_mapper.bats` replaced: the old file had 19 tests, 14 of
  which tested copies of functions defined inside the test file rather than the
  script. The new suite (56 tests) runs the real script against a fake sysfs.
  The QEMU end-to-end suite lives in the standalone repository.

### Reliability Audit (2026-07, third pass)

A third adversarial, hardware-free reliability pass focused on the long-horizon
and cold-start failure modes an unattended field node hits over weeks/months.
Every fix ships with a regression test that fails before and passes after; the
suite grew from 528 to 579 tests, all green, ShellCheck-clean. See
`docs/ENGINEERING-REVIEW-2026-07.md` §8 for the reproduced findings.

Component versions bumped: `lyrebird-stream-manager.sh` 1.4.3 → 1.5.0,
`lyrebird-metrics.sh` 1.1.0 → 1.2.0, `lyrebird-storage.sh` 1.0.0 → 1.1.0.

#### Deferred trio — closed with simulation proof
- **Deep health check (H9)**: `monitor_streams` now probes the MediaMTX control
  API for each path's readiness, not just the wrapper's bash PID. A stream whose
  path stays not-ready for `DEEP_HEALTH_MAX_STRIKES` (default 3) consecutive
  monitor runs — a hung FFmpeg or endless backoff — is restarted within the
  existing cron budget. An unreachable API neither strikes nor forgives a
  stream; a ready probe resets the streak; `DEEP_HEALTH_CHECK_ENABLED=false`
  restores the old shallow behavior.
- **Deprecated MediaMTX JSON fields**: readiness parsing now accepts both the
  deprecated (`ready`) and current (`available`) path-status shapes, preferring
  the new field, across all five grep sites (stream-manager ×4, metrics ×1). A
  future MediaMTX that drops `ready` no longer makes every stream look dead.
- **Non-monotonic timing**: wrapper run-time/backoff, the cron restart budget,
  and silence tracking now read `/proc/uptime` (monotonic) instead of wall-clock
  `date +%s`. An NTP step on an RTC-less Pi no longer counts a healthy multi-hour
  run as a failure, evaporates the anti-storm budget, or fires a false DEAD MIC.

#### Fixed
- **errexit/pipefail silent aborts**: swept 15 more `var=$(… | grep …)` sites
  across seven scripts where a zero-match grep aborted the whole run under
  `set -euo pipefail` (NTP probe on an unsynced daemon, audio-level check with no
  volumedetect output, metrics scrape when MediaMTX exits mid-scrape, checksum
  verification, service-env merge, and more). Idle-server counting in the stream
  manager (`0 ready paths`/`0 sessions`) was aborting too.
- **Corrupt device config aborted `start`**: a config truncated by power loss,
  SD-card bit-rot, or a bad operator edit hit a syntax error that aborted the
  whole run under errexit — no streams came up on the next unattended boot. The
  config is now syntax-checked before sourcing and ignored if corrupt; a valid
  config is sourced with errexit neutralised and still fully honored.
- **Non-numeric env knobs aborted the cron monitor**: 37 numeric knobs in the
  stream manager (e.g. `CRON_RESTART_MAX_PER_HOUR=unlimited`) reached bash
  arithmetic and killed every cron pass with an "unbound variable" error. All
  are now coerced to sane defaults at load; valid overrides are preserved.
- **Broken-clock mass deletion**: age-based recording retention is skipped while
  the system clock is pre-2025 (not yet NTP-synced), and any recording whose
  mtime predates that epoch is kept — preventing minutes-old data from being
  deleted as "56 years old" the moment the clock steps. Emergency size-based
  cleanup is deliberately exempt.

#### Added
- **Inode-exhaustion detection** in storage monitoring: a recorder writing many
  small files exhausts inodes long before blocks; `cmd_monitor` now applies the
  warning/critical/emergency thresholds to `df -Pi` too. Filesystems without
  inode accounting are treated as no pressure.
- **In-band metrics staleness marker**: every scrape emits
  `lyrebird_scrape_timestamp_seconds` so a `.prom` left behind by a dead exporter
  ("dead recorder looks alive") is detectable via a Prometheus age alert.

## [1.3.0] - 2026-07-19

First release to bundle the full Engineering Excellence Review (C1–C9, H1–H10)
and the follow-up Reliability Hardening pass. A large correctness/reliability
release for unattended 24/7 operation — no intentional breaking API change; the
one script rename is handled by automatic migration. Suite: 528 tests, green;
ShellCheck-clean. Highlights are grouped below.

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

The **suite** is released as a whole under a single `vX.Y.Z` git tag (the value
`git describe --tags` returns); the current release is **v1.3.0**. Each component
additionally tracks its own internal version, shown below:

| Component | Current Version |
|-----------|-----------------|
| lyrebird-orchestrator.sh | 2.1.3 |
| lyrebird-stream-manager.sh | 1.5.0 |
| lyrebird-updater.sh | 1.6.0 |
| usb-audio-mapper.sh | 4.0.0 |
| lyrebird-diagnostics.sh | 1.0.2 |
| install_mediamtx.sh | 2.0.1 |
| lyrebird-mic-check.sh | 1.0.0 |
| lyrebird-common.sh | 1.0.0 |
| lyrebird-metrics.sh | 1.2.0 |
| lyrebird-storage.sh | 1.1.0 |
| lyrebird-alerts.sh | 1.0.0 |

## Links

- [GitHub Repository](https://github.com/tomtom215/LyreBirdAudio)
- [Issue Tracker](https://github.com/tomtom215/LyreBirdAudio/issues)
- [Discussions](https://github.com/tomtom215/LyreBirdAudio/discussions)

# Changelog

All notable changes to LyreBirdAudio will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Webhook alerting system (`lyrebird-alerts.sh`) for remote monitoring
  - Supports Discord, Slack, ntfy.sh, Pushover, and generic HTTP webhooks
  - Rate limiting and alert deduplication
  - Pure bash implementation with no new dependencies
- `CHANGELOG.md` to track version history
- `CONTRIBUTING.md` with contribution guidelines

### Changed
- Improved inline documentation in `usb-audio-mapper.sh`
- Enhanced error messages with remediation steps

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
- Security documentation (`docs/SECURITY.md`) with optional TLS/auth guides
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
| lyrebird-stream-manager.sh | 1.4.3 |
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

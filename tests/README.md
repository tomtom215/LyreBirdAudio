# LyreBirdAudio Test Suite

Unit tests for LyreBirdAudio using the [Bats](https://github.com/bats-core/bats-core) testing framework.

## Test Coverage Summary

| Component | Test File | Tests | Est. Coverage |
|-----------|-----------|-------|---------------|
| lyrebird-common.sh | test_lyrebird_common.bats | 40 | 80% |
| lyrebird-stream-manager.sh | test_stream_manager.bats | 39 | 50% |
| usb-audio-mapper.sh | test_usb_audio_mapper.bats | 56 | not estimated (real script vs. fake sysfs; E2E in the standalone repo) |
| lyrebird-diagnostics.sh | test_lyrebird_diagnostics.bats | 37 | 70% |
| lyrebird-orchestrator.sh | test_lyrebird_orchestrator.bats | 48 | 70% |
| lyrebird-alerts.sh | test_lyrebird_alerts.bats | 54 | 60% |
| lyrebird-metrics.sh | test_lyrebird_metrics.bats | 39 | 55% |
| lyrebird-storage.sh | test_lyrebird_storage.bats | 59 | 65% |
| lyrebird-updater.sh | test_lyrebird_updater.bats | 58 | 75% |
| install_mediamtx.sh | test_install_mediamtx.bats | 66 | 70% |
| lyrebird-mic-check.sh | test_lyrebird_mic_check.bats | 45 | 70% |
| lyrebird-stream-manager.sh vs. MediaMTX versions | test_mediamtx_config_versions.bats, test_mediamtx_live.bats | 4 + 1 live | not estimated |
| tools/soak/lyrebird-soak.sh | test_soak.bats, test_soak_live.bats | 31 + 1 live | not estimated |
| tools/soak/lyrebird-soak-observer.sh | test_soak_observer.bats | 9 (2 live) | not estimated |

**Total: 664 tests (`bats --count tests/`); the 4 marked live are skipped unless `LYREBIRD_TEST_MEDIAMTX_BINS` is set (see below).** Coverage percentages above are estimates, not measured. `test_suite_can_fail.bats` checks that every test file reports a failing assertion, so a file whose `setup()` disables bats' error handling fails the suite (`docs/ENGINEERING-REVIEW-2026-07.md` §9, U9).

## Prerequisites

Install Bats:

```bash
# Ubuntu/Debian
sudo apt-get install bats

# macOS
brew install bats-core

# Or install from source
git clone https://github.com/bats-core/bats-core.git
cd bats-core
sudo ./install.sh /usr/local
```

## Running Tests

**Run all tests:**
```bash
bats tests/
```

**Run all tests and check for leaked temp files (what CI runs):**
```bash
tests/check_tmp_leaks.sh
```

**Run the live tests against real MediaMTX releases** (downloads checksum-pinned
1.15.0, 1.18.0, 1.19.0 and 1.21.1 for linux amd64 into `.cache/mediamtx`; needs
ffmpeg, curl, jq and free ports 8554/9997; refuses to run while another
MediaMTX or RTSP ffmpeg is running):
```bash
LYREBIRD_TEST_MEDIAMTX_BINS="$(tests/fetch_mediamtx.sh)" \
    bats tests/test_mediamtx_live.bats tests/test_soak_live.bats tests/test_soak_observer.bats
```
Without `LYREBIRD_TEST_MEDIAMTX_BINS` those live tests are skipped.

**Run specific test file:**
```bash
bats tests/test_lyrebird_common.bats
bats tests/test_stream_manager.bats
bats tests/test_usb_audio_mapper.bats
bats tests/test_lyrebird_diagnostics.bats
bats tests/test_lyrebird_orchestrator.bats
bats tests/test_lyrebird_alerts.bats
bats tests/test_lyrebird_metrics.bats
bats tests/test_lyrebird_storage.bats
bats tests/test_lyrebird_updater.bats
bats tests/test_install_mediamtx.bats
bats tests/test_lyrebird_mic_check.bats
```

**Run with verbose output:**
```bash
bats --verbose-run tests/
```

**Run with TAP output (for CI):**
```bash
bats --tap tests/
```

**Run tests matching a pattern:**
```bash
bats tests/ --filter "validation"
```

## Test Files

| File | Description |
|------|-------------|
| `test_lyrebird_common.bats` | Tests for shared library functions (hashing, timestamps, exit codes, progress indicators, error helpers) |
| `test_stream_manager.bats` | Tests for stream manager (sanitization, PID, locks, heartbeat, network) |
| `test_usb_audio_mapper.bats` | USB audio mapper: rule generation and safety, name/port validation, sysfs discovery, every CLI path, migration, locking, interactive mode (real script against a fake sysfs; same tests as the standalone usb-audio-mapper repository, which also has the QEMU end-to-end suite) |
| `test_lyrebird_diagnostics.bats` | Tests for diagnostic utilities (validation, port, disk, logs, system resources) |
| `test_lyrebird_orchestrator.bats` | Tests for menu validation, version comparison, status display, service status, time formatting |
| `test_lyrebird_alerts.bats` | Tests for webhook alerting (formatters, rate limiting, alert types) |
| `test_lyrebird_metrics.bats` | Tests for Prometheus metrics export (collectors, formatting) |
| `test_lyrebird_storage.bats` | Tests for storage management (cleanup, retention, disk usage) |
| `test_lyrebird_updater.bats` | Tests for update system (git operations, transactions, service detection, backups) |
| `test_install_mediamtx.bats` | Tests for MediaMTX installer (version comparison, platform detection, validation) |
| `test_lyrebird_mic_check.bats` | Tests for mic check utility (device detection, capability testing, config generation) |
| `test_storage_suite_safety.bats` | Guards `test_lyrebird_storage.bats` itself: its setup must point the storage script at private temp dirs, never at real recordings, logs or `/tmp` |

## Test Categories

### Unit Tests (Current)
- Input validation and sanitization
- Version comparison logic
- PID and device parsing
- Configuration defaults
- Lock file handling
- Heartbeat/watchdog mechanisms
- Network connectivity checks
- Disk space monitoring
- Git operations and transactions
- Service detection and management
- Audio device capabilities
- Webhook formatting and rate limiting
- Metrics collection and formatting
- Storage cleanup and retention
- Progress indicators and error helpers

### Integration Tests (Future)
- Stream lifecycle tests with mock devices
- USB hot-plug simulation
- API interaction tests
- Error recovery scenarios

## Writing New Tests

```bash
#!/usr/bin/env bats

setup() {
    # Runs before each test
    TEST_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
    PROJECT_ROOT="$( cd "$TEST_DIR/.." && pwd )"
    source "$PROJECT_ROOT/lyrebird-common.sh"

    # Create temp directory
    export TEST_TMP=$(mktemp -d)
}

teardown() {
    # Runs after each test (cleanup)
    rm -rf "$TEST_TMP"
}

@test "description of what is being tested" {
    run some_function "arg1" "arg2"
    [ "$status" -eq 0 ]
    [ "$output" = "expected output" ]
}

@test "validation rejects invalid input" {
    run validate_input "invalid"
    [ "$status" -eq 1 ]
}
```

## CI Integration

Tests are automatically run in the GitHub Actions CI pipeline:
- On every push to main branch
- On every pull request
- Daily scheduled runs

See `.github/workflows/bash-ci.yml` for configuration.

## Test Isolation

Tests are designed to be isolated and **do not require**:
- Running MediaMTX server
- USB audio devices connected
- Root privileges (for most tests)
- Network access

Functions are extracted and tested independently to ensure unit test isolation.

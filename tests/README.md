# LyreBirdAudio Test Suite

Unit tests for LyreBirdAudio using the [Bats](https://github.com/bats-core/bats-core) testing framework.

## Test Coverage Summary

| Component | Test File | Tests | Est. Coverage |
|-----------|-----------|-------|---------------|
| lyrebird-common.sh | test_lyrebird_common.bats | 13 | 65% |
| mediamtx-stream-manager.sh | test_stream_manager.bats | 32 | 50% |
| usb-audio-mapper.sh | test_usb_audio_mapper.bats | 15 | 45% |
| lyrebird-diagnostics.sh | test_lyrebird_diagnostics.bats | 16 | 40% |
| lyrebird-orchestrator.sh | test_lyrebird_orchestrator.bats | 14 | 35% |

**Total: ~90 tests covering approximately 50% of critical paths**

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

**Run specific test file:**
```bash
bats tests/test_lyrebird_common.bats
bats tests/test_stream_manager.bats
bats tests/test_usb_audio_mapper.bats
bats tests/test_lyrebird_diagnostics.bats
bats tests/test_lyrebird_orchestrator.bats
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
| `test_lyrebird_common.bats` | Tests for shared library functions (hashing, timestamps, exit codes) |
| `test_stream_manager.bats` | Tests for stream manager (sanitization, PID, locks, heartbeat, network) |
| `test_usb_audio_mapper.bats` | Tests for USB device detection, sanitization, udev rules |
| `test_lyrebird_diagnostics.bats` | Tests for diagnostic utilities (validation, port, disk, logs) |
| `test_lyrebird_orchestrator.bats` | Tests for menu validation, version comparison, status display |

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

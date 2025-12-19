# LyreBirdAudio Tests

Unit tests for LyreBirdAudio using the [Bats](https://github.com/bats-core/bats-core) testing framework.

## Prerequisites

Install Bats:

```bash
# Ubuntu/Debian
sudo apt-get install bats

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
```

**Run with verbose output:**
```bash
bats --verbose-run tests/
```

**Run with TAP output (for CI):**
```bash
bats --tap tests/
```

## Test Files

| File | Description |
|------|-------------|
| `test_lyrebird_common.bats` | Tests for shared library functions (hashing, timestamps, exit codes) |
| `test_stream_manager.bats` | Tests for stream manager functions (sanitization, PID validation) |

## Writing New Tests

```bash
#!/usr/bin/env bats

setup() {
    # Runs before each test
    source "../lyrebird-common.sh"
}

teardown() {
    # Runs after each test (cleanup)
}

@test "description of what is being tested" {
    run some_function "arg1" "arg2"
    [ "$status" -eq 0 ]
    [ "$output" = "expected output" ]
}
```

## CI Integration

Tests are automatically run in the GitHub Actions CI pipeline. See `.github/workflows/bash-ci.yml`.

## Coverage

Current test coverage focuses on:
- Core utility functions (lyrebird-common.sh)
- Input validation and sanitization
- Version comparison logic
- PID and device parsing
- Configuration defaults

Future additions planned:
- Integration tests with mock devices
- Stream lifecycle tests
- Error recovery tests

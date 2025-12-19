# Contributing to LyreBirdAudio

Thank you for your interest in contributing to LyreBirdAudio! This document provides guidelines and instructions for contributing.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Getting Started](#getting-started)
- [Development Setup](#development-setup)
- [Coding Standards](#coding-standards)
- [Testing](#testing)
- [Submitting Changes](#submitting-changes)
- [Reporting Bugs](#reporting-bugs)
- [Requesting Features](#requesting-features)

## Code of Conduct

This project follows a simple code of conduct:

- Be respectful and inclusive
- Focus on constructive feedback
- Help others learn and grow
- Keep discussions on-topic

## Getting Started

### Prerequisites

- Bash 4.0+ (check with `bash --version`)
- Git 2.0+
- ShellCheck (for linting)
- BATS (for testing, optional)

### Fork and Clone

1. Fork the repository on GitHub
2. Clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/LyreBirdAudio.git
   cd LyreBirdAudio
   ```
3. Add upstream remote:
   ```bash
   git remote add upstream https://github.com/tomtom215/LyreBirdAudio.git
   ```

## Development Setup

### Install Development Dependencies

```bash
# Ubuntu/Debian
sudo apt-get install shellcheck

# For running tests
sudo apt-get install bats

# macOS
brew install shellcheck bats-core
```

### Verify Setup

```bash
# Check all scripts pass syntax validation
for script in *.sh; do
    bash -n "$script" && echo "[OK] $script"
done

# Run ShellCheck on all scripts
shellcheck *.sh

# Run tests (if BATS is installed)
cd tests && bats *.bats
```

## Coding Standards

### Shell Script Style

LyreBirdAudio follows these conventions:

#### Header Format

Every script must have a standard header:

```bash
#!/bin/bash
# script-name.sh - Brief Description
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
#
# Author: Your Name (https://github.com/yourusername)
# Copyright: Tom F and LyreBirdAudio contributors
# License: Apache 2.0
#
# Version: X.Y.Z
#
# DESCRIPTION:
#   Detailed description of what the script does.
#
# USAGE:
#   ./script-name.sh [options]
```

#### Strict Mode

All scripts must use strict mode:

```bash
set -euo pipefail
```

#### Variable Naming

- **Constants**: `UPPERCASE_WITH_UNDERSCORES`
- **Local variables**: `lowercase_with_underscores`
- **Function-scoped**: Always use `local`

```bash
readonly SCRIPT_VERSION="1.0.0"

my_function() {
    local input="$1"
    local result=""
    # ...
}
```

#### Quoting

- Always quote variables: `"${variable}"`
- Use single quotes for literals without variables: `'literal string'`
- Use double quotes when variables are needed: `"Hello ${name}"`

```bash
# Good
echo "${message}"
if [[ -z "${value}" ]]; then

# Bad
echo $message
if [ -z $value ]; then
```

#### Conditionals

- Use `[[ ]]` instead of `[ ]` for tests
- Use `(( ))` for arithmetic

```bash
# Good
if [[ -f "$file" ]]; then
if (( count > 10 )); then

# Bad
if [ -f "$file" ]; then
if [ "$count" -gt 10 ]; then
```

#### Functions

- Use descriptive names with underscores
- Document complex functions
- Return meaningful exit codes

```bash
# Calculate disk usage percentage
# Arguments:
#   $1 - Mount point path
# Returns:
#   0 on success, 1 on error
# Outputs:
#   Usage percentage to stdout
get_disk_usage() {
    local mount_point="$1"

    if [[ ! -d "$mount_point" ]]; then
        return 1
    fi

    df -P "$mount_point" | awk 'NR==2 {print $5}' | tr -d '%'
}
```

#### Error Handling

- Use meaningful error messages
- Include remediation steps when possible
- Log errors appropriately

```bash
if ! command -v ffmpeg &>/dev/null; then
    log_error "FFmpeg not found. Install with: sudo apt-get install ffmpeg"
    return 1
fi
```

#### Logging

LyreBirdAudio provides standardized logging through `lyrebird-common.sh`. Both patterns are acceptable:

```bash
# Wrapper functions (preferred for new code)
log_info "Starting service..."
log_warn "Configuration missing, using defaults"
log_error "Failed to connect"
log_debug "Variable value: ${value}"

# Direct log calls (also acceptable)
log INFO "Starting service..."
log WARN "Configuration missing"
```

The logging functions write to both stderr and a log file when available.

#### Variable Naming Prefixes

Configuration variables follow these prefix conventions:

- **`LYREBIRD_*`**: LyreBirdAudio-specific settings (alerts, storage, orchestrator)
- **`MEDIAMTX_*`**: MediaMTX-related settings (API, ports, paths)

```bash
# LyreBirdAudio settings
LYREBIRD_ALERT_ENABLED=true
LYREBIRD_RECORDING_DIR=/var/lib/recordings

# MediaMTX settings
MEDIAMTX_API_PORT=9997
MEDIAMTX_CONFIG_DIR=/etc/mediamtx
```

#### Comments

- Comment complex logic, not obvious code
- Use TODO for future work
- Explain regex patterns and complex commands
- Use section headers to organize code:

```bash
# ============================================================================
# Section Name
# ============================================================================

# Inline comment for complex logic
```

Example:

```bash
# Match USB device path format: /sys/devices/pci0000:00/0000:00:14.0/usb1/1-2/1-2.3
# Format: usb<bus>/<port>-<hub>/<port>-<hub>.<port>
readonly USB_PATH_PATTERN='^/sys/devices/.*/usb[0-9]+/[0-9]+-[0-9]+(/[0-9]+-[0-9]+(\.[0-9]+)*)*$'
```

### ShellCheck Compliance

All scripts must pass ShellCheck without errors:

```bash
shellcheck script.sh
```

If you must disable a warning, add a justification:

```bash
# shellcheck disable=SC2034  # Variable used by sourcing scripts
readonly LYREBIRD_COMMON_VERSION="1.0.0"
```

### Line Length

- Maximum 100 characters per line
- Break long commands with backslashes

```bash
curl --silent \
    --max-time 30 \
    --retry 3 \
    --header "Content-Type: application/json" \
    "$url"
```

## Testing

### Test Structure

Tests use [BATS](https://github.com/bats-core/bats-core) (Bash Automated Testing System):

```bash
#!/usr/bin/env bats

@test "function returns expected value" {
    source ../script.sh
    result=$(my_function "input")
    [[ "$result" == "expected" ]]
}

@test "function handles errors" {
    source ../script.sh
    run my_function "bad_input"
    [[ "$status" -ne 0 ]]
}
```

### Running Tests

```bash
cd tests
bats *.bats
```

### Test Coverage Goals

- Aim for 50%+ coverage of critical functions
- Test error conditions, not just happy paths
- Test edge cases (empty input, special characters, etc.)

### What to Test

1. **Input validation** - Empty strings, special characters, long inputs
2. **Error conditions** - Missing files, network failures, permission errors
3. **Edge cases** - Zero, negative numbers, boundary conditions
4. **Integration** - Script interactions when possible

## Submitting Changes

### Branch Naming

Use descriptive branch names:

```
feature/add-webhook-alerts
fix/usb-mapper-port-detection
docs/update-installation-guide
```

### Commit Messages

Write clear, descriptive commit messages:

```
Add webhook alerting system for remote monitoring

- Support Discord, Slack, ntfy.sh, and generic webhooks
- Implement rate limiting to prevent alert spam
- Add interactive setup wizard
- Pure bash implementation, no new dependencies

Fixes #42
```

Format:
- First line: Summary (50 chars or less)
- Blank line
- Body: Detailed explanation (wrap at 72 chars)
- Reference issues when applicable

### Pull Request Process

1. **Update your fork**:
   ```bash
   git fetch upstream
   git rebase upstream/main
   ```

2. **Create a branch**:
   ```bash
   git checkout -b feature/your-feature
   ```

3. **Make changes** following the coding standards

4. **Test your changes**:
   ```bash
   # Syntax check
   bash -n your-script.sh

   # Lint
   shellcheck your-script.sh

   # Run tests
   cd tests && bats *.bats
   ```

5. **Commit and push**:
   ```bash
   git add .
   git commit -m "Your descriptive message"
   git push origin feature/your-feature
   ```

6. **Create Pull Request** on GitHub with:
   - Clear description of changes
   - Reference to related issues
   - Test results or screenshots if applicable

### Review Process

- Maintainers will review within 1-2 weeks
- Address feedback promptly
- Be open to suggestions and changes
- PRs must pass CI checks before merge

## Reporting Bugs

### Before Reporting

1. Check existing issues to avoid duplicates
2. Try the latest version from `main` branch
3. Collect diagnostic information

### Bug Report Contents

Include the following in your bug report:

1. **System Information**:
   ```bash
   cat /etc/os-release
   uname -a
   bash --version
   ```

2. **Script Versions**:
   ```bash
   ./lyrebird-orchestrator.sh  # Check version in menu
   ```

3. **Diagnostic Output**:
   ```bash
   sudo ./lyrebird-diagnostics.sh full
   ```

4. **Relevant Logs** (last 50 lines):
   ```bash
   tail -50 /var/log/lyrebird-stream-manager.log
   ```

5. **Steps to Reproduce**:
   - What you did
   - What you expected
   - What actually happened

Use the bug report template when creating issues.

## Requesting Features

### Feature Request Contents

1. **Problem Statement**: What problem does this solve?
2. **Proposed Solution**: How would you like it to work?
3. **Alternatives Considered**: What other approaches did you consider?
4. **Additional Context**: Screenshots, examples, use cases

### Feature Priorities

Features are prioritized based on:
- Impact on core use case (24/7 wildlife monitoring)
- Number of users affected
- Implementation complexity
- Alignment with project goals

## Questions?

- Open a [Discussion](https://github.com/tomtom215/LyreBirdAudio/discussions) for questions
- Check [README.md](README.md) for documentation
- Review existing issues and PRs for context

Thank you for contributing to LyreBirdAudio!

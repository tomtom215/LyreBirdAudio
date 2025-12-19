# Architecture Decision Records (ADR)

This document records significant architectural decisions made during the development of LyreBirdAudio.

## ADR-001: Bash as Primary Implementation Language

**Date**: April 2025
**Status**: Accepted

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
**Status**: Accepted

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
**Status**: Accepted

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

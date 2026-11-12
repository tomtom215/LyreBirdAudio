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

- Bash (check with `bash --version`). Most scripts refuse to start below 4.0,
  but the test suite and CI have only run on Bash 5.2, so they cannot catch a
  script that needs a newer Bash than it checks for (ADR-001 in `docs/ADR.md`
  names one)
- Git 2.0+
- ShellCheck, shfmt and bashate, the linters CI runs (CI pins ShellCheck
  0.11.0, shfmt 3.13.1 and bashate 2.1.1; other versions can report
  differently)
- BATS, `jq` and `python3`, to run the tests (some tests also need `ffmpeg`,
  `curl`, `flock` and root; a test that cannot run on your machine skips)

The scripts and the test suite are for Linux: they read `/proc` and `/sys` and
use `flock`. Nothing in the repository runs them on macOS or BSD.

### Fork and Clone

1. Fork the repository on GitHub
2. Clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/LyreBirdAudio.git
   cd LyreBirdAudio
   ```
   Six of the scripts are committed without the executable bit, so run them as
   `bash script.sh` in a clone (the README's `chmod +x` shows up in `git status`
   as a mode change).
3. Add upstream remote:
   ```bash
   git remote add upstream https://github.com/tomtom215/LyreBirdAudio.git
   ```

## Development Setup

### Install Development Dependencies

```bash
# Ubuntu/Debian
sudo apt-get install shellcheck bats jq python3 ffmpeg curl
pip install bashate==2.1.1

# shfmt: a release binary from https://github.com/mvdan/sh/releases
# (CI uses v3.13.1; the packaged ShellCheck may be older than CI's 0.11.0)
```

### Verify Setup

Run the four gates CI runs on every `*.sh` file (the scripts, `tools/soak/` and
`tests/*.sh`; `.bats` and `.bash` files are not covered). Nothing is printed
for a script that passes them all:

```bash
find . -name '*.sh' -type f -not -path './.git/*' | sort | while IFS= read -r script; do
    bash -n "$script" || echo "[FAIL] bash -n $script"
    shellcheck --severity=warning --external-sources --shell=bash "$script" || echo "[FAIL] shellcheck $script"
    shfmt -d -i 4 -bn -ci "$script" || echo "[FAIL] shfmt $script"   # fix with: shfmt -w -i 4 -bn -ci "$script"
    bashate --ignore E001,E006,E040,E042,E043 "$script" || echo "[FAIL] bashate $script"
done
```

The bashate rules left out are E001 (trailing whitespace, which shfmt handles),
E006 (line length), E040 (syntax, which `bash -n` checks), and E042 and E043
(patterns that are valid Bash).

Then run the tests of the file you work on (the whole suite is slow; see
[Testing](#testing)):

```bash
bats --count tests/                      # how many tests there are
bats tests/test_lyrebird_common.bats     # one file
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
- Do not leave `TODO` comments in delivered code (none of the scripts has
  one); open an issue for future work
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

All scripts must pass ShellCheck at warning severity with no finding; this is
the gate CI enforces on every `*.sh` file (see [Verify Setup](#verify-setup)):

```bash
shellcheck --severity=warning --external-sources --shell=bash script.sh
```

If you must disable a warning, add a justification:

```bash
# shellcheck disable=SC2034  # Variable used by sourcing scripts
readonly LYREBIRD_COMMON_VERSION="1.0.0"
```

### Line Length

- Aim for at most 100 characters per line. No check enforces it (bashate's
  line-length rule E006 is ignored) and some existing lines are longer
- Break long commands with backslashes

```bash
curl --silent \
    --max-time 30 \
    --retry 3 \
    --header "Content-Type: application/json" \
    "$url"
```

## Testing

The suite lives in `tests/`; `tests/README.md` lists its files and what each
covers.

### Test Structure

Tests use [BATS](https://github.com/bats-core/bats-core) (Bash Automated Testing System):

```bash
#!/usr/bin/env bats
load bats_shell_state
load scratch_tmpdir

setup() {
    scratch_setup     # private TMPDIR for this test, removed in teardown
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    bats_save_shell_state
    source "$PROJECT_ROOT/script.sh"
    bats_restore_shell_state
}

teardown() {
    scratch_teardown
}

@test "function returns expected value" {
    run my_function "input"
    [ "$status" -eq 0 ]
    [ "$output" = "expected" ]
}
```

Rules that keep tests honest:

- Wrap any `source` of a script in `bats_save_shell_state` /
  `bats_restore_shell_state`. Scripts set their own traps and shell options;
  without the restore, a failing assertion in the middle of a test is ignored.
  `tests/test_suite_can_fail.bats` fails if any file loses this.
- Do not write `set +e` (or `set +euo pipefail`) in a test or its setup.
- End negated assertions with `|| false` (`! grep -q x file || false`); bash
  does not fail on a negated command in the middle of a test.
- To check an exit status, capture it as `local rc=0; cmd || rc=$?`;
  `cmd; rc=$?` aborts the test before `rc` is set.
- Create temp files with `mktemp` under `scratch_setup`, never in fixed paths.
  `tests/check_tmp_leaks.sh` (run by CI) fails if the suite leaves anything in
  `TMPDIR`.
- Never point a test at real system paths (`/var/lib/...`, `/var/log/...`):
  override the script's own path variables (for example `LYREBIRD_*_DIR`).
  The next section lists the ones that matter.
- Test the real code. Source the script (the main scripts run `main` only
  when executed, not when sourced) and call its real functions, or run the
  script. Do not define a function in the test file
  and test that: the copy passes while the script is broken. Tests that did
  this were converted to the real script or removed.
- Never weaken a test, an assertion or a gate to get green.
- End the name of a test with the ID of what it protects, in brackets
  (`[LB-05]`). `docs/remediation-status.json` names tests by their exact
  title, and `tests/test_remediation_status.bats` fails when an item marked
  fixed names a test that does not exist.
- A test that skips proves nothing. When a tool or a permission is missing
  (`ffmpeg`, `jq`, `setpriv`, `unshare`, root, `LYREBIRD_TEST_MEDIAMTX_BINS`)
  a test skips with a message instead of failing; read the `skip` lines of a
  run before you trust it.

### Running Tests

```bash
bats --count tests/                                         # how many tests there are
bats tests/test_lyrebird_storage.bats                       # one file
tests/check_tmp_leaks.sh                                    # the whole suite plus the leak check, as CI runs it
tests/check_tmp_leaks.sh tests/test_lyrebird_storage.bats   # arguments go to bats
```

The whole suite is slow, because it starts real processes and, with MediaMTX
binaries, real servers: run the files you changed and let CI run the rest.

`tests/check_tmp_leaks.sh` runs bats with a fresh `TMPDIR` and fails (exit 1)
if the run leaves anything in it. With `LYREBIRD_LEAK_CHECK_HOST=1` (CI sets
it) it also records, before and after the run, the paths a test could write by
mistake: `/var/log/lyrebird*` and `/var/log/mediamtx*`, `/var/lib/lyrebird`,
`/var/lib/mediamtx-ffmpeg`, `/run/lyrebird*`, `/run/mediamtx*`,
`/run/lock/mediamtx*`, `/etc/lyrebird`, `/etc/mediamtx`, `/etc/cron.d/mediamtx*`,
`/etc/systemd/system/mediamtx*`, `/etc/logrotate.d/*` and `/dev/shm/lyrebird*`,
the repository tree (except `.git`) and the current directory. Any difference
is printed as `created`, `removed` or `changed` and fails the run. Any value
other than `0` or `1` is refused (exit 2), and so is a machine that looks like
a LyreBirdAudio node (a `mediamtx` or `mediamtx-audio` unit is active, or a
`/etc/cron.d/mediamtx*` job exists), because the node's own writes would be
blamed on the suite: run it on CI or a disposable machine.

### Proving a Test

A regression test is finished when you have seen it fail for the right reason:

1. Write the test and make the fix.
2. Revert only the production change, run the test and watch it fail.
3. Restore the change and watch it pass.
4. Put "mutation check" and what you saw in the commit message.

A test that has never failed has not been shown to test anything. The same holds
for a test of documentation: run it against the old text.

### Fixtures and Helpers

- **`scratch_setup` and `scratch_teardown`** (`tests/scratch_tmpdir.bash`). Call
  `scratch_setup` first in `setup()` and `scratch_teardown` in `teardown()`. It
  sets `TMPDIR` and `TEST_SCRATCH` to a private directory, and points the paths
  the scripts write by default at it: `LYREBIRD_STATE_DIR`,
  `STREAM_MANAGER_LOG_FILE`, `DIAGNOSTIC_LOG_FILE`, `LYREBIRD_ALERT_LOG`,
  `LYREBIRD_ALERT_STATE_DIR`, and an empty `LYREBIRD_STORAGE_CONFIG` (no
  `storage.conf`). Without it, a test that sources a script and runs one of its
  functions writes the real `/var/log` or `/var/lib` of the machine. When a
  script gains a log or state variable whose default is under `/var`, `/run` or
  `/etc`, add it to `scratch_setup`: `tests/test_suite_hygiene.bats` sources the
  real scripts and fails if a name there is not the one a script reads.
- **Two log variables.** The manager's own log is `STREAM_MANAGER_LOG_FILE`;
  `MEDIAMTX_LOG_FILE` is only where MediaMTX's output goes. A test that sets
  `MEDIAMTX_LOG_FILE` must set `STREAM_MANAGER_LOG_FILE` too, or the manager
  writes `/var/log/lyrebird-stream-manager.log` of the machine; the hygiene test
  fails a file that sets the first and never mentions the second.
- **A fake ALSA tree.** The manager reads a card's capture PCMs from
  `ASOUND_PROC_ROOT` (default `/proc/asound`) and device nodes from
  `DEV_SND_ROOT` (default `/dev/snd`). A card that counts as a microphone needs
  a directory `ASOUND_PROC_ROOT/card<N>/pcm0c` and a file
  `DEV_SND_ROOT/pcmC<N>D0c` (`pcm<M>c` and `pcmC<N>D<M>c` for capture PCM `M`; a
  directory `pcm<M>p` is a playback PCM, and a card with no capture PCM is
  skipped as playback-only). Where `arecord` is installed the check also runs
  `arecord -l` and wants the card in its listing, so a test puts an `arecord`
  stand-in first on `PATH`. Only the capture checks and the generated wrappers
  use the two roots: `detect_audio_devices` and the control-node check
  (`/dev/snd/controlC<N>`) read the real `/proc/asound` and `/dev/snd`, so a
  test of `start`, `monitor` or `status` replaces those functions.
  `sd_setup` and `sd_fake_card` in `tests/stream_definition_helper.bash` build
  the tree, a card and the `arecord` stand-in, and `tests/manager_stage.bash`
  shows the replacements.
- **`tests/manager_stage.bash`**: a private, hardware-free installation of the
  real stream manager for tests of `start`, `stop`, `monitor` and `status`. The
  script, its wrappers, the lock, the PID files and the markers are real;
  the device tree, MediaMTX (a copy of bash that waits, and a `curl` shim that
  answers the API from files) and FFmpeg (a stub that "publishes" by keeping an
  API file) are stand-ins. Call `scratch_setup` and `stage_setup` in `setup()`,
  `stage_teardown` and `scratch_teardown` in `teardown()`; then `device_add NAME
  CARD`, `device_remove`, `device_add_playback`, `bad_card`, `stage 'CODE'` and
  `wait_until`.
- **`tests/process_decoys.bash`**: for code that finds or stops processes. Start
  real look-alike processes (copies of bash at a path the test chooses) with
  `decoy_setup`, run the real function, and check which decoys survived and
  which signals were sent. A guarded `kill` refuses any PID that is not a decoy,
  and `pkill`, `pgrep` and `systemctl` are shims, so nothing outside the test can
  be signalled. Call `decoy_teardown` in `teardown()`.
- **The orchestrator** reads its menus from the terminal and gives every
  delegated script `</dev/tty`, so its tests run it on a pseudo-terminal.
  `tests/orchestrator_helper.bash` (`orch_setup`) puts stand-ins for the six
  delegated scripts in place, steered by `STUB_RC_*` and `STUB_DOC_*`
  variables, and `tests/helpers/pty_run.py --step REGEX TEXT -- COMMAND`
  answers each prompt when it appears, without sleeps. These tests need
  `python3` and `jq`.
- **The updater tests** run real git repositories (`tests/updater_helper.bash`)
  and fault-injection shims in `tests/helpers/updater/bin`. A shim signals the
  outermost ancestor process whose command line names `lyrebird-updater.sh`, so
  do not start these tests from a command line that names that file itself
  (for example `bash -c 'bats tests/...; shellcheck lyrebird-updater.sh'`):
  the shell that runs it is the ancestor.
- Other helpers say what they do in their first lines:
  `tests/stream_definition_helper.bash` (the manager sourced in a child shell),
  `tests/storage_helper.bash`, `tests/installer_fixture.bash` (a local stand-in
  for GitHub's release downloads), `tests/soak_helper.bash` (a fake node),
  `tests/usb_audio_mapper_helper.bash` (a fake sysfs) and
  `tests/prom_validate.bash` (a Prometheus exposition validator).

### Live Tests Against Real MediaMTX

Tests marked live run a real MediaMTX binary and skip unless
`LYREBIRD_TEST_MEDIAMTX_BINS` names binaries (space-separated paths).
`tests/fetch_mediamtx.sh [CACHE_DIR] [VERSION...]` downloads checksum-pinned
Linux x86-64 releases (v1.15.0, v1.18.0, v1.19.0, v1.21.1, v1.21.2 and v1.21.3;
default cache `.cache/mediamtx`) and prints the paths; `latest` fetches the
newest upstream release, verified against that release's own checksum file:

```bash
LYREBIRD_TEST_MEDIAMTX_BINS="$(tests/fetch_mediamtx.sh)" \
    tests/check_tmp_leaks.sh tests/test_mediamtx_api_live.bats
```

The files with live tests are `test_mediamtx_live`, `test_mediamtx_config_live`,
`test_mediamtx_api_live`, `test_mediamtx_e2e_ports`, `test_install_mediamtx_live`,
`test_soak_live` and `test_soak_observer`, which CI runs once per pinned version,
`test_stream_names`, four of whose tests are live and which no CI job runs
with the variable set, and `test_docs_security`, whose live test loads every YAML
block of the security guide into each binary that has `--validate-conf` (also not
run by a CI job with the variable set).

The private-port rule: a new test must not bind a default port of MediaMTX or of
the metrics server (8554, 8000, 8001, 9997, 9998, 9100, 8890 to 8893) on the
machine it runs on. Allocate free ports with `mtx_ports_setup` from
`tests/mediamtx_live_helper.bash`, which also moves every other MediaMTX
listener to a spare port with MediaMTX's own `MTX_*` environment overrides, or
run in a private network namespace (`unshare --net --pid --fork --mount-proc`,
which needs root; the namespace tests skip where it is not permitted). Two files
still break the rule: `tests/test_soak_live.bats` and
`tests/test_soak_observer.bats` bind 8554 and 9997 on the host. The first also
kills the `ffmpeg` and MediaMTX processes it finds, so it skips while one is
running. Neither is for a node.

### What a Good Test Covers

No tool measures coverage here; this is the guide:

- Test error conditions, not just happy paths
- Test edge cases (empty input, special characters, etc.)

### What to Test

1. **Input validation** - Empty strings, special characters, long inputs
2. **Error conditions** - Missing files, network failures, permission errors
3. **Edge cases** - Zero, negative numbers, boundary conditions
4. **Integration** - Script interactions when possible

### What CI Runs, and What It Cannot Prove

`.github/workflows/bash-ci.yml` runs on every pull request and every push to
`main` or `master`, with no path filter; also weekly (Monday 04:23 UTC), on
demand, and for a release tag (`release.yml` calls it). All jobs run on
`ubuntu-latest`:

- **Discover Scripts**, **Workflow Lint (actionlint)**, which also runs
  ShellCheck over every `run:` step, **Bash Syntax Check**, **ShellCheck
  Analysis** (0.11.0, warning severity), **Format Check (shfmt)** (3.13.1) and
  **Style Check (bashate)** (2.1.1, with the rules left out above): the gates of
  [Verify Setup](#verify-setup), on every `*.sh` file.
- **Security Scan**: a pattern scan for risky constructs. It only warns; it
  never fails the run.
- **Bats Tests**: the whole suite through `tests/check_tmp_leaks.sh` with
  `LYREBIRD_LEAK_CHECK_HOST=1`. The live tests skip here, because the variable
  that names MediaMTX binaries is not set.
- **Live MediaMTX vX.Y.Z**: one job per pinned MediaMTX release, each running
  the seven live test files above against that release.
- **Live MediaMTX newest upstream (advisory, non-blocking)**: the same files
  against the newest upstream release, resolved at run time. Advisory: it cannot
  fail the run.
- **CI Summary**: passes only if every job above except the advisory one
  succeeded; a failed, cancelled or skipped job fails it. It is the one check to
  require before merging. Whether the repository's branch protection requires
  it is a setting of the GitHub repository that no file here shows.

Downloaded tools are checked against hashes pinned in the workflow, bashate is
installed from the hashes in `.github/ci/requirements.txt`, and every Action is
pinned to a commit. Dependabot proposes updates for the Actions and for
bashate; ShellCheck, shfmt, actionlint and the MediaMTX releases in
`tests/fetch_mediamtx.sh` are bumped by hand, each together with its hash.

CI cannot prove anything that needs real hardware (USB microphones, how a real
card lays out its PCMs, a real power cut), a real systemd manager (the units
are checked with `systemd-analyze verify` and a namespace emulation, never
started), ARM, macOS or BSD, a Bash older than the runner's, an FFmpeg other
than the runner's, an RTSP client on another host, or that GitHub runs the
workflows as designed (the suite lints them and runs their steps locally).
`docs/REMEDIATION-2026-11.md`, "Validation that cannot be done in CI", keeps the
list.

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
- For a fix: the reproducer, the mutation check (see
  [Proving a Test](#proving-a-test)) and which tests you ran

### Changelog and Releases

- Add a line under `## [Unreleased]` in `CHANGELOG.md` for every change a user
  of an existing node would notice, in plain language, with the register ID in
  brackets at the end of the line when the change has one.
  `docs/changelog.html` is a copy of the file: edit both.
  `tests/test_docs_release.bats` checks that they say the same words, that
  every ID cited is in `docs/remediation-status.json` and that the version table
  gives the version each script says.
- A release is a `vX.Y.Z` tag. `release.yml` runs the whole CI pipeline on the
  tagged commit, then publishes a release with a source tarball and
  `SHA256SUMS`. Its notes are the `## [X.Y.Z]` section of `CHANGELOG.md`, so
  before tagging rename `## [Unreleased]` to `## [X.Y.Z] - DATE` (without that
  section GitHub generates the notes) and update the version table.
  `sha256sum -c SHA256SUMS`, in the directory with the tarball, shows that a
  download is the published file; releases are not signed, so it does not show
  who published it.

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
   # The gates (see Verify Setup), at least for the scripts you changed
   bash -n your-script.sh
   shellcheck --severity=warning --external-sources --shell=bash your-script.sh
   shfmt -d -i 4 -bn -ci your-script.sh
   bashate --ignore E001,E006,E040,E042,E043 your-script.sh

   # The tests of what you changed (see Running Tests)
   bats tests/test_<script>.bats
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

- Maintainers review pull requests as time allows
- Address feedback promptly
- Be open to suggestions and changes
- PRs must pass the `CI Summary` check, which fails unless every CI job
  succeeded (see [What CI Runs](#what-ci-runs-and-what-it-cannot-prove))

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
   git describe --tags               # the release your checkout is based on
   bash lyrebird-orchestrator.sh --version
   bash lyrebird-stream-manager.sh help | head -n 1
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

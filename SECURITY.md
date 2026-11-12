# Security Policy

## Supported Versions

Security fixes are made on the `main` branch, and only there. There are no release
branches.

| What you run | Receives security fixes |
| ------------ | ----------------------- |
| The `main` branch | Yes |
| A release tag (`v1.1.0`, `v1.2.0`, `v1.3.0`; list them with `git tag`) | No. A tag is a snapshot and no fix is back-ported to it |
| A fork, or any other branch | No |

Read the second row with care: **the newest tag does not contain the fixes that make a
node safe by default.** `v1.3.0` still generates a MediaMTX configuration with the API and
metrics listening on every interface and has no ownership marker or authentication mode for
`mediamtx.yml`. Those changes are on `main` and in no tag. Check what you run with
`git describe --tags --always` in your checkout (or `lyrebird-updater.sh --status`); to see
whether a tag contains a given commit, use `git tag --contains <commit>`. In the updater's
menu, "Switch to Latest Stable Release" installs the newest tag, and "Switch to Development
Version" follows the repository's default branch, which is `main`.

The version numbers inside the scripts (the stream manager and the installer, for example)
are version numbers of those scripts. They are not release numbers and do not match the tags.

After any update, check what the node exposes: see the first sections of the
[Security Guide](docs/SECURITY-GUIDE.md).

## Reporting a Vulnerability

If you discover a security vulnerability in LyreBirdAudio, please report it responsibly.

### How to Report

1. **Do NOT** open a public GitHub issue for security vulnerabilities
2. Email security concerns to the maintainer (see GitHub profile)
3. Include as much detail as possible:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

### What to Expect

Reports go to the maintainer and are answered as time allows. This policy
promises no response time and no fix time. A report is treated as private. A fix is made on
`main` and described in [CHANGELOG.md](CHANGELOG.md).

Please keep the details private until a fix is on `main`.

## What the Code Does for Security

These are properties of the scripts in this repository, each checkable by reading them or
by running the test suite (`bats tests/`):

- **Downloads are checked.** `install_mediamtx.sh` compares the MediaMTX release tarball with
  the `checksums.sha256` file published in the same release. A mismatch is fatal, also with
  `--force`; `--force` skips the check only when the release publishes no checksum for the
  file. This detects a damaged or swapped download. It does not detect a compromised
  release, and no signature is checked. `update` never runs MediaMTX's own `--upgrade`,
  which applies no checksum.
- **Configuration is data, not code.** The device configuration is read by a parser that
  accepts `DEVICE_<NAME>_<SETTING>=value` lines and reports anything else (command
  substitution, backticks and bare commands included) with its line number, without running
  it. The alert settings file accepts only `LYREBIRD_*` names.
- **Names and values are checked before they reach a file.** Stream names are reduced to
  lower-case letters, digits, `_` and `-` (at most 64 characters) before they appear in
  the MediaMTX configuration, a wrapper script, a PID file name or a unit; ports must be
  integers from 1 to 65535; a value a systemd unit or a cron file cannot carry is refused.
- **Processes are signalled by identity.** The stream manager signals only PIDs it recorded
  itself, and only while the process start time still matches. The one broad kill is
  `force-stop --kill-all --yes`; without `--yes` that command only prints what it would kill.
- **Configuration is replaced safely.** The MediaMTX configuration is written to a temporary
  file in the same directory, flushed, and renamed; where MediaMTX can check a file
  (`--validate-conf`, 1.21.1 and later) a rejected rendering never replaces the working
  file; the previous file is kept as a backup.
- **Temporary files use `mktemp`**, and CI looks for fixed `/tmp` file names.
- **No credentials in the repository.** CI looks for password, key and token assignments in the
  scripts. Passwords and webhook URLs come from files and environment variables you control.
- **The defaults expose little but RTSP.** The API and metrics listen on `127.0.0.1`; SRT,
  MoQ, RTMP, HLS and WebRTC are off. RTSP itself is **open by default**: anyone who can reach
  port 8554 can listen and publish. Closing that is the operator's job; see the
  [Security Guide](docs/SECURITY-GUIDE.md).

This is not a sandbox. The stream manager and the installer run as root.

## What Is Not Covered

The checks above are limited to what the repository can run. Not covered:

- **Real hardware.** The tests use fake sysfs and ALSA trees and stand-in devices. No real
  USB microphone, sound driver, power cut or hardware watchdog was involved.
- **A real systemd manager.** Units are checked with `systemd-analyze verify`. Nothing in
  the tests runs under a live systemd: boot ordering, start limits, sandbox directives and
  `systemctl edit` overrides were not exercised.
- **Other platforms.** The tests run on Linux x86-64 (GitHub's `ubuntu-latest` runners in CI)
  with Bash 5.2. There is no ARM run, no Bash 4.x run, and no macOS or BSD run. MediaMTX is
  tested live at 1.15.0, 1.18.0, 1.19.0, 1.21.1, 1.21.2 and 1.21.3.
- **Signed releases and provenance.** There are none. Release tags are lightweight (unsigned)
  tags. The release workflow publishes a source archive and a `SHA256SUMS` file made in the
  same job; that detects corruption, not tampering, and there is no signature or build
  attestation.
- **Repository settings.** Branch protection, required reviews and who may push or tag are
  settings of the GitHub repository, not of the code. The maintainer sets them; this
  repository cannot show or enforce them.
- **Code scanning services and audits.** The security-related checks in CI are a pattern scan
  (`grep` for `eval`, `curl -k`, `chmod 777`, hard-coded secrets and fixed temp names),
  ShellCheck and the test suite, plus Dependabot for pinned CI dependencies. No fuzzing, no
  penetration test and no external audit were done.
- **The software you install with it.** MediaMTX, FFmpeg and the operating system have their
  own vulnerabilities and their own reporting channels.

## Hardening a Deployment

Do not rely on the defaults on a network you do not control. The
[Security Guide](docs/SECURITY-GUIDE.md) says what a node exposes, what each kind of attacker
can do with it, and how to close it (authentication, TLS, firewall, alert webhooks, file
permissions). Keep webhook URLs and password files out of version control and out of
shared chat.

## Acknowledgments

We appreciate security researchers who help keep LyreBirdAudio secure. Responsible disclosures
will be acknowledged in the changelog (with permission).

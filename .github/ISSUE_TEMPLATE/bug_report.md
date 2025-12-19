---
name: Bug Report
about: Report a bug or unexpected behavior
title: "[BUG] "
labels: bug
assignees: ''
---

## Bug Description

A clear and concise description of what the bug is.

## Environment

**System Information:**
- OS: [e.g., Ubuntu 22.04, Raspberry Pi OS Bookworm]
- Architecture: [e.g., x86_64, ARM64, ARMv7]
- Bash version: [run `bash --version`]

**LyreBirdAudio Version:**
- Branch/Tag: [e.g., main, v1.0.0]
- Commit: [run `git rev-parse --short HEAD`]

**Component Versions** (from orchestrator or script headers):
- lyrebird-orchestrator.sh:
- mediamtx-stream-manager.sh:
- Other affected scripts:

**Hardware:**
- Device: [e.g., Intel N100 Mini PC, Raspberry Pi 4]
- USB Microphones: [e.g., 3x Generic USB Mic, Blue Yeti]

## Steps to Reproduce

1. Run '...'
2. Select '...'
3. See error

## Expected Behavior

What you expected to happen.

## Actual Behavior

What actually happened.

## Error Messages

```
Paste any error messages here
```

## Logs

**Relevant log excerpts** (last 50 lines showing the error):

<details>
<summary>Stream Manager Log</summary>

```
sudo tail -50 /var/log/mediamtx-stream-manager.log
```

</details>

<details>
<summary>Orchestrator Log</summary>

```
sudo tail -50 /var/log/lyrebird-orchestrator.log
```

</details>

<details>
<summary>FFmpeg Device Logs</summary>

```
sudo tail -50 /var/log/lyrebird/*.log
```

</details>

## Diagnostics Output

Please run diagnostics and paste the output:

```bash
sudo ./lyrebird-diagnostics.sh full
```

<details>
<summary>Diagnostics Output</summary>

```
Paste diagnostics output here
```

</details>

## Additional Context

Add any other context about the problem here. Screenshots, configuration files, or anything else that might help.

## Checklist

- [ ] I have searched existing issues to ensure this is not a duplicate
- [ ] I have included the output of `lyrebird-diagnostics.sh full`
- [ ] I am using a tagged release or have noted my branch/commit
- [ ] I have included relevant log excerpts

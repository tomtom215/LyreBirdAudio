# Soak testing a LyreBirdAudio node

Unit tests and emulators cannot show that a node keeps streaming for months in
a field. A soak test can: run the real node, on its real hardware, for weeks,
break it on purpose at random times, and measure whether it comes back. This
directory has two tools for that:

| Tool | Runs on | Measures |
|---|---|---|
| `lyrebird-soak.sh` | the node (root, systemd) | device names, stream liveness, services, resources; injects faults and times recovery |
| `lyrebird-soak-observer.sh` | a second machine (Linux or macOS) | audio actually arriving over RTSP, including through power cuts; can cut the node's power |

Use both. The node harness sees causes (which device, which process); the
observer sees what a listener sees, including outages the node cannot record
because it was off.

**Use a test node.** Faults are real: processes are killed, devices
unplugged, the disk filled (the storage manager may then delete recordings),
the network dropped, the clock stepped, the node reset without unmounting.
Use expendable storage and the same hardware, microphones, hubs, power supply
and storage model as the field nodes.

## What counts as passing

`lyrebird-soak report` checks, for the whole run:

1. **Every injected fault was recovered from** within `SOAK_RECOVERY_DEADLINE`
   (default 360 s) after it ended, or `SOAK_REBOOT_DEADLINE` (300 s) after
   boot. Recovered means every check below is back to normal.
2. **No reboot happened that the harness did not cause.** A new boot ID with no
   reboot fault in progress means a crash, a watchdog reset or a power loss.
3. **Device names held.** For each name in the usb-audio-mapper rules, the
   sound card at that USB path (`ID_PATH`, or the port, for older rules) has
   that name, no other card has it, and `/dev/sound/by-id/<name>` points at the
   card. A wrong name seen in two consecutive samples fails; a single sample is
   allowed because a re-plugged card is renamed by udev a moment after it
   appears.
4. **No outage outside fault windows.** An outage is any sample with a problem:
   MediaMTX API down, a service inactive, a stream missing from MediaMTX
   (`stream-down`), a stream whose byte counter stopped for
   `SOAK_STALL_SAMPLES` samples (`stream-stalled`, e.g. a microphone that stops
   delivering while ffmpeg stays alive), or a name problem.
5. **No resource heads for exhaustion.** After 24 h of data, disk use, inode
   use and available memory are fitted with a straight line; running out within
   `SOAK_EXHAUSTION_DAYS` (30) fails. Growth of MediaMTX/ffmpeg memory, open
   files, the log directory and zombie processes is reported as a warning.

The observer's report fails on any gap in the audio longer than `--gap`
(5 s) that is not inside a power cut or a node fault window, and on any
stream whose audio is not back within `--boot-deadline` (300 s) of power-on.

Limits worth knowing:

- Recovery times are measured in whole samples (`SOAK_INTERVAL`, 10 s).
- Linear trend projection is a heuristic. A month of flat data is better
  evidence than any projection from a day.
- The observer's and the node's clocks must agree (NTP on both) for
  `--node-events` to explain gaps; `clock-jump` faults upset that by design.
- The harness reads `ID_PATH` from udev; names are checked against the mapper's
  rules, so a node mapped without usb-audio-mapper gets no name checks.
- `stream-stalled` relies on MediaMTX's byte counters. Audio that arrives but
  is silent (a muted or disconnected capsule) is not detected; LyreBirdAudio's
  own silence detection covers that.

## Install on the node

```bash
sudo install -d /usr/local/lib/lyrebird-soak
sudo install -m 755 tools/soak/lyrebird-soak.sh /usr/local/lib/lyrebird-soak/
sudo install -m 644 tools/soak/soak-report.awk /usr/local/lib/lyrebird-soak/
sudo ln -sf /usr/local/lib/lyrebird-soak/lyrebird-soak.sh /usr/local/bin/lyrebird-soak
sudo install -m 644 tools/soak/lyrebird-soak.service /etc/systemd/system/
sudo install -m 600 tools/soak/lyrebird-soak.conf.example /etc/lyrebird-soak.conf
sudo systemctl daemon-reload
```

Needs bash 4.2+, curl, jq, udevadm, pgrep, flock and systemd-run (all present
on a node with LyreBirdAudio installed); `ip`, `fallocate` and `uhubctl` only
for the faults that use them.

## Run

1. Bring the node up normally: devices mapped, streams live.
2. Record the baseline. It refuses an unhealthy node:

   ```bash
   sudo lyrebird-soak init
   ```

3. **First 24–48 h without faults.** This shows the node is stable when left
   alone, and gives the resource trends a clean start.

   ```bash
   sudo systemctl enable --now lyrebird-soak
   sudo lyrebird-soak status        # any time
   ```

4. Try each fault once by hand while watching, before scheduling them:

   ```bash
   sudo systemctl stop lyrebird-soak
   sudo lyrebird-soak fault kill-ffmpeg      # prints recovered/not_recovered
   sudo lyrebird-soak fault usb-replug
   sudo systemctl start lyrebird-soak
   ```

   `SOAK_DRY_RUN=1` prints what a fault would do without doing it.

5. Enable faults in `/etc/lyrebird-soak.conf` and restart the service. A
   reasonable profile for a 2–4 week run:

   ```
   SOAK_FAULTS=kill-ffmpeg,kill-mediamtx,kill-manager,restart-udev,udev-trigger,usb-replug,reboot,hard-reset
   SOAK_FAULT_MIN_GAP=3600
   SOAK_FAULT_MAX_GAP=14400
   ```

   A gap of 9000 s on average: about 10 faults a day, about 270 over four
   weeks. Add `disk-fill`,
   `net-down` and `clock-jump` once the basics pass.

6. Report at any time; the run continues:

   ```bash
   sudo lyrebird-soak report            # exit 0 = PASS, 1 = FAIL
   ```

`sudo lyrebird-soak restore` undoes any fault still in effect. Every fault with
a duration also schedules its own undo as a systemd timer *before* it starts,
so a dying harness cannot leave the node unplugged, offline, full or with the
wrong time. A reboot cancels those timers; the harness then runs the pending
undo itself when it starts again.

## Observer

On a second machine with ffmpeg. The observer is written for bash 3.2 (as
shipped with macOS) and tested with bash 3.2.57 and 5.2 on Linux; it has not
been run on macOS itself.

```bash
tools/soak/lyrebird-soak-observer.sh run --dir obs-run \
    rtsp://node.local:8554/mic_a rtsp://node.local:8554/mic_b
```

To include power cuts, give commands that switch the node's supply, for
example a smart plug or relay with an HTTP API:

```bash
tools/soak/lyrebird-soak-observer.sh run --dir obs-run \
    --power-off-cmd 'curl -fsS http://plug.local/relay/0?turn=off' \
    --power-on-cmd  'curl -fsS http://plug.local/relay/0?turn=on' \
    --power-every 21600 --power-off-for 30 \
    rtsp://node.local:8554/mic_a rtsp://node.local:8554/mic_b
```

That is about four cuts a day. Stop with Ctrl-C or `touch obs-run/stop`; power
is switched back on before the observer exits. Then:

```bash
tools/soak/lyrebird-soak-observer.sh report --dir obs-run \
    --node-events node-run/events.tsv     # copied from the node's SOAK_DIR
```

Each reader uses an RTSP socket timeout (`--timeout`, 5 s), so a connection
that dies without a reset, as in a power cut, is noticed and retried.

## Files

In `SOAK_DIR` (`/var/lib/lyrebird-soak`):

| File | Content |
|---|---|
| `baseline` | expected names (from the mapper rules), streams and services |
| `samples.tsv` | one row per sample; the header names the columns |
| `events.tsv` | init, harness start/stop, fault start/end, recovered, not_recovered, unexpected_reboot |
| `environment` | kernel, OS, board, udev, MediaMTX, ffmpeg and LyreBirdAudio versions; the settings |
| `state`, `streams.state`, `restore.d/` | harness state; pending fault undos |

Keep the whole directory with the report: it is the evidence.

## How these tools are tested

- `tests/test_soak.bats`: the harness against a fake node (fake `/sys`, `/proc`
  and `/dev`; stub udevadm, curl, systemctl, systemd-run). Covers the checks,
  every fault's bookkeeping, undo-before-fault ordering, the seeded schedule,
  expected and unexpected reboots, and the report under four awks.
- `tests/test_soak_live.bats`: the harness against real MediaMTX and ffmpeg: a
  frozen publisher is reported as stalled, then down; real `kill-ffmpeg` and
  `kill-mediamtx` faults are recovered and replaced processes are verified.
- `tests/test_soak_observer.bats`: observer reports on synthetic logs, and the
  reader against real MediaMTX, including a simulated power cut (MediaMTX
  frozen with SIGSTOP, so connections die without a reset).

The live tests run when `LYREBIRD_TEST_MEDIAMTX_BINS` names MediaMTX binaries:

```bash
LYREBIRD_TEST_MEDIAMTX_BINS="$(tests/fetch_mediamtx.sh)" \
    bats tests/test_soak_live.bats tests/test_soak_observer.bats
```

None of this replaces the soak run itself: the tests show the tools measure
correctly; only the run on your hardware shows the node holds up.

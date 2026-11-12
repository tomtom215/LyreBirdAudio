# Soak testing a LyreBirdAudio node

Unit tests and emulators cannot show that a node keeps streaming for months in
a field. A soak test can: run the real node, on its real hardware, for weeks,
break it on purpose at random times, and measure whether it comes back. This
directory has two tools for that:

| Tool | Runs on | Measures |
|---|---|---|
| `lyrebird-soak.sh` | the node (root, systemd) | device names, stream liveness, services, resources; injects faults and times recovery |
| `lyrebird-soak-observer.sh` | a second machine with ffmpeg (written without Bash 4 features; run only on Linux, with Bash 5.2) | audio actually arriving over RTSP, including through power cuts; can cut the node's power |

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
   reboot fault in progress means a crash, a power loss or, if you configured
   one, a hardware watchdog reset.
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
- `stream-stalled` relies on MediaMTX's byte counters, and the observer on the
  position of the stream. Audio that arrives but is silent (a muted or
  disconnected capsule) keeps both moving, so neither tool reports it. The
  stream manager's monitor looks for it, with limits of its own: see
  [Silence](#silence). The soak report does not read what the monitor logs.
- The harness reads MediaMTX's API at `SOAK_API_URL` (default
  `http://127.0.0.1:9997`): set it if the node uses another
  `MEDIAMTX_API_PORT`.

## Silence

The soak tools do not measure the level of the audio. The stream manager does,
in its monitor, which is the cron job `lyrebird-stream-manager.sh install`
writes (every 5 minutes):

- Each monitor run reads every published stream over RTSP from `127.0.0.1` for 3
  seconds (`AUDIO_LEVEL_SAMPLE_DURATION`) with FFmpeg's `volumedetect`, and no
  stream more often than every 240 seconds (`AUDIO_LEVEL_CHECK_INTERVAL`). It
  opens no sound card. `AUDIO_LEVEL_CHECK_ENABLED=false` turns it off.
- A probe is silent when its loudest sample is at or below -60 dB
  (`AUDIO_SILENCE_THRESHOLD_DB`). The first silent probe logs `Silence detected`;
  a later silent probe, once the silence has lasted 60 seconds
  (`AUDIO_SILENCE_WARN_DURATION`), logs `DEAD MIC` once for that episode. With
  the 5-minute cron job that is the second silent probe. A probe that cannot
  decide (the stream is not published, no samples arrived, the measurement
  failed) neither starts nor ends an episode, and a probe that hears sound ends
  it (`Audio recovered`).
- The only record is the manager's log, `/var/log/lyrebird-stream-manager.log`
  (`STREAM_MANAGER_LOG_FILE`). There is no metric and no alert type for it, and
  the soak report does not count it: after a run, look with
  `grep 'DEAD MIC' /var/log/lyrebird-stream-manager.log`.
- The settings are environment variables of the monitor process. Cron does not
  pass the unit's environment, so a non-default value must also be in
  `/etc/cron.d/mediamtx-monitor`. `lyrebird-stream-manager.sh install` does not
  carry the `AUDIO_*` settings into that file (it carries the ports, the bind
  addresses and a few others), and it rewrites the file, so add the lines again
  after every `install`.

What it does not catch:

- A capsule that idles louder than -60 dB. The threshold was checked against
  digital silence and an FFmpeg test tone, not against real microphones.
- Silence between two probes, or shorter than the time to the second probe.
- Silence on a stream behind read authentication: the probe reads anonymously,
  so MediaMTX refuses it, a failed probe is logged at every run, and it is never
  counted as silence.
- Anything on a node without that cron job, which includes a node set up only
  by the Quick Setup Wizard (the wizard does not run `install`).

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

`init` needs bash 4.2+, curl, jq, udevadm and pgrep; `run` also needs flock;
every fault with a duration needs systemd-run; `ip`, `fallocate` and `uhubctl`
are needed only by the faults that use them.

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

On a second machine with ffmpeg. The observer is written to avoid Bash 4 features
(a search of its script for them finds none), so that it can run under bash 3.2,
the bash macOS ships, and it uses portable commands: its report formats times with
GNU `date`, then with BSD `date`.

What was run: `tests/test_soak_observer.bats` runs it on Linux under the `bash`
on `PATH`. That is its report on synthetic logs always, and its reader against a
real MediaMTX, including a simulated power cut, when `LYREBIRD_TEST_MEDIAMTX_BINS`
is set. The test file can run the observer under a bash 3.2 binary you provide
(`LYREBIRD_TEST_BASH32=/path/to/bash`); CI does not set that variable, and no
bash 3.2 was run in this check. Not run: macOS and BSD, so neither the BSD `date`
branch nor bash 3.2 on a Mac has been seen to work.

The observer reads anonymously unless a URL carries credentials, and it records
every URL as given in `obs-run/streams` and `obs-run/observer.tsv`. That matters
when the node runs with `RTSP_AUTH_MODE=local-only-publish`, which refuses remote
readers that are not listed.

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

`report` exits 0 for PASS and 1 for FAIL, for example when a stream never
delivered audio. Each reader uses an RTSP socket timeout (`--timeout`, 5 s), so a
connection that dies without a reset, as in a power cut, is noticed and retried.

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

They bind 8554 and 9997 on the machine they run on, and `test_soak_live.bats` kills
the ffmpeg and MediaMTX processes it finds (it skips while one is running). Do not
run them on a node.

None of this replaces the soak run itself: the tests show the tools measure
correctly; only the run on your hardware shows the node holds up.

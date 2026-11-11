# Stream manager monitoring honesty and the unit template (for the documentation pass)

Findings LB-14, X-05, LB-15, LB-16, LB-11, LB-12, X-12 and the manager side of X-13;
decisions D6, D7, D8, D12. Code: `lyrebird-stream-manager.sh` ("Audio level signals"
section, `update_heartbeat`, `warn_removed_settings`, `reload_mediamtx`,
`create_systemd_service`), `config/mediamtx-audio.service`, `config/mediamtx.service`.
Tests: `tests/test_stream_manager_signals.bats` (new), `tests/signals_e2e.bash` (the
live driver, run by the last test of `tests/test_mediamtx_live.bats`), the files named
in the later sections.

Evidence labels: **R** = reproduced by running the real code, **S** = source read
only, **HW** = needs real hardware or a real systemd manager.

## Audio level signals (LB-14, X-05, D6)

### What was wrong (R)

`check_all_audio_levels` had no caller anywhere in the repository, so
`AUDIO_LEVEL_CHECK_ENABLED=true` (the default) did nothing and the only dead-mic
mechanism was the API `ready` flag, which sees "no publisher", not "publisher
connected but silent". Had it been wired as written, `check_audio_level` would have
opened `plughw:<card>,0` a second time next to the capture FFmpeg (second-open
behaviour needs hardware, HW), and `check_all_audio_levels` counted rc 2 ("check
failed", for example the device busy) as silence, so a probe that cannot open the
device would have reported every microphone silent.

### What the code does now (R, against real MediaMTX 1.15.0, 1.19.0 and 1.21.1)

- `probe_stream_level PATH [SECONDS]` reads `AUDIO_LEVEL_SAMPLE_DURATION` seconds
  (default 3) of the stream MediaMTX publishes: `timeout -k 2 <sample+grace> ffmpeg
  -nostdin -hide_banner -nostats -loglevel info -rtsp_transport tcp -i
  rtsp://127.0.0.1:<MEDIAMTX_RTSP_PORT or 8554>/PATH -t N -vn -af volumedetect -f null -`.
  No ALSA device is opened by any level-signal function (asserted statically and
  through the arguments the probe passes to ffmpeg).
- It prints one line, `<state> <max dB> <mean dB> [detail]`, and returns 0. States:

  | state | meaning | counted as silence |
  |-------|---------|--------------------|
  | `ok` | samples read, `max_volume` above the threshold | no (ends an episode) |
  | `silent` | samples read, `max_volume` at or below `AUDIO_SILENCE_THRESHOLD_DB` (default -60; digital silence measures -91.0) | **yes, the only one** |
  | `no_audio_data` | the stream opened, no samples came | no |
  | `unreachable` | the stream could not be opened (404 not published, connection refused, timeout) | no (the deep health probe's business) |
  | `probe_error` | the measurement failed: no `ffmpeg` or `timeout`, ffmpeg exited non-zero or printed nothing usable, or the server answered 401/403 | no |

  Measurements printed by an ffmpeg that exited non-zero are never believed. `-inf`
  and a decimal comma parse; of several volumedetect blocks (ffmpeg prints an empty
  `n_samples: 0` block when it rebuilds its filter graph) the last one counts.
- `monitor_signals` is the monitor's signals step (`main monitor`: after the resource
  check, before `monitor_streams`; it always returns 0 and never changes the
  monitor's exit status). It probes every stream that has a PID file in
  `FFMPEG_PID_DIR` naming a live process and that `probe_stream_ready` reports ready,
  at most once per stream per run, and skips a stream probed less than
  `AUDIO_LEVEL_CHECK_INTERVAL` seconds ago (default 240, so a 5-minute cron probes
  every run). `AUDIO_LEVEL_CHECK_ENABLED=false` turns the step off.
- The silence episode (the previous design's monotonic tracking, kept): the first
  `silent` probe logs `WARN Silence detected on <stream>: max volume X dB (threshold:
  T dB)` and starts an episode; when it has lasted `AUDIO_SILENCE_WARN_DURATION` (default
  60 s, measured between probes, so in practice the resolution is the monitor interval)
  one `ERROR DEAD MIC: <stream> has been silent for Ns (>Ms)` is logged **once per
  episode** (it used to be logged on every probe); the first `ok` probe logs `INFO
  Audio recovered on <stream> after Ns of silence` and ends the episode, and the next
  silence is a new episode with its own DEAD MIC. `unreachable`, `no_audio_data` and
  `probe_error` neither start, extend, end nor alert an episode.
- State: one line per stream, `<silence start|-> <alerted 0|1> <last probe|->`, in
  `SILENCE_STATE_DIR` (default `/run/lyrebird/silence`, `<stream>.state`), monotonic
  seconds from `/proc/uptime`. The old `/run/mediamtx-silence-<stream>` files were never
  reachable and are not read; delete any that exist.

### Documentation consequences

- `tools/soak/README.md` (the paragraph at about L62-63, "LyreBirdAudio's own silence
  detection covers that") becomes true with this change; say what it is: the monitor
  reads each published stream back for `AUDIO_LEVEL_SAMPLE_DURATION` seconds every
  `AUDIO_LEVEL_CHECK_INTERVAL` seconds and logs `DEAD MIC` once per silence episode.
  There is still no metric and no alert type for it (`lyrebird-alerts.sh` has no
  dead-mic alert): the log line in `LOG_FILE` is the signal.
- Configuration reference (new or changed): `AUDIO_LEVEL_CHECK_ENABLED` (default
  `true`, now real), `AUDIO_LEVEL_SAMPLE_DURATION` (3), `AUDIO_LEVEL_CHECK_INTERVAL`
  (240), `AUDIO_LEVEL_PROBE_GRACE` (10: seconds beyond the sample before the probe is
  killed), `AUDIO_SILENCE_THRESHOLD_DB` (-60, an integer, now compared with
  `max_volume` at or below), `AUDIO_SILENCE_WARN_DURATION` (60), `SILENCE_STATE_DIR`,
  and the RTSP port the probe uses, `MEDIAMTX_RTSP_PORT` (default 8554; the other
  worker's D15 change makes the rest of the manager follow it).
- Operators will notice: every monitor run now opens one short RTSP reader per
  published stream (visible in MediaMTX's log as a read session, and for a few seconds
  in the API's session counts and `lyrebird_api_rtsp_*` metrics). The default is `true`
  and it was documented as an existing feature, so nodes upgraded to this version start
  probing without a configuration change. A MediaMTX with **read authentication**
  configured by the operator answers the probe's anonymous read with 401: the probe
  reports `probe_error` (`the server wants credentials`) in the log on every run and
  never counts it as silence; there is no credential setting for the probe yet.
- Removed: `check_audio_level`, `check_all_audio_levels`. Their two tests
  (`tests/test_monotonic_timing.bats` "silence tracking does not fire a false DEAD MIC
  after a forward clock jump" and `tests/test_pipefail_aborts.bats` "check_audio_level
  survives ffmpeg exiting 0 with NO volumedetect output") were removed because they
  called the deleted function; the same two behaviours are covered, against the real
  new functions, by "silence tracking does not fire a false DEAD MIC after a forward
  wall-clock jump" and "probe_stream_level: ffmpeg exiting 0 with no report at all is
  probe_error ..." in `tests/test_stream_manager_signals.bats`.

### Not verified here (HW)

- The `-60 dB` default was chosen by the original authors and is only validated here
  for digital silence (-91.0 dB) and a -18 dB tone. A real muted or unplugged USB
  microphone may output dither or hum above -60 dB; whether a given capsule's "dead"
  level is at or below the threshold needs a real device (the threshold is a setting).
- The probe is a second reader of an RTSP stream that already exists; it opens no
  device, so the second-open EBUSY question of the old design is moot. Capture
  behaviour under load (a probe every 5 minutes next to the capture FFmpeg) is
  unchanged by it.

## No watchdog claims, a heartbeat that says what it is (LB-15, X-13 manager side, D7)

### What was wrong (R, scratchpad monitoring/)

`HEARTBEAT_INTERVAL` and `HARDWARE_WATCHDOG_TIMEOUT` were never used.
`init_hardware_watchdog` (only reachable from `start`) tested `-c`/`-w` on the device,
logged "Hardware watchdog initialized" without ever opening it (strace: no `open`
of the device) and exported `HARDWARE_WATCHDOG_ACTIVE` in the short-lived launcher
process only, so `kick_hardware_watchdog`, called from `update_heartbeat` in the
cron `monitor` process, was unreachable; had it run it would have opened, written one
byte to and closed the device without the magic close character, which on a real driver
arms a reset. The `systemd-notify WATCHDOG=1` branch could never run (`NOTIFY_SOCKET` is
not set for the cron monitor, and the unit has no `WatchdogSec=` by design). The sample
unit's `LYREBIRD_WATCHDOG_ENABLED`/`LYREBIRD_WATCHDOG_INTERVAL` were read by nothing.
`update_heartbeat` is called only from `check_all_resources` (the monitor, every 5
minutes from cron), and it wrote the heartbeat while MediaMTX was down.

### What the code does now

- Removed: `HEARTBEAT_INTERVAL`, `HARDWARE_WATCHDOG_TIMEOUT`, `ENABLE_HARDWARE_WATCHDOG`,
  `HARDWARE_WATCHDOG_DEVICE`, `init_hardware_watchdog`, `kick_hardware_watchdog`, the
  `systemd-notify` branch, the call in `start`, the SIGUSR2 trap (it wrote the heartbeat
  outside a monitor run, so the file could not mean "last monitor run"), and the
  `LYREBIRD_WATCHDOG_*` lines of `config/mediamtx-audio.service`.
- If any of the six names (those four and `LYREBIRD_WATCHDOG_ENABLED`,
  `LYREBIRD_WATCHDOG_INTERVAL`, which units copied from the old sample still set) is
  present in the environment, even empty, every run of the script logs exactly one
  `WARN Ignoring removed setting(s): A, B. The manager has no watchdog: it never opened
  a watchdog device. For a hardware watchdog use systemd's RuntimeWatchdogSec= ...`
  line (`warn_removed_settings`, called once from `main`).
- The heartbeat stays and is exactly "the last monitor run": `update_heartbeat` writes
  one line, the Unix time, atomically (`HEARTBEAT_FILE.tmp` then `mv`) to
  `HEARTBEAT_FILE` (default `/run/mediamtx-audio.heartbeat`), once per `monitor` run
  (`check_all_resources`), whatever state MediaMTX is in. A write that fails logs
  `WARN Cannot write the monitor heartbeat <file>` (it used to be silent) and does not
  fail the run. `lyrebird-metrics.sh` (threshold `LYREBIRD_HEARTBEAT_MAX_AGE`, 900 s) sees
  the file the real manager writes as healthy and one older than that as unhealthy
  (tested end to end).

### Documentation consequences

- `README.md` L1481 ("systemd service for stream manager (with watchdog)"),
  `docs/configuration.html` L139, `docs/index.html` L57, `docs/usage.html` L216
  ("Enables systemd watchdog integration"), `CHANGELOG.md` L310/L335 (history, keep):
  say what exists. The unit has **no** `WatchdogSec=` (the manager sends no sd_notify
  keep-alives: a `WatchdogSec=` would kill the service every interval). Recovery is
  `Restart=`, the cron monitor (exit 2 restarts the service) and, for a hardware watchdog,
  systemd's own `RuntimeWatchdogSec=` in `/etc/systemd/system.conf` (resets the machine
  if PID 1 stops responding; Raspberry Pi: needs the `bcm2835_wdt` driver and
  `RuntimeWatchdogSec=` set) or a watchdog daemon. None of that is implemented or
  validated by this project.
- The heartbeat file: Unix time of the last monitor run, nothing else. It proves the
  cron monitor ran; it does not prove MediaMTX or any stream is up (`lyrebird_stream_up`,
  `lyrebird_api_up` do).
- Settings removed from the configuration reference, if listed: `HEARTBEAT_INTERVAL`,
  `HARDWARE_WATCHDOG_TIMEOUT`, `ENABLE_HARDWARE_WATCHDOG`, `HARDWARE_WATCHDOG_DEVICE`.
  `tests/README.md`: the heartbeat/watchdog line under "Unit Tests (Current)" should say
  heartbeat only.

### Tests

`tests/test_stream_manager_removed_features.bats` (10): the settings and functions are
gone; no executable line mentions a watchdog device, the notify socket or SIGUSR2; one
warning per run naming every set variable and `RuntimeWatchdogSec=`, none when unset;
with the old settings set and a FIFO as the "device" nothing opens it (the old
`kick_hardware_watchdog` writes to it); `update_heartbeat` content and mtime semantics;
one heartbeat write per `monitor` run, also with MediaMTX down; metrics reads it as
healthy. `tests/test_config_files.bats` "no shipped unit sets or mentions the
LYREBIRD_WATCHDOG_* variables". Two tests in `tests/test_stream_manager.bats` changed:
"default values are set for timeouts" lost its `HEARTBEAT_INTERVAL` assertion (the
setting is gone) and the inline-copy "heartbeat file update writes timestamp" (it
re-defined `update_heartbeat` in the test and tested the copy) is replaced by the real
`update_heartbeat` tests above.

### Not validated (HW)

Real hardware watchdog drivers (nothing opens a device any more; configuring
`RuntimeWatchdogSec=` on a given board is the operator's and was not tested here).

# Stream manager monitoring honesty and the unit template (for the documentation pass)

Findings LB-14, X-05, LB-15, LB-16, LB-11, LB-12, X-12 and the manager side of X-13 (plus
the cron stream-mode defect handed over by the stream-definition work); decisions D6, D7,
D8, D12. Code: `lyrebird-stream-manager.sh` ("Audio level signals" section,
`update_heartbeat`, `warn_removed_settings`, `reload_mediamtx`, "systemd unit and monitor
cron job" section: `render_systemd_unit`, `render_monitor_cron`, `create_systemd_service`),
`config/mediamtx-audio.service`, `config/mediamtx.service`, one line of
`lyrebird-updater.sh`. Tests: `tests/test_stream_manager_signals.bats`,
`tests/test_stream_manager_removed_features.bats`, `tests/test_stream_manager_reload.bats`,
`tests/test_stream_manager_unit.bats` (all new), and the live drivers
`tests/signals_e2e.bash`, `tests/reload_e2e.bash`, `tests/unit_sandbox_e2e.bash`, run by
the last four tests of `tests/test_mediamtx_live.bats`.

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

## Recording is RAM-only unless AUDIO_RECORDING_PATH says otherwise (LB-16, D8)

### What was wrong (S, confirmed by reading every use)

`AUDIO_DISK_PERSIST` (comment: "Move segments to disk (SD card wear!)") only made
`setup_directories` run `mkdir -p` and `chmod 755` on `AUDIO_DISK_PATH` (default
`/var/lib/mediamtx-ffmpeg/recordings`) when `AUDIO_LOCAL_RECORDING=true`. Neither
variable reached a wrapper; the segments always went to `AUDIO_RECORDING_PATH`
(default `/dev/shm/lyrebird-buffer`, tmpfs). Both defaulted to false/unused, so the
only promise of persistence was the code comment.

### What the code does now

- `AUDIO_DISK_PERSIST` and `AUDIO_DISK_PATH` are not read by any code and the
  directory creation is gone. If either name is present in the environment (even
  empty) every run logs one `WARN Ignoring removed setting(s): ...` line saying
  nothing is moved to disk, that recording is RAM-only by default and that durable
  recording means pointing `AUDIO_RECORDING_PATH` at persistent storage (the same
  function and the same once-per-run rule as the watchdog settings; the two groups
  warn separately, so both set means two lines).
- Unchanged: with `AUDIO_LOCAL_RECORDING=true` the wrapper's FFmpeg writes a ring of
  `AUDIO_RECORDING_SEGMENTS` (default 12) segments of `AUDIO_RECORDING_SEGMENT_TIME`
  seconds (default 300) per stream to `AUDIO_RECORDING_PATH/<stream>/audio_%03d.<codec>`.

### Documentation consequences

- Say plainly: the default recording is **RAM-only** (tmpfs): it is lost at reboot and
  power loss, and it holds the last `AUDIO_RECORDING_SEGMENTS x AUDIO_RECORDING_SEGMENT_TIME`
  seconds (one hour by default) per stream, nothing more (see
  `docs/remediation/notes/storage.md`: the ring overwrites in place, retention days do
  not govern it). To keep recordings across a reboot set `AUDIO_RECORDING_PATH` to a
  directory on persistent storage (and, for the storage script's emergency clear and
  retention, the matching `LYREBIRD_BUFFER_DIR` / `LYREBIRD_RECORDING_DIR`). Remove any
  mention of `AUDIO_DISK_PERSIST` / `AUDIO_DISK_PATH`; neither was in the README's
  configuration tables.
- **Slot order is not chronological across restarts** (reproduced with the same FFmpeg
  options the wrapper uses, `-f segment -segment_time 1 -segment_wrap 3`, scratchpad
  `monunits/ring.*`): the ring restarts at slot 000 every time FFmpeg is (re)started, and
  rewrites 000, 001, ... in place. After a 3.5 s run and a restart that ran 1.5 s the
  mtimes were `000` newest-but-one, `001` newest, `002` oldest (still from the first
  run). Anyone who plays the segments back must order them by modification time, not by
  slot number; after a wrapper restart the newest audio is at the low slots and the
  oldest is whatever the new run has not overwritten yet.

### Tests

`tests/test_stream_manager_removed_features.bats` (four more, 14 in all): no executable
line names the removed settings; `setup_directories` with
`AUDIO_LOCAL_RECORDING=true AUDIO_DISK_PERSIST=true` creates the recording directory
and never `AUDIO_DISK_PATH`; the warning (once, both names, where durable recording
goes; each group separately); the default path is tmpfs and the wrapper generators
write the segments to `AUDIO_RECORDING_PATH` and name no other recording path.

## The `reload` command and what MediaMTX does with a config change (LB-11, X-12 manager side, D12)

### What was wrong

`config/mediamtx-audio.service` had `ExecReload=<script> reload` and the script had no
`reload` command (`Unknown command`, exit 1: R). The signals the units sent instead were
not handled by MediaMTX (R, real 1.21.1, scratchpad `monunits/exp2.sh`): `SIGUSR1` and
`SIGUSR2` are ignored (the sample installer unit's `ExecReload=kill -USR1` does nothing),
and **`SIGHUP` terminates MediaMTX** (`Hangup`; the sample `mediamtx.service`'s
`ExecReload=kill -HUP $MAINPID` kills the server and, with `Restart=always`, restarts it:
an outage in the name of a reload). MediaMTX reloads its configuration by itself: it watches
the file and applies a change without restarting the process.

### The command (exact)

`lyrebird-stream-manager.sh reload` (root; `check_dependencies`, `setup_directories`,
`validate_config` first, then `reload_mediamtx`). It never stops, restarts or signals
anything. Steps: lifecycle lock (`acquire_lock`, re-entrant) -> refuse if another owner has
MediaMTX (exit **8**) -> MediaMTX not running (exit **7**, "use start") -> re-render the
configuration with the real generator; unchanged: say so; changed: log one `INFO` per
changed top-level key (`MediaMTX configuration key 'X' changed: <effect>`), wait one
second and for the API (`wait_for_mediamtx_ready`; if MediaMTX did not come back: error,
exit 1, "run restart"), `MediaMTX (PID n) is running with the new configuration; it was
not restarted` -> the idempotent start path (`start_mediamtx`: a stream whose wrapper runs
is not touched, a missing one is started); the exit status is the start path's. Exit
codes: 0, 1, 4 (configuration could not be generated or the device configuration is
invalid), 5 (lock), 7, 8 and whatever `start_mediamtx` returns. `SKIP_CLEANUP` is set for
the whole command: a failed reload must not leave `/run/mediamtx-audio.cleanup`, which
makes the wrappers stop at their next loop iteration. The CLI help lists it.

### What a changed key does (measured, R)

Measured on real MediaMTX 1.15.0 and 1.21.1 (scratchpad `monunits/exp3.sh`: identical
answers), and re-checked on every binary of `LYREBIRD_TEST_MEDIAMTX_BINS` by the live test; a bare FFmpeg
publisher per case, the file replaced atomically (`tests/reload_e2e.bash`, last section;
the table is `mediamtx_reload_effect`, and the live test fails if it lies):

| key | connected publishers |
|-----|----------------------|
| `api`, `apiAddress`, `rtmp`, `hls`, `webrtc`, `srt`; a path entry that is added | stay connected |
| `logLevel`, `readTimeout`, `writeTimeout`, `metrics`, `metricsAddress`, `rtsp`, `rtspAddress`, `rtspTransports` | **every publisher is disconnected** (their FFmpeg exits) |
| a path entry whose settings change (`sourceProtocol`) | the publishers of that path are disconnected |

No key the manager writes needs a restart of the MediaMTX process; `runOnInit` (not
generated) is the only setting MediaMTX applies only at start. **A configuration file
MediaMTX cannot load makes the running MediaMTX log the error and exit (status 0)** (R: a
broken file, and also `sourceOnDemand: yes` with `source: publisher`): that is why `reload`
only ever installs what the generator wrote, never an operator-supplied text.

### Documentation consequences

- `docs/` and README should describe `reload` as "apply a changed configuration without
  restarting MediaMTX or the healthy streams; changes to log level, timeouts, metrics, RTSP
  settings and path settings make MediaMTX disconnect the publishers, whose FFmpegs must
  reconnect (a gap per stream); `restart` is the heavy hammer". `systemctl reload
  mediamtx-audio` runs it. Exit 7 means "start it instead".
- Per-device audio settings (`DEVICE_<NAME>_*`) are baked into a running wrapper:
  `reload` does not apply them (a healthy stream is not restarted); `restart` does.
- Found while testing, **not fixed** (the wrapper-generation work owns it, and its X-10 test
  names it): in this tree a generated wrapper dies at the first FFmpeg exit (an unbound
  `MAX_RESTART_DELAY` / `INITIAL_RESTART_DELAY` under `set -u`: log line `FFmpeg exited with
  code 224 after 19 seconds` then `Wrapper cleanup initiated (exit code: 1)`), so a
  publisher dropped by MediaMTX is not reconnected by its wrapper here; `reload` (and
  `start`) then start the missing wrapper. The live test does not depend on either behaviour.
- The SIGHUP trap of the interactive manager process (`trap '... restart_mediamtx' HUP`,
  commented "reload configuration without full restart") still runs a full restart; with
  `reload` it could call `reload_mediamtx`. Left as is: out of scope, never active under
  systemd.

### Tests

`tests/test_stream_manager_reload.bats` (13: changed-key detection, the effect table,
every exit path, no stop/restart/signal on any path, the command and help) and the live
test `reload against a real MediaMTX ...` at the end of `tests/test_mediamtx_live.bats`
(driver `tests/reload_e2e.bash`: unchanged reload keeps every PID and the reader never
stalls; a publisher-safe change is applied with the reader alive; a `logLevel` change is
reported as disconnecting and both streams are ready again with MediaMTX's PID unchanged;
a dead wrapper is started and nothing else is touched; stopped -> 7; foreign MediaMTX ->
8 with nothing touched; the per-key matrix; the unloadable-file exit). About 100 s per
MediaMTX version.

## One unit template, rendered by `install` (LB-11, LB-12, X-12, D12) and the cron mode fix

### What was wrong

R = reproduced, S = read.

- (R) Sample unit: `ExecReload=... reload` (no such command), `ProtectSystem=strict` with
  `ReadWritePaths` lacking `/var/lib/mediamtx-ffmpeg`: `setup_directories` fails with
  `mkdir: cannot create directory '/var/lib/mediamtx-ffmpeg': Read-only file system` (the
  negative control of the live test reproduces exactly that on the real manager),
  `WorkingDirectory=/var/lib/lyrebird` created by nothing, no `TimeoutStartSec`, a
  `# User=mediamtx` hint that breaks the root-only manager, `Wants/After/PartOf=mediamtx.service`
  (D1 contradiction).
- (S) The unit `install` generated differed from the sample in a dozen directives (no
  mediamtx dependency, `Restart=on-failure`, `ProtectSystem=full`, `Group=audio`,
  `ExecReload=restart`, `TimeoutStartSec=300`, `Environment="INVOCATION_ID=systemd"`, the
  multiplex name written unquoted from an unquoted heredoc). `StartLimitInterval=` under
  `[Service]` is accepted by systemd 255 (verified, R); the finding is placement only.
- (R, from the stream-definition work, source read) The cron line `install` wrote ran
  `monitor` with no `STREAM_MODE`/`MULTIPLEX_*`: a cron monitor on a multiplex node ran in
  individual mode and started per-device streams next to the multiplexed one (reproduced
  here with the real `monitor_streams`, see the test below).

### What there is now

- **`config/mediamtx-audio.service` is the only template** and a complete valid unit with
  the manager's defaults (script at `/usr/local/bin`); copying it to `/etc/systemd/system/`
  by hand works for a default install. `lyrebird-stream-manager.sh install` (this script's
  own `create_systemd_service`) **renders** it (`render_systemd_unit`): the template header
  lists the only lines it rewrites: the three `Exec*=` lines (script path), `PIDFile=`,
  `StandardOutput=`/`StandardError=` (log file), `TimeoutStartSec=`, `TimeoutStopSec=`,
  `ReadWritePaths=` and the `STREAM_MODE`, `MULTIPLEX_FILTER_TYPE`, `MULTIPLEX_STREAM_NAME`
  `Environment=` lines. Everything else, comments included, is copied; with default
  settings the output is the template byte for byte except the script path (tested).
  The installer's later pass can reuse the template the same way. The template is looked
  up at `LYREBIRD_UNIT_TEMPLATE`, else `<script dir>/config/mediamtx-audio.service`; if it
  is missing `install` stops (exit 4) saying so: **`install` must be run from a checkout
  (or a directory that has `config/` beside the script)**, not from a bare copy of the
  script in `/usr/local/bin`. The updater runs `./lyrebird-stream-manager.sh install` from
  the checkout, so it is unaffected.
- `install` renders the unit and the cron file **before writing anything**; a value it
  cannot carry stops it with exit 4 and nothing is changed. Refused: `STREAM_MODE` other than
  `individual|multiplex`, `MULTIPLEX_FILTER_TYPE` other than `amix|amerge`, a script, PID file,
  log file or recorded directory path with characters outside `A-Za-z0-9_./+-` (a space used
  to produce a broken unit), a multiplex name with a control character (a newline would start
  a new directive), and for the cron file a multiplex name outside `A-Za-z0-9_-`. Environment
  values are escaped for systemd (`\`, `"` and `%` -> `\\`, `\"`, `%%`; tested by round trip
  and with `systemd-analyze verify`). The unit and the cron file are written atomically
  (temporary file in the same directory, `chmod 644`, rename); `systemctl daemon-reload` runs
  last. New environment variables: `LYREBIRD_UNIT_TEMPLATE`, `LYREBIRD_UNIT_MAX_STREAMS`
  (default 8: the stream count the timeouts are sized for) and `LYREBIRD_SYSROOT` (a prefix
  for `/etc/systemd/system`, `/etc/logrotate.d` and `/etc/cron.d`, with no daemon-reload: for
  packaging and tests; the updater's own is `LYREBIRD_UPDATER_SYSROOT`).
- After merging the stream-definition work, `render_systemd_unit` and `render_monitor_cron`
  should take the multiplex name from `resolve_multiplex_stream_name` (the canonical name) so
  the unit and the cron file carry the canonical form; today they carry what
  `MULTIPLEX_STREAM_NAME` holds, validated as above. One line each.

### The unit, directive by directive (retained or relaxed, with the reason)

| directive | value | why |
|-----------|-------|-----|
| `Conflicts=mediamtx.service` and `After=mediamtx.service` | new | D1: one owner. `Conflicts=` stops the standalone unit when this one starts; `After=` makes that stop finish first (the pattern display managers use with `getty@tty1.service`). No `Wants=`, `Requires=`, `BindsTo=`, `PartOf=` (tested). `config/mediamtx.service` gets `Conflicts=mediamtx-audio.service` (no `After=`: two `After=` would be an ordering cycle; `systemd-analyze verify` of both units together finds none). |
| `After=network.target sound.target alsa-restore.service`, `Wants=sound.target` | kept from both | `network-online.target` deliberately not used: the streams need no address and waiting for "online" delays the audio stack by the wait-online timeout on a node with no uplink. |
| `StartLimitIntervalSec=1200`, `StartLimitBurst=10` in `[Unit]` | the installed fleet's values (the sample said 300/5) | canonical placement (LB-12); 10 starts in 20 minutes tolerates a USB hub that arrives late. |
| `Type=forking`, `PIDFile=` | kept | `start` daemonizes; systemd follows MediaMTX's PID. Not changed to another type: no test shows a better one. |
| `ExecReload=<script> reload` | new | the real `reload`; no signal (MediaMTX 1.21.1 ignores USR1/USR2 and exits on HUP). |
| `Restart=always`, `RestartSec=30` | `always` from the sample, 30 s from the installed unit | a MediaMTX that exits with status 0 (it does when it cannot load its file) must be restarted; `on-failure` would leave it down. `RestartPreventExitStatus=SIGTERM SIGINT` (sample) dropped: a SIGTERM from outside must not leave an unattended node down. |
| `TimeoutStartSec=480`, `TimeoutStopSec=130` | derived, see below | the installed unit said 300/120, the sample nothing/30. |
| `User=root`, no `Group=`, no `# User=mediamtx` hint | root | the manager requires root; root needs no group for `/dev/snd`, and a `Group=audio` makes systemd refuse to start the unit (216/GROUP, S) on a system that has no such group. |
| `WorkingDirectory=/var/lib/lyrebird` + `StateDirectory=lyrebird mediamtx-ffmpeg` | new | systemd creates both directories (and makes them writable under `strict`) before the process starts: the missing working directory and the missing `/var/lib/mediamtx-ffmpeg` entry of LB-11. |
| `RuntimeDirectory=lyrebird`, `RuntimeDirectoryPreserve=yes` | new | `/run/lyrebird` holds the cron monitor's restart budgets, deep-health strikes and silence state; they must outlive a service restart (cleared at boot). |
| `ConfigurationDirectory=mediamtx`, `ReadWritePaths=/etc/mediamtx /var/log /run` | `/etc/mediamtx` and `/var/log` as before, `/run` kept | the config, `audio-devices.conf` and `.config.lock` in `/etc/mediamtx`; the two logs in `/var/log`; the PID file, lock, markers and heartbeat sit directly in `/run`, so all of `/run` is writable. `install` adds the directory of every configured path that differs from the defaults (and the recording directory when it is not under `/dev`, prefixed `-` so a USB disk that is not mounted yet loses the recording, not the streams). |
| `ProtectSystem=strict`, `NoNewPrivileges=yes`, `PrivateTmp=yes`, `ProtectKernelTunables=yes`, `ProtectKernelModules=yes`, `ProtectControlGroups=yes` | kept (the sample's set; the installed unit had `ProtectSystem=full`) | strictest the manager's audited writes allow (below). |
| `ProtectHome=read-only` | relaxed from the sample's `yes` | the script is often installed under `/home` or `/root`, which `yes` makes inaccessible. |
| `ProtectHostname`, `LockPersonality`, `RestrictSUIDSGID` | new | nothing in the manager or FFmpeg needs what they remove; unknown to older systemd they are ignored with a log line. |
| **not set**: `PrivateDevices`, `DevicePolicy`, `DeviceAllow`, `ProtectClock` | | USB audio and its hotplug need `/dev/snd` and new device nodes at any time; `ProtectClock=` implies a device policy. |
| **not set**: `PrivateNetwork`, `RestrictAddressFamilies`, `MemoryDenyWriteExecute`, `SystemCallFilter`, `CapabilityBoundingSet` | | RTSP and the API, `ping` for the network check, FFmpeg, and root signalling and raising limits. |
| **not set**: `MemoryMax=1G`, `MemoryHigh=800M` (sample only) | | the installed unit never had them; a cgroup OOM kill takes streams down at random; the manager watches its own processes (leaks restart through the monitor). |
| `Environment=LYREBIRD_UNDER_SYSTEMD=1`, no `INVOCATION_ID` | | systemd sets the real `INVOCATION_ID`; the faked word was never needed. `lyrebird_under_systemd` is true for either variable, so units from older versions keep working. |
| `Environment=USB_STABILIZATION_DELAY=10`, `HOME`, `PATH`, `STREAM_MODE`, `MULTIPLEX_*` | as the installed unit | |
| no `WatchdogSec=` | kept (CFG-2) | see the watchdog section. |

### `TimeoutStartSec=` and `TimeoutStopSec=`

`unit_start_timeout_seconds [STREAMS=8] [USB_DELAY=10]`, worst case of the manager's own start
(it is also the bound for `reload`, which is shorter), from the code's own timings:

```
lifecycle lock wait                  LOCK_ACQUISITION_TIMEOUT           30
cleanup, 5 s per recorded process    (streams + 1) x 5                  45
restart wait (restart path only)     RESTART_STABILIZATION_DELAY        15
USB wait (the unit's setting)        USB_STABILIZATION_DELAY            10
MediaMTX API wait                    MEDIAMTX_API_TIMEOUT               60
per stream: settle sleep + validation
  (STREAM_STARTUP_DELAY + 3)
  + STREAM_VALIDATION_ATTEMPTS x (STREAM_VALIDATION_DELAY + 2 s curl)
  = 13 + 3 x 7                                              34 x 8 =   272
                                                                 sum = 432
+ 10 %, rounded up to 10 s                                             480
```

`unit_stop_timeout_seconds [STREAMS=8]`: `STOP_LOCK_TIMEOUT` 5 + 10 s per wrapper (the
literal in `stop_ffmpeg_stream`) x 8 + 30 s for MediaMTX (the literal in `stop_mediamtx`) =
115, +10 % rounded up = 130. The template carries 480 and 130 (a test pins them to the
functions); `install` recomputes them from the configured timeouts and
`LYREBIRD_UNIT_MAX_STREAMS` (16 streams: 820 / 220). Another test pins the literals the
derivation depends on (5, 10, 30, the settle sleep, the validation attempts and the 2 s curl
timeout) to the code: if one of them changes the test fails and the formula must follow.
Caveat: the values are computed from the variables in effect in the shell that runs `install`;
the service itself runs with the defaults plus whatever the unit's `Environment=` sets.

### Every default write path is covered (R)

`tests/unit_sandbox_e2e.bash` runs the real manager with its **default** paths and the unit's
`Environment=` inside a network + mount namespace with overlays over `/etc /var /run /dev
/usr/local` (nothing reaches the host), real MediaMTX and FFmpeg: `setup_directories`, `start`,
`monitor` x3, `reload`, `restart`, `stop`, with local recording on. **Audit** mode lists every
file or directory the manager created or opened for writing (26 paths: `/etc/mediamtx/{mediamtx.yml,
audio-devices.conf,.config.lock}`, `/run/mediamtx-audio.{pid,pid.id,lock,heartbeat}`,
`/run/lyrebird/silence/<stream>.state`, `/var/log/{lyrebird-stream-manager.log,.log.lock,
mediamtx.out}`, `/var/lib/mediamtx-ffmpeg/{.mem_samples,<stream>.{sh,log,log.prev.1,pid,pid.id}}`,
`/dev/shm/lyrebird-buffer/<stream>/audio_000.opus`) and requires each to be inside the paths the
unit makes writable (`ReadWritePaths=`, `StateDirectory=`, `RuntimeDirectory=`, the private
`/tmp`; `/dev` is not read-only under `strict`). **Strict** mode emulates `ProtectSystem=strict`
(every mount except `/dev /proc /sys` made read-only, then only the declared paths opened
again) and requires the whole run to work and leave its files. The **negative control** runs the
same flow with the sample unit's directives (`ReadWritePaths=/var/log /var/lib/lyrebird
/etc/mediamtx /run`) and must fail with the `mkdir ... /var/lib/mediamtx-ffmpeg: Read-only
file system` of LB-11. Mutation checks: dropping `/var/log` from the unit (template and
generator) fails the audit ("the manager wrote /var/log, which the unit does not make
writable"). Not covered by a real run: other agents' later writes (`/run/lyrebird/status.json`,
config backups in `/etc/mediamtx`) are inside the same paths; a new default path outside them
fails the audit.

### The cron file

`install` now writes `STREAM_MODE`, `MULTIPLEX_FILTER_TYPE` and `MULTIPLEX_STREAM_NAME` next to
`CRON=1` in `/etc/cron.d/mediamtx-monitor` (cron `NAME=value` lines, so the values are limited
to what needs no quoting), so the cron `monitor` runs in the unit's stream mode. The job line
and its policy are unchanged (flock, `monitor`, exit status 2 restarts the service, other
non-zero statuses are only logged). The live behaviour is tested by rendering the file, taking
its environment lines, and running the real `monitor_streams` in that environment with only the
process spawns stood in for: a multiplex node starts the multiplexed stream and never a
per-device one; an individual node the reverse; the cron file as written before (no mode in
it) on the same multiplex node starts per-device streams (the control). Changing the mode
after install: run `install` again with `-m/-f/-n` (the help and the install output say so);
editing the unit with `systemctl edit` alone leaves the cron file in the old mode.

### Documentation consequences

- README ("Requires mediamtx.service to be running first", the sample unit's header comment)
  and any text that says the stream manager unit depends on `mediamtx.service`: it **conflicts**
  with it. `mediamtx.service` is for MediaMTX-only installs; the two cannot both run.
- README L1481 and the configuration table: the unit has no watchdog, `Restart=always`,
  start limit 10 per 20 minutes, `systemctl reload mediamtx-audio` applies a changed MediaMTX
  configuration without an outage (see the reload section), `systemctl edit` is for local
  overrides and `install` again for the stream mode.
- Installing by hand: `sudo cp config/mediamtx-audio.service /etc/systemd/system/` is still
  valid for a script at `/usr/local/bin`; otherwise run `install` from the checkout. The unit
  needs `/etc/mediamtx` (install MediaMTX first) or the `ConfigurationDirectory=` creates it.
- `docs/troubleshooting.html`/README: after `systemctl status` shows `status=226/NAMESPACE`,
  a path in `ReadWritePaths=` does not exist (the recording path is `-`-prefixed for that).

### Found while working, not fixed

- `lyrebird-updater.sh` listed `INVOCATION_ID=systemd` as a default variable of the unit; it
  now lists `LYREBIRD_UNDER_SYSTEMD=1` too (one line, tested against the real generated unit),
  otherwise every update would have restored it as a customization.
- The help text of `monitor` in `show_help` says `3=MediaMTX down, 7=no devices`; the code uses
  7 (MediaMTX down) and 6 (no devices). Not changed (the monitor/status work owns it).
- The `cleanup()` exit trap leaves `/run/mediamtx-audio.cleanup` after any failing command
  except `monitor`, `status` and `config`; that marker makes the wrappers stop at their next
  loop iteration. `install` and `reload` now set `SKIP_CLEANUP` (a failed `install` or
  `reload` changes no process, so there is nothing to clean up).

### Needs a real systemd manager (not validated here: PID 1 is not systemd)

`systemd-analyze verify` (systemd 255.4) parses the template and the rendered unit with the
real parser and finds nothing, and the namespace emulation shows the paths are sufficient, but
none of this ran under a real manager: (1) `StateDirectory=`/`ConfigurationDirectory=` creation
before the `ReadWritePaths=` namespace setup and their implied writable bind mounts under
`ProtectSystem=strict`; (2) `RuntimeDirectoryPreserve=yes`; (3) the `Conflicts=` + `After=`
transaction when both units are enabled at boot and when one is started over the other;
(4) `systemctl reload` of a `Type=forking` unit with the real `reload` (bounded by
`TimeoutStartSec`); (5) `ProtectHome=read-only` with the script under `/home`; (6) the start
limit and `Restart=always` timing at boot with a late USB hub; (7) every sandbox directive
against real ALSA/udev hotplug. A hardware watchdog (`RuntimeWatchdogSec=`) was not tried.

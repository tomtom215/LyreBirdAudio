# Changelog

All notable changes to LyreBirdAudio will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Everything since v1.3.0, the latest release (2026-07-19). The release that will
carry it has no number yet. The version of every script in this tree is in the
table at the end of this file; the "Component versions bumped" lines in the
blocks below record the step each block made.

### Audit remediation (2026-11)

An independent review of revision `5befe80` found defects in the stream
manager, the installer, the updater and the documentation, and checking them
found more. The IDs in brackets (`LB-` for the review's findings, `X-` for
those found while checking, `DOC-` for documentation) are the ones in
`docs/REMEDIATION-2026-11.md`, which also holds the design decisions D1 to D15.
`docs/remediation-status.json` names the tests that cover each item.

#### Security

- **The MediaMTX API and metrics endpoint listen on `127.0.0.1` by default.**
  In the configuration the stream manager and `install_mediamtx.sh` generated,
  they listened on every interface (ports 9997 and 9998). `MEDIAMTX_API_BIND`
  and `MEDIAMTX_METRICS_BIND` change the address; an empty value means every
  interface. MediaMTX's own default rules already refused API and metrics
  calls from other machines, so a working setup is not affected. [LB-06, LB-22]
- **Only RTSP is open to the network.** SRT, RTMP, HLS and WebRTC are off in
  every generated configuration, MoQ is off on MediaMTX 1.19.0 and later, and
  no setting turns any of them on. The installer's old configuration left SRT
  listening, and MoQ on 1.19.0 and later. With the generated configuration
  MediaMTX opens RTSP (every interface), the API and metrics (loopback) and
  the two UDP ports RTSP uses (8000 and 8001 by default), and nothing else;
  checked on MediaMTX 1.15.0, 1.18.0, 1.19.0, 1.21.1, 1.21.2 and 1.21.3.
  [LB-06]
- **RTSP is still open by default**: anyone who can reach port 8554 can
  publish to and read every stream, as before. The new
  `RTSP_AUTH_MODE=local-only-publish` closes it without editing the file: this
  machine needs no password, and every other client must be a user listed in
  `RTSP_USERS_FILE` and can only read. `lyrebird-stream-manager.sh help` shows
  the file format; `docs/SECURITY-GUIDE.md` covers authentication. [LB-06]
- **A `mediamtx.yml` you edited is no longer overwritten.** The manager
  regenerated the file on every start, so a password, bind address or file
  mode you set was lost. Only a file whose first line is
  `# Managed by LyreBirdAudio` is rewritten (after a backup); any other file is
  yours, is used as it is and is never written. [LB-22]
- **The device configuration is read as data and never run.**
  `/etc/mediamtx/audio-devices.conf` was loaded with `source`, so a line such
  as `exit 0` ended the manager and a `$(...)` ran as root. [LB-08, X-09]
- **Generated files cannot be injected.** Every value in a generated stream
  wrapper is quoted (a `"`, `$(...)`, backtick or trailing backslash in a
  setting used to run or break the wrapper), and a stream name can no longer
  add a YAML key (`runOnInit` ran as a command), a systemd directive or a cron
  line. [LB-09, X-10, X-11, LB-04]
- **`install_mediamtx.sh update` always checks the checksum.** It used to run
  MediaMTX's own `--upgrade`, which downloads the newest tag and replaces the
  binary without any checksum check. [X-41]
- **The metrics HTTP server listens on `127.0.0.1` by default.** It listened on
  every interface while its log said "localhost". It still has no
  authentication or TLS. [X-17]
- **`docs/SECURITY-GUIDE.md` Option 2 set the admin password to a literal
  string.** MediaMTX does not expand `${MEDIAMTX_ADMIN_PASSWORD}` in its YAML,
  so the password was that text (checked on MediaMTX 1.21.1: 200 for the
  literal string, 401 for the real value). If you followed that guide, change
  the password. [DOC-01]

#### Changed behaviour

**Start, stop and ownership**

- **`start` reports what happened.** Exit status 0 means the start policy is
  met, and 9 (new) that it is not. `LYREBIRD_START_POLICY=degraded` (the
  default) requires one stream to be publishing, `strict` requires the stream
  of every detected device; "publishing" is what MediaMTX's API reports, not
  that FFmpeg is running. Before, `start` printed `[FAIL]` lines and still
  exited 0. A failed start stops what that run started and leaves a stack that
  was already running alone. Under systemd, a node whose microphones all fail
  now has a failed start, which `Restart=always` retries. [LB-03]
- **`start` is safe to repeat.** With the manager's own MediaMTX running it
  changes nothing that works (same process IDs, no outage, configuration not
  rewritten) and starts only a stream whose wrapper is missing. Before, every
  start cleaned up and restarted everything. [LB-01]
- **One MediaMTX owner.** `mediamtx-audio.service` now conflicts with
  `mediamtx.service` (`Conflicts=`), and `start`, `restart` and `reload`
  refuse with exit 8 (new) and change nothing while `mediamtx.service` is
  active or a MediaMTX the manager did not start is running on its
  configuration. The old sample unit made the manager depend on
  `mediamtx.service` while the manager started its own MediaMTX on the same
  file and port. [LB-02]
- **No USB microphone is not a failed start.** `start` starts MediaMTX, reports
  `waiting_for_devices` and exits 0; it used to exit 6 without starting
  anything. `LYREBIRD_ALLOW_EMPTY_START=false` restores exit 6. The wait for USB
  devices to settle no longer counts an empty list as settled. The monitor
  starts the stream of each device that appears, restarts a multiplex stream
  when a device is added, and restarts a MediaMTX that is gone while the node
  is meant to run (`start` was run and `stop` was not), within
  `CRON_RESTART_MAX_PER_HOUR`. [LB-07, X-03]
- **Lifecycle commands never overlap, and no lock goes stale.** Locks are
  `flock`s on files that are never deleted or truncated; the kernel releases
  one when its holder dies, so `LOCK_STALE_THRESHOLD` is gone. `stop` and
  `force-stop` now refuse with exit 5 (nothing changed) when another lifecycle
  command still holds the lock after `STOP_LOCK_TIMEOUT` seconds (default 5);
  the monitor skips its cycle, exit 0, while one runs. The "Failed to acquire
  lock" message names the holder: do not delete lock files by hand. MediaMTX,
  the wrappers and FFmpeg no longer inherit the lock. [LB-05, X-02]
- **Processes are found by identity, never by name.** The manager signals only
  processes recorded in its own PID files (checked against the process start
  time) that are what it started. `stop` no longer kills other FFmpeg
  processes that read a stream, and `force-stop` kills only what this manager
  started. `force-stop --kill-all` prints what it would kill and exits 1;
  `force-stop --kill-all --yes` kills it: the only broad kill. The first
  signal is SIGTERM, then SIGKILL after the timeout. `stop` exits 1 when
  something could not be stopped. The installer stops MediaMTX through its
  owner (systemd or the manager) and, as a last resort, by executable path and
  configuration file. [LB-10]

**Health checks and monitoring**

- **Silence is measured on the published stream.** The monitor reads each
  published stream over RTSP for 3 seconds (`AUDIO_LEVEL_SAMPLE_DURATION`) at
  most every 240 seconds (`AUDIO_LEVEL_CHECK_INTERVAL`) and logs
  `DEAD MIC` once per silence episode, after 60 seconds
  (`AUDIO_SILENCE_WARN_DURATION`) at or below -60 dB
  (`AUDIO_SILENCE_THRESHOLD_DB`). `AUDIO_LEVEL_CHECK_ENABLED=true` was already
  the default, but nothing ever ran it. It does not open the sound card. It
  adds at most one short RTSP read session per stream and monitor run (visible
  in MediaMTX's log and API). There is no metric or alert for it: the log line
  is the signal. [LB-14, X-05]
- **The heartbeat says only what it is.** `/run/mediamtx-audio.heartbeat` holds
  the time of the last monitor run. `lyrebird_heartbeat_healthy` is 1 when the
  monitor ran within `LYREBIRD_HEARTBEAT_MAX_AGE` seconds (default 900); it was
  tied to 60 seconds although the monitor runs every 5 minutes. It proves
  that the monitor ran, not that any stream is up. [LB-15, X-13]
- **MediaMTX readiness is checked, not assumed.** Readiness, the API version
  and the per-stream probe check the HTTP status and the shape of the answer;
  any answer used to count. A 401 or 403 (an authenticated API) or an API that
  does not answer is "unknown" and never counts as a failed stream: before,
  such a stream was restarted after three monitor runs in a row. [LB-13]

**Configuration**

- **`mediamtx.yml` has an owner.** A file with the `# Managed by LyreBirdAudio`
  first line is rewritten only when its content changes, after a backup
  `mediamtx.yml.<UTC time>.<nn>.bak` (the newest `MEDIAMTX_CONFIG_BACKUPS`,
  default 5, are kept), written so that a power cut leaves the old or the new
  file. The manager and the installer render it with one generator. A file
  without the line is yours: `--regenerate-config start` (or `restart`) takes
  it over after a backup; to keep hand edits in a managed file, delete the
  first line. Where MediaMTX has `--validate-conf` (1.21.1 and later), the new
  file is checked by the binary before it replaces the old one. The file is
  written after the port check, not before. [LB-22, LB-23]
- **The file an earlier manager wrote is adopted.** A `mediamtx.yml` whose first
  line is `# MediaMTX Configuration - Audio Streams` is replaced by the current
  rendering at the first `start` or `reload` (after a backup), with a log line
  saying so. An edit you made to it by hand is in the backup only. The file the
  earlier installer wrote (first line a row of `#`) is not adopted: it is
  yours, and every start warns about it. [X-38]
- **The device configuration is checked, not trusted.** The file is read line by
  line against a list of keys: `DEVICE_<NAME>_<SETTING>=value`, `<SETTING>` one
  of `SAMPLE_RATE`, `CHANNELS`, `CODEC`, `BITRATE`, `THREAD_QUEUE` and `PCM`,
  with the values each accepts. A line that cannot be used is skipped, logged
  with its file, line and key, and its setting keeps the default; it no longer
  stops `start` (which exited 4 for a syntax error). The new
  `lyrebird-stream-manager.sh validate` checks the file (exit 4 when a line
  cannot be used). Keys in mixed case, which `lyrebird-mic-check.sh` used to
  write and which were ignored, are now read and so apply. Settings are no
  longer taken from `DEVICE_*` environment variables. `DEFAULT_*=` lines in the
  file are an error (set them in the environment). `BITRATE` must be `NNNk`
  (`128000` is an error); `CODEC` must be `opus`, `aac` or `mp3` (`pcm_s16le`
  was accepted and left local recording empty). [LB-08, X-09, X-28]
- **Stream names are canonical.** One rule serves the MediaMTX path, the
  publisher URL, PID file, status and systemd line: lower case, `[a-z0-9_-]`,
  first character a letter or digit, at most 64 characters; other characters
  become `_` (`Studio Mix` is `studio_mix`, `My-Mix_2` is `my-mix_2`). The
  `-n` name goes through the same rule, and the result is logged when it
  differs. A name that is reserved (`control`,
  `stats`, `api`, `metrics`, `health`, `all`, `all_others`), too long or
  without a letter or digit ends the command with exit 4. A name with a space
  made MediaMTX refuse to start. [LB-04]
- **The three ports are honoured everywhere.** `MEDIAMTX_RTSP_PORT`,
  `MEDIAMTX_API_PORT` and `MEDIAMTX_METRICS_PORT` reach the generated file,
  readiness and stream probes, the port check, the wrappers' publish URL and
  every URL the manager prints; the manager hard-coded 8554 and 9997 before. A
  value that is not an integer from 1 to 65535 ends every command with exit 4.
  The unit and the cron file do not carry them: set them in both (see
  Upgrading). The port check no longer counts a client socket that merely uses
  the number. [X-19]
- **The capture device is not assumed to be PCM 0.** The manager lists a card's
  capture PCMs; `DEVICE_<NAME>_PCM` picks one if there are several. [LB-24]
- **Multiplex mode asks FFmpeg before it starts.** The amix `normalize` option
  needs FFmpeg 4.4; on 4.2 and 4.3 (Ubuntu 20.04, Debian 11) the stream used to
  fail with "Option not found" and now starts without it, which gives amix's
  default scaling. From 4.4 the mix stays the plain sum (`normalize=0`), 6 dB
  louder than amix's default for two equal inputs. A channel count the codec
  cannot encode (for example two stereo microphones with `amerge` and `opus`,
  4 channels, on FFmpeg 6.1.1) is refused before the wrapper is written, with
  the alternatives in the message; an individual stream's `CHANNELS` is
  checked the same way. [X-20, X-49]
- **Recording is RAM-only unless you point it elsewhere.** With
  `AUDIO_LOCAL_RECORDING=true` the segments go to `AUDIO_RECORDING_PATH`
  (default `/dev/shm/lyrebird-buffer`, lost at reboot or power loss): the last
  `AUDIO_RECORDING_SEGMENTS` x `AUDIO_RECORDING_SEGMENT_TIME` seconds (one hour
  by default) per stream, overwritten in place. For recordings that survive,
  set `AUDIO_RECORDING_PATH` to persistent storage. After a wrapper restart the
  segments are not in slot order: sort them by modification time. [LB-16]
- **Two log variables.** `STREAM_MANAGER_LOG_FILE` is the manager's own log
  (default `/var/log/lyrebird-stream-manager.log`); `MEDIAMTX_LOG_FILE` is only
  where MediaMTX's output goes (default `/var/log/mediamtx.out`). They used to
  be one variable. [X-15]
- **FFmpeg logs are kept.** A new wrapper moves the previous `<stream>.log` to
  `<stream>.log.prev.1` and shifts older ones up; `FFMPEG_LOG_KEEP` (default 3,
  at most 20) bounds them. `start`, `stop` and `force-stop` no longer delete
  logs. [X-25]
- **`reload` is a real command.**
  `lyrebird-stream-manager.sh reload` re-renders the MediaMTX configuration
  and lets the running MediaMTX apply it; the manager stops nothing. Changes to
  the log level, timeouts, metrics, RTSP settings or a path's settings make
  MediaMTX disconnect that stream's publishers, which reconnect (a gap); the
  command says which keys do. Per-device audio settings are applied by
  `restart`, not `reload`. Exit 7 means MediaMTX is not running. A terminal
  hang-up (SIGHUP) of a manually started manager now runs `reload`; it used to
  stop every stream. [LB-11, X-46]

**systemd units**

- **One unit template, rendered at `install`.** `config/mediamtx-audio.service`
  is the template; `lyrebird-stream-manager.sh install` renders it and the
  monitor cron file before it writes anything, and refuses (exit 4, nothing
  written) a value a unit cannot carry. `install` must be run from a checkout
  (it needs `config/` next to the script). Compared with the unit `install`
  used to write: `Restart=always` (was `on-failure`), the start limit is 10 in
  20 minutes in `[Unit]` (`StartLimitInterval=` sat in `[Service]`),
  `ExecReload` runs the real `reload` (was `restart`), `ProtectSystem=strict`
  with every path the manager writes made writable (was `full`), start and stop
  timeouts computed from the manager's own timings (560 s and 130 s for 8
  streams; were 300 and 120), `Conflicts=mediamtx.service`, no `Group=audio`
  and no faked `INVOCATION_ID`. The unit has no `WatchdogSec=`: the manager
  sends no keep-alives. A node keeps its old unit until `install` runs again
  (the updater does that). [LB-11, LB-12, X-12]
- **The standalone MediaMTX unit** (`config/mediamtx.service`) conflicts with
  the manager's unit and has the start limit in `[Unit]`, and `install_mediamtx.sh`
  renders the unit from that file. Compared with the unit the installer wrote:
  5 starts in 300 s (was 3 in 60 s), `RestartSec=5` (was 10), no `ExecReload`,
  `MemoryMax=512M`. `systemctl reload mediamtx` now says the unit cannot
  reload: MediaMTX re-reads a changed configuration file by itself (checked on
  1.15.0 and 1.21.1), and SIGHUP ends it. A node keeps its unit until
  `install_mediamtx.sh --force install`. [LB-02, X-12, LB-12]
- **The cron monitor runs in the unit's stream mode.** `install` writes
  `STREAM_MODE`, `MULTIPLEX_FILTER_TYPE` and `MULTIPLEX_STREAM_NAME` into
  `/etc/cron.d/mediamtx-monitor`; before, the monitor of a multiplex node ran
  in individual mode and started per-device streams next to the multiplexed
  one. Run `install` again to change the mode. [X-32]

**Installer** (`install_mediamtx.sh` 2.1.0)

- **The configuration is the shared generator's**: first line
  `# Managed by LyreBirdAudio`, API and metrics on `127.0.0.1`, everything but
  RTSP off, and a catch-all path so publishers are accepted (the old file's
  `paths: {}` made MediaMTX answer every publisher with "path is not
  configured"). It is generated for the version of the binary that will run
  it. An existing marked file is replaced only if its content changes, after
  `mediamtx.yml.backup.<time>`; a file without the marker is left alone
  unless `--force`, which saves a backup first. Exit 9: MediaMTX rejected the
  generated file (1.21.1 and later); nothing is written. [LB-06, LB-22]
- **Ports are validated before anything is downloaded or written**: a
  `MEDIAMTX_*_PORT` that is not an integer from 1 to 65535, or two equal
  ones, ends `install` with exit 10 and names the variable. [X-43]
- **`install` needs `lyrebird-common.sh` next to the installer** (exit 4
  otherwise); `--no-config --no-service` does not. [LB-22]
- **`update` downloads and verifies first, then stops MediaMTX**, so a failed
  download or a checksum mismatch (always fatal, even with `--force`) leaves
  MediaMTX running. It installs atomically, checks that the new binary runs,
  and rolls back to the previous one when it does not run or the service does
  not come back. A MediaMTX started by hand is stopped, not started again; the
  command to start it is printed and the exit status is 0 (it used to end
  rolled back with exit 7). Across MediaMTX 1.19 an update adds `moq: no` to a
  generated configuration; before, MoQ listened on every interface. `update`
  still never rewrites the configuration or the unit otherwise. [X-39, X-40,
  X-41, X-42]

**Updater** (`lyrebird-updater.sh` 1.8.0)

- **`--history` and `--rollback [VERSION]` exist** (the README described them
  before they existed). `--history` lists updates, rollbacks and
  resets from a local log, and any update that did not finish. `--rollback`
  returns to the version the last update came from, or to a release tag or
  commit already in the clone; neither needs the network. [X-21]
- **An update is a journalled transaction.** An update killed halfway (a
  power cut, SIGKILL) is undone by the next run: back to the recorded commit,
  stash and service restored. Declining "Save your changes temporarily?" or a
  failing stash no longer discards your uncommitted edits; a conflicting
  stash restore leaves a clean tree, keeps your changes in the stash and
  exits 10. File modes survive (every tracked `*.sh` stays executable), and
  no command waits on an unreachable remote: a fetch is bounded (30 seconds,
  3 attempts). [X-21]
- **The lock is a kernel `flock`** on `<git-dir>/lyrebird-updater/updater.lock`,
  never deleted; it is no longer an untracked directory in the working tree.
  `flock` (util-linux) is now a prerequisite (exit 2 without it). Migrations
  now also run after a self-update. [X-31]
- **Exit codes**: 6 (the version is not in the clone), 10 (switched, but your
  saved changes conflict and are in the stash), 11 (the automatic rollback
  could not restore everything), 12 (input ended at a menu prompt). A switch
  that fails in the menu is reported and the menu stays open; `Q` leaves with
  the status of the last switch. [X-21, X-31]

**Orchestrator** (`lyrebird-orchestrator.sh` 2.2.0)

- **It says what a start really did.** Audio Streaming Control (menu 4: Start
  All Streams, Restart All Streams) and the Quick Setup Wizard read `/run/lyrebird/status.json` (or
  `status --json`) and print each stream's state and reason, then the next
  step; the wizard's final message is decided by the start it just ran (it
  used to report success after a failed start, and warnings after a good one).
  Exit codes of the stream manager and the updater are explained in words. The
  wizard no longer advises a reboot. Version Management (menu 6) has 3) Show
  Update History and 4) Roll Back to a Previous Version. Listing stream URLs
  no longer ends the orchestrator on a system without the `ip` command.
  [LB-21, X-21]

**Metrics** (`lyrebird-metrics.sh` 1.4.0)

- **`serve` and its options exist as documented**: `serve [--port PORT]
  [--bind ADDR]` (and `--serve [PORT]`). It answers `GET /` and `GET /metrics`
  with correct HTTP framing, one connection at a time, a document generated
  after the request arrived, and no longer loops while the port is taken
  (exit 2 after 5 attempts). `--file` replaces the file atomically and keeps
  the previous one when anything fails. [LB-18, X-17]
- **Exit status is no longer always 0**: 2 when nothing could be delivered,
  3 when a collector failed. New `lyrebird_scrape_success` and
  `lyrebird_collector_success{collector}` say which; a source that cannot be
  read makes its metrics absent, not 0 (alert on `lyrebird_scrape_success == 0`).
  [LB-18]
- **MediaMTX is this installation's MediaMTX**: the configured binary on the
  configured configuration (`MEDIAMTX_BINARY`, `MEDIAMTX_CONFIG_FILE`), as for
  the manager; a process whose command line merely contains "mediamtx" no
  longer counts. Liveness is read from `/proc`, not `kill -0`. Run the exporter
  as root: as another user MediaMTX details are left out and the scrape counts
  as degraded (exit 3). One scrape spends at most `LYREBIRD_API_TIMEOUT`
  seconds (default 5) on the MediaMTX API; a refused API costs 20 ms, not
  1 second. [X-30]

**Storage** (`lyrebird-storage.sh` 1.3.0)

- **The documented cron lines work.** `cleanup --quiet` and `monitor --once`
  are implemented (`monitor` checks once and exits; there is no `--interval`
  and never was). `/etc/lyrebird/storage.conf` is read, as data, when it
  exists, and not at all when anyone can write it or another user owns it
  (reported, exit 4); an `/etc/lyrebird/storage.conf` written from the old
  documentation takes effect with this version. Exit status 3 also covers a
  directory that could not be listed, and 4 means lines of the configuration
  file were ignored. [DOC-05, X-29]
- **Retention and emergency cleanup see every recording.** `.aac` was missing
  from the list, so `CODEC=aac` recordings were never cleaned (the list is now
  `opus ogg aac adts m4a mp3 flac wav`). Empty segments left by a killed
  FFmpeg are removed once idle for `LYREBIRD_ACTIVE_SEGMENT_SECONDS` (default
  900); a file written more recently is never evicted. Emergency cleanup
  removes at most 100 of each kind per run, oldest first, and no longer
  deletes the buffer's stream directories (FFmpeg lost its recording leg
  until restarted). Symlinked configured directories are followed. [X-14, X-29]

**Alerts** (`lyrebird-alerts.sh` 1.1.0)

- **Delivery is tracked per destination.** An identical alert is not sent
  again to a destination that confirmed it within `LYREBIRD_ALERT_RATE_LIMIT`
  seconds (default 300); a destination that failed is retried by the next
  identical alert. Five parallel identical alerts deliver once per
  destination. New exit status 5: some destinations have the alert and at
  least one failed (0 now means every destination that needed it has it).
  A script that sources the library and calls `send_alert` under `set -e`
  must handle 3, 4 and 5. [LB-17]

**Test suite and CI** (for contributors)

- **The suite no longer writes the machine's real `/var/log`, `/etc` or
  `/run`**, and `LYREBIRD_LEAK_CHECK_HOST=1 tests/check_tmp_leaks.sh` fails a
  run that does (CI sets it). Tests that tested copies of functions defined in
  the test file were converted to run the real script, or removed where a real
  test already covered the behaviour. [X-35, X-18]
- **CI runs on every pull request and push to main**, with no path filter.
  The `CI Summary` job fails unless every job succeeded, `shfmt` and `bashate`
  block, every Action is pinned to a commit and every downloaded tool is
  checked against a hash. The live matrix covers MediaMTX 1.15.0, 1.18.0,
  1.19.0, 1.21.1, 1.21.2 and 1.21.3, plus an advisory canary on the newest
  upstream release. A tag runs the whole pipeline before a release is
  published, with a source tarball and `SHA256SUMS`; publishing can be
  repeated. [LB-19, LB-20, X-22, X-16]

**Stream manager exit codes** (`lyrebird-stream-manager.sh help` has the same
list; 8 and 9 are new, 5, 6 and 7 changed)

| Code | Meaning |
|------|---------|
| 0 | Success. `start`: the start policy is met, or there is no device and an empty start is allowed. `monitor`: healthy, waiting for devices, or skipped because a lifecycle command is running |
| 1 | General error, including `force-stop --kill-all` without `--yes` and a command that could not stop what it had to |
| 2 | Critical resource state (the cron job restarts the service) |
| 3 | Missing dependency (`curl` is now one) |
| 4 | Configuration error: an invalid `LYREBIRD_*` setting, port, stream name or device configuration, or no MediaMTX configuration |
| 5 | Another lifecycle command holds the lock; nothing was changed (`stop` and `force-stop` now return it too) |
| 6 | No USB audio device, with `LYREBIRD_ALLOW_EMPTY_START=false` only |
| 7 | MediaMTX not running (`monitor`; `reload`) |
| 8 | Another MediaMTX owns the node; `start`, `restart` and `reload` refused (new) |
| 9 | `start` did not meet `LYREBIRD_START_POLICY`; what it started was stopped (new) |
| 10 | Streams degraded (`monitor`, logged only) |
| 128+N | Ended by signal N: 130 SIGINT, 143 SIGTERM |

#### Fixed

- **A monitor restart reverted per-device settings to the defaults.** The device
  configuration was loaded only when the MediaMTX configuration was generated.
  [X-01]
- **A generated wrapper ended at its first back-off** (`MAX_RESTART_DELAY:
  unbound variable`) unless those variables were in the manager's environment,
  so the "FFmpeg restarts with back-off" fix of 1.3.0 did not hold for a
  default install. [X-10]
- **A card that is detected but cannot be opened used up the restart budget**,
  so after six such attempts an hour a real restart was refused. The budget is
  charged only for restarts that are attempted, and in multiplex mode too.
  [X-04, X-48]
- **A failed command left `/run/mediamtx-audio.cleanup`**, which makes every
  wrapper stop at its next loop; a failed `start` on a healthy node ended its
  streams. Only an interrupted run that could not take down what it had
  launched leaves it now, and a start refused by the lock or by ownership never
  does. A refused `restart` no longer leaves its marker either. [LB-03, LB-05]
- **A card with no capture PCM (a USB speaker or DAC) counted as a failed
  stream.** It is skipped, listed as `[SKIP]` and `"skipped":true` in the
  status file, left out of the start policy and of the monitor. A device
  without `/dev/snd/controlC<N>` is reported instead of skipped silently.
  [X-34, X-27]
- **`arecord -l | grep -q` under `pipefail` could report a present card as
  missing** (SIGPIPE), so its stream was not started or restarted. [LB-24]
- **A stream that failed its own validation left its wrapper behind.** It is
  now stopped by identity, and its PID file, start-time record and wrapper
  script are removed. [X-47]
- **`status` without root printed running wrappers as "Not running"**; it now
  says "Unknown (run as root)" for a process it cannot read. [X-36]
- **`exec ... 2>/dev/null` silenced stderr for the rest of the process**, so
  errors vanished after the first lock release. [X-06]
- **`AUDIO_RECORDING_PATH` with `|`, `\`, `'` or `%` changed what the tee muxer
  wrote** (another directory, or an error). It is escaped; `[`, `]`, `:` and
  spaces were harmless. [X-33]
- **A live PID file was deleted when its process had another program name**
  (for example MediaMTX started from a differently named binary); identity is
  now the process start time. [X-26]
- **The device config template, `lyrebird-mic-check.sh`'s generator and its
  restore are written durably** (temp file, fsync, rename, fsync of the
  directory). mic-check writes quoted values, and the header of the file it
  generates, silently missing before, is back. [LB-23, LB-08]
- **The metrics server could abort on SIGTERM** (a bash 5.2 `read -t` timer
  left armed; seen in 6 of 480 shutdowns under load). [X-44]
- **`usb-audio-mapper.sh` could read a directory above its sysfs root as a USB
  port.** Real sysfs was not affected; the mapper is 4.0.1. [X-45]
- **`tools/soak/README.md` claimed more than had been checked.** It said that
  LyreBirdAudio's own silence detection covered a muted microphone (nothing ran
  it) and listed macOS for the observer (it has not been run there). It now
  has a Silence section that says what the monitor's check reads and what it
  cannot catch, and says what was and was not run for the observer. [DOC-03]
- **The version table at the end of this file was out of date.** It listed
  versions the scripts no longer had and called them current. It now gives each
  script's version in v1.3.0 and in this tree. [DOC-04]

#### Removed

- **`HEARTBEAT_INTERVAL`, `HARDWARE_WATCHDOG_TIMEOUT`,
  `ENABLE_HARDWARE_WATCHDOG`, `HARDWARE_WATCHDOG_DEVICE`,
  `LYREBIRD_WATCHDOG_ENABLED` and `LYREBIRD_WATCHDOG_INTERVAL`**, with the
  `/dev/watchdog` code and the SIGUSR2 handler: none of them did anything (the
  device was never opened). A set one is ignored with one warning per run. For
  a hardware watchdog use systemd's `RuntimeWatchdogSec=` or a watchdog
  daemon; this project neither implements nor tests one. [LB-15]
- **`AUDIO_DISK_PERSIST` and `AUDIO_DISK_PATH`**: they only created a directory
  and moved nothing. A set one is ignored with one warning per run. See
  "Recording is RAM-only" above. [LB-16]
- **`LOCK_STALE_THRESHOLD`**, the lock-age and process-name staleness checks,
  and the instruction to delete a stale lock file. [LB-05]
- **The pattern kills**: `pkill` and `pgrep -f` of FFmpeg and MediaMTX by name or
  command line in the manager, the installer and the metrics server, and the
  use of MediaMTX's `--upgrade`. [LB-10, X-17, X-41]
- **A signal as a reload**: `ExecReload=` in the units sent HUP (which ends
  MediaMTX) or USR1 (which it ignores). [X-12]
- **From the manager's unit**: `Wants=` and `PartOf=mediamtx.service`, the
  `LYREBIRD_WATCHDOG_*` lines and the memory limits of the sample, and the
  generated unit's `Group=audio`. [LB-02, LB-11]
- **The wizard's "reboot may be needed" advice.** [LB-21]
- **`/run/mediamtx-silence-<stream>` files**, which nothing read: delete any
  that exist. [LB-14]

#### Added

- **Stream manager commands**: `reload`, `validate`, `status --json`,
  `force-stop --kill-all [--yes]` and the option `--regenerate-config`.
  [LB-11, LB-08, LB-03, LB-10, LB-22]
- **A status file**, `/run/lyrebird/status.json` (`LYREBIRD_STATUS_FILE`), and
  `status --json`. Per stream: `configured`, `process_alive`, `path_ready`,
  `bytes_flowing` (each true, false or null for "not known") and
  `last_error`; overall `ok`, `degraded`, `failed`, `waiting_for_devices` or
  `stopped`. `start`, `stop`, `force-stop`, `monitor` and `status` write it
  atomically, so a reader never sees a partial file. `bytes_flowing` samples
  MediaMTX's
  inbound byte counter twice, `LYREBIRD_FLOW_SAMPLE_SECONDS` (3) apart, which
  adds that long to `status` and to each monitor run when a stream is ready.
  [LB-03, LB-07]
- **Settings**: `LYREBIRD_START_POLICY`, `LYREBIRD_ALLOW_EMPTY_START`,
  `LYREBIRD_STATE_DIR`, `MONITOR_LOCK_TIMEOUT` (5), `STOP_LOCK_TIMEOUT` (5),
  `MEDIAMTX_API_BIND`, `MEDIAMTX_METRICS_BIND`, `RTSP_AUTH_MODE`,
  `RTSP_USERS_FILE`, `MEDIAMTX_CONFIG_BACKUPS`, `FFMPEG_LOG_KEEP`,
  `STREAM_MANAGER_LOG_FILE`, `AUDIO_LEVEL_*`, `AUDIO_SILENCE_*`,
  `SILENCE_STATE_DIR`, `DEVICE_<NAME>_PCM`. `lyrebird-stream-manager.sh help`
  lists them with their defaults.
- **Updater**: `--history`, `--rollback [VERSION]`, exit codes 6, 10, 11 and
  12, and the settings `LYREBIRD_FETCH_TIMEOUT`, `LYREBIRD_FETCH_RETRIES`,
  `LYREBIRD_FETCH_RETRY_DELAY`, `LYREBIRD_REMOTE_PROBE_TIMEOUT`,
  `LYREBIRD_UPDATER_LOCK_WAIT` and `LYREBIRD_UPDATER_STATE_DIR`. [X-21]
- **Installer**: exit codes 4, 9 and 10, and the settings `MEDIAMTX_SERVICE_DIR`,
  `MEDIAMTX_UNIT_TEMPLATE`, `MEDIAMTX_STOP_TIMEOUT` and `MEDIAMTX_PID_FILE`.
  [LB-22, X-43]
- **Metrics**: `serve`, `--port`, `--bind`, `lyrebird_scrape_success`,
  `lyrebird_collector_success`, `LYREBIRD_HEARTBEAT_MAX_AGE` and
  `LYREBIRD_API_TIMEOUT`. [LB-18, X-13, X-30]
- **Storage**: `--quiet`, `--once`, `/etc/lyrebird/storage.conf`
  (`LYREBIRD_STORAGE_CONFIG` names another file; empty means none),
  `LYREBIRD_ACTIVE_SEGMENT_SECONDS`, `Empty segments` in `status`. [DOC-05,
  X-14]

#### Upgrading an existing node

Which command refreshes which file:

- **The scripts of the checkout**: `sudo ./lyrebird-updater.sh`.
- **`/etc/systemd/system/mediamtx-audio.service`,
  `/etc/cron.d/mediamtx-monitor` and `/etc/logrotate.d/mediamtx`**:
  `sudo ./lyrebird-stream-manager.sh install`. The updater runs it when the
  manager script changed and the service is installed.
- **`/etc/mediamtx/mediamtx.yml` of a manager node**: the first `start`, if an
  earlier manager wrote it; otherwise
  `sudo ./lyrebird-stream-manager.sh --regenerate-config restart`.
- **`/etc/mediamtx/mediamtx.yml` and `/etc/systemd/system/mediamtx.service` of
  a standalone MediaMTX**: `sudo ./install_mediamtx.sh --force install`, which
  reinstalls the latest binary too (`-V vX.Y.Z` pins one).
- **The MediaMTX binary**: `sudo ./install_mediamtx.sh update`, which touches
  nothing else.
- **`/etc/mediamtx/audio-devices.conf`**: never rewritten;
  `sudo ./lyrebird-stream-manager.sh validate` checks it.

In this order:

1. Look at what runs: `systemctl is-active mediamtx mediamtx-audio`. If both are
   active, choose one: the manager's unit conflicts with `mediamtx.service`, and
   the manager refuses to start (exit 8) while `mediamtx.service` is active. A
   node that streams microphones uses `mediamtx-audio.service`; the standalone
   unit is for a MediaMTX-only node.
2. Update the checkout with `sudo ./lyrebird-updater.sh` (option 1, or 3 for a
   tag) to the release that contains this section; v1.3.0 does not. When
   `mediamtx-audio.service` is installed and the manager script changed, the
   updater stops the service, runs `install` (keeping the `Environment=` lines
   you added to the unit), reloads systemd and starts the service. Without the
   updater, run `sudo ./lyrebird-stream-manager.sh install` with the `-m`, `-f`
   and `-n` options you used before (it rewrites the unit, so keep local
   settings in `systemctl edit mediamtx-audio`), then
   `sudo systemctl daemon-reload` and `sudo systemctl restart mediamtx-audio`.
3. Keep `lyrebird-common.sh` in the same directory as
   `lyrebird-stream-manager.sh` and `install_mediamtx.sh`, and run `install`
   from a checkout: the manager cannot write a MediaMTX configuration without
   the library, `install_mediamtx.sh install` needs it, and the unit is
   rendered from `config/mediamtx-audio.service`. A copy of one script alone in
   `/usr/local/bin` has none of that.
4. Check the device configuration with `sudo ./lyrebird-stream-manager.sh
   validate`. Lines that were silently ignored before are now listed with their
   line numbers, and mixed-case keys now take effect.
5. Replace `mediamtx.yml` where you want the new defaults (list above). The
   file the earlier manager wrote is replaced by the first `start`, after a
   backup. The file the earlier installer wrote is yours: until you replace it
   its API and metrics stay on every interface, SRT (and MoQ) stay on, and
   `paths: {}` still refuses every publisher.
6. Move settings. A node that set `MEDIAMTX_LOG_FILE` and relied on the manager
   log being in the same file must also set `STREAM_MANAGER_LOG_FILE`.
   `install` writes no port settings: a non-default `MEDIAMTX_RTSP_PORT`,
   `MEDIAMTX_API_PORT` or `MEDIAMTX_METRICS_PORT` must be in the unit's
   environment (`systemctl edit mediamtx-audio`) and, as `NAME=value` lines
   before the job line, in `/etc/cron.d/mediamtx-monitor`, which every `install`
   rewrites, so add them again afterwards. Delete the removed settings (see
   Removed) from the unit; until then every run logs one warning.
7. If the service was not restarted in step 2, restart it:
   `sudo systemctl restart mediamtx-audio`. On a node started by hand with the
   old code, the first `stop` or `force-stop` can wait `STOP_LOCK_TIMEOUT`
   seconds and refuse (exit 5), because MediaMTX and FFmpeg inherited the old
   lock; it lists the processes that hold it, and you stop them once.
8. Check: `sudo ./lyrebird-stream-manager.sh status` ends with an overall state
   of `ok`, `degraded` or `waiting_for_devices` (`status --json` has the same),
   and `systemctl status mediamtx-audio` is active.

What changes without your doing anything:

- A Prometheus on another machine that scrapes `lyrebird-metrics.sh serve` needs
  `serve --bind ADDR` (or `0.0.0.0`) and a firewall. A cron job that redirects
  `lyrebird-metrics.sh` into a file should use `--file PATH`, which replaces the
  file atomically.
- Alert state files of the previous version (`<alert>.last`) are no longer read,
  so the first identical alert after the upgrade can be delivered once more.
- An `/etc/lyrebird/storage.conf` written from the old documentation, which
  was never read, now takes effect.
- Each monitor run opens a short RTSP read session per published stream. A
  MediaMTX that requires authentication to read refuses it (401): the failed
  probe is logged every run and never counted as silence.
  `AUDIO_LEVEL_CHECK_ENABLED=false` turns the check off.

#### Known limits

- **Not run on hardware or under a real systemd manager.** Tested here: Linux,
  Bash 5.2, MediaMTX 1.15.0, 1.18.0, 1.19.0, 1.21.1, 1.21.2 and 1.21.3 (live
  tests), `systemd-analyze verify` and a mount-namespace emulation of the unit's
  sandbox. Not tested: real USB hardware (hot-plug, how a card lays out its
  capture PCMs, `plughw` behaviour, a second open of a busy card), a hub that
  appears after the start limit is used up (LB-07, LB-11, LB-12, X-12), the
  `Conflicts=` and boot ordering with a real manager, `systemctl reload`, a
  real power cut during a write (only the order of the operations is
  tested; LB-23), USB clock drift between independent microphones (X-20),
  FFmpeg 4.2 and 4.3 at run time (the missing `normalize` option is tested
  with a stand-in help text), hardware watchdog drivers (LB-15), RTSP clients
  on another host (the tests connect to the machine's own non-loopback
  address), IPv6, ARM boards and binaries, macOS and BSD, Bash older than 5.2,
  and a real `sudo` for the orchestrator. [LB-07, LB-11, LB-12, X-12, LB-23,
  LB-24, X-20, LB-15]
- **GitHub itself.** The workflows were checked with actionlint and each step
  script was run locally; no run on GitHub is part of this check. Requiring
  the `CI Summary` check in branch protection, signing tags and attesting
  releases are repository settings this change does not make: a release
  carries a source tarball and `SHA256SUMS`, which prove integrity, not
  authorship. [LB-19, LB-20, X-22, X-16]
- **Older MediaMTX cannot validate a file.** `--validate-conf` exists from
  1.21.1; before that an unknown key or an invalid path name is found only when
  MediaMTX refuses to start (the reason is in `/var/log/mediamtx.out`).
  [LB-22]
- **`install` writes no port settings** into the unit or the cron file, and
  rewrites the cron file every time, so a node with non-default ports must
  repeat step 6 above after each `install`. [X-19]
- **RTSP has no authentication unless you configure it**, and the metrics
  server none at all (one connection at a time; for several scrapers use
  `--file` and node_exporter's textfile collector). [LB-06]
- **The silence check is a log line, with a threshold not validated on real
  microphones.** -60 dB was checked against digital silence (-91 dB) and an
  FFmpeg test tone only; a dead capsule that idles above it is not detected. The
  probe reads anonymously, so it cannot see a stream behind read
  authentication. [LB-14]
- **Nothing monitors a node set up only by the Quick Setup Wizard.** The
  monitor, and with it late-device recovery and the silence check, is the cron
  job `lyrebird-stream-manager.sh install` writes, and the wizard does not run
  it. [LB-07, LB-21]
- **Known smaller defects, not fixed**: the orchestrator's header counts every
  `ffmpeg` process on the host and finds MediaMTX by name, and "View Stream
  URLs" prints port 8554 whatever `MEDIAMTX_RTSP_PORT` says; the installer
  uses exit 7 for "already installed" and for some failed install steps, which
  the wizard reads as "already installed"; a second updater started in the
  instant of a self-update's `exec` could take its lock; non-root `status`
  prints a garbled `Resources:` line for MediaMTX; the failure counter of the
  network check is the fixed file `/run/mediamtx-network-failures`; a card whose
  `usbid` shows up before its PCM entries is skipped until the next monitor
  run.
- **Older entries below claim more than was tested.** "Cross-platform" and
  platform-list entries (orchestrator 2.0.1, diagnostics 1.0.2, installer
  2.0.1) were never backed by a run on macOS, BSD or ARM: the suite runs on
  Linux, Bash 5.2, and `tests/fetch_mediamtx.sh` fetches linux amd64 releases
  only.

### Soak testing and current MediaMTX (2026-10)

Component versions bumped: `lyrebird-stream-manager.sh` 1.5.0 → 1.5.1.

#### Added
- `tools/soak/`: a soak-test harness for field-like long runs.
  `lyrebird-soak.sh` runs on the node (systemd service), checks device names
  against the usb-audio-mapper rules, stream liveness and stalls, services and
  resource trends, injects faults on a seeded schedule (process kills, udev
  restarts, USB unplug, network loss, full disk, clock steps, reboots and
  hard resets; each undo armed as a systemd timer before the fault), and
  reports PASS/FAIL. `lyrebird-soak-observer.sh` watches the streams from a
  second machine (bash 3.2 or later), can cut the node's power through
  commands you supply, and reports gaps and time to audio. See
  `tools/soak/README.md`.
- Live tests against real MediaMTX releases (`tests/fetch_mediamtx.sh`
  downloads checksum-pinned 1.15.0, 1.18.0, 1.19.0, 1.21.1, 1.21.2 and
  1.21.3), run by a CI job per version.

#### Fixed
- **MediaMTX 1.19.0 and later opened three extra ports.** Those versions start
  a MoQ (Media over QUIC) server unless told not to, so the generated
  `mediamtx.yml` left `:8892/tcp`, `:8892/udp` and `:8893/udp` listening on
  every interface (allowed origins `*`), and MediaMTX wrote a generated
  key/certificate pair into its working directory. The installer installs the
  latest release by default, so new installs were affected. The config now
  says `moq: no` when the installed MediaMTX is 1.19.0 or later; 1.15–1.18
  refuse to start with that key, so it is left out for them and when the
  version cannot be read. Verified with the real binaries of every release
  from 1.15.0 to 1.21.1.

### USB Audio Mapper 4.0.0 (2026-10)

`usb-audio-mapper.sh` is now the same file as the standalone
[usb-audio-mapper](https://github.com/tomtom215/usb-audio-mapper) 4.0.0 (its
version number replaces this repository's 1.2.1). Tested end to end with real
Linux kernels and real systemd-udevd in QEMU; see
`docs/ENGINEERING-REVIEW-2026-07.md` §9.

Component versions bumped: `usb-audio-mapper.sh` 1.2.1 → 4.0.0,
`lyrebird-orchestrator.sh` 2.1.2 → 2.1.3, `lyrebird-updater.sh` 1.6.0 → 1.6.1,
`lyrebird-mic-check.sh` 1.0.0 → 1.0.1, `lyrebird-alerts.sh` 1.0.0 → 1.0.1.

#### Fixed
- **USB persistent naming still never worked (critical).** The 2026-07 fix (C1)
  made the rule an active line, but whenever udev knew the device's `ID_PATH`
  the rule matched `ENV{ID_PATH}` taken from the USB *device* node, which never
  equals the sound card's `ID_PATH` (the card's carries the interface suffix,
  e.g. `-usb-0:1:1.0`). In non-interactive mode the value also came from the
  first `lsusb` line with the vendor/product id, so identical devices all got
  the first device's rule and `-u` was ignored. Reproduced with three identical
  devices: 0 of 3 renamed. Rules now match the sound card's own `ID_PATH`
  (imported in the rule), gated to the card device; 3 of 3 renamed, immediately,
  after replug, after udevd restarts and system-wide triggers, and at boot.
- **Wrong microphone named after USB bus renumbering (critical).** A port rule
  such as `KERNELS=="1-1"` contains the USB bus number, which changes between
  boots when host-controller drivers register in a different order; in a test
  with two controllers one microphone got the other's name. `ID_PATH` omits the
  bus number and kept both names in every load order.
- **Names the kernel truncates or refuses**: ALSA card ids hold 15 characters
  (longer names were silently cut), and ids starting with `card` (the
  wizard's own fallback suggestion) or reserved words like `pcm` are refused.
- **Rule side effects**: the rule also matched `controlC*`/`pcm*` nodes, so
  udev logged failed `ATTR{id}` writes on every event and several nodes
  competed for the symlink; re-applying an unchanged id fails with `EEXIST`.
  Rules are now gated (`KERNEL=="card*"` / `"controlC*"`,
  `ACTION=="add|change"`) with an `ATTR{id}!=` guard.
- An invalid `-u` value no longer silently falls back to a vendor/product rule
  that names every identical device the same; several identical devices with
  no port given are refused (exit 5).
- Concurrent mapper runs no longer lose updates (`flock`).
- `-u usb-<controller>-<port>` (the form in `/proc/asound/cards`) was refused
  when the controller name contains `-`, as on dwc3 ARM boards
  (`usb-xhci-hcd.0.auto-1.2`).

- **Test suite could delete recordings and logs.** `tests/test_lyrebird_storage.bats`
  exported `RECORDING_DIR`/`LOG_DIR`/`TEMP_DIR`, which `lyrebird-storage.sh`
  overwrites with its readonly defaults when sourced, so the teardown's
  `rm -rf` hit `/var/lib/mediamtx-ffmpeg/recordings`, `/var/log/lyrebird` and
  `/tmp`. Run as root on a node, the test suite deleted all recordings and
  logs. The setup now uses the `LYREBIRD_*_DIR` variables; regression test in
  `tests/test_storage_suite_safety.bats`.

- **321 tests could not fail.** Six test files sourced a script in `setup()`
  that replaced bats' `EXIT` trap and then switched errexit off, so a failing
  assertion was ignored. A helper now restores bats' traps and options after
  sourcing, and `tests/test_suite_can_fail.bats` checks every test file.
  This surfaced 28 failures; 25 were wrong tests, corrected to the scripts'
  actual behaviour (`docs/ENGINEERING-REVIEW-2026-07.md` §9, U9–U13).
- The test suite left 27 temp files and directories behind per run. Test files
  that create temp files now give each test a private `TMPDIR`
  (`tests/scratch_tmpdir.bash`), and CI runs `tests/check_tmp_leaks.sh`, which
  fails on any leftover.
- `lyrebird-mic-check.sh -g` wrote `DEFAULT_SAMPLE_RATE`, `DEFAULT_CHANNELS`
  and `DEFAULT_BITRATE` into `audio-devices.conf`, where the stream manager
  ignores them (they are readonly by then) and logs `readonly variable` on
  every load. They are now written as comments; set them in the stream
  manager's environment instead. README corrected.
- `lyrebird-alerts.sh`: level colours and prefixes were lost when the script
  was sourced from a function.
- `lyrebird-updater.sh --help` now lists the command-line options.
- `lyrebird-stream-manager.sh` header said version 1.4.4 (it is 1.5.0), which
  `lyrebird-diagnostics.sh` reported.

#### Added
- `--card N`, `--list`, `--remove NAME`, `--dry-run`, `--no-apply`,
  `--any-port`; immediate application with kernel verification (exit 6 when
  the name did not take, naming the card that holds it); automatic migration
  of rules written by earlier versions; documented exit codes.

#### Changed
- Orchestrator: no reboot prompt after mapping (not needed any more); messages
  name the real outputs (`/proc/asound/cards`, `/dev/sound/by-id/`); "show
  mappings" uses `usb-audio-mapper.sh --list`.
- Docs: removed references to `/dev/snd/by-usb-port/Device_N` and
  `--rescan`, neither of which existed, and to reboots after mapping.
- `tests/test_usb_audio_mapper.bats` replaced: the old file had 19 tests, 14 of
  which tested copies of functions defined inside the test file rather than the
  script. The new suite (56 tests) runs the real script against a fake sysfs.
  The QEMU end-to-end suite lives in the standalone repository.

### Reliability Audit (2026-07, third pass)

A third adversarial, hardware-free reliability pass focused on the long-horizon
and cold-start failure modes an unattended field node hits over weeks/months.
Every fix ships with a regression test that fails before and passes after; the
suite grew from 528 to 579 tests, all green, ShellCheck-clean. See
`docs/ENGINEERING-REVIEW-2026-07.md` §8 for the reproduced findings.

Component versions bumped: `lyrebird-stream-manager.sh` 1.4.3 → 1.5.0,
`lyrebird-metrics.sh` 1.1.0 → 1.2.0, `lyrebird-storage.sh` 1.0.0 → 1.1.0.

#### Deferred trio — closed with simulation proof
- **Deep health check (H9)**: `monitor_streams` now probes the MediaMTX control
  API for each path's readiness, not just the wrapper's bash PID. A stream whose
  path stays not-ready for `DEEP_HEALTH_MAX_STRIKES` (default 3) consecutive
  monitor runs — a hung FFmpeg or endless backoff — is restarted within the
  existing cron budget. An unreachable API neither strikes nor forgives a
  stream; a ready probe resets the streak; `DEEP_HEALTH_CHECK_ENABLED=false`
  restores the old shallow behavior.
- **Deprecated MediaMTX JSON fields**: readiness parsing now accepts both the
  deprecated (`ready`) and current (`available`) path-status shapes, preferring
  the new field, across all five grep sites (stream-manager ×4, metrics ×1). A
  future MediaMTX that drops `ready` no longer makes every stream look dead.
- **Non-monotonic timing**: wrapper run-time/backoff, the cron restart budget,
  and silence tracking now read `/proc/uptime` (monotonic) instead of wall-clock
  `date +%s`. An NTP step on an RTC-less Pi no longer counts a healthy multi-hour
  run as a failure, evaporates the anti-storm budget, or fires a false DEAD MIC.
  **Correction (2026-11):** nothing called the silence check at the time
  (`AUDIO_LEVEL_CHECK_ENABLED` did nothing); the monitor has run it since the
  2026-11 audit [LB-14].

#### Fixed
- **errexit/pipefail silent aborts**: swept 15 more `var=$(… | grep …)` sites
  across seven scripts where a zero-match grep aborted the whole run under
  `set -euo pipefail` (NTP probe on an unsynced daemon, audio-level check with no
  volumedetect output, metrics scrape when MediaMTX exits mid-scrape, checksum
  verification, service-env merge, and more). Idle-server counting in the stream
  manager (`0 ready paths`/`0 sessions`) was aborting too.
- **Corrupt device config aborted `start`**: a config truncated by power loss,
  SD-card bit-rot, or a bad operator edit hit a syntax error that aborted the
  whole run under errexit — no streams came up on the next unattended boot. The
  config is now syntax-checked before sourcing and ignored if corrupt; a valid
  config is sourced with errexit neutralised and still fully honored.
  **Correction (2026-11):** the file is no longer sourced at all; it is read as
  data, line by line [LB-08].
- **Non-numeric env knobs aborted the cron monitor**: 37 numeric knobs in the
  stream manager (e.g. `CRON_RESTART_MAX_PER_HOUR=unlimited`) reached bash
  arithmetic and killed every cron pass with an "unbound variable" error. All
  are now coerced to sane defaults at load; valid overrides are preserved.
- **Broken-clock mass deletion**: age-based recording retention is skipped while
  the system clock is pre-2025 (not yet NTP-synced), and any recording whose
  mtime predates that epoch is kept — preventing minutes-old data from being
  deleted as "56 years old" the moment the clock steps. Emergency size-based
  cleanup is deliberately exempt.

#### Added
- **Inode-exhaustion detection** in storage monitoring: a recorder writing many
  small files exhausts inodes long before blocks; `cmd_monitor` now applies the
  warning/critical/emergency thresholds to `df -Pi` too. Filesystems without
  inode accounting are treated as no pressure.
- **In-band metrics staleness marker**: every scrape emits
  `lyrebird_scrape_timestamp_seconds` so a `.prom` left behind by a dead exporter
  ("dead recorder looks alive") is detectable via a Prometheus age alert.

## [1.3.0] - 2026-07-19

First release to bundle the full Engineering Excellence Review (C1–C9, H1–H10)
and the follow-up Reliability Hardening pass. A large correctness/reliability
release for unattended 24/7 operation — no intentional breaking API change; the
one script rename is handled by automatic migration. Suite: 528 tests, green;
ShellCheck-clean. Highlights are grouped below.

### ⚠️ Breaking Changes
- **Script Renamed**: `mediamtx-stream-manager.sh` → `lyrebird-stream-manager.sh`
  - Log file path changed: `/var/log/mediamtx-stream-manager.log` → `/var/log/lyrebird-stream-manager.log`
  - **Automatic migration**: Running `lyrebird-updater.sh` will automatically update:
    - Systemd service files
    - Cron jobs
    - `/usr/local/bin` installations
    - Log file symlinks for backward compatibility
  - **Manual migration**: Run `sudo ./lyrebird-updater.sh --migrate`

### Added
- Automatic migration system in `lyrebird-updater.sh` v1.6.0
  - Post-update migrations for breaking changes
  - Idempotent migration tracking in `/var/lib/lyrebird/migrations/`
  - CLI flag `--migrate` for manual migration runs
- Migration detection in `lyrebird-orchestrator.sh`
  - Startup warning when old script names detected
  - Clear remediation steps for users
- Webhook alerting system (`lyrebird-alerts.sh`) for remote monitoring
  - Supports Discord, Slack, ntfy.sh, Pushover, and generic HTTP webhooks
  - Rate limiting and alert deduplication
  - Pure bash implementation with no new dependencies
- `CHANGELOG.md` to track version history
- `CONTRIBUTING.md` with contribution guidelines

### Changed
- Improved inline documentation in `usb-audio-mapper.sh`
- Enhanced error messages with remediation steps
- `lyrebird-stream-manager.sh` updated to v1.4.4
  - Restructured API validation to preserve curl exit status for better error detection
  - Replaced `curl|grep` pattern with explicit exit code checking
- CI now runs the `bats` test suite as a required check (previously never run)
- Documented MediaMTX support through v1.19.x (endpoints/assets unchanged from v1.15.x)

### Fixed (Engineering Excellence Review, 2026-07)
Full line-by-line audit; see `docs/ENGINEERING-REVIEW-2026-07.md`. Each fix ships
with a regression test. Highlights (all verified against the code):
- **USB persistent naming never worked** — `usb-audio-mapper.sh` emitted every
  udev rule as a comment (a literal `\n` collapsed the comment and rule onto one
  `#`-prefixed line). Also fixed an injection-prone card-name sanitizer.
- **FFmpeg streams did not auto-restart** — the supervisor wrapper died on the
  first FFmpeg failure (bare `wait` under `set -euo pipefail`) and again when the
  transient launcher PID exited. Restored the wrapper's backoff-restart loop.
  **Correction (2026-11):** the generated wrapper still ended at its first
  back-off (`MAX_RESTART_DELAY: unbound variable`) unless those variables were
  in the manager's environment; fixed in the 2026-11 audit [X-10].
- **Per-device audio config was ignored** — `lyrebird-mic-check.sh` wrote
  `DEVICE_<name>_*` keys in the wrong case for the stream manager's uppercase
  lookup; a "high quality" mic silently ran at defaults (and `--validate` passed).
- **ntfy/Pushover alerts were silently dropped** and falsely reported as sent.
- **Prometheus scrape was rejected** — duplicate `# HELP`/`# TYPE` lines.
- **Self-update always failed** — the updater deadlocked on its own lock after
  `exec`.
- **Orchestrator interactive delegations couldn't read input** (backgrounded
  child stdin was `/dev/null`) — the Quick Setup Wizard could not map devices.
- **Storage cleanup halted on a 0-byte file** (disk fill risk); emergency cleanup
  no longer deletes unrelated `/var/log/*.gz` or ignores `--dry-run`.
- **Diagnostics aborted on a healthy host** — `grep -c … || echo 0` produced a
  `0\n0` arithmetic error under `set -e`.
- **Webhook/JSON output is now valid** for control characters and backslashes.
- **Test suite repaired** — 159 tests silently never ran; source guards + `set -e`
  handling restored so all tests execute (and CI enforces them).

### Fixed (Reliability Hardening pass, 2026-07)
Deeper follow-up audit (6 parallel reviewers, every finding reproduced) closing
the pending HIGH items and a large MEDIUM/LOW sweep. Every fix ships with a
regression test; the suite is green (528 tests) and ShellCheck-clean.

- **Storage / data-loss:** `df` output was misparsed on wrapped long device
  names (LVM/`/dev/mapper`), so a FULL disk read as "OK" and cleanup never ran;
  empty-dir cleanup could delete the recording directory itself; oversized-log
  truncation swapped the inode out from under the writer (invisible unbounded
  growth); a non-integer retention env value aborted the script at load (crons
  silently stopped). Now POSIX `df -P` with guards, `-mindepth 1`, in-place
  truncation, and validated numeric inputs.
- **Metrics:** the Prometheus scrape silently aborted in the normal "streams up,
  no listeners" state (unguarded `curl`/`grep|wc` under `set -euo pipefail`), so
  `--file` mode served a STALE `.prom` with `up=1` — a dead recorder looked alive
  for months. Guarded all collectors; label values are now escaped.
- **Stream supervision:** the wrapper gave up after a LIFETIME (not windowed)
  restart count, so streams died off one by one over weeks; a dead stream was
  never resurrected under cron (now bounded per-stream resurrection); disk/memory
  pressure triggered a 5-minute service-restart storm that freed nothing (now
  degraded/alert-only). Generated logrotate now uses `copytruncate`.
- **Installer/updater:** a failed `update` left MediaMTX stopped indefinitely
  (rollback never restarted it); `update -V <ver>` ignored the pin and jumped to
  latest; a branch switch never fast-forwarded (no-op "success"); a self-update
  re-exec could strand the service on a prompt.
- **Alerts:** every CRITICAL Pushover alert was rejected (missing retry/expire);
  ntfy titles containing a colon were truncated. **Diagnostics:** a healthy-host
  run could abort mid-way; several checks read false "healthy" (inotify, disk,
  world-writable config perms, "recent crash", BusyBox reachability).
- **USB mapper:** closed a udev-rule injection via `-u`; made VID:PID-only naming
  visible; atomic rules-file write. **mic-check:** `--format=json` always emitted
  an empty list; config could pick an unsupported channel count.
- **Sample configs:** removed systemd `WatchdogSec` restart-loop traps (MediaMTX
  can't feed it; the manager's ping is rejected under default `NotifyAccess`),
  fixed the audio unit's `Type` (forking) and `StartLimit` placement, and made
  logrotate use `copytruncate`. Added config-file validation tests.
- **Tests/CI:** added a hardware-free end-to-end integration suite (stub MediaMTX
  API, mock webhook, disk-full, device-config round-trip); bumped ShellCheck
  0.10→0.11 (verified clean), shfmt 3.8→3.13.1, actions/checkout v4→v5.

See `docs/ENGINEERING-REVIEW-2026-07.md` for the full finding-by-finding detail.

## [1.4.2] - 2025-12-19

### Added
- Prometheus metrics export (`lyrebird-metrics.sh`)
- Storage management with configurable retention (`lyrebird-storage.sh`)
- Comprehensive test suite (~90 tests, ~50% coverage)
  - `test_usb_audio_mapper.bats` - 15 tests
  - `test_lyrebird_diagnostics.bats` - 16 tests
  - `test_lyrebird_orchestrator.bats` - 14 tests
  - Enhanced `test_stream_manager.bats` - 32 tests
- systemd service files with watchdog support
  - `config/mediamtx.service`
  - `config/mediamtx-audio.service`
  - **Correction (2026-11):** `WatchdogSec=` was removed from the shipped
    units in 1.3.0, and the stream manager's own watchdog code, which never
    opened a device, in the 2026-11 audit [LB-15].
- Log rotation configuration (`config/lyrebird-logrotate.conf`)
- Security documentation (`docs/SECURITY-GUIDE.md`) with optional TLS/auth guides
- `.gitignore` file to prevent accidental sensitive data commits

### Changed
- Updated stream manager version to 1.4.2
- README updated with new scripts and configuration files
- Comprehensive audit report documenting 64 issues

## [1.4.1] - 2025-12

### Added
- Friendly name support for device configuration in stream manager
- Dual-lookup config system (friendly names and full device IDs)

### Fixed
- Device configuration lookup now tries friendly name first, then full ID

## [1.4.0] - 2025-12

### Added
- Production stability and monitoring enhancements
- Heartbeat/watchdog integration with systemd
  - **Correction (2026-11):** there was no working watchdog. The hardware
    watchdog code never opened the device; what remains is a heartbeat file
    holding the time of the monitor's last run [LB-15].
- Network connectivity monitoring
- Resource threshold monitoring (CPU, memory, file descriptors)

### Changed
- Improved stream recovery with exponential backoff
- Better cron-based health monitoring

## [1.3.4] - 2025-12

### Fixed
- Resolved persistent stream failure issues
- Improved FFmpeg process lifecycle management

## [2.1.2] - 2025-12 (Orchestrator)

### Fixed
- Fixed broken integrations found in verification testing
- Improved menu navigation and user feedback

## [2.1.1] - 2025-12 (Orchestrator)

### Fixed
- Various bugs in menu handling
- Improved UI/UX responsiveness

## [2.1.0] - 2025-12 (Orchestrator)

### Added
- Microphone capability detection integration
- Security hardening for external script calls
- SHA256 integrity checking for sourced scripts

### Changed
- Improved hardware capability display
- Better error handling throughout

## [2.0.1] - 2025-12 (Orchestrator)

### Added
- Cross-platform support improvements
- Security fixes for input handling

## [1.5.1] - 2025-12 (Updater)

### Added
- Pre-execution syntax validation for self-updates
- Self-update safety checks

### Fixed
- Improved rollback reliability

## [1.5.0] - 2025-12 (Updater)

### Added
- Automatic systemd service lifecycle management
- Stop services before update, reinstall after
- Cron job update handling

## [1.2.1] - 2025-12 (USB Audio Mapper)

### Fixed
- USB port detection bug causing incorrect device-to-port mapping
- Improved physical port path resolution

## [1.0.2] - 2025-12 (Diagnostics)

### Added
- Cross-platform compatibility improvements

### Fixed
- Reliability fixes for various system configurations

## [2.0.1] - 2025-12 (MediaMTX Installer)

### Added
- Platform-aware installation (Linux/Darwin/FreeBSD)
- Automatic architecture detection (x86_64, ARM64, ARMv7, ARMv6)
  - **Correction (2026-11):** the installer has Darwin, FreeBSD and ARM
    branches, but no test in this repository runs on those platforms or
    downloads those builds; `tests/fetch_mediamtx.sh` fetches linux amd64
    releases only.
- SHA256 checksum verification
- Atomic updates with automatic rollback
- Dry-run mode for testing

### Changed
- Built-in upgrade support for MediaMTX 1.15.0+
  - **Correction (2026-11):** removed in installer 2.1.0. MediaMTX's own
    `--upgrade` applies no checksum, and MediaMTX 1.15.0 does not have the
    flag (`--help` lists it from 1.18.0; 1.16 and 1.17 were not checked)
    [X-41].

## [1.0.0] - 2025-12 (Mic Check)

### Added
- Hardware capability detection via `/proc/asound`
- Non-invasive detection (won't interrupt active streams)
- Automatic sample rate, channel, and format detection
- Quality tier recommendations (low/normal/high)
- Configuration generation and validation
- JSON output support

## [1.0.0] - 2025-12 (Common Library)

### Added
- Shared utility library (`lyrebird-common.sh`)
- Standardized color handling
- Common logging functions (debug, info, warn, error)
- Command existence checking with caching
- Portable hash computation
- Standard exit codes

---

## Version Numbering

The **suite** is released as a whole under a single `vX.Y.Z` git tag. The tags
are v1.1.0 (2025-10-11), v1.2.0 (2025-10-22) and v1.3.0 (2026-07-19), the latest
release. The release that will carry the [Unreleased] changes has no number yet.
The headings above that carry a version number and no component name (1.4.2,
1.4.1, 1.4.0 and 1.3.4) are versions of the stream manager, not tags of the
suite.

Each script also carries its own version. This table gives it as it is in
v1.3.0 and as it is in this tree, which is not released:

| Component | In v1.3.0 | In this tree |
|-----------|-----------|--------------|
| lyrebird-orchestrator.sh | 2.1.2 | 2.2.0 |
| lyrebird-stream-manager.sh | 1.4.3 | 2.0.0 |
| lyrebird-updater.sh | 1.6.0 | 1.8.0 |
| usb-audio-mapper.sh | 1.2.1 | 4.0.1 |
| lyrebird-diagnostics.sh | 1.0.2 | 1.0.2 |
| install_mediamtx.sh | 2.0.1 | 2.1.0 |
| lyrebird-mic-check.sh | 1.0.0 | 1.0.2 |
| lyrebird-common.sh | 1.0.0 | 1.1.0 |
| lyrebird-metrics.sh | 1.1.0 | 1.4.0 |
| lyrebird-storage.sh | 1.0.0 | 1.3.0 |
| lyrebird-alerts.sh | 1.0.0 | 1.1.0 |
| tools/soak/lyrebird-soak.sh | not in v1.3.0 | 1.0.0 |

## Links

- [GitHub Repository](https://github.com/tomtom215/LyreBirdAudio)
- [Issue Tracker](https://github.com/tomtom215/LyreBirdAudio/issues)
- [Discussions](https://github.com/tomtom215/LyreBirdAudio/discussions)

# Stream manager residual items (for the documentation pass)

Findings X-34, X-33, X-36, X-38, LB-23 (residual), X-11 (closure), X-18, and four small
defects found while the manager work was merged (called 8a to 8d below). Code:
`lyrebird-stream-manager.sh`, and `lyrebird-mic-check.sh` (device-config writers only).
Branch `worktree-agent-a5e44b298e6b5d4d6`, starting at `6f10415`. Commits:

| Item | Commit |
|------|--------|
| X-34 playback-only cards skipped | `a885ef3` |
| X-36 non-root `status` | `992342c` (+ fixture follow-up `73c3138`) |
| X-38 legacy MediaMTX config adopted | `10e3684` |
| LB-23 device config written durably | `0b63f4a` |
| X-33 tee muxer recording path | `e2ea073` |
| 8a SIGHUP reloads | `2782314` |
| 8b failed-validation stop | `1c5cec9` |
| 8c multiplex monitor ALSA pre-check | `f2099df` |
| 8d channels against codec | `562c134` |
| X-11 closure test | `55faab3` |
| X-18 inline-copy tests | `7d0a712` |

Evidence labels as in the register: R = reproduced by running the real code, S = read only,
HW = needs hardware.

## What the documentation must now say

### X-34: a card with no capture PCM (a USB speaker or DAC) is not a stream (R)

- A card the manager detects as USB audio but that has no `/proc/asound/card<N>/pcm<M>c`
  (and, when that directory lists no PCMs at all, no `pcmC<N>D<M>c` node) is **skipped**:
  no wrapper, no PID file, no start attempt. `start` logs one INFO line per such card:
  `Not streaming <device> (card N): no capture PCM (playback-only card); it is not counted for
  the start policy`, and the start list shows `[SKIP] <device> (card N): no capture PCM
  (playback-only card)` instead of `[FAIL]`.
- It is **outside the start policy**: `degraded` and `strict` count only capture-capable
  devices. One microphone plus one speaker satisfies `strict`. A node with only speakers
  behaves like a node with no device: `start` exits 0 (`No USB audio device that can capture:
  MediaMTX is running and waiting for devices`, `overall: waiting_for_devices`), or **6** with
  `LYREBIRD_ALLOW_EMPTY_START=false` (`No USB audio device that can capture (N playback-only
  card(s) skipped)`). In multiplex mode the multiplex stream is made of the microphones only,
  and the device set the monitor records and compares (`<stream>.devices`) is the microphones.
- `status` shows the device as `Status: Skipped (no capture PCM (playback-only card))` (no
  stream URL, no settings line) and, in the stream summary, `<device>: skipped (no capture PCM
  (playback-only card))`.
- **status.json / `status --json`** (schema_version stays 1): the card is listed with
  `configured:false`, `process_alive:false`, `path_ready:false`, `bytes_flowing:false`,
  `last_error:"no capture PCM (playback-only card)"` and an extra key **`"skipped":true`**.
  The key is present **only on skipped entries** (every other entry keeps exactly the shape
  documented in `stream-outcome.md`, which the status tests compare as a whole object).
  Consumers that count streams must ignore entries with `skipped:true`; `overall` already
  does. No other script in this repository reads status.json today (checked with grep), so
  nothing else needed adapting.
- The **monitor** leaves such a card out before it decides anything: no restart attempt, no
  restart budget charged, not a failed stream (it used to be reported degraded, exit 10, in
  every cycle). Logged at DEBUG per cycle; a node with only speakers logs `No USB audio
  device that can capture (N playback-only card(s) skipped); waiting for devices`.
- `start_ffmpeg_stream` itself still refuses such a card (returns 1 with the existing
  `Card N (...) has no capture PCM (a playback-only card?); it is not used for streaming`
  WARN); the callers now never ask it to.
- Residual risk (HW): the capture PCM list comes from `/proc/asound`; the tests model a
  speaker as a card directory with `pcm0p` only. A card whose `usbid` shows up before its PCM
  entries (a hot-plug in the middle of registration) would be skipped for one run and picked
  up by the next monitor cycle. Not observable without hardware.
- `stream-definition.md` ("Cards that cannot capture ... the lifecycle/D4 work should treat it
  as 'skipped'") and `stream-outcome.md` (the schema block) are updated by this.

### X-33: the recording path in the tee muxer argument (R, with the real FFmpeg 6.1.1)

- **The register's description was partly wrong.** Measured: `|` (ends the recording slave and
  starts a second output), `\` and `'` (consumed as the tee escape and quote: the recording went
  into a different directory, `a\|b` into `a|b`) and `%` (a pattern of the segment filename:
  "Invalid segment filename template") change what is written. `[`, `]`, `:` and blanks in the
  path do **not**: the slave's options end at the first `]` before the filename. A relative
  path whose first component contains a colon (`rtmp:x/y`) was read as a protocol name (an RTMP
  connection was attempted).
- Fixed by escaping, not refusing: `tee_segment_dir` puts a backslash before `| \ '`, doubles
  `%` and prefixes `./` to a relative path. The generated wrapper header gets
  `RECORDING_TEE_DIR` (the escaped `<AUDIO_RECORDING_PATH>/<stream>`); `AUDIO_RECORDING_PATH`
  stays the raw path (the wrapper creates the directory from it). `AUDIO_RECORDING_PATH` may
  therefore hold any of those characters when the manager is run directly (an apostrophe in a
  drive label, say). For a systemd install the unit work's rule is unchanged and still applies:
  `install` refuses to write the unit when `AUDIO_LOCAL_RECORDING=true` and `AUDIO_RECORDING_PATH`
  has anything outside letters, digits and `_ . / + -` (`_unit_safe_path`: `Cannot write the unit:
  AUDIO_RECORDING_PATH ... is not an absolute path of letters, digits and _ . / + - only`).
- `stream-definition.md` "New defects found while verifying" (the first bullet) is superseded.

### X-36: `status` without root (R)

- `show_status` identifies each wrapper with the ownership helpers (`stream_wrapper_state`:
  `read_pid_safe` plus the `/proc` image check) instead of `kill -0`. A wrapper that is there but
  whose `/proc/<pid>/exe` the caller cannot read (another user's process) prints
  `Status: Unknown (PID: n; its /proc entry cannot be read, so it cannot be identified: run as
  root)`, never `Not running`; its PID file is kept and nothing is signalled. A dead wrapper, or a
  PID that is another program, is still `Not running`. The multiplex wrapper likewise (its state
  also decides whether the multiplex listing is shown).
- `stream-ownership.md`: the sentence "Non-root `status` still prints stream wrappers as 'Not
  running' ... (not changed here)" is resolved.

### X-38: the MediaMTX configuration an earlier release wrote is adopted (R)

- A `mediamtx.yml` whose **first line is exactly `# MediaMTX Configuration - Audio Streams`**
  (trailing blanks and a CRLF ending ignored, like the marker) is what the generator of the
  earlier releases wrote on every start. It is now managed: the first start after the upgrade
  replaces it with the current rendering (API and metrics on the loopback address by default,
  the new defaults of `mediamtx-config.md`), after the usual timestamped backup
  (`mediamtx.yml.<UTC stamp>.<nn>.bak`, same mode and owner, newest `MEDIAMTX_CONFIG_BACKUPS`
  kept), and logs one INFO: `MediaMTX configuration <file> was written by an earlier release of
  <script> (first line '# MediaMTX Configuration - Audio Streams'), which regenerated it on every
  start (no edit of yours could have survived it): replacing it with the current rendering ...,
  after a timestamped backup`. The rendering is validated first; one MediaMTX rejects leaves the
  old file and the start fails as for any managed file. From then on the file carries the marker.
- **Not adopted** (still the operator's, never rewritten, one WARN per start): the file
  `install_mediamtx.sh` writes, any other first line, the legacy text on a later line or with
  anything added, another case. Fact for the docs: the installer's `create_config` writes a row
  of `#` as its first line and `# MediaMTX Configuration` as the second (so it could not be
  confused with the legacy line either way).
- `mediamtx-config.md` "Upgrade effect to document" (an earlier release's file is treated as
  the operator's after the upgrade, and the "Decision for the lead") is superseded; the
  upgrade note for the README/SECURITY-GUIDE becomes: the first `start` (or `reload`) after the
  upgrade rewrites a legacy-first-line file, the old file is kept as a `.bak`; an operator who
  edited that file by hand (and kept the first line) loses the edit from the live file, as the
  old generator would have done at the next restart, and finds it in the backup.
- Side effect worth knowing: on a node that already has such a file (the machine these tests
  ran on had one in `/etc/mediamtx`), the live test "every path the manager writes by default is
  writable under the unit" had failed because the legacy file counted as operator-owned and was
  not written; it passes now (its `/etc` is an overlay, the host file was not touched).

### LB-23 residual: the device config is written durably (S for the power cut, R for the order)

- `save_device_config` (the template `config` and `start` create) and `lyrebird-mic-check.sh`'s
  `generate_config` and `restore_config_backup` replace `/etc/mediamtx/audio-devices.conf` with
  `lyrebird_atomic_write` (temp file in the same directory, fsync, rename, fsync of the
  directory). Modes and owners as before (0644; a restore keeps the backup's mode, which is
  0600 for the backups mic-check makes, and its owner). A failed write leaves the old file and
  no temp file; `save_device_config` returns 1 (start goes on with the defaults and a WARN,
  `config` exits non-zero). `create_config_backup` (the timestamped copy) is unchanged.
- Where `lyrebird-common.sh` is missing or older, mic-check defines a local fallback (temp
  file + rename, no fsync), as `lyrebird-alerts.sh` does; the manager requires the library (it
  already did for the MediaMTX configuration).
- Not verifiable here (HW): that a power cut leaves the file intact; only the order of the
  operations is tested.
- `mediamtx-config.md` ("`save_device_config` ... still writes with mktemp + mv") is resolved.

### 8a: SIGHUP reloads instead of restarting (R)

- For a run that is not under systemd the HUP handler (`on_sighup`) runs the same reload as the
  `reload` command; it used to run `restart_mediamtx` under a comment that said reload, so a
  terminal hang-up during an interactive command stopped every stream. While the process holds
  the lifecycle lock (it is in the middle of its own start, stop, restart, reload, force-stop or
  monitor cycle) the signal is logged and ignored (`Received SIGHUP while a lifecycle command is
  running in this process; not reloading`): a nested start could launch a second wrapper for a
  stream whose first one is not recorded yet. `SIGUSR1` (status dump) is unchanged. Under
  systemd neither handler is installed, as before.
- Docs: nothing in README or docs/ describes the SIGHUP behaviour; if a sentence is added,
  "SIGHUP of an interactive run = `reload`, no outage".

### 8b: a stream that fails its own validation (R)

- `start_ffmpeg_stream` stops the wrapper with `stop_ffmpeg_stream` (identity, SIGTERM then
  SIGKILL, waits) and removes its PID file, `<stream>.pid.id` and the wrapper script; the FFmpeg
  log stays. A wrapper that cannot be stopped keeps its PID file and an ERROR says so.
  `stream-outcome.md` ("`start_ffmpeg_stream`'s own validation and its bare `kill "$pid"` on
  failure are unchanged. Two consequences seen in the tests ...") is resolved.

### 8c: the multiplex monitor checks ALSA before charging the budget (R)

- All five multiplex restart decisions of `monitor_streams` (no PID file, invalid PID, stale
  PID, stuck path, changed device set) ask `monitor_multiplex_cards_available` first: the
  multiplex stream may be restarted when at least one of its devices can be opened; otherwise
  `Multiplex stream S: ALSA device not available (card 31, 33), skipping restart`, the stream
  counts as failed (exit 10) and `CRON_RESTART_MAX_PER_HOUR` is not charged. `stream-outcome.md`
  ("The multiplex branches of the monitor still charge the restart budget without an ALSA
  pre-check", and "Multiplex has no such pre-check") is resolved.

### 8d: an individual stream's CHANNELS against its codec (R, real FFmpeg 6.1.1)

- Before the wrapper is written, `start_ffmpeg_stream` asks FFmpeg (`check_individual_encoding`)
  whether it can encode CHANNELS channels as CODEC: the wrapper's encoder arguments and `-af`
  over 0.1 s of silent lavfi input with that channel count, to the null muxer; no table of
  counts. Measured with the wrapper's own arguments: opus accepts 1, 2, 3, 5, 6, 7 and 8
  channels and refuses 4 and 9 or more; aac accepts 1 to 8 and refuses 9 or more; mp3 accepts 1
  to 8 (and 9 refused, 10 and 12 accepted, an artefact of FFmpeg's layout names for those
  counts). On a refusal the stream is not started (`start_ffmpeg_stream` returns 1, no wrapper,
  PID file or log) and the log says `Stream <path> not started: FFmpeg cannot encode <N> channels
  as <codec> (<bitrate>): <FFmpeg's first error line>` and `Set the channel count of this device
  (DEVICE_<NAME>_CHANNELS) to one that <codec> can encode, or its codec (DEVICE_<NAME>_CODEC) to
  aac`. A check that cannot be made (no ffmpeg or timeout, no lavfi, 20 s timeout) or a question
  that cannot be put (a channel count or rate that is not a number, a codec with no encoder
  arguments: the settings were validated earlier) never stops a stream.
- README: the individual-mode `CHANNELS` text should say a count the codec cannot encode stops
  that stream with the error above (`status.json` shows `the stream could not be started (see
  ...)`; the reason is in the manager log). `stream-definition.md` ("Not changed ... The
  individual mode CHANNELS against the codec ... is not checked before launch ... (residual)")
  is resolved. The individual wrapper keeps its own `case "${CODEC}"`; a test compares its arms
  with the words the check uses (`multiplex_encoder_args`).

### X-11 closure

Both halves were fixed earlier (YAML: canonical name and quoted path key; systemd: the name is
canonicalised once, `systemd_escape_env_value` and the renderers' refusals). Tests that prove it,
exact names:

- YAML side (`tests/test_stream_names.bats`): "a name with a newline and YAML syntax becomes one
  harmless line [LB-04]", "a hostile name cannot add a YAML key to the generated config
  [LB-04]", and the live "a name with a newline and a runOnInit line starts MediaMTX without
  running the injected command [LB-04, live]"; (`tests/test_mediamtx_config_render.bats`) "any
  printable stream name comes back from a YAML parser as exactly that one path name [LB-04]",
  "a stream name with a control character, a line break or a non-ASCII byte is refused, so it
  cannot inject YAML [LB-04]"; (`tests/test_mediamtx_config_ownership.bats`) "multiplex mode
  renders one quoted path; a stream name that is not a plain scalar cannot inject YAML [LB-04,
  LB-22]".
- systemd side (`tests/test_stream_manager_unit.bats`): "render_systemd_unit: stream mode,
  filter and name reach the unit, the name escaped for systemd (round trip) [LB-11, X-11]",
  "render_systemd_unit refuses what the unit file cannot carry and prints no unit: a newline in
  the name, a bad mode or filter, a path with a space [LB-11, X-11]", "the rendered unit is
  accepted by systemd with zero findings ... [LB-11, LB-12]" (with a name needing escaping).
- cron file (same file): "the cron file carries only values that need no quoting: the name is
  limited to letters, digits, _ and - [LB-11, X-11]" (includes a name with a newline and a
  second assignment), "the cron file sets the stream mode, the filter and the multiplex name
  ... [LB-11, X-11]".
- **Added** (`tests/test_stream_manager_unit.bats`): "a hostile multiplex name cannot add a
  systemd directive, a cron line or a YAML key: it is made canonical once and the unit, the
  cron file and the MediaMTX config carry that one name [X-11]": one hostile name through the
  real `main -m multiplex -n NAME install`, the unit and the cron file differ from a benign
  install in exactly the one name line, `systemd-analyze verify` is clean, a name too long is
  refused with exit 4 and nothing is written, and the generated MediaMTX config has one quoted
  path and no injected key.

### X-18: inline-copy tests

`tests/test_stream_manager.bats` went from 36 to 29 tests. Nine inline-copy tests were removed
(each with the covering test named in commit `7d0a712`), nineteen converted to the real functions
(sanitize_path_name, check_version_compatibility, read_pid_safe, stream_outcome_expect, the
script's own defaults, check_network_connectivity, check_disk_space, AUDIO_RTBUFSIZE), eight
(the wrapper, cron and resource regressions) were already real. The file's `setup()` now
points the manager's log at a private file (the SM-2 and SM-4 tests used to write
`/var/log/lyrebird-stream-manager.log` of the machine).

## Existing tests changed (each justified in its commit)

- Fixtures that stood in for a microphone with a card that has no capture PCM now give it one
  (since such a card is a speaker): `tests/test_mediamtx_ports.bats`,
  `tests/test_deep_health_check.bats`, `tests/test_stream_manager_unit.bats` (cron monitor),
  `tests/test_stream_device_config.bats` (status test). Fixtures that pretended a live process
  was a wrapper by PID alone now start a real process that runs `<wrapper dir>/<stream>.sh`
  (`status` identifies a wrapper by what it runs): `tests/test_mediamtx_ports.bats` (multiplex
  status), `tests/test_stream_names.bats` (the `-n` test).
- `tests/test_storage_codecs.bats` "a real FFmpeg recording per manager CODEC is covered by
  retention cleanup [X-14 regression]" defines `RECORDING_TEE_DIR`, the variable the manager's
  segment spec now names (assertions unchanged).
- `tests/test_mediamtx_config_ownership.bats`: "the warning says when the operator-owned file is
  the one an earlier release wrote, whose API is on every interface [LB-06]" encoded the
  behaviour X-38 changes and is replaced by four tests.
- `tests/manager_stage.bash` gains `device_add_playback`.

## Deviations from the register and decisions made

- X-33: escaped instead of refused (the register allowed either); the finding's list of
  characters was corrected by measurement (above).
- X-34: the register asks for "skipped/`configured:false`"; the extra `skipped:true` key is
  present only on skipped entries so the existing exact-shape status test and any consumer of
  the other entries are unaffected.
- X-38: the lead described the installer's first line as `# MediaMTX Configuration`; it is a row
  of `#` (the heading is the second line). Both are tested as not adopted.
- 8a: besides making the handler reload, it ignores the signal while this process itself holds
  the lifecycle lock (not in the brief): a reload nested in the interrupted command can double
  start a stream.
- 8d: the individual wrapper's own `case "${CODEC}"` was not replaced by header arguments
  (`tests/test_storage_codecs.bats` reads those arms); equality with what the check uses is
  tested instead.
- X-18: where the "function" a test re-defined does not exist in the manager at all
  (version_compare, is_valid_pid, ...), the test was converted to the closest real behaviour
  of the script (or removed where a real test already covers it), as listed in `7d0a712`.

## New defects found (not fixed: outside the brief)

- **P3, non-root `status`:** the `Resources:` line of MediaMTX prints `FDs=0` followed by a line
  `?, CPU=0.0%, Threads=1`: `fd_count=$(find /proc/$pid/fd ... | wc -l || echo "?")` prints both
  `0` (from `wc`) and `?` when `find` fails with EACCES under `pipefail`, the `$(... || echo)`
  class of `docs/ENGINEERING-REVIEW-2026-07.md` section 1. Seen in the output of the X-36 tests.
- **P3, `check_network_connectivity`** keeps its failure counter in `/run/mediamtx-network-failures`,
  a fixed path (every other state path is configurable, D15's spirit): a test of it writes the
  machine's `/run` unless run in a private mount namespace, which the converted test does.
- **P3, hot-plug window (HW):** see the X-34 residual risk.
- **Note, not a defect:** `exit_critical_section` sets the HUP/USR1 traps again after every lock
  acquisition even in a process that only *sourced* the script (the main-guard block sets them
  only for an executed script), so any sourcing process that takes the lock gets the handlers.
- **Environment:** `/etc/mediamtx/mediamtx.yml` on the machine these tests ran on is a
  legacy-first-line file left by an earlier run; it explains the pre-existing live test failure
  described under X-38 and is the real-world case the adoption handles. It was not modified.

## Test counts for `tests/README.md`

`bats --count tests/` is **1504** on this branch (1459 before). New files: `test_stream_playback_only.bats`
11, `test_stream_status_nonroot.bats` 3 (needs root and setpriv), `test_device_config_durable.bats`
10, `test_stream_recording_path.bats` 5 (real ffmpeg), `test_stream_manager_sighup.bats` 5,
`test_stream_manager_residuals.bats` 13 (the 8d ones use the real ffmpeg). Changed:
`test_stream_manager.bats` 36 to 29 (the README row says 39, stale), `test_mediamtx_config_ownership.bats`
38 to 41, `test_mediamtx_config_live.bats` 11 to 12 (live), `test_stream_manager_unit.bats` 24 to 25.
The README table's stream-manager rows need these added; the live test count under
`test_mediamtx_config_live.bats` becomes 12.

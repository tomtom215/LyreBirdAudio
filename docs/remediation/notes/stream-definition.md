# Stream definition notes (for the documentation pass)

Findings LB-04, LB-08, LB-09, LB-24, X-01, X-09, X-10, X-11 (wrapper side), X-15,
X-20, X-28; decisions D3 and D13. Code: `lyrebird-stream-manager.sh` (sections
"Canonical stream names", "Device configuration", the wrapper generator, the
capture-PCM helpers, the multiplex graph) and, for the writer only,
`lyrebird-mic-check.sh`. Tests: `tests/test_stream_log_variables.bats`,
`tests/test_stream_names.bats`, `tests/test_stream_device_config.bats`,
`tests/test_stream_wrappers.bats`, `tests/test_stream_capture_pcm.bats`,
`tests/test_stream_multiplex_graph.bats`, helper `tests/stream_definition_helper.bash`.

## X-15: two log variables

- `STREAM_MANAGER_LOG_FILE` (new): the manager's own log, default
  `/var/log/lyrebird-stream-manager.log` (unchanged default).
- `MEDIAMTX_LOG_FILE`: now means only "where the MediaMTX process's output goes"
  (default `/var/log/mediamtx.out`). Before, the manager's own log followed it too, so
  an operator who set `MEDIAMTX_LOG_FILE` got the manager's messages mixed into
  MediaMTX's file and the default manager log stayed empty.
- README (`Environment Variables`, `MEDIAMTX_LOG_FILE="/var/log/mediamtx.out"` example,
  about line 571) and `docs/configuration.html` (line ~179) list only `MEDIAMTX_LOG_FILE`:
  add `STREAM_MANAGER_LOG_FILE` next to it. Upgrade note: an installation that set
  `MEDIAMTX_LOG_FILE` and relied on the manager log being in that same file must set
  `STREAM_MANAGER_LOG_FILE` to keep it there. The systemd unit's
  `StandardOutput=append:` already names the default manager log path and the unit
  generator writes `${LOG_FILE}` there, so under systemd nothing changes unless the
  variable was set.
- Tests that used `MEDIAMTX_LOG_FILE` as "the manager's log" were changed to
  `STREAM_MANAGER_LOG_FILE` (`test_stream_manager_locks.bats`, `test_deep_health_check.bats`).
  Any other worker's test that points `MEDIAMTX_LOG_FILE` at a temp file to capture the
  manager's log must do the same, otherwise the manager writes to
  `/var/log/lyrebird-stream-manager.log`.

## LB-04 / D13: one canonical stream name

- New functions: `canonical_stream_name NAME` (stdout: the name; stderr + status 1: the
  reason), `is_canonical_stream_name`, `resolve_multiplex_stream_name`, `visible_text`
  (renders an untrusted string safely in a log line).
- Rule: lower-case; every run of characters outside `[a-z0-9_-]` (spaces, `/`, `.`,
  accented letters, a newline, any byte) becomes one `_`; leading `_`/`-` are removed
  (the first character must be a letter or digit); a name that is already canonical is
  returned unchanged; at most 64 characters (a longer name is rejected, not truncated);
  at least one letter or digit; reserved words rejected: `control`, `stats`, `api`,
  `metrics`, `health` (the old list) and `all`, `all_others` (new: MediaMTX treats both as
  a catch-all path name, verified on 1.15.0 and 1.21.1 with real binaries; `all-others` is
  an ordinary name on those versions).
- Examples: `Studio Mix` -> `studio_mix`, `Studio` -> `studio`, `a/b` -> `a_b`,
  `my.mix` -> `my_mix`, `Étude` -> `tude` (each non-ASCII byte is replaced), `9lives` -> `9lives` (a leading
  digit is allowed; the old code prefixed `stream_` for the publisher only), `My-Mix_2` ->
  `my-mix_2` (hyphen kept; the old publisher turned it into `_`).
- Applied once: `main` calls `resolve_multiplex_stream_name` right after
  `parse_arguments` (not for `help`). `-n/--name` and the `MULTIPLEX_STREAM_NAME`
  environment variable both pass through it. One INFO line is logged when the result
  differs from what was typed (`Multiplex stream name 'Studio Mix' is used as 'studio_mix'`),
  nothing when it does not. After that every consumer reads the canonical value: the
  publisher/wrapper, `<name>.pid`/`.sh`/`.log`, `status`, `monitor`, the display, the
  systemd `Environment=MULTIPLEX_STREAM_NAME=` line written by `install`, and the YAML
  path key the generator writes.
- An unusable name (reserved, no letters/digits, too long) stops the command with
  **exit 4** (`E_CONFIG_ERROR`) and the message `Invalid multiplex stream name: <reason>`
  when it will be used (multiplex mode) or was given with `-n`; no cleanup marker is
  left. In individual mode a stale `MULTIPLEX_STREAM_NAME` environment value is replaced by
  `all_mics` with one WARN (the name is not used there).
- `start_ffmpeg_multiplex_stream` no longer sanitizes: it refuses (status 1, nothing
  written) a name that is not canonical. `monitor_streams` uses the same name (it used
  to re-sanitize, which turned `my-mix` into `my_mix`).
- Individual-mode stream paths are unchanged for every name the code produced before.
  Only a card id that is one of the reserved words (`api`, `stats`, `control`, `metrics`,
  `health`, and now `all`, `all_others`) gets a `stream_` prefix, as the sanitizing
  route already did.
- What the YAML generator must do (other worker): quote the path key. The canonical charset
  is always safe in a quoted scalar; an unquoted key such as `null`, `yes` or `123` may
  be read by a YAML parser as a non-string (not tested here, the generator is not part of
  this change). MediaMTX 1.15.0 and 1.21.1 load and publish to `'null'`, `'yes'` and
  `'123'` when the key is quoted (hand-written config, test `canonical names that YAML
  reads as null, bool or number load and publish when the key is quoted`).
- README to correct: any statement that a multiplex stream name may contain spaces,
  capitals or dots; `-n NAME` help: "lower-case letters, digits, `_` and `-`, at most 64
  characters; anything else is replaced by `_` and the result is logged".

## LB-08 / X-09 / X-01 / X-28, D3: the device config is data

- **No `source`, no `eval`.** `parse_device_config` reads `audio-devices.conf` line by line
  with an allowlist. One loader, `load_device_config`, serves `start`, `restart`
  (through `generate_mediamtx_config`), `monitor` restarts, `status` and `validate`.
  `get_device_config` and the new `resolve_stream_settings` load it themselves when no earlier
  step has (`ensure_device_config_loaded`), so no caller can see defaults only (X-01:
  after the first monitor restart every per-device setting used to revert to the default).
- **Format.** One `DEVICE_<NAME>_<SETTING>=value` per line. `<NAME>` is the friendly stream
  name or the full device name, upper-cased with other characters as `_` (lookup order
  unchanged: friendly name first, then device name, then the default). `<SETTING>` is one of
  `SAMPLE_RATE`, `CHANNELS`, `CODEC`, `BITRATE`, `THREAD_QUEUE`. Blank lines and `#` comments
  are ignored (a comment may follow a value: `...=192k   # high`). A value is bare,
  `'single-quoted'` or `"double-quoted"`, taken literally; `$`, backticks and backslashes
  are not interpreted (inside double quotes they are an error). No spaces around `=`.
  CRLF line endings and a UTF-8 byte order mark are accepted.
- **Values** (anything else is an error naming the file, line, key and what is expected):
  `SAMPLE_RATE` one of 8000 11025 12000 16000 22050 24000 32000 44100 48000 88200 96000 176400
  192000 352800 384000 705600 768000 (all of them go through libopus, aac and libmp3lame in
  FFmpeg 6.1.1: the encoder negotiates its own rate; the ALSA device is the real limit and is
  not known here); `CHANNELS` 1 to 32; `CODEC` `opus`, `aac` or `mp3` (any case);
  `BITRATE` `1k` to `9999k` (`k` or `K`; a plain number such as `128000`, which FFmpeg would have
  taken, is now an error: the README only documents the `NNNk` form); `THREAD_QUEUE` 1 to 1048576. Leading zeros are removed.
- **X-28.** A `CODEC` outside `opus|aac|mp3` (the old sample comment `pcm_s16le`, the README's
  `pcm`) is rejected when the file is read, with `expected: one of opus, aac, mp3`; the
  setting keeps its default, so the wrong-extension recording segment (`audio_000.pcm_s16le`)
  can no longer happen. A `DEFAULT_CODEC` (and the other `DEFAULT_*` environment variables)
  that is not valid falls back to the built-in default (`opus`, 48000, 2, 128k, 8192) with an
  error in the log. The template `save_device_config` writes no longer uses `pcm_s16le`.
- **A bad file never stops streams.** An invalid line is skipped, logged
  (`Device config <file>:<line>: <KEY>: <problem> (expected: ...)`, at most 50 lines, the
  rest counted, parsing stops after 100 problems) and the setting keeps its default. Nothing
  exits, aborts or touches the manager's traps. `start` used to stop with exit 4
  (`Configuration validation failed`) for a config with a syntax error; it now logs
  `Device configuration has problems (listed above); ...` and starts. A file larger than
  64 KiB, a line longer than 4096 characters, a directory or FIFO in place of the file are
  one problem each. The same findings are logged once per process.
- **New command `validate`**: `lyrebird-stream-manager.sh validate` parses the file (no root
  needed, read-only, leaves no cleanup marker) and exits `0` ("OK (N setting(s))", also for a
  missing file) or `4` (`E_CONFIG_ERROR`, "N problem(s), see above"). Document it next to
  `config` in the command table and in the exit-code description. `status` now prints a
  `Settings: 48000 Hz, 2 ch, opus 128k` line per device (and for the multiplex stream), so it
  reads the file too.
- **Behaviour changes to mention.** (1) Mixed-case keys such as `DEVICE_Blue_Yeti_SAMPLE_RATE`,
  which the pre-C4 `lyrebird-mic-check.sh` wrote and which were silently ignored because the
  lookup is upper-case, are now read as upper-case with one WARN, so those settings
  start to apply. (2) The per-device variables are no longer taken from the environment
  (`DEVICE_X_CODEC=aac lyrebird-stream-manager.sh start` used to work by accident); the file is the
  only source. (3) `DEFAULT_*=...` lines in the file (the README suggests
  `echo 'DEFAULT_THREAD_QUEUE=16384' >> audio-devices.conf`) were always ignored (readonly) and
  are now an error line with a hint: set the environment variable instead. (4) Duplicate keys:
  last line wins (as with `source`), with a WARN naming the earlier line. (5) No mode or
  ownership check on the file was added (not required): it is still chmod 644 root-owned in
  practice; because nothing in it runs, a writable config can no longer run code as root but a
  bad one still degrades the streams it names.
- **README to correct**: `Text (bash environment variables)` (file formats table, ~L542) ->
  "Text, one `DEVICE_<NAME>_<SETTING>=value` per line; read as data, never executed"; the
  settings list (~L525-530): drop `pcm` from the codecs, add the allowed values above, the
  `validate` command; ~L1377 `DEFAULT_THREAD_QUEUE=16384 >> audio-devices.conf` -> set it in
  the environment; ~L654-657 "a corrupted file never stops streams" is now true (say so for
  invalid lines too, not only for corruption); the "Sample Rate Selection" list is fine.
  `lyrebird-mic-check.sh` header comments ("This file is sourced by ...") are corrected
  with the writer change.
- Tests changed: `tests/test_e2e_integration.bats` "a per-device config (mic-check key format)
  is honored by stream-manager" `source`d the config itself before calling `get_device_config`;
  the manager no longer does that, so the test now calls `load_device_config`
  (`MEDIAMTX_DEVICE_CONFIG`). The assertion (96000 is honoured) is unchanged.

## LB-24: the capture PCM is not always 0

- **What changed.** `check_audio_device`, `check_alsa_device_available`, `check_audio_level`, the
  individual wrapper (`plughw:CARD,PCM` input and its "device still exists" check) and the
  multiplex wrapper (one PCM per input device) no longer assume ALSA PCM device 0. New
  functions: `alsa_capture_pcms CARD` (the N of every `/proc/asound/card<CARD>/pcm<N>c`
  directory, ascending; if there is none, the `pcmC<CARD>D<N>c` device nodes) and
  `resolve_capture_pcm CARD DEVICE_NAME [STREAM_PATH]` (sets `STREAM_PCM`).
  `check_audio_device`, `check_alsa_device_available` and `check_audio_level` take the PCM as an
  optional last argument and default to the card's first capture PCM.
- **New setting `DEVICE_<NAME>_PCM`** (0 to 255), same lookup order as the other settings
  (friendly stream name, then device name). It must name a capture PCM of the card; if it does
  not, an ERROR is logged (`PCM 0 set for three is not a capture PCM of card 3 (capture PCMs: 1);
  using 1`) and the first capture PCM is used. In multiplex mode each input device has its own
  `DEVICE_<NAME>_PCM` (looked up by the device's own stream path, as in individual mode); the
  other multiplex settings still come from the first device and the multiplex stream name.
  Document it in the README settings list and next to the `lyrebird-mic-check.sh` example.
- **Cards that cannot capture** (a playback-only USB speaker or DAC) are left out with one WARN,
  `Card N (<device>) has no capture PCM (a playback-only card?); it is not used for streaming`:
  `start_ffmpeg_stream` returns 1 (the start summary counts it among the failed streams; the
  lifecycle/D4 work should treat it as "skipped", not as a failed stream) and the multiplex
  start leaves the card out of the mix.
- **New environment variables for tests**, defaults unchanged: `ASOUND_PROC_ROOT`
  (`/proc/asound`) and `DEV_SND_ROOT` (`/dev/snd`). `detect_audio_devices`,
  `generate_stream_path` and the `controlC` check in `start_all_ffmpeg_streams` still read the
  real paths directly (other workers' functions); only the capture checks use the roots.
  The wrappers carry `DEV_SND_ROOT` and `PCM_NUM` (multiplex: `PCM_NUMBERS`, parallel to
  `CARD_NUMBERS`) as variables.
- **Needs hardware (not verified here).** The tests run over fake `/proc/asound` and `/dev/snd`
  trees and a stand-in for `arecord -l`; nothing shows how a real USB card lays out its PCMs
  (capture on device 0 or 1, several capture PCMs), that `plughw:CARD,PCM` opens the intended
  stream, or what a second open of a busy capture device does. `arecord -l` is still only
  checked per card. The template written by `save_device_config` mentions the setting
  (`# DEVICE_BLUE_YETI_PCM=1`).

## lyrebird-mic-check.sh: the writer (D3)

- `generate_config` now writes quoted values (`DEVICE_BLUE_YETI_SAMPLE_RATE="48000"`,
  `..._CHANNELS="2"`, `..._BITRATE="192k"`), so its output is exactly what the manager's
  parser accepts; unquoted files written by earlier versions are still read (bare values are
  accepted). `lyrebird-mic-check.sh --validate` still `source`s the file (a copy of it); that
  part was not changed. Its header comments now say the file is read as data and list
  `CODEC` and `THREAD_QUEUE` as settings you can add by hand.
- The scan loop in `generate_config` reads the card directories from `ASOUND_PROC_ROOT`
  (default `/proc/asound`) so tests can run the real writer over a fake tree.
- **New defect fixed in the same place: the generated header was silently missing.** The header
  heredoc is unquoted and contained `${name^^}` and `${param^^}` inside a comment (added by
  the C4 fix); under the script's own `set -u` that is `name: unbound variable`, the `cat`
  failed and the whole header (quality tier, format description, the note that `DEFAULT_*`
  are not read from the file) was missing from every generated config. Reproduced with the
  real `generate_config` over a fake card; the comment no longer expands anything. README
  text that says the generated file "starts with a header describing ..." is true again.

## New defects found while verifying (not fixed here)

- The generated wrappers refer to `MAX_RESTART_DELAY` and `INITIAL_RESTART_DELAY` but never
  define them (the manager's copies are `readonly`, not exported): under the wrapper's own
  `set -euo pipefail` the first back-off computation after an FFmpeg failure aborts the
  wrapper with `MAX_RESTART_DELAY: unbound variable`. Reproduced by running a generated
  wrapper for real: it logged `Failed to start FFmpeg` and ended with exit code 1 instead of
  waiting and retrying (fixed in the wrapper commit, see below).
- The cron line written by `install` (`.../lyrebird-stream-manager.sh monitor`) does not
  carry `STREAM_MODE`, `MULTIPLEX_STREAM_NAME` or `MULTIPLEX_FILTER_TYPE`, so the cron
  `monitor` always runs in individual mode: on a multiplex node it finds no per-device PID
  files and tries to start individual streams next to the multiplex stream (read from
  `create_systemd_service` and `monitor_streams`, not reproduced end to end). Owner: units
  and monitoring.

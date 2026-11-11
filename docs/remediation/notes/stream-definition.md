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

## New defects found while verifying (not fixed here)

- The cron line written by `install` (`.../lyrebird-stream-manager.sh monitor`) does not
  carry `STREAM_MODE`, `MULTIPLEX_STREAM_NAME` or `MULTIPLEX_FILTER_TYPE`, so the cron
  `monitor` always runs in individual mode: on a multiplex node it finds no per-device PID
  files and tries to start individual streams next to the multiplex stream (read from
  `create_systemd_service` and `monitor_streams`, not reproduced end to end). Owner: units
  and monitoring.

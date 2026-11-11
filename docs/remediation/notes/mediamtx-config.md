# MediaMTX configuration and endpoint notes (for the documentation pass)

Findings LB-06 (manager side), LB-13, LB-22, LB-23, X-19; decisions D9, D10, D14,
D15. Code: `lyrebird-common.sh` ("MediaMTX Configuration Renderer"),
`lyrebird-stream-manager.sh` (port variables, `mediamtx_api_*`,
`mediamtx_config_*`, `generate_mediamtx_config`, `start_mediamtx`). Tests:
`tests/test_mediamtx_ports.bats`, `test_mediamtx_config_render.bats`,
`test_mediamtx_config_ownership.bats`, `test_mediamtx_api_probe.bats` (no MediaMTX
needed) and `test_mediamtx_config_live.bats`, `test_mediamtx_api_live.bats`,
`test_mediamtx_e2e_ports.bats` (real MediaMTX binaries, skipped unless
`LYREBIRD_TEST_MEDIAMTX_BINS` is set). Helpers: `tests/mediamtx_live_helper.bash`,
`tests/helpers/mediamtx/http_stub.py`, `tests/helpers/mediamtx/curl_shim`.

## What the documentation must now say

### Ports (X-19, D15)

- `MEDIAMTX_RTSP_PORT` (8554), `MEDIAMTX_API_PORT` (9997), `MEDIAMTX_METRICS_PORT`
  (9998) are read once by the manager. A decimal integer 1-65535 is required (leading
  zeros are fine and are not octal; an empty value means the default). Anything else
  ends the run with exit code **4** and `MEDIAMTX_API_PORT must be an integer from 1
  to 65535 (got: ...)`, for every command (`help` included): an invalid port is never
  replaced by the default. The three ports must differ (the renderer refuses
  otherwise, which fails `start`).
- They reach the generated configuration, the port-in-use check, the readiness and
  API probes, the stream probe, the wrappers' publish URL and every URL the manager
  prints. A wrapper carries `MEDIAMTX_RTSP_PORT` as a variable next to
  `MEDIAMTX_HOST`.
- New helpers for other code: `mediamtx_rtsp_base` (`rtsp://HOST:PORT`),
  `rtsp_publish_url PATH`, `mediamtx_api_root`. The silence/dead-mic probe of D6 must
  use `rtsp_publish_url`.
- **Not carried into the systemd unit or the cron file** by `create_systemd_service`
  (unit phase). A non-default value must be in the environment of **both** the service
  and the monitor: `Environment="MEDIAMTX_RTSP_PORT=..."` (and API/metrics, and
  `MEDIAMTX_API_BIND`, `RTSP_AUTH_MODE`, `RTSP_USERS_FILE` where used) in the unit, and
  `NAME=value` lines before the job line of `/etc/cron.d/mediamtx-monitor` (cron does
  not inherit the unit's environment). A monitor-driven stream restart regenerates the
  wrapper from the monitor's environment: without the variable it would publish to
  8554. The same applies to `STREAM_MODE` and `MULTIPLEX_*`, which the cron line does
  not carry either (not mine; found on the way).
- Still hard-coded `8554` (owned by the process-ownership work, which removes them
  under D11): the `pgrep`/`pkill -f "^ffmpeg.*rtsp://${MEDIAMTX_HOST}:8554"` patterns
  in `is_restart_scenario`, `cleanup_stale_processes`, `verify_cleanup_complete`,
  `stop_all_ffmpeg_streams` and `force_stop_mediamtx`.
- The installer already honoured the three variables (see `installer.md`); it does not
  validate them. Pass 2 should use `lyrebird_is_valid_port`.
- The port-in-use check (`lsof`) now looks only at listening TCP sockets: `lsof -i :PORT` also
  names a client socket that merely uses the number as its source port (reproduced), which
  with configurable ports in the ephemeral range could refuse a start at random.

### Who owns `/etc/mediamtx/mediamtx.yml` (LB-22, D10)

- The first line of a file the project may rewrite is exactly
  `# Managed by LyreBirdAudio` (a CR or trailing blanks are ignored). The manager
  rewrites the file only when it is missing, empty, or has that first line. Any other
  existing file is the **operator's**: validated and used as it is, never written.
  `start` logs one WARN naming `lyrebird-stream-manager.sh --regenerate-config start`.
- To keep hand edits in a managed file: delete the first line. To hand a file over to
  the manager: `--regenerate-config` with `start` or `restart` (new option, listed in
  `help`); the old file is saved first. The documentation must stop saying that the
  manager "regenerates `mediamtx.yml` on every start" (SECURITY-GUIDE note under
  Option 1, `docs/advanced.html`, `docs/troubleshooting.html`, README configuration
  sections).
- **Upgrade effect to document:** the file an earlier release generated has no marker
  (its first line was `# MediaMTX Configuration - Audio Streams`), so after the upgrade
  it is treated as the operator's: it keeps its API and metrics on every interface and
  keeps working, and each start warns (the warning says it looks like the file an
  earlier release wrote). One `--regenerate-config start` (or deleting the file) moves
  the node to the new defaults. Auto-migrating a file that is byte-identical to what the
  old generator wrote is possible (the old text is deterministic for the default
  ports) and was **not** done: D10 says an unmarked file is the operator's. Decision
  for the lead.
- A managed file whose rendering is unchanged is left untouched (no new mtime, no
  backup). A changed rendering is validated, the old file is saved next to it as
  `mediamtx.yml.<UTC YYYYmmddTHHMMSSZ>.<nn>.bak` (same mode and owner; `nn` counts up
  within a second), the newest `MEDIAMTX_CONFIG_BACKUPS` (default 5, minimum 1) are
  kept, and the replacement is written with `lyrebird_atomic_write` (temp file in the
  same directory, fsync, rename, fsync of the directory; LB-23, D14). The mode and owner
  of an existing file are kept; a new file is 0644, or 0640 when it carries password
  hashes; a file that now carries hashes loses world access and group write.
- Validation: MediaMTX's own `--validate-conf` where the binary has it, which of the six
  pinned releases is **1.21.1, 1.21.2 and 1.21.3 only** (1.15.0, 1.18.0 and 1.19.0 do
  not have the flag; checked by `--help`). It catches an unknown key and an invalid path
  name before the file is replaced. Older binaries get a structural check only
  (readable, non-empty, no NUL, no tab indentation, a top-level key); an unknown key or
  an invalid path name passes it and MediaMTX itself then refuses to start (asserted in
  the live test, so the limit is on record). A rendering MediaMTX rejects never replaces
  the file.
- The configuration is rendered after the port-in-use check (before, a failed check
  still rewrote the file), under the existing config lock.
- An empty `mediamtx.yml` (what a power cut during the old non-durable write can leave)
  is replaced and not treated as the operator's.

### Listeners and endpoints (LB-06, D9)

- The rendered configuration binds the control API and the metrics endpoint to
  `127.0.0.1` (was every interface). `MEDIAMTX_API_BIND` / `MEDIAMTX_METRICS_BIND` change
  that: an IPv4 or IPv6 address, or the empty string for every interface (a deliberate
  override; MediaMTX's default policy still answers `401` to a non-loopback caller of
  the API or metrics, asserted live). The manager asks the API where it listens
  (`MEDIAMTX_API_BIND`, else `MEDIAMTX_HOST`).
- RTMP, HLS, WebRTC and SRT are `no`, MoQ is `no` from 1.19.0 on (the key is invalid
  before), in every rendered configuration, and no option turns them on. Checked on
  v1.15.0, v1.18.0, v1.19.0, v1.21.1, v1.21.2, v1.21.3: the exact set of sockets of
  MediaMTX is RTSP (all interfaces), API and metrics (loopback), and the two UDP ports
  of RTSP (8000/8001 by default; RTP/RTCP stay at MediaMTX's defaults because the
  generated config lists `udp` among the transports).
- **RTSP stays open by default**: an anonymous remote client can publish and read
  (asserted live so that a change is deliberate). SECURITY-GUIDE's table is right on
  this; it is wrong that the API "accepts connections on all interfaces" for the
  rendered configuration, and the paragraph about the installer's configuration keeps
  being true until installer pass 2.
- `RTSP_AUTH_MODE=local-only-publish` (default `open`) renders the verified hardened
  pattern without hand-editing: a password-less user `any` restricted to `127.0.0.1` and
  `::1` with publish, read, playback, api, metrics, pprof; plus one read-only user
  (read, playback) per line of `RTSP_USERS_FILE` (default
  `<config dir>/rtsp-users.conf`, i.e. `/etc/mediamtx/rtsp-users.conf`). A line is
  `user:sha256:<base64 of the raw SHA-256 digest of the password>`, made with
  `printf '%s' 'the password' | openssl dgst -sha256 -binary | base64`; user names are
  `[A-Za-z0-9._@-]{1,64}`, `any` is reserved, duplicates and anything else (a plaintext
  password included) stop the start without echoing the line. A missing users file is a
  WARN and leaves only the local machine with access. `RTSP_AUTH_MODE` is ignored (with
  a WARN) for an operator-owned file. Under this mode publishers must connect from loopback:
  `MEDIAMTX_HOST` must be `localhost`, `127.x` or `::1` (WARN otherwise: MediaMTX refuses
  them). Verified live on all six versions: local publish/read/API need no credentials;
  remote anonymous read and publish get `401`; a listed user reads; a read-only user
  cannot publish; a wrong password, another user's password, an unknown user and the
  hash itself get `401`; an API bound to every interface still answers `401` to a remote
  caller, including a listed user; the manager's own readiness and stream probes work.
  The SECURITY-GUIDE "Option 1" YAML stays valid for people who want to write their own;
  mention this mode as the no-hand-edit way and the users file format.
- Not verified: IPv6 (`::1`) on a real listener, because the machine the tests ran on has
  no IPv6; a remote client from a second host (the tests connect to the machine's own
  non-loopback address, which MediaMTX sees as a non-loopback source).

### Readiness and the API (LB-13)

- One helper, `mediamtx_api_get PATH`, returns the HTTP status and body separately
  (`curl -sS --max-time`, `-w` status, no `-f`). Readiness (`wait_for_mediamtx_ready`),
  version detection (`detect_mediamtx_api_version`), `probe_stream_ready` and
  `validate_stream` all use it.
- Ready = HTTP 200 **and** a paths list of the right shape (`.items` array for v2/v3, an
  object for v1 and the unversioned API). `404` moves on to the older prefix (v3, v2,
  v1, then none unless `MEDIAMTX_API_FALLBACK=false`); an explicit
  `MEDIAMTX_API_VERSION` asks only that one. `401`/`403`: MediaMTX is up behind an
  authenticated API: `start` continues with one WARN ("its API requires credentials:
  stream health cannot be checked through it"). `5xx`, any other status, a 200 that is
  not a paths list, no answer, a refused connection: not ready until
  `MEDIAMTX_API_TIMEOUT`; the final error now says the state and the last status.
- Stream probe (`probe_stream_ready`, used by the deep health check): 0 ready; 1 not
  ready (200 and not available, or MediaMTX's JSON `path not found` 404); **2 unknown**
  for 401/403, 5xx, a plain-text 404, garbage, a body of the wrong shape, no answer. 2
  never counts as a strike. **Deviation from the register's table:** the register lists
  "5xx/garbage = not ready" for readiness; for the per-stream probe they are unknown, so
  that an API hiccup cannot restart a healthy stream.
  Against an authenticated API (SECURITY-GUIDE Option 1 without the local `any` user) a
  healthy stream used to be restarted after `DEEP_HEALTH_MAX_STRIKES` (3) monitor runs;
  now it is not (live test, six versions). The shape check uses `jq` (a dependency of
  `start`); without it a textual check of the same shapes.
- `validate_stream` (what `start` prints as `[OK]`/`[FAIL]`) no longer accepts a
  ready-looking body of a failed request.

## MediaMTX behaviour observed on the way (facts, checked against the real binaries)

- `mediamtx --validate-conf=FILE` exists on 1.21.1, 1.21.2, 1.21.3 and not on 1.15.0,
  1.18.0, 1.19.0 (`--help` lists it). It reports an unknown key
  (`json: unknown field "bogusKey"`) and an invalid path name
  (`invalid path name 'Studio Mix': can contain only alphanumeric characters,
  underscore, dot, minus, slash`).
- API answers: `{"itemCount":0,"pageCount":0,"items":[]}` for an empty `/v3/paths/list`;
  `404 {"status":"error","error":"path not found"}` for a path nobody publishes (also what
  a path that stopped publishing answers); `404` with the plain text `404 page not found`
  for a route MediaMTX does not have (`/v2/...`); `401 {"status":"error","error":
  "authentication error"}` when authentication fails.
- MediaMTX 1.21.1 reloaded its configuration when the file was replaced by a rename
  (`INF reloading configuration (file changed)`); not checked on the other versions.
- After a failed request that carried credentials, MediaMTX delays its answer to that
  client address, and the delay grows (about 1 s, then 3.4 s on 1.21.1); a request without
  credentials is answered at once with 401. Clients and probes that send wrong credentials
  need a generous timeout (relevant to the fail2ban section too).
- MediaMTX reads `MTX_<PARAMETER>` environment variables as overrides of any parameter
  (`MTX_RTPADDRESS=:36010`, `MTX_SRTADDRESS`, ...): the tests use them to move the listeners
  the configuration does not name; an operator can use them too (SECURITY-GUIDE Option 2
  already documents it for passwords).
- `rtspTransports: [tcp, udp]` makes MediaMTX also open UDP 8000 (RTP) and 8001 (RTCP) on
  every interface; the rendered configuration keeps that as it was.

## Using the renderer from the installer (pass 2)

`lyrebird_render_mediamtx_config` (in `lyrebird-common.sh`, which `install_mediamtx.sh`
sources) prints the complete configuration on stdout and nothing unless it all rendered
(exit 1 and a message on stderr otherwise). Options (all optional): `--rtsp-port`,
`--api-port`, `--metrics-port` (8554/9997/9998), `--rtsp-bind`, `--api-bind`,
`--metrics-bind` (every interface / `127.0.0.1` / `127.0.0.1`; an IPv4 or IPv6
address, `""` = every interface), `--api yes|no`, `--metrics yes|no`, `--log-level`,
`--read-timeout`, `--write-timeout` (30s), `--mediamtx-version vX.Y.Z` (the `moq` key
only for 1.19.0 and later), `--stream-name NAME`, `--auth-mode open|local-only-publish`,
`--users-file FILE`. Companions: `lyrebird_is_valid_port`,
`lyrebird_is_valid_bind_address`, `lyrebird_mediamtx_version_parts`,
`lyrebird_yaml_quote`, `lyrebird_atomic_write DEST [MODE [OWNER_REFERENCE_FILE]]` (the
third argument is new), `LYREBIRD_MEDIAMTX_CONFIG_MARKER`. The manager's ownership logic
(`mediamtx_config_is_managed`, `mediamtx_validate_config`, `mediamtx_config_backup`,
`mediamtx_config_apply`) lives in the manager; pass 2 should reuse the same rules (marker,
backup before replacing, atomic durable write) or move them into the library.
What the installer's own `create_config` writes and the renderer does not (so pass 2 has
to decide): `rtspEncryption`, `logFile`, `pathDefaults`, `paths: {}`, timeouts per
protocol. The renderer's catch-all path rule is `'~^[a-zA-Z0-9_-]+$'` (valid on all six
versions).

## Test infrastructure for other workers

- No test here binds a default port. `tests/mediamtx_live_helper.bash`
  (`mtx_ports_setup`, `mtx_start`, `mtx_listeners`, `nonloopback_addr`, ...) allocates
  free ports per test and moves every other MediaMTX listener (RTP/RTCP, RTMP, HLS,
  WebRTC, SRT, MoQ) with MediaMTX's own `MTX_*ADDRESS` environment overrides, so even a
  broken configuration cannot take a default port; `LYREBIRD_TEST_PORT_BASE` pins the
  ports to BASE..BASE+12 instead.
- `tests/helpers/mediamtx/curl_shim` is a `curl` stand-in that behaves like the real one
  for the manager's calls (`-w %{http_code}`); the old shims in
  `test_deep_health_check.bats` and `test_stream_manager_locks.bats` printed only a body,
  which the corrected readiness check (rightly) no longer accepts, and were changed to it.
- The non-loopback source tests connect to `hostname -I`'s first IPv4 address and are
  skipped on a machine that has none.

## CI

`.github/workflows/bash-ci.yml` runs the three live files above in the live matrix and
the canary (the files are appended to the two `tests/check_tmp_leaks.sh` commands that
already name `test_mediamtx_live.bats`, `test_soak_live.bats`, `test_soak_observer.bats`).
They need `openssl` (users-file hashes) besides the tools those jobs install; ubuntu
runners have it.
`tests/test_mediamtx_live.bats` now allocates free ports instead of 8554/9997/9998/8000/8001,
so the README sentence "needs ports 8554/9997 free" no longer applies to it
(`test_soak_live.bats` and `test_soak_observer.bats` still bind the defaults).

## Test counts for tests/README.md

`bats --count tests/` is 1016 on this branch (other workers' tests not included). New files:
`test_mediamtx_ports.bats` 20, `test_mediamtx_config_render.bats` 25,
`test_mediamtx_config_ownership.bats` 38, `test_mediamtx_api_probe.bats` 26 (these four need
no MediaMTX), `test_mediamtx_config_live.bats` 11, `test_mediamtx_api_live.bats` 2,
`test_mediamtx_e2e_ports.bats` 1 (live: skipped without `LYREBIRD_TEST_MEDIAMTX_BINS`);
`test_lyrebird_common.bats` +3 (46 to 49 with the owner reference tests);
`test_mediamtx_live.bats` is still 1 live test. The full suite run through
`tests/check_tmp_leaks.sh` passed 1016 of 1016 with 28 skipped (18 live tests: 15 above and
3 in the soak files; the 9 placeholder integration tests that were already skipped; one
`udevadm` test) and no temp file left behind.

## For docs/remediation-status.json (the lead edits it)

Suggested status, by finding (test names are exact, file in parentheses where the name alone
could be ambiguous; every file is under `tests/`):

- **X-19**: fixed in the manager (ports validated and honoured by the generator, the
  port-in-use check, readiness, probes, wrappers, printed URLs). Still open elsewhere: the
  `pgrep`/`pkill` patterns with 8554 (D11, ownership work) and the ports in the unit and cron
  file written by `create_systemd_service` (unit phase). The installer already honoured them.
- **LB-13**: fixed (stub-server table tests plus real binaries, six versions).
- **LB-22**: fixed in the manager; the installer still has its own generator until pass 2
  (use `lyrebird_render_mediamtx_config`).
- **LB-23**: fixed for the MediaMTX configuration (temp file, fsync, rename, fsync of the
  directory, asserted by call order); real power-cut durability is not testable here (HW).
  `save_device_config` (device config) still writes with `mktemp` + `mv` (device-config work).
- **LB-06**: manager side fixed (loopback API and metrics, nothing else listening, hardened
  mode, endpoint deny tests); the installer's configuration still binds `:9997`/`:9998` and leaves
  SRT/MoQ on until pass 2; documentation (SECURITY-GUIDE) still to be reconciled. RTSP is open by
  default on purpose (D9) and asserted as such.

Tests per tag, as they appear in the files:

#### X-19
- the defaults are MediaMTX's own: 8554, 9997, 9998 [X-19]
- an empty port variable means the default [X-19]
- publisher and reader URLs are built from the configured host and RTSP port [X-19]
- the generated MediaMTX configuration listens on the configured ports [X-19]
- start_mediamtx starts when the configured ports are free [X-19]
- start_mediamtx prints the stream URLs with the configured RTSP port, for individual and multiplex mode [X-19]
- start_mediamtx prints the URL of a stream that failed validation with the configured RTSP port [X-19]
- start_mediamtx refuses to start when any of the three configured ports is taken, checked with ss when lsof is absent [X-19]
- a client socket that merely has a configured port number as its source port is not a port in use [X-19]
- start_mediamtx refuses to start when any of the three configured ports is taken [X-19]
- wait_for_mediamtx_ready asks the API on the configured port [X-19]
- probe_stream_ready and the API version detection use the configured API port [X-19]
- a per-stream wrapper publishes to the configured RTSP port and carries it in its environment [X-19]
- a per-stream wrapper with local recording publishes to the configured RTSP port [X-19]
- a multiplex wrapper publishes to the configured RTSP port and carries it in its environment [X-19]
- status shows the stream URL with the configured RTSP port [X-19]
- status shows the multiplex stream URL with the configured RTSP port [X-19]
- the usage text shows the configured RTSP port in its multiplex examples [X-19]
- start_mediamtx, a real MediaMTX and the real wrapper work together on non-default ports: the stream is published, readable and seen by the probes [X-19, LB-13, LB-22]
#### LB-13
- readiness: a 200 with a paths list is ready, at once [LB-13]
- readiness: a paths list with entries is ready too, with and without jq [LB-13]
- readiness: a 200 that is not a paths list is not ready, with and without jq [LB-13]
- readiness: a 404 everywhere, a 5xx, a redirect and any other status are not ready [LB-13]
- readiness: a 401 or 403 means MediaMTX is up behind an authenticated API: accepted with a warning, never 'not ready' [LB-13]
- readiness: a 404 on /v3 falls back to /v2, then /v1, then the unversioned API, as documented [LB-13]
- readiness: v3 and v2 want an items array, so an items object there is not ready [LB-13]
- readiness: an explicit MEDIAMTX_API_VERSION asks only that version [LB-13]
- readiness: a refused connection is not ready until the deadline, and the message says so [LB-13]
- readiness: an answer that takes longer than the request limit is not ready [LB-13]
- readiness: an answer cut off before its announced length, or a connection closed without one, is no answer [LB-13]
- readiness: it keeps asking until the API answers properly [LB-13]
- readiness: a MediaMTX that died during start-up ends the wait at once [LB-13]
- version detection: v3 when /v3 answers with a paths list [LB-13]
- version detection: a 404 on /v3 moves on to /v2 and /v1, which could never happen before [LB-13]
- version detection: a 401, a 5xx, garbage or no answer default to v3 without trying older prefixes [LB-13]
- version detection: an explicit MEDIAMTX_API_VERSION is used without asking [LB-13]
- the API host follows MEDIAMTX_API_BIND, and MEDIAMTX_HOST when the API listens on every interface [D9, LB-13]
- probe: a published path is ready (0); an unavailable one, and a path MediaMTX does not know, are not ready (1) [LB-13]
- probe: a 401 or 403, a 5xx, a plain-text 404, garbage and a path of the wrong shape are unknown (2), not 'not ready' [LB-13]
- probe: no answer at all (refused, too slow) is unknown (2) [LB-13]
- probe: the same verdicts without jq [LB-13]
- probe: the path name goes under the detected API prefix [LB-13]
- validate_stream trusts the API only for a 200 that says the path is ready [LB-13]
- deep health: a healthy stream behind an authenticated API is never struck, however often it is checked [LB-13]
- deep health: a 5xx, garbage or an unreachable API never strike either; a path that is not ready does, until it is restarted [LB-13]
- RTSP_AUTH_MODE=local-only-publish: the manager's own readiness and stream probes keep working on every version, with no credentials [LB-06, LB-13]
- on every MediaMTX version the real API is ready, detected as v3, and a stream goes from not ready to ready to not ready [LB-13]
- behind an authenticated API a healthy publishing stream is not struck and not restarted by the monitor, on every version [LB-13]
- start_mediamtx, a real MediaMTX and the real wrapper work together on non-default ports: the stream is published, readable and seen by the probes [X-19, LB-13, LB-22]
#### LB-22
- a managed file whose rendering is unchanged is not touched at all: same inode, same mtime, no backup [LB-22]
- a managed file whose rendering changes is replaced after a backup of the old content [LB-22]
- backups are bounded: only the newest MEDIAMTX_CONFIG_BACKUPS (default 5) are kept, even when several fall in one second [LB-22]
- MEDIAMTX_CONFIG_BACKUPS sets the number of backups, and at least one is always kept [LB-22]
- the mode of a managed file the operator changed is kept when it is replaced, and the backup has it too [LB-22]
- the group of a managed file is kept when it is replaced [LB-22]
- an operator-owned file is used as it is: bytes, mode, inode and mtime survive every start, with no backup [LB-22]
- an operator-owned file that cannot be a MediaMTX configuration stops the start and is left alone [LB-22]
- where MediaMTX has --validate-conf, its verdict decides about an operator-owned file, and its message is logged [LB-22]
- a rendering MediaMTX rejects never replaces the managed file: no new content, no backup, no temp file [LB-22]
- a rendering that fails leaves a managed file as it is, and creates none [LB-22]
- a backup that cannot be saved stops the replacement and the file stays as it was [LB-22]
- two replacements in the same second never overwrite each other's backup [LB-22]
- with the clock standing still the retention still removes the oldest backups, never the newest [LB-22]
- multiplex mode renders one quoted path; a stream name that is not a plain scalar cannot inject YAML [LB-04, LB-22]
- individual mode renders the catch-all path, moq follows the binary's version [LB-22]
- start_mediamtx checks the ports before it renders anything: a taken port leaves the configuration as it was [LB-22]
- start_mediamtx writes the configuration, then launches MediaMTX on that file [LB-22]
- start_mediamtx launches MediaMTX on an operator-owned file without touching it [LB-22]
- start_mediamtx refuses to start on an operator-owned file MediaMTX rejects, and launches nothing [LB-22]
- the manager validates a configuration with MediaMTX's own check where the binary has one, and says what the structural check cannot see [LB-22]
- every option of the renderer produces a configuration MediaMTX accepts and honours [LB-22]
- start_mediamtx, a real MediaMTX and the real wrapper work together on non-default ports: the stream is published, readable and seen by the probes [X-19, LB-13, LB-22]
#### LB-23
- the replacement is flushed to disk: the temp file before the rename, the directory after it [LB-23, D14]
- an empty file, what a power cut during an old non-durable write leaves behind, is replaced rather than treated as the operator's [LB-23]
#### LB-06
- moq: no is written for MediaMTX 1.19.0 and later, left out before it and when the version is unknown [LB-06]
- local-only-publish: the loopback 'any' user may do everything, and nothing else is granted without a users file [LB-06]
- local-only-publish: each users-file line becomes a read-only remote user with a hashed password [LB-06]
- local-only-publish: a plaintext password, a bad hash and a malformed line are refused without echoing the line [LB-06]
- local-only-publish: the user name 'any' is reserved, a duplicate is refused, an unreadable file is refused [LB-06]
- the warning says when the operator-owned file is the one an earlier release wrote, whose API is on every interface [LB-06]
- the API and metrics listen on the loopback address by default; MEDIAMTX_API_BIND and MEDIAMTX_METRICS_BIND change that [D9, LB-06]
- local-only-publish renders the hardened pattern with the users of RTSP_USERS_FILE, and the file loses world access [LB-06]
- the default users file is rtsp-users.conf in the MediaMTX configuration directory [LB-06]
- a file that now carries password hashes loses world access and group write; other modes are kept; hash-free renderings keep any mode [LB-06]
- a missing users file is a warning, and only this machine may use RTSP [LB-06]
- a users file with a plaintext password stops the start and nothing is written [LB-06]
- publishers that do not connect through a loopback name are warned about under local-only-publish [LB-06]
- the default configuration starts on every MediaMTX version and opens exactly the sockets it names, no SRT, MoQ, RTMP, HLS or WebRTC [LB-06]
- a publisher without credentials can publish and a client without credentials can read, from this machine [LB-06]
- RTSP is open by default: an anonymous remote client can publish and read. Asserted so that a change is deliberate [LB-06]
- the API and the metrics endpoint cannot be reached from a remote address; bound to every interface they answer 401 there, 200 here [LB-06, D9]
- RTSP_AUTH_MODE=local-only-publish: this machine needs no credentials, a remote client needs a listed user, who can read but not publish [LB-06]
- RTSP_AUTH_MODE=local-only-publish: the manager's own readiness and stream probes keep working on every version, with no credentials [LB-06, LB-13]
- an API bound to every interface under local-only-publish still answers 401 to a remote caller, the local machine keeps its access [LB-06]
#### D15
- a port outside 1-65535 or not a plain integer is refused with an error naming the variable [D15]
- the bounds 1 and 65535 and leading zeros are accepted, and leading zeros are not read as octal [D15]
- invalid values are refused, nothing is printed and the message names the option [D15]
#### D10
- the first line is the managed marker, with nothing before it [D10]
- no file yet: the rendered configuration is written with the marker first, mode 0644, and no backup [D10]
- only a first line that is the marker (a line ending or trailing blanks aside) makes a file managed [D10]
- an operator-owned file gets one warning per start that names --regenerate-config [D10]
- RTSP_AUTH_MODE has no effect on an operator-owned file, and the log says so [D10]
- --regenerate-config replaces an operator-owned file after saving it, keeping its mode; the next start leaves the new file alone [D10]
#### D9
- RTMP, HLS, WebRTC and SRT are switched off, and so is every key that has no switch-on option [D9]
- the API and metrics listen on the loopback address by default; MEDIAMTX_API_BIND and MEDIAMTX_METRICS_BIND change that [D9, LB-06]
- an invalid MEDIAMTX_API_BIND stops the start with a message, and the file stays [D9]
- the API host follows MEDIAMTX_API_BIND, and MEDIAMTX_HOST when the API listens on every interface [D9, LB-13]
- the API and the metrics endpoint cannot be reached from a remote address; bound to every interface they answer 401 there, 200 here [LB-06, D9]
#### LB-04
- any printable stream name comes back from a YAML parser as exactly that one path name [LB-04]
- a stream name with a control character, a line break or a non-ASCII byte is refused, so it cannot inject YAML [LB-04]
- multiplex mode renders one quoted path; a stream name that is not a plain scalar cannot inject YAML [LB-04, LB-22]
- multiplex configuration: the named path accepts a publisher and every other path is refused [LB-04]
- names within MediaMTX's path syntax work quoted; one outside it is refused by MediaMTX itself, never read as YAML [LB-04]

## README / docs corrections (summary)

README configuration tables: the three port variables are now validated and honoured;
add `MEDIAMTX_API_BIND`, `MEDIAMTX_METRICS_BIND`, `RTSP_AUTH_MODE`, `RTSP_USERS_FILE`,
`MEDIAMTX_CONFIG_BACKUPS`, `--regenerate-config`, and the exit code 4 for a bad port.
`tests/README.md`: new files and counts (see the final report of this work), the live
instructions, the helper files. SECURITY-GUIDE: the "regenerates on every start" note,
the API/metrics bind sentence and table row, the new auth mode and users file, the
upgrade note. `docs/ADR.md`/architecture: configuration ownership (marker) and the one
renderer.

## Found while working (not fixed, outside this area)

- `monitor` run from cron has no `STREAM_MODE`/`MULTIPLEX_*`/port environment (see Ports).
- `LOG_FILE` and `MEDIAMTX_LOG_FILE` are one variable (X-15, register).
- A MediaMTX older than 1.21 has no `--validate-conf`: an invalid path name or unknown
  key is only found when MediaMTX refuses to start ("MediaMTX process died
  immediately"; the reason is in `MEDIAMTX_LOG_FILE`).
- Rapid configuration changes inside one second were numbered into the gaps left by
  retention, which would have removed the newest backup first: fixed here (found by the
  retention test).

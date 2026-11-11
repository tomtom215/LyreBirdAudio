# lyrebird-metrics.sh notes (for the documentation pass)

Findings: LB-18 (output validity, `--file`, `--serve`), X-17 (serve framing,
process control), X-13 (metrics side: heartbeat threshold). Script version
1.2.0 -> **1.3.0** (README version table, CHANGELOG, `docs/components.html`,
`docs/changelog.html`). Test count of `test_lyrebird_metrics.bats`: 39 -> 95
(`tests/README.md` table row for lyrebird-metrics.sh; also the total there).
New test helpers: `tests/prom_validate.bash` (exposition validator),
`tests/helpers/http_probe.py`, `tests/helpers/port_holder.py`.

## Command line (exact)

```
lyrebird-metrics.sh                       # document to stdout (--once is the same)
lyrebird-metrics.sh --file PATH           # atomic replace of PATH
lyrebird-metrics.sh --serve [PORT]        # HTTP server, PORT defaults to 9100
lyrebird-metrics.sh serve [--port PORT] [--bind ADDR]   # the documented spelling
lyrebird-metrics.sh --port PORT --bind ADDR serve       # options may come in any order
```

* `serve`, `--port PORT`, `--bind ADDR` are new. `--port`/`--bind` without
  `serve`/`--serve` is a usage error (exit 1), as are a port outside 1-65535 and
  a bind address that is not an IPv4/IPv6 literal or `localhost` (= 127.0.0.1).
* **Default bind is 127.0.0.1** (it used to be every interface while the log said
  "localhost"). A non-loopback `--bind` logs a WARN: the server has no
  authentication or TLS. A Prometheus on another host needs `--bind ADDR` (or
  `0.0.0.0`) and a firewall; `README` "targets: ['field-unit-1:9100']" only works
  that way.
* Does **not** exist, remove from README (`### Prometheus Metrics`) and
  `docs/components.html`: `--streams-only`, `--system-only`.
* `docs/monitoring.html` shows `./lyrebird-metrics.sh > .../lyrebird.prom` for the
  node_exporter textfile collector; that is a non-atomic write that a scrape can
  read half-way. Use `--file` (cron: `* * * * * lyrebird-metrics.sh --file
  /var/lib/node_exporter/textfile_collector/lyrebird.prom`).

## Exit status (also in `--help`)

| status | meaning |
|--------|---------|
| 0 | every collector completed (server: stopped by SIGTERM/SIGINT) |
| 1 | command-line error |
| 2 | nothing could be delivered: `--file` could not publish (the previous file is kept), or the server cannot run (no usable netcat, port in use / cannot bind after 5 attempts, no temp directory) |
| 3 | the document was delivered but at least one collector failed (`lyrebird_scrape_success 0`) |

Failures never abort the shell uncontrolled ("never crash the cron" holds), but
the status is no longer 0 when something failed. A cron mail is sent only if the
job prints to stderr, which it does on any failure (one line per failed
collector).

## New and changed metrics

* `lyrebird_scrape_success` (gauge): 1 only if all six collectors completed.
  Alert on `== 0`.
* `lyrebird_collector_success{collector="..."}` (gauge), fixed label set:
  `mediamtx`, `stream_manager`, `usb_audio`, `system`, `api`, `streams`.
* A source that cannot be read, or a missing tool (`pgrep` for `mediamtx`, `curl`
  for `api`), makes the affected metrics **absent** (not 0) and its collector 0:
  `lyrebird_mediamtx_up`, `lyrebird_api_up`, `lyrebird_stream_manager_up`,
  `lyrebird_active_streams`, `lyrebird_configured_devices`,
  `lyrebird_usb_audio_devices`/`lyrebird_total_audio_cards`,
  `lyrebird_heartbeat_*`, per-stream `lyrebird_stream_up`, disk usage. Alert
  rules that use `== 0` on these will not fire for an unreadable source; use
  `lyrebird_scrape_success == 0` for that.
* `lyrebird_heartbeat_healthy`: **1 if the stream-manager monitor ran within the
  last N seconds**, N = `LYREBIRD_HEARTBEAT_MAX_AGE` (default **900** = 3 x the
  5-minute cron cadence; was a fixed 60 s, which read unhealthy on ~80% of scrapes
  of a healthy node). HELP: "proves only that the monitor ran, not that streams
  are healthy". `lyrebird_heartbeat_age_seconds` is -1 when there is no file.
  A heartbeat from the future is not healthy. Invalid values of the variable are
  ignored with a warning (900 is used). New setting for the configuration
  reference: `LYREBIRD_HEARTBEAT_MAX_AGE` (positive integer seconds).
* Real metric names (README/monitoring.html list names that never existed):
  `lyrebird_mediamtx_up`, `_mediamtx_memory_bytes`, `_mediamtx_cpu_percent`,
  `_mediamtx_open_fds`, `_mediamtx_uptime_seconds`, `lyrebird_stream_manager_up`,
  `lyrebird_active_streams`, `lyrebird_configured_devices`,
  `lyrebird_heartbeat_age_seconds`, `lyrebird_heartbeat_healthy`,
  `lyrebird_usb_audio_devices`, `lyrebird_total_audio_cards`,
  `lyrebird_disk_usage_percent{mount}`, `lyrebird_system_memory_total_bytes`,
  `_system_memory_available_bytes`, `_system_load_1m`,
  `_system_entropy_available`, `lyrebird_api_*` (up, info{version}, uptime,
  paths total/ready, rtsp/rtsps/rtmp/rtmps/webrtc/srt connections, hls muxers,
  recordings, total connections), `lyrebird_stream_up{stream}`,
  `lyrebird_stream_memory_bytes{stream}`, `lyrebird_stream_cpu_percent{stream}`,
  `lyrebird_build_info{version}`, `lyrebird_scrape_timestamp_seconds`,
  `lyrebird_scrape_success`, `lyrebird_collector_success{collector}`.
  Not emitted anywhere: `lyrebird_stream_active`, `lyrebird_usb_devices_total`,
  `lyrebird_usb_device_connected`, `lyrebird_cpu_usage_percent`,
  `lyrebird_memory_usage_percent`, `lyrebird_load_average_1m`,
  `lyrebird_stream_uptime_seconds`.
* The document is valid text exposition by construction: per-family contiguous
  samples (the per-stream families used to be interleaved), values validated at
  the single emit point (`NaN`/`Inf` allowed, anything else dropped, logged and
  counted against the collector), label values escaped.

## `--file`

* Replaced atomically: hidden temp `.NAME.XXXXXX` in the same directory (mktemp;
  starts with `.`, never ends in `.prom`, so the textfile collector never reads
  it), then rename. Concurrent writers are safe (last rename wins); readers see
  the previous or the new document, never a partial one.
* The previous file is kept, nothing is half-written, and the status is 2 when the
  generator fails, the write fails (disk full), the target is a directory or its
  directory is missing/unwritable. No fsync (the file is regenerated every
  interval; a lost rename after a power cut leaves the previous document, which
  `lyrebird_scrape_timestamp_seconds` makes alertable). A SIGKILL can leave one
  hidden `.NAME.XXXXXX` behind; SIGTERM/INT/HUP remove it (exit 143/130/129;
  SIGTERM is tested, the three share one handler).
* File mode follows the umask (as the old redirect did), not mktemp's 0600.
* Old behaviour (fixed `NAME.tmp`, exit 1 for the losing writer, exit 0 on
  generation failure) is gone; nothing else used `NAME.tmp`.

## HTTP server

* Answers `GET /` and `GET /metrics` (query string ignored) with 200,
  `Content-Type: text/plain; version=0.0.4; charset=utf-8`; any other path 404;
  any other method on those paths 405 (`Allow: GET`); a malformed request line,
  an oversized request line (> 8 KiB), more than 100 header lines or a head that
  takes > 5 s is 400. `HEAD` is 405. Always CRLF, `Content-Length` in bytes
  (computed in the C locale), `Connection: close`. A document with a failed
  collector is still 200 (its `scrape_success` is 0); only a generator failure is
  500.
* The metrics are generated **after** the request has arrived (they used to be
  generated before waiting, so a response could be arbitrarily old; the document
  is fresh: `lyrebird_scrape_timestamp_seconds` >= the time of the request).
* Needs a netcat, recognised from `nc -h`: OpenBSD (`nc -l [-q 0|-N] ADDR PORT`),
  ncat (`ncat -l ADDR PORT`), traditional/GNU (`nc -l -p PORT -s ADDR [-q 0]`),
  BusyBox (`nc -l -p PORT -s ADDR`; a BusyBox without `-s` can only bind
  `--bind 0.0.0.0`, otherwise the server says so and exits 2). Install
  `netcat-openbsd` (`apt-get install netcat-openbsd`) where unsure. Candidates
  tried in order: `nc`, `ncat`, `netcat`. Verified against the real OpenBSD nc
  only; the other variants only through PATH shims that check the command line.
* Port already in use (any listener, including another netcat: nc sets
  SO_REUSEPORT, so a second one would bind NEXT to the first and split its
  connections): retried 5 times with 0.5/1/2/4 s back-off (the previous instance
  may still be closing), then `ERROR: cannot listen on ADDR:PORT: ...`, exit 2.
  No more `pkill`; only the pid of the netcat the script started (checked with
  its start time) is ever signalled. A SIGKILLed server can leave its netcat
  behind until it accepts one connection; the next start refuses to run while it
  is there (port in use) rather than binding beside it. (For an IPv6 `--bind` the
  pre-check only sees listeners on every address; a non-netcat holder of the exact
  address is still caught by nc's own bind error.)
* SIGTERM/SIGINT/SIGHUP: logs "Shutting down metrics server...", stops its netcat
  processes, removes its private temp directory, exit 0. (A signal that arrives
  while the metrics are being generated is handled when the generation ends.)
* Limits to state in the docs: one connection at a time; a second scraper that
  connects while a request is being answered is served roughly half the time
  (the next listener is armed before the metrics are generated) and otherwise
  reset, as is a client that reconnects within about a millisecond of the previous
  response; a client that half-closes its sending side before the response
  (`printf ... | ncat HOST PORT`) gets no answer with OpenBSD nc (use curl/wget);
  a client that connects and sends nothing occupies the armed listener for up to
  10 s; no authentication or TLS. For several scrapers, or anything exposed
  beyond loopback, use `--file` with node_exporter's textfile collector.
* Log lines (stderr): `Metrics server listening on http://127.0.0.1:9100/metrics
  (netcat: openbsd; ...)` only once the socket is really bound.
* Server dependencies beyond bash 4.2 (`mapfile`, `exec {fd}<`, `$BASHPID`): a
  netcat, `mkfifo`, `mktemp`, `awk`, `readlink`, Linux `/proc` (start-time
  identity and the port pre-check; without `/proc/net/tcp` the pre-check is
  skipped and nc's own bind error is the only guard). `timeout` is used for
  `nc -h` when present.

## Things for the other areas / the docs pass to know

* The collectors read `PID_FILE` (/run/mediamtx-audio.pid), `FFMPEG_PID_DIR`
  (/var/lib/mediamtx-ffmpeg), `HEARTBEAT_FILE` (/run/mediamtx-audio.heartbeat) and
  `/etc/mediamtx/audio-devices.conf`. If the stream-manager work (D2/D4/D7/D11)
  moves, renames or reformats any of them (`/run/lyrebird/status.json`, PID files
  by canonical name), the defaults here must follow in the same change.
* Manager side of X-13 (not done here): the monitor writes the heartbeat on every
  pass even while MediaMTX is down; the metric only claims what it can prove.
* The collector status design deliberately does not use `set -e` (errexit is
  disabled inside any function called from an `if`/`||`).

## Defects found while working on this area, not fixed (out of scope)

1. `collect_mediamtx_metrics` uses `pgrep -f mediamtx`: any process whose command
   line contains the word (`tail -f /var/log/mediamtx.log`, an editor, a script
   under a path containing it) gives `lyrebird_mediamtx_up 1` and its memory/CPU/
   uptime (reproduced with a decoy process). Same class as LB-10 in the manager.
2. Liveness uses `kill -0 PID`: run as an unprivileged user (a `--file` cron job
   as `node_exporter`, a `--serve` unit with `User=`), a live root-owned process
   gives EPERM, so every stream reads `stream_up 0` / `active_streams 0` and
   `stream_manager_up 0` (reproduced as uid 65534). The documentation does not say
   the exporter must run as root; either it must, or liveness should use
   `/proc/PID`.
3. With the MediaMTX API down every scrape waits at least one second
   (`api_call_with_retry` sleeps between its two attempts); in `--serve` mode that
   is added to every response.

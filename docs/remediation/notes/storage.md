# Storage notes (X-14) for the documentation pass

`lyrebird-storage.sh` 1.1.0 -> **1.2.0** (README component table, CHANGELOG).
Everything below was run against the real script; "measured" means measured with
ffmpeg 6.1.1 and the stream manager's own tee + segment arguments.

## New behaviour to document

### Recording extensions (one list)

Retention, emergency eviction and `status` treat a file as a recording when its
name ends in one of: `opus ogg aac adts m4a mp3 flac wav` (case-sensitive; the
list is `RECORDING_EXTENSIONS` in the script and is printed by `--help`).
Anything else in the recording directory is never touched. Previously `.aac`
was missing, so `CODEC=aac` recordings were never cleaned.

What the manager writes: `AUDIO_RECORDING_PATH/<stream>/audio_%03d.${CODEC}`;
the extension is the `CODEC` value and FFmpeg picks the container from it
(measured): `opus` -> `.opus` (Ogg Opus), `aac` -> `.aac` (ADTS), `mp3` -> `.mp3`;
`CODEC=ogg` also works (the manager's libopus fallback inside an Ogg container).

### Empty and in-progress segments

Measured: the segment FFmpeg is writing is a **0-byte file whose mtime stays at
its creation time** until the first 256 KiB chunk is flushed (16 s at 128 kb/s),
after which the mtime advances once per chunk. A hard-killed FFmpeg leaves that
segment at 0 bytes, or cut at a 256 KiB boundary (that truncated Opus file still
decodes). So:

- An **empty** recording file idle for longer than `ACTIVE_SEGMENT_SECONDS` is
  debris. `cleanup` (and so `monitor`) removes it at any retention age; a younger
  one is a segment being opened and is kept; a pre-`CLOCK_SANE_EPOCH` mtime keeps
  it (real age unknown, same rule as before); nothing is removed while the clock
  is unsynced.
- A **truncated but non-empty** segment is treated as the audio it is: kept until
  retention, evicted oldest-first in an emergency.
- `status` now counts only recordings in `Files:` (non-empty, by extension; it
  used to count every file) and prints a new line `Empty segments: N`.

### New setting

| Variable | Default | Meaning |
|----------|---------|---------|
| `LYREBIRD_ACTIVE_SEGMENT_SECONDS` | `900` (minimum `60`; non-numeric -> `900`) | A file written this recently belongs to a stream that is recording now: emergency cleanup never deletes it, and an empty segment younger than this is not removed. Must exceed how long the open segment's mtime can stay unchanged (256 KiB at 6 kb/s = 350 s, derived from the measured 256 KiB flush chunk). |

### Emergency cleanup (`emergency`, and `monitor` at emergency level)

Order, deterministic: (1) idle empty segments, then (2) the oldest non-empty
recordings, **up to 100 of each class per run** (it used to be "the oldest 100
files"); oldest first by mtime, ties by path in byte order (`LC_ALL=C`). Not gated
on the clock-sanity floor (a 1970 mtime is just "oldest"; by design). Files
modified within `ACTIVE_SEGMENT_SECONDS` are never evicted. Then rotated `*.gz`
logs in `LYREBIRD_LOG_DIR` and `mediamtx*.out*.gz`, `lyrebird-*` files in
`LYREBIRD_TEMP_DIR`, and the **files** (not directories) of `LYREBIRD_BUFFER_DIR`.
Before, the buffer was cleared with `rm -rf "$BUFFER_DIR"/*`: stream directories
disappeared and FFmpeg silently dropped its recording leg until the stream was
restarted (measured: "Failed to open segment ... continuing with 1/2 slaves").

### Exit status

`0` success; `1` usage error (unknown option, no command); **`3` new: the run
finished but at least one deletion failed** (permission, immutable file,
read-only filesystem). Each refusal is logged as
`Cannot delete <what> <path>: <rm's reason>`, summaries end with
`; N deletion(s) FAILED`, and the run ends with
`Run finished with N failed deletion(s); ...`. A refusal no longer aborts the
run (it used to stop everything after the first stuck file, exit 1, no summary),
and `emergency` no longer ignores refusals. A cron job reports, and a systemd
unit fails on, the non-zero status. `--dry-run` never reports failures.

### Symlinked configured directories

`LYREBIRD_RECORDING_DIR` and `LYREBIRD_BUFFER_DIR` may now be symlinks to the real
directory (retention found nothing through a symlink before). Symlinks *inside*
the trees are never followed. `LYREBIRD_BUFFER_DIR` must still resolve (through
`..` and links) to a path under `/dev/shm`, `/tmp`, `/var/tmp` or `/run`.

## Documentation that is wrong today (verified by running the script)

- README "Storage Management", `docs/components.html`, `docs/monitoring.html`:
  `lyrebird-storage.sh monitor --interval 300`, `cleanup --quiet` and
  `monitor --once` are not options: each exits **1** with "Unknown option" and
  the help text, so the documented cron lines in README/`monitoring.html`
  (`cleanup --quiet`, `monitor --once`) fail every run. Real options are
  `-h/--help -v/--version -n/--dry-run -d/--debug`; `monitor` is one check per
  invocation (run it from cron), not a loop.
- The same sections document `/etc/lyrebird/storage.conf` (never read; the script
  takes environment variables only) and `RECORDING_DIR=` / `LOG_DIR=` (ignored;
  the variables are `LYREBIRD_RECORDING_DIR`, `LYREBIRD_LOG_DIR`,
  `LYREBIRD_BUFFER_DIR`, `LYREBIRD_TEMP_DIR`, `MEDIAMTX_LOG`).
- README feature list: "Integration with alerting system" - the script has no
  reference to `lyrebird-alerts.sh` (grep).
- `docs/contributing.html` says `test_lyrebird_storage.bats` has 42 tests; it has
  59, plus 75 in the `test_storage_*.bats` files (below).
- `tests/README.md`: total is now 743 (`bats --count tests/`); add the new files
  `test_storage_codecs.bats` (7), `test_storage_delete_failures.bats` (14),
  `test_storage_eviction.bats` (9), `test_storage_segments.bats` (18),
  `test_storage_buffer.bats` (5), `test_storage_path_safety.bats` (12) and the
  shared `storage_helper.bash`. The storage row (59 tests) counts only
  `test_lyrebird_storage.bats`.

## Recorder interaction the docs pass should state (D8/LB-16)

- The recorder's ring is `segment_wrap=AUDIO_RECORDING_SEGMENTS` (12) slots per
  stream that FFmpeg overwrites in place, so `AUDIO_RECORDING_PATH` never holds
  more than 12 segments per stream and the retention days do not govern it (the
  mtimes keep refreshing). A "durable" `AUDIO_RECORDING_PATH` keeps the last hour,
  not 30 days.
- The storage script never reads `AUDIO_RECORDING_PATH`. Retention looks at
  `LYREBIRD_RECORDING_DIR` (default `/var/lib/mediamtx-ffmpeg/recordings`) and the
  emergency buffer clear at `LYREBIRD_BUFFER_DIR` (default
  `/dev/shm/lyrebird-buffer`, which equals the manager's default
  `AUDIO_RECORDING_PATH`). If an operator moves `AUDIO_RECORDING_PATH`, set the
  matching storage variable, or cleanup will not see the segments.
- Manager defect found while verifying (not fixed here, stream-manager owner): a
  `CODEC` other than `opus|aac|mp3` takes the `*)` arm (libopus encoder) but the
  segment keeps the raw `CODEC` as its extension. With `AUDIO_LOCAL_RECORDING=true`
  FFmpeg then picks a container from that extension and refuses Opus in it:
  `flac`, `m4a`, `adts` leave a 0-byte `audio_000.<ext>`, `wav` a 20-byte stub,
  `pcm_s16le` ("Muxer not found") nothing, and the tee carries on with the RTSP
  leg only, so streaming works and local recording silently does not. The sample
  config comment `DEVICE_BLUE_YETI_CODEC=pcm_s16le` is such a value. Storage now
  removes the empty debris (extensions listed above); the manager should reject
  or map unsupported codecs.

## Not fixed (residual, low)

- `LYREBIRD_LOG_DIR`, `LYREBIRD_TEMP_DIR` and the MediaMTX log directory are still
  scanned with plain `find`: a symlink there is not followed (same cause as the
  recording directory above).
- `find ... 2>/dev/null` hides traversal errors (an unreadable subdirectory, or a
  relative `LYREBIRD_RECORDING_DIR` that starts with `-`, which `find` parses as
  an expression: reproduced, "Cleaned 0 recording file(s)" while a 45-day-old file
  stays). Deletion failures are surfaced; listing failures are not.
- `truncate_large_logs` removes its stale `*.tmp` files with `find -delete ||
  true` (a refusal there is not counted).
- The empty-subdirectory sweep (`find -mindepth 1 -type d -empty -delete`) could
  in theory remove a stream directory in the instant between the wrapper's
  `mkdir -p` and FFmpeg opening its first segment; not observed.
- No lock between concurrent storage runs; overlapping runs both evict the same
  oldest files, which is harmless (an already-gone file is not a failure).

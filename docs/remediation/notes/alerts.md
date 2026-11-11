# lyrebird-alerts.sh notes (LB-17) for the documentation pass

Script version 1.0.1 -> 1.1.0. Config variable names and the config file format
are unchanged; no setting was removed or deprecated.

## Behaviour the docs must state

- **Suppression is per destination.** An identical alert (same alert type and
  same message text) is not sent again to a destination that already confirmed
  it (HTTP 2xx) within `LYREBIRD_ALERT_RATE_LIMIT` seconds (default 300). A
  destination that failed has no record and is retried by the next identical
  alert; destinations that succeeded are not re-sent.
- **`LYREBIRD_ALERT_RATE_LIMIT` is the window that suppresses a repeat.**
  `LYREBIRD_ALERT_DEDUP_WINDOW` (default 3600) only controls how long delivery
  state is kept on disk; the effective retention is
  `max(LYREBIRD_ALERT_DEDUP_WINDOW, LYREBIRD_ALERT_RATE_LIMIT)`. (Before, state
  was deleted after `DEDUP_WINDOW` alone, so a rate limit longer than it was
  silently cut short.) README line 1943 "Alert deduplication within
  configurable window" and docs/components.html line 383 / docs/monitoring.html
  line 218 should say "per destination, within `LYREBIRD_ALERT_RATE_LIMIT`".
- **Concurrent identical alerts deliver once per destination.** A destination
  is claimed (flock) before the first request. A second sender that finds the
  destination claimed skips it (another process is delivering). If the
  claiming process dies, the kernel releases the claim at once.
- Message variable parts hash differently by design ("87%" vs "88%" are two
  alerts); the `alert_*` helpers embed no timestamps. Unchanged, worth one
  sentence.

## Exit status of `send_alert` (and of `lyrebird-alerts.sh send`)

| Code | Meaning |
|------|---------|
| 0 | Delivered: every destination that needed the alert received it. Destinations that already had it within the window are not re-sent. |
| 1 | General error (CLI usage, e.g. `send` without `--message`) - unchanged |
| 2 | Configuration error - unchanged (not produced by `send_alert`) |
| 3 | Total failure: no destination holds the alert and at least one failed (also: no usable destination could be built from the configuration). Nothing is recorded; the next identical alert retries. |
| 4 | Suppressed (not an error): every destination already has this alert within the rate-limit window, or another process is delivering it right now. |
| **5 (new)** | **Partial failure**: at least one destination has the alert (delivered now or earlier within the window) and at least one failed. The failure is logged with the URL masked (`mask_url`: first 30 characters + `***`) and a hash of the destination. |

- `0` used to mean "at least one destination accepted it"; that is now `5` if
  any destination failed. Scripts that source `lyrebird-alerts.sh` run under
  `set -e` and call `send_alert` bare abort on 3, 4 and 5 (already true for 3
  and 4): use `send_alert ... || rc=$?`. Constants `ALERT_RC_DELIVERED` (0),
  `ALERT_RC_FAILED` (3), `ALERT_RC_SUPPRESSED` (4), `ALERT_RC_PARTIAL` (5) are
  defined by the script. `lyrebird-alerts.sh help` now has an EXIT STATUS
  section with the same table.
- `lyrebird-alerts.sh test` keeps its 0/1 contract (0 = delivered, 1 otherwise)
  and prints "Test alert reached only some destinations; at least one FAILED."
  on a partial result. A second `test` within the rate-limit window still
  prints the generic "Failed to send test alert" (rc 4 -> 1); unchanged.

## State directory (`LYREBIRD_ALERT_STATE_DIR`, default `/var/lib/lyrebird/alerts`)

Files are per (alert hash, destination id); the destination id is a 16-hex hash
of type + endpoint (+ Pushover token and user key), so no URL or token is ever
stored or logged by the state mechanism.

- `<alert>.<destination>.last` - epoch second of the confirmed delivery,
  replaced atomically (`lyrebird_atomic_write`). An empty, torn, non-numeric or
  future-dated file is ignored (the alert is sent and the file rewritten).
- `<alert>.<destination>.lock` - claim lock file (never written, only flocked).
- `.claim.guard` - short-lived guard so cleanup cannot remove a claim file
  between a sender opening and locking it. Never removed.
- Pre-1.1.0 `<alert>.last` files are no longer consulted and expire with
  everything else. Consequence: the first identical alert after the upgrade can
  be delivered once more than the old file would have allowed.
- Cleanup (after any send that tried a destination) removes stamps and
  unheld claim files older than the retention above, plus orphaned
  `.<stamp>.XXXXXX` temp files from a killed writer.
- `flock` (util-linux) is used for claims. If it is missing or the state
  directory is unusable, alerts are still sent, without duplicate protection,
  with a warning ("sending without duplicate protection").

## Other doc touch points

- README "Webhook Alerts" version table (line 1474) 1.0.1 -> 1.1.0;
  docs/components.html line 56 still lists 1.0.0; CHANGELOG entry needed.
- tests/README.md: `test_lyrebird_alerts.bats` 54 -> 87 tests.
- docs/monitoring.html "Rate Limiting" paragraph: add the per-destination
  retry behaviour and the exit codes above.

## Not verified (state in the docs only what was verified)

- Bash 4.2: the code uses `exec {fd}>>file` / `{fd}>&-` (bash >= 4.1) but was
  only run on bash 5.2.
- Real webhook endpoints: all deliveries were checked against a curl PATH shim.
- Stamp durability across a power cut (fsync is requested by
  `lyrebird_atomic_write`; the medium decides).

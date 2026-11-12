# lyrebird-updater.sh notes, second pass (for the documentation pass)

Area: X-31 (updater residuals) = the three findings the first updater pass left
open (`docs/remediation/notes/updater.md`): **U-18** (menu exit status), **U-19**
(migrations after a self-update), **U-20** (the lock, decision D2). Updater
version **1.8.0** (was 1.7.0). Everything below is what the code does now;
nothing here has been edited into README.md, CHANGELOG.md, docs/*.html or
SECURITY*.md. `docs/remediation-status.json` is left to the lead (test names
are in the final report).

| ID | Sev | Status | What |
|---|---|---|---|
| U-20 | P3 | fixed (R: the race reproduced on the old code, 5 rounds in 15 with 12 processes, 5 in 8 with 30) | The mkdir+pid-file lock: two updaters started together after a crash could both remove the dead holder's lock and both create their own. Now a `flock(2)` lock on a never-unlinked file (D2) |
| U-18 | P3 | fixed (R) | A failed action ended the whole menu run with the failing status; end of input at a prompt ended it silently with 1 |
| U-19 | P3 | fixed (R) | A self-update never ran the post-update migrations of the version it installed |

## README / docs changes (exact)

* **Version table**: `lyrebird-updater.sh | 1.8.0` (README ~L1466).
* **"Update Behavior" (README ~L1219-1229)**: "Lock file prevents concurrent
  executions" stays true; the lock is now a kernel `flock` (see "The lock").
  "Automatic migrations ... run automatically" is now true for the updates
  that restart the updater as well (they were skipped for those).
* **"Version Manager" Features / Exit Codes (README ~L1528-1550)**: replace the
  list by the full table in "Exit codes" below. The README list lacks 6, 10, 11
  and the new 12 and describes 4 as "No remote configured" (it is "could not
  reach the remote"; see updater.md).
* **Requirements**: `flock` (util-linux, present on every Debian/Raspberry Pi OS
  install) is now a prerequisite of the updater; without it the updater stops
  with exit 2 and says where flock comes from.
* **Troubleshooting**: nothing in the README tells the operator to remove an
  updater lock, and nothing should: "Lock held by process ..." means another
  updater is really running (or a child of one: see below); wait or stop that
  process. The lock file is never removed.
* **Menu**: a switch (options 1-3) or reset (option 6) that fails is reported
  and the menu stays open; see "The menu".
* No other page describes the updater's own lock (`docs/ADR.md` line ~207,
  "lockfiles with timeout and stale lock detection", is about the stream
  manager; see stream-locks.md). README lines ~1220 and ~1535 ("Lock file
  prevents concurrent executions", "Lock file protection against concurrent
  execution") stay true; the word "file" is now literal (a kernel lock on a file).

## The lock (U-20, D2)

* **File**: `<git-dir>/lyrebird-updater/updater.lock` (a linked worktree's own
  git dir; `LYREBIRD_UPDATER_STATE_DIR` moves the whole state directory, as
  before). It was a *directory* named `lock` in 1.7.0 and in the working tree
  (`.lyrebird-updater.lock`) before that; the new file has another name on
  purpose, so that a 1.7.0 updater (reached by `--rollback` to an old release)
  can still create its own `lock` directory.
* **Protocol**: opened read-write **without truncation**, never removed, a
  `flock` taken on it (the same open file description for the life of the run).
  The kernel releases the lock when the holder dies, however it dies (exit,
  SIGKILL, OOM, power cut): there is no stale lock, no lock-age test, no
  process-name test and no removal step. The old code's staleness checks
  (`kill -0`, a "does the command line contain lyrebird-updater" test, `rm -rf`)
  are gone for the new lock.
* **Owner record**: after the lock is won, the first 65 bytes of the file are
  overwritten in place with `<pid> <starttime>` padded with spaces to 64
  columns plus a newline (`starttime` = field 22 of `/proc/<pid>/stat`, clock
  ticks since boot). A re-exec'd updater has the same pid and start time. The
  record is informational: it names the holder to an updater that has to give
  up. It is never used to decide whether the lock is held, and the last
  owner's record stays in the file after it exits. A pid is only named when its
  start time still matches (a recycled pid is never blamed).
* **Waiting and giving up**: unchanged knob, `LYREBIRD_UPDATER_LOCK_WAIT`
  (default 30 s). While it waits it prints `Waiting for other instance to finish...`
  once. A run that gives up exits **7** with
  `Lock held by process <pid> (start time <t>): <command line>`, or
  `Lock held by another process (no owner recorded)` /
  `... (the last recorded owner, process <pid>, start time <t>, is not running)`,
  then `Processes with the lock file open: <pid>(<comm>) ...` (the real holders,
  found through `/proc/*/fd`) and `Nothing needs to be deleted (<path> is never
  removed).` The old text `If you're sure no other instance is running, remove:
  <lock>` is gone: removing the file is what the design forbids.
* **No disk space for the record** (the 64 bytes): exit 5,
  `Cannot write the lock file in <dir> (disk full or read-only?)` (the old
  message for the pid file, kept; the journal and history could not be written
  either). A lock file that cannot be opened at all: exit 5, `Cannot open the
  lock file: <path>`.
* **The lock descriptor is closed in every child**: a `flock` belongs to an
  open file description and a child inherits it. A child that kept it would
  hold the lock after the updater exited; the real case is the detached
  `git gc --auto` that a fetch or a commit can leave behind (reproduced with git
  2.43: after `git commit` with two packs and `gc.autoPackLimit=1`, the detached
  `git gc` processes had the parent's descriptor open; on a Raspberry Pi such a gc
  can run for minutes), which would have made every later updater run fail with
  exit 7. Every `git` and every `systemctl` the updater starts goes through a
  shell function of the same name that closes the descriptor around the call
  (`run_unlocked`); `timeout N git ...` (which runs the git binary itself), the
  stream manager's `install` and the self-update re-exec are handled
  explicitly. Other short-lived utilities (`sed`, `sleep`, `cp`...) still
  inherit it for the milliseconds they run; as in the stream manager, after a
  SIGKILL of the updater such a command can keep the lock for as long as it
  runs (the longest are `sleep 2` and `sleep 1`).
* **Self-update**: the lock is released (descriptor closed) immediately before
  the re-exec, exactly as before; the new updater takes it again. There is a
  window of one `exec` between the two in which another updater could take the
  lock (see "Defects found": U-22).
* **Prerequisite**: `flock` is checked with the other required tools (exit 2).
  `git` and `systemctl` are now shell functions inside the updater, so the
  "is it installed" checks use `type -P` (a missing git is still exit 2).
* **Older updaters**: while an updater older than 1.8.0 holds its own mkdir lock
  (`<repo>/.lyrebird-updater.lock` before 1.7.0, `<git-dir>/lyrebird-updater/lock/`
  in 1.7.0) the new updater honours it exactly as before (exit 7, `Another
  (older) updater instance is running: <dir>`). A lock directory left by a dead
  one, or without a pid file (killed between `mkdir` and the pid write: 1.7.0
  then locked every later run out for good), is removed. That test of an *old*
  protocol is the only pid/name-based check left; the new lock has none.
* **Which commands take the lock** (unchanged, verified): every command except
  `--history`, including `--version`, `--help`, `--status` and `--list`
  (`main()` takes it right after the prerequisite check). `--history` reads the
  local log with no lock, no git and no network and creates no lock file.

## The menu (U-18)

* A switch (1, 2, 3) or reset (6) that fails is **reported** (`That did not
  complete (exit status N). The menu is still open.`) and the menu continues.
  `Q` leaves with the status of the **last switch or reset** that was run
  (0 when it worked); the informational choices 4 (check), 5 (status) and H
  (help) are also protected from ending the run but do not replace that status,
  so a status screen cannot hide a failed update. When no switch or reset was
  run the status is the run's own: 0, or 10 after a self-update whose saved
  changes could not be re-applied. A switch the operator cancels ends with 9
  (declined "Save your changes temporarily?"); a reset the operator cancels
  (menu 6, then C, an empty version, or anything but `yes`) ends with 0, as
  before, and so replaces the status of an earlier failed switch like any other
  successful action.
* Inside a menu action errexit is now off (the action runs in a `||` context):
  a stray failing statement no longer ends the whole run, the action's own
  checks decide, and those roll the transaction back for every failure they know
  of (`transaction_abort`). Should an action ever return with its transaction
  still open, `menu_run` rolls it back before the menu goes on. Read, not
  proven: no statement in `switch_version_safe`, `reset_to_clean_state` or
  `select_version_interactive` was found whose failure errexit used to turn
  into an abort-and-rollback and that has no check of its own.
* **End of input at a prompt** (Ctrl-D, a closed pipe, `</dev/null`) at any menu
  prompt (the menu, "Press Enter to continue", the version selection, the reset
  menu and its version prompt, the start-up diagnostics pause on a terminal)
  leaves with the new **exit status 12** and says `Input ended (end of file) at
  a prompt: leaving the version manager.`, `The last action ended with exit
  status N.` when one failed, and `Exit status 12 means the input ended; Q
  leaves the menu normally.` A last line without a trailing newline is still an
  answer. The lock is released and `core.fileMode` restored as on any exit.
* End of input at a **confirmation** (`y/N`: save changes, continue as root,
  confirm the reset) is unchanged: it counts as "no" (safe), so that switch ends
  with 9. Every documented non-interactive exit code is unchanged.
* `--help` has a new block, "EXIT STATUS OF THE MENU".

### Exit codes (complete list)

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | general error (a failed switch, an invalid version, an unknown option) |
| 2 | prerequisites not met (git, awk, sed, grep, tput or **flock** missing; git or bash too old) |
| 3 | not a git repository |
| 4 | could not reach the remote (fetch failed; `--list` shows cached data and exits 4) or no remote |
| 5 | permission (repository not writable or owned by root; the state directory or lock file cannot be opened or written) |
| 6 | the requested or previous version is not available locally |
| 7 | locked: another updater holds the lock for longer than `LYREBIRD_UPDATER_LOCK_WAIT` |
| 8 | bad git state (merge, rebase, ... in progress; also an unreadable journal) |
| 9 | user aborted (declined a prompt, input ended at a confirmation, SIGINT, SIGTERM) |
| 10 | switch done but the saved changes conflict with the new version and were NOT re-applied (kept in the stash) |
| 11 | the automatic rollback could not restore everything |
| **12** | **new**: standard input ended at a menu prompt |

In the menu the run's status is the last switch/reset's (1, 5, 8, 9, 10, 11 as
above) when it is left with Q, or 12 at end of input.

## Migrations after a self-update (U-19)

* The updater that does the checkout of a self-update hands over to the
  **new** updater (`--post-update-restore|--post-update-complete`); that
  updater now runs `run_post_update_migrations` first thing, on the tree as the
  new version left it (before the operator's saved changes are re-applied, so
  the migration's `cp ./lyrebird-stream-manager.sh /usr/local/bin/` copies the
  version's file, not an edited one), then restores the stash, completes the
  service update and closes the journal. The old updater never runs them on
  that path, so they run once.
* **Recovery**: the journal keeps phase `handoff` until the new updater has
  finished all of that, so a kill -9 (or power cut) before or during the
  migrations is completed by the next run's `recover_handoff`, which now runs
  the migrations too. They are idempotent (the marker file
  `/var/lib/lyrebird/migrations/stream-manager-rename-v1` is written when the
  migration finished without errors), so one that already ran is skipped and one
  that was cut in the middle is finished.
* `--rollback` across an updater change goes through the same hand-over and runs
  the migrations of the version it returns to.
* **Not covered**: switching to a release whose updater predates the hand-over
  (before 1.5; see updater.md, U-17) is finished by the *current* updater
  ("Finishing this update with the current updater; start it again
  afterwards"), so the migrations of that release are not run; run
  `lyrebird-updater.sh --migrate` after it.

## Defects found while doing this (not fixed here)

| ID | Sev | Status | What |
|---|---|---|---|
| U-22 | P3 | not fixed (S) | The self-update hands the lock over by releasing it and letting the new image take it again. In that one `exec` another updater could take the lock, find the journal in phase `handoff` and "recover" it (complete the update) while the new image waits; the new image then finds the stash gone and a duplicate history line. Needs a second updater started within that instant. A fix would pass the descriptor across the exec on purpose (the pid and start time survive an exec) or have recovery ignore a `handoff` journal whose recorded pid is alive; either changes the "lock released before exec" behaviour the tests pin, so it is left for a decision |
| U-23 | P4 | observed | `--version`, `--help` and `--status` take the exclusive lock and wait up to 30 s for a running update (then exit 7). Pre-existing; the first updater pass's tests rely on `--status` refusing |
| U-24 | P4 | fixed in the test | `test_lyrebird_updater_failures.bats` asserted `*"RC=1"*`, which also matches `RC=12`; it is now exact |
| U-25 | P4 | observed (R), not fixed | The fault shims (`tests/helpers/updater/bin/git`, `killat`) kill/signal "the outermost ancestor whose command line names `lyrebird-updater.sh`". A shell whose own command line contains that text (for example `bash -c 'bats tests/...; shellcheck lyrebird-updater.sh'`, or an agent harness running such a line) is that ancestor: it was killed twice during this work (exit status 144). Start the updater tests from a script file or a command line that does not contain the file name |

## Test infrastructure added

`tests/test_lyrebird_updater_lock.bats` (22), `tests/test_lyrebird_updater_menu.bats`
(11), `tests/test_lyrebird_updater_migrations.bats` (8); in
`tests/updater_helper.bash`: `updater_hold_lock` (an updater that stays in its
critical section), `updater_wait_for`, `updater_descendants`, `updater_holders_stop`,
`updater_install_killat`, `updater_lock_path`; in the shims: `git` gains the
actions `SLEEP`, `DETACH` (a child that outlives git and the updater, as a
detached `git gc` does), `PROBE_FD` and `PROBE_LOCK`, `systemctl` logs a lock descriptor
it inherited (`FAKE_SVC_LOCK_PROBE`), and the new `killat` shim kills the updater
at an exact `mkdir` or `cp`. `tests/README.md`: the updater rows and the Test Files table.

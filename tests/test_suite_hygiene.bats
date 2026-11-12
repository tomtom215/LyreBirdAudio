#!/usr/bin/env bats
# Static guards for how the suite itself is written, so a class of host-state
# leak cannot come back unnoticed; and tests of tests/check_tmp_leaks.sh, the
# mechanical gate for host state (X-35).

load scratch_tmpdir

setup() {
    scratch_setup
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown() {
    [[ -n "${TEST_SCRATCH:-}" ]] && scratch_teardown
    return 0
}

@test "no test redirects the stream manager's log through MEDIAMTX_LOG_FILE alone" {
    # MEDIAMTX_LOG_FILE is MediaMTX's output file. The manager's own log has its
    # own variable (X-15); a test that sets only the former lets the manager
    # write the real /var/log/lyrebird-stream-manager.log of the machine it runs on.
    local f bad=0
    for f in "$ROOT"/tests/*.bats "$ROOT"/tests/*.bash; do
        [[ "$f" == "$ROOT/tests/test_stream_log_variables.bats" ]] && continue
        [[ "$f" == "$BATS_TEST_FILENAME" ]] && continue
        if grep -qE 'MEDIAMTX_LOG_FILE=' "$f" && ! grep -qF 'STREAM_MANAGER_LOG_FILE' "$f"; then
            echo "sets MEDIAMTX_LOG_FILE but never STREAM_MANAGER_LOG_FILE: ${f#"$ROOT"/}"
            bad=1
        fi
    done
    [ "$bad" -eq 0 ]
}

# ---------------------------------------------------------------------------
# scratch_setup (tests/scratch_tmpdir.bash) is what keeps the scripts' default
# logs and state off the machine's /var/log and /var/lib in every test file that
# loads it. The variable names it sets must be the ones the scripts read: each
# script is sourced for real and asked where it will write.
# ---------------------------------------------------------------------------

@test "scratch_setup points the manager, diagnostics and alert logs and the alert state at the scratch directory [X-35]" {
    run env ROOT="$ROOT" bash -c '
        source "$ROOT/lyrebird-stream-manager.sh" >/dev/null 2>&1
        printf "manager log: %s\n" "$LOG_FILE"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "manager log: $TEST_SCRATCH/lyrebird-stream-manager.log" ]

    run env ROOT="$ROOT" bash -c '
        source "$ROOT/lyrebird-diagnostics.sh" >/dev/null 2>&1
        printf "diagnostics log: %s\n" "$DIAGNOSTIC_LOG_FILE"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "diagnostics log: $TEST_SCRATCH/lyrebird-diagnostics.log" ]

    run env ROOT="$ROOT" bash -c '
        source "$ROOT/lyrebird-alerts.sh" >/dev/null 2>&1
        printf "alert log: %s\nalert state: %s\n" "$ALERT_LOG_FILE" "$ALERT_STATE_DIR"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "alert log: $TEST_SCRATCH/lyrebird-alerts.log"$'\n'"alert state: $TEST_SCRATCH/lyrebird-alert-state" ]
}

# ---------------------------------------------------------------------------
# tests/check_tmp_leaks.sh with LYREBIRD_LEAK_CHECK_HOST=1 (X-35)
#
# The real script runs from a throwaway copy of the repository layout, with a
# throwaway bats suite as the "suite" and a scratch tree as the "host"
# (LYREBIRD_LEAK_HOST_ROOT), so a leaking suite really leaks, into a place the
# test owns. Nothing here touches the machine's real /var/log, /etc or /run.
# ---------------------------------------------------------------------------

# leak_fixture: FAKE (a repository holding a copy of the check), HOST (the tree
# it watches), and CLEAN_PATH: the real bats first, then a systemctl that
# reports every unit inactive except those in $FAKE_ACTIVE_UNITS, then this
# run's PATH without the launcher directory bats puts first (the inner bats must
# not pick up this run's internals).
leak_fixture() {
    FAKE="$TEST_SCRATCH/repo"
    HOST="$TEST_SCRATCH/host"
    FAKEBIN="$TEST_SCRATCH/bin"
    mkdir -p "$FAKE/tests" "$FAKEBIN" "$TEST_SCRATCH/leaktmp" \
        "$HOST/var/log/lyrebird" "$HOST/etc/mediamtx" "$HOST/etc/logrotate.d"
    cp "$ROOT/tests/check_tmp_leaks.sh" "$FAKE/tests/"
    ln -s "$BATS_ROOT/bin/bats" "$FAKEBIN/bats"
    cat >"$FAKEBIN/systemctl" <<'SH'
#!/bin/sh
# systemctl is-active UNIT
unit="$2"
for u in $FAKE_ACTIVE_UNITS; do
    if [ "$u" = "$unit" ]; then
        echo active
        exit 0
    fi
done
echo inactive
exit 3
SH
    chmod +x "$FAKEBIN/systemctl"
    printf 'first line\n' >"$HOST/var/log/lyrebird-diagnostics.log"
    printf 'cfg: 1\n' >"$HOST/etc/mediamtx/mediamtx.yml"
    printf 'rotate\n' >"$HOST/etc/logrotate.d/existing"
    local dir clean=""
    while IFS= read -r -d: dir; do
        [[ "$dir" == *bats-core* ]] || clean+="${clean:+:}$dir"
    done <<<"$PATH:"
    CLEAN_PATH="$FAKEBIN:$clean"
}

# write_suite NAME BODY: FAKE/tests/NAME.bats with one test running BODY.
write_suite() {
    printf '@test "%s" {\n%s\n}\n' "$1" "$2" >"$FAKE/tests/$1.bats"
}

# run_check [VAR=value ...] [-- bats-args ...]: the copy of the check, in a
# clean environment, started in FAKE; the fake suite sees the host tree as
# $LYREBIRD_LEAK_HOST_ROOT.
run_check() {
    local -a envs=() args=()
    while (($#)); do
        if [[ "$1" == -- ]]; then
            shift
            args=("$@")
            break
        fi
        envs+=("$1")
        shift
    done
    cd "$FAKE"
    run env -i PATH="$CLEAN_PATH" HOME="${HOME:-/}" TMPDIR="$TEST_SCRATCH/leaktmp" \
        LYREBIRD_LEAK_HOST_ROOT="$HOST" ${envs[@]+"${envs[@]}"} \
        tests/check_tmp_leaks.sh ${args[@]+"${args[@]}"}
}

@test "host check: a suite that leaves the host alone passes [X-35]" {
    leak_fixture
    write_suite clean 'echo fine >"$BATS_TEST_TMPDIR/inside"'
    run_check LYREBIRD_LEAK_CHECK_HOST=1
    [ "$status" -eq 0 ]
    [[ "$output" == *"No host-state changes."* ]]
}

@test "host check: appending to a watched log fails the run and shows the file with its before and after size [X-35]" {
    leak_fixture
    write_suite leaky 'echo more >>"$LYREBIRD_LEAK_HOST_ROOT/var/log/lyrebird-diagnostics.log"'
    run_check LYREBIRD_LEAK_CHECK_HOST=1
    [ "$status" -eq 1 ]
    [[ "$output" == *"Test run changed host state outside TMPDIR"* ]]
    [[ "$output" == *"changed: $HOST/var/log/lyrebird-diagnostics.log"* ]]
    [[ "$output" == *"size=11"* ]]
    [[ "$output" == *"size=16"* ]]
}

@test "host check: a file or directory created under every watched path is reported [X-35]" {
    leak_fixture
    local rel rels=(
        var/log/lyrebird-stream-manager.log
        var/log/lyrebird/alerts.log
        var/log/mediamtx.out
        var/lib/lyrebird/alerts/state.last
        var/lib/mediamtx-ffmpeg/segment.aac
        run/lyrebird/status.json
        run/mediamtx-audio.pid
        etc/lyrebird/alerts.conf
        etc/mediamtx/audio-devices.conf
        etc/cron.d/mediamtx-monitor
        etc/systemd/system/mediamtx-audio.service
        etc/logrotate.d/mediamtx
        dev/shm/lyrebird-segments/mic1.aac
    )
    write_suite creates "for rel in ${rels[*]}; do
    mkdir -p \"\$(dirname \"\$LYREBIRD_LEAK_HOST_ROOT/\$rel\")\"
    echo x >\"\$LYREBIRD_LEAK_HOST_ROOT/\$rel\"
done"
    run_check LYREBIRD_LEAK_CHECK_HOST=1
    [ "$status" -eq 1 ]
    for rel in "${rels[@]}"; do
        [[ "$output" == *"created: $HOST/$rel"* ]] || {
            echo "not reported: $rel"
            return 1
        }
    done
}

@test "host check: a watched path that only exists after the run is reported as created [X-35]" {
    leak_fixture
    [ ! -e "$HOST/var/lib/lyrebird" ]
    write_suite appears 'mkdir -p "$LYREBIRD_LEAK_HOST_ROOT/var/lib/lyrebird/alerts"'
    run_check LYREBIRD_LEAK_CHECK_HOST=1
    [ "$status" -eq 1 ]
    [[ "$output" == *"created: $HOST/var/lib/lyrebird"$'\n'* ]]
    [[ "$output" == *"created: $HOST/var/lib/lyrebird/alerts"* ]]
}

@test "host check: a watched file the suite removes is reported as removed [X-35]" {
    leak_fixture
    write_suite removes 'rm -f "$LYREBIRD_LEAK_HOST_ROOT/etc/mediamtx/mediamtx.yml"'
    run_check LYREBIRD_LEAK_CHECK_HOST=1
    [ "$status" -eq 1 ]
    [[ "$output" == *"removed: $HOST/etc/mediamtx/mediamtx.yml"* ]]
}

@test "host check: a file replaced by a rename with the same size and mtime is reported, by its inode [X-35]" {
    leak_fixture
    write_suite replaces 'f="$LYREBIRD_LEAK_HOST_ROOT/etc/mediamtx/mediamtx.yml"; cp -p "$f" "$f.new"; mv "$f.new" "$f"'
    run_check LYREBIRD_LEAK_CHECK_HOST=1
    [ "$status" -eq 1 ]
    [[ "$output" == *"changed: $HOST/etc/mediamtx/mediamtx.yml"* ]]
}

@test "host check: a rewrite in place with the same size and inode, and a plain touch, are reported by their mtime [X-35]" {
    leak_fixture
    write_suite rewrites 'f="$LYREBIRD_LEAK_HOST_ROOT/var/log/lyrebird-diagnostics.log"; sleep 0.05; printf "other line\n" >"$f"; sleep 0.05; touch "$LYREBIRD_LEAK_HOST_ROOT/etc/mediamtx/mediamtx.yml"'
    run_check LYREBIRD_LEAK_CHECK_HOST=1
    [ "$status" -eq 1 ]
    [[ "$output" == *"changed: $HOST/var/log/lyrebird-diagnostics.log"* ]]
    [[ "$output" == *"changed: $HOST/etc/mediamtx/mediamtx.yml"* ]]
}

@test "host check: a relative path written in the repository working tree is reported, changes under .git are not [X-35]" {
    leak_fixture
    mkdir -p "$FAKE/.git"
    printf 'idx\n' >"$FAKE/.git/index"
    write_suite relative 'echo stray >alerts.log; echo refreshed >.git/index'
    run_check LYREBIRD_LEAK_CHECK_HOST=1
    [ "$status" -eq 1 ]
    [[ "$output" == *"created: $FAKE/alerts.log"* ]]
    [[ "$output" != *"$FAKE/.git"* ]]
}

@test "host check: a relative path written in the current directory outside the repository is reported [X-35]" {
    leak_fixture
    mkdir "$TEST_SCRATCH/elsewhere"
    write_suite relative 'echo stray >alerts.log'
    cd "$TEST_SCRATCH/elsewhere"
    run env -i PATH="$CLEAN_PATH" HOME="${HOME:-/}" TMPDIR="$TEST_SCRATCH/leaktmp" \
        LYREBIRD_LEAK_HOST_ROOT="$HOST" LYREBIRD_LEAK_CHECK_HOST=1 \
        "$FAKE/tests/check_tmp_leaks.sh" "$FAKE/tests"
    [ "$status" -eq 1 ]
    [[ "$output" == *"created: $TEST_SCRATCH/elsewhere/alerts.log"* ]]
}

@test "host check: bats arguments are passed through and the check applies to the files they name [X-35]" {
    leak_fixture
    write_suite one 'true'
    write_suite two 'echo more >>"$LYREBIRD_LEAK_HOST_ROOT/var/log/lyrebird-diagnostics.log"'
    run_check LYREBIRD_LEAK_CHECK_HOST=1 -- tests/one.bats
    [ "$status" -eq 0 ]
    run_check LYREBIRD_LEAK_CHECK_HOST=1 -- tests/two.bats
    [ "$status" -eq 1 ]
    [[ "$output" == *"changed: $HOST/var/log/lyrebird-diagnostics.log"* ]]
}

@test "host check: it is off unless LYREBIRD_LEAK_CHECK_HOST is 1, so a leaking suite passes by default and with 0 [X-35]" {
    leak_fixture
    write_suite leaky 'echo more >>"$LYREBIRD_LEAK_HOST_ROOT/var/log/lyrebird-diagnostics.log"'
    run_check
    [ "$status" -eq 0 ]
    [[ "$output" == *"No temp files left behind."* ]]
    [[ "$output" != *"host"* ]]
    run_check LYREBIRD_LEAK_CHECK_HOST=0
    [ "$status" -eq 0 ]
}

@test "host check: any other value is refused with status 2 and runs nothing [X-35]" {
    leak_fixture
    write_suite marker 'touch "$LYREBIRD_LEAK_HOST_ROOT/suite-ran"'
    run_check LYREBIRD_LEAK_CHECK_HOST=true
    [ "$status" -eq 2 ]
    [[ "$output" == *"LYREBIRD_LEAK_CHECK_HOST must be 0 or 1"* ]]
    [ ! -e "$HOST/suite-ran" ]
}

@test "host check: it refuses to run, and runs nothing, while a LyreBird service unit is active [X-35]" {
    leak_fixture
    write_suite marker 'touch "$LYREBIRD_LEAK_HOST_ROOT/suite-ran"'
    run_check LYREBIRD_LEAK_CHECK_HOST=1 FAKE_ACTIVE_UNITS="mediamtx-audio.service"
    [ "$status" -eq 2 ]
    [[ "$output" == *"systemd unit mediamtx-audio.service is active"* ]]
    [[ "$output" == *"Nothing was run."* ]]
    [ ! -e "$HOST/suite-ran" ]
    run_check LYREBIRD_LEAK_CHECK_HOST=1 FAKE_ACTIVE_UNITS="mediamtx.service"
    [ "$status" -eq 2 ]
    [[ "$output" == *"systemd unit mediamtx.service is active"* ]]
    [ ! -e "$HOST/suite-ran" ]
}

@test "host check: it refuses to run, and runs nothing, while a monitor cron job is installed [X-35]" {
    leak_fixture
    mkdir -p "$HOST/etc/cron.d"
    printf '* * * * * root /usr/local/bin/lyrebird-stream-manager.sh monitor\n' >"$HOST/etc/cron.d/mediamtx-monitor"
    write_suite marker 'touch "$LYREBIRD_LEAK_HOST_ROOT/suite-ran"'
    run_check LYREBIRD_LEAK_CHECK_HOST=1
    [ "$status" -eq 2 ]
    [[ "$output" == *"cron job $HOST/etc/cron.d/mediamtx-monitor is installed"* ]]
    [ ! -e "$HOST/suite-ran" ]
}

@test "host check: a failing suite keeps its failure status and the host changes are still shown [X-35]" {
    leak_fixture
    write_suite failing 'echo more >>"$LYREBIRD_LEAK_HOST_ROOT/var/log/lyrebird-diagnostics.log"; false'
    run_check LYREBIRD_LEAK_CHECK_HOST=1
    [ "$status" -ne 0 ]
    [[ "$output" == *"not ok 1 failing"* ]]
    [[ "$output" == *"changed: $HOST/var/log/lyrebird-diagnostics.log"* ]]
}

@test "host check: a TMPDIR leak and a host change are both reported [X-35]" {
    leak_fixture
    write_suite both 'mktemp "$TMPDIR/leftover.XXXXXX" >/dev/null; echo more >>"$LYREBIRD_LEAK_HOST_ROOT/var/log/lyrebird-diagnostics.log"'
    run_check LYREBIRD_LEAK_CHECK_HOST=1
    [ "$status" -eq 1 ]
    [[ "$output" == *"Test run left 1 entries in TMPDIR"* ]]
    [[ "$output" == *"Test run changed host state outside TMPDIR"* ]]
}

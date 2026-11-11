#!/usr/bin/env bats
# Process ownership in lyrebird-stream-manager.sh (register: LB-01, LB-02, LB-10
# manager part, X-25, X-26 and the refused-restart marker; decisions D1, D11).
#
# Every test runs the REAL script: it is sourced in a fresh bash (as the
# installer tests do) and its real functions are called against real, live
# processes. Processes the manager must tell apart are decoys
# (tests/process_decoys.bash): copies of the bash binary run on a script that
# only waits, so their /proc/<pid>/exe, argv and name are whatever the test
# chooses. Nothing here can signal a process that is not a decoy: `kill` is a
# guarded function, pkill/pgrep are shims that act only on decoys (so a
# name-based call in the code under test hits decoys, which is how the old code
# is shown to be wrong, and never a real process), and systemctl is a shim.
#
# Two installations share the machine in these tests:
#
#   ours    $OW/{cfg,ff,mtx.pid,...}: what the manager under test owns
#   other   $OW/other/...: another installation's processes (same MediaMTX
#           binary with another configuration, a wrapper of the same stream name
#           in another directory, an FFmpeg that reads a stream) and an editor
#           that has our wrapper script open
#
# What the hardware would provide (USB devices, the ALSA check, the USB
# settling wait) is stood in for; the lifecycle logic is the real function.

load scratch_tmpdir
load process_decoys

setup() {
    scratch_setup
    decoy_setup
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
    OW="$TEST_SCRATCH/ow"
    mkdir -p "$OW/cfg" "$OW/ff" "$OW/bin" "$OW/shim" "$OW/other/bin" "$OW/other/ff"
    BASH_REAL="$(readlink -f "$(command -v bash)")"
    EXTRA_PIDS=()

    export PROJECT_ROOT OW BASH_REAL
    export MEDIAMTX_CONFIG_DIR="$OW/cfg"
    export MEDIAMTX_PID_FILE="$OW/mtx.pid"
    export MEDIAMTX_FFMPEG_DIR="$OW/ff"
    export MEDIAMTX_LOCK_FILE="$OW/run.lock"
    export MEDIAMTX_LOG_FILE="$OW/sm.log" STREAM_MANAGER_LOG_FILE="$OW/sm.log"
    export MEDIAMTX_RESTART_MARKER="$OW/restart.marker"
    export MEDIAMTX_CLEANUP_MARKER="$OW/cleanup.marker"
    export MEDIAMTX_BINARY="$OW/bin/mediamtx"
    # A host name nothing else uses, so the old name-based patterns can only
    # match what these tests start
    export MEDIAMTX_HOST="ownership.invalid"
    export LOCK_ACQUISITION_TIMEOUT=2 STOP_LOCK_TIMEOUT=1
    export STREAM_STARTUP_DELAY=0 STREAM_VALIDATION_DELAY=0 STREAM_VALIDATION_ATTEMPTS=1
    export MEDIAMTX_API_TIMEOUT=5 USB_STABILIZATION_DELAY=1 RESTART_STABILIZATION_DELAY=1
    CFG="$OW/cfg/mediamtx.yml"
    FF="$OW/ff"

    # The configured MediaMTX binary is a copy of bash; run on a hold script as
    # its "configuration file" it waits, which makes it a live look-alike
    decoy_bash_copy "$MEDIAMTX_BINARY"
    decoy_hold_script "$CFG"
    # It stands for the configuration the manager wrote on an earlier start, so it
    # carries the managed marker (a comment line for the decoy's bash as well);
    # a file without it would be the operator's and is never rewritten
    { printf '# Managed by LyreBirdAudio\n'; cat "$CFG"; } >"$CFG.new" && mv "$CFG.new" "$CFG"

    # Port probes and the readiness probe see an idle, healthy host
    printf '#!/bin/bash\nexit 1\n' >"$OW/shim/lsof"
    printf '#!/bin/bash\nexit 0\n' >"$OW/shim/ss"
    # a MediaMTX API that answers like a healthy one (200 and a paths list)
    install -m 755 "$BATS_TEST_DIRNAME/helpers/mediamtx/curl_shim" "$OW/shim/curl"
    chmod +x "$OW/shim/"*
    PATH="$OW/shim:$PATH"
    export SEAM_LOG="$OW/seam.log"
    : >"$SEAM_LOG"
}

teardown() {
    local pid child
    for pid in "${EXTRA_PIDS[@]}"; do
        [[ -n "$pid" ]] || continue
        # children first: a wrapper's FFmpeg runs in a session of its own
        for child in $(ps -o pid= --ppid "$pid" 2>/dev/null); do
            builtin kill -9 "$child" 2>/dev/null || true
        done
        builtin kill -9 "$pid" 2>/dev/null || true
    done
    decoy_teardown
    scratch_teardown
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run a function (or `eval CODE`) of the real script in a fresh bash, with the
# guarded kill (so only decoys can be signalled). $PREAMBLE is evaluated after
# sourcing, to stand in for hardware.
run_mgr() {
    export -f kill decoy_registered
    export PREAMBLE="${PREAMBLE:-}"
    run bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"; eval "$PREAMBLE"; "$@"' _ "$@"
}

# The same without the guard, for processes the test started itself (not decoys)
run_mgr_real() {
    export PREAMBLE="${PREAMBLE:-}"
    run bash -c 'source "$PROJECT_ROOT/lyrebird-stream-manager.sh"; eval "$PREAMBLE"; "$@"' _ "$@"
}

# Hardware seams (devices come from $DEVICES, "name:card name:card ...")
use_seams() {
    PREAMBLE='
detect_audio_devices() { printf "%s\n" ${DEVICES:-}; }
wait_for_usb_stabilization() { echo "stabilize $*" >>"$SEAM_LOG"; return 0; }
check_audio_device() { return 0; }
validate_stream() { return 0; }
'
    export DEVICES="${DEVICES:-mic1:31}"
}

# Our MediaMTX: a decoy at the configured binary with the configuration file as
# argv[1], recorded in the PID file by the real write_pid_atomic
our_mediamtx_up() {
    decoy_spawn mtx "$MEDIAMTX_BINARY" "$CFG"
    run_mgr write_pid_atomic "$(decoy_pid mtx)" "$MEDIAMTX_PID_FILE"
    [ "$status" -eq 0 ]
}

# Our wrapper of stream $1: bash running <wrapper dir>/<stream>.sh, recorded
our_wrapper_up() {
    local stream="$1"
    decoy_hold_script "$FF/$stream.sh"
    decoy_spawn "w_$stream" "$BASH_REAL" "$FF/$stream.sh"
    run_mgr write_pid_atomic "$(decoy_pid "w_$stream")" "$FF/$stream.pid"
    [ "$status" -eq 0 ]
}

# Another installation's processes
other_installation_up() {
    decoy_hold_script "$OW/other/mediamtx.yml"
    decoy_hold_script "$OW/other/ff/mic1.sh"
    decoy_hold_script "$OW/other/reader.sh"
    decoy_bash_copy "$OW/other/bin/ffmpeg"
    # same binary, another configuration (for example mediamtx.service's)
    decoy_spawn X_mtx "$MEDIAMTX_BINARY" "$OW/other/mediamtx.yml"
    # a wrapper of the same stream name in another wrapper directory
    decoy_spawn X_wrapper "$BASH_REAL" "$OW/other/ff/mic1.sh"
    # an FFmpeg reading a stream from the local server, started as plain "ffmpeg"
    decoy_spawn_as X_reader ffmpeg "$OW/other/bin/ffmpeg" "$OW/other/reader.sh" \
        -i "rtsp://${MEDIAMTX_HOST}:8554/mic1"
}

# An operator's editor that has our wrapper script $1 open (argv[1] is the script)
editor_on_wrapper_up() {
    decoy_bash_copy "$OW/other/bin/vim"
    decoy_spawn X_editor "$OW/other/bin/vim" "$FF/$1.sh"
}

# The PIDs a signal was sent to so far (kill -0 and shim lookups left out)
signalled_pids() {
    decoy_signals | awk '{print $NF}' | sed 's/^-//' | sort -un
}

# Fail unless every signal so far went to one of the given decoy labels, and no
# pattern-based pkill/pgrep was used
assert_signals_only_to() {
    local label allowed=" " pid
    for label in "$@"; do
        allowed+="$(decoy_pid "$label") "
    done
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        [[ "$allowed" == *" $pid "* ]] || {
            echo "signal sent to '$pid', which is not one of: $*"
            decoy_signals
            return 1
        }
    done < <(signalled_pids)
    ! grep -qE '^(pkill|pgrep -[a-zA-Z]*[fx])' "$SIGNAL_LOG" || {
        echo "a pattern-based pkill/pgrep was used:"
        grep -E '^(pkill|pgrep)' "$SIGNAL_LOG"
        return 1
    }
}

assert_alive() {
    local label
    for label in "$@"; do
        decoy_alive "$label" || {
            echo "decoy $label was killed"
            decoy_signals
            return 1
        }
    done
}

assert_dead() {
    local label
    for label in "$@"; do
        decoy_dead "$label" || {
            echo "decoy $label is still running"
            return 1
        }
    done
}

# Wait until $1 (a command string) succeeds, at most $2 seconds
wait_until() {
    local i
    for ((i = 0; i < ${2:-10} * 20; i++)); do
        eval "$1" && return 0
        sleep 0.05
    done
    echo "timed out waiting for: $1" >&2
    return 1
}

# Wait until process $1 is gone (a zombie counts as gone)
wait_gone() {
    local pid="$1" i state
    for ((i = 0; i < ${2:-10} * 20; i++)); do
        state="$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)"
        if [[ -z "$state" || "$state" == Z ]]; then
            return 0
        fi
        sleep 0.05
    done
    echo "process $pid is still running" >&2
    return 1
}

# Stand-ins for the hardware a real wrapper needs: `bash` on PATH is a shim
# that runs the wrapper the manager generated with its /dev/snd check pointed at
# an existing path and a stub ffmpeg first on PATH. The file is rewritten in
# place, so the process still runs "<wrapper dir>/<stream>.sh" as argv[1]. The
# launch, the wrapper text and the PID file are the real ones.
use_wrapper_stand_ins() {
    mkdir -p "$OW/wrapbin"
    cat >"$OW/wrapbin/bash" <<'SHIM_EOF'
#!/bin/bash
if [[ "${1:-}" == "$OW/ff/"*.sh ]]; then
    script="$1"
    shift
    sed -e 's#/dev/snd/pcmC${card_num}D0c#/dev/null#' \
        -e 's#/dev/snd/pcmC${CARD_NUM}D0c#/dev/null#' \
        -e 's#export PATH="/usr/local/sbin#export PATH="'"$OW"'/bin:/usr/local/sbin#' \
        "$script" >"$script.rewritten"
    cat "$script.rewritten" >"$script"
    rm -f "$script.rewritten"
    exec /bin/bash "$script" "$@"
fi
exec /bin/bash "$@"
SHIM_EOF
    # An FFmpeg that only waits (argv[0] stays "ffmpeg"); it ends on its own
    printf '#!/bin/bash\nexec -a ffmpeg sleep 120\n' >"$OW/bin/ffmpeg"
    chmod +x "$OW/wrapbin/bash" "$OW/bin/ffmpeg"
    PATH="$OW/wrapbin:$PATH"
    # A capture PCM for the stand-in cards: the manager reads the card's capture
    # PCMs from ASOUND_PROC_ROOT and checks their device nodes under DEV_SND_ROOT
    # (the wrapper carries both roots), instead of a fixed /dev/snd/pcmC<N>D0c
    local card
    export ASOUND_PROC_ROOT="$OW/asound" DEV_SND_ROOT="$OW/dev-snd"
    mkdir -p "$ASOUND_PROC_ROOT" "$DEV_SND_ROOT"
    for card in 31 32; do
        mkdir -p "$ASOUND_PROC_ROOT/card${card}/pcm0c"
        echo "0d8c:0014" >"$ASOUND_PROC_ROOT/card${card}/usbid"
        : >"$DEV_SND_ROOT/controlC${card}"
        : >"$DEV_SND_ROOT/pcmC${card}D0c"
    done
}

# A MediaMTX the real start_mediamtx can launch: a copy of bash at the configured
# path, which BASH_ENV (for that copy only) makes wait instead of running the
# configuration file as a script
use_mediamtx_launch_stub() {
    cat >"$OW/prelude.sh" <<'STUB_EOF'
if [[ "$BASH" == "$MEDIAMTX_BINARY" ]]; then
    exec {stub_fd}<>"$DECOY_DIR/hold"
    read -r -t 300 -u "$stub_fd" || true
    exit 0
fi
STUB_EOF
    export BASH_ENV="$OW/prelude.sh"
}

# ---------------------------------------------------------------------------
# X-26: read_pid_safe decides by start time, not by the program's name
# ---------------------------------------------------------------------------

@test "read_pid_safe keeps the PID file of a live process whose binary is not mediamtx, bash or ffmpeg [X-26]" {
    # A real MediaMTX started from a differently named binary: the old comm
    # allowlist took it for a recycled PID, deleted its PID file and so made
    # the manager lose track of a running process
    decoy_bash_copy "$OW/bin/lbuniq"
    decoy_spawn odd "$OW/bin/lbuniq" "$CFG"
    echo "$(decoy_pid odd)" >"$OW/odd.pid"
    run_mgr read_pid_safe "$OW/odd.pid"
    [ "$status" -eq 0 ]
    [ "$output" = "$(decoy_pid odd)" ]
    [ -f "$OW/odd.pid" ]
    assert_alive odd
}

@test "read_pid_safe drops the PID file and the start-time record of a dead process [X-26]" {
    decoy_spawn gone "$BASH_REAL" "$CFG"
    run_mgr write_pid_atomic "$(decoy_pid gone)" "$OW/gone.pid"
    [ "$status" -eq 0 ]
    [ -f "$OW/gone.pid.id" ]
    builtin kill -KILL "$(decoy_pid gone)"
    wait_gone "$(decoy_pid gone)"
    run_mgr read_pid_safe "$OW/gone.pid"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$OW/gone.pid" ]
    [ ! -e "$OW/gone.pid.id" ]
}

@test "read_pid_safe treats a PID with another start time as recycled and does not signal the process now using it [X-26]" {
    decoy_spawn bystander "$BASH_REAL" "$CFG"
    local pid start
    pid="$(decoy_pid bystander)"
    start="$(decoy_starttime "$pid")"
    # The record says an earlier process had this PID
    echo "$pid" >"$OW/r.pid"
    echo "$pid $((start - 5))" >"$OW/r.pid.id"
    run_mgr read_pid_safe "$OW/r.pid"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$OW/r.pid" ]
    [ ! -e "$OW/r.pid.id" ]
    assert_alive bystander
    [ -z "$(decoy_signals)" ]
}

@test "read_pid_safe accepts a PID file written without a start-time record (older versions) while the process lives [X-26]" {
    decoy_spawn legacy "$BASH_REAL" "$CFG"
    echo "$(decoy_pid legacy)" >"$OW/legacy.pid"
    run_mgr read_pid_safe "$OW/legacy.pid"
    [ "$output" = "$(decoy_pid legacy)" ]
    [ -f "$OW/legacy.pid" ]
}

@test "write_pid_atomic keeps the PID file a plain PID and records the start time beside it [X-26, D11]" {
    decoy_spawn rec "$BASH_REAL" "$CFG"
    local pid
    pid="$(decoy_pid rec)"
    run_mgr write_pid_atomic "$pid" "$OW/rec.pid"
    [ "$status" -eq 0 ]
    # systemd's PIDFile= and the other readers of this file parse a bare PID
    [ "$(<"$OW/rec.pid")" = "$pid" ]
    [ "$(wc -l <"$OW/rec.pid")" -eq 1 ]
    [ "$(<"$OW/rec.pid.id")" = "$pid $(decoy_starttime "$pid")" ]
}

@test "an unreadable /proc entry (a run without root) is 'unknown', not 'dead': the PID file is kept and nothing is signalled [X-26]" {
    command -v setpriv >/dev/null || skip "setpriv is not available"
    # The manager's own MediaMTX runs as root; this is a run as another user,
    # which can read /proc/<pid>/stat but not /proc/<pid>/exe
    our_mediamtx_up
    local who=65534 pid
    pid="$(decoy_pid mtx)"
    run setpriv --reuid="$who" --regid="$who" --clear-groups readlink "/proc/$pid/exe"
    [ "$status" -ne 0 ] || skip "this user can read other users' /proc/<pid>/exe"
    # The real scripts, readable by that user
    mkdir -p "$TEST_SCRATCH/nobody"
    cp "$PROJECT_ROOT/lyrebird-stream-manager.sh" "$PROJECT_ROOT/lyrebird-common.sh" "$TEST_SCRATCH/nobody/"
    chmod 755 "$TEST_SCRATCH" "$TEST_SCRATCH/nobody" "$OW" "$OW/cfg" "$OW/ff"
    # every directory above must be traversable by that user too (the suite's
    # own temp directories are private; they are removed with the run)
    local d="$TEST_SCRATCH"
    while [[ "$d" != "/" ]]; do
        if ! setpriv --reuid="$who" --regid="$who" --clear-groups test -x "$d"; then
            [[ -O "$d" ]] || skip "cannot make $d traversable for another user"
            chmod o+x "$d"
        fi
        d="$(dirname "$d")"
    done
    chmod 644 "$TEST_SCRATCH/nobody/"*.sh "$MEDIAMTX_PID_FILE" "$MEDIAMTX_PID_FILE.id"
    # the PID file is deletable by that user, as it would be for a user who owns it
    chmod 777 "$OW"
    run setpriv --reuid="$who" --regid="$who" --clear-groups \
        env MEDIAMTX_LOG_FILE="$TEST_SCRATCH/nobody/sm.log" STREAM_MANAGER_LOG_FILE="$TEST_SCRATCH/nobody/sm.log" \
        bash -c '
            cd "$1" || exit 9
            source ./lyrebird-stream-manager.sh
            pid="$(read_pid_safe "$MEDIAMTX_PID_FILE")"
            rc=0; is_managed_mediamtx_pid "$pid" || rc=$?
            running=no; is_mediamtx_running && running=yes
            stop_rc=0; stop_recorded_process "$MEDIAMTX_PID_FILE" mediamtx 1 || stop_rc=$?
            echo "pid=$pid identity=$rc running=$running stop=$stop_rc"' _ "$TEST_SCRATCH/nobody"
    [[ "$output" == *"pid=$pid identity=2 running=yes stop=2"* ]]
    # kept, and not signalled
    [ -f "$MEDIAMTX_PID_FILE" ]
    assert_alive mtx
    [ -z "$(decoy_signals)" ]
}

# ---------------------------------------------------------------------------
# terminate_process_group
# ---------------------------------------------------------------------------

@test "terminate_process_group does not signal a process whose start time is not the recorded one [LB-10]" {
    decoy_spawn victim "$BASH_REAL" "$CFG"
    local pid start
    pid="$(decoy_pid victim)"
    start="$(decoy_starttime "$pid")"
    run_mgr terminate_process_group "$pid" 2 "$((start + 1))"
    [ "$status" -eq 0 ]
    assert_alive victim
    [ -z "$(decoy_signals)" ]
    # with the right start time the same call stops it
    run_mgr terminate_process_group "$pid" 2 "$start"
    [ "$status" -eq 0 ]
    assert_dead victim
}

# A wrapper-shaped process: a loop that keeps restarting its child and a TERM
# trap that stops the child, started by nohup setsid as spawn_detached does. From
# a shell that has no SIGINT trap (the script sourced, as here) it inherits
# "ignore SIGINT" for being a background job; the installed script sets such a
# trap, so its real wrappers keep SIGINT. The first signal must work either way.
write_loop_wrapper() {
    cat >"$1" <<'WRAP_EOF'
#!/bin/bash
child=""
stop() { [[ -z "$child" ]] || kill "$child" 2>/dev/null; exit 0; }
trap stop TERM
echo "SigIgn $(grep SigIgn /proc/$$/status | cut -f2)" >"$LB_WRAPPER_NOTE"
while true; do
    setsid sleep 300 &
    child=$!
    echo "$child" >>"$LB_WRAPPER_CHILDREN"
    wait "$child" 2>/dev/null || true
    child=""
    sleep 0.2
done
WRAP_EOF
    chmod +x "$1"
}

@test "terminate_process_group stops a wrapper that ignores SIGINT well before its timeout and leaves no child behind [LB-10]" {
    write_loop_wrapper "$FF/loop.sh"
    export LB_WRAPPER_NOTE="$OW/note" LB_WRAPPER_CHILDREN="$OW/children"
    : >"$LB_WRAPPER_CHILDREN"
    (
        nohup setsid bash "$FF/loop.sh" >/dev/null 2>&1 3>&- &
        echo $! >"$OW/loop.pid"
    )
    wait_until '[[ -s "$LB_WRAPPER_NOTE" && -s "$LB_WRAPPER_CHILDREN" ]]'
    local wpid child
    wpid="$(<"$OW/loop.pid")"
    EXTRA_PIDS+=("$wpid")
    child="$(head -n1 "$LB_WRAPPER_CHILDREN")"
    EXTRA_PIDS+=("$child")
    # it really ignores SIGINT here (inherited from the sourcing shell)
    [[ "$(<"$LB_WRAPPER_NOTE")" == "SigIgn "*7 ]]

    local t0=$SECONDS
    run_mgr_real terminate_process_group "$wpid" 10
    [ "$status" -eq 0 ]
    # SIGINT is ignored by wrapper and child alike, so a SIGINT first sits out the
    # whole timeout and then needs SIGKILL
    [ $((SECONDS - t0)) -lt 5 ]
    wait_gone "$wpid" 1
    local c
    while read -r c; do
        wait_gone "$c" 1
    done <"$LB_WRAPPER_CHILDREN"
}

# ---------------------------------------------------------------------------
# LB-10 / D11: nothing is chosen by name or pattern
# ---------------------------------------------------------------------------

@test "no pkill, killall, pidof or pgrep -f/-x pattern is left in the script's commands [LB-10, D11]" {
    run bash -c 'grep -nE "(^|[^_[:alnum:]-])(pkill|killall|pidof|pgrep[[:space:]]+-[a-zA-Z]*[fx])" "$1" | grep -vE "^[0-9]+:[[:space:]]*#"' _ "$PROJECT_ROOT/lyrebird-stream-manager.sh"
    # what is printed is a pattern-based process command: there must be none
    [ -z "$output" ]
}

@test "stop_mediamtx stops only the processes this manager started; another installation's processes and an FFmpeg reader survive [LB-10]" {
    our_mediamtx_up
    our_wrapper_up mic1
    our_wrapper_up mic2
    other_installation_up
    editor_on_wrapper_up mic1
    run_mgr stop_mediamtx
    [ "$status" -eq 0 ]
    assert_dead mtx w_mic1 w_mic2
    assert_alive X_mtx X_wrapper X_reader X_editor
    assert_signals_only_to mtx w_mic1 w_mic2
    [ ! -e "$MEDIAMTX_PID_FILE" ]
    [ ! -e "$MEDIAMTX_PID_FILE.id" ]
    [ ! -e "$FF/mic1.pid" ]
}

@test "cleanup_stale_processes stops only what this manager started [LB-10]" {
    our_mediamtx_up
    our_wrapper_up mic1
    other_installation_up
    editor_on_wrapper_up mic1
    run_mgr cleanup_stale_processes
    [ "$status" -eq 0 ]
    assert_dead mtx w_mic1
    assert_alive X_mtx X_wrapper X_reader X_editor
    assert_signals_only_to mtx w_mic1
}

@test "force_stop_mediamtx kills only what this manager started; the other installation's processes survive [LB-10]" {
    our_mediamtx_up
    our_wrapper_up mic1
    other_installation_up
    editor_on_wrapper_up mic1
    run_mgr force_stop_mediamtx
    [ "$status" -eq 0 ]
    assert_dead mtx w_mic1
    assert_alive X_mtx X_wrapper X_reader X_editor
    assert_signals_only_to mtx w_mic1
    # SIGKILL, at once
    decoy_signals | grep -q "kill -KILL $(decoy_pid mtx)"
    [ ! -e "$MEDIAMTX_PID_FILE" ]
    [ ! -e "$FF/mic1.pid" ]
}

@test "a PID file that names another installation's process does not make stop, cleanup or force-stop signal it [LB-10, X-26]" {
    other_installation_up
    local verb
    for verb in stop_mediamtx cleanup_stale_processes force_stop_mediamtx; do
        # our PID files name the other installation's MediaMTX and wrapper
        echo "$(decoy_pid X_mtx)" >"$MEDIAMTX_PID_FILE"
        echo "$(decoy_pid X_wrapper)" >"$FF/mic1.pid"
        run_mgr "$verb"
        [ "$status" -eq 0 ]
        assert_alive X_mtx X_wrapper X_reader
        [ -z "$(decoy_signals)" ] || {
            echo "$verb signalled: $(decoy_signals)"
            return 1
        }
        [ ! -e "$MEDIAMTX_PID_FILE" ]
        [ ! -e "$FF/mic1.pid" ]
    done
}

@test "is_restart_scenario ignores other installations' MediaMTX and FFmpeg processes [LB-10]" {
    other_installation_up
    run_mgr is_restart_scenario
    # not a restart: nothing of ours is running (the old host-wide pgrep said yes)
    [ "$status" -eq 1 ]
    our_mediamtx_up
    run_mgr is_restart_scenario
    [ "$status" -eq 0 ]
}

@test "verify_cleanup_complete counts this installation's leftovers, not another installation's FFmpeg [LB-10]" {
    other_installation_up
    run_mgr verify_cleanup_complete
    [ "$status" -eq 0 ]
    [[ "$output" != *"orphaned"* ]]
    # a wrapper and an FFmpeg of ours that cleanup missed
    our_wrapper_up mic1
    decoy_bash_copy "$OW/bin/ffmpeg"
    decoy_hold_script "$OW/orphan.sh"
    DECOY_STDOUT="$FF/mic1.log" decoy_spawn_as orphan ffmpeg "$OW/bin/ffmpeg" "$OW/orphan.sh"
    run_mgr verify_cleanup_complete
    [ "$status" -eq 1 ]
    [[ "$output" == *"Found 1 orphaned wrapper processes"* ]]
    [[ "$output" == *"Found 1 orphaned FFmpeg processes"* ]]
}


@test "count_wrapper_processes counts the wrappers of this wrapper directory only [LB-10]" {
    other_installation_up
    decoy_hold_script "$FF/mic1.sh"
    editor_on_wrapper_up mic1
    run_mgr count_wrapper_processes
    [ "$output" = "0" ]
    our_wrapper_up mic1
    our_wrapper_up mic2
    run_mgr count_wrapper_processes
    [ "$output" = "2" ]
}


# ---------------------------------------------------------------------------
# force-stop --kill-all [--yes]
# ---------------------------------------------------------------------------

@test "force-stop --kill-all without --yes prints exactly what it would signal and why, signals nothing and exits non-zero [D11]" {
    our_mediamtx_up
    our_wrapper_up mic1
    other_installation_up
    editor_on_wrapper_up mic1
    : >"$MEDIAMTX_RESTART_MARKER"
    run_mgr eval 'COMMAND=force-stop; trap cleanup EXIT; force_stop_mediamtx --kill-all'
    [ "$status" -eq 1 ]
    [[ "$output" == *"would send SIGKILL"* ]]
    [[ "$output" == *"Nothing was signalled"* ]]
    [[ "$output" == *"force-stop --kill-all --yes"* ]]
    # listed, each with the reason: our MediaMTX and the other installation's
    # (same binary), our wrapper, and the editor that names our wrapper script
    local label
    for label in mtx X_mtx w_mic1 X_editor; do
        [[ "$output" == *"PID $(decoy_pid "$label") ("* ]] || {
            echo "$label ($(decoy_pid "$label")) missing from the preview"
            return 1
        }
    done
    [[ "$output" == *"its executable is the configured MediaMTX binary"* ]]
    [[ "$output" == *"in this installation's wrapper directory"* ]]
    # not listed: another installation's wrapper and the FFmpeg reader
    [[ "$output" != *"PID $(decoy_pid X_wrapper) ("* ]]
    [[ "$output" != *"PID $(decoy_pid X_reader) ("* ]]
    # nothing signalled, nothing removed, and the non-zero exit left no cleanup
    # marker (which would make every wrapper stop at its next loop)
    [ -z "$(decoy_signals)" ]
    assert_alive mtx w_mic1 X_mtx X_wrapper X_reader X_editor
    [ -f "$MEDIAMTX_PID_FILE" ]
    [ -f "$FF/mic1.pid" ]
    [ -f "$MEDIAMTX_RESTART_MARKER" ]
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]
}

@test "force-stop --kill-all --yes signals exactly the processes of that preview and no others [D11]" {
    our_mediamtx_up
    our_wrapper_up mic1
    other_installation_up
    editor_on_wrapper_up mic1
    run_mgr force_stop_mediamtx --kill-all --yes
    [ "$status" -eq 0 ]
    assert_dead mtx w_mic1 X_mtx X_editor
    assert_alive X_wrapper X_reader
    assert_signals_only_to mtx w_mic1 X_mtx X_editor
    [ ! -e "$MEDIAMTX_PID_FILE" ]
    [ ! -e "$FF/mic1.pid" ]
}

@test "force-stop --kill-all also finds an FFmpeg that logs into the wrapper directory after its wrapper died [D11]" {
    decoy_bash_copy "$OW/bin/ffmpeg"
    decoy_hold_script "$OW/orphan.sh"
    # an orphaned FFmpeg: argv[0] is "ffmpeg", its output goes to our stream log
    DECOY_STDOUT="$FF/mic1.log" decoy_spawn_as orphan ffmpeg "$OW/bin/ffmpeg" "$OW/orphan.sh"
    other_installation_up
    run_mgr force_stop_mediamtx --kill-all
    [ "$status" -eq 1 ]
    [[ "$output" == *"PID $(decoy_pid orphan) (ffmpeg): FFmpeg writing its log $FF/mic1.log"* ]]
    [[ "$output" != *"PID $(decoy_pid X_reader) ("* ]]
    assert_alive orphan
    run_mgr force_stop_mediamtx --kill-all --yes
    [ "$status" -eq 0 ]
    assert_dead orphan
    assert_alive X_reader X_wrapper
}

@test "force-stop --kill-all --yes kills the FFmpeg children of a wrapper, which run in a session of their own [D11]" {
    write_loop_wrapper "$FF/loop.sh"
    export LB_WRAPPER_NOTE="$OW/note" LB_WRAPPER_CHILDREN="$OW/children"
    : >"$LB_WRAPPER_CHILDREN"
    (
        nohup setsid bash "$FF/loop.sh" >/dev/null 2>&1 3>&- &
        echo $! >"$OW/loop.pid"
    )
    wait_until '[[ -s "$LB_WRAPPER_NOTE" && -s "$LB_WRAPPER_CHILDREN" ]]'
    local wpid child
    wpid="$(<"$OW/loop.pid")"
    child="$(head -n1 "$LB_WRAPPER_CHILDREN")"
    EXTRA_PIDS+=("$child" "$wpid")
    run_mgr_real force_stop_mediamtx --kill-all
    [ "$status" -eq 1 ]
    [[ "$output" == *"PID $wpid (wrapper)"* ]]
    [[ "$output" == *"PID $child (ffmpeg): child of wrapper $wpid"* ]]
    run_mgr_real force_stop_mediamtx --kill-all --yes
    [ "$status" -eq 0 ]
    wait_gone "$wpid" 3
    wait_gone "$child" 3
}

@test "force-stop rejects unknown options and --yes without --kill-all, signalling nothing and leaving no cleanup marker [D11]" {
    our_mediamtx_up
    run_mgr eval 'COMMAND=force-stop; trap cleanup EXIT; force_stop_mediamtx --yes'
    [ "$status" -eq 1 ]
    [[ "$output" == *"--yes only applies to --kill-all"* ]]
    run_mgr eval 'COMMAND=force-stop; trap cleanup EXIT; force_stop_mediamtx --everything'
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown force-stop option: --everything"* ]]
    assert_alive mtx
    [ -z "$(decoy_signals)" ]
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]
}

@test "the command line passes the options after force-stop on to the function, and help documents them [D11]" {
    run_mgr eval 'parse_arguments force-stop --kill-all --yes; echo "command=$COMMAND args=${COMMAND_ARGS[*]}"'
    [[ "$output" == *"command=force-stop args=--kill-all --yes"* ]]
    run_mgr eval 'parse_arguments start; echo "command=$COMMAND args=${#COMMAND_ARGS[@]}"'
    [[ "$output" == *"command=start args=0"* ]]
    run_mgr show_help
    [[ "$output" == *"force-stop --kill-all [--yes]"* ]]
}

# ---------------------------------------------------------------------------
# LB-02 / D1: one owner
# ---------------------------------------------------------------------------

@test "help documents exit code 8 and the idempotent start [LB-02, LB-01]" {
    run_mgr show_help
    [[ "$output" == *"8  - Another MediaMTX owns the node"* ]]
    [[ "$output" == *"Safe to repeat"* ]]
}

@test "start is refused with exit 8 while mediamtx.service is active, touching nothing [LB-02]" {
    use_seams
    decoy_unit_active mediamtx
    printf 'sentinel: configuration of the other owner\n' >"$CFG"
    local before
    before="$(<"$CFG")"
    run_mgr eval 'COMMAND=start; trap cleanup EXIT; start_mediamtx'
    [ "$status" -eq 8 ]
    [[ "$output" == *"Refusing to start: mediamtx.service is active and owns MediaMTX"* ]]
    # nothing was written, started, stopped or marked
    [ "$(<"$CFG")" = "$before" ]
    [ ! -e "$MEDIAMTX_PID_FILE" ]
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]
    [ ! -e "$MEDIAMTX_RESTART_MARKER" ]
    [ ! -s "$SEAM_LOG" ]
    [ -z "$(decoy_signals)" ]
    # the lifecycle lock was released
    run_mgr acquire_lock 1
    [ "$status" -eq 0 ]
}

@test "start is refused with exit 8, and signals nothing, when a MediaMTX this manager did not start runs on its configuration [LB-02]" {
    use_seams
    # the process of another unit: our binary on our configuration, but not in our PID file
    decoy_spawn alien "$MEDIAMTX_BINARY" "$CFG"
    run_mgr eval 'COMMAND=start; trap cleanup EXIT; start_mediamtx'
    [ "$status" -eq 8 ]
    [[ "$output" == *"Refusing to start: MediaMTX (PID $(decoy_pid alien)) is already running on $CFG but was not started by this script"* ]]
    assert_alive alien
    [ -z "$(decoy_signals)" ]
    [ ! -e "$MEDIAMTX_PID_FILE" ]
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]
}

@test "the refusal names the unit that runs the other MediaMTX when systemd says it is active [LB-02]" {
    decoy_spawn alien "$MEDIAMTX_BINARY" "$CFG"
    # a unit this script knows nothing about, found through the process's cgroup
    run_mgr eval '
        proc_systemd_unit() { printf "audio-bridge.service"; }
        foreign_mediamtx_owner; echo " rc=$?"'
    [[ "$output" == *"MediaMTX (PID $(decoy_pid alien)) is already running"* ]]
    decoy_unit_active audio-bridge
    run_mgr eval '
        proc_systemd_unit() { printf "audio-bridge.service"; }
        foreign_mediamtx_owner; echo " rc=$?"'
    [[ "$output" == *"unit audio-bridge.service is active and runs MediaMTX (PID $(decoy_pid alien))"* ]]
    [[ "$output" == *"rc=0" ]]
}

@test "restart is refused with exit 8 before anything is stopped or marked while mediamtx.service owns MediaMTX [LB-02]" {
    use_seams
    decoy_unit_active mediamtx
    our_mediamtx_up
    our_wrapper_up mic1
    run_mgr eval 'COMMAND=restart; trap cleanup EXIT; restart_mediamtx'
    [ "$status" -eq 8 ]
    [[ "$output" == *"Refusing to restart: mediamtx.service is active"* ]]
    assert_alive mtx w_mic1
    [ -z "$(decoy_signals)" ]
    [ ! -e "$MEDIAMTX_RESTART_MARKER" ]
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]
}

# ---------------------------------------------------------------------------
# Refused restart: no marker (found by the lock work)
# ---------------------------------------------------------------------------

@test "a restart refused by the lock leaves no restart marker and stops nothing [new defect]" {
    use_seams
    our_mediamtx_up
    our_wrapper_up mic1
    # another lifecycle command holds the lock until the test ends
    bash -c 'exec 8<>"$MEDIAMTX_LOCK_FILE"; flock -x 8; : >"$OW/holder.ready"; exec sleep 60' 3>&- &
    EXTRA_PIDS+=("$!")
    wait_until '[[ -e "$OW/holder.ready" ]]'
    LOCK_ACQUISITION_TIMEOUT=1 run_mgr eval 'COMMAND=restart; trap cleanup EXIT; restart_mediamtx'
    [ "$status" -eq 5 ]
    [[ "$output" == *"Refusing to restart: another lifecycle command holds the lock"* ]]
    # The old code marked the restart before it asked for the lock, so the next
    # start treated the node as being in a restart for 60 seconds
    [ ! -e "$MEDIAMTX_RESTART_MARKER" ]
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]
    assert_alive mtx w_mic1
    [ -z "$(decoy_signals)" ]
}

# ---------------------------------------------------------------------------
# LB-01: an idempotent start
# ---------------------------------------------------------------------------

@test "a repeated start on a healthy node changes nothing: same PIDs, no signal, no cleanup, no wait, no restart marker [LB-01]" {
    use_seams
    our_mediamtx_up
    our_wrapper_up mic1
    our_wrapper_up mic2
    other_installation_up
    local before_mtx before_w1 before_w2 cfg_before
    before_mtx="$(decoy_pid mtx):$(decoy_starttime "$(decoy_pid mtx)")"
    before_w1="$(decoy_pid w_mic1):$(decoy_starttime "$(decoy_pid w_mic1)")"
    before_w2="$(decoy_pid w_mic2):$(decoy_starttime "$(decoy_pid w_mic2)")"
    cfg_before="$(cksum <"$CFG")"
    DEVICES="mic1:31 mic2:32"
    local round
    for round in 1 2 3; do
        run_mgr eval 'COMMAND=start; trap cleanup EXIT; start_mediamtx'
        [ "$status" -eq 0 ] || {
            echo "round $round: $output"
            return 1
        }
        [[ "$output" == *"MediaMTX is already running (PID: $(decoy_pid mtx)) and owned by this manager"* ]]
        [ "$(decoy_pid mtx):$(decoy_starttime "$(decoy_pid mtx)")" = "$before_mtx" ]
        [ "$(decoy_pid w_mic1):$(decoy_starttime "$(decoy_pid w_mic1)")" = "$before_w1" ]
        [ "$(decoy_pid w_mic2):$(decoy_starttime "$(decoy_pid w_mic2)")" = "$before_w2" ]
    done
    assert_alive mtx w_mic1 w_mic2 X_mtx X_wrapper X_reader
    # no signal at all, not even to our own processes
    [ -z "$(decoy_signals)" ]
    # the old code went through cleanup_stale_processes and a USB wait every time
    [ ! -s "$SEAM_LOG" ]
    [ ! -e "$MEDIAMTX_RESTART_MARKER" ]
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]
    # the configuration was not regenerated either
    [ "$(cksum <"$CFG")" = "$cfg_before" ]
    [ -f "$MEDIAMTX_PID_FILE" ]
    [ -f "$FF/mic1.pid" ]
}

@test "a leftover cleanup marker does not make start tear down a MediaMTX this manager owns [LB-01]" {
    use_seams
    our_mediamtx_up
    our_wrapper_up mic1
    # an earlier command exited abnormally and left the marker
    : >"$MEDIAMTX_CLEANUP_MARKER"
    run_mgr eval 'COMMAND=start; trap cleanup EXIT; start_mediamtx'
    [ "$status" -eq 0 ]
    [[ "$output" == *"MediaMTX is running and owned by this manager; keeping it"* ]]
    assert_alive mtx w_mic1
    [ -z "$(decoy_signals)" ]
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]
}

@test "start on a healthy node starts a missing stream and leaves the running one alone; a dead wrapper is reconciled by the next start [LB-01]" {
    use_seams
    use_wrapper_stand_ins
    export STREAM_MODE=multiplex
    DEVICES="mic1:31"
    our_mediamtx_up
    local mtx_before
    mtx_before="$(decoy_pid mtx):$(decoy_starttime "$(decoy_pid mtx)")"

    # No wrapper yet: the first start launches it
    run_mgr eval 'COMMAND=start; trap cleanup EXIT; start_mediamtx'
    [ "$status" -eq 0 ]
    [ -f "$FF/all_mics.pid" ]
    local w1
    w1="$(<"$FF/all_mics.pid")"
    EXTRA_PIDS+=("$w1")
    [ -d "/proc/$w1" ]
    [ "$(decoy_pid mtx):$(decoy_starttime "$(decoy_pid mtx)")" = "$mtx_before" ]

    # A second start leaves that wrapper (and its FFmpeg) alone
    run_mgr eval 'COMMAND=start; trap cleanup EXIT; start_mediamtx'
    [ "$status" -eq 0 ]
    [ "$(<"$FF/all_mics.pid")" = "$w1" ]

    # The wrapper dies (killed from outside, its FFmpeg with it): the next start
    # brings the stream back and still leaves MediaMTX alone
    local ff_child
    ff_child="$(ps -o pid= --ppid "$w1" | head -n1 | tr -d ' ')"
    EXTRA_PIDS+=("$ff_child")
    builtin kill -KILL "$w1"
    [ -z "$ff_child" ] || builtin kill -KILL "$ff_child"
    wait_gone "$w1"
    run_mgr eval 'COMMAND=start; trap cleanup EXIT; start_mediamtx'
    [ "$status" -eq 0 ]
    local w2
    w2="$(<"$FF/all_mics.pid")"
    EXTRA_PIDS+=("$w2")
    [ "$w2" != "$w1" ]
    [ -d "/proc/$w2" ]
    [ "$(decoy_pid mtx):$(decoy_starttime "$(decoy_pid mtx)")" = "$mtx_before" ]
    assert_alive mtx
    # the manager signalled nothing (the kills above are the test's own)
    [ -z "$(decoy_signals)" ]
}

@test "when the recorded MediaMTX is dead, start cleans up what is stale and launches a new one [LB-01]" {
    use_seams
    use_mediamtx_launch_stub
    our_mediamtx_up
    our_wrapper_up mic1
    other_installation_up
    local old_mtx
    old_mtx="$(decoy_pid mtx)"
    # MediaMTX dies; its wrapper is still up (publishing to nothing)
    builtin kill -KILL "$old_mtx"
    wait_gone "$old_mtx"
    run_mgr eval 'COMMAND=start; trap cleanup EXIT; start_mediamtx'
    [ "$status" -eq 0 ]
    local new_mtx
    new_mtx="$(<"$MEDIAMTX_PID_FILE")"
    EXTRA_PIDS+=("$new_mtx")
    [ "$new_mtx" != "$old_mtx" ]
    [ -d "/proc/$new_mtx" ]
    # the stale generation's wrapper was stopped, by identity, and nothing else was
    assert_dead w_mic1
    assert_alive X_mtx X_wrapper X_reader
    assert_signals_only_to w_mic1
    # the new process is recorded with its start time
    [ "$(<"$MEDIAMTX_PID_FILE.id")" = "$new_mtx $(decoy_starttime "$new_mtx")" ]
    # and the USB settling wait ran, as for any fresh start
    grep -q '^stabilize' "$SEAM_LOG"
}

@test "a recorded PID that now belongs to an unrelated process is not signalled: the stale record is dropped and MediaMTX is started [LB-01, X-26]" {
    use_seams
    use_mediamtx_launch_stub
    # The PID file names a process that is alive but is not the MediaMTX that
    # was recorded (its start time differs)
    decoy_hold_script "$OW/other/mediamtx.yml"
    decoy_bash_copy "$OW/other/bin/exporter"
    decoy_spawn recycled "$OW/other/bin/exporter" "$OW/other/mediamtx.yml"
    echo "$(decoy_pid recycled)" >"$MEDIAMTX_PID_FILE"
    echo "$(decoy_pid recycled) $(($(decoy_starttime "$(decoy_pid recycled)") - 100))" >"$MEDIAMTX_PID_FILE.id"
    run_mgr eval 'COMMAND=start; trap cleanup EXIT; start_mediamtx'
    [ "$status" -eq 0 ]
    local new_mtx
    new_mtx="$(<"$MEDIAMTX_PID_FILE")"
    EXTRA_PIDS+=("$new_mtx")
    [ "$new_mtx" != "$(decoy_pid recycled)" ]
    assert_alive recycled
    [ -z "$(decoy_signals)" ]
}

@test "MediaMTX is recorded in the PID file, with its start time, before the readiness wait begins [D1]" {
    use_seams
    use_mediamtx_launch_stub
    # The readiness probe (curl) notes whether the PID file already exists
    cat >"$OW/shim/curl" <<'CURL_EOF'
#!/bin/bash
if [[ -f "$MEDIAMTX_PID_FILE" && -f "$MEDIAMTX_PID_FILE.id" ]]; then
    echo "recorded $(cat "$MEDIAMTX_PID_FILE")" >>"$OW/probe.log"
else
    echo "not recorded" >>"$OW/probe.log"
fi
# ...and then answer like a healthy API
exec "$PROJECT_ROOT/tests/helpers/mediamtx/curl_shim" "$@"
CURL_EOF
    run_mgr eval 'COMMAND=start; trap cleanup EXIT; start_mediamtx'
    [ "$status" -eq 0 ]
    EXTRA_PIDS+=("$(<"$MEDIAMTX_PID_FILE")")
    # A start interrupted during the wait would otherwise leave a running
    # MediaMTX that no PID file names, which the manager could not take over
    [ "$(head -n1 "$OW/probe.log")" = "recorded $(<"$MEDIAMTX_PID_FILE")" ]
}


@test "a MediaMTX that never becomes ready is stopped and its PID file removed [D1]" {
    use_seams
    use_mediamtx_launch_stub
    printf '#!/bin/bash\nexit 7\n' >"$OW/shim/curl"
    # (the manager signals the process it launched itself, which is not a decoy)
    MEDIAMTX_API_TIMEOUT=2 run_mgr_real eval 'COMMAND=start; trap cleanup EXIT; start_mediamtx'
    [ "$status" -eq 1 ]
    [[ "$output" == *"MediaMTX failed to become ready"* ]]
    [ ! -e "$MEDIAMTX_PID_FILE" ]
    [ ! -e "$MEDIAMTX_PID_FILE.id" ]
    # the process it launched is gone: nothing runs the configured binary any more
    run_mgr_real eval 'for p in /proc/[0-9]*; do is_managed_mediamtx_pid "${p#/proc/}" && echo "left ${p#/proc/}"; done; echo scanned'
    [[ "$output" == "scanned" ]]
}


# ---------------------------------------------------------------------------
# X-25: FFmpeg logs are rotated, not deleted
# ---------------------------------------------------------------------------

@test "help documents FFMPEG_LOG_KEEP and that no command deletes the logs [X-25]" {
    run_mgr show_help
    [[ "$output" == *"FFMPEG_LOG_KEEP"* ]]
    [[ "$output" == *"never delete them"* ]]
}

@test "rotate_ffmpeg_log keeps the logs of the last FFMPEG_LOG_KEEP runs and removes older ones [X-25]" {
    FFMPEG_LOG_KEEP=3 run_mgr eval '
        for run in 1 2 3 4 5 6; do
            rotate_ffmpeg_log "$FFMPEG_PID_DIR/mic1.log"
            echo "run $run" >"$FFMPEG_PID_DIR/mic1.log"
        done'
    [ "$status" -eq 0 ]
    [ "$(<"$FF/mic1.log")" = "run 6" ]
    [ "$(<"$FF/mic1.log.prev.1")" = "run 5" ]
    [ "$(<"$FF/mic1.log.prev.2")" = "run 4" ]
    [ "$(<"$FF/mic1.log.prev.3")" = "run 3" ]
    [ ! -e "$FF/mic1.log.prev.4" ]
    # the bound holds: the live log and 3 archives
    [ "$(find "$FF" -name 'mic1.log*' | wc -l)" -eq 4 ]
}

@test "rotate_ffmpeg_log removes archives beyond a lowered limit, skips an empty log and discards the old run at limit 0 [X-25]" {
    printf 'a\n' >"$FF/s.log.prev.1"
    printf 'b\n' >"$FF/s.log.prev.2"
    printf 'c\n' >"$FF/s.log.prev.5"
    : >"$FF/s.log"
    FFMPEG_LOG_KEEP=2 run_mgr rotate_ffmpeg_log "$FF/s.log"
    [ "$status" -eq 0 ]
    [ -e "$FF/s.log.prev.2" ]
    [ ! -e "$FF/s.log.prev.5" ]
    # an empty live log is not worth an archive slot
    [ "$(<"$FF/s.log.prev.1")" = "a" ]
    printf 'now\n' >"$FF/s.log"
    FFMPEG_LOG_KEEP=0 run_mgr rotate_ffmpeg_log "$FF/s.log"
    [ ! -e "$FF/s.log" ]
    [ ! -e "$FF/s.log.prev.1" ]
}

@test "FFMPEG_LOG_KEEP falls back to 3 when it is not a number and is capped at 20 [X-25]" {
    FFMPEG_LOG_KEEP=lots run_mgr eval 'echo "keep=$FFMPEG_LOG_KEEP"'
    [[ "$output" == *"keep=3"* ]]
    FFMPEG_LOG_KEEP=500 run_mgr eval 'echo "keep=$FFMPEG_LOG_KEEP"'
    [[ "$output" == *"keep=20"* ]]
    run_mgr eval 'echo "keep=$FFMPEG_LOG_KEEP"'
    [[ "$output" == *"keep=3"* ]]
}

# The processes are stopped, the post-mortem stays
assert_logs_survive() {
    [ "$(<"$FF/mic1.log")" = "why mic1 died" ]
    [ "$(<"$FF/mic1.log.prev.1")" = "older" ]
    [ "$(<"$FF/mic1.log.old")" = "rotated by the wrapper" ]
}

make_logs() {
    printf 'why mic1 died\n' >"$FF/mic1.log"
    printf 'older\n' >"$FF/mic1.log.prev.1"
    printf 'rotated by the wrapper\n' >"$FF/mic1.log.old"
}

@test "cleanup_stale_processes keeps the FFmpeg logs of the run it cleans up [X-25]" {
    our_mediamtx_up
    our_wrapper_up mic1
    make_logs
    run_mgr cleanup_stale_processes
    [ "$status" -eq 0 ]
    assert_dead mtx w_mic1
    assert_logs_survive
}

@test "stop_mediamtx keeps the FFmpeg logs of the run it stops [X-25]" {
    our_mediamtx_up
    our_wrapper_up mic1
    make_logs
    run_mgr stop_mediamtx
    [ "$status" -eq 0 ]
    assert_dead mtx w_mic1
    assert_logs_survive
}

@test "force_stop_mediamtx keeps the FFmpeg logs [X-25]" {
    our_mediamtx_up
    our_wrapper_up mic1
    make_logs
    run_mgr force_stop_mediamtx
    [ "$status" -eq 0 ]
    assert_dead mtx w_mic1
    assert_logs_survive
}

@test "starting a stream rotates the log of its previous run instead of deleting it [X-25]" {
    use_seams
    use_wrapper_stand_ins
    export STREAM_MODE=multiplex
    printf 'previous run\n' >"$FF/all_mics.log"
    run_mgr start_ffmpeg_multiplex_stream mic1:31
    [ "$status" -eq 0 ]
    EXTRA_PIDS+=("$(<"$FF/all_mics.pid")")
    [ "$(<"$FF/all_mics.log.prev.1")" = "previous run" ]
    # the new run writes a fresh log
    ! grep -q 'previous run' "$FF/all_mics.log" || false
}

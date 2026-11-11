# shellcheck shell=bash
# Decoy processes and PATH shims for tests of code that stops or detects
# processes (LB-10 / D11).
#
# The code under test must act on the process it manages and on nothing else.
# To prove that, a test starts real look-alike processes ("decoys") and runs
# the real function; afterwards it checks which decoys survived and which
# signals were sent. A decoy is a copy of the bash binary placed at a chosen
# path and run on a script that only waits, so its /proc/<pid>/exe, its
# argv and its name (comm) are whatever the test chooses. It needs no compiler.
#
# Safety: nothing here can signal a process that is not a decoy.
#   - `kill` is wrapped by a function that refuses any PID that is not a decoy.
#   - the pkill/pgrep shims run the real pgrep with the caller's arguments and
#     act only on matches that are decoys, so a name- or pattern-based call in
#     the code under test hits decoys (which proves the defect) and never a
#     real process on the host.
#   - systemctl is a shim that records the call and keeps state in files.
#
# Usage: call decoy_setup in a test (or its setup) and decoy_teardown in
# teardown. Needs scratch_setup (tests/scratch_tmpdir.bash) not to be required.

# Create the work directory, the shims and the signal log; put the shims first
# on PATH and install the guarded `kill`.
decoy_setup() {
    DECOY_DIR="$(mktemp -d)"
    DECOY_REGISTRY="$DECOY_DIR/registry"
    SIGNAL_LOG="$DECOY_DIR/signals.log"
    SYSTEMCTL_LOG="$DECOY_DIR/systemctl.log"
    SHIM_STATE="$DECOY_DIR/shim-state"
    SHIM_DIR="$DECOY_DIR/shims"
    mkdir -p "$SHIM_STATE" "$SHIM_DIR"
    : >"$DECOY_REGISTRY"
    : >"$SIGNAL_LOG"
    : >"$SYSTEMCTL_LOG"
    mkfifo "$DECOY_DIR/hold"
    DECOY_REAL_PGREP="$(command -v pgrep)"
    export DECOY_DIR DECOY_REGISTRY SIGNAL_LOG SYSTEMCTL_LOG SHIM_STATE DECOY_REAL_PGREP

    cat >"$SHIM_DIR/systemctl" <<'EOF'
#!/bin/bash
# Records every call. State lives in $SHIM_STATE: active.<unit> = unit is
# active; fail.stop / fail.start = that action fails without changing state.
echo "systemctl $*" >>"$SYSTEMCTL_LOG"
action="${1:-}"
unit="${*: -1}"
unit="${unit%.service}"
case "$action" in
    is-active)
        [[ -e "$SHIM_STATE/active.$unit" ]] || exit 1
        ;;
    stop)
        [[ ! -e "$SHIM_STATE/fail.stop" ]] || exit 1
        rm -f "$SHIM_STATE/active.$unit"
        ;;
    start)
        [[ ! -e "$SHIM_STATE/fail.start" ]] || exit 1
        : >"$SHIM_STATE/active.$unit"
        ;;
    *) ;;
esac
exit 0
EOF

    # pkill / pgrep: real matching semantics, restricted to decoys.
    cat >"$SHIM_DIR/pgrep" <<'EOF'
#!/bin/bash
echo "pgrep $*" >>"$SIGNAL_LOG"
found=1
while read -r pid; do
    if awk '{print $2}' "$DECOY_REGISTRY" | grep -qx "$pid"; then
        echo "$pid"
        found=0
    fi
done < <("$DECOY_REAL_PGREP" "$@" 2>/dev/null)
exit "$found"
EOF
    cat >"$SHIM_DIR/pkill" <<'EOF'
#!/bin/bash
echo "pkill $*" >>"$SIGNAL_LOG"
sig=TERM
args=()
for a in "$@"; do
    case "$a" in
        -[0-9]*) sig="${a#-}" ;;
        -TERM | -KILL | -HUP | -INT | -USR1 | -USR2) sig="${a#-}" ;;
        *) args+=("$a") ;;
    esac
done
hit=1
while read -r pid; do
    if awk '{print $2}' "$DECOY_REGISTRY" | grep -qx "$pid"; then
        builtin kill "-$sig" "$pid" 2>/dev/null && hit=0
    fi
done < <("$DECOY_REAL_PGREP" "${args[@]}" 2>/dev/null)
exit "$hit"
EOF
    chmod +x "$SHIM_DIR/systemctl" "$SHIM_DIR/pgrep" "$SHIM_DIR/pkill"
    PATH="$SHIM_DIR:$PATH"

    # Guarded kill: log every call, refuse anything that is not a decoy.
    # shellcheck disable=SC2329  # shadows the kill builtin for the code under test
    kill() {
        local arg pid=""
        for arg in "$@"; do
            case "$arg" in
                -*) ;;
                *) pid="$arg" ;;
            esac
        done
        echo "kill $*" >>"$SIGNAL_LOG"
        if [[ -n "$pid" ]] && ! decoy_registered "$pid"; then
            echo "REFUSED kill $*" >>"$SIGNAL_LOG"
            return 1
        fi
        builtin kill "$@"
    }
}

# Kill what is left of the decoys and remove the work directory. A PID is
# signalled only if its start time is the one recorded when the decoy was
# started, so a recycled PID is never touched.
decoy_teardown() {
    [[ -n "${DECOY_DIR:-}" && -d "$DECOY_DIR" ]] || return 0
    unset -f kill
    local label pid start
    while read -r label pid start; do
        [[ -n "$pid" && -n "$start" ]] || continue
        if [[ "$(decoy_starttime "$pid")" == "$start" ]]; then
            builtin kill -KILL "$pid" 2>/dev/null || true
        fi
    done <"$DECOY_REGISTRY"
    chmod -R u+rwx -- "$DECOY_DIR" 2>/dev/null || true
    rm -rf -- "$DECOY_DIR"
    DECOY_DIR=""
}

# decoy_starttime PID: field 22 of /proc/PID/stat, empty if the process is gone
decoy_starttime() {
    local line rest
    local -a fields
    line="$(cat "/proc/$1/stat" 2>/dev/null || true)"
    rest="${line##*) }"
    read -r -a fields <<<"$rest"
    echo "${fields[19]:-}"
}

decoy_registered() {
    awk '{print $2}' "$DECOY_REGISTRY" | grep -qx "$1"
}

# decoy_bash_copy PATH: a copy of the bash binary at PATH (parent dirs created)
decoy_bash_copy() {
    mkdir -p "$(dirname "$1")"
    cp "$(command -v bash)" "$1"
}

# decoy_hold_script PATH [ignore_term]: a script that just waits (up to 5
# minutes, so a leaked decoy expires on its own). With ignore_term it ignores
# SIGTERM, so only SIGKILL stops it.
decoy_hold_script() {
    mkdir -p "$(dirname "$1")"
    {
        if [[ "${2:-}" == "ignore_term" ]]; then
            echo "trap '' TERM"
        fi
        printf 'exec 9<>%q\n' "$DECOY_DIR/hold"
        echo 'read -r -t 300 -u 9 || true'
    } >"$1"
}

# decoy_spawn LABEL EXE [ARG...]: run EXE ARG... in the background as decoy
# LABEL and wait until /proc shows the final image (before exec the child
# still looks like the test shell).
decoy_spawn() {
    local label="$1" exe="$2" want pid i
    shift 2
    "$exe" "$@" </dev/null >/dev/null 2>&1 3>&- &
    pid=$!
    # Not tracked as a job: no "Killed" notices when a decoy is stopped.
    disown "$pid" 2>/dev/null || true
    # Registered at once (with the start time, which does not change on exec)
    # so teardown cleans up even if the wait below fails.
    echo "$label $pid $(decoy_starttime "$pid")" >>"$DECOY_REGISTRY"
    want="$(readlink -f "$exe")"
    for ((i = 0; i < 200; i++)); do
        if [[ "$(readlink "/proc/$pid/exe" 2>/dev/null || true)" == "$want" ]]; then
            return 0
        fi
        sleep 0.05
    done
    echo "decoy $label never reached its final image" >&2
    return 1
}

# decoy_pid LABEL
decoy_pid() {
    awk -v l="$1" '$1 == l {print $2}' "$DECOY_REGISTRY"
}

# decoy_alive LABEL: running and not a zombie
decoy_alive() {
    local pid line state
    pid="$(decoy_pid "$1")"
    if [[ -z "$pid" || ! -e "/proc/$pid/stat" ]]; then
        return 1
    fi
    line="$(cat "/proc/$pid/stat" 2>/dev/null || true)"
    state="${line##*) }"
    state="${state:0:1}"
    if [[ -z "$state" || "$state" == "Z" || "$state" == "X" ]]; then
        return 1
    fi
    return 0
}

# decoy_dead LABEL: the decoy is gone (or a zombie). Used instead of
# `! decoy_alive`, because a negated function call confuses bats' ERR trap.
decoy_dead() {
    if decoy_alive "$1"; then
        return 1
    fi
    return 0
}

# decoy_signals: the signals sent so far (calls with signal 0 and shim calls
# that only look are left out): "kill -TERM 123", "pkill -f x", ...
decoy_signals() {
    grep -vE '^(kill -0 |pgrep )' "$SIGNAL_LOG" || true
}

# decoy_unit_active UNIT / decoy_fail ACTION: drive the systemctl shim
decoy_unit_active() {
    : >"$SHIM_STATE/active.$1"
}
decoy_fail() {
    : >"$SHIM_STATE/fail.$1"
}

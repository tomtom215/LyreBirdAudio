# shellcheck shell=bash
# Drives the REAL orchestrator (lyrebird-orchestrator.sh, sourced, every test
# command is one of its own functions) against stand-ins for the scripts it
# delegates to, on a pseudo-terminal.
#
# Why a terminal: the orchestrator gives every delegated script `</dev/tty` and
# reads its menus from the terminal, so none of that runs without a controlling
# terminal (a CI runner has none). tests/helpers/pty_run.py provides one and
# answers each prompt when it appears.
#
# What is real: the orchestrator, execute_script and everything that reads a
# delegated script's outcome. What stands in for what a unit test cannot run:
# the six delegated scripts (installer, stream manager, USB mapper, mic check,
# updater, diagnostics), each a few lines that record the call and exit with the
# status the test chose, and -- for the stream manager -- write the status
# document the test chose, as the real one does (tests/test_orchestrator_manager_contract.bats
# feeds the orchestrator a document the REAL manager wrote).
#
# Usage: load scratch_tmpdir, then orchestrator_helper; in setup() call
# scratch_setup then orch_setup; in teardown() scratch_teardown.
#
# The stand-ins are steered by environment variables:
#   STUB_RC_<key>_<first argument>   exit status, e.g. STUB_RC_stream_manager_start=9,
#                                    STUB_RC_updater___rollback=6 (non-letters become _),
#                                    STUB_RC_stream_manager_status_json for `status --json`
#   STUB_RC_default                  exit status of everything else (default 0)
#   STUB_DOC_start / STUB_DOC_restart / STUB_DOC_status_json
#                                    a status document the manager writes into
#                                    $LYREBIRD_STATUS_FILE for start / restart, or prints for
#                                    `status --json` (unset: nothing is written / printed)
#   STUB_PGREP_MEDIAMTX=1, STUB_PGREP_FFMPEG=N
#                                    the pgrep stand-in sees MediaMTX / N FFmpeg processes;
#                                    with STUB_PGREP_ONLY_AFTER_START=1 only once a stream
#                                    manager `start` has been run (the state changes under
#                                    the orchestrator, as it does on a real node)

ORCH_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_ROOT="$(cd "$ORCH_HELPER_DIR/.." && pwd)"
ORCH_KEYS=(installer stream_manager usb_mapper mic_check updater diagnostics)

orch_setup() {
    ORCH_DIR="$TEST_SCRATCH/orch"
    ORCH_STUBS="$ORCH_DIR/stubs"
    ORCH_CALLS="$ORCH_DIR/calls.log"
    mkdir -p "$ORCH_STUBS" "$ORCH_DIR/bin"
    : >"$ORCH_CALLS"
    export ORCH_DIR ORCH_STUBS ORCH_CALLS
    export LYREBIRD_STATUS_FILE="$ORCH_DIR/status.json"
    unset LYREBIRD_UPDATER_STATE_DIR

    cat >"$ORCH_STUBS/engine.sh" <<'ENGINE_EOF'
#!/bin/bash
# stand-in for a delegated script: engine.sh KEY ARGS...
key="$1"
shift
printf '%s %s\n' "$key" "$*" >>"$ORCH_CALLS"
cmd="${1:-none}"
if [[ "$key" == stream_manager && "$cmd" == start ]]; then
    : >"$ORCH_DIR/started"
fi
if [[ "$cmd" == status && "${2:-}" == --json ]]; then
    cmd=status_json
fi
rc_var="STUB_RC_${key}_${cmd//[^A-Za-z0-9]/_}"
rc="${!rc_var:-${STUB_RC_default:-0}}"
if [[ "$key" == stream_manager ]]; then
    doc_var="STUB_DOC_${cmd}"
    if [[ -n "${!doc_var:-}" ]]; then
        if [[ "$cmd" == status_json ]]; then
            cat "${!doc_var}"
        else
            cp -- "${!doc_var}" "$LYREBIRD_STATUS_FILE"
        fi
    fi
fi
if [[ "$cmd" != status_json ]]; then
    echo "stub ${key} $*"
fi
exit "$rc"
ENGINE_EOF
    local key name
    for key in "${ORCH_KEYS[@]}"; do
        case "$key" in
            installer) name=install_mediamtx.sh ;;
            stream_manager) name=lyrebird-stream-manager.sh ;;
            usb_mapper) name=usb-audio-mapper.sh ;;
            mic_check) name=lyrebird-mic-check.sh ;;
            updater) name=lyrebird-updater.sh ;;
            diagnostics) name=lyrebird-diagnostics.sh ;;
        esac
        printf '#!/bin/bash\nexec /bin/bash "%s/engine.sh" %s "$@"\n' "$ORCH_STUBS" "$key" >"$ORCH_STUBS/$name"
        chmod +x "$ORCH_STUBS/$name"
    done

    # The host's processes must not decide a test: pgrep sees what the test says
    cat >"$ORCH_DIR/bin/pgrep" <<'PGREP_EOF'
#!/bin/bash
if [[ "$*" == *--help* ]]; then
    echo "usage: pgrep [-c] [-x] PATTERN"
    exit 0
fi
mtx="${STUB_PGREP_MEDIAMTX:-0}"
ff="${STUB_PGREP_FFMPEG:-0}"
if [[ -n "${STUB_PGREP_ONLY_AFTER_START:-}" && ! -e "$ORCH_DIR/started" ]]; then
    mtx=0
    ff=0
fi
case "$*" in
    *mediamtx*)
        [[ "$mtx" == 1 ]] && { echo 4242; exit 0; }
        exit 1
        ;;
    *ffmpeg*)
        n="$ff"
        if [[ "$*" == *-c* ]]; then
            echo "$n"
            ((n > 0)) && exit 0
            exit 1
        fi
        ((n > 0)) || exit 1
        for ((i = 0; i < n; i++)); do echo $((5000 + i)); done
        ;;
esac
PGREP_EOF
    chmod +x "$ORCH_DIR/bin/pgrep"
    export PATH="$ORCH_DIR/bin:$PATH"
}

# orch_doc FILE OVERALL MTX_RUNNING [PATH|READY|FLOWING|ERROR]...
# Write a status document in the manager's schema (version 1). READY and FLOWING
# are true, false or null; ERROR empty means null; the policy is $ORCH_DOC_POLICY
# (default degraded). Every document is unique (timestamp_epoch in nanoseconds),
# as no two real ones are.
orch_doc() {
    local file="$1" overall="$2" running="$3" streams="[]" spec path ready flowing err
    shift 3
    for spec in "$@"; do
        IFS='|' read -r path ready flowing err <<<"$spec"
        streams="$(jq -c --arg p "$path" --argjson r "$ready" --argjson f "$flowing" --arg e "${err:-}" \
            '. + [{device: ("usb-" + $p), card: "1", path: $p, configured: true,
                   process_alive: ($r == true), path_ready: $r, bytes_flowing: $f,
                   last_error: (if $e == "" then null else $e end)}]' <<<"$streams")"
    done
    jq -n --arg overall "$overall" --argjson running "$running" --argjson streams "$streams" \
        --argjson epoch "$(date +%s%N)" --arg policy "${ORCH_DOC_POLICY:-degraded}" \
        '{schema_version: 1, timestamp: "2026-11-12T10:00:00Z", timestamp_epoch: $epoch,
          command: "start", overall: $overall, policy: $policy, stream_mode: "individual",
          mediamtx: {running: $running, pid: (if $running then 4242 else null end)},
          streams: $streams}' >"$file"
}

# orch_run [--step REGEX TEXT]... BODY
# Run BODY (bash) in a shell that has sourced the real orchestrator, the six
# delegated scripts pointed at the stand-ins, on a pseudo-terminal; each --step
# answers a prompt when it appears. Sets $status and $output (colours removed).
orch_run() {
    local -a steps=()
    while [[ "${1:-}" == --step ]]; do
        steps+=(--step "$2" "$3")
        shift 3
    done
    {
        printf 'source %q\n' "${ORCH_SOURCE:-$ORCH_ROOT/lyrebird-orchestrator.sh}"
        printf 'clear() { :; }\n'
        printf 'LOG_FILE=%q\n' "$ORCH_DIR/orchestrator.log"
        local key name
        for key in "${ORCH_KEYS[@]}"; do
            case "$key" in
                installer) name=install_mediamtx.sh ;;
                stream_manager) name=lyrebird-stream-manager.sh ;;
                usb_mapper) name=usb-audio-mapper.sh ;;
                mic_check) name=lyrebird-mic-check.sh ;;
                updater) name=lyrebird-updater.sh ;;
                diagnostics) name=lyrebird-diagnostics.sh ;;
            esac
            printf 'SCRIPT_PATHS[%s]=%q\n' "$key" "$ORCH_STUBS/$name"
        done
        printf '%s\n' "$1"
    } >"$ORCH_DIR/harness.sh"
    run python3 -I "$ORCH_ROOT/tests/helpers/pty_run.py" --timeout 90 "${steps[@]}" -- /bin/bash "$ORCH_DIR/harness.sh"
}

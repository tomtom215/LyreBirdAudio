#!/usr/bin/env bats
# DOC-02: README.md claims that were wrong and are pinned here so they cannot come back.
#
# Each test reads README.md and checks what it says against the real scripts,
# their --help output or the shipped unit files, so a script change that makes the
# README false fails here, and a README edit that brings back a claim the code
# does not support fails here too. The evidence for each claim is in the test.
#
# README_FILE=<path> points the tests at another copy of the README (used to show
# that every test fails on the README as it was before the correction, e.g.
# `git show <old commit>:README.md > /tmp/old.md; README_FILE=/tmp/old.md bats ...`).

load scratch_tmpdir

setup() {
    scratch_setup
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    README="${README_FILE:-$ROOT/README.md}"
    MANAGER="$ROOT/lyrebird-stream-manager.sh"
    [ -f "$README" ]
}

teardown() {
    scratch_teardown
}

# Lines inside fenced code blocks
_code_lines() {
    awk '/^```/ { f = !f; next } f' "$README"
}

# The lines of a section: after the line equal to $1, up to (not including) the next
# line that matches the regular expression $2
_section() {
    awk -v start="$1" -v stop="$2" '$0 == start { f = 1; next } f && $0 ~ stop { exit } f' "$README"
}

# The version a script declares (the table in the README is generated the same way)
_version() {
    grep -m1 -E '^(readonly )?(SCRIPT_|LYREBIRD_COMMON_)?VERSION=' "$ROOT/$1" | sed -E 's/.*VERSION="?([^"]*)"?.*/\1/'
}

# The default of an environment variable in a script: read from the first line that
# reads it, in one of the forms the scripts use:
#   NAME=$(_uint_or "${NAME:-}" N)   NAME=$(_int_or "${NAME:-}" N)
#   NAME="$(_mediamtx_port_env NAME N)"   "${NAME:-word}"   "${NAME-word}"
_default_in() {
    local script="$1" name="$2" line
    line="$(grep -m1 -F -e "\${${name}:-" -e "\${${name}-" -e "_mediamtx_port_env ${name} " "$script")" || return 1
    if [[ "$line" =~ _(uint|int)_or\ \"\$\{${name}:-\}\"\ (-?[0-9]+) ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
    elif [[ "$line" =~ _mediamtx_port_env\ ${name}\ ([0-9]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$line" =~ \$\{${name}:-([^}]*)\} ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    elif [[ "$line" =~ \$\{${name}-([^}]*)\} ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

@test "README does not tell the reader to kill processes by name, and offers the identity-based force-stop [DOC-02]" {
    # `pkill -9 mediamtx; pkill -9 ffmpeg` stops every MediaMTX and every FFmpeg on the host
    run grep -nE '(pkill|killall)[[:space:]]+(-[A-Za-z0-9]+[[:space:]]+)*(-f[[:space:]]+)?["'"'"']?\^?(mediamtx|ffmpeg)' "$README"
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    grep -qF 'force-stop --kill-all' "$README"
    run bash "$MANAGER" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"force-stop --kill-all [--yes]"* ]]
    [[ "$output" == *"signals nothing"* ]]
}

@test "README checks a MediaMTX configuration with --validate-conf and never with --check [DOC-02]" {
    # MediaMTX has no --check flag (1.21.3 prints its usage and exits 80); --validate-conf=FILE exists from 1.21.1
    run grep -nE 'mediamtx[^[:space:]]*[[:space:]]+--check([[:space:]]|$)' "$README"
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    grep -qE 'mediamtx --validate-conf=' "$README"
    grep -qF 'validate-conf' "$MANAGER"
    grep -qF '1.21.1' "$README"
}

@test "README does not claim built-in upgrade support, and its installer options are in the installer's help [DOC-02]" {
    run grep -niE 'built-in upgrade|upgrade support' "$README"
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    grep -qF "MediaMTX's own \`--upgrade\` is not used" "$README"
    run bash "$ROOT/install_mediamtx.sh" --help
    [ "$status" -eq 0 ]
    local help="$output" line tok n=0
    [[ "$help" == *"MediaMTX's own --upgrade is not"* ]]
    while IFS= read -r line; do
        for tok in $line; do
            case "$tok" in
                -[A-Za-z] | --[a-z]*)
                    [[ "$help" == *"$tok"* ]] || { echo "README uses $tok, which install_mediamtx.sh --help does not list"; false; }
                    n=$((n + 1))
                    ;;
            esac
        done
    done < <(_code_lines | grep -E 'install_mediamtx\.sh')
    [ "$n" -ge 3 ]
}

@test "README says the standalone unit has no ExecReload and the stream manager unit has a real reload [DOC-02]" {
    # systemctl reload mediamtx: MediaMTX ignores USR1 and ends on HUP, so the unit has none
    run grep -E '^ExecReload=' "$ROOT/config/mediamtx.service"
    [ "$status" -eq 1 ]
    grep -qE '^ExecReload=.* reload$' "$ROOT/config/mediamtx-audio.service"
    run bash "$MANAGER" --help
    [[ "$output" == *"reload      Re-render the MediaMTX configuration"* ]]
    grep -qF 'the new unit has no `ExecReload=`' "$README"
    grep -qF 'systemctl reload mediamtx-audio' "$README"
}

@test "every lyrebird-storage.sh command line in README is accepted by the script [DOC-02]" {
    export LYREBIRD_STORAGE_CONFIG="" MEDIAMTX_LOG="$TEST_SCRATCH/mediamtx.out"
    export LYREBIRD_RECORDING_DIR="$TEST_SCRATCH/rec" LYREBIRD_LOG_DIR="$TEST_SCRATCH/log" \
        LYREBIRD_TEMP_DIR="$TEST_SCRATCH/tmp" LYREBIRD_BUFFER_DIR="$TEST_SCRATCH/buf"
    mkdir -p "$LYREBIRD_RECORDING_DIR" "$LYREBIRD_LOG_DIR" "$LYREBIRD_TEMP_DIR" "$LYREBIRD_BUFFER_DIR"
    local line args n=0
    local -a argv
    while IFS= read -r line; do
        args="${line#*lyrebird-storage.sh}"
        args="${args%%>*}"
        args="${args%%#*}"
        read -ra argv <<<"$args"
        # --dry-run in front: nothing is deleted, whatever the line says
        run bash "$ROOT/lyrebird-storage.sh" --dry-run "${argv[@]}"
        [ "$status" -eq 0 ] || { echo "README line: $line"; echo "status $status: $output"; false; }
        n=$((n + 1))
    done < <(_code_lines | grep -E 'lyrebird-storage\.sh[[:space:]]')
    [ "$n" -ge 6 ]
    # the documented cron lines are among them
    grep -qE 'lyrebird-storage\.sh cleanup --quiet' "$README"
    grep -qE 'lyrebird-storage\.sh monitor --once' "$README"
    run grep -nE 'monitor --interval' "$README"
    [ "$status" -eq 1 ]
}

@test "every lyrebird-metrics.sh option in README is in the script's help, and its metric names are the script's [DOC-02]" {
    run bash "$ROOT/lyrebird-metrics.sh" --help
    [ "$status" -eq 0 ]
    local help="$output" line tok n=0
    while IFS= read -r line; do
        for tok in $line; do
            case "$tok" in
                serve | -[A-Za-z] | --[a-z]*)
                    [[ "$help" == *"$tok"* ]] || { echo "README uses $tok, which the metrics help does not list"; false; }
                    n=$((n + 1))
                    ;;
            esac
        done
    done < <(_code_lines | grep -E 'lyrebird-metrics\.sh')
    [ "$n" -ge 5 ]
    [[ "$help" == *"It is made for a poller"* ]]
    grep -qF 'It is made for a poller' "$README"
    grep -qF 'serve --port 9100' "$README"
    # metric names that never existed
    local gone
    for gone in lyrebird_stream_active lyrebird_usb_devices_total lyrebird_usb_device_connected \
        lyrebird_cpu_usage_percent lyrebird_memory_usage_percent lyrebird_load_average_1m lyrebird_stream_uptime_seconds; do
        run grep -nF "$gone" "$README"
        [ "$status" -eq 1 ] || { echo "README lists $gone"; false; }
    done
    # every name in the metrics table is one the script emits
    local row name found=0
    while IFS= read -r row; do
        while read -r name; do
            name="${name%%\{*}"
            grep -qE "(\"|lyrebird_)${name}\b" "$ROOT/lyrebird-metrics.sh" || { echo "no metric $name in lyrebird-metrics.sh"; false; }
            found=$((found + 1))
        done < <(awk -F'|' '{ print $3 }' <<<"$row" | grep -oE '`[a-z_0-9]+(\{[a-z]+\})?`' | tr -d '`')
    done < <(_section '**Metrics** (every name starts with `lyrebird_`):' '^\*\*Prometheus Configuration' | grep -E '^\| `?[a-z_(]')
    [ "$found" -ge 30 ]
}

@test "every stream manager exit code the script defines is in README's table, with its name [DOC-02]" {
    local block line name num
    block="$(_section '### Stream Manager (lyrebird-stream-manager.sh)' '^### ')"
    [ -n "$block" ]
    while IFS= read -r line; do
        name="${line#readonly }"
        num="${name#*=}"
        name="${name%%=*}"
        grep -qE "^\| ${num} \| \`${name}\` \|" <<<"$block" || { echo "exit code $num $name is not in the README table"; false; }
    done < <(grep -E '^readonly E_[A-Z_]+=[0-9]+$' "$MANAGER")
    grep -qE '^\| 0 \|' <<<"$block"
    grep -qE '^\| 128\+N \|' <<<"$block"
    # and every code the script's own help lists
    run bash "$MANAGER" --help
    local code
    while read -r code; do
        grep -qE "^\| ${code} \|" <<<"$block" || { echo "help lists exit code $code, the README table does not"; false; }
    done < <(awk '/^Exit Codes:/ { f = 1; next } f && /^[[:space:]]+[0-9]+[[:space:]]+- / { print $1 }' <<<"$output")
    # what a caller does with 5, 8 and 9
    grep -qF '**What a script that calls the manager should do with 5, 8 and 9**' "$README"
}

@test "the component version table is the versions the scripts declare [DOC-02]" {
    local f v
    for f in lyrebird-orchestrator.sh lyrebird-updater.sh lyrebird-stream-manager.sh usb-audio-mapper.sh \
        lyrebird-mic-check.sh lyrebird-diagnostics.sh install_mediamtx.sh lyrebird-metrics.sh \
        lyrebird-storage.sh lyrebird-alerts.sh lyrebird-common.sh; do
        v="$(_version "$f")"
        [ -n "$v" ] || { echo "no version in $f"; false; }
        grep -qE "^\| ${f} \| ${v//./\\.} \|" "$README" || { echo "README table: $f is not at $v"; false; }
    done
}

@test "README makes no watchdog claim, the unit has none, and the heartbeat is the time of the last monitor run [DOC-02]" {
    # every mention of a watchdog must be a denial, a removal note, systemd's own setting or the list of what is untested
    local bad
    bad="$(grep -inE 'watchdog' "$README" | grep -viE '\b(no|not|never|nothing|neither|removed)\b|RuntimeWatchdogSec|drivers' || true)"
    [ -z "$bad" ] || { echo "$bad"; false; }
    run grep -E '^[[:space:]]*WatchdogSec=' "$ROOT"/config/*.service
    [ "$status" -eq 1 ]
    run bash -c "grep -v '^[[:space:]]*#' '$MANAGER' | grep -c '/dev/watchdog'"
    [ "$output" = "0" ]
    grep -qF 'Unix time of the last monitor run' "$README"
    grep -qE 'No heartbeat service exists' "$README"
    run bash "$MANAGER" --help
    [[ "$output" != *"watchdog"* ]]
}

@test "README says the newest tag has no 2026-11 fixes and says to install from main, for as long as that is true [DOC-02]" {
    local newest
    newest="$(git -C "$ROOT" tag --sort=-v:refname 2>/dev/null | head -n 1)"
    [ -n "$newest" ] || skip "no tags in this clone (a shallow checkout): nothing to compare"
    if git -C "$ROOT" ls-tree -r --name-only "$newest" 2>/dev/null | grep -qx 'docs/REMEDIATION-2026-11.md'; then
        echo "The newest tag $newest contains docs/REMEDIATION-2026-11.md: a release has the fixes."
        echo "Revisit the paragraph 'Which version this README describes' in README.md and the install-from-main text."
        return 0
    fi
    grep -qF "The newest release tag, \`${newest}\`" "$README" || {
        echo "The newest tag is $newest and it has no docs/REMEDIATION-2026-11.md, but the README does not say so."
        echo "Update 'Which version this README describes' in README.md (Quick Start) to name $newest."
        false
    }
    grep -qF 'install from `main`' "$README"
    grep -qF 'git checkout main' "$README"
    # what the README says v1.3.0 lacks, while the newest tag is v1.3.0 (git show)
    if [ "$newest" = "v1.3.0" ]; then
        run bash -c "git -C '$ROOT' show v1.3.0:lyrebird-updater.sh | grep -c -- '--rollback'"
        [ "$output" = "0" ]
        run bash -c "git -C '$ROOT' show v1.3.0:lyrebird-stream-manager.sh | grep -c 'E_OWNERSHIP'"
        [ "$output" = "0" ]
        run bash -c "git -C '$ROOT' show v1.3.0:lyrebird-stream-manager.sh | grep -c 'status.json'"
        [ "$output" = "0" ]
        run bash -c "git -C '$ROOT' show v1.3.0:lyrebird-stream-manager.sh | grep -c 'apiAddress: :9997'"
        [ "$output" != "0" ]
    fi
}

@test "README's updater exit codes and commands are the script's, and the menu keys are right [DOC-02]" {
    local block line name num
    block="$(_section '## Version Management' '^## ')"
    [ -n "$block" ]
    while IFS= read -r line; do
        name="${line#readonly }"
        num="${name#*=}"
        num="${num%% *}"
        name="${name%%=*}"
        [ "$name" = "E_SUCCESS" ] && num=0
        grep -qE "^\| ${num} \|" <<<"$block" || { echo "updater exit code $num ($name) is not in the README table"; false; }
    done < <(grep -E '^readonly E_[A-Z_]+=[0-9]+' "$ROOT/lyrebird-updater.sh")
    # the help text of the updater (a here-document in show_help) lists the commands the README shows
    local help tok n=0
    help="$(awk '/^show_help\(\) \{/ { f = 1 } f { print } f && /^EOF$/ { exit }' "$ROOT/lyrebird-updater.sh")"
    [ -n "$help" ]
    while IFS= read -r line; do
        for tok in $line; do
            case "$tok" in
                --[a-z]*)
                    [[ "$help" == *"$tok"* ]] || { echo "README uses $tok, the updater's help does not list it"; false; }
                    n=$((n + 1))
                    ;;
            esac
        done
    done < <(_code_lines | grep -E 'lyrebird-updater\.sh')
    [ "$n" -ge 5 ]
    # menu: 1 is the newest tag, 2 the default branch (an earlier text said "option 2: Upgrade to Latest Version")
    run grep -nE 'option [23]: (Upgrade to Latest|Switch to Specific)' "$README"
    [ "$status" -eq 1 ]
    grep -qF 'Switch to Latest Stable Release' "$ROOT/lyrebird-updater.sh"
    grep -qF 'Switch to Development Version' "$ROOT/lyrebird-updater.sh"
}

@test "README describes the wizard's four steps and not a step the orchestrator does not have [DOC-02]" {
    run grep -cE 'Step [1-4]/4' "$ROOT/lyrebird-orchestrator.sh"
    [ "$output" = "4" ]
    grep -qF 'four steps' "$README"
    run grep -nF 'Generate optimal configuration' "$README"
    [ "$status" -eq 1 ]
    grep -qF 'Show Update History' "$ROOT/lyrebird-orchestrator.sh"
    grep -qF 'Roll Back to a Previous Version' "$ROOT/lyrebird-orchestrator.sh"
    grep -qF 'show update history, roll back' "$README"
}

@test "every lyrebird-mic-check.sh option in README is in its usage text, and --json is not one [DOC-02]" {
    # (the real --help: it needs no /proc/asound and exits 0 since X-53)
    local usage line tok n=0
    usage="$(bash "$ROOT/lyrebird-mic-check.sh" --help 2>&1)"
    [ -n "$usage" ]
    while IFS= read -r line; do
        for tok in $line; do
            case "$tok" in
                -[A-Za-z] | --[a-z]*)
                    tok="${tok%%=*}"
                    grep -qE -- "(^|[[:space:],])${tok}([[:space:],=\[]|$)" <<<"$usage" || { echo "README uses $tok, the usage text does not list it"; false; }
                    n=$((n + 1))
                    ;;
            esac
        done
    done < <(_code_lines | grep -E 'lyrebird-mic-check\.sh')
    [ "$n" -ge 6 ]
    run grep -nE 'lyrebird-mic-check\.sh[[:space:]]+--json' "$README"
    [ "$status" -eq 1 ]
    grep -qF -- '--format=json' "$README"
}

@test "README states the Bash versions by what the code uses, and no ARMv6 or 4.0 promise [DOC-02]" {
    # the claims in the table, checked against the code
    local f negative
    # negative array subscripts (${array[-1]}) need Bash 4.3: the mic-check row says 4.3 while the script has
    # one, and 4.2 (declare -g, checked below) once it has none
    negative="$(grep -cE '\$\{[a-z_]+\[-[0-9]\]\}' "$ROOT/lyrebird-mic-check.sh")" || negative=0
    if [ "$negative" -ge 1 ]; then
        grep -qE '^\| `lyrebird-mic-check.sh` \| none \| 4\.3 ' "$README" || { echo "mic-check has a negative subscript: its row must say 4.3"; false; }
    else
        grep -qE '^\| `lyrebird-mic-check.sh` \| none \| 4\.2 ' "$README" || { echo "mic-check has no negative subscript left: its row must say 4.2 (declare -g)"; false; }
    fi
    # nothing else in the suite uses a feature newer than 4.2 (namerefs, wait -n, ${var@Q}, $EPOCHSECONDS and so on)
    for f in "$ROOT"/*.sh; do
        run grep -nE '(local|declare|typeset)[[:space:]]+-[a-zA-Z]*n[a-zA-Z]*[[:space:]]|wait[[:space:]]+-[a-z]*[nfp]|\$\{[a-zA-Z_]+@[QPAaEKkUuL]\}|EPOCHSECONDS|EPOCHREALTIME|BASH_ARGV0|SRANDOM' "$f"
        [ "$status" -eq 1 ] || { echo "${f##*/} uses a feature newer than 4.2: $output"; false; }
    done
    for f in lyrebird-alerts.sh lyrebird-common.sh lyrebird-storage.sh lyrebird-stream-manager.sh lyrebird-mic-check.sh lyrebird-diagnostics.sh; do
        grep -qE '(declare|typeset)[[:space:]]+-[a-zA-Z]*g' "$ROOT/$f" || { echo "$f no longer uses declare -g: update the Bash table"; false; }
    done
    for f in lyrebird-stream-manager.sh lyrebird-orchestrator.sh; do
        grep -qE '\[\[ !?[[:space:]]*-v ' "$ROOT/$f" || { echo "$f no longer uses [[ -v: update the Bash table"; false; }
    done
    for f in lyrebird-stream-manager.sh lyrebird-updater.sh lyrebird-metrics.sh; do
        grep -qE '\{[A-Za-z_]+\}[<>]|exec \{' "$ROOT/$f" || { echo "$f no longer uses {fd} redirections: update the Bash table"; false; }
    done
    # the mapper's row says 4.0: it must not use anything newer
    run grep -cE '(declare|typeset)[[:space:]]+-[a-zA-Z]*g|\[\[ !?[[:space:]]*-v |\{[A-Za-z_]+\}[<>]' "$ROOT/usb-audio-mapper.sh"
    [ "$output" = "0" ] || { echo "usb-audio-mapper.sh uses a feature newer than Bash 4.0: update the Bash table"; false; }
    grep -qE '^\| `usb-audio-mapper.sh` \| 4\.0 \| 4\.0 ' "$README"
    run grep -nE 'bash 4\.0\+|Bash 4\.0\+|Bash: Version 4\.0' "$README"
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    # architectures: the mapping exists in the installer, the README does not call ARMv6 supported or tested
    grep -qE 'armv6\*\)' "$ROOT/install_mediamtx.sh"
    run grep -nE 'Architecture\*\*: .*ARMv6|x86_64, ARM64, ARMv7, ARMv6' "$README"
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    grep -qF 'were not checked' "$README"
    grep -qF 'No ARM, no Bash 4.x, no macOS or BSD' "$README"
}

@test "README puts the FFmpeg logs where the stream manager writes them, and says DEBUG must be true [DOC-02]" {
    grep -qE 'ffmpeg_log="\$\{FFMPEG_PID_DIR\}/\$\{stream_path\}\.log"' "$MANAGER"
    run grep -nE 'FFmpeg per-device: `/var/log/lyrebird|/var/log/lyrebird/<device-name>|tail -f /var/log/lyrebird/\*\.log' "$README"
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    grep -qF '/var/lib/mediamtx-ffmpeg/<stream>.log' "$README"
    # DEBUG=1 does nothing: every script compares the value with "true"
    grep -qF '[[ "${DEBUG:-false}" == "true" ]]' "$MANAGER"
    run grep -nE '(export|env|sudo) +DEBUG=1|^DEBUG=1' "$README"
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    run grep -nE 'debug --verbose' "$README"
    [ "$status" -eq 1 ]
}

@test "README names the backups the software makes, not an audio-devices.conf.bak no script writes [DOC-02]" {
    run grep -nF 'audio-devices.conf.bak' "$README"
    [ "$status" -eq 1 ] || { echo "$output"; false; }
    # mic-check writes ${CONFIG_FILE}.backup.<date>_<time>; the manager writes <file>.<UTC>.<nn>.bak
    grep -qF 'backup_file="${CONFIG_FILE}.backup.$(date +%Y%m%d_%H%M%S)"' "$ROOT/lyrebird-mic-check.sh"
    grep -qF 'audio-devices.conf.backup.<YYYYmmdd_HHMMSS>' "$README"
    grep -qF 'mediamtx.yml.<UTC time>.<nn>.bak' "$README"
    run grep -rnF '.conf.bak' "$ROOT"/*.sh
    [ "$status" -eq 1 ] || { echo "a script mentions .conf.bak: $output"; false; }
}

@test "README documents the status document with the fields the script's help lists [DOC-02]" {
    run bash "$MANAGER" --help
    [ "$status" -eq 0 ]
    local field
    for field in schema_version timestamp overall policy mediamtx running pid streams device path configured process_alive path_ready bytes_flowing last_error; do
        [[ "$output" == *"$field"* ]] || { echo "help does not name $field"; false; }
        grep -qF "$field" "$README" || { echo "README does not name $field"; false; }
    done
    local state
    for state in ok degraded failed waiting_for_devices stopped; do
        grep -qF "\`$state\`" "$README" || { echo "README does not describe overall state $state"; false; }
    done
    grep -qF '/run/lyrebird/status.json' "$README"
    grep -qF 'status --json' "$README"
}

@test "README gives the start policy and the empty-start setting with the defaults the code has [DOC-02]" {
    run bash "$MANAGER" --help
    [[ "$output" == *"LYREBIRD_START_POLICY    What start requires [default: degraded]"* ]]
    [[ "$output" == *"true (default): with no USB audio device start"* ]]
    grep -qE '^\| `LYREBIRD_START_POLICY` \| `degraded` \|' "$README"
    grep -qE '^\| `LYREBIRD_ALLOW_EMPTY_START` \| `true` \|' "$README"
    grep -qF 'waiting_for_devices' "$README"
    # the ports: invalid is exit 4 in the manager and exit 10 in the installer
    grep -qF 'stops the stream manager with exit 4 and the installer with exit 10' "$README"
    run env MEDIAMTX_API_PORT=abc bash "$MANAGER" help
    [ "$status" -eq 4 ]
    # (the installer takes a lock under /run/lock even for a dry run, so its exit code is read from the source)
    grep -qF 'fatal "Invalid MediaMTX port settings" 10' "$ROOT/install_mediamtx.sh"
}

@test "the defaults in README's environment table are the defaults in the script [DOC-02]" {
    local name want got tbl v names cells pos i d
    tbl="$(_section '### Environment Variables' '^\*\*Installer settings')"
    [ -n "$tbl" ] || { echo "README has no environment table"; false; }
    for name in MEDIAMTX_RTSP_PORT MEDIAMTX_API_PORT MEDIAMTX_METRICS_PORT MEDIAMTX_CONFIG_BACKUPS \
        STREAM_STARTUP_DELAY USB_STABILIZATION_DELAY RESTART_STABILIZATION_DELAY STREAM_VALIDATION_ATTEMPTS \
        STREAM_VALIDATION_DELAY MEDIAMTX_API_TIMEOUT LOCK_ACQUISITION_TIMEOUT STOP_LOCK_TIMEOUT MONITOR_LOCK_TIMEOUT \
        MAX_FD_WARNING MAX_FD_CRITICAL MAX_CPU_WARNING MAX_CPU_CRITICAL MAX_WRAPPER_RESTARTS WRAPPER_SUCCESS_DURATION \
        MAX_CONSECUTIVE_FAILURES INITIAL_RESTART_DELAY MAX_RESTART_DELAY DEEP_HEALTH_MAX_STRIKES CRON_RESTART_MAX_PER_HOUR \
        AUDIO_LEVEL_SAMPLE_DURATION AUDIO_LEVEL_CHECK_INTERVAL AUDIO_SILENCE_THRESHOLD_DB AUDIO_SILENCE_WARN_DURATION \
        DISK_SPACE_WARNING_PERCENT DISK_SPACE_CRITICAL_PERCENT DISK_SPACE_MIN_FREE_MB MEM_WARNING_PERCENT MEM_CRITICAL_PERCENT \
        FFMPEG_LOG_KEEP DEFAULT_SAMPLE_RATE DEFAULT_CHANNELS DEFAULT_CODEC DEFAULT_BITRATE DEFAULT_THREAD_QUEUE \
        DEFAULT_ANALYZEDURATION DEFAULT_PROBESIZE AUDIO_RECORDING_PATH AUDIO_RECORDING_SEGMENT_TIME AUDIO_RECORDING_SEGMENTS \
        MAIN_LOG_MAX_SIZE FFMPEG_LOG_MAX_SIZE MEDIAMTX_LOG_MAX_SIZE MEDIAMTX_HOST MEDIAMTX_API_BIND MEDIAMTX_METRICS_BIND \
        RTSP_AUTH_MODE STREAM_MANAGER_LOG_FILE MEDIAMTX_LOG_FILE; do
        got="$(_default_in "$MANAGER" "$name")" || { echo "no default found for $name in the script"; false; }
        # the README row: | `NAME` | `default` | ... ; two variables in one row: | `A`, `B` | `x`, `y` |
        want="$(grep -E "^\| .*\`${name}\`.*\|" <<<"$tbl" | head -n 1)" || true
        [ -n "$want" ] || { echo "README table has no row for $name"; false; }
        # first cell: the names; second cell: the defaults, in the same order
        names="$(awk -F'|' '{ print $2 }' <<<"$want")"
        cells="$(awk -F'|' '{ print $3 }' <<<"$want")"
        pos=-1
        i=0
        for v in $(grep -oE '`[A-Z_0-9]+`' <<<"$names" | tr -d '`'); do
            [ "$v" = "$name" ] && pos=$i
            i=$((i + 1))
        done
        [ "$pos" -ge 0 ] || { echo "$name is not in the name cell of its row"; false; }
        d="$(grep -oE '`[^`]*`' <<<"$cells" | sed -n "$((pos + 1))p" | tr -d '`')"
        [ "$d" = "$got" ] || { echo "$name: README says '$d', the script says '$got'"; false; }
    done
}

@test "README's generated MediaMTX configuration is what the shared renderer writes [DOC-02]" {
    local rendered shown
    rendered="$(cd "$ROOT" && bash -c 'source ./lyrebird-common.sh && lyrebird_render_mediamtx_config --mediamtx-version v1.21.3')"
    [ -n "$rendered" ]
    # first line is the marker
    [ "$(head -n 1 <<<"$rendered")" = "# Managed by LyreBirdAudio" ]
    # the yaml block that follows 'What the generator writes' in the README
    shown="$(awk '/^What the generator writes/ { f = 1; next } f && /^```yaml/ { y = 1; next } y && /^```/ { exit } y' "$README")"
    [ -n "$shown" ] || { echo "README has no block after 'What the generator writes'"; false; }
    # compare without comments, trailing comments and blank lines
    local norm='/^[[:space:]]*#/d; s/[[:space:]]+#.*$//; /^[[:space:]]*$/d'
    diff <(sed -E "$norm" <<<"$shown") <(sed -E "$norm" <<<"$rendered") || {
        echo "README's example differs from the renderer's output"
        false
    }
    grep -qF '# Managed by LyreBirdAudio' "$README"
}

@test "README's sections for ownership, status, upgrading and testing exist, and every link inside the README resolves [DOC-02]" {
    local h
    for h in '## Upgrading an Existing Node' '### Which unit runs MediaMTX' '### Configuration ownership' \
        '### Status document' '### The Monitor' '### Testing' '### Reload' '### Systemd Service Installation' \
        '### Reliability: what recovers and what does not'; do
        grep -qxF "$h" "$README" || { echo "README has no heading '$h'"; false; }
    done
    # GitHub's anchor for a heading: lower case, punctuation dropped, spaces to hyphens
    local anchors link a
    anchors="$(awk '/^```/ { f = !f; next } !f' "$README" | grep -E '^#{1,6} ' | sed -E 's/^#+ +//; s/`//g' | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9_ -]//g; s/ /-/g')"
    while IFS= read -r link; do
        a="${link#\#}"
        grep -qxF "$a" <<<"$anchors" || { echo "link to #$a has no heading"; false; }
    done < <(awk '/^```/ { f = !f; next } !f' "$README" | grep -oE '\]\(#[^)]+\)' | sed -E 's/^\]\(//; s/\)$//' | sort -u)
    # links to files in the repository
    while IFS= read -r link; do
        [ -e "$ROOT/${link%%#*}" ] || { echo "link to missing file $link"; false; }
    done < <(awk '/^```/ { f = !f; next } !f' "$README" | grep -oE '\]\((docs|tools|tests|config)/[^)]+\)' | sed -E 's/^\]\(//; s/\)$//' | sort -u)
}

@test "the test counts README states are the counts of tests/, not counting the documentation checks [DOC-02]" {
    local f n_files=0 files=() want_tests got_tests
    for f in "$ROOT"/tests/*.bats; do
        case "${f##*/}" in test_docs_*) continue ;; esac
        files+=("$f")
        n_files=$((n_files + 1))
    done
    got_tests="$(bats --count "${files[@]}")"
    want_tests="$(grep -oE '\*\*[0-9]+ tests in [0-9]+ files\*\*' "$README" | head -n 1)" || true
    [ -n "$want_tests" ] || { echo "README does not state '**N tests in M files**'"; false; }
    [ "$want_tests" = "**${got_tests} tests in ${n_files} files**" ] || {
        echo "README says $want_tests; tests/ has $got_tests tests in $n_files files (without tests/test_docs_*.bats)"
        false
    }
}

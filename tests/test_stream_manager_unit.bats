#!/usr/bin/env bats
# The systemd unit of lyrebird-stream-manager.sh (register: LB-11, LB-12, X-12;
# decision D12): the one template config/mediamtx-audio.service, the generator
# that renders it (`install`), the settings the unit hands the manager, and the
# cron line `install` writes.
#
# The real script is sourced in a fresh bash for every call and the real
# functions run. systemd-analyze (which loads a unit file with systemd's own
# parser, without a service manager) is the judge of the rendered files.

load scratch_tmpdir

setup() {
    scratch_setup
    TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
    UN="$TEST_SCRATCH/un"
    mkdir -p "$UN"
    BG_PIDS=()
    export PROJECT_ROOT UN
    export MEDIAMTX_LOG_FILE="$UN/sm.log" STREAM_MANAGER_LOG_FILE="$UN/sm.log" MEDIAMTX_CONFIG_DIR="$UN/cfg" MEDIAMTX_FFMPEG_DIR="$UN/ff"
    export MEDIAMTX_PID_FILE="$UN/mtx.pid" MEDIAMTX_LOCK_FILE="$UN/run.lock"
    SCRIPT="$PROJECT_ROOT/lyrebird-stream-manager.sh"
    TEMPLATE="$PROJECT_ROOT/config/mediamtx-audio.service"
}

teardown() {
    local pid
    for pid in "${BG_PIDS[@]:-}"; do
        [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    done
    scratch_teardown
}

# ---------------------------------------------------------------------------
# No faked systemd variable (LB-11)
# ---------------------------------------------------------------------------

@test "lyrebird_under_systemd: the unit's LYREBIRD_UNDER_SYSTEMD, or systemd's own INVOCATION_ID, and nothing else [LB-11]" {
    local value
    for value in 1 true yes; do
        run env -u INVOCATION_ID LYREBIRD_UNDER_SYSTEMD="$value" bash -c 'source "$1" >/dev/null 2>&1; lyrebird_under_systemd' _ "$SCRIPT"
        [ "$status" -eq 0 ]
    done
    for value in 0 false no ""; do
        run env -u INVOCATION_ID LYREBIRD_UNDER_SYSTEMD="$value" bash -c 'source "$1" >/dev/null 2>&1; lyrebird_under_systemd' _ "$SCRIPT"
        [ "$status" -eq 1 ]
    done
    run env -u INVOCATION_ID -u LYREBIRD_UNDER_SYSTEMD bash -c 'source "$1" >/dev/null 2>&1; lyrebird_under_systemd' _ "$SCRIPT"
    [ "$status" -eq 1 ]
    # systemd itself sets INVOCATION_ID (a 32-digit hex id) for every service process; a unit
    # written by an older version of this script set it to the word "systemd" by hand
    run env -u LYREBIRD_UNDER_SYSTEMD INVOCATION_ID=0123456789abcdef0123456789abcdef bash -c 'source "$1" >/dev/null 2>&1; lyrebird_under_systemd' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    run env -u LYREBIRD_UNDER_SYSTEMD INVOCATION_ID=systemd bash -c 'source "$1" >/dev/null 2>&1; lyrebird_under_systemd' _ "$SCRIPT"
    [ "$status" -eq 0 ]
}

# The signal handlers are installed when the script is executed (not sourced) and not under
# systemd. The copy has its final `main "$@"` replaced by a printout of the traps; everything
# before it, the code under test, is the real script.
@test "the manager installs its HUP/USR1 handlers only when it is not run by systemd, and sets no USR2 handler [LB-11, LB-15]" {
    mkdir -p "$UN/copy"
    cp "$PROJECT_ROOT/lyrebird-common.sh" "$UN/copy/"
    sed 's/^    main "\$@"$/    trap -p HUP USR1 USR2/' "$SCRIPT" >"$UN/copy/lyrebird-stream-manager.sh"
    ! cmp -s "$SCRIPT" "$UN/copy/lyrebird-stream-manager.sh"
    run env -u INVOCATION_ID -u LYREBIRD_UNDER_SYSTEMD bash "$UN/copy/lyrebird-stream-manager.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SIGHUP"* && "$output" == *"SIGUSR1"* ]]
    [[ "$output" != *"SIGUSR2"* ]]

    run env -u INVOCATION_ID LYREBIRD_UNDER_SYSTEMD=1 bash "$UN/copy/lyrebird-stream-manager.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    # a unit from an older version, which set INVOCATION_ID by hand, behaves as before
    run env -u LYREBIRD_UNDER_SYSTEMD INVOCATION_ID=systemd bash "$UN/copy/lyrebird-stream-manager.sh"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "no code and no shipped unit sets INVOCATION_ID by hand; the logrotate guard asks lyrebird_under_systemd [LB-11]" {
    local f
    for f in setup_mediamtx_logrotate exit_critical_section; do
        run bash -c 'source "$1" >/dev/null 2>&1; declare -f "$2"' _ "$SCRIPT" "$f"
        [ "$status" -eq 0 ]
        [[ "$output" == *"lyrebird_under_systemd"* ]]
        [[ "$output" != *"INVOCATION_ID"* ]]
    done
    run bash -c 'source "$1" >/dev/null 2>&1; declare -f create_systemd_service' _ "$SCRIPT"
    [[ "$output" != *'INVOCATION_ID='* ]]
    run grep -n 'INVOCATION_ID' "$PROJECT_ROOT/config/mediamtx-audio.service" "$PROJECT_ROOT/config/mediamtx.service"
    [ "$status" -ne 0 ]
    # the unit tells the manager it is under systemd explicitly
    run grep -n '^Environment="LYREBIRD_UNDER_SYSTEMD=1"$' "$PROJECT_ROOT/config/mediamtx-audio.service"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Helpers for the template and the generator
# ---------------------------------------------------------------------------

# An installation of the script at $UN/inst: executable, with its library and the
# template next to it, as a checkout (or /usr/local/bin plus config/) holds them
make_install() {
    mkdir -p "$UN/inst/config"
    cp "$PROJECT_ROOT/lyrebird-stream-manager.sh" "$PROJECT_ROOT/lyrebird-common.sh" "$UN/inst/"
    cp "$PROJECT_ROOT/config/mediamtx-audio.service" "$UN/inst/config/"
    chmod +x "$UN/inst/lyrebird-stream-manager.sh"
    ISCRIPT="$UN/inst/lyrebird-stream-manager.sh"
    export ISCRIPT
}

# inst FUNCTION [ARGS]: a function of the installed copy, in a fresh process
inst() {
    run bash -c 'source "$ISCRIPT" >/dev/null 2>&1; "$@"' _ "$@"
}

# The manager's configured paths unset: its defaults (the setup points them at a scratch directory)
DEFAULT_PATHS=(-u MEDIAMTX_LOG_FILE -u STREAM_MANAGER_LOG_FILE -u MEDIAMTX_CONFIG_DIR -u MEDIAMTX_FFMPEG_DIR -u MEDIAMTX_PID_FILE -u MEDIAMTX_LOCK_FILE
    -u STREAM_MODE -u MULTIPLEX_FILTER_TYPE -u MULTIPLEX_STREAM_NAME -u AUDIO_LOCAL_RECORDING -u AUDIO_RECORDING_PATH)

# The value of the first KEY= line of SECTION in FILE
unit_value() { # unit_value FILE SECTION KEY
    awk -v sec="[$2]" -v key="$3=" '
        /^\[/ { cur = $0 }
        cur == sec && index($0, key) == 1 { print substr($0, length(key) + 1); exit }' "$1"
}
# Every KEY= line of FILE in SECTION
unit_values() {
    awk -v sec="[$2]" -v key="$3=" '
        /^\[/ { cur = $0 }
        cur == sec && index($0, key) == 1 { print substr($0, length(key) + 1) }' "$1"
}

require_analyze() {
    command -v systemd-analyze >/dev/null 2>&1 || skip "systemd-analyze not available"
}

# systemd-analyze verify of FILES, minus the one message that is expected for a unit that
# names a program that is not installed on this machine
verify_findings() {
    systemd-analyze verify "$@" 2>&1 | grep -v 'is not executable: No such file or directory' || true
}

# ---------------------------------------------------------------------------
# The template
# ---------------------------------------------------------------------------

@test "the template and the standalone unit load without a finding, together without an ordering cycle [LB-11, LB-12, D12]" {
    require_analyze
    # (the only message allowed is a program that is not installed here: /usr/local/bin/mediamtx)
    [ -z "$(verify_findings "$PROJECT_ROOT/config/mediamtx-audio.service")" ]
    [ -z "$(verify_findings "$PROJECT_ROOT/config/mediamtx.service")" ]
    [ -z "$(verify_findings "$PROJECT_ROOT/config/mediamtx-audio.service" "$PROJECT_ROOT/config/mediamtx.service")" ]
}

@test "the template has Type=forking with a PIDFile, no WatchdogSec, User=root and no User=mediamtx hint [LB-11]" {
    [ "$(unit_value "$TEMPLATE" Service Type)" = "forking" ]
    [ -n "$(unit_value "$TEMPLATE" Service PIDFile)" ]
    [ "$(unit_value "$TEMPLATE" Service User)" = "root" ]
    run grep -nE '^[[:space:]]*WatchdogSec=' "$TEMPLATE"
    [ "$status" -ne 0 ]
    # the manager requires root: a hint to run it as another user breaks it
    run grep -n 'User=mediamtx' "$TEMPLATE"
    [ "$status" -ne 0 ]
}

@test "StartLimitIntervalSec and StartLimitBurst are in [Unit] and nowhere else, in both units [LB-12]" {
    local unit
    for unit in mediamtx-audio.service mediamtx.service; do
        [ -n "$(unit_value "$PROJECT_ROOT/config/$unit" Unit StartLimitIntervalSec)" ]
        [ -n "$(unit_value "$PROJECT_ROOT/config/$unit" Unit StartLimitBurst)" ]
        # every StartLimit* line of the file sits in [Unit]: the section of each one
        run awk '/^\[/ { cur = $0 } /^StartLimit/ { print cur }' "$PROJECT_ROOT/config/$unit"
        [ "$status" -eq 0 ]
        [ -n "$output" ]
        [ -z "$(grep -v '^\[Unit\]$' <<<"$output")" ]
    done
    # the old non-canonical spelling is gone from the template
    run grep -n '^StartLimitInterval=' "$TEMPLATE"
    [ "$status" -ne 0 ]
}

@test "the manager unit conflicts with mediamtx.service and has no Wants=, Requires=, BindsTo= or PartOf= on it; After= is ordering only [LB-11, D1]" {
    [ "$(unit_value "$TEMPLATE" Unit Conflicts)" = "mediamtx.service" ]
    run grep -nE '^(Wants|Requires|Requisite|BindsTo|PartOf|Upholds)=.*mediamtx\.service' "$TEMPLATE"
    [ "$status" -ne 0 ]
    [[ " $(unit_values "$TEMPLATE" Unit After | tr '\n' ' ') " == *" mediamtx.service"* || "$(unit_values "$TEMPLATE" Unit After | tr '\n' ' ')" == *"mediamtx.service"* ]]
    [[ "$(unit_values "$TEMPLATE" Unit After | tr '\n' ' ')" == *"network.target"* ]]
    [[ "$(unit_values "$TEMPLATE" Unit After | tr '\n' ' ')" == *"sound.target"* ]]
    # the standalone unit is the other half of the exclusion
    [ "$(unit_value "$PROJECT_ROOT/config/mediamtx.service" Unit Conflicts)" = "mediamtx-audio.service" ]
    run grep -nE '^(Wants|Requires|Requisite|BindsTo|PartOf|Upholds)=.*mediamtx-audio\.service' "$PROJECT_ROOT/config/mediamtx.service"
    [ "$status" -ne 0 ]
}

@test "every command the units run is one main implements, and no unit reloads by sending a signal MediaMTX does not handle [LB-11, X-12]" {
    local unit key cmd
    run bash -c 'source "$1" >/dev/null 2>&1; declare -f main' _ "$PROJECT_ROOT/lyrebird-stream-manager.sh"
    local main_text="$output"
    for key in ExecStart ExecStop ExecReload; do
        cmd="$(unit_value "$TEMPLATE" Service "$key")"
        [ -n "$cmd" ]
        # the last word is the command: a case label of main
        [[ "$main_text" == *"${cmd##* })"* ]]
    done
    [ "$(unit_value "$TEMPLATE" Service ExecReload | awk '{print $NF}')" = "reload" ]
    for unit in mediamtx-audio.service mediamtx.service; do
        run grep -nE '^ExecReload=.*(kill|-HUP|-USR1|-USR2|SIGHUP|SIGUSR)' "$PROJECT_ROOT/config/$unit"
        [ "$status" -ne 0 ]
    done
    # the standalone unit has no ExecReload at all: MediaMTX re-reads its file by itself
    [ -z "$(unit_value "$PROJECT_ROOT/config/mediamtx.service" Service ExecReload)" ]
}

@test "the sandbox is as strict as the manager allows and sets nothing that would block USB audio or hotplug [LB-11]" {
    [ "$(unit_value "$TEMPLATE" Service ProtectSystem)" = "strict" ]
    [ "$(unit_value "$TEMPLATE" Service NoNewPrivileges)" = "yes" ]
    [ "$(unit_value "$TEMPLATE" Service PrivateTmp)" = "yes" ]
    [ "$(unit_value "$TEMPLATE" Service ProtectKernelTunables)" = "yes" ]
    [ "$(unit_value "$TEMPLATE" Service ProtectKernelModules)" = "yes" ]
    [ "$(unit_value "$TEMPLATE" Service ProtectControlGroups)" = "yes" ]
    # read-only, not inaccessible: the script is often installed under /home or /root
    [ "$(unit_value "$TEMPLATE" Service ProtectHome)" = "read-only" ]
    # the manager needs the sound devices and their hotplug: none of these may be set
    local key
    for key in PrivateDevices DevicePolicy DeviceAllow ProtectClock PrivateNetwork RestrictAddressFamilies MemoryDenyWriteExecute SystemCallFilter CapabilityBoundingSet MemoryMax; do
        [ -z "$(unit_value "$TEMPLATE" Service "$key")" ]
    done
    # the directories it creates for itself
    [[ "$(unit_value "$TEMPLATE" Service StateDirectory)" == *"lyrebird"* && "$(unit_value "$TEMPLATE" Service StateDirectory)" == *"mediamtx-ffmpeg"* ]]
    [ "$(unit_value "$TEMPLATE" Service WorkingDirectory)" = "/var/lib/lyrebird" ]
    [ "$(unit_value "$TEMPLATE" Service RuntimeDirectory)" = "lyrebird" ]
    [ "$(unit_value "$TEMPLATE" Service RuntimeDirectoryPreserve)" = "yes" ]
}


# ---------------------------------------------------------------------------
# The generator: render_systemd_unit
# ---------------------------------------------------------------------------

@test "render_systemd_unit with the default settings is the template, with only the script path replaced [LB-11, D12: no drift]" {
    make_install
    run env "${DEFAULT_PATHS[@]}" bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_systemd_unit >"$1"' _ "$UN/rendered.service"
    [ "$status" -eq 0 ]
    # the template names the default install path; the rest is byte for byte the same
    sed "/^Exec/s#/usr/local/bin/lyrebird-stream-manager.sh#$UN/inst/lyrebird-stream-manager.sh#" "$TEMPLATE" >"$UN/expected.service"
    run diff "$UN/expected.service" "$UN/rendered.service"
    [ "$status" -eq 0 ]
    [ "$(grep -c "^Exec" "$UN/rendered.service")" -eq 3 ]
    # the three Exec lines are the lines that differ from the template
    run diff "$TEMPLATE" "$UN/rendered.service"
    [ "$(grep -c '^[<>]' <<<"$output")" -eq 6 ]
    [ "$(grep '^[<>]' <<<"$output" | grep -vc '^[<>] Exec')" -eq 0 ]
}

@test "the rendered unit is accepted by systemd with zero findings when ExecStart names an existing executable script [LB-11, LB-12]" {
    require_analyze
    make_install
    # (verified with the script installed and executable: the shipped template names /usr/local/bin,
    # where this machine has nothing, which is the one finding the template check above allows)
    run bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_systemd_unit >"$1"' _ "$UN/mediamtx-audio.service"
    [ "$status" -eq 0 ]
    run systemd-analyze verify "$UN/mediamtx-audio.service"
    [ -z "$output" ]
    # multiplex, with a name that needs escaping
    run env STREAM_MODE=multiplex MULTIPLEX_FILTER_TYPE=amerge MULTIPLEX_STREAM_NAME='a"b\c%d e;f' \
        bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_systemd_unit >"$1"' _ "$UN/mediamtx-audio.service"
    [ "$status" -eq 0 ]
    run systemd-analyze verify "$UN/mediamtx-audio.service"
    [ -z "$output" ]
}

@test "render_systemd_unit: stream mode, filter and name reach the unit, the name escaped for systemd (round trip) [LB-11, X-11]" {
    make_install
    local name='a"b\c%d e;f$g'
    run env STREAM_MODE=multiplex MULTIPLEX_FILTER_TYPE=amerge MULTIPLEX_STREAM_NAME="$name" \
        bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_systemd_unit' _
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nEnvironment="STREAM_MODE=multiplex"\n'* ]]
    [[ "$output" == *$'\nEnvironment="MULTIPLEX_FILTER_TYPE=amerge"\n'* ]]
    local line
    line="$(grep '^Environment="MULTIPLEX_STREAM_NAME=' <<<"$output")"
    # backslash, double quote and percent are escaped; nothing else is touched
    [ "$line" = 'Environment="MULTIPLEX_STREAM_NAME=a\"b\\c%%d e;f$g"' ]
    # systemd's reading of the quoted assignment gives the name back
    run python3 -I - "$line" "$name" <<'PY'
import re, sys
line, want = sys.argv[1], sys.argv[2]
m = re.fullmatch(r'Environment="(MULTIPLEX_STREAM_NAME)=(.*)"', line)
raw = m.group(2)
out, i = [], 0
while i < len(raw):
    c = raw[i]
    if c == '\\':
        out.append(raw[i + 1])
        i += 2
    elif c == '%':
        assert raw[i + 1] == '%', "a lone % is a specifier"
        out.append('%')
        i += 2
    else:
        assert c != '"', "an unescaped quote ends the value"
        out.append(c)
        i += 1
assert ''.join(out) == want, (''.join(out), want)
PY
    [ "$status" -eq 0 ]
}

@test "render_systemd_unit refuses what the unit file cannot carry and prints no unit: a newline in the name, a bad mode or filter, a path with a space [LB-11, X-11]" {
    make_install
    run env MULTIPLEX_STREAM_NAME=$'studio\nExecStartPre=/bin/touch /tmp/pwned' bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_systemd_unit' _
    [ "$status" -ne 0 ]
    [[ "$output" == *"MULTIPLEX_STREAM_NAME is empty or contains a control character"* ]]
    [[ "$output" != *"[Unit]"* ]]
    # an empty name is the default name, as everywhere else in the manager
    run env MULTIPLEX_STREAM_NAME= bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_systemd_unit' _
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nEnvironment="MULTIPLEX_STREAM_NAME=all_mics"\n'* ]]
    run env STREAM_MODE=both bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_systemd_unit' _
    [ "$status" -ne 0 ]
    [[ "$output" == *"neither individual nor multiplex"* ]]
    run env MULTIPLEX_FILTER_TYPE=join bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_systemd_unit' _
    [ "$status" -ne 0 ]
    [[ "$output" == *"neither amix nor amerge"* ]]
    # a path with a space or a quote: the PID file, the log file
    run env MEDIAMTX_PID_FILE="/run/my pid.pid" bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_systemd_unit' _
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not an absolute path of letters, digits"* ]]
    run env MEDIAMTX_LOG_FILE='/var/log/it"s.log' STREAM_MANAGER_LOG_FILE='/var/log/it"s.log' bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_systemd_unit' _
    [ "$status" -ne 0 ]
    # the script installed under a path with a space
    mkdir -p "$UN/with space/config"
    cp "$ISCRIPT" "$PROJECT_ROOT/lyrebird-common.sh" "$UN/with space/"
    cp "$TEMPLATE" "$UN/with space/config/"
    run bash -c 'source "$1" >/dev/null 2>&1; render_systemd_unit' _ "$UN/with space/lyrebird-stream-manager.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"move the script or the file to such a path"* ]]
}

@test "the template is found next to the script, LYREBIRD_UNIT_TEMPLATE overrides it, and a missing one is an error that says what to do [LB-11, D12]" {
    make_install
    inst unit_template_path
    [ "$output" = "$UN/inst/config/mediamtx-audio.service" ]
    cp "$TEMPLATE" "$UN/other.service"
    sed -i 's/^LimitNOFILE=65536/LimitNOFILE=1234/' "$UN/other.service"
    run env LYREBIRD_UNIT_TEMPLATE="$UN/other.service" bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_systemd_unit' _
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\nLimitNOFILE=1234\n'* ]]
    rm -f "$UN/inst/config/mediamtx-audio.service"
    inst render_systemd_unit
    [ "$status" -ne 0 ]
    [[ "$output" == *"unit template"*"is missing: run install from a complete checkout"* ]]
}

# ---------------------------------------------------------------------------
# TimeoutStartSec= / TimeoutStopSec= and ReadWritePaths=
# ---------------------------------------------------------------------------

@test "TimeoutStartSec and TimeoutStopSec: the template's numbers are the manager's worst case for 8 streams, and follow the configured timeouts [LB-11]" {
    make_install
    # 30 lock + 9*5 cleanup + 15 restart wait + 10 USB + 60 API + 8*(13 + 3*(5+2+3)) = 504; +10 % rounded up to 10 s
    inst unit_start_timeout_seconds
    [ "$output" = "560" ]
    [ "$(unit_value "$TEMPLATE" Service TimeoutStartSec)" = "560" ]
    # 5 lock + 8*10 wrappers + 30 MediaMTX = 115; +10 % rounded up to 10 s
    inst unit_stop_timeout_seconds
    [ "$output" = "130" ]
    [ "$(unit_value "$TEMPLATE" Service TimeoutStopSec)" = "130" ]
    # the rendered unit carries them
    inst render_systemd_unit
    [[ "$output" == *$'\nTimeoutStartSec=560\n'* && "$output" == *$'\nTimeoutStopSec=130\n'* ]]

    # 30 + 15 + 15 + 10 + 60 + 2*43 = 216 -> 238 -> 240
    inst unit_start_timeout_seconds 2 10
    [ "$output" = "240" ]
    inst unit_start_timeout_seconds 16 10
    [ "$output" -gt 560 ]
    run env STREAM_VALIDATION_DELAY=15 bash -c 'source "$ISCRIPT" >/dev/null 2>&1; unit_start_timeout_seconds' _
    [ "$output" -gt 560 ]
    # +60 s of API wait: 504 + 60 = 564 -> 621 -> 630
    run env MEDIAMTX_API_TIMEOUT=120 bash -c 'source "$ISCRIPT" >/dev/null 2>&1; unit_start_timeout_seconds' _
    [ "$output" -eq 630 ]
    # 60 + 80 + 30 = 170 -> 187 -> 190
    run env STOP_LOCK_TIMEOUT=60 bash -c 'source "$ISCRIPT" >/dev/null 2>&1; unit_stop_timeout_seconds' _
    [ "$output" -eq 190 ]
    # LYREBIRD_UNIT_MAX_STREAMS sizes the unit for more (or fewer) streams
    run env LYREBIRD_UNIT_MAX_STREAMS=16 bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_systemd_unit' _
    [[ "$output" == *$'\nTimeoutStartSec=980\n'* && "$output" == *$'\nTimeoutStopSec=220\n'* ]]
}

@test "the constants of the timeout derivation are the ones the code uses: 5 s per cleaned process, 10 s per wrapper stop, 30 s for MediaMTX, the settle sleep and the validation attempts [LB-11]" {
    local src="$PROJECT_ROOT/lyrebird-stream-manager.sh"
    run bash -c 'source "$1" >/dev/null 2>&1; declare -f cleanup_stale_processes stop_ffmpeg_stream stop_mediamtx start_ffmpeg_stream validate_stream probe_stream_ready mediamtx_api_probe' _ "$src"
    [ "$status" -eq 0 ]
    [[ "$output" == *'local timeout="${1:-5}"'* ]]
    [[ "$output" == *'stop_recorded_process "$pid_file" wrapper 10 "$stream_path"'* ]]
    [[ "$output" == *'stop_recorded_process "${PID_FILE}" mediamtx 30'* ]]
    [[ "$output" == *'sleep $((STREAM_STARTUP_DELAY + 3))'* ]]
    [[ "$output" == *'local max_attempts="${2:-${STREAM_VALIDATION_ATTEMPTS}}"'* ]]
    [[ "$output" == *'sleep "${STREAM_VALIDATION_DELAY}"'* ]]
    # the per-attempt API cost: the path query (3 s) and one version-detection request (2 s)
    [[ "$output" == *'/paths/get/${stream_path}" 3'* ]]
    [[ "$output" == *'local max_time="${1:-2}"'* ]]
}

@test "ReadWritePaths: the defaults, the directories of configured paths, and a recording path off tmpfs that may be absent [LB-11]" {
    make_install
    run env "${DEFAULT_PATHS[@]}" bash -c 'source "$ISCRIPT" >/dev/null 2>&1; unit_read_write_paths "$1"' _ "$TEMPLATE"
    [ "$status" -eq 0 ]
    [ "$output" = "/etc/mediamtx /var/log /run" ]
    [ "$(unit_value "$TEMPLATE" Service ReadWritePaths)" = "/etc/mediamtx /var/log /run" ]

    run env MEDIAMTX_CONFIG_DIR=/srv/mtx/etc MEDIAMTX_FFMPEG_DIR=/srv/mtx/ff MEDIAMTX_PID_FILE=/run/lb/x.pid \
        MEDIAMTX_LOG_FILE=/srv/log/sm.log STREAM_MANAGER_LOG_FILE=/srv/log/sm.log MEDIAMTX_LOCK_FILE=/run/lb/x.lock bash -c 'source "$ISCRIPT" >/dev/null 2>&1; unit_read_write_paths "$1"' _ "$TEMPLATE"
    [ "$status" -eq 0 ]
    [ "$output" = "/srv/mtx/etc /srv/log /run /srv/mtx/ff" ]

    # recording: the default tmpfs path is not listed (/dev is not read-only), another one is, with "-"
    run env "${DEFAULT_PATHS[@]}" AUDIO_LOCAL_RECORDING=true bash -c 'source "$ISCRIPT" >/dev/null 2>&1; unit_read_write_paths "$1"' _ "$TEMPLATE"
    [ "$output" = "/etc/mediamtx /var/log /run" ]
    run env "${DEFAULT_PATHS[@]}" AUDIO_LOCAL_RECORDING=true AUDIO_RECORDING_PATH=/mnt/usb/recordings bash -c 'source "$ISCRIPT" >/dev/null 2>&1; unit_read_write_paths "$1"' _ "$TEMPLATE"
    [ "$output" = "/etc/mediamtx /var/log /run -/mnt/usb/recordings" ]
    run env "${DEFAULT_PATHS[@]}" AUDIO_LOCAL_RECORDING=false AUDIO_RECORDING_PATH=/mnt/usb/recordings bash -c 'source "$ISCRIPT" >/dev/null 2>&1; unit_read_write_paths "$1"' _ "$TEMPLATE"
    [ "$output" = "/etc/mediamtx /var/log /run" ]
    run env AUDIO_LOCAL_RECORDING=true AUDIO_RECORDING_PATH="/mnt/my usb" bash -c 'source "$ISCRIPT" >/dev/null 2>&1; unit_read_write_paths "$1"' _ "$TEMPLATE"
    [ "$status" -ne 0 ]
    run env MEDIAMTX_CONFIG_DIR="/etc/my mtx" bash -c 'source "$ISCRIPT" >/dev/null 2>&1; unit_read_write_paths "$1"' _ "$TEMPLATE"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# install: create_systemd_service
# ---------------------------------------------------------------------------

# The tools install calls, as PATH shims that only record: systemctl and logrotate
install_shims() {
    mkdir -p "$UN/shim"
    printf '#!/bin/bash\nprintf "%%s\\n" "$*" >>"$UN/systemctl.calls"\n' >"$UN/shim/systemctl"
    printf '#!/bin/bash\nexit 0\n' >"$UN/shim/logrotate"
    chmod +x "$UN/shim/systemctl" "$UN/shim/logrotate"
    mkdir -p "$UN/root/etc/logrotate.d" "$UN/root/etc/systemd/system" "$UN/root/etc/cron.d"
    export LYREBIRD_SYSROOT="$UN/root"
}

@test "install writes the unit, the monitor cron file and the logrotate file under LYREBIRD_SYSROOT, exactly what the renderers print, without asking systemd to reload [LB-11, D12]" {
    make_install
    install_shims
    run env PATH="$UN/shim:$PATH" bash -c 'source "$ISCRIPT" >/dev/null 2>&1; create_systemd_service' _
    [ "$status" -eq 0 ]
    [[ "$output" == *"Systemd service created: $UN/root/etc/systemd/system/mediamtx-audio.service"* ]]
    [[ "$output" == *"systemctl reload mediamtx-audio"* ]]
    run bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_systemd_unit' _
    [ "$output" = "$(cat "$UN/root/etc/systemd/system/mediamtx-audio.service")" ]
    run bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_monitor_cron' _
    [ "$output" = "$(cat "$UN/root/etc/cron.d/mediamtx-monitor")" ]
    grep -q "^${MEDIAMTX_LOG_FILE} {" "$UN/root/etc/logrotate.d/mediamtx"
    [ "$(stat -c %a "$UN/root/etc/systemd/system/mediamtx-audio.service")" = "644" ]
    [ "$(stat -c %a "$UN/root/etc/cron.d/mediamtx-monitor")" = "644" ]
    # no temporary file is left behind, and systemd was not asked to reload (a prefix is no live system)
    [ "$(find "$UN/root/etc/systemd/system" "$UN/root/etc/cron.d" -type f -printf '%f\n' | sort | tr '\n' ' ')" = "mediamtx-audio.service mediamtx-monitor " ]
    [ ! -e "$UN/systemctl.calls" ]
}

@test "install is repeatable and replaces the unit atomically; a value it cannot carry stops it with exit 4 and changes nothing [LB-11, X-11]" {
    make_install
    install_shims
    printf 'OLD UNIT\n' >"$UN/root/etc/systemd/system/mediamtx-audio.service"
    printf 'OLD CRON\n' >"$UN/root/etc/cron.d/mediamtx-monitor"
    run env PATH="$UN/shim:$PATH" STREAM_MODE=sideways bash -c 'source "$ISCRIPT" >/dev/null 2>&1; rc=0; create_systemd_service || rc=$?; echo "rc=$rc skip_cleanup=$SKIP_CLEANUP"' _
    [[ "$output" == *"rc=4 skip_cleanup=true" ]]
    [ "$(cat "$UN/root/etc/systemd/system/mediamtx-audio.service")" = "OLD UNIT" ]
    [ "$(cat "$UN/root/etc/cron.d/mediamtx-monitor")" = "OLD CRON" ]
    [ ! -e "$UN/root/etc/logrotate.d/mediamtx" ]
    # a name the cron file cannot carry (the unit could): also nothing is written
    run env PATH="$UN/shim:$PATH" STREAM_MODE=multiplex MULTIPLEX_STREAM_NAME='Studio Mix' bash -c 'source "$ISCRIPT" >/dev/null 2>&1; rc=0; create_systemd_service || rc=$?; echo "rc=$rc"' _
    [[ "$output" == *"rc=4" ]]
    [ "$(cat "$UN/root/etc/systemd/system/mediamtx-audio.service")" = "OLD UNIT" ]
    # a good run replaces both, twice
    run env PATH="$UN/shim:$PATH" bash -c 'source "$ISCRIPT" >/dev/null 2>&1; create_systemd_service >/dev/null 2>&1; create_systemd_service >/dev/null 2>&1; echo done' _
    [ "$output" = "done" ]
    grep -q "^\[Unit\]" "$UN/root/etc/systemd/system/mediamtx-audio.service"
    ! grep -q "OLD" "$UN/root/etc/systemd/system/mediamtx-audio.service" "$UN/root/etc/cron.d/mediamtx-monitor"
}

@test "the install command is wired: main runs check_root then create_systemd_service and passes its status on [LB-11]" {
    make_install
    install_shims
    run env PATH="$UN/shim:$PATH" bash -c '
        source "$ISCRIPT" >/dev/null 2>&1
        check_root() { :; }
        main install' _
    [ "$status" -eq 0 ]
    [ -s "$UN/root/etc/systemd/system/mediamtx-audio.service" ]
    run env PATH="$UN/shim:$PATH" STREAM_MODE=sideways bash -c '
        source "$ISCRIPT" >/dev/null 2>&1
        check_root() { :; }
        main install' _
    [ "$status" -eq 4 ]
}

# ---------------------------------------------------------------------------
# The monitor cron file (a cron `monitor` must run in the unit's stream mode)
# ---------------------------------------------------------------------------

# The NAME=value lines of a cron file (what cron puts into the job's environment)
cron_env() { grep -E '^[A-Z_][A-Z0-9_]*=' "$1"; }

@test "the cron file sets the stream mode, the filter and the multiplex name, and keeps its restart policy: only exit status 2 restarts the service [LB-11, X-11]" {
    make_install
    run env STREAM_MODE=multiplex MULTIPLEX_FILTER_TYPE=amerge MULTIPLEX_STREAM_NAME=studio_mix-2 \
        bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_monitor_cron >"$1"' _ "$UN/cron-multiplex"
    [ "$status" -eq 0 ]
    run cron_env "$UN/cron-multiplex"
    [[ "$output" == *$'\nSTREAM_MODE=multiplex'* || "$output" == "STREAM_MODE=multiplex"* ]]
    [[ "$output" == *"MULTIPLEX_FILTER_TYPE=amerge"* ]]
    [[ "$output" == *"MULTIPLEX_STREAM_NAME=studio_mix-2"* ]]
    [[ "$output" == *"CRON=1"* ]]

    run env "${DEFAULT_PATHS[@]}" bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_monitor_cron >"$1"' _ "$UN/cron-individual"
    run cron_env "$UN/cron-individual"
    [[ "$output" == *"STREAM_MODE=individual"* && "$output" == *"MULTIPLEX_FILTER_TYPE=amix"* && "$output" == *"MULTIPLEX_STREAM_NAME=all_mics"* ]]

    # the job line is the one this script always wrote: flock, the monitor, restart only on exit 2, log the rest
    local job
    job="$(grep -E '^\*/5 ' "$UN/cron-individual")"
    [ "$job" = "*/5 * * * * root flock -n /run/mediamtx-monitor.lock -c '$UN/inst/lyrebird-stream-manager.sh monitor; EXIT=\$?; if [ \$EXIT -eq 2 ]; then systemctl restart mediamtx-audio; elif [ \$EXIT -ne 0 ]; then logger -t mediamtx-monitor \"Non-critical exit code \$EXIT (no restart)\"; fi' || logger -t mediamtx-monitor \"Monitor already running or locked\"" ]
    # every line is a comment, blank, an environment assignment or the one job
    run grep -vE '^(#.*|[A-Z_][A-Z0-9_]*=[A-Za-z0-9_/:.-]*|\*/5 .*|)$' "$UN/cron-multiplex"
    [ -z "$output" ]
}

@test "the cron file carries only values that need no quoting: the name is limited to letters, digits, _ and - [LB-11, X-11]" {
    make_install
    local bad
    for bad in 'Studio Mix' 'a%b' 'a;b' 'a$b' 'a"b' "a'b" 'a=b' $'a\nSTREAM_MODE=individual'; do
        run env STREAM_MODE=multiplex MULTIPLEX_STREAM_NAME="$bad" bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_monitor_cron' _
        [ "$status" -ne 0 ]
        [[ "$output" == *"cannot carry"* ]]
        [[ "$output" != *"*/5"* ]]
    done
    run env STREAM_MODE=maybe bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_monitor_cron' _
    [ "$status" -ne 0 ]
    run env MULTIPLEX_FILTER_TYPE=join bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_monitor_cron' _
    [ "$status" -ne 0 ]
}

# The real monitor decision (monitor_streams) in the environment a cron file sets, as cron starts it
# (a clean environment plus the file's assignments). Only the processes it would spawn are
# stood in for: they record the call. Two devices, MediaMTX running, no stream running yet.
# fake_mediamtx: a live process in the MediaMTX PID file (MediaMTX "is running")
fake_mediamtx() {
    sleep 600 &
    BG_PIDS+=("$!")
    echo "$!" >"$UN/mtx.pid"
}
cron_monitor_calls() { # cron_monitor_calls CRONFILE: prints "individual:<name>" / "multiplex:<names>" lines
    local -a assigns
    mapfile -t assigns < <(cron_env "$1")
    : >"$UN/calls"
    rm -rf "$UN/ff" "$UN/cronstate"
    mkdir -p "$UN/ff"
    # the two stood-in cards are microphones: each has a capture PCM (a card without one is a
    # speaker, which the monitor skips, X-34)
    mkdir -p "$UN/asound/card1/pcm0c" "$UN/asound/card2/pcm0c"
    env -i "${assigns[@]}" HOME=/root ISCRIPT="$ISCRIPT" UN="$UN" ASOUND_PROC_ROOT="$UN/asound" MEDIAMTX_PID_FILE="$UN/mtx.pid" MEDIAMTX_FFMPEG_DIR="$UN/ff" \
        MEDIAMTX_CONFIG_DIR="$UN/cfg" MEDIAMTX_LOG_FILE="$UN/sm.log" STREAM_MANAGER_LOG_FILE="$UN/sm.log" MEDIAMTX_LOCK_FILE="$UN/run.lock" \
        CRON_RESTART_STATE_DIR="$UN/cronstate" DEEP_HEALTH_STATE_DIR="$UN/deep" MEDIAMTX_HOST=cron.invalid \
        bash -c '
        source "$ISCRIPT" >/dev/null 2>&1
        detect_audio_devices() { printf "%s\n" "Mic_A:1" "Mic_B:2"; }
        check_alsa_device_available() { return 0; }
        deep_stream_unhealthy() { return 1; }
        start_ffmpeg_stream() { echo "individual:$1" >>"$UN/calls"; return 0; }
        start_ffmpeg_multiplex_stream() { echo "multiplex:$*" >>"$UN/calls"; return 0; }
        monitor_streams || true' >/dev/null 2>&1
    cat "$UN/calls"
}

@test "a cron monitor on a multiplex node restarts the multiplex stream and never starts per-device streams; on an individual node the reverse [LB-11, X-11]" {
    make_install
    fake_mediamtx
    run env STREAM_MODE=multiplex MULTIPLEX_FILTER_TYPE=amix MULTIPLEX_STREAM_NAME=studio \
        bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_monitor_cron >"$1"' _ "$UN/cron-multiplex"
    [ "$status" -eq 0 ]
    run cron_monitor_calls "$UN/cron-multiplex"
    [ "$status" -eq 0 ]
    [ "$output" = "multiplex:Mic_A:1 Mic_B:2" ]

    run env "${DEFAULT_PATHS[@]}" bash -c 'source "$ISCRIPT" >/dev/null 2>&1; render_monitor_cron >"$1"' _ "$UN/cron-individual"
    run cron_monitor_calls "$UN/cron-individual"
    [ "$status" -eq 0 ]
    [[ "$output" == *"individual:Mic_A"* && "$output" == *"individual:Mic_B"* ]]
    [[ "$output" != *"multiplex:"* ]]

    # the control: the cron file as install wrote it before (no mode in it) on the same multiplex node
    grep -vE '^(STREAM_MODE|MULTIPLEX_FILTER_TYPE|MULTIPLEX_STREAM_NAME)=' "$UN/cron-multiplex" >"$UN/cron-old"
    run cron_monitor_calls "$UN/cron-old"
    [[ "$output" == *"individual:Mic_A"* && "$output" == *"individual:Mic_B"* ]]
    [[ "$output" != *"multiplex:"* ]]
}

# ---------------------------------------------------------------------------
# The unit install writes and the updater
# ---------------------------------------------------------------------------

@test "the unit install writes is one the updater sees as unmodified: no customizations are detected, and a real one still is [LB-11]" {
    make_install
    install_shims
    run env PATH="$UN/shim:$PATH" bash -c 'source "$ISCRIPT" >/dev/null 2>&1; create_systemd_service' _
    [ "$status" -eq 0 ]
    local unit="$UN/root/etc/systemd/system/mediamtx-audio.service"
    run env LYREBIRD_UPDATER_SYSROOT="$UN/root" LYREBIRD_UPDATER_STATE_DIR="$UN/updater-state" bash -c '
        source "$1" >/dev/null 2>&1
        SERVICE_CUSTOM_ENV=()
        SERVICE_STATE[has_customizations]=false
        detect_service_customizations
        echo "customized=${SERVICE_STATE[has_customizations]} count=${#SERVICE_CUSTOM_ENV[@]}"' _ "$PROJECT_ROOT/lyrebird-updater.sh"
    [ "$output" = "customized=false count=0" ]
    # an operator's own variable is still seen
    sed -i 's/^Environment="USB_STABILIZATION_DELAY=10"/Environment="USB_STABILIZATION_DELAY=25"/' "$unit"
    run env LYREBIRD_UPDATER_SYSROOT="$UN/root" LYREBIRD_UPDATER_STATE_DIR="$UN/updater-state" bash -c '
        source "$1" >/dev/null 2>&1
        SERVICE_CUSTOM_ENV=()
        SERVICE_STATE[has_customizations]=false
        detect_service_customizations
        echo "customized=${SERVICE_STATE[has_customizations]} count=${#SERVICE_CUSTOM_ENV[@]}"' _ "$PROJECT_ROOT/lyrebird-updater.sh"
    [ "$output" = "customized=true count=1" ]
}

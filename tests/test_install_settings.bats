#!/usr/bin/env bats
# What `install` carries into the unit and the monitor's cron file, and what the updater's
# service reinstall keeps (register: X-52, X-58).
#
# The unit (systemd) and the cron file (cron) start the manager as processes of their own:
# they do not inherit the environment `install` ran in, and `install` writes the whole of
# both files every time.
#   X-58: the ports, the listen addresses, the authentication mode and the endpoint
#         settings given to `install` were not written into either file. A node installed
#         with RTSP_AUTH_MODE=local-only-publish and a private port ran on the defaults
#         under systemd, and the cron monitor, which brings a MediaMTX that died back and
#         renders its configuration again, rewrote the managed file with the defaults:
#         authentication gone, ports back on 8554/9997/9998.
#   X-52: the updater reinstalls the service by running `install` with no settings: the
#         unit got its Environment= lines merged back, the cron file was rewritten with
#         STREAM_MODE=individual, so a multiplex node monitored in individual mode.
# The real manager and the real updater run; systemd-analyze is the judge of the unit.

load scratch_tmpdir
load updater_helper

setup_file() {
    updater_template_build
}

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    UN="$TEST_SCRATCH/un"
    mkdir -p "$UN"
    export PROJECT_ROOT UN
    export MEDIAMTX_LOG_FILE="$UN/sm.log" STREAM_MANAGER_LOG_FILE="$UN/sm.log" MEDIAMTX_CONFIG_DIR="$UN/cfg" MEDIAMTX_FFMPEG_DIR="$UN/ff"
    export MEDIAMTX_PID_FILE="$UN/mtx.pid" MEDIAMTX_LOCK_FILE="$UN/run.lock"
    # none of the carried settings comes from the machine the suite runs on
    unset RTSP_AUTH_MODE RTSP_USERS_FILE MEDIAMTX_HOST MEDIAMTX_BINARY MEDIAMTX_RTSP_PORT MEDIAMTX_API_PORT \
        MEDIAMTX_METRICS_PORT MEDIAMTX_API_BIND MEDIAMTX_METRICS_BIND STREAM_MODE MULTIPLEX_FILTER_TYPE MULTIPLEX_STREAM_NAME
}

teardown() {
    scratch_teardown
}

# A real copy of the manager (script, library, unit template) in DIR. Without root the copy
# skips the root check, the one line of `install` that cannot be satisfied: nothing else
# differs from the script under test.
real_manager() {
    local dir="$1"
    mkdir -p "$dir/config"
    cp "$PROJECT_ROOT/lyrebird-stream-manager.sh" "$PROJECT_ROOT/lyrebird-common.sh" "$dir/"
    cp "$PROJECT_ROOT/config/mediamtx-audio.service" "$dir/config/"
    if [[ "$EUID" -ne 0 ]]; then
        sed -i 's/if \[\[ \${EUID} -ne 0 \]\]; then/if false; then/' "$dir/lyrebird-stream-manager.sh"
        grep -q 'if false; then' "$dir/lyrebird-stream-manager.sh"
    fi
    chmod +x "$dir/lyrebird-stream-manager.sh"
}

# the tools `install` calls, and the system root its files go under
install_root() {
    mkdir -p "$UN/shim" "$UN/root/etc/systemd/system" "$UN/root/etc/cron.d"
    # no unit is active (the manager refuses to start while the standalone mediamtx.service is)
    printf '#!/bin/bash\ncase "$1" in is-active | is-enabled) exit 3 ;; *) exit 0 ;; esac\n' >"$UN/shim/systemctl"
    chmod +x "$UN/shim/systemctl"
    mkdir -p "$UN/cfg"
    export LYREBIRD_SYSROOT="$UN/root"
}

UNIT_REL=etc/systemd/system/mediamtx-audio.service
CRON_REL=etc/cron.d/mediamtx-monitor

# The NAME=value lines of a cron file (what cron puts into the job's environment)
cron_env() { grep -E '^[A-Z_][A-Z0-9_]*=' "$1"; }

# the nine settings `install` carries, at non-default values (private ports)
carried_values() {
    printf '%s\n' MEDIAMTX_RTSP_PORT=41554 MEDIAMTX_API_PORT=41997 MEDIAMTX_METRICS_PORT=41998 \
        MEDIAMTX_API_BIND=127.0.0.2 MEDIAMTX_METRICS_BIND= RTSP_AUTH_MODE=local-only-publish \
        "RTSP_USERS_FILE=$UN/rtsp-users.conf" MEDIAMTX_HOST=127.0.0.1 "MEDIAMTX_BINARY=$UN/no-mediamtx"
}

# install with the settings in $@ (NAME=value words): the real script's own `install` command
run_install() {
    run env PATH="$UN/shim:$PATH" "$@" bash "$UN/inst/lyrebird-stream-manager.sh" install </dev/null
}

# ---------------------------------------------------------------------------
# X-58: what install writes
# ---------------------------------------------------------------------------

@test "install writes every listener, authentication and endpoint setting that differs from its default into the unit and the cron file [X-58]" {
    real_manager "$UN/inst"
    install_root
    local -a settings
    mapfile -t settings < <(carried_values)
    run_install "${settings[@]}"
    [ "$status" -eq 0 ] || {
        echo "$output"
        false
    }
    local unit="$UN/root/$UNIT_REL" cron="$UN/root/$CRON_REL" s name value
    for s in "${settings[@]}"; do
        name="${s%%=*}"
        value="${s#*=}"
        grep -qxF "Environment=\"${name}=${value}\"" "$unit" || {
            echo "unit lacks ${name}=${value}"
            false
        }
        grep -qxF "${name}=${value}" "$cron" || {
            echo "cron file lacks ${name}=${value}"
            false
        }
    done
    # each once, after the template's own Environment= lines, and nothing else changed shape
    [ "$(grep -c '^Environment="MEDIAMTX_RTSP_PORT=' "$unit")" -eq 1 ]
    [ "$(grep -n '^Environment=' "$unit" | tail -n 1 | cut -d: -f1)" -eq "$(grep -n '^Environment="MEDIAMTX_BINARY=' "$unit" | cut -d: -f1)" ]
    # the cron file stays what cron can read: comments, assignments of plain values, the one job
    run grep -vE '^(#.*|[A-Z_][A-Z0-9_]*=[A-Za-z0-9_/:.+-]*|\*/5 .*|)$' "$cron"
    [ -z "$output" ]
    if command -v systemd-analyze >/dev/null 2>&1; then
        cp "$unit" "$UN/mediamtx-audio.service"
        run bash -c 'systemd-analyze verify "$1" 2>&1 | grep -v "is not executable: No such file or directory" || true' _ "$UN/mediamtx-audio.service"
        [ -z "$output" ] || {
            echo "$output"
            false
        }
    fi
}

@test "with none of the settings given, or each given at its default, the unit and the cron file carry none of them [X-58]" {
    real_manager "$UN/inst"
    install_root
    run_install
    [ "$status" -eq 0 ]
    local name
    for name in MEDIAMTX_RTSP_PORT MEDIAMTX_API_PORT MEDIAMTX_METRICS_PORT MEDIAMTX_API_BIND MEDIAMTX_METRICS_BIND \
        RTSP_AUTH_MODE RTSP_USERS_FILE MEDIAMTX_HOST MEDIAMTX_BINARY; do
        ! grep -q "${name}" "$UN/root/$UNIT_REL" || {
            echo "unit mentions ${name}"
            false
        }
        ! grep -vE '^#' "$UN/root/$CRON_REL" | grep -q "${name}" || {
            echo "cron file mentions ${name}"
            false
        }
    done
    cp "$UN/root/$UNIT_REL" "$UN/plain.service"
    cp "$UN/root/$CRON_REL" "$UN/plain.cron"
    # the same settings, spelled as the defaults: the same two files
    run_install MEDIAMTX_RTSP_PORT=8554 MEDIAMTX_API_PORT=9997 MEDIAMTX_METRICS_PORT=9998 MEDIAMTX_API_BIND=127.0.0.1 \
        MEDIAMTX_METRICS_BIND=127.0.0.1 RTSP_AUTH_MODE=open MEDIAMTX_HOST=localhost MEDIAMTX_BINARY=/usr/local/bin/mediamtx \
        "RTSP_USERS_FILE=$UN/cfg/rtsp-users.conf"
    [ "$status" -eq 0 ]
    cmp "$UN/root/$UNIT_REL" "$UN/plain.service"
    cmp "$UN/root/$CRON_REL" "$UN/plain.cron"
}

@test "a value the unit or the cron file cannot carry stops install with exit 4 and changes nothing [X-58]" {
    real_manager "$UN/inst"
    install_root
    run_install RTSP_AUTH_MODE=local-only-publish MEDIAMTX_RTSP_PORT=41554
    [ "$status" -eq 0 ]
    cp "$UN/root/$UNIT_REL" "$UN/before.service"
    cp "$UN/root/$CRON_REL" "$UN/before.cron"
    local bad
    for bad in $'MEDIAMTX_API_BIND=1.2.3.4"\nExecStartPre=/bin/touch /tmp/pwned' 'MEDIAMTX_API_BIND=1.2.3.999' \
        'MEDIAMTX_METRICS_BIND=localhost' 'RTSP_AUTH_MODE=banana' $'RTSP_AUTH_MODE=local-only-publish\nX=1' \
        'RTSP_USERS_FILE=/etc/my users' 'MEDIAMTX_BINARY=/opt/a;b' 'MEDIAMTX_HOST=a b' $'MEDIAMTX_HOST=h\n[Install]' \
        'MEDIAMTX_RTSP_PORT=abc' 'MEDIAMTX_API_PORT=70000' 'MEDIAMTX_METRICS_PORT=0'; do
        run_install "$bad"
        [ "$status" -eq 4 ] || {
            echo "[$bad] exit $status: $output"
            false
        }
        cmp "$UN/root/$UNIT_REL" "$UN/before.service"
        cmp "$UN/root/$CRON_REL" "$UN/before.cron"
    done
}

@test "install writes what it is given: a plain install after a multiplex one is the individual mode again [X-52]" {
    # The decision: `install` is a command that writes a configuration, so running it with
    # nothing writes the defaults (the help says to run it again with the options to change
    # the mode, and a sticky mode could never be switched back by running it plain). The one
    # who knows an existing node is being upgraded is the updater, which passes the node's
    # settings (below).
    real_manager "$UN/inst"
    install_root
    run_install STREAM_MODE=multiplex MULTIPLEX_STREAM_NAME=studio
    [ "$status" -eq 0 ]
    grep -qx 'STREAM_MODE=multiplex' "$UN/root/$CRON_REL"
    run_install
    [ "$status" -eq 0 ]
    grep -qx 'STREAM_MODE=individual' "$UN/root/$CRON_REL"
    grep -qxF 'Environment="STREAM_MODE=individual"' "$UN/root/$UNIT_REL"
}

@test "the updater passes to install exactly the settings the manager carries [X-52, X-58]" {
    run env bash -c '
        source "$1/lyrebird-stream-manager.sh" >/dev/null 2>&1
        printf "%s\n" STREAM_MODE MULTIPLEX_FILTER_TYPE MULTIPLEX_STREAM_NAME "${UNIT_CARRIED_SETTINGS[@]}" | sort' _ "$PROJECT_ROOT"
    local manager_list="$output"
    run env LYREBIRD_UPDATER_STATE_DIR="$UN/updater-state" bash -c '
        source "$1/lyrebird-updater.sh" >/dev/null 2>&1
        printf "%s\n" "${INSTALL_SETTING_VARS[@]}" | sort' _ "$PROJECT_ROOT"
    [ -n "$manager_list" ]
    [ "$output" = "$manager_list" ]
}

# ---------------------------------------------------------------------------
# X-58: the cron monitor that brings MediaMTX back (the real monitor code path)
# ---------------------------------------------------------------------------

@test "a cron monitor that finds MediaMTX gone renders the configuration with the authentication and the ports the node was installed with [X-58]" {
    real_manager "$UN/inst"
    install_root
    local -a settings
    mapfile -t settings < <(carried_values)
    # the node as the operator set it up: install, then the start that wrote the managed file
    run_install "${settings[@]}"
    [ "$status" -eq 0 ]
    run env "${settings[@]}" PATH="$UN/shim:$PATH" bash -c '
        source "$UN/inst/lyrebird-stream-manager.sh" >/dev/null 2>&1
        generate_mediamtx_config >/dev/null 2>&1; echo "generate rc=$?"'
    [[ "$output" == *"generate rc=0"* ]]
    grep -q '^authInternalUsers:' "$UN/cfg/mediamtx.yml"
    grep -qx 'rtspAddress: :41554' "$UN/cfg/mediamtx.yml"
    cp "$UN/cfg/mediamtx.yml" "$UN/cfg/before.yml"

    # MediaMTX was killed (kill -9): a PID file that names a dead process, and a node that is
    # meant to run. cron starts the monitor with ONLY its file's assignments (and the
    # directories this machine's default paths are replaced by)
    sleep 0.1 &
    local dead=$!
    wait "$dead"
    echo "$dead" >"$UN/mtx.pid"
    mkdir -p "$UN/state"
    echo "1 1 start" >"$UN/state/desired-running"
    local -a assigns
    mapfile -t assigns < <(cron_env "$UN/root/$CRON_REL")
    run env -i "${assigns[@]}" HOME=/root PATH="$UN/shim:$PATH" ISCRIPT="$UN/inst/lyrebird-stream-manager.sh" UN="$UN" \
        ASOUND_PROC_ROOT="$UN/asound" MEDIAMTX_PID_FILE="$UN/mtx.pid" MEDIAMTX_FFMPEG_DIR="$UN/ff" MEDIAMTX_CONFIG_DIR="$UN/cfg" \
        MEDIAMTX_LOG_FILE="$UN/sm.log" STREAM_MANAGER_LOG_FILE="$UN/sm.log" MEDIAMTX_LOCK_FILE="$UN/run.lock" \
        LYREBIRD_STATE_DIR="$UN/state" CRON_RESTART_STATE_DIR="$UN/cronstate" DEEP_HEALTH_STATE_DIR="$UN/deep" \
        USB_STABILIZATION_DELAY=0 CRON=1 \
        bash -c '
            source "$ISCRIPT" >/dev/null 2>&1
            wait_for_usb_stabilization() { return 0; }
            detect_audio_devices() { :; }
            spawn_detached() { echo "spawn: $*" >>"$UN/spawned"; return 1; }
            monitor_streams
            echo "monitor rc=$?"'
    # the monitor really took the restart path (the configuration is rendered on it)
    grep -q 'starting it again' "$UN/sm.log"
    ! grep -q 'Refusing to start' "$UN/sm.log"
    # and what it rendered is what the node was installed with
    grep -q '^authInternalUsers:' "$UN/cfg/mediamtx.yml" || {
        echo "the restart's configuration has no authentication block:"
        cat "$UN/cfg/mediamtx.yml"
        false
    }
    grep -qx 'rtspAddress: :41554' "$UN/cfg/mediamtx.yml"
    grep -qx 'apiAddress: 127.0.0.2:41997' "$UN/cfg/mediamtx.yml"
    grep -qx 'metricsAddress: :41998' "$UN/cfg/mediamtx.yml"
    cmp "$UN/cfg/mediamtx.yml" "$UN/cfg/before.yml"
}

# ---------------------------------------------------------------------------
# X-52 and X-58: the updater's reinstall of the service, through its own code path
# ---------------------------------------------------------------------------

# A tag v1.2.1 of the node's origin whose stream manager is the real one (v1.2.0's is a
# stand-in), so that updating to it changes the manager and the updater reinstalls the service
make_real_manager_tag() {
    git -C "$WORK" checkout -q v1.2.0
    real_manager "$WORK"
    git -C "$WORK" add -A
    git -C "$WORK" commit -qm "v1.2.1 (the real stream manager)"
    git -C "$WORK" tag v1.2.1
    git -C "$WORK" push -q origin v1.2.1 2>/dev/null
    git -C "$WORK" checkout -q main
    git -C "$REPO" fetch -q origin --tags
}

# A node at v1.1.0 whose unit and cron file were written by `install` with the settings in $@,
# in the updater's sysroot, then updated to v1.2.1 by the updater (menu choice 3)
update_node_with_settings() {
    updater_node_setup
    updater_checkout v1.1.0
    make_real_manager_tag
    updater_install_fake_service running
    real_manager "$UN/old"
    export LYREBIRD_SYSROOT="$SYSROOT"
    run env PATH="$SHIMS:$PATH" "$@" bash "$UN/old/lyrebird-stream-manager.sh" install </dev/null
    [ "$status" -eq 0 ] || {
        echo "$output"
        false
    }
    cp "$SYSROOT/$UNIT_REL" "$UN/unit.before"
    cp "$SYSROOT/$CRON_REL" "$UN/cron.before"
    # a unit with settings in it has customizations the updater asks about
    if (($# > 0)); then
        updater_stdin 3 v1.2.1 y "" q
    else
        updater_stdin 3 v1.2.1 "" q
    fi
    updater_run
    [ "$status" -eq 0 ] || {
        echo "$output"
        false
    }
    [ "$(updater_head)" = "v1.2.1" ]
    grep -q 'systemctl start mediamtx-audio' "$FAKE_SVC_LOG"
}

@test "the updater's service reinstall keeps the stream mode, the filter and the name in the cron file as well as in the unit [X-52]" {
    update_node_with_settings STREAM_MODE=multiplex MULTIPLEX_FILTER_TYPE=amerge MULTIPLEX_STREAM_NAME=studio_mix
    grep -qx 'STREAM_MODE=multiplex' "$SYSROOT/$CRON_REL"
    grep -qx 'MULTIPLEX_FILTER_TYPE=amerge' "$SYSROOT/$CRON_REL"
    grep -qx 'MULTIPLEX_STREAM_NAME=studio_mix' "$SYSROOT/$CRON_REL"
    # the unit: one assignment of each, the new ExecStart (the reinstall really happened)
    [ "$(grep -c '^Environment="STREAM_MODE=' "$SYSROOT/$UNIT_REL")" -eq 1 ]
    grep -qxF 'Environment="STREAM_MODE=multiplex"' "$SYSROOT/$UNIT_REL"
    grep -qxF 'Environment="MULTIPLEX_FILTER_TYPE=amerge"' "$SYSROOT/$UNIT_REL"
    grep -qxF 'Environment="MULTIPLEX_STREAM_NAME=studio_mix"' "$SYSROOT/$UNIT_REL"
    grep -qxF "ExecStart=$REPO/lyrebird-stream-manager.sh start" "$SYSROOT/$UNIT_REL"
    # nothing else about the monitor's environment changed
    run diff <(cron_env "$UN/cron.before") <(cron_env "$SYSROOT/$CRON_REL")
    [ "$status" -eq 0 ] || {
        echo "$output"
        false
    }
}

@test "the updater's service reinstall keeps the ports, the listen addresses, the authentication and the endpoint settings in the unit and the cron file [X-58, X-52]" {
    local -a settings
    mapfile -t settings < <(carried_values)
    update_node_with_settings STREAM_MODE=multiplex "${settings[@]}"
    local s name value
    for s in "${settings[@]}"; do
        name="${s%%=*}"
        value="${s#*=}"
        [ "$(grep -cxF "Environment=\"${name}=${value}\"" "$SYSROOT/$UNIT_REL")" -eq 1 ] || {
            echo "unit: ${name}=${value} is not there exactly once"
            grep '^Environment=' "$SYSROOT/$UNIT_REL"
            false
        }
        grep -qxF "${name}=${value}" "$SYSROOT/$CRON_REL" || {
            echo "cron file lacks ${name}=${value}"
            false
        }
    done
    # the cron environment is the one the updater found
    run diff <(cron_env "$UN/cron.before") <(cron_env "$SYSROOT/$CRON_REL")
    [ "$status" -eq 0 ] || {
        echo "$output"
        false
    }
}

@test "the reinstall still restores an operator's own variable once, and takes the settings from the cron file for what the unit does not set [X-52]" {
    updater_node_setup
    updater_checkout v1.1.0
    make_real_manager_tag
    updater_install_fake_service running
    real_manager "$UN/old"
    export LYREBIRD_SYSROOT="$SYSROOT"
    run env PATH="$SHIMS:$PATH" STREAM_MODE=multiplex MEDIAMTX_RTSP_PORT=41554 bash "$UN/old/lyrebird-stream-manager.sh" install </dev/null
    [ "$status" -eq 0 ]
    # an operator's own variable in the unit, and a unit written before `install` carried the
    # stream mode: only the cron file says multiplex
    sed -i 's/^Environment="USB_STABILIZATION_DELAY=10"/Environment="USB_STABILIZATION_DELAY=25"/; /^Environment="STREAM_MODE=/d; /^Environment="MEDIAMTX_RTSP_PORT=/d' "$SYSROOT/$UNIT_REL"
    ! grep -q 'STREAM_MODE=multiplex' "$SYSROOT/$UNIT_REL"
    updater_stdin 3 v1.2.1 y "" q
    updater_run
    [ "$status" -eq 0 ] || {
        echo "$output"
        false
    }
    [ "$(grep -c '^Environment="USB_STABILIZATION_DELAY=' "$SYSROOT/$UNIT_REL")" -eq 2 ]
    grep -qxF 'Environment="USB_STABILIZATION_DELAY=25"' "$SYSROOT/$UNIT_REL"
    grep -qxF 'Environment="STREAM_MODE=multiplex"' "$SYSROOT/$UNIT_REL"
    grep -qxF 'Environment="MEDIAMTX_RTSP_PORT=41554"' "$SYSROOT/$UNIT_REL"
    grep -qx 'STREAM_MODE=multiplex' "$SYSROOT/$CRON_REL"
    grep -qx 'MEDIAMTX_RTSP_PORT=41554' "$SYSROOT/$CRON_REL"
}

@test "a node that sets none of the settings is reinstalled with none: its unit and cron file are what a plain install writes [X-52]" {
    update_node_with_settings
    ! grep -q 'MEDIAMTX_RTSP_PORT\|RTSP_AUTH_MODE' "$SYSROOT/$UNIT_REL"
    grep -qx 'STREAM_MODE=individual' "$SYSROOT/$CRON_REL"
    run diff <(cron_env "$UN/cron.before") <(cron_env "$SYSROOT/$CRON_REL")
    [ "$status" -eq 0 ]
}

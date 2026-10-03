#!/usr/bin/env bash
# lyrebird-soak.sh - soak test for a LyreBirdAudio node
#
# Samples the node every SOAK_INTERVAL seconds for weeks, optionally injects
# faults on a seeded schedule, and reports whether the node held up:
#   - every mapped microphone keeps its name (by its USB path, not its order);
#   - every stream stays published and its byte counter keeps moving;
#   - every injected fault is recovered from within a deadline;
#   - no reboot happens that the harness did not cause;
#   - disk, inodes and memory do not trend toward exhaustion.
#
# Commands:
#   init [--force]   record the baseline (mapped names, streams, services)
#   run              sample (and inject faults) until stopped; meant for systemd
#   sample           take one sample and print it
#   fault KIND       inject one fault now and measure recovery (service stopped)
#   restore          undo any fault still in effect
#   status           show the latest sample and the active fault
#   report [DIR]     analyse a run; exit 0 = PASS, 1 = FAIL
#
# Faults (SOAK_FAULTS, comma-separated; none by default):
#   kill-ffmpeg      SIGKILL one stream's ffmpeg
#   kill-mediamtx    SIGKILL MediaMTX
#   kill-manager     SIGKILL every process of the stream manager service
#   restart-udev     restart systemd-udevd
#   udev-trigger     udevadm trigger --action=change on sound devices
#   usb-replug       logically unplug one mapped device (sysfs authorized=0) or
#                    power-cycle its hub port (SOAK_USB_METHOD=uhubctl)
#   net-down         take SOAK_NET_IFACE down for SOAK_NET_DOWN_SECONDS
#   disk-fill        fill SOAK_DISK_PATH's filesystem to SOAK_DISK_FILL_PERCENT
#   clock-jump       step the wall clock by SOAK_CLOCK_JUMP_SECONDS
#   reboot           clean reboot
#   hard-reset       immediate reboot without sync or unmount (sysrq b)
# Every fault with a duration schedules its own undo as a systemd timer before
# it starts, so the node recovers even if this script dies mid-fault.
#
# Configuration: /etc/lyrebird-soak.conf (KEY=value lines; see
# tools/soak/README.md), overridden by environment variables.
#
# Exit codes: 0 ok/PASS, 1 FAIL or runtime error, 2 usage, 3 not root,
# 4 missing dependency, 5 node not healthy at init.

if [[ "$(uname -s 2>/dev/null)" != Linux ]]; then
    echo "lyrebird-soak.sh: Linux only" >&2
    exit 4
fi
if [[ -z "${BASH_VERSINFO:-}" ]] || ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2))); then
    echo "lyrebird-soak.sh: bash 4.2 or later required" >&2
    exit 4
fi

set -euo pipefail
export LC_ALL=C

readonly SOAK_VERSION="1.0.0"
readonly E_FAIL=1 E_USAGE=2 E_ROOT=3 E_DEP=4 E_UNHEALTHY=5

readonly ALL_FAULTS="kill-ffmpeg kill-mediamtx kill-manager restart-udev udev-trigger usb-replug net-down disk-fill clock-jump reboot hard-reset"
readonly FILL_NAME=".lyrebird-soak-fill"
readonly SAMPLE_COLUMNS="wall uptime boot elapsed healthy fault problems api_ok streams_live streams_total cards_ok cards_total mtx_pid mtx_rss_kb mtx_fds ffmpeg_n ffmpeg_rss_kb mem_avail_kb disk_pct inode_pct log_kb zombies temp_mc throttled svc_restarts ntp clock_off"

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------

# Keys accepted from the config file, with the pattern their value must match.
declare -A CONFIG_KEYS=(
    [SOAK_DIR]='^/[A-Za-z0-9._/-]+$'
    [SOAK_INTERVAL]='^[1-9][0-9]*$'
    [SOAK_STALL_SAMPLES]='^[1-9][0-9]*$'
    [SOAK_API_URL]='^https?://[][A-Za-z0-9.:-]+$'
    [SOAK_SERVICES]='^[A-Za-z0-9@._ -]*$'
    [SOAK_STREAMS]='^[A-Za-z0-9_ -]*$'
    [SOAK_RULES_FILE]='^/[A-Za-z0-9._/-]+$'
    [SOAK_FAULTS]='^[a-z, -]*$'
    [SOAK_SEED]='^[0-9]+$'
    [SOAK_WARMUP]='^[0-9]+$'
    [SOAK_FAULT_MIN_GAP]='^[1-9][0-9]*$'
    [SOAK_FAULT_MAX_GAP]='^[1-9][0-9]*$'
    [SOAK_RECOVERY_DEADLINE]='^[1-9][0-9]*$'
    [SOAK_REBOOT_DEADLINE]='^[1-9][0-9]*$'
    [SOAK_USB_METHOD]='^(authorized|uhubctl)$'
    [SOAK_USB_OFF_SECONDS]='^[1-9][0-9]*$'
    [SOAK_NET_IFACE]='^[A-Za-z0-9._-]*$'
    [SOAK_NET_DOWN_SECONDS]='^[1-9][0-9]*$'
    [SOAK_DISK_PATH]='^/[A-Za-z0-9._/-]*$'
    [SOAK_DISK_FILL_PERCENT]='^[1-9][0-9]?$'
    [SOAK_DISK_FILL_SECONDS]='^[1-9][0-9]*$'
    [SOAK_DISK_MIN_FREE_MB]='^[0-9]+$'
    [SOAK_CLOCK_JUMP_SECONDS]='^-?[1-9][0-9]*$'
    [SOAK_CLOCK_JUMP_HOLD]='^[1-9][0-9]*$'
    [SOAK_LOG_DIR]='^/[A-Za-z0-9._/-]+$'
    [SOAK_EXHAUSTION_DAYS]='^[1-9][0-9]*$'
    [SOAK_DRY_RUN]='^(0|1)$'
)

die() {
    local code="$1"
    shift
    printf 'lyrebird-soak: %s\n' "$*" >&2
    exit "$code"
}

load_config() {
    local file="${SOAK_CONFIG:-/etc/lyrebird-soak.conf}" line key value n=0
    if [[ -f "$file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            n=$((n + 1))
            [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
            [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || die "$E_USAGE" "$file:$n: expected KEY=value"
            key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
            value="${value#\"}" value="${value%\"}"
            [[ -n "${CONFIG_KEYS[$key]+set}" ]] || die "$E_USAGE" "$file:$n: unknown key $key"
            # The environment wins over the file.
            [[ -n "${!key+set}" ]] || printf -v "$key" '%s' "$value"
        done <"$file"
    fi

    : "${SOAK_ROOT:=}"
    : "${SOAK_DIR:=/var/lib/lyrebird-soak}"
    : "${SOAK_INTERVAL:=10}"
    : "${SOAK_STALL_SAMPLES:=3}"
    : "${SOAK_API_URL:=http://127.0.0.1:9997}"
    : "${SOAK_SERVICES:=}"
    : "${SOAK_STREAMS:=}"
    : "${SOAK_RULES_FILE:=/etc/udev/rules.d/99-usb-soundcards.rules}"
    : "${SOAK_FAULTS:=}"
    : "${SOAK_SEED:=}"
    : "${SOAK_WARMUP:=600}"
    : "${SOAK_FAULT_MIN_GAP:=1800}"
    : "${SOAK_FAULT_MAX_GAP:=7200}"
    : "${SOAK_RECOVERY_DEADLINE:=360}"
    : "${SOAK_REBOOT_DEADLINE:=300}"
    : "${SOAK_USB_METHOD:=authorized}"
    : "${SOAK_USB_OFF_SECONDS:=10}"
    : "${SOAK_NET_IFACE:=}"
    : "${SOAK_NET_DOWN_SECONDS:=60}"
    : "${SOAK_DISK_PATH:=}"
    : "${SOAK_DISK_FILL_PERCENT:=97}"
    : "${SOAK_DISK_FILL_SECONDS:=600}"
    : "${SOAK_DISK_MIN_FREE_MB:=64}"
    : "${SOAK_CLOCK_JUMP_SECONDS:=3600}"
    : "${SOAK_CLOCK_JUMP_HOLD:=300}"
    : "${SOAK_LOG_DIR:=/var/log}"
    : "${SOAK_EXHAUSTION_DAYS:=30}"
    : "${SOAK_DRY_RUN:=0}"

    for key in "${!CONFIG_KEYS[@]}"; do
        value="${!key}"
        [[ -z "$value" || "$value" =~ ${CONFIG_KEYS[$key]} ]] || die "$E_USAGE" "invalid $key: '$value'"
    done
    ((SOAK_FAULT_MAX_GAP >= SOAK_FAULT_MIN_GAP)) || die "$E_USAGE" "SOAK_FAULT_MAX_GAP < SOAK_FAULT_MIN_GAP"
    if [[ -z "$SOAK_DISK_PATH" ]]; then
        SOAK_DISK_PATH=/
        [[ -d "$SOAK_ROOT/var/lib/mediamtx-ffmpeg" ]] && SOAK_DISK_PATH=/var/lib/mediamtx-ffmpeg
    fi
    local f
    for f in ${SOAK_FAULTS//,/ }; do
        [[ " $ALL_FAULTS " == *" $f "* ]] || die "$E_USAGE" "unknown fault '$f' (known: $ALL_FAULTS)"
    done

    SYS="$SOAK_ROOT/sys"
    PROC="$SOAK_ROOT/proc"
    SAMPLES="$SOAK_DIR/samples.tsv"
    EVENTS="$SOAK_DIR/events.tsv"
    STATE="$SOAK_DIR/state"
    BASELINE="$SOAK_DIR/baseline"
    STREAMSTATE="$SOAK_DIR/streams.state"
    RESTORE_DIR="$SOAK_DIR/restore.d"
}

need() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "$E_DEP" "missing command: $c"
    done
}

require_root() {
    [[ -n "$SOAK_ROOT" || "$(id -u)" -eq 0 ]] || die "$E_ROOT" "must run as root"
}

# ----------------------------------------------------------------------------
# State (key=value file, rewritten atomically)
# ----------------------------------------------------------------------------

declare -A ST=()

state_load() {
    ST=()
    local line
    [[ -f "$STATE" ]] || return 0
    while IFS= read -r line; do
        [[ "$line" =~ ^([a-z_]+)=(.*)$ ]] && ST[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
    done <"$STATE"
}

state_save() {
    local k tmp="$STATE.tmp"
    for k in "${!ST[@]}"; do
        printf '%s=%s\n' "$k" "${ST[$k]}"
    done | sort >"$tmp"
    mv -f "$tmp" "$STATE"
}

st() { printf '%s' "${ST[$1]:-${2:-}}"; }

# ----------------------------------------------------------------------------
# Clocks and events
# ----------------------------------------------------------------------------

uptime_s() {
    local u
    read -r u _ <"$PROC/uptime"
    printf '%s' "${u%%.*}"
}

boot_id() {
    local b
    read -r b <"$PROC/sys/kernel/random/boot_id"
    printf '%s' "$b"
}

wall_s() { date +%s; }

# event NAME DETAIL...
event() {
    local name="$1"
    shift
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(wall_s)" "$(uptime_s)" "$(boot_id)" "${ST[elapsed]:-0}" "$name" "$*" >>"$EVENTS"
    printf '%s %s %s\n' "$(date '+%F %T')" "$name" "$*" >&2
}

# Deterministic pseudo-random number in [0, 2^32) from the seed and a label.
rand() {
    local v
    v=$(printf '%s:%s' "${ST[seed]:-0}" "$1" | cksum)
    printf '%s' "${v%% *}"
}

# ----------------------------------------------------------------------------
# Observations
# ----------------------------------------------------------------------------

# card_rows: one line per USB sound card: index <TAB> id <TAB> port <TAB> id_path
card_rows() {
    local dir n id dev port idpath
    for dir in "$SYS"/class/sound/card[0-9]*; do
        [[ -e "$dir/id" ]] || continue
        n="${dir##*/card}"
        read -r id <"$dir/id" || id=""
        dev=$(readlink -f "$dir/device" 2>/dev/null) || continue
        [[ "$dev" == */usb[0-9]*/* ]] || continue
        port="${dev%/*}"
        port="${port##*/}"
        idpath=$(udevadm info --query=property --path="/sys/class/sound/card$n" 2>/dev/null | sed -n 's/^ID_PATH=//p') || idpath=""
        printf '%s\t%s\t%s\t%s\n' "$n" "$id" "$port" "${idpath:--}"
    done
}

# stream_rows: name <TAB> live(true/false) <TAB> bytes; fails if the API is down.
stream_rows() {
    local json
    json=$(curl -sf --max-time 5 "$SOAK_API_URL/v3/paths/list?itemsPerPage=1000") || return 1
    printf '%s' "$json" | jq -r '.items[]? | [.name,
        ((if has("available") then .available else .ready end) // false | tostring),
        ((.inboundBytes // .bytesReceived // 0) | tostring)] | @tsv'
}

pid_rss_kb() {
    local v
    v=$(sed -n 's/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p' "$PROC/$1/status" 2>/dev/null) || true
    printf '%s' "${v:-0}"
}

# Health problems against the baseline, one per line.
check_names() {
    local rows="$1" kind name a b live_n live_id live_port live_path found
    while IFS=$'\t' read -r kind name a b; do
        [[ "$kind" == card ]] || continue
        # a = expected port ("any" if unknown), b = expected ID_PATH ("-" if
        # unknown). A device is identified by its ID_PATH, else its port, else
        # (vendor/product-only rule) only by its name.
        found=""
        while IFS=$'\t' read -r live_n live_id live_port live_path; do
            [[ -n "$live_n" ]] || continue
            if [[ "$b" != - && "$live_path" == "$b" ]] \
                || [[ "$b" == - && "$a" != any && "$live_port" == "$a" ]] \
                || [[ "$b" == - && "$a" == any && "$live_id" == "$name" ]]; then
                found=1
                [[ "$live_id" == "$name" ]] || echo "misnamed:$name=$live_id"
                if [[ ! -e "$SOAK_ROOT/dev/sound/by-id/$name" ]] \
                    || [[ "$(readlink -f "$SOAK_ROOT/dev/sound/by-id/$name")" != */controlC"$live_n" ]]; then
                    echo "symlink:$name"
                fi
            elif [[ "$live_id" == "$name" ]]; then
                echo "swap:$name@$live_port"
            fi
        done <<<"$rows"
        [[ -n "$found" ]] || echo "absent:$name"
    done <"$BASELINE"
}

# check_streams ROWS MTX_PID: stall bookkeeping in STREAMSTATE; prints problems.
check_streams() {
    local rows="$1" mtx_pid="$2" kind name live bytes last_bytes last_pid count
    local -A prev_bytes=() prev_pid=() prev_count=() now_live=() now_bytes=()
    if [[ -f "$STREAMSTATE" ]]; then
        while IFS=$'\t' read -r name last_bytes last_pid count; do
            prev_bytes[$name]="$last_bytes" prev_pid[$name]="$last_pid" prev_count[$name]="$count"
        done <"$STREAMSTATE"
    fi
    while IFS=$'\t' read -r name live bytes; do
        [[ -n "$name" ]] || continue
        now_live[$name]="$live" now_bytes[$name]="$bytes"
    done <<<"$rows"
    : >"$STREAMSTATE.tmp"
    while IFS=$'\t' read -r kind name _; do
        [[ "$kind" == stream ]] || continue
        if [[ "${now_live[$name]:-false}" != true ]]; then
            echo "stream-down:$name"
            continue
        fi
        bytes="${now_bytes[$name]}" count=0
        if [[ "${prev_pid[$name]:-}" == "$mtx_pid" && -n "${prev_bytes[$name]:-}" ]] \
            && ((bytes <= prev_bytes[$name])); then
            # No new bytes since the last sample (a smaller value means MediaMTX
            # restarted under the same PID, which cannot happen; count it too).
            count=$((${prev_count[$name]:-0} + 1))
        fi
        ((count < SOAK_STALL_SAMPLES)) || echo "stream-stalled:$name"
        printf '%s\t%s\t%s\t%s\n' "$name" "$bytes" "$mtx_pid" "$count" >>"$STREAMSTATE.tmp"
    done <"$BASELINE"
    mv -f "$STREAMSTATE.tmp" "$STREAMSTATE"
}

check_services() {
    local kind svc
    command -v systemctl >/dev/null 2>&1 || return 0
    while IFS=$'\t' read -r kind svc _; do
        [[ "$kind" == service ]] || continue
        systemctl is-active --quiet "$svc" || echo "service-inactive:$svc"
    done <"$BASELINE"
}

df_field() { # df_field -k|-i PATH -> use percent
    df -P "$1" "$SOAK_ROOT$2" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}'
}

# take_sample: appends one row to SAMPLES; sets HEALTHY and PROBLEMS.
take_sample() {
    local fault_label="${1:--}"
    local wall up boot cards streams api_ok=1 mtx_pid ffpids p
    wall=$(wall_s) up=$(uptime_s) boot=$(boot_id)
    cards=$(card_rows)
    streams=$(stream_rows) || {
        api_ok=0
        streams=""
    }
    mtx_pid=$(pgrep -o -x mediamtx 2>/dev/null || true)
    local problems
    problems=$(
        ((api_ok)) || echo "api-down"
        check_names "$cards"
        check_streams "$streams" "${mtx_pid:-0}"
        check_services
    )
    PROBLEMS=$(printf '%s' "$problems" | paste -sd, -)
    HEALTHY=1
    [[ -z "$PROBLEMS" ]] || HEALTHY=0

    local cards_total cards_bad streams_total streams_bad
    cards_total=$(grep -c '^card' "$BASELINE" || true)
    cards_bad=$(printf '%s\n' "$problems" | grep -cE '^(absent|misnamed|swap):' || true)
    streams_total=$(grep -c '^stream' "$BASELINE" || true)
    streams_bad=$(printf '%s\n' "$problems" | grep -cE '^stream-(down|stalled):' || true)

    local mtx_rss=0 mtx_fds=0 ff_n=0 ff_rss=0
    if [[ -n "$mtx_pid" ]]; then
        mtx_rss=$(pid_rss_kb "$mtx_pid")
        mtx_fds=$(find "$PROC/$mtx_pid/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    fi
    ffpids=$(pgrep -f '^ffmpeg.*rtsp://' 2>/dev/null || true)
    for p in $ffpids; do
        ff_n=$((ff_n + 1))
        ff_rss=$((ff_rss + $(pid_rss_kb "$p")))
    done
    local mem disk inode logkb zomb temp thr="-" restarts="-" ntp="-" svc kind n
    mem=$(sed -n 's/^MemAvailable:[[:space:]]*\([0-9]*\).*/\1/p' "$PROC/meminfo" 2>/dev/null || true)
    disk=$(df_field -k "$SOAK_DISK_PATH")
    inode=$(df_field -i "$SOAK_DISK_PATH")
    logkb=$(du -sk "$SOAK_ROOT$SOAK_LOG_DIR" 2>/dev/null | cut -f1 || true)
    # shellcheck disable=SC2016 # awk program, not shell
    zomb=$(cat "$PROC"/[0-9]*/stat 2>/dev/null | awk '{sub(/^.*\) /, ""); if ($1 == "Z") n++} END {print n + 0}')
    temp=$(cat "$SYS/class/thermal/thermal_zone0/temp" 2>/dev/null || echo -)
    if command -v vcgencmd >/dev/null 2>&1; then
        thr=$(vcgencmd get_throttled 2>/dev/null | sed -n 's/^throttled=//p')
    fi
    if command -v systemctl >/dev/null 2>&1; then
        restarts=0
        while IFS=$'\t' read -r kind svc _; do
            [[ "$kind" == service ]] || continue
            n=$(systemctl show -p NRestarts --value "$svc" 2>/dev/null || true)
            [[ "$n" =~ ^[0-9]+$ ]] && restarts=$((restarts + n))
        done <"$BASELINE"
    fi
    if command -v timedatectl >/dev/null 2>&1; then
        ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo -)
    fi

    printf '%s\n' "$wall" "$up" "$boot" "${ST[elapsed]:-0}" "$HEALTHY" "$fault_label" "${PROBLEMS:--}" \
        "$api_ok" "$((streams_total - streams_bad))" "$streams_total" "$((cards_total - cards_bad))" "$cards_total" \
        "${mtx_pid:--}" "$mtx_rss" "$mtx_fds" "$ff_n" "$ff_rss" "${mem:--}" "${disk:--}" "${inode:--}" \
        "${logkb:--}" "$zomb" "$temp" "${thr:--}" "$restarts" "${ntp:--}" "$((wall - up))" \
        | paste -sd '\t' - >>"$SAMPLES"
}

# ----------------------------------------------------------------------------
# init
# ----------------------------------------------------------------------------

cmd_init() {
    local force=0
    [[ "${1:-}" == --force ]] && force=1
    require_root
    need curl jq udevadm pgrep
    mkdir -p "$SOAK_DIR" "$RESTORE_DIR"
    if [[ -s "$SAMPLES" && $force -eq 0 ]]; then
        die "$E_USAGE" "$SOAK_DIR already holds a run; report it, move it away, or use init --force"
    fi

    local tmp="$BASELINE.tmp" line name port path n=0 svc s
    : >"$tmp"
    # Names come from the mapper's rules: the intended mapping, not today's state.
    if [[ -f "$SOAK_ROOT$SOAK_RULES_FILE" ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^\#\ usb-audio-mapper:\ name=([a-z][a-z0-9-]*)\ usb=[0-9a-f:]+\ port=([0-9.-]+|any)\ path=([^ ]+)\  ]] || continue
            name="${BASH_REMATCH[1]}" port="${BASH_REMATCH[2]}" path="${BASH_REMATCH[3]}"
            printf 'card\t%s\t%s\t%s\n' "$name" "$port" "$path" >>"$tmp"
            n=$((n + 1))
        done <"$SOAK_ROOT$SOAK_RULES_FILE"
    fi
    ((n > 0)) || echo "warning: no usb-audio-mapper rules in $SOAK_RULES_FILE; names are not checked" >&2

    local streams
    if [[ -n "$SOAK_STREAMS" ]]; then
        # shellcheck disable=SC2086 # split the space-separated list
        streams=$(printf '%s\n' $SOAK_STREAMS)
    else
        streams=$(stream_rows | awk -F'\t' '$2 == "true" {print $1}') || die "$E_UNHEALTHY" "MediaMTX API not reachable at $SOAK_API_URL"
    fi
    [[ -n "$streams" ]] || die "$E_UNHEALTHY" "no live streams found; start LyreBirdAudio first or set SOAK_STREAMS"
    while IFS= read -r s; do
        printf 'stream\t%s\n' "$s" >>"$tmp"
    done <<<"$streams"

    svc="$SOAK_SERVICES"
    if [[ -z "$svc" ]] && command -v systemctl >/dev/null 2>&1; then
        for s in mediamtx mediamtx-audio; do
            systemctl is-active --quiet "$s" && svc+=" $s"
        done
    fi
    for s in $svc; do
        printf 'service\t%s\n' "$s" >>"$tmp"
    done
    mv -f "$tmp" "$BASELINE"

    ST=()
    ST[seed]="${SOAK_SEED:-$(($(date +%s) % 1000000))}"
    ST[elapsed]=0
    ST[fault_idx]=0
    ST[next_fault]=$((SOAK_WARMUP + $(rand gap0) % (SOAK_FAULT_MAX_GAP - SOAK_FAULT_MIN_GAP + 1) + SOAK_FAULT_MIN_GAP))
    ST[last_boot]=$(boot_id)
    ST[last_uptime]=$(uptime_s)
    state_save

    printf '%s\n' "$SAMPLE_COLUMNS" | tr ' ' '\t' >"$SAMPLES"
    printf 'wall\tuptime\tboot\telapsed\tevent\tdetail\n' >"$EVENTS"
    rm -f "$STREAMSTATE"
    write_environment
    event init "seed=${ST[seed]} faults=${SOAK_FAULTS:-none} interval=$SOAK_INTERVAL"

    # Two samples: the first sets the byte counters, the second checks them.
    take_sample
    sleep "$SOAK_INTERVAL"
    take_sample
    cat "$BASELINE"
    if ((!HEALTHY)); then
        event init_unhealthy "$PROBLEMS"
        die "$E_UNHEALTHY" "node not healthy at init: $PROBLEMS"
    fi
    echo "baseline recorded in $SOAK_DIR; node healthy"
}

write_environment() {
    # Best effort: a missing tool or file leaves its line out, never aborts.
    local f v
    {
        echo "harness=lyrebird-soak $SOAK_VERSION"
        echo "date=$(date -u '+%FT%TZ')"
        echo "kernel=$(uname -r) $(uname -m)"
        v=$(sed -n 's/^PRETTY_NAME=//p' "$SOAK_ROOT/etc/os-release" 2>/dev/null || true)
        [[ -n "$v" ]] && echo "os=$v"
        if [[ -r "$SOAK_ROOT/proc/device-tree/model" ]]; then
            echo "model=$(tr -d '\0' <"$SOAK_ROOT/proc/device-tree/model")"
        fi
        echo "udev=$(udevadm --version 2>/dev/null || echo -)"
        v=$(mediamtx --version 2>/dev/null | head -n 1 || true)
        echo "mediamtx=${v:--}"
        v=$(ffmpeg -version 2>/dev/null | head -n 1 || true)
        echo "ffmpeg=${v:--}"
        echo "bash=$BASH_VERSION"
        for f in /usr/local/bin/lyrebird-stream-manager.sh /usr/local/bin/usb-audio-mapper.sh; do
            [[ -f "$f" ]] || continue
            v=$(grep -m1 -oE 'VERSION="[0-9.]+"' "$f" | cut -d'"' -f2 || true)
            echo "${f##*/}=${v:--}"
        done
        echo "faults=${SOAK_FAULTS:-none}"
        echo "interval=$SOAK_INTERVAL warmup=$SOAK_WARMUP stall_samples=$SOAK_STALL_SAMPLES recovery_deadline=$SOAK_RECOVERY_DEADLINE reboot_deadline=$SOAK_REBOOT_DEADLINE"
    } >"$SOAK_DIR/environment"
}

# ----------------------------------------------------------------------------
# Faults
# ----------------------------------------------------------------------------

# Run a command, or print it under SOAK_DRY_RUN=1.
act() {
    if [[ "$SOAK_DRY_RUN" == 1 ]]; then
        printf 'DRY-RUN:' >&2
        printf ' %q' "$@" >&2
        printf '\n' >&2
        return 0
    fi
    "$@"
}

# arm_restore NAME DELAY SCRIPT: write the undo script, then schedule it as a
# systemd timer DELAY seconds from now, BEFORE the fault starts. The script
# deletes itself when done, so the harness and the timer can both call it.
arm_restore() {
    local name="$1" delay="$2" body="$3" file="$RESTORE_DIR/$1.sh"
    mkdir -p "$RESTORE_DIR"
    # shellcheck disable=SC2016 # "$0" belongs to the generated script
    printf '#!/bin/sh\n# lyrebird-soak undo for %s\n%s\nrm -f "$0"\n' "$name" "$body" >"$file"
    chmod 700 "$file"
    if [[ "$SOAK_DRY_RUN" != 1 ]]; then
        command -v systemd-run >/dev/null 2>&1 || {
            rm -f "$file"
            die "$E_DEP" "systemd-run is required for fault $name (it guarantees the undo)"
        }
        systemctl stop "lyrebird-soak-undo-$name.timer" >/dev/null 2>&1 || true
        systemd-run --quiet --unit="lyrebird-soak-undo-$name" --on-active="$delay" \
            --timer-property=AccuracySec=1s /bin/sh -c "[ -f '$file' ] && /bin/sh '$file'" \
            || {
                rm -f "$file"
                die "$E_FAIL" "could not schedule the undo timer for $name; fault not started"
            }
    fi
    ST[restore]="$name"
}

run_restore() {
    local name="${1:-${ST[restore]:-}}" file
    [[ -n "$name" ]] || return 0
    file="$RESTORE_DIR/$name.sh"
    if [[ "$SOAK_DRY_RUN" != 1 ]]; then
        systemctl stop "lyrebird-soak-undo-$name.timer" >/dev/null 2>&1 || true
    fi
    if [[ -f "$file" ]]; then
        if [[ "$SOAK_DRY_RUN" == 1 ]]; then
            echo "DRY-RUN: undo $name:" >&2
            sed -n '3,$p' "$file" | sed '$d' >&2
            rm -f "$file"
        else
            /bin/sh "$file" || event restore_failed "$name"
            rm -f "$file"
        fi
    fi
    unset 'ST[restore]'
}

# Pick a mapped, connected device's USB port for usb-replug.
pick_usb_port() {
    local rows ports
    rows=$(card_rows)
    ports=$(awk -F'\t' 'NR==FNR {if ($1 == "card") want[$2] = 1; next} ($2 in want) {print $3}' "$BASELINE" - <<<"$rows")
    [[ -n "$ports" ]] || ports=$(cut -f3 <<<"$rows")
    [[ -n "$ports" ]] || return 1
    local n
    n=$(wc -l <<<"$ports")
    sed -n "$(($(rand "usb${ST[fault_idx]}") % n + 1))p" <<<"$ports"
}

# inject KIND: start a fault. Sets FAULT_HOLD (seconds until the undo, 0 for
# instantaneous faults) and FAULT_DETAIL. Returns 1 if it could not start.
inject() {
    local kind="$1" pids pid n
    FAULT_HOLD=0 FAULT_DETAIL=""
    case "$kind" in
        kill-ffmpeg)
            pids=$(pgrep -f '^ffmpeg.*rtsp://' 2>/dev/null || true)
            [[ -n "$pids" ]] || return 1
            n=$(wc -w <<<"$pids")
            pid=$(tr ' ' '\n' <<<"$pids" | sed -n "$(($(rand "ff${ST[fault_idx]}") % n + 1))p")
            FAULT_DETAIL="pid=$pid $(tr '\0' ' ' <"$PROC/$pid/cmdline" 2>/dev/null | grep -oE 'rtsp://[^ ]+' || true)"
            act kill -KILL "$pid"
            ;;
        kill-mediamtx)
            pid=$(pgrep -o -x mediamtx 2>/dev/null || true)
            [[ -n "$pid" ]] || return 1
            FAULT_DETAIL="pid=$pid"
            act kill -KILL "$pid"
            ;;
        kill-manager)
            FAULT_DETAIL="unit=mediamtx-audio"
            act systemctl kill --signal=KILL mediamtx-audio
            ;;
        restart-udev)
            act systemctl restart systemd-udevd
            ;;
        udev-trigger)
            act udevadm trigger --action=change --subsystem-match=sound
            act udevadm settle --timeout=30
            ;;
        usb-replug)
            local port
            port=$(pick_usb_port) || return 1
            FAULT_HOLD="$SOAK_USB_OFF_SECONDS"
            if [[ "$SOAK_USB_METHOD" == uhubctl ]]; then
                need uhubctl
                local loc p
                if [[ "$port" == *.* ]]; then loc="${port%.*}" p="${port##*.}"; else loc="${port%%-*}" p="${port#*-}"; fi
                FAULT_DETAIL="port=$port uhubctl -l $loc -p $p"
                arm_restore usb $((FAULT_HOLD + 30)) "uhubctl -a on -l '$loc' -p '$p' >/dev/null"
                act uhubctl -a off -l "$loc" -p "$p"
            else
                local auth="$SYS/bus/usb/devices/$port/authorized"
                [[ -e "$auth" ]] || return 1
                FAULT_DETAIL="port=$port authorized=0"
                arm_restore usb $((FAULT_HOLD + 30)) "echo 1 > '$auth'"
                if [[ "$SOAK_DRY_RUN" == 1 ]]; then act tee "$auth" <<<0; else echo 0 >"$auth"; fi
            fi
            ;;
        net-down)
            [[ -n "$SOAK_NET_IFACE" ]] || die "$E_USAGE" "net-down needs SOAK_NET_IFACE"
            need ip
            FAULT_HOLD="$SOAK_NET_DOWN_SECONDS" FAULT_DETAIL="iface=$SOAK_NET_IFACE"
            arm_restore net $((FAULT_HOLD + 30)) "ip link set '$SOAK_NET_IFACE' up"
            act ip link set "$SOAK_NET_IFACE" down
            ;;
        disk-fill)
            need fallocate
            local total used avail target size_kb file
            read -r total used avail < <(df -Pk "$SOAK_ROOT$SOAK_DISK_PATH" | awk 'NR==2 {print $2, $3, $4}')
            target=$((total * SOAK_DISK_FILL_PERCENT / 100))
            size_kb=$((target - used))
            ((size_kb <= avail - SOAK_DISK_MIN_FREE_MB * 1024)) || size_kb=$((avail - SOAK_DISK_MIN_FREE_MB * 1024))
            ((size_kb > 0)) || return 1
            file="$SOAK_ROOT$SOAK_DISK_PATH/$FILL_NAME"
            FAULT_HOLD="$SOAK_DISK_FILL_SECONDS" FAULT_DETAIL="file=$file size_kb=$size_kb target=${SOAK_DISK_FILL_PERCENT}%"
            arm_restore disk $((FAULT_HOLD + 30)) "rm -f '$file'"
            act fallocate -l "$((size_kb * 1024))" "$file" || {
                run_restore disk
                return 1
            }
            ;;
        clock-jump)
            # Undo restores wall = uptime + the offset before the jump, so it is
            # right even if NTP already corrected part of it. Same boot only.
            local off boot
            off=$(($(wall_s) - $(uptime_s))) boot=$(boot_id)
            FAULT_HOLD="$SOAK_CLOCK_JUMP_HOLD" FAULT_DETAIL="by=${SOAK_CLOCK_JUMP_SECONDS}s"
            arm_restore clock $((FAULT_HOLD + 30)) "[ \"\$(cat /proc/sys/kernel/random/boot_id)\" = '$boot' ] && date -s \"@\$(( \$(cut -d. -f1 /proc/uptime) + $off ))\" >/dev/null"
            act date -s "@$(($(wall_s) + SOAK_CLOCK_JUMP_SECONDS))"
            ;;
        reboot | hard-reset)
            ST[active]="$kind" ST[phase]=rebooting ST[fault_boot]=$(boot_id) ST[fault_start]="${ST[elapsed]:-0}"
            state_save
            event fault_start "$kind"
            sync -f "$EVENTS" 2>/dev/null || sync
            if [[ "$kind" == reboot ]]; then
                act systemctl reboot
            elif [[ "$SOAK_DRY_RUN" == 1 ]]; then
                act tee /proc/sysrq-trigger <<<b
            else
                echo b >/proc/sysrq-trigger
            fi
            ;;
        *)
            die "$E_USAGE" "unknown fault $kind"
            ;;
    esac
    return 0
}

enabled_faults() {
    local f
    for f in ${SOAK_FAULTS//,/ }; do printf '%s\n' "$f"; done
}

# ----------------------------------------------------------------------------
# run loop
# ----------------------------------------------------------------------------

lock_dir() {
    exec {LOCK_FD}>"$SOAK_DIR/.lock"
    flock -n "$LOCK_FD" || die "$E_FAIL" "another lyrebird-soak is running on $SOAK_DIR (stop the service first)"
}

# Advance the harness's own elapsed clock (immune to wall-clock jumps).
tick_clock() {
    local up boot
    up=$(uptime_s) boot=$(boot_id)
    if [[ "$boot" != "${ST[last_boot]:-}" ]]; then
        ST[elapsed]=$((${ST[elapsed]:-0} + up))
        on_new_boot "$boot"
    else
        ST[elapsed]=$((${ST[elapsed]:-0} + up - ${ST[last_uptime]:-$up}))
    fi
    ST[last_boot]="$boot" ST[last_uptime]="$up"
}

on_new_boot() {
    if [[ "${ST[phase]:-}" == rebooting && "${ST[fault_boot]:-}" != "$1" ]]; then
        ST[phase]=recovering ST[fault_end]=boot
        event fault_end "${ST[active]} new_boot"
    else
        event unexpected_reboot "previous_boot=${ST[last_boot]:-?}"
        # Attribute the outage to the reboot, not to separate failures.
        ST[active]=unexpected-reboot ST[phase]=recovering ST[fault_end]=boot
        # Undo scripts of a fault interrupted by the reboot: their timers are gone.
        local f
        for f in "$RESTORE_DIR"/*.sh; do
            [[ -f "$f" ]] || continue
            /bin/sh "$f" || event restore_failed "${f##*/}"
            rm -f "$f"
        done
        unset 'ST[restore]'
    fi
    rm -f "$STREAMSTATE"
}

clear_fault() {
    unset 'ST[active]' 'ST[phase]' 'ST[fault_end]' 'ST[hold_until]' 'ST[fault_boot]' 'ST[fault_start]'
}

fault_label() {
    [[ -n "${ST[active]:-}" ]] && printf '%s:%s' "${ST[active]}" "${ST[phase]}" || printf -- '-'
}

step() {
    local kinds n kind
    tick_clock

    # A fault with a duration ends: undo it, then measure recovery from here.
    if [[ "${ST[phase]:-}" == holding ]] && ((ST[elapsed] >= ST[hold_until])); then
        run_restore
        ST[phase]=recovering ST[fault_end]="${ST[elapsed]}"
        event fault_end "${ST[active]}"
    fi

    take_sample "$(fault_label)"

    # A reboot that never came (refused, or dry run).
    if [[ "${ST[phase]:-}" == rebooting ]] && ((ST[elapsed] - ${ST[fault_start]:-0} > 120)); then
        event fault_failed "${ST[active]} no reboot within 120s"
        clear_fault
    fi

    if [[ "${ST[phase]:-}" == recovering ]]; then
        local took deadline="$SOAK_RECOVERY_DEADLINE"
        if [[ "${ST[fault_end]}" == boot ]]; then
            took=$(uptime_s) deadline="$SOAK_REBOOT_DEADLINE"
        else
            took=$((ST[elapsed] - ST[fault_end]))
        fi
        if ((HEALTHY)); then
            event recovered "${ST[active]} seconds=$took"
            clear_fault
        elif ((took > deadline)); then
            event not_recovered "${ST[active]} seconds=$took deadline=$deadline problems=$PROBLEMS"
            clear_fault
        fi
    fi

    kinds=$(enabled_faults)
    if [[ -n "$kinds" && -z "${ST[active]:-}" ]] && ((HEALTHY && ST[elapsed] >= ST[next_fault])); then
        n=$(wc -l <<<"$kinds")
        ST[fault_idx]=$((${ST[fault_idx]:-0} + 1))
        kind=$(sed -n "$(($(rand "kind${ST[fault_idx]}") % n + 1))p" <<<"$kinds")
        ST[next_fault]=$((ST[elapsed] + $(rand "gap${ST[fault_idx]}") % (SOAK_FAULT_MAX_GAP - SOAK_FAULT_MIN_GAP + 1) + SOAK_FAULT_MIN_GAP))
        if inject "$kind"; then
            if [[ "$kind" != reboot && "$kind" != hard-reset ]]; then
                ST[active]="$kind"
                if ((FAULT_HOLD > 0)); then
                    ST[phase]=holding ST[hold_until]=$((ST[elapsed] + FAULT_HOLD))
                else
                    ST[phase]=recovering ST[fault_end]="${ST[elapsed]}"
                fi
                event fault_start "$kind $FAULT_DETAIL"
            fi
        else
            event fault_skipped "$kind (nothing to act on)"
        fi
    fi
    state_save
}

cmd_run() {
    require_root
    need curl jq udevadm pgrep flock
    [[ -f "$BASELINE" && -f "$STATE" ]] || die "$E_USAGE" "no baseline in $SOAK_DIR; run init first"
    mkdir -p "$RESTORE_DIR"
    lock_dir
    state_load
    if [[ "${ST[last_boot]:-}" == "$(boot_id)" ]]; then
        # Same boot, harness restarted: undo anything it left half-done.
        if [[ -n "${ST[restore]:-}" ]]; then
            run_restore
            [[ "${ST[phase]:-}" == holding ]] && ST[phase]=recovering ST[fault_end]="${ST[elapsed]:-0}"
        fi
    fi
    # Fault settings may have changed since init: never wait longer for the
    # next fault than the current settings allow.
    local latest=$((${ST[elapsed]:-0} > SOAK_WARMUP ? ${ST[elapsed]:-0} : SOAK_WARMUP))
    latest=$((latest + SOAK_FAULT_MAX_GAP))
    ((${ST[next_fault]:-0} <= latest)) || ST[next_fault]=$latest
    event harness_start "pid=$$ version=$SOAK_VERSION"
    trap 'event harness_stop "signal"; run_restore; state_save; exit 0' TERM INT
    local t0 spent
    while :; do
        t0=$(uptime_s)
        step
        spent=$(($(uptime_s) - t0))
        sleep $((spent < SOAK_INTERVAL ? SOAK_INTERVAL - spent : 1)) &
        wait $! || true
    done
}

cmd_sample() {
    [[ -f "$BASELINE" ]] || die "$E_USAGE" "no baseline in $SOAK_DIR; run init first"
    state_load
    take_sample "manual"
    tail -n 1 "$SAMPLES" | paste <(tr ' ' '\n' <<<"$SAMPLE_COLUMNS") <(tail -n 1 "$SAMPLES" | tr '\t' '\n') 2>/dev/null \
        || tail -n 1 "$SAMPLES"
    ((HEALTHY))
}

cmd_fault() {
    local kind="${1:-}"
    [[ " $ALL_FAULTS " == *" $kind "* ]] || die "$E_USAGE" "usage: fault KIND (one of: $ALL_FAULTS)"
    require_root
    [[ -f "$BASELINE" && -f "$STATE" ]] || die "$E_USAGE" "no baseline in $SOAK_DIR; run init first"
    mkdir -p "$RESTORE_DIR"
    lock_dir
    state_load
    tick_clock
    take_sample "-"
    ((HEALTHY)) || die "$E_UNHEALTHY" "node not healthy before the fault: $PROBLEMS"
    ST[fault_idx]=$((${ST[fault_idx]:-0} + 1))
    inject "$kind" || die "$E_FAIL" "fault $kind found nothing to act on"
    event fault_start "$kind $FAULT_DETAIL (manual)"
    [[ "$kind" == reboot || "$kind" == hard-reset ]] && return 0
    ST[active]="$kind" ST[phase]=holding ST[hold_until]=$((ST[elapsed] + FAULT_HOLD))
    ((FAULT_HOLD > 0)) || ST[phase]=recovering ST[fault_end]="${ST[elapsed]}"
    state_save
    while [[ -n "${ST[active]:-}" ]]; do
        sleep "$SOAK_INTERVAL"
        step
    done
    local last
    last=$(grep -E $'\t(recovered|not_recovered)\t' "$EVENTS" | tail -n 1 | cut -f5-)
    printf '%s\n' "$last"
    [[ "$last" == recovered$'\t'* ]]
}

cmd_restore() {
    require_root
    state_load
    local f
    for f in "$RESTORE_DIR"/*.sh; do
        [[ -f "$f" ]] || continue
        local name="${f##*/}"
        run_restore "${name%.sh}"
        echo "undone: ${name%.sh}"
    done
    [[ -f "$STATE" ]] && state_save
    return 0
}

cmd_status() {
    [[ -f "$SAMPLES" ]] || die "$E_USAGE" "no run in $SOAK_DIR"
    state_load
    echo "run: $SOAK_DIR"
    echo "elapsed: $((${ST[elapsed]:-0} / 3600))h$(((${ST[elapsed]:-0} % 3600) / 60))m, faults injected: ${ST[fault_idx]:-0}, next fault at elapsed ${ST[next_fault]:-?}s"
    echo "active fault: $(fault_label)"
    echo "latest sample:"
    paste <(tr ' ' '\n' <<<"$SAMPLE_COLUMNS") <(tail -n 1 "$SAMPLES" | tr '\t' '\n') | sed 's/^/  /'
}

# ----------------------------------------------------------------------------
# report
# ----------------------------------------------------------------------------

cmd_report() {
    local dir="${1:-$SOAK_DIR}"
    [[ -f "$dir/samples.tsv" && -f "$dir/events.tsv" ]] || die "$E_USAGE" "no run in $dir"
    local here interval="$SOAK_INTERVAL" warmup="$SOAK_WARMUP" line
    here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
    # Use the settings the run was made with.
    if [[ -f "$dir/environment" ]]; then
        cat "$dir/environment"
        echo
        line=$(grep -m1 '^interval=' "$dir/environment" || true)
        [[ "$line" =~ interval=([0-9]+) ]] && interval="${BASH_REMATCH[1]}"
        [[ "$line" =~ warmup=([0-9]+) ]] && warmup="${BASH_REMATCH[1]}"
    fi
    awk -v interval="$interval" -v exhaustion_days="$SOAK_EXHAUSTION_DAYS" -v warmup="$warmup" \
        -f "$here/soak-report.awk" "$dir/events.tsv" "$dir/samples.tsv"
}

usage() {
    sed -n '2,/^# Exit codes/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
    local cmd="${1:-}"
    shift || true
    case "$cmd" in
        -h | --help | help | "")
            usage
            [[ -n "$cmd" ]] || exit "$E_USAGE"
            return 0
            ;;
        --version | version)
            echo "lyrebird-soak $SOAK_VERSION"
            return 0
            ;;
    esac
    load_config
    case "$cmd" in
        init) cmd_init "$@" ;;
        run) cmd_run ;;
        sample) cmd_sample ;;
        fault) cmd_fault "$@" ;;
        restore) cmd_restore ;;
        status) cmd_status ;;
        report) cmd_report "$@" ;;
        *) die "$E_USAGE" "unknown command '$cmd' (see --help)" ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

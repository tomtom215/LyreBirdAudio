#!/usr/bin/env bash
# lyrebird-soak-observer.sh - watch a LyreBirdAudio node's streams from outside
#
# Run on a second machine (Linux or macOS; bash 3.2 or later, ffmpeg). It
# keeps one RTSP reader per stream and logs, once a second, that audio
# arrived. Gaps are measured from the listener's side, so they include what
# the node itself cannot record: power cuts, kernel hangs, network loss.
# Optionally it cuts and restores the node's power with commands you supply
# (a smart plug, a relay, a PDU) and measures the time until audio is back.
#
# Usage:
#   lyrebird-soak-observer.sh run --dir DIR [options] RTSP_URL...
#       --power-off-cmd CMD   shell command that cuts the node's power
#       --power-on-cmd CMD    shell command that restores it
#       --power-every SEC     mean seconds between power cuts (jittered +-50%)
#       --power-off-for SEC   seconds the power stays off (default 30)
#       --seed N              seed for the power-cut schedule (default: time)
#       --timeout SEC         reader socket timeout (default 5)
#     Stops on Ctrl-C/SIGTERM or when DIR/stop exists.
#   lyrebird-soak-observer.sh report --dir DIR [--gap SEC] [--boot-deadline SEC]
#                                    [--node-events FILE]
#       --gap SEC             silence longer than this is a gap (default 5)
#       --boot-deadline SEC   audio must return this long after power-on
#                             (default 300)
#       --node-events FILE    the node's events.tsv: gaps inside its fault
#                             windows are expected (clocks must be in sync)
#     Exit 0 = PASS, 1 = FAIL.

set -eu
LC_ALL=C
export LC_ALL

die() {
    printf 'lyrebird-soak-observer: %s\n' "$*" >&2
    exit 2
}

now() { date +%s; }

log() { # log STREAM EVENT VALUE
    printf '%s\t%s\t%s\t%s\n' "$(now)" "$1" "$2" "$3" >>"$DIR/observer.tsv"
}

# Deterministic jitter from the seed and a counter (no $RANDOM state to keep).
rand() {
    printf '%s:%s' "$SEED" "$1" | cksum | awk '{print $1}'
}

timeout_option() {
    if ffmpeg -hide_banner -h demuxer=rtsp 2>/dev/null | grep -q -- '-stimeout'; then
        echo -stimeout
    else
        echo -timeout
    fi
}

# reader INDEX URL: read the stream until stopped, reconnecting after errors.
reader() {
    local idx="$1" url="$2" opt rc
    opt=$(timeout_option)
    while [ ! -e "$DIR/stop" ]; do
        log "$idx" connect "$url"
        rc=0
        ffmpeg -nostdin -hide_banner -loglevel error -rtsp_transport tcp "$opt" "$TIMEOUT_US" \
            -i "$url" -map 0:a:0 -c copy -f null - -progress pipe:1 -nostats 2>>"$DIR/reader-$idx.err" \
            | progress_to_log "$idx" || rc=$?
        log "$idx" disconnect "rc=$rc"
        [ -e "$DIR/stop" ] || sleep 1
    done
}

# Turn ffmpeg -progress output into at most one "audio" line per second,
# only when the stream position advanced. Only "progress=continue" blocks
# count: the final "progress=end" block, printed when a dead connection times
# out, carries a position from buffered data and would hide the gap.
progress_to_log() {
    local idx="$1" key val pos last_pos=-1 sec last_sec=0
    while IFS='=' read -r key val; do
        case "$key" in
            out_time_us | out_time_ms) pos="$val" ;;
            progress)
                [ "$val" = continue ] || continue
                case "$pos" in '' | N/A | *[!0-9]*) continue ;; esac
                if [ "$pos" -gt "$last_pos" ]; then
                    sec=$(now)
                    if [ "$sec" -ne "$last_sec" ]; then
                        log "$idx" audio "$((pos / 1000000))"
                        last_sec="$sec"
                    fi
                    last_pos="$pos"
                fi
                ;;
        esac
    done
}

power_cycler() {
    local n=0 wait_s
    while [ ! -e "$DIR/stop" ]; do
        n=$((n + 1))
        wait_s=$((POWER_EVERY / 2 + $(rand "power$n") % (POWER_EVERY + 1)))
        sleep_until_stop "$wait_s" || return 0
        log - power_off "cut $n"
        sh -c "$POWER_OFF_CMD" >>"$DIR/power.log" 2>&1 || log - power_error "off rc=$?"
        sleep_until_stop "$POWER_OFF_FOR" || true
        sh -c "$POWER_ON_CMD" >>"$DIR/power.log" 2>&1 || log - power_error "on rc=$?"
        log - power_on "cut $n"
    done
}

# Sleep up to N seconds; fail early if a stop was requested.
sleep_until_stop() {
    local left="$1"
    while [ "$left" -gt 0 ]; do
        [ ! -e "$DIR/stop" ] || return 1
        sleep 1
        left=$((left - 1))
    done
    return 0
}

cmd_run() {
    DIR="" POWER_OFF_CMD="" POWER_ON_CMD="" POWER_EVERY=0 POWER_OFF_FOR=30 SEED="" TIMEOUT=5
    while [ $# -gt 0 ]; do
        case "$1" in --[a-z]*-* | --dir | --seed | --timeout)
            [ $# -ge 2 ] || die "$1 needs a value"
            ;;
        esac
        case "$1" in
            --dir)
                DIR="$2"
                shift 2
                ;;
            --power-off-cmd)
                POWER_OFF_CMD="$2"
                shift 2
                ;;
            --power-on-cmd)
                POWER_ON_CMD="$2"
                shift 2
                ;;
            --power-every)
                POWER_EVERY="$2"
                shift 2
                ;;
            --power-off-for)
                POWER_OFF_FOR="$2"
                shift 2
                ;;
            --seed)
                SEED="$2"
                shift 2
                ;;
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --)
                shift
                break
                ;;
            -*) die "unknown option $1" ;;
            *) break ;;
        esac
    done
    [ -n "$DIR" ] || die "run needs --dir DIR"
    [ $# -gt 0 ] || die "run needs at least one rtsp:// URL"
    for v in "$POWER_EVERY" "$POWER_OFF_FOR" "$TIMEOUT"; do
        case "$v" in '' | *[!0-9]*) die "not a number: $v" ;; esac
    done
    if [ "$POWER_EVERY" -gt 0 ]; then
        if [ -z "$POWER_OFF_CMD" ] || [ -z "$POWER_ON_CMD" ]; then
            die "--power-every needs --power-off-cmd and --power-on-cmd"
        fi
    fi
    command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg not found"
    [ -n "$SEED" ] || SEED=$(($(now) % 1000000))
    TIMEOUT_US=$((TIMEOUT * 1000000))

    mkdir -p "$DIR"
    rm -f "$DIR/stop"
    [ -f "$DIR/observer.tsv" ] || printf 'wall\tstream\tevent\tvalue\n' >"$DIR/observer.tsv"
    log - start "seed=$SEED power_every=$POWER_EVERY power_off_for=$POWER_OFF_FOR"

    local i=0 url pids=""
    for url in "$@"; do
        case "$url" in rtsp://* | rtsps://*) ;; *) die "not an RTSP URL: $url" ;; esac
        i=$((i + 1))
        printf '%s\t%s\n' "$i" "$url" >>"$DIR/streams"
        reader "$i" "$url" &
        pids="$pids $!"
    done
    if [ "$POWER_EVERY" -gt 0 ]; then
        power_cycler &
        pids="$pids $!"
    fi
    # Ctrl-C/SIGTERM and DIR/stop end the same way: readers are stopped, and
    # the power cycler is left to finish, so a cut in progress is undone
    # (power switched back on) before we exit.
    # shellcheck disable=SC2064 # expand $DIR now
    trap "touch '$DIR/stop'" INT TERM
    while [ ! -e "$DIR/stop" ]; do
        sleep 1
    done
    for p in $pids; do
        pkill -P "$p" 2>/dev/null || true # ffmpeg may be blocked in I/O
    done
    wait
    log - stop ""
}

cmd_report() {
    local dir="" gap=5 boot=300 node=""
    while [ $# -gt 0 ]; do
        [ $# -ge 2 ] || die "$1 needs a value"
        case "$1" in
            --dir)
                dir="$2"
                shift 2
                ;;
            --gap)
                gap="$2"
                shift 2
                ;;
            --boot-deadline)
                boot="$2"
                shift 2
                ;;
            --node-events)
                node="$2"
                shift 2
                ;;
            *) die "unknown option $1" ;;
        esac
    done
    [ -f "$dir/observer.tsv" ] || die "no observer run in '$dir'"
    [ -z "$node" ] || [ -f "$node" ] || die "no such file: $node"
    local here
    here=$(cd "$(dirname "$0")" && pwd)
    awk -v gap="$gap" -v boot="$boot" -v streams="$dir/streams" -v node="$node" \
        -f "$here/observer-report.awk" "$dir/observer.tsv"
}

case "${1:-}" in
    run)
        shift
        cmd_run "$@"
        ;;
    report)
        shift
        cmd_report "$@"
        ;;
    -h | --help | help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
    *)
        sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
        exit 2
        ;;
esac

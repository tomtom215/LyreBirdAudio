# shellcheck shell=bash
# Fake node for tests/test_soak.bats: a root with /sys, /proc and /dev pieces,
# stub commands on PATH (tests/helpers/soak/bin) and a MediaMTX API fixture.
# Load after scratch_tmpdir; call soak_setup from setup().

soak_setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SOAK="$PROJECT_ROOT/tools/soak/lyrebird-soak.sh"
    R="$TEST_SCRATCH/root"
    export STUB_DIR="$TEST_SCRATCH/stub"
    mkdir -p "$R/proc/sys/kernel/random" "$R/sys/class/sound" "$R/sys/bus/usb/devices" \
        "$R/dev/sound/by-id" "$R/dev/snd" "$R/etc/udev/rules.d" "$R/var/lib/mediamtx-ffmpeg" \
        "$R/var/log" "$STUB_DIR"
    : >"$STUB_DIR/calls"
    set_uptime 1000
    set_boot boot-a
    printf 'MemTotal: 1000000 kB\nMemAvailable: 500000 kB\n' >"$R/proc/meminfo"
    fake_proc 100 "mediamtx" 20000
    echo 100 >"$STUB_DIR/pid.mediamtx"
    : >"$STUB_DIR/pid.ffmpeg"

    export SOAK_ROOT="$R" SOAK_DIR="$TEST_SCRATCH/run" SOAK_CONFIG="$TEST_SCRATCH/none.conf"
    export SOAK_INTERVAL=1 SOAK_WARMUP=0 SOAK_SEED=42 SOAK_SERVICES="mediamtx-audio"
    export PATH="$PROJECT_ROOT/tests/helpers/soak/bin:$PATH"
}

set_uptime() { printf '%s.25 9999.00\n' "$1" >"$R/proc/uptime"; }
set_boot() { echo "$1" >"$R/proc/sys/kernel/random/boot_id"; }

# fake_proc PID NAME RSS_KB [STATE]
fake_proc() {
    mkdir -p "$R/proc/$1/fd"
    printf 'Name:\t%s\nVmRSS:\t%s kB\n' "$2" "$3" >"$R/proc/$1/status"
    printf '%s (%s) %s 1 1\n' "$1" "$2" "${4:-S}" >"$R/proc/$1/stat"
    printf '%s\0rtsp://127.0.0.1:8554/x\0' "$2" >"$R/proc/$1/cmdline"
    : >"$R/proc/$1/fd/0"
    : >"$R/proc/$1/fd/1"
}

# add_card N ID PORT IDPATH: USB sound card N at PORT, with its control link.
add_card() {
    local n="$1" id="$2" port="$3" idpath="$4" bus dev
    bus="${port%%-*}"
    dev="$R/sys/devices/pci0000:00/0000:00:14.0/usb$bus/$port/$port:1.0"
    mkdir -p "$dev/sound/card$n"
    echo "$id" >"$dev/sound/card$n/id"
    ln -sfn "../.." "$dev/sound/card$n/device"
    ln -sfn "../../devices/pci0000:00/0000:00:14.0/usb$bus/$port/$port:1.0/sound/card$n" "$R/sys/class/sound/card$n"
    ln -sfn "../../../devices/pci0000:00/0000:00:14.0/usb$bus/$port" "$R/sys/bus/usb/devices/$port"
    echo 1 >"$R/sys/devices/pci0000:00/0000:00:14.0/usb$bus/$port/authorized"
    : >"$R/dev/snd/controlC$n"
    ln -sfn "../../snd/controlC$n" "$R/dev/sound/by-id/$id"
    echo "$idpath" >"$STUB_DIR/idpath.card$n"
}

# set_card_id N ID: rename card N (the kernel's view; links untouched).
set_card_id() { echo "$2" >"$(readlink -f "$R/sys/class/sound/card$1")/id"; }

remove_card() {
    local dir
    dir=$(readlink -f "$R/sys/class/sound/card$1")
    rm -f "$R/sys/class/sound/card$1"
    rm -rf "$dir"
}

# mapper_rule NAME PORT IDPATH: the comment line usb-audio-mapper writes.
mapper_rule() {
    printf '# usb-audio-mapper: name=%s usb=46f4:0002 port=%s path=%s desc=Mic\n' "$1" "$2" "$3" \
        >>"$R/etc/udev/rules.d/99-usb-soundcards.rules"
}

# api_paths [old] NAME:LIVE:BYTES... : write the /v3/paths/list fixture in the
# MediaMTX >= 1.19 shape, or the 1.15 shape with "old".
api_paths() {
    local shape=new item name live bytes items=""
    [[ "${1:-}" == old ]] && shape=old && shift
    for item in "$@"; do
        IFS=: read -r name live bytes <<<"$item"
        if [[ $shape == new ]]; then
            items+="${items:+,}{\"name\":\"$name\",\"ready\":$live,\"available\":$live,\"online\":$live,\"inboundBytes\":$bytes,\"bytesReceived\":$bytes}"
        else
            items+="${items:+,}{\"name\":\"$name\",\"ready\":$live,\"bytesReceived\":$bytes}"
        fi
    done
    printf '{"pageCount":1,"itemCount":%d,"items":[%s]}\n' "$#" "$items" >"$STUB_DIR/paths.json"
}

# Two mapped mics on 1-1 and 1-2, both streaming.
standard_node() {
    add_card 0 mic-a 1-1 pci-0000:00:14.0-usb-0:1:1.0
    add_card 1 mic-b 1-2 pci-0000:00:14.0-usb-0:2:1.0
    mapper_rule mic-a 1-1 pci-0000:00:14.0-usb-0:1:1.0
    mapper_rule mic-b 1-2 pci-0000:00:14.0-usb-0:2:1.0
    api_paths mic_a:true:1000 mic_b:true:1000
}

# Run the harness CLI.
soak() { bash "$SOAK" "$@"; }

# soak_eval CODE: run CODE with the harness sourced, config and state loaded,
# and the state saved afterwards.
soak_eval() {
    bash -c 'source "$1"; load_config; state_load; eval "$2"; state_save' _ "$SOAK" "$1"
}

# advance SECONDS [BYTES_STEP]: move the fake clock and stream counters on.
advance() {
    local up
    read -r up _ <"$R/proc/uptime"
    set_uptime $((${up%%.*} + $1))
    if [[ -n "${2:-}" ]]; then
        sed -i -E 's/"(inboundBytes|bytesReceived)":([0-9]+)/"\1":\2+'"$2"'/g' "$STUB_DIR/paths.json"
        # Evaluate the additions.
        local j
        j=$(cat "$STUB_DIR/paths.json")
        while [[ "$j" =~ ([0-9]+)\+([0-9]+) ]]; do
            j="${j/${BASH_REMATCH[0]}/$((BASH_REMATCH[1] + BASH_REMATCH[2]))}"
        done
        printf '%s\n' "$j" >"$STUB_DIR/paths.json"
    fi
}

# step_n N: N harness steps, each 10 s apart with the streams moving.
step_n() {
    local i
    for ((i = 0; i < $1; i++)); do
        advance 10 500
        soak_eval step 2>/dev/null
    done
}

last_problems() { tail -n 1 "$SOAK_DIR/samples.tsv" | cut -f7; }
events() { cut -f5- "$SOAK_DIR/events.tsv"; }

# Shared setup for the bats suite: builds a fake sysfs tree that mirrors the
# layout of a real kernel (captured from Linux 6.8 with QEMU usb-audio devices,
# see tests/e2e) and puts stub udevadm/logger first on PATH.

MAPPER="${MAPPER_UNDER_TEST:-$BATS_TEST_DIRNAME/../usb-audio-mapper.sh}"

setup_env() {
    T="$BATS_TEST_TMPDIR"
    SYS="$T/sys"
    RULES="$T/rules.d/99-usb-soundcards.rules"
    mkdir -p "$SYS/class/sound" "$SYS/bus/usb/devices" "$T/rules.d"
    export USB_AUDIO_MAPPER_SYSFS="$SYS"
    export STUB_LOG="$T/stub.log"
    : >"$STUB_LOG"
    REAL_UDEVADM="$(command -v udevadm || true)"
    export REAL_UDEVADM
    export PATH="$BATS_TEST_DIRNAME/helpers/usb-audio-mapper/bin:$PATH"
    export NO_COLOR=1
    unset STUB_RENAME STUB_VERIFY_FAIL DEBUG
}

# add_controller <bus> <pci-address>: root hub usb<bus> under a PCI controller.
add_controller() {
    local bus="$1" pci="$2" d
    d="$SYS/devices/pci0000:00/$pci/usb$bus"
    mkdir -p "$d"
    printf '1d6b\n' >"$d/idVendor"
    printf '0002\n' >"$d/idProduct"
    ln -s "../../../devices/pci0000:00/$pci/usb$bus" "$SYS/bus/usb/devices/usb$bus"
}

# add_usb_device <port> <vid> <pid> [product]: plain USB device (e.g. a hub).
add_usb_device() {
    local port="$1" vid="$2" pid="$3" product="${4:-Device}" bus parent d
    bus="${port%%-*}"
    parent=$(readlink -f "$SYS/bus/usb/devices/usb$bus")
    # Nest under the upstream hub for multi-level ports (1-3.1 lives in 1-3/).
    if [[ "$port" == *.* ]]; then
        parent=$(readlink -f "$SYS/bus/usb/devices/${port%.*}")
    fi
    d="$parent/$port"
    mkdir -p "$d"
    printf '%s\n' "$vid" >"$d/idVendor"
    printf '%s\n' "$pid" >"$d/idProduct"
    printf '%s\n' "$product" >"$d/product"
    printf 'ACME\n' >"$d/manufacturer"
    ln -s "$(realpath --relative-to="$SYS/bus/usb/devices" "$d")" "$SYS/bus/usb/devices/$port"
}

# add_usb_card <card#> <port> <vid> <pid> <id> [product]: USB audio device with
# interface <port>:1.0 carrying sound/card<N>.
add_usb_card() {
    local n="$1" port="$2" vid="$3" pid="$4" id="$5" product="${6:-USB Audio}" dev intf card
    add_usb_device "$port" "$vid" "$pid" "$product"
    dev=$(readlink -f "$SYS/bus/usb/devices/$port")
    intf="$dev/$port:1.0"
    card="$intf/sound/card$n"
    mkdir -p "$card"
    printf '%s\n' "$id" >"$card/id"
    ln -s "../.." "$card/device"
    ln -s "$(realpath --relative-to="$SYS/class/sound" "$card")" "$SYS/class/sound/card$n"
    mkdir -p "$intf/sound/controlC$n"
    ln -s "$(realpath --relative-to="$SYS/class/sound" "$intf/sound/controlC$n")" "$SYS/class/sound/controlC$n"
}

# add_pci_card <card#> <id>: on-board (non-USB) sound card.
add_pci_card() {
    local n="$1" id="$2" card
    card="$SYS/devices/pci0000:00/0000:00:1f.3/sound/card$n"
    mkdir -p "$card"
    printf '%s\n' "$id" >"$card/id"
    ln -s "../.." "$card/device"
    ln -s "$(realpath --relative-to="$SYS/class/sound" "$card")" "$SYS/class/sound/card$n"
}

# Standard topology: on-board card0; three identical 46f4:0002 mics on 1-1,
# 1-2 and 1-3.1 (behind a hub on 1-3); one different device on 1-4.
standard_topology() {
    add_controller 1 0000:00:14.0
    add_pci_card 0 PCH
    add_usb_card 1 1-1 46f4 0002 Audio "QEMU USB Audio"
    add_usb_card 2 1-2 46f4 0002 Audio_1 "QEMU USB Audio"
    add_usb_device 1-3 0409 55aa "Hub"
    add_usb_card 3 1-3.1 46f4 0002 Audio_2 "QEMU USB Audio"
    add_usb_card 4 1-4 2e88 4610 Mini "MOVO X1 MINI"
}

mapper() { "${MAPPER_BASH:-bash}" "$MAPPER" --rules-file "$RULES" "$@"; }

# Call one of the script's functions in a child bash that sourced the script,
# i.e. under the script's own `set -euo pipefail`. (Sourcing into the bats
# process would replace bats' shell options and traps and silently disable
# assertion failures.)
# shellcheck disable=SC2016  # $1/$@ expand in the child shell
fn() { "${MAPPER_BASH:-bash}" -c 'source "$1"; shift; "$@"' fn "$MAPPER" "$@"; }

active_lines() { grep -cvE '^[[:space:]]*(#|$)' "$1" || true; }

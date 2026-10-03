#!/usr/bin/env bats
# Tests for usb-audio-mapper.sh. Same tests as tests/usb-audio-mapper.bats in
# the standalone usb-audio-mapper repository (only the helper name differs),
# which also holds the QEMU end-to-end suite (real kernel + real udev).
# Keep the two in sync.
load usb_audio_mapper_helper

setup() {
    setup_env
    standard_topology
}

# --- rule generation --------------------------------------------------------

@test "generated block: one comment + two active rules, port-pinned, card/controlC gated" {
    out=$(fn generate_udev_rules 46f4 0002 mic-left "QEMU USB Audio" 1-1)
    [ "$(printf '%s\n' "$out" | wc -l)" -eq 3 ]
    [ "$(printf '%s\n' "$out" | grep -vc '^#')" -eq 2 ]
    printf '%s\n' "$out" | grep -qx '# usb-audio-mapper: name=mic-left usb=46f4:0002 port=1-1 path=- desc=QEMU USB Audio'
    printf '%s\n' "$out" | grep -qx 'SUBSYSTEM=="sound", KERNEL=="card\*", ACTION=="add|change", ATTRS{idVendor}=="46f4", ATTRS{idProduct}=="0002", KERNELS=="1-1", ATTR{id}!="mic-left", ATTR{id}="mic-left", ENV{USB_AUDIO_MAPPER}="mic-left"'
    printf '%s\n' "$out" | grep -qx 'SUBSYSTEM=="sound", KERNEL=="controlC\*", ACTION=="add|change", ATTRS{idVendor}=="46f4", ATTRS{idProduct}=="0002", KERNELS=="1-1", SYMLINK+="sound/by-id/mic-left", ENV{USB_AUDIO_MAPPER}="mic-left"'
    [[ "$out" != *'\n'* ]]
    fn assert_rules_safe "$out"
}

@test "generated block with ID_PATH: imports path_id and matches the card's ID_PATH, not KERNELS" {
    out=$(fn generate_udev_rules 46f4 0002 mic-left "x" 1-1 pci-0000:00:14.0-usb-0:1:1.0)
    printf '%s\n' "$out" | grep -qx '# usb-audio-mapper: name=mic-left usb=46f4:0002 port=1-1 path=pci-0000:00:14.0-usb-0:1:1.0 desc=x'
    [ "$(printf '%s\n' "$out" | grep -c 'IMPORT{builtin}="path_id", ENV{ID_PATH}=="pci-0000:00:14.0-usb-0:1:1.0"')" -eq 2 ]
    ! printf '%s\n' "$out" | grep -q KERNELS || false
    fn assert_rules_safe "$out"
    run fn generate_udev_rules 46f4 0002 mic x 1-1 'pci-0000"x'
    [ "$status" -ne 0 ]
}

@test "generated block parses with udevadm verify (when available)" {
    [ -n "$REAL_UDEVADM" ] && "$REAL_UDEVADM" verify --help >/dev/null 2>&1 || skip "udevadm verify not available"
    { fn generate_udev_rules 46f4 0002 mic-left "x" 1-3.1; fn generate_udev_rules 46f4 0002 mic-b x 1-1 pci-0000:00:14.0-usb-0:1:1.0; } >"$T/a.rules"
    run "$REAL_UDEVADM" verify --no-style "$T/a.rules"
    [ "$status" -eq 0 ]
}

@test "no port: rule matches by VID:PID only (no KERNELS)" {
    out=$(fn generate_udev_rules 46f4 0002 mic "d" "")
    ! printf '%s\n' "$out" | grep -q KERNELS || false
    printf '%s\n' "$out" | grep -q 'port=any'
}

@test "description cannot inject udev keys (newline, quotes, RUN+=)" {
    evil=$(printf 'x"\nRUN+="/bin/sh -c evil"\n#')
    out=$(fn generate_udev_rules 46f4 0002 mic "$evil" 1-1)
    [ "$(printf '%s\n' "$out" | wc -l)" -eq 3 ]
    ! printf '%s\n' "$out" | grep -qE 'RUN[+]=|PROGRAM|IMPORT' || false
    fn assert_rules_safe "$out"
}

@test "generate_udev_rules refuses unvalidated input" {
    run fn generate_udev_rules 46f4 0002 mic d '1-1", RUN+="x'
    [ "$status" -ne 0 ]
    run fn generate_udev_rules 46f4 0002 'Bad Name' d 1-1
    [ "$status" -ne 0 ]
    run fn generate_udev_rules 46f 0002 mic d 1-1
    [ "$status" -ne 0 ]
}

@test "assert_rules_safe rejects a tampered line" {
    good=$(fn generate_udev_rules 46f4 0002 mic d 1-1)
    run fn assert_rules_safe "${good/ENV\{USB_AUDIO_MAPPER\}/RUN+=\"/bin/x\", ENV{USB_AUDIO_MAPPER\}}"
    [ "$status" -ne 0 ]
    run fn assert_rules_safe "$(printf '%s\nRUN+="/bin/x"' "$good")"
    [ "$status" -ne 0 ]
}

# --- names ------------------------------------------------------------------

@test "name_problem accepts valid ALSA ids" {
    for n in a mic-left mic1 abcdefghijklmno x-y-z; do
        fn name_problem "$n" || { echo "rejected $n"; return 1; }
    done
}

@test "name_problem rejects what the kernel would truncate or refuse" {
    for n in "" abcdefghijklmnop Mic mic_1 1mic -mic "mic left" card card-1 cards pcm oss seq timers \
        "$(printf 'mic\nRUN')"; do
        if fn name_problem "$n" >/dev/null; then echo "accepted [$n]"; return 1; fi
    done
}

@test "suggest_name always yields a valid name" {
    [ "$(fn suggest_name 'USB Audio Device')" = "usb-audio-devic" ]
    [ "$(fn suggest_name 'C-Media')" = "c-media" ]
    [ "$(fn suggest_name 'Card9')" = "usb-card9" ]
    [ "$(fn suggest_name '123')" = "usb-123" ]
    for raw in "" "---" "Микрофон" "a__b" "USB-Audio------------x"; do
        s=$(fn suggest_name "$raw")
        fn name_problem "$s" || { echo "[$raw] -> invalid [$s]"; return 1; }
    done
}

# --- ports ------------------------------------------------------------------

@test "normalize_usb_port accepts kernel, usb- and /proc/asound/cards forms" {
    [ "$(fn normalize_usb_port 1-2)" = 1-2 ]
    [ "$(fn normalize_usb_port 1-3.1)" = 1-3.1 ]
    [ "$(fn normalize_usb_port usb-1-2)" = 1-2 ]
    [ "$(fn normalize_usb_port usb-0000:00:14.0-2)" = 1-2 ]
    [ "$(fn normalize_usb_port usb-0000:00:14.0-3.1)" = 1-3.1 ]
}

@test "normalize_usb_port rejects injection, synthetic and malformed ports" {
    evil=$(printf '1-2" GOTO="end\nRUN+="/bin/rm -rf /"\nLABEL="end')
    for bad in "$evil" bus3-dev5 3 a-b 1-2:1.0 "" usb-3.4 ../1-2 "1-2 " 1-2. usb-0000:00:14.0-9; do
        if fn normalize_usb_port "$bad" >/dev/null 2>&1; then echo "accepted [$bad]"; return 1; fi
    done
}

# --- discovery --------------------------------------------------------------

@test "card_usb_port resolves direct and hub-attached cards, rejects non-USB" {
    [ "$(fn card_usb_port 1)" = 1-1 ]
    [ "$(fn card_usb_port 3)" = 1-3.1 ]
    run fn card_usb_port 0
    [ "$status" -ne 0 ]
}

@test "find_ports_by_id lists every identical device" {
    [ "$(fn find_ports_by_id 46f4 0002 | sort | tr '\n' ' ')" = "1-1 1-2 1-3.1 " ]
    [ "$(fn find_ports_by_id 2e88 4610)" = "1-4" ]
    [ -z "$(fn find_ports_by_id dead beef)" ]
}

# --- CLI: mapping -----------------------------------------------------------

@test "--card maps by port and verifies the rename" {
    export STUB_RENAME="$(readlink -f "$SYS/class/sound/card2")=mic-right"
    run mapper -n --card 2 -f mic-right
    [ "$status" -eq 0 ]
    grep -q 'ENV{ID_PATH}=="pci-0000:00:14.0-usb-0:2:1.0"' "$RULES"
    grep -q 'name=mic-right usb=46f4:0002 port=1-2 path=pci-0000:00:14.0-usb-0:2:1.0' "$RULES"
    ! grep -q KERNELS "$RULES" || false
    [ "$(active_lines "$RULES")" -eq 2 ]
    [[ "$output" == *"Verified: card 2 is now 'mic-right'"* ]]
    grep -q 'udevadm control --reload' "$STUB_LOG"
    grep -q "udevadm trigger --action=change $SYS/class/sound/card2" "$STUB_LOG"
    grep -q 'logger -t usb-audio-mapper -- mapped 46f4:0002 port=1-2 path=pci-0000:00:14.0-usb-0:2:1.0 -> mic-right' "$STUB_LOG"
}

@test "exit 6 when the rule was written but the card was not renamed" {
    run mapper -n --card 1 -f mic-left
    [ "$status" -eq 6 ]
    [[ "$output" == *"still named 'Audio'"* ]]
    grep -q 'mic-left' "$RULES"
}

@test "verification names the card that already holds the requested name" {
    printf 'mic-left\n' >"$SYS/class/sound/card2/id"
    run mapper -n --card 1 -f mic-left
    [ "$status" -eq 6 ]
    [[ "$output" == *"Card 2 (port 1-2) currently uses the name 'mic-left'"* ]]
    [[ "$output" == *"Card 2 still holds the name 'mic-left'"* ]]
}

@test "-v/-p with several identical devices and no port is refused (exit 5)" {
    run mapper -n -v 46f4 -p 0002 -f mic
    [ "$status" -eq 5 ]
    [[ "$output" == *"1-1 1-2 1-3.1"* ]]
    [ ! -e "$RULES" ]
}

@test "-v/-p with exactly one device ties the rule to its current port" {
    run mapper -n -v 2E88 -p 4610 -f movo --no-apply
    [ "$status" -eq 0 ]
    grep -q 'ATTRS{idVendor}=="2e88", ATTRS{idProduct}=="4610", IMPORT{builtin}="path_id", ENV{ID_PATH}=="pci-0000:00:14.0-usb-0:4:1.0"' "$RULES"
}

@test "-u selects one of several identical devices (incl. behind a hub)" {
    run mapper -n -v 46f4 -p 0002 -u 1-3.1 -f mic-hub --no-apply
    [ "$status" -eq 0 ]
    grep -q 'ENV{ID_PATH}=="pci-0000:00:14.0-usb-0:3.1:1.0"' "$RULES"
}

@test "-u accepts the /proc/asound/cards port form" {
    run mapper -n -v 46f4 -p 0002 -u usb-0000:00:14.0-2 -f mic-b --no-apply
    [ "$status" -eq 0 ]
    grep -q 'port=1-2 path=pci-0000:00:14.0-usb-0:2:1.0' "$RULES"
}

@test "-u with an invalid value fails without writing (no silent VID:PID fallback)" {
    run mapper -n -v 46f4 -p 0002 -u "usb-3.4" -f mic
    [ "$status" -eq 2 ]
    [ ! -e "$RULES" ]
}

@test "device not connected: VID:PID rule with a warning (pre-provisioning)" {
    run mapper -n -v dead -p beef -f future --no-apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"No dead:beef device is connected"* ]]
    ! grep -q KERNELS "$RULES" || false
}

@test "--any-port forces a VID:PID-only rule" {
    run mapper -n -v 2e88 -p 4610 --any-port -f movo --no-apply
    [ "$status" -eq 0 ]
    ! grep -q KERNELS "$RULES" || false
}

@test "--card contradicting -v/-p or -u is a usage error" {
    run mapper -n --card 1 -v 2e88 -p 4610 -f x
    [ "$status" -eq 2 ]
    run mapper -n --card 1 -u 1-2 -f x
    [ "$status" -eq 2 ]
    run mapper -n --card 0 -f x
    [ "$status" -eq 5 ]
    run mapper -n --card 9 -f x
    [ "$status" -eq 5 ]
}

@test "invalid names are rejected before anything is written" {
    for n in abcdefghijklmnop card-x pcm Mic; do
        run mapper -n --card 1 -f "$n"
        [ "$status" -eq 2 ]
    done
    [ ! -e "$RULES" ]
}

# --- rules file maintenance -------------------------------------------------

@test "re-mapping a name replaces its block; different names accumulate" {
    mapper -n --card 1 -f mic-a --no-apply
    mapper -n --card 2 -f mic-b --no-apply
    mapper -n --card 3 -f mic-a --no-apply
    [ "$(grep -c 'name=mic-a' "$RULES")" -eq 1 ]
    grep -q 'name=mic-a usb=46f4:0002 port=1-3.1' "$RULES"
    grep -q 'name=mic-b usb=46f4:0002 port=1-2' "$RULES"
    [ "$(active_lines "$RULES")" -eq 4 ]
    ! grep -q '^$' <(sed -n '1{/^$/p}' "$RULES") || false
}

@test "mapping a new name to an already-mapped port replaces the old mapping" {
    mapper -n --card 1 -f old-name --no-apply
    run mapper -n --card 1 -f new-name --no-apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removing mapping 'old-name'"* ]]
    ! grep -q old-name "$RULES" || false
    [ "$(active_lines "$RULES")" -eq 2 ]
}

@test "legacy rules for the same name are migrated; unrelated lines kept verbatim" {
    cat >"$RULES" <<'RULES'
# my own rule, keep me
SUBSYSTEM=="input", ATTRS{idVendor}=="1234", MODE="0660"
# USB Sound Card: Old v3\nSUBSYSTEM=="sound", ATTRS{idVendor}=="46f4", ATTRS{idProduct}=="0002", KERNELS=="1-1", ATTR{id}="mic-left", SYMLINK+="sound/by-id/mic-left"
# USB Sound Card: Lyrebird 1.2.1
SUBSYSTEM=="sound", ATTRS{idVendor}=="46f4", ATTRS{idProduct}=="0002", ENV{ID_PATH}=="pci-0000:00:14.0-usb-0:1", ATTR{id}="mic-left", SYMLINK+="sound/by-id/mic-left"
SUBSYSTEM=="sound", KERNELS=="1-1*", ATTRS{idVendor}=="46f4", ATTRS{idProduct}=="0002", ATTR{id}="mic-left"
# USB Sound Card: Other device
SUBSYSTEM=="sound", ATTRS{idVendor}=="2e88", ATTRS{idProduct}=="4610", ATTR{id}="movo"
RULES
    run mapper -n --card 1 -f mic-left --no-apply
    [ "$status" -eq 0 ]
    [ "$(grep -c 'mic-left' "$RULES")" -eq 3 ]
    ! grep -q 'Lyrebird 1.2.1\|Old v3\|ID_PATH}=="pci-0000:00:14.0-usb-0:1"' "$RULES" || false
    grep -qx '# my own rule, keep me' "$RULES"
    grep -qx 'SUBSYSTEM=="input", ATTRS{idVendor}=="1234", MODE="0660"' "$RULES"
    grep -qx '# USB Sound Card: Other device' "$RULES"
    grep -qx 'SUBSYSTEM=="sound", ATTRS{idVendor}=="2e88", ATTRS{idProduct}=="4610", ATTR{id}="movo"' "$RULES"
}

@test "--remove deletes exactly one mapping" {
    mapper -n --card 1 -f mic-a --no-apply
    mapper -n --card 2 -f mic-b --no-apply
    before_b=$(grep 'mic-b' "$RULES")
    run mapper --remove mic-a
    [ "$status" -eq 0 ]
    ! grep -q mic-a "$RULES" || false
    [ "$(grep 'mic-b' "$RULES")" = "$before_b" ]
    run mapper --remove mic-a
    [ "$status" -eq 5 ]
}

@test "--dry-run prints rules and writes nothing" {
    run "${MAPPER_BASH:-bash}" "$MAPPER" --rules-file /nonexistent/dir/x.rules -n --card 3 -f mic-hub --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *'ENV{ID_PATH}=="pci-0000:00:14.0-usb-0:3.1:1.0"'* ]]
    [ ! -e /nonexistent/dir ]
    ! grep -qE 'udevadm (control|trigger)|logger' "$STUB_LOG" || false
}

@test "dry-run stdout is only the rule block (diagnostics on stderr)" {
    out=$(mapper -n --card 1 -f mic --dry-run 2>/dev/null)
    [ "$(printf '%s\n' "$out" | wc -l)" -eq 3 ]
}

@test "a failed udevadm verify leaves the rules file untouched and no temp files" {
    mapper -n --card 1 -f mic-a --no-apply
    cp "$RULES" "$T/before"
    export STUB_VERIFY_FAIL=1
    run mapper -n --card 2 -f mic-b --no-apply
    [ "$status" -ne 0 ]
    [[ "$output" == *"udevadm verify rejected"* ]]
    cmp "$RULES" "$T/before"
    [ -z "$(find "$T/rules.d" -name '.usb-audio-mapper.*' ! -name '*.lock')" ]
}

@test "successful writes leave no temp files and mode 0644" {
    mapper -n --card 1 -f mic-a --no-apply
    [ -z "$(find "$T/rules.d" -name '.usb-audio-mapper.*' ! -name '*.lock')" ]
    [ "$(stat -c %a "$RULES")" = 644 ]
}

@test "concurrent runs do not lose updates" {
    command -v flock >/dev/null || skip "flock not available"
    for i in 1 2 3 4 5 6 7 8; do
        "${MAPPER_BASH:-bash}" "$MAPPER" --rules-file "$RULES" -n -v dead -p beef -u "2-$i" -f "m$i" --no-apply >/dev/null 2>&1 &
    done
    wait
    [ "$(grep -c '^# usb-audio-mapper: name=' "$RULES")" -eq 8 ]
}

@test "unwritable rules location is a permission error (exit 3)" {
    printf 'x' >"$T/notadir"
    run "${MAPPER_BASH:-bash}" "$MAPPER" --rules-file "$T/notadir/x.rules" -n --card 1 -f mic
    [ "$status" -eq 3 ]
}

# --- listing / misc -----------------------------------------------------------

@test "--list shows USB cards, ports and mapped names (not the on-board card)" {
    mapper -n --card 3 -f mic-hub --no-apply
    run mapper --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"46f4:0002  1-3.1      mic-hub"* ]]
    [[ "$output" == *"2e88:4610  1-4"* ]]
    [[ "$output" != *"PCH"* ]]
}

@test "--list flags legacy rules" {
    printf '%s\n' 'SUBSYSTEM=="sound", ATTRS{idVendor}=="2e88", ATTR{id}="movo"' >"$RULES"
    run mapper --list
    [[ "$output" == *"Legacy (pre-v4) rules for: movo"* ]]
}

@test "-t lists USB devices with ports" {
    run mapper -t
    [ "$status" -eq 0 ]
    [[ "$output" == *"1-3.1"*"46f4:0002"*"yes"* ]]
    [[ "$output" == *"1-3 "*"0409:55aa"*"no"* ]]
}

@test "usage errors exit 2" {
    run mapper --bogus
    [ "$status" -eq 2 ]
    run mapper -n -f
    [ "$status" -eq 2 ]
    run mapper -n -v 46f4 -p 0002 -u 1-1 --any-port -f x
    [ "$status" -eq 2 ]
    run mapper -n -f mic
    [ "$status" -eq 2 ]
}

@test "--help and --version" {
    run mapper --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--usb-port"* ]]
    run mapper --version
    [[ "$output" =~ ^usb-audio-mapper\ [0-9]+\.[0-9]+\.[0-9]+$ ]]
}

@test "sourcing the script does not run main" {
    run bash -c "source '$MAPPER'; echo sourced-ok"
    [ "$status" -eq 0 ]
    [ "$output" = "sourced-ok" ]
}

# --- interactive --------------------------------------------------------------

@test "interactive: choose card, accept port, name, confirm" {
    export STUB_RENAME="$(readlink -f "$SYS/class/sound/card4")=movo"
    run bash -c "printf '4\ny\nmovo\ny\n' | "${MAPPER_BASH:-bash}" '$MAPPER' --rules-file '$RULES'"
    [ "$status" -eq 0 ]
    grep -q 'name=movo usb=2e88:4610 port=1-4' "$RULES"
}

@test "interactive: identical devices force port matching; bad input is retried" {
    run bash -c "printf 'x\n2\nBad_Name\nmic-2\ny\n' | "${MAPPER_BASH:-bash}" '$MAPPER' --rules-file '$RULES' --no-apply"
    [ "$status" -eq 0 ]
    [[ "$output" == *"identical device(s) also connected"* ]]
    grep -q 'name=mic-2 usb=46f4:0002 port=1-2' "$RULES"
}

@test "interactive: default name and 'n' at confirmation changes nothing" {
    run bash -c "printf '4\ny\n\nn\n' | "${MAPPER_BASH:-bash}" '$MAPPER' --rules-file '$RULES'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[mini]"* ]]
    [ ! -e "$RULES" ]
}

@test "interactive: end of input exits 2 without writing" {
    run bash -c "printf '4\n' | "${MAPPER_BASH:-bash}" '$MAPPER' --rules-file '$RULES'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"No input"* ]]
    [ ! -e "$RULES" ]
}

@test "re-running an identical mapping leaves the file byte-identical" {
    mapper -n --card 1 -f mic-a --no-apply
    mapper -n --card 2 -f mic-b --no-apply
    cp "$RULES" "$T/before"
    run mapper -n --card 1 -f mic-a --no-apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"already in"* ]]
    cmp "$RULES" "$T/before"
}

@test "works without /dev/fd (no process substitution)" {
    ! grep -n '< <(' "$MAPPER" || false
    ! grep -nE '>[[:space:]]*>?\(' "$MAPPER" || false
}

@test "description has no stray space when the device has no manufacturer string" {
    rm "$SYS/bus/usb/devices/1-4/manufacturer"
    run mapper --list
    [[ "$output" == *"1-4        -                MOVO X1 MINI"* ]]
}

@test "no ID_PATH available: falls back to KERNELS and warns about bus numbers" {
    export STUB_NO_PATHID=1
    run mapper -n --card 2 -f mic-right --no-apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"Port numbers include the USB bus number"* ]]
    grep -q 'KERNELS=="1-2"' "$RULES"
    grep -q 'port=1-2 path=- ' "$RULES"
}

@test "-u for a port with nothing connected: KERNELS rule with the bus-number warning" {
    run mapper -n -v 46f4 -p 0002 -u 1-7 -f later --no-apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"Nothing is connected to port 1-7"* ]]
    [[ "$output" == *"Port numbers include the USB bus number"* ]]
    grep -q 'KERNELS=="1-7"' "$RULES"
}

@test "-u for a port holding a different device does not borrow that device's ID_PATH" {
    run mapper -n -v 46f4 -p 0002 -u 1-4 -f wrong-dev --no-apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"Port 1-4 currently holds 2e88:4610"* ]]
    grep -q 'KERNELS=="1-4"' "$RULES"
    ! grep -q 'usb-0:4:1.0' "$RULES" || false
}

@test "--list matches ID_PATH mappings even after the bus number changes" {
    mapper -n --card 3 -f mic-hub --no-apply
    # Same controller and port chain, new bus number (2 instead of 1).
    rm -rf "$SYS"
    mkdir -p "$SYS/class/sound" "$SYS/bus/usb/devices"
    add_controller 2 0000:00:14.0
    add_usb_device 2-3 0409 55aa "Hub"
    add_usb_card 0 2-3.1 46f4 0002 Audio "QEMU USB Audio"
    run mapper --list
    [[ "$output" == *"46f4:0002  2-3.1      mic-hub"* ]]
}

@test "re-mapping the same device after a bus renumbering replaces its block" {
    mapper -n --card 3 -f mic-hub --no-apply
    rm -rf "$SYS"
    mkdir -p "$SYS/class/sound" "$SYS/bus/usb/devices"
    add_controller 2 0000:00:14.0
    add_usb_device 2-3 0409 55aa "Hub"
    add_usb_card 0 2-3.1 46f4 0002 Audio "QEMU USB Audio"
    run mapper -n --card 0 -f mic-new --no-apply
    [ "$status" -eq 0 ]
    [[ "$output" == *"Removing mapping 'mic-hub'"* ]]
    [ "$(grep -c '^# usb-audio-mapper: name=' "$RULES")" -eq 1 ]
}

@test "refuses cleanly on a non-Linux system (e.g. macOS), also when sourced" {
    mkdir -p "$T/darwin"
    printf '#!/bin/sh\necho Darwin\n' >"$T/darwin/uname"
    chmod +x "$T/darwin/uname"
    run env PATH="$T/darwin:$PATH" bash "$MAPPER" --list
    [ "$status" -eq 4 ]
    [[ "$output" == *"manages Linux udev rules; it cannot run on Darwin"* ]]
    run env PATH="$T/darwin:$PATH" bash -c 'source "$1"; echo "caller continues rc=$?"' _ "$MAPPER"
    [[ "$output" == *"caller continues rc=4"* ]]
}

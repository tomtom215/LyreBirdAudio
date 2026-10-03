#!/usr/bin/env bash
# usb-audio-mapper.sh - Persistent, port-aware names for USB audio devices
#
# Part of LyreBirdAudio - RTSP Audio Streaming Suite
# https://github.com/tomtom215/LyreBirdAudio
# Standalone home: https://github.com/tomtom215/usb-audio-mapper
#
# Author: Tom F (https://github.com/tomtom215)
# Copyright: Tom F and LyreBirdAudio contributors
# License: Apache 2.0
#
# Writes udev rules that give a USB sound card a fixed ALSA card id (the name
# shown in /proc/asound/cards and usable as hw:CARD=<name>) plus a
# /dev/sound/by-id/<name> symlink to its control device. Identical devices are
# told apart by the physical USB port they are plugged into.
#
# Generated rule format (v4), one block per mapping:
#   # usb-audio-mapper: name=<name> usb=<vid>:<pid> port=<port|any> path=<id_path|-> desc=<text>
#   SUBSYSTEM=="sound", KERNEL=="card*", ACTION=="add|change", ATTRS{idVendor}=="<vid>",
#     ATTRS{idProduct}=="<pid>", <location>, ATTR{id}!="<name>", ATTR{id}="<name>",
#     ENV{USB_AUDIO_MAPPER}="<name>"
#   SUBSYSTEM=="sound", KERNEL=="controlC*", ACTION=="add|change", (same match),
#     SYMLINK+="sound/by-id/<name>", ENV{USB_AUDIO_MAPPER}="<name>"
# where <location> is IMPORT{builtin}="path_id", ENV{ID_PATH}=="<id_path>" when
# the device was connected at mapping time, KERNELS=="<port>" when it was not,
# and absent for --any-port (each rule is a single physical line in the file).
#
# Why this shape (each point verified on a real kernel + systemd-udevd, see
# tests/e2e/):
#   - KERNEL=="card*": ATTR{id} only exists on the card device; SYMLINK only
#     makes sense on a device node, so it goes on controlC<n> alone.
#   - ENV{ID_PATH} of the card itself (imported with path_id, so it is set on
#     "add" events too): controller path + port chain with the USB bus number
#     dropped. KERNELS=="<bus>-<port>" contains the bus number, and when bus
#     numbers change between boots (e.g. two host-controller drivers loading in
#     a different order) a KERNELS rule names the WRONG device. KERNELS is only
#     used when the device is not connected at mapping time. ATTRS{} and
#     KERNELS are matched on the same ancestor, so a port rule never captures a
#     device behind a hub on that port.
#   - ATTR{id}!="<name>": the kernel rejects re-assigning a card its current id
#     with EEXIST; the guard makes the rule idempotent on change events.
#   - The ID_PATH is the SOUND CARD's (...-usb-0:1:1.0), not the USB device
#     node's (...-usb-0:1): rules built from the latter never matched (bug in
#     <= v3.0.0 and LyreBirdAudio <= 1.2.1).

# Refuse early and clearly where the script cannot work. Kept to bash 3.2
# syntax (macOS ships bash 3.2, and this must run there to say so), and placed
# before `set -e` so that a shell sourcing this file is not terminated.
# shellcheck disable=SC2317  # "exit" runs when executed, "return" when sourced
if [[ "$(uname -s 2>/dev/null)" != "Linux" ]]; then
    printf 'ERROR: usb-audio-mapper manages Linux udev rules; it cannot run on %s.\n' "$(uname -s 2>/dev/null || echo this system)" >&2
    return 4 2>/dev/null || exit 4
fi
if [[ -z "${BASH_VERSINFO[0]:-}" || "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    printf 'ERROR: bash 4.0 or newer is required (found %s)\n' "${BASH_VERSION:-unknown}" >&2
    return 4 2>/dev/null || exit 4
fi

set -euo pipefail
# Byte-wise, locale-independent behavior for tr/sort/awk and regex ranges.
export LC_ALL=C

readonly SCRIPT_VERSION="4.0.0"

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# Default rules file; override with --rules-file.
readonly DEFAULT_RULES_FILE="/etc/udev/rules.d/99-usb-soundcards.rules"
RULES_FILE="$DEFAULT_RULES_FILE"

# sysfs root. Overridable ONLY so the test suite can point the script at a
# fake sysfs tree; never needed in normal use.
SYSFS_ROOT="${USB_AUDIO_MAPPER_SYSFS:-/sys}"

# ALSA limits, from the kernel (sound/core/init.c, sound/core/info.c):
#   - card->id is char[16]: writes are silently truncated to 15 characters.
#   - ids that start with "card" or equal a reserved word are refused (EEXIST).
readonly MAX_NAME_LENGTH=15
readonly RESERVED_NAMES=" version meminfo memdebug detect devices oss cards timers synth pcm seq "
readonly MAX_DESC_LENGTH=64

# Pattern of a USB device's kernel name: <bus>-<port>[.<port>...] (drivers/usb/core/usb.c).
readonly USB_PORT_RE='^[0-9]+-[0-9]+(\.[0-9]+)*$'
readonly NAME_RE='^[a-z][a-z0-9-]*$'
readonly HEX4_RE='^[0-9a-fA-F]{4}$'
# udev path_id value, e.g. pci-0000:00:14.0-usb-0:1.2:1.0 (no quotes/spaces).
readonly IDPATH_RE='^[A-Za-z0-9][A-Za-z0-9:._+-]*$'

# Exit codes
readonly E_ERROR=1
readonly E_USAGE=2
readonly E_PERMISSION=3
readonly E_DEPENDENCY=4
readonly E_DEVICE=5
readonly E_VERIFY=6

DEBUG="${DEBUG:-false}"
CLEANUP_FILES=()
USE_COLOR=false
if [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    USE_COLOR=true
fi

# ----------------------------------------------------------------------------
# Output helpers. Diagnostics go to stderr so stdout carries only data
# (generated rules, listings) and can be piped.
# ----------------------------------------------------------------------------

_msg() {
    local color="$1" label="$2" message="$3"
    if [[ "$USE_COLOR" == "true" ]]; then
        printf '\033[%sm%s:\033[0m %s\n' "$color" "$label" "$message" >&2
    else
        printf '%s: %s\n' "$label" "$message" >&2
    fi
}
info() { _msg 34 INFO "${1:-}"; }
success() { _msg 32 OK "${1:-}"; }
warning() { _msg 33 WARNING "${1:-}"; }
error() { _msg 31 ERROR "${1:-}"; }
debug() {
    if [[ "$DEBUG" == "true" || "$DEBUG" == "1" || "$DEBUG" == "yes" ]]; then
        _msg 35 DEBUG "${1:-}"
    fi
    return 0
}

error_exit() {
    error "${1:-Unknown error occurred}"
    exit "${2:-$E_ERROR}"
}

cleanup() {
    local file
    for file in ${CLEANUP_FILES[@]+"${CLEANUP_FILES[@]}"}; do
        [[ -n "$file" && -e "$file" ]] && rm -f -- "$file"
    done
    return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Log a change to syslog when available (audit trail for root changes).
audit_log() {
    if command -v logger >/dev/null 2>&1; then
        logger -t usb-audio-mapper -- "$1" 2>/dev/null || true
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Validation
# ----------------------------------------------------------------------------

# Strict decimal parse (rejects octal-looking input such as "08" turning into an error).
safe_base10() {
    local val="${1:-}"
    [[ "$val" =~ ^[0-9]+$ ]] || return 1
    val="${val#"${val%%[!0]*}"}"
    printf '%d' "${val:-0}"
}

# Explain why NAME is not a usable ALSA card id; print nothing and succeed if it is.
name_problem() {
    local name="${1:-}"
    if [[ -z "$name" ]]; then
        printf 'name is empty'
    elif ((${#name} > MAX_NAME_LENGTH)); then
        printf "'%s' is %d characters; ALSA card ids hold at most %d (the kernel silently truncates longer ones)" \
            "$name" "${#name}" "$MAX_NAME_LENGTH"
    elif ! [[ "$name" =~ $NAME_RE ]]; then
        printf "'%s' must start with a lowercase letter and contain only lowercase letters, digits and hyphens" "$name"
    elif [[ "$name" == card* ]]; then
        printf "'%s' starts with \"card\", which the kernel refuses as a card id" "$name"
    elif [[ "$RESERVED_NAMES" == *" $name "* ]]; then
        printf "'%s' is reserved by ALSA and refused by the kernel" "$name"
    else
        return 0
    fi
    return 1
}

validate_name() {
    local problem
    if problem=$(name_problem "${1:-}"); then
        return 0
    fi
    error_exit "Invalid friendly name: $problem." "$E_USAGE"
}

# Derive a valid default name from free text (card id / product string).
suggest_name() {
    local raw="${1:-}" name
    name=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | tr -s '-')
    name="${name#-}"
    if [[ -z "$name" || ! "$name" =~ ^[a-z] || "$name" == card* ]]; then
        name="usb-${name}"
    fi
    name="${name:0:$MAX_NAME_LENGTH}"
    while [[ "$name" == *- ]]; do name="${name%-}"; done
    if ! name_problem "$name" >/dev/null; then
        name="usb-audio"
    fi
    printf '%s' "$name"
}

# Comment text: printable, no quotes/newlines, bounded length.
sanitize_desc() {
    local desc
    desc=$(printf '%s' "${1:-}" | tr -c '[:alnum:] ._()-' ' ' | tr -s ' ')
    desc="${desc# }"
    desc="${desc% }"
    printf '%s' "${desc:0:$MAX_DESC_LENGTH}"
}

# Normalize a user-supplied port to the kernel's <bus>-<port>[.<port>...] form.
# Accepts:
#   1-2, 1-2.3                  (kernel name, as shown by --list)
#   usb-1-2                     (legacy prefix; stripped)
#   usb-0000:00:14.0-2.3        (the form printed in /proc/asound/cards; also
#   usb-xhci-hcd.0.auto-1.2      platform controllers; needs the device
#                                connected to resolve the bus number)
# Prints the normalized port; fails (with a reason on stderr) otherwise.
normalize_usb_port() {
    local input="${1:-}" port
    if [[ "$input" =~ $USB_PORT_RE ]]; then
        printf '%s' "$input"
        return 0
    fi
    if [[ "$input" == usb-* ]]; then
        port="${input#usb-}"
        if [[ "$port" =~ $USB_PORT_RE ]]; then
            printf '%s' "$port"
            return 0
        fi
    fi
    # The controller name may itself contain '-' (xhci-hcd.0.auto on dwc3
    # boards); the greedy group leaves only the trailing port chain.
    if [[ "$input" =~ ^usb-([0-9A-Za-z:._-]+)-([0-9]+(\.[0-9]+)*)$ ]]; then
        local controller="${BASH_REMATCH[1]}" devpath="${BASH_REMATCH[2]}" hub ctrl bus
        for hub in "$SYSFS_ROOT"/bus/usb/devices/usb[0-9]*; do
            [[ -e "$hub" ]] || continue
            ctrl=$(basename "$(dirname "$(readlink -f "$hub")")")
            bus="${hub##*/usb}"
            if [[ "$ctrl" == "$controller" && -d "$SYSFS_ROOT/bus/usb/devices/${bus}-${devpath}" ]]; then
                printf '%s' "${bus}-${devpath}"
                return 0
            fi
        done
        printf "cannot resolve '%s': no connected device at controller %s, port %s\n" \
            "$input" "$controller" "$devpath" >&2
        return 1
    fi
    printf "'%s' is not a USB port (expected e.g. 1-2 or 1-2.3; see --list)\n" "$input" >&2
    return 1
}

# ----------------------------------------------------------------------------
# Device discovery (sysfs)
# ----------------------------------------------------------------------------

usb_dev_dir() { printf '%s/bus/usb/devices/%s' "$SYSFS_ROOT" "$1"; }

read_attr() {
    local file="$1" val=""
    if [[ -r "$file" ]]; then
        IFS= read -r val <"$file" || true
    fi
    printf '%s' "$val"
}

# Print the USB port (e.g. 1-3.1) of ALSA card N; fail if it is not a USB card.
card_usb_port() {
    local card="$1" dir base
    dir=$(readlink -f "$SYSFS_ROOT/class/sound/card${card}/device" 2>/dev/null) || return 1
    while [[ -n "$dir" && "$dir" != "/" && "$dir" != "." ]]; do
        base=$(basename "$dir")
        if [[ "$base" =~ $USB_PORT_RE ]]; then
            printf '%s' "$base"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

# List the numbers of all ALSA cards, ascending.
list_card_numbers() {
    local c n
    for c in "$SYSFS_ROOT"/class/sound/card[0-9]*; do
        [[ -e "$c" ]] || continue
        n="${c##*/card}"
        [[ "$n" =~ ^[0-9]+$ ]] && printf '%s\n' "$n"
    done | sort -n
    return 0
}

card_id() { read_attr "$SYSFS_ROOT/class/sound/card${1}/id"; }

# Bus-number-independent location of card N as udev computes it (path_id),
# e.g. pci-0000:00:14.0-usb-0:1.2:1.0. Fails if udevadm cannot provide one.
card_id_path() {
    local out val
    command -v udevadm >/dev/null 2>&1 || return 1
    out=$(udevadm test-builtin path_id "$SYSFS_ROOT/class/sound/card${1}" 2>/dev/null) || return 1
    val=$(printf '%s\n' "$out" | sed -n 's/^ID_PATH=//p' | head -n 1)
    [[ -n "$val" && "$val" =~ $IDPATH_RE ]] || return 1
    printf '%s' "$val"
}

# Number of the card attached to USB port P (empty if none).
card_on_port() {
    local port="$1" n
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        if [[ "$(card_usb_port "$n" 2>/dev/null || true)" == "$port" ]]; then
            printf '%s' "$n"
            return 0
        fi
    done <<<"$(list_card_numbers)"
    return 1
}

# Ports of connected USB devices with VID:PID (lowercase hex), one per line.
find_ports_by_id() {
    local vid="$1" pid="$2" d base
    for d in "$SYSFS_ROOT"/bus/usb/devices/*; do
        base="${d##*/}"
        [[ "$base" =~ $USB_PORT_RE ]] || continue
        if [[ "$(read_attr "$d/idVendor")" == "$vid" && "$(read_attr "$d/idProduct")" == "$pid" ]]; then
            printf '%s\n' "$base"
        fi
    done
    return 0
}

device_desc() {
    local d m p
    d=$(usb_dev_dir "$1")
    m=$(read_attr "$d/manufacturer")
    p=$(read_attr "$d/product")
    printf '%s' "${m:+$m${p:+ }}$p"
}

# ----------------------------------------------------------------------------
# Rules file handling
# ----------------------------------------------------------------------------

# Emit the rule block for one mapping. All inputs must already be validated;
# assert_rules_safe re-checks the output so no caller can inject udev keys.
generate_udev_rules() {
    local vid="${1:-}" pid="${2:-}" name="${3:-}" desc="${4:-}" port="${5:-}" idpath="${6:-}"
    [[ "$vid" =~ $HEX4_RE && "$pid" =~ $HEX4_RE ]] \
        || error_exit "Internal: invalid vendor/product id '$vid:$pid'"
    name_problem "$name" >/dev/null || error_exit "Internal: invalid name '$name'"
    if [[ -n "$port" && ! "$port" =~ $USB_PORT_RE ]]; then
        error_exit "Internal: invalid port '$port'"
    fi
    if [[ -n "$idpath" && ! "$idpath" =~ $IDPATH_RE ]]; then
        error_exit "Internal: invalid ID_PATH '$idpath'"
    fi
    vid="${vid,,}"
    pid="${pid,,}"
    desc=$(sanitize_desc "$desc")

    local match="SUBSYSTEM==\"sound\", KERNEL==\"%s\", ACTION==\"add|change\", ATTRS{idVendor}==\"$vid\", ATTRS{idProduct}==\"$pid\""
    if [[ -n "$idpath" ]]; then
        match+=", IMPORT{builtin}=\"path_id\", ENV{ID_PATH}==\"$idpath\""
    elif [[ -n "$port" ]]; then
        match+=", KERNELS==\"$port\""
    fi
    # shellcheck disable=SC2059  # match is a format string built above from validated parts
    {
        printf '# usb-audio-mapper: name=%s usb=%s:%s port=%s path=%s desc=%s\n' "$name" "$vid" "$pid" "${port:-any}" "${idpath:--}" "${desc:-none}"
        printf "$match"', ATTR{id}!="%s", ATTR{id}="%s", ENV{USB_AUDIO_MAPPER}="%s"\n' "card*" "$name" "$name" "$name"
        printf "$match"', SYMLINK+="sound/by-id/%s", ENV{USB_AUDIO_MAPPER}="%s"\n' "controlC*" "$name" "$name"
    }
}

# Defense in depth: every generated line must be exactly one of the 3 shapes.
assert_rules_safe() {
    local line count=0
    local c_re='^# usb-audio-mapper: name=[a-z][a-z0-9-]* usb=[0-9a-f]{4}:[0-9a-f]{4} port=([0-9.-]+|any) path=([A-Za-z0-9][A-Za-z0-9:._+-]*|-) desc=[[:alnum:] ._()-]*$'
    # Bracket expressions instead of backslash escapes: \| and \+ are not portable ERE.
    local m_re='^SUBSYSTEM=="sound", KERNEL=="(card|controlC)[*]", ACTION=="add[|]change", ATTRS[{]idVendor[}]=="[0-9a-f]{4}", ATTRS[{]idProduct[}]=="[0-9a-f]{4}"(, KERNELS=="[0-9]+-[0-9]+([.][0-9]+)*"|, IMPORT[{]builtin[}]="path_id", ENV[{]ID_PATH[}]=="[A-Za-z0-9][A-Za-z0-9:._+-]*")?, '
    local tail_re='(ATTR[{]id[}]!="[a-z][a-z0-9-]*", ATTR[{]id[}]="[a-z][a-z0-9-]*"|SYMLINK[+]="sound/by-id/[a-z][a-z0-9-]*"), ENV[{]USB_AUDIO_MAPPER[}]="[a-z][a-z0-9-]*"$'
    while IFS= read -r line; do
        count=$((count + 1))
        if [[ "$line" =~ $c_re ]]; then continue; fi
        if [[ "$line" =~ $m_re$tail_re ]]; then continue; fi
        error_exit "Internal: refusing to write unexpected rule line: $line"
    done <<<"$1"
    ((count == 3)) || error_exit "Internal: expected 3 rule lines, got $count"
}

# Filter existing rules on stdin, dropping every mapping that NAME or KEY
# (mapping_key: VID:PID@location) would collide with. Recognizes:
#   - v4 blocks (comment + rules carrying ENV{USB_AUDIO_MAPPER}="...")
#   - legacy (<= v3 / LyreBird <= 1.2.x) lines containing ATTR{id}="NAME",
#     including the v3 bug form where the comment and rule share one line,
#     and a "# USB Sound Card:" comment directly preceding a removed rule.
# Prints kept lines on stdout and "REMOVED <name>" notices on fd 3.
# POSIX awk only (works with mawk, gawk and busybox awk).
filter_rules() {
    local name="$1" key="${2:-}"
    awk -v name="$name" -v key="$key" '
        # Fixed-string parsing (index/substr) only: dynamic regexes with
        # "{" behave differently across awk implementations.
        function field(line, tag,    pos, s, sp) {
            pos = index(line, tag)
            if (pos == 0) return ""
            s = substr(line, pos + length(tag))
            sp = index(s, " ")
            return sp ? substr(s, 1, sp - 1) : s
        }
        function quoted(line, tag,    pos, s, q) {
            pos = index(line, tag "\"")
            if (pos == 0) return ""
            s = substr(line, pos + length(tag) + 1)
            q = index(s, "\"")
            return q ? substr(s, 1, q - 1) : ""
        }
        function line_key(line,    v, p, k, ip) {
            v = quoted(line, "ATTRS{idVendor}==")
            p = quoted(line, "ATTRS{idProduct}==")
            k = quoted(line, "KERNELS==")
            ip = quoted(line, "ENV{ID_PATH}==")
            if (v == "" || p == "") return ""
            return v ":" p "@" (ip != "" ? ip : (k == "" ? "any" : k))
        }
        function v4_comment_key(line,    u, p, pa) {
            u = field(line, "usb=")
            p = field(line, "port=")
            pa = field(line, "path=")
            return u "@" ((pa != "" && pa != "-") ? pa : p)
        }
        function drop(owner) {
            if (!(owner in seen)) { seen[owner] = 1; print "REMOVED " owner > "/dev/fd/3" }
        }
        {
            line = $0
            remove = 0
            owner = ""
            if (index(line, "# usb-audio-mapper: name=") == 1) {
                owner = field(line, "name=")
                if (owner == name || (key != "" && v4_comment_key(line) == key)) remove = 1
            } else if (index(line, "ENV{USB_AUDIO_MAPPER}=") > 0) {
                owner = quoted(line, "ENV{USB_AUDIO_MAPPER}=")
                if (owner == name || (key != "" && line_key(line) == key)) remove = 1
            } else if (index(line, "ATTR{id}=\"" name "\"") > 0) {
                owner = name
                remove = 1
            }
            if (remove) {
                drop(owner)
                held = ""
                next
            }
            if (held != "") { print held; held = "" }
            if (index(line, "# USB Sound Card:") == 1) { held = line; next }
            print line
        }
        END { if (held != "") print held }
    '
}

udevadm_supports_verify() {
    command -v udevadm >/dev/null 2>&1 && udevadm verify --help >/dev/null 2>&1
}

# Atomically replace RULES_FILE with CONTENT (temp file in the same directory,
# fsync, rename). The temp name starts with "." and lacks the .rules suffix, so
# udev never reads a partial file.
install_rules_file() {
    local content="$1" dir tmp
    dir=$(dirname "$RULES_FILE")
    tmp=$(mktemp "$dir/.usb-audio-mapper.XXXXXX") || error_exit "Cannot create a temporary file in $dir" "$E_PERMISSION"
    CLEANUP_FILES+=("$tmp")
    printf '%s' "$content" >"$tmp" || error_exit "Failed to write $tmp"
    chmod 0644 "$tmp" || error_exit "Failed to set permissions on $tmp"
    if udevadm_supports_verify; then
        local out
        if ! out=$(udevadm verify --no-style "$tmp" 2>&1); then
            error_exit "udevadm verify rejected the new rules file; nothing was changed:
$out"
        fi
    fi
    sync "$tmp" 2>/dev/null || sync
    mv -f -- "$tmp" "$RULES_FILE" || error_exit "Failed to install $RULES_FILE"
    sync "$dir" 2>/dev/null || sync
}

# Serialize concurrent invocations (read-modify-write of one file).
acquire_lock() {
    local lock
    lock="$(dirname "$RULES_FILE")/.usb-audio-mapper.lock"
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$lock" || error_exit "Cannot open lock file $lock" "$E_PERMISSION"
        flock -w 30 9 || error_exit "Timed out waiting for another usb-audio-mapper run to finish"
    fi
}

ensure_writable_rules_dir() {
    local dir
    dir=$(dirname "$RULES_FILE")
    if [[ ! -d "$dir" ]]; then
        mkdir -p -- "$dir" 2>/dev/null || error_exit "Cannot create $dir (run with sudo?)" "$E_PERMISSION"
    fi
    if [[ ! -w "$dir" ]] || { [[ -e "$RULES_FILE" ]] && [[ ! -w "$RULES_FILE" ]]; }; then
        error_exit "No write permission for $RULES_FILE. Run with sudo." "$E_PERMISSION"
    fi
}

# Drop leading/trailing blank lines and squeeze runs of blank lines (left
# behind when blocks are removed).
squeeze_blank_lines() {
    awk 'NF { if (seen && blank) print ""; print; seen = 1; blank = 0; next } { blank = 1 }'
}

# Identity of the location a mapping matches: VID:PID@(ID_PATH|port|any).
mapping_key() { printf '%s:%s@%s' "$1" "$2" "${4:-${3:-any}}"; }

# Replace whatever collides with NAME / the same device location, then append
# the new block.
write_mapping() {
    local vid="$1" pid="$2" name="$3" desc="$4" port="$5" idpath="${6:-}" block existing="" kept removed
    block=$(generate_udev_rules "$vid" "$pid" "$name" "$desc" "$port" "$idpath")
    assert_rules_safe "$block"
    ensure_writable_rules_dir
    acquire_lock
    [[ -f "$RULES_FILE" ]] && existing=$(cat -- "$RULES_FILE")
    removed=$(mktemp "${TMPDIR:-/tmp}/usb-audio-mapper.XXXXXX")
    CLEANUP_FILES+=("$removed")
    kept=$(printf '%s\n' "$existing" | filter_rules "$name" "$(mapping_key "$vid" "$pid" "$port" "$idpath")" 3>"$removed")
    local owner others=0
    while read -r _ owner; do
        [[ "$owner" == "$name" ]] || others=$((others + 1))
    done <"$removed"
    # Re-running an identical mapping is a no-op: keep the file byte-for-byte.
    if ((others == 0)) && [[ $'\n'"$existing"$'\n' == *$'\n'"$block"$'\n'* ]]; then
        info "Mapping '$name' is already in $RULES_FILE; nothing to change."
        return 0
    fi
    while read -r _ owner; do
        if [[ "$owner" == "$name" ]]; then
            info "Replacing the existing mapping for '$name'."
        else
            warning "Removing mapping '$owner': it matched the same device and port."
        fi
    done <"$removed"
    kept=$(printf '%s\n' "$kept" | squeeze_blank_lines)
    local content
    if [[ -n "$kept" ]]; then
        content="${kept}"$'\n\n'"${block}"$'\n'
    else
        content="# Generated by usb-audio-mapper.sh. Edit with: usb-audio-mapper.sh --remove NAME"$'\n\n'"${block}"$'\n'
    fi
    install_rules_file "$content"
    audit_log "mapped ${vid}:${pid} port=${port:-any} path=${idpath:--} -> ${name}"
    success "Rules written to $RULES_FILE"
}

remove_mapping() {
    local name="$1" existing kept removed
    validate_name "$name"
    [[ -f "$RULES_FILE" ]] || error_exit "No rules file at $RULES_FILE; nothing to remove." "$E_DEVICE"
    ensure_writable_rules_dir
    acquire_lock
    existing=$(cat -- "$RULES_FILE")
    removed=$(mktemp "${TMPDIR:-/tmp}/usb-audio-mapper.XXXXXX")
    CLEANUP_FILES+=("$removed")
    kept=$(printf '%s\n' "$existing" | filter_rules "$name" 3>"$removed")
    if [[ ! -s "$removed" ]]; then
        error_exit "No mapping named '$name' in $RULES_FILE." "$E_DEVICE"
    fi
    kept=$(printf '%s\n' "$kept" | squeeze_blank_lines)
    install_rules_file "${kept:+$kept$'\n'}"
    audit_log "removed mapping ${name}"
    success "Removed mapping '$name' from $RULES_FILE"
    apply_rules ""
    info "The card keeps its current name until it is reconnected or the system reboots."
}

# Print "name<TAB>usb<TAB>port<TAB>path" for every v4 mapping.
read_mappings() {
    [[ -f "$RULES_FILE" ]] || return 0
    awk '
        /^# usb-audio-mapper: name=/ {
            n = $3; u = $4; p = $5; pa = $6
            sub(/^name=/, "", n); sub(/^usb=/, "", u); sub(/^port=/, "", p); sub(/^path=/, "", pa)
            print n "\t" u "\t" p "\t" pa
        }
    ' "$RULES_FILE"
}

legacy_rule_names() {
    [[ -f "$RULES_FILE" ]] || return 0
    grep -v 'ENV{USB_AUDIO_MAPPER}=' "$RULES_FILE" 2>/dev/null \
        | grep -oE 'ATTR\{id\}="[^"]*"' | sed 's/^ATTR{id}="//; s/"$//' | sort -u || true
}

# ----------------------------------------------------------------------------
# Apply and verify
# ----------------------------------------------------------------------------

# Reload udev and re-run the rules for the given card so the name applies now.
# Prints nothing; returns 0 even when udevadm is missing (rules still apply at
# next boot/replug).
apply_rules() {
    local card="${1:-}"
    if ! command -v udevadm >/dev/null 2>&1; then
        warning "udevadm not found; the rules will take effect at next boot."
        return 0
    fi
    udevadm control --reload-rules 2>/dev/null || udevadm control --reload 2>/dev/null \
        || warning "udevadm could not reload rules (is udev running?)."
    if [[ -n "$card" ]]; then
        udevadm trigger --action=change "$SYSFS_ROOT/class/sound/card${card}" \
            "$SYSFS_ROOT/class/sound/controlC${card}" 2>/dev/null \
            || udevadm trigger --action=change --subsystem-match=sound 2>/dev/null || true
        udevadm settle --timeout=15 2>/dev/null || true
    fi
    return 0
}

# Confirm the kernel now reports NAME for the card on PORT (or for the card
# with VID:PID when no port). Returns E_VERIFY with an explanation otherwise.
verify_mapping() {
    local name="$1" card="$2" got holder="" n
    got=$(card_id "$card")
    if [[ "$got" == "$name" ]]; then
        success "Verified: card $card is now '$name' (hw:CARD=$name)."
        if [[ -L "/dev/sound/by-id/$name" ]]; then
            success "Verified: /dev/sound/by-id/$name -> $(readlink "/dev/sound/by-id/$name")"
        elif [[ "$SYSFS_ROOT" == "/sys" ]]; then
            warning "/dev/sound/by-id/$name was not created yet; it appears on the next replug or reboot."
        fi
        return 0
    fi
    error "Card $card is still named '$got', not '$name'."
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        if [[ "$n" != "$card" && "$(card_id "$n")" == "$name" ]]; then holder="$n"; fi
    done <<<"$(list_card_numbers)"
    if [[ -n "$holder" ]]; then
        error "Card $holder still holds the name '$name' (ALSA ids must be unique)."
        error "The rule is saved; card $card gets the name once card $holder releases it (reconnect or reboot)."
    else
        error "udev did not apply the rule. Check: udevadm test \$(udevadm info -q path -p /class/sound/card$card)"
    fi
    return "$E_VERIFY"
}

# ----------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------

# Resolve and create one mapping. Arguments are raw user input.
#   map_device NAME VID PID PORT CARD DESC ANY_PORT DRY_RUN APPLY
map_device() {
    local name="$1" vid="$2" pid="$3" port="$4" card="$5" desc="$6"
    local any_port="$7" dry_run="$8" apply="$9"

    if [[ -n "$card" ]]; then
        card=$(safe_base10 "$card") || error_exit "Invalid card number: $5" "$E_USAGE"
        [[ -e "$SYSFS_ROOT/class/sound/card$card" ]] || error_exit "Sound card $card does not exist." "$E_DEVICE"
        local card_port
        card_port=$(card_usb_port "$card") || error_exit "Sound card $card is not a USB device." "$E_DEVICE"
        local d cvid cpid
        d=$(usb_dev_dir "$card_port")
        cvid=$(read_attr "$d/idVendor")
        cpid=$(read_attr "$d/idProduct")
        if [[ -n "$vid" && "${vid,,}" != "$cvid" ]] || [[ -n "$pid" && "${pid,,}" != "$cpid" ]]; then
            error_exit "Card $card is ${cvid}:${cpid}, which contradicts -v/-p ${vid}:${pid}." "$E_USAGE"
        fi
        vid="$cvid"
        pid="$cpid"
        if [[ -n "$port" ]]; then
            local p
            p=$(normalize_usb_port "$port") || error_exit "Invalid USB port." "$E_USAGE"
            [[ "$p" == "$card_port" ]] || error_exit "Card $card is on port $card_port, not $p." "$E_USAGE"
        fi
        port="$card_port"
        [[ -n "$desc" ]] || desc=$(device_desc "$card_port")
    else
        [[ -n "$vid" && -n "$pid" ]] || error_exit "Give either --card N, or --vendor and --product." "$E_USAGE"
        [[ "$vid" =~ $HEX4_RE ]] || error_exit "Invalid vendor ID '$vid': must be 4 hexadecimal digits." "$E_USAGE"
        [[ "$pid" =~ $HEX4_RE ]] || error_exit "Invalid product ID '$pid': must be 4 hexadecimal digits." "$E_USAGE"
        vid="${vid,,}"
        pid="${pid,,}"
        if [[ -n "$port" ]]; then
            port=$(normalize_usb_port "$port") || error_exit "Invalid USB port (see --list for valid ports)." "$E_USAGE"
            local d at_vid at_pid
            d=$(usb_dev_dir "$port")
            if [[ -d "$d" ]]; then
                at_vid=$(read_attr "$d/idVendor")
                at_pid=$(read_attr "$d/idProduct")
                if [[ "$at_vid:$at_pid" != "$vid:$pid" ]]; then
                    warning "Port $port currently holds ${at_vid}:${at_pid}, not ${vid}:${pid}; the rule applies once the right device is plugged in there."
                fi
            else
                info "Nothing is connected to port $port right now; the rule applies once the device is plugged in there."
            fi
        elif [[ "$any_port" != "true" ]]; then
            local ports=()
            local p
            while IFS= read -r p; do [[ -n "$p" ]] && ports+=("$p"); done <<<"$(find_ports_by_id "$vid" "$pid")"
            if ((${#ports[@]} == 1)); then
                port="${ports[0]}"
                info "Found ${vid}:${pid} on USB port $port; the name will follow this port."
            elif ((${#ports[@]} > 1)); then
                error_exit "${#ports[@]} connected devices are ${vid}:${pid} (ports: ${ports[*]}). Choose one with --usb-port PORT or --card N." "$E_DEVICE"
            else
                warning "No ${vid}:${pid} device is connected; creating a rule that matches it on any port."
            fi
        fi
        [[ -n "$desc" || -z "$port" || ! -d "$(usb_dev_dir "$port")" ]] || desc=$(device_desc "$port")
    fi

    [[ -n "$name" ]] || error_exit "A friendly name is required (--friendly NAME)." "$E_USAGE"
    validate_name "$name"

    # The connected card (if any) this mapping is for: the one on PORT, or the
    # first with VID:PID for an any-port rule; only if it really is VID:PID.
    local target="" tport
    if [[ -n "$port" ]]; then
        tport="$port"
    else
        tport=$(find_ports_by_id "$vid" "$pid" | head -n 1)
    fi
    if [[ -n "$tport" && "$(read_attr "$(usb_dev_dir "$tport")/idVendor"):$(read_attr "$(usb_dev_dir "$tport")/idProduct")" == "$vid:$pid" ]]; then
        target=$(card_on_port "$tport" || true)
    fi

    # Match a port-tied rule on the card's bus-independent ID_PATH when it can
    # be determined (device connected); otherwise fall back to the bus port.
    local idpath=""
    if [[ -z "$port" ]]; then
        warning "This rule matches ${vid}:${pid} on ANY port. With two identical devices only one can get the name."
    elif [[ -n "$target" ]] && idpath=$(card_id_path "$target"); then
        debug "card $target ID_PATH=$idpath"
    else
        idpath=""
        warning "Could not read the device's udev ID_PATH (not connected, or udevadm unavailable); the rule matches USB port $port instead. Port numbers include the USB bus number, which can change between boots on machines with several USB controllers. Re-run the mapper with the device connected to avoid this."
    fi

    if [[ "$dry_run" == "true" ]]; then
        local block
        block=$(generate_udev_rules "$vid" "$pid" "$name" "$desc" "$port" "$idpath")
        assert_rules_safe "$block"
        printf '%s\n' "$block"
        return 0
    fi

    # Warn when the name is live on a different connected card: it will move.
    local n
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        [[ "$(card_id "$n")" == "$name" && "$n" != "$target" ]] || continue
        warning "Card $n (port $(card_usb_port "$n" 2>/dev/null || echo n/a)) currently uses the name '$name'; the name moves to the new device."
    done <<<"$(list_card_numbers)"

    write_mapping "$vid" "$pid" "$name" "$desc" "$port" "$idpath"

    if [[ "$apply" != "true" ]]; then
        info "Not applying now (--no-apply); the name takes effect at next boot or replug."
        return 0
    fi
    if [[ -z "$target" ]]; then
        apply_rules ""
        info "The device is not connected; it will be named '$name' when plugged in."
        return 0
    fi
    apply_rules "$target"
    verify_mapping "$name" "$target"
}

cmd_list() {
    local n port d vid pid id mapped idpath any=false
    local -a names=() usbs=() ports=() paths=()
    local m_name m_usb m_port m_path
    while IFS=$'\t' read -r m_name m_usb m_port m_path; do
        [[ -n "$m_name" ]] || continue
        names+=("$m_name")
        usbs+=("$m_usb")
        ports+=("$m_port")
        paths+=("${m_path:--}")
    done <<<"$(read_mappings)"

    printf '%-5s %-16s %-10s %-10s %-16s %s\n' CARD ID USB-ID PORT MAPPED-AS DESCRIPTION
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        port=$(card_usb_port "$n" 2>/dev/null) || continue
        any=true
        d=$(usb_dev_dir "$port")
        vid=$(read_attr "$d/idVendor")
        pid=$(read_attr "$d/idProduct")
        id=$(card_id "$n")
        mapped="-"
        idpath=$(card_id_path "$n" || true)
        local i
        for i in "${!names[@]}"; do
            [[ "${usbs[i]}" == "$vid:$pid" ]] || continue
            if [[ "${paths[i]}" != "-" ]]; then
                [[ "${paths[i]}" == "$idpath" ]] && mapped="${names[i]}"
            elif [[ "${ports[i]}" == "$port" ]]; then
                mapped="${names[i]}"
            elif [[ "${ports[i]}" == "any" ]]; then
                mapped="${names[i]}(any)"
            fi
        done
        printf '%-5s %-16s %-10s %-10s %-16s %s\n' "$n" "$id" "$vid:$pid" "$port" "$mapped" "$(device_desc "$port")"
    done <<<"$(list_card_numbers)"
    [[ "$any" == "true" ]] || printf '(no USB sound cards found)\n'

    if ((${#names[@]} > 0)); then
        printf '\nMappings in %s:\n' "$RULES_FILE"
        local i
        for i in "${!names[@]}"; do
            if [[ "${paths[i]}" != "-" ]]; then
                printf '  %-16s %s at %s\n' "${names[i]}" "${usbs[i]}" "${paths[i]}"
            else
                printf '  %-16s %s on port %s\n' "${names[i]}" "${usbs[i]}" "${ports[i]}"
            fi
        done
    fi
    local legacy
    legacy=$(legacy_rule_names)
    if [[ -n "$legacy" ]]; then
        printf '\nLegacy (pre-v4) rules for: %s\n' "$(printf '%s' "$legacy" | tr '\n' ' ')"
        printf 'These may not work; re-create each mapping with this version to replace it.\n'
    fi
    return 0
}

# Show the port of every connected USB device (kept as -t/--test for compatibility).
cmd_test() {
    local d base count=0 audio
    printf '%-10s %-10s %-6s %s\n' PORT USB-ID AUDIO DESCRIPTION
    for d in "$SYSFS_ROOT"/bus/usb/devices/*; do
        base="${d##*/}"
        [[ "$base" =~ $USB_PORT_RE ]] || continue
        count=$((count + 1))
        audio=no
        local c
        for c in "$d/$base":*/sound/card*; do
            [[ -e "$c" ]] && audio=yes
            break
        done
        printf '%-10s %-10s %-6s %s\n' "$base" "$(read_attr "$d/idVendor"):$(read_attr "$d/idProduct")" "$audio" "$(device_desc "$base")"
    done
    if ((count == 0)); then
        warning "No USB devices found under $SYSFS_ROOT/bus/usb/devices."
        return "$E_DEVICE"
    fi
    success "Port detection works: $count USB device(s) found."
}

# Read one line of user input; exit cleanly on EOF.
prompt() {
    local question="$1" reply
    printf '%s' "$question" >&2
    if ! IFS= read -r reply; then
        printf '\n' >&2
        error_exit "No input (end of file)." "$E_USAGE"
    fi
    printf '%s' "$reply"
}

cmd_interactive() {
    local dry_run="$1" apply="$2"
    # Fail before asking questions if the result could not be written anyway.
    [[ "$dry_run" == "true" ]] || ensure_writable_rules_dir
    printf 'USB Audio Mapper %s - give a USB sound card a permanent name.\n\n' "$SCRIPT_VERSION" >&2
    cmd_list >&2
    printf '\n' >&2

    local cards=() n
    while IFS= read -r n; do
        [[ -n "$n" ]] || continue
        card_usb_port "$n" >/dev/null 2>&1 && cards+=("$n")
    done <<<"$(list_card_numbers)"
    ((${#cards[@]} > 0)) || error_exit "No USB sound cards are connected. Plug one in and try again." "$E_DEVICE"

    local card _
    for _ in 1 2 3; do
        card=$(prompt "Card number to map [${cards[*]}]: ")
        if card=$(safe_base10 "$card") && [[ " ${cards[*]} " == *" $card "* ]]; then
            break
        fi
        warning "Enter one of: ${cards[*]}"
        card=""
    done
    [[ -n "$card" ]] || error_exit "No valid card selected." "$E_USAGE"

    local port d vid pid desc others=()
    port=$(card_usb_port "$card")
    d=$(usb_dev_dir "$port")
    vid=$(read_attr "$d/idVendor")
    pid=$(read_attr "$d/idProduct")
    desc=$(device_desc "$port")
    while IFS= read -r n; do [[ -n "$n" && "$n" != "$port" ]] && others+=("$n"); done <<<"$(find_ports_by_id "$vid" "$pid")"
    printf '\nCard %s: %s (%s:%s) on USB port %s\n' "$card" "$desc" "$vid" "$pid" "$port" >&2

    local use_port="$port" answer
    if ((${#others[@]} > 0)); then
        info "${#others[@]} identical device(s) also connected (port ${others[*]}); the name must follow the port."
    else
        answer=$(prompt "Tie the name to USB port $port (recommended; answer n to follow the device to any port) [Y/n]: ")
        [[ "$answer" =~ ^[Nn] ]] && use_port=""
    fi

    local suggestion name problem
    suggestion=$(suggest_name "$(card_id "$card")")
    for _ in 1 2 3; do
        name=$(prompt "Name (lowercase letters, digits, hyphens; max $MAX_NAME_LENGTH) [$suggestion]: ")
        name="${name:-$suggestion}"
        if problem=$(name_problem "$name"); then
            break
        fi
        warning "$problem"
        name=""
    done
    [[ -n "$name" ]] || error_exit "No valid name given." "$E_USAGE"

    printf '\nThese rules will be written to %s:\n\n' "$RULES_FILE" >&2
    local preview_path=""
    [[ -n "$use_port" ]] && preview_path=$(card_id_path "$card" || true)
    generate_udev_rules "$vid" "$pid" "$name" "$desc" "$use_port" "$preview_path" >&2
    printf '\n' >&2
    if [[ "$dry_run" != "true" ]]; then
        answer=$(prompt "Proceed? [Y/n]: ")
        [[ "$answer" =~ ^[Nn] ]] && {
            info "Cancelled; nothing was changed."
            return 0
        }
    fi
    if [[ -n "$use_port" ]]; then
        map_device "$name" "$vid" "$pid" "$use_port" "" "$desc" false "$dry_run" "$apply"
    else
        map_device "$name" "$vid" "$pid" "" "" "$desc" true "$dry_run" "$apply"
    fi
}

show_help() {
    cat <<EOF
USB Audio Mapper $SCRIPT_VERSION - persistent names for USB audio devices

Usage:
  $SCRIPT_NAME                              Interactive wizard (needs root)
  $SCRIPT_NAME -n --card N -f NAME          Name the USB card that is ALSA card N
  $SCRIPT_NAME -n -v VID -p PID [-u PORT] -f NAME
                                            Name a device by vendor/product id
  $SCRIPT_NAME --list                       Show USB sound cards and mappings
  $SCRIPT_NAME --remove NAME                Delete a mapping

Options:
  -i, --interactive       Interactive mode (default when no options are given)
  -n, --non-interactive   Non-interactive mode
  -c, --card N            ALSA card number of a connected USB device; vendor,
                          product and port are read from it
  -v, --vendor VID        USB vendor ID (4 hex digits)
  -p, --product PID       USB product ID (4 hex digits)
  -u, --usb-port PORT     Physical port, e.g. 1-2 or 1-2.3 (see --list); also
                          accepts the usb-0000:00:14.0-2 form from /proc/asound/cards
      --any-port          Match the device on any port (only safe if you have
                          one device with this vendor/product id)
  -f, --friendly NAME     Name to assign: lowercase letters, digits, hyphens,
                          starting with a letter, at most $MAX_NAME_LENGTH characters
  -d, --device TEXT       Description stored in the rule comment (optional)
  -l, --list              List USB sound cards, their ports and mappings
  -t, --test              List every USB device with its port
  -r, --remove NAME       Remove the mapping for NAME
      --dry-run           Print the rules that would be written; change nothing
      --no-apply          Write rules but do not trigger udev now
      --rules-file PATH   Rules file (default: $DEFAULT_RULES_FILE)
  -D, --debug             Debug output
  -V, --version           Print version
  -h, --help              Show this help

Without -u, a single connected device is tied to the port it is on now; if
several identical devices are connected you must pick one with -u or --card.
After writing the rules the mapping is applied immediately and verified when
the device is connected; no reboot is needed.

Examples:
  sudo $SCRIPT_NAME -n --card 1 -f mic-left
  sudo $SCRIPT_NAME -n -v 2e88 -p 4610 -u 1-1.2 -f movo-left
  $SCRIPT_NAME -n -v 2e88 -p 4610 --any-port -f movo --dry-run

Exit status: 0 ok, 1 error, 2 usage, 3 permission, 4 missing dependency,
5 device not found/ambiguous, 6 rule written but not applied by the kernel.

Report bugs: https://github.com/tomtom215/usb-audio-mapper/issues
EOF
}

check_dependencies() {
    local cmd missing=()
    for cmd in awk grep sed sort tr mktemp readlink dirname basename head; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if ((${#missing[@]} > 0)); then
        error_exit "Required commands not found: ${missing[*]}" "$E_DEPENDENCY"
    fi
}

need_arg() {
    if [[ -z "${2:-}" || "$2" == -* && "$2" != "-" ]]; then
        error_exit "Option '$1' requires an argument." "$E_USAGE"
    fi
}

main() {
    local mode="" name="" vid="" pid="" port="" card="" desc="" remove_name=""
    local any_port=false dry_run=false apply=true

    while (($# > 0)); do
        case "$1" in
            -i | --interactive) mode="${mode:-interactive}" ;;
            -n | --non-interactive) mode="map" ;;
            -c | --card)
                need_arg "$1" "${2:-}"
                card="$2"
                shift
                ;;
            -v | --vendor)
                need_arg "$1" "${2:-}"
                vid="$2"
                shift
                ;;
            -p | --product)
                need_arg "$1" "${2:-}"
                pid="$2"
                shift
                ;;
            -u | --usb-port)
                need_arg "$1" "${2:-}"
                port="$2"
                shift
                ;;
            -f | --friendly)
                need_arg "$1" "${2:-}"
                name="$2"
                shift
                ;;
            -d | --device)
                need_arg "$1" "${2:-}"
                desc="$2"
                shift
                ;;
            --any-port) any_port=true ;;
            -l | --list) mode="list" ;;
            -t | --test) mode="test" ;;
            -r | --remove)
                need_arg "$1" "${2:-}"
                remove_name="$2"
                mode="remove"
                shift
                ;;
            --dry-run) dry_run=true ;;
            --no-apply) apply=false ;;
            --rules-file)
                need_arg "$1" "${2:-}"
                RULES_FILE="$2"
                shift
                ;;
            -D | --debug) DEBUG=true ;;
            -V | --version)
                printf 'usb-audio-mapper %s\n' "$SCRIPT_VERSION"
                return 0
                ;;
            -h | --help)
                show_help
                return 0
                ;;
            *) error_exit "Unknown option: $1 (see --help)" "$E_USAGE" ;;
        esac
        shift
    done
    [[ -n "$mode" ]] || mode=interactive
    if [[ "$any_port" == "true" && -n "$port" ]]; then
        error_exit "--any-port and --usb-port cannot be combined." "$E_USAGE"
    fi
    debug "mode=$mode rules=$RULES_FILE sysfs=$SYSFS_ROOT"
    check_dependencies

    case "$mode" in
        list) cmd_list ;;
        test) cmd_test ;;
        remove) remove_mapping "$remove_name" ;;
        map) map_device "$name" "$vid" "$pid" "$port" "$card" "$desc" "$any_port" "$dry_run" "$apply" ;;
        interactive) cmd_interactive "$dry_run" "$apply" ;;
        *) error_exit "Internal: unknown mode '$mode'" ;;
    esac
}

# Run only when executed, not when sourced (the test suite sources this file).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

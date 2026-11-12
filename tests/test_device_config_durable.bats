#!/usr/bin/env bats
# The device configuration is written durably (register: LB-23; decision D14).
#
# save_device_config (the stream manager's default template) and the writers of
# lyrebird-mic-check.sh that replace /etc/mediamtx/audio-devices.conf
# (generate_config and restore_config_backup) used mktemp + mv: no fsync of the
# file before the rename and none of the directory after it, so a power cut right
# after a write could leave a zero-length or missing file. They now go through
# lyrebird_atomic_write (temp file in the same directory, fsync, rename, fsync of
# the directory), as the MediaMTX configuration already did.
#
# Real code: the real functions of both scripts and the real lyrebird_atomic_write.
# Stood in for: `sync`, by a PATH shim that records what it is asked to flush and what
# the destination holds at that moment (the order is what is asserted: the temp
# file first, the directory after the rename), and that can fail; and, for
# generate_config, the two hardware probes and the disk check, as in
# tests/test_stream_device_config.bats. Whether a power cut leaves the file intact
# needs hardware; what is tested is the order of the operations.

load scratch_tmpdir
load stream_definition_helper

setup() {
    sd_setup
    SYNC_LOG="$SD/sync.log"
    : >"$SYNC_LOG"
    mkdir -p "$SD/shim"
    cat >"$SD/shim/sync" <<'SHIM'
#!/bin/bash
[[ "$1" == "--" ]] && shift
dest_state=absent
if [[ -e "$SYNC_DEST" ]]; then
    dest_state="$(head -n 1 "$SYNC_DEST")"
fi
printf 'path=%s exists=%s dest=%s\n' "$1" "$([[ -e "$1" ]] && echo y || echo n)" "$dest_state" >>"$SYNC_LOG"
[[ -z "${SYNC_FAIL:-}" ]]
SHIM
    chmod +x "$SD/shim/sync"
    export SYNC_LOG
}

teardown() {
    sd_teardown
}

# The parser's verdict on a config file: errors and settings
_PARSE='parse_device_config "$MEDIAMTX_DEVICE_CONFIG"; echo "errors=$DEVICE_CONFIG_ERROR_COUNT settings=${#DEVICE_SETTINGS[@]}"'

# No temporary file left next to the config
assert_no_temp_files() {
    local junk
    junk="$(find "$SD/cfg" "$SD" -maxdepth 1 -name '.*' ! -name '.' ! -name '.config.lock' 2>/dev/null | grep -F -e '.audio-devices.conf.' -e '.written.conf' -e 'written.conf.' || true)"
    [ -z "$junk" ] || {
        echo "left behind: $junk"
        false
    }
}

# ---------------------------------------------------------------------------
# The manager: save_device_config
# ---------------------------------------------------------------------------

@test "save_device_config flushes the temp file before the rename and the directory after it [LB-23, D14]" {
    echo old >"$MEDIAMTX_DEVICE_CONFIG"
    SYNC_DEST="$MEDIAMTX_DEVICE_CONFIG" PATH="$SD/shim:$PATH" run smq 'save_device_config; echo "rc=$?"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=0"* ]]
    mapfile -t calls <"$SYNC_LOG"
    [ "${#calls[@]}" -eq 2 ] || {
        cat "$SYNC_LOG"
        false
    }
    # first: the hidden temp file in the same directory, still there, the old config still in place
    [[ "${calls[0]}" == "path=$SD/cfg/.audio-devices.conf."* ]]
    [[ "${calls[0]}" == *"exists=y dest=old" ]]
    # second: the directory, after the rename made the new file visible
    [ "${calls[1]}" = "path=$SD/cfg exists=y dest=# Audio device configuration" ]
    assert_no_temp_files
}

@test "save_device_config writes the same template, mode 0644, that the parser reads without a problem [LB-23, D14]" {
    run smq 'save_device_config; echo "rc=$?"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=0"* ]]
    [ "$(stat -c %a "$MEDIAMTX_DEVICE_CONFIG")" = "644" ]
    [ "$(head -n 1 "$MEDIAMTX_DEVICE_CONFIG")" = "# Audio device configuration" ]
    [ "$(tail -n 1 "$MEDIAMTX_DEVICE_CONFIG")" = "# DEVICE_BLUE_YETI_PCM=1" ]
    run smq "$_PARSE"
    [ "$output" = "errors=0 settings=0" ]
    assert_no_temp_files
}

@test "a write that fails leaves the old config as it was, removes the temp file and says so [LB-23]" {
    echo old >"$MEDIAMTX_DEVICE_CONFIG"
    SYNC_FAIL=1 SYNC_DEST="$MEDIAMTX_DEVICE_CONFIG" PATH="$SD/shim:$PATH" run smq 'rc=0; save_device_config || rc=$?; echo "rc=$rc"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=1"* ]]
    [ "$(cat "$MEDIAMTX_DEVICE_CONFIG")" = "old" ]
    assert_no_temp_files
    grep -qF "Failed to write the default device configuration $MEDIAMTX_DEVICE_CONFIG" "$STREAM_MANAGER_LOG_FILE"
}

@test "a start whose default device config cannot be written goes on with the defaults; the config command fails [LB-23]" {
    # (the failing write itself is the previous test; here only what the callers do with it)
    run smq '
        save_device_config() { return 1; }
        rc=0; generate_mediamtx_config || rc=$?
        echo "generate rc=$rc"
        rc=0; show_config || rc=$?
        echo "show rc=$rc"'
    [[ "$output" == *"show rc=1"* ]]
    grep -qF 'The default device configuration could not be written; every setting uses its default' "$STREAM_MANAGER_LOG_FILE"
    # the MediaMTX configuration was still rendered
    [ -s "$MEDIAMTX_CONFIG_FILE" ]
    [ "$(head -n 1 "$MEDIAMTX_CONFIG_FILE")" = "# Managed by LyreBirdAudio" ]
}

# ---------------------------------------------------------------------------
# lyrebird-mic-check.sh: generate_config and restore_config_backup
# ---------------------------------------------------------------------------

# Run the REAL generate_config of lyrebird-mic-check.sh over a fake /proc/asound with two
# USB cards (what the probes would read from the hardware is stood in for, as in
# tests/test_stream_device_config.bats) and print "generate rc=N". CONFIG_FILE is
# $SD/written.conf; extra environment (SYNC_*) is passed through.
_mic_check_generate() {
    mkdir -p "$SD/asound/card0" "$SD/asound/card3"
    echo "b58e:9e84" >"$SD/asound/card0/usbid"
    echo "19f7:0003" >"$SD/asound/card3/usbid"
    run bash -c '
        source "$PROJECT_ROOT/lyrebird-mic-check.sh" >/dev/null 2>&1
        set +e
        check_root_access() { :; }
        check_disk_space() { :; }
        get_device_info() {
            case "$1" in
                0) printf "card_number=0\ndevice_name=Blue Yeti\nusb_id=b58e:9e84\n" ;;
                3) printf "card_number=3\ndevice_name=Rode NT-USB\nusb_id=19f7:0003\n" ;;
            esac
        }
        detect_device_capabilities() {
            case "$1" in
                0) printf "is_usb=true\nsample_rates=44100 48000 96000\nchannels=1 2\ncapture_capable=true\n" ;;
                3) printf "is_usb=true\nsample_rates=48000\nchannels=2\ncapture_capable=true\n" ;;
            esac
        }
        ASOUND_PROC_ROOT="$SD/asound"
        CONFIG_FILE="$SD/written.conf" MODE_FORCE=true MODE_NO_BACKUP=true QUALITY_TIER=normal
        generate_config >/dev/null 2>"$SD/generate.err"
        echo "generate rc=$?"'
}

@test "generate_config flushes the staged config before the rename and the directory after it [LB-23, D14]" {
    echo old >"$SD/written.conf"
    SYNC_DEST="$SD/written.conf" PATH="$SD/shim:$PATH" _mic_check_generate
    [ "$status" -eq 0 ]
    [[ "$output" == *"generate rc=0"* ]]
    mapfile -t calls <"$SYNC_LOG"
    [ "${#calls[@]}" -eq 2 ] || {
        cat "$SYNC_LOG"
        false
    }
    [[ "${calls[0]}" == "path=$SD/.written.conf."* ]]
    [[ "${calls[0]}" == *"exists=y dest=old" ]]
    [ "${calls[1]}" = "path=$SD exists=y dest=# MediaMTX USB Audio Device Configuration" ]
    # mode 0644 as before, nothing left behind
    [ "$(stat -c %a "$SD/written.conf")" = "644" ]
    assert_no_temp_files
    [ -z "$(find "$SD" -maxdepth 1 -name 'written.conf.*')" ]
}

@test "what generate_config writes round-trips through the manager's parser [LB-23, D3]" {
    _mic_check_generate
    [ "$status" -eq 0 ]
    [[ "$output" == *"generate rc=0"* ]]
    grep -qE '^DEVICE_BLUE_YETI_SAMPLE_RATE="[0-9]+"$' "$SD/written.conf"
    grep -qE '^DEVICE_RODE_NT_USB_BITRATE="[0-9]+k"$' "$SD/written.conf"
    export MEDIAMTX_DEVICE_CONFIG="$SD/written.conf"
    run smq "$_PARSE"
    [ "$output" = "errors=0 settings=6" ]
}

@test "a generate_config whose write fails leaves the old config as it was and no temp file [LB-23]" {
    echo old >"$SD/written.conf"
    SYNC_FAIL=1 SYNC_DEST="$SD/written.conf" PATH="$SD/shim:$PATH" _mic_check_generate
    [ "$status" -eq 0 ]
    [[ "$output" == *"generate rc=2"* ]]
    [ "$(cat "$SD/written.conf")" = "old" ]
    assert_no_temp_files
    [ -z "$(find "$SD" -maxdepth 1 -name 'written.conf.*')" ]
    grep -q 'Failed to write configuration file' "$SD/generate.err"
}

@test "without lyrebird-common.sh next to it, generate_config still replaces the config atomically (no fsync) [LB-23]" {
    mkdir -p "$SD/lone"
    cp "$PROJECT_ROOT/lyrebird-mic-check.sh" "$SD/lone/"
    echo old >"$SD/written.conf"
    mkdir -p "$SD/asound/card0"
    echo "b58e:9e84" >"$SD/asound/card0/usbid"
    run bash -c '
        source "$SD/lone/lyrebird-mic-check.sh" >/dev/null 2>&1
        set +e
        declare -F lyrebird_fsync_path >/dev/null && echo "library loaded: test is void"
        check_root_access() { :; }
        check_disk_space() { :; }
        get_device_info() { printf "card_number=0\ndevice_name=Blue Yeti\nusb_id=b58e:9e84\n"; }
        detect_device_capabilities() { printf "is_usb=true\nsample_rates=48000\nchannels=2\ncapture_capable=true\n"; }
        ASOUND_PROC_ROOT="$SD/asound"
        CONFIG_FILE="$SD/written.conf" MODE_FORCE=true MODE_NO_BACKUP=true QUALITY_TIER=normal
        generate_config >/dev/null 2>"$SD/generate.err"
        echo "generate rc=$?"'
    [[ "$output" == *"generate rc=0"* ]]
    [[ "$output" != *"library loaded"* ]]
    grep -qE '^DEVICE_BLUE_YETI_SAMPLE_RATE="48000"$' "$SD/written.conf"
    [ "$(stat -c %a "$SD/written.conf")" = "644" ]
    assert_no_temp_files
}

# Run the REAL restore_config_backup of lyrebird-mic-check.sh for the backup of 20260102_030405
_mic_check_restore() {
    run bash -c '
        source "$PROJECT_ROOT/lyrebird-mic-check.sh" >/dev/null 2>&1
        set +e
        CONFIG_FILE="$SD/written.conf" MODE_FORCE=true MODE_NO_BACKUP=true
        restore_config_backup 20260102_030405 >/dev/null 2>"$SD/restore.err"
        echo "restore rc=$?"'
}

@test "restore_config_backup flushes the config before the rename and the directory after it, and keeps the backup's mode [LB-23, D14]" {
    printf '%s\n' '# restored backup' 'DEVICE_BLUE_YETI_SAMPLE_RATE="44100"' >"$SD/written.conf.backup.20260102_030405"
    chmod 600 "$SD/written.conf.backup.20260102_030405"
    echo old >"$SD/written.conf"
    SYNC_DEST="$SD/written.conf" PATH="$SD/shim:$PATH" _mic_check_restore
    [[ "$output" == *"restore rc=0"* ]]
    [ "$(head -n 1 "$SD/written.conf")" = "# restored backup" ]
    cmp "$SD/written.conf" "$SD/written.conf.backup.20260102_030405"
    # what cp -p gave the live file before: the backup's mode
    [ "$(stat -c %a "$SD/written.conf")" = "600" ]
    mapfile -t calls <"$SYNC_LOG"
    [ "${#calls[@]}" -eq 2 ] || {
        cat "$SYNC_LOG"
        false
    }
    [[ "${calls[0]}" == "path=$SD/.written.conf."* && "${calls[0]}" == *"exists=y dest=old" ]]
    [ "${calls[1]}" = "path=$SD exists=y dest=# restored backup" ]
    # no temp file under the name the old code used either
    [ -z "$(find "$SD" -maxdepth 1 -name 'written.conf.restore.*' -o -name '.written.conf.*')" ]
}

@test "a restore whose write fails leaves the live config as it was [LB-23]" {
    printf '%s\n' '# restored backup' >"$SD/written.conf.backup.20260102_030405"
    echo old >"$SD/written.conf"
    SYNC_FAIL=1 SYNC_DEST="$SD/written.conf" PATH="$SD/shim:$PATH" _mic_check_restore
    [[ "$output" == *"restore rc=2"* ]]
    [ "$(cat "$SD/written.conf")" = "old" ]
    [ -z "$(find "$SD" -maxdepth 1 -name 'written.conf.restore.*' -o -name '.written.conf.*')" ]
    grep -q 'Failed to restore configuration' "$SD/restore.err"
}

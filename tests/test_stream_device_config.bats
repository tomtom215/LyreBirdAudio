#!/usr/bin/env bats
# The device config is data (register: LB-08, X-09, X-01, X-28; decision D3).
#
# audio-devices.conf used to be `source`d by validate_config and by
# load_device_config: a syntactically valid `exit 0` passed validation and ended
# the real manager (start "succeeded" with nothing running), `exit 3` killed it, an
# unbound variable killed it under set -u, `trap - EXIT` removed its cleanup trap,
# `sleep 4` ran twice and `$(touch MARK; echo 48000)` ran in both places.
# parse_device_config reads it with an allowlist and nothing in it is ever run.
#
# Real code: the real parser, loader, get_device_config, resolve_stream_settings,
# validate_config, generate_mediamtx_config, monitor_streams, start_ffmpeg_stream,
# main (start/validate/status arms) and the real script as a command (`validate`).
# Stand-ins are named where used (the wrapper process; hardware probes).

load scratch_tmpdir
load stream_definition_helper

setup() {
    sd_setup
    # A marker file any executed config line would create is looked for here
    cd "$SD"
}

teardown() {
    sd_teardown
}

# Write the device config from printf arguments: _conf 'line1' 'line2' ...
_conf() {
    printf '%s\n' "$@" >"$MEDIAMTX_DEVICE_CONFIG"
}

# Dump of what the real validate_config makes of the device config
_DUMP='
rc=0; validate_config || rc=$?
printf "rc=%s errors=%s warnings=%s settings=%s\n" "$rc" "$DEVICE_CONFIG_ERROR_COUNT" "${#DEVICE_CONFIG_WARNINGS[@]}" "${#DEVICE_SETTINGS[@]}"
if ((${#DEVICE_SETTINGS[@]} > 0)); then
    for k in $(printf "%s\n" "${!DEVICE_SETTINGS[@]}" | sort); do printf "%s=%s\n" "$k" "${DEVICE_SETTINGS[$k]}"; done
fi
echo STILL-ALIVE'

# ---------------------------------------------------------------------------
# What is accepted
# ---------------------------------------------------------------------------

@test "bare, single-quoted and double-quoted values, comments, blank lines and indentation are parsed as data [D3]" {
    _conf '# a comment' '' \
        'DEVICE_YETI_SAMPLE_RATE=96000' \
        'DEVICE_YETI_CHANNELS="1"' \
        "DEVICE_YETI_CODEC='aac'" \
        'DEVICE_YETI_BITRATE=192k   # trailing comment' \
        '    DEVICE_YETI_THREAD_QUEUE=4096' \
        '   # indented comment' \
        "DEVICE_OTHER_BITRATE='64k' # quoted, then a comment"
    run smq "$_DUMP"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "rc=0 errors=0 warnings=0 settings=6" ]
    [ "${lines[1]}" = "DEVICE_OTHER_BITRATE=64k" ]
    [ "${lines[2]}" = "DEVICE_YETI_BITRATE=192k" ]
    [ "${lines[3]}" = "DEVICE_YETI_CHANNELS=1" ]
    [ "${lines[4]}" = "DEVICE_YETI_CODEC=aac" ]
    [ "${lines[5]}" = "DEVICE_YETI_SAMPLE_RATE=96000" ]
    [ "${lines[6]}" = "DEVICE_YETI_THREAD_QUEUE=4096" ]
    [ "${lines[7]}" = "STILL-ALIVE" ]
}

@test "a missing device config is not a problem: defaults apply [D3]" {
    run smq "$_DUMP"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "rc=0 errors=0 warnings=0 settings=0" ]
}

@test "CRLF line endings and a UTF-8 byte order mark are accepted [D3]" {
    printf '\xef\xbb\xbfDEVICE_A_CODEC=aac\r\nDEVICE_A_BITRATE="96k"\r\n# comment\r\nDEVICE_B_SAMPLE_RATE=44100\r\n' >"$MEDIAMTX_DEVICE_CONFIG"
    run smq "$_DUMP"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "rc=0 errors=0 warnings=0 settings=3" ]
    [ "${lines[1]}" = "DEVICE_A_BITRATE=96k" ]
    [ "${lines[2]}" = "DEVICE_A_CODEC=aac" ]
    [ "${lines[3]}" = "DEVICE_B_SAMPLE_RATE=44100" ]
}

@test "a final line without a newline is read [D3]" {
    printf 'DEVICE_A_CODEC=mp3' >"$MEDIAMTX_DEVICE_CONFIG"
    run smq "$_DUMP"
    [ "${lines[0]}" = "rc=0 errors=0 warnings=0 settings=1" ]
    [ "${lines[1]}" = "DEVICE_A_CODEC=mp3" ]
}

@test "mixed-case keys, as lyrebird-mic-check used to write them, are read as upper-case with a warning [D3, C4]" {
    _conf 'Device_Blue_Yeti_Sample_Rate=44100' 'DEVICE_Blue_Yeti_CODEC=aac'
    run smq "$_DUMP"'
        get_device_config "Blue Yeti" SAMPLE_RATE 48000'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "rc=0 errors=0 warnings=2 settings=2" ]
    [ "${lines[1]}" = "DEVICE_BLUE_YETI_CODEC=aac" ]
    [ "${lines[2]}" = "DEVICE_BLUE_YETI_SAMPLE_RATE=44100" ]
    [ "${lines[-1]}" = "44100" ]
    [ "$(sd_count "$STREAM_MANAGER_LOG_FILE" "key read as DEVICE_BLUE_YETI_SAMPLE_RATE (keys are upper-case)")" -eq 1 ]
}

@test "a duplicate key: the last line wins and the warning names the first [D3]" {
    _conf 'DEVICE_A_CHANNELS=1' 'DEVICE_A_CODEC=aac' 'DEVICE_A_CHANNELS=2'
    run smq "$_DUMP"
    [ "${lines[0]}" = "rc=0 errors=0 warnings=1 settings=2" ]
    [ "${lines[1]}" = "DEVICE_A_CHANNELS=2" ]
    [ "$(sd_count "$STREAM_MANAGER_LOG_FILE" "audio-devices.conf:3: DEVICE_A_CHANNELS: overrides the value on line 1")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Per-key value validation
# ---------------------------------------------------------------------------

# _check_batch KEY 'VALUE|EXPECTED'...: the real device_setting_check on each
# VALUE; EXPECTED is the normal form it must give, or REJECT
_check_batch() {
    local key="$1" out
    shift
    out="$(bash -c 'source "$LB_REAL_SCRIPT" || exit 99
        key="$1"; shift
        for pair in "$@"; do
            value="${pair%%|*}"; want="${pair#*|}"
            if device_setting_check "$key" "$value"; then got="$DS_VALUE"; else got=REJECT; fi
            [[ "$got" == "$want" ]] || printf "%s=[%s]: got [%s], want [%s]\n" "$key" "$value" "$got" "$want"
        done' _ "$key" "$@")"
    [ -z "$out" ] || { echo "$out"; return 1; }
}

@test "SAMPLE_RATE accepts the supported rates, normalises leading zeros and rejects everything else [D3]" {
    _check_batch SAMPLE_RATE '8000|8000' '11025|11025' '12000|12000' '16000|16000' '22050|22050' '24000|24000' \
        '32000|32000' '44100|44100' '48000|48000' '88200|88200' '96000|96000' '176400|176400' '192000|192000' \
        '352800|352800' '384000|384000' '705600|705600' '768000|768000' '048000|48000' \
        '0|REJECT' '4800|REJECT' '44800|REJECT' '480000|REJECT' '99999999999|REJECT' '-48000|REJECT' \
        '48000.5|REJECT' '0x10|REJECT' '48000 96000|REJECT' '|REJECT' 'abc|REJECT' '1e5|REJECT'
}

@test "CHANNELS accepts 1 to 32 and rejects the rest [D3]" {
    _check_batch CHANNELS '1|1' '2|2' '8|8' '32|32' '02|2' \
        '0|REJECT' '33|REJECT' '100|REJECT' '-1|REJECT' '2.5|REJECT' '2 3|REJECT' '|REJECT' 'x|REJECT'
}

@test "CODEC accepts opus, aac and mp3 in any case and rejects every other name, pcm_s16le included [D3, X-28]" {
    _check_batch CODEC 'opus|opus' 'aac|aac' 'mp3|mp3' 'OPUS|opus' 'Mp3|mp3' \
        'pcm_s16le|REJECT' 'pcm|REJECT' 'flac|REJECT' 'wav|REJECT' 'libopus|REJECT' 'vorbis|REJECT' \
        'opus aac|REJECT' '|REJECT' 'opus2|REJECT' '../x|REJECT'
}

@test "the codec error names the supported codecs [D3, X-28]" {
    _conf 'DEVICE_BLUE_YETI_CODEC=pcm_s16le'
    run smq "$_DUMP"
    [ "${lines[0]}" = "rc=1 errors=1 warnings=0 settings=0" ]
    [ "$(sd_count "$STREAM_MANAGER_LOG_FILE" "DEVICE_BLUE_YETI_CODEC: unsupported value 'pcm_s16le' (expected: one of opus, aac, mp3)")" -eq 1 ]
}

@test "BITRATE accepts 1k to 9999k and rejects the rest [D3]" {
    _check_batch BITRATE '1k|1k' '64k|64k' '128k|128k' '9999k|9999k' '128K|128k' '0128k|128k' \
        '0k|REJECT' '10000k|REJECT' '128|REJECT' '128kb|REJECT' 'k|REJECT' '|REJECT' '1.5k|REJECT' \
        '-64k|REJECT' '128 k|REJECT' '1M|REJECT'
}

@test "THREAD_QUEUE accepts 1 to 1048576 and rejects the rest [D3]" {
    _check_batch THREAD_QUEUE '1|1' '8192|8192' '16384|16384' '1048576|1048576' \
        '0|REJECT' '1048577|REJECT' '99999999|REJECT' '-1|REJECT' '|REJECT' '8k|REJECT'
}

@test "a problem is one structured line: file, line, key, what is wrong, what is expected [D3]" {
    _conf 'DEVICE_A_CODEC=aac' 'DEVICE_A_SAMPLE_RATE=44800'
    run smq "$_DUMP"
    [ "${lines[0]}" = "rc=1 errors=1 warnings=0 settings=1" ]
    grep -qE "^\[[0-9: -]+\] \[ERROR\] Device config .*/audio-devices\.conf:2: DEVICE_A_SAMPLE_RATE: unsupported value '44800' \(expected: one of 8000, 11025, " "$STREAM_MANAGER_LOG_FILE"
}

@test "unknown settings and DEFAULT_ lines are errors that say what to do [D3]" {
    _conf 'DEVICE_A_FOO=1' 'DEFAULT_CODEC=aac' 'OTHER=1' 'DEVICE_A_CODEC = aac'
    run smq "$_DUMP"
    [ "${lines[0]}" = "rc=1 errors=4 warnings=0 settings=0" ]
    grep -qF 'DEVICE_A_FOO: unknown setting (expected: DEVICE_<NAME>_<SETTING> with SETTING one of SAMPLE_RATE, CHANNELS, CODEC, BITRATE, THREAD_QUEUE, PCM)' "$STREAM_MANAGER_LOG_FILE"
    grep -qF 'DEFAULT_CODEC: defaults are read from the environment (the DEFAULT_CODEC variable), not from this file' "$STREAM_MANAGER_LOG_FILE"
    grep -qF 'OTHER: unknown key' "$STREAM_MANAGER_LOG_FILE"
    grep -qF "no spaces are allowed before the '='" "$STREAM_MANAGER_LOG_FILE"
}

# ---------------------------------------------------------------------------
# Hostile files: nothing in the file runs, nothing ends the manager
# ---------------------------------------------------------------------------

# _hostile LABEL LINE...: the file holds a good line, the hostile lines, a good line.
# The real parser and loader must survive, run nothing, and keep the good lines.
_hostile() {
    local label="$1"
    shift
    _conf 'DEVICE_GOOD_CODEC=aac' "$@" 'DEVICE_GOOD2_CHANNELS=1'
    rm -f "$SD/MARK" "$SD/MARK2"
    run smq "$_DUMP"'
        load_device_config
        echo LOADER-RETURNED
        generate_mediamtx_config >/dev/null 2>&1; echo "generate rc=$?"'
    [ "$status" -eq 0 ] || { echo "$label: status $status: $output"; return 1; }
    [[ "$output" == *"STILL-ALIVE"* ]] || { echo "$label: the manager ended: $output"; return 1; }
    [[ "$output" == *"LOADER-RETURNED"* ]] || { echo "$label: the loader did not return: $output"; return 1; }
    [[ "$output" == *"generate rc=0"* ]] || { echo "$label: config generation failed: $output"; return 1; }
    [[ "$output" == *"DEVICE_GOOD_CODEC=aac"* && "$output" == *"DEVICE_GOOD2_CHANNELS=1"* ]] || { echo "$label: good lines lost: $output"; return 1; }
    [[ "${lines[0]}" == "rc=1 "* ]] || { echo "$label: not reported as invalid: ${lines[0]}"; return 1; }
    [ ! -e "$SD/MARK" ] && [ ! -e "$SD/MARK2" ] || { echo "$label: a config line ran"; return 1; }
}

@test "'exit 0' and 'exit 3' end nothing and are reported [LB-08]" {
    _hostile "exit 0" 'exit 0'
    _hostile "exit 3" 'exit 3'
    _hostile "return" 'return 0'
}

@test "'exec' does not replace the manager [LB-08]" {
    _hostile "exec" 'exec sleep 30'
    _hostile "exec touch" 'exec touch MARK'
}

@test "an unbound variable on a line cannot kill the manager under set -u [LB-08, X-09]" {
    _hostile "unbound" 'DEVICE_X_CHANNELS=$UNSET_VARIABLE_FOR_THIS_TEST'
    _hostile "unbound braces" 'DEVICE_X_CHANNELS=${UNSET_VARIABLE_FOR_THIS_TEST}'
    _hostile "unbound command" 'echo $UNSET_VARIABLE_FOR_THIS_TEST'
}

@test "a trap line does not remove the manager's own trap [LB-08, X-09]" {
    _conf 'trap - EXIT INT TERM QUIT' 'trap "" TERM' 'DEVICE_A_CODEC=aac'
    run smq 'trap "echo CLEANUP-TRAP" EXIT
        trap "echo TERM-TRAP" TERM
        load_device_config
        trap -p EXIT; trap -p TERM'
    [ "$status" -eq 0 ]
    [[ "$output" == *"trap -- 'echo CLEANUP-TRAP' EXIT"* ]]
    [[ "$output" == *"trap -- 'echo TERM-TRAP' "*TERM* ]]
    # the manager's EXIT trap still runs on the way out
    [[ "$output" == *"CLEANUP-TRAP"* ]]
}

@test "'sleep' does not run (it used to run twice, in validation and in the loader) [LB-08]" {
    _conf 'sleep 4' 'DEVICE_A_CODEC=aac'
    local start end
    start=$SECONDS
    run smq "$_DUMP"'
        load_device_config'
    end=$SECONDS
    [ "$status" -eq 0 ]
    [[ "$output" == *"STILL-ALIVE"* ]]
    ((end - start < 3))
}

@test "command substitution and backticks in a value are never run [LB-08]" {
    _hostile 'subst' 'DEVICE_X_SAMPLE_RATE=$(touch MARK; echo 48000)'
    _hostile 'subst quoted' 'DEVICE_X_SAMPLE_RATE="$(touch MARK; echo 48000)"'
    _hostile 'subst single' "DEVICE_X_SAMPLE_RATE='\$(touch MARK; echo 48000)'"
    _hostile 'backticks' 'DEVICE_X_SAMPLE_RATE=`touch MARK`'
    _hostile 'backticks quoted' 'DEVICE_X_SAMPLE_RATE="`touch MARK`"'
    _hostile 'arithmetic' 'DEVICE_X_CHANNELS=$((1+1))'
    _hostile 'subshell' '(touch MARK)'
    _hostile 'subst command' '$(touch MARK)'
}

@test "shell syntax after a value is an error and is not run [LB-08]" {
    _hostile 'semicolon' 'DEVICE_X_CODEC=opus;touch MARK'
    _hostile 'and' 'DEVICE_X_CODEC=opus&&touch MARK'
    _hostile 'and spaced' 'DEVICE_X_CODEC=opus && touch MARK'
    _hostile 'pipe' 'DEVICE_X_CODEC=opus|touch MARK'
    _hostile 'redirect' 'DEVICE_X_CODEC=opus >MARK'
    _hostile 'redirect tight' 'DEVICE_X_CODEC=opus>MARK'
    _hostile 'background' 'DEVICE_X_CODEC=opus & touch MARK'
    _hostile 'newline in quotes' 'DEVICE_X_CODEC="opus
touch MARK"'
}

@test "source, dot, eval, function definitions and compound commands are not run [LB-08]" {
    printf 'touch MARK2\n' >"$SD/other.conf"
    _hostile 'source' "source $SD/other.conf"
    _hostile 'dot' ". $SD/other.conf"
    _hostile 'eval' 'eval touch MARK'
    _hostile 'function' 'f() { touch MARK; }' 'f'
    _hostile 'if' 'if true; then touch MARK; fi'
    _hostile 'export' 'export DEVICE_X_CODEC=opus'
    _hostile 'declare' 'declare -r DEVICE_GOOD_CODEC=opus'
    _hostile 'readonly' 'readonly DEFAULT_CODEC=aac'
}

@test "an unterminated quote costs that line only [LB-08]" {
    _hostile 'single' "DEVICE_X_CODEC='opus"
    _hostile 'double' 'DEVICE_X_CODEC="opus'
    _hostile 'array' 'DEVICE_X_CHANNELS=(1 2'
}

@test "backslashes and dollar signs inside double quotes are not interpreted [LB-08]" {
    _hostile 'dollar' 'DEVICE_X_CODEC="op$us"'
    _hostile 'backslash' 'DEVICE_X_CODEC="opus\"'
    _hostile 'trailing backslash' 'DEVICE_X_BITRATE=128k\'
}

@test "binary junk is reported, capped, and ends nothing [LB-08]" {
    python3 -I -c '
import random, sys
r = random.Random(7)
data = bytes(r.randrange(256) for _ in range(20000))
sys.stdout.buffer.write(b"DEVICE_GOOD_CODEC=aac\n" + data + b"\nDEVICE_GOOD2_CHANNELS=1\n")' >"$MEDIAMTX_DEVICE_CONFIG"
    run smq "$_DUMP"'
        load_device_config; echo LOADER-RETURNED'
    [ "$status" -eq 0 ]
    [[ "$output" == *"STILL-ALIVE"* && "$output" == *"LOADER-RETURNED"* ]]
    [[ "${lines[0]}" == "rc=1 errors="* ]]
    # at most 50 problems are listed, the rest only counted
    [ "$(grep -c '\[ERROR\] Device config .*audio-devices.conf:[0-9]' "$STREAM_MANAGER_LOG_FILE")" -le 50 ]
    grep -q 'more problems not shown' "$STREAM_MANAGER_LOG_FILE"
    [[ "$output" == *"DEVICE_GOOD_CODEC=aac"* && "$output" == *"DEVICE_GOOD2_CHANNELS=1"* ]]
}

@test "a 1 MB line makes the file too large, and is refused in bounded time [LB-08]" {
    {
        printf 'DEVICE_GOOD_CODEC=aac\nDEVICE_X_CODEC='
        head -c 1000000 /dev/zero | tr '\0' a
        printf '\nDEVICE_GOOD2_CHANNELS=1\n'
    } >"$MEDIAMTX_DEVICE_CONFIG"
    local start=$SECONDS
    run smq "$_DUMP"
    [ "$status" -eq 0 ]
    ((SECONDS - start < 10))
    [ "${lines[0]}" = "rc=1 errors=1 warnings=0 settings=0" ]
    grep -qE 'audio-devices\.conf: is [0-9]+ bytes long, more than the 65536 byte limit' "$STREAM_MANAGER_LOG_FILE"
    # the log line itself stays short
    [ "$(awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$STREAM_MANAGER_LOG_FILE")" -lt 600 ]
}

@test "a very long line in a file of acceptable size is refused quickly, whatever it holds, and the lines around it are read [LB-08]" {
    local kind start
    for kind in a spaces tabs equals; do
        {
            printf 'DEVICE_GOOD_CODEC=aac\n'
            case "$kind" in
                a) head -c 50000 /dev/zero | tr '\0' a ;;
                spaces) head -c 50000 /dev/zero | tr '\0' ' ' ;;
                tabs) head -c 50000 /dev/zero | tr '\0' '\t' ;;
                equals) printf 'DEVICE_X_CODEC='; head -c 50000 /dev/zero | tr '\0' '=' ;;
            esac
            printf '\nDEVICE_GOOD2_CHANNELS=1\n'
        } >"$MEDIAMTX_DEVICE_CONFIG"
        start=$SECONDS
        run smq "$_DUMP"
        [ "$status" -eq 0 ]
        ((SECONDS - start < 10)) || { echo "$kind: took $((SECONDS - start)) s"; return 1; }
        [ "${lines[0]}" = "rc=1 errors=1 warnings=0 settings=2" ] || { echo "$kind: ${lines[0]}"; return 1; }
        grep -qE "audio-devices\.conf:2: line is 50[0-9]+ characters long, more than the 4096 character limit" "$STREAM_MANAGER_LOG_FILE" || { echo "$kind: no line error"; return 1; }
        : >"$STREAM_MANAGER_LOG_FILE"
    done
}

@test "a long comment line is ignored, not an error [D3]" {
    { printf '# '; head -c 6000 /dev/zero | tr '\0' c; printf '\nDEVICE_A_CODEC=aac\n'; } >"$MEDIAMTX_DEVICE_CONFIG"
    run smq "$_DUMP"
    [ "${lines[0]}" = "rc=0 errors=0 warnings=0 settings=1" ]
}

@test "a file of garbage lines stops being read after 100 problems, in bounded time [LB-08]" {
    yes 'x' | head -n 30000 >"$MEDIAMTX_DEVICE_CONFIG"
    local start=$SECONDS
    run smq "$_DUMP"
    [ "$status" -eq 0 ]
    ((SECONDS - start < 20))
    [ "${lines[0]}" = "rc=1 errors=100 warnings=0 settings=0" ]
    grep -qE 'audio-devices\.conf:101: stopped reading after 100 problems; this line and the rest of the file were not read' "$STREAM_MANAGER_LOG_FILE"
}

@test "a config file larger than 64 KiB is one error and contributes nothing [LB-08]" {
    { printf 'DEVICE_GOOD_CODEC=aac\n'; head -c 100000 /dev/zero | tr '\0' '#'; printf '\n'; } >"$MEDIAMTX_DEVICE_CONFIG"
    run smq "$_DUMP"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "rc=1 errors=1 warnings=0 settings=0" ]
    grep -qE 'bytes long, more than the 65536 byte limit' "$STREAM_MANAGER_LOG_FILE"
}

@test "a directory or a FIFO where the config file should be is an error and is never read [LB-08]" {
    mkdir "$MEDIAMTX_DEVICE_CONFIG"
    run timeout 20 bash -c 'exec 2>/dev/null; source "$LB_REAL_SCRIPT"; '"$_DUMP"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "rc=1 errors=1 warnings=0 settings=0" ]
    grep -qF 'is not a regular file' "$STREAM_MANAGER_LOG_FILE"
    rmdir "$MEDIAMTX_DEVICE_CONFIG"
    mkfifo "$MEDIAMTX_DEVICE_CONFIG"
    run timeout 20 bash -c 'exec 2>/dev/null; source "$LB_REAL_SCRIPT"; '"$_DUMP"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "rc=1 errors=1 warnings=0 settings=0" ]
}

@test "control characters in a bad value are not written to the log raw [LB-08]" {
    printf 'DEVICE_A_CODEC=op\x1b[31mus\n' >"$MEDIAMTX_DEVICE_CONFIG"
    run smq "$_DUMP"
    [ "${lines[0]}" = "rc=1 errors=1 warnings=0 settings=0" ]
    ! grep -q $'\x1b' "$STREAM_MANAGER_LOG_FILE"
}

# ---------------------------------------------------------------------------
# The loader and its callers
# ---------------------------------------------------------------------------

@test "the template save_device_config writes is accepted, and so are its examples uncommented [D3]" {
    run smq 'save_device_config; echo saved'
    [ "$status" -eq 0 ]
    [ -s "$MEDIAMTX_DEVICE_CONFIG" ]
    run smq "$_DUMP"
    [ "${lines[0]}" = "rc=0 errors=0 warnings=0 settings=0" ]
    # the documented examples, uncommented
    sed -i -E 's/^# (DEVICE_BLUE_YETI_[A-Z_]+=)/\1/' "$MEDIAMTX_DEVICE_CONFIG"
    run smq "$_DUMP"
    [ "${lines[0]}" = "rc=0 errors=0 warnings=0 settings=5" ]
    [ "${lines[1]}" = "DEVICE_BLUE_YETI_BITRATE=256k" ]
    [ "${lines[3]}" = "DEVICE_BLUE_YETI_CODEC=aac" ]
    [ "${lines[4]}" = "DEVICE_BLUE_YETI_PCM=1" ]
    # and no example in the template names a codec that is not supported (X-28)
    ! grep -q 'pcm_s16le' "$MEDIAMTX_DEVICE_CONFIG"
}

@test "get_device_config: friendly stream name first, then the device name, then the default [D3]" {
    _conf 'DEVICE_BLUE_YETI_SAMPLE_RATE=44100' 'DEVICE_USB_AUDIO_BLUE_YETI_SAMPLE_RATE=96000' 'DEVICE_USB_AUDIO_BLUE_YETI_CHANNELS=1'
    run smq '
        load_device_config
        echo "friendly: $(get_device_config usb-audio-Blue_Yeti SAMPLE_RATE 48000 blue_yeti)"
        echo "device:   $(get_device_config usb-audio-Blue_Yeti SAMPLE_RATE 48000 other_path)"
        echo "only dev: $(get_device_config usb-audio-Blue_Yeti CHANNELS 2 blue_yeti)"
        echo "default:  $(get_device_config usb-audio-Blue_Yeti CODEC opus blue_yeti)"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "friendly: 44100" ]
    [ "${lines[1]}" = "device:   96000" ]
    [ "${lines[2]}" = "only dev: 1" ]
    [ "${lines[3]}" = "default:  opus" ]
}

@test "get_device_config loads the file itself when nobody has, so no caller can see defaults only [X-01]" {
    _conf 'DEVICE_BLUE_YETI_SAMPLE_RATE=44100'
    run smq 'get_device_config usb-audio-Blue_Yeti SAMPLE_RATE 48000 blue_yeti'
    [ "$status" -eq 0 ]
    [ "$output" = "44100" ]
}

@test "resolve_stream_settings falls back to the built-in default, with an error, for an unusable DEFAULT_ value [D3, X-28]" {
    export DEFAULT_CODEC=pcm DEFAULT_BITRATE=lots
    run smq '
        resolve_stream_settings mic1 mic1
        echo "$STREAM_SAMPLE_RATE $STREAM_CHANNELS $STREAM_CODEC $STREAM_BITRATE $STREAM_THREAD_QUEUE"'
    [ "$status" -eq 0 ]
    [ "$output" = "48000 2 opus 128k 8192" ]
    grep -qF "CODEC for mic1 is 'pcm', which cannot be used (expected: one of opus, aac, mp3); using opus" "$STREAM_MANAGER_LOG_FILE"
    grep -qF "BITRATE for mic1 is 'lots'" "$STREAM_MANAGER_LOG_FILE"
}

@test "the generator and the loader go on, and the good settings stay, when other lines are bad [LB-08]" {
    _conf 'DEVICE_MIC1_CODEC=flac' 'DEVICE_MIC1_CHANNELS=1' 'garbage' 'DEVICE_MIC1_BITRATE=96k'
    run smq '
        generate_mediamtx_config >/dev/null 2>&1; echo "generate rc=$?"
        resolve_stream_settings mic1 mic1
        echo "$STREAM_SAMPLE_RATE $STREAM_CHANNELS $STREAM_CODEC $STREAM_BITRATE"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "generate rc=0" ]
    [ "${lines[1]}" = "48000 1 opus 96k" ]
}

@test "the same problems are logged once per process, not once per reader [D3]" {
    _conf 'DEVICE_MIC1_CODEC=flac'
    run smq '
        validate_config || true
        load_device_config
        resolve_stream_settings mic1 mic1
        resolve_stream_settings mic2 mic2'
    [ "$status" -eq 0 ]
    [ "$(sd_count "$STREAM_MANAGER_LOG_FILE" "DEVICE_MIC1_CODEC: unsupported value 'flac'")" -eq 1 ]
}

@test "validate_config and the loader use the same parser: what validate accepts, the loader loads [D3]" {
    _conf 'DEVICE_MIC1_SAMPLE_RATE=44100' 'DEVICE_MIC1_CODEC=AAC' 'DEVICE_MIC1_BITRATE=96K'
    run smq '
        validate_config; echo "validate rc=$?"
        a="${DEVICE_SETTINGS[*]}"
        load_device_config
        b="${DEVICE_SETTINGS[*]}"
        [[ "$a" == "$b" ]] && echo same-settings
        resolve_stream_settings mic1 mic1
        echo "$STREAM_SAMPLE_RATE $STREAM_CODEC $STREAM_BITRATE"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"validate rc=0"* ]]
    [[ "$output" == *"same-settings"* ]]
    [[ "$output" == *"44100 aac 96k"* ]]
}

# ---------------------------------------------------------------------------
# The commands
# ---------------------------------------------------------------------------

@test "the validate command exits 4 on an unusable line, names the line, and leaves no cleanup marker [LB-08]" {
    _conf 'DEVICE_A_CODEC=aac' 'exit 0' 'DEVICE_A_SAMPLE_RATE=12'
    run bash "$LB_REAL_SCRIPT" validate
    [ "$status" -eq 4 ]
    [[ "$output" == *"audio-devices.conf:2: not a DEVICE_<NAME>_<SETTING>=value assignment: 'exit 0'"* ]]
    [[ "$output" == *"audio-devices.conf:3: DEVICE_A_SAMPLE_RATE: unsupported value '12'"* ]]
    [[ "$output" == *"2 problem(s), see above"* ]]
    [ ! -e "$MEDIAMTX_CLEANUP_MARKER" ]
}

@test "the validate command exits 0 on a good file and on a missing one [D3]" {
    _conf 'DEVICE_A_CODEC=aac' '# fine'
    run bash "$LB_REAL_SCRIPT" validate
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK (1 setting(s))"* ]]
    rm -f "$MEDIAMTX_DEVICE_CONFIG"
    run bash "$LB_REAL_SCRIPT" validate
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK (0 setting(s))"* ]]
}

@test "the real validate command survives every hostile file and never runs it [LB-08]" {
    local case_lines
    for case_lines in 'exit 0' 'exit 3' 'exec touch MARK' 'trap - EXIT' 'sleep 4' '$(touch MARK)' 'DEVICE_X_CHANNELS=$UNSET' 'DEVICE_X_CODEC="opus'; do
        _conf "$case_lines"
        rm -f "$SD/MARK"
        run bash "$LB_REAL_SCRIPT" validate
        [ "$status" -eq 4 ] || { echo "$case_lines: status $status: $output"; return 1; }
        [[ "$output" == *"1 problem(s), see above"* ]] || { echo "$case_lines: $output"; return 1; }
        [ ! -e "$SD/MARK" ]
    done
}

@test "start does not stop for a bad device config: the main start arm goes on to start (README: a bad config never stops streams) [LB-08]" {
    _conf 'DEVICE_A_CODEC=pcm_s16le' 'exit 0' 'DEVICE_A_CHANNELS=2'
    # Stand-ins: everything that touches the host or hardware. The routing in main
    # and the real validate_config are what run.
    run smq '
        check_root() { :; }
        check_dependencies() { :; }
        setup_directories() { :; }
        check_version_compatibility() { :; }
        init_hardware_watchdog() { :; }
        start_mediamtx() { echo STARTED-STREAMS; return 0; }
        main start'
    [ "$status" -eq 0 ]
    [[ "$output" == *"STARTED-STREAMS"* ]]
    [ "$(sd_count "$STREAM_MANAGER_LOG_FILE" "Device configuration has problems (listed above)")" -eq 1 ]
    [ "$(sd_count "$STREAM_MANAGER_LOG_FILE" "Configuration validation failed")" -eq 0 ]
}

@test "restart's path to the config, generate_mediamtx_config, survives a config that used to end the manager [LB-08]" {
    _conf 'exit 0'
    run smq '
        generate_mediamtx_config >/dev/null 2>&1; echo "generate rc=$?"
        test -s "$CONFIG_FILE" && echo config-written'
    [ "$status" -eq 0 ]
    [[ "$output" == *"generate rc=0"* ]]
    [[ "$output" == *"config-written"* ]]
}

# ---------------------------------------------------------------------------
# X-01: per-device settings survive a monitor-triggered restart
# ---------------------------------------------------------------------------

# Stand-ins for two live processes with comm "bash": MediaMTX (monitor's first
# check) and, for the healthy case, a wrapper
_start_live_mediamtx_standin() {
    bash -c 'sleep 300; :' 3>&- &
    local pid=$!
    echo "$pid" >>"$SD_PIDS_FILE"
    echo "$pid" >"$MEDIAMTX_PID_FILE"
}

@test "a monitor-triggered restart keeps the per-device settings from the config file [X-01]" {
    _conf 'DEVICE_MIC1_SAMPLE_RATE=96000' 'DEVICE_MIC1_CHANNELS=1' 'DEVICE_MIC1_CODEC=aac' 'DEVICE_MIC1_BITRATE=192k' 'DEVICE_MIC1_THREAD_QUEUE=4096'
    _start_live_mediamtx_standin
    sd_fake_card 98 0c
    export DEEP_HEALTH_CHECK_ENABLED=false
    # The whole path is real: monitor_streams finds no PID file for the stream and
    # restarts it with start_ffmpeg_stream, which reads its settings. Nothing in
    # this process has called the loader before. Stood in for: the device list,
    # the wrapper process and the waits (the card checks are real, over a fake ALSA tree).
    run smq "$SD_SPAWN_STUBS"'
        detect_audio_devices() { printf "mic1:98\n"; }
        rc=0; monitor_streams || rc=$?
        echo "monitor rc=$rc"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"monitor rc=0"* ]]
    [ -f "$SD/ff/mic1.sh" ]
    grep -qE '^SAMPLE_RATE=.?96000' "$SD/ff/mic1.sh"
    grep -qE '^CHANNELS=.?1' "$SD/ff/mic1.sh"
    grep -qE '^CODEC=.?aac' "$SD/ff/mic1.sh"
    grep -qE '^BITRATE=.?192k' "$SD/ff/mic1.sh"
    grep -qE '^THREAD_QUEUE=.?4096' "$SD/ff/mic1.sh"
    # and not the defaults
    ! grep -qE '^SAMPLE_RATE=.?48000' "$SD/ff/mic1.sh"
}

@test "a monitor-triggered restart of the multiplex stream keeps the settings of its first device [X-01]" {
    _conf 'DEVICE_ALL_MICS_SAMPLE_RATE=44100' 'DEVICE_ALL_MICS_CHANNELS=1' 'DEVICE_ALL_MICS_BITRATE=64k'
    _start_live_mediamtx_standin
    sd_fake_card 98 0c
    sd_fake_card 99 0c
    export DEEP_HEALTH_CHECK_ENABLED=false STREAM_MODE=multiplex
    run smq "$SD_SPAWN_STUBS"'
        detect_audio_devices() { printf "mic1:98\nmic2:99\n"; }
        resolve_multiplex_stream_name
        rc=0; monitor_streams || rc=$?
        echo "monitor rc=$rc"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"monitor rc=0"* ]]
    grep -qE '^SAMPLE_RATE=.?44100' "$SD/ff/all_mics.sh"
    grep -qE '^CHANNELS=.?1' "$SD/ff/all_mics.sh"
    grep -qE '^BITRATE=.?64k' "$SD/ff/all_mics.sh"
}

@test "status shows the settings in use for each device, from the config file [D3]" {
    _conf 'DEVICE_MIC1_SAMPLE_RATE=96000' 'DEVICE_MIC1_CODEC=aac' 'DEVICE_MIC1_BITRATE=192k'
    run smq '
        detect_audio_devices() { printf "mic1:98\n"; }
        show_status'
    [ "$status" -eq 0 ]
    [[ "$output" == *"Settings: 96000 Hz, 2 ch, aac 192k"* ]]
}

# ---------------------------------------------------------------------------
# The writer: lyrebird-mic-check.sh writes what the parser accepts
# ---------------------------------------------------------------------------

# Run the REAL generate_config of lyrebird-mic-check.sh over a fake /proc/asound
# tree (ASOUND_PROC_ROOT) with two USB cards. Stood in for: the two probes that
# read the hardware's stream files (get_device_info, detect_device_capabilities)
# and the root and disk checks. The scan loop, capability parsing, tier logic,
# bitrate calculation and the writer itself are real.
_mic_check_generate() {
    local tier="$1"
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
        CONFIG_FILE="$SD/written.conf" MODE_FORCE=true MODE_NO_BACKUP=true QUALITY_TIER="$1"
        generate_config >/dev/null 2>"$SD/generate.err"
        echo "generate rc=$?"' _ "$tier"
    [ "$status" -eq 0 ]
    [[ "$output" == *"generate rc=0"* ]]
}

@test "the config lyrebird-mic-check writes is quoted and accepted by the manager's parser, for every quality tier [D3, writer]" {
    local tier
    for tier in low normal high; do
        rm -f "$SD/written.conf"
        _mic_check_generate "$tier"
        grep -qE '^DEVICE_BLUE_YETI_SAMPLE_RATE="[0-9]+"$' "$SD/written.conf"
        grep -qE '^DEVICE_BLUE_YETI_CHANNELS="[0-9]+"$' "$SD/written.conf"
        grep -qE '^DEVICE_BLUE_YETI_BITRATE="[0-9]+k"$' "$SD/written.conf"
        grep -qE '^DEVICE_RODE_NT_USB_BITRATE="[0-9]+k"$' "$SD/written.conf"
        export MEDIAMTX_DEVICE_CONFIG="$SD/written.conf"
        run smq "$_DUMP"
        [ "${lines[0]}" = "rc=0 errors=0 warnings=0 settings=6" ] || { echo "$tier: $output"; return 1; }
    done
}

@test "what lyrebird-mic-check writes is what get_device_config finds, by the device's friendly name [D3, C4, writer]" {
    _mic_check_generate high
    export MEDIAMTX_DEVICE_CONFIG="$SD/written.conf"
    run smq '
        echo "$(get_device_config "Blue Yeti" SAMPLE_RATE 1 "")"
        echo "$(get_device_config "Blue Yeti" CHANNELS 9 "")"
        echo "$(get_device_config "Rode NT-USB" BITRATE 1k "")"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "96000" ]
    [ "${lines[1]}" = "2" ]
    [[ "${lines[2]}" =~ ^[0-9]+k$ ]]
    [ "${lines[2]}" != "1k" ]
}

@test "the writer's header is written, with no unbound variable in it, under the script's own set -u [D3, writer]" {
    _mic_check_generate normal
    # The header heredoc used to expand ${name^^} and ${param^^} in a comment: under
    # set -u that is "unbound variable" and the whole header (quality tier, format
    # description, defaults note) was silently missing from every generated config
    ! grep -q 'unbound variable' "$SD/generate.err"
    head -n 1 "$SD/written.conf" | grep -qF '# MediaMTX USB Audio Device Configuration'
    grep -q '^# Quality Tier: normal$' "$SD/written.conf"
    grep -qF '(DEVICE_<NAME>_<PARAMETER>, both upper-case)' "$SD/written.conf"
}

@test "the header the writer produces says the file is read as data and lists CODEC and THREAD_QUEUE [D3, writer]" {
    _mic_check_generate normal
    grep -qF 'It is data, never executed' "$SD/written.conf"
    grep -qF 'CODEC (opus, aac or mp3), THREAD_QUEUE' "$SD/written.conf"
    ! grep -q 'is sourced by' "$SD/written.conf"
}

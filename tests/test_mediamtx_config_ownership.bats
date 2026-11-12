#!/usr/bin/env bats
# Who owns /etc/mediamtx/mediamtx.yml, and how it is replaced
# (register: LB-22, LB-23, LB-06; decisions D9, D10, D14).
#
# Every test runs the real generate_mediamtx_config (and, where the order of
# steps matters, the real start_mediamtx) on a private configuration directory.
# The MediaMTX binary is a stand-in that answers --version, --help and
# --validate-conf; test_mediamtx_config_live.bats does the same with real
# MediaMTX binaries. No port is bound: the numbers are only written into files.

load scratch_tmpdir
load mediamtx_live_helper

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SM="$PROJECT_ROOT/lyrebird-stream-manager.sh"
    D="$TEST_SCRATCH/d"
    CFG="$D/cfg"
    CONF="$CFG/mediamtx.yml"
    mkdir -p "$CFG" "$D/bin" "$D/ff"
    HELD_PIDS=()

    export MEDIAMTX_CONFIG_DIR="$CFG"
    export MEDIAMTX_PID_FILE="$D/mtx.pid"
    export MEDIAMTX_FFMPEG_DIR="$D/ff"
    export MEDIAMTX_LOG_FILE="$D/sm.log" STREAM_MANAGER_LOG_FILE="$D/sm.log"
    export MEDIAMTX_LOCK_FILE="$D/run.lock"
    export MEDIAMTX_RESTART_MARKER="$D/restart.marker"
    export MEDIAMTX_CLEANUP_MARKER="$D/cleanup.marker"
    export MEDIAMTX_HOST=localhost
    export MEDIAMTX_RTSP_PORT=36000 MEDIAMTX_API_PORT=36001 MEDIAMTX_METRICS_PORT=36002
    export LOCK_ACQUISITION_TIMEOUT=2 STOP_LOCK_TIMEOUT=1
    export MEDIAMTX_BINARY="$D/bin/mediamtx"
    unset STREAM_MODE MULTIPLEX_STREAM_NAME RTSP_AUTH_MODE RTSP_USERS_FILE MEDIAMTX_API_BIND MEDIAMTX_METRICS_BIND MEDIAMTX_CONFIG_BACKUPS

    # The MediaMTX stand-in. STUB_VALIDATE=1 gives it --validate-conf (as in
    # MediaMTX 1.21), which rejects a file containing the text $STUB_REJECT.
    cat >"$D/bin/mediamtx" <<'STUB'
#!/bin/bash
case "${1:-}" in
    --version)
        echo "${STUB_VERSION:-v1.21.1}"
        ;;
    --help)
        [[ "${STUB_VALIDATE:-}" == 1 ]] && echo "      --validate-conf=path    check whether a configuration file is valid"
        ;;
    --validate-conf=*)
        if [[ -n "${STUB_REJECT:-}" ]] && grep -q -- "$STUB_REJECT" "${1#--validate-conf=}"; then
            echo "ERR: invalid path name: stub says no"
            exit 1
        fi
        echo "configuration file is valid"
        ;;
    *)
        printf '%s\n' "$@" >"${STUB_STARTED:-/dev/null}"
        exec sleep 300
        ;;
esac
STUB
    chmod +x "$D/bin/mediamtx"
    # Nothing of the host may be touched
    local tool
    for tool in pkill pgrep; do
        printf '#!/bin/bash\nexit 1\n' >"$D/bin/$tool"
        chmod +x "$D/bin/$tool"
    done
    export PATH="$D/bin:$PATH"
}

teardown() {
    local pid
    for pid in "${HELD_PIDS[@]:-}"; do
        [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    done
    scratch_teardown
}

# gen: run the real generate_mediamtx_config in a new process (as every start
# does); GEN_RC is its status and the messages are in $D/gen.out and $D/sm.log
gen() {
    bash -c 'source "$1" >/dev/null 2>&1; set +e; generate_mediamtx_config >"$2/gen.out" 2>&1; echo $? >"$2/gen.rc"' _ "$SM" "$D"
    GEN_RC="$(<"$D/gen.rc")"
}

# The rendered file after a successful first generation: the baseline most
# tests start from
gen_ok() {
    gen
    [ "$GEN_RC" -eq 0 ] || {
        cat "$D/gen.out"
        false
    }
}

backups() {
    local f
    for f in "$CONF".????????T??????Z.??.bak; do
        [[ -e "$f" ]] && printf '%s\n' "$f"
    done
    return 0
}

count_backups() {
    backups | wc -l
}

# The port written after "apiAddress: ...:" in file $1
api_port_in() {
    sed -n 's/^apiAddress: .*:\([0-9]*\)$/\1/p' "$1"
}

# No temporary file left in the configuration directory or in TMPDIR
assert_no_leftovers() {
    local junk
    junk="$(find "$CFG" -maxdepth 1 -name '.*' ! -name '.config.lock' ! -name '.' | head -n 3)"
    [ -z "$junk" ] || {
        echo "left in the config directory: $junk"
        false
    }
    junk="$(find "$TEST_SCRATCH" -mindepth 1 -maxdepth 1 -name 'tmp.*' | head -n 3)"
    [ -z "$junk" ] || {
        echo "left in TMPDIR: $junk"
        false
    }
}

# ---------------------------------------------------------------------------
# A file that does not exist yet
# ---------------------------------------------------------------------------

@test "no file yet: the rendered configuration is written with the marker first, mode 0644, and no backup [D10]" {
    gen_ok
    [ "$(head -n 1 "$CONF")" = "# Managed by LyreBirdAudio" ]
    [ "$(stat -c %a "$CONF")" = "644" ]
    [ "$(count_backups)" -eq 0 ]
    [ "$(api_port_in "$CONF")" = "36001" ]
    assert_no_leftovers
}

@test "the configuration directory is created when it is missing" {
    rm -rf "$CFG"
    gen_ok
    [ -f "$CONF" ]
}

# ---------------------------------------------------------------------------
# A managed file
# ---------------------------------------------------------------------------

@test "a managed file whose rendering is unchanged is not touched at all: same inode, same mtime, no backup [LB-22]" {
    gen_ok
    touch -d '2001-02-03 04:05:06' "$CONF"
    local inode mtime
    inode="$(stat -c %i "$CONF")"
    mtime="$(stat -c %.9Y "$CONF")"
    local i
    for i in 1 2 3; do
        gen_ok
    done
    [ "$(stat -c %i "$CONF")" = "$inode" ]
    [ "$(stat -c %.9Y "$CONF")" = "$mtime" ]
    [ "$(count_backups)" -eq 0 ]
    grep -q 'is up to date' "$D/sm.log"
    assert_no_leftovers
}

@test "a managed file whose rendering changes is replaced after a backup of the old content [LB-22]" {
    gen_ok
    cp -p "$CONF" "$D/v0"
    MEDIAMTX_API_PORT=36005 gen_ok
    [ "$(api_port_in "$CONF")" = "36005" ]
    [ "$(count_backups)" -eq 1 ]
    cmp "$(backups)" "$D/v0"
    [[ "$(backups)" == "$CONF".*Z.00.bak ]]
    grep -q 'Saved the previous MediaMTX configuration as' "$D/sm.log"
    assert_no_leftovers
}

@test "backups are bounded: only the newest MEDIAMTX_CONFIG_BACKUPS (default 5) are kept, even when several fall in one second [LB-22]" {
    local i
    for i in 0 1 2 3 4 5 6 7 8; do
        MEDIAMTX_API_PORT=$((36100 + i)) gen_ok
    done
    [ "$(api_port_in "$CONF")" = "36108" ]
    [ "$(count_backups)" -eq 5 ]
    local f ports=""
    while IFS= read -r f; do
        ports+="$(api_port_in "$f") "
    done < <(backups)
    # the five newest old versions, oldest first
    [ "$ports" = "36103 36104 36105 36106 36107 " ] || {
        echo "backups hold: $ports"
        backups
        false
    }
}

@test "MEDIAMTX_CONFIG_BACKUPS sets the number of backups, and at least one is always kept [LB-22]" {
    local i
    for i in 0 1 2 3 4 5; do
        MEDIAMTX_CONFIG_BACKUPS=2 MEDIAMTX_API_PORT=$((36100 + i)) gen_ok
    done
    [ "$(count_backups)" -eq 2 ]
    for i in 6 7 8; do
        MEDIAMTX_CONFIG_BACKUPS=0 MEDIAMTX_API_PORT=$((36100 + i)) gen_ok
    done
    [ "$(count_backups)" -eq 1 ]
    [ "$(api_port_in "$(backups)")" = "36107" ]
}

@test "the mode of a managed file the operator changed is kept when it is replaced, and the backup has it too [LB-22]" {
    gen_ok
    chmod 640 "$CONF"
    MEDIAMTX_API_PORT=36005 gen_ok
    [ "$(stat -c %a "$CONF")" = "640" ]
    [ "$(stat -c %a "$(backups)")" = "640" ]
    chmod 600 "$CONF"
    MEDIAMTX_API_PORT=36006 gen_ok
    [ "$(stat -c %a "$CONF")" = "600" ]
}

@test "the group of a managed file is kept when it is replaced [LB-22]" {
    local gid
    if [ "$(id -u)" -eq 0 ]; then
        gid=23456
    else
        gid="$(for g in $(id -G); do [ "$g" != "$(id -g)" ] && echo "$g" && break; done)"
        [ -n "$gid" ] || skip "no second group to test with"
    fi
    gen_ok
    chgrp "$gid" "$CONF"
    MEDIAMTX_API_PORT=36005 gen_ok
    [ "$(stat -c %g "$CONF")" = "$gid" ]
    [ "$(stat -c %g "$(backups)")" = "$gid" ]
}

@test "the replacement is flushed to disk: the temp file before the rename, the directory after it [LB-23, D14]" {
    gen_ok
    cp -p "$CONF" "$D/v0"
    cat >"$D/bin/sync" <<'SHIM'
#!/bin/bash
[[ "$1" == "--" ]] && shift
printf 'path=%s dest=%s\n' "$1" "$(grep -o '^apiAddress: .*' "$SYNC_DEST" 2>/dev/null)" >>"$SYNC_LOG"
SHIM
    chmod +x "$D/bin/sync"
    SYNC_DEST="$CONF" SYNC_LOG="$D/sync.log" MEDIAMTX_API_PORT=36005 gen_ok
    mapfile -t calls <"$D/sync.log"
    # backup (temp file, directory), then the configuration (temp file, directory)
    [ "${#calls[@]}" -eq 4 ] || {
        printf '%s\n' "${calls[@]}"
        false
    }
    [[ "${calls[0]}" == "path=$CFG/.mediamtx.yml."*".00.bak."* ]]
    [[ "${calls[1]}" == "path=$CFG dest=apiAddress: 127.0.0.1:36001" ]]
    [[ "${calls[2]}" == "path=$CFG/.mediamtx.yml."* ]]
    [[ "${calls[2]}" == *"dest=apiAddress: 127.0.0.1:36001" ]]
    [[ "${calls[3]}" == "path=$CFG dest=apiAddress: 127.0.0.1:36005" ]]
}

@test "an empty file, what a power cut during an old non-durable write leaves behind, is replaced rather than treated as the operator's [LB-23]" {
    : >"$CONF"
    chmod 640 "$CONF"
    gen_ok
    [ "$(head -n 1 "$CONF")" = "# Managed by LyreBirdAudio" ]
    [ "$(stat -c %a "$CONF")" = "640" ]
    # nothing worth a backup
    [ "$(count_backups)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The marker
# ---------------------------------------------------------------------------

@test "only a first line that is the marker (a line ending or trailing blanks aside) makes a file managed [D10]" {
    local text
    for text in $'# Managed by LyreBirdAudio\nlogLevel: info\n' $'# Managed by LyreBirdAudio\r\nlogLevel: info\r\n' \
        $'# Managed by LyreBirdAudio   \t\nlogLevel: info\n' $'# Managed by LyreBirdAudio\n' '# Managed by LyreBirdAudio'; do
        printf '%s' "$text" >"$D/m.yml"
        run bash -c 'source "$1" >/dev/null 2>&1; mediamtx_config_is_managed "$2"' _ "$SM" "$D/m.yml"
        [ "$status" -eq 0 ] || {
            echo "not managed: $(printf '%q' "$text")"
            false
        }
    done
    for text in $'\n# Managed by LyreBirdAudio\nlogLevel: info\n' $'  # Managed by LyreBirdAudio\nlogLevel: info\n' \
        $'#Managed by LyreBirdAudio\nlogLevel: info\n' $'# managed by lyrebirdaudio\nlogLevel: info\n' \
        $'logLevel: info\n# Managed by LyreBirdAudio\n' $'# Managed by LyreBirdAudio v2\nlogLevel: info\n' \
        $'# MediaMTX Configuration - Audio Streams\nlogLevel: info\n' '' $'logLevel: info\n'; do
        printf '%s' "$text" >"$D/m.yml"
        run bash -c 'source "$1" >/dev/null 2>&1; mediamtx_config_is_managed "$2"' _ "$SM" "$D/m.yml"
        [ "$status" -ne 0 ] || {
            echo "managed: $(printf '%q' "$text")"
            false
        }
    done
}

# ---------------------------------------------------------------------------
# An operator-owned file
# ---------------------------------------------------------------------------

# A hand-edited file: authentication, loopback binds, a different log level, a
# custom path, and a mode the operator chose
write_operator_file() {
    cat >"$CONF" <<'YAML'
logLevel: error
api: yes
apiAddress: 127.0.0.1:36001
metrics: no
rtsp: yes
rtspAddress: :36000
authMethod: internal
authInternalUsers:
  - user: any
    pass:
    ips: ['127.0.0.1', '::1']
    permissions:
      - action: publish
      - action: read
      - action: api
paths:
  mic1:
    source: publisher
YAML
    chmod 640 "$CONF"
    cp -p "$CONF" "$D/operator.yml"
}

@test "an operator-owned file is used as it is: bytes, mode, inode and mtime survive every start, with no backup [LB-22]" {
    write_operator_file
    touch -d '2001-02-03 04:05:06' "$CONF"
    local inode mtime i
    inode="$(stat -c %i "$CONF")"
    mtime="$(stat -c %.9Y "$CONF")"
    for i in 1 2 3; do
        gen_ok
    done
    cmp "$CONF" "$D/operator.yml"
    [ "$(stat -c %a "$CONF")" = "640" ]
    [ "$(stat -c %i "$CONF")" = "$inode" ]
    [ "$(stat -c %.9Y "$CONF")" = "$mtime" ]
    [ "$(count_backups)" -eq 0 ]
    assert_no_leftovers
}

@test "an operator-owned file gets one warning per start that names --regenerate-config [D10]" {
    write_operator_file
    gen_ok
    gen_ok
    [ "$(grep -c "does not start with the line '# Managed by LyreBirdAudio'" "$D/sm.log")" -eq 2 ]
    grep -q "run 'lyrebird-stream-manager.sh --regenerate-config start' (a timestamped backup is saved first)" "$D/sm.log"
    # one warning, not two lines of it
    [ "$(grep -c 'regenerate-config' "$D/sm.log")" -eq 2 ]
}

# What an earlier release's generator wrote on every start (v1.5.1 and before; default ports:
# it ignored MEDIAMTX_*_PORT). The first line is the only thing the adoption looks at.
write_legacy_file() {
    cat >"$CONF" <<'YAML'
# MediaMTX Configuration - Audio Streams
logLevel: info
readTimeout: 30s
writeTimeout: 30s

api: yes
apiAddress: :9997

metrics: yes
metricsAddress: :9998

rtsp: yes
rtspAddress: :8554
rtspTransports: [tcp, udp]

rtmp: no
hls: no
webrtc: no
srt: no
moq: no

paths:
  '~^[a-zA-Z0-9_-]+$':
    source: publisher
    sourceProtocol: automatic
    sourceOnDemand: no
YAML
    cp -p "$CONF" "$D/legacy.yml"
}

@test "the file an earlier release generated is adopted on the first start: backed up, replaced by the current rendering, one INFO, managed from then on [X-38]" {
    write_legacy_file
    gen_ok
    # replaced by the current rendering: the marker first, the configured ports, the API and
    # the metrics on the loopback address (the legacy file had them on every interface)
    [ "$(head -n 1 "$CONF")" = "# Managed by LyreBirdAudio" ]
    grep -qxF 'apiAddress: 127.0.0.1:36001' "$CONF"
    grep -qxF 'metricsAddress: 127.0.0.1:36002' "$CONF"
    grep -qxF 'rtspAddress: :36000' "$CONF"
    ! grep -q 'Audio Streams' "$CONF"
    # the usual timestamped backup holds the old text, byte for byte
    [ "$(count_backups)" -eq 1 ]
    cmp "$(backups)" "$D/legacy.yml"
    # one INFO says so, and the file is not treated as the operator's
    [ "$(grep -c 'was written by an earlier release of lyrebird-stream-manager.sh' "$D/sm.log")" -eq 1 ]
    grep -F 'was written by an earlier release' "$D/sm.log" | grep -q '\[INFO\]'
    ! grep -q 'does not start with the line' "$D/sm.log"
    grep -q 'Saved the previous MediaMTX configuration as' "$D/sm.log"
    assert_no_leftovers

    # from then on it is an ordinary managed file: nothing is rewritten, no second backup, no second INFO
    local inode
    inode="$(stat -c %i "$CONF")"
    gen_ok
    [ "$(stat -c %i "$CONF")" = "$inode" ]
    [ "$(count_backups)" -eq 1 ]
    [ "$(grep -c 'was written by an earlier release' "$D/sm.log")" -eq 1 ]
    grep -q 'left untouched' "$D/sm.log"
}

@test "the earlier release's first line is adopted with a CRLF line ending or trailing blanks, and the file keeps its mode [X-38]" {
    local text
    for text in $'# MediaMTX Configuration - Audio Streams\r\nlogLevel: info\r\n' $'# MediaMTX Configuration - Audio Streams   \nlogLevel: info\n'; do
        rm -f "$CONF" "$CONF".*.bak
        printf '%s' "$text" >"$CONF"
        chmod 640 "$CONF"
        gen_ok
        [ "$(head -n 1 "$CONF")" = "# Managed by LyreBirdAudio" ]
        [ "$(stat -c %a "$CONF")" = "640" ]
        [ "$(count_backups)" -eq 1 ]
    done
}

@test "a file that only looks like the earlier release's is the operator's and is left alone: installer file, other first lines, the text on a later line [X-38]" {
    local name text mtime
    # What install_mediamtx.sh 2.0.1 (the revision the audit examined) wrote, as a literal. Since
    # 2.1.0 the installer writes the managed file (marker first), which the manager treats as its
    # own ('the stream manager takes the installer's file as its own', test_install_mediamtx.bats),
    # so only a copy of the earlier output can stand for a file that merely looks like the old one.
    cat >"$D/installer-style.yml" <<'OLDINSTALLER'
###############################################
# MediaMTX Configuration
# Generated by install_mediamtx.sh v2.0.1
# Date: 2026-11-01T00:00:00+00:00
###############################################

# Global settings
logLevel: info
logDestinations: [stdout]
logFile: /var/lib/mediamtx/mediamtx.log

# API Configuration
api: yes
apiAddress: :9997

# Metrics
metrics: yes
metricsAddress: :9998

# RTSP Server Configuration
rtsp: yes
rtspAddress: :8554
rtspEncryption: "no"
rtspTransports: [tcp, udp]

# RTMP Server (disabled by default)
rtmp: no
rtmpAddress: :1935

# HLS Server (disabled by default)
hls: no
hlsAddress: :8888

# WebRTC (disabled by default)
webrtc: no
webrtcAddress: :8889

# Paths configuration
pathDefaults:
  source: publisher
  sourceOnDemand: no

paths: {}
  # Define your paths here
OLDINSTALLER
    # the same, with the installer's heading as the first line (how it is described elsewhere), the
    # earlier text with something added, another case, and the earlier text only below a key
    printf '# MediaMTX Configuration\n# Generated by install_mediamtx.sh\nlogLevel: info\n' >"$D/heading-first.yml"
    printf '# MediaMTX Configuration - Audio Streams (edited)\nlogLevel: info\n' >"$D/suffix.yml"
    printf '# mediamtx configuration - audio streams\nlogLevel: info\n' >"$D/lowercase.yml"
    printf '\n# MediaMTX Configuration - Audio Streams\nlogLevel: info\n' >"$D/blank-first.yml"
    printf 'logLevel: info\n# MediaMTX Configuration - Audio Streams\n' >"$D/later-line.yml"
    printf '###\n# MediaMTX Configuration - Audio Streams\nlogLevel: info\n' >"$D/second-line.yml"
    for name in installer-style heading-first suffix lowercase blank-first later-line second-line; do
        rm -f "$CONF" "$CONF".*.bak
        cp -p "$D/$name.yml" "$CONF"
        touch -d '2001-02-03 04:05:06' "$CONF"
        mtime="$(stat -c %.9Y "$CONF")"
        : >"$D/sm.log"
        gen_ok
        cmp "$CONF" "$D/$name.yml" || {
            echo "rewritten: $name"
            false
        }
        [ "$(stat -c %.9Y "$CONF")" = "$mtime" ]
        [ "$(count_backups)" -eq 0 ] || {
            echo "backup made for: $name"
            false
        }
        grep -q "does not start with the line '# Managed by LyreBirdAudio'" "$D/sm.log" || {
            echo "no operator warning for: $name"
            false
        }
        ! grep -q 'earlier release' "$D/sm.log" || {
            echo "adopted: $name"
            false
        }
    done
}

@test "a rendering MediaMTX rejects never replaces the earlier release's file; once it is accepted the file is adopted [X-38]" {
    write_legacy_file
    STUB_VALIDATE=1 STUB_REJECT='Managed by LyreBirdAudio' gen
    # the stand-in validator rejects the new rendering: nothing was replaced, no backup, the legacy file stays
    [ "$GEN_RC" -ne 0 ]
    cmp "$CONF" "$D/legacy.yml"
    [ "$(count_backups)" -eq 0 ]
    # and once the rendering is accepted the file is adopted
    gen_ok
    [ "$(head -n 1 "$CONF")" = "# Managed by LyreBirdAudio" ]
    [ "$(count_backups)" -eq 1 ]
}

@test "RTSP_AUTH_MODE has no effect on an operator-owned file, and the log says so [D10]" {
    write_operator_file
    RTSP_AUTH_MODE=local-only-publish gen_ok
    cmp "$CONF" "$D/operator.yml"
    grep -q 'RTSP_AUTH_MODE=local-only-publish has no effect' "$D/sm.log"
}

@test "an operator-owned file that cannot be a MediaMTX configuration stops the start and is left alone [LB-22]" {
    local kind
    for kind in tab tab2 nul comment words; do
        case "$kind" in
            tab) printf 'logLevel: info\n\tapi: yes\n' >"$CONF" ;;
            tab2) printf 'rtsp: yes\n  \t- tab\n' >"$CONF" ;;
            nul) printf 'logLevel: info\n\0apiAddress: :1\n' >"$CONF" ;;
            comment) printf '# only a comment\n' >"$CONF" ;;
            words) printf 'just some words\n' >"$CONF" ;;
        esac
        cp -p "$CONF" "$D/operator.yml"
        : >"$D/sm.log"
        gen
        [ "$GEN_RC" -ne 0 ] || {
            echo "accepted: $kind"
            false
        }
        cmp "$CONF" "$D/operator.yml"
        grep -q 'ERROR' "$D/sm.log"
        case "$kind" in
            tab | tab2) grep -q 'indented with tabs' "$D/sm.log" ;;
            nul) grep -q 'contains NUL bytes' "$D/sm.log" ;;
            *) grep -q 'has no top-level key' "$D/sm.log" ;;
        esac
    done
    [ "$(count_backups)" -eq 0 ]
}

@test "where MediaMTX has --validate-conf, its verdict decides about an operator-owned file, and its message is logged [LB-22]" {
    write_operator_file
    printf 'bogusKey: 1\n' >>"$CONF"
    cp -p "$CONF" "$D/operator.yml"
    STUB_VALIDATE=1 STUB_REJECT=bogusKey gen
    [ "$GEN_RC" -ne 0 ]
    grep -q "MediaMTX rejects the configuration $CONF" "$D/sm.log"
    grep -q 'ERR: invalid path name: stub says no' "$D/sm.log"
    cmp "$CONF" "$D/operator.yml"
    # a valid file passes the same check
    write_operator_file
    STUB_VALIDATE=1 STUB_REJECT=bogusKey gen_ok
}

@test "--regenerate-config replaces an operator-owned file after saving it, keeping its mode; the next start leaves the new file alone [D10]" {
    write_operator_file
    run bash -c 'source "$1" >/dev/null 2>&1; set +e; parse_arguments --regenerate-config start; echo "command=$COMMAND regenerate=$REGENERATE_CONFIG"; generate_mediamtx_config >/dev/null 2>&1; echo "rc=$?"' _ "$SM"
    [[ "$output" == *"command=start regenerate=true"* ]]
    [[ "$output" == *"rc=0"* ]]
    [ "$(head -n 1 "$CONF")" = "# Managed by LyreBirdAudio" ]
    [ "$(stat -c %a "$CONF")" = "640" ]
    [ "$(count_backups)" -eq 1 ]
    cmp "$(backups)" "$D/operator.yml"
    [ "$(stat -c %a "$(backups)")" = "640" ]
    local inode
    inode="$(stat -c %i "$CONF")"
    gen_ok
    [ "$(stat -c %i "$CONF")" = "$inode" ]
    [ "$(count_backups)" -eq 1 ]
}

@test "--regenerate-config is in the usage text" {
    run bash "$SM" help
    [[ "$output" == *"--regenerate-config"* ]]
    [[ "$output" == *"MEDIAMTX_API_BIND"* && "$output" == *"RTSP_AUTH_MODE"* && "$output" == *"MEDIAMTX_CONFIG_BACKUPS"* ]]
}

# ---------------------------------------------------------------------------
# What is validated before a managed file is replaced
# ---------------------------------------------------------------------------

@test "a rendering MediaMTX rejects never replaces the managed file: no new content, no backup, no temp file [LB-22]" {
    gen_ok
    cp -p "$CONF" "$D/v0"
    STUB_VALIDATE=1 STUB_REJECT='Studio Mix' STREAM_MODE=multiplex MULTIPLEX_STREAM_NAME="Studio Mix" gen
    [ "$GEN_RC" -ne 0 ]
    cmp "$CONF" "$D/v0"
    [ "$(count_backups)" -eq 0 ]
    grep -q 'ERR: invalid path name: stub says no' "$D/sm.log"
    grep -q "Not writing $CONF" "$D/sm.log"
    assert_no_leftovers
}

@test "a rendering that fails leaves a managed file as it is, and creates none [LB-22]" {
    RTSP_AUTH_MODE=bogus gen
    [ "$GEN_RC" -ne 0 ]
    [ ! -e "$CONF" ]
    grep -q 'Cannot render the MediaMTX configuration' "$D/sm.log"
    gen_ok
    cp -p "$CONF" "$D/v0"
    RTSP_AUTH_MODE=bogus gen
    [ "$GEN_RC" -ne 0 ]
    cmp "$CONF" "$D/v0"
    assert_no_leftovers
}

@test "a backup that cannot be saved stops the replacement and the file stays as it was [LB-22]" {
    gen_ok
    cp -p "$CONF" "$D/v0"
    # mktemp refuses to create the temp file of a backup (names ending in .bak.XXXXXX)
    cat >"$D/bin/mktemp" <<'SHIM'
#!/bin/bash
[[ "$*" == *.bak.XXXXXX* ]] && exit 1
exec /usr/bin/mktemp "$@"
SHIM
    chmod +x "$D/bin/mktemp"
    MEDIAMTX_API_PORT=36005 gen
    [ "$GEN_RC" -ne 0 ]
    cmp "$CONF" "$D/v0"
    [ "$(count_backups)" -eq 0 ]
    grep -q "Cannot save a backup of $CONF: leaving it as it is" "$D/sm.log"
}

@test "two replacements in the same second never overwrite each other's backup [LB-22]" {
    # a clock that stands still
    printf '#!/bin/bash\nexec /bin/date "$@" -d "2030-01-02 03:04:05 UTC"\n' >"$D/bin/date"
    chmod +x "$D/bin/date"
    local i
    for i in 0 1 2 3; do
        MEDIAMTX_API_PORT=$((36100 + i)) gen_ok
    done
    [ "$(count_backups)" -eq 3 ]
    [ "$(api_port_in "$CONF.20300102T030405Z.00.bak")" = "36100" ]
    [ "$(api_port_in "$CONF.20300102T030405Z.01.bak")" = "36101" ]
    [ "$(api_port_in "$CONF.20300102T030405Z.02.bak")" = "36102" ]
}

@test "with the clock standing still the retention still removes the oldest backups, never the newest [LB-22]" {
    # Backup numbers freed by pruning must not be reused: a reused number sorts
    # before older backups and the newest backup would be the next one removed
    printf '#!/bin/bash\nexec /bin/date "$@" -d "2030-01-02 03:04:05 UTC"\n' >"$D/bin/date"
    chmod +x "$D/bin/date"
    local i
    for i in 0 1 2 3 4 5 6 7 8 9 10; do
        MEDIAMTX_API_PORT=$((36100 + i)) gen_ok
    done
    [ "$(count_backups)" -eq 5 ]
    local f ports=""
    while IFS= read -r f; do
        ports+="$(api_port_in "$f") "
    done < <(backups)
    [ "$ports" = "36105 36106 36107 36108 36109 " ] || {
        echo "backups hold: $ports"
        backups
        false
    }
}

# ---------------------------------------------------------------------------
# What is rendered from the manager's settings
# ---------------------------------------------------------------------------

@test "the API and metrics listen on the loopback address by default; MEDIAMTX_API_BIND and MEDIAMTX_METRICS_BIND change that [D9, LB-06]" {
    gen_ok
    grep -qx 'apiAddress: 127.0.0.1:36001' "$CONF"
    grep -qx 'metricsAddress: 127.0.0.1:36002' "$CONF"
    grep -qx 'rtspAddress: :36000' "$CONF"
    MEDIAMTX_API_BIND= MEDIAMTX_METRICS_BIND=192.0.2.5 gen_ok
    grep -qx 'apiAddress: :36001' "$CONF"
    grep -qx 'metricsAddress: 192.0.2.5:36002' "$CONF"
    MEDIAMTX_API_BIND=::1 gen_ok
    grep -qx 'apiAddress: \[::1\]:36001' "$CONF"
}

@test "an invalid MEDIAMTX_API_BIND stops the start with a message, and the file stays [D9]" {
    gen_ok
    cp -p "$CONF" "$D/v0"
    MEDIAMTX_API_BIND=not-an-address gen
    [ "$GEN_RC" -ne 0 ]
    grep -q -- '--api-bind must be empty or an IPv4/IPv6 address' "$D/sm.log"
    cmp "$CONF" "$D/v0"
}

@test "multiplex mode renders one quoted path; a stream name that is not a plain scalar cannot inject YAML [LB-04, LB-22]" {
    STREAM_MODE=multiplex MULTIPLEX_STREAM_NAME="it's" gen_ok
    grep -qx "  'it''s':" "$CONF"
    [ "$(grep -c '^  [^ ].*:$' "$CONF")" -eq 1 ]
    cp -p "$CONF" "$D/v0"
    local name
    for name in $'a\nrunOnInit: touch /tmp/pwned' $'x\'\n  other: 1' $'tab\there'; do
        STREAM_MODE=multiplex MULTIPLEX_STREAM_NAME="$name" gen
        [ "$GEN_RC" -ne 0 ]
        cmp "$CONF" "$D/v0"
    done
    ! grep -rq runOnInit "$CFG"
}

@test "individual mode renders the catch-all path, moq follows the binary's version [LB-22]" {
    gen_ok
    grep -Fx "  '~^[a-zA-Z0-9_-]+\$':" "$CONF"
    grep -qx 'moq: no' "$CONF"
    STUB_VERSION=v1.18.2 gen_ok
    ! grep -q moq "$CONF"
    rm -f "$D/bin/mediamtx"
    gen_ok
    ! grep -q moq "$CONF"
}

# ---------------------------------------------------------------------------
# RTSP_AUTH_MODE=local-only-publish through the manager
# ---------------------------------------------------------------------------

make_users_file() {
    printf '%s:sha256:%s\n' alice "$(printf '%s' 'alice pw' | openssl dgst -sha256 -binary | base64)" >"$D/users.conf"
}

@test "local-only-publish renders the hardened pattern with the users of RTSP_USERS_FILE, and the file loses world access [LB-06]" {
    make_users_file
    export RTSP_AUTH_MODE=local-only-publish RTSP_USERS_FILE="$D/users.conf"
    gen_ok
    grep -qx 'authMethod: internal' "$CONF"
    grep -q "^  - user: any\$" "$CONF"
    grep -q "^  - user: 'alice'\$" "$CONF"
    grep -q "pass: 'sha256:" "$CONF"
    [ "$(stat -c %a "$CONF")" = "640" ]
}

@test "the default users file is rtsp-users.conf in the MediaMTX configuration directory [LB-06]" {
    make_users_file
    cp "$D/users.conf" "$CFG/rtsp-users.conf"
    RTSP_AUTH_MODE=local-only-publish gen_ok
    grep -q "^  - user: 'alice'\$" "$CONF"
}

@test "a file that now carries password hashes loses world access and group write; other modes are kept; hash-free renderings keep any mode [LB-06]" {
    make_users_file
    gen_ok
    # open -> authenticated, from 0644
    RTSP_AUTH_MODE=local-only-publish RTSP_USERS_FILE="$D/users.conf" gen_ok
    [ "$(stat -c %a "$CONF")" = "640" ]
    chmod 664 "$CONF"
    MEDIAMTX_API_PORT=36005 RTSP_AUTH_MODE=local-only-publish RTSP_USERS_FILE="$D/users.conf" gen_ok
    [ "$(stat -c %a "$CONF")" = "640" ]
    chmod 600 "$CONF"
    MEDIAMTX_API_PORT=36006 RTSP_AUTH_MODE=local-only-publish RTSP_USERS_FILE="$D/users.conf" gen_ok
    [ "$(stat -c %a "$CONF")" = "600" ]
    # no users: nothing secret in the file, the mode is the operator's
    rm -f "$CONF"
    gen_ok
    chmod 664 "$CONF"
    RTSP_AUTH_MODE=local-only-publish RTSP_USERS_FILE="$D/none.conf" gen_ok
    [ "$(stat -c %a "$CONF")" = "664" ]
}

@test "a missing users file is a warning, and only this machine may use RTSP [LB-06]" {
    RTSP_AUTH_MODE=local-only-publish RTSP_USERS_FILE="$D/none.conf" gen_ok
    grep -q "does not exist: only this machine can use RTSP" "$D/sm.log"
    [ "$(grep -c '^  - user:' "$CONF")" -eq 1 ]
}

@test "a users file with a plaintext password stops the start and nothing is written [LB-06]" {
    printf 'alice:hunter2\n' >"$D/users.conf"
    RTSP_AUTH_MODE=local-only-publish RTSP_USERS_FILE="$D/users.conf" gen
    [ "$GEN_RC" -ne 0 ]
    [ ! -e "$CONF" ]
    grep -q 'plaintext passwords are refused' "$D/sm.log"
    ! grep -q hunter2 "$D/sm.log"
}

@test "publishers that do not connect through a loopback name are warned about under local-only-publish [LB-06]" {
    make_users_file
    RTSP_AUTH_MODE=local-only-publish RTSP_USERS_FILE="$D/users.conf" MEDIAMTX_HOST=192.0.2.7 gen_ok
    grep -q 'publishers connect to 192.0.2.7, which is not a loopback name' "$D/sm.log"
    RTSP_AUTH_MODE=local-only-publish RTSP_USERS_FILE="$D/users.conf" MEDIAMTX_HOST=127.0.0.1 gen_ok
    [ "$(grep -c 'not a loopback name' "$D/sm.log")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# start_mediamtx
# ---------------------------------------------------------------------------

# Run the real start_mediamtx with only the hardware stood in for. $1 is shell
# code run after the stand-ins.
start_with_stub() {
    export EXTRA_SEAMS="${1:-}" STUB_STARTED="$D/mediamtx.started"
    rm -f "$STUB_STARTED"
    # A launch needs a process the manager recognises as its MediaMTX (a copy of bash
    # at the binary path); the validation emulation (STUB_VALIDATE=1) is the script
    # stub, whose tests expect the start to stop before launching anything
    local binary="$D/bin/mediamtx" prelude=""
    if [[ "${STUB_VALIDATE:-}" != 1 ]]; then
        make_launchable_mediamtx "$D/bin/mediamtx_proc" "$D"
        binary="$STUB_MEDIAMTX_BINARY" prelude="$STUB_PRELUDE"
    fi
    MEDIAMTX_BINARY="$binary" BASH_ENV="$prelude" MEDIAMTX_API_TIMEOUT=2 LYREBIRD_FLOW_SAMPLE_SECONDS=0 run bash -c '
        source "$1" >/dev/null 2>&1
        set +e
        detect_audio_devices() { echo "testmic:1"; }
        wait_for_usb_stabilization() { return 0; }
        wait_for_mediamtx_ready() { return 0; }
        start_all_ffmpeg_streams() { :; }
        validate_stream() { return 0; }
        device_node_exists() { return 0; }
        mediamtx_path_info() { printf "{\"ready\":true,\"bytesReceived\":1}"; }
        eval "$EXTRA_SEAMS"
        start_mediamtx' _ "$SM"
    local i
    for ((i = 0; i < 30; i++)); do
        [[ -s "$STUB_STARTED" ]] && break
        sleep 0.1
    done
    return 0
}

@test "start_mediamtx checks the ports before it renders anything: a taken port leaves the configuration as it was [LB-22]" {
    gen_ok
    cp -p "$CONF" "$D/v0"
    # `ss` says the API port of the NEW settings is taken
    cat >"$D/bin/ss" <<'SHIM'
#!/bin/bash
printf 'Netid State  Recv-Q Send-Q Local Address:Port Peer Address:Port\n'
printf 'tcp   LISTEN 0      4096         0.0.0.0:%s        0.0.0.0:*\n' "$SS_PORT"
SHIM
    chmod +x "$D/bin/ss"
    export SS_PORT=36005
    MEDIAMTX_API_PORT=36005 start_with_stub 'command_exists() { [[ "$1" == lsof ]] && return 1; command -v "$1" >/dev/null 2>&1; }'
    [ "$status" -ne 0 ]
    grep -q 'Port 36005 appears to be in use' "$D/sm.log"
    [ ! -e "$D/mediamtx.started" ]
    cmp "$CONF" "$D/v0"
    [ "$(count_backups)" -eq 0 ]
}

@test "start_mediamtx writes the configuration, then launches MediaMTX on that file [LB-22]" {
    command -v lsof >/dev/null || command -v ss >/dev/null || skip "neither lsof nor ss is installed"
    start_with_stub
    [ "$status" -eq 0 ]
    HELD_PIDS+=("$(<"$MEDIAMTX_PID_FILE")")
    [ "$(head -n 1 "$CONF")" = "# Managed by LyreBirdAudio" ]
    [ "$(head -n 1 "$D/mediamtx.started")" = "$CONF" ]
}

@test "start_mediamtx launches MediaMTX on an operator-owned file without touching it [LB-22]" {
    command -v lsof >/dev/null || command -v ss >/dev/null || skip "neither lsof nor ss is installed"
    write_operator_file
    start_with_stub
    [ "$status" -eq 0 ]
    HELD_PIDS+=("$(<"$MEDIAMTX_PID_FILE")")
    cmp "$CONF" "$D/operator.yml"
    [ "$(head -n 1 "$D/mediamtx.started")" = "$CONF" ]
}

@test "start_mediamtx refuses to start on an operator-owned file MediaMTX rejects, and launches nothing [LB-22]" {
    command -v lsof >/dev/null || command -v ss >/dev/null || skip "neither lsof nor ss is installed"
    write_operator_file
    printf 'bogusKey: 1\n' >>"$CONF"
    cp -p "$CONF" "$D/operator.yml"
    STUB_VALIDATE=1 STUB_REJECT=bogusKey start_with_stub
    [ "$status" -ne 0 ]
    [ ! -e "$D/mediamtx.started" ]
    cmp "$CONF" "$D/operator.yml"
}

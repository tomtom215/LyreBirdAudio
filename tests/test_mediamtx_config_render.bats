#!/usr/bin/env bats
# lyrebird_render_mediamtx_config: the one MediaMTX configuration renderer that
# the stream manager and, later, the installer share (register: LB-06, LB-22;
# decisions D9, D10).
#
# These tests call the real function and read what it prints. That every
# configuration it can print is accepted by real MediaMTX binaries, and what
# those servers then do, is checked in test_mediamtx_config_live.bats.

load scratch_tmpdir

setup() {
    scratch_setup
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    COMMON="$PROJECT_ROOT/lyrebird-common.sh"
    # shellcheck source=../lyrebird-common.sh
    source "$COMMON"
}

teardown() {
    scratch_teardown
}

# render ARGS...: print the configuration for those options
render() {
    lyrebird_render_mediamtx_config "$@"
}

# The value of top-level key $1 in the rendered text on stdin
top_value() {
    sed -n "s/^$1: //p" | head -n 1
}

# A users-file line for the password $2 of user $1
user_line() {
    printf '%s:sha256:%s\n' "$1" "$(printf '%s' "$2" | openssl dgst -sha256 -binary | base64)"
}

# ---------------------------------------------------------------------------
# What the default configuration says
# ---------------------------------------------------------------------------

@test "the first line is the managed marker, with nothing before it [D10]" {
    run render
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "# Managed by LyreBirdAudio" ]
    [ "${lines[0]}" = "$LYREBIRD_MEDIAMTX_CONFIG_MARKER" ]
}

@test "the default configuration listens as decided in D9: API and metrics on loopback, RTSP on every interface" {
    run render
    [ "$status" -eq 0 ]
    [ "$(top_value apiAddress <<<"$output")" = "127.0.0.1:9997" ]
    [ "$(top_value metricsAddress <<<"$output")" = "127.0.0.1:9998" ]
    [ "$(top_value rtspAddress <<<"$output")" = ":8554" ]
    [ "$(top_value api <<<"$output")" = "yes" ]
    [ "$(top_value metrics <<<"$output")" = "yes" ]
    [ "$(top_value rtsp <<<"$output")" = "yes" ]
}

@test "RTMP, HLS, WebRTC and SRT are switched off, and so is every key that has no switch-on option [D9]" {
    run render
    [ "$status" -eq 0 ]
    [ "$(top_value rtmp <<<"$output")" = "no" ]
    [ "$(top_value hls <<<"$output")" = "no" ]
    [ "$(top_value webrtc <<<"$output")" = "no" ]
    [ "$(top_value srt <<<"$output")" = "no" ]
    # no option of the renderer can turn one on
    run render --rtmp yes
    [ "$status" -eq 1 ]
    run render --srt yes
    [ "$status" -eq 1 ]
}

@test "individual mode: one catch-all path that takes any publisher, as before" {
    run render
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\npaths:\n  \'~^[a-zA-Z0-9_-]+$\':\n    source: publisher\n    sourceProtocol: automatic\n    sourceOnDemand: no' ]]
}

@test "multiplex mode: exactly one path, named as asked and quoted" {
    run render --stream-name studio
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\npaths:\n  \'studio\':\n    source: publisher\n    sourceProtocol: automatic\n    sourceOnDemand: no' ]]
    [[ "$output" != *"~^"* ]]
}

@test "the output ends with a newline and has no partial text when it fails" {
    render >"$TEST_SCRATCH/out"
    [ "$(tail -c 1 "$TEST_SCRATCH/out" | od -An -tx1 | tr -d ' ')" = "0a" ]
    local out
    out="$(render --api-port nonsense 2>/dev/null)" || true
    [ -z "$out" ]
    printf '%s:sha256:%s\n' alice "not a hash" >"$TEST_SCRATCH/users"
    out="$(render --auth-mode local-only-publish --users-file "$TEST_SCRATCH/users" 2>/dev/null)" || true
    [ -z "$out" ]
}

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

@test "ports, bind addresses, switches, log level and timeouts are rendered as given" {
    run render --rtsp-port 36000 --api-port 36001 --metrics-port 36002 \
        --rtsp-bind 10.1.2.3 --api-bind 192.0.2.7 --metrics-bind "" \
        --api no --metrics no --log-level debug --read-timeout 45s --write-timeout 2m
    [ "$status" -eq 0 ]
    [ "$(top_value rtspAddress <<<"$output")" = "10.1.2.3:36000" ]
    [ "$(top_value apiAddress <<<"$output")" = "192.0.2.7:36001" ]
    [ "$(top_value metricsAddress <<<"$output")" = ":36002" ]
    [ "$(top_value api <<<"$output")" = "no" ]
    [ "$(top_value metrics <<<"$output")" = "no" ]
    [ "$(top_value logLevel <<<"$output")" = "debug" ]
    [ "$(top_value readTimeout <<<"$output")" = "45s" ]
    [ "$(top_value writeTimeout <<<"$output")" = "2m" ]
}

@test "an IPv6 bind address is written in brackets" {
    run render --api-bind ::1 --metrics-bind fe80::1 --rtsp-bind 2001:db8::5
    [ "$status" -eq 0 ]
    [ "$(top_value apiAddress <<<"$output")" = "[::1]:9997" ]
    [ "$(top_value metricsAddress <<<"$output")" = "[fe80::1]:9998" ]
    [ "$(top_value rtspAddress <<<"$output")" = "[2001:db8::5]:8554" ]
}

@test "ports with leading zeros are written as plain decimals" {
    run render --rtsp-port 08554 --api-port 09997 --metrics-port 9998
    [ "$status" -eq 0 ]
    [ "$(top_value rtspAddress <<<"$output")" = ":8554" ]
    [ "$(top_value apiAddress <<<"$output")" = "127.0.0.1:9997" ]
}

@test "moq: no is written for MediaMTX 1.19.0 and later, left out before it and when the version is unknown [LB-06]" {
    local v
    for v in v1.19.0 1.19.0 v1.21.3 v1.100.0 v2.0.0 "v1.19.0-rc1"; do
        run render --mediamtx-version "$v"
        [ "$status" -eq 0 ]
        [ "$(top_value moq <<<"$output")" = "no" ] || { echo "missing for $v"; false; }
    done
    for v in v1.15.0 v1.18.2 v1.9.9 v0.23.8 "" garbage "MediaMTX v1.21.1"; do
        run render --mediamtx-version "$v"
        [ "$status" -eq 0 ]
        [[ "$output" != *moq* ]] || { echo "present for '$v'"; false; }
    done
    run render
    [[ "$output" != *moq* ]]
}

@test "paths: stays the last top-level key, after moq" {
    run render --mediamtx-version v1.21.1
    [[ "$output" == *$'moq: no\n\npaths:\n  '* ]]
    printf '%s\n' "$output" | python3 -I -c '
import sys
top = [l.split(":")[0] for l in sys.stdin.read().splitlines() if l and not l.startswith((" ", "#"))]
assert top[-1] == "paths", top
assert top.count("moq") == 1, top
'
}

# ---------------------------------------------------------------------------
# Refusals
# ---------------------------------------------------------------------------

@test "invalid values are refused, nothing is printed and the message names the option [D15]" {
    local row err
    local -a args
    # one case per line, the words to pass ("EMPTY" stands for an empty word)
    while IFS= read -r row; do
        read -ra args <<<"${row//EMPTY/}"
        [[ "$row" == *EMPTY* ]] && args=("${row%% *}" "")
        err="$(render "${args[@]}" 2>&1 >"$TEST_SCRATCH/out")" && {
            echo "accepted: $row"
            false
        }
        [ ! -s "$TEST_SCRATCH/out" ] || {
            echo "printed something for: $row"
            false
        }
        [[ "$err" == *"lyrebird_render_mediamtx_config"* ]] || {
            echo "no message for: $row ($err)"
            false
        }
    done <<'TABLE'
--rtsp-port 0
--rtsp-port 65536
--rtsp-port abc
--api-port -1
--api-port 80.5
--api-port 0x50
--metrics-port EMPTY
--api-bind not-an-address
--api-bind 256.1.1.1
--api-bind 1.2.3
--metrics-bind localhost
--rtsp-bind [::1]
--api maybe
--metrics true
--log-level verbose
--read-timeout 30
--write-timeout 1d
--read-timeout -5s
--auth-mode secret
--users-file /nonexistent
--bogus 1
--api-port
TABLE
}

@test "the RTSP, API and metrics ports must be three different ports" {
    run render --rtsp-port 9000 --api-port 9000
    [ "$status" -eq 1 ]
    [[ "$output" == *"must differ"* ]]
    run render --api-port 9100 --metrics-port 9100
    [ "$status" -eq 1 ]
    run render --rtsp-port 9998
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# The stream name is data, not YAML
# ---------------------------------------------------------------------------

# Parse the configuration with a real YAML parser and print the path keys, one
# per line, each as its JSON-escaped string
path_keys() {
    python3 -I -c '
import json, sys, yaml
doc = yaml.safe_load(sys.stdin.read())
for key in doc["paths"]:
    print(json.dumps(key))
'
}

@test "any printable stream name comes back from a YAML parser as exactly that one path name [LB-04]" {
    python3 -I -c 'import yaml' 2>/dev/null || skip "PyYAML is not installed"
    local name keys
    for name in "studio" "all_mics" "it's" "'" "''" "a: b" "# not a comment" "- item" "{a: 1}" "[1, 2]" '"quoted"' 'back\slash' \
        "*alias" "&anchor" "!tag" "%directive" "@at" '`tick`' " leading" "trailing " "~regex" "null" "yes" "0x10" "1e3" "a,b" "a|b" \
        "a>b" "?" "key: 'v'" "x'; runOnInit: touch /tmp/pwned; '" "paths:" "---" "..." "=" "<<" "a#b" " # " "ab:cd" "a/b.c-d_e"; do
        run render --stream-name "$name"
        [ "$status" -eq 0 ] || { echo "rejected: [$name]"; false; }
        keys="$(path_keys <<<"$output")"
        [ "$keys" = "$(python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$name")" ] || {
            echo "name [$name] parsed as: $keys"
            false
        }
    done
}

@test "a stream name with a control character, a line break or a non-ASCII byte is refused, so it cannot inject YAML [LB-04]" {
    local name
    for name in $'a\nb' $'a\rb' $'a\tb' $'a\x01b' $'a\x1bb' $'a\x7fb' $'studio\n' $'x\nrunOnInit: touch /tmp/pwned' \
        $'x\'\nrunOnInit: touch /tmp/pwned\n\'' $'\xc3\xa9' $'a\xe2\x80\xa8b' $'a\xc2\x85b' $'a\xc3\x28b'; do
        run render --stream-name "$name"
        [ "$status" -eq 1 ] || { echo "accepted: $(printf '%q' "$name")"; false; }
        [[ "$output" == *"--stream-name contains a control character or a non-ASCII byte"* ]]
        [[ "$output" != *"runOnInit"* ]]
    done
}

@test "lyrebird_yaml_quote doubles quotes and refuses what is not printable ASCII" {
    run lyrebird_yaml_quote "it's"
    [ "$status" -eq 0 ]
    [ "$output" = "'it''s'" ]
    run lyrebird_yaml_quote ""
    [ "$output" = "''" ]
    run lyrebird_yaml_quote $'a\nb'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    # the check does not depend on the caller's locale
    run env LC_ALL=C.UTF-8 bash -c 'source "$1"; lyrebird_yaml_quote "$(printf "caf\xc3\xa9")"' _ "$COMMON"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Small validators the renderer is built from (the installer will reuse them)
# ---------------------------------------------------------------------------

@test "lyrebird_is_valid_port accepts 1-65535 and nothing else" {
    local v
    for v in 1 80 8554 65535 00080 "0001"; do lyrebird_is_valid_port "$v"; done
    for v in 0 00 65536 100000 -1 +1 1.5 abc "" " 1" "1 " 0x10 1e3; do
        ! lyrebird_is_valid_port "$v" || { echo "accepted [$v]"; false; }
    done
    ! lyrebird_is_valid_port
}

@test "lyrebird_is_valid_bind_address accepts empty, IPv4 and IPv6 literals" {
    local v
    for v in "" 0.0.0.0 127.0.0.1 255.255.255.255 192.168.1.10 ::1 :: fe80::1 2001:db8:0:0:0:0:0:1 ::ffff:1; do
        lyrebird_is_valid_bind_address "$v" || { echo "rejected [$v]"; false; }
    done
    for v in 256.0.0.1 1.2.3 1.2.3.4.5 a.b.c.d localhost "[::1]" 1:2 gggg::1 "127.0.0.1:9997" " 1.2.3.4" $'1.2.3.4\nx'; do
        ! lyrebird_is_valid_bind_address "$v" || { echo "accepted [$v]"; false; }
    done
}

@test "lyrebird_mediamtx_version_parts reads the first line of mediamtx --version" {
    run lyrebird_mediamtx_version_parts v1.21.1
    [ "$output" = "1 21 1" ]
    run lyrebird_mediamtx_version_parts 1.8.10-rc1
    [ "$output" = "1 8 10" ]
    run lyrebird_mediamtx_version_parts v01.019.003
    [ "$output" = "1 19 3" ]
    run lyrebird_mediamtx_version_parts "MediaMTX v1.21.1"
    [ "$status" -eq 1 ]
    run lyrebird_mediamtx_version_parts ""
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# --auth-mode local-only-publish (the users file)
# ---------------------------------------------------------------------------

@test "open mode writes no authentication keys at all" {
    run render
    [ "$status" -eq 0 ]
    [[ "$output" != *auth* && "$output" != *"user:"* && "$output" != *sha256* ]]
}

@test "local-only-publish: the loopback 'any' user may do everything, and nothing else is granted without a users file [LB-06]" {
    run render --auth-mode local-only-publish
    [ "$status" -eq 0 ]
    [ "$(top_value authMethod <<<"$output")" = "internal" ]
    [[ "$output" == *$'authInternalUsers:\n'* ]]
    [[ "$output" == *$'  - user: any\n    pass:\n    ips: [\'127.0.0.1\', \'::1\']\n    permissions:\n      - action: publish\n      - action: read\n      - action: playback\n      - action: api\n      - action: metrics\n      - action: pprof\n'* ]]
    # exactly one user
    [ "$(grep -c '^  - user:' <<<"$output")" -eq 1 ]
    [[ "$output" == *$'\n\npaths:\n'* ]]
}

@test "local-only-publish: each users-file line becomes a read-only remote user with a hashed password [LB-06]" {
    {
        echo "# remote listeners"
        user_line alice 'correct horse'
        echo
        printf '%s\r\n' "$(user_line bob.smith@example 'battery staple')"
        # indented, and the last line has no line ending at all
        printf '   %s' "$(user_line carol 'x')"
    } >"$TEST_SCRATCH/users"
    run render --auth-mode local-only-publish --users-file "$TEST_SCRATCH/users"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^  - user:' <<<"$output")" -eq 4 ]
    [[ "$output" == *$'  - user: \'alice\'\n    pass: \'sha256:'* ]]
    [[ "$output" == *"  - user: 'bob.smith@example'"* ]]
    [[ "$output" == *"  - user: 'carol'"* ]]
    # their permissions: read and playback only
    python3 -I -c 'import yaml' 2>/dev/null || return 0
    printf '%s\n' "$output" | python3 -I -c '
import sys, yaml
doc = yaml.safe_load(sys.stdin.read())
users = {u["user"]: u for u in doc["authInternalUsers"]}
assert set(users) == {"any", "alice", "bob.smith@example", "carol"}, users
for name in ("alice", "bob.smith@example", "carol"):
    perms = [p["action"] for p in users[name]["permissions"]]
    assert perms == ["read", "playback"], (name, perms)
    assert users[name]["pass"].startswith("sha256:") and "ips" not in users[name]
assert users["any"]["ips"] == ["127.0.0.1", "::1"] and users["any"]["pass"] is None
'
}

@test "local-only-publish: a plaintext password, a bad hash and a malformed line are refused without echoing the line [LB-06]" {
    local line
    for line in "alice:hunter2" "alice:sha256:hunter2" "alice:sha256:" "alice:sha256:AAAA" \
        "alice:SHA256:MMlS+rEiw/l1nwKm2Vw3WLJGtP7iOZV7LU/uRuJhcMQ=" "alice sha256:MMlS+rEiw/l1nwKm2Vw3WLJGtP7iOZV7LU/uRuJhcMQ=" \
        ":sha256:MMlS+rEiw/l1nwKm2Vw3WLJGtP7iOZV7LU/uRuJhcMQ=" "al'ice:sha256:MMlS+rEiw/l1nwKm2Vw3WLJGtP7iOZV7LU/uRuJhcMQ=" \
        "alice:sha256:MMlS+rEiw/l1nwKm2Vw3WLJGtP7iOZV7LU/uRuJhcMQ==" "alice:sha256:MMlS+rEiw/l1nwKm2Vw3WLJGtP7iOZV7LU/uRuJhcMQ=:extra"; do
        printf '%s\n' "$line" >"$TEST_SCRATCH/users"
        run render --auth-mode local-only-publish --users-file "$TEST_SCRATCH/users"
        [ "$status" -eq 1 ] || { echo "accepted: $line"; false; }
        [[ "$output" == *"line 1 is not \"user:sha256:<base64 of the SHA-256 digest>\""* ]]
        [[ "$output" != *"hunter2"* ]]
    done
}

@test "local-only-publish: the user name 'any' is reserved, a duplicate is refused, an unreadable file is refused [LB-06]" {
    user_line any pw >"$TEST_SCRATCH/users"
    run render --auth-mode local-only-publish --users-file "$TEST_SCRATCH/users"
    [ "$status" -eq 1 ]
    [[ "$output" == *'"any" is reserved'* ]]
    { user_line alice a; user_line alice b; } >"$TEST_SCRATCH/users"
    run render --auth-mode local-only-publish --users-file "$TEST_SCRATCH/users"
    [ "$status" -eq 1 ]
    [[ "$output" == *'user "alice" is listed twice'* ]]
    run render --auth-mode local-only-publish --users-file "$TEST_SCRATCH"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a readable file"* ]]
}

@test "--users-file without --auth-mode local-only-publish is an error, not silently ignored" {
    user_line alice a >"$TEST_SCRATCH/users"
    run render --users-file "$TEST_SCRATCH/users"
    [ "$status" -eq 1 ]
    run render --auth-mode open --users-file "$TEST_SCRATCH/users"
    [ "$status" -eq 1 ]
}

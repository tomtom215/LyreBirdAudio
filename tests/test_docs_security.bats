#!/usr/bin/env bats
# Guard tests for the security documents: docs/SECURITY-GUIDE.md, docs/security.html
# ([DOC-01]) and SECURITY.md ([DOC-04]).
#
# Each test pins a claim the documents make to the code, the scripts' own --help
# text, the CI workflow or the git tags, or pins a wrong statement the documents
# used to make to its absence, so neither can come back unnoticed. The claims were
# established by running real MediaMTX binaries, the real stream manager, installer
# and renderer, and real clients (see the "What this guide was checked against"
# paragraph of the guide). Tests that need a MediaMTX binary use
# LYREBIRD_TEST_MEDIAMTX_BINS like the live tests and run without one otherwise.

load scratch_tmpdir

setup() {
    scratch_setup
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    GUIDE="$ROOT/docs/SECURITY-GUIDE.md"
    HTML="$ROOT/docs/security.html"
    POLICY="$ROOT/SECURITY.md"
    export MEDIAMTX_LOG_FILE="$TEST_SCRATCH/mediamtx.out" STREAM_MANAGER_LOG_FILE="$TEST_SCRATCH/sm.log"
    export MEDIAMTX_CONFIG_DIR="$TEST_SCRATCH/cfg" MEDIAMTX_FFMPEG_DIR="$TEST_SCRATCH/ff"
    export MEDIAMTX_PID_FILE="$TEST_SCRATCH/mtx.pid" MEDIAMTX_LOCK_FILE="$TEST_SCRATCH/run.lock"
}

teardown() {
    [[ -n "${TEST_SCRATCH:-}" ]] && scratch_teardown
    return 0
}

# fenced_block FILE TOKEN: the first fenced code block of Markdown FILE that contains TOKEN
fenced_block() {
    awk -v tok="$2" '
        /^[[:space:]]*```/ {
            if (inb) { if (index(buf, tok)) { printf "%s", buf; exit } inb = 0; buf = "" } else { inb = 1; buf = "" }
            next
        }
        inb { buf = buf $0 "\n" }
    ' "$1"
}

# html_block FILE TOKEN: the first <pre><code> block of HTML FILE that contains TOKEN, unescaped
html_block() {
    python3 -I - "$1" "$2" <<'PY'
import html, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
for m in re.finditer(r"<pre><code>(.*?)</code></pre>", text, re.S):
    body = html.unescape(m.group(1))
    if sys.argv[2] in body:
        sys.stdout.write(body.rstrip("\n") + "\n")
        break
PY
}

# no_match GREP-ARGS...: succeeds only when grep finds nothing. (A bare `! grep -q ...` never fails a
# bats test: bash exempts a negated command from errexit.)
no_match() {
    if grep -q "$@"; then
        echo "found text that must not be there: grep $*"
        grep -n "$@" | head -n 3
        return 1
    fi
    return 0
}

# squeeze: drop indentation and blank lines, so a block quoted in a list item equals the same block elsewhere
squeeze() {
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$'
}

# ---------------------------------------------------------------------------
# [DOC-01] the guide and security.html
# ---------------------------------------------------------------------------

@test "the guide and security.html give the API and metrics the loopback address the generator really renders, and no longer say they listen on every interface [DOC-01]" {
    run bash -c 'source "$1/lyrebird-common.sh"; lyrebird_render_mediamtx_config' _ "$ROOT"
    [ "$status" -eq 0 ]
    local line
    for line in 'apiAddress: 127.0.0.1:9997' 'metricsAddress: 127.0.0.1:9998' 'rtspAddress: :8554' 'srt: no' 'rtmp: no' 'hls: no' 'webrtc: no'; do
        grep -qxF "$line" <<<"$output" || {
            echo "the generator does not render: $line"
            return 1
        }
    done
    grep -qF '`127.0.0.1`, TCP 9997' "$GUIDE"
    grep -qF '`127.0.0.1`, TCP 9998' "$GUIDE"
    grep -qF '<code>127.0.0.1</code>, TCP 9997' "$HTML"
    grep -qF '<code>127.0.0.1</code>, TCP 9998' "$HTML"
    no_match -F 'accepts connections on all interfaces' "$GUIDE"
    no_match -F '<td>Localhost only</td>' "$HTML"
    no_match -E 'WebRTC.*Open \(no auth\)' "$HTML"
}

@test "the marker line the guides name is the one the code writes, and the ways to keep, hand back and replace a file are in the guides and in the --help texts [DOC-01]" {
    local marker
    marker="$(bash -c 'source "$1/lyrebird-common.sh"; printf %s "$LYREBIRD_MEDIAMTX_CONFIG_MARKER"' _ "$ROOT")"
    [ "$marker" = "# Managed by LyreBirdAudio" ]
    grep -qF "$marker" "$GUIDE"
    grep -qF "$marker" "$HTML"
    grep -qF -- '--regenerate-config' "$GUIDE"
    grep -qF -- '--regenerate-config' "$HTML"
    grep -qF -- '--force' "$GUIDE"
    grep -qF -- '--force' "$HTML"
    grep -qF 'mediamtx.yml.<UTC time>.<nn>.bak' "$GUIDE"
    grep -qF 'mediamtx.yml.backup.<date>-<time>' "$GUIDE"
    # the file names the guide shows are the ones the scripts write
    grep -qF "'%s.%s.%02d.bak'" "$ROOT/lyrebird-stream-manager.sh"
    grep -qF 'mediamtx.yml.backup.' "$ROOT/install_mediamtx.sh" || grep -qF '.backup.$(date' "$ROOT/install_mediamtx.sh"
    run bash "$ROOT/lyrebird-stream-manager.sh" help
    grep -qF -- '--regenerate-config' <<<"$output"
    run bash "$ROOT/install_mediamtx.sh" --help
    grep -qF -- '--force' <<<"$output"
}

@test "every stream manager variable the guides name is in the manager's --help, with the same default [DOC-01]" {
    run bash "$ROOT/lyrebird-stream-manager.sh" help
    [ "$status" -eq 0 ]
    local help="$output" var
    for var in RTSP_AUTH_MODE RTSP_USERS_FILE MEDIAMTX_API_BIND MEDIAMTX_METRICS_BIND MEDIAMTX_CONFIG_BACKUPS; do
        grep -qF "$var" <<<"$help" || {
            echo "$var is not in the manager's help"
            return 1
        }
        grep -qF "$var" "$GUIDE" || {
            echo "$var is not in the guide"
            return 1
        }
    done
    for var in RTSP_AUTH_MODE RTSP_USERS_FILE MEDIAMTX_API_BIND MEDIAMTX_METRICS_BIND; do
        grep -qF "$var" "$HTML" || {
            echo "$var is not in security.html"
            return 1
        }
    done
    # the default is derived from MEDIAMTX_CONFIG_DIR (the test points it at a scratch directory)
    grep -qF 'rtsp-users.conf' <<<"$help"
    run env -u MEDIAMTX_CONFIG_DIR bash "$ROOT/lyrebird-stream-manager.sh" help
    grep -qF '[default: /etc/mediamtx/rtsp-users.conf]' <<<"$output"
    grep -qF '/etc/mediamtx/rtsp-users.conf' "$GUIDE"
    grep -qF 'local-only-publish' <<<"$help"
    grep -qF 'local-only-publish' "$GUIDE"
}

@test "the users-file format and the hash command in the guide are what the renderer accepts, and a plaintext line is refused without being printed [DOC-01]" {
    command -v openssl >/dev/null || skip "openssl not installed"
    local cmd hash
    cmd="$(fenced_block "$GUIDE" "printf '%s' 'the password'" | grep -m1 'openssl dgst')"
    [ -n "$cmd" ] || {
        echo "the guide has no hash command for the users file"
        return 1
    }
    hash="$(bash -c "$cmd")"
    [ "${#hash}" -eq 44 ]
    printf 'listener:sha256:%s\n' "$hash" >"$TEST_SCRATCH/users.conf"
    run bash -c 'source "$1/lyrebird-common.sh"; lyrebird_render_mediamtx_config --auth-mode local-only-publish --users-file "$2"' _ "$ROOT" "$TEST_SCRATCH/users.conf"
    [ "$status" -eq 0 ]
    grep -qF "ips: ['127.0.0.1', '::1']" <<<"$output"
    grep -qF "user: 'listener'" <<<"$output"
    printf 'listener:topsecretword\n' >"$TEST_SCRATCH/plain.conf"
    run bash -c 'source "$1/lyrebird-common.sh"; lyrebird_render_mediamtx_config --auth-mode local-only-publish --users-file "$2" 2>&1' _ "$ROOT" "$TEST_SCRATCH/plain.conf"
    [ "$status" -ne 0 ]
    no_match -F topsecretword <<<"$output"
    grep -qF 'rtsp-users.conf' "$GUIDE"
    grep -qF 'plaintext' "$GUIDE"
}

@test "the guide says the unit and the cron file do not carry the authentication variables, and the generated unit and cron file really do not [DOC-01]" {
    run bash -c 'source "$1/lyrebird-stream-manager.sh" >/dev/null 2>&1; render_monitor_cron; render_systemd_unit' _ "$ROOT"
    [ "$status" -eq 0 ]
    local var
    for var in RTSP_AUTH_MODE RTSP_USERS_FILE MEDIAMTX_API_BIND MEDIAMTX_METRICS_BIND MEDIAMTX_RTSP_PORT; do
        ! grep -qF "$var" <<<"$output" || {
            echo "$var is now carried by the unit or the cron file: update the guide's instructions for it"
            return 1
        }
    done
    grep -qF '/etc/cron.d/mediamtx-monitor' "$GUIDE"
    grep -qF 'rewrites the cron file' "$GUIDE"
    grep -qF 'systemctl edit mediamtx-audio' "$GUIDE"
    grep -qF '/etc/cron.d/mediamtx-monitor' "$HTML"
    # the sed command of the guide edits the line the generated cron file really has
    run bash -c 'source "$1/lyrebird-stream-manager.sh" >/dev/null 2>&1; render_monitor_cron' _ "$ROOT"
    grep -qx 'CRON=1' <<<"$output"
    grep -qF "s/^CRON=1\$/&\\nRTSP_AUTH_MODE=local-only-publish/" "$GUIDE"
}

@test "Option 2 states which MediaMTX versions honour the MTX_ override and uses a placeholder nobody can match [DOC-01]" {
    grep -qF 'MTX_AUTHINTERNALUSERS_1_PASS' "$GUIDE"
    grep -qF '1.15.0' "$GUIDE"
    grep -qF 'ignores the variable' "$GUIDE"
    grep -qF 'ignores it' "$HTML"
    local ph
    ph="$(grep -o -m1 'sha256:A\{43\}=' "$GUIDE")"
    [ -n "$ph" ]
    grep -qF "$ph" "$HTML"
    # a well-formed base64 digest of 32 bytes that no password produces
    [ "$(printf '%s' "${ph#sha256:}" | base64 -d | wc -c)" -eq 32 ]
    # change_me must not be offered as the placeholder of the environment option
    grep -qF 'MediaMTX does **not** expand' "$GUIDE"
}

@test "the TLS section uses MediaMTX's current key names, says optional and not strict, and has no WebRTC TLS keys [DOC-01]" {
    local f
    for f in "$GUIDE" "$HTML"; do
        grep -qE '^rtspEncryption: optional$' "$f"
        grep -qE '^rtspServerCert: ' "$f"
        grep -qE '^rtspServerKey: ' "$f"
        no_match -E '^(encryption|serverCert|serverKey|webrtcEncryption|webrtcServerCert|webrtcServerKey):' "$f"
    done
    grep -qF 'Use `optional`, not `strict`' "$GUIDE"
    grep -qF 'Use <code>optional</code>, not <code>strict</code>' "$HTML"
    # the certificate recipe names the host in subjectAltName, which current clients require
    grep -qF 'subjectAltName=' "$GUIDE"
}

@test "the iptables rules accept loopback before the drop rule, in the guide and in security.html [DOC-01]" {
    local block
    for block in "$(fenced_block "$GUIDE" '--dport 8554 -j DROP')" "$(html_block "$HTML" '--dport 8554 -j DROP')"; do
        [ -n "$block" ]
        local lo drop allow
        lo="$(grep -n -F -- '-i lo -j ACCEPT' <<<"$block" | head -n1 | cut -d: -f1)"
        allow="$(grep -n -F -- '-s 192.168.1.0/24 -j ACCEPT' <<<"$block" | head -n1 | cut -d: -f1)"
        drop="$(grep -n -F -- '--dport 8554 -j DROP' <<<"$block" | head -n1 | cut -d: -f1)"
        [ -n "$lo" ] || {
            echo "no loopback rule before the drop rule"
            return 1
        }
        [ -n "$allow" ] && [ "$lo" -lt "$allow" ] && [ "$allow" -lt "$drop" ]
    done
    no_match -E 'ufw deny 9997|ufw deny 8554|ufw deny 8889' "$GUIDE" "$HTML"
}

@test "the fail2ban filter in the guide and in security.html matches the failed-login line of every MediaMTX version once, and not the old client= form [DOC-01]" {
    local g h
    g="$(fenced_block "$GUIDE" 'failregex' | grep -E 'failregex|^[[:space:]]+\^' || true)"
    h="$(html_block "$HTML" 'failregex' | grep -E 'failregex|^[[:space:]]+\^' || true)"
    [ -n "$g" ]
    no_match -F 'client=' <<<"$g"
    printf '%s\n' \
        '2026/11/12 05:41:11 WAR [RTSP] [conn 10.99.0.1:37452] failed to authenticate: authentication failed' \
        '2026/11/12 05:41:12 INF [RTSP] [conn 10.99.0.1:37452] closed: failed to authenticate: authentication failed' \
        '2026/11/12 05:40:50 INF [RTSP] [conn 10.99.0.1:49050] closed: authentication failed: authentication failed' \
        '2026/11/12 05:40:39 INF [RTSP] [conn 10.99.0.1:57320] closed: authentication error' \
        '2026/11/12 05:39:29 INF [RTSP] [conn 10.99.0.2:57953] opened' >"$TEST_SCRATCH/mediamtx.log"
    printf '%s\n' "$g" >"$TEST_SCRATCH/filter.txt"
    run python3 -I - "$TEST_SCRATCH/filter.txt" "$TEST_SCRATCH/mediamtx.log" <<'PY'
import re, sys
patterns = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if line.startswith("failregex"):
        line = line.split("=", 1)[1].strip()
    patterns.append(re.compile(line.replace("<HOST>", r"(?P<host>[0-9a-fA-F:.]+)")))
matched = []
for line in open(sys.argv[2], encoding="utf-8"):
    rest = line.rstrip("\n")[19:]  # fail2ban removes the time stamp before it applies the patterns
    hits = [m.group("host") for p in patterns for m in [p.search(rest)] if m]
    if len(hits) > 1:
        print("matched twice:", line)
        sys.exit(1)
    if hits:
        matched.append(hits[0])
if matched != ["10.99.0.1"] * 3:
    print("expected three matches of 10.99.0.1, got", matched)
    sys.exit(1)
PY
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    # security.html carries the same filter
    [ "$(squeeze <<<"$g")" = "$(squeeze <<<"$h")" ]
}

@test "every YAML block the guide and security.html share is the same text in both, and loads in each MediaMTX binary that can validate it, without a deprecation warning [DOC-01]" {
    local token
    for token in 'user: birdwatcher' 'rtspEncryption: optional' 'user: operator'; do
        local g h
        g="$(fenced_block "$GUIDE" "$token")"
        h="$(html_block "$HTML" "$token")"
        [ -n "$g" ] || {
            echo "the guide has no block with: $token"
            return 1
        }
        [ -n "$h" ] || {
            echo "security.html has no block with: $token"
            return 1
        }
        [ "$(squeeze <<<"$g")" = "$(squeeze <<<"$h")" ] || {
            echo "the block with '$token' differs between the guide and security.html"
            return 1
        }
    done
    # Live part: each block, inserted before "paths:" of a rendered configuration, must load
    local bin version out n=0
    for bin in ${LYREBIRD_TEST_MEDIAMTX_BINS:-}; do
        "$bin" --help 2>&1 | grep -q -- '--validate-conf' || continue
        version="$("$bin" --version | head -n1)"
        for token in 'user: birdwatcher' 'rtspEncryption: optional' 'user: operator'; do
            fenced_block "$GUIDE" "$token" >"$TEST_SCRATCH/block.yml"
            sed -i "s#/etc/mediamtx/certs#$TEST_SCRATCH#g" "$TEST_SCRATCH/block.yml"
            bash -c 'source "$1/lyrebird-common.sh"; lyrebird_render_mediamtx_config --mediamtx-version "$2"' _ "$ROOT" "$version" >"$TEST_SCRATCH/base.yml"
            awk -v snip="$TEST_SCRATCH/block.yml" '/^paths:/ && !d { while ((getline l < snip) > 0) print l; print ""; d = 1 } { print }' "$TEST_SCRATCH/base.yml" >"$TEST_SCRATCH/full.yml"
            out="$("$bin" --validate-conf="$TEST_SCRATCH/full.yml" 2>&1)" || {
                echo "MediaMTX $version rejects the block with '$token':"
                echo "$out"
                return 1
            }
            ! grep -q ' WAR ' <<<"$out" || {
                echo "MediaMTX $version warns about the block with '$token':"
                echo "$out"
                return 1
            }
            n=$((n + 1))
        done
    done
    echo "validated $n block(s) with MediaMTX" >&3
}

@test "the metrics exporter claims match its --help: loopback by default, port 9100, no authentication or TLS [DOC-01]" {
    run bash "$ROOT/lyrebird-metrics.sh" --help
    [ "$status" -eq 0 ]
    grep -qF 'default: 127.0.0.1' <<<"$output"
    grep -qF '9100' <<<"$output"
    grep -qF 'authentication or TLS' <<<"$output"
    grep -qF '127.0.0.1:9100' "$GUIDE"
    grep -qF 'no authentication and no TLS' "$GUIDE"
    grep -qF '127.0.0.1:9100' "$HTML"
    grep -qF 'no authentication and no TLS' "$HTML"
}

@test "the alert claims match the script: the settings file and its default mode, off by default, and the webhook URL on curl's command line [DOC-01]" {
    run env -u LYREBIRD_ALERT_CONFIG bash "$ROOT/lyrebird-alerts.sh" status
    [ "$status" -eq 0 ]
    grep -qF 'Config file: /etc/lyrebird/alerts.conf' <<<"$output"
    grep -qE 'Enabled: +false' <<<"$output"
    grep -qF 'chmod 600 "$ALERT_CONFIG_FILE"' "$ROOT/lyrebird-alerts.sh"
    # the URL is handed to curl as an argument (what makes it visible in /proc/<pid>/cmdline)
    grep -qF '"$webhook_url" 2>/dev/null' "$ROOT/lyrebird-alerts.sh"
    local f
    for f in "$GUIDE" "$HTML"; do
        grep -qF '/etc/lyrebird/alerts.conf' "$f"
        grep -qF '0600' "$f"
        grep -qF '/proc/<pid>/cmdline' "$f" || grep -qF '/proc/&lt;pid&gt;/cmdline' "$f"
        grep -qF 'http://' "$f"
    done
    grep -qF 'LYREBIRD_ALERT_ENABLED' "$GUIDE"
}

@test "the guide and security.html no longer advise binding RTSP to a LAN address, installing both logrotate files, or an invented log owner and recording path [DOC-01]" {
    local block
    block="$(html_block "$HTML" 'rtspAddress: 192')"
    [ -z "$block" ]
    [ -z "$(fenced_block "$GUIDE" 'rtspAddress: 192')" ]
    no_match -F 'sudo cp config/lyrebird-logrotate.conf /etc/logrotate.d/lyrebird' "$GUIDE" "$HTML"
    no_match -F 'chown mediamtx:adm' "$GUIDE"
    no_match -F '/var/recordings' "$GUIDE"
    no_match -F 'ss -tlnp | grep -E' "$GUIDE"
    grep -qF 'Do not bind RTSP to one interface' "$GUIDE"
    grep -qF 'duplicate log entry' "$GUIDE"
    # the default recording path the wipe script uses is the manager's
    grep -qF 'AUDIO_RECORDING_PATH="${AUDIO_RECORDING_PATH:-/dev/shm/lyrebird-buffer}"' "$ROOT/lyrebird-stream-manager.sh"
    grep -qF '${AUDIO_RECORDING_PATH:-/dev/shm/lyrebird-buffer}' "$GUIDE"
    fenced_block "$GUIDE" 'emergency-wipe.sh' >"$TEST_SCRATCH/wipe.txt"
    grep -qF '/etc/lyrebird/alerts.conf' "$TEST_SCRATCH/wipe.txt"
}

@test "the guide names no updater command the updater does not have [DOC-01]" {
    # the updater has no 'update' or 'check' command: it is a menu plus --status, --list, --history, --rollback, --migrate
    no_match -E 'updater[.]sh (update|check)' "$GUIDE" "$HTML"
    grep -qE 'install_mediamtx[.]sh (-n )?update' "$GUIDE"
}

@test "every in-page link of security.html resolves, and so does every security.html anchor the site search points at [DOC-01]" {
    local id
    for id in $(grep -o 'href="#[A-Za-z0-9_-]*"' "$HTML" | sed 's/^href="#//; s/"$//' | sort -u); do
        grep -qF "id=\"$id\"" "$HTML" || {
            echo "security.html links to #$id, which does not exist"
            return 1
        }
    done
    for id in $(grep -o 'security[.]html#[A-Za-z0-9_-]*' "$ROOT/docs/js/search.js" | sed 's/.*#//' | sort -u); do
        grep -qF "id=\"$id\"" "$HTML" || {
            echo "docs/js/search.js points at security.html#$id, which does not exist"
            return 1
        }
    done
    # the new sections exist
    grep -qF 'id="metrics-alerts"' "$HTML"
    grep -qF 'id="tls"' "$HTML"
}

@test "the library integrity check the guides describe exists, and only in the stream manager [DOC-01]" {
    grep -qF 'LYREBIRD_COMMON_EXPECTED_HASH' "$ROOT/lyrebird-stream-manager.sh"
    local f
    for f in "$ROOT"/lyrebird-alerts.sh "$ROOT"/lyrebird-metrics.sh "$ROOT"/lyrebird-storage.sh "$ROOT"/lyrebird-diagnostics.sh \
        "$ROOT"/lyrebird-orchestrator.sh "$ROOT"/lyrebird-updater.sh "$ROOT"/install_mediamtx.sh; do
        ! grep -qF 'LYREBIRD_COMMON_EXPECTED_HASH' "$f" || {
            echo "$f now checks the library: update the guide, which says only the stream manager does"
            return 1
        }
    done
    grep -qF 'Only the stream manager has this check' "$GUIDE"
    grep -qF 'Only the stream manager has this check' "$HTML"
    # a wrong hash stops the manager (run by path, as the guide says)
    run env LYREBIRD_COMMON_EXPECTED_HASH=0000 bash "$ROOT/lyrebird-stream-manager.sh" help
    [ "$status" -eq 1 ]
    grep -qF 'integrity check failed' <<<"$output"
}

# ---------------------------------------------------------------------------
# [DOC-04] SECURITY.md
# ---------------------------------------------------------------------------

@test "SECURITY.md has no support row for a version that was never released, says fixes are made on main, and every tag it names exists [DOC-04]" {
    no_match -E '^\|[[:space:]]*[0-9]+\.x(\.x)?[[:space:]]*\|' "$POLICY"
    grep -qF 'Security fixes are made on the `main` branch' "$POLICY"
    grep -qF 'no fix is back-ported' "$POLICY"
    # the tags named are real ones (when this checkout has tags at all)
    local tag
    if git -C "$ROOT" tag | grep -q .; then
        for tag in $(grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+' "$POLICY" | sort -u); do
            git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null || {
                echo "SECURITY.md names the tag $tag, which does not exist"
                return 1
            }
        done
    fi
    grep -qF 'git tag --contains' "$POLICY"
}

@test "SECURITY.md promises no response or fix times [DOC-04]" {
    no_match -iE '48 hours|24-48|7 days|30 days|within [0-9]+' "$POLICY"
    no_match -E '^\s*- (Critical|High|Medium|Low):' "$POLICY"
    grep -qF 'promises no response time and no fix time' "$POLICY"
}

@test "SECURITY.md keeps the reporting instructions and says what is not covered, and the repository really has no signing or attestation [DOC-04]" {
    grep -qF 'Email security concerns to the maintainer (see GitHub profile)' "$POLICY"
    grep -qF '**Do NOT** open a public GitHub issue' "$POLICY"
    local phrase
    for phrase in 'Real hardware' 'A real systemd manager' 'Signed releases and provenance' 'Branch protection' 'ARM' 'macOS'; do
        grep -qF "$phrase" "$POLICY" || {
            echo "SECURITY.md does not say that this is not covered: $phrase"
            return 1
        }
    done
    # there is no signing or attestation step in any workflow
    no_match -riE 'attest|cosign|sigstore|slsa|gpg|provenance' "$ROOT/.github/workflows"
    # existing tags are lightweight (a lightweight tag is a commit object)
    local tag
    for tag in $(git -C "$ROOT" tag 2>/dev/null); do
        [ "$(git -C "$ROOT" cat-file -t "refs/tags/$tag")" = commit ] || {
            echo "tag $tag is not lightweight: SECURITY.md says release tags are unsigned"
            return 1
        }
    done
}

@test "SECURITY.md's download-verification statement matches the installer's own --help [DOC-04]" {
    run bash "$ROOT/install_mediamtx.sh" --help
    [ "$status" -eq 0 ]
    grep -qF 'a mismatch is always fatal' <<<"$output"
    grep -qF 'only skips the check when no checksum is available' <<<"$output"
    grep -qF 'checksums.sha256' "$POLICY"
    grep -qF 'A mismatch is fatal, also with' "$POLICY"
    grep -qF 'does not detect a compromised' "$POLICY"
    grep -qF "never runs MediaMTX's own \`--upgrade\`" "$POLICY"
    no_match -F 'All MediaMTX downloads are verified' "$POLICY"
}

@test "SECURITY.md lists exactly the MediaMTX versions the live CI matrix runs [DOC-04]" {
    local ci pol
    ci="$(awk '/^  live-mediamtx:/ { j = 1 } j && /^        version:/ { m = 1; next } j && m && /^          - v/ { sub(/^ *- v/, ""); print; next } j && m { exit }' "$ROOT/.github/workflows/bash-ci.yml" | sort -V -u | tr '\n' ' ')"
    [ -n "$ci" ]
    # MediaMTX versions are written without the v that release tags have: 1.21.1, not v1.21.1
    pol="$(grep -o -E '(^|[^v0-9.])1[.][0-9]+[.][0-9]+' "$POLICY" | sed -E 's/^[^1]*//' | sort -V -u | tr '\n' ' ')"
    [ "$pol" = "$ci" ] || {
        echo "CI matrix:  $ci"
        echo "SECURITY.md: $pol"
        return 1
    }
}

@test "SECURITY.md and the guide point at each other, and the anchors exist [DOC-04]" {
    grep -qF '(docs/SECURITY-GUIDE.md)' "$POLICY"
    grep -qF '(../SECURITY.md)' "$GUIDE"
    grep -qF '(../SECURITY.md#supported-versions)' "$GUIDE"
    grep -qE '^## Supported Versions$' "$POLICY"
    grep -qE '^## Reporting a Vulnerability$' "$POLICY"
    grep -qE '^## What Is Not Covered$' "$POLICY"
    [ -f "$ROOT/CHANGELOG.md" ]
}

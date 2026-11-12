#!/usr/bin/env bats
# Mechanical checks of the release and contributor documents: CHANGELOG.md and
# its browsing copy docs/changelog.html, docs/ADR.md, CONTRIBUTING.md and
# tools/soak/README.md (docs/REMEDIATION-2026-11.md: DOC-03, DOC-04). Each test
# pins a claim that was wrong, missing or stale, against the real scripts, the
# register (docs/remediation-status.json) or the workflows, so it cannot come
# back unnoticed. Test names end with the tag of the register item.
#
# LYREBIRD_DOCS_ROOT (default: the repository) is the tree the DOCUMENTS are read
# from, so that a test can be run against an older copy of them to see it fail.
# Scripts, the register and the workflows are always the repository's own.

load scratch_tmpdir

setup() {
    scratch_setup
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    DOCS="${LYREBIRD_DOCS_ROOT:-$ROOT}"
    CHANGELOG="$DOCS/CHANGELOG.md"
    CHANGELOG_HTML="$DOCS/docs/changelog.html"
    ADR="$DOCS/docs/ADR.md"
    REGISTER="$ROOT/docs/remediation-status.json"
}

teardown() {
    [[ -n "${TEST_SCRATCH:-}" ]] && scratch_teardown
    return 0
}

# unreleased_section: the text of the [Unreleased] section of CHANGELOG.md, from
# its heading to the next "## " heading.
unreleased_section() {
    awk '/^## \[Unreleased\]/ { on = 1; next } /^## / { on = 0 } on' "$CHANGELOG"
}

# group_section NAME: the lines of one "#### NAME" group of the Unreleased
# section, up to the next "#### " or "### " heading.
group_section() {
    unreleased_section | awk -v want="#### $1" '
        $0 == want { on = 1; next }
        /^#### / || /^### / { on = 0 }
        on'
}

# script_version FILE: what `grep -m1 VERSION=` finds in the script, as a bare number
script_version() {
    local line
    line="$(grep -m1 'VERSION=' "$1")" || return 1
    line="${line#*VERSION=}"
    line="${line//[\"\']/}"
    printf '%s\n' "${line%%[^0-9.]*}"
}

# ---------------------------------------------------------------------------
# CHANGELOG.md [DOC-04]
# ---------------------------------------------------------------------------

@test "the CHANGELOG has an Unreleased section with its groups in order: Security, Changed behaviour, Fixed, Removed, Added, Upgrading, Known limits [DOC-04]" {
    local got want
    got="$(unreleased_section | grep -E '^#### ' | head -n 7 | tr '\n' '|')"
    want='#### Security|#### Changed behaviour|#### Fixed|#### Removed|#### Added|#### Upgrading an existing node|#### Known limits|'
    [ "$got" = "$want" ] || { echo "got:  $got"; echo "want: $want"; return 1; }
}

@test "the Unreleased section has a row for every exit code the stream manager can return [DOC-04]" {
    local help codes code missing=0
    help="$(bash "$ROOT/lyrebird-stream-manager.sh" help 2>&1)"
    # the "Exit Codes:" block of --help: lines such as "    9  - Streams failed: ..."
    codes="$(awk '/^Exit Codes:/ { on = 1; next } on && /^[A-Za-z]/ { on = 0 } on' <<<"$help" \
        | sed -nE 's/^[[:space:]]+([0-9]+)[[:space:]]+-.*/\1/p')"
    [ -n "$codes" ]
    # 0 to 10 are the codes the manager defines; 128+N is a signal
    [ "$(wc -l <<<"$codes")" -ge 11 ]
    for code in $codes; do
        if ! unreleased_section | grep -qE "^\\| $code \\|"; then
            echo "no row for exit code $code in the Unreleased exit-code table"
            missing=1
        fi
    done
    unreleased_section | grep -qE '^\| 128\+N \|' || { echo "no row for 128+N"; missing=1; }
    [ "$missing" -eq 0 ]
}

@test "every ID in brackets in the Unreleased section is in the register, fixed or documented-hw, and the register's P1 and P2 findings are all there [DOC-04]" {
    run python3 -I - "$CHANGELOG" "$REGISTER" <<'PY'
import json, re, sys

text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^## \[Unreleased\]\n(.*?)^## ", text, re.S | re.M)
section = re.sub(r"\s+", " ", m.group(1)) if m else ""
register = {i["id"]: i for i in json.load(open(sys.argv[2], encoding="utf-8"))["items"]}

cited = set()
for group in re.findall(r"\[((?:(?:LB|X|DOC)-\d+)(?:, (?:LB|X|DOC)-\d+)*)\]", section):
    cited.update(group.split(", "))

problems = []
# items whose remaining work is the documentation pass this section belongs to
docs_pass = {"X-21", "DOC-02", "DOC-03", "DOC-04"}
for i in sorted(cited):
    item = register.get(i)
    if item is None:
        problems.append("%s is not in the register" % i)
    elif item["status"] not in ("fixed", "documented-hw") and not (item["status"] == "open" and i in docs_pass):
        problems.append("%s has status %s" % (i, item["status"]))
if not cited:
    problems.append("the Unreleased section cites no register ID")

for i, item in sorted(register.items()):
    if not re.match(r"^(LB|X)-", i):
        continue
    if item["status"] in ("fixed", "documented-hw") and item["severity"] in ("P1", "P2") and i not in cited:
        problems.append("%s (%s, %s) is not in the Unreleased section: %s" % (i, item["severity"], item["status"], item["title"]))

print("\n".join(problems))
sys.exit(1 if problems else 0)
PY
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the version table gives every script's version as the script says it [DOC-04]" {
    local table row name tree file want missing=0 f
    table="$(awk '/^## Version Numbering/ { on = 1 } on && /^\|/' "$CHANGELOG")"
    [ -n "$table" ]
    # the old header "Current Version" named a column that was out of date
    ! grep -q 'Current Version' "$CHANGELOG" || { echo "the table still has a 'Current Version' column"; return 1; }
    while IFS='|' read -r _ name _ tree _; do
        name="$(echo "$name" | tr -d ' ')"
        tree="$(echo "$tree" | tr -d ' ')"
        case "$name" in
            Component | -*) continue ;;
        esac
        file="$ROOT/$name"
        [ -f "$file" ] || { echo "the table names $name, which is not in the repository"; missing=1; continue; }
        want="$(script_version "$file")"
        [ "$tree" = "$want" ] || { echo "$name: the table says $tree, the script says $want"; missing=1; }
    done <<<"$table"
    # every script of the repository that carries a version is in the table
    for f in "$ROOT"/*.sh "$ROOT"/tools/soak/lyrebird-soak.sh; do
        name="${f#"$ROOT"/}"
        grep -q 'VERSION=' "$f" || continue
        grep -qF "| $name |" <<<"$table" || { echo "$name has a version and is not in the table"; missing=1; }
    done
    [ "$missing" -eq 0 ]
}

@test "old entries the audit made false carry a one-line correction note [DOC-04]" {
    local entry missing=0
    # each entry (a fixed text of the entry) must be followed within 6 lines by a correction
    while IFS= read -r entry; do
        if ! grep -n -A6 -F -- "$entry" "$CHANGELOG" | grep -q 'Correction (2026-11)'; then
            echo "no correction note after: $entry"
            missing=1
        fi
    done <<'EOF'
Restored the wrapper's backoff-restart loop.
- systemd service files with watchdog support
- Heartbeat/watchdog integration with systemd
config is sourced with errexit neutralised and still fully honored.
fires a false DEAD MIC.
- Automatic architecture detection (x86_64, ARM64, ARMv7, ARMv6)
- Built-in upgrade support for MediaMTX 1.15.0+
EOF
    [ "$missing" -eq 0 ]
}

@test "the Known limits say what the suite does not run on and what GitHub itself was not asked [DOC-04]" {
    local limits term
    limits="$(group_section 'Known limits')"
    [ -n "$limits" ]
    for term in 'real systemd' 'USB' 'ARM' 'macOS' 'Bash 5.2' 'GitHub' 'validate-conf'; do
        grep -qF -- "$term" <<<"$limits" || { echo "the Known limits do not mention: $term"; return 1; }
    done
}

@test "every command and option in the Upgrading steps is one the real script has [DOC-04]" {
    local upgrading span script rest word helptext missing=0
    upgrading="$(group_section 'Upgrading an existing node')"
    [ -n "$upgrading" ]
    local mgr_help inst_help
    mgr_help="$(bash "$ROOT/lyrebird-stream-manager.sh" help 2>&1)"
    inst_help="$(bash "$ROOT/install_mediamtx.sh" help 2>&1)"
    # the updater asks for a confirmation when it runs as root, even for --help:
    # its help text is read from the script
    local upd_help
    upd_help="$(sed -n '/^show_help()/,/^}/p' "$ROOT/lyrebird-updater.sh")"
    local n=0
    while IFS= read -r span; do
        case "$span" in
            'sudo ./lyrebird-stream-manager.sh'*) script=mgr helptext="$mgr_help" ;;
            'sudo ./install_mediamtx.sh'*) script=inst helptext="$inst_help" ;;
            'sudo ./lyrebird-updater.sh'*) script=upd helptext="$upd_help" ;;
            *) continue ;;
        esac
        n=$((n + 1))
        rest="${span#sudo ./*.sh}"
        for word in $rest; do
            case "$word" in
                # an option must be there as a whole word: --regenerate is not --regenerate-config
                -*) grep -qE -- "(^|[^A-Za-z0-9_-])${word}([^A-Za-z0-9_-]|$)" <<<"$helptext" || { echo "$script: '$word' (in: $span) is not in its help"; missing=1; } ;;
                vX.Y.Z | ADDR | PATH) ;;
                *) grep -qw -- "$word" <<<"$helptext" || { echo "$script: '$word' (in: $span) is not in its help"; missing=1; } ;;
            esac
        done
    done < <(tr '\n' ' ' <<<"$upgrading" | tr -s ' ' | grep -oE '`sudo \./[^`]+`' | tr -d '`')
    # the steps name at least the manager's install, validate and restart, the installer's
    # --force install, and the updater
    [ "$n" -ge 6 ] || { echo "only $n commands found in the Upgrading steps"; return 1; }
    [ "$missing" -eq 0 ]
}

# ---------------------------------------------------------------------------
# docs/changelog.html is a copy of CHANGELOG.md [DOC-04]
# ---------------------------------------------------------------------------

# changelog_copy_report: print the first difference between the words of
# CHANGELOG.md (from its first "## " heading) and the words of the content of
# docs/changelog.html (from its first <h2>). Markdown marks are not words:
# heading hashes, bullet and number markers, table bars and separator rows,
# rules, backticks, bold marks, the target of a link, and the brackets of a
# version heading. Prints nothing and exits 0 when both say the same.
changelog_copy_report() {
    python3 -I - "$CHANGELOG" "$CHANGELOG_HTML" <<'PY'
import html.parser
import re
import sys


def md_words(path):
    lines = open(path, encoding="utf-8").read().split("\n")
    start = next(i for i, l in enumerate(lines) if l.startswith("## "))
    out = []
    for line in lines[start:]:
        if not line.strip() or re.match(r"^---+\s*$", line):
            continue
        if re.match(r"^\s*\|[-\s|:]+\|\s*$", line):
            continue
        m = re.match(r"^#{2,4}\s+(.*)$", line)
        if m:
            line = m.group(1)
            v = re.match(r"^\[([^\]]+)\](.*)$", line)
            if v:
                line = v.group(1) + v.group(2)
        elif line.lstrip().startswith("|"):
            line = line.strip().strip("|").replace("|", " ")
        else:
            line = re.sub(r"^\s*([-*]|\d+\.)\s+", "", line)
        line = line.replace("`", "").replace("**", "")
        line = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r"\1", line)
        out.extend(line.split())
    return out


# inline tags (code, strong, a, span, em) do not separate words; block tags do
INLINE = {"code", "strong", "a", "span", "em", "b", "i"}


class Words(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.on = False
        self.done = False
        self.words = []

    def handle_starttag(self, tag, attrs):
        if tag == "h2":
            self.on = True
        if tag not in INLINE:
            self.words.append(" ")

    def handle_endtag(self, tag):
        if tag == "main":
            self.done = True
        if tag not in INLINE:
            self.words.append(" ")

    def handle_data(self, data):
        if self.on and not self.done:
            self.words.append(data)


def html_words(path):
    p = Words()
    p.feed(open(path, encoding="utf-8").read())
    return "".join(p.words).split()


a, b = md_words(sys.argv[1]), html_words(sys.argv[2])
if a != b:
    n = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
    print("CHANGELOG.md has %d words, docs/changelog.html has %d" % (len(a), len(b)))
    print("first difference at word %d" % n)
    print("  CHANGELOG.md:       ... %s" % " ".join(a[max(0, n - 6):n + 8]))
    print("  docs/changelog.html: ... %s" % " ".join(b[max(0, n - 6):n + 8]))
    sys.exit(1)
PY
}

@test "docs/changelog.html has the headings of CHANGELOG.md, in order [DOC-04]" {
    local md html
    md="$(grep -E '^#{2,4} ' "$CHANGELOG" | sed -E 's/^#+ +//; s/^\[([^]]+)\]/\1/' | sed -E 's/`//g' | tr -s ' ')"
    html="$(python3 -I - "$CHANGELOG_HTML" <<'PY'
import html.parser, sys
class H(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.cur = None
        self.buf = ""
        self.out = []
        self.seen_h2 = False
    def handle_starttag(self, tag, attrs):
        if tag in ("h2", "h3", "h4"):
            self.cur, self.buf = tag, ""
            self.seen_h2 = self.seen_h2 or tag == "h2"
    def handle_endtag(self, tag):
        if tag == self.cur:
            self.out.append(" ".join(self.buf.split()))
            self.cur = None
    def handle_data(self, data):
        if self.cur:
            self.buf += data
h = H()
h.feed(open(sys.argv[1], encoding="utf-8").read())
print("\n".join(h.out))
PY
)"
    [ "$md" = "$html" ] || {
        diff <(printf '%s\n' "$md") <(printf '%s\n' "$html") | head -20
        return 1
    }
}

@test "docs/changelog.html says what CHANGELOG.md says, word for word, version table included [DOC-04]" {
    run changelog_copy_report
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# ---------------------------------------------------------------------------
# docs/ADR.md: the decisions D1 to D15 of docs/REMEDIATION-2026-11.md [ADR]
# ---------------------------------------------------------------------------

# adr N: the text of ADR-0NN, from its heading to the next ADR heading
adr() {
    awk -v want="$(printf '## ADR-%03d:' "$1")" '
        index($0, want) == 1 { on = 1; print; next }
        /^## ADR-/ { on = 0 }
        on' "$ADR"
}

# manager_help: the stream manager's own help text, with the defaults it shows
# (scratch_setup moves the state directory and the log into the scratch directory)
manager_help() {
    env -u LYREBIRD_STATE_DIR -u LYREBIRD_STATUS_FILE -u STREAM_MANAGER_LOG_FILE \
        bash "$ROOT/lyrebird-stream-manager.sh" help 2>&1
}

# code_lines FILE: the lines of a script that are not comments
code_lines() {
    grep -vE '^[[:space:]]*#' "$1"
}

# unit_lines FILE: the uncommented lines of a unit file
unit_lines() {
    grep -vE '^[[:space:]]*(#|$)' "$1"
}

@test "the ADRs are numbered without gaps, each has its sections, and the new ones say what they rejected [ADR]" {
    local nums n num block section bad=0
    nums="$(grep -oE '^## ADR-[0-9]{3}' "$ADR" | sed 's/## ADR-//')"
    [ "$(wc -l <<<"$nums")" -ge 21 ] || { echo "fewer than 21 ADRs"; return 1; }
    n=0
    for num in $nums; do
        n=$((n + 1))
        [ "$((10#$num))" -eq "$n" ] || { echo "ADR numbers are not consecutive at $num"; bad=1; }
        block="$(adr "$((10#$num))")"
        for section in '**Date**' '**Status**' '### Context' '### Decision' '### Rationale' '### Consequences'; do
            grep -qF -- "$section" <<<"$block" || { echo "ADR-$num lacks $section"; bad=1; }
        done
        if [ "$((10#$num))" -ge 11 ]; then
            grep -qF '**Rejected' <<<"$block" || { echo "ADR-$num names no rejected alternative"; bad=1; }
        fi
    done
    [ "$bad" -eq 0 ]
}

@test "every decision D1 to D15 is recorded in an ADR, and the old ADRs that were superseded say by which [ADR]" {
    local d missing=0
    for d in $(seq 1 15); do
        grep -qE "\\bD${d}\\b" "$ADR" || { echo "D$d is not named in docs/ADR.md"; missing=1; }
    done
    # the superseded records point at ADRs that exist
    grep -qE '^\*\*Status\*\*: Accepted; superseded in part by ADR-017' "$ADR" || { echo "ADR-005 does not say ADR-017 supersedes it"; missing=1; }
    grep -qE '^\*\*Status\*\*: Accepted; superseded in part by ADR-013' "$ADR" || { echo "ADR-009 does not say ADR-013 supersedes it"; missing=1; }
    [ -n "$(adr 13)" ] && [ -n "$(adr 17)" ] || { echo "ADR-013 or ADR-017 is missing"; missing=1; }
    # ADR-001 says what the Bash claim rests on
    adr 1 | grep -qF 'Only Bash 5.2 has been run' || { echo "ADR-001 does not say which Bash was run"; missing=1; }
    [ "$missing" -eq 0 ]
}

@test "ADR-011: the two units conflict and neither depends on the other, as the units are written; exit 8 is in the manager's help [ADR]" {
    local block
    block="$(adr 11)"
    grep -qF 'Conflicts=' <<<"$block"
    grep -qF 'exit 8' <<<"$block"
    unit_lines "$ROOT/config/mediamtx-audio.service" | grep -qx 'Conflicts=mediamtx.service'
    unit_lines "$ROOT/config/mediamtx-audio.service" | grep -qx 'After=mediamtx.service'
    unit_lines "$ROOT/config/mediamtx.service" | grep -qx 'Conflicts=mediamtx-audio.service'
    ! unit_lines "$ROOT/config/mediamtx-audio.service" | grep -E '^(Wants|Requires|BindsTo|PartOf)=.*mediamtx\.service' || false
    ! unit_lines "$ROOT/config/mediamtx.service" | grep -E '^(Wants|Requires|BindsTo|PartOf)=.*mediamtx-audio' || false
    manager_help | grep -qE '^[[:space:]]+8[[:space:]]+-[[:space:]]+Another MediaMTX owns the node'
}

@test "ADR-012: the start policy, the empty start, exit 9 and the status file are what the manager's help says [ADR]" {
    local block help term
    block="$(adr 12)"
    help="$(manager_help)"
    for term in 'LYREBIRD_START_POLICY' 'LYREBIRD_ALLOW_EMPTY_START' 'exit 9' '/run/lyrebird/status.json' 'waiting_for_devices'; do
        grep -qF -- "$term" <<<"$block" || { echo "ADR-012 does not mention $term"; return 1; }
    done
    for term in 'LYREBIRD_START_POLICY' 'LYREBIRD_ALLOW_EMPTY_START' '/run/lyrebird/status.json' 'waiting_for_devices' 'degraded' 'strict'; do
        grep -qF -- "$term" <<<"$help" || { echo "the manager's help does not mention $term"; return 1; }
    done
    grep -qE '^[[:space:]]+9[[:space:]]+-' <<<"$help"
    # the default policy is degraded, as the ADR says
    grep -qE 'LYREBIRD_START_POLICY[[:space:]]+What start requires \[default: degraded\]' <<<"$help"
}

@test "ADR-013: locks and process control are as the ADR says: STOP_LOCK_TIMEOUT 5, --kill-all --yes, no pkill or pgrep patterns [ADR]" {
    local block f term
    block="$(adr 13)"
    for term in 'flock' 'STOP_LOCK_TIMEOUT' 'force-stop --kill-all --yes' 'SIGTERM' 'start time'; do
        grep -qF -- "$term" <<<"$block" || { echo "ADR-013 does not mention $term"; return 1; }
    done
    grep -qE '^STOP_LOCK_TIMEOUT=\$\(_uint_or "\$\{STOP_LOCK_TIMEOUT:-\}" 5\)' "$ROOT/lyrebird-stream-manager.sh"
    manager_help | grep -qF 'force-stop --kill-all [--yes]'
    # no executable line of the manager, the installer or the metrics exporter runs pkill, killall or pgrep
    for f in lyrebird-stream-manager.sh install_mediamtx.sh lyrebird-metrics.sh; do
        ! code_lines "$ROOT/$f" | grep -E '\b(pkill|killall|pgrep)\b' || { echo "$f runs a name-based process tool"; return 1; }
    done
    # no lock file is removed: the manager's code names no rm of a lock path
    ! code_lines "$ROOT/lyrebird-stream-manager.sh" | grep -E 'rm .*(LOCK_FILE|CONFIG_LOCK)' || false
}

@test "ADR-014: the device configuration is parsed as data and a stream name follows one rule, as the ADR says [ADR]" {
    local block conf name out term
    block="$(adr 14)"
    for term in 'SAMPLE_RATE' 'CHANNELS' 'CODEC' 'BITRATE' 'THREAD_QUEUE' 'PCM' 'canonical_stream_name' 'all_others' 'printf %q' 'validate'; do
        grep -qF -- "$term" <<<"$block" || { echo "ADR-014 does not mention $term"; return 1; }
    done
    # every setting the ADR lists is accepted, and a shell line is refused without being run
    conf="$TEST_SCRATCH/devices.conf"
    cat >"$conf" <<EOF
DEVICE_ONE_SAMPLE_RATE=48000
DEVICE_ONE_CHANNELS="2"
DEVICE_ONE_CODEC='opus'
DEVICE_ONE_BITRATE=128k
DEVICE_ONE_THREAD_QUEUE=8192
DEVICE_ONE_PCM=0
EOF
    run env MEDIAMTX_DEVICE_CONFIG="$conf" bash "$ROOT/lyrebird-stream-manager.sh" validate
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    printf '%s\n' "touch $TEST_SCRATCH/was-run" >>"$conf"
    run env MEDIAMTX_DEVICE_CONFIG="$conf" bash "$ROOT/lyrebird-stream-manager.sh" validate
    [ "$status" -eq 4 ] || { echo "$output"; return 1; }
    [ ! -e "$TEST_SCRATCH/was-run" ]
    # the name rule: Studio Mix is studio_mix, and every reserved word the ADR lists is refused
    out="$(bash -c 'source "$1" >/dev/null 2>&1; canonical_stream_name "Studio Mix"' _ "$ROOT/lyrebird-stream-manager.sh")"
    [ "$out" = "studio_mix" ]
    for name in control stats api metrics health all all_others; do
        run bash -c 'source "$1" >/dev/null 2>&1; canonical_stream_name "$2"' _ "$ROOT/lyrebird-stream-manager.sh" "$name"
        [ "$status" -ne 0 ] || { echo "'$name' was accepted"; return 1; }
    done
    run bash -c 'source "$1" >/dev/null 2>&1; canonical_stream_name "$2"' _ "$ROOT/lyrebird-stream-manager.sh" "$(printf 'x%.0s' $(seq 1 65))"
    [ "$status" -ne 0 ]
}

@test "ADR-015: the generated MediaMTX configuration binds API and metrics to loopback and turns the other protocols off, as the ADR says [ADR]" {
    local block cfg proto term
    block="$(adr 15)"
    for term in '127.0.0.1' 'MEDIAMTX_API_BIND' 'MEDIAMTX_METRICS_BIND' 'RTSP_AUTH_MODE=local-only-publish' 'RTSP_USERS_FILE' 'MoQ'; do
        grep -qF -- "$term" <<<"$block" || { echo "ADR-015 does not mention $term"; return 1; }
    done
    cfg="$(bash -c 'source "$1"; lyrebird_render_mediamtx_config --mediamtx-version v1.21.1' _ "$ROOT/lyrebird-common.sh")"
    grep -qx 'apiAddress: 127.0.0.1:9997' <<<"$cfg"
    grep -qx 'metricsAddress: 127.0.0.1:9998' <<<"$cfg"
    for proto in rtmp hls webrtc srt; do
        grep -qx "$proto: no" <<<"$cfg" || { echo "$proto is not off"; return 1; }
    done
    grep -qx 'moq: no' <<<"$cfg"
    # MoQ is only written where the key exists: from 1.19.0
    cfg="$(bash -c 'source "$1"; lyrebird_render_mediamtx_config --mediamtx-version v1.18.0' _ "$ROOT/lyrebird-common.sh")"
    ! grep -q 'moq' <<<"$cfg" || false
    manager_help | grep -qF 'RTSP_AUTH_MODE'
    manager_help | grep -qF 'MEDIAMTX_API_BIND'
}

@test "ADR-016: the ownership marker, the adopted first line and the options that hand a file over are what the scripts have [ADR]" {
    local block marker legacy
    block="$(adr 16)"
    marker="$(bash -c 'source "$1"; printf "%s" "$LYREBIRD_MEDIAMTX_CONFIG_MARKER"' _ "$ROOT/lyrebird-common.sh")"
    [ "$marker" = '# Managed by LyreBirdAudio' ]
    grep -qF -- "$marker" <<<"$block"
    legacy="$(sed -n 's/^LEGACY_MEDIAMTX_CONFIG_FIRST_LINE="\(.*\)"$/\1/p' "$ROOT/lyrebird-stream-manager.sh")"
    [ "$legacy" = '# MediaMTX Configuration - Audio Streams' ]
    grep -qF -- "$legacy" <<<"$block"
    grep -qF -- '--regenerate-config' <<<"$block"
    manager_help | grep -qF -- '--regenerate-config'
    bash "$ROOT/install_mediamtx.sh" help 2>&1 | grep -qE -- '-f, --force'
    grep -qF -- '--validate-conf' <<<"$block"
    grep -qF -- '--validate-conf' "$ROOT/lyrebird-stream-manager.sh"
    grep -qF 'MEDIAMTX_CONFIG_BACKUPS' <<<"$block"
    manager_help | grep -qF 'MEDIAMTX_CONFIG_BACKUPS'
}

@test "ADR-017: lyrebird_atomic_write is used where the ADR says, and not by the metrics exporter [ADR]" {
    local block f
    block="$(adr 17)"
    grep -qF 'lyrebird_atomic_write' <<<"$block"
    grep -qE '^lyrebird_atomic_write\(\)' "$ROOT/lyrebird-common.sh"
    for f in lyrebird-stream-manager.sh install_mediamtx.sh lyrebird-mic-check.sh lyrebird-alerts.sh; do
        code_lines "$ROOT/$f" | grep -q 'lyrebird_atomic_write' || { echo "$f does not use lyrebird_atomic_write"; return 1; }
    done
    ! code_lines "$ROOT/lyrebird-metrics.sh" | grep -q 'lyrebird_atomic_write' || { echo "the metrics exporter uses lyrebird_atomic_write; ADR-017 says it does not"; return 1; }
}

@test "ADR-018: a port that is not an integer from 1 to 65535 ends the manager with exit 4 and the installer names exit 10 [ADR]" {
    local block term
    block="$(adr 18)"
    for term in 'MEDIAMTX_RTSP_PORT' 'MEDIAMTX_API_PORT' 'MEDIAMTX_METRICS_PORT' 'exit 4' 'exit 10'; do
        grep -qF -- "$term" <<<"$block" || { echo "ADR-018 does not mention $term"; return 1; }
    done
    run env MEDIAMTX_API_PORT=abc bash "$ROOT/lyrebird-stream-manager.sh" help
    [ "$status" -eq 4 ]
    run env MEDIAMTX_METRICS_PORT=70000 bash "$ROOT/lyrebird-stream-manager.sh" status
    [ "$status" -eq 4 ]
    grep -qE 'must be an integer from 1 to 65535' "$ROOT/install_mediamtx.sh"
    grep -qE 'Invalid MediaMTX port settings" 10' "$ROOT/install_mediamtx.sh"
}

@test "ADR-019: the level probe reads the RTSP stream, never an ALSA device, and has the verdicts the ADR lists [ADR]" {
    local block body state term
    block="$(adr 19)"
    body="$(sed -n '/^probe_stream_level()/,/^}/p' "$ROOT/lyrebird-stream-manager.sh")"
    [ -n "$body" ]
    for state in ok silent no_audio_data unreachable probe_error; do
        grep -qF -- "$state" <<<"$block" || { echo "ADR-019 does not name the verdict $state"; return 1; }
        grep -qF -- "$state" <<<"$body" || { echo "probe_stream_level has no verdict $state"; return 1; }
    done
    grep -qF 'rtsp://127.0.0.1:' <<<"$body"
    grep -qF 'volumedetect' <<<"$body"
    ! grep -vE '^[[:space:]]*#' <<<"$body" | grep -qE 'arecord|plughw|/dev/snd' || { echo "probe_stream_level touches an ALSA device"; return 1; }
    for term in AUDIO_LEVEL_SAMPLE_DURATION AUDIO_SILENCE_THRESHOLD_DB AUDIO_SILENCE_WARN_DURATION 'DEAD MIC'; do
        grep -qF -- "$term" <<<"$block" || { echo "ADR-019 does not mention $term"; return 1; }
        grep -qF -- "$term" "$ROOT/lyrebird-stream-manager.sh" || { echo "the manager has no $term"; return 1; }
    done
}

@test "ADR-020: the removed settings are gone from the code and only warned about, and neither unit has a watchdog [ADR]" {
    local block name f body in_code in_body
    block="$(adr 20)"
    body="$(sed -n '/^warn_removed_settings()/,/^}/p' "$ROOT/lyrebird-stream-manager.sh")"
    [ -n "$body" ]
    for name in HEARTBEAT_INTERVAL HARDWARE_WATCHDOG_TIMEOUT ENABLE_HARDWARE_WATCHDOG HARDWARE_WATCHDOG_DEVICE LYREBIRD_WATCHDOG_ENABLED LYREBIRD_WATCHDOG_INTERVAL AUDIO_DISK_PERSIST AUDIO_DISK_PATH; do
        grep -qF -- "$name" <<<"$block" || { echo "ADR-020 does not name $name"; return 1; }
        grep -qF -- "$name" <<<"$body" || { echo "$name is not in warn_removed_settings"; return 1; }
        # each name is used in executable code only inside warn_removed_settings
        in_code="$(code_lines "$ROOT/lyrebird-stream-manager.sh" | grep -cF -- "$name" || true)"
        in_body="$(grep -vE '^[[:space:]]*#' <<<"$body" | grep -cF -- "$name" || true)"
        [ "$in_code" -eq "$in_body" ] || { echo "$name is used outside warn_removed_settings"; return 1; }
    done
    ! code_lines "$ROOT/lyrebird-stream-manager.sh" | grep -qF '/dev/watchdog' || { echo "the manager still names /dev/watchdog"; return 1; }
    for f in mediamtx-audio.service mediamtx.service; do
        ! unit_lines "$ROOT/config/$f" | grep -q '^WatchdogSec=' || { echo "$f sets WatchdogSec="; return 1; }
    done
    grep -qF 'RuntimeWatchdogSec=' <<<"$block"
}

@test "ADR-021: both units are shaped as the ADR says: start limit in [Unit], a real reload only for the manager, strict sandbox, always restart [ADR]" {
    local block u section term
    block="$(adr 21)"
    for term in 'StartLimitIntervalSec=' 'ExecReload=' 'ProtectSystem=strict' 'Restart=always' 'systemd-analyze verify'; do
        grep -qF -- "$term" <<<"$block" || { echo "ADR-021 does not mention $term"; return 1; }
    done
    for u in mediamtx-audio.service mediamtx.service; do
        # the start limit keys sit in [Unit], and nowhere else
        section="$(awk '/^\[/ { s = $0 } /^(StartLimitIntervalSec|StartLimitBurst)=/ { print s }' "$ROOT/config/$u" | sort -u)"
        [ "$section" = '[Unit]' ] || { echo "$u: start limit in $section"; return 1; }
    done
    unit_lines "$ROOT/config/mediamtx-audio.service" | grep -qE '^ExecReload=.* reload$'
    ! unit_lines "$ROOT/config/mediamtx.service" | grep -q '^ExecReload=' || { echo "the standalone unit has an ExecReload"; return 1; }
    unit_lines "$ROOT/config/mediamtx-audio.service" | grep -qx 'ProtectSystem=strict'
    unit_lines "$ROOT/config/mediamtx-audio.service" | grep -qx 'Restart=always'
    ! unit_lines "$ROOT/config/mediamtx-audio.service" | grep -q '^Group=' || { echo "the manager's unit sets Group="; return 1; }
    manager_help | grep -qE '^[[:space:]]+reload[[:space:]]'
}

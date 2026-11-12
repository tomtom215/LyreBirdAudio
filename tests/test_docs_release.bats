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

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    DOCS="${LYREBIRD_DOCS_ROOT:-$ROOT}"
    CHANGELOG="$DOCS/CHANGELOG.md"
    CHANGELOG_HTML="$DOCS/docs/changelog.html"
    REGISTER="$ROOT/docs/remediation-status.json"
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

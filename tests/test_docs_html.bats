#!/usr/bin/env bats
# Guard tests for the HTML documentation pages under docs/ (everything except
# security.html and changelog.html, which are checked by their own tests).
#
# The pages once described scripts, flags, exit codes, ports and settings that
# did not exist or behaved otherwise (a watchdog, `serve --port` and `monitor
# --interval` before they were real, `mediamtx --check`, `pkill -9 mediamtx`,
# lock files to delete, WebRTC on 8889, a wizard that generates configuration...).
# Each test below pins one of those claims, or a whole class of them, against
# the real scripts: it runs their --help, their parsers and their generators and
# compares the result with what the page says. A test therefore fails when a
# page drifts, not only when a known wrong sentence comes back.
#
# The pages are read with python3's html.parser into one JSON file per page
# (setup_file); the tests query those files with jq. LYREBIRD_DOCS_DIR points the
# tests at another copy of docs/ (for example an older one) to see them fail.

load scratch_tmpdir

PAGES="index quick-start usage configuration components architecture advanced monitoring troubleshooting contributing"

setup_file() {
    command -v jq >/dev/null 2>&1 || skip "jq is required"
    command -v python3 >/dev/null 2>&1 || skip "python3 is required"
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    DOCS="${LYREBIRD_DOCS_DIR:-$ROOT/docs}"
    export ROOT DOCS
    TOOL="$BATS_FILE_TMPDIR/docs_tool.py"
    cat >"$TOOL" <<'PY'
import json, os, re, sys
from html.parser import HTMLParser

VOID = {"meta", "link", "br", "hr", "img", "input", "base", "col", "area", "source", "wbr"}
BLOCK = {"p", "li", "div", "h1", "h2", "h3", "h4", "td", "th", "dd", "dt", "tr", "ul", "ol", "table", "pre"}


def squash(s):
    return re.sub(r"\s+", " ", s).strip()


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack, self.errors = [], []
        self.text, self.code, self.prose = [], [], []
        self.ids, self.links, self.headings, self.tables = [], [], [], []
        self.pre_by_id = {}
        self.buf = []
        self.pre = None
        self.pre_id = None
        self.pre_depth = 0
        self.table = self.row = self.cell = self.head = None
        self.h2 = self.h3 = ""

    def flush(self):
        t = squash("".join(self.buf))
        if t:
            self.prose.append(t)
        self.buf = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if "id" in a:
            self.ids.append(a["id"])
        if tag == "a" and "href" in a:
            self.links.append(a["href"])
        if tag not in VOID:
            self.stack.append(tag)
        if tag in BLOCK:
            self.flush()
        if tag in ("h1", "h2", "h3", "h4"):
            self.head = [int(tag[1]), a.get("id", ""), []]
        if tag == "pre":
            self.pre_depth += 1
            if self.pre_depth == 1:
                self.pre, self.pre_id = [], a.get("id")
        if tag == "table":
            self.table = {"h2": self.h2, "h3": self.h3, "rows": []}
        if tag == "tr" and self.table is not None:
            self.row = []
        if tag in ("td", "th") and self.row is not None:
            self.cell = []

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if tag in BLOCK:
            self.flush()
        if self.stack and self.stack[-1] == tag:
            self.stack.pop()
        elif tag in self.stack:
            self.errors.append("</%s> closes <%s>" % (tag, self.stack[-1]))
            while self.stack[-1] != tag:
                self.stack.pop()
            self.stack.pop()
        else:
            self.errors.append("stray </%s>" % tag)
        if tag in ("h1", "h2", "h3", "h4") and self.head:
            lvl, hid, parts = self.head
            txt = squash("".join(parts))
            self.headings.append([lvl, hid, txt])
            if lvl == 2:
                self.h2, self.h3 = hid or txt, ""
            elif lvl == 3:
                self.h3 = txt
            self.head = None
        if tag == "pre":
            self.pre_depth -= 1
            if self.pre_depth == 0:
                body = "".join(self.pre)
                self.code.append(body)
                if self.pre_id:
                    self.pre_by_id[self.pre_id] = body
                self.pre = self.pre_id = None
        if tag in ("td", "th") and self.cell is not None:
            self.row.append(squash("".join(self.cell)))
            self.cell = None
        if tag == "tr" and self.row is not None:
            if self.row:
                self.table["rows"].append(self.row)
            self.row = None
        if tag == "table" and self.table is not None:
            self.tables.append(self.table)
            self.table = None

    def handle_data(self, data):
        if "script" in self.stack or "style" in self.stack:
            return
        self.text.append(data)
        if self.head is not None:
            self.head[2].append(data)
        if self.pre is not None:
            self.pre.append(data)
        else:
            self.buf.append(data)
        if self.cell is not None:
            self.cell.append(data)


def extract(docs, out):
    os.makedirs(out, exist_ok=True)
    for name in sorted(os.listdir(docs)):
        if not name.endswith(".html"):
            continue
        p = Page()
        with open(os.path.join(docs, name), encoding="utf-8") as fh:
            p.feed(fh.read())
            p.close()
        p.flush()
        doc = {"text": squash(" ".join(p.text)), "code": p.code, "prose": p.prose, "ids": p.ids,
               "links": p.links, "headings": p.headings, "tables": p.tables,
               "pre_by_id": p.pre_by_id, "errors": p.errors + ["unclosed <%s>" % t for t in p.stack]}
        with open(os.path.join(out, name[:-5] + ".json"), "w", encoding="utf-8") as fh:
            json.dump(doc, fh)


def links(out, docs, mine):
    pages = {f[:-5]: json.load(open(os.path.join(out, f))) for f in os.listdir(out) if f.endswith(".json")}
    bad = []
    for name in mine:
        d = pages[name]
        for e in d["errors"]:
            bad.append("%s: markup: %s" % (name, e))
        lv = [h[0] for h in d["headings"]]
        if lv.count(1) != 1:
            bad.append("%s: %d h1 headings" % (name, lv.count(1)))
        for a, b in zip(lv, lv[1:]):
            if b > a + 1:
                bad.append("%s: heading level jumps from h%d to h%d" % (name, a, b))
    for name, d in pages.items():
        for href in d["links"]:
            if re.match(r"^(https?:|mailto:)", href) or href == "#":
                continue
            file, _, frag = href.partition("#")
            file = file or name + ".html"
            tgt = file[:-5]
            if not file.endswith(".html") or tgt not in pages:
                bad.append("%s: %s: no such page" % (name, href))
            elif frag and frag not in pages[tgt]["ids"]:
                bad.append("%s: %s: no such anchor" % (name, href))
    js = os.path.join(docs, "js", "search.js")
    if os.path.exists(js):
        for m in re.finditer(r"file: '([^']+)'", open(js).read()):
            file, _, frag = m.group(1).partition("#")
            tgt = file[:-5]
            if tgt not in pages:
                bad.append("search.js: %s: no such page" % m.group(1))
            elif frag and frag not in pages[tgt]["ids"]:
                bad.append("search.js: %s: no such anchor" % m.group(1))
    print("\n".join(bad))
    return 1 if bad else 0


if sys.argv[1] == "extract":
    extract(sys.argv[2], sys.argv[3])
elif sys.argv[1] == "links":
    sys.exit(links(sys.argv[2], sys.argv[3], sys.argv[4].split()))
PY
    python3 -I "$TOOL" extract "$DOCS" "$BATS_FILE_TMPDIR/pages"
    export TOOL
}

setup() {
    scratch_setup
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    PAGEDIR="$BATS_FILE_TMPDIR/pages"
    # the scripts under test run with a clean environment and a private home
    CLEAN=(env -i "PATH=$PATH" "HOME=$TEST_SCRATCH" "TMPDIR=$TEST_SCRATCH"
        "STREAM_MANAGER_LOG_FILE=$TEST_SCRATCH/sm.log" "LYREBIRD_STATE_DIR=$TEST_SCRATCH/state"
        "MEDIAMTX_DEVICE_CONFIG=$TEST_SCRATCH/none.conf")
}

teardown() {
    scratch_teardown
}

# ---- helpers ---------------------------------------------------------------

# Fail, showing the matching lines, when a pattern is found (in the files named after it, else on stdin).
# `! grep ...` in the middle of a bats test cannot fail the test, so negative checks use this.
absent() {
    local out
    if out="$(grep -nE -- "$1" "${@:2}")"; then
        printf 'unexpected: %s\n' "$out"
        return 1
    fi
}
absenti() {
    local out
    if out="$(grep -niE -- "$1" "${@:2}")"; then
        printf 'unexpected: %s\n' "$out"
        return 1
    fi
}

pj() { printf '%s/%s.json' "$PAGEDIR" "$1"; }
page_text() { jq -r .text "$(pj "$1")"; }
all_text() { local p; for p in $PAGES; do page_text "$p"; done; }
all_code() { local p; for p in $PAGES; do jq -r '.code[]' "$(pj "$p")"; done; }
all_prose() { local p; for p in $PAGES; do jq -r '.prose[]' "$(pj "$p")"; done; }

# the first cells of the rows of the tables under h2 id $2 whose h3 matches $3 (header row dropped)
table_firsts() { jq -r --arg h2 "$2" --arg h3 "$3" '.tables[] | select(.h2 == $h2 and (.h3 | test($h3; "i"))) | .rows[1:][] | .[0]' "$(pj "$1")"; }

# the real --help of a script
help_of() { "${CLEAN[@]}" bash "$ROOT/$1" --help 2>&1 || true; }

# the real usage text of lyrebird-mic-check.sh (its --help needs /proc/asound; the function does not)
mic_usage() { "${CLEAN[@]}" bash -c 'source "$1"; show_usage' _ "$ROOT/lyrebird-mic-check.sh" 2>&1; }

# value of variables of the stream manager after sourcing it with nothing set
manager_vars() { env -i "PATH=$PATH" "HOME=$TEST_SCRATCH" bash -c 'source "$1"; shift; for v in "$@"; do printf "%s=%s\n" "$v" "${!v-}"; done' _ "$ROOT/lyrebird-stream-manager.sh" "$@"; }

# ---- structure -------------------------------------------------------------

@test "every page is well-formed, has one h1 and no skipped heading level, and every link, anchor and search entry resolves [DOC-02]" {
    run python3 -I "$TOOL" links "$PAGEDIR" "$DOCS" "$PAGES"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the anchors the cross-references rely on exist: status document, monitor, backoff, start outcome, configuration ownership [DOC-02]" {
    local bad=() want a page frag
    for want in monitoring#status-file monitoring#monitor monitoring#check-categories monitoring#prometheus monitoring#alerts \
        architecture#backoff architecture#ownership architecture#locking architecture#config-ownership \
        components#start-outcome components#storage components#updater components#alerts \
        configuration#mediamtx-config configuration#mediamtx configuration#env-vars configuration#quality-tiers; do
        page="${want%%#*}"
        frag="${want#*#}"
        jq -e --arg a "$frag" '.ids | index($a)' "$(pj "$page")" >/dev/null || bad+=("$page.html#$frag")
    done
    ((${#bad[@]} == 0)) || { printf 'missing anchor: %s\n' "${bad[@]}"; return 1; }
}

# ---- claims that were wrong and must not come back --------------------------

@test "no page claims a watchdog: every mention says there is none, or that a setting is ignored [DOC-02]" {
    local line bad=()
    while IFS= read -r line; do
        grep -qi 'watchdog' <<<"$line" || continue
        grep -qiE 'no software watchdog|there is no|has no|no watchdog|ignored|RuntimeWatchdogSec|neither implements|keep-alives' <<<"$line" \
            || bad+=("$line")
    done < <(all_prose)
    ((${#bad[@]} == 0)) || { printf 'unqualified watchdog claim: %s\n' "${bad[@]}"; return 1; }
    # and the unit really has none
    absent '^WatchdogSec=' "$ROOT/config/mediamtx-audio.service"
}

@test "the settings removed by the audit are documented as ignored, and recording is documented as RAM-only by default [DOC-02]" {
    local t
    t="$(page_text configuration)"
    local v
    for v in HEARTBEAT_INTERVAL HARDWARE_WATCHDOG_TIMEOUT ENABLE_HARDWARE_WATCHDOG AUDIO_DISK_PERSIST AUDIO_DISK_PATH LOCK_STALE_THRESHOLD; do
        [[ "$t" == *"$v"* ]] || { echo "configuration page does not mention $v"; return 1; }
    done
    [[ "$t" == *"ignores it"* || "$t" == *"ignored"* ]]
    [[ "$t" == *"RAM"* && "$t" == *"/dev/shm/lyrebird-buffer"* ]]
    # what the script does: one warning for each group
    grep -q 'AUDIO_DISK_PERSIST AUDIO_DISK_PATH' "$ROOT/lyrebird-stream-manager.sh"
    grep -q 'HEARTBEAT_INTERVAL HARDWARE_WATCHDOG_TIMEOUT' "$ROOT/lyrebird-stream-manager.sh"
}

@test "no page tells the reader to kill processes by name, and the recipes that replaced it exist [DOC-02]" {
    local code
    code="$(all_code)"
    absent '(^|[[:space:];&|])(pkill|killall)([[:space:]]|$)' <<<"$code"
    # prose may only mention them to warn
    local line bad=()
    while IFS= read -r line; do
        grep -qE 'pkill|killall' <<<"$line" || continue
        grep -qE 'Do not|do not|never|kill every|No pkill' <<<"$line" || bad+=("$line")
    done < <(all_prose)
    ((${#bad[@]} == 0)) || { printf 'pkill/killall without a warning: %s\n' "${bad[@]}"; return 1; }
    # the replacement is a real command with a preview
    help_of lyrebird-stream-manager.sh | grep -q 'force-stop --kill-all \[--yes\]'
    [[ "$(page_text troubleshooting)" == *"force-stop --kill-all"* ]]
    [[ "$(page_text advanced)" == *"force-stop --kill-all"* ]]
}

@test "no page asks the reader to delete a lock file, and the stream manager's lock files are never unlinked [DOC-02]" {
    local code
    code="$(all_code)"
    absent 'rm[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*[^|;&]*(\.lock|mediamtx-audio\.\*|mediamtx-audio\.\{)' <<<"$code"
    # the code side of the claim: no rm of a lock path in the manager's lifecycle code
    absent 'rm[[:space:]]+-f[^#]*(LOCK_FILE|\.lock)' "$ROOT/lyrebird-stream-manager.sh"
}

@test "mediamtx --check does not exist: the pages use --validate-conf, and say from which release [DOC-02]" {
    local code
    code="$(all_code)"
    absent 'mediamtx[[:space:]]+--check' <<<"$code"
    grep -q -- '--validate-conf=/etc/mediamtx/mediamtx.yml' <<<"$code"
    [[ "$(page_text configuration)" == *"1.21.1"* ]]
    # the installer and the manager use the same flag
    grep -q -- '--validate-conf' "$ROOT/install_mediamtx.sh"
    grep -q -- '--validate-conf' "$ROOT/lyrebird-stream-manager.sh"
}

@test "systemctl reload is documented where it works: the manager's unit has ExecReload, the standalone unit has none [DOC-02]" {
    grep -q '^ExecReload=.* reload$' "$ROOT/config/mediamtx-audio.service"
    absent '^ExecReload=' "$ROOT/config/mediamtx.service"
    help_of lyrebird-stream-manager.sh | grep -q '^    reload '
    [[ "$(page_text usage)" == *"systemctl reload mediamtx-audio"* ]]
    local line bad=()
    while IFS= read -r line; do
        [[ "$line" == *"systemctl reload mediamtx"* && "$line" != *"systemctl reload mediamtx-audio"* ]] || continue
        [[ "$line" == *"does nothing"* || "$line" == *"no ExecReload"* || "$line" == *"no <code>ExecReload"* ]] || bad+=("$line")
    done < <(all_prose)
    # the standalone case is stated in the troubleshooting and configuration pages
    [[ "$(page_text troubleshooting)" == *"has no ExecReload"* ]]
    [[ "$(page_text configuration)" == *"has no ExecReload"* ]]
    ((${#bad[@]} == 0)) || { printf 'reload claim: %s\n' "${bad[@]}"; return 1; }
}

@test "the installer's update is documented as a checksum-verified download, not as MediaMTX's own --upgrade [DOC-02]" {
    local t
    t="$(page_text components)"
    [[ "$t" != *"Built-in upgrade support"* && "$t" != *"built-in upgrade support"* ]]
    [[ "$t" == *"checksums.sha256"* && "$t" == *"--upgrade"* && "$t" == *"without any checksum check"* ]]
    # the installer says the same, and never runs --upgrade
    help_of install_mediamtx.sh | grep -q "MediaMTX's own --upgrade is not"
    absent '"\$\{?[A-Za-z_]*(BIN|INSTALL_DIR)[A-Za-z_}]*/?(mediamtx)?"? --upgrade' "$ROOT/install_mediamtx.sh"
    # --force: a mismatch is always fatal
    help_of install_mediamtx.sh | grep -q 'only when no checksum is available'
    [[ "$t" == *"only when no checksum is available"* && "$t" != *"skip verification"* ]]
}

@test "DEBUG=1 is not documented as a switch: the scripts compare DEBUG with true, and -d is the option [DOC-02]" {
    local code
    code="$(all_code)"
    absent 'DEBUG=1' <<<"$code"
    # what the code does: DEBUG=1 does nothing, DEBUG=true traces
    run "${CLEAN[@]}" DEBUG=1 bash "$ROOT/lyrebird-stream-manager.sh" help
    absent '^\+' <<<"$output"
    run "${CLEAN[@]}" DEBUG=true bash "$ROOT/lyrebird-stream-manager.sh" help
    grep -qE '^\+' <<<"$output"
    help_of lyrebird-stream-manager.sh | grep -q -- '-d, --debug'
    grep -qE 'lyrebird-stream-manager\.sh -d start' <<<"$code"
}

@test "no page names a variable or a log path the stream manager does not have [DOC-02]" {
    local t
    t="$(all_text)"
    # FFMPEG_LOG_DIR belongs to the orchestrator's log viewer, not to the stream manager
    [[ "$t" != *"FFMPEG_LOG_DIR"* ]]
    # FFmpeg's per-stream logs are in the state directory, where the manager writes them
    grep -q 'ffmpeg_log="${FFMPEG_PID_DIR}/${stream_path}.log"' "$ROOT/lyrebird-stream-manager.sh"
    absent '/var/log/lyrebird/(\*|<)' <<<"$t"
    [[ "$(page_text troubleshooting)" == *"/var/lib/mediamtx-ffmpeg/<stream>.log"* ]]
    # no page puts a DEFAULT_* line into audio-devices.conf (the parser rejects it)
    absent '^DEFAULT_[A-Z_]+=' <<<"$(all_code)"
}

@test "the recipes that were wrong are gone: audio-devices.conf.bak, git describe for production, journalctl for the manager's log [DOC-02]" {
    local code t
    code="$(all_code)"
    t="$(all_text)"
    absent 'audio-devices\.conf\.bak([^u]|$)' <<<"$code"
    absent 'git describe --tags --abbrev=0' <<<"$code"
    absent 'journalctl -u mediamtx-audio -f' <<<"$code"
    # the unit sends the manager's output to a file, which is where the pages send the reader
    grep -q '^StandardOutput=append:/var/log/lyrebird-stream-manager.log' "$ROOT/config/mediamtx-audio.service"
    [[ "$t" == *"No script creates an"* ]]
    # mic-check really makes .backup.<stamp> files
    grep -q 'CONFIG_FILE}.backup.' "$ROOT/lyrebird-mic-check.sh"
}

@test "the pages that discuss tags say v1.3.0 predates the fixes, and still agree with git while it is the newest tag [DOC-02]" {
    [[ "$(page_text quick-start)" == *"v1.3.0"* && "$(page_text advanced)" == *"v1.3.0"* ]]
    command -v git >/dev/null 2>&1 || skip "git is required"
    local newest
    newest="$(git -C "$ROOT" tag 2>/dev/null | sort -V | tail -n 1)"
    [[ -n "$newest" ]] || skip "this checkout has no tags"
    # when a release newer than v1.3.0 exists those sentences are out of date and must be rewritten
    [ "$newest" = "v1.3.0" ] || { echo "newest tag is $newest: update the v1.3.0 warnings in quick-start.html and advanced.html"; return 1; }
}

@test "the platform and Bash claims say what the suite runs on, and the unmeasured ones are gone [DOC-02]" {
    local t
    t="$(all_text)"
    [[ "$(page_text index)" == *"Bash 5.2"* && "$(page_text quick-start)" == *"Bash 5.2"* ]]
    [[ "$(page_text index)" == *"ARM"* && "$(page_text quick-start)" == *"ARM"* ]]
    [[ "$t" != *"Fully tested"* && "$t" != *"72 hours"* && "$t" != *"Max 2 USB mics"* && "$t" != *'$100'* ]]
    # what the scripts check for
    grep -q 'BASH_VERSINFO\[0\] < 4' "$ROOT/lyrebird-common.sh"
    grep -q 'bash 4.4+ required' "$ROOT/lyrebird-diagnostics.sh"
}

@test "nothing in the suite sends an alert by itself, and the pages say so [DOC-02]" {
    local f
    for f in "$ROOT"/*.sh "$ROOT"/config/*; do
        [[ "$f" == */lyrebird-alerts.sh ]] && continue
        absent 'lyrebird-alerts|send_alert|alert_(stream|device|disk|mediamtx|network|memory|cpu)_' "$f" || { echo "$f calls the alert script"; return 1; }
    done
    [[ "$(page_text components)" == *"no other LyreBirdAudio script"* ]]
    [[ "$(page_text monitoring)" == *"Nothing sends an alert unless you wire it up"* ]]
    [[ "$(page_text monitoring)" != *"What Events Trigger Alerts"* ]]
}

@test "alert_disk_warning is documented with the argument order the function has [DOC-02]" {
    awk '/^alert_disk_warning\(\)/{f=1} f&&/local /{print; n++} n==2{exit}' "$ROOT/lyrebird-alerts.sh" | head -1 | grep -q 'usage_percent'
    awk '/^alert_disk_warning\(\)/{f=1} f&&/local /{print; n++} n==2{exit}' "$ROOT/lyrebird-alerts.sh" | tail -1 | grep -q 'mount_point'
    grep -q 'alert_disk_warning "82%" "/"' <<<"$(all_code)"
    absent 'alert_disk_warning "/"' <<<"$(all_code)"
}

@test "WebRTC and HLS are not documented as served: the generated configuration switches them off, and the port table matches it [DOC-02]" {
    local cfg
    cfg="$("${CLEAN[@]}" bash -c 'source "$1"; lyrebird_render_mediamtx_config --mediamtx-version v1.21.3 --stream-name all_mics' _ "$ROOT/lyrebird-common.sh")"
    local k
    for k in 'apiAddress: 127.0.0.1:9997' 'metricsAddress: 127.0.0.1:9998' 'rtspAddress: :8554' 'webrtc: no' 'hls: no' 'rtmp: no' 'srt: no' 'moq: no'; do
        grep -qxF "$k" <<<"$cfg" || { echo "the generated configuration has no line '$k'"; return 1; }
    done
    [[ "$(all_text)" != *"8889"* ]]
    local rows
    rows="$(jq -r '.tables[] | select(.rows[0][0] == "Listener") | .rows[1:][] | join(" | ")' "$(pj configuration)")"
    grep -qE '^RTSP \| 8554 \| every interface' <<<"$rows"
    grep -qE '^MediaMTX control API \| 9997 \| this machine only' <<<"$rows"
    grep -qE '^MediaMTX metrics \| 9998 \| this machine only' <<<"$rows"
    absenti 'webrtc|hls' <<<"$rows"
}

# ---- documented commands run against the real scripts -----------------------

@test "every option of lyrebird-metrics.sh and lyrebird-mic-check.sh shown in a page exists, and the invented ones are gone [DOC-02]" {
    local code mh mu tok bad=()
    code="$(all_code)"
    mh="$(help_of lyrebird-metrics.sh)"
    mu="$(mic_usage)"
    while read -r tok; do
        [[ "$mh" == *"$tok"* ]] || bad+=("lyrebird-metrics.sh $tok")
    done < <(grep -E 'lyrebird-metrics\.sh' <<<"$code" | sed -E 's/.*lyrebird-metrics\.sh//; s/#.*//' | grep -oE '(^|[[:space:]])--?[a-z][a-z-]*' | tr -d ' ' | sort -u)
    while read -r tok; do
        [[ "$mu" == *"$tok"* ]] || bad+=("lyrebird-mic-check.sh $tok")
    done < <(grep -E 'lyrebird-mic-check\.sh' <<<"$code" | sed -E 's/.*lyrebird-mic-check\.sh//; s/#.*//' | grep -oE '(^|[[:space:]])--?[a-zA-Z][a-zA-Z-]*' | tr -d ' ' | sort -u)
    ((${#bad[@]} == 0)) || { printf 'not an option of the script: %s\n' "${bad[@]}"; return 1; }
    absent '--streams-only|--system-only' <<<"$code"
    absent 'mic-check\.sh .*--(dry-run|json)' <<<"$code"
    # at least one documented use of each, so the loops above cannot pass on nothing
    grep -qE 'lyrebird-metrics\.sh serve --port 9100' <<<"$code"
    grep -qE 'lyrebird-mic-check\.sh --format=json' <<<"$code"
    # the parsers reject the invented ones (this is what the old pages showed)
    run "${CLEAN[@]}" bash "$ROOT/lyrebird-metrics.sh" --streams-only
    [ "$status" -ne 0 ]
    run getopt -o 'hgfVq' --long 'help,version,generate-config,force,no-backup,quality:,validate,quiet,format:,list-backups,restore::' -n x -- --json
    [ "$status" -ne 0 ]
}

@test "the stream manager commands and options in the pages are the ones its --help lists, and every command is documented [DOC-02]" {
    local help cmds opts code tok bad=() c
    help="$(help_of lyrebird-stream-manager.sh)"
    cmds="$(sed -nE 's/^    (start|stop|force-stop|restart|reload|status|config|validate|monitor|install|help) .*/\1/p' <<<"$help" | sort -u | tr '\n' ' ')"
    [[ "$cmds" == "config force-stop help install monitor reload restart start status stop validate " ]] || { echo "unexpected command list: $cmds"; return 1; }
    for c in $cmds; do
        [[ "$c" == help ]] && continue
        [[ "$(page_text components)" == *"$c"* && "$(page_text usage)" == *"$c"* ]] || bad+=("command '$c' is not on both the components and the usage page")
    done
    code="$(all_code)"
    # documented invocations: skip the values of -m, -f and -n, take the first word as the command
    while read -r tok; do
        [[ " $cmds" == *" $tok "* ]] || bad+=("documented command '$tok' does not exist")
    done < <(grep -oE 'lyrebird-stream-manager\.sh( +-[mfn] +[A-Za-z_]+| +--[a-z-]+| +-d)* +[a-z][a-z-]*' <<<"$code" | awk '{print $NF}' | sort -u)
    while read -r tok; do
        [[ "$help" == *"$tok"* ]] || bad+=("documented option '$tok' is not in --help")
    done < <(grep -E 'lyrebird-stream-manager\.sh' <<<"$code" | sed -E 's/.*lyrebird-stream-manager\.sh//; s/#.*//' | grep -oE ' --?[a-z][a-z-]*' | tr -d ' ' | sort -u)
    ((${#bad[@]} == 0)) || { printf '%s\n' "${bad[@]}"; return 1; }
}

@test "every lyrebird-storage.sh invocation shown in a page runs, and the storage.conf example is accepted by the real parser [DOC-02]" {
    mkdir -p "$TEST_SCRATCH/rec" "$TEST_SCRATCH/log" "$TEST_SCRATCH/tmp" "$TEST_SCRATCH/buf"
    local store=(env -i "PATH=$PATH" "HOME=$TEST_SCRATCH" "LYREBIRD_STORAGE_CONFIG=" "LYREBIRD_RECORDING_DIR=$TEST_SCRATCH/rec"
        "LYREBIRD_LOG_DIR=$TEST_SCRATCH/log" "LYREBIRD_TEMP_DIR=$TEST_SCRATCH/tmp" "LYREBIRD_BUFFER_DIR=$TEST_SCRATCH/buf"
        "MEDIAMTX_LOG=$TEST_SCRATCH/mediamtx.out")
    local line args n=0 bad=()
    set -f # the arguments are split into words below and must not be expanded as patterns
    while IFS= read -r line; do
        args="${line#*lyrebird-storage.sh}"
        args="${args%%>*}"
        args="${args%%#*}"
        # shellcheck disable=SC2086  # the arguments are words of a documented command line
        "${store[@]}" bash "$ROOT/lyrebird-storage.sh" --dry-run $args >"$TEST_SCRATCH/out" 2>&1 || bad+=("lyrebird-storage.sh$args: $(head -c 120 "$TEST_SCRATCH/out" | tr '\n' ' ')")
        n=$((n + 1))
    done < <(all_code | grep -E 'lyrebird-storage\.sh +(-|status|cleanup|monitor|emergency)')
    set +f
    ((n >= 6)) || { echo "found only $n documented invocations"; return 1; }
    ((${#bad[@]} == 0)) || { printf '%s\n' "${bad[@]}"; return 1; }
    # the configuration example (a file of the kind the script reads) is accepted without a rejected line
    jq -re '.pre_by_id["example-storage-conf"]' "$(pj components)" >"$TEST_SCRATCH/storage.conf"
    chmod 644 "$TEST_SCRATCH/storage.conf"
    run "${store[@]}" "LYREBIRD_STORAGE_CONFIG=$TEST_SCRATCH/storage.conf" bash "$ROOT/lyrebird-storage.sh" status
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # and --interval, which the old pages showed, is refused
    run "${store[@]}" bash "$ROOT/lyrebird-storage.sh" monitor --interval 300
    [ "$status" -eq 1 ]
}

@test "the audio-devices.conf example passes the stream manager's own validate, with no warning [DOC-02]" {
    jq -re '.pre_by_id["example-audio-devices-conf"]' "$(pj configuration)" >"$TEST_SCRATCH/audio-devices.conf"
    run "${CLEAN[@]}" "MEDIAMTX_DEVICE_CONFIG=$TEST_SCRATCH/audio-devices.conf" bash "$ROOT/lyrebird-stream-manager.sh" validate
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"[WARN]"* && "$output" != *"[ERROR]"* ]]
    [[ "$output" == *"OK (8 setting(s))"* ]]
}

@test "the per-device settings table lists the settings the parser accepts, with the values it accepts [DOC-02]" {
    local f="$TEST_SCRATCH/bad.conf" out rows
    printf 'DEVICE_X_BOGUS=1\nDEVICE_X_SAMPLE_RATE=1\nDEVICE_X_CODEC=pcm\nDEVICE_X_CHANNELS=99\nDEVICE_X_BITRATE=x\nDEVICE_X_THREAD_QUEUE=0\nDEVICE_X_PCM=999\n' >"$f"
    run "${CLEAN[@]}" "MEDIAMTX_DEVICE_CONFIG=$f" bash "$ROOT/lyrebird-stream-manager.sh" validate
    out="$output"
    # the setting names
    local real doc
    real="$(sed -nE 's/.*SETTING one of ([A-Z_, ]+)\).*/\1/p' <<<"$out" | head -1 | tr -d ' ' | tr ',' '\n' | sort | tr '\n' ' ')"
    [ -n "$real" ]
    doc="$(jq -r '.tables[] | select(.rows[0][0] == "Setting") | .rows[1:][] | .[0]' "$(pj configuration)" | sort | tr '\n' ' ')"
    [ "$real" = "$doc" ] || { echo "parser: $real"; echo "page:   $doc"; return 1; }
    # the values: every value the parser lists for a setting is in the page's cell, and pcm is not among the codecs
    rows="$(jq -r '.tables[] | select(.rows[0][0] == "Setting") | .rows[1:][] | .[0] + "|" + .[1]' "$(pj configuration)")"
    local rates v
    rates="$(sed -nE 's/.*SAMPLE_RATE: unsupported value.*expected: one of ([0-9, ]+).*/\1/p' <<<"$out" | head -1)"
    [ -n "$rates" ]
    for v in ${rates//,/}; do
        grep -E '^SAMPLE_RATE\|' <<<"$rows" | grep -qE "(^|[ ,|])$v(,|$)" || { echo "SAMPLE_RATE $v is not in the page"; return 1; }
    done
    grep -E '^CODEC\|' <<<"$rows" | grep -q 'opus, aac, mp3'
    absenti 'pcm' <<<"$(grep -E '^CODEC\|' <<<"$rows")"
    grep -q "expected: one of opus, aac, mp3" <<<"$out"
    grep -E '^CHANNELS\|' <<<"$rows" | grep -q '1 to 32'
    grep -E '^THREAD_QUEUE\|' <<<"$rows" | grep -q '1 to 1048576'
    grep -E '^PCM\|' <<<"$rows" | grep -q '0 to 255'
    grep -E '^BITRATE\|' <<<"$rows" | grep -q '1k to 9999k'
    grep -q 'from 1 to 32' <<<"$out"
    grep -q 'from 1 to 1048576' <<<"$out"
    grep -q 'from 0 to 255' <<<"$out"
    grep -q 'from 1k to 9999k' <<<"$out"
}

@test "the defaults in the configuration page's environment tables are the values in the script [DOC-02]" {
    local rows name def real bad=() n=0 internal
    declare -A alias_of=([MEDIAMTX_BINARY]=MEDIAMTX_BIN [MEDIAMTX_CONFIG_DIR]=CONFIG_DIR [MEDIAMTX_CONFIG_FILE]=CONFIG_FILE
        [MEDIAMTX_DEVICE_CONFIG]=DEVICE_CONFIG_FILE [STREAM_MANAGER_LOG_FILE]=LOG_FILE [MEDIAMTX_PID_FILE]=PID_FILE
        [MEDIAMTX_LOCK_FILE]=LOCK_FILE [MEDIAMTX_FFMPEG_DIR]=FFMPEG_PID_DIR [LYREBIRD_STATE_DIR]=RUN_STATE_DIR
        [LYREBIRD_STATUS_FILE]=STATUS_FILE [LYREBIRD_FLOW_SAMPLE_SECONDS]=FLOW_SAMPLE_SECONDS)
    rows="$(jq -r '.tables[] | select(.h2 == "env-vars" and .rows[0][0] == "Variable") | .rows[1:][] | .[0] + "\t" + .[1]' "$(pj configuration)")"
    local names=() line
    while IFS=$'\t' read -r name def; do
        [[ -n "$name" ]] || continue
        names+=("${alias_of[$name]:-$name}")
    done <<<"$rows"
    ((${#names[@]} >= 60)) || { echo "found only ${#names[@]} documented variables"; return 1; }
    local values
    values="$(manager_vars "${names[@]}")"
    local help
    help="$(help_of lyrebird-stream-manager.sh)"
    while IFS=$'\t' read -r name def; do
        [[ -n "$name" ]] || continue
        internal="${alias_of[$name]:-$name}"
        n=$((n + 1))
        case "$name" in
            LYREBIRD_START_POLICY) [[ "$help" == *"[default: degraded]"* && "$def" == degraded ]] || bad+=("$name") ;;
            LYREBIRD_ALLOW_EMPTY_START) [[ "$help" == *"true (default)"* && "$def" == true ]] || bad+=("$name") ;;
            *)
                real="$(grep -m1 "^${internal}=" <<<"$values" | cut -d= -f2-)"
                [ "$real" = "$def" ] || bad+=("$name: page says '$def', script has '$real'")
                ;;
        esac
    done <<<"$rows"
    ((${#bad[@]} == 0)) || { printf '%s\n' "${bad[@]}"; return 1; }
    # every variable of the table that the script reads from the environment is documented where the script reads it
    local v
    for v in MEDIAMTX_RTSP_PORT MEDIAMTX_API_PORT MEDIAMTX_METRICS_PORT MEDIAMTX_API_BIND MEDIAMTX_METRICS_BIND RTSP_AUTH_MODE MEDIAMTX_CONFIG_BACKUPS LYREBIRD_FLOW_SAMPLE_SECONDS; do
        grep -q "^$v"$'\t' <<<"$rows" || { echo "$v is not in the table"; return 1; }
    done
}

# ---- tables that must equal what the scripts define -------------------------

@test "the version table is the VERSION of each script [DOC-02]" {
    local f label v doc bad=()
    for f in lyrebird-orchestrator lyrebird-stream-manager usb-audio-mapper lyrebird-mic-check lyrebird-diagnostics install_mediamtx \
        lyrebird-alerts lyrebird-metrics lyrebird-storage lyrebird-updater lyrebird-common; do
        if [ "$f" = lyrebird-common ]; then
            v="$(grep -m1 -E '^readonly LYREBIRD_COMMON_VERSION=' "$ROOT/$f.sh" | cut -d'"' -f2)"
        else
            v="$(grep -m1 -E '^readonly (SCRIPT_)?VERSION=' "$ROOT/$f.sh" | cut -d'"' -f2)"
        fi
        [ -n "$v" ] || { echo "no version in $f.sh"; return 1; }
        doc="$(jq -r --arg s "$f.sh" '.tables[] | select(.rows[0][0] == "Script") | .rows[1:][] | select(.[0] == $s) | .[1]' "$(pj components)")"
        [ "$doc" = "$v" ] || bad+=("$f.sh: page says '$doc', script says '$v'")
    done
    ((${#bad[@]} == 0)) || { printf '%s\n' "${bad[@]}"; return 1; }
}

@test "the exit-code table of every script lists the codes the script defines [DOC-02]" {
    local bad=() real doc h2 spec
    declare -A real_of=()
    local sm_help
    sm_help="$(help_of lyrebird-stream-manager.sh)"
    real_of[stream-manager]="$(awk '/^Exit Codes:/{f=1;next} /^FFmpeg logs:/{f=0} f' <<<"$sm_help" | grep -oE '^ +[0-9]+(\+N)?' | tr -d ' ' | sort | tr '\n' ' ')"
    real_of[metrics]="$(help_of lyrebird-metrics.sh | awk '/^Exit status:/{f=1;next} f&&/^$/{f=0} f' | grep -oE '^ +[0-9]+' | tr -d ' ' | sort | tr '\n' ' ')"
    real_of[storage]="$(help_of lyrebird-storage.sh | awk '/^Exit status:/{f=1;next} f&&/^$/{f=0} f' | grep -oE '^ {2}[0-9]+ ' | tr -d ' ' | sort | tr '\n' ' ')"
    real_of[usb-mapper]="$(help_of usb-audio-mapper.sh | sed -n '/^Exit status:/,/^$/p' | grep -oE '[0-9] [a-z]' | cut -c1 | sort | tr '\n' ' ')"
    real_of[diagnostics]="$(help_of lyrebird-diagnostics.sh | awk '/^EXIT CODES:/{f=1;next} /^$/{f=0} f' | grep -oE '^ {2}[0-9]+ ' | tr -d ' ' | sort | tr '\n' ' ')"
    real_of[mic-check]="$(mic_usage | awk '/^EXIT CODES:/{f=1;next} /^$/{f=0} f' | grep -oE '^ {2}[0-9]+ ' | tr -d ' ' | sort | tr '\n' ' ')"
    real_of[updater]="$(grep -oE '^readonly E_[A-Z_]+=[0-9]+' "$ROOT/lyrebird-updater.sh" | cut -d= -f2 | sort -n | tr '\n' ' ')"
    real_of[installer]="$( (echo 0; grep -E 'fatal "' "$ROOT/install_mediamtx.sh" | grep -oE '[0-9]+$') | sort -n | uniq | tr '\n' ' ')"
    real_of[orchestrator]="$( (echo 0; grep -oE '^readonly E_(GENERAL|PERMISSION|DEPENDENCY|SCRIPT_NOT_FOUND)=[0-9]+' "$ROOT/lyrebird-orchestrator.sh" | cut -d= -f2) | sort -n | tr '\n' ' ')"
    for h2 in stream-manager metrics storage usb-mapper diagnostics mic-check updater installer orchestrator; do
        real="$(tr ' ' '\n' <<<"${real_of[$h2]}" | sort -u | grep . | sort -V | tr '\n' ' ')"
        doc="$(table_firsts components "$h2" 'exit codes' | sort -V | tr '\n' ' ')"
        [ -n "$real" ] || { echo "could not read the codes of $h2 from the script"; return 1; }
        [ "$real" = "$doc" ] || bad+=("$h2: script '$real' / page '$doc'")
    done
    # lyrebird-alerts.sh's help lists 0, 3, 4 and 5; the page adds the general error 1 that its CLI also returns
    real="$(help_of lyrebird-alerts.sh | awk '/^EXIT STATUS/{f=1;next} /^$/{f=0} f' | grep -oE '^ {4}[0-9]+ ' | tr -d ' ' | sort | tr '\n' ' ')"
    doc="$(table_firsts components alerts 'exit codes' | sort | tr '\n' ' ')"
    [ "$real" = "0 3 4 5 " ] || bad+=("alerts help lists '$real'")
    [ "$doc" = "0 1 3 4 5 " ] || bad+=("alerts page lists '$doc'")
    ((${#bad[@]} == 0)) || { printf '%s\n' "${bad[@]}"; return 1; }
}

@test "the metric names in the pages are metrics lyrebird-metrics.sh emits [DOC-02]" {
    local emitted funcs name bad=() n=0
    emitted="$(grep -oE 'emit_metric "[a-z_0-9]+"' "$ROOT/lyrebird-metrics.sh" | sed -E 's/emit_metric "(.*)"/lyrebird_\1/' | sort -u)"
    funcs="$(grep -oE '^lyrebird_[a-z_]+\(\)' "$ROOT/lyrebird-common.sh" | tr -d '()')"
    while read -r name; do
        grep -qxF "$name" <<<"$funcs" && continue
        n=$((n + 1))
        if [[ "$name" == *_ ]]; then
            grep -q "^$name" <<<"$emitted" || bad+=("$name*")
        else
            grep -qxF "$name" <<<"$emitted" || bad+=("$name")
        fi
    done < <(all_text | grep -oE '(^|[^a-z_])lyrebird_[a-z0-9_]+' | sed -E 's/^[^l]//' | sort -u)
    ((n >= 20)) || { echo "found only $n metric names"; return 1; }
    ((${#bad[@]} == 0)) || { printf 'not emitted: %s\n' "${bad[@]}"; return 1; }
    # the heartbeat threshold is the exporter's default
    help_of lyrebird-metrics.sh | grep -q 'default: 900'
    [[ "$(page_text monitoring)" == *"900"* ]]
}

@test "the status document example has the keys status --json prints, and the documented jq recipe tells ok from not ok [DOC-02]" {
    local doc real_top real_stream
    jq -re '.pre_by_id["example-status-json"]' "$(pj monitoring)" >"$TEST_SCRATCH/example.json"
    jq -e . "$TEST_SCRATCH/example.json" >/dev/null
    run "${CLEAN[@]}" bash "$ROOT/lyrebird-stream-manager.sh" status --json
    [ "$status" -eq 0 ]
    real_top="$(jq -r 'keys_unsorted | sort | join(",")' <<<"$output")"
    doc="$(jq -r 'keys_unsorted | sort | join(",")' "$TEST_SCRATCH/example.json")"
    [ "$real_top" = "$doc" ] || { echo "top level: script '$real_top', page '$doc'"; return 1; }
    # the keys of one stream entry, from the code that prints it
    real_stream="$(grep -oE "printf '\{\"device\":%s[^']*'" "$ROOT/lyrebird-stream-manager.sh" | head -1 | grep -oE '"[a-z_]+":' | tr -d '":' | LC_ALL=C sort | tr '\n' ',')"
    doc="$(jq -r '.streams[0] | keys_unsorted | sort | join(",")' "$TEST_SCRATCH/example.json")"
    [ "${real_stream%,}" = "$doc" ] || { echo "stream entry: script '$real_stream', page '$doc'"; return 1; }
    # the recipe on the pages: a node that is stopped is not ok
    grep -q "jq -e '.overall == \"ok\"'" <<<"$(all_code)$(all_prose)"
    "${CLEAN[@]}" bash "$ROOT/lyrebird-stream-manager.sh" status --json | jq -e '.overall == "ok"' >/dev/null && return 1
    true
}

@test "the diagnostics modes are documented with the number of check groups each runs [DOC-02]" {
    local counts quick full debug
    counts="$(awk '/^    case "\$\{COMMAND\}" in/{f=1} f&&/^        quick\)/{m="quick"} f&&/^        debug\)/{m="debug"} f&&/^        full \| \*\)/{m="full"} f&&/^            check_/{c[m]++} END{print c["quick"], c["full"], c["debug"]}' "$ROOT/lyrebird-diagnostics.sh")"
    read -r quick full debug <<<"$counts"
    [[ "$quick" == 8 && "$full" == 25 && "$debug" == 24 ]] || { echo "the script runs $counts"; return 1; }
    local rows
    rows="$(jq -r '.tables[] | select(.rows[0][2] == "Check groups") | .rows[1:][] | .[0] + "|" + .[2]' "$(pj monitoring)")"
    grep -qE '^Quick\|8$' <<<"$rows"
    grep -qE '^Full .*\|25$' <<<"$rows"
    grep -qE '^Debug .*\|24, with log analysis$' <<<"$rows"
    [[ "$(page_text index)" == *"25 check groups"* && "$(page_text components)" == *"25 in"* ]]
    # no minute estimates, and no claim that section 7 looks at streams
    [[ "$(page_text monitoring)" != *"~10 seconds"* && "$(page_text monitoring)" != *"API accessibility"* ]]
    [[ "$(page_text monitoring)" == *"does not ask whether any stream is publishing"* ]]
    # the sections it names are the sections it prints
    local title
    for title in 'PREREQUISITES' 'USB AUDIO DEVICES' 'MEDIAMTX SERVICE' 'STREAM HEALTH' 'RTSP CONNECTIVITY' 'ENTROPY POOL' 'SERVICE DEPENDENCIES'; do
        grep -q "print_section \"[0-9a-z]*\. .*$title" "$ROOT/lyrebird-diagnostics.sh" || { echo "no section $title"; return 1; }
    done
}

@test "the wizard is documented with the four steps the orchestrator runs, and the menu table is its menu [DOC-02]" {
    local steps line n label bad=()
    steps="$(sed -n '/^menu_quick_setup()/,/Continue with quick setup/p' "$ROOT/lyrebird-orchestrator.sh" | grep -oE 'echo "  [0-9]\. [^"]+"' | sed -E 's/echo "  //; s/"$//')"
    [ "$(wc -l <<<"$steps")" -eq 4 ]
    local qs
    qs="$(jq -r '.prose[]' "$(pj quick-start)")"
    for want in 'Install MediaMTX' 'Map USB audio devices' 'Start audio streams' 'Run quick diagnostics'; do
        grep -qxF "$want" <<<"$qs" || bad+=("quick start has no step '$want'")
    done
    [[ "$steps" == *"Install/Update MediaMTX"* && "$steps" == *"Map USB audio devices"* && "$steps" == *"Start audio streaming"* && "$steps" == *"Run quick diagnostics"* ]]
    local t
    t="$(page_text quick-start)"
    [[ "$t" != *"Detect Hardware Capabilities"* && "$t" != *"Reboot Recommended"* ]]
    grep -qxF 'Generate Configuration' <<<"$qs" && bad+=("quick start still has a 'Generate Configuration' step")
    # the main menu: the usage page lists the options the orchestrator prints, with the same names
    while IFS= read -r line; do
        n="${line%%)*}"
        label="${line#*) }"
        jq -e --arg l "$n. $label" '.tables[] | select(.rows[0][0] == "Option") | .rows[1:][] | select(.[0] == $l)' "$(pj usage)" >/dev/null \
            || bad+=("usage table has no row '$n. $label'")
    done < <(sed -n '/^menu_main()/,/0) Exit/p' "$ROOT/lyrebird-orchestrator.sh" | grep -oE 'echo "  [1-7]\) [^"]+"' | sed -E 's/echo "  //; s/"$//')
    jq -e '.tables[] | select(.rows[0][0] == "Option") | .rows[] | select(.[0] | startswith("6.")) | select(.[1] | test("history"))' "$(pj usage)" >/dev/null \
        || bad+=("the Version Management row does not mention the update history")
    # and it never installs the unit or the cron job, as the callout says
    absent 'execute_script "stream_manager" +"?install' "$ROOT/lyrebird-orchestrator.sh"
    [[ "$(page_text components)" == *"does not install the systemd unit or the monitor cron job"* ]]
    ((${#bad[@]} == 0)) || { printf '%s\n' "${bad[@]}"; return 1; }
}

@test "the unit facts on the pages are the unit's: Restart=always, 10 starts in 20 minutes, Conflicts=, ExecReload, output to a file [DOC-02]" {
    local u="$ROOT/config/mediamtx-audio.service"
    grep -q '^Restart=always' "$u"
    grep -q '^StartLimitIntervalSec=1200' "$u"
    grep -q '^StartLimitBurst=10' "$u"
    grep -q '^Conflicts=mediamtx.service' "$u"
    local t
    t="$(page_text usage)"
    [[ "$t" == *"Restart=always"* && "$t" == *"10 starts in 20 minutes"* && "$t" == *"Conflicts=mediamtx.service"* ]]
    [[ "$t" == *"no watchdog"* ]]
    grep -qE '^ExecStart=.*stream-manager.sh start' "$u"
    # the cron job the pages describe is the one install writes
    local cron
    cron="$("${CLEAN[@]}" bash -c 'source "$1"; render_monitor_cron' _ "$ROOT/lyrebird-stream-manager.sh")"
    grep -q '^\*/5 \* \* \* \* root flock -n /run/mediamtx-monitor.lock' <<<"$cron"
    grep -q 'systemctl restart mediamtx-audio' <<<"$cron"
    [[ "$(page_text monitoring)" == *"every 5 minutes under"* && "$(page_text monitoring)" == *"2 restarts"* ]]
}

# ---- numbers the pages derive from the code ---------------------------------

@test "the exponential backoff on the architecture page is the sequence the wrapper's arithmetic gives [DOC-02]" {
    local vars initial max d seq=""
    vars="$(manager_vars INITIAL_RESTART_DELAY MAX_RESTART_DELAY MAX_CONSECUTIVE_FAILURES WRAPPER_SUCCESS_DURATION MAX_WRAPPER_RESTARTS)"
    initial="$(sed -n 's/^INITIAL_RESTART_DELAY=//p' <<<"$vars")"
    max="$(sed -n 's/^MAX_RESTART_DELAY=//p' <<<"$vars")"
    [[ "$initial" == 10 && "$max" == 300 ]]
    # the wrapper's rule, as in the generated script: double before each wait, never above the maximum
    grep -q 'RESTART_DELAY=$((RESTART_DELAY \* 2))' "$ROOT/lyrebird-stream-manager.sh"
    d="$initial"
    local i
    for i in 1 2 3 4 5; do
        if ((d <= 0 || d > max)); then d="$initial"; else d=$((d * 2)); ((d > max)) && d="$max"; fi
        seq+="After failure $i: wait ${d}s"$'\n'
    done
    local doc
    doc="$(jq -r '.code[]' "$(pj architecture)")"
    local line
    while IFS= read -r line; do
        grep -qF -- "${line%,*}" <<<"$doc" || { echo "the page does not show: $line"; return 1; }
    done <<<"$seq"
    [[ "$(page_text architecture)" != *"Attempt 1: Wait 10s"* ]]
    [[ "$vars" == *"MAX_CONSECUTIVE_FAILURES=5"* && "$vars" == *"WRAPPER_SUCCESS_DURATION=300"* && "$vars" == *"MAX_WRAPPER_RESTARTS=50"* ]]
}

@test "the quality tier table is what calculate_encoder_bitrate and determine_optimal_settings compute [DOC-02]" {
    local want got case_ rate ch tier expect cell
    # tier|rate|channels|bitrate the function must return, and the text the page must show for it
    for case_ in 'low|44100|1|96' 'low|44100|2|128' 'low|22050|1|64' 'low|22050|2|96' 'normal|48000|1|128' 'normal|48000|2|192' \
        'normal|96000|1|192' 'normal|96000|2|256' 'high|192000|1|192' 'high|192000|2|320' 'high|96000|1|160' 'high|96000|2|256' \
        'high|48000|1|128' 'high|48000|2|192'; do
        IFS='|' read -r tier rate ch expect <<<"$case_"
        got="$("${CLEAN[@]}" bash -c 'source "$1"; calculate_encoder_bitrate "$2" "$3" "$4"' _ "$ROOT/lyrebird-mic-check.sh" "$rate" "$ch" "$tier")"
        [ "$got" = "$expect" ] || { echo "$tier $rate Hz x $ch: the function returns $got, the test expects $expect"; return 1; }
    done
    local rows
    rows="$(jq -r '.tables[] | select(.rows[0][0] == "Tier") | .rows[1:][] | join(" | ")' "$(pj configuration)")"
    grep -qE '^low \| 44,100 Hz .* \| mono if offered \| 96k mono, 128k stereo \(64k and 96k below 44.1 kHz\)' <<<"$rows"
    grep -qE '^normal \| 48,000 Hz .* \| stereo if offered \| 128k mono, 192k stereo \(192k and 256k from 96 kHz\)' <<<"$rows"
    grep -qE '^high \| 192,000 Hz .* \| 192k mono, 320k stereo at 192 kHz; 160k / 256k at 96 kHz; 128k / 192k at 48 kHz' <<<"$rows"
    # the sample rate each tier prefers
    grep -q 'Prefer 44100 Hz if available' "$ROOT/lyrebird-mic-check.sh"
    grep -q 'Prefer 48000 Hz if available' "$ROOT/lyrebird-mic-check.sh"
    grep -q 'Prefer highest rate in 96-192 kHz range' "$ROOT/lyrebird-mic-check.sh"
}

@test "multiplex names and channel counts on the usage page are what the code does [DOC-02]" {
    local out w
    out="$("${CLEAN[@]}" bash -c 'source "$1"; canonical_stream_name "Studio Mix"; canonical_stream_name all 2>&1 || true' _ "$ROOT/lyrebird-stream-manager.sh")"
    [[ "$out" == studio_mix* ]]
    for w in control stats api metrics health all all_others; do
        [[ "$out" == *"$w"* ]] || { echo "the reserved list of the script lacks $w"; return 1; }
        [[ "$(page_text usage)" == *"$w"* ]] || { echo "the usage page lacks the reserved name $w"; return 1; }
    done
    [[ "$(page_text usage)" == *"Studio Mix"* && "$(page_text usage)" == *"studio_mix"* ]]
    run "${CLEAN[@]}" bash "$ROOT/lyrebird-stream-manager.sh" -m multiplex -n all validate
    [ "$status" -eq 4 ]
    # the channel counts: two stereo inputs merged are 4 channels, which libopus refuses; mixed they stay stereo
    command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 || skip "ffmpeg and ffprobe are required for the rest of this test"
    ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libopus || skip "this ffmpeg has no libopus"
    local in2=(-f lavfi -i anullsrc=cl=stereo:r=48000 -f lavfi -i anullsrc=cl=stereo:r=48000)
    ffmpeg -v error -y "${in2[@]}" -filter_complex '[0:a][1:a]amix=inputs=2:duration=longest,aresample=async=1:first_pts=0' -t 0.2 -c:a pcm_s16le "$TEST_SCRATCH/mix.wav"
    [ "$(ffprobe -v error -show_entries stream=channels -of csv=p=0 "$TEST_SCRATCH/mix.wav")" = 2 ]
    ffmpeg -v error -y "${in2[@]}" -filter_complex '[0:a][1:a]amerge=inputs=2' -t 0.2 -c:a pcm_s16le "$TEST_SCRATCH/merge.wav"
    [ "$(ffprobe -v error -show_entries stream=channels -of csv=p=0 "$TEST_SCRATCH/merge.wav")" = 4 ]
    run ffmpeg -v error -y "${in2[@]}" -filter_complex '[0:a][1:a]amerge=inputs=2' -t 0.2 -c:a libopus -b:a 128k -f null -
    [ "$status" -ne 0 ]
    [[ "$(page_text usage)" == *"refuses the 4 channels of two stereo microphones"* ]]
}

# ---- contributing page ------------------------------------------------------

@test "the development gates on the contributing page are the ones the CI workflow runs, and no per-file test counts are left to drift [DOC-02]" {
    local wf="$ROOT/.github/workflows/bash-ci.yml" t
    t="$(page_text contributing)"
    grep -q 'shfmt -d -i 4 -bn -ci' "$wf"
    grep -q -- '--severity=warning' "$wf"
    grep -q 'bashate --ignore E001,E006,E040,E042,E043' "$wf"
    [[ "$t" == *"shfmt -d -i 4 -bn -ci"* && "$t" == *"--severity=warning"* && "$t" == *"bashate --ignore E001,E006,E040,E042,E043"* ]]
    [[ "$t" == *"tests/check_tmp_leaks.sh"* ]]
    # no table of per-file test counts (they were all stale)
    [[ "$t" != *"Test File Tests What's Covered"* ]]
    absent 'test_[a-z_]+\.bats [0-9]+ ' <<<"$t"
    # the example test on the page is a real, passing test: it uses helpers that exist
    [ -f "$ROOT/tests/scratch_tmpdir.bash" ]
    grep -q '^lyrebird_atomic_write()' "$ROOT/lyrebird-common.sh"
    # and the header template carries no personal name
    absent 'Author: Tom|Copyright: Tom' <<<"$(jq -r '.code[]' "$(pj contributing)")"
}

#!/usr/bin/env bats
# Guard tests for what the documents say about a node: the settings `install` writes into the
# unit and the cron file, the log directories and their rotation, `lyrebird-mic-check.sh
# --restore` and `--help`, how MediaMTX and the stream wrappers are found, the port and
# directory variables, the executable bits, the installer's exit codes, the CI live steps and
# the library lookup by bare name (register: X-50 to X-60).
#
# Every test runs the real script, or reads the real source or workflow, for the claim the
# documents make, and also checks that the sentences the claim replaced are gone, so neither
# the claim nor the old text can drift unnoticed. Test names end with the tag of the register
# item they pin.
#
# LYREBIRD_DOCS_ROOT (default: the repository) is the tree the DOCUMENTS are read from, so a
# test can be run against an older copy of them to see it fail. Scripts, config files, the
# register and the workflows are always the repository's own.

load scratch_tmpdir

setup() {
    scratch_setup
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    DOCS="${LYREBIRD_DOCS_ROOT:-$ROOT}"
    README="$DOCS/README.md"
    CHANGELOG="$DOCS/CHANGELOG.md"
    GUIDE="$DOCS/docs/SECURITY-GUIDE.md"
    ADR="$DOCS/docs/ADR.md"
    CONTRIB="$DOCS/CONTRIBUTING.md"
    PAGES_DIR="$DOCS/docs"
    REGISTER="$ROOT/docs/remediation-status.json"
}

teardown() {
    scratch_teardown
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# html_text PAGE: the visible text of docs/PAGE.html on one line, tags dropped, entities decoded
html_text() {
    python3 -I - "$PAGES_DIR/$1.html" <<'PY'
import html.parser
import sys


class P(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.t = []
        self.skip = 0

    BLOCK = {"td", "th", "tr", "li", "p", "div", "pre", "br", "h1", "h2", "h3", "h4", "ul", "ol", "table"}

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self.skip += 1
        if tag in self.BLOCK:
            self.t.append(" ")

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self.skip -= 1
        if tag in self.BLOCK:
            self.t.append(" ")

    def handle_data(self, data):
        if not self.skip:
            self.t.append(data)


p = P()
p.feed(open(sys.argv[1], encoding="utf-8").read())
print(" ".join("".join(p.t).split()))
PY
}

# html_code PAGE: the lines of the <pre><code> blocks of docs/PAGE.html, unescaped
html_code() {
    python3 -I - "$PAGES_DIR/$1.html" <<'PY'
import html
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
for m in re.finditer(r"<pre[^>]*><code>(.*?)</code></pre>", text, re.S):
    print(html.unescape(m.group(1)))
PY
}

# md_code FILE: the lines inside fenced code blocks of a Markdown file
md_code() {
    awk '/^[[:space:]]*```/ { f = !f; next } f' "$1"
}

# flat FILE: a Markdown file on one line, runs of blanks squeezed
flat() {
    tr '\n' ' ' <"$1" | tr -s ' '
}

# text_of NAME: README, CHANGELOG, GUIDE, ADR, CONTRIB (flat) or a page name (visible text)
text_of() {
    case "$1" in
        README) flat "$README" ;;
        CHANGELOG) flat "$CHANGELOG" ;;
        GUIDE) flat "$GUIDE" ;;
        ADR) flat "$ADR" ;;
        CONTRIB) flat "$CONTRIB" ;;
        *) html_text "$1" ;;
    esac
}

# the documents and pages that speak about the node
ALL_DOCS="README CHANGELOG GUIDE ADR CONTRIB advanced architecture changelog components configuration contributing index monitoring quick-start security troubleshooting usage"

# said NAME PATTERN: succeeds when the text of the document has the extended regular expression
said() {
    text_of "$1" | grep -qE -- "$2"
}

# nowhere PATTERN [NAME...]: fails, naming the documents, when any of them (default: all) has the
# extended regular expression. (A bare `! grep` never fails a bats test.)
nowhere() {
    local pattern="$1" name found=0
    shift
    local -a names=("$@")
    [[ ${#names[@]} -gt 0 ]] || read -r -a names <<<"$ALL_DOCS"
    for name in "${names[@]}"; do
        if text_of "$name" | grep -qE -- "$pattern"; then
            echo "$name still says: $(text_of "$name" | grep -oE -- ".{0,60}${pattern}.{0,60}" | head -n 1)"
            found=1
        fi
    done
    [ "$found" -eq 0 ]
}

# carried_names: the nine settings the manager's install carries, as the manager defines them
carried_names() {
    bash -c 'source "$1/lyrebird-stream-manager.sh" >/dev/null 2>&1; printf "%s\n" "${UNIT_CARRIED_SETTINGS[@]}"' _ "$ROOT"
}

# scratch_install [NAME=value ...]: the stream manager's own `install` command, with the given settings in its
# environment (what `sudo env NAME=value ./lyrebird-stream-manager.sh install` does), writing under a scratch
# system root: a copy of the script, the library and the unit template; without root the copy skips the one
# root check. Sets $status and $output (run), SCRATCH_UNIT, SCRATCH_CRON and SCRATCH_LOGROTATE.
scratch_install() {
    local d="$TEST_SCRATCH/inst" root="$TEST_SCRATCH/sysroot" a sep=false
    local -a assigns=() options=()
    # words before "--" are NAME=value settings, words after it are options of the script (-m multiplex)
    for a in "$@"; do
        if [[ "$sep" == true ]]; then
            options+=("$a")
        elif [[ "$a" == -- ]]; then
            sep=true
        else
            assigns+=("$a")
        fi
    done
    rm -rf "$d" "$root"
    mkdir -p "$d/config" "$d/shim" "$root/etc/systemd/system" "$root/etc/cron.d" "$root/etc/logrotate.d" "$TEST_SCRATCH/cfg"
    cp "$ROOT/lyrebird-stream-manager.sh" "$ROOT/lyrebird-common.sh" "$d/"
    cp "$ROOT/config/mediamtx-audio.service" "$d/config/"
    if [[ "$EUID" -ne 0 ]]; then
        sed -i 's/if \[\[ \${EUID} -ne 0 \]\]; then/if false; then/' "$d/lyrebird-stream-manager.sh"
        grep -q 'if false; then' "$d/lyrebird-stream-manager.sh"
    fi
    printf '#!/bin/bash\ncase "$1" in is-active | is-enabled) exit 3 ;; *) exit 0 ;; esac\n' >"$d/shim/systemctl"
    printf '#!/bin/bash\nexit 0\n' >"$d/shim/logrotate"
    chmod +x "$d/lyrebird-stream-manager.sh" "$d/shim/systemctl" "$d/shim/logrotate"
    run env -u RTSP_AUTH_MODE -u RTSP_USERS_FILE -u MEDIAMTX_HOST -u MEDIAMTX_BINARY -u MEDIAMTX_RTSP_PORT -u MEDIAMTX_API_PORT \
        -u MEDIAMTX_METRICS_PORT -u MEDIAMTX_API_BIND -u MEDIAMTX_METRICS_BIND -u STREAM_MODE \
        MEDIAMTX_LOG_FILE="$TEST_SCRATCH/m.log" STREAM_MANAGER_LOG_FILE="$TEST_SCRATCH/sm.log" MEDIAMTX_CONFIG_DIR="$TEST_SCRATCH/cfg" \
        MEDIAMTX_FFMPEG_DIR="$TEST_SCRATCH/ff" MEDIAMTX_PID_FILE="$TEST_SCRATCH/m.pid" MEDIAMTX_LOCK_FILE="$TEST_SCRATCH/l.lock" \
        PATH="$d/shim:$PATH" LYREBIRD_SYSROOT="$root" ${assigns[@]+"${assigns[@]}"} bash "$d/lyrebird-stream-manager.sh" ${options[@]+"${options[@]}"} install </dev/null
    SCRATCH_UNIT="$root/etc/systemd/system/mediamtx-audio.service"
    SCRATCH_CRON="$root/etc/cron.d/mediamtx-monitor"
    SCRATCH_LOGROTATE="$root/etc/logrotate.d/mediamtx"
}

# ---------------------------------------------------------------------------
# X-58, X-52, X-59: what install carries into the unit and the cron file
# ---------------------------------------------------------------------------

@test "the nine settings install carries are the manager's list and the updater's, and every document that lists them names all nine [X-58, DOC-02]" {
    local names n doc updater
    names="$(carried_names)"
    [ "$(wc -l <<<"$names")" -eq 9 ] || { echo "the manager carries $(wc -l <<<"$names") settings: $names"; return 1; }
    # the updater passes the same nine, and the three stream-mode variables
    updater="$(sed -n '/^readonly INSTALL_SETTING_VARS=(/,/)$/p' "$ROOT/lyrebird-updater.sh" | sed 's/^readonly INSTALL_SETTING_VARS=(//' | tr -d ')' | tr -s ' \n' '\n\n' | grep -E '^[A-Z_]+$' | sort)"
    [ "$updater" = "$(printf '%s\n' "$names" STREAM_MODE MULTIPLEX_FILTER_TYPE MULTIPLEX_STREAM_NAME | sort)" ] || { echo "the updater passes: $updater"; return 1; }
    for doc in README CHANGELOG GUIDE configuration security; do
        for n in $names; do
            said "$doc" "$n" || { echo "$doc does not name $n"; return 1; }
        done
    done
    # ADR-018 names the three ports in its context and the other six where it says what install writes
    for n in $names; do
        grep -qF "$n" <<<"$(awk '/^## ADR-018:/ { on = 1; next } /^## ADR-/ { on = 0 } on' "$ADR")" || { echo "ADR-018 does not name $n"; return 1; }
    done
    for doc in README CHANGELOG GUIDE security configuration; do
        said "$doc" '(these|the) nine settings|nine settings|nine of them' || { echo "$doc does not say there are nine"; return 1; }
    done
}

@test "the install command the documents show writes the settings into the unit and the cron file, writes the defaults when given none, and exits 4 with nothing written for a value it cannot carry [X-58, DOC-02]" {
    # the command of the README, of the Upgrading steps of the CHANGELOG, and of the configuration page
    local cmd='sudo env RTSP_AUTH_MODE=local-only-publish MEDIAMTX_RTSP_PORT=31554 ./lyrebird-stream-manager.sh install'
    grep -qF "$cmd" "$README"
    grep -qF 'sudo env RTSP_AUTH_MODE=local-only-publish ./lyrebird-stream-manager.sh install' "$CHANGELOG"
    html_text configuration | grep -qF "$cmd"
    scratch_install RTSP_AUTH_MODE=local-only-publish MEDIAMTX_RTSP_PORT=31554
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qxF 'Environment="RTSP_AUTH_MODE=local-only-publish"' "$SCRATCH_UNIT"
    grep -qxF 'Environment="MEDIAMTX_RTSP_PORT=31554"' "$SCRATCH_UNIT"
    grep -qxF 'RTSP_AUTH_MODE=local-only-publish' "$SCRATCH_CRON"
    grep -qxF 'MEDIAMTX_RTSP_PORT=31554' "$SCRATCH_CRON"
    # a setting at its default is not written, and with none given neither file has one
    scratch_install MEDIAMTX_RTSP_PORT=8554 RTSP_AUTH_MODE=open
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    ! grep -qE 'RTSP_PORT|RTSP_AUTH_MODE' "$SCRATCH_UNIT" "$SCRATCH_CRON" || { echo "a default was written"; return 1; }
    # a value the files cannot carry: exit 4, and nothing is written
    scratch_install RTSP_AUTH_MODE=everyone
    [ "$status" -eq 4 ]
    [ ! -e "$SCRATCH_UNIT" ] && [ ! -e "$SCRATCH_CRON" ]
    scratch_install MEDIAMTX_BINARY='/opt/my mediamtx'
    [ "$status" -eq 4 ]
    [ ! -e "$SCRATCH_UNIT" ] && [ ! -e "$SCRATCH_CRON" ]
    local doc
    for doc in README CHANGELOG configuration; do
        said "$doc" 'exit 4' || { echo "$doc does not say exit 4"; return 1; }
        said "$doc" 'writes what it is given' || { echo "$doc does not say install writes what it is given"; return 1; }
    done
    # the Upgrading steps tell a node installed before this change to run install with its settings
    said CHANGELOG 'run `install` once with the ones the node uses' || return 1
    said CHANGELOG 'again with them exported' || return 1
    said README 'a node installed before this release has none of the nine' || return 1
}

@test "the documents say install does not carry the path variables or the audio settings, and the unit's PIDFile= and StandardOutput= follow the paths the service never gets [X-59, DOC-02]" {
    scratch_install "MEDIAMTX_PID_FILE=$TEST_SCRATCH/x.pid" "STREAM_MANAGER_LOG_FILE=$TEST_SCRATCH/x.log" AUDIO_LOCAL_RECORDING=true \
        LYREBIRD_START_POLICY=strict "MEDIAMTX_FFMPEG_DIR=$TEST_SCRATCH/ffx"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # the unit names the files of the shell that ran install ...
    grep -qxF "PIDFile=$TEST_SCRATCH/x.pid" "$SCRATCH_UNIT"
    grep -qxF "StandardOutput=append:$TEST_SCRATCH/x.log" "$SCRATCH_UNIT"
    # ... and neither file gives the service or the monitor the variables
    ! grep -qE 'MEDIAMTX_PID_FILE|STREAM_MANAGER_LOG_FILE|AUDIO_LOCAL_RECORDING|LYREBIRD_START_POLICY|MEDIAMTX_FFMPEG_DIR' "$SCRATCH_UNIT" "$SCRATCH_CRON" || {
        echo "a path or audio variable is carried"
        return 1
    }
    local doc
    for doc in README CHANGELOG configuration ADR; do
        said "$doc" 'PIDFile=' || { echo "$doc does not name PIDFile="; return 1; }
        said "$doc" 'StandardOutput=append:' || { echo "$doc does not name StandardOutput=append:"; return 1; }
    done
    said CHANGELOG '`wontfix` in `docs/remediation-status.json`' || return 1
    # the register records it as a decision, not a fix
    [ "$(python3 -I -c 'import json,sys; print({i["id"]: i["status"] for i in json.load(open(sys.argv[1]))["items"]}["X-59"])' "$REGISTER")" = "wontfix" ]
}

@test "no document says any more that the unit and the cron file carry no port or authentication variable [X-58, DOC-02]" {
    nowhere 'unit and the cron file do not carry them' CHANGELOG
    nowhere '[Ii]nstall. writes no port settings' CHANGELOG
    nowhere 'writes no port variable' ADR
    nowhere 'are not written into either file' README
    nowhere 'writes only .STREAM_MODE., .MULTIPLEX_FILTER_TYPE. and .MULTIPLEX_STREAM_NAME. into the unit' README
    nowhere 'do \*\*not\*\* carry this variable' GUIDE
    nowhere 'Neither the unit nor the cron file carries it' security
    nowhere 'carry no port, even when you run' configuration
    nowhere 'but not the port variables' configuration
    nowhere 'Non-default ports must be set in both places' configuration
    nowhere 'repeat (step 6|the second command|the sed command)' CHANGELOG GUIDE security
}

@test "the updater's reinstall is documented as keeping the stream mode and the settings, as the updater does, and a plain install as not [X-52, DOC-02]" {
    grep -q 'read_installed_service_settings' "$ROOT/lyrebird-updater.sh"
    grep -qE 'run_unlocked env .*SERVICE_INSTALL_ENV.* install' "$ROOT/lyrebird-updater.sh"
    said README 'so a multiplex node stays multiplex' || return 1
    said README "does not read the files it replaces" || return 1
    said CHANGELOG 'A service reinstall keeps the node as it is' || return 1
    said GUIDE "service reinstall reads them from the installed unit" || return 1
    said security "service reinstall reads them from the installed unit" || return 1
    nowhere 'That .install. is run without .-m., .-f. and .-n., so on a multiplex node run it again by hand' README
    # install itself does not read what it replaces: a plain install after a multiplex one is the individual mode again
    scratch_install -- -m multiplex
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qxF 'STREAM_MODE=multiplex' "$SCRATCH_CRON"
    scratch_install
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qxF 'STREAM_MODE=individual' "$SCRATCH_CRON"
}

# ---------------------------------------------------------------------------
# X-51: FFmpeg logs, and one logrotate owner per log
# ---------------------------------------------------------------------------

@test "the FFmpeg logs are where the manager writes them in every script and page that shows them, and the two logrotate files share no log [X-51, DOC-02]" {
    # the scripts: the manager's directory is the default of the diagnostics and of the orchestrator, and only they read FFMPEG_LOG_DIR
    grep -qF 'FFMPEG_LOG_DIR:-${MEDIAMTX_FFMPEG_DIR' "$ROOT/lyrebird-diagnostics.sh"
    grep -qF 'FFMPEG_LOG_DIR:-${MEDIAMTX_FFMPEG_DIR' "$ROOT/lyrebird-orchestrator.sh"
    ! grep -q 'FFMPEG_LOG_DIR' "$ROOT/lyrebird-stream-manager.sh"
    # the shipped logrotate file lists none of the logs install's file lists, and the logs the documents give it
    local shipped installed log
    shipped="$(grep -vE '^[[:space:]]*#' "$ROOT/config/lyrebird-logrotate.conf")"
    for log in /var/log/mediamtx.out /var/log/lyrebird-stream-manager.log /var/lib/mediamtx-ffmpeg; do
        ! grep -qF "$log" <<<"$shipped" || { echo "the shipped logrotate file lists $log"; return 1; }
    done
    for log in '/var/log/lyrebird/*.log' /var/log/lyrebird-orchestrator.log /var/log/lyrebird-updater.log /var/log/lyrebird-diagnostics.log /var/log/usb-audio-mapper.log; do
        grep -qxF "$log" <<<"$(sed -E 's/[[:space:]]*\{.*$//' <<<"$shipped")" || { echo "the shipped logrotate file does not list $log"; return 1; }
    done
    scratch_install
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    installed="$(sed -n -E 's/^(\/[^ ]+) \{$/\1/p' "$SCRATCH_LOGROTATE")"
    [ "$(wc -l <<<"$installed")" -eq 3 ]
    for log in "$TEST_SCRATCH/m.log" "$TEST_SCRATCH/sm.log" "$TEST_SCRATCH/ff/*.log"; do
        grep -qxF "$log" <<<"$installed" || { echo "install's logrotate file does not list $log"; return 1; }
    done
    # the documents give each log its one owner
    said README 'lists none of the three logs above' || return 1
    said README '/var/log/lyrebird/\*.log' || return 1
    said monitoring 'lists none of the logs of the first file' || return 1
    said security 'lists none of the logs of the first file' || return 1
    said GUIDE 'lists none of the logs of the first file' || return 1
    said CHANGELOG 'each log rotated once' || return 1
    # and the earlier statements are gone: a shipped FFmpeg stanza, "the same logs", "install one of the two, not both"
    nowhere 'FFmpeg stanza' README
    nowhere 'lists the same (MediaMTX and manager )?(two )?logs' GUIDE monitoring security
    nowhere 'install one of the two, not both' monitoring
    nowhere '[Dd]o (\*\*)?not(\*\*)? (also )?install (it|config/lyrebird-logrotate.conf)' GUIDE security
    nowhere 'default .?/var/log/lyrebird.?\)' README
    nowhere 'is not where the stream manager writes the FFmpeg logs' README
    nowhere 'looks in .?/var/log/lyrebird.?, while the manager' README
}

# ---------------------------------------------------------------------------
# X-53: lyrebird-mic-check.sh --restore and --help
# ---------------------------------------------------------------------------

@test "mic-check takes --restore TIMESTAMP, --restore=TIMESTAMP and a bare --restore, and --help needs no /proc/asound, as the documents say [X-53, DOC-02]" {
    local form
    for form in '--restore 20251111_123456' '--restore=20251111_123456'; do
        run bash -c 'source "$1/lyrebird-mic-check.sh" >/dev/null 2>&1; set +e; shift; parse_arguments "$@"; echo "rc=$? restore=$MODE_RESTORE timestamp=[$RESTORE_TIMESTAMP]"' _ "$ROOT" ${form}
        [ "$output" = "rc=0 restore=true timestamp=[20251111_123456]" ] || { echo "$form: $output"; return 1; }
    done
    run bash -c 'source "$1/lyrebird-mic-check.sh" >/dev/null 2>&1; set +e; shift; parse_arguments "$@"; echo "rc=$? restore=$MODE_RESTORE timestamp=[$RESTORE_TIMESTAMP]"' _ "$ROOT" --restore
    [ "$output" = "rc=0 restore=true timestamp=[]" ]
    # a machine without /proc/asound: --help and --version exit 0
    run bash -c 'source "$1/lyrebird-mic-check.sh" >/dev/null 2>&1; alsa_proc_available() { return 1; }; main --help' _ "$ROOT"
    [ "$status" -eq 0 ]
    run bash -c 'source "$1/lyrebird-mic-check.sh" >/dev/null 2>&1; alsa_proc_available() { return 1; }; main --version' _ "$ROOT"
    [ "$status" -eq 0 ]
    local doc
    for doc in README components; do
        said "$doc" '--restore \[?TIMESTAMP\]?|--restore <timestamp>' || { echo "$doc does not show --restore with a timestamp"; return 1; }
    done
    said README '--restore=20251111_123456' || return 1
    said README '`--help` and `--version` do not look at the hardware and exit 0 there' || return 1
    said components '--help</code> and <code>--version</code> need no|--help and --version need no' || return 1
    nowhere 'timestamp must be attached with' README
    nowhere 'exits 1 on a machine without .?/proc/asound.? \(even for' README
    nowhere 'restore one \(interactively, or the one with that timestamp\)' components
}

# ---------------------------------------------------------------------------
# X-54, X-55: finding MediaMTX and the wrappers, and the port and directory variables
# ---------------------------------------------------------------------------

@test "the orchestrator and the diagnostics find MediaMTX by identity, and the variables the documents give them are the ones they read [X-54, X-55, DOC-02]" {
    grep -q '^lyrebird_mediamtx_pids()' "$ROOT/lyrebird-common.sh"
    grep -q '^lyrebird_stream_wrapper_pids()' "$ROOT/lyrebird-common.sh"
    grep -q 'lyrebird_mediamtx_pids' "$ROOT/lyrebird-orchestrator.sh"
    grep -q 'lyrebird_stream_wrapper_pids' "$ROOT/lyrebird-orchestrator.sh"
    grep -q 'lyrebird_mediamtx_pids' "$ROOT/lyrebird-diagnostics.sh"
    # the orchestrator runs no pgrep, pkill or killall
    ! grep -vE '^[[:space:]]*#' "$ROOT/lyrebird-orchestrator.sh" | grep -qE '\b(pgrep|pkill|killall)\b' || { echo "the orchestrator runs a name-based process tool"; return 1; }
    # the variables: the diagnostics read the RTSP port from MEDIAMTX_RTSP_PORT, the exporter the directory from MEDIAMTX_FFMPEG_DIR,
    # and the orchestrator prints the RTSP port from MEDIAMTX_RTSP_PORT
    grep -qF 'MEDIAMTX_PORT="${MEDIAMTX_RTSP_PORT:-${MEDIAMTX_PORT:-8554}}"' "$ROOT/lyrebird-diagnostics.sh"
    grep -qF 'FFMPEG_PID_DIR="${MEDIAMTX_FFMPEG_DIR:-${FFMPEG_PID_DIR:-/var/lib/mediamtx-ffmpeg}}"' "$ROOT/lyrebird-metrics.sh"
    grep -qF 'port="${MEDIAMTX_RTSP_PORT:-8554}"' "$ROOT/lyrebird-orchestrator.sh"
    said README '`MEDIAMTX_RTSP_PORT` \(default 8554\), the variable the other scripts use' || return 1
    said README '`MEDIAMTX_FFMPEG_DIR` \(the manager.s directory of PID files and wrappers; `FFMPEG_PID_DIR` is the fallback\)' || return 1
    said README 'the orchestrator needs no `pgrep`' || return 1
    said components 'MEDIAMTX_RTSP_PORT' || return 1
    said monitoring 'MEDIAMTX_RTSP_PORT' || return 1
    said CHANGELOG '`lyrebird_mediamtx_pids` and `lyrebird_stream_wrapper_pids`' || return 1
    said ADR '`lyrebird_mediamtx_pids` and `lyrebird_stream_wrapper_pids`' || return 1
    nowhere 'not `MEDIAMTX_RTSP_PORT`|ignores .?MEDIAMTX_RTSP_PORT|do not read `MEDIAMTX_RTSP_PORT`' README components monitoring
    nowhere 'The exporter reads `FFMPEG_PID_DIR` while' README
    nowhere 'binary path against every command line' monitoring
    nowhere 'come from a process-name scan' README
    nowhere 'every .ffmpeg. on the host counts as a stream' README
    nowhere 'prints port 8554 whatever' README CHANGELOG
    nowhere 'finds MediaMTX by name' CHANGELOG
}

# ---------------------------------------------------------------------------
# X-56: executable bits
# ---------------------------------------------------------------------------

@test "every script is committed executable, and no document asks for chmod +x after a clone of main [X-56, DOC-02]" {
    git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || skip "not a git checkout"
    [ "$(git -C "$ROOT" ls-files -s -- '*.sh' | awk '$1 == "100644"' | wc -l)" -eq 0 ]
    local page
    # no fenced block of the Markdown documents, and no code block of a page, runs chmod +x on the scripts
    for page in "$README" "$CONTRIB"; do
        ! md_code "$page" | grep -qE '^[[:space:]]*chmod \+x( \./)?\*\.sh' || { echo "$page asks for chmod +x in a code block"; return 1; }
    done
    for page in advanced architecture contributing index quick-start usage; do
        ! html_code "$page" | grep -qE '^[[:space:]]*chmod \+x( \./)?\*\.sh' || { echo "docs/$page.html asks for chmod +x in a code block"; return 1; }
    done
    # the one place it is still right: the tag made before the change
    git -C "$ROOT" rev-parse -q --verify 'refs/tags/v1.3.0^{commit}' >/dev/null 2>&1 || skip "tag v1.3.0 is not in this clone"
    [ "$(git -C "$ROOT" ls-tree v1.3.0 | awk '$1 == "100644" && $4 ~ /[.]sh$/' | wc -l)" -eq 7 ]
    said README 'seven of its scripts are mode 100644' || return 1
    said CHANGELOG 'seven of the eleven in v1.3.0' || return 1
    said advanced 'seven of its scripts are mode 100644' || return 1
    said quick-start 'seven of its scripts are mode 100644' || return 1
    nowhere 'The scripts need to be executable after a clone' README
    nowhere 'the repository does not store the executable bit' README
    nowhere 'git clone, chmod \+x, run|clone, .?chmod \+x.?, run' README architecture
}

# ---------------------------------------------------------------------------
# X-57: installer exit codes
# ---------------------------------------------------------------------------

@test "the installer's --help lists exit codes 0 to 11, and the documents list 11 and say what 7 is left meaning [X-57, DOC-02]" {
    local help codes
    help="$(bash "$ROOT/install_mediamtx.sh" --help 2>&1)"
    codes="$(awk '/^EXIT CODES:/ { on = 1; next } on && /^[A-Z]+:/ { on = 0 } on' <<<"$help" | sed -nE 's/^ +([0-9]+) +[A-Za-z].*/\1/p' | tr '\n' ' ')"
    [ "$codes" = "0 1 2 3 4 5 6 7 8 9 10 11 " ] || { echo "codes in --help: $codes"; return 1; }
    grep -qF 'MediaMTX binary could not be put in place' <<<"$help"
    said README '11 the binary could not be put in place' || return 1
    html_text components | grep -qE '11 The binary could not be put in place' || { echo "components.html has no row for exit 11"; return 1; }
    said CHANGELOG 'Exit 11 is the binary steps' || return 1
    said CHANGELOG 'exit 11' || return 1
    # the orchestrator explains 11, and no longer says 7 can be a failed install step
    grep -q 'installer exit code: 11' "$ROOT/lyrebird-orchestrator.sh"
    ! grep -qE 'exited with code 7.*(failed|step)' "$ROOT/lyrebird-orchestrator.sh" || { echo "the orchestrator still says 7 can be a failed step"; return 1; }
    nowhere 'a step of the install or update failed' README
    nowhere 'or an install or update step failed \(including a rollback\)' components
    nowhere 'for some failed install steps' CHANGELOG
}

# ---------------------------------------------------------------------------
# X-60: the CI live steps
# ---------------------------------------------------------------------------

@test "the live test files the CI workflow runs are the ones the README command and the CHANGELOG name [X-60, DOC-02]" {
    local ci f name missing=0
    # the files of the live step: every tests/*.bats named between its "Run live tests for one MediaMTX version" and the next step
    ci="$(awk '/- name: Run live tests for one MediaMTX version/ { on = 1; next } on && /^      - name:/ { exit } on' "$ROOT/.github/workflows/bash-ci.yml" | grep -oE 'tests/test_[a-z0-9_]+\.bats' | sort -u)"
    [ "$(wc -l <<<"$ci")" -ge 9 ] || { echo "the live step names: $ci"; return 1; }
    for f in $ci; do
        grep -qF "$f" "$README" || { echo "the README does not name $f in its live command"; missing=1; }
        name="${f#tests/}"
        name="${name%.bats}"
        grep -qF "\`${name}\`" <<<"$(flat "$CONTRIB")" || { echo "CONTRIBUTING does not name \`$name\`"; missing=1; }
    done
    [ "$missing" -eq 0 ]
    for f in test_stream_names test_docs_security; do
        grep -qF "$f" <<<"$ci" || { echo "CI does not run $f live"; return 1; }
        said CHANGELOG "tests/$f.bats" || { echo "CHANGELOG does not name $f"; return 1; }
    done
    said CHANGELOG 'once per pinned MediaMTX version' || return 1
}

# ---------------------------------------------------------------------------
# X-50: a script started by its bare name
# ---------------------------------------------------------------------------

@test "a script started by its bare name finds lyrebird-common.sh and still verifies the library hash, as the documents say [X-50, DOC-02]" {
    local hash
    run bash -c 'cd "$1" && env -i PATH="$PATH" HOME="$2" STREAM_MANAGER_LOG_FILE="$2/sm.log" LYREBIRD_STATE_DIR="$2/state" bash lyrebird-stream-manager.sh help' _ "$ROOT" "$TEST_SCRATCH"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "MediaMTX Stream Manager v"* ]]
    run bash -c 'cd "$1" && env -i PATH="$PATH" HOME="$2" STREAM_MANAGER_LOG_FILE="$2/sm.log" LYREBIRD_STATE_DIR="$2/state" LYREBIRD_COMMON_EXPECTED_HASH=0000 bash lyrebird-stream-manager.sh status' _ "$ROOT" "$TEST_SCRATCH"
    [ "$status" -ne 0 ]
    [[ "$output" == *"may have been tampered with"* ]]
    hash="$(sha256sum "$ROOT/lyrebird-common.sh" | cut -d' ' -f1)"
    run bash -c 'cd "$1" && env -i PATH="$PATH" HOME="$2" STREAM_MANAGER_LOG_FILE="$2/sm.log" LYREBIRD_STATE_DIR="$2/state" LYREBIRD_COMMON_EXPECTED_HASH="$3" bash lyrebird-stream-manager.sh help' _ "$ROOT" "$TEST_SCRATCH" "$hash"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    said GUIDE 'started by its bare name from its own directory' || return 1
    said security 'started by its bare name from its own directory' || return 1
    said CHANGELOG 'A script started by its bare name could not find' || return 1
    nowhere 'it does not find the library at all' GUIDE security
    nowhere 'Run the script as .?\./lyrebird-stream-manager.sh.? \(or' GUIDE security
}

# ---------------------------------------------------------------------------
# X-61 to X-64: --version, the updater's help, Bash 4.3, the soak observer's header
# ---------------------------------------------------------------------------

@test "the stream manager and the alerts script print their version, the updater answers --help and --version first, and the documents say so [X-61, X-62, DOC-02]" {
    local version
    version="$(grep -m1 -E '^readonly VERSION=' "$ROOT/lyrebird-stream-manager.sh" | sed -E 's/.*"([^"]*)".*/\1/')"
    run env -i PATH="$PATH" HOME="$TEST_SCRATCH" STREAM_MANAGER_LOG_FILE="$TEST_SCRATCH/sm.log" bash "$ROOT/lyrebird-stream-manager.sh" --version
    [ "$status" -eq 0 ]
    [ "$output" = "lyrebird-stream-manager.sh version $version" ]
    run env -i PATH="$PATH" HOME="$TEST_SCRATCH" STREAM_MANAGER_LOG_FILE="$TEST_SCRATCH/sm.log" bash "$ROOT/lyrebird-stream-manager.sh" -V
    [ "$status" -eq 0 ]
    local flag
    for flag in --version -V version; do
        run env -i PATH="$PATH" HOME="$TEST_SCRATCH" bash "$ROOT/lyrebird-alerts.sh" "$flag"
        [ "$status" -eq 0 ] || { echo "alerts $flag: $output"; return 1; }
        [[ "$output" == *"version $(grep -m1 -E '^readonly SCRIPT_VERSION=' "$ROOT/lyrebird-alerts.sh" | sed -E 's/.*"([^"]*)".*/\1/')" ]]
    done
    # the updater answers for a sudo user without a terminal: no root confirmation (it ended in "Cancelled by user", exit 9)
    run env -i PATH="$PATH" HOME="$TEST_SCRATCH" SUDO_USER=somebody bash "$ROOT/lyrebird-updater.sh" --version </dev/null
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "LyreBirdAudio Version Manager v"* ]]
    said README '`-V, --version` \(prints the script.s name and version, exit 0\)' || return 1
    said README './lyrebird-alerts.sh version' || return 1
    said README '`--help` and `--version` answer at once, without the confirmation' || return 1
    said README 'Every command except `--history`, `--help` and `--version` takes a kernel `flock`' || return 1
    html_text components | grep -qE -- '-V, --version Print the script.s name and version and exit 0' || { echo "components.html lists no --version for the stream manager"; return 1; }
    said components 'lyrebird-alerts.sh version' || return 1
    said CHANGELOG '`--version` and `-V`\*\* for `lyrebird-stream-manager.sh` and `lyrebird-alerts.sh`' || return 1
    said CHANGELOG 'lyrebird-updater.sh --help` and `--version` did not answer first' || return 1
    said CONTRIB 'lyrebird-stream-manager.sh --version' || return 1
    nowhere 'lyrebird-stream-manager.sh help \| head -n 1' CONTRIB
}

@test "no script needs Bash 4.3, the README's table and the ADR say so, and the soak observer's header and README claim only what was run [X-63, X-64, DOC-02]" {
    ! grep -nE '\$\{[A-Za-z_][A-Za-z_0-9]*\[-[0-9]+\]\}' "$ROOT"/*.sh "$ROOT"/tools/soak/*.sh || { echo "a script has a negative array subscript"; return 1; }
    said README '`lyrebird-mic-check.sh` \| none \| 4.2 \(`declare -g`\)' || return 1
    said README '`tests/test_bash_features.bats` keeps every script free of features newer than 4.2' || return 1
    said ADR '`tests/test_bash_features.bats`' || return 1
    said CONTRIB '`tests/test_bash_features.bats` keeps every script' || return 1
    [ -f "$ROOT/tests/test_bash_features.bats" ]
    nowhere 'uses .\$\{array\[-1\]\}., which needs Bash 4.3' ADR
    nowhere '4\.3 \(`\$\{array\[-1\]\}`\)' README
    nowhere 'names one\)' CONTRIB
    # the observer: the header says what was run, and so does the README that quotes it
    local head
    head="$(sed -n 1,12p "$ROOT/tools/soak/lyrebird-soak-observer.sh")"
    [[ "$head" != *"Linux or macOS"* && "$head" != *"bash 3.2 or later"* && "$head" == *"never run on macOS"* ]]
    local soak
    soak="$(tr '\n' ' ' <"$DOCS/tools/soak/README.md" | tr -s ' ')"
    [[ "$soak" == *"run only on Linux, with Bash 5.2"* ]]
    [[ "$soak" != *"written for bash 3.2"* ]]
    [[ "$soak" == *"written to avoid Bash 4 features"* ]]
    said CHANGELOG 'The soak observer.s header claimed Linux or macOS and Bash 3.2' || return 1
    said CHANGELOG '`lyrebird-mic-check.sh` needed Bash 4.3' || return 1
}

# ---------------------------------------------------------------------------
# the CHANGELOG covers the register
# ---------------------------------------------------------------------------

@test "every fixed register item from X-50 to X-64 is in the Unreleased section of the CHANGELOG, and docs/changelog.html says the same [X-50, DOC-04]" {
    run python3 -I - "$CHANGELOG" "$REGISTER" "$PAGES_DIR/changelog.html" <<'PY'
import html
import json
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^## \[Unreleased\]\n(.*?)^## ", text, re.S | re.M)
section = re.sub(r"\s+", " ", m.group(1))
register = {i["id"]: i for i in json.load(open(sys.argv[2], encoding="utf-8"))["items"]}
page = html.unescape(re.sub(r"<[^>]+>", "", open(sys.argv[3], encoding="utf-8").read()))
page = re.sub(r"\s+", " ", page)
problems = []
for n in range(50, 65):
    ident = "X-%d" % n
    item = register.get(ident)
    if item is None:
        problems.append("%s is not in the register" % ident)
        continue
    if item["status"] not in ("fixed", "wontfix"):
        problems.append("%s has status %s" % (ident, item["status"]))
        continue
    for where, body in (("CHANGELOG.md", section), ("docs/changelog.html", page)):
        if not re.search(r"\[(?:[A-Z]+-\d+, )*%s(?:, [A-Z]+-\d+)*\]" % re.escape(ident), body):
            problems.append("%s is not cited in %s" % (ident, where))
print("\n".join(problems))
sys.exit(1 if problems else 0)
PY
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

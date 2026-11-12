#!/usr/bin/env bats
# CI and release automation (docs/REMEDIATION-2026-11.md: LB-19, LB-20, X-22,
# X-16). Mechanical checks of .github/ and tests/fetch_mediamtx.sh, so the
# properties the register asks for cannot be lost by a later edit:
#   - tests/fetch_mediamtx.sh pins and verifies the MediaMTX releases the live
#     matrix runs, and resolves and verifies "latest" for the advisory canary;
# plus, in later sections of this file, the workflows themselves.
#
# Everything runs the real script/steps against local fixtures: no network.

load scratch_tmpdir

setup() {
    scratch_setup
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    FETCH="$ROOT/tests/fetch_mediamtx.sh"
}

teardown() {
    [[ -n "${TEST_SCRATCH:-}" ]] && scratch_teardown
    return 0
}

# Skips here, not in setup(): a setup() that skips would also skip the failing
# canary test_suite_can_fail.bats appends to every file.
require_fetch_platform() {
    [[ "$(uname -s)/$(uname -m)" == Linux/x86_64 ]] || skip "fetch_mediamtx.sh pins linux amd64 only"
    command -v git >/dev/null || skip "git not installed"
    command -v curl >/dev/null || skip "curl not installed"
}

# make_release TAG [CONTENT]: a local stand-in for the upstream release TAG: a
# linux amd64 tarball holding a one-line "mediamtx" script, and a
# checksums.sha256 in the upstream format ("<sha256> *<file>", other platforms
# included) that lists the tarball's real hash.
make_release() {
    local tag="$1" content="${2:-fake}" dir file pk
    dir="$REL/download/$tag"
    file="mediamtx_${tag}_linux_amd64.tar.gz"
    pk="$TEST_SCRATCH/pk-$tag"
    mkdir -p "$dir" "$pk"
    printf '#!/bin/sh\necho %s-%s\n' "$content" "$tag" >"$pk/mediamtx"
    chmod +x "$pk/mediamtx"
    tar -czf "$dir/$file" -C "$pk" mediamtx
    {
        printf '%s *mediamtx_%s_darwin_arm64.tar.gz\n' "$(printf other | sha256sum | cut -d' ' -f1)" "$tag"
        printf '%s *%s\n' "$(sha256sum "$dir/$file" | cut -d' ' -f1)" "$file"
        printf '%s *mediamtx_%s_windows_amd64.zip\n' "$(printf win | sha256sum | cut -d' ' -f1)" "$tag"
    } >"$dir/checksums.sha256"
}

# make_upstream TAG...: a local git repository carrying exactly these tags,
# standing in for the upstream repository that "latest" is resolved from.
make_upstream() {
    local t
    UP="$TEST_SCRATCH/upstream"
    git init -q "$UP"
    git -C "$UP" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m init
    for t in "$@"; do
        git -C "$UP" -c tag.gpgSign=false tag "$t"
    done
}

# fetch_from_fixture ARGS...: the real fetch_mediamtx.sh against REL/UP.
fetch_from_fixture() {
    run env LYREBIRD_MEDIAMTX_RELEASES_URL="file://$REL" \
        LYREBIRD_MEDIAMTX_GIT_URL="$UP" \
        "$FETCH" "$TEST_SCRATCH/cache" "$@"
}

@test "fetch_mediamtx pins v1.21.2 and v1.21.3 with the sha256 from the release checksum files" {
    grep -qE '^    \["v1\.21\.2"\]=121be6e00397e473a95d83c75f4fcd3819a6af3b0e1a50889cba43ab4fab6a27$' "$FETCH"
    grep -qE '^    \["v1\.21\.3"\]=0a2ea7eba96023631efa1bea7804823a9145b043b6646a8a05798d4ac24ed635$' "$FETCH"
}

@test "fetch_mediamtx: latest resolves the newest stable tag and ignores pre-releases" {
    require_fetch_platform
    REL="$TEST_SCRATCH/releases"
    make_upstream v9.9.8 v9.9.9 v9.10.0 v10.0.0-rc1
    make_release v9.10.0
    fetch_from_fixture latest
    [ "$status" -eq 0 ]
    [[ "$output" == *"latest upstream release is v9.10.0"* ]]
    [ "$(tail -n 1 <<<"$output")" = "$(cd "$TEST_SCRATCH/cache/v9.10.0" && pwd)/mediamtx" ]
    run "$TEST_SCRATCH/cache/v9.10.0/mediamtx"
    [ "$output" = "fake-v9.10.0" ]
}

@test "fetch_mediamtx: latest refuses a tarball that does not match the release checksum file" {
    require_fetch_platform
    REL="$TEST_SCRATCH/releases"
    make_upstream v9.9.9
    make_release v9.9.9
    # A different tarball under the same name: the checksum file no longer fits.
    printf 'tampered' >"$REL/download/v9.9.9/mediamtx_v9.9.9_linux_amd64.tar.gz"
    fetch_from_fixture latest
    [ "$status" -eq 1 ]
    [[ "$output" == *"checksum mismatch for v9.9.9"* ]]
    [ ! -e "$TEST_SCRATCH/cache/v9.9.9/mediamtx" ]
    [ ! -e "$TEST_SCRATCH/cache/mediamtx_v9.9.9_linux_amd64.tar.gz.part" ]
}

@test "fetch_mediamtx: latest refuses a release whose checksum file has no single linux amd64 entry" {
    require_fetch_platform
    REL="$TEST_SCRATCH/releases"
    make_upstream v9.9.9
    make_release v9.9.9
    grep -v linux_amd64 "$REL/download/v9.9.9/checksums.sha256" >"$TEST_SCRATCH/sums"
    cp "$TEST_SCRATCH/sums" "$REL/download/v9.9.9/checksums.sha256"
    fetch_from_fixture latest
    [ "$status" -eq 1 ]
    [[ "$output" == *"no usable linux amd64 entry"* ]]
    [ ! -e "$TEST_SCRATCH/cache/v9.9.9/mediamtx" ]

    # Two entries for the same file are ambiguous and refused too.
    make_release v9.9.9
    cat "$REL/download/v9.9.9/checksums.sha256" "$REL/download/v9.9.9/checksums.sha256" >"$TEST_SCRATCH/sums"
    cp "$TEST_SCRATCH/sums" "$REL/download/v9.9.9/checksums.sha256"
    fetch_from_fixture latest
    [ "$status" -eq 1 ]
    [[ "$output" == *"no usable linux amd64 entry"* ]]
}

@test "fetch_mediamtx: latest fails when upstream has no stable release tag" {
    require_fetch_platform
    REL="$TEST_SCRATCH/releases"
    make_upstream v2.0.0-rc1 nightly
    fetch_from_fixture latest
    [ "$status" -eq 1 ]
    [[ "$output" == *"cannot determine the latest upstream release"* ]]
}

@test "fetch_mediamtx: latest on a pinned version requires the checksum file to agree with the pin" {
    require_fetch_platform
    REL="$TEST_SCRATCH/releases"
    # v1.21.3 is pinned; this stand-in release is self-consistent but is not the
    # pinned artifact, so the pin must win.
    make_upstream v1.21.3
    make_release v1.21.3
    fetch_from_fixture latest
    [ "$status" -eq 1 ]
    [[ "$output" == *"disagrees with the pinned value"* ]]
    [ ! -e "$TEST_SCRATCH/cache/v1.21.3/mediamtx" ]
}

@test "fetch_mediamtx: a pinned version whose download does not match its pin is refused and removed" {
    require_fetch_platform
    REL="$TEST_SCRATCH/releases"
    make_upstream v1.21.3
    make_release v1.21.3
    fetch_from_fixture v1.21.3
    [ "$status" -eq 1 ]
    [[ "$output" == *"checksum mismatch for v1.21.3"* ]]
    [ ! -e "$TEST_SCRATCH/cache/v1.21.3/mediamtx" ]
    [ ! -e "$TEST_SCRATCH/cache/mediamtx_v1.21.3_linux_amd64.tar.gz.part" ]
    [ ! -e "$TEST_SCRATCH/cache/mediamtx_v1.21.3_linux_amd64.tar.gz" ]
}

@test "fetch_mediamtx: an unpinned version is refused with exit status 2" {
    require_fetch_platform
    REL="$TEST_SCRATCH/releases"
    make_upstream v9.9.9
    fetch_from_fixture v9.9.9
    [ "$status" -eq 2 ]
    [[ "$output" == *"no pin for v9.9.9"* ]]
}

# ---------------------------------------------------------------------------
# Workflows. The YAML is loaded into JSON (python3 + PyYAML, else ruby) and
# asserted with jq. GitHub's own `on:` key is parsed as boolean true by YAML
# 1.1 loaders; it is mapped back to "on".
# ---------------------------------------------------------------------------

# wf_json FILE: the workflow as one line of JSON.
wf_json() {
    if python3 -I -c 'import yaml' 2>/dev/null; then
        python3 -I -c '
import json, sys, yaml
d = yaml.safe_load(sys.stdin)
if True in d:
    d["on"] = d.pop(True)
print(json.dumps(d))' <"$1"
    elif command -v ruby >/dev/null && ruby -ryaml -rjson -e 'exit' 2>/dev/null; then
        ruby -ryaml -rjson -e '
d = YAML.safe_load(STDIN.read)
d["on"] = d.delete(true) if d.key?(true)
puts JSON.generate(d)' <"$1"
    else
        return 3
    fi
}

# require_yaml: the workflow checks need jq and a YAML loader. Skip when one is
# missing on a developer machine, but never in CI, where a skip would hide the
# checks.
require_yaml() {
    local why=""
    if ! command -v jq >/dev/null; then
        why="jq not installed"
    elif ! wf_json "$ROOT/.github/workflows/bash-ci.yml" >/dev/null 2>&1; then
        why="needs python3 with PyYAML, or ruby"
    fi
    [[ -z "$why" ]] && return 0
    if [[ -n "${CI:-}" ]]; then
        echo "CI checks cannot run: $why" >&2
        return 1
    fi
    skip "$why"
}

# load_wf NAME: put the JSON of .github/workflows/NAME.yml in $WF.
load_wf() {
    require_yaml
    WF="$(wf_json "$ROOT/.github/workflows/$1.yml")"
}

# step_script JOB STEP: print the run: script of the step named STEP in JOB of
# $WF (exactly one such step must exist).
step_script() {
    jq -e --arg j "$1" --arg s "$2" '[.jobs[$j].steps[] | select(.name == $s)] | length == 1' <<<"$WF" >/dev/null || {
        echo "no single step '$2' in job '$1'" >&2
        return 1
    }
    jq -er --arg j "$1" --arg s "$2" '.jobs[$j].steps[] | select(.name == $s) | .run' <<<"$WF"
}

# step_env JOB STEP: NAME=value lines for the workflow-, job- and step-level
# env of the step; values that use a ${{ }} expression are left out (the test
# supplies those).
step_env() {
    jq -r --arg j "$1" --arg s "$2" '
        ([.env, .jobs[$j].env, (.jobs[$j].steps[] | select(.name == $s) | .env)] | map(. // {}) | add)
        | to_entries[] | select((.value | tostring | contains("${{")) | not)
        | "\(.key)=\(.value)"' <<<"$WF"
}

# run_step JOB STEP [NAME=value...]: run the step's real script the way the
# runner does, with its static env plus the given variables, in the current
# directory. The runner runs `shell: bash` as bash --noprofile --norc -eo
# pipefail and a step with no shell set as bash -e; the workflow decides.
run_step() {
    local job="$1" step="$2"
    shift 2
    local -a envs flags
    local shell
    shell="$(jq -r --arg j "$job" --arg s "$step" '
        (.jobs[$j].steps[] | select(.name == $s) | .shell) // .jobs[$j].defaults.run.shell // .defaults.run.shell // ""' <<<"$WF")"
    case "$shell" in
        bash) flags=(--noprofile --norc -eo pipefail) ;;
        "") flags=(-e) ;;
        *)
            echo "run_step does not know shell '$shell'" >&2
            return 1
            ;;
    esac
    step_script "$job" "$step" >"$TEST_SCRATCH/step.sh"
    mapfile -t envs < <(step_env "$job" "$step")
    run env "${envs[@]}" "$@" bash "${flags[@]}" "$TEST_SCRATCH/step.sh"
}

@test "bash-ci runs on pull requests and pushes to main/master, weekly, on demand and when called" {
    load_wf bash-ci
    run jq -e '
        (.on | has("pull_request") and has("push") and has("schedule")
            and has("workflow_dispatch") and has("workflow_call"))
        and (.on.pull_request.branches == ["main", "master"])
        and (.on.push.branches == ["main", "master"])
        and (.on.schedule | length >= 1)' <<<"$WF"
    [ "$status" -eq 0 ]
}

@test "bash-ci has no path filter on any trigger" {
    load_wf bash-ci
    run jq -e '[.on | .. | objects | keys[] | select(. == "paths" or . == "paths-ignore")] | length == 0' <<<"$WF"
    [ "$status" -eq 0 ]
}

@test "bash-ci cancels superseded pull request runs only, never a run on main or a tag" {
    load_wf bash-ci
    run jq -er '.concurrency."cancel-in-progress"' <<<"$WF"
    [ "$status" -eq 0 ]
    [[ "$output" == *"github.event_name == 'pull_request'"* ]]
}

@test "no workflow interpolates an expression into a run script, and every run script parses" {
    require_yaml
    local f json n=0 i script
    for f in "$ROOT"/.github/workflows/*.yml; do
        json="$(wf_json "$f")"
        run jq -r '[.jobs[] | .steps[]? | select(.run != null) | select(.run | contains("${{")) | .name] | .[]' <<<"$json"
        [ -z "$output" ] || {
            echo "$f puts an expression in a run script (pass it through env: instead): $output"
            return 1
        }
        # Every run script is valid bash.
        for i in $(jq -r '[.jobs[] | .steps[]? | select(.run != null)] | keys[]' <<<"$json"); do
            script="$TEST_SCRATCH/run-script.sh"
            jq -r --argjson i "$i" '[.jobs[] | .steps[]? | select(.run != null)][$i].run' <<<"$json" >"$script"
            bash -n "$script" || {
                echo "$f: run script #$i does not parse"
                return 1
            }
            n=$((n + 1))
        done
    done
    # The loop must not pass by finding nothing.
    [ "$n" -ge 20 ]
}

@test "bash-ci runs its steps with bash -eo pipefail and a read-only token" {
    load_wf bash-ci
    run jq -e '.defaults.run.shell == "bash" and .permissions == {"contents": "read"}' <<<"$WF"
    [ "$status" -eq 0 ]
}

@test "bash-ci ShellCheck report step survives a script with findings under pipefail" {
    load_wf bash-ci
    mkdir "$TEST_SCRATCH/repo" "$TEST_SCRATCH/bin"
    : >"$TEST_SCRATCH/repo/a.sh"
    # A shellcheck that reports findings the way the real one does: JSON on
    # stdout and exit status 1.
    cat >"$TEST_SCRATCH/bin/shellcheck" <<'SH'
#!/bin/bash
echo '[{"level":"warning","code":2086},{"level":"info","code":2016},{"level":"error","code":1072}]'
exit 1
SH
    chmod +x "$TEST_SCRATCH/bin/shellcheck"
    cd "$TEST_SCRATCH/repo"
    run_step shellcheck "ShellCheck Summary Report" \
        PATH="$TEST_SCRATCH/bin:$PATH" GITHUB_STEP_SUMMARY="$TEST_SCRATCH/summary.md"
    [ "$status" -eq 0 ]
    grep -qF '| FAIL ./a.sh | 1 | 1 | 1 |' "$TEST_SCRATCH/summary.md"
}

# ---------------------------------------------------------------------------
# Supply chain: every Action is pinned to a commit, Dependabot keeps the pins
# current.
# ---------------------------------------------------------------------------

# uses_lines: every `uses:` line of every workflow, as "file:line:text".
uses_lines() {
    grep -nE '^[[:space:]]*(-[[:space:]]+)?uses:' "$ROOT"/.github/workflows/*.yml
}

@test "every action is pinned to a full commit sha with a version comment" {
    local line text target comment bad=0 n=0
    while IFS= read -r line; do
        text="${line#*:*:}"
        if [[ ! "$text" =~ ^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+([^[:space:]#]+)[[:space:]]*(#[[:space:]]*(.*))?$ ]]; then
            echo "unparsable uses line: $line"
            bad=1
            continue
        fi
        target="${BASH_REMATCH[2]}"
        comment="${BASH_REMATCH[4]}"
        # A workflow in this repository is referenced by path and has no ref.
        [[ "$target" == ./* ]] && continue
        n=$((n + 1))
        if [[ ! "$target" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+@[0-9a-f]{40}$ ]]; then
            echo "not pinned to a 40-hex commit sha: $line"
            bad=1
        elif [[ ! "$comment" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "pin has no '# vX.Y.Z' comment: $line"
            bad=1
        fi
    done < <(uses_lines)
    # A broken pattern must not pass by matching nothing.
    [ "$n" -ge 10 ] || {
        echo "only $n pinned actions found"
        return 1
    }
    [ "$bad" -eq 0 ]
}

@test "each action is pinned to one commit, under one version, in every workflow" {
    local out
    out="$(uses_lines | sed -E 's/^[^:]*:[0-9]+:[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+//' \
        | grep -v '^\./' | sed -E 's/@([0-9a-f]+)[[:space:]]+#[[:space:]]*(.*)$/ \1 \2/' \
        | sort -u | awk '{ n[$1]++; if (n[$1] > 1) print "action " $1 " is pinned more than once" }')"
    [ -z "$out" ] || {
        echo "$out"
        return 1
    }
}

@test "dependabot proposes weekly updates for the pinned GitHub Actions" {
    require_yaml
    local dep
    dep="$(wf_json "$ROOT/.github/dependabot.yml")"
    run jq -e '
        .version == 2
        and ([.updates[] | select(."package-ecosystem" == "github-actions"
            and .directory == "/" and .schedule.interval == "weekly")] | length == 1)' <<<"$dep"
    [ "$status" -eq 0 ]
}

@test "dependabot proposes weekly updates for the pinned Python tools, and their requirements file exists" {
    require_yaml
    local dep dir
    dep="$(wf_json "$ROOT/.github/dependabot.yml")"
    dir="$(jq -er '.updates[] | select(."package-ecosystem" == "pip" and .schedule.interval == "weekly") | .directory' <<<"$dep")"
    [ -f "$ROOT${dir%/}/requirements.txt" ]
}

# ---------------------------------------------------------------------------
# Downloaded tools are pinned and verified before they are installed.
# ---------------------------------------------------------------------------

# installer_shims: curl that "downloads" $FAKE_DOWNLOAD to the -o path, sudo
# that only records its arguments, and stand-ins for the installed tools, all
# in $TEST_SCRATCH/bin; $FAKE_LOG receives the URL and the sudo calls.
installer_shims() {
    local t
    mkdir -p "$TEST_SCRATCH/bin" "$TEST_SCRATCH/runner"
    cat >"$TEST_SCRATCH/bin/curl" <<'SH'
#!/bin/bash
out="" url=""
while (($#)); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
echo "curl $url" >>"$FAKE_LOG"
cp "$FAKE_DOWNLOAD" "$out"
SH
    cat >"$TEST_SCRATCH/bin/sudo" <<'SH'
#!/bin/bash
echo "sudo $*" >>"$FAKE_LOG"
SH
    for t in shellcheck shfmt actionlint; do
        printf '#!/bin/bash\necho "%s stand-in"\n' "$t" >"$TEST_SCRATCH/bin/$t"
    done
    chmod +x "$TEST_SCRATCH"/bin/*
}

# check_installer JOB STEP PIN_VAR TOOL URL_PART FORMAT: the install step of
# TOOL in JOB must refuse a download that does not match the pinned sha256 and
# install one that does. FORMAT says how the fake download is packed.
check_installer() {
    local job="$1" step="$2" pin_var="$3" tool="$4" url_part="$5" format="$6" ver good
    ver="$(jq -er '.env | [.SHELLCHECK_VERSION, .SHFMT_VERSION, .ACTIONLINT_VERSION] | join(" ")' <<<"$WF")"
    if [[ "$format" == xz ]] && ! command -v xz >/dev/null; then
        skip "xz not installed"
    fi
    rm -rf "${TEST_SCRATCH:?}/pack" "${TEST_SCRATCH:?}/bin" "${TEST_SCRATCH:?}/runner" "${TEST_SCRATCH:?}/log"
    mkdir -p "$TEST_SCRATCH/pack"
    installer_shims
    case "$format" in
        xz)
            mkdir "$TEST_SCRATCH/pack/shellcheck-${ver%% *}"
            echo payload >"$TEST_SCRATCH/pack/shellcheck-${ver%% *}/$tool"
            tar -cJf "$TEST_SCRATCH/download" -C "$TEST_SCRATCH/pack" "shellcheck-${ver%% *}"
            ;;
        gz)
            echo payload >"$TEST_SCRATCH/pack/$tool"
            tar -czf "$TEST_SCRATCH/download" -C "$TEST_SCRATCH/pack" "$tool"
            ;;
        raw)
            echo payload >"$TEST_SCRATCH/download"
            ;;
    esac
    good="$(sha256sum "$TEST_SCRATCH/download" | cut -d' ' -f1)"

    # The pin from the workflow is not the hash of this fake download: refused,
    # nothing installed.
    # (LC_ALL=C: sha256sum prints a translated word for FAILED in other locales.)
    run_step "$job" "$step" PATH="$TEST_SCRATCH/bin:$PATH" RUNNER_TEMP="$TEST_SCRATCH/runner" \
        FAKE_LOG="$TEST_SCRATCH/log" FAKE_DOWNLOAD="$TEST_SCRATCH/download" LC_ALL=C
    [ "$status" -ne 0 ] || {
        echo "$tool: a download that does not match the pin was accepted"
        return 1
    }
    [[ "$output" == *"FAILED"* ]]
    grep -qF "releases/download/" "$TEST_SCRATCH/log"
    grep -qF "$url_part" "$TEST_SCRATCH/log"
    if grep -q '^sudo' "$TEST_SCRATCH/log"; then
        echo "$tool was installed although its hash did not match"
        return 1
    fi

    # With the hash of the download as the pin, it installs.
    run_step "$job" "$step" PATH="$TEST_SCRATCH/bin:$PATH" RUNNER_TEMP="$TEST_SCRATCH/runner" \
        FAKE_LOG="$TEST_SCRATCH/log" FAKE_DOWNLOAD="$TEST_SCRATCH/download" "$pin_var=$good"
    [ "$status" -eq 0 ]
    grep -qE "^sudo install -m 0755 .* /usr/local/bin/$tool\$" "$TEST_SCRATCH/log"
}

@test "bash-ci installs ShellCheck only from a download that matches the pinned sha256" {
    load_wf bash-ci
    local job
    for job in shellcheck workflow-lint; do
        check_installer "$job" "Install ShellCheck (pinned, sha256-verified)" SHELLCHECK_SHA256 shellcheck \
            "koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz" xz
    done
}

@test "bash-ci installs shfmt only from a download that matches the pinned sha256" {
    load_wf bash-ci
    check_installer shfmt "Install shfmt (pinned, sha256-verified)" SHFMT_SHA256 shfmt \
        "mvdan/sh/releases/download/v3.13.1/shfmt_v3.13.1_linux_amd64" raw
}

@test "bash-ci installs actionlint only from a download that matches the pinned sha256" {
    load_wf bash-ci
    check_installer workflow-lint "Install actionlint (pinned, sha256-verified)" ACTIONLINT_SHA256 actionlint \
        "rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz" gz
}

@test "bash-ci tool pins are exact versions with a 64-hex sha256" {
    load_wf bash-ci
    run jq -e '.env
        | ([.SHELLCHECK_VERSION, .SHFMT_VERSION, .ACTIONLINT_VERSION] | all(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")))
        and ([.SHELLCHECK_SHA256, .SHFMT_SHA256, .ACTIONLINT_SHA256] | all(test("^[0-9a-f]{64}$")))' <<<"$WF"
    [ "$status" -eq 0 ]
}

@test "no workflow step downloads a file without verifying a sha256, or pip-installs without hashes" {
    require_yaml
    local f json unverified
    local n=0 p=0
    for f in "$ROOT"/.github/workflows/*.yml; do
        json="$(wf_json "$f")"
        # A line that starts a curl/wget command (not a word in a package list
        # or in a grep pattern).
        unverified="$(jq -r '[.jobs[] | .steps[]? | select(.run != null)
            | select(.run | split("\n") | any(.[]; test("^[[:space:]]*(curl|wget)[[:space:]]")
                or test("[|;&(][[:space:]]*(curl|wget)[[:space:]]")))
            | select((.run | contains("sha256sum -c")) | not) | .name] | .[]' <<<"$json")"
        [ -z "$unverified" ] || {
            echo "$f downloads without sha256sum -c: $unverified"
            return 1
        }
        unverified="$(jq -r '[.jobs[] | .steps[]? | select(.run != null)
            | select(.run | test("pip3?\"?[[:space:]]+install"))
            | select((.run | contains("--require-hashes")) | not) | .name] | .[]' <<<"$json")"
        [ -z "$unverified" ] || {
            echo "$f installs with pip without --require-hashes: $unverified"
            return 1
        }
        n=$((n + $(jq '[.jobs[] | .steps[]? | select(.run != null) | select(.run | contains("sha256sum -c"))] | length' <<<"$json")))
        p=$((p + $(jq '[.jobs[] | .steps[]? | select(.run != null) | select(.run | test("pip3?\"?[[:space:]]+install"))] | length' <<<"$json")))
    done
    # The patterns must not pass by matching nothing: four verified installs
    # exist (ShellCheck twice, shfmt, actionlint) and one hash-checked pip install.
    [ "$n" -ge 4 ]
    [ "$p" -ge 1 ]
}

@test "bashate is installed at an exact version from a requirements file where every pin has hashes" {
    require_yaml
    local req="$ROOT/.github/ci/requirements.txt"
    grep -qE '^bashate==2\.1\.1 \\$' "$req"
    # Every requirement (a "name==version" line plus its --hash continuation
    # lines) carries at least one sha256, and nothing else is in the file.
    local line name="" hashes=0 bad="" pin_re hash_re
    pin_re='^([A-Za-z0-9._-]+==[^[:space:]]+)'
    hash_re='^[[:space:]]+--hash=sha256:[0-9a-f]{64}( \\)?$'
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ "$line" =~ $pin_re ]]; then
            if [[ -n "$name" && "$hashes" -eq 0 ]]; then bad+=" $name"; fi
            name="${BASH_REMATCH[1]}"
            hashes=0
        elif [[ "$line" =~ $hash_re ]]; then
            hashes=$((hashes + 1))
        else
            bad+=" [$line]"
        fi
    done <"$req"
    if [[ -n "$name" && "$hashes" -eq 0 ]]; then bad+=" $name"; fi
    [ -z "$bad" ] || {
        echo "requirements without a sha256, or lines that are not pins:$bad"
        return 1
    }
    # bashate's dependencies are pinned too: three requirements in all.
    [ "$(grep -cE '^[A-Za-z0-9._-]+==' "$req")" -ge 3 ]
}

# ---------------------------------------------------------------------------
# Live MediaMTX: one blocking job per pinned version, plus an advisory canary.
# ---------------------------------------------------------------------------

# pinned_versions: the versions tests/fetch_mediamtx.sh holds a sha256 for.
pinned_versions() {
    sed -nE 's/^[[:space:]]+\["(v[0-9]+\.[0-9]+\.[0-9]+)"\]=[0-9a-f]{64}$/\1/p' "$FETCH" | sort -V
}

@test "every version in the live matrix has a sha256 pin in fetch_mediamtx.sh, and every pin is in the matrix" {
    load_wf bash-ci
    local matrix pins v
    matrix="$(jq -r '.jobs["live-mediamtx"].strategy.matrix.version[]' <<<"$WF" | sort -V)"
    pins="$(pinned_versions)"
    [ -n "$matrix" ]
    for v in $matrix; do
        grep -qE "^[[:space:]]+\[\"$v\"\]=[0-9a-f]{64}\$" "$FETCH" || {
            echo "matrix version $v has no sha256 pin in fetch_mediamtx.sh"
            return 1
        }
    done
    [ "$matrix" = "$pins" ] || {
        printf 'matrix:\n%s\npins:\n%s\n' "$matrix" "$pins"
        return 1
    }
}

@test "the live matrix runs v1.21.2 and v1.21.3, each version as its own job that fails on its own" {
    load_wf bash-ci
    run jq -e '
        .jobs["live-mediamtx"] as $j
        | ($j.strategy.matrix.version | index("v1.21.2") != null and index("v1.21.3") != null)
        and ($j.strategy["fail-fast"] == false)
        and ($j.name | contains("${{ matrix.version }}"))
        and ($j["continue-on-error"] != true)' <<<"$WF"
    [ "$status" -eq 0 ]
}

@test "bash-ci live step fetches exactly the matrix version and fails when its tests fail" {
    load_wf bash-ci
    mkdir -p "$TEST_SCRATCH/repo/tests" "$TEST_SCRATCH/runner"
    cat >"$TEST_SCRATCH/repo/tests/fetch_mediamtx.sh" <<'SH'
#!/bin/bash
echo "fetch $*" >>"$FAKE_LOG"
echo "$1/$2/mediamtx"
SH
    cat >"$TEST_SCRATCH/repo/tests/check_tmp_leaks.sh" <<'SH'
#!/bin/bash
echo "tests bins=$LYREBIRD_TEST_MEDIAMTX_BINS args=$*" >>"$FAKE_LOG"
exit "${FAKE_TEST_STATUS:-0}"
SH
    chmod +x "$TEST_SCRATCH"/repo/tests/*.sh
    cd "$TEST_SCRATCH/repo"
    run_step live-mediamtx "Run live tests for one MediaMTX version" \
        MEDIAMTX_VERSION=v1.21.3 RUNNER_TEMP="$TEST_SCRATCH/runner" FAKE_LOG="$TEST_SCRATCH/log"
    [ "$status" -eq 0 ]
    grep -qxF "fetch $TEST_SCRATCH/runner/mediamtx v1.21.3" "$TEST_SCRATCH/log"
    grep -qF "bins=$TEST_SCRATCH/runner/mediamtx/v1.21.3/mediamtx " "$TEST_SCRATCH/log"
    grep -qF 'tests/test_mediamtx_live.bats tests/test_soak_live.bats tests/test_soak_observer.bats' "$TEST_SCRATCH/log"

    run_step live-mediamtx "Run live tests for one MediaMTX version" \
        MEDIAMTX_VERSION=v1.19.0 RUNNER_TEMP="$TEST_SCRATCH/runner" FAKE_LOG="$TEST_SCRATCH/log" FAKE_TEST_STATUS=1
    [ "$status" -ne 0 ]
}

@test "bash-ci bats job runs the suite through check_tmp_leaks.sh with the host-state check on (X-35)" {
    load_wf bash-ci
    mkdir -p "$TEST_SCRATCH/repo/tests" "$TEST_SCRATCH/runner"
    cat >"$TEST_SCRATCH/repo/tests/check_tmp_leaks.sh" <<'SH'
#!/bin/bash
echo "check_tmp_leaks host_check=${LYREBIRD_LEAK_CHECK_HOST-unset} args=[$*]" >>"$FAKE_LOG"
exit "${FAKE_TEST_STATUS:-0}"
SH
    chmod +x "$TEST_SCRATCH"/repo/tests/*.sh
    cd "$TEST_SCRATCH/repo"
    run_step bats-tests "Run bats test suite" RUNNER_TEMP="$TEST_SCRATCH/runner" FAKE_LOG="$TEST_SCRATCH/log"
    [ "$status" -eq 0 ]
    grep -qxF 'check_tmp_leaks host_check=1 args=[]' "$TEST_SCRATCH/log"

    # and a suite that fails or leaks fails the step
    run_step bats-tests "Run bats test suite" RUNNER_TEMP="$TEST_SCRATCH/runner" FAKE_LOG="$TEST_SCRATCH/log" FAKE_TEST_STATUS=1
    [ "$status" -ne 0 ]
}

@test "the canary is advisory: continue-on-error, labelled non-blocking, outside the summary, skipped for tags" {
    load_wf bash-ci
    run jq -e '
        .jobs["live-mediamtx-canary"] as $c
        | ($c["continue-on-error"] == true)
        and ($c.name | test("advisory") and test("non-blocking"))
        and (.jobs.summary.needs | index("live-mediamtx-canary") == null)
        and ($c["if"] | contains("startsWith(github.ref, '"'"'refs/tags/'"'"')"))
        and ([.jobs | to_entries[] | select(.value["continue-on-error"] == true) | .key] == ["live-mediamtx-canary"])' <<<"$WF"
    [ "$status" -eq 0 ]
}

@test "the canary resolves and verifies the newest upstream release and runs the same live tests" {
    load_wf bash-ci
    mkdir -p "$TEST_SCRATCH/repo/tests" "$TEST_SCRATCH/runner"
    cat >"$TEST_SCRATCH/repo/tests/fetch_mediamtx.sh" <<'SH'
#!/bin/bash
echo "fetch $*" >>"$FAKE_LOG"
echo "$1/v9.9.9/mediamtx"
SH
    cat >"$TEST_SCRATCH/repo/tests/check_tmp_leaks.sh" <<'SH'
#!/bin/bash
echo "tests bins=$LYREBIRD_TEST_MEDIAMTX_BINS args=$*" >>"$FAKE_LOG"
SH
    chmod +x "$TEST_SCRATCH"/repo/tests/*.sh
    cd "$TEST_SCRATCH/repo"
    run_step live-mediamtx-canary "Run live tests against the newest upstream release" \
        RUNNER_TEMP="$TEST_SCRATCH/runner" FAKE_LOG="$TEST_SCRATCH/log" GITHUB_STEP_SUMMARY="$TEST_SCRATCH/summary.md"
    [ "$status" -eq 0 ]
    grep -qxF "fetch $TEST_SCRATCH/runner/mediamtx latest" "$TEST_SCRATCH/log"
    grep -qF 'tests/test_mediamtx_live.bats tests/test_soak_live.bats tests/test_soak_observer.bats' "$TEST_SCRATCH/log"
    grep -qF 'MediaMTX v9.9.9' "$TEST_SCRATCH/summary.md"
}

# ---------------------------------------------------------------------------
# Required checks: the summary job gates on every job, and the format and
# style linters block.
# ---------------------------------------------------------------------------

# fake_tool NAME: a stand-in for a linter that, like the real shfmt -d and
# bashate, exits 1 for a file whose text contains UNFORMATTED and 0 otherwise.
fake_tool() {
    mkdir -p "$TEST_SCRATCH/bin"
    cat >"$TEST_SCRATCH/bin/$1" <<'SH'
#!/bin/bash
file="${*: -1}"
if grep -q UNFORMATTED "$file"; then
    echo "finding in $file"
    exit 1
fi
SH
    chmod +x "$TEST_SCRATCH/bin/$1"
}

@test "bash-ci summary needs every other job, so none can fail or be skipped unnoticed" {
    load_wf bash-ci
    run jq -e '
        ([.jobs | to_entries[] | select(.key != "summary" and (.value["continue-on-error"] != true)) | .key] | sort) as $all
        | ([.jobs.summary.needs[]] | sort) as $needed
        | ($needed | length) == ($needed | unique | length)
        and $needed == $all
        and (.jobs.summary["if"] == "always()")' <<<"$WF"
    [ "$status" -eq 0 ]
    # The jobs the register names are all there.
    run jq -e '[.jobs.summary.needs[]] as $n
        | ["discover-scripts", "workflow-lint", "bash-syntax", "shellcheck", "shfmt", "bashate",
           "security-scan", "bats-tests", "live-mediamtx"] | all(. as $j | $n | index($j) != null)' <<<"$WF"
    [ "$status" -eq 0 ]
}

@test "bash-ci summary fails unless every needed job succeeded: failure, cancelled, skipped and an empty result all fail" {
    load_wf bash-ci
    run_step summary "Require every job to succeed" \
        'NEEDS_JSON={"a":{"result":"success"},"b":{"result":"success"}}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"All 2 required jobs succeeded"* ]]

    local bad
    for bad in failure cancelled skipped ""; do
        run_step summary "Require every job to succeed" \
            "NEEDS_JSON={\"a\":{\"result\":\"success\"},\"live\":{\"result\":\"$bad\"}}"
        [ "$status" -ne 0 ] || {
            echo "a job that finished as '$bad' passed the summary"
            return 1
        }
        [[ "$output" == *"::error::live finished as '$bad'"* ]]
    done

    run_step summary "Require every job to succeed" 'NEEDS_JSON={}'
    [ "$status" -ne 0 ]
}

@test "bash-ci summary report lists every needed job with its result" {
    load_wf bash-ci
    run_step summary "Report job results" \
        'NEEDS_JSON={"shellcheck":{"result":"success"},"live-mediamtx":{"result":"failure"}}' \
        SCRIPT_COUNT=7 GITHUB_STEP_SUMMARY="$TEST_SCRATCH/summary.md"
    [ "$status" -eq 0 ]
    grep -qF '| shellcheck | success |' "$TEST_SCRATCH/summary.md"
    grep -qF '| live-mediamtx | failure |' "$TEST_SCRATCH/summary.md"
    grep -qF 'Scripts analyzed: 7' "$TEST_SCRATCH/summary.md"
}

@test "bash-ci shfmt job fails when a script is not formatted, and passes when all are" {
    load_wf bash-ci
    fake_tool shfmt
    mkdir "$TEST_SCRATCH/repo"
    cd "$TEST_SCRATCH/repo"
    echo ok >good.sh
    run_step shfmt "Check formatting with shfmt" PATH="$TEST_SCRATCH/bin:$PATH"
    [ "$status" -eq 0 ]

    echo UNFORMATTED >bad.sh
    run_step shfmt "Check formatting with shfmt" PATH="$TEST_SCRATCH/bin:$PATH"
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::1 script(s) have formatting inconsistencies"* ]]
}

@test "bash-ci bashate job fails when a script has style findings, and passes when none has" {
    load_wf bash-ci
    fake_tool bashate
    mkdir "$TEST_SCRATCH/repo"
    cd "$TEST_SCRATCH/repo"
    echo ok >good.sh
    run_step bashate "Run bashate style check" PATH="$TEST_SCRATCH/bin:$PATH"
    [ "$status" -eq 0 ]

    echo UNFORMATTED >bad.sh
    run_step bashate "Run bashate style check" PATH="$TEST_SCRATCH/bin:$PATH"
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::bashate found style issues in 1 script(s)"* ]]
}

@test "bash-ci security report states what the scan found instead of a fixed OK table" {
    load_wf bash-ci
    run_step security-scan "Security Summary Report" \
        WARNING_COUNT=2 'WARNING_LIST=Dangerous eval patterns found Hardcoded secrets' \
        GITHUB_STEP_SUMMARY="$TEST_SCRATCH/summary.md"
    [ "$status" -eq 0 ]
    grep -qF '2 pattern(s) matched: Dangerous eval patterns found Hardcoded secrets' "$TEST_SCRATCH/summary.md"
    if grep -q '| OK |' "$TEST_SCRATCH/summary.md"; then
        echo "the report still contains a fixed OK table"
        return 1
    fi

    run_step security-scan "Security Summary Report" \
        WARNING_COUNT=0 WARNING_LIST=None GITHUB_STEP_SUMMARY="$TEST_SCRATCH/summary.md"
    grep -qF 'No pattern matched' "$TEST_SCRATCH/summary.md"
}

# ---------------------------------------------------------------------------
# release.yml: validated by the same pipeline as a pull request, then an
# idempotent publish with a source tarball and SHA256SUMS.
# ---------------------------------------------------------------------------

ARCHIVE_STEP="Build source archive and checksums"
PUBLISH_STEP="Publish GitHub Release (create, or update an existing one)"

@test "release validates the tagged commit with the full Bash CI before it publishes" {
    load_wf release
    run jq -e '
        (.jobs.validate.uses == "./.github/workflows/bash-ci.yml")
        and (.jobs.validate | has("steps") | not)
        and ([.jobs.release.needs] | flatten | index("validate") != null)
        and (.permissions == {"contents": "read"})
        and (.jobs.release.permissions == {"contents": "write"})
        and (.defaults.run.shell == "bash")' <<<"$WF"
    [ "$status" -eq 0 ]
    # ... and bash-ci can be called.
    run jq -e '.on | has("workflow_call")' <<<"$(wf_json "$ROOT/.github/workflows/bash-ci.yml")"
    [ "$status" -eq 0 ]
}

# make_tagged_repo: a git repository with one tracked commit and an untracked
# file; sets GITHUB_SHA.
make_tagged_repo() {
    mkdir -p "$TEST_SCRATCH/repo/sub"
    cd "$TEST_SCRATCH/repo" || return 1
    git init -q .
    echo tracked >a.sh
    echo nested >sub/b.txt
    git add a.sh sub/b.txt
    GIT_COMMITTER_DATE="2026-11-01T12:00:00Z" GIT_AUTHOR_DATE="2026-11-01T12:00:00Z" \
        git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m "release content"
    echo untracked >untracked.txt
    GITHUB_SHA="$(git rev-parse HEAD)"
}

@test "release source archive is the tracked files of the tagged commit and SHA256SUMS verifies it" {
    load_wf release
    command -v git >/dev/null || skip "git not installed"
    make_tagged_repo
    run_step release "$ARCHIVE_STEP" GITHUB_REF_NAME=v1.3.0 GITHUB_SHA="$GITHUB_SHA" RUNNER_TEMP="$TEST_SCRATCH/r1"
    [ "$status" -eq 0 ]
    local dir="$TEST_SCRATCH/r1/release-assets"
    [ -f "$dir/LyreBirdAudio-1.3.0.tar.gz" ]
    # The checksum file names the tarball without a path, so it verifies in place.
    [ "$(cut -d' ' -f3- "$dir/SHA256SUMS")" = "LyreBirdAudio-1.3.0.tar.gz" ]
    (cd "$dir" && sha256sum -c SHA256SUMS)
    # Layout: one top-level directory; tracked files only.
    run tar -tzf "$dir/LyreBirdAudio-1.3.0.tar.gz"
    [ "$status" -eq 0 ]
    [[ "$output" == *"LyreBirdAudio-1.3.0/a.sh"* ]]
    [[ "$output" == *"LyreBirdAudio-1.3.0/sub/b.txt"* ]]
    [[ "$output" != *"untracked.txt"* ]]
    [[ "$output" != *".git/"* ]]
    [ "$(grep -vc '^LyreBirdAudio-1.3.0/' <<<"$output")" -eq 0 ]
}

@test "release source archive is reproducible: rebuilding the same commit gives the same bytes" {
    load_wf release
    command -v git >/dev/null || skip "git not installed"
    make_tagged_repo
    run_step release "$ARCHIVE_STEP" GITHUB_REF_NAME=v1.3.0 GITHUB_SHA="$GITHUB_SHA" RUNNER_TEMP="$TEST_SCRATCH/r1"
    [ "$status" -eq 0 ]
    # Later, in another directory, with an extra untracked file and a changed
    # working tree: the archive comes from the commit, not from the checkout.
    echo changed >a.sh
    echo more >another-untracked.txt
    sleep 1
    run_step release "$ARCHIVE_STEP" GITHUB_REF_NAME=v1.3.0 GITHUB_SHA="$GITHUB_SHA" RUNNER_TEMP="$TEST_SCRATCH/r2"
    [ "$status" -eq 0 ]
    cmp "$TEST_SCRATCH/r1/release-assets/LyreBirdAudio-1.3.0.tar.gz" "$TEST_SCRATCH/r2/release-assets/LyreBirdAudio-1.3.0.tar.gz"
    cmp "$TEST_SCRATCH/r1/release-assets/SHA256SUMS" "$TEST_SCRATCH/r2/release-assets/SHA256SUMS"
}

@test "release archive step fails, and writes no checksums, when git archive fails" {
    load_wf release
    command -v git >/dev/null || skip "git not installed"
    make_tagged_repo
    run_step release "$ARCHIVE_STEP" GITHUB_REF_NAME=v1.3.0 \
        GITHUB_SHA=0000000000000000000000000000000000000000 RUNNER_TEMP="$TEST_SCRATCH/r1"
    [ "$status" -ne 0 ]
    [ ! -e "$TEST_SCRATCH/r1/release-assets/SHA256SUMS" ]
}

# gh_shim: a `gh` that keeps state in $FAKE_STATE (the file "exists" is the
# release), logs every call to $FAKE_LOG and saves the notes file it is given.
# FAKE_CREATE_RACE=1: create fails because the release appears meanwhile;
# FAKE_CREATE_FAIL=1: create fails and the release does not exist.
gh_shim() {
    mkdir -p "$TEST_SCRATCH/bin" "$TEST_SCRATCH/state" "$TEST_SCRATCH/pub/rt/release-assets"
    cat >"$TEST_SCRATCH/bin/gh" <<'SH'
#!/bin/bash
echo "gh $*" >>"$FAKE_LOG"
args=("$@")
for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == --notes-file ]]; then
        cp "${args[$((i + 1))]}" "$FAKE_STATE/notes-$1-$2"
    fi
done
case "$1 $2" in
    "release view") [[ -e "$FAKE_STATE/exists" ]] ;;
    "release create")
        if [[ -n "${FAKE_CREATE_RACE:-}" ]]; then
            : >"$FAKE_STATE/exists"
            echo "a release with that tag already exists" >&2
            exit 1
        fi
        if [[ -n "${FAKE_CREATE_FAIL:-}" ]]; then
            echo "HTTP 500" >&2
            exit 1
        fi
        : >"$FAKE_STATE/exists"
        ;;
    "release edit" | "release upload") ;;
    *)
        echo "unexpected gh call: $*" >&2
        exit 99
        ;;
esac
SH
    chmod +x "$TEST_SCRATCH/bin/gh"
    mkdir -p "$TEST_SCRATCH/pubrepo"
    cat >"$TEST_SCRATCH/pubrepo/CHANGELOG.md" <<'MD'
# Changelog

## [1.3.0] - 2026-11-11
- A fix that shipped in 1.3.0

## [1.2.0] - 2026-10-01
- Old news
MD
}

# publish TAG [NAME=value...]: run the publish step for TAG in a directory with
# a CHANGELOG.md.
publish() {
    local tag="$1"
    shift
    cd "$TEST_SCRATCH/pubrepo" || return 1
    run_step release "$PUBLISH_STEP" GITHUB_REF_NAME="$tag" GH_TOKEN=x \
        PATH="$TEST_SCRATCH/bin:$PATH" RUNNER_TEMP="$TEST_SCRATCH/pub/rt" \
        FAKE_LOG="$TEST_SCRATCH/log" FAKE_STATE="$TEST_SCRATCH/state" "$@"
}

# calls PATTERN: how many logged gh calls match the grep pattern.
calls() {
    grep -c -- "$1" "$TEST_SCRATCH/log" || true
}

@test "release publish creates the release when none exists, with the CHANGELOG section and both assets" {
    load_wf release
    gh_shim
    publish v1.3.0
    [ "$status" -eq 0 ]
    [ "$(calls '^gh release create v1.3.0 ')" -eq 1 ]
    [ "$(calls '^gh release edit ')" -eq 0 ]
    grep -qE '^gh release create v1\.3\.0 --title v1\.3\.0 --notes-file [^ ]+ --verify-tag --prerelease=false$' "$TEST_SCRATCH/log"
    grep -qF 'A fix that shipped in 1.3.0' "$TEST_SCRATCH/state/notes-release-create"
    if grep -qF 'Old news' "$TEST_SCRATCH/state/notes-release-create"; then
        echo "the notes include another version's section"
        return 1
    fi
    grep -qF "gh release upload v1.3.0 $TEST_SCRATCH/pub/rt/release-assets/LyreBirdAudio-1.3.0.tar.gz $TEST_SCRATCH/pub/rt/release-assets/SHA256SUMS --clobber" "$TEST_SCRATCH/log"
}

@test "release publish updates an existing release instead of failing, and replaces its assets" {
    load_wf release
    gh_shim
    : >"$TEST_SCRATCH/state/exists"
    publish v1.3.0
    [ "$status" -eq 0 ]
    [ "$(calls '^gh release create ')" -eq 0 ]
    [ "$(calls '^gh release edit v1.3.0 ')" -eq 1 ]
    grep -qE '^gh release edit v1\.3\.0 --title v1\.3\.0 --notes-file [^ ]+ --prerelease=false$' "$TEST_SCRATCH/log"
    [ "$(calls '^gh release upload v1.3.0 .* --clobber$')" -eq 1 ]
}

@test "release publish survives losing the race to create: the release appears during create, so it is updated" {
    load_wf release
    gh_shim
    publish v1.3.0 FAKE_CREATE_RACE=1
    [ "$status" -eq 0 ]
    [ "$(calls '^gh release create ')" -eq 1 ]
    [ "$(calls '^gh release edit v1.3.0 ')" -eq 1 ]
    [ "$(calls '^gh release upload v1.3.0 .* --clobber$')" -eq 1 ]
    [[ "$output" == *"appeared while it was being created"* ]]
}

@test "release publish still fails when the release cannot be created and does not exist" {
    load_wf release
    gh_shim
    publish v1.3.0 FAKE_CREATE_FAIL=1
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::Could not create release v1.3.0"* ]]
    [ "$(calls '^gh release upload ')" -eq 0 ]
}

@test "release publish marks a hyphenated tag as a pre-release, on create and on update" {
    load_wf release
    gh_shim
    publish v1.3.0-rc1
    [ "$status" -eq 0 ]
    grep -qE '^gh release create v1\.3\.0-rc1 .* --prerelease=true$' "$TEST_SCRATCH/log"
    publish v1.3.0-rc1
    [ "$status" -eq 0 ]
    grep -qE '^gh release edit v1\.3\.0-rc1 .* --prerelease=true$' "$TEST_SCRATCH/log"
}

@test "release publish without a CHANGELOG section generates notes on create and keeps the notes of an existing release" {
    load_wf release
    gh_shim
    publish v1.4.0
    [ "$status" -eq 0 ]
    grep -qE '^gh release create v1\.4\.0 --title v1\.4\.0 --generate-notes --verify-tag --prerelease=false$' "$TEST_SCRATCH/log"
    publish v1.4.0
    [ "$status" -eq 0 ]
    grep -qE '^gh release edit v1\.4\.0 --title v1\.4\.0 --prerelease=false$' "$TEST_SCRATCH/log"
    [ "$(calls '^gh release edit .*--notes-file')" -eq 0 ]
}

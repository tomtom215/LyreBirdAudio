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
    git -C "$UP" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
    for t in "$@"; do
        git -C "$UP" tag "$t"
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
# runner does (bash --noprofile --norc -eo pipefail), with its static env plus
# the given variables, in the current directory.
run_step() {
    local job="$1" step="$2"
    shift 2
    local -a envs
    step_script "$job" "$step" >"$TEST_SCRATCH/step.sh"
    mapfile -t envs < <(step_env "$job" "$step")
    run env "${envs[@]}" "$@" bash --noprofile --norc -eo pipefail "$TEST_SCRATCH/step.sh"
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
        | ["discover-scripts", "bash-syntax", "shellcheck", "shfmt", "bashate",
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

#!/usr/bin/env bats
# File modes in git (register: X-56).
#
# Six scripts that are run directly (install_mediamtx.sh, lyrebird-diagnostics.sh,
# lyrebird-mic-check.sh, lyrebird-orchestrator.sh, lyrebird-stream-manager.sh,
# lyrebird-updater.sh) were tracked as 100644, the rest as 100755: a fresh clone needed
# `chmod +x` before `./lyrebird-orchestrator.sh` worked (the updater makes the scripts
# executable on disk after a switch, which is why updated nodes never noticed).
# The index is what a clone gets, so the index is what is checked.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || skip "not a git work tree"
}

# "<mode> <path>" for every tracked file, from the index
tracked_modes() {
    git -C "$ROOT" ls-files -s | awk '{ mode = $1; $1 = $2 = $3 = ""; sub(/^ +/, ""); print mode " " $0 }'
}

@test "every script that is run directly is 100755 in the index [X-56]" {
    local mode path bad=""
    # what they run directly: the scripts of the suite and its tools
    for path in install_mediamtx.sh lyrebird-alerts.sh lyrebird-diagnostics.sh lyrebird-metrics.sh lyrebird-mic-check.sh \
        lyrebird-orchestrator.sh lyrebird-storage.sh lyrebird-stream-manager.sh lyrebird-updater.sh usb-audio-mapper.sh \
        tools/soak/lyrebird-soak.sh tools/soak/lyrebird-soak-observer.sh; do
        mode="$(tracked_modes | awk -v p="$path" '$2 == p { print $1 }')"
        [[ "$mode" == 100755 ]] || bad+=" ${path}(${mode:-untracked})"
    done
    [ -z "$bad" ] || {
        echo "not 100755 in the index:$bad"
        false
    }
}

@test "no tracked file that starts with a shebang is left at 100644, except the test files bats runs and the sourced-only library [X-56]" {
    local mode path first bad=""
    while read -r mode path; do
        case "$path" in
            *.bats | lyrebird-common.sh) continue ;;
        esac
        first="$(head -c 2 "$ROOT/$path" 2>/dev/null || true)"
        if [[ "$first" == '#!' && "$mode" != 100755 ]]; then
            bad+=" ${path}(${mode})"
        fi
    done < <(tracked_modes)
    [ -z "$bad" ] || {
        echo "a shebang and not executable in the index:$bad"
        false
    }
}

@test "the files that are sourced, not run, are not required to be executable: the helpers under tests/ are 100644 and the library is either [X-56]" {
    local mode path bad=""
    while read -r mode path; do
        case "$path" in
            tests/*.bash)
                [[ "$mode" == 100644 ]] || bad+=" ${path}(${mode})"
                ;;
        esac
    done < <(tracked_modes)
    [ -z "$bad" ] || {
        echo "sourced helpers that are executable:$bad"
        false
    }
    # the library is sourced by every script; nothing requires it to be executable
    mode="$(tracked_modes | awk '$2 == "lyrebird-common.sh" { print $1 }')"
    [[ "$mode" == 100644 || "$mode" == 100755 ]]
}

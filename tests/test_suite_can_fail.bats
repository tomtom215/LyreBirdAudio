#!/usr/bin/env bats
# Every test file must be able to fail. Six files used to source their script
# in setup() and then run `set +euo pipefail`; sourcing also replaced bats'
# EXIT/ERR traps, so a failing assertion in the middle of a test was ignored
# and only the last command decided the result (docs/ENGINEERING-REVIEW-2026-07.md
# §9, U9). Re-introducing that pattern in any file must fail here.
#
# For each tests/*.bats, run a copy with this test appended and check that
# bats reports it as failed:
#   @test "zz suite canary" { [ 1 -eq 2 ]; true; }
# The copy sits in a mirror of the project made of symlinks, so its setup()
# resolves PROJECT_ROOT, `load` helpers and scripts exactly as the original.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    MIRROR="$(mktemp -d)"
    mkdir "$MIRROR/tests"
    local e
    for e in "$PROJECT_ROOT"/* "$PROJECT_ROOT"/.[!.]*; do
        [[ -e "$e" ]] || continue
        case "${e##*/}" in tests | .git) continue ;; esac
        ln -s "$e" "$MIRROR/"
    done
    for e in "$PROJECT_ROOT"/tests/*; do
        ln -s "$e" "$MIRROR/tests/"
    done
}

teardown() {
    rm -rf -- "$MIRROR"
}

@test "a failing assertion mid-test fails the test, in every test file" {
    local f name result failed=() path=""
    # Run the real bats entry point, not the internal launcher that this run
    # put on PATH, and with a clean environment so the inner run does not pick
    # up this run's BATS_* state.
    local dir
    while IFS= read -r -d: dir; do
        [[ "$dir" == *bats-core* ]] || path+="${path:+:}$dir"
    done <<<"$PATH:"
    for f in "$PROJECT_ROOT"/tests/*.bats; do
        name="${f##*/}"
        [[ "$name" == "${BATS_TEST_FILENAME##*/}" ]] && continue
        rm "$MIRROR/tests/$name"
        {
            cat "$f"
            printf '\n@test "zz suite canary" {\n    [ 1 -eq 2 ]\n    true\n}\n'
        } >"$MIRROR/tests/$name"
        result="$(env -i PATH="$path" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
            "$BATS_ROOT/bin/bats" -f 'zz suite canary' "$MIRROR/tests/$name" 2>&1 || true)"
        if ! grep -q '^not ok 1 zz suite canary' <<<"$result"; then
            failed+=("$name")
        fi
    done
    if ((${#failed[@]})); then
        printf 'cannot fail: %s\n' "${failed[@]}"
        false
    fi
}

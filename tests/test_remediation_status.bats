#!/usr/bin/env bats
# Mechanical check of docs/remediation-status.json: a finding may only be
# marked "fixed" when every test it names exists, so the register cannot claim
# a fix that has no regression test.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    STATUS="$ROOT/docs/remediation-status.json"
    REGISTER="$ROOT/docs/REMEDIATION-2026-11.md"
}

@test "status file is valid JSON with the required fields and unique ids" {
    run jq -e '
        .schema == 1
        and (.items | length > 0)
        and ([.items[].id] | length == (unique | length))
        and (all(.items[]; (.id | test("^(LB|X|DOC)-[0-9]+$"))
            and (.title | length > 0)
            and (.severity | test("^P[0-3]$"))
            and (.phase | type == "number")
            and (.status as $s | ["open","fixed","documented-hw","wontfix"] | index($s) != null)
            and (.tests | type == "array")))' "$STATUS"
    [ "$status" -eq 0 ]
}

@test "every LB-01..LB-24 finding is tracked, and appears in the register" {
    local n id
    for n in $(seq 1 24); do
        id="$(printf 'LB-%02d' "$n")"
        run jq -e --arg id "$id" '[.items[] | select(.id == $id)] | length == 1' "$STATUS"
        [ "$status" -eq 0 ] || { echo "missing in status file: $id"; return 1; }
        grep -q -- "$id" "$REGISTER" || { echo "missing in register: $id"; return 1; }
    done
}

@test "findings marked fixed or documented-hw name at least one test, and every named test exists" {
    local id name missing=0
    while IFS=$'\t' read -r id name; do
        if [[ -z "$name" ]]; then
            echo "no test named for $id"
            missing=1
            continue
        fi
        if ! grep -rqF -- "@test \"$name\"" "$ROOT"/tests/*.bats; then
            echo "test named by $id does not exist: $name"
            missing=1
        fi
    done < <(jq -r '.items[] | select(.status == "fixed" or .status == "documented-hw")
        | .id as $id | (if (.tests | length) == 0 then [""] else .tests end)[] | "\($id)\t\(.)"' "$STATUS")
    [ "$missing" -eq 0 ]
}

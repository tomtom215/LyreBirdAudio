#!/usr/bin/env bats
# tests/README.md lists every test file with its test count and states the totals (register: DOC-02).
# The table is generated from `bats --count`; these tests fail when it is out of date.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    README="${TESTS_README:-$PROJECT_ROOT/tests/README.md}"
}

@test "tests/README.md lists every test file once, and lists no file that does not exist [DOC-02]" {
    local f name listed missing=0
    for f in "$PROJECT_ROOT"/tests/*.bats; do
        name="$(basename "$f" .bats)"
        listed="$(grep -o "\`$name\` ([0-9]*)" "$README" | wc -l)"
        [ "$listed" -eq 1 ] || {
            echo "$name is listed $listed times"
            missing=1
        }
    done
    while read -r name; do
        [ -f "$PROJECT_ROOT/tests/$name.bats" ] || {
            echo "tests/README.md lists $name, which is not a file"
            missing=1
        }
    done < <(grep -o '`test_[a-z0-9_]*` ([0-9]*)' "$README" | sed -E 's/^`([^`]*)`.*/\1/')
    [ "$missing" -eq 0 ]
}

@test "the counts in tests/README.md are the counts of bats --count: each file, and the total [DOC-02]" {
    local f name want got missing=0 files total
    for f in "$PROJECT_ROOT"/tests/*.bats; do
        name="$(basename "$f" .bats)"
        want="$(bats --count "$f")"
        got="$(grep -o "\`$name\` ([0-9]*)" "$README" | head -1 | sed -E 's/.*\(([0-9]+)\).*/\1/')"
        [ "$want" = "$got" ] || {
            echo "$name: README says $got, bats counts $want"
            missing=1
        }
    done
    total="$(bats --count "$PROJECT_ROOT/tests/")"
    files="$(ls "$PROJECT_ROOT"/tests/*.bats | wc -l)"
    grep -qF "**$total tests in $files files**" "$README" || {
        echo "the total in tests/README.md is not $total tests in $files files"
        missing=1
    }
    [ "$missing" -eq 0 ]
}

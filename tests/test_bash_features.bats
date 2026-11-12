#!/usr/bin/env bats
# Bash features newer than the oldest Bash the scripts claim to need (register: X-63).
# The suite itself runs on one Bash (5.2); this guard is the mechanical part of the
# compatibility claim: a feature that needs a newer Bash than 4.2 must not appear.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

scripts() {
    ls "$PROJECT_ROOT"/lyrebird-*.sh "$PROJECT_ROOT"/install_mediamtx.sh "$PROJECT_ROOT"/usb-audio-mapper.sh "$PROJECT_ROOT"/tools/soak/*.sh
}

@test "no script uses a negative array subscript, which needs Bash 4.3 [X-63]" {
    local f hits=""
    for f in $(scripts); do
        # ${arr[-1]} and arr[-1]=...; not a ${var:-default} or a [-flag] in a test
        if grep -nE '\$\{[A-Za-z_][A-Za-z_0-9]*\[-[0-9]+\]\}|^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*\[-[0-9]+\]=' "$f" >/dev/null; then
            hits+="$f: $(grep -nE '\$\{[A-Za-z_][A-Za-z_0-9]*\[-[0-9]+\]\}|^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*\[-[0-9]+\]=' "$f" | head -3 | tr '\n' ' ')"$'\n'
        fi
    done
    [ -z "$hits" ] || {
        echo "negative array subscripts (Bash 4.3):"
        echo "$hits"
        false
    }
}

@test "no script uses namerefs, wait -n, mapfile -d, \${var@X} transforms or EPOCHSECONDS, which need Bash 4.3 to 5.0 [X-63]" {
    local f hits=""
    for f in $(scripts); do
        grep -nE '(^|[[:space:];])(local|declare|typeset)[[:space:]]+-[a-zA-Z]*n[a-zA-Z]*[[:space:]]|(^|[[:space:];])wait[[:space:]]+-n|mapfile[[:space:]]+-[a-zA-Z]*d|\$\{[A-Za-z_][A-Za-z_0-9]*@[QEPAaUuLK]\}|EPOCHSECONDS|EPOCHREALTIME' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s#^#$f:#" >>"$BATS_TEST_TMPDIR/hits" || true
    done
    [ ! -s "$BATS_TEST_TMPDIR/hits" ] || {
        cat "$BATS_TEST_TMPDIR/hits"
        false
    }
}

@test "the soak observer's own header does not claim a platform or Bash it was never run on [X-64]" {
    local head
    head="$(sed -n 1,12p "$PROJECT_ROOT/tools/soak/lyrebird-soak-observer.sh")"
    [[ "$head" != *"Linux or macOS"* ]]
    [[ "$head" != *"bash 3.2 or later"* ]]
    [[ "$head" == *"never run on macOS"* ]]
}

#!/usr/bin/env bats
# X-14: emergency eviction order and name handling.
#
# emergency_cleanup deletes the oldest recordings first (by design it is not
# gated on the clock sanity floor: a full disk must be freed). The order must be
# deterministic, and the listing must survive any legal file name: the old
# `find -printf '%T+ %p\n' | sort | head | cut` pipeline split a name containing
# a newline into two "paths" and deleted the second one relative to the current
# directory, outside every configured directory.

load scratch_tmpdir
load storage_helper

setup() {
    scratch_setup
    storage_setup
}

teardown() {
    storage_teardown
    scratch_teardown
}

# Paths a dry-run emergency_cleanup would evict from the recording directory,
# in order, relative to it (names must not contain newlines).
_dry_run_order() {
    ST_ENV=(DRY_RUN=true)
    storage_run emergency_cleanup | sed -n "s|.*Would delete emergency recording: $ST_REC/||p"
}

@test "emergency eviction takes the oldest recordings first [X-14]" {
    local i
    for i in 1 2 3 4 5; do
        echo data >"$ST_REC/seg_$i.opus"
        touch -d "@$((1700000000 + (6 - i) * 100))" "$ST_REC/seg_$i.opus" # seg_5 oldest
    done
    run _dry_run_order
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'seg_5.opus\nseg_4.opus\nseg_3.opus\nseg_2.opus\nseg_1.opus')" ]
}

@test "emergency eviction compares mtimes numerically, not as text [X-14]" {
    # "999" sorts after "1000" as text; the older file must still go first.
    echo data >"$ST_REC/newer.opus"
    echo data >"$ST_REC/older.opus"
    touch -d @1000 "$ST_REC/newer.opus"
    touch -d @999 "$ST_REC/older.opus"
    run _dry_run_order
    [ "$output" = "$(printf 'older.opus\nnewer.opus')" ]
}

@test "recordings with equal mtimes are evicted in byte-wise name order [X-14]" {
    local n
    for n in delta.opus Charlie.opus alpha.opus bravo.opus B_x.opus aa.opus; do
        echo data >"$ST_REC/$n"
        touch -d @1700000000 "$ST_REC/$n"
    done
    run _dry_run_order
    [ "$output" = "$(printf 'B_x.opus\nCharlie.opus\naa.opus\nalpha.opus\nbravo.opus\ndelta.opus')" ]
}

@test "the tie-break order does not depend on the caller's locale [X-14]" {
    # In en_US collation punctuation and case are ignored at first level, so
    # "a_b" < "aB" < "A_c"; byte order is "A_c" < "aB" < "a_b". Needs the glibc
    # locale sources (compiled here into a private LOCPATH); skipped without them.
    command -v localedef >/dev/null 2>&1 && [ -r /usr/share/i18n/locales/en_US ] \
        || skip "localedef or the en_US locale source is not installed"
    mkdir -p "$ST_ROOT/locale"
    localedef -i en_US -f UTF-8 "$ST_ROOT/locale/en_US.UTF-8" >/dev/null 2>&1 || true
    [ -d "$ST_ROOT/locale/en_US.UTF-8" ] || skip "could not compile an en_US locale here"
    [ "$(LOCPATH="$ST_ROOT/locale" LC_ALL=en_US.UTF-8 sort <<<"$(printf 'a_b\naB\nA_c')" | head -n 1)" = "a_b" ] \
        || skip "the compiled locale does not collate differently from C"

    local n
    for n in a_b.opus aB.opus A_c.opus b.opus; do
        echo data >"$ST_REC/$n"
        touch -d @1700000000 "$ST_REC/$n"
    done
    ST_ENV=(DRY_RUN=true LOCPATH="$ST_ROOT/locale" LC_ALL=en_US.UTF-8)
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [ "$(sed -n "s|.*Would delete emergency recording: $ST_REC/||p" <<<"$output")" = "$(printf 'A_c.opus\naB.opus\na_b.opus\nb.opus')" ]
}

@test "mtime ties inside a stream directory are broken by full path [X-14]" {
    mkdir -p "$ST_REC/b" "$ST_REC/a"
    echo data >"$ST_REC/b/audio_000.opus"
    echo data >"$ST_REC/a/audio_001.opus"
    echo data >"$ST_REC/a/audio_000.opus"
    touch -d @1700000000 "$ST_REC/b/audio_000.opus" "$ST_REC/a/audio_001.opus" "$ST_REC/a/audio_000.opus"
    run _dry_run_order
    [ "$output" = "$(printf 'a/audio_000.opus\na/audio_001.opus\nb/audio_000.opus')" ]
}

@test "emergency eviction deletes at most EMERGENCY_MAX_DELETE files per run, oldest first [X-14]" {
    local i
    for i in $(seq 1 105); do
        echo data >"$ST_REC/seg_$(printf '%03d' "$i").opus"
        touch -d "@$((1700000000 + i * 60))" "$ST_REC/seg_$(printf '%03d' "$i").opus"
    done
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [[ "$output" == *"Deleted 100 oldest recording(s)"* ]]
    run find "$ST_REC" -type f -printf '%f\n'
    [ "$(sort <<<"$output")" = "$(printf 'seg_101.opus\nseg_102.opus\nseg_103.opus\nseg_104.opus\nseg_105.opus')" ]
}

@test "pre-NTP-epoch recordings are evicted first and are not exempt from emergency eviction [X-14]" {
    # By design, emergency eviction is size-driven, not clock-gated (the
    # age-based exemption lives in cleanup_recordings): files written under a
    # 1970 clock are simply the oldest.
    echo data >"$ST_REC/sane.opus"
    echo data >"$ST_REC/from1970.opus"
    echo data >"$ST_REC/from1970b.opus"
    touch -d "2 days ago" "$ST_REC/sane.opus"
    touch -d @1000000 "$ST_REC/from1970.opus"
    touch -d @500 "$ST_REC/from1970b.opus"
    run _dry_run_order
    [ "$output" = "$(printf 'from1970b.opus\nfrom1970.opus\nsane.opus')" ]

    # With room for only one eviction the oldest pre-epoch file is the one that goes.
    local i
    for i in $(seq 1 100); do
        echo data >"$ST_REC/pad_$i.opus"
        touch -d "@$((1700000000 + i))" "$ST_REC/pad_$i.opus"
    done
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [ ! -e "$ST_REC/from1970b.opus" ]
    [ ! -e "$ST_REC/from1970.opus" ]
    [ -f "$ST_REC/pad_100.opus" ]       # 103 candidates: the 100 oldest go, pad_99/pad_100/sane stay
}

@test "a newline in a file name cannot make eviction delete anything outside the recording directory [X-14 regression]" {
    # Name "x\nvictim.opus": the old listing produced the line "victim.opus",
    # which rm then resolved against the current directory.
    echo precious >"$ST_CWD/victim.opus"
    echo data >"$ST_REC/$(printf 'x\nvictim.opus')"
    touch -d "2 days ago" "$ST_REC/$(printf 'x\nvictim.opus')"
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]
    [ -f "$ST_CWD/victim.opus" ]                                  # outside the directory: untouched
    [ ! -e "$ST_REC/$(printf 'x\nvictim.opus')" ]                 # the recording itself was evicted
}

@test "awkward but legal file names are evicted whole, by retention and by emergency cleanup [X-14 regression]" {
    local dir name
    local -a names=(
        '-rf.opus'
        '--no-preserve-root.aac'
        'two  spaces.mp3'
        ' leading space.opus'
        '*.opus'
        '?.opus'
        '[a].opus'
        "it's.opus"
        '$(touch pwned).opus'
        '`touch pwned2`.opus'
        "$(printf 'a\nb.opus')"
        "$(printf 'tab\there.opus')"
    )
    for dir in age emerg; do
        mkdir -p "$ST_REC/$dir"
        for name in "${names[@]}"; do
            echo data >"$ST_REC/$dir/$name"
        done
        # Bystanders: not recordings, and a recording one level up.
        echo keep >"$ST_REC/$dir/keep.txt"
    done
    find "$ST_REC/age" -type f -exec touch -d "45 days ago" {} +
    find "$ST_REC/emerg" -type f -exec touch -d "2 days ago" {} +
    echo keep >"$ST_CWD/pwned"
    echo keep >"$ST_CWD/pwned2"

    run storage_run cleanup_recordings
    [ "$status" -eq 0 ]
    run storage_run emergency_cleanup
    [ "$status" -eq 0 ]

    # Only the two bystanders are left (counted by NUL: names may hold newlines).
    [ -f "$ST_REC/age/keep.txt" ]
    [ -f "$ST_REC/emerg/keep.txt" ]
    local left
    left="$(find "$ST_REC" -type f -print0 | tr -cd '\0' | wc -c)"
    [ "$left" -eq 2 ] || { echo "files left: $left"; find "$ST_REC" -type f -print0 | tr '\0' '|'; return 1; }
    [ -f "$ST_CWD/pwned" ]      # nothing executed the names
    [ -f "$ST_CWD/pwned2" ]
}

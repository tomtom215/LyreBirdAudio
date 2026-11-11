# shellcheck shell=bash
# A small validator for the Prometheus text exposition format (0.0.4), for tests
# that must prove a scrape is accepted by a real parser instead of grepping for
# the metrics they expect. Portable awk (mawk/gawk/busybox): no gensub, no
# match() arrays, no regex intervals.
#
#   prom_validate FILE      prints one line per problem; returns 1 if there are any
#
# Checks: sample syntax (name, label pairs with only \\ \" \n escapes, numeric
# value, optional integer timestamp, nothing after), no empty values, HELP and TYPE
# at most once per family and before its first sample, TYPE one of the known kinds,
# all samples of a family contiguous, no duplicate series, trailing newline, no NUL
# bytes and valid UTF-8 (label values must be).

prom_validate() {
    local file="$1" rc=0

    if [[ ! -s "$file" ]]; then
        echo "document is empty"
        return 1
    fi
    if [[ "$(tail -c 1 "$file" | od -An -c | tr -d ' ')" != '\n' ]]; then
        echo "document does not end with a newline"
        rc=1
    fi
    if [[ "$(tr -d '\0' <"$file" | wc -c)" != "$(wc -c <"$file")" ]]; then
        echo "document contains NUL bytes"
        rc=1
    fi
    if command -v iconv >/dev/null 2>&1 && ! iconv -f UTF-8 -t UTF-8 "$file" >/dev/null 2>&1; then
        echo "document is not valid UTF-8"
        rc=1
    fi

    awk '
    function err(msg) { printf "line %d: %s: %s\n", NR, msg, $0; bad = 1 }

    # s starts right after the "{". On success sets LEND to the index (in s) of the
    # first character after the closing "}" and returns 1.
    function parse_labels(s,    i, n, c, name, e) {
        n = length(s); i = 1
        while (1) {
            c = substr(s, i, 1)
            if (c == "}") { LEND = i + 1; return 1 }
            name = ""
            while (i <= n) {
                c = substr(s, i, 1)
                if (c == "=") break
                name = name c; i++
            }
            if (i > n) return 0
            if (name !~ /^[a-zA-Z_][a-zA-Z0-9_]*$/) return 0
            i++
            if (substr(s, i, 1) != "\"") return 0
            i++
            while (1) {
                if (i > n) return 0
                c = substr(s, i, 1)
                if (c == "\\") {
                    e = substr(s, i + 1, 1)
                    if (e != "\\" && e != "\"" && e != "n") return 0
                    i += 2; continue
                }
                if (c == "\"") { i++; break }
                i++
            }
            c = substr(s, i, 1)
            if (c == ",") { i++; continue }
            if (c == "}") { LEND = i + 1; return 1 }
            return 0
        }
    }

    function is_value(v) {
        return (v ~ /^[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$/ || v ~ /^[-+]?Inf$/ || v == "NaN")
    }

    {
        line = $0
        if (line == "") next
        if (line ~ /^# HELP /) {
            split(line, a, " ")
            name = a[3]
            if (name !~ /^[a-zA-Z_:][a-zA-Z0-9_:]*$/) { err("HELP with an invalid metric name"); next }
            if (name in helped) err("second HELP for " name)
            if (name in sampled) err("HELP for " name " after its samples")
            helped[name] = 1
            next
        }
        if (line ~ /^# TYPE /) {
            split(line, a, " ")
            name = a[3]; kind = a[4]
            if (name !~ /^[a-zA-Z_:][a-zA-Z0-9_:]*$/) { err("TYPE with an invalid metric name"); next }
            if (kind !~ /^(counter|gauge|histogram|summary|untyped)$/) err("unknown TYPE " kind)
            if (name in typed) err("second TYPE for " name)
            if (name in sampled) err("TYPE for " name " after its samples")
            typed[name] = 1
            next
        }
        if (line ~ /^#/) next

        if (!match(line, /^[a-zA-Z_:][a-zA-Z0-9_:]*/)) { err("sample does not start with a metric name"); next }
        name = substr(line, 1, RLENGTH)
        rest = substr(line, RLENGTH + 1)
        if (substr(rest, 1, 1) == "{") {
            tail = substr(rest, 2)
            if (!parse_labels(tail)) { err("malformed label set"); next }
            rest = substr(tail, LEND)
        }
        series = substr(line, 1, length(line) - length(rest))
        if (rest !~ /^[ \t]+[^ \t]/) { err("sample has no value"); next }
        n = split(rest, tok, /[ \t]+/)
        # tok[1] is empty (leading blank), tok[2] the value, tok[3] an optional timestamp
        if (!is_value(tok[2])) { err("invalid sample value \"" tok[2] "\""); next }
        if (n >= 3 && tok[3] !~ /^-?[0-9]+$/) { err("invalid timestamp \"" tok[3] "\""); next }
        if (n > 3) { err("trailing text after the value"); next }

        if (name != current) {
            if (name in sampled) err("samples of " name " are not contiguous")
            current = name
        }
        sampled[name] = 1
        if (series in seen) err("duplicate series " series)
        seen[series] = 1
    }
    END { exit bad }
    ' "$file" || rc=1

    return "$rc"
}

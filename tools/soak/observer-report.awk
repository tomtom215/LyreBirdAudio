# observer-report.awk - analyse a lyrebird-soak-observer run.
#
# Input: observer.tsv (wall, stream, event, value; header line).
# Variables: gap (seconds of silence that count as a gap), boot (seconds within
# which audio must return after power-on), streams (the run's streams file),
# node (the node's events.tsv, optional: its fault windows explain gaps).
# Exits 1 if any criterion fails. Portable awk: no gawk extensions.

BEGIN {
    FS = "\t"
    while ((getline line < streams) > 0) {
        split(line, f, "\t")
        url[f[1]] = f[2]
        if (f[1] + 0 > nstreams) nstreams = f[1] + 0
    }
    # Node fault windows: fault_start .. recovered / not_recovered / fault_failed.
    if (node != "") {
        while ((getline line < node) > 0) {
            split(line, f, "\t")
            if (f[5] == "fault_start") { open_start = f[1] + 0; open = 1 }
            else if (open && (f[5] == "recovered" || f[5] == "not_recovered" || f[5] == "fault_failed")) {
                nwin++; ws[nwin] = open_start; we[nwin] = f[1] + 0; wk[nwin] = "node fault"; open = 0
            }
        }
        if (open) { nwin++; ws[nwin] = open_start; we[nwin] = 2147483647; wk[nwin] = "node fault" }
    }
}

FNR == 1 { next }

{
    t = $1 + 0; s = $2; ev = $3
    if (first == "") first = t
    last = t
    if (ev == "power_off") {
        off_t = t; cuts++
    } else if (ev == "power_on") {
        nwin++; ws[nwin] = off_t; we[nwin] = t + boot; wk[nwin] = "power cut"
        npow++; pon[npow] = t
        for (i = 1; i <= nstreams; i++) waiting[npow, i] = 1
    } else if (ev == "audio") {
        if ((s in prev) && t - prev[s] > gap) add_gap(s, prev[s], t)
        if (!(s in prev)) firsta[s] = t
        prev[s] = t
        audio_n[s]++
        for (p = 1; p <= npow; p++)
            if (waiting[p, s] && t >= pon[p]) { tta[p, s] = t - pon[p]; waiting[p, s] = 0 }
    }
}

function add_gap(s, a, b,   i, why) {
    why = ""
    for (i = 1; i <= nwin; i++)
        if (a + 1 >= ws[i] - gap && a + 1 <= we[i]) { why = wk[i]; break }
    g_n[s]++
    if (why == "") {
        u_n[s]++; u_total[s] += b - a
        if (b - a > u_max[s]) u_max[s] = b - a
        if (u_n[s] <= 10) u_txt[s, u_n[s]] = sprintf("%s  %ds", fmt(a), b - a)
    }
}

function fmt(t,   cmd, out) {
    # GNU date, then BSD date (macOS).
    cmd = "date -u -d @" t " '+%F %TZ' 2>/dev/null || date -u -r " t " '+%F %TZ' 2>/dev/null"
    out = ""
    cmd | getline out
    close(cmd)
    return out == "" ? t : out
}

function verdict(status, text) {
    printf "  %-6s %s\n", status, text
    if (status == "FAIL") fails++
}

END {
    if (first == "") { print "no observations"; exit 1 }
    span = last - first
    printf "Observed: %s to %s (%.1f h), %d stream(s), %d power cut(s)\n\n", fmt(first), fmt(last), span / 3600, nstreams, cuts + 0
    for (i = 1; i <= nstreams; i++) {
        s = i ""
        # A stream silent at the end of the run has a trailing gap.
        if ((s in prev) && last - prev[s] > gap) add_gap(s, prev[s], last)
        printf "Stream %s: %s\n", s, url[s]
        if (!(s in prev)) { printf "  never received audio\n"; never++; continue }
        printf "  audio in %.3f%% of seconds; gaps > %ds: %d (%d not explained by a power cut or node fault)\n",
            100 * audio_n[s] / (last - firsta[s] + 1), gap, g_n[s], u_n[s]
        for (k = 1; k <= u_n[s] && k <= 10; k++) printf "    %s\n", u_txt[s, k]
    }
    print ""
    if (npow) {
        print "Time to audio after power-on (s):"
        for (p = 1; p <= npow; p++) {
            line = sprintf("  %s ", fmt(pon[p]))
            for (i = 1; i <= nstreams; i++) {
                if (waiting[p, i] && pon[p] + boot > last) { line = line sprintf(" stream %d: (run ended)", i); continue }
                if (waiting[p, i] || tta[p, i] > boot) { late++; line = line sprintf(" stream %d: >%d", i, boot) }
                else line = line sprintf(" stream %d: %d", i, tta[p, i])
            }
            print line
        }
        print ""
    }
    print "Verdict:"
    if (never) verdict("FAIL", never " stream(s) never delivered audio")
    tot = 0
    for (i = 1; i <= nstreams; i++) tot += u_n[i ""]
    if (tot) verdict("FAIL", tot " unexplained gap(s) in the audio")
    else verdict("PASS", "no unexplained gaps")
    if (npow) {
        if (late) verdict("FAIL", late " stream restart(s) after power-on took longer than " boot "s")
        else verdict("PASS", "audio back within " boot "s after every power cut")
    }
    print ""
    if (fails) { print "RESULT: FAIL"; exit 1 }
    print "RESULT: PASS"
}

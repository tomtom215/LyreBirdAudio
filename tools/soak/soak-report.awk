# soak-report.awk - analyse a lyrebird-soak run.
#
# Input files, in order: events.tsv, samples.tsv (both with a header line).
# Variables: interval and warmup (seconds), exhaustion_days.
# Prints a report and exits 1 if any criterion fails.
#
# Portable awk (gawk, mawk, BusyBox): no asort, gensub or length(array).

BEGIN {
    FS = "\t"
    fails = 0
    warns = 0
}

# ---------------------------------------------------------------- events.tsv
FNR == NR {
    if (FNR == 1) next
    ev = $5
    split($6, w, " ")
    kind = w[1]
    if (ev == "fault_start") {
        injected[kind]++
        if (!(kind in seen_kind)) { seen_kind[kind] = 1; kinds[++nkinds] = kind }
        total_injected++
    } else if (ev == "recovered" || ev == "not_recovered") {
        secs = ""
        for (i = 2; i in w; i++) if (w[i] ~ /^seconds=/) secs = substr(w[i], 9)
        if (!(kind in seen_kind)) { seen_kind[kind] = 1; kinds[++nkinds] = kind }
        if (ev == "recovered") {
            recovered[kind]++
            rec_n[kind]++
            rec_v[kind, rec_n[kind]] = secs + 0
        } else {
            not_recovered[kind]++
            nr_detail[++n_nr] = $6
        }
    } else if (ev == "unexpected_reboot") {
        unexpected[++n_unexpected] = $1
    } else if (ev == "fault_skipped") {
        skipped++
    } else if (ev == "restore_failed") {
        restore_failed[++n_restore_failed] = $6
    } else if (ev == "init_unhealthy") {
        init_unhealthy = 1
    }
    next
}

# --------------------------------------------------------------- samples.tsv
FNR == 1 {
    for (i = 1; i <= NF; i++) col[$i] = i
    next
}

{
    n++
    wall = $col["wall"]; up = $col["uptime"]; boot = $col["boot"]
    el = $col["elapsed"] + 0; ok = $col["healthy"]; fault = $col["fault"]
    probs = $col["problems"]
    if (n == 1) { first_wall = wall; first_el = el }
    last_wall = wall; last_el = el
    if (!(boot in seen_boot)) { seen_boot[boot] = 1; boots++ }

    # Sampling gaps within one boot (the harness itself stalled).
    if (n > 1 && boot == prev_boot && up - prev_up > 3 * interval) {
        gaps_harness++
        if (gaps_harness <= 10) harness_gap[gaps_harness] = sprintf("%s: %ds without a sample", fmt(prev_wall), up - prev_up)
    }

    # Name integrity: misnamed or swapped in two consecutive samples.
    bad_name = (probs ~ /(^|,)(misnamed|swap):/)
    if (bad_name && prev_bad_name) {
        name_violations++
        if (name_violations <= 10) name_detail[name_violations] = fmt(wall) " " probs
    }
    prev_bad_name = bad_name

    # Unexplained outages: unhealthy with no fault in progress.
    if (ok == "0" && fault == "-") {
        if (!in_outage) {
            in_outage = 1; out_start_el = el; out_start_wall = wall; out_probs = probs
            out_boot = boot
        }
        out_last_el = el
    } else if (in_outage) {
        close_outage()
    }

    # Stream availability, overall and outside fault windows.
    if (fault == "-") { calm++; if (ok == "1") calm_ok++ }
    if (ok == "1") all_ok++

    # Trend data after warm-up.
    if (el >= warmup) {
        add_point("disk_pct"); add_point("inode_pct"); add_point("mem_avail_kb")
        add_point("mtx_rss_kb"); add_point("ffmpeg_rss_kb"); add_point("mtx_fds")
        add_point("log_kb"); add_point("zombies")
    }

    prev_boot = boot; prev_up = up; prev_wall = wall
}

function close_outage(   d) {
    d = out_last_el - out_start_el + interval
    outages++
    outage_total += d
    if (outages <= 20) outage_detail[outages] = sprintf("%s  %ds  %s", fmt(out_start_wall), d, out_probs)
    in_outage = 0
}

function add_point(name,   v) {
    v = $col[name]
    if (v == "-" || v == "") return
    v += 0
    tn[name]++
    sx[name] += el; sy[name] += v; sxx[name] += el * el; sxy[name] += el * v
    tlast[name] = v
    if (!(name in tfirst)) tfirst[name] = v
}

# Least-squares slope per day; "" if not computable.
function slope_per_day(name,   d) {
    if (tn[name] < 10) return ""
    d = tn[name] * sxx[name] - sx[name] * sx[name]
    if (d <= 0) return ""
    return (tn[name] * sxy[name] - sx[name] * sy[name]) / d * 86400
}

function fmt(t,   cmd, out) {
    cmd = "date -u -d @" t " '+%F %TZ' 2>/dev/null"
    out = ""
    cmd | getline out
    close(cmd)
    return out == "" ? t : out
}

function verdict(status, text) {
    printf "  %-13s %s\n", status, text
    if (status == "FAIL") fails++
    if (status == "WARN") warns++
}

function median(kind,   i, j, k, a, m) {
    m = rec_n[kind]
    for (i = 1; i <= m; i++) a[i] = rec_v[kind, i]
    for (i = 2; i <= m; i++) { k = a[i]; for (j = i - 1; j >= 1 && a[j] > k; j--) a[j + 1] = a[j]; a[j + 1] = k }
    lo = a[1]; hi = a[m]
    return (m % 2) ? a[(m + 1) / 2] : (a[m / 2] + a[m / 2 + 1]) / 2
}

END {
    if (in_outage) close_outage()
    if (n == 0) { print "no samples"; exit 1 }
    dur = last_el - first_el
    days = dur / 86400

    printf "Run:      %s to %s\n", fmt(first_wall), fmt(last_wall)
    printf "Covered:  %.1f h (harness elapsed time), %d samples, %d boot(s)\n", dur / 3600, n, boots
    printf "Healthy:  %.3f%% of all samples, %.3f%% outside fault windows\n", 100 * all_ok / n, calm ? 100 * calm_ok / calm : 100
    print ""

    print "Faults:"
    if (total_injected == 0 && nkinds == 0) print "  none injected (observation-only run)"
    for (k = 1; k <= nkinds; k++) {
        kind = kinds[k]
        line = sprintf("  %-18s injected %3d  recovered %3d  not recovered %3d", kind, injected[kind], recovered[kind], not_recovered[kind])
        if (rec_n[kind] > 0) {
            med = median(kind)
            line = line sprintf("  recovery s: min %d median %d max %d", lo, med, hi)
        }
        print line
    }
    if (skipped) printf "  skipped (nothing to act on): %d\n", skipped
    print ""

    print "Verdict:"
    if (init_unhealthy) verdict("FAIL", "node was not healthy at init")
    if (n_nr) {
        verdict("FAIL", n_nr " fault(s) not recovered within the deadline:")
        for (i = 1; i <= n_nr && i <= 10; i++) print "                  " nr_detail[i]
    } else if (total_injected) {
        verdict("PASS", "every injected fault recovered within its deadline")
    } else {
        verdict("NOT ASSESSED", "fault recovery (no faults injected)")
    }

    if (n_unexpected) {
        verdict("FAIL", n_unexpected " reboot(s) the harness did not cause (crash, watchdog or power loss)")
        for (i = 1; i <= n_unexpected && i <= 10; i++) print "                  detected at " fmt(unexpected[i])
    } else {
        verdict("PASS", "no unexpected reboots")
    }

    if (name_violations) {
        verdict("FAIL", name_violations " sample(s) with a device under the wrong name (persisting 2+ samples)")
        for (i = 1; i <= name_violations && i <= 10; i++) print "                  " name_detail[i]
    } else {
        verdict("PASS", "device names held")
    }

    if (outages) {
        verdict("FAIL", sprintf("%d outage(s) outside fault windows, %ds in total:", outages, outage_total))
        for (i = 1; i <= outages && i <= 20; i++) print "                  " outage_detail[i]
    } else {
        verdict("PASS", "no outages outside fault windows")
    }

    if (n_restore_failed) verdict("FAIL", n_restore_failed " fault undo(s) failed: " restore_failed[1])

    if (gaps_harness) {
        verdict("WARN", gaps_harness " gap(s) in sampling (harness stalled or node frozen):")
        for (i = 1; i <= gaps_harness && i <= 10; i++) print "                  " harness_gap[i]
    }

    # Exhaustion projections need at least a day of data.
    if (days < 1) {
        verdict("NOT ASSESSED", sprintf("resource trends (%.1f h of data; need 24 h)", dur / 3600))
    } else {
        trend_exhaust("disk_pct", "disk use", "%", 100)
        trend_exhaust("inode_pct", "inode use", "%", 100)
        trend_mem()
        trend_growth("mtx_rss_kb", "MediaMTX RSS", "kB", 5120)
        trend_growth("ffmpeg_rss_kb", "ffmpeg RSS (all)", "kB", 5120)
        trend_growth("mtx_fds", "MediaMTX open files", "", 10)
        trend_growth("log_kb", "log directory", "kB", 10240)
        trend_growth("zombies", "zombie processes", "", 1)
    }

    print ""
    if (fails) { printf "RESULT: FAIL (%d failing, %d warning)\n", fails, warns; exit 1 }
    printf "RESULT: PASS (%d warning)\n", warns
    exit 0
}

function trend_exhaust(name, label, unit, limit,   s, left) {
    s = slope_per_day(name)
    if (s == "") { verdict("NOT ASSESSED", label " trend (no data)"); return }
    if (s <= 0) { verdict("PASS", sprintf("%s flat or falling (%+.3f%s/day, now %s%s)", label, s, unit, tlast[name], unit)); return }
    left = (limit - tlast[name]) / s
    if (left < exhaustion_days)
        verdict("FAIL", sprintf("%s rising %+.3f%s/day; full in about %.1f days (now %s%s)", label, s, unit, left, tlast[name], unit))
    else
        verdict("PASS", sprintf("%s rising %+.3f%s/day; full in about %.0f days (now %s%s)", label, s, unit, left, tlast[name], unit))
}

function trend_mem(   s, left) {
    s = slope_per_day("mem_avail_kb")
    if (s == "") { verdict("NOT ASSESSED", "available memory trend (no data)"); return }
    if (s >= 0) { verdict("PASS", sprintf("available memory flat or rising (%+.0f kB/day)", s)); return }
    left = tlast["mem_avail_kb"] / -s
    if (left < exhaustion_days)
        verdict("FAIL", sprintf("available memory falling %.0f kB/day; exhausted in about %.1f days", -s, left))
    else
        verdict("PASS", sprintf("available memory falling %.0f kB/day; exhausted in about %.0f days", -s, left))
}

function trend_growth(name, label, unit, floor,   s) {
    s = slope_per_day(name)
    if (s == "") return
    # Growth over 30 days above the floor and above 20% of the starting value.
    if (s * 30 > floor && (tfirst[name] == 0 || s * 30 > 0.2 * tfirst[name]))
        verdict("WARN", sprintf("%s growing %+.1f%s/day (first %s, last %s)", label, s, unit, tfirst[name], tlast[name]))
    else
        verdict("PASS", sprintf("%s steady (%+.1f%s/day)", label, s, unit))
}

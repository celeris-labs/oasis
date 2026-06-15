#!/bin/bash
# Analyze Vivado timing & utilization reports for a build directory and print a summary.
# Usage: analyze_reports.sh <build_dir>
set -u

# ---------- Tunable parameters (override via environment) ----------
# Timing: how many failing-path clusters to list, and how many trailing levels of
# the destination instance path to strip when forming a cluster key.
TIMING_CLUSTERS=${TIMING_CLUSTERS:-5}
CLUSTER_STRIP_LEVELS=${CLUSTER_STRIP_LEVELS:-2}
# Nets with fanout above this are treated as clock distribution and excluded from
# the per-cluster fanout average (so it reflects data-path logic fanout).
FO_CLOCK_MAX=${FO_CLOCK_MAX:-50000}
# Utilization: a module in the inst_user_c0_0 table is kept only if it has at least
# this many LUTs AND FFs; HIER_MAX_DEPTH limits how many hierarchy levels are shown
# below inst_user_c0_0 (1 = direct children only, 2 = children + grandchildren).
HIER_CUTOFF_LUT=${HIER_CUTOFF_LUT:-500}
HIER_CUTOFF_FF=${HIER_CUTOFF_FF:-500}
HIER_MAX_DEPTH=${HIER_MAX_DEPTH:-2}
# -------------------------------------------------------------------

DIR=${1:-.}

TIMING="$DIR/timing_report.txt"
UTIL="$DIR/utilization_report.txt"

build_name=$(basename "$(cd "$DIR" && pwd)")
host=$(hostname)
now=$(date '+%Y-%m-%d %H:%M:%S')

echo "OASIS report analysis"
echo "Build:   $build_name  ($DIR)"
echo "Host:    $host"
echo "Run at:  $now"
echo ""

# ---------- Timing ----------
echo "==================== TIMING ===================="
if [ -r "$TIMING" ]; then
    # Worst negative slack (WNS) = most negative violated slack; timing met if none violated.
    awk '
        /^Slack \(/ {
            v = $4; sub(/ns.*/, "", v); val = v + 0
            n++
            if (val < worst || worst == "") worst = val
            if ($0 ~ /VIOLATED/) violated++
        }
        END {
            if ((violated+0) == 0) print "Status: TIMING MET"
            else print "Status: TIMING NOT MET"
            printf "WNS (worst slack):    %.3f ns\n", worst+0
            printf "Failing paths:        %d (of %d reported)\n", violated+0, n
        }
    ' "$TIMING"

    echo ""
    echo "Biggest clusters of failing paths (destination with last $CLUSTER_STRIP_LEVELS levels stripped),"
    echo "with per-cluster averages over its paths:"
    # Cluster every violated path by destination minus last 2 levels, and accumulate
    # per cluster: logic levels, max data-path fanout, and logic/route delay split.
    awk -v FO_CLOCK_MAX="$FO_CLOCK_MAX" -v STRIP="$CLUSTER_STRIP_LEVELS" '
        # Fold the just-finished path metrics into its cluster.
        function flush(   c) {
            if (!cur_violated || curkey == "") return
            cnt[curkey]++
            if (have_ll)  sum_ll[curkey]  += ll
            if (have_fo)  sum_fo[curkey]  += maxfo
            if (have_dpd) { sum_logic[curkey] += logic_pct; sum_route[curkey] += route_pct }
        }
        /^Slack \(/ {
            flush()
            cur_violated = ($0 ~ /VIOLATED/)
            curkey = ""; have_ll = have_fo = have_dpd = 0; maxfo = 0
        }
        cur_violated && /^  Destination:/ {
            d=$2; np=split(d, a, "/")
            keep = np - STRIP; if (keep < 1) keep = np
            curkey=a[1]; for(j=2;j<=keep;j++) curkey=curkey"/"a[j]
        }
        /^  Logic Levels:/ { ll = $3 + 0; have_ll = 1 }
        /^  Data Path Delay:/ {
            if (match($0, /logic[^(]*\(([0-9.]+)%\)/, m)) { logic_pct = m[1] + 0; have_dpd = 1 }
            if (match($0, /route[^(]*\(([0-9.]+)%\)/, m)) { route_pct = m[1] + 0 }
        }
        # Max data-path net fanout (exclude huge clock-distribution nets).
        /net \(fo=[0-9]+/ {
            if (match($0, /fo=([0-9]+)/, m)) {
                f = m[1] + 0
                if (f <= FO_CLOCK_MAX && f > maxfo) { maxfo = f; have_fo = 1 }
            }
        }
        END {
            flush()
            for (k in cnt) printf "%d\t%.1f\t%.0f\t%.0f\t%.0f\t%s\n", \
                cnt[k], sum_ll[k]/cnt[k], sum_fo[k]/cnt[k], \
                sum_logic[k]/cnt[k], sum_route[k]/cnt[k], k
        }
    ' "$TIMING" | sort -rn | head -"$TIMING_CLUSTERS" | awk -F'\t' '
        BEGIN { printf "  %5s  %6s  %7s  %-11s  %s\n", "paths", "levels", "fanout", "logic/route", "cluster" }
        { printf "  %5d  %6s  %7s  %10s  %s\n", $1, $2, $3, ($4"%/"$5"%"), $6 }'
else
    echo "(timing report not found at $TIMING)"
fi

echo ""
# ---------- Utilization ----------
echo "================= UTILIZATION =================="
if [ -r "$UTIL" ]; then
    echo "Device: $(grep -m1 -E '^\| Device' "$UTIL" | sed 's/^| Device[ :]*//')"
    echo ""
    echo "Total resource utilization (cyt_top):  (device: xcu55c / Alveo U55C)"
    # Lines start with '|' so $1 is empty: Instance=$2 Module=$3 PR=$4 PPLOCs=$5
    # TotalLUTs=$6 LogicLUTs=$7 LUTRAMs=$8 SRLs=$9 FFs=$10 RAMB36=$11 RAMB18=$12 URAM=$13 DSP=$14
    # Device capacities for xcu55c-fsvh2892 (Alveo U55C).
    awk -F'|' '
        BEGIN {
            cLUT=1303680; cFF=2607360; cBRAM=2016; cURAM=960; cDSP=9024
            printf "  %-6s %12s %10s %8s\n", "Rsrc", "Used", "Avail", "Util%"
        }
        /^\| cyt_top / {
            for (i=6;i<=14;i++) gsub(/ /,"",$i)
            bram = $11 + 0.5*$12
            printf "  %-6s %12d %10d %7.1f%%\n", "LUTs", $6, cLUT, 100*$6/cLUT
            printf "  %-6s %12d %10d %7.1f%%\n", "FFs",  $10, cFF, 100*$10/cFF
            printf "  %-6s %12g %10d %7.1f%%   (RAMB36: %s, RAMB18: %s)\n", "BRAM", bram, cBRAM, 100*bram/cBRAM, $11, $12
            printf "  %-6s %12d %10d %7.1f%%\n", "URAM", $13, cURAM, 100*$13/cURAM
            printf "  %-6s %12d %10d %7.1f%%\n", "DSPs", $14, cDSP, 100*$14/cDSP
            exit
        }
    ' "$UTIL"

    echo ""
    echo "Major modules within inst_user_c0_0 (kept only if LUTs >= $HIER_CUTOFF_LUT and FFs >= $HIER_CUTOFF_FF):"
    # Walk the hierarchy table from inst_user_c0_0 until its indentation level is left.
    # Show only the shallower "major" levels (not the deep leaf cells).
    awk -F'|' -v CUTOFF_LUT="$HIER_CUTOFF_LUT" -v CUTOFF_FF="$HIER_CUTOFF_FF" -v MAX_DEPTH="$HIER_MAX_DEPTH" '
        function indent(s,   m){ match(s,/^ */); return RLENGTH }
        BEGIN {
            printf "  +-%-46s-+-%9s-+-%9s-+-%7s-+-%6s-+\n", \
                   "----------------------------------------------", \
                   "---------", "---------", "-------", "------"
            printf "  | %-46s | %9s | %9s | %7s | %6s |\n", \
                   "Module", "LUTs", "FFs", "BRAM", "URAM"
            printf "  +-%-46s-+-%9s-+-%9s-+-%7s-+-%6s-+\n", \
                   "----------------------------------------------", \
                   "---------", "---------", "-------", "------"
        }
        /^\|/ {
            raw=$2; name=raw
            gsub(/ +$/,"",name)
            depth=indent(name)
            gsub(/^ +/,"",name)
            if (name ~ /^\(/) next                 # skip self/grouping rows
            if (!seen) {
                if (name=="inst_user_c0_0") { seen=1; base=depth }
                next
            }
            if (depth <= base) { done=1; exit }    # left the subtree
            if (depth > base + 2*MAX_DEPTH) next   # limit hierarchy depth shown
            luts=$6; ffs=$10; ramb36=$11; ramb18=$12; uram=$13
            gsub(/ /,"",luts); gsub(/ /,"",ffs); gsub(/ /,"",ramb36); gsub(/ /,"",ramb18); gsub(/ /,"",uram)
            # Keep a module only if it has at least the cutoff of both LUTs and FFs.
            if (luts+0 < CUTOFF_LUT || ffs+0 < CUTOFF_FF) next
            ind=""; for(i=0;i<(depth-base)/2;i++) ind=ind"  "
            bram = ramb36 + 0.5*ramb18
            printf "  | %-46s | %9s | %9s | %7g | %6s |\n", \
                   substr(ind name, 1, 46), luts, ffs, bram, uram
        }
        END {
            printf "  +-%-46s-+-%9s-+-%9s-+-%7s-+-%6s-+\n", \
                   "----------------------------------------------", \
                   "---------", "---------", "-------", "------"
        }
    ' "$UTIL"
else
    echo "(utilization report not found at $UTIL)"
fi

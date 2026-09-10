#!/bin/bash
# Stress the FSST passthrough path on the FPGA and report per-query deviations.
#
# WHY THIS EXISTS
# ---------------
# The FSST passthrough path wedged (hung forever, host waiting on a result beat
# that never arrived) within 1-3 replications at OASIS_REGEX_TABLE_SLOTS=0.
# Root cause was in rem_engines.sv: the arm retire was written as the `else` of
# the parallel pop, so when a pop was available on the very cycle outCount_q
# reached strings_in_batch_i, the pop won, the count stepped past the target,
# and `outCount_q == strings_in_batch_i` could never match again. Fixed by
# evaluating the retire against outCount_d (the count *after* any pop taken this
# cycle) instead of as the pop's else-branch.
#
# Keep this script around: it is the only reliable way to provoke the race, and
# it distinguishes the two failure modes that look similar from the outside.
#
#   exit != 0 (timeout)        -> WEDGE. The card is poisoned; a fresh process
#                                 then hangs even on an 8000-row scan. REPROGRAM
#                                 before believing any later measurement.
#   exit == 0, nonzero delta   -> MISCOUNT. Run completes, one query returns the
#                                 wrong number of rows. Wedge-era discrepancies
#                                 were always a multiple of 64 (RESULTS_PER_POP);
#                                 a delta that is not tells you it is something
#                                 else.
#
# OPERATIONAL RULES (learned the hard way)
# ----------------------------------------
#   * SIGTERM ONLY when killing a wedged run. `kill -KILL` leaked the 1 GiB
#     hugepage pool irrecoverably and forced a reboot. `timeout -s TERM` below.
#   * Check free_hugepages, never nr_hugepages -- a leaked pool still reads 12.
#   * The DB must be written by a mode-1 (zeroTerminated=1) FSST encoder, or the
#     passthrough will not engage.
#   * Only one process can hold the card. Make sure nothing else is running.
#
# USAGE
#   scripts/regex_fsst_stress.sh                       # 10 reps, slots=0
#   REPS=3 scripts/regex_fsst_stress.sh                # fewer reps
#   OASIS_REGEX_TABLE_SLOTS=1 scripts/regex_fsst_stress.sh   # known-good config
#   TABLE=ocomment PATTERN='.*ing.*' scripts/regex_fsst_stress.sh
#   SMOKE=1 scripts/regex_fsst_stress.sh               # smoke test only, then exit
set -u

DB=${DB:-/scratch/vifranz/regex_fsst.duckdb}
DUCKDB=${DUCKDB:-$(dirname "$0")/../extension/build/release/duckdb}
TABLE=${TABLE:-ocomment128}
COLUMN=${COLUMN:-s}
PATTERN=${PATTERN:-.*ing.*}
REPS=${REPS:-10}
TIMEOUT=${TIMEOUT:-300}
OUTDIR=${OUTDIR:-$(mktemp -d -t regex_fsst_stress.XXXXXX)}
TAG=${TAG:-run}
SMOKE=${SMOKE:-0}

# slots = number of distinct FSST symbol tables live on the card at once.
# 0 = unlimited (fast, and the configuration that provoked the wedge),
# 1 = serialised (was the workaround; ~5x slower).
export OASIS_REGEX_TABLE_SLOTS=${OASIS_REGEX_TABLE_SLOTS:-0}

# The release build links a jemalloc that is not on the default loader path.
export LD_LIBRARY_PATH=$HOME/opt/lib:${LD_LIBRARY_PATH:-}

HP=/sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages

die() { echo "FATAL: $*" >&2; exit 2; }

# ---- preflight -------------------------------------------------------------
[ -x "$DUCKDB" ] || die "no duckdb binary at $DUCKDB (run 'make -j' in extension/)"

# Refuse to start on a poisoned card. A wedge leaves an uninterruptible task holding the
# driver; reprogramming then wedges rmmod too and the module is stuck "going", after which
# every card operation blocks and only a reboot helps. Catching that here costs a second and
# saves an hour -- see scripts/regex_card_health.sh.
health="$(dirname "$0")/regex_card_health.sh"
if [ -x "$health" ]; then
    if ! "$health"; then
        die "card is not healthy (see above). Do NOT reprogram if it says REBOOT REQUIRED."
    fi
fi
[ -r "$DB" ]     || die "no database at $DB"
free=$(cat $HP 2>/dev/null || echo 0)
[ "$free" -ge 2 ] || die "only $free free 1 GiB hugepages. Provision from a real
       terminal (sudo needs a tty), in TWO calls, and re-check *free*_hugepages:
         sudo hdev set hugepages --num-2m 0
         sudo hdev set hugepages --num-1g 12
       If a run wedged, the pool is leaked and only a REBOOT clears it."
stray=$(pgrep -f 'release/duckdb|benchmark_runner|unittest' | grep -v $$ || true)
[ -z "$stray" ] || die "another process is holding the card: $stray"

mkdir -p "$OUTDIR"
echo "db=$DB table=$TABLE pattern=$PATTERN slots=$OASIS_REGEX_TABLE_SLOTS"
echo "outdir=$OUTDIR free_hugepages=$free"

# ---- smoke test ------------------------------------------------------------
# Never start a long hardware run without this: it costs seconds and catches a
# card that is already poisoned from a previous wedge.
# -noheader -list keeps output as bare values; the box-drawing default is UTF-8
# and painful (and easy to mis-parse) to scrape.
run_sql() { timeout -s TERM "$TIMEOUT" stdbuf -oL "$DUCKDB" -readonly "$DB" -noheader -list ; }

cat > "$OUTDIR/smoke.sql" <<EOF
LOAD oasis;
SET threads=2;
SET GLOBAL enable_fsst_vectors=true;
SET oasis_regex_fsst_passthrough=true;
SELECT count(*) FROM $TABLE WHERE $COLUMN SIMILAR TO '$PATTERN';
SELECT count(*) FROM regex_fpga_scan('$TABLE', regex_column := '$COLUMN', pattern := '$PATTERN');
EOF

echo "-- smoke test (2 threads) --"
run_sql < "$OUTDIR/smoke.sql" > "$OUTDIR/smoke.out" 2> "$OUTDIR/smoke.err"
sec=$?
[ $sec -eq 0 ] || die "smoke test exited $sec -- card is likely poisoned, REPROGRAM"
mapfile -t sm < <(grep -oE '^[0-9]+$' "$OUTDIR/smoke.out")
[ ${#sm[@]} -eq 2 ] || die "could not parse smoke counts from $OUTDIR/smoke.out"
if [ "${sm[0]}" != "${sm[1]}" ]; then
    die "smoke MISMATCH: software=${sm[0]} fpga=${sm[1]}"
fi
EXPECT_SMOKE=${sm[0]}
echo "smoke ok: software == fpga == $EXPECT_SMOKE"
[ "$SMOKE" = "1" ] && { echo "SMOKE=1, stopping here."; exit 0; }

# ---- establish the software baseline ---------------------------------------
# NB: "software" is a baseline, not an oracle. A decompression bug in the storage
# layer made DuckDB read back a truncated string where the card, decompressing in
# RTL, read the correct one -- so the FPGA was right and this number was wrong by 2.
# When they disagree, find the differing rows before assuming the card is at fault.
cat > "$OUTDIR/truth.sql" <<EOF
SELECT count(*) FROM $TABLE WHERE $COLUMN SIMILAR TO '$PATTERN';
EOF
EXPECT=$("$DUCKDB" -readonly "$DB" -noheader -list < "$OUTDIR/truth.sql" | grep -oE '^[0-9]+$' | head -1)
[ -n "$EXPECT" ] || die "could not compute the software ground truth"
echo "ground truth (software): $EXPECT rows match"

# ---- the reproducer ---------------------------------------------------------
# Thread count matters: denser results close the window on the retire race, so
# T=8 warms up and T=32 is where it actually bites.
cat > "$OUTDIR/stress.sql" <<EOF
LOAD oasis;
SET GLOBAL enable_fsst_vectors=true;
SET oasis_regex_fsst_passthrough=true;
SET threads=8;
SELECT count(*) FROM regex_fpga_scan('$TABLE', regex_column := '$COLUMN', pattern := '$PATTERN');
SELECT count(*) FROM regex_fpga_scan('$TABLE', regex_column := '$COLUMN', pattern := '$PATTERN');
SET threads=32;
SELECT count(*) FROM regex_fpga_scan('$TABLE', regex_column := '$COLUMN', pattern := '$PATTERN');
SELECT count(*) FROM regex_fpga_scan('$TABLE', regex_column := '$COLUMN', pattern := '$PATTERN');
SELECT count(*) FROM regex_fpga_scan('$TABLE', regex_column := '$COLUMN', pattern := '$PATTERN');
EOF

LOG=$OUTDIR/hunt_$TAG.log
: > "$LOG"
bad=0
for rep in $(seq 1 "$REPS"); do
    run_sql < "$OUTDIR/stress.sql" \
        > "$OUTDIR/${TAG}_$rep.out" 2> "$OUTDIR/${TAG}_$rep.diag"
    ec=$?
    counts=$(grep -oE '^[0-9]+$' "$OUTDIR/${TAG}_$rep.out")
    deltas=""
    for c in $counts; do
        d=$((c - EXPECT))
        deltas="$deltas $d"
        [ "$d" -ne 0 ] && bad=$((bad + 1))
    done
    free=$(cat $HP)
    echo "rep=$rep exit=$ec free_hugepages=$free deltas:$deltas" | tee -a "$LOG"

    # A wedge poisons the card: every later run in this process *and* the next
    # one is void. Stop immediately and tell the operator to reprogram.
    if [ $ec -ne 0 ]; then
        echo "WEDGE on rep $rep (exit=$ec). Card is poisoned -- REPROGRAM before" \
             "any further measurement, and treat later runs as void." | tee -a "$LOG"
        exit 1
    fi
done

echo "---"
echo "$REPS replications completed with no wedge; $bad/$((REPS * 5)) queries miscounted." \
    | tee -a "$LOG"
echo "artifacts in $OUTDIR"
[ "$bad" -eq 0 ] || exit 3

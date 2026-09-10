#!/bin/bash
# Provoke the residual regex wedge and snapshot the card with the ILAs.
#
# WHY THIS EXISTS
# ---------------
# After the retire-race fix (Bug A) and the lost-result-beat fix (Bug C), one
# wedge sighting remains unexplained. Seen ONCE on hacc-u55c-08: armed for 14400
# strings, eng_outcount stuck at 448 (7 pops), results starved with tready=1 and
# every host channel idle-and-ready. That signature is the array not being FED,
# which is upstream of both fixes -- so neither is expected to have cured it.
#
# It has never reproduced on -07 (0 in 23+ replications), so this script is a
# soak: it runs the query over and over until one hangs.
#
# THE POINT IS THE CAPTURE, NOT THE HANG.
# A wedge is a *static* state, so there is no edge to trigger an ILA on -- we
# snapshot with -trigger_now instead. Critically, the capture runs while the
# wedged process is STILL ALIVE and still holding the card: tearing the process
# down first risks the driver resetting the vFPGA and clearing the very counters
# we want. Vivado reaches the ILAs over JTAG, not PCIe, so it does not contend
# with the stuck process for the device.
#
# WHAT THE PROBES ANSWER
#   rx_transfer_cnt   beats reaching the regex block
#   body_transfer_cnt beats forwarded into the engines
#   arm_pop_cnt       arms popped        res_beat_cnt  result beats emitted
#   eng_outcount      the outCount register at the moment of the freeze
#   retire_missed / wedge_suspect        dedicated flags
#   axis_host_recv[0] host->card DMA at the vfpga boundary
# Together these split "bytes never arrived" from "arrived but were not consumed"
# from "produced but the retire missed it".
#
# USAGE
#   scripts/regex_wedge_hunt.sh                  # soak until wedge or ITERS
#   ITERS=500 WEDGE_SECS=90 scripts/regex_wedge_hunt.sh
#
# On success it leaves wedge_*.ila files in $OUTDIR and STOPS -- a wedge poisons
# the card, so every later run is void until it is reprogrammed.
set -u

D=${DUCKDB:-/home/vifranz/oasis/extension/build/release/duckdb}
DB=${DB:-/scratch/vifranz/regex_fsst.duckdb}
TABLE=${TABLE:-ocomment128}
COLUMN=${COLUMN:-s}
PATTERN=${PATTERN:-.*ing.*}
ITERS=${ITERS:-400}
# A healthy query is ~3.5 s. 120 s is far outside any cold-cache excursion, so a
# breach means hung, not slow.
WEDGE_SECS=${WEDGE_SECS:-120}
OUTDIR=${OUTDIR:-/tmp/regex_wedge_hunt}
TCL=${TCL:-$(dirname "$0")/ila_capture.tcl}
LTX=${LTX:-/local/home/vifranz/celeris/build_hw_undercount/bitstreams/cyt_top.ltx}

export LD_LIBRARY_PATH=$HOME/opt/lib:${LD_LIBRARY_PATH:-}
export OASIS_REGEX_TABLE_SLOTS=${OASIS_REGEX_TABLE_SLOTS:-0}
# Diag OFF on purpose: the per-submit fprintf masks timing-dependent races.
unset OASIS_REGEX_DIAG

HP=/sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages
die() { echo "FATAL: $*" >&2; exit 2; }
[ -x "$D" ]   || die "no duckdb at $D"

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
[ -r "$DB" ]  || die "no database at $DB"
[ -r "$TCL" ] || die "no ILA capture script at $TCL"
[ -r "$LTX" ] || die "no probes file at $LTX"
free=$(cat $HP 2>/dev/null || echo 0)
[ "$free" -ge 2 ] || die "only $free free 1 GiB hugepages (see CLAUDE.md; needs a real tty)"
stray=$(pgrep -f 'release/duckdb|benchmark_runner' || true)
[ -z "$stray" ] || die "another process holds the card: $stray"
mkdir -p "$OUTDIR"

echo "soak: iters=$ITERS wedge_secs=$WEDGE_SECS slots=$OASIS_REGEX_TABLE_SLOTS free_hp=$free"

capture() {  # $1 = tag
    echo "*** WEDGE DETECTED -- capturing ILAs (process left running on purpose)"
    timeout -s TERM 600 vivado -mode batch -nojournal -nolog \
        -source "$TCL" -tclargs "$1" "$OUTDIR" 2>&1 \
        | grep -E '^\*\*\*\*|ERROR' | tee "$OUTDIR/$1.vivado.log"
}

for i in $(seq 1 "$ITERS"); do
    # Vary the shape: the one sighting was FSST at T=32, but the trigger is
    # unknown, so alternate rather than bet on it.
    if [ $((i % 2)) -eq 0 ]; then
        PRE="SET GLOBAL enable_fsst_vectors=true; SET oasis_regex_fsst_passthrough=true;"; mode=fsst
    else
        PRE=""; mode=plain
    fi
    T=32; [ $((i % 4)) -eq 3 ] && T=8

    "$D" -readonly "$DB" -noheader -list -c \
        "LOAD oasis; SET threads=$T; $PRE
         SELECT count(*) FROM regex_fpga_scan('$TABLE', regex_column := '$COLUMN', pattern := '$PATTERN');" \
        > "$OUTDIR/run.out" 2> "$OUTDIR/run.err" &
    pid=$!

    waited=0
    while kill -0 $pid 2>/dev/null && [ $waited -lt $WEDGE_SECS ]; do
        sleep 2; waited=$((waited + 2))
    done

    if kill -0 $pid 2>/dev/null; then
        echo "iter=$i mode=$mode threads=$T HUNG after ${waited}s (pid $pid)"
        capture "wedge_${i}_${mode}_t${T}"
        # SIGTERM ONLY. A KILL leaked the 1 GiB pool irrecoverably once and cost
        # a reboot; and a task stuck in vfpga_dev_ioctl ignores both anyway.
        kill -TERM $pid 2>/dev/null
        echo "captured into $OUTDIR. Card is poisoned -- REPROGRAM before any further runs."
        exit 1
    fi

    wait $pid; ec=$?
    v=$(grep -oE '^[0-9]+$' "$OUTDIR/run.out" | head -1)
    echo "iter=$i mode=$mode threads=$T exit=$ec count=${v:-NONE} free_hp=$(cat $HP) ${waited}s"
done
echo "--- $ITERS iterations, no wedge."

#!/usr/bin/env bash
#
# Watch the TCP interfaces of a RUNNING board with the ILA that is already in the bitstream.
# Does not reprogram anything.
#
#   ./scripts/util/ila_tcp.sh list           # what the probes are actually called
#   ./scripts/util/ila_tcp.sh peerclose    # MinIO hung up
#   ./scripts/util/ila_tcp.sh weclose      # our RTL hung up
#   ./scripts/util/ila_tcp.sh txerr        # the TOE refused a send
#   SECS=180 ./scripts/util/ila_tcp.sh now # no trigger: force a capture after N seconds
#
# Arm it FIRST, then start the query run in another shell. It sits armed through the queries that
# pass and fires on the one that does not.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE=${1:-list}
BUILD=${BUILD:-103}
LTX=${LTX:-$ROOT/hardware/build-$BUILD/bitstreams/cyt_top.ltx}
OUTDIR=${OUTDIR:-$ROOT/.ila}
[ -f "$LTX" ] || { echo "no probes file at $LTX (set BUILD= or LTX=)"; exit 1; }
mkdir -p "$OUTDIR"
echo "probes:  $LTX"
echo "mode:    $MODE"
echo "output:  $OUTDIR/$MODE.csv"
cd "$OUTDIR"
exec vivado -mode batch -nojournal -log "$OUTDIR/vivado-$MODE.log" \
     -source "$ROOT/scripts/util/ila_tcp.tcl" -tclargs "$MODE" "$LTX" "$OUTDIR/$MODE"

#!/usr/bin/env bash
#
# WHILE THE BOARD IS WEDGED, ask the decoder which side it is blocked on.
#
# The receive path is one back-pressured AXI-Stream chain:
#     TOE rx fifo -> axis_tcp_recv -> strip_http -> axis_rewrite_last -> decoder -> output writer
# tready runs backwards through all of it, so a stall anywhere freezes the TCP read pointer, the
# window walks down 8192 at a time, crosses the 24000-byte rx_engine floor, and the connection dies.
# These counters say WHERE the chain stopped.
#
#   in_starved   ready high, valid low  -> the decoder is WAITING. Blame is UPSTREAM (strip_http/TCP).
#   in_stalled   valid high, ready low  -> the decoder REFUSES input. Blame is the decoder or below.
#   out_stalled  valid high, ready low  -> the decoder produced output nobody takes. Blame is the
#                                          OUTPUT WRITER / host DMA -- which would be a software bug.
#
# A single read gives totals since the bitstream was programmed, which says nothing about now.
# So this samples twice and reports the DELTA: whichever counter grows while wedged is the answer.
#
#   ./scripts/util/decoder_stall.sh          # 5 s apart
#   GAP=15 ./scripts/util/decoder_stall.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DUCKDB=${DUCKDB:-$ROOT/extension/build/release/duckdb}
SERVER=${OASIS_SERVER:-10.253.74.74}
PORT=${OASIS_PORT:-9000}
GAP=${GAP:-5}
export NO_PROXY="${SERVER},127.0.0.1,localhost"; export no_proxy="$NO_PROXY"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY 2>/dev/null || true

sample() {
    "$DUCKDB" -csv -noheader -c "
        SET http_server='$SERVER'; SET http_port=$PORT;
        SELECT decoder, in_handshakes_cycles, in_starved_cycles, in_stalled_cycles, in_idle_cycles,
               out_handshakes_cycles, out_starved_cycles, out_stalled_cycles, out_idle_cycles
        FROM oasis_stream_profile();" 2>/dev/null
}

echo "sampling the decoder profile ${GAP}s apart -- run this WHILE the board is wedged"
A=$(sample)
[ -n "$A" ] || { echo "no rows. is the extension loaded and the device reachable?"; exit 1; }
sleep "$GAP"
B=$(sample)

paste -d, <(echo "$A") <(echo "$B") | awk -F, -v gap="$GAP" '
{
  d=$1
  # first sample fields 2..9, second sample fields 11..18
  ih=$11-$2; ist=$12-$3; isl=$13-$4; iid=$14-$5
  oh=$15-$6; ost=$16-$7; osl=$17-$8; oid=$18-$9
  printf "\ndecoder %d, change over %ss:\n", d, gap
  printf "  IN   handshakes=%-12d starved=%-12d stalled=%-12d idle=%d\n", ih, ist, isl, iid
  printf "  OUT  handshakes=%-12d starved=%-12d stalled=%-12d idle=%d\n", oh, ost, osl, oid
  print  "  ------------------------------------------------------------------"
  if (ih==0 && ist==0 && isl==0 && oh==0 && ost==0 && osl==0) {
    print "  NOTHING MOVED AT ALL. The decoder is not even being clocked into a"
    print "  waiting state -- suspect the profiler or a reset, not a stall."
  } else if (osl > 0 && osl >= ost) {
    print "  OUT is STALLED: the decoder has results nobody is taking."
    print "  -> the blockage is the OUTPUT WRITER / host DMA, downstream of the"
    print "     decoder. That is a SOFTWARE bug and needs no bitstream to fix."
  } else if (isl > 0) {
    print "  IN is STALLED: the decoder refuses input while data waits."
    print "  -> the blockage is inside the decoder itself."
  } else if (ist > 0) {
    print "  IN is STARVED: the decoder is idle, waiting for bytes that never come."
    print "  -> the decoder is INNOCENT. The blockage is UPSTREAM: strip_http or"
    print "     axis_rewrite_last stopped emitting. Check align_starved in the"
    print "     handler stall word, then the http parser state."
  } else {
    print "  Mixed or all-idle. Re-run with a longer GAP."
  }
}'

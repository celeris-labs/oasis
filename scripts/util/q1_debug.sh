#!/usr/bin/env bash
#
# q1 on lineitem, alone, with the FPGA watchdog on and every line kept.
#
# tpch_demo runs 22 queries and truncates what it prints; this runs the one that fails and keeps
# everything, so the watchdog's 3-second handler dump is visible while the read is stuck. That dump
# is the whole point: get_next_stream_output blocks with NO timeout, so a stall inside it is
# otherwise completely silent.
#
# Read the WATCHDOG lines:
#   copied=X/Y with X stuck        -> bytes stopped arriving; peak/ever_busy says which stage
#   handler_max=0, ever_busy=0     -> START never fired: a control bug, no GET on the wire
#   handler_max=1..4               -> the handler ran, so the loss is after receive (decoder/DMA)
#   copied=Y/Y and still waiting   -> every byte arrived and the DELIVERY never completed
#
#   ./scripts/util/q1_debug.sh              # default chunk
#   OASIS_HTTP_CHUNK_BYTES=8192 ./scripts/util/q1_debug.sh    # the pre-2026-08-07 default

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DUCKDB=${DUCKDB:-$ROOT/extension/build/release/duckdb}
SERVER=${OASIS_SERVER:-10.253.74.74}
PORT=${OASIS_PORT:-9000}
SCALE=${SCALE:-1}
OUT=${OUT:-/tmp/oasis-q1-debug.txt}

export NO_PROXY="${SERVER},127.0.0.1,localhost,${NO_PROXY:-}"
export no_proxy="$NO_PROXY"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy 2>/dev/null || true
export OASIS_HTTP_DEBUG=1

echo "chunk=${OASIS_HTTP_CHUNK_BYTES:-default}  inflight=${OASIS_HTTP_MAX_INFLIGHT:-default}  arp_settle=${OASIS_ARP_SETTLE_US:-default}"
echo "writing everything to $OUT"

{ echo "SET http_server='$SERVER'; SET http_port=$PORT; SET enable_progress_bar=false;"
  echo "CREATE OR REPLACE VIEW lineitem AS SELECT * FROM read_oasis('httpfpga:///throughput/tpch-${SCALE}/lineitem.parquet');"
  cat "$ROOT/scripts/tpch/q01.sql"
} | timeout "${TIMEOUT:-180}s" "$DUCKDB" -noheader -list 2>&1 | tee "$OUT"

rc=${PIPESTATUS[1]}
echo
echo "---- exit $rc ----"
[ "$rc" = 124 ] && echo "timed out: it hung rather than failing. The last WATCHDOG line above says where."
echo "last handler/watchdog lines:"
grep -E 'WATCHDOG|oasis-http|httpfpga|terminate|rror' "$OUT" | tail -15 | sed 's/^/  /'

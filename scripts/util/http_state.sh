#!/usr/bin/env bash
#
# Dump the FPGA HTTP handler's state. Run this WHILE a query is stuck, from a second terminal.
#
# The handler's state registers are readable only until the bitstream is reprogrammed, and
# reprogramming is the first thing anyone does after a hang -- so this exists to make capturing them
# one command instead of a remembered incantation nobody types correctly under pressure.
#
# It issues one trivial GET (region.parquet, a few hundred bytes). On a wedged board that request
# fails, and the failure message carries the whole state: ring occupancy, which stage stalled, the
# sticky error flags, and how the last response was framed. On a healthy board it just prints them.
#
#   ./scripts/util/http_state.sh                # tpch-30/region.parquet
#   SCALE=1 ./scripts/util/http_state.sh
#
# WHAT TO READ FIRST
#   inflight=N/M     the request ring. N==M means the pipeline stopped draining.
#   conn=up/down     and `peer-closed`, which means the server FINed and we have not noticed.
#   handler=STAGE    which stage is parked.
#   stallWord bits   the ones that matter here:
#       notify_overflow  the announcement queue between the TOE and tcp_read overflowed. Segments
#                        the TOE announced were DROPPED. NOTIFY_DEPTH is 32 in tcp_session_table.sv,
#                        which was sized when responses arrived in bursts with ~1 ms of server think
#                        time between them; back-to-back responses remove those gaps.
#       rx_fifo_stall    the parser stopped draining and back-pressure reached the TOE.
#       read_timeout     ~2 s passed with nothing arriving while a request was outstanding.
#       dirty_abort      body bytes had already reached the decoder, so nothing can be replayed.
#       send_error       the TOE refused a send. Sticky; harmless on its own, see configuration.cpp.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DUCKDB=${DUCKDB:-$ROOT/extension/build/release/duckdb}
SERVER=${OASIS_SERVER:-10.253.74.74}
PORT=${OASIS_PORT:-9000}
SCALE=${SCALE:-30}
OUT=${OUT:-/tmp/oasis-http-state.txt}

export NO_PROXY="${SERVER},127.0.0.1,localhost,${NO_PROXY:-}"
export no_proxy="$NO_PROXY"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy 2>/dev/null || true
export OASIS_HTTP_DEBUG=1

echo "probing the handler with one small GET (scale=$SCALE) -- full output in $OUT"
echo "=============================================================================="
timeout "${TIMEOUT:-60}s" "$DUCKDB" -c \
  "SET http_server='$SERVER'; SET http_port=$PORT; \
   SELECT sum(r_regionkey) FROM read_oasis('httpfpga:///throughput/tpch-${SCALE}/region.parquet');" \
  > "$OUT" 2>&1
rc=$?
echo "=============================================================================="

# The state is in the debug lines and in the exception text, both of which the shell prints to
# stderr; show them rather than the query result, which is not the point.
grep -E 'inflight=|stalled:|handler=|latched:|last response:|Error|rror' "$OUT" | sed 's/^/  /'

echo
case "$rc" in
    0)   echo "the board answered -- it is NOT wedged. If a suite is stuck, the fault is upstream"
         echo "of the handler (host side, or the query that is running, not the FPGA)." ;;
    124) echo "the probe itself timed out: the handler is not answering at all."
         echo
         echo "Nothing was printed above, which is itself the finding: the state registers are read"
         echo "on the way to issuing a request, so a run that reaches them prints them even when the"
         echo "request then hangs. Getting nothing means it hung EARLIER -- in cThread setup or the"
         echo "HEAD probe -- so the fault is below the HTTP handler, not in it."
         echo "Check first:  hdev set hugepages -s 1G -p 16   and   lsmod | grep coyote" ;;
    *)   echo "probe failed (rc=$rc). The state above is from the moment of failure, which is the"
         echo "reading you want -- it disappears on reprogram." ;;
esac
echo
# Resolve the newest bitstream rather than naming one. This used to say build-97, which by the time
# anyone read it was five bitstreams stale -- and following it silently reprograms the board with an
# old design, so the next run tests something other than what is being debugged.
BIT=$(ls -dt "$ROOT"/hardware/build-*/bitstreams/cyt_top.bit 2>/dev/null | head -1)
echo "reprogram before the next run:"
echo "  hdev set hugepages -s 1G -p 16"
echo "  cd $ROOT/parcore/libstf/coyote/util && ./program_hacc_local.sh \\"
echo "      ${BIT:-$ROOT/hardware/build-<newest>/bitstreams/cyt_top.bit} \\"
echo "      $ROOT/parcore/libstf/coyote/driver/build/coyote_driver.ko"

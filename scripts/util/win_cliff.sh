#!/usr/bin/env bash
#
# Test the flow-control-cliff hypothesis against a capture.
#
# rx_engine.cpp:1295 (RX_DDR_BYPASS branch) accepts a segment only when
#     (rxbuffer_max_data_count - rxbuffer_data_count) > 375   beats
# = 375 * 64 = 24000 bytes free. But rx_sar_table advertises (appd - recvd) - 1, which is
# unaware of that floor. So any advertised window in 1..24000 is a window the peer is invited
# to use and the receiver will drop every byte of -- a permanent deadlock.
#
# PREDICTION, which this script checks and can falsify:
#   every stream that dies has the FPGA advertising inside 1..24000 first, and
#   every stream that stays above 24000 completes.
#
#   ./scripts/util/win_cliff.sh capture.pcapng
#   FPGA=10.253.74.80 MINIO=10.253.74.74 ./scripts/util/win_cliff.sh capture.pcapng
set -uo pipefail
PCAP=${1:-}
FPGA=${FPGA:-10.253.74.80}
MINIO=${MINIO:-10.253.74.74}
CLIFF=${CLIFF:-24000}
[ -n "$PCAP" ] && [ -f "$PCAP" ] || { echo "usage: $0 <capture.pcap|pcapng>"; exit 1; }
command -v tshark >/dev/null || { echo "tshark not found (apt install tshark, or run this on a host that has it)"; exit 1; }

echo "capture: $PCAP"
echo "fpga=$FPGA  minio=$MINIO  cliff=${CLIFF} bytes (375 beats x 64)"
echo

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tshark -r "$PCAP" -Y "ip.addr==$FPGA && ip.addr==$MINIO && tcp" -T fields \
    -e frame.time_relative -e tcp.stream -e ip.src -e tcp.window_size \
    -e tcp.analysis.duplicate_ack -e tcp.flags.reset -e tcp.flags.fin -e tcp.len \
    -E separator=, 2>/dev/null \
  | FPGA="$FPGA" CLIFF="$CLIFF" python3 "$ROOT/scripts/util/win_cliff.py"

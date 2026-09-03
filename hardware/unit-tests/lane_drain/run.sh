#!/usr/bin/env bash
# lane_drain -- independent black-box liveness bench for handler_multi and rx_dispatch.
#
# The bench models the whole outside world (Coyote TOE, an HTTP/1.1 origin server, the host config
# port and DMA, and the per-lane decoder sink) and checks four properties continuously: LIVENESS
# (a readPkg within a bounded number of cycles while a notification is outstanding), ROUTING
# (byte-exact, to the lane bound to that session), FRAMING (one tlast per response at the
# Content-Length) and RECOVERY (everything drains once a transient clears).
#
#   ./run.sh                 all scenarios, all lane counts
#   ./run.sh <scen> [lanes]  one scenario at one lane count (default 2)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
HDL="$ROOT/../../src/hdl/http_read"

if ! command -v xvlog >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
fi

cd "$ROOT"
rm -rf xsim.dir xsim.jou xsim.log xvlog.pb xelab.pb webtalk* .Xil 2>/dev/null || true

xvlog -sv lynxTypes_stub.sv \
      "$HDL/http_types.sv" "$HDL/axis_fifo.sv" "$HDL/strip_http.sv" "$HDL/tcp_read.sv" \
      "$HDL/rx_dispatch.sv" "$HDL/tcp_init.sv" "$HDL/http_req_stream.sv" \
      "$HDL/axis_rewrite_last.sv" "$HDL/tx_arbiter.sv" "$HDL/handler_multi.sv" \
      rxd_drain_tb.sv lane_drain_tb.sv

xelab -debug typical -timescale 1ns/1ps -top rxd_drain_tb -snapshot rxd_snap
for N in 1 2 4; do
  xelab -debug typical -timescale 1ns/1ps -top lane_drain_tb \
        -snapshot "ld${N}_snap" -generic_top "NUM_CONNS=${N}"
done

run_rxd() { echo "=== rx_dispatch : $1 ==="; xsim rxd_snap -R -testplusarg "SCEN=$1" | sed -n '/^rxd_drain_tb /p'; }
run_hm()  { echo "=== handler_multi[$2] : $1 ==="; xsim "ld$2_snap" -R -testplusarg "SCEN=$1" | sed -n '/^lane_drain_tb /p'; }

if [ $# -ge 1 ]; then
  case "$1" in
    r*) run_rxd "$1" ;;
    *)  run_hm "$1" "${2:-2}" ;;
  esac
  exit 0
fi

# rx_dispatch in isolation
for s in r1 r2 r3 r4 r5 r6 r7; do run_rxd "$s"; done

# handler_multi: the mandated scenarios (a)-(h)
for s in a b c d e f g h; do run_hm "$s" 2; done

# handler_multi: probes that localise the pipelining failure
for s in a2 a8 a9 a10; do run_hm "$s" 2; done

# handler_multi: serialised variants -- one response outstanding per lane, which is the
# configuration the design does work in, so the drain/containment questions can be asked
for s in s_base s_g s_d s_e s_f; do run_hm "$s" 2; done

# other lane counts
for N in 1 4; do
  run_hm s_base "$N"
  run_hm a2     "$N"
done

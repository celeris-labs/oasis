#!/usr/bin/env bash
# Standalone xsim (Vivado) for the pipelined HTTP handler.
#
# Covers handler + tcp_session_table + tcp_init + tcp_send_http (+ http_req_builder) + tcp_read
# (+ strip_http) against a TOE model that serves several concurrent sessions. See the testbench
# header for what it asserts -- in particular that request k+1's GET goes out before body k has
# finished, which is the whole reason the handler was restructured.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
HDL="$ROOT/../../src/hdl/http_read"
OUT="$ROOT/xsim.dir"

if ! command -v xvlog >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
fi

cd "$ROOT"
rm -rf "$OUT" xsim.jou xsim.log xvlog.pb xelab.pb webtalk* .Xil 2>/dev/null || true

xvlog -sv ${TRACE:+-d TRACE} \
  lynxTypes_stub.sv \
  "$HDL/http_types.sv" \
  "$HDL/tcp_session_table.sv" \
  "$HDL/tcp_init.sv" \
  "$HDL/http_req_builder.sv" \
  "$HDL/tcp_send_http.sv" \
  "$HDL/axis_fifo.sv" \
  "$HDL/strip_http.sv" \
  "$HDL/tcp_read.sv" \
  "$HDL/handler.sv" \
  http_pipeline_tb.sv

# http_req_builder.sv carries no timescale directive, so one has to be supplied here.
#
# Two configurations: the pipelined one that ships (4 slots), and the sequential fallback (1 slot).
# The fallback matters -- if pipelining ever has to be switched off to isolate a hardware problem,
# NUM_SLOTS=1 has to still deliver correct bodies, and $clog2(1)=0 makes that a real elaboration
# edge case rather than a formality.
for slots in ${SLOTS:-4 1}; do
  echo "=============================== NUM_SLOTS=$slots ==============================="
  xelab -debug typical -timescale 1ns/1ps \
        -generic_top "NUM_SLOTS=$slots" \
        -top http_pipeline_tb -snapshot "http_pipeline_tb_snap_$slots"
  xsim "http_pipeline_tb_snap_$slots" -R
done

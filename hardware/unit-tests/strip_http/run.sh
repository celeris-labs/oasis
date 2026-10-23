#!/usr/bin/env bash
# Standalone xsim (Vivado) for strip_http
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DUT="$ROOT/../../src/hdl/http_read/strip_http.sv"
OUT="$ROOT/xsim.dir"

# Source Vivado if needed
if ! command -v xvlog >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
fi

cd "$ROOT"
rm -rf "$OUT" xsim.jou xsim.log xvlog.pb xelab.pb webtalk* .Xil 2>/dev/null || true

xvlog -sv ../common/lynxTypes_stub.sv "$DUT" strip_http_tb.sv
xelab -debug typical -timescale 1ns/1ps -top strip_http_tb -snapshot strip_http_tb_snap
xsim strip_http_tb_snap -R
# xsim exits 0 after a $fatal, so the verdict line decides
grep -qE '^strip_http_tb: [0-9]+ passed, 0 failed' xsim.log

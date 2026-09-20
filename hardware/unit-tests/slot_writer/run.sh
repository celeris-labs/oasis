#!/usr/bin/env bash
# slot_writer -- every TCP segment into its connection's card-memory slot, byte exact, without ever
# refusing the receive side.
#
# The bench drives rx_dispatch's side of the contract (one-hot routed beats, conn_pkg_issued on a
# readPkg, conn_space_ok as the only gate) and the real card DMA model on the other side, and every
# case checks the same four things: byte exactness in the slot, landed[], route_stall never latching
# (the property the whole redesign exists for), and the DMA model's own contract asserts.
#
#   ./run.sh                     every case; exit status 1 if any of them fails
#   ./run.sh <case> [PLUSARG=v]  one case (w1 w4 w24 wbp wlat wovf wrel)
#
# Bench plusargs: SCEN HDR BODY TOELAT
# Model plusargs: DMA_WR_REQ_LAT DMA_WR_ACK_LAT DMA_WR_BP DMA_SEED
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
HDL="${HDL:-$ROOT/../../src/hdl/http_read}"
MODEL="$ROOT/../card_dma/card_dma_model.sv"

if ! command -v xvlog >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
fi

cd "$ROOT"
rm -rf xsim.dir xsim.jou xsim.log xvlog.pb xelab.pb webtalk* .Xil *.wdb 2>/dev/null || true

xvlog -sv lynxTypes_stub.sv "$HDL/axis_fifo.sv" "$HDL/slot_writer.sv" "$MODEL" slot_writer_tb.sv \
      > xvlog.log 2>&1 || { tail -40 xvlog.log; exit 1; }

elab() { # <snapshot> <nconns> <slotlog2>
  [ -d "xsim.dir/$1" ] && return 0
  xelab -debug typical -timescale 1ns/1ps -top slot_writer_tb -snapshot "$1" \
        -generic_top "NCONNS=$2" -generic_top "SLOTL=$3" > "xelab_$1.log" 2>&1 \
    || { tail -40 "xelab_$1.log"; exit 1; }
}

FAILS=0
run() { # <snapshot> <case> [plusargs...]
  local snap="$1" scen="$2"; shift 2
  local a=(-testplusarg "SCEN=$scen"); for p in "$@"; do a+=(-testplusarg "$p"); done
  local out; out="$(xsim "$snap" -R "${a[@]}" 2>&1)"
  echo "$out" | grep -E "^slot_writer_tb|^  ERROR|^card_dma_model|^slot_writer: FAIL"
  echo "$out" | grep -q "^slot_writer_tb.*: PASS" || FAILS=$((FAILS + 1))
}

elab sw1  1  22
elab sw4  4  22
elab sw24 24 22
elab swov 4  14

if [ $# -ge 1 ]; then
  case "$1" in
    w1)   shift; run sw1  w1   "$@" ;;
    w4)   shift; run sw4  w4   "$@" ;;
    w24)  shift; run sw24 w24  "$@" ;;
    wbp)  shift; run sw4  wbp  DMA_WR_BP=50 "$@" ;;
    wlat) shift; run sw4  wlat "$@" ;;
    wovf) shift; run swov wovf "$@" ;;
    wrel) shift; run sw1  wrel "$@" ;;
    *) echo "usage: $0 [w1|w4|w24|wbp|wlat|wovf|wrel] [PLUSARG=v ...]"; exit 2 ;;
  esac
  exit $(( FAILS > 0 ))
fi

# -- unaligned cursor: a 630 byte header segment of its own, then 4096 byte body segments and a
#    short tail, so nothing after the header starts on a 64 byte boundary.
run sw1  w1
# -- four connections interleaved at segment granularity, then twenty-four.
run sw4  w4
run sw24 w24
# -- the DMA write data channel refuses half the cycles. The rx side must still never be refused.
run sw4  wbp  DMA_WR_BP=50
run sw24 w24  DMA_WR_BP=70 DMA_SEED=3
# -- ack latency 0 / 8 / 200: at 200 the 8-deep completion queue is the throttle and the shared
#    fifo has to absorb it, which is the "does the card path keep up per 4 KiB segment" question
#    ADR-5 lists as the thing that would overturn it.
run sw4  wlat DMA_WR_ACK_LAT=0   DMA_WR_REQ_LAT=0
run sw4  wlat DMA_WR_ACK_LAT=8
run sw4  wlat DMA_WR_ACK_LAT=200 DMA_WR_REQ_LAT=20
# -- a segment that would cross the end of a slot is discarded whole, and stays inside the slot.
run swov wovf
# -- two responses on one connection with a release between: the second lands at offset 0 again.
run sw1  wrel

echo "slot_writer: $FAILS failed case(s)"
exit $(( FAILS > 0 ))

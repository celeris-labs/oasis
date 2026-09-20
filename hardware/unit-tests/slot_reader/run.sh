#!/usr/bin/env bash
# slot_reader -- end to end: HTTP response bytes in at the receive side of a real slot_writer,
# through the card DMA model, out of a real slot_reader, into the REAL strip_http, body bytes out.
#
# Nothing between the two ends is stubbed, so a case fails on the things that actually break here:
# an off-by-one in the unaligned cursor after the header segment, a read issued before its write was
# acked (the DMA model fails that outright), an RD_MAX split that lands a beat in the wrong place, a
# residue left in the slot when a response is retired.
#
# `rslow` is the measurement this work package exists for: decoder 0's sink takes one beat every 16
# cycles while decoder 1's runs flat out, and both rates are printed. In build-119 that experiment
# starves every lane (ADR-5, "Lanes are coupled head-of-line"). `rsolo` is the same run with the
# slow decoder absent, for the number to compare against.
#
#   ./run.sh                     every case; exit status 1 if any of them fails
#   ./run.sh <case> [PLUSARG=v]  one case (r1 r4 rmax rtwo rgap rslow rsolo)
#
# Bench plusargs: SCEN BODY HDR TOELAT SLOWDIV SLOWOFF
# Model plusargs: DMA_WR_REQ_LAT DMA_WR_ACK_LAT DMA_RD_REQ_LAT DMA_RD_ACK_LAT DMA_WR_BP DMA_RD_GAP
#                 DMA_SEED
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

xvlog -sv ../slot_writer/lynxTypes_stub.sv \
      "$HDL/axis_fifo.sv" "$HDL/strip_http.sv" "$HDL/slot_writer.sv" "$HDL/slot_reader.sv" \
      "$MODEL" slot_reader_tb.sv > xvlog.log 2>&1 || { tail -40 xvlog.log; exit 1; }

# (If elaboration ever hangs after "Completed static elaboration", read the note at the top of
# card_dma_model.sv: an assignment pattern pushed into a queue wedges xelab.)
elab() { # <snapshot> <nconns> <nrd> <rdmax>
  [ -d "xsim.dir/$1" ] && return 0
  xelab -debug typical -timescale 1ns/1ps -top slot_reader_tb -snapshot "$1" \
        -generic_top "NCONNS=$2" -generic_top "NRD=$3" -generic_top "RDMAX=$4" \
        > "xelab_$1.log" 2>&1 || { tail -40 "xelab_$1.log"; exit 1; }
}

FAILS=0
run() { # <snapshot> <case> [plusargs...]
  local snap="$1" scen="$2"; shift 2
  local a=(-testplusarg "SCEN=$scen"); for p in "$@"; do a+=(-testplusarg "$p"); done
  local out; out="$(xsim "$snap" -R "${a[@]}" 2>&1)"
  echo "$out" | grep -E "^slot_reader_tb|^  ERROR|^  decoder|^card_dma_model|^slot_writer: FAIL"
  echo "$out" | grep -q "^slot_reader_tb.*: PASS" || FAILS=$((FAILS + 1))
}

elab sr1 1 1 65536
elab sr4 4 2 65536
elab srm 1 1 4096
elab sr2 2 2 65536

if [ $# -ge 1 ]; then
  case "$1" in
    r1)    shift; run sr1 r1    "$@" ;;
    r4)    shift; run sr4 r4    "$@" ;;
    rmax)  shift; run srm rmax  "$@" ;;
    rtwo)  shift; run sr1 rtwo  "$@" ;;
    rgap)  shift; run sr1 rgap  DMA_RD_GAP=40 DMA_WR_BP=40 "$@" ;;
    rslow) shift; run sr2 rslow "$@" ;;
    rsolo) shift; run sr2 rsolo "$@" ;;
    *) echo "usage: $0 [r1|r4|rmax|rtwo|rgap|rslow|rsolo] [PLUSARG=v ...]"; exit 2 ;;
  esac
  exit $(( FAILS > 0 ))
fi

# -- one connection end to end. The entry is queued before a byte has landed (the normal case, and
#    a legal wait), the header is a segment of its own so every body byte lands unaligned.
run sr1 r1
# -- the card path at its most hostile: read gaps and write back-pressure at once.
run sr1 rgap DMA_RD_GAP=40 DMA_WR_BP=40 DMA_SEED=11
# -- the request pipeline against a slow ack and a slow request: reads must still only ever touch
#    bytes the write channel has acked, which the model checks on every read request.
run sr1 r1 DMA_WR_ACK_LAT=200 DMA_RD_REQ_LAT=20 DMA_WR_REQ_LAT=20
# -- four connections over two decoders, segments interleaved on the wire.
run sr4 r4
# -- RD_MAX 4096: a 32 KiB body is split into nine reads, at most two outstanding.
run srm rmax
# -- two responses in a row on one connection, with the release between them.
run sr1 rtwo
# -- THE COUPLING EXPERIMENT, and its baseline.
run sr2 rsolo
run sr2 rslow SLOWDIV=16

echo "slot_reader: $FAILS failed case(s)"
exit $(( FAILS > 0 ))

#!/usr/bin/env bash
# slot_reader -- end to end: HTTP response bytes in at the receive side of a real slot_writer,
# through the card DMA model, out of a real slot_reader, into the REAL strip_http, body bytes out.
#
# Since 2026-09-22 the readers reach the model through the REAL slot_rd_share on ONE card read
# channel (card_dma_model at N_RD=1), which is the topology the bitstream is built with -- build-123
# failed route_design with five card AXI streams. SHARE=0 restores WP1's one-channel-per-reader
# wiring for a bisect; nothing below uses it, and a case run that way says SHARE=0 in its verdict.
#
# Nothing between the two ends is stubbed, so a case fails on the things that actually break here:
# an off-by-one in the unaligned cursor after the header segment, a read issued before its write was
# acked (the DMA model fails that outright), an RD_MAX split that lands a beat in the wrong place, a
# residue left in the slot when a response is retired, and now a shared-channel demux that miscounts
# a beat and hands one decoder's bytes to another.
#
# THE MEASUREMENT THIS WORK PACKAGE EXISTS FOR is `rslow` against `rsolo`, and it is run TWICE:
#   FASTDIV=4  decoder 1's sink asks for 4 GB/s -- twice the fastest decoder intake ADR-5 ever
#              measured -- so both decoders fit on one 16 GB/s channel and the slow one must cost
#              the fast one NOTHING. This is the pass/fail one (floor 95% of 1/FASTDIV).
#   FASTDIV=1  decoder 1's sink asks for the WHOLE channel, so whatever decoder 0 legitimately
#              draws comes off decoder 1's number. Reported, with a floor that only says the
#              channel never idled; one 512-bit channel cannot serve two flat-out sinks and no
#              design with one channel could.
# `rstall` is the same question with decoder 0 stopped dead: its fifo fills, the credit refuses it,
# and decoder 1 must still finish.
#
#   ./run.sh                     every case; exit status 1 if any of them fails
#   ./run.sh <case> [PLUSARG=v]  one case (r1 r4 r4x rmax rtwo rgap rslow rsolo rstall)
#
# Bench plusargs: SCEN BODY HDR TOELAT SLOWDIV FASTDIV SLOWOFF RMINP
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
      "$HDL/slot_rd_share.sv" \
      "$MODEL" slot_reader_tb.sv > xvlog.log 2>&1 || { tail -40 xvlog.log; exit 1; }

# (If elaboration ever hangs after "Completed static elaboration", read the note at the top of
# card_dma_model.sv: an assignment pattern pushed into a queue wedges xelab.)
elab() { # <snapshot> <nconns> <nrd> <rdmax> [share]
  [ -d "xsim.dir/$1" ] && return 0
  xelab -debug typical -timescale 1ns/1ps -top slot_reader_tb -snapshot "$1" \
        -generic_top "NCONNS=$2" -generic_top "NRD=$3" -generic_top "RDMAX=$4" \
        -generic_top "SHARE=${5:-1}" \
        > "xelab_$1.log" 2>&1 || { tail -40 "xelab_$1.log"; exit 1; }
}

FAILS=0
run() { # <snapshot> <case> [plusargs...]
  local snap="$1" scen="$2"; shift 2
  local a=(-testplusarg "SCEN=$scen"); for p in "$@"; do a+=(-testplusarg "$p"); done
  local out; out="$(xsim "$snap" -R "${a[@]}" 2>&1)"
  echo "$out" | grep -E "^slot_reader_tb|^  ERROR|^  decoder|^card_dma_model|^slot_writer: FAIL|^slot_rd_share: FAIL"
  echo "$out" | grep -q "^slot_reader_tb.*: PASS" || FAILS=$((FAILS + 1))
}

elab sr1 1 1 16384
elab sr4 4 2 16384
elab srm 1 1 4096
elab sr2 2 2 16384
elab sr4x 4 4 16384

if [ $# -ge 1 ]; then
  case "$1" in
    r1)     shift; run sr1  r1     "$@" ;;
    r4)     shift; run sr4  r4     "$@" ;;
    r4x)    shift; run sr4x r4x    DMA_RD_GAP=40 "$@" ;;
    rmax)   shift; run srm  rmax   "$@" ;;
    rtwo)   shift; run sr1  rtwo   "$@" ;;
    rpipe)  shift; run sr1  rpipe  "$@" ;;
    rpipe4) shift; run sr4x rpipe4 "$@" ;;
    rgap)   shift; run sr1  rgap   DMA_RD_GAP=40 DMA_WR_BP=40 "$@" ;;
    rslow)  shift; run sr2  rslow  "$@" ;;
    rsolo)  shift; run sr2  rsolo  "$@" ;;
    rstall) shift; run sr2  rstall BODY=262144 RMINP=85 "$@" ;;
    *) echo "usage: $0 [r1|r4|r4x|rmax|rtwo|rpipe|rpipe4|rgap|rslow|rsolo|rstall] [PLUSARG=v ...]"; exit 2 ;;
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
# -- ALL FOUR readers on the one shared channel at once, mixed request lengths, ~40% read gaps.
run sr4x r4x DMA_RD_GAP=40
run sr4x r4x DMA_RD_GAP=40 DMA_WR_BP=30 DMA_SEED=7
# -- RD_MAX 4096: a 32 KiB body is split into nine reads, at most two outstanding.
run srm rmax
# -- two responses in a row on one connection, with the release between them.
run sr1 rtwo
# -- PIPELINED GETs (CSR revision 4): several responses queued on one connection before the first
#    drains, arriving as one stream (responses share segments and beats, every one ends mid-beat).
#    HOLD=1 lets every byte land before the decoder takes any; HOLD=0 races them.
for n in 2 4; do for h in 0 1; do run sr1 rpipe NPIPE=$n HOLD=$h; done; done
run sr1 rpipe NPIPE=2 HOLD=0 BODY=400000
run sr1 rpipe NPIPE=4 HOLD=1 BODY=400000 DMA_RD_GAP=30 DMA_WR_BP=30
run sr1 rpipe NPIPE=4 HOLD=0 BODY=70            # 75..126-byte bodies, all in one segment
run sr1 rpipe NPIPE=4 HOLD=1 BODY=70 MSS=64
run sr1 rpipe NPIPE=3 HOLD=0 BODY=5000 MSS=1460 DMA_RD_GAP=40 DMA_SEED=5
run sr1 rpipe NPIPE=8 HOLD=0 BODY=20000 DMA_WR_ACK_LAT=200
run srm rpipe NPIPE=3 HOLD=0 BODY=9000
run sr4x rpipe4 NPIPE=3 BODY=6000 DMA_RD_GAP=40
run sr4x rpipe4 NPIPE=4 BODY=70 MSS=1460
# -- THE COUPLING EXPERIMENT at a realistic sink rate: the slow decoder must cost the fast one
#    nothing at all. This pair is the proof.
run sr2 rsolo FASTDIV=4 RMINP=95
run sr2 rslow FASTDIV=4 SLOWDIV=16 RMINP=95
# -- ...and at a sink that asks for the WHOLE channel. Measured 2026-09-22: 1.0000 both ways, i.e.
#    still no cost at all, because the slow decoder takes its 2 x RD_MAX fifo fill while the fast
#    one is still parsing its header and only 1/16 of the channel afterwards, and the fast
#    decoder's own fifo covers the difference. A response much larger than 2 x RD_MAX with BOTH
#    sinks flat out would show a bandwidth split instead -- one 512-bit channel cannot serve two
#    16 GB/s sinks, and no design with one channel could.
run sr2 rsolo FASTDIV=1 RMINP=95
run sr2 rslow FASTDIV=1 SLOWDIV=16 RMINP=90
# -- a decoder stopped dead with two reads outstanding: its credit runs out, everyone else flows.
run sr2 rstall BODY=262144 RMINP=85

echo "slot_reader: $FAILS failed case(s)"
exit $(( FAILS > 0 ))

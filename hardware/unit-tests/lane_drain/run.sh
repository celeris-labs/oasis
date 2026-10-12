#!/usr/bin/env bash
# lane_drain -- independent black-box liveness bench for the HTTP receive path.
#
# The bench models the whole outside world (Coyote TOE, an HTTP/1.1 origin server, the host config
# port and DMA, the per-decoder sink, and -- for the slots DUT -- Coyote's card DMA) and checks four
# properties continuously: LIVENESS (a readPkg within a bounded number of cycles while a
# notification is outstanding), ROUTING (byte-exact, to the connection bound to that session),
# FRAMING (one tlast per chunk at the configured byte count) and RECOVERY (everything drains once a
# transient clears).
#
# TWO DUTs
#   --dut multi   handler_multi, the sealed build-119 baseline. The default for a named scenario, so
#                 every old invocation means exactly what it meant before.
#   --dut slots   handler_slots + slot_rd_share + unit-tests/card_dma/card_dma_model (ADR-5).
#                 The readers share ONE card read channel, which is the topology the bitstream is
#                 built with since 2026-09-22 -- build-123 failed route_design with five card AXI
#                 streams -- so the black-box scenarios cover the real thing.
#   --dut toe     handler_toe (TOE with a receive ring per session, RX_DDR_BYPASS=0) against the
#                 bench's NON-BYPASS TOE MODEL (per-session rings, delayed notifications with the
#                 FIN overtaking them, over-read = failure, window model). Not part of `both`.
#   --dut both    both, which is what a bare ./run.sh does (plus the s2 set below).
#   --dut s2      STAGE 2 only: handler_slots at revision 5 with MORE CONNECTIONS THAN DECODERS
#                 (NUM_CONNS 24 and 32 over NUM_DEC 4, the build-127 shape), the host model placing
#                 every GET on a connection; the s2* scenarios plus the generic ones that are
#                 meaningful per decoder, and s2mix with the host using 4, 24 and 32 connections.
#
# DECODER COUNT. NDEC (environment, default 4) is the handler_slots width under test: the full-width
# stage-1 cases (lanes = connections = decoders = NDEC, e.g. `for N in 1 2 4` becomes 1 2 NDEC) and
# the stage-2 decoder count. NDEC=4 runs exactly the cases and snapshots it always did; NDEC=3 is the
# 3-decoder build (build-131), a decoder count that is not a power of two. The handler_multi arm is
# the sealed build-119 baseline and does not move with it.
#
#   ./run.sh                          everything, both DUTs, N = 1, 2, 4
#   ./run.sh --dut slots              every slots scenario, N = 1, 2, 4
#   ./run.sh <scen> [lanes]           one scenario at one lane count on handler_multi (default 2)
#   ./run.sh --dut slots <scen> [n]   ...on handler_slots
#   ./run.sh p1 1 DEPTH=2 NRESP=100   ...plus any extra plusargs, forwarded verbatim to xsim
#
# Exit status is 1 if any case failed. Cases whose passing verdict is not the word PASS are declared
# below rather than guessed: `e` and `s_e` measure CONTAINMENT and say so, and `lz1`/`lz2` are
# EXPECTED TO FAIL on both DUTs for the same reason -- the pinned baseline is build-119, which
# predates the lazy-open fix (commit a08b100, which shipped in the broken build-120), and
# handler_slots copies its session side deliberately. They are reported as XFAIL with that reason
# instead of being hidden or counted.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
HDL="$ROOT/../../src/hdl/http_read"
MODEL="$ROOT/../card_dma/card_dma_model.sv"

if ! command -v xvlog >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
fi

cd "$ROOT"

DUT=both
NDEC="${NDEC:-4}"
# Stage-2 snapshot names: unchanged at 4 decoders, suffixed with the count otherwise.
if [ "$NDEC" = 4 ]; then S2SFX=""; else S2SFX="d${NDEC}"; fi
ONE=""
LANES=2
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dut) DUT="$2"; shift 2 ;;
    *=*)   EXTRA+=("$1"); shift ;;
    *)
      if [ -z "$ONE" ]; then ONE="$1"; shift
      elif [[ "$1" =~ ^[0-9]+$ ]]; then LANES="$1"; shift
      else EXTRA+=("$1"); shift
      fi ;;
  esac
done
if [ -n "$ONE" ] && [ "$DUT" = both ]; then DUT=multi; fi

rm -rf xsim.dir xsim.jou xsim.log xvlog.pb xelab.pb webtalk* .Xil 2>/dev/null || true

# axis_skid.sv is instantiated by handler_multi (the build-119 copy pinned in efd5fbb) but is NOT
# tracked in git, so it can legitimately be absent from a clean checkout -- and then the
# handler_multi arm cannot be elaborated at all and only the slots arm runs. handler_slots
# deliberately does not depend on it; it inlines the same two registers.
SKID=()
[ -f "$HDL/axis_skid.sv" ] && SKID=("$HDL/axis_skid.sv")

xvlog -sv lynxTypes_stub.sv \
      "$HDL/http_types.sv" "$HDL/axis_fifo.sv" "${SKID[@]}" \
      "$HDL/strip_http.sv" "$HDL/tcp_read.sv" \
      "$HDL/rx_dispatch.sv" "$HDL/tcp_init.sv" "$HDL/http_req_stream.sv" \
      "$HDL/axis_rewrite_last.sv" "$HDL/tx_arbiter.sv" "$HDL/handler_multi.sv" \
      "$HDL/slot_writer.sv" "$HDL/slot_reader.sv" "$HDL/slot_rd_share.sv" \
      "$HDL/handler_slots.sv" "$MODEL" \
      "$HDL/toe_rx.sv" "$HDL/handler_toe.sv" \
      rxd_drain_tb.sv lane_drain_tb.sv > xvlog.log 2>&1 \
  || { tail -40 xvlog.log; exit 1; }

# CSR_REV=4 (environment) elaborates handler_slots with revision 4's conn == decoder arm decoding;
# the default is the bench's own (5, the stage-2 RTL driven stage-1 shaped: conn L on decoder L).
elab() { # <snapshot> <generic>...
  local snap="$1"; shift
  local g=(); local x; for x in "$@"; do g+=(-generic_top "$x"); done
  [ -n "${CSR_REV:-}" ] && [[ " $* " == *DUT_SLOTS=1* ]] && g+=(-generic_top "CSR_REV=${CSR_REV}")
  [ -d "xsim.dir/$snap" ] && return 0
  xelab -debug typical -timescale 1ns/1ps -top lane_drain_tb -snapshot "$snap" "${g[@]}" \
        > "xelab_$snap.log" 2>&1 || { tail -30 "xelab_$snap.log"; return 1; }
}

FAILS=0
CASES=0

# Scenarios whose passing verdict is not the word PASS. (e) and (s_e) measure containment.
expected() {
  case "$1" in
    e|s_e)   echo "CONTAINED" ;;
    win_bad) echo "BUDGET" ;;     # handler_toe: the window rule broken on purpose
    *)       echo "PASS" ;;
  esac
}
is_xfail() { case "$1" in lz1|lz2) return 0 ;; *) return 1 ;; esac; }

run_rxd() {
  local out
  CASES=$((CASES + 1))
  out="$(xsim rxd_snap -R -testplusarg "SCEN=$1" 2>&1)"
  if echo "$out" | grep -qE "^rxd_drain_tb '$1': (PASS|CONTAINED)"; then
    echo "PASS  rx_dispatch   $1"
  else
    echo "FAIL  rx_dispatch   $1   -- $(echo "$out" | grep -E "^rxd_drain_tb '" | head -1)"
    FAILS=$((FAILS + 1))
  fi
}

run_hm() { # <dut> <scen> <lanes> [plusargs...]
  local dut="$1" scen="$2" lanes="$3"; shift 3
  local pfx snap exp out verdict
  case "$dut" in slots) pfx=lds ;; toe) pfx=ldt ;; *) pfx=ld ;; esac
  snap="${SNAP_OVERRIDE:-${pfx}${lanes}_snap}"
  # lz2 has to WAIT for the connect watchdog, which defaults to 2^28 cycles -- a second on the
  # board, a week in xsim. Its own snapshot shrinks only that parameter.
  [ "$scen" = "lz2" ] && snap="${pfx}to_snap"
  # ovf has to overrun a slot, so it gets a small one rather than half a megabyte of waiting.
  # So does cuovf, which overruns it to get a fatal teardown. (handler_toe has no slot: its cuovf
  # is a FIN with unread bytes in the ring, on the ordinary snapshot.)
  if [ "$dut" != toe ]; then
    [ "$scen" = "ovf" ] || [ "$scen" = "cuovf" ] && snap="${pfx}ovf${lanes}_snap"
  fi

  local a=(-testplusarg "SCEN=$scen"); local p
  for p in "$@"; do a+=(-testplusarg "$p"); done
  CASES=$((CASES + 1))
  out="$(xsim "$snap" -R "${a[@]}" 2>&1)"
  verdict="$(echo "$out" | grep -E "^lane_drain_tb '" | tail -1)"
  exp="$(expected "$scen")"
  echo "$out" | grep -E '^  == |^     conn |^     stall bits|^     worst |^  NOTE slots|^  CARD DMA' || true
  # The RTL's own simulation-only invariants. slot_writer asserts that a connection is never
  # released with segments of it still in flight -- the thing BR_DRAIN exists to guarantee -- and
  # card_dma_model asserts Coyote's contract; handler_toe asserts a lane is never rebound with a
  # readPkg of its old session outstanding. Any firing is a failure whatever the verdict says.
  local asserts
  asserts="$(echo "$out" | grep -cE '^(slot_writer|card_dma_model): FAIL|handler_toe: lane [0-9]+ bound' || true)"
  if [ "${asserts:-0}" -gt 0 ]; then
    echo "$out" | grep -E '^(slot_writer|card_dma_model): FAIL|handler_toe: lane [0-9]+ bound' | head -3
    echo "FAIL  ${dut}[$lanes]  $scen  -- $asserts RTL assertion(s) fired"
    FAILS=$((FAILS + 1))
    return
  fi
  if echo "$verdict" | grep -q ": $exp"; then
    echo "PASS  ${dut}[$lanes]  $scen  ${*:-}"
  elif is_xfail "$scen"; then
    echo "XFAIL ${dut}[$lanes]  $scen  -- build-119 has no lazy open (a08b100); identical on every DUT"
  else
    echo "FAIL  ${dut}[$lanes]  $scen  ${*:-}  -- ${verdict:-no verdict line}"
    FAILS=$((FAILS + 1))
  fi
}

# ---- single case ---------------------------------------------------------------------------------
if [ -n "$ONE" ]; then
  case "$ONE" in
    r[0-9]*)
      xelab -debug typical -timescale 1ns/1ps -top rxd_drain_tb -snapshot rxd_snap \
            > xelab_rxd.log 2>&1 || { tail -30 xelab_rxd.log; exit 1; }
      run_rxd "$ONE" ;;
    *)
      if [ "$DUT" = toe ]; then
        elab "ldt${LANES}_snap" "NUM_CONNS=${LANES}" "DUT_TOE=1" || exit 1
        [ "$ONE" = "lz2" ] && { elab "ldtto_snap" "NUM_CONNS=${LANES}" "DUT_TOE=1" "STALL_CYCLES=8192" || exit 1; }
      elif [ "$DUT" = slots ]; then
        elab "lds${LANES}_snap" "NUM_CONNS=${LANES}" "DUT_SLOTS=1" || exit 1
        [ "$ONE" = "lz2" ] && { elab "ldsto_snap" "NUM_CONNS=${LANES}" "DUT_SLOTS=1" "STALL_CYCLES=8192" || exit 1; }
        { [ "$ONE" = "ovf" ] || [ "$ONE" = "cuovf" ]; } && { elab "ldsovf${LANES}_snap" "NUM_CONNS=${LANES}" "DUT_SLOTS=1" "SLOT_LOG2=16" || exit 1; }
      else
        elab "ld${LANES}_snap" "NUM_CONNS=${LANES}" || exit 1
        [ "$ONE" = "lz2" ] && { elab "ldto_snap" "NUM_CONNS=${LANES}" "STALL_CYCLES=8192" || exit 1; }
      fi
      run_hm "$DUT" "$ONE" "$LANES" "${EXTRA[@]}" ;;
  esac
  echo "lane_drain: $FAILS failed of $CASES case(s)"
  exit $(( FAILS > 0 ))
fi

# ---- everything ----------------------------------------------------------------------------------
xelab -debug typical -timescale 1ns/1ps -top rxd_drain_tb -snapshot rxd_snap \
      > xelab_rxd.log 2>&1 || { tail -30 xelab_rxd.log; exit 1; }

# rx_dispatch in isolation. UNCHANGED by ADR-5 -- it is the same module on both DUTs, with the same
# contract -- so it runs once rather than once per handler.
echo "--- rx_dispatch (shared by both DUTs, unchanged) ---"
for s in r1 r2 r3 r4 r5 r6 r7 r8; do run_rxd "$s"; done

if [ "$DUT" = multi ] || [ "$DUT" = both ]; then
  if [ ${#SKID[@]} -eq 0 ]; then
    echo "SKIP  handler_multi -- axis_skid.sv is missing and the build-119 handler instantiates it"
  else
    for N in 1 2 4; do elab "ld${N}_snap" "NUM_CONNS=${N}" || exit 1; done
    elab ldto_snap "NUM_CONNS=2" "STALL_CYCLES=8192" || exit 1
    echo "--- handler_multi (build-119 baseline) ---"
    for s in a b c d e f g h;        do run_hm multi "$s" 2; done
    for s in a2 a8 a9 a10;           do run_hm multi "$s" 2; done
    for s in lz1 lz2;                do run_hm multi "$s" 2; done
    for s in s_base s_g s_d s_e s_f; do run_hm multi "$s" 2; done
    # a fatal lane's session is released while the peer still has segments in flight: the late
    # segment lands before lane 1's next batch, then in the middle of one of lane 1's bodies
    run_hm multi cu 2
    run_hm multi cu 2 MIDBODY
    for N in 1 4; do run_hm multi s_base "$N"; run_hm multi a2 "$N"; done
  fi
fi

if [ "$DUT" = slots ] || [ "$DUT" = both ]; then
  for N in 1 2 "$NDEC"; do
    elab "lds${N}_snap"    "NUM_CONNS=${N}" "DUT_SLOTS=1" || exit 1
    elab "ldsovf${N}_snap" "NUM_CONNS=${N}" "DUT_SLOTS=1" "SLOT_LOG2=16" || exit 1
  done
  elab ldsto_snap "NUM_CONNS=2" "DUT_SLOTS=1" "STALL_CYCLES=8192" || exit 1

  # Everything runs twice since CSR revision 4: HDEPTH=1 is the host keeping one GET per
  # connection (what revision 3's hardware enforced by itself), HDEPTH=4 is the pipelined host.
  # Both keep the slot byte budget (see the feeder).
  for H in ${SLOTS_HDEPTHS:-1 4}; do
  echo "--- handler_slots (ADR-5) : the build-119 scenarios, HDEPTH=$H ---"
  for s in a b c d e f g h;        do run_hm slots "$s" 2 HDEPTH=$H; done
  for s in a2 a8 a9 a10;           do run_hm slots "$s" 2 HDEPTH=$H; done
  for s in lz1 lz2;                do run_hm slots "$s" 2 HDEPTH=$H; done
  for s in s_base s_g s_d s_e s_f; do run_hm slots "$s" 2 HDEPTH=$H; done
  for N in 1 "$NDEC"; do run_hm slots s_base "$N" HDEPTH=$H; run_hm slots a2 "$N" HDEPTH=$H; done

  echo "--- handler_slots : the questions only the slots raise, HDEPTH=$H ---"
  # (a) the host's biggest legal GET, on every connection at once
  for N in 1 2 "$NDEC"; do run_hm slots big "$N" HDEPTH=$H; done
  # (b) THE experiment: one decoder throttled to 16 B/cycle, then 4, while the others run flat out
  for N in 2 "$NDEC"; do
    run_hm slots thr "$N" THRDIV=4 HDEPTH=$H
    run_hm slots thr "$N" THRDIV=16 HDEPTH=$H
  done
  # (c) the card path slow and lumpy underneath the full scenario
  run_hm slots dmabp "$NDEC" DMA_WR_BP=50 DMA_RD_GAP=40 HDEPTH=$H
  # (d) one connection overruns its slot; nobody else may notice
  for N in 2 "$NDEC"; do run_hm slots ovf "$N" HDEPTH=$H; done
  #     ...and with the overrun connection's peer still sending: its late segment lands after the
  #     release, between two of another connection's (cuovf)
  for N in 2 "$NDEC"; do run_hm slots cuovf "$N" HDEPTH=$H; done
  # (e) a connection dies with a half-written slot, and its next response is byte-exact
  for N in 2 "$NDEC"; do run_hm slots refatal "$N" HDEPTH=$H; done
  # (e2) the peer FINs right behind a response that is complete in the handler, with its decoder
  #      stalled past CLOSE_SETTLE: FSBLEN=512 leaves the last beats in the reader->framer slice
  #      (9811956), which the FIN drain must count as it counted them in the card fifo. It was 384
  #      until the framer -> chunk counter slice (2026-09-26) put two more beats of buffering
  #      downstream of the framer: the same position is now 2 x 64 bytes further on (a mutation
  #      with the drain's fs_busy term removed fails here, as it did at 384 before). 384 now leaves
  #      the last beats INSIDE strip_http (residue and output skid), which the drain does not
  #      count -- a hole older than the slice, and not this case's question: d2c6e89 already fails
  #      FSBLEN=128..256 the same way.
  for N in 2 "$NDEC"; do run_hm slots fsfin "$N" FSBLEN=512 HDEPTH=$H; done
  done

  echo "--- handler_slots : pipelined GETs (CSR revision 4) ---"
  # (f) arms kept `DEPTH` deep against an origin with a request->response latency (SRVLAT cycles),
  #     with and without responses sharing TCP segments. Byte-exact, and faster than depth 1.
  for D in 1 4; do
    run_hm slots p1 1 DEPTH=$D NRESP=40 BLEN=16384 SRVLAT=2000
    run_hm slots p1 1 DEPTH=$D NRESP=60 BLEN=5000 SRVLAT=600 COALESCE MSS=1460
    run_hm slots p3 2 DEPTH=$D NRESP=40 SRVLAT=1000 COALESCE
    run_hm slots p4 2 DEPTH=$D NRESP=60 SRVLAT=1000
    run_hm slots p1 "$NDEC" DEPTH=$D NRESP=30 BLEN=100 SRVLAT=300 COALESCE
  done
  # (g) a connection torn down mid-response with THREE GETs armed on it: fatal, slot released,
  #     nobody else hurt -- the entries stranded behind the head must not leak anywhere.
  for N in 2 "$NDEC"; do run_hm slots refatal "$N" RFN=3 HDEPTH=4; done
  #     ...and cut in the SECOND of them, after the reader has continued onto it mid-slot.
  for N in 2 "$NDEC"; do run_hm slots refatal "$N" RFN=3 RFB=20000 RFP=7 HDEPTH=4; done
  # (h) the stage-1 bitstream's geometry, NDEC x 256 MiB slots (SLOT_LOG2 28), pipelined.
  B="lds${NDEC}big_snap"
  elab "$B" "NUM_CONNS=${NDEC}" "DUT_SLOTS=1" "SLOT_LOG2=28" || exit 1
  SNAP_OVERRIDE=$B run_hm slots p3 "$NDEC" DEPTH=4 NRESP=30 SRVLAT=1000 COALESCE
  SNAP_OVERRIDE=$B run_hm slots refatal "$NDEC" RFN=3 HDEPTH=4
  SNAP_OVERRIDE=$B run_hm slots refatal "$NDEC" RFN=3 RFB=20000 RFP=7 HDEPTH=4
fi

if [ "$DUT" = toe ]; then
  for N in 1 2 4; do elab "ldt${N}_snap" "NUM_CONNS=${N}" "DUT_TOE=1" || exit 1; done
  elab ldtto_snap "NUM_CONNS=2" "DUT_TOE=1" "STALL_CYCLES=8192" || exit 1
  echo "--- handler_toe : the build-119 scenarios on the non-bypass TOE model ---"
  for s in a a1 a2 a3 a4 a5 a8 a9 a10; do run_hm toe "$s" 2; done
  for s in b c d f g h;               do run_hm toe "$s" 2; done
  for s in lz1 lz2;                   do run_hm toe "$s" 2; done
  for s in s_base s_g s_d s_f;        do run_hm toe "$s" 2; done
  for N in 1 4; do run_hm toe s_base "$N"; run_hm toe a2 "$N"; done
  echo "--- handler_toe : new expectations (no head-of-line kill; late bytes never read) ---"
  # e/s_e: the stalled lane is NOT fatal, its bytes wait in its ring, the other lane is served
  run_hm toe e 2; run_hm toe s_e 2
  # cu/cuovf: a lane killed by a mid-response FIN; the origin's late bytes for the closed session
  # are announced and never read (cuovf: its decoder held, unread bytes in the ring at the FIN)
  run_hm toe cu 2; run_hm toe cu 2 MIDBODY; run_hm toe cuovf 2; run_hm toe cuovf 2 MIDBODY
  echo "--- handler_toe : pipelined GETs, the biggest budget, the throttled decoder ---"
  for D in 1 4; do
    run_hm toe p1 1 DEPTH=$D NRESP=40 BLEN=16384 SRVLAT=2000
    run_hm toe p1 1 DEPTH=$D NRESP=60 BLEN=5000 SRVLAT=600 COALESCE MSS=1460
    run_hm toe p3 2 DEPTH=$D NRESP=40 SRVLAT=1000 COALESCE
    run_hm toe p4 2 DEPTH=$D NRESP=60 SRVLAT=1000
    run_hm toe p1 4 DEPTH=$D NRESP=30 BLEN=100 SRVLAT=300 COALESCE
  done
  run_hm toe p5 2
  for N in 1 2 4; do run_hm toe big "$N"; done
  for N in 2 4; do run_hm toe thr "$N" THRDIV=4; run_hm toe thr "$N" THRDIV=16; done
  echo "--- handler_toe : the questions only the TOE ring raises ---"
  run_hm toe fin_overtake 2 NLAT=3000
  run_hm toe win_ok 2
  run_hm toe win_bad 2
  run_hm toe sidreuse 2 SIDREUSE
  run_hm toe thr_hbm 4
  # the model's own knobs under older scenarios: slow notifications and reads, session-id reuse
  run_hm toe h 2 NLAT=2000 RDLAT=400
  run_hm toe d 4 NLAT=1000 RDLAT=200
  run_hm toe c 2 NLAT=1500
  run_hm toe f 2 SIDREUSE
  run_hm toe b 2 SIDREUSE
fi

if [ "$DUT" = s2 ] || [ "$DUT" = both ]; then
  for C in 24 32; do
    elab "lds2c${C}${S2SFX}_snap" "NUM_CONNS=${C}" "NUM_DEC=${NDEC}" "DUT_SLOTS=1" "CSR_REV=5" || exit 1
  done
  for C in 24 32; do
    echo "--- handler_slots STAGE 2 : ${C} connections, ${NDEC} decoders ---"
    S="lds2c${C}${S2SFX}_snap"
    SNAP_OVERRIDE=$S run_hm slots s2mix  $C SRVLAT=500 SRVJIT=2000 COALESCE
    SNAP_OVERRIDE=$S run_hm slots s2mix  $C SRVLAT=300 SRVJIT=300 MSS=1460 BMAX=3000 NREQ=40 HDEPTH=4
    # SRVLAT must outlast the whole open sequence, or "every connection armed at once" measures the
    # TOE model's random open latency (40..280 cycles each, $urandom) instead of the handler: the
    # host can only arm connection k after k-1's request text is out, i.e. after it is OPEN, so the
    # last arm lands ~C x 160 cycles in on average and up to C x 295. At 4000 the 32-connection case
    # passed or failed with the random draw, which any RTL change reshuffles (xsim reseeds the
    # bench's processes when the design's process layout changes).
    SNAP_OVERRIDE=$S run_hm slots s2arm  $C SRVLAT=12000 HDEPTH=1
    SNAP_OVERRIDE=$S run_hm slots s2fatal $C SRVLAT=3000 SRVJIT=1000
    SNAP_OVERRIDE=$S run_hm slots s2idle $C SRVLAT=300
    for s in a g h d; do SNAP_OVERRIDE=$S run_hm slots "$s" $C; done
    SNAP_OVERRIDE=$S run_hm slots dmabp $C DMA_WR_BP=50 DMA_RD_GAP=40
    SNAP_OVERRIDE=$S run_hm slots big   $C
    SNAP_OVERRIDE=$S run_hm slots thr   $C THRDIV=16
    SNAP_OVERRIDE=$S run_hm slots p3    $C DEPTH=8 NRESP=40 SRVLAT=1000 COALESCE
  done
  # the RUNTIME connection count (OASIS_HTTP_CONNS on the board): the 32-connection bitstream with
  # the host using only 4, 24 or all 32 of them.
  for U in 4 24 32; do
    SNAP_OVERRIDE=lds2c32${S2SFX}_snap run_hm slots s2mix 32 S2CONNS=$U S2MINUSED=$U SRVLAT=500 SRVJIT=1000 COALESCE
  done
fi

echo "lane_drain: $FAILS failed of $CASES case(s)"
exit $(( FAILS > 0 ))

#!/usr/bin/env bash
# lane_drain -- independent black-box liveness bench for the HTTP receive path.
#
# The bench models the whole outside world (Coyote TOE, an HTTP/1.1 origin server, the host config
# port and DMA, and the per-decoder sink) and checks four properties continuously: LIVENESS (a
# readPkg within a bounded number of cycles while a notification is outstanding), ROUTING
# (byte-exact, to the connection bound to that session), FRAMING (one tlast per chunk at the
# configured byte count) and RECOVERY (everything drains once a transient clears).
#
# TWO DUTs
#   --dut multi   handler_multi (TOE in bypass mode, one shared rx FIFO, rx_dispatch). The default
#                 for a named scenario.
#   --dut toe     handler_toe (TOE with a receive ring per session, RX_DDR_BYPASS=0) against the
#                 bench's NON-BYPASS TOE MODEL (per-session rings, delayed notifications with the
#                 FIN overtaking them, over-read = failure, window model).
#   --dut both    both, which is what a bare ./run.sh does.
#
#   ./run.sh                          everything, both DUTs
#   ./run.sh --dut toe                every handler_toe scenario
#   ./run.sh <scen> [lanes]           one scenario at one lane count on handler_multi (default 2)
#   ./run.sh --dut toe <scen> [n]     ...on handler_toe
#   ./run.sh p1 1 DEPTH=2 NRESP=100   ...plus any extra plusargs, forwarded verbatim to xsim
#
# Exit status is 1 if any case failed. Cases whose passing verdict is not the word PASS are declared
# below rather than guessed: `e` and `s_e` measure CONTAINMENT and say so, `win_bad` breaks the
# window rule on purpose, and `lz1`/`lz2` are EXPECTED TO FAIL on both DUTs for the same reason --
# handler_multi predates the lazy-open fix (commit a08b100, which shipped in the broken build-120),
# and handler_toe keeps its session side. They are reported as XFAIL with that reason instead of
# being hidden or counted.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
HDL="$ROOT/../../src/hdl/http_read"

if ! command -v xvlog >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
fi

cd "$ROOT"

DUT=both
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

xvlog -sv lynxTypes_stub.sv \
      "$HDL/http_types.sv" "$HDL/axis_fifo.sv" "$HDL/axis_skid.sv" \
      "$HDL/strip_http.sv" "$HDL/tcp_read.sv" \
      "$HDL/rx_dispatch.sv" "$HDL/tcp_init.sv" "$HDL/http_req_stream.sv" \
      "$HDL/axis_rewrite_last.sv" "$HDL/tx_arbiter.sv" "$HDL/handler_multi.sv" \
      "$HDL/toe_rx.sv" "$HDL/handler_toe.sv" \
      rxd_drain_tb.sv lane_drain_tb.sv > xvlog.log 2>&1 \
  || { tail -40 xvlog.log; exit 1; }

elab() { # <snapshot> <generic>...
  local snap="$1"; shift
  local g=(); local x; for x in "$@"; do g+=(-generic_top "$x"); done
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
  case "$dut" in toe) pfx=ldt ;; *) pfx=ld ;; esac
  snap="${SNAP_OVERRIDE:-${pfx}${lanes}_snap}"
  # lz2 has to WAIT for the connect watchdog, which defaults to 2^28 cycles -- a second on the
  # board, a week in xsim. Its own snapshot shrinks only that parameter.
  [ "$scen" = "lz2" ] && snap="${pfx}to_snap"

  local a=(-testplusarg "SCEN=$scen"); local p
  for p in "$@"; do a+=(-testplusarg "$p"); done
  CASES=$((CASES + 1))
  out="$(xsim "$snap" -R "${a[@]}" 2>&1)"
  verdict="$(echo "$out" | grep -E "^lane_drain_tb '" | tail -1)"
  exp="$(expected "$scen")"
  echo "$out" | grep -E '^  == |^     conn |^     stall bits|^     worst ' || true
  # The RTL's own simulation-only invariant: handler_toe asserts a lane is never rebound with a
  # readPkg of its old session outstanding. A firing is a failure whatever the verdict says.
  local asserts
  asserts="$(echo "$out" | grep -cE 'handler_toe: lane [0-9]+ bound' || true)"
  if [ "${asserts:-0}" -gt 0 ]; then
    echo "$out" | grep -E 'handler_toe: lane [0-9]+ bound' | head -3
    echo "FAIL  ${dut}[$lanes]  $scen  -- $asserts RTL assertion(s) fired"
    FAILS=$((FAILS + 1))
    return
  fi
  if echo "$verdict" | grep -q ": $exp"; then
    echo "PASS  ${dut}[$lanes]  $scen  ${*:-}"
  elif is_xfail "$scen"; then
    echo "XFAIL ${dut}[$lanes]  $scen  -- no lazy open (a08b100); identical on both DUTs"
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

# rx_dispatch (handler_multi's receive dispatcher) in isolation. Runs once per invocation.
echo "--- rx_dispatch ---"
for s in r1 r2 r3 r4 r5 r6 r7 r8; do run_rxd "$s"; done

if [ "$DUT" = multi ] || [ "$DUT" = both ]; then
  for N in 1 2 4; do elab "ld${N}_snap" "NUM_CONNS=${N}" || exit 1; done
  elab ldto_snap "NUM_CONNS=2" "STALL_CYCLES=8192" || exit 1
  echo "--- handler_multi ---"
  for s in a b c d e f g h;        do run_hm multi "$s" 2; done
  for s in a2 a8 a9 a10;           do run_hm multi "$s" 2; done
  for s in lz1 lz2;                do run_hm multi "$s" 2; done
  # an open the TOE refuses: during the first bring-up (of1), and on a reconnect (of2)
  run_hm multi of1 2; run_hm multi of1 4; run_hm multi of2 2
  for s in s_base s_g s_d s_e s_f; do run_hm multi "$s" 2; done
  # a fatal lane's session is released while the peer still has segments in flight: the late
  # segment lands before lane 1's next batch, then in the middle of one of lane 1's bodies
  run_hm multi cu 2
  run_hm multi cu 2 MIDBODY
  for N in 1 4; do run_hm multi s_base "$N"; run_hm multi a2 "$N"; done
fi

if [ "$DUT" = toe ] || [ "$DUT" = both ]; then
  for N in 1 2 4; do elab "ldt${N}_snap" "NUM_CONNS=${N}" "DUT_TOE=1" || exit 1; done
  elab ldtto_snap "NUM_CONNS=2" "DUT_TOE=1" "STALL_CYCLES=8192" || exit 1
  echo "--- handler_toe : the handler_multi scenarios on the non-bypass TOE model ---"
  for s in a a1 a2 a3 a4 a5 a8 a9 a10; do run_hm toe "$s" 2; done
  for s in b c d f g h;               do run_hm toe "$s" 2; done
  for s in lz1 lz2;                   do run_hm toe "$s" 2; done
  run_hm toe of1 2; run_hm toe of1 4; run_hm toe of2 2
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

echo "lane_drain: $FAILS failed of $CASES case(s)"
exit $(( FAILS > 0 ))

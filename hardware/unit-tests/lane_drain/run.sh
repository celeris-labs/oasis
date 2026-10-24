#!/usr/bin/env bash
# lane_drain -- independent black-box liveness bench for the HTTP receive path.
#
# The bench models the whole outside world (Coyote TOE, an HTTP/1.1 origin server, the host config
# port and DMA, and the per-decoder sink) and checks four properties continuously: LIVENESS (a
# readPkg within a bounded number of cycles while a notification is outstanding), ROUTING
# (byte-exact, to the connection bound to that session), FRAMING (one tlast per chunk at the
# configured byte count) and RECOVERY (everything drains once a transient clears).
#
# The DUT is handler_multi (TOE in bypass mode, one shared rx FIFO, rx_dispatch).
#
#   ./run.sh                          everything
#   ./run.sh <scen> [lanes]           one scenario at one lane count (default 2)
#   ./run.sh p1 1 DEPTH=2 NRESP=100   ...plus any extra plusargs, forwarded verbatim to xsim
#
# Exit status is 1 if any case failed. Cases whose passing verdict is not the word PASS are declared
# below rather than guessed: `e` and `s_e` measure CONTAINMENT and say so, and `lz1`/`lz2` are
# EXPECTED TO FAIL: they ask for behaviour the handler does not have. lz1 wants a lazy open (an idle
# lane whose peer FINs stays down until its next batch; the handler reconnects at once), lz2 wants
# an open that is never answered to time out and free the bring-up FSM (the handler waits in
# BR_OPEN; the connect watchdog only raises a sticky bit). They are reported as XFAIL with that
# reason instead of being hidden or counted.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
HDL="$ROOT/../../src/hdl/http_read"

if ! command -v xvlog >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
fi

cd "$ROOT"

ONE=""
LANES=2
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    *=*)   EXTRA+=("$1"); shift ;;
    *)
      if [ -z "$ONE" ]; then ONE="$1"; shift
      elif [[ "$1" =~ ^[0-9]+$ ]]; then LANES="$1"; shift
      else EXTRA+=("$1"); shift
      fi ;;
  esac
done

rm -rf xsim.dir xsim.jou xsim.log xvlog.pb xelab.pb webtalk* .Xil 2>/dev/null || true

xvlog -sv ../common/lynxTypes_stub.sv \
      "$HDL/http_types.sv" "$HDL/axis_fifo.sv" "$HDL/axis_skid.sv" \
      "$HDL/strip_http.sv" "$HDL/tcp_read.sv" \
      "$HDL/rx_dispatch.sv" "$HDL/tcp_init.sv" "$HDL/http_req_stream.sv" \
      "$HDL/axis_rewrite_last.sv" "$HDL/tx_arbiter.sv" "$HDL/handler_multi.sv" \
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
    *)       echo "PASS" ;;
  esac
}
is_xfail() { case "$1" in lz1|lz2) return 0 ;; *) return 1 ;; esac; }
xfail_why() {
  case "$1" in
    lz1) echo "known limitation: no lazy open, an idle FIN reconnects at once" ;;
    lz2) echo "known limitation: an open that is never answered holds BR_OPEN" ;;
  esac
}

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

run_hm() { # <scen> <lanes> [plusargs...]
  local scen="$1" lanes="$2"; shift 2
  local snap exp out verdict
  snap="${SNAP_OVERRIDE:-ld${lanes}_snap}"
  # lz2 has to WAIT for the connect watchdog, which defaults to 2^28 cycles -- a second on the
  # board, a week in xsim. Its own snapshot shrinks only that parameter.
  [ "$scen" = "lz2" ] && snap="ldto_snap"

  local a=(-testplusarg "SCEN=$scen"); local p
  for p in "$@"; do a+=(-testplusarg "$p"); done
  CASES=$((CASES + 1))
  out="$(xsim "$snap" -R "${a[@]}" 2>&1)"
  verdict="$(echo "$out" | grep -E "^lane_drain_tb '" | tail -1)"
  exp="$(expected "$scen")"
  echo "$out" | grep -E '^  == |^     conn |^     stall bits|^     worst ' || true
  if echo "$verdict" | grep -q ": $exp"; then
    echo "PASS  multi[$lanes]  $scen  ${*:-}"
  elif is_xfail "$scen"; then
    echo "XFAIL multi[$lanes]  $scen  -- $(xfail_why "$scen")"
  else
    echo "FAIL  multi[$lanes]  $scen  ${*:-}  -- ${verdict:-no verdict line}"
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
      elab "ld${LANES}_snap" "NUM_CONNS=${LANES}" || exit 1
      [ "$ONE" = "lz2" ] && { elab "ldto_snap" "NUM_CONNS=${LANES}" "STALL_CYCLES=8192" || exit 1; }
      run_hm "$ONE" "$LANES" "${EXTRA[@]}" ;;
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

for N in 1 2 4; do elab "ld${N}_snap" "NUM_CONNS=${N}" || exit 1; done
elab ldto_snap "NUM_CONNS=2" "STALL_CYCLES=8192" || exit 1
for s in a b c d e f g h;        do run_hm "$s" 2; done
for s in a2 a8 a9 a10;           do run_hm "$s" 2; done
for s in lz1 lz2;                do run_hm "$s" 2; done
# an open the TOE refuses: during the first bring-up (of1), and on a reconnect (of2)
run_hm of1 2; run_hm of1 4; run_hm of2 2
for s in s_base s_g s_d s_e s_f; do run_hm "$s" 2; done
# a fatal lane's session is released while the peer still has segments in flight: the late
# segment lands before lane 1's next batch, then in the middle of one of lane 1's bodies
run_hm cu 2
run_hm cu 2 MIDBODY
for N in 1 4; do run_hm s_base "$N"; run_hm a2 "$N"; done

echo "lane_drain: $FAILS failed of $CASES case(s)"
exit $(( FAILS > 0 ))

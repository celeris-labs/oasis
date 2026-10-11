#!/usr/bin/env bash
# tcp_mem_mux -- Coyote's TOE memory multiplexer (hardware/patches/0008): the TOE's tx-ring and
# rx-ring memory channels onto the shell's one TCP memory channel. See tcp_mem_mux_tb.sv for the
# models and the checks.
#
#   ./run.sh                 every case, then the mutation runs (the bench must catch each mutant)
#   ./run.sh <scen> [cfg]    one scenario; cfg = def | small | tiny (default def)
#   SEEDS="1 2 3" ./run.sh   seeds per case (default "1 2")
#   COY=<coyote dir>         take tcp_mem_mux.sv from another Coyote checkout
#
# CONFIGS (DUT parameters)
#   def    the build's: TXW_DEPTH 1024, N_RD 32, N_WR 32, CMDQ_DEPTH 16 (rate: >= 95% of one beat/cycle)
#   small  everything that can fill does: N_RD 2, N_WR 1, CMDQ_DEPTH 2
#   tiny   TXW_DEPTH 16 (tx packets <= 16 beats): the store-and-forward FIFO full with whole +
#          partial packets
#
# MUTANTS (copies of the RTL, edited by sed; each must make its target case FAIL)
#   no_sf    tx write commands eligible before their packet is complete     -> tx_slow
#   no_cred  write-status credits ignored                                   -> wsts_stall
#   no_bit29 rx addresses not moved to the rx region                         -> basic
#
# Exit status 1 if any case or mutant check fails.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
COY="${COY:-$ROOT/../../../parcore/libstf/coyote}"
RTL="$COY/hw/hdl/network/tcp/tcp_mem_mux.sv"
SEEDS="${SEEDS:-1 2}"

if ! command -v xvlog >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
fi
[ -f "$RTL" ] || { echo "tcp_mem_mux.sv not found at $RTL (patch 0008 applied? see hardware/patches/apply.sh)"; exit 1; }

cd "$ROOT"
rm -rf xsim.dir xsim.jou xsim.log xvlog.pb xelab.pb webtalk* .Xil mut 2>/dev/null || true

generics() { # <cfg>
  case "$1" in
    def)   echo "TXW_DEPTH=1024 N_RD=32 N_WR=32 CMDQ_DEPTH=16" ;;
    small) echo "TXW_DEPTH=1024 N_RD=2 N_WR=1 CMDQ_DEPTH=2" ;;
    tiny)  echo "TXW_DEPTH=16 N_RD=32 N_WR=32 CMDQ_DEPTH=16" ;;
  esac
}

build() { # <lib-tag> <rtl> <cfg>
  local tag="$1" rtl="$2" cfg="$3" snap="${1}_${3}" g=() x
  [ -d "xsim.dir/$snap" ] && return 0
  for x in $(generics "$cfg"); do g+=(-generic_top "$x"); done
  xvlog -sv -work "w_$tag" "$rtl" tcp_mem_mux_tb.sv > "xvlog_$tag.log" 2>&1 || { tail -20 "xvlog_$tag.log"; return 1; }
  xelab -debug typical -timescale 1ns/1ps -L "w_$tag" "w_$tag.tcp_mem_mux_tb" -snapshot "$snap" "${g[@]}" \
        > "xelab_$snap.log" 2>&1 || { tail -20 "xelab_$snap.log"; return 1; }
}

FAILS=0
CASES=0
TABLE=()

run_case() { # <tag> <cfg> <scen> <seed> -> sets RUN_VERDICT, RUN_LINE
  local tag="$1" cfg="$2" scen="$3" seed="$4" out
  out="$(xsim "${tag}_${cfg}" -R -sv_seed "$seed" -testplusarg "SCEN=$scen" 2>&1)"
  echo "$out" > "run_${tag}_${cfg}_${scen}_${seed}.log"
  RUN_LINE="$(echo "$out" | grep -E "^tcp_mem_mux_tb '" | tail -1)"
  RUN_STATS="$(echo "$out" | grep -E '^  stats:' | tail -1 | sed 's/^  stats: //')"
  if [ "$scen" = addr29 ]; then
    if echo "$out" | grep -q "has bits \[63:29\] set"; then RUN_VERDICT=PASS; else RUN_VERDICT=FAIL; fi
  elif echo "$RUN_LINE" | grep -q ": PASS"; then RUN_VERDICT=PASS
  else RUN_VERDICT=FAIL
  fi
}

case_line() { # <cfg> <scen>
  local cfg="$1" scen="$2" s v=PASS stats=""
  for s in $SEEDS; do
    CASES=$((CASES + 1))
    run_case dut "$cfg" "$scen" "$s"
    if [ "$RUN_VERDICT" != PASS ]; then
      v=FAIL; FAILS=$((FAILS + 1))
      echo "FAIL  $cfg  $scen  seed $s  -- ${RUN_LINE:-no verdict line}"
      grep -m3 ERROR "run_dut_${cfg}_${scen}_${s}.log" | sed 's/^/        /'
    else
      echo "PASS  $cfg  $scen  seed $s  ${RUN_STATS}"
    fi
    stats="$RUN_STATS"
    [ "$scen" = rd_hol ] && stats="$(echo "$RUN_LINE" | sed 's/.*PASS //')"
  done
  TABLE+=("| $scen | $cfg | $v | $stats |")
}

# ---- single case ---------------------------------------------------------------------------------
if [ $# -ge 1 ]; then
  cfg="${2:-def}"
  build dut "$RTL" "$cfg" || exit 1
  for s in $SEEDS; do
    CASES=$((CASES + 1))
    run_case dut "$cfg" "$1" "$s"
    echo "$RUN_VERDICT  $cfg  $1  seed $s  -- $RUN_LINE"
    [ -n "$RUN_STATS" ] && echo "      $RUN_STATS"
    [ "$RUN_VERDICT" = PASS ] || { FAILS=$((FAILS + 1)); grep -m5 ERROR "run_dut_${cfg}_${1}_${s}.log"; }
  done
  echo "tcp_mem_mux: $FAILS failed of $CASES"
  exit $(( FAILS > 0 ))
fi

# ---- everything ----------------------------------------------------------------------------------
for cfg in def small tiny; do build dut "$RTL" "$cfg" || exit 1; done

for scen in basic bp burst rate free max tx_slow wsts_stall rd_hol addr29; do case_line def "$scen"; done
for scen in basic bp burst free tx_slow wsts_stall; do case_line small "$scen"; done
for scen in basic bp burst free; do case_line tiny "$scen"; done

# ---- mutants: the bench must catch each one ------------------------------------------------------
mkdir -p mut
sed "s/(tx_pkts_q != '0)/1'b1/" "$RTL" > mut/no_sf.sv
sed "s/assign cred_ok\[c\] = (cred_q != '0);/assign cred_ok[c] = 1'b1;/" "$RTL" > mut/no_cred.sv
sed "s/if (ch == RX) c\[RX_ADDR_BIT\] = 1'b1;/if (ch == RX) c = c;/" "$RTL" > mut/no_bit29.sv
MUT=()
for m in "no_sf tx_slow" "no_cred wsts_stall" "no_bit29 basic"; do
  set -- $m
  if cmp -s "mut/$1.sv" "$RTL"; then
    echo "FAIL  mutant $1: the sed did not change the RTL (pattern drifted)"; FAILS=$((FAILS + 1)); continue
  fi
  build "$1" "mut/$1.sv" def || exit 1
  CASES=$((CASES + 1))
  run_case "$1" def "$2" 1
  if [ "$RUN_VERDICT" = FAIL ]; then
    echo "PASS  mutant $1 caught by $2 -- $(grep -m1 ERROR "run_${1}_def_${2}_1.log" | sed 's/^\[[^]]*\] //')"
    MUT+=("| $1 | $2 | caught: $(grep -m1 ERROR "run_${1}_def_${2}_1.log" | sed 's/^\[[^]]*\] ERROR: //' | cut -c1-110) |")
  else
    echo "FAIL  mutant $1 NOT caught by $2"; FAILS=$((FAILS + 1))
    MUT+=("| $1 | $2 | NOT caught |")
  fi
done

echo
echo "| case | config | verdict ($(echo $SEEDS | wc -w) seeds) | stats (last seed) |"
echo "|---|---|---|---|"
printf '%s\n' "${TABLE[@]}"
echo
echo "| mutant | case | result |"
echo "|---|---|---|"
printf '%s\n' "${MUT[@]}"
echo
echo "tcp_mem_mux: $FAILS failed of $CASES"
exit $(( FAILS > 0 ))

#!/usr/bin/env bash
#
# Throughput / latency harness for read_oasis() over httpfpga://.
#
# Every measurement brackets the query with a read of oasis_stream_profile(). That readout is
# destructive by design (column_chunk_decoder_config.sv pulses profile[I].stop on the read of the
# last profile register), so the first call arms a window and the second one reports exactly the
# cycles the query spent. From those four counters the whole story falls out:
#
#   handshakes  cycles that moved a 64 B beat into the decoder   -> useful work
#   starved     inside a column chunk, waiting for network bytes -> TCP / MinIO too slow
#   stalled     decoder backpressured the source                 -> decoder is the bottleneck
#   idle        BETWEEN column chunks                            -> connect + close + host round trip
#
# The interesting number is almost never the throughput. It is idle/(total): the fraction of the
# query the decoder spent waiting for the next request to be set up. Divide idle_cycles*4ns by the
# request count and you have the per-request dead time, which is what actually caps this design.
#
# Usage:
#   scripts/throughput.sh                         # all workloads on the default file
#   scripts/throughput.sh --workload latency      # per-request dead time only
#   scripts/throughput.sh --file /tpch1/lineitem.parquet --repeat 5
#
# Env overrides: DUCKDB, OASIS_SERVER, OASIS_PORT.
#
# NOTE: never set OASIS_HTTP_DEBUG=1 while measuring. Its tracing thread calls read_profile() three
# times per request, and each of those resets the counters you are trying to read.

set -uo pipefail

DUCKDB=${DUCKDB:-$(dirname "$0")/../extension/build/release/duckdb}
SERVER=${OASIS_SERVER:-10.253.74.74}
PORT=${OASIS_PORT:-9000}
FILE=/tpch1/lineitem.parquet
REPEAT=3
WORKLOAD=all

while [ $# -gt 0 ]; do
    case "$1" in
        --file)     FILE="$2"; shift ;;
        --repeat)   REPEAT="$2"; shift ;;
        --server)   SERVER="$2"; shift ;;
        --port)     PORT="$2"; shift ;;
        --workload) WORKLOAD="$2"; shift ;;
        -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

if [ ! -x "$DUCKDB" ]; then
    echo "No duckdb shell at $DUCKDB (build it with 'make' in extension/)" >&2
    exit 1
fi

URL="httpfpga://$FILE"
SETUP="SET http_server='$SERVER'; SET http_port=$PORT;"

# ---------------------------------------------------------------------------------------------
# Workload definitions. Each is a query over read_oasis($URL) plus the number of hardware column
# chunks it fetches PER ROW GROUP -- that count times the row groups is the number of GETs, which
# is what per-request dead time has to be divided by.
# ---------------------------------------------------------------------------------------------
q_sql() {
    case "$1" in
        latency) # one INT64 column, no filter: requests == row groups exactly.
            echo "SELECT sum(l_orderkey) FROM read_oasis('$URL');" ;;
        q6)
            echo "SELECT sum(l_extendedprice * l_discount) AS revenue FROM read_oasis('$URL')
                  WHERE l_shipdate >= DATE '1994-01-01' AND l_shipdate < DATE '1995-01-01'
                    AND l_discount BETWEEN 0.05 AND 0.07 AND l_quantity < 24;" ;;
        q1)
            echo "SELECT l_returnflag, l_linestatus, sum(l_quantity) AS sum_qty,
                         sum(l_extendedprice) AS sum_base_price,
                         sum(l_extendedprice * (1 - l_discount)) AS sum_disc_price,
                         count(*) AS count_order
                  FROM read_oasis('$URL')
                  WHERE l_shipdate <= DATE '1998-09-02'
                  GROUP BY 1, 2 ORDER BY 1, 2;" ;;
        wide) # every fixed-width column: the most bytes this file can push through the decoder.
            echo "SELECT sum(l_orderkey), sum(l_partkey), sum(l_suppkey), sum(l_linenumber),
                         sum(l_quantity), sum(l_extendedprice), sum(l_discount), sum(l_tax)
                  FROM read_oasis('$URL');" ;;
    esac
}

q_cols() {
    case "$1" in
        latency) echo 1 ;;
        q6)      echo 4 ;;   # shipdate, discount, quantity, extendedprice
        q1)      echo 4 ;;   # shipdate, quantity, extendedprice, discount (returnflag/linestatus are CPU)
        wide)    echo 8 ;;
    esac
}

# The CPU comparison: same object, same server, same DuckDB, but fetched over an ordinary host
# socket and parsed by DuckDB's Parquet reader. This is the honest baseline -- it isolates the
# decode path rather than the storage.
q_cpu_sql() { q_sql "$1" | sed "s/read_oasis(/read_parquet(/"; }

row_groups() {
    "$DUCKDB" -noheader -list -c "
        $SETUP SET httpfpga_cpu_fallback=true;
        SELECT count(DISTINCT row_group_id) FROM parquet_metadata('$URL');" 2>/dev/null | tail -1
}

run_one() {
    local name=$1 mode=$2 sql=$3
    local sql_file; sql_file=$(mktemp)
    {
        echo "$SETUP"
        [ "$mode" = cpu ] && echo "SET httpfpga_cpu_fallback=true;"
        # Arm the profiler window, then time the query, then read the window back.
        echo "SELECT count(*) FROM oasis_stream_profile();"
        echo ".timer on"
        echo "$sql"
        echo ".timer off"
        if [ "$mode" = oasis ]; then
            echo "SELECT decoder, in_handshakes_cycles AS hs, in_starved_cycles AS starved,
                         in_stalled_cycles AS stalled, in_idle_cycles AS idle,
                         out_handshakes_cycles AS out_hs,
                         round(in_throughput_gbps, 3) AS in_gbps,
                         round(in_throughput_excl_idle_gbps, 3) AS in_gbps_busy,
                         round(out_throughput_gbps, 3) AS out_gbps
                  FROM oasis_stream_profile();"
        fi
    } > "$sql_file"
    echo "--- $name [$mode] run"
    "$DUCKDB" < "$sql_file"
    rm -f "$sql_file"
}

echo "=============================================================================="
echo " oasis throughput   file=$FILE  server=$SERVER:$PORT  repeat=$REPEAT"
RG=$(row_groups)
echo " row groups: ${RG:-unknown}"
echo "=============================================================================="

# ---------------------------------------------------------------------------------------------
# Connection budget.
#
# Every column chunk is its own ranged GET on its own TCP connection (the request says
# `Connection: close`; keep-alive is not implemented). The TOE hands out ephemeral ports from a
# pool of exactly TCP_STACK_MAX_SESSIONS = 512 -- ports 32768..33279, cursor wrapping at 512 --
# and releases each one the moment the connection closes, with no quiet time. The server closes
# first, so IT holds the 4-tuple in TIME_WAIT for 60 s.
#
# So once a run exceeds 512 connections, every reused port lands on a tuple the server still owns.
# The TOE presents a random ISN, Linux usually refuses to recycle the TIME_WAIT socket, and the
# resulting challenge ACK resets the SYN retry counter in the TOE's rx engine -- so the SYN is
# retried forever and openStatus never arrives. The handler waits in CONNECT and the query dies on
# the host-side credit timeout.
#
# The cursor lives in the bitstream, so this count is CUMULATIVE SINCE PROGRAMMING. Restarting
# duckdb does not reset it; reprogramming does.
# ---------------------------------------------------------------------------------------------
PORT_POOL=512
[ "$WORKLOAD" = all ] && WORKLOADS="latency q6 q1 wide" || WORKLOADS="$WORKLOAD"
total_cols=0
for w in $WORKLOADS; do
    total_cols=$((total_cols + $(q_cols "$w")))
done
CONNS=$((total_cols * ${RG:-0} * REPEAT))
echo " estimated ranged GETs (== TCP connections) for this run: $CONNS"
if [ "$CONNS" -ge "$PORT_POOL" ]; then
    cat <<EOF
 !! This run needs $CONNS connections but the FPGA only has $PORT_POOL ephemeral ports, and the
 !! count is cumulative since the bitstream was programmed. It WILL wrap into the server's 60 s
 !! TIME_WAIT and is likely to wedge partway through with a stalled CONNECT.
 !!
 !! Until keep-alive exists, the fix is fewer connections, i.e. fewer/larger row groups:
 !!   COPY tbl TO 'x.parquet' (FORMAT parquet, ROW_GROUP_SIZE 1000000);
 !! At ~1M-row groups this file would need about $((total_cols * 7 * REPEAT)) connections instead.
 !! Reprogram the bitstream before the run to start from a fresh port cursor.
EOF
fi
echo "=============================================================================="

for w in $WORKLOADS; do
    cols=$(q_cols "$w")
    echo
    echo "##############################################################################"
    echo "# $w -- $cols hardware column(s) per row group => $((cols * ${RG:-0})) ranged GETs"
    echo "##############################################################################"
    for i in $(seq 1 "$REPEAT"); do
        run_one "$w" oasis "$(q_sql "$w")"
    done
    echo "--- $w CPU baseline (same object over a host socket, DuckDB parquet reader)"
    run_one "$w" cpu "$(q_cpu_sql "$w")"
done

cat <<'EOF'

------------------------------------------------------------------------------
Reading the counters (all cycles are 4 ns at the 250 MHz user clock):

  bytes into decoder   = hs * 64
  FPGA-side wall time  = (hs + starved + stalled + idle) * 4 ns
  duty cycle           = hs / (hs + starved + stalled + idle)
  per-request dead time = idle * 4 ns / (GETs - 1)

If idle dominates you are latency-bound on request setup (TCP connect, MinIO
time-to-first-byte, close, host round trip) and no amount of decoder speed helps.
If starved dominates, the body itself arrives too slowly. If stalled dominates,
the decoder is genuinely the bottleneck -- which so far it never is.
------------------------------------------------------------------------------
EOF

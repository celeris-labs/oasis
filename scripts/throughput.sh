#!/usr/bin/env bash
#
# Throughput / latency harness for read_oasis() over httpfpga://.
#
# Every measurement brackets the query with a read of oasis_stream_profile(). Reading the last
# profile register pulses profile[I].stop (column_chunk_decoder_config.sv:96), which returns the
# profiler to WAIT and HOLDS its counters; they are re-zeroed by the next valid data beat, not by
# the read (stream_profiler.sv:4-7). So the first call ends whatever window was running and the
# second reports exactly the cycles this query spent -- PROVIDED the query actually moved data.
#
# If it did not -- a 404, a scan fully pruned by filter statistics, count(*), or an all-string
# projection -- the second read returns the PREVIOUS query's numbers rather than zero, and a stale
# reading is indistinguishable from a real one. Always check the value changed before believing it.
#
# From those four counters the whole story falls out:
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
#   scripts/throughput.sh --file /throughput/tpch-1/lineitem.parquet --repeat 5
#
# Env overrides: DUCKDB, OASIS_SERVER, OASIS_PORT.
#
# NOTE: never set OASIS_HTTP_DEBUG=1 while measuring. Its tracing thread calls read_profile() three
# times per request, and each of those resets the counters you are trying to read.

set -uo pipefail

DUCKDB=${DUCKDB:-$(dirname "$0")/../extension/build/release/duckdb}
SERVER=${OASIS_SERVER:-10.253.74.74}
PORT=${OASIS_PORT:-9000}
# 35 characters, which needs the 64-character GET path budget (build-89 and later). On an
# older 32-character bitstream use a short alias bucket instead, e.g. /tpch1/lineitem.parquet.
FILE=/throughput/tpch-1/lineitem.parquet
REPEAT=3
WORKLOAD=all
# EXPORTED, not assumed. This used to default to 8192 for its own arithmetic while the library used
# whatever HTTP_DEFAULT_CHUNK_BYTES had become -- so every derived column (gets, kib_per_get,
# dead_us_per_get) was computed from a split that was not in force. At the 192 KiB default that made
# the GET count wrong by 24x. Exporting it means the number printed is the number used.
# Keep in step with HTTP_DEFAULT_CHUNK_BYTES in software/oasis/configuration.cpp.
export OASIS_HTTP_CHUNK_BYTES=${OASIS_HTTP_CHUNK_BYTES:-0}

while [ $# -gt 0 ]; do
    case "$1" in
        --file)     FILE="$2"; shift ;;
        # Convenience, so this takes the same argument as tpch_demo.sh instead of a full path.
        --scale)    FILE="/throughput/tpch-$2/lineitem.parquet"; shift ;;
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
# enable_progress_bar=false is not cosmetic. The bar redraws with carriage returns and leaves
# partial lines behind, so a captured run comes out full of blank gaps between the query result and
# its profile readback -- and the redraw thread runs during the window being measured.
SETUP="SET http_server='$SERVER'; SET http_port=$PORT; SET enable_progress_bar=false;"

# ---------------------------------------------------------------------------------------------
# Workload definitions. Each is a query over read_oasis($URL) plus the number of hardware column
# chunks it fetches PER ROW GROUP. That count times the row groups is the column-chunk count; each
# chunk is then split into GETs of at most OASIS_HTTP_CHUNK_BYTES on the one open connection.
# ---------------------------------------------------------------------------------------------
q_sql() {
    case "$1" in
        latency) # one INT64 column, no filter: column chunks == row groups exactly.
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
    local name=$1 mode=$2 sql=$3 chunks=${4:-0}
    # GETs actually issued: one per OASIS_HTTP_CHUNK_BYTES slice of every column chunk, or one per
    # column chunk when splitting is off. Needed to turn the cycle counters into a per-request cost,
    # which is the number that discriminates "the link is slow" from "each request costs a fixed
    # amount no matter how big it is".
    local split=$OASIS_HTTP_CHUNK_BYTES
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
            # .mode line, not the default box. The box renderer drops columns to fit the terminal,
            # and the two it dropped were stalled and idle -- precisely the pair that says whether
            # the decoder is waiting on the network or on the host. One field per line never lies.
            echo ".mode line"
            echo "WITH c AS (
                    SELECT decoder,
                           in_handshakes_cycles AS hs, in_starved_cycles AS starved,
                           in_stalled_cycles AS stalled, in_idle_cycles AS idle,
                           in_throughput_gbytes_s AS gbytes_s
                    FROM oasis_stream_profile()
                  ), t AS (
                    SELECT *, hs + starved + stalled + idle AS total, hs * 64 AS bytes FROM c
                  ), g AS (
                    SELECT *, CASE WHEN $split > 0
                                   THEN ceil(bytes / greatest(${split}.0, 1.0))
                                   ELSE $chunks END AS gets
                    FROM t
                  )
                  SELECT decoder, hs, starved, stalled, idle, total,
                         round(bytes / 1048576.0, 2)                  AS mib_in,
                         round(total * 4e-9, 4)                       AS fpga_s,
                         round(100.0 * hs      / nullif(total,0), 3)  AS duty_pct,
                         round(100.0 * starved / nullif(total,0), 1)  AS starved_pct,
                         round(100.0 * stalled / nullif(total,0), 1)  AS stalled_pct,
                         round(100.0 * idle    / nullif(total,0), 1)  AS idle_pct,
                         CAST(gets AS BIGINT)                         AS gets,
                         round(bytes / nullif(gets,0) / 1024.0, 1)    AS kib_per_get,
                         round((starved + idle) * 4e-3 / nullif(gets,0), 1)
                                                                      AS dead_us_per_get,
                         round(gbytes_s * 1000.0, 1)                  AS in_mbytes_s
                  FROM g;"
            echo ".mode duckbox"
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
# Request budget.
#
# Every column chunk is a ranged GET, but they no longer cost a TCP connection each: the client
# holds ONE persistent connection open across every request and every query (the request says
# `Connection: keep-alive` and strip_http delimits each response by Content-Length). So the 512
# ephemeral ports the TOE has -- 32768..33279, cursor wrapping at TCP_STACK_MAX_SESSIONS,
# CUMULATIVE SINCE PROGRAMMING -- are no longer the limit they were. A run that used to need ~2500
# connections and wedge partway through now needs one.
#
# What DOES scale with the request count is the range split. HTTPReadConfig::read cuts each column
# chunk into GETs of at most OASIS_HTTP_CHUNK_BYTES (default 8 KiB) so that
# max_inflight() x chunk_bytes() stays under the ~41.5 KB at which the TOE's shared receive fifo
# starts dropping segments. That multiplies the GET count by chunk_size/8 KiB, which is fine -- they
# are pipelined on the open connection with no handshake -- but it is the number to look at if the
# per-request overhead ever shows up in these timings.
# ---------------------------------------------------------------------------------------------
[ "$WORKLOAD" = all ] && WORKLOADS="latency q6 q1 wide" || WORKLOADS="$WORKLOAD"
total_cols=0
for w in $WORKLOADS; do
    total_cols=$((total_cols + $(q_cols "$w")))
done
CHUNKS=$((total_cols * ${RG:-0} * REPEAT))
echo " estimated column chunks for this run: $CHUNKS (all on one TCP connection)"
echo " range split: OASIS_HTTP_CHUNK_BYTES=$OASIS_HTTP_CHUNK_BYTES bytes per GET"
echo " (set OASIS_HTTP_CHUNK_BYTES=0 to send one GET per column chunk and measure what the split costs)"
echo "=============================================================================="

for w in $WORKLOADS; do
    cols=$(q_cols "$w")
    echo
    echo "##############################################################################"
    echo "# $w -- $cols hardware column(s) per row group => $((cols * ${RG:-0})) column chunks"
    echo "##############################################################################"
    for i in $(seq 1 "$REPEAT"); do
        run_one "$w" oasis "$(q_sql "$w")" "$((cols * ${RG:-0}))"
    done
    echo "--- $w CPU baseline (same object over a host socket, DuckDB parquet reader)"
    run_one "$w" cpu "$(q_cpu_sql "$w")" "$((cols * ${RG:-0}))"
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

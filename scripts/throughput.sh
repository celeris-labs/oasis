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
# reading is indistinguishable from a real one. The harness keeps BOTH reads and compares them per
# decoder: a decoder whose counters did not change did no work in this run and is left out of the
# run summary.
#
# TWO RATES, and only one of them is throughput:
#
#   in_mbytes_s  (per decoder)  bytes over the profiler's counted window: the decoder's INTAKE while
#                               it had streams. On tpch-1 that window is ~3% of the query, so a 3x
#                               on this number was 5.6% on the query. It is not throughput.
#   wall_MB/s    (run summary)  bytes of every active decoder over the query's wall clock (`.timer`
#                               real). This one is throughput.
#
# COMPLETENESS. hs summed over the active decoders is the same for every complete run of a workload,
# whatever the lane count. A run that died part-way moves fewer beats AND loses its idle tail, which
# INFLATES in_mbytes_s (a truncated run once reported 1036 MB/s, the best single-lane number ever
# seen). So each workload ends with a verdict marking every repeat OK, INCOMPLETE (hs short of the
# section's value), FAILED (the query printed an error) or NO WORK. The section's value is
# EXPECT_HS_<workload> if exported, else the measured value for tpch-1 lineitem (known_hs), else the
# largest hs among the repeats that did not fail -- which cannot see a run where EVERY repeat died
# early. Never quote a rate from a run that is not OK.
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
# Extra SET statements, so the scheduler knobs are reachable without editing this file.
# The two that matter for isolation:
#   OASIS_EXTRA_SETUP="SET oasis_scheduler_num_streams=1;"   -- one lane only. THE isolation switch:
#       OASIS_HTTP_LANE_DEPTH caps pipelining DEPTH, not the lane count, so on a 2-lane bitstream
#       depth 1 still runs both lanes and still contends for the shared receive path.
#   OASIS_EXTRA_SETUP="SET oasis_scheduler_queue_depth=1;"   -- one host pipeline slot per stream.
SETUP="SET http_server='$SERVER'; SET http_port=$PORT; SET enable_progress_bar=false; ${OASIS_EXTRA_SETUP:-}"

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
    local out_file; out_file=$(mktemp)
    {
        echo "$SETUP"
        [ "$mode" = cpu ] && echo "SET httpfpga_cpu_fallback=true;"
        # Arm the profiler window, then time the query, then read the window back. The arming read
        # is kept (as PROFILE_BEFORE rows) so the summary can tell which decoders this run touched.
        if [ "$mode" = oasis ]; then
            echo ".mode csv"
            echo ".headers off"
            echo "SELECT 'PROFILE_BEFORE', decoder, in_handshakes_cycles, in_starved_cycles,
                         in_stalled_cycles, in_idle_cycles FROM oasis_stream_profile();"
            echo ".headers on"
            echo ".mode duckbox"
        else
            echo "SELECT count(*) FROM oasis_stream_profile();"
        fi
        echo ".timer on"
        echo "$sql"
        echo ".timer off"
        if [ "$mode" = oasis ]; then
            # The same read in machine form, taken before the human-readable one below so both
            # describe one window. (A read only stops and holds the window; it does not reset it.)
            echo ".mode csv"
            echo ".headers off"
            echo "SELECT 'PROFILE_AFTER', decoder, in_handshakes_cycles, in_starved_cycles,
                         in_stalled_cycles, in_idle_cycles FROM oasis_stream_profile();"
            echo ".headers on"
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
    "$DUCKDB" < "$sql_file" 2>&1 | tee "$out_file"
    rm -f "$sql_file"
    [ "$mode" = oasis ] && summarize_run "$name" "$out_file"
    rm -f "$out_file"
}

# summarize_run <workload> <captured duckdb output>
#
# One line per oasis run, then remembered for the workload's verdict. The PROFILE_* rows stay in
# the log; they are CSV, so they match none of the patterns sumrate (env4dec.sh) parses --
# `decoder =`, `hs =`, `in_mbytes_s` -- and none of this function's own lines do either.
RUN_HS=() RUN_WALL=() RUN_INTAKE=() RUN_ACTIVE=() RUN_ERR=()
summarize_run() {
    local line
    line=$(awk -F, '
        /^Run Time \(s\): real / { real = $0; sub(/^Run Time \(s\): real /, "", real); sub(/ .*/, "", real) }
        /Error:/                  { err = 1 }
        $1 == "PROFILE_BEFORE"    { before[$2] = $3 "," $4 "," $5 "," $6 }
        $1 == "PROFILE_AFTER"     { after[$2] = $3 "," $4 "," $5 "," $6; hs[$2] = $3; tot[$2] = $3 + $4 + $5 + $6; n++ }
        END {
            active = 0; hs_sum = 0; intake = 0
            for (d in after) {
                if (after[d] == before[d]) continue
                active++; hs_sum += hs[d]
                if (tot[d] > 0) intake += hs[d] * 64 / (tot[d] * 4e-9) / 1e6
            }
            wall = (real > 0) ? hs_sum * 64 / 1e6 / real : 0
            printf "%d %.1f %.1f %d/%d %d %s", hs_sum, wall, intake, active, n, err ? 1 : 0, real
        }' "$2")
    local hs_sum wall intake active err real
    read -r hs_sum wall intake active err real <<< "$line"
    RUN_HS+=("$hs_sum") RUN_WALL+=("$wall") RUN_INTAKE+=("$intake") RUN_ACTIVE+=("$active") RUN_ERR+=("$err")
    printf '>>> run summary: wall_MB/s=%s over %ss (%.2f MiB) | decoder intake, in-window, NOT throughput: %s MB/s | active decoders %s | hs_total=%s%s\n' \
        "$wall" "${real:-?}" "$(awk -v h="$hs_sum" 'BEGIN { printf "%.2f", h * 64 / 1048576 }')" \
        "$intake" "$active" "$hs_sum" "$([ "$err" = 1 ] && echo ' | QUERY FAILED')"
}

# Complete hs totals, taken from every build-118/119 log that ran these workloads (66-75 runs
# each). The same for any lane count and any OASIS_HTTP_CHUNK_BYTES: hs counts bytes into the
# decoders, not requests. q1 and q6 read the same four columns.
known_hs() {
    case "$FILE:$1" in
        /throughput/tpch-1/lineitem.parquet:latency) echo 146159 ;;
        /throughput/tpch-1/lineitem.parquet:q6)      echo 751496 ;;
        /throughput/tpch-1/lineitem.parquet:q1)      echo 751496 ;;
        /throughput/tpch-1/lineitem.parquet:wide)    echo 1455162 ;;
    esac
}

# verdict <workload> -- mark every repeat of the workload just run, then forget them.
# 0.1% tolerance either way: one log in ~75 read a single beat over the complete total.
verdict() {
    local w=$1 i expect=0 var="EXPECT_HS_$1" tag src
    if [ -n "${!var:-}" ]; then
        expect=${!var}; src="from $var"
    elif [ -n "$(known_hs "$w")" ]; then
        expect=$(known_hs "$w"); src="measured complete value for $FILE"
    else
        src="largest of the repeats that did not fail"
        for i in "${!RUN_HS[@]}"; do
            [ "${RUN_ERR[$i]}" = 1 ] && continue
            [ "${RUN_HS[$i]}" -gt "$expect" ] && expect=${RUN_HS[$i]}
        done
    fi
    echo "=== $w verdict: expected hs_total=$expect ($src) ==="
    for i in "${!RUN_HS[@]}"; do
        local ratio
        ratio=$(awk -v a="${RUN_HS[$i]}" -v b="$expect" 'BEGIN { printf "%.1f", b ? 100 * a / b : 0 }')
        if [ "${RUN_ERR[$i]}" = 1 ]; then tag="FAILED (query printed an error) -- rates are meaningless"
        elif [ "${RUN_HS[$i]}" = 0 ]; then tag="NO WORK (no decoder counter changed) -- dead run, not a measurement"
        elif [ "$expect" = 0 ] || [ $((RUN_HS[i] * 1000)) -lt $((expect * 999)) ]; then
            tag="INCOMPLETE (${ratio}% of expected) -- do not quote"
        elif [ $((RUN_HS[i] * 1000)) -gt $((expect * 1001)) ]; then
            tag="MORE than expected (${ratio}%) -- wrong EXPECT_HS_$w, or a different workload"
        else tag="OK"
        fi
        printf '  run %d: hs_total=%-9s wall_MB/s=%-8s intake_MB/s=%-8s decoders=%-5s %s\n' \
            "$((i + 1))" "${RUN_HS[$i]}" "${RUN_WALL[$i]}" "${RUN_INTAKE[$i]}" "${RUN_ACTIVE[$i]}" "$tag"
    done
    RUN_HS=() RUN_WALL=() RUN_INTAKE=() RUN_ACTIVE=() RUN_ERR=()
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
    verdict "$w"
    echo "--- $w CPU baseline (same object over a host socket, DuckDB parquet reader)"
    run_one "$w" cpu "$(q_cpu_sql "$w")" "$((cols * ${RG:-0}))"
done

cat <<'EOF'

------------------------------------------------------------------------------
Reading the counters (all cycles are 4 ns at the 250 MHz user clock):

  bytes into decoder   = hs * 64
  per-decoder MB/s     = bytes / FPGA-side window -- decoder intake, NOT throughput
  wall_MB/s            = bytes of all active decoders / query wall clock -- throughput
  FPGA-side wall time  = (hs + starved + stalled + idle) * 4 ns
  duty cycle           = hs / (hs + starved + stalled + idle)
  per-request dead time = idle * 4 ns / (GETs - 1)

If idle dominates you are latency-bound on request setup (TCP connect, MinIO
time-to-first-byte, close, host round trip) and no amount of decoder speed helps.
If starved dominates, the body itself arrives too slowly. If stalled dominates,
the decoder is genuinely the bottleneck -- which so far it never is.
------------------------------------------------------------------------------
EOF

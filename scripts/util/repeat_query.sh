#!/usr/bin/env bash
#
# Run the SAME query N times in a row and report which iteration fails.
#
# Every query passes on its own; runs of several do not. That splits into two very different
# causes and this tells them apart:
#
#   fails on the Nth repeat of one query   -> purely cumulative. Nothing about query content
#                                             matters; state left on the FPGA by one duckdb process
#                                             breaks the next. The connection is held across
#                                             processes and there is no reset register.
#   never fails however many repeats       -> it takes VARIETY, not count. Something about
#                                             switching files, column counts or chunk sizes between
#                                             queries is what does it.
#
# Each iteration is a separate duckdb process, exactly as tpch_demo runs them.
#
#   ./scripts/util/repeat_query.sh              # 8 x sum(l_quantity) on lineitem
#   N=12 TABLE=orders COL=o_orderkey ./scripts/util/repeat_query.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DUCKDB=${DUCKDB:-$ROOT/extension/build/release/duckdb}
SERVER=${OASIS_SERVER:-10.253.74.74}
PORT=${OASIS_PORT:-9000}
SCALE=${SCALE:-30}
N=${N:-8}
TABLE=${TABLE:-lineitem}
COL=${COL:-l_quantity}
GRPS=${GROUPS_IN_FLIGHT:-4}   # NOT 'GROUPS' -- bash owns that name and silently keeps your gid

LOG=${LOG:-$ROOT/.repeat-logs}; rm -rf "$LOG"; mkdir -p "$LOG"

export NO_PROXY="${SERVER},127.0.0.1,localhost"; export no_proxy="$NO_PROXY"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY 2>/dev/null || true

echo "$N x  sum($COL) from $TABLE  (scale $SCALE, groups=$GRPS, chunk=${OASIS_HTTP_CHUNK_BYTES:-default})"
echo "each iteration is its own duckdb process, as tpch_demo runs them"
echo "----------------------------------------------------------------------"
first_fail=0
for i in $(seq "$N"); do
    t0=$(date +%s.%N)
    OASIS_HTTP_DEBUG=1 timeout "${TIMEOUT:-60}" "$DUCKDB" -csv -c "
        SET http_server='$SERVER'; SET http_port=$PORT; SET threads=1;
        SET oasis_scan_groups_in_flight=$GRPS;
        SELECT sum($COL) AS s, count(*) AS n FROM read_oasis('httpfpga:///throughput/tpch-$SCALE/$TABLE.parquet');" \
        > "$LOG/repeat-$i.txt" 2>&1
    rc=$?
    t1=$(date +%s.%N)
    secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
    val=$(grep -oE '^[0-9]+\.?[0-9]*,[0-9]+$' "$LOG/repeat-$i.txt" | head -1)
    gets=$(grep -c 'GET /' "$LOG/repeat-$i.txt")
    if [ "$i" = 1 ]; then ref=$val; fi
    if [ "$rc" = 0 ] && [ -n "$val" ] && [ "$val" = "$ref" ]; then
        printf '  %2d  OK       %8ss   sum,rows=%-28s gets=%s\n' "$i" "$secs" "$val" "$gets"
    elif [ "$rc" = 0 ]; then
        printf '  %2d  WRONG    %8ss   sum,rows=%-28s gets=%s  (want %s)\n' "$i" "$secs" "${val:-<none>}" "$gets" "$ref"
        [ "$first_fail" = 0 ] && first_fail=$i
        break
    else
        printf '  %2d  FAIL     %8ss   rc=%s  gets=%s\n' "$i" "$secs" "$rc" "$gets"
        grep -oE 'inflight=[0-9]+/[0-9]+[^|]*\| stalled:[^\\]*' "$LOG/repeat-$i.txt" | tail -1 | sed 's/^/        /'
        [ "$first_fail" = 0 ] && first_fail=$i
        break
    fi
done
echo "----------------------------------------------------------------------"
if [ "$first_fail" = 0 ]; then
    echo "all $N passed -- repeating ONE query does not break it, so variety matters, not count"
else
    echo "first failure on iteration $first_fail -- purely cumulative, query content is irrelevant"
    echo "state kept: $LOG/repeat-$first_fail.txt  (readable from the build server too)"
fi

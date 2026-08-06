#!/usr/bin/env bash
#
# Chunk-size / depth sweep. Answers one question: is the per-request cost FIXED or SIZE-DEPENDENT?
#
# WHY THE SHAPE IS THE ANSWER
#   A fixed per-request cost -- a spurious retransmit timeout, or MinIO's time-to-first-byte -- adds
#   the same constant to every request no matter how big it is. Per-request time is then LINEAR in
#   chunk size with a POSITIVE intercept, and the marginal MB/s (the slope) stays flat as chunks grow.
#
#   A size-dependent failure -- the receive FIFO overrunning, go-back-N recovery -- costs more the
#   bigger the response is. Per-request time is then SUPERLINEAR and the marginal MB/s FALLS as
#   chunks grow.
#
#   Two points cannot tell these apart. Five can, and it needs no packet capture and no privileges.
#
# The workload is deliberately the simplest one: a single INT64 column, so column chunks are uniform
# and the GET count is just ceil(bytes / chunk).
#
#   ./scripts/sweep.sh                            # depth 4, chunks 4K..128K
#   ./scripts/sweep.sh --depths 1,2,4             # also vary depth
#   ./scripts/sweep.sh --repeat 3                 # median of 3 per cell
#
# Env: DUCKDB, OASIS_SERVER, OASIS_PORT.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUCKDB=${DUCKDB:-$ROOT/extension/build/release/duckdb}
SERVER=${OASIS_SERVER:-10.253.74.74}
PORT=${OASIS_PORT:-9000}
FILE=${FILE:-/throughput/tpch-1/lineitem.parquet}
DEPTHS=4
CHUNKS="4096,8192,16384,32768,65536,131072"
REPEAT=2
TIMEOUT=300

while [ $# -gt 0 ]; do
    case "$1" in
        --depths)  DEPTHS="$2"; shift ;;
        --chunks)  CHUNKS="$2"; shift ;;
        --repeat)  REPEAT="$2"; shift ;;
        --file)    FILE="$2"; shift ;;
        --timeout) TIMEOUT="$2"; shift ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

[ -x "$DUCKDB" ] || { echo "no duckdb shell at $DUCKDB" >&2; exit 2; }

export NO_PROXY="${SERVER},127.0.0.1,localhost,${NO_PROXY:-}"
export no_proxy="$NO_PROXY"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy 2>/dev/null || true

URL="httpfpga://$FILE"
SETUP="SET http_server='$SERVER'; SET http_port=$PORT; SET enable_progress_bar=false;"
QUERY="SELECT sum(l_orderkey) FROM read_oasis('$URL');"

# Wall time of one run, in seconds, on stdout. Empty string if it failed or timed out.
timed_run() {
    local sql=$1 t0 t1 rc
    t0=$(date +%s.%N)
    timeout "${TIMEOUT}s" "$DUCKDB" -noheader -list -c "$sql" >/dev/null 2>&1; rc=$?
    t1=$(date +%s.%N)
    [ "$rc" = 0 ] && awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.4f", b-a}'
}

# Median of REPEAT runs, discarding failures.
median_run() {
    local sql=$1 i v; local -a vals=()
    for i in $(seq 1 "$REPEAT"); do
        v=$(timed_run "$sql")
        [ -n "$v" ] && vals+=("$v")
    done
    [ "${#vals[@]}" -eq 0 ] && { echo ""; return; }
    printf '%s\n' "${vals[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'
}

echo "=============================================================================="
echo " oasis chunk sweep   file=$FILE  server=$SERVER:$PORT  repeat=$REPEAT (median)"
echo "=============================================================================="

# NO baseline subtraction. An earlier version measured the CPU-fallback runtime and subtracted it as
# "host overhead" -- but that is a different code path which also does all the fetching, so it came
# out LARGER than most FPGA runs and every derived number underflowed to a clamp.
#
# None is needed. The query is identical in every row, so the bytes are constant and only the GET
# count changes. Fitting wall against GETs puts every constant -- DuckDB planning, the metadata
# HEADs, the aggregation -- into the intercept, and the slope between adjacent rows is the marginal
# cost of one GET, free of all of it.

# Bytes the decoder will see, from the profiler, so the GET count is exact rather than assumed.
BYTES=$("$DUCKDB" -noheader -list -c "$SETUP
    SELECT count(*) FROM oasis_stream_profile();
    $QUERY
    SELECT sum(in_handshakes_cycles) * 64 FROM oasis_stream_profile();" 2>/dev/null | tail -1)
case "$BYTES" in ''|*[!0-9]*) echo "could not read decoder byte count; aborting" >&2; exit 1 ;; esac
echo "decoder bytes per run: $BYTES ($(awk -v b="$BYTES" 'BEGIN{printf "%.2f", b/1048576}') MiB)"
echo

printf '%6s %9s %8s %10s %14s  %s\n' "depth" "chunk" "GETs" "wall_s" "us/GET (marg)" "verdict"
echo "------------------------------------------------------------------------------"

for d in ${DEPTHS//,/ }; do
    PREV_G=""; PREV_W=""
    for c in ${CHUNKS//,/ }; do
        gets=$(awk -v b="$BYTES" -v c="$c" 'BEGIN{printf "%d", (b+c-1)/c}')
        wall=$(OASIS_HTTP_MAX_INFLIGHT="$d" OASIS_HTTP_CHUNK_BYTES="$c" \
               median_run "$SETUP $QUERY")
        if [ -z "$wall" ]; then
            printf '%6s %9s %8s %10s %14s  %s\n' "$d" "$c" "$gets" "FAIL" "-" "timed out"
            continue
        fi
        marg="-"; verdict=""
        if [ -n "$PREV_G" ]; then
            # Halving the chunk count should REDUCE wall time if the only cost is per-GET.
            # Wall time going UP while GETs go DOWN can only mean the larger response is itself
            # more expensive -- the signature of a response that no longer fits the receive FIFO.
            read -r marg verdict <<EOF
$(awk -v g1="$PREV_G" -v w1="$PREV_W" -v g2="$gets" -v w2="$wall" 'BEGIN{
    dg = g1 - g2; dw = w1 - w2;
    if (dg <= 0) { print "- -"; exit }
    if (dw <= 0) { printf "%s SIZE-PENALTY(+%.1fms/GET)", "n/a", (-dw)*1000/g2; exit }
    printf "%.0f fixed-per-GET", dw*1e6/dg }')
EOF
        fi
        printf '%6s %9s %8s %10s %14s  %s\n' "$d" "$c" "$gets" "$wall" "$marg" "$verdict"
        PREV_G=$gets; PREV_W=$wall
    done
    echo
done

cat <<'EOF'
------------------------------------------------------------------------------
Reading the us_per_GET column:

  LINEAR in chunk size, positive intercept, marginal MB/s roughly CONSTANT
      -> a fixed cost per request. Spurious retransmit timeout, or MinIO's
         time-to-first-byte. Bigger requests are strictly better; the fix is
         fewer, larger GETs (and more depth).

  SUPERLINEAR, marginal MB/s FALLING as chunks grow
      -> the cost grows with response size. Receive FIFO overrun and go-back-N
         recovery. Bigger requests make it worse; the fix is in the TOE receive
         path, not in host-side tuning.

Fit the intercept by hand from the two smallest points:
    slope = (us2 - us1) / (chunk2 - chunk1)
    intercept = us1 - slope * chunk1      <- microseconds of fixed cost per GET
An intercept near zero with a falling marginal rate is the second case.
EOF

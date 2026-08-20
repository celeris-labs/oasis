#!/usr/bin/env bash
#
# Does a SECOND decoder buy anything?
#
# Run the same query twice on the SAME 2-decoder bitstream, once with one decode lane active and
# once with both, and print wall time plus how many bytes each lane actually decoded.
#
# Why not compare build-105 (1 decoder) against build-107 (2)? Two bitstreams means reprogramming
# between arms, and MinIO's page cache drifts over a day -- the last comparison that ignored that
# produced a 7.31 s vs 191.34 s spread on one query. One bitstream, one knob
# (oasis_scheduler_num_streams), arms interleaved 1,2,1,2, is the only version of this that is
# actually an A/B.
#
# WHAT TO EXPECT, stated up front so the result is falsifiable rather than reassuring:
#
#   The decoder is NOT believed to be the bottleneck. One TCP connection to MinIO tops out at
#   0.463 GB/s and the FPGA already gets 0.33 GB/s of it -- 72%. In-chunk the decoder ingests
#   ~1.0 GB/s and sits idle 68% of the wall clock. So the honest prediction is:
#
#     lane bytes    split roughly evenly across the two decoders   -> the demux works
#     wall time     UNCHANGED, within noise                        -> the decoder was never the limit
#
#   A flat wall time here is the POINT, not a failure. It is the control that turns "the network is
#   the bottleneck" from an inference into a measurement, and it is what makes the case for spending
#   the next weeks on multi-session TCP rather than on more decoders.
#
#   If wall time DOES drop materially, the network model is wrong and needs revisiting before
#   anything else is built on it.
#
# OASIS_HTTP_BATCH=0 is not optional. A row-group batch carries ONE lane for all its chunks, and
# those chunks may belong to flows the scheduler placed on different streams; with more than one
# decoder that would route a column's bytes into a decoder configured for another column. The
# software refuses rather than corrupt. Both arms use it, so batching is not a variable here.
#
#   ./scripts/util/decoder_ab.sh                 # q01 at scale 30, 2 reps per arm
#   QUERY=q18 REPS=3 ./scripts/util/decoder_ab.sh
#   SCALE=3 ./scripts/util/decoder_ab.sh         # quick shakedown before the real one
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DUCKDB=${DUCKDB:-$ROOT/extension/build/release/duckdb}
SERVER=${OASIS_SERVER:-10.253.74.74}
PORT=${OASIS_PORT:-9000}
SCALE=${SCALE:-30}
QUERY=${QUERY:-q01}
REPS=${REPS:-2}
THREADS=${THREADS:-1}
TIMEOUT=${TIMEOUT:-900}

SQL_FILE="$ROOT/scripts/tpch/${QUERY}.sql"
[ -r "$SQL_FILE" ] || { echo "no such query: $SQL_FILE" >&2; exit 2; }
[ -x "$DUCKDB" ]   || { echo "no duckdb shell at $DUCKDB" >&2; exit 2; }

# One request per column chunk. See the note above -- this is a correctness requirement with more
# than one decoder, not a tuning choice.
export OASIS_HTTP_BATCH=0
export NO_PROXY="${SERVER},127.0.0.1,localhost"; export no_proxy="$NO_PROXY"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy 2>/dev/null || true

PREFIX="/throughput/tpch-${SCALE}"
TABLES="lineitem orders customer part partsupp supplier nation region"
LOG=${LOG:-$ROOT/.decoder-ab}; rm -rf "$LOG"; mkdir -p "$LOG"

views() { for t in $TABLES; do
    echo "CREATE OR REPLACE VIEW $t AS SELECT * FROM read_oasis('httpfpga://${PREFIX}/${t}.parquet');"
done; }

# How many decode lanes does this bitstream actually have? oasis_stream_profile() emits one row per
# decoder, so its row count IS num_decoders -- read from a hardware register, not compiled in.
# Asking first turns "SET oasis_scheduler_num_streams=2 failed" into a sentence that says which
# bitstream is loaded.
LANES=$({ echo "SET http_server='$SERVER'; SET http_port=$PORT;"
          echo "SELECT count(*) FROM oasis_stream_profile();"; } \
        | timeout 120s "$DUCKDB" -noheader -list 2>"$LOG/probe.err" | tail -1)
case "$LANES" in ''|*[!0-9]*)
    echo "could not read the decoder count from the board. $LOG/probe.err:" >&2
    sed 's/^/    /' "$LOG/probe.err" >&2; exit 2 ;;
esac
echo "bitstream reports $LANES decode lane(s)"
if [ "$LANES" -lt 2 ]; then
    echo
    echo "This is a ONE-decoder bitstream, so there is no A/B to run: the two arms would be the"
    echo "same configuration. Program a bitstream built with --decoders 2 and rerun."
    exit 1
fi

echo "$QUERY at scale $SCALE, threads=$THREADS, $REPS rep(s) per arm, arms interleaved"
echo "----------------------------------------------------------------------------------"
printf '  %-4s %-6s %9s   %-28s\n' rep lanes secs "MiB decoded per lane"

run_arm() {   # $1 = active lanes, $2 = rep
    local lanes=$1 rep=$2 f out t0 t1 secs per
    f=$(mktemp)
    { echo "SET http_server='$SERVER'; SET http_port=$PORT; SET enable_progress_bar=false;"
      echo "SET threads=$THREADS;"
      echo "SET oasis_scheduler_num_streams=$lanes;"
      views
      # Read once to close the previous profiling window; the counters restart on the next chunk.
      echo "SELECT count(*) FROM oasis_stream_profile();"
      cat "$SQL_FILE"
      # in_handshakes_cycles counts BEATS accepted, one per cycle, 64 bytes each -- so this is the
      # bytes each lane really decoded. It is the whole point of the run: it is what distinguishes
      # "the second lane did nothing" from "both lanes worked and it did not help".
      echo ".mode list"
      echo "SELECT 'LANE', decoder, round(in_handshakes_cycles * 64 / 1048576.0, 2)
              FROM oasis_stream_profile() ORDER BY decoder;"
    } > "$f"
    out="$LOG/${QUERY}-lanes$lanes-rep$rep.txt"
    t0=$(date +%s.%N)
    timeout "${TIMEOUT}s" "$DUCKDB" -noheader -list < "$f" > "$out" 2>&1; local rc=$?
    t1=$(date +%s.%N)
    rm -f "$f"
    secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
    per=$(grep '^LANE|' "$out" | awk -F'|' '{printf "%s%s:%s", (NR>1?"  ":""), $2, $3}')
    if [ "$rc" != 0 ]; then
        printf '  %-4s %-6s %9s   FAILED rc=%s -- see %s\n' "$rep" "$lanes" "$secs" "$rc" "$out"
        grep -m3 -iE 'error|exception|refus' "$out" | sed 's/^/        /'
        return 1
    fi
    printf '  %-4s %-6s %9s   %s\n' "$rep" "$lanes" "$secs" "${per:-<no profile rows>}"
    echo "$lanes $secs" >> "$LOG/times.txt"
}

for rep in $(seq "$REPS"); do
    for lanes in 1 2; do run_arm "$lanes" "$rep" || exit 1; done
done

echo "----------------------------------------------------------------------------------"
awk '{ n[$1]++; s[$1]+=$2 } END {
        for (l in n) printf "  %s lane(s): mean %.2f s over %d run(s)\n", l, s[l]/n[l], n[l]
        if (n[1] && n[2]) {
            r = (s[1]/n[1]) / (s[2]/n[2])
            printf "\n  two lanes are %.2fx the throughput of one\n", r
            if (r < 1.05)
                print  "\n  FLAT, as predicted: the decoder was not the limit. The bottleneck is the\n" \
                       "  single TCP connection (0.46 GB/s), and more decoders cannot reach past it.\n" \
                       "  Check the per-lane MiB above -- if both lanes decoded real bytes, the demux\n" \
                       "  works and this is a clean negative result, not a broken test."
            else
                print  "\n  NOT flat. The decoder was contributing to the limit after all, which\n" \
                       "  contradicts the single-connection model. Re-measure before building on it."
        }
      }' "$LOG/times.txt"
echo
echo "  raw output: $LOG/"

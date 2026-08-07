#!/usr/bin/env bash
#
# TPC-H conformance demo: all 22 queries, FPGA-decoded vs CPU, on the same objects.
#
# Each table becomes a VIEW over read_oasis('httpfpga://...'), so the official TPC-H query text in
# scripts/tpch/qNN.sql runs UNMODIFIED. Every query is then run a second time with the CPU fallback
# and the two answers are compared cell for cell. Nothing has a baked-in expected value.
#
# WHAT THIS DOES AND DOES NOT PROVE
#   It proves: the hardware decoder returns bit-identical results to DuckDB's own Parquet reader
#   across the full TPC-H workload, including joins, aggregation, sorting and filters.
#   It does not prove anything about speed -- see scripts/throughput.sh for that.
#
# WHERE THE HARDWARE ACTUALLY RUNS. read_oasis decodes FIXED-WIDTH columns on the FPGA. BYTE_ARRAY
# (string) columns have no hardware path and are decoded on the host from bytes fetched over the
# socket. That is the supported arrangement, not a failure: a query like Q13, which touches almost
# nothing but strings, will pass with the decoder nearly idle. The `hw_MiB` column reports the bytes
# that actually crossed the decoder, so a demo can show which queries exercise it and which do not.
#
#   ./scripts/tpch_demo.sh                    # all 22 on tpch-1
#   ./scripts/tpch_demo.sh --scale 3          # tpch-3 (note: lineitem is 657 MB)
#   ./scripts/tpch_demo.sh --only 1,6,14      # a subset
#   ./scripts/tpch_demo.sh --timeout 300
#
# Env: DUCKDB, OASIS_SERVER, OASIS_PORT, OASIS_HTTP_MAX_INFLIGHT, OASIS_HTTP_CHUNK_BYTES.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUCKDB=${DUCKDB:-$ROOT/extension/build/release/duckdb}
# The bitstream the reprogram hint below points at. Resolved to the newest build that actually
# produced one, because hardcoding a build number here sends you to a stale bitstream and costs
# a full board cycle to notice.
BITSTREAM=$(ls -dt "$ROOT"/hardware/build-*/bitstreams/cyt_top.bit 2>/dev/null | head -1)
SERVER=${OASIS_SERVER:-10.253.74.74}
PORT=${OASIS_PORT:-9000}
SCALE=1
TIMEOUT=300
ONLY=""

while [ $# -gt 0 ]; do
    case "$1" in
        --scale)   SCALE="$2"; shift ;;
        --only)    ONLY="$2"; shift ;;
        --timeout) TIMEOUT="$2"; shift ;;
        --server)  SERVER="$2"; shift ;;
        --port)    PORT="$2"; shift ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

[ -x "$DUCKDB" ] || { echo "no duckdb shell at $DUCKDB" >&2; exit 2; }
[ -d "$ROOT/scripts/tpch" ] || { echo "missing scripts/tpch/*.sql" >&2; exit 2; }

export NO_PROXY="${SERVER},127.0.0.1,localhost,${NO_PROXY:-}"
export no_proxy="$NO_PROXY"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy 2>/dev/null || true

PREFIX="/throughput/tpch-${SCALE}"
TABLES="lineitem orders customer part partsupp supplier nation region"

# Views over the FPGA reader. The path budget is 64 characters -- /throughput/tpch-30/lineitem.parquet
# is 36, so every scale factor fits.
views() {
    local reader=$1 t
    for t in $TABLES; do
        echo "CREATE OR REPLACE VIEW $t AS SELECT * FROM ${reader}('httpfpga://${PREFIX}/${t}.parquet');"
    done
}

SETUP="SET http_server='$SERVER'; SET http_port=$PORT; SET enable_progress_bar=false;"

# The FPGA script has to arm the profiler before the query and read it back after, and both of those
# print rows of their own. Rather than trying to filter them out by shape -- which silently broke
# every comparison by exactly one row -- bracket the real query with sentinels and take only what
# lies between. Missing sentinels also give us a reliable error signal, since the DuckDB shell
# reading a script does not always exit non-zero on a failed statement.
BEGIN_MARK='<<<OASIS-BEGIN>>>'
END_MARK='<<<OASIS-END>>>'
extract_rows() { awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0==b{f=1;next} $0==e{f=0} f' | sed '/^$/d'; }

# Result sets go through files, not shell variables. At scale 30 a single query can return several
# hundred thousand rows and the old string comparison would have held two copies of it in memory.
FPGA_RAW=$(mktemp); FPGA_ROWS=$(mktemp); CPU_RAW=$(mktemp); CPU_ROWS=$(mktemp)
trap 'rm -f "$FPGA_RAW" "$FPGA_ROWS" "$CPU_RAW" "$CPU_ROWS"' EXIT

echo "=============================================================================="
echo " TPC-H conformance   scale=$SCALE  server=$SERVER:$PORT"
echo " inflight=${OASIS_HTTP_MAX_INFLIGHT:-default}  chunk=${OASIS_HTTP_CHUNK_BYTES:-default}"
echo " read_oasis() decodes fixed-width columns on the FPGA; strings are decoded on the host."
echo "=============================================================================="
printf '%-5s %-8s %9s %9s %10s  %s\n' "query" "result" "fpga_s" "cpu_s" "hw_MiB" "note"

PASS=0; FAIL=0; SKIP=0; CONSEC_TIMEOUT=0
FAILED=()

for f in "$ROOT"/scripts/tpch/q*.sql; do
    n=$(basename "$f" .sql); n=${n#q}; n=$((10#$n))
    if [ -n "$ONLY" ] && ! printf ',%s,' "$ONLY" | grep -q ",$n,"; then continue; fi

    sql_body=$(cat "$f")

    # --- FPGA -------------------------------------------------------------------------------
    fpga_file=$(mktemp)
    { echo "$SETUP"; views read_oasis
      echo "SELECT count(*) FROM oasis_stream_profile();"   # arm the profiler window
      echo "SELECT '$BEGIN_MARK';"
      echo "$sql_body"
      echo "SELECT '$END_MARK';"
      echo ".mode line"
      echo "SELECT round(sum(in_handshakes_cycles) * 64 / 1048576.0, 2) AS hw_mib FROM oasis_stream_profile();"
    } > "$fpga_file"
    t0=$(date +%s.%N)
    timeout "${TIMEOUT}s" "$DUCKDB" -noheader -list < "$fpga_file" > "$FPGA_RAW" 2>&1; fpga_rc=$?
    t1=$(date +%s.%N)
    rm -f "$fpga_file"
    fpga_s=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
    # the profiler line is the last "hw_mib = N" the shell printed
    hw_mib=$(grep -oE 'hw_mib *= *[0-9.]+' "$FPGA_RAW" | tail -1 | grep -oE '[0-9.]+$')
    extract_rows < "$FPGA_RAW" > "$FPGA_ROWS"
    grep -qF "$END_MARK" "$FPGA_RAW" || fpga_rc=1

    # --- CPU --------------------------------------------------------------------------------
    cpu_file=$(mktemp)
    { echo "$SETUP"; echo "SET httpfpga_cpu_fallback=true;"; views read_parquet
      echo "SELECT '$BEGIN_MARK';"
      echo "$sql_body"
      echo "SELECT '$END_MARK';"
    } > "$cpu_file"
    t0=$(date +%s.%N)
    timeout "${TIMEOUT}s" "$DUCKDB" -noheader -list < "$cpu_file" > "$CPU_RAW" 2>&1; cpu_rc=$?
    t1=$(date +%s.%N)
    rm -f "$cpu_file"
    cpu_s=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
    extract_rows < "$CPU_RAW" > "$CPU_ROWS"
    grep -qF "$END_MARK" "$CPU_RAW" || cpu_rc=1

    # --- verdict ----------------------------------------------------------------------------
    if [ "$fpga_rc" = 124 ]; then
        printf '%-5s %-8s %9s %9s %10s  %s\n' "q$n" "TIMEOUT" "$fpga_s" "-" "-" \
            "no result in ${TIMEOUT}s -- likely a wedge"
        FAIL=$((FAIL+1)); FAILED+=("q$n")
        # Once the board wedges every later query times out too, so carrying on costs
        # (remaining queries x TIMEOUT) of nothing. At scale 30 that is hours.
        CONSEC_TIMEOUT=$((CONSEC_TIMEOUT+1))
        if [ "$CONSEC_TIMEOUT" -ge 2 ]; then
            echo
            echo "  two consecutive timeouts -- stopping rather than waiting out the rest."
            echo "  Read the handler state BEFORE reprogramming, it is the only time it is visible:"
            echo "    OASIS_HTTP_DEBUG=1 $DUCKDB -c \"SET http_server='$SERVER'; SET http_port=$PORT;\\"
            echo "        SELECT sum(r_regionkey) FROM read_oasis('httpfpga://${PREFIX}/region.parquet');\""
            echo "  stallWord bit 6 = fatal (dirty abort);  coarse_state stuck at 1 = port exhaustion."
            echo
            echo "  then reprogram:"
            echo "    cd $ROOT/parcore/libstf/coyote/util && ./program_hacc_local.sh \\"
            echo "        ${BITSTREAM:-$ROOT/hardware/<newest>/bitstreams/cyt_top.bit} \\"
            echo "        $ROOT/parcore/libstf/coyote/driver/build/coyote_driver.ko"
            break
        fi
        continue
    fi
    CONSEC_TIMEOUT=0
    if [ "$cpu_rc" != 0 ]; then
        printf '%-5s %-8s %9s %9s %10s  %s\n' "q$n" "SKIP" "$fpga_s" "$cpu_s" "${hw_mib:--}" \
            "CPU baseline itself failed: $(tr '\n' ' ' < "$CPU_RAW" | cut -c1-60)"
        SKIP=$((SKIP+1)); continue
    fi
    if [ "$fpga_rc" != 0 ]; then
        printf '%-5s %-8s %9s %9s %10s  %s\n' "q$n" "ERROR" "$fpga_s" "$cpu_s" "${hw_mib:--}" \
            "$(tr '\n' ' ' < "$FPGA_RAW" | cut -c1-70)"
        # Keep the whole thing. Cut to 70 characters, every hardware failure in this design reads
        # "terminate called after throwing an instance of 'st" -- which names neither the exception
        # nor the stage, and those are the only two things worth knowing. The tail is where the
        # handler state and the stall word are.
        cp "$FPGA_RAW" "/tmp/oasis-q$n-error.txt"
        echo "         full error kept: /tmp/oasis-q$n-error.txt"
        sed -n '$p;/rror\|xception\|terminate\|httpfpga\|oasis-http/p' "$FPGA_RAW" \
            | tail -12 | sed 's/^/         | /'
        FAIL=$((FAIL+1)); FAILED+=("q$n"); continue
    fi
    # cmp, not string equality: a scale-30 result can be hundreds of thousands of rows and holding
    # two copies of that in shell variables is both slow and needless.
    if cmp -s "$FPGA_ROWS" "$CPU_ROWS"; then
        note="$(wc -l < "$FPGA_ROWS" | tr -d ' ') rows"
        # A query whose columns are all strings never reaches the decoder. Say so rather than
        # letting a 0.00 look like a failure.
        awk -v m="${hw_mib:-0}" 'BEGIN{exit !(m+0 < 0.01)}' &&
            note="$note, all-CPU query (no fixed-width column fetched)"
        printf '%-5s %-8s %9s %9s %10s  %s\n' "q$n" "PASS" "$fpga_s" "$cpu_s" "${hw_mib:--}" "$note"
        PASS=$((PASS+1))
    else
        nf=$(wc -l < "$FPGA_ROWS" | tr -d ' '); nc=$(wc -l < "$CPU_ROWS" | tr -d ' ')
        if [ "$nf" != "$nc" ]; then
            detail="$nf fpga rows vs $nc cpu rows"
        else
            detail="$nf rows both, first difference: $(diff "$FPGA_ROWS" "$CPU_ROWS" \
                     | sed -n '2,3p' | tr '\n' ' ' | cut -c1-70)"
        fi
        printf '%-5s %-8s %9s %9s %10s  %s\n' "q$n" "MISMATCH" "$fpga_s" "$cpu_s" "${hw_mib:--}" "$detail"
        FAIL=$((FAIL+1)); FAILED+=("q$n")
        cp "$FPGA_ROWS" "/tmp/oasis-q$n-fpga.txt"; cp "$CPU_ROWS" "/tmp/oasis-q$n-cpu.txt"
        echo "         full outputs kept: /tmp/oasis-q$n-{fpga,cpu}.txt"
    fi
done

echo "=============================================================================="
printf ' pass %d   fail %d   skip %d\n' "$PASS" "$FAIL" "$SKIP"
[ "${#FAILED[@]}" -gt 0 ] && printf ' failed: %s\n' "$(printf '%s ' "${FAILED[@]}")"
echo "=============================================================================="
[ "$FAIL" -eq 0 ]

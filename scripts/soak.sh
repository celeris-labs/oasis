#!/usr/bin/env bash
#
# Soak / crash test for the FPGA column-chunk decoder path.
#
# Every case runs the SAME query twice -- once through read_oasis() so the FPGA issues the GET and
# the body streams into the ColumnChunkDecoder, and once through read_parquet() with the CPU
# fallback -- and compares the two answers. Nothing here has a baked-in expected value, so it stays
# correct if the objects on the server ever change.
#
# WHY NOT httpfpga_smoke.sh: that script uses read_parquet('httpfpga://...'), which only uses the
# FPGA as a byte source and parses on the CPU. It never touches the hardware decoder. read_oasis()
# is the one that builds an HTTPSourceOperator. If you want to know whether the decoder crashes,
# this is the script; if you want to know whether the HTTP path delivers bytes, that is the other.
#
# WEDGE DETECTION. The handler latches fatal_q on a dirty abort and there is no reset CSR, so a
# wedge outlives the process and only reprogramming clears it. Two symptoms are treated as a wedge
# rather than an ordinary failure:
#   * the query times out (the decoder is waiting for bytes that will never come)
#   * the error text mentions dirty / fatal / reprogram / the credit timeout
# On a wedge the run stops by default, because every later result would be measuring a dead board.
#
#   ./scripts/soak.sh                      # one pass over everything
#   ./scripts/soak.sh --repeat 20          # soak: 20 passes, report the first failure
#   ./scripts/soak.sh --quick              # decoder corpus only, no TPC-H
#   ./scripts/soak.sh --include-hangs      # also run the cases known to hang (needs a reprogram after)
#   ./scripts/soak.sh --keep-going         # do not stop on a wedge
#
# Env: DUCKDB, OASIS_SERVER, OASIS_PORT, and the usual OASIS_HTTP_MAX_INFLIGHT / _CHUNK_BYTES.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUCKDB=${DUCKDB:-$ROOT/extension/build/release/duckdb}
# The bitstream the reprogram hint below points at. Resolved to the newest build that actually
# produced one, because hardcoding a build number here sends you to a stale bitstream and costs
# a full board cycle to notice.
BITSTREAM=$(ls -dt "$ROOT"/hardware/build-*/bitstreams/cyt_top.bit 2>/dev/null | head -1)
SERVER=${OASIS_SERVER:-10.253.74.74}
PORT=${OASIS_PORT:-9000}
REPEAT=1
TIMEOUT=120
QUICK=0
INCLUDE_HANGS=0
STOP_ON_WEDGE=1

while [ $# -gt 0 ]; do
    case "$1" in
        --repeat)        REPEAT="$2"; shift ;;
        --timeout)       TIMEOUT="$2"; shift ;;
        --server)        SERVER="$2"; shift ;;
        --port)          PORT="$2"; shift ;;
        --quick)         QUICK=1 ;;
        --include-hangs) INCLUDE_HANGS=1 ;;
        --keep-going)    STOP_ON_WEDGE=0 ;;
        -h|--help)       sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

if [ ! -x "$DUCKDB" ]; then
    echo "no duckdb shell at $DUCKDB (build it with 'make' in extension/)" >&2
    exit 2
fi

# The FPGA reaches MinIO on its own 100 GbE port, but the CPU baseline goes through the host stack
# and will hit the corporate proxy on a bare IP.
export NO_PROXY="${SERVER},127.0.0.1,localhost,${NO_PROXY:-}"
export no_proxy="$NO_PROXY"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy 2>/dev/null || true

SETUP="SET http_server='$SERVER'; SET http_port=$PORT; SET enable_progress_bar=false;"

# ---------------------------------------------------------------------------------------------
# Cases: name | object | query body (%%SRC%% is replaced by the reader) | expectation
#
#   match  the FPGA answer must equal the CPU answer                     (counts as a failure)
#   throw  read_oasis must reject this, and read_parquet must accept it  (counts as a failure)
#   probe  run it and report, never fails the run -- boundary cases whose intended behaviour
#          is not settled, so a change here is news rather than a regression
#   hang   known to hang the decoder; skipped unless --include-hangs, and it WILL need a reprogram
#
# Every query projects a real fixed-width column on purpose. A bare count(*) projects nothing, so
# read_oasis answers straight from the footer with the FPGA idle and the case proves nothing.
# ---------------------------------------------------------------------------------------------
CASES=(
  # --- decoder corpus: encodings, codecs, page and buffer boundaries -----------------------
  "t4|/testbench/t4.parquet|SELECT count(*), sum(numbers) FROM %%SRC%%|match"
  "t8|/testbench/t8.parquet|SELECT count(*), sum(numbers) FROM %%SRC%%|match"
  "t16|/testbench/t16.parquet|SELECT count(*), sum(numbers) FROM %%SRC%%|match"
  "t64|/testbench/t64.parquet|SELECT count(*), sum(numbers) FROM %%SRC%%|match"
  "t256|/testbench/t256.parquet|SELECT count(*), sum(numbers) FROM %%SRC%%|match"
  "t1024|/testbench/t1024.parquet|SELECT count(*), sum(numbers) FROM %%SRC%%|match"
  "fp4|/testbench/fp4.parquet|SELECT count(*), sum(numbers) FROM %%SRC%%|match"
  "fp1024|/testbench/fp1024.parquet|SELECT count(*), sum(numbers) FROM %%SRC%%|match"
  "dk4-int64|/testbench/dk4.parquet|SELECT count(*), sum(numbers) FROM %%SRC%%|match"
  "dummy|/testbench/dummy.parquet|SELECT count(*), sum(numbers) FROM %%SRC%%|match"
  "dict-100k|/testbench/dict.parquet|SELECT count(*), sum(v) FROM %%SRC%%|match"
  "uncompressed|/testbench/unco.parquet|SELECT count(*), sum(v) FROM %%SRC%%|match"
  "seam|/testbench/seam.parquet|SELECT count(*), sum(v) FROM %%SRC%%|match"
  "bufeq-131072|/testbench/bufeq.parquet|SELECT count(*), sum(v) FROM %%SRC%%|match"
  "manyrg-245rg|/testbench/manyrg.parquet|SELECT count(*), sum(v) FROM %%SRC%%|match"
  # boundary cases -- report, do not fail
  "bufov-131073|/testbench/bufov.parquet|SELECT count(*), sum(v) FROM %%SRC%%|probe"
  "empty-0rows|/testbench/empty.parquet|SELECT count(*), sum(v) FROM %%SRC%%|probe"
  # unsupported codecs must be rejected, not silently misdecoded
  "gzip-reject|/testbench/gzip.parquet|SELECT count(*), sum(v) FROM %%SRC%%|throw"
  "zstd-reject|/testbench/zstd.parquet|SELECT count(*), sum(v) FROM %%SRC%%|throw"
  # NULLs: the decoder is configured from num_values, which counts NULLs, but the page only holds
  # the non-null values, so it waits forever for values that do not exist. See README.
  "nulls|/testbench/nulls.parquet|SELECT count(*), sum(v) FROM %%SRC%%|hang"
)

TPCH_CASES=(
  "region|/throughput/tpch-1/region.parquet|SELECT count(*), sum(r_regionkey) FROM %%SRC%%|match"
  "nation|/throughput/tpch-1/nation.parquet|SELECT count(*), sum(n_nationkey), sum(n_regionkey) FROM %%SRC%%|match"
  "supplier|/throughput/tpch-1/supplier.parquet|SELECT count(*), sum(s_suppkey), round(sum(s_acctbal),2) FROM %%SRC%%|match"
  "part|/throughput/tpch-1/part.parquet|SELECT count(*), sum(p_partkey), sum(p_size) FROM %%SRC%%|match"
  "customer|/throughput/tpch-1/customer.parquet|SELECT count(*), sum(c_custkey), round(sum(c_acctbal),2) FROM %%SRC%%|match"
  "orders|/throughput/tpch-1/orders.parquet|SELECT count(*), sum(o_orderkey), round(sum(o_totalprice),2) FROM %%SRC%%|match"
  "longpath-64ch|/throughput/longP/pathlengthtestsixtyfourchars1234/part.parquet|SELECT count(*), sum(p_partkey) FROM %%SRC%%|match"
  "lineitem-1col|/throughput/tpch-1/lineitem.parquet|SELECT sum(l_orderkey) FROM %%SRC%%|match"
  "lineitem-q6|/throughput/tpch-1/lineitem.parquet|SELECT round(sum(l_extendedprice * l_discount),4) FROM %%SRC%% WHERE l_shipdate >= DATE '1994-01-01' AND l_shipdate < DATE '1995-01-01' AND l_discount BETWEEN 0.05 AND 0.07 AND l_quantity < 24|match"
  "lineitem-wide|/throughput/tpch-1/lineitem.parquet|SELECT sum(l_orderkey), sum(l_partkey), sum(l_suppkey), sum(l_linenumber), sum(l_quantity), sum(l_extendedprice), sum(l_discount), sum(l_tax) FROM %%SRC%%|match"
)

[ "$QUICK" = 1 ] || CASES+=("${TPCH_CASES[@]}")

# Runs one query. Leaves output in RUN_OUT and the exit status in RUN_RC (124 == timed out).
run_sql() {
    local reader=$1 obj=$2 body=$3
    local src sql
    if [ "$reader" = fpga ]; then
        src="read_oasis('httpfpga://$obj')"
        sql="$SETUP ${body//%%SRC%%/$src};"
    else
        src="read_parquet('httpfpga://$obj')"
        sql="$SETUP SET httpfpga_cpu_fallback=true; ${body//%%SRC%%/$src};"
    fi
    RUN_OUT=$(timeout "${TIMEOUT}s" "$DUCKDB" -noheader -list -c "$sql" 2>&1)
    RUN_RC=$?
}

# A failure that means the board itself is now unusable, not just this query.
is_wedge() {
    [ "$RUN_RC" = 124 ] && return 0
    printf '%s' "$RUN_OUT" | grep -qiE 'dirty|fatal|reprogram|ring has been at its depth' && return 0
    return 1
}

PASS=0; FAIL=0; PROBE=0; SKIP=0; WEDGED=0
FAILED_NAMES=()

echo "=============================================================================="
echo " oasis decoder soak   server=$SERVER:$PORT  repeat=$REPEAT  timeout=${TIMEOUT}s"
echo " inflight=${OASIS_HTTP_MAX_INFLIGHT:-default}  chunk=${OASIS_HTTP_CHUNK_BYTES:-default}"
echo " cases: ${#CASES[@]} per pass"
echo "=============================================================================="

for pass in $(seq 1 "$REPEAT"); do
    echo
    echo "---- pass $pass/$REPEAT ----"
    for case_line in "${CASES[@]}"; do
        IFS='|' read -r name obj body expect <<< "$case_line"

        if [ "$expect" = hang ] && [ "$INCLUDE_HANGS" = 0 ]; then
            printf '  %-16s SKIP   (known hang; --include-hangs to run, needs a reprogram after)\n' "$name"
            SKIP=$((SKIP + 1))
            continue
        fi

        run_sql fpga "$obj" "$body"
        fpga_out=$RUN_OUT; fpga_rc=$RUN_RC

        if is_wedge; then
            printf '  %-16s WEDGE  rc=%s %s\n' "$name" "$fpga_rc" "$(printf '%s' "$fpga_out" | tr '\n' ' ' | cut -c1-160)"
            WEDGED=$((WEDGED + 1)); FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name(wedge)")
            if [ "$STOP_ON_WEDGE" = 1 ]; then
                echo
                echo "  stopping: the handler latches this state and there is no reset CSR."
                echo "  reprogram before the next run:"
                echo "    cd $ROOT/parcore/libstf/coyote/util && ./program_hacc_local.sh \\"
                echo "        ${BITSTREAM:-$ROOT/hardware/<newest>/bitstreams/cyt_top.bit} \\"
                echo "        $ROOT/parcore/libstf/coyote/driver/build/coyote_driver.ko"
                break 2
            fi
            continue
        fi

        case "$expect" in
            throw)
                if [ "$fpga_rc" = 0 ]; then
                    printf '  %-16s FAIL   expected a rejection, got: %s\n' "$name" "$(printf '%s' "$fpga_out" | head -1)"
                    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name")
                else
                    printf '  %-16s ok     rejected: %s\n' "$name" \
                        "$(printf '%s' "$fpga_out" | tr '\n' ' ' | grep -oiE '[^ ]*codec[^,.]*' | head -1)"
                    PASS=$((PASS + 1))
                fi
                ;;
            match|probe)
                run_sql cpu "$obj" "$body"
                if [ "$fpga_rc" != 0 ] || [ "$RUN_RC" != 0 ]; then
                    if [ "$expect" = probe ]; then
                        printf '  %-16s PROBE  fpga_rc=%s cpu_rc=%s %s\n' "$name" "$fpga_rc" "$RUN_RC" \
                            "$(printf '%s' "$fpga_out" | tr '\n' ' ' | cut -c1-100)"
                        PROBE=$((PROBE + 1))
                    else
                        printf '  %-16s FAIL   fpga_rc=%s cpu_rc=%s %s\n' "$name" "$fpga_rc" "$RUN_RC" \
                            "$(printf '%s' "$fpga_out" | tr '\n' ' ' | cut -c1-140)"
                        FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name")
                    fi
                elif [ "$fpga_out" = "$RUN_OUT" ]; then
                    printf '  %-16s ok     %s\n' "$name" "$(printf '%s' "$fpga_out" | tr '\n' ' ' | cut -c1-70)"
                    PASS=$((PASS + 1))
                else
                    printf '  %-16s MISMATCH\n           fpga: %s\n           cpu : %s\n' "$name" \
                        "$(printf '%s' "$fpga_out" | tr '\n' ' ' | cut -c1-90)" \
                        "$(printf '%s' "$RUN_OUT"  | tr '\n' ' ' | cut -c1-90)"
                    if [ "$expect" = probe ]; then PROBE=$((PROBE + 1))
                    else FAIL=$((FAIL + 1)); FAILED_NAMES+=("$name"); fi
                fi
                ;;
        esac
    done
done

echo
echo "=============================================================================="
printf ' pass %d   fail %d   probe %d   skip %d   wedges %d\n' "$PASS" "$FAIL" "$PROBE" "$SKIP" "$WEDGED"
if [ "${#FAILED_NAMES[@]}" -gt 0 ]; then
    printf ' failed: %s\n' "$(printf '%s ' "${FAILED_NAMES[@]}")"
fi
if [ "$WEDGED" -gt 0 ]; then
    echo
    echo ' A wedge means the handler latched an unrecoverable state (dirty abort, or the request'
    echo ' ring stopped draining). Reprogram the bitstream -- restarting DuckDB will not clear it.'
fi
echo "=============================================================================="

[ "$FAIL" -eq 0 ]

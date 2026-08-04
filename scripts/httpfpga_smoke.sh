#!/usr/bin/env bash
# Self-checking smoke test for the httpfpga:// read path.
#
# Every expected value here was computed from the objects actually on the MinIO server
# (10.253.74.74:9000), not from TPC-H reference tables, so a mismatch means the bytes the FPGA
# delivered differ from the bytes the server holds -- not that the data set is unusual.
#
# Cases are ordered by transfer size: the cheapest failure comes first, so a broken datapath fails in
# under a second instead of after a 56 MB read. Path lengths are called out because the GET path
# budget is 64 characters (it was 32 before build-88) and most realistic prefixes sit either side of
# the old limit.
#
#   ./scripts/httpfpga_smoke.sh            # all cases
#   ./scripts/httpfpga_smoke.sh --quick    # only the small ones (< 1 MB)
#   ./scripts/httpfpga_smoke.sh --diff     # differential: FPGA vs CPU fallback, no expected values
#
# Run from the repo root on the alveo node, after the extension is built and the board programmed.

set -u

DUCKDB="${DUCKDB:-./extension/build/release/duckdb}"
SERVER="${HTTP_SERVER:-10.253.74.74}"
PORT="${HTTP_PORT:-9000}"
DEBUG="${HTTPFPGA_DEBUG:-false}"

MODE="all"
case "${1:-}" in
	--quick) MODE="quick" ;;
	--diff)  MODE="diff" ;;
	--help|-h) sed -n '2,20p' "$0"; exit 0 ;;
	"") ;;
	*) echo "unknown option: $1" >&2; exit 2 ;;
esac

if [[ ! -x "$DUCKDB" ]]; then
	echo "no duckdb shell at $DUCKDB (set DUCKDB=... or run make in extension/)" >&2
	exit 2
fi

PASS=0
FAIL=0
FAILED_CASES=()

# Runs `sql` and leaves stdout in RUN_OUT, stderr in RUN_ERR, exit status in RUN_RC.
#
# Only stdout is ever compared. The [httpfpga] debug lines and the watchdog go to stderr, so folding
# stderr into the result would make every case fail the moment HTTPFPGA_DEBUG=true -- and would hide
# the error text on a genuine failure behind a diff of the wrong thing. `fallback` picks the path:
# true fetches over an ordinary host socket, false goes through the FPGA.
run_query() {
	local fallback="$1" sql="$2"
	local errfile
	errfile="$(mktemp)"
	RUN_OUT="$("$DUCKDB" -csv -noheader -c "
SET enable_progress_bar=false;
SET http_server='$SERVER';
SET http_port=$PORT;
SET httpfpga_cpu_fallback=$fallback;
SET httpfpga_debug=$DEBUG;
$sql" 2>"$errfile")"
	RUN_RC=$?
	RUN_ERR="$(cat "$errfile")"
	rm -f "$errfile"
}

record_pass() {
	echo "PASS  $1"
	PASS=$((PASS + 1))
}

record_fail() {
	echo "FAIL  $1"
	FAIL=$((FAIL + 1))
	FAILED_CASES+=("$1")
}

# Indents whatever came out on stderr, so a failure shows the actual exception rather than just an
# empty result.
show_err() {
	[[ -n "$1" ]] && echo "$1" | sed 's/^/          | /'
}

# check <label> <expected-rows> <sql> -- runs the FPGA path against a known answer.
check() {
	local label="$1" expected="$2" sql="$3"
	run_query false "$sql"
	if [[ $RUN_RC -eq 0 && "$RUN_OUT" == "$expected" ]]; then
		record_pass "$label"
	else
		record_fail "$label"
		echo "        expected: $(echo "$expected" | tr '\n' ' ')"
		echo "        actual:   $(echo "$RUN_OUT" | tr '\n' ' ')"
		show_err "$RUN_ERR"
	fi
}

# diff_check <label> <sql> -- no expected value needed; the CPU path is the oracle.
#
# The CPU side runs FIRST, on purpose. It is the reference, so if it fails the problem is the server,
# the object or the query -- not the datapath -- and the run says so instead of blaming the FPGA for
# someone else's bug. Note the CPU path still initializes the board (OpenFile does that before the
# fallback is consulted), so this is not a way to test without hardware.
diff_check() {
	local label="$1" sql="$2"
	local ref
	run_query true "$sql"
	ref="$RUN_OUT"
	if (( RUN_RC != 0 )); then
		record_fail "$label -- reference (CPU) side failed, FPGA not judged"
		show_err "$RUN_ERR"
		return
	fi

	run_query false "$sql"
	if [[ $RUN_RC -eq 0 && "$RUN_OUT" == "$ref" ]]; then
		record_pass "$label (fpga == cpu)"
	else
		record_fail "$label (fpga != cpu)"
		echo "        cpu:  $(echo "$ref" | tr '\n' ' ')"
		echo "        fpga: $(echo "$RUN_OUT" | tr '\n' ' ')"
		show_err "$RUN_ERR"
	fi
}

T="httpfpga://"

if [[ "$MODE" == "diff" ]]; then
	echo "== differential: the same query on both paths must agree =="
	# No hardcoded answers: this catches corruption even in files nobody has baselined, and it is the
	# only check that stays valid if the data on the server is regenerated.
	diff_check "dummy"          "SELECT * FROM read_parquet('${T}/testbench/dummy.parquet') ORDER BY numbers;"
	diff_check "region"         "SELECT * FROM read_parquet('${T}/throughput/tpch-1/region.parquet') ORDER BY r_regionkey;"
	diff_check "nation"         "SELECT * FROM read_parquet('${T}/throughput/tpch-1/nation.parquet') ORDER BY n_nationkey;"
	diff_check "supplier sf1"   "SELECT count(*), sum(s_suppkey), round(sum(s_acctbal),2) FROM read_parquet('${T}/throughput/tpch-1/supplier.parquet');"
	diff_check "part sf1"       "SELECT p_brand, count(*) FROM read_parquet('${T}/throughput/tpch-1/part.parquet') GROUP BY 1 ORDER BY 1;"
	diff_check "customer sf1"   "SELECT c_mktsegment, count(*) FROM read_parquet('${T}/throughput/tpch-1/customer.parquet') GROUP BY 1 ORDER BY 1;"
	diff_check "supplier sf30"  "SELECT count(*), round(sum(s_acctbal),2) FROM read_parquet('${T}/throughput/tpch-30/supplier.parquet');"
else
	echo "== tiny: smallest possible transfers =="
	# 690 bytes, path 24 chars -- the only case that fits the pre-build-88 32-character budget, so it
	# still works even if the path widening is broken. If this passes and everything else fails, the
	# problem is the widened path, not the datapath.
	check "dummy.parquet (690 B, path 24)" \
		$'1\n2\n3\n4' \
		"SELECT numbers FROM read_parquet('${T}/testbench/dummy.parquet') ORDER BY numbers;"

	# 1060 bytes, path 33 -- the cheapest case that needs a path longer than 32 characters.
	check "region rows (1 KB, path 33)" \
		$'0,AFRICA\n1,AMERICA\n2,ASIA\n3,EUROPE\n4,MIDDLE EAST' \
		"SELECT r_regionkey, r_name FROM read_parquet('${T}/throughput/tpch-1/region.parquet') ORDER BY r_regionkey;"

	# 2297 bytes. Integer-only, so no decimal formatting can muddy a real mismatch.
	check "nation checksum (2 KB, path 33)" \
		"25,300,50" \
		"SELECT count(*), sum(n_nationkey), sum(n_regionkey) FROM read_parquet('${T}/throughput/tpch-1/nation.parquet');"

	check "nations per region" \
		$'0,5\n1,5\n2,5\n3,5\n4,5' \
		"SELECT n_regionkey, count(*) FROM read_parquet('${T}/throughput/tpch-1/nation.parquet') GROUP BY 1 ORDER BY 1;"

	echo "== small: single row group, sub-megabyte =="
	# 794 KB, 1 row group, path 35. First case big enough to span many FPGA buffers.
	check "supplier sf1 (794 KB, path 35)" \
		"10000,50005000,45103548.65" \
		"SELECT count(*), sum(s_suppkey), round(sum(s_acctbal),2) FROM read_parquet('${T}/throughput/tpch-1/supplier.parquet');"

	if [[ "$MODE" == "quick" ]]; then
		echo
		echo "quick mode: skipping the multi-megabyte cases"
	else
		echo "== medium: multiple row groups =="
		# 6.4 MB, 2 row groups, path 31 -- also under the old 32 budget.
		check "part sf1 count (6 MB, path 31)" \
			"200000,25.4271" \
			"SELECT count(*), round(avg(p_size),4) FROM read_parquet('${T}/throughput/tpch-1/part.parquet');"

		check "part sf1 brands" \
			$'Brand#11,7876\nBrand#12,8167\nBrand#13,7989\nBrand#14,8053\nBrand#15,7999' \
			"SELECT p_brand, count(*) FROM read_parquet('${T}/throughput/tpch-1/part.parquet') GROUP BY 1 ORDER BY 1 LIMIT 5;"

		# 12 MB, 2 row groups. Strings only -- a byte lost mid-transfer shows up as a garbled segment
		# name rather than a plausible-looking number.
		check "customer sf1 segments (12 MB, path 35)" \
			$'AUTOMOBILE,29752\nBUILDING,30142\nFURNITURE,29968\nHOUSEHOLD,30189\nMACHINERY,29949' \
			"SELECT c_mktsegment, count(*) FROM read_parquet('${T}/throughput/tpch-1/customer.parquet') GROUP BY 1 ORDER BY 1;"

		# 23 MB, 3 row groups, path 36 -- the longest path in the suite.
		check "supplier sf30 (23 MB, path 36)" \
			"300000,1348760542.11" \
			"SELECT count(*), round(sum(s_acctbal),2) FROM read_parquet('${T}/throughput/tpch-30/supplier.parquet');"

		echo "== large: 13 row groups, dates and decimals =="
		# 56 MB. Range offsets here are 9 digits, which is what exposed the truncated Range header:
		# the begin value spans three CSR words instead of two.
		check "orders sf1 status (56 MB, path 33)" \
			$'F,729413,109702414613.69\nO,732044,110017774440.76\nP,38543,7109117393.01' \
			"SELECT o_orderstatus, count(*), round(sum(o_totalprice),2) FROM read_parquet('${T}/throughput/tpch-1/orders.parquet') GROUP BY 1 ORDER BY 1;"

		check "orders sf1 by year" \
			$'1992,227089\n1993,226645\n1994,227597\n1995,228637\n1996,228626\n1997,227783\n1998,133623' \
			"SELECT year(o_orderdate), count(*) FROM read_parquet('${T}/throughput/tpch-1/orders.parquet') GROUP BY 1 ORDER BY 1;"

		check "orders sf1 date span" \
			"1500000,1992-01-01,1998-08-02" \
			"SELECT count(*), min(o_orderdate), max(o_orderdate) FROM read_parquet('${T}/throughput/tpch-1/orders.parquet');"

		check "orders sf1 top 5 by price" \
			$'1750466,555285.16\n4722021,544089.09\n3043270,530604.44\n4576548,525590.57\n2232932,522720.61' \
			"SELECT o_orderkey, o_totalprice FROM read_parquet('${T}/throughput/tpch-1/orders.parquet') ORDER BY o_totalprice DESC, o_orderkey LIMIT 5;"
	fi
fi

echo
echo "-------- $PASS passed, $FAIL failed --------"
if (( FAIL > 0 )); then
	printf 'failed: %s\n' "${FAILED_CASES[@]}"
	exit 1
fi

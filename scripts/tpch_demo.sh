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
#   On speed it reports one thing only: total wall clock for the suite, each side against the other,
#   with the CPU side running STOCK DuckDB (its httpfs filesystem, its parquet reader) over the same
#   objects on the same server, so nothing we wrote is inside the baseline.
#   summed over the queries where both sides finished. That is a fair end-to-end number but it says
#   nothing about WHERE the time went -- for the decomposition into fetch, decode, idle and stall,
#   use scripts/throughput.sh.
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
#   ./scripts/tpch_demo.sh --cpu-first        # run the CPU side first, to expose the cache bias
#   ./scripts/tpch_demo.sh --threads 1        # pin BOTH sides to one DuckDB thread
#   ./scripts/tpch_demo.sh --phases           # all FPGA queries, THEN all CPU ones
#   ./scripts/tpch_demo.sh --cpu-baseline fallback   # time our own CPU path instead of stock DuckDB
#   ./scripts/tpch_demo.sh --groups 4         # row groups in flight per scan (default 16)
#   ./scripts/tpch_demo.sh --threads 1 --cpu-threads 0   # FPGA on 1 thread, CPU on every core
#   ./scripts/tpch_demo.sh --single-session   # all 22 queries in ONE duckdb process per side
#   ./scripts/tpch_demo.sh --cache off        # DEFAULT: neither side caches file data in RAM
#   ./scripts/tpch_demo.sh --cache full       # DuckDB's own cache defaults, i.e. the CPU at its best
#
# --single-session is the standard TPC-H shape and the quotable one. By default this script starts a
# FRESH duckdb per query -- 44 processes for a full run -- which throws away every in-process cache
# between queries. DuckDB's parquet metadata cache and its external file cache both live in the
# process, so per-query processes re-fetch every footer over HTTP (lineitem's alone is 2.37 MB) and
# re-read every byte. It also re-attaches the vFPGA 22 times while the hardware's TCP connection
# persists across them, which is how a killed query poisons the next.
#
# EXPECT THE RATIO TO DROP. The CPU side gains more from caching than the FPGA side does. That is
# the point: it is the number that survives scrutiny.
#   ./scripts/tpch_demo.sh --sched-depth 16   # splinters in flight per stream (0 = hardware depth,
#                                             # which is 64 -- exactly filling BOTH the decoder
#                                             # config FIFO and the HTTP chunk queue, no slack)
#
# The CPU baseline is STOCK DuckDB by default -- its httpfs filesystem and its parquet reader,
# reading the same objects from the same MinIO. One-time setup, with the proxy still set:
#     duckdb -c 'INSTALL httpfs;'
#
# USE --phases AT SCALE 30. Interleaved, the FPGA's persistent connection idles through every CPU
# baseline run, and MinIO closes it after ~30 s -- the next FPGA query then sends into a dead socket
# and dies unrecoverably. See the PHASES comment below for the mechanism.
#
# The summary ends with the total for each side and the ratio between them. --threads 1 is the
# comparison to quote: without it the CPU column is every core at once against one decoder.
#
# ON --cpu-first: both sides fetch the same bytes from the same MinIO, so whichever runs SECOND
# reads them from the server's page cache. The default order (FPGA first) therefore warms the cache
# for the CPU baseline on every single query. If the ratio changes when you flip this, the number
# being reported is partly a cache-hit rate, not a decode rate.
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
# Which side runs first. This is not cosmetic: both sides fetch THE SAME BYTES from MinIO, so
# whichever runs second reads them out of the server's page cache. Running FPGA-first therefore
# hands the CPU baseline a warm cache on every query and flatters it. Swap the order and the bias
# reverses; if the ratio moves, the comparison was measuring caching as much as decoding.
CPU_FIRST=0
# Run every FPGA query first, then every CPU query, instead of alternating per query.
#
# This is not a style preference, it is a correctness fix for the FPGA side. The handler holds ONE
# persistent TCP connection to the object store and it outlives the duckdb PROCESS -- connections are
# cumulative since the bitstream was programmed. MinIO closes an idle connection after ~30 s (measured:
# keep-alive probe at 15.3 s, FIN at 30.25 s). Interleaved, the FPGA's connection sits idle for the
# whole of each CPU baseline run, so any query whose cpu_s approaches 30 s hands the NEXT FPGA query a
# connection the server has already closed. The handler does not test peer_closed before transmitting,
# so it sends into the dead socket, and because earlier body bytes had already reached the decoder the
# abort is DIRTY -- unreplayable, fatal, reprogram to clear.
#
# In phases the FPGA gap between queries is one process start, about a second, and the connection never
# goes idle long enough to be closed. The cache bias is the reverse of --cpu-first and is reported.
PHASES=0
# Which CPU baseline to time.
#   httpfs   (default) stock DuckDB: its own httpfs filesystem and its own parquet reader, over plain
#            HTTP to the same MinIO. No code of ours in the baseline at all. This is the number to
#            quote, and the one a reviewer will ask for. Needs a one-time `INSTALL httpfs;` with the
#            proxy still set -- this script unsets it, so do that separately.
#   fallback read_parquet over our httpfpga:// filesystem with httpfpga_cpu_fallback=true. Same
#            filesystem on both sides, so it isolates the DECODER more tightly -- but it is our code,
#            and it fetches without keep-alive, so it flatters the FPGA by roughly a third.
#
# Expect stock httpfs to be considerably FASTER than the old fallback: it pools connections and
# prefetches in parallel. That is the point. If the ratio moves against us, that was always the real
# number.
CPU_BASELINE=httpfs
# Row groups a scan keeps in flight. Empty means DuckDB's default (16).
#
# This bounds how many COLUMN CHUNKS are outstanding on the FPGA at once: chunks =
# groups_in_flight x projected columns, summed over the tables a query scans. A six-way join at the
# default fills the handler's 64-entry chunk queue, and once it is full the decoder is behind, the
# read stage stalls, and the query stops -- reported as "config port refused a chunk-length entry".
#
# It is a HOST-side concurrency knob, not a wire one: the requests for each batch still go out in a
# single TCP write however low this is set.
GROUPS_IN_FLIGHT=
# DuckDB worker threads, applied to BOTH sides. Empty means DuckDB's default (one per core).
#
# --threads 1 is the honest like-for-like comparison. By default DuckDB decodes Parquet across every
# core while the FPGA path decodes in one piece of hardware, so the wall-clock gap is partly a core
# count. Pinning both to one thread removes that and asks the question actually being asked: for the
# same amount of parallelism, is decoding in hardware faster?
THREADS=""

# Caching posture, applied to BOTH sides. A FAIRNESS knob, not a tuning one.
#
# Three caches are in play and only two of them are ours to set:
#
#   enable_external_file_cache -- DuckDB's in-memory cache of file DATA, and it DEFAULTS TO TRUE
#       (duckdb v1.5.2, src/include/duckdb/main/settings.hpp:710). It caches everything the CPU
#       baseline's parquet reader touches, footers AND column bytes, so in --single-session the CPU
#       can answer the second query that reads lineitem out of RAM with no HTTP at all. The FPGA
#       side cannot use it the same way: ParquetReader opens through CachingFileSystem
#       (extension/parquet/parquet_reader.cpp:862) so our FOOTER reads are cached, but the column
#       bytes never pass through it -- the scheduler streams them into the decoder. Leaving this at
#       its default hands the CPU a cache the FPGA path structurally cannot have, and that is
#       exactly what makes a --single-session ratio unquotable.
#   enable_http_metadata_cache -- httpfs's cache of HTTP metadata (HEAD results). CPU side only:
#       our filesystem never consults it, it keeps its own one-HEAD-per-path size cache
#       (http_file_system.cpp:374). Defaults to false.
#   MinIO's own page cache -- shared by both sides and NOT settable from here. It is why every
#       configuration is run twice and the second run reported.
#
#   off       (default) both DuckDB caches OFF on both sides. Every query re-fetches from the
#             server, which is what the FPGA path does today, so both sides do the same work.
#             This is the parity number.
#   metadata  HEAD results cached on the CPU side; no file DATA cached anywhere. Removes the footer
#             round trip without letting either side re-read column bytes from RAM.
#   full      DuckDB's own defaults: the CPU baseline at its best, with a warm RAM cache against an
#             FPGA that has none. Worth quoting TOO -- a baseline that can be accused of being
#             handicapped is worth nothing -- but quote it as what it is.
#
# Whichever it is, it belongs next to the number. "FPGA 273 s vs CPU 249 s" says nothing alone.
CACHE=off

while [ $# -gt 0 ]; do
    case "$1" in
        --scale)   SCALE="$2"; shift ;;
        --only)    ONLY="$2"; shift ;;
        --timeout) TIMEOUT="$2"; shift ;;
        --cpu-first) CPU_FIRST=1 ;;
        --phases)  PHASES=1 ;;
        --cpu-baseline) CPU_BASELINE="$2"; shift ;;
        --groups)  GROUPS_IN_FLIGHT="$2"; shift ;;
        --sched-depth) SCHED_DEPTH="$2"; shift ;;
        --threads) THREADS="$2"; shift ;;
        --cpu-threads) CPU_THREADS="$2"; shift ;;
        --single-session) SINGLE_SESSION=1 ;;
        --cache)   CACHE="$2"; shift ;;
        --server)  SERVER="$2"; shift ;;
        --port)    PORT="$2"; shift ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

case "$CPU_BASELINE" in
    httpfs|fallback) ;;
    *) echo "--cpu-baseline must be 'httpfs' (stock DuckDB) or 'fallback' (ours): got '$CPU_BASELINE'" >&2
       exit 2 ;;
esac

case "$CACHE" in
    off|metadata|full) ;;
    *) echo "--cache must be 'off', 'metadata' or 'full': got '$CACHE'" >&2; exit 2 ;;
esac

if [ "$PHASES" = 1 ] && [ "$CPU_FIRST" = 1 ]; then
    echo "--phases already fixes the order (all FPGA, then all CPU); ignoring --cpu-first." >&2
    CPU_FIRST=0
fi

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

# The CPU baseline, over STOCK DuckDB: the httpfs filesystem and the parquet reader, both shipped by
# DuckDB, reading the same objects from the same MinIO over plain HTTP.
#
# It used to run read_parquet over OUR httpfpga:// filesystem with httpfpga_cpu_fallback=true. That
# was a mistake in the comparison, not merely in its speed: HTTPReadRangeCpu was written as a
# debugging aid and opens a fresh TCP connection per range with Connection: close, which measures
# ~1.35x slower than keep-alive against this server. Patching it would have helped, but the deeper
# problem is that a baseline we wrote is a baseline we can be accused of shaping. Stock httpfs takes
# our code out of the measurement entirely, and it is what a reviewer means by "DuckDB".
views_cpu() {
    local t
    for t in $TABLES; do
        echo "CREATE OR REPLACE VIEW $t AS SELECT * FROM read_parquet('http://${SERVER}:${PORT}${PREFIX}/${t}.parquet');"
    done
}

SETUP="SET http_server='$SERVER'; SET http_port=$PORT; SET enable_progress_bar=false;"
# enable_external_file_cache is a GLOBAL setting and it is on by DEFAULT, so it has to be turned off
# explicitly, on every process, FPGA side included -- otherwise the FPGA side caches its footers in
# RAM while the CPU side caches whole columns, and neither of them is doing what the run claims.
if [ "$CACHE" = full ]; then
    SETUP="$SETUP SET enable_external_file_cache=true;"
else
    SETUP="$SETUP SET enable_external_file_cache=false;"
fi
# httpfs-only, so it is emitted with the CPU baseline rather than here.
if [ "$CACHE" = off ]; then CPU_META_CACHE=false; else CPU_META_CACHE=true; fi
[ -n "$THREADS" ] && SETUP="$SETUP SET threads=$THREADS;"
[ -n "$GROUPS_IN_FLIGHT" ] && SETUP="$SETUP SET oasis_scan_groups_in_flight=$GROUPS_IN_FLIGHT;"
[ -n "${SCHED_DEPTH:-}" ] && SETUP="$SETUP SET oasis_scheduler_queue_depth=$SCHED_DEPTH;"

# Traces go inside the repo, not /tmp. /tmp is per-host, so a trace written on the FPGA node is
# invisible from the build node where the analysis happens -- and the interesting files are exactly
# the ones someone else needs to read.
# One session per side means the FPGA side runs to completion before the CPU side starts,
# which is exactly what --phases means. Force it rather than allow a contradiction.
[ "${SINGLE_SESSION:-0}" = 1 ] && PHASES=1

TRACE_DIR=${TRACE_DIR:-$ROOT/.traces}
mkdir -p "$TRACE_DIR"

# Ctrl-C used to leave the duckdb child running: the shell interrupts the script, but the query
# under `timeout` keeps going and keeps the vFPGA open, so the next run cannot attach and the board
# looks wedged when it is only occupied. Signal the whole process group instead.
on_interrupt() {
    trap - INT TERM
    echo
    echo "  interrupted -- killing the query so it releases the vFPGA"
    kill -TERM 0 2>/dev/null
    exit 130
}
trap on_interrupt INT TERM

# The FPGA script has to arm the profiler before the query and read it back after, and both of those
# print rows of their own. Rather than trying to filter them out by shape -- which silently broke
# every comparison by exactly one row -- bracket the real query with sentinels and take only what
# lies between. Missing sentinels also give us a reliable error signal, since the DuckDB shell
# reading a script does not always exit non-zero on a failed statement.
BEGIN_MARK='<<<OASIS-BEGIN>>>'
END_MARK='<<<OASIS-END>>>'
# Rows between the markers, MINUS anything the library wrote to stderr.
#
# The capture is `> file 2>&1`, because a hardware fault's only trace is on stderr and losing it
# costs a debugging session. That also means OASIS_HTTP_DEBUG's per-batch trace lands between the
# markers and is counted as result rows: a scale-30 q8 reported "3849 fpga rows vs 2 cpu rows" when
# the answer was the correct two rows and the other 3847 lines were debug output. A MISMATCH that is
# really a logging artifact is worse than no check at all -- it sent two rounds of debugging after
# data corruption that had not happened.
#
# Dropped: anything tagged [oasis-http], and continuation lines, which the stall descriptions indent.
# duckdb -noheader -list never indents a value, so leading whitespace is a safe discriminator.
extract_rows() {
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0==b{f=1;next} $0==e{f=0} f' \
        | grep -v '\[oasis-http\]' \
        | grep -v '^[[:space:]]' \
        | sed '/^$/d'
}

# Result sets go through files, not shell variables. At scale 30 a single query can return several
# hundred thousand rows and the old string comparison would have held two copies of it in memory.
FPGA_RAW=$(mktemp); FPGA_ROWS=$(mktemp); CPU_RAW=$(mktemp); CPU_ROWS=$(mktemp)
trap 'rm -f "$FPGA_RAW" "$FPGA_ROWS" "$CPU_RAW" "$CPU_ROWS"' EXIT

echo "=============================================================================="
echo " TPC-H conformance   scale=$SCALE  server=$SERVER:$PORT"
# threads goes in the banner, not only in the summary. Two runs at different chunk sizes were once
# compared as if only the chunk had moved, when one of them had also been left on every core -- and
# the pasted output gave no hint of it until 40 lines later.
echo " inflight=${OASIS_HTTP_MAX_INFLIGHT:-default}  chunk=${OASIS_HTTP_CHUNK_BYTES:-default}  threads=${THREADS:-ALL CORES}  groups=${GROUPS_IN_FLIGHT:-default(16)}"
echo " cpu baseline: $([ "$CPU_BASELINE" = httpfs ] \
        && echo 'stock DuckDB httpfs + read_parquet over plain HTTP' \
        || echo 'OUR httpfpga:// cpu fallback -- not a neutral baseline')"
echo " read_oasis() decodes fixed-width columns on the FPGA; strings are decoded on the host."
# The two things that make a timing comparable, printed with every run because both have silently
# differed between the sides before: what is cached, and whether anything is encrypted.
echo " cache=$CACHE  ($(case "$CACHE" in
        off)      echo 'no file-data cache and no HTTP metadata cache on either side' ;;
        metadata) echo 'HTTP metadata cached on the CPU side; no file data cached on either' ;;
        full)     echo "DuckDB's own defaults -- the CPU side caches file data in RAM, the FPGA cannot" ;;
    esac))"
echo " transport: plain HTTP/1.1, no TLS on either side (FPGA: TCP+HTTP in hardware, no TLS exists"
echo "            in the datapath; CPU: http:// URLs to the same port, proxies unset)."
echo "=============================================================================="
[ "$PHASES" = 1 ] || \
    printf '%-5s %-8s %9s %9s %10s  %s\n' "query" "result" "fpga_s" "cpu_s" "hw_MiB" "note"

PASS=0; FAIL=0; SKIP=0; CONSEC_TIMEOUT=0
FAILED=()
# Totals, summed only over queries where BOTH sides ran to completion. A query that timed out on the
# FPGA or errored on the CPU contributes to neither, because adding a 300 s timeout to one column and
# nothing to the other turns the total into a fiction.
FPGA_TOTAL=0; CPU_TOTAL=0; TIMED=0
accumulate() {
    FPGA_TOTAL=$(awk -v a="$FPGA_TOTAL" -v b="$fpga_s" 'BEGIN{printf "%.2f", a+b}')
    CPU_TOTAL=$(awk -v a="$CPU_TOTAL" -v b="$cpu_s" 'BEGIN{printf "%.2f", a+b}')
    TIMED=$((TIMED+1))
}

# --- FPGA -------------------------------------------------------------------------------
run_fpga() {
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
    # Only DOWNGRADE a success. timeout(1) returns 124 and the shell's own signals 130/143, and
    # every one of those was being overwritten with 1 here, because a killed query never reaches
    # the end marker either. That made every timeout look like an ordinary error: the TIMEOUT
    # branch could not fire, the two-consecutive-timeouts stop never triggered, and the trace kept
    # on timeout was never kept -- in exactly the case it exists for.
    if [ "$fpga_rc" = 0 ] && ! grep -qF "$END_MARK" "$FPGA_RAW"; then
        fpga_rc=1
    fi

}

# --- CPU --------------------------------------------------------------------------------
run_cpu() {
    cpu_file=$(mktemp)
    { echo "$SETUP"
      # --cpu-threads overrides --threads for the CPU side only.
      #
      # threads=1 equalises DECODE parallelism, but it also throttles DuckDB's I/O: it gets HTTP
      # concurrency from threads, so at one thread its parquet reader issues range reads nearly
      # serially and pays the object store's latency on each. The FPGA path keeps 64 requests in
      # flight from a single thread. Comparing at threads=1 therefore handicaps the CPU on I/O
      # while equalising decode -- run it both ways and report both numbers.
      # 0 means "leave DuckDB's own default", i.e. every core -- SET threads=0 is not valid.
      if [ -n "${CPU_THREADS:-}" ] && [ "${CPU_THREADS}" != 0 ]; then
          echo "SET threads=$CPU_THREADS;"
      elif [ "${CPU_THREADS:-}" = 0 ]; then
          echo "RESET threads;"
      fi
      if [ "$CPU_BASELINE" = httpfs ]; then
          # The metadata cache is httpfs's and applies to this side only; --cache decides it. It
          # used to be hardcoded true, which gave the baseline its best shot but made the two sides
          # cache differently without saying so.
          echo "LOAD httpfs; SET enable_http_metadata_cache=$CPU_META_CACHE;"; views_cpu
      else
          echo "SET httpfpga_cpu_fallback=true;"; views read_parquet
      fi
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
    if [ "$cpu_rc" = 0 ] && ! grep -qF "$END_MARK" "$CPU_RAW"; then
        cpu_rc=1
    fi

}



# ---------------------------------------------------------------------------------------------
# --single-session: every query in ONE duckdb process per side.
#
# Per-query wall time comes from timestamps the session itself prints, not from the shell, so the
# process startup that dominates short queries is excluded from all of them equally. Populates the
# same P_S / P_RC / P_MIB arrays and PHASE_CACHE the per-query path fills, so the verdict, the
# totals and every error path below are untouched.
# ---------------------------------------------------------------------------------------------
SESSION_MARK='@@MARK@'

# Emit one query's block: a begin stamp, the body, an end stamp.
session_block() {
    local n=$1 body=$2
    echo "SELECT '${SESSION_MARK}q${n}@begin@' || epoch_ms(get_current_timestamp());"
    echo "$body"
    echo "SELECT '${SESSION_MARK}q${n}@end@' || epoch_ms(get_current_timestamp());"
}

# $1 = fpga|cpu. Writes the raw output to $2.
run_session() {
    local side=$1 out=$2
    local f; f=$(mktemp)
    {
        echo "$SETUP"
        if [ "$side" = cpu ]; then
            if [ -n "${CPU_THREADS:-}" ] && [ "${CPU_THREADS}" != 0 ]; then
                echo "SET threads=$CPU_THREADS;"
            elif [ "${CPU_THREADS:-}" = 0 ]; then
                echo "RESET threads;"
            fi
            echo "LOAD httpfs; SET enable_http_metadata_cache=$CPU_META_CACHE;"
            views_cpu
        else
            views read_oasis
        fi
        local q
        for q in "$ROOT"/scripts/tpch/q*.sql; do
            local n; n=$(basename "$q" .sql); n=${n#q}; n=$((10#$n))
            if [ -n "$ONLY" ] && ! printf ',%s,' "$ONLY" | grep -q ",$n,"; then continue; fi
            session_block "$n" "$(cat "$q")"
        done
    } > "$f"
    # One timeout for the whole session rather than per query.
    local budget=$(( TIMEOUT * 22 ))
    timeout "${budget}s" "$DUCKDB" -noheader -list < "$f" > "$out" 2>&1
    local rc=$?
    rm -f "$f"
    return $rc
}

# Split one session's output into per-query row files and durations.
# $1 = raw output, $2 = destination dir, $3 = suffix (rows file extension)
session_split() {
    local raw=$1 dir=$2
    awk -v mark="$SESSION_MARK" -v dir="$dir" '
        index($0, mark) == 1 {
            rest = substr($0, length(mark) + 1)
            split(rest, a, "@")          # a[1]=qN a[2]=begin|end a[3]=epoch_ms
            q = a[1]; what = a[2]; ms = a[3] + 0
            if (what == "begin") { start[q] = ms; cur = q; next }
            if (what == "end") {
                if (q in start) printf "%s %.2f\n", q, (ms - start[q]) / 1000.0 >> (dir "/durations")
                close(dir "/durations")
                cur = ""; next
            }
            next
        }
        cur != "" {
            if ($0 ~ /\[oasis-http\]/) next
            if ($0 ~ /^[[:space:]]/) next
            if ($0 == "") next
            print >> (dir "/" cur ".rows")
        }
    ' "$raw"
}

# ---------------------------------------------------------------------------------------------
# PHASE 1 (--phases only): every FPGA query, back to back, before any CPU baseline runs.
#
# Results are cached to files and replayed by the main loop below, so the verdict, the totals and
# every error path stay in exactly one place. A wedge still stops the pass -- carrying on past two
# consecutive timeouts costs (remaining queries x TIMEOUT) of nothing.
# ---------------------------------------------------------------------------------------------
declare -A P_S P_RC P_MIB C_S C_RC
CPU_CACHE=""
PHASE_CACHE=""
if [ "$PHASES" = 1 ]; then
    PHASE_CACHE=$(mktemp -d)
    trap 'rm -f "$FPGA_RAW" "$FPGA_ROWS" "$CPU_RAW" "$CPU_ROWS"; rm -rf "$PHASE_CACHE" "$CPU_CACHE"' EXIT
    if [ "${SINGLE_SESSION:-0}" = 1 ]; then
        CPU_CACHE=$(mktemp -d)
        echo "phase 1/2: FPGA, all queries in ONE duckdb session"
        run_session fpga "$FPGA_RAW"; sess_rc=$?
        cp "$FPGA_RAW" "$TRACE_DIR/oasis-session-fpga.txt"
        session_split "$FPGA_RAW" "$PHASE_CACHE"
        echo "phase 2/2: CPU baseline, ONE duckdb session"
        run_session cpu "$CPU_RAW"; cpu_sess_rc=$?
        cp "$CPU_RAW" "$TRACE_DIR/oasis-session-cpu.txt"
        session_split "$CPU_RAW" "$CPU_CACHE"
        # A query that printed an end stamp finished; one that did not was cut off by the session
        # timeout or an error, and its rc has to say so or it would be scored as a pass.
        while read -r q secs; do P_S[${q#q}]=$secs; P_RC[${q#q}]=0; done < "$PHASE_CACHE/durations" 2>/dev/null
        while read -r q secs; do C_S[${q#q}]=$secs; C_RC[${q#q}]=0; done < "$CPU_CACHE/durations" 2>/dev/null
        printf '  fpga session rc=%s   cpu session rc=%s\n' "$sess_rc" "$cpu_sess_rc"
        [ "$sess_rc" = 0 ] || echo "  FPGA session did not complete -- trace: $TRACE_DIR/oasis-session-fpga.txt"
        [ "$cpu_sess_rc" = 0 ] || echo "  CPU session did not complete -- trace: $TRACE_DIR/oasis-session-cpu.txt"
    else
    echo "phase 1/2: FPGA, all queries back to back (keeps the connection from going idle)"
    ct=0
    for f in "$ROOT"/scripts/tpch/q*.sql; do
        n=$(basename "$f" .sql); n=${n#q}; n=$((10#$n))
        if [ -n "$ONLY" ] && ! printf ',%s,' "$ONLY" | grep -q ",$n,"; then continue; fi
        sql_body=$(cat "$f")
        run_fpga
        P_S[$n]=$fpga_s; P_RC[$n]=$fpga_rc; P_MIB[$n]=$hw_mib
        cp "$FPGA_ROWS" "$PHASE_CACHE/q$n.rows"
        cp "$FPGA_RAW"  "$PHASE_CACHE/q$n.raw"
        printf '  q%-3s %8ss  rc=%s\n' "$n" "$fpga_s" "$fpga_rc"
        # Keep the raw output for ANY failure, not just a timeout, and keep it OUTSIDE the phase
        # cache. That cache is a mktemp -d removed on exit, and the verdict that copies failures to
        # /tmp runs in phase 2 -- so a phase-1 failure lost its trace entirely unless the whole run
        # completed, which by definition it had not. A q5 timeout left nothing to look at while
        # phase 1 carried on spending 300 s per remaining query.
        if [ "$fpga_rc" != 0 ]; then
            cp "$FPGA_RAW" "$TRACE_DIR/oasis-q$n-fpga-raw.txt"
            echo "    rc=$fpga_rc -- trace kept: $TRACE_DIR/oasis-q$n-fpga-raw.txt"
            grep -E 'oasis-http|stalled|Error|rror' "$FPGA_RAW" | tail -6 | sed 's/^/      /'
        fi
        if [ "$fpga_rc" = 124 ]; then
            # KEEP THE OUTPUT. A timeout is the case where the trace matters most and it was the one
            # case that threw it away: the raw file is a mktemp that the next query overwrites, so
            # by the time anyone looked, the last state before the hang was gone. With
            # OASIS_HTTP_DEBUG=1 this file holds the per-batch ring occupancy and stall word right
            # up to the moment it stopped, which is otherwise unreadable -- the wedged process still
            # owns the vFPGA, so nothing else can attach to ask.
            cp "$FPGA_RAW" "$TRACE_DIR/oasis-q$n-timeout.txt"
            echo "  timed out -- trace kept: $TRACE_DIR/oasis-q$n-timeout.txt"
            echo "  last lines:"
            grep -E 'oasis-http|stalled|batch' "$FPGA_RAW" | tail -6 | sed 's/^/    /'
            ct=$((ct+1))
            [ "$ct" -ge 2 ] && { echo "  two consecutive timeouts -- stopping the FPGA phase."; break; }
        else
            ct=0
        fi
    done
    fi
    [ "${SINGLE_SESSION:-0}" = 1 ] || echo "phase 2/2: CPU baseline"
    echo
    printf '%-5s %-8s %9s %9s %10s  %s\n' "query" "result" "fpga_s" "cpu_s" "hw_MiB" "note"
fi

# An end stamp means the query STOPPED, not that it succeeded. A query that raised prints its error
# between its own begin and end markers and stamps the end regardless, so scoring on the stamp alone
# treats a failed session as 22 completed queries -- and because both sides then hold the SAME error
# text, `cmp` matches and every query is reported PASS at 0.00 s. A whole run of 404s once printed
# "pass 22  fail 0", which is the most dangerous output this script can produce.
#
# Detected per query rather than by gating on the session rc: at scale 30 a session that dies on q22
# still measured q1..q21 correctly, and throwing those away would be its own kind of wrong.
query_errored() {   # $1 = captured rows file
    [ -s "$1" ] || return 1
    grep -qE '^[A-Za-z][A-Za-z ]*Error: ' "$1"
}

# Replays what phase 1 measured. Defined AFTER run_fpga so it wins the name.
replay_fpga() {
    fpga_s=${P_S[$n]:-0}; fpga_rc=${P_RC[$n]:-1}; hw_mib=${P_MIB[$n]:-}
    # One session = one profiler window for all 22 queries, so a per-query hw_MiB does not exist.
    [ "${SINGLE_SESSION:-0}" = 1 ] && hw_mib=""
    cp "$PHASE_CACHE/q$n.rows" "$FPGA_ROWS" 2>/dev/null || : > "$FPGA_ROWS"
    cp "$PHASE_CACHE/q$n.raw"  "$FPGA_RAW"  2>/dev/null || : > "$FPGA_RAW"
    query_errored "$FPGA_ROWS" && fpga_rc=1
}

# Replays what the single CPU session measured, mirroring replay_fpga.
replay_cpu() {
    cpu_s=${C_S[$n]:-0}; cpu_rc=${C_RC[$n]:-1}
    cp "$CPU_CACHE/q$n.rows" "$CPU_ROWS" 2>/dev/null || : > "$CPU_ROWS"
    : > "$CPU_RAW"
    query_errored "$CPU_ROWS" && cpu_rc=1
}

for f in "$ROOT"/scripts/tpch/q*.sql; do
    n=$(basename "$f" .sql); n=${n#q}; n=$((10#$n))
    if [ -n "$ONLY" ] && ! printf ',%s,' "$ONLY" | grep -q ",$n,"; then continue; fi

    sql_body=$(cat "$f")

    # Second reader gets MinIO's page cache warm, so the order is a measurement choice.
    if   [ "${SINGLE_SESSION:-0}" = 1 ]; then replay_fpga; replay_cpu
    elif [ "$PHASES" = 1 ];    then replay_fpga; run_cpu
    elif [ "$CPU_FIRST" = 1 ]; then run_cpu; run_fpga
    else                            run_fpga; run_cpu; fi

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
        # Keep the whole thing, and print it ONCE. The FPGA side learned this the hard way and the
        # CPU side did not: 60 characters of "IO Error: Extension /home/.../extensions/f1b9c" names
        # neither the extension nor why it was refused, and both are the only things worth knowing.
        cp "$CPU_RAW" "$TRACE_DIR/oasis-q$n-cpu-error.txt"
        if [ "$SKIP" -eq 0 ]; then
            echo "         full error kept: $TRACE_DIR/oasis-q$n-cpu-error.txt"
            sed -n '/rror\|xception\|xtension/p' "$CPU_RAW" | head -6 | sed 's/^/         | /'
            # Only when the failure IS about the extension. This hint once fired on "Couldn't
            # connect to server" -- MinIO being down -- and sent the reader off to rebuild an
            # extension that was working perfectly.
            if [ "$CPU_BASELINE" = httpfs ] && grep -qi 'extension' "$CPU_RAW"; then cat <<'HINT'
         The baseline needs stock httpfs, and INSTALL httpfs CANNOT provide it here. This duckdb
         is one commit past v1.5.2, so it looks for .duckdb/extensions/<commit>/... and the
         repository has no build for that commit. Do NOT substitute the v1.5.2 binary: the extra
         commit adds fields to TableFunction, so the layouts differ and it corrupts rather than
         fails. httpfs is declared in extension/extension_config.cmake -- rebuild the extension.
         Until then, --cpu-baseline fallback runs, but its ratio is not quotable.
HINT
            fi
        fi
        SKIP=$((SKIP+1)); continue
    fi
    # 130 = SIGINT, 143 = SIGTERM. You pressed Ctrl-C; the query was alive and working. Calling that
    # ERROR sent a previous debugging session looking for a fault that had not happened -- and the
    # interrupt leaves the handler mid-transfer, so the board needs a reprogram before the next run.
    if [ "$fpga_rc" = 130 ] || [ "$fpga_rc" = 143 ]; then
        printf '%-5s %-8s %9s %9s %10s  %s\n' "q$n" "INTERRUPTED" "$fpga_s" "$cpu_s" "${hw_mib:--}" \
            "killed by hand while still running -- not a failure"
        echo "         the handler was mid-transfer when it died: reprogram before the next run."
        FAIL=$((FAIL+1)); FAILED+=("q$n"); break
    fi
    if [ "$fpga_rc" != 0 ]; then
        printf '%-5s %-8s %9s %9s %10s  %s\n' "q$n" "ERROR" "$fpga_s" "$cpu_s" "${hw_mib:--}" \
            "$(tr '\n' ' ' < "$FPGA_RAW" | cut -c1-70)"
        # Keep the whole thing. Cut to 70 characters, every hardware failure in this design reads
        # "terminate called after throwing an instance of 'st" -- which names neither the exception
        # nor the stage, and those are the only two things worth knowing. The tail is where the
        # handler state and the stall word are.
        cp "$FPGA_RAW" "$TRACE_DIR/oasis-q$n-error.txt"
        echo "         full error kept: $TRACE_DIR/oasis-q$n-error.txt"
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
        # Only meaningful when a per-query hw_MiB exists. In --single-session there is ONE profiler
        # window for all 22 queries, so hw_mib is deliberately blank -- and treating blank as zero
        # labelled every query "all-CPU query", which is simply false.
        if [ -n "${hw_mib:-}" ]; then
            awk -v m="$hw_mib" 'BEGIN{exit !(m+0 < 0.01)}' &&
                note="$note, all-CPU query (no fixed-width column fetched)"
        fi
        printf '%-5s %-8s %9s %9s %10s  %s\n' "q$n" "PASS" "$fpga_s" "$cpu_s" "${hw_mib:--}" "$note"
        PASS=$((PASS+1)); accumulate
    else
        nf=$(wc -l < "$FPGA_ROWS" | tr -d ' '); nc=$(wc -l < "$CPU_ROWS" | tr -d ' ')
        if [ "$nf" != "$nc" ]; then
            detail="$nf fpga rows vs $nc cpu rows"
        else
            detail="$nf rows both, first difference: $(diff "$FPGA_ROWS" "$CPU_ROWS" \
                     | sed -n '2,3p' | tr '\n' ' ' | cut -c1-70)"
        fi
        printf '%-5s %-8s %9s %9s %10s  %s\n' "q$n" "MISMATCH" "$fpga_s" "$cpu_s" "${hw_mib:--}" "$detail"
        FAIL=$((FAIL+1)); FAILED+=("q$n"); accumulate
        cp "$FPGA_ROWS" "$TRACE_DIR/oasis-q$n-fpga.txt"; cp "$CPU_ROWS" "$TRACE_DIR/oasis-q$n-cpu.txt"
        echo "         full outputs kept: $TRACE_DIR/oasis-q$n-{fpga,cpu}.txt"
    fi
done

echo "=============================================================================="
printf ' pass %d   fail %d   skip %d\n' "$PASS" "$FAIL" "$SKIP"
[ "${#FAILED[@]}" -gt 0 ] && printf ' failed: %s\n' "$(printf '%s ' "${FAILED[@]}")"

# The headline number: total wall clock for the whole suite, each side against the other. This is
# just the sum of the per-query columns above, over the queries where both sides finished.
if [ "$TIMED" -gt 0 ]; then
    echo "------------------------------------------------------------------------------"
    printf ' total over %d queries where both sides completed\n' "$TIMED"
    printf '   FPGA %8.2f s\n' "$FPGA_TOTAL"
    printf '   CPU  %8.2f s   (threads=%s, baseline=%s)\n' "$CPU_TOTAL" "${THREADS:-all cores}" \
        "$([ "$CPU_BASELINE" = httpfs ] && echo 'stock DuckDB' || echo 'our cpu fallback')"
    awk -v f="$FPGA_TOTAL" -v c="$CPU_TOTAL" 'BEGIN{
        if (f <= 0) exit
        r = c / f
        if (r >= 1) printf "   FPGA is %.2fx faster\n", r
        else        printf "   CPU is %.2fx faster\n", 1/r
    }'
    if [ -z "$THREADS" ]; then
        echo "   NOTE: the CPU side used every core. For a like-for-like comparison against one"
        echo "         decoder, rerun with --threads 1."
    fi
    if [ "$CPU_BASELINE" != httpfs ]; then
        echo "   WARNING: the baseline is OUR cpu fallback, which opens a TCP connection per range"
        echo "            with Connection: close. Measured ~1.35x slower than keep-alive against this"
        echo "            server, so this ratio flatters the FPGA. Do not quote it -- use the default."
    fi
    # The cache posture belongs with the total, not only in the banner 40 lines up: it changes what
    # the ratio MEANS, not just its value.
    case "$CACHE" in
        off)      echo "   CACHE: off on both sides -- every query re-fetched from MinIO. Parity." ;;
        metadata) echo "   CACHE: HTTP metadata only on the CPU side; no file data cached anywhere." ;;
        full)     echo "   CACHE: DuckDB defaults -- the CPU side served file data from RAM and the"
                  echo "          FPGA side could not. Quote this next to a --cache off run, never alone." ;;
    esac
    # Whichever side ran second read the same bytes out of MinIO's page cache. Say which that was,
    # because a ratio measured in one order is not the same claim as the other.
    if [ "$PHASES" = 1 ]; then
        echo "   ORDER: every FPGA query ran before any CPU query, so the CPU side read a warm"
        echo "          server cache -- by a whole phase, not by one query. Required at scale 30:"
        echo "          interleaved, MinIO closes the FPGA's idle connection during the CPU runs."
    elif [ "$CPU_FIRST" = 1 ]; then
        echo "   ORDER: CPU ran first, so the FPGA read a warm server cache. Flip with the default"
        echo "          order to see how much of the ratio is caching."
    else
        echo "   ORDER: FPGA ran first, so the CPU read a warm server cache. Rerun with --cpu-first"
        echo "          to see how much of the ratio is caching."
    fi
fi
echo "=============================================================================="
[ "$FAIL" -eq 0 ]

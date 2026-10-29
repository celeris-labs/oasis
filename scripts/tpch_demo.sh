#!/usr/bin/env bash
#
# TPC-H conformance and timing run: all 22 queries, FPGA-decoded vs CPU, on the same objects.
#
# Each table becomes a VIEW over read_oasis('httpfpga://...'), so the official TPC-H query text in
# scripts/tpch/qNN.sql runs UNMODIFIED. Every query is then run a second time on stock DuckDB (its
# httpfs file system and its parquet reader, over plain HTTP to the same server) and the two answers
# are compared cell for cell. Nothing has a baked-in expected value.
#
# WHAT THIS DOES AND DOES NOT PROVE
#   It proves: the hardware decoder returns bit-identical results to DuckDB's own Parquet reader
#   across the full TPC-H workload, including joins, aggregation, sorting and filters.
#   On speed it reports one thing only: total wall clock for the suite, each side against the other,
#   summed over the queries where both sides finished. No code of this repository is inside the
#   baseline. For the decomposition into fetch, decode, idle and stall, use scripts/throughput.sh.
#
# WHERE THE HARDWARE ACTUALLY RUNS. read_oasis decodes FIXED-WIDTH columns on the FPGA. BYTE_ARRAY
# (string) columns have no hardware path and are decoded on the host from bytes fetched over a host
# socket. A query like Q13, which touches almost nothing but strings, passes with the decoder nearly
# idle. The `hw_MiB` column reports the bytes that crossed the decoder.
#
# Objects: /throughput/tpch-<scale>/<table>.parquet on the server, for the eight TPC-H tables.
#
# Usage: scripts/tpch_demo.sh [options]
#   --scale N           read /throughput/tpch-N/ (default 1)
#   --only 1,6,14       a subset of the queries
#   --timeout S         per-query timeout in seconds (default 300)
#   --threads N         DuckDB threads on BOTH sides (default: DuckDB's own, one per core)
#   --cpu-threads N     DuckDB threads on the CPU side only; 0 = every core
#   --groups N          oasis_scan_groups_in_flight: row groups in flight per scan (default 16)
#   --sched-depth N     oasis_scheduler_queue_depth: splinters in flight per stream (0 = the
#                       bitstream's config-FIFO depth)
#   --cache MODE        caching posture on both sides: off (default; no DuckDB file-data or HTTP
#                       metadata cache), metadata (HTTP metadata cached on the CPU side) or full
#                       (DuckDB's defaults, the CPU side caches file data in RAM)
#   --single-session    all queries in ONE duckdb process per side (implies --phases)
#   --phases            all FPGA queries, then all CPU ones (default: alternate per query)
#   --cpu-first         per query, run the CPU side first
#   --server IP         object server address the FPGA can reach (default $OASIS_SERVER, else
#                       10.253.74.74, the server this was developed against)
#   --port P            object server port (default $OASIS_PORT, else 9000)
#   -h, --help          this text
#
# Examples:
#   ./scripts/tpch_demo.sh                    # all 22 on tpch-1
#   ./scripts/tpch_demo.sh --only 1,6,14      # a subset
#   ./scripts/tpch_demo.sh --threads 1 --cpu-threads 0   # FPGA side on 1 thread, CPU on every core
#   ./scripts/tpch_demo.sh --scale 30 --single-session --cache metadata
#
# --single-session is the standard TPC-H shape. By default this script starts a FRESH duckdb per
# query -- 44 processes for a full run -- which throws away every in-process cache between queries:
# DuckDB's parquet metadata cache and its external file cache both live in the process, so
# per-query processes re-fetch every footer over HTTP.
#
# ORDER. Both sides fetch the same bytes from the same server, so whichever runs SECOND reads them
# from the server's page cache. The default order (FPGA first) warms the cache for the CPU baseline
# on every query; --cpu-first reverses that, and --phases warms it by a whole phase. The summary
# says which order ran. If the ratio moves when you flip it, the comparison measures caching as
# much as decoding.
#
# Env: DUCKDB (default extension/build/release/duckdb), OASIS_SERVER, OASIS_PORT, TRACE_DIR
# (default .traces/ in the repository), and the library's OASIS_HTTP_* tunables.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUCKDB=${DUCKDB:-$ROOT/extension/build/release/duckdb}
# The newest bitstream under hardware/build-*, for the reprogram hint printed after a wedge.
BITSTREAM=$(ls -dt "$ROOT"/hardware/build-*/bitstreams/cyt_top.bit 2>/dev/null | head -1)
SERVER=${OASIS_SERVER:-10.253.74.74}
PORT=${OASIS_PORT:-9000}
SCALE=1
TIMEOUT=300
ONLY=""
# Which side runs first per query (see ORDER above).
CPU_FIRST=0
# Run every FPGA query first, then every CPU query, instead of alternating per query. The FPGA's
# lanes then stay busy back to back; an idle lane the server closes is reopened by the handler
# either way.
PHASES=0
# Row groups a scan keeps in flight (oasis_scan_groups_in_flight). Empty means the extension's
# default (16). It bounds how many COLUMN CHUNKS are outstanding on the FPGA at once: groups in
# flight x projected fixed-width columns, summed over the tables a query scans. It is a host-side
# concurrency knob, not a wire one.
GROUPS_IN_FLIGHT=
# DuckDB worker threads, applied to BOTH sides. Empty means DuckDB's default (one per core).
# --cpu-threads overrides it for the CPU side only.
THREADS=""

# Caching posture, applied to BOTH sides. A FAIRNESS knob, not a tuning one.
#
#   enable_external_file_cache -- DuckDB's in-memory cache of file DATA, ON by default. It caches
#       everything the CPU baseline's parquet reader touches, footers AND column bytes, so in
#       --single-session the CPU can answer the second query that reads lineitem out of RAM with no
#       HTTP at all. The FPGA side cannot use it the same way: its footer reads go through DuckDB's
#       caching file system, but the column bytes never pass through it -- the FPGA fetches them
#       itself and streams them into the decoder.
#   enable_http_metadata_cache -- httpfs's cache of HTTP metadata (HEAD results). CPU side only:
#       the httpfpga:// file system keeps its own one-HEAD-per-path size cache. Defaults to false.
#   The server's own page cache -- shared by both sides and NOT settable from here (see ORDER).
#
#   off       (default) both DuckDB caches OFF on both sides. Every query re-fetches from the
#             server, which is what the FPGA path does, so both sides do the same work.
#   metadata  HEAD results cached on the CPU side; no file DATA cached anywhere. Removes the footer
#             round trip without letting either side re-read column bytes from RAM.
#   full      DuckDB's own defaults: the CPU baseline at its best, with a warm RAM cache against an
#             FPGA side that has none. Quote it next to an off or metadata run, never alone.
CACHE=off

while [ $# -gt 0 ]; do
    case "$1" in
        --scale)   SCALE="$2"; shift ;;
        --only)    ONLY="$2"; shift ;;
        --timeout) TIMEOUT="$2"; shift ;;
        --cpu-first) CPU_FIRST=1 ;;
        --phases)  PHASES=1 ;;
        --groups)  GROUPS_IN_FLIGHT="$2"; shift ;;
        --sched-depth) SCHED_DEPTH="$2"; shift ;;
        --threads) THREADS="$2"; shift ;;
        --cpu-threads) CPU_THREADS="$2"; shift ;;
        --single-session) SINGLE_SESSION=1 ;;
        --cache)   CACHE="$2"; shift ;;
        --server)  SERVER="$2"; shift ;;
        --port)    PORT="$2"; shift ;;
        -h|--help) awk 'NR > 1 { if (/^set -uo pipefail/) exit; print }' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

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

# Views over the FPGA reader.
views() {
    local reader=$1 t
    for t in $TABLES; do
        echo "CREATE OR REPLACE VIEW $t AS SELECT * FROM ${reader}('httpfpga://${PREFIX}/${t}.parquet');"
    done
}

# The CPU baseline: stock DuckDB's httpfs file system (built into the shell by
# extension/extension_config.cmake) and its parquet reader, reading the same objects from the same
# server over plain HTTP.
views_cpu() {
    local t
    for t in $TABLES; do
        echo "CREATE OR REPLACE VIEW $t AS SELECT * FROM read_parquet('http://${SERVER}:${PORT}${PREFIX}/${t}.parquet');"
    done
}

# http_server and http_port are set once, before the first httpfpga:// access of each process: the
# extension refuses a change after that.
SETUP="SET http_server='$SERVER'; SET http_port=$PORT; SET enable_progress_bar=false;"
# enable_external_file_cache is a GLOBAL setting and on by DEFAULT, so it is set explicitly on every
# process, FPGA side included.
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

# One session per side means the FPGA side runs to completion before the CPU side starts,
# which is exactly what --phases means. Force it rather than allow a contradiction.
[ "${SINGLE_SESSION:-0}" = 1 ] && PHASES=1

# Traces of failed queries go inside the repository (.traces/, ignored by git), not /tmp, so they
# can be read from another host.
TRACE_DIR=${TRACE_DIR:-$ROOT/.traces}
mkdir -p "$TRACE_DIR"

# Ctrl-C signals the whole process group, so the query under timeout(1) stops too and releases the
# vFPGA; otherwise the next run cannot attach and the board looks wedged when it is only occupied.
on_interrupt() {
    trap - INT TERM
    echo
    echo "  interrupted -- killing the query so it releases the vFPGA"
    kill -TERM 0 2>/dev/null
    exit 130
}
trap on_interrupt INT TERM

# The FPGA script arms the profiler before the query and reads it back after, and both print rows
# of their own. So the real query is bracketed with sentinels and only what lies between is taken.
# A missing end sentinel is also a reliable error signal, since the DuckDB shell reading a script
# does not always exit non-zero on a failed statement.
BEGIN_MARK='<<<OASIS-BEGIN>>>'
END_MARK='<<<OASIS-END>>>'
# Rows between the markers, MINUS anything the library wrote to stderr.
#
# The capture is `> file 2>&1`, because a hardware fault's only trace is on stderr. That also puts
# the debug trace (OASIS_HTTP_DEBUG=1 or httpfpga_debug) between the markers, where it would count
# as result rows. Dropped: lines tagged [oasis-http], [oasis] or [httpfpga], and continuation lines,
# which the stall descriptions indent. duckdb -noheader -list never indents a value, so leading
# whitespace is a safe discriminator.
extract_rows() {
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0==b{f=1;next} $0==e{f=0} f' \
        | grep -v -e '\[oasis-http\]' -e '\[oasis\]' -e '\[httpfpga\]' \
        | grep -v '^[[:space:]]' \
        | sed '/^$/d'
}

# Result sets go through files, not shell variables: at scale 30 a single query can return several
# hundred thousand rows.
FPGA_RAW=$(mktemp); FPGA_ROWS=$(mktemp); CPU_RAW=$(mktemp); CPU_ROWS=$(mktemp)
trap 'rm -f "$FPGA_RAW" "$FPGA_ROWS" "$CPU_RAW" "$CPU_ROWS"' EXIT

echo "=============================================================================="
echo " TPC-H conformance   scale=$SCALE  server=$SERVER:$PORT"
# The knobs go in the banner, so a pasted output says what was run.
echo " inflight=${OASIS_HTTP_MAX_INFLIGHT:-default}  chunk=${OASIS_HTTP_CHUNK_BYTES:-default}  threads=${THREADS:-ALL CORES}  groups=${GROUPS_IN_FLIGHT:-default(16)}"
echo " cpu baseline: stock DuckDB httpfs + read_parquet over plain HTTP"
echo " read_oasis() decodes fixed-width columns on the FPGA; strings are decoded on the host."
# What is cached and whether anything is encrypted, printed with every run.
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
    # Only DOWNGRADE a success: a killed query never reaches the end marker either, and the verdict
    # needs timeout(1)'s 124 and the signals' 130/143 as they are.
    if [ "$fpga_rc" = 0 ] && ! grep -qF "$END_MARK" "$FPGA_RAW"; then
        fpga_rc=1
    fi

}

# --- CPU --------------------------------------------------------------------------------
run_cpu() {
    cpu_file=$(mktemp)
    { echo "$SETUP"
      # --cpu-threads overrides --threads for the CPU side only. DuckDB's HTTP concurrency comes
      # from its threads, so at threads=1 its parquet reader issues range reads nearly serially,
      # while the FPGA path keeps many requests in flight from one thread.
      # 0 means "leave DuckDB's own default", i.e. every core -- SET threads=0 is not valid.
      if [ -n "${CPU_THREADS:-}" ] && [ "${CPU_THREADS}" != 0 ]; then
          echo "SET threads=$CPU_THREADS;"
      elif [ "${CPU_THREADS:-}" = 0 ]; then
          echo "RESET threads;"
      fi
      # The metadata cache is httpfs's and applies to this side only; --cache decides it.
      echo "LOAD httpfs; SET enable_http_metadata_cache=$CPU_META_CACHE;"; views_cpu
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
            if ($0 ~ /\[(oasis-http|oasis|httpfpga)\]/) next
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
        while read -r q secs; do P_S[${q#q}]=$secs; P_RC[${q#q}]=0; done 2>/dev/null < "$PHASE_CACHE/durations"
        while read -r q secs; do C_S[${q#q}]=$secs; C_RC[${q#q}]=0; done 2>/dev/null < "$CPU_CACHE/durations"
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
            # Keep the raw output of ANY failure in TRACE_DIR, outside the phase cache (a mktemp -d
            # removed on exit), so it survives a run that does not complete.
            if [ "$fpga_rc" != 0 ]; then
                cp "$FPGA_RAW" "$TRACE_DIR/oasis-q$n-fpga-raw.txt"
                echo "    rc=$fpga_rc -- trace kept: $TRACE_DIR/oasis-q$n-fpga-raw.txt"
                grep -E 'oasis-http|stalled|Error|rror' "$FPGA_RAW" | tail -6 | sed 's/^/      /'
            fi
            if [ "$fpga_rc" = 124 ]; then
                # Keep the output: the raw file is a mktemp the next query overwrites. With
                # OASIS_HTTP_DEBUG=1 it holds the per-batch lane state right up to the moment the query
                # stopped, which is otherwise unreadable -- the wedged process still owns the vFPGA.
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
# would treat a failed session as 22 completed queries -- and because both sides then hold the SAME
# error text, `cmp` would match and report every query PASS.
#
# Detected per query rather than by gating on the session rc: a session that dies on q22 still
# measured q1..q21 correctly.
query_errored() {   # $1 = captured rows file
    [ -s "$1" ] || return 1
    grep -qE '^[A-Za-z][A-Za-z ]*Error: ' "$1"
}

# Replays what phase 1 measured.
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

    # The second reader gets the server's page cache warm, so the order is a measurement choice.
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
            echo "  The [oasis-http] lines name each lane's state and the stall flags (dirty_abort: a lane went fatal)."
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
        # Keep the whole thing and print the error lines once: 60 characters rarely name the cause.
        cp "$CPU_RAW" "$TRACE_DIR/oasis-q$n-cpu-error.txt"
        if [ "$SKIP" -eq 0 ]; then
            echo "         full error kept: $TRACE_DIR/oasis-q$n-cpu-error.txt"
            sed -n '/rror\|xception\|xtension/p' "$CPU_RAW" | head -6 | sed 's/^/         | /'
            # Only when the failure IS about the extension, not e.g. an unreachable server.
            if grep -qi 'extension' "$CPU_RAW"; then cat <<'HINT'
         The baseline needs httpfs, which extension/extension_config.cmake builds into this shell;
         if LOAD httpfs fails, rebuild the extension (make in extension/). INSTALL httpfs cannot
         stand in for it: this duckdb is one commit past v1.5.2, so no published httpfs binary
         matches it, and the v1.5.2 one corrupts rather than fails (TableFunction differs).
HINT
            fi
        fi
        SKIP=$((SKIP+1)); continue
    fi
    # 130 = SIGINT, 143 = SIGTERM: killed by hand while still running, not a failure of the query.
    # The interrupt leaves the handler mid-transfer, so the board needs a reprogram before the next run.
    if [ "$fpga_rc" = 130 ] || [ "$fpga_rc" = 143 ]; then
        printf '%-5s %-8s %9s %9s %10s  %s\n' "q$n" "INTERRUPTED" "$fpga_s" "$cpu_s" "${hw_mib:--}" \
            "killed by hand while still running -- not a failure"
        echo "         the handler was mid-transfer when it died: reprogram before the next run."
        FAIL=$((FAIL+1)); FAILED+=("q$n"); break
    fi
    if [ "$fpga_rc" != 0 ]; then
        printf '%-5s %-8s %9s %9s %10s  %s\n' "q$n" "ERROR" "$fpga_s" "$cpu_s" "${hw_mib:--}" \
            "$(tr '\n' ' ' < "$FPGA_RAW" | cut -c1-70)"
        # Keep the whole thing: 70 characters name neither the exception nor the stage. The tail is
        # where the handler state and the stall flags are.
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
        # letting a 0.00 look like a failure. Only when a per-query hw_MiB exists: in
        # --single-session there is ONE profiler window for all queries, so hw_mib is blank.
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
    cpu_threads_used=${THREADS:-all cores}
    [ -n "${CPU_THREADS:-}" ] && cpu_threads_used=$CPU_THREADS
    [ "$cpu_threads_used" = 0 ] && cpu_threads_used="all cores"
    printf '   CPU  %8.2f s   (threads=%s, stock DuckDB)\n' "$CPU_TOTAL" "$cpu_threads_used"
    awk -v f="$FPGA_TOTAL" -v c="$CPU_TOTAL" 'BEGIN{
        if (f <= 0) exit
        r = c / f
        if (r >= 1) printf "   FPGA is %.2fx faster\n", r
        else        printf "   CPU is %.2fx faster\n", 1/r
    }'
    if [ -z "$THREADS" ] && [ -z "${CPU_THREADS:-}" ]; then
        echo "   NOTE: both sides used DuckDB's default thread count (every core). --threads N pins"
        echo "         both, --cpu-threads N the CPU side only."
    fi
    # The cache posture belongs with the total, not only in the banner 40 lines up: it changes what
    # the ratio MEANS, not just its value.
    case "$CACHE" in
        off)      echo "   CACHE: off on both sides -- every query re-fetched from the server. Parity." ;;
        metadata) echo "   CACHE: HTTP metadata only on the CPU side; no file data cached anywhere." ;;
        full)     echo "   CACHE: DuckDB defaults -- the CPU side served file data from RAM and the"
                  echo "          FPGA side could not. Quote this next to a --cache off run, never alone." ;;
    esac
    # Whichever side ran second read the same bytes out of the server's page cache. Say which that
    # was, because a ratio measured in one order is not the same claim as the other.
    if [ "$PHASES" = 1 ]; then
        echo "   ORDER: every FPGA query ran before any CPU query, so the CPU side read a warm"
        echo "          server cache -- by a whole phase, not by one query."
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

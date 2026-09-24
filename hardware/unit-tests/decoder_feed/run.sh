#!/usr/bin/env bash
# decoder_feed -- does the build-127 receive path keep all 4 decoders fed under a realistic origin?
#
# A throughput bench, not a liveness bench. It runs lane_drain_tb's `feed` scenario (the bench,
# its TOE / origin / host / card-DMA models and its byte-exact checker are lane_drain's; nothing is
# copied) on the build-127 shape: handler_slots at CSR revision 5, 32 connections, 4 decoders,
# 32 MiB slots (SLOT_LOG2 25), the shared card read channel through slot_rd_share, RD_MAX 16 KiB.
#
# WHAT IS MODELLED (all knobs are plusargs of the `feed` scenario, see lane_drain_tb.sv)
#   decoder   every decoder takes 1280 MB/s, byte-weighted (5.12 B/cycle at 250 MHz, one full
#             64-byte beat per 12.5 cycles) -- the measured intake with data waiting
#   origin    ONE request at a time per connection (Go net/http, i.e. MinIO): time to first byte
#             from when the previous response has left, then a per-connection byte rate
#               minio  TTFB 0.8..1.0 ms, 230 MB/s per connection
#               fast   TTFB 0.12..0.14 ms, 750 MB/s per connection (the sendfile origin)
#             sharing one 100 Gb/s wire (50 B/cycle), TCP segments of 4096 bytes
#   host      the software's single dispatcher: PlaceOnLane (least-occupied decoder under the lane
#             depth = conn depth x ceil(active conns / 4)), one chunk = one GET, pick_conn (free
#             connection round robin, else the decoder's tail below conn depth), 10 us of host work
#             per GET, 20 us pick poll, 100 us lane retry; GETs uniform 279..424 KiB (the board's
#             byte-weighted range)
#   card      card_dma_model with PIPELINED latency (+DMA_PIPE): 100 cycles request->data on
#             reads, 100 cycles last-beat->ack on writes (~0.4 us; an assumption, see REPORT)
#
# TIME SCALE: every host/origin TIME and every GET size is divided by SCALE; rates in bytes per
# cycle are not, so TTFB : transfer : decode keep their real proportions and the GB/s printed are
# real-scale. What does NOT scale is everything inside the FPGA (segment size, RD_MAX, card latency,
# the byte-serial header parse, the reader's per-response turnaround) -- those fixed costs weigh
# SCALE times more than on the board. Measured 2026-09-24: the turnaround is ~300-700 cycles per
# response, i.e. ~7% of a decoder at 1/10 scale against ~0.7% at 1/1. So the sweep defaults to
# SCALE=1 (real sizes and latencies; ~10-35 min per case, ~1-5 GB RSS) and 1/10 is for quick looks.
#
#   ./run.sh                     the sweep: origin {minio,fast} x conns {4,8,16,24,32} x depth
#                                {1,2,4}, plus sensitivity cases at 32 connections (see
#                                sweep_list), in parallel (JOBS, default 16), then the table
#   ./run.sh table               the table again, from the logs in runs/
#   ./run.sh one NAME [+args]    one case, e.g. ./run.sh one x ORIGIN=fast S2CONNS=32 HDEPTH=2
#   ./run.sh list FILE           the cases in FILE (lines "NAME PLUSARG..."), in parallel
#
# Exit status 1 if any case is not byte-exact / did not drain / set a sticky stall bit.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
LD="$ROOT/../lane_drain"
HDL="$ROOT/../../src/hdl/http_read"
MODEL="$ROOT/../card_dma/card_dma_model.sv"
JOBS="${JOBS:-16}"
SCALE="${SCALE:-1}"
SNAP=fd32_snap

if ! command -v xvlog >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source /tools/Xilinx/Vivado/2024.2/settings64.sh
fi

# The card path as the feed runs assume it (see the header). Overridable per case.
CARD=(DMA_PIPE DMA_RD_REQ_LAT=100 DMA_WR_ACK_LAT=100)

build() {
  mkdir -p "$ROOT/work"
  cd "$ROOT/work" || exit 1
  [ -d "xsim.dir/$SNAP" ] && [ "${REBUILD:-0}" = 0 ] && return 0
  rm -rf xsim.dir xvlog.pb xelab.pb .Xil 2>/dev/null || true
  local SKID=()
  [ -f "$HDL/axis_skid.sv" ] && SKID=("$HDL/axis_skid.sv")
  xvlog -sv "$LD/lynxTypes_stub.sv" \
        "$HDL/http_types.sv" "$HDL/axis_fifo.sv" "${SKID[@]}" \
        "$HDL/strip_http.sv" "$HDL/tcp_read.sv" \
        "$HDL/rx_dispatch.sv" "$HDL/tcp_init.sv" "$HDL/http_req_stream.sv" \
        "$HDL/axis_rewrite_last.sv" "$HDL/tx_arbiter.sv" "$HDL/handler_multi.sv" \
        "$HDL/slot_writer.sv" "$HDL/slot_reader.sv" "$HDL/slot_rd_share.sv" \
        "$HDL/handler_slots.sv" "$MODEL" \
        "$LD/lane_drain_tb.sv" > xvlog.log 2>&1 || { tail -40 xvlog.log; exit 1; }
  xelab -debug typical -timescale 1ns/1ps -top lane_drain_tb -snapshot "$SNAP" \
        -generic_top NUM_CONNS=32 -generic_top NUM_DEC=4 -generic_top DUT_SLOTS=1 \
        -generic_top CSR_REV=5 -generic_top SLOT_LOG2=25 \
        > "xelab_$SNAP.log" 2>&1 || { tail -30 "xelab_$SNAP.log"; exit 1; }
}

# run_case NAME plusarg...   -> runs/NAME.log
run_case() {
  local name="$1"; shift
  local d="$ROOT/runs/$name"
  mkdir -p "$d"
  # A private COPY of the snapshot, not a link: xsim -R writes the run's plusargs into
  # xsim.dir/<snap>/xsim_script.tcl, so two runs sharing one xsim.dir race and one of them runs
  # with the other's arguments (it happened). The snapshot is 2 MB.
  rm -rf "$d/xsim.dir"; cp -r "$ROOT/work/xsim.dir" "$d/xsim.dir"
  # $value$plusargs takes the FIRST match, so a case's own SCALE= / card settings go first.
  local a=(-testplusarg SCEN=feed); local p
  for p in "$@"; do a+=(-testplusarg "$p"); done
  [[ " $* " == *" SCALE="* ]] || a+=(-testplusarg "SCALE=$SCALE")
  for p in "${CARD[@]}"; do a+=(-testplusarg "$p"); done
  ( cd "$d" && xsim "$SNAP" -R -log "$ROOT/runs/$name.log" "${a[@]}" > /dev/null 2>&1 )
  rm -rf "$d"
  # one summary line per case
  verdict "$ROOT/runs/$name.log" "$name"
}

verdict() { # log name
  local log="$1" name="$2" v fv
  v="$(grep -E "^lane_drain_tb 'feed'" "$log" | tail -1 | sed 's/^[^:]*: //')"
  fv="$(grep -E '^FEEDVERDICT' "$log" | tail -1 | sed 's/^FEEDVERDICT //')"
  if grep -qE '^(slot_writer|card_dma_model): FAIL' "$log"; then v="FAIL (RTL/model assertion) $v"; fi
  printf '%-28s %-60s %s\n' "$name" "${v:-no verdict}" "${fv:-}"
}

table() {
  python3 - "$ROOT/runs" <<'EOF'
import glob, os, re, sys
rows = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], '*.log'))):
    t = open(f, errors='replace').read()
    m = re.search(r'^FEEDRESULT (.*)$', t, re.M)
    if not m:
        continue
    kv = dict(x.split('=', 1) for x in m.group(1).split())
    v = re.findall(r"^lane_drain_tb 'feed'[^:]*: (.*)$", t, re.M)
    kv['ok'] = 'ok' if v and v[-1].startswith('PASS') else 'FAIL'
    kv['name'] = os.path.basename(f)[:-4]
    rows.append(kv)
key = lambda r: (r['origin'], int(r['scale']), int(r['conns']), int(r['depth']), r['name'])
rows.sort(key=key)
hdr = ('origin', 'scale', 'conns', 'dep', 'ldep', 'busy_min', 'mean', 'GB/s', 'ceil%', 'empty', 'switch',
       'rdpath', 'wrpath', 'hol', 'server', 'c.free', 'c.wait', 'c.held', 'h.nolane', 'h.noconn', 'h.noadm',
       'ok', 'case')
print(' '.join('%8s' % h for h in hdr))
for r in rows:
    print(' '.join('%8s' % x for x in (r['origin'], '1/' + r['scale'], r['conns'], r['depth'], r['ldepth'],
                   r['busy_min'], r['busy_mean'], r['gbps'], r['ceil'], r['empty'], r['switch'],
                   r['rdpath'], r['wrpath'], r['hol'], r['server'], r['cfree'], r['cwait'], r['cheld'],
                   r['hnolane'], r['hnoconn'], r.get('hnoadm', '-'), r['ok'], r['name'])))
EOF
}

sweep_list() {
  local o c d
  # the big ones first, so the long runs start early
  for c in 32 24 16 8 4; do
    for o in minio fast; do
      for d in 1 2 4; do
        if [ "$c" = 32 ] && [ "$d" = 2 ]; then
          echo "$o-c$c-d$d ORIGIN=$o S2CONNS=$c HDEPTH=$d FEEDTRACE=60"
        else
          echo "$o-c$c-d$d ORIGIN=$o S2CONNS=$c HDEPTH=$d"
        fi
      done
    done
  done
  # sensitivity, all at 32 connections and conn depth 2
  for o in minio fast; do
    echo "sens-$o-card400 ORIGIN=$o S2CONNS=32 HDEPTH=2 DMA_RD_REQ_LAT=400 DMA_WR_ACK_LAT=400"
    echo "sens-$o-small ORIGIN=$o S2CONNS=32 HDEPTH=2 GETMIN=16384 GETMAX=65536"
    echo "sens-$o-s10 ORIGIN=$o S2CONNS=32 HDEPTH=2 SCALE=10 FEEDTRACE=40"
  done
  echo "sens-minio-overlap ORIGIN=minio S2CONNS=32 HDEPTH=2 SRVOVERLAP"
  echo "sens-minio-hdr200 ORIGIN=minio S2CONNS=32 HDEPTH=2 HDRBYTES=200"
}

case "${1:-sweep}" in
  table) table; exit 0 ;;
  one)
    shift; name="$1"; shift
    build
    mkdir -p "$ROOT/runs"
    run_case "$name" "$@"
    grep -E '^  == feed|^     |^  feed:|^FEED' "$ROOT/runs/$name.log"
    grep -qE "^lane_drain_tb 'feed'[^:]*: PASS" "$ROOT/runs/$name.log" && \
      ! grep -qE '^(slot_writer|card_dma_model): FAIL' "$ROOT/runs/$name.log"
    exit $? ;;
  sweep|list)
    if [ "$1" = list ]; then LIST="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; fi
    build
    mkdir -p "$ROOT/runs"
    export -f run_case verdict
    export ROOT SNAP SCALE
    export CARD_S="${CARD[*]}"
    if [ "$1" != list ]; then LIST="$ROOT/runs/sweep.list"; sweep_list > "$LIST"; : > "$ROOT/runs/sweep.verdicts"; fi
    # shellcheck disable=SC2016
    xargs -P "$JOBS" -L 1 bash -c 'CARD=($CARD_S); run_case "$@"' _ < "$LIST" \
      | tee -a "$ROOT/runs/sweep.verdicts"
    echo
    table
    if grep -vqE '^\S+\s+PASS' "$ROOT/runs/sweep.verdicts"; then exit 1; fi
    exit 0 ;;
  *) echo "usage: $0 [sweep|table|list FILE|one NAME [+plusargs]]"; exit 2 ;;
esac

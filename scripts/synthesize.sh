#!/bin/bash

script_dir="$(cd "$(dirname "$0")" && pwd)"

cmake_args=()
decoders=1
enable_http_multi=0
enable_http=0
enable_perf_ila=0
enable_http_slots=0
conns=0
build_num=0
while [ $# -gt 0 ]; do
    case "$1" in
        --http) enable_http=1 ;;
        --no-rdma) cmake_args+=(-DENABLE_RDMA=OFF) ;;
        --multi) enable_http_multi=1 ;;
        # Per-connection receive slots in HBM (ADR-5): rx_dispatch -> slot_writer -> one card slot
        # per TCP connection (the 1 GiB slot page split N ways) -> one slot_reader per decoder.
        # Needs --multi. N is the connection count, --decoders..32: equal to --decoders is stage 1,
        # more is stage 2 (CSR revision 5, host-placed connections). Giving it turns the mode on, so
        # `--conns 4` alone is enough -- there is no separate --slots flag to forget.
        #
        # This is the flag that sets EN_MEM, which changes the SHELL (N_CARD_AXI+1 more cdma engines
        # and HBM crossbar ports) and not just the user region. Do not expect build-119's timing.
        --conns) enable_http_slots=1; conns="$2"; shift ;;
        --conns=*) enable_http_slots=1; conns="${1#*=}" ;;
        # Add the 42-probe TCP/HTTP performance ILA back. OFF by default since it costs ~13.2k
        # LUTs and ~114.5 BRAM in the user region -- affordable at 1-2 lanes, not at 4 (build-110
        # missed timing at WNS -7.43 ns carrying it). Use it to debug the receive path, not to
        # produce a bitstream anyone will measure.
        --perf-ila) enable_perf_ila=1 ;;
        # Name the build directory build-N instead of the next free number. For a second checkout
        # (git worktree) whose hardware/ has no build history, so its build carries the number the
        # log and the board notes will refer to. Refuses an existing directory like the default.
        --build-num) build_num="$2"; shift ;;
        --build-num=*) build_num="${1#*=}" ;;
        --decoders) decoders="$2"; shift ;;
        --decoders=*) decoders="${1#*=}" ;;
        # Make the advertised TCP receive window match the buffer that actually exists.
        #
        # NO LONGER THE FIX IT WAS. This existed because the stack over-promised: WINDOW_BITS = 18
        # advertised 262,144 bytes while every session shared one axis_data_fifo_512_d1024
        # (tcp_stack.sv:681) holding 65,536. rx_engine decides whether to accept a segment from rxSar
        # pointer arithmetic, not from the FIFO fill level -- the check that would have used the real
        # level is commented out at rx_engine.cpp:1123 -- so the overflow was dropped and recovered
        # by go-back-N. Turning scaling OFF made the promise honest by shrinking it to 65,536.
        #
        # Since build-95 the fifo is sized to the window instead, which fixes the same problem in the
        # direction that helps: they now match at 1 MiB (WINDOW_SCALE_BITS = 4, fifo 16384 deep).
        # Passing this flag today would drop the window to 64 KiB and cap the largest ranged GET at
        # a sixteenth of what the hardware can hold -- which, since a GET costs ~1.4 ms of
        # object-store latency whatever its size, is directly a sixteenth of the throughput.
        # Keep it only for bisecting a receive-path fault.
        --no-window-scaling) cmake_args+=(-DTCP_STACK_WINDOW_SCALING_EN=0) ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

if [ "$enable_http" -eq 1 ]; then
    cmake_args+=(-DENABLE_HTTP=ON -DENABLE_RDMA=OFF)
fi
cmake_args+=(-DN_DECODERS="$decoders")
# One TCP session per decoder lane. Needs --http; the build fails loudly otherwise.
cmake_args+=(-DENABLE_HTTP_MULTI="$([ "$enable_http_multi" = 1 ] && echo ON || echo OFF)")
cmake_args+=(-DENABLE_PERF_ILA="$([ "$enable_perf_ila" = 1 ] && echo ON || echo OFF)")
# Per-connection HBM slots. OFF unless --conns was given, so a plain `--http --multi` build is
# byte-for-byte the build-119 configuration.
cmake_args+=(-DENABLE_HTTP_SLOTS="$([ "$enable_http_slots" = 1 ] && echo ON || echo OFF)")
cmake_args+=(-DN_HTTP_CONNS="$conns")

pushd hardware

# Next build directory: highest existing number + 1.
#
# The glob matches TWO OR MORE digits. It used to be `build-[0-9][0-9]`, exactly two, so once
# build-100 existed it was invisible: the scan found build-99, computed 100, failed to mkdir a
# directory that already existed -- and then carried on regardless, reconfiguring and REBUILDING the
# existing build-100 in place. Six hours of synthesis landed on top of an artifact someone might
# still have been testing, under a name that no longer described it.
n=0
for d in build-[0-9][0-9]*; do
    [ -d "$d" ] || continue
    num="${d#build-}"
    case "$num" in
        ''|*[!0-9]*) continue ;;   # skip build-tmp and friends
    esac
    [ "$((10#$num))" -gt "$n" ] && n=$((10#$num))
done
build_dir="$PWD/build-$((n + 1))"
if [ "$build_num" -gt 0 ]; then
    build_dir="$PWD/build-$build_num"
fi
echo Building bitstream in hardware/$build_dir...

# Fatal, not a warning. Continuing past a collision is what overwrote build-100.
mkdir "$build_dir" || { echo "refusing to build into an existing directory: $build_dir" >&2; exit 1; }
cmake -S . -B "$build_dir" "${cmake_args[@]}"

util_dir="$script_dir/util"
build_cmd="cmake --build $build_dir --target project --target bitgen &> $build_dir/bitgen.log"
report_cmd="$util_dir/generate_reports.sh $build_dir"
# Analyze, save to analysis.txt, and email it (email needs BOT_GMAIL_USER,
# BOT_GMAIL_PASSWORD and BOT_RECIPIENT_EMAIL in the environment; skipped if unset).
analyze_cmd="$util_dir/analyze_reports.sh $build_dir | tee $build_dir/analysis.txt | { $util_dir/send_report_email.sh || echo 'report email skipped/failed (check BOT_GMAIL_USER, BOT_GMAIL_PASSWORD, BOT_RECIPIENT_EMAIL)'; }"
tmux new-session -d -s "bitgen-$build_dir" "$build_cmd && $report_cmd && $analyze_cmd"

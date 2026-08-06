#!/bin/bash

script_dir="$(cd "$(dirname "$0")" && pwd)"

cmake_args=()
decoders=1
enable_http=0
while [ $# -gt 0 ]; do
    case "$1" in
        --http) enable_http=1 ;;
        --no-rdma) cmake_args+=(-DENABLE_RDMA=OFF) ;;
        --decoders) decoders="$2"; shift ;;
        --decoders=*) decoders="${1#*=}" ;;
        # Make the advertised TCP receive window match the buffer that actually exists.
        #
        # WINDOW_SCALING_EN=1 gives WINDOW_BITS = 16 + WINDOW_SCALE_BITS = 18, so the TOE tells the
        # peer it can accept 1<<18 = 262,144 bytes. With RX_DDR_BYPASS_EN=1 there are no per-session
        # buffers at all -- every session shares one axis_data_fifo_512_d1024 (tcp_stack.sv:681),
        # which is 1024 x 64 B = 65,536 bytes. The stack advertises 4x what it has, and rx_engine
        # decides whether to accept a segment from rxSar pointer arithmetic rather than from the
        # FIFO fill level; the check that would have used the real level is commented out at
        # rx_engine.cpp:1123.
        #
        # Setting this to 0 gives WINDOW_BITS = 16 and BUFFER_SIZE = 65,536 -- exactly the FIFO. It
        # does not make the buffer bigger; it stops the stack over-promising, so a peer that fills
        # the window gets flow-controlled instead of having the overflow dropped and recovered by
        # go-back-N. Measured motivation: responses up to 32 KiB scale linearly, 64 KiB ones cost
        # ~10 ms extra each, at every pipeline depth (scripts/sweep.sh).
        --no-window-scaling) cmake_args+=(-DTCP_STACK_WINDOW_SCALING_EN=0) ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

if [ "$enable_http" -eq 1 ]; then
    cmake_args+=(-DENABLE_HTTP=ON -DENABLE_RDMA=OFF)
fi
cmake_args+=(-DN_DECODERS="$decoders")

pushd hardware

# Finds the build directory with the highest number and starts the synthesis in a new directory with that number + 1
n=0
for d in build-[0-9][0-9]; do
    [ -d "$d" ] || continue
    num="${d#build-}"
    [ "$((10#$num))" -gt "$n" ] && n=$((10#$num))
done
build_dir="$PWD/build-$(printf '%02d' $((n + 1)))"
echo Building bitstream in hardware/$build_dir...

mkdir "$build_dir"
cmake -S . -B "$build_dir" "${cmake_args[@]}"

util_dir="$script_dir/util"
build_cmd="cmake --build $build_dir --target project --target bitgen &> $build_dir/bitgen.log"
report_cmd="$util_dir/generate_reports.sh $build_dir"
# Analyze, save to analysis.txt, and email it (email needs BOT_GMAIL_USER,
# BOT_GMAIL_PASSWORD and BOT_RECIPIENT_EMAIL in the environment; skipped if unset).
analyze_cmd="$util_dir/analyze_reports.sh $build_dir | tee $build_dir/analysis.txt | { $util_dir/send_report_email.sh || echo 'report email skipped/failed (check BOT_GMAIL_USER, BOT_GMAIL_PASSWORD, BOT_RECIPIENT_EMAIL)'; }"
tmux new-session -d -s "bitgen-$build_dir" "$build_cmd && $report_cmd && $analyze_cmd"

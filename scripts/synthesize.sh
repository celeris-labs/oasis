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

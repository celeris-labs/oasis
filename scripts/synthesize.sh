#!/bin/bash

script_dir="$(cd "$(dirname "$0")" && pwd)"
orig_args="$*"

cmake_args=()
decoders=1
enable_http=0
enable_toe_buffer=0
build_num=0
while [ $# -gt 0 ]; do
    case "$1" in
        --http) enable_http=1 ;;
        --no-rdma) cmake_args+=(-DENABLE_RDMA=OFF) ;;
        # The TOE keeps the receive buffer itself (TCP_STACK_RX_DDR_BYPASS_EN = 0): a 1 MiB ring per
        # session in the TCP stack's HBM channel, shared with the transmit rings through Coyote's
        # tcp_mem_mux (hardware/patches/0008), instead of one 1 MiB rx FIFO for all sessions. Needs
        # --http. Changes the SHELL: the TOE's non-bypass HLS, the mux, and the rx FIFO's 256 BRAM
        # gone. EN_MEM stays 0.
        --toe-buffer) enable_toe_buffer=1 ;;
        # Name the build directory build-N instead of the next free number. For a second checkout
        # (git worktree) whose hardware/ has no build history, so its build carries the number the
        # log and the board notes will refer to. Refuses an existing directory like the default.
        --build-num) build_num="$2"; shift ;;
        --build-num=*) build_num="${1#*=}" ;;
        --decoders) decoders="$2"; shift ;;
        --decoders=*) decoders="${1#*=}" ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

if [ "$enable_http" -eq 1 ]; then
    cmake_args+=(-DENABLE_HTTP=ON -DENABLE_RDMA=OFF)
fi
cmake_args+=(-DN_DECODERS="$decoders")
# TOE receive rings in card memory. OFF unless --toe-buffer, so every other invocation configures
# exactly as before.
cmake_args+=(-DENABLE_HTTP_TOE_BUFFER="$([ "$enable_toe_buffer" = 1 ] && echo ON || echo OFF)")

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
cmake -S . -B "$build_dir" "${cmake_args[@]}" || { echo "cmake configure failed (see above); nothing launched" >&2; exit 1; }

# PROVENANCE.txt: what this directory was configured from. Operator notes go below the header.
# Only plumbing commands here -- no `git status` (the main tree's NFS checkout hangs on it).
{
    echo "configured : $(date '+%Y-%m-%d %H:%M %Z') on $(hostname) by $(id -un)"
    echo "command    : scripts/synthesize.sh $orig_args"
    echo "flags      : http=$enable_http decoders=$decoders toe_buffer=$enable_toe_buffer"
    echo "cmake args : ${cmake_args[*]}"
    echo "oasis      : $(git -C "$script_dir/.." rev-parse HEAD 2>/dev/null)" \
         "($(git -C "$script_dir/.." rev-parse --abbrev-ref HEAD 2>/dev/null))"
    echo "coyote     : $(git -C "$script_dir/../parcore/libstf/coyote" rev-parse HEAD 2>/dev/null)" \
         "uncommitted:$(git -C "$script_dir/../parcore/libstf/coyote" diff --shortstat -- . ':!hw/services/network' 2>/dev/null)"
    echo "network    : $(git -C "$script_dir/../parcore/libstf/coyote/hw/services/network" rev-parse HEAD 2>/dev/null)" \
         "uncommitted:$(git -C "$script_dir/../parcore/libstf/coyote/hw/services/network" diff --shortstat 2>/dev/null)"
    echo "TCP_STACK_RX_DDR_BYPASS_EN = $(grep -E '^TCP_STACK_RX_DDR_BYPASS_EN:' "$build_dir/CMakeCache.txt" | cut -d= -f2)"
} > "$build_dir/PROVENANCE.txt"

util_dir="$script_dir/util"
build_cmd="cmake --build $build_dir --target project --target bitgen &> $build_dir/bitgen.log"
report_cmd="$util_dir/generate_reports.sh $build_dir"
# Analyze, save to analysis.txt, and email it (email needs BOT_GMAIL_USER,
# BOT_GMAIL_PASSWORD and BOT_RECIPIENT_EMAIL in the environment; skipped if unset).
analyze_cmd="$util_dir/analyze_reports.sh $build_dir | tee $build_dir/analysis.txt | { $util_dir/send_report_email.sh || echo 'report email skipped/failed (check BOT_GMAIL_USER, BOT_GMAIL_PASSWORD, BOT_RECIPIENT_EMAIL)'; }"
tmux new-session -d -s "bitgen-$build_dir" "$build_cmd && $report_cmd && $analyze_cmd"

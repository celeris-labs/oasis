#!/bin/bash

script_dir="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat <<'EOF'
Usage: synthesize.sh [options]

Configure and launch a Vivado bitstream build for the OASIS hardware in a
fresh hardware/build-NN directory (run detached in a tmux session). When the
build finishes, reports are generated, analyzed, and emailed (if configured).

Options:
  --no-rdma            Disable the Coyote RDMA stack (default: enabled).
  --decoders N         Number of ColumnChunkDecoders (default: 1).
  --device NAME        Target FPGA device: u55c, v80, ... (default: u55c).
  --v80                Shortcut for --device v80 (Alveo V80).
  -h, --help           Show this help message and exit.

Examples:
  synthesize.sh                       # u55c, RDMA on, 1 decoder
  synthesize.sh --v80 --decoders 4    # Alveo V80 with 4 decoders
  synthesize.sh --no-rdma --device u55c
EOF
}

cmake_args=()
decoders=1
device=u55c
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --no-rdma) cmake_args+=(-DENABLE_RDMA=OFF) ;;
        --decoders) decoders="$2"; shift ;;
        --decoders=*) decoders="${1#*=}" ;;
        --v80) device=v80 ;;
        --device) device="$2"; shift ;;
        --device=*) device="${1#*=}" ;;
        *) echo "Unknown argument: $1" >&2; echo "" >&2; usage >&2; exit 1 ;;
    esac
    shift
done
cmake_args+=(-DN_DECODERS="$decoders" -DFDEV_NAME="$device")

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

# On build failure, have Claude summarize why from bitgen.log and email that.
fail_cmd="$util_dir/summarize_build_failure.sh $build_dir | REPORT_SUBJECT='[OASIS $(basename $build_dir)] build FAILED' $util_dir/send_report_email.sh || echo 'failure email skipped/failed (check BOT_GMAIL_USER, BOT_GMAIL_PASSWORD, BOT_RECIPIENT_EMAIL)'"

tmux new-session -d -s "bitgen-$build_dir" "if $build_cmd; then $report_cmd && $analyze_cmd; else $fail_cmd; fi"

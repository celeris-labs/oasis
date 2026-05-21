#!/bin/bash

cmake_args=()
for arg in "$@"; do
    case "$arg" in
        --no-rdma) cmake_args+=(-DENABLE_RDMA=OFF) ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

pushd hardware

# Finds the build directory with the highest number and starts the synthesis in a new directory with that number + 1
n=0
for d in build-[0-9][0-9]; do
    [ -d "$d" ] || continue
    num="${d#build-}"
    [ "$((10#$num))" -gt "$n" ] && n=$((10#$num))
done
build_dir="build-$(printf '%02d' $((n + 1)))"
echo Building bitstream in hardware/$build_dir...

mkdir "$build_dir"
cmake -S . -B "$build_dir" "${cmake_args[@]}"
tmux new-session -d -s "bitgen-$build_dir" "cmake --build $build_dir --target project --target bitgen &> $build_dir/bitgen.log && $(dirname "$0")/generate_reports.sh $build_dir"

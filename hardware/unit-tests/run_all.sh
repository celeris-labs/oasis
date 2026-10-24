#!/usr/bin/env bash
# Every bench, one after the other: ./run_all.sh [bench ...]. Exit status 1 if any bench failed.
#
# The RTL benches need only Vivado's xsim. tcp_mem_mux needs patch 0008 in the Coyote submodule and
# toe_csim needs Vitis HLS and patch 0007 in the network submodule (hardware/patches/apply.sh).
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
benches=("$@")
[ ${#benches[@]} -gt 0 ] || benches=(strip_http tcp_read http_req_stream handler_multi lane_drain tcp_mem_mux toe_csim)
failed=()
for b in "${benches[@]}"; do
  echo "=== $b"
  if "$ROOT/$b/run.sh"; then echo "=== $b: PASS"; else echo "=== $b: FAIL"; failed+=("$b"); fi
done
if [ ${#failed[@]} -gt 0 ]; then
  echo "run_all: ${#failed[@]} of ${#benches[@]} bench(es) failed: ${failed[*]}"
  exit 1
fi
echo "run_all: all ${#benches[@]} bench(es) passed"

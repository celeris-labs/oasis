#!/usr/bin/env bash
# Starts oasis_s3_server on the extension's Parquet fixtures, then runs the SQL tests against it.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
server="$here/../rdma_server/build/oasis_s3_server"
port=9200

"$server" --port "$port" --listen 127.0.0.1 --capacity 2G --preload "oasis=$here/../extension/data" &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null || true' EXIT

for _ in $(seq 100); do
    curl -sf -o /dev/null "http://127.0.0.1:$port/" && break
    sleep 0.1
done

cd "$here"
# The runner exits 0 even if it skipped everything, so insist on seeing the pass.
output="$(./build/release/test/unittest "test/sql/*" 2>&1)" || { echo "$output"; exit 1; }
echo "$output"
grep -q "All tests passed" <<< "$output"

#!/usr/bin/env bash
#
# Where is the HOST stuck? Run this while a query is wedged.
#
# The decoder profile says out_stalled >> out_starved: the decoder has produced results nobody is
# collecting, so the blockage is above the hardware. Everything downstream of that -- decoder input
# refusing, the rx fifo filling, the advertised window crossing the 24000-byte floor, MinIO's
# go-back-N storm -- follows from it. A backtrace names the line the host is blocked on, which no
# CSR can.
#
#   ./scripts/util/hang_bt.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT=${OUT:-$ROOT/.traces/hang-bt.txt}
mkdir -p "$(dirname "$OUT")"

PID=$(pgrep -f 'release/duckdb' | head -1)
[ -n "$PID" ] || { echo "no duckdb running -- run this WHILE it is wedged"; exit 1; }
echo "duckdb pid $PID -> $OUT"

{
  echo "=== $(date) pid=$PID ==="
  echo "--- /proc status ---"
  grep -E '^(State|Threads)' "/proc/$PID/status" 2>/dev/null
  echo "--- per-thread wchan (what each thread sleeps on) ---"
  for t in /proc/$PID/task/*; do
    printf '%-8s %-18s %s\n' "$(basename "$t")" \
      "$(cat "$t/comm" 2>/dev/null)" "$(cat "$t/wchan" 2>/dev/null)"
  done
  echo
  if command -v gdb >/dev/null; then
      echo "--- full backtraces ---"
      gdb -p "$PID" -batch -ex "set pagination off" -ex "thread apply all bt" 2>&1
  else
      echo "gdb not installed -- wchan above is all we get. 'sudo apt install gdb' for the rest."
  fi
} > "$OUT" 2>&1

echo "wrote $OUT"
echo "--- threads not sleeping in the usual poll/futex ---"
grep -vE 'futex|poll|epoll|hrtimer|0x0|^$' "$OUT" | head -25

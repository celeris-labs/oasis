#!/bin/bash
# Summarize why a Vivado bitstream build failed by feeding bitgen.log to Claude.
#
# Usage: summarize_build_failure.sh <build_dir>
#
# Prints a short human-readable summary to stdout. Falls back to the raw log tail
# if the `claude` CLI is unavailable or errors, so the failure email is never empty.
set -u

build_dir="${1:?usage: summarize_build_failure.sh <build_dir>}"
log="$build_dir/bitgen.log"

if [ ! -r "$log" ]; then
    echo "Bitstream build FAILED in hardware/$build_dir (no readable bitgen.log)."
    exit 0
fi

# Last 400 lines is enough to capture the Vivado ERROR/CRITICAL WARNING context
# without overflowing the prompt; the real cause is almost always near the end.
tail_log=$(tail -n 400 "$log")

prompt="You are reviewing a failed Vivado FPGA bitstream build (OASIS hardware).
Below is the tail of bitgen.log. In a few sentences, explain why the build
failed: the root-cause error, the file/module/constraint involved if shown, and
the most likely fix. Be concise and concrete. Do not restate the whole log.

--- bitgen.log (last 400 lines) ---
$tail_log"

summary=$(printf '%s' "$prompt" | claude -p 2>/dev/null)

if [ -n "$summary" ]; then
    printf 'Bitstream build FAILED in hardware/%s\n\n' "$build_dir"
    printf 'Claude summary:\n%s\n\n' "$summary"
    printf -- '--- last 40 lines of bitgen.log ---\n%s\n' "$(tail -n 40 "$log")"
else
    # claude unavailable/failed: fall back to the raw tail so we still get a useful email.
    printf 'Bitstream build FAILED in hardware/%s (Claude summary unavailable)\n\n' "$build_dir"
    printf -- '--- last 100 lines of bitgen.log ---\n%s\n' "$(tail -n 100 "$log")"
fi

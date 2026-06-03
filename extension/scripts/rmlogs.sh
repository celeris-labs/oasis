#!/usr/bin/env bash
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

find "$dir" -maxdepth 1 -type f \( -name 'vivado*' -o -name 'hs_err_*' \) -print -delete

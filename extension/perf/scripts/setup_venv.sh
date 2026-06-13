#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

python3 -m venv .venv
source .venv/bin/activate

python -m pip install --upgrade pip
python -m pip install -r requirements.txt

python - <<'PY'
import duckdb
import pyarrow
import numpy

print("duckdb", duckdb.__version__)
print("pyarrow", pyarrow.__version__)
print("numpy", numpy.__version__)
PY

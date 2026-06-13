# OASIS Performance Experiments

This directory contains software-only performance experiments for estimating the upper-bound benefit of runtime filtering before DuckDB joins.

The first benchmark compares:

1. unfiltered probe table joined with build table
2. perfectly filtered probe table joined with build table

This models an ideal Bloom filter with 0% false positives and no filter runtime overhead. It is an upper bound for the possible downstream join speedup.

## Setup

```bash
cd extension
perf/scripts/setup_venv.sh

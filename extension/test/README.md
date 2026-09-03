# Testing the Oasis extension

The tests are [SQLLogicTests](https://duckdb.org/dev/sqllogictest/intro.html) under `sql/`, run by
DuckDB's unittest runner:

```bash
make test          # release build
make test_debug    # debug build
```

Both run the unittest binary from the extension root, so the fixture paths in the tests
(`data/...`) are relative to this directory's parent.

**These tests need the accelerator.** Loading the extension opens the FPGA context, so every file
starts with `require oasis` and fails at that line on a machine without a device. A simulation
build (`-DEN_SIMULATION=ON`, with `COYOTE_SIM_DIR` set) works too, but is slow enough that the
65 K-row fixtures take a while.

## The suites

| File | Covers |
| --- | --- |
| `sql/oasis.test` | Extension loads, `read_oasis` and `oasis_stream_profile` register, one end-to-end scan |
| `sql/oasis_scan.test` | Decode correctness per type and column count, projection pushdown, multi-row-group scans, composition with joins and aggregates |
| `sql/oasis_filter.test` | Zone-map pruning, row-level filtering, conjunction splitting, `filter_prune` |
| `sql/oasis_cpu_columns.test` | `BYTE_ARRAY` columns decoded on the CPU, alone and mixed with hardware columns |
| `sql/oasis_settings.test` | Extension settings and their validation, the stream profiler, bind-time errors |

## How the assertions are built

Two complementary styles, because either one alone leaves a gap:

- **Differential.** `read_oasis` and `read_parquet` must return the same multiset of rows for the
  same file. The hardware decoder and DuckDB's software reader are independent implementations, so
  any bit that differs shows up. Comparison is by multiset, not sequence: the scan parallelizes
  over row groups and does not preserve global row order.
- **Structural.** The fixtures were generated from closed-form relations — `data/mixed_small.parquet`
  is `c_int32 = 0..65535` with `c_int64 = 1e6·i`, `c_float = 0.5·i`, `c_double = 1.25·i`, in eight
  row groups of 8192 — so the tests can assert exact values without depending on `read_parquet` at
  all, and a failure says which column went wrong rather than just "something differs".

## The fixtures

`data/` holds the checked-in Parquet files. They are hand-generated, nothing in the repo
regenerates them, and the layout matters:

| File | Shape | Why it exists |
| --- | --- | --- |
| `int32.parquet`, `float32.parquet` | 1 col, 1000 rows | Single column, one type at a time |
| `test.parquet` | 1 INT64 col, 10000 rows | Single column, wider type |
| `float4_small/large.parquet` | 4 FLOAT cols, 1000 rows | Multi-column; `small` is uncompressed with small magnitudes, `large` is Snappy with values across the full exponent range |
| `mixed_int_small/large.parquet` | INT32/INT64/INT32/INT64, 1000 rows | Mixed widths in one row group, same small/large split |
| `mixed_small.parquet` | INT32/INT64/FLOAT/DOUBLE, 65536 rows, 8 row groups | All four fixed-width types, multi-group parallelism, and row-group boundaries that line up with round `c_int32` values so filters can target the zone-map path exactly |
| `huge.parquet` | 1 INT64 col, 21 M rows, 21 row groups | Not used by any test: its column chunks are `RLE_DICTIONARY`, which the ParCore decoder does not handle |

Fixtures that need a variable-length column, an unsupported type, or an unsupported codec are
written into `__TEST_DIR__` by the tests themselves rather than checked in. Note that this only
works while the fixed-width columns stay `PLAIN`-encoded — the decoder requires it, and DuckDB's
writer only avoids dictionary-encoding a column when its values are distinct enough.

## Known gaps

- **NULLs.** The hardware path does not read definition levels, so nothing here covers a
  fixed-width column containing NULLs. None of the fixtures have any.
- **`BOOLEAN`.** Mapped to `BYTE_T`, but Parquet stores booleans bit-packed rather than one byte
  per value. Untested, and no fixture exercises it.
- **`rdma://`.** Only the "not configured" error is covered; the read path needs a server.

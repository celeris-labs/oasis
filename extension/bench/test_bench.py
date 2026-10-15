#!/usr/bin/env python3
"""Tests of bench.py and the sweeps without the FPGA: a fake DuckDB CLI prints what the extension's does (the format
was taken from a real run), so the script generation, the parsing, the checks and the sweep bookkeeping are
exercised. Run: python test_bench.py (or pytest)."""

import os
import stat
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))

import bench

FAKE_CLI = r'''#!/usr/bin/env python3
import json, re, sys
mode = open(__file__ + ".mode").read().strip() if True else ""
sql = sys.stdin.read()
ncols = int(re.search(r"sum_c(\d+)", " ".join(re.findall(r"AS sum_c\d+", sql)[-1:])).group(1)) if "AS sum_c" in sql else 0
bloom = "oasis_runtime_bloom_filter = true" in sql
for line in sql.splitlines():
    if line.startswith(".print"):
        print(line.split(" ", 1)[1])
        if line.startswith(".print @@SETTINGS"):
            print(json.dumps([{"threads": 32, "oasis_runtime_bloom_filter": bloom, "duckdb_version": "v0.0.1"}]))
        if line.startswith(".print @@RESULT"):
            if mode == "wrong":
                res = {"n_rows": "999", "key_sum": "5"}
            else:
                res = {"n_rows": "1000", "key_sum": "5"}
            for i in range(1, ncols + 1):
                res[f"sum_c{i}"] = str(10 * i)
            print(json.dumps([res]))
        if line.startswith(".print @@PROFILE"):
            print(json.dumps([{"stream": "0", "in_handshakes_cycles": "1000", "in_starved_cycles": "100",
                               "in_stalled_cycles": "0", "in_idle_cycles": "900", "in_last_handshakes": "1",
                               "out_handshakes_cycles": "2000", "out_starved_cycles": "0",
                               "out_stalled_cycles": "0", "out_idle_cycles": "0", "out_last_handshakes": "1"},
                              {"stream": "1", "out_handshakes_cycles": "5"}]))
        if line.startswith(".print @@DP") and mode != "oldext":
            def seg(i, label, f, h, st, idle, oh):
                return {"segment": str(i), "label": label, "file": f, "in_handshakes_cycles": str(h),
                        "in_starved_cycles": str(st), "in_stalled_cycles": "0", "in_idle_cycles": str(idle),
                        "out_handshakes_cycles": str(oh), "out_starved_cycles": "0", "out_stalled_cycles": "0",
                        "out_idle_cycles": "0"}
            print(json.dumps([seg(0, "before_scan", "/x/build.parquet", 200, 10, 50, 300),
                              seg(1, "final", "/x/probe.parquet", 1000, 100, 900, 375)]))
        if line.startswith(".print @@QS"):
            print(json.dumps([{"total_query_ms": 10.0, "scan_only_ms": 2.0,
                               "scan_celeris_bloom_ms": 5.0 if bloom else None, "duckdb_bloom_ms": None,
                               "join_ms": 30.5}]))
        if line.startswith(".print @@BF") and bloom:
            print(json.dumps([{"run": "0",
                               "build": "{'cycles': 1001, 'idle_cycles': 1, 'stalled_cycles': 0, 'cmd_wait_cycles': 0, "
                                        "'beats': 1000}",
                               "probe": "{'cycles': 4000, 'idle_cycles': 2000, 'stalled_cycles': 0, "
                                        "'cmd_wait_cycles': 0, 'beats': 2000}",
                               "run_perf": "{'cycles': 6000, 'keys_in_beats': 2999, 'values_in_beats': 2000, "
                                           "'out_cycles': 4000, 'probe_start_cycles': 1000, 'out_bytes': 64000}",
                               "command_queue_overflowed": mode == "overflow"}]))
        if line.startswith(".print @@ST") and bloom:
            print(json.dumps([{"file": "/x/probe.parquet", "bloom": True, "wall_ms": 5.0},
                              {"file": "/x/build.parquet", "bloom": False, "wall_ms": 2.0}]))
'''


def make_fake(tmp, mode="ok"):
    path = Path(tmp) / "fake_duckdb"
    path.write_text(FAKE_CLI)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    Path(str(path) + ".mode").write_text(mode)
    return path


def dataset(columns):
    return SimpleNamespace(
        build_path=Path("/x/build.parquet"), probe_path=Path("/x/probe.parquet"), build_row_groups=[10],
        probe_row_groups=[10, 10], expected_rows=1000, expected_key_sum=5,
        expected_sums=[10 * i for i in range(1, columns + 1)], build_meta={}, probe_meta={})


def run(tmp, mode="ok", name="p", **params):
    params = {"ssize": 100, "rsize": 1000, "columns": 2, **params}
    return bench.run_benchmark(Path(tmp) / name, params, warmup=1, iterations=3, binary=make_fake(tmp, mode),
                               dataset=dataset(params["columns"]), quiet=True, lib_dir=tmp,
                               guard_device=False)


def load(folder):
    import yaml
    return yaml.safe_load((Path(folder) / "bench.yaml").read_text())


def test_script_and_measures():
    with tempfile.TemporaryDirectory() as tmp:
        folder = run(tmp, columns=2, threads=4, egress_gbps=6.0)
        sql = (folder / "run.sql").read_text()
        assert "SET threads = 4;" in sql and "SET oasis_emulated_egress_gbps = 6.0;" in sql
        # The hardware Bloom filter is on: DuckDB's own is off, and the other way round
        assert "SET oasis_runtime_bloom_filter = true;" in sql and "SET oasis_duckdb_bloom_filter = false;" in sql
        off = (run(tmp, name="off", runtime_bloom=False) / "run.sql").read_text()
        assert "SET oasis_runtime_bloom_filter = false;" in off and "SET oasis_duckdb_bloom_filter = true;" in off
        assert sql.count("@@ITER") == 4 and "sum(p.c2)" in sql and "sum(p.c3)" not in sql
        assert sql.index("read_oasis('/x/build.parquet')") < sql.index("read_oasis('/x/probe.parquet')")
        data = load(folder)
        assert data["benchmark"]["status"] == "ok"
        assert len(data["warmups"]) == 1 and len(data["iterations"]) == 3
        it = data["iterations"][0]
        assert it["host"]["query_ms"] == 10.0 and it["host"]["scan_ms"] == 7.0 and it["host"]["rest_ms"] == 3.0
        # 1000 beats * 64 B over 2000 cycles * 4 ns = 8 GB/s; excluding the idle cycles over 1100: 14.5 GB/s
        assert abs(it["decoder"]["in_gbps"] - 8.0) < 1e-9
        assert abs(it["decoder"]["in_gbps_excl_idle"] - 64000 / 4400) < 1e-9
        assert abs(it["decoder"]["out_gbps"] - 16.0) < 1e-9  # 375 beats in 375 cycles
        # probe in: (2999 + 2000 - 999 build key beats) * 64 B over the probe window 4000 - 1000 cycles (first
        # probe beat to the last output; the probe phase's own 4000 cycles, up to the host's END, are not used)
        assert abs(it["bloom"]["in_gbps"] - 4000 * 64 / 12000) < 1e-9
        assert abs(it["bloom"]["out_gbps"] - 64000 / 12000) < 1e-9
        assert it["decoder"]["scope"] == "probe" and it["decoder"]["segments"] == 2
        # The whole run: both segments added up (1200 + 150 + 0 + 50 cycles in, 300 + 2000 out)
        assert it["decoder_run"]["in"]["handshakes"] == 1200 and it["decoder_run"]["out"]["handshakes"] == 675
        assert it["checks"]["decoder_probe_out_bytes_ratio"] == 1.0
        assert data["parameters"]["threads"] == 4 and data["parameters"]["emulated_egress_gbps"] == 6.0


def test_contaminated_probe_segment_fails():
    with tempfile.TemporaryDirectory() as tmp:
        try:
            run(tmp, rsize=2000)  # The fake's segment holds the bytes of 1000 rows
        except bench.BenchmarkError as e:
            assert "does not cover exactly the probe scan" in str(e) or "wrong result" in str(e)
        else:
            raise AssertionError("expected a BenchmarkError")


def test_old_extension_without_decoder_segments():
    with tempfile.TemporaryDirectory() as tmp:
        it = load(run(tmp, mode="oldext"))["iterations"][0]
        assert it["decoder"]["scope"] == "run" and abs(it["decoder"]["in_gbps"] - 8.0) < 1e-9


def test_bloom_off():
    with tempfile.TemporaryDirectory() as tmp:
        data = load(run(tmp, runtime_bloom=False))
        it = data["iterations"][0]
        assert it["bloom"] is None and it["host"]["scan_ms"] == 2.0


def test_wrong_result_fails():
    with tempfile.TemporaryDirectory() as tmp:
        try:
            run(tmp, mode="wrong")
        except bench.BenchmarkError as e:
            assert "wrong result" in str(e)
        else:
            raise AssertionError("expected a BenchmarkError")
        assert load(Path(tmp) / "p")["benchmark"]["status"] == "failed"


def test_overflow_fails():
    with tempfile.TemporaryDirectory() as tmp:
        try:
            run(tmp, mode="overflow")
        except bench.BenchmarkError as e:
            assert "overflowed" in str(e)
        else:
            raise AssertionError("expected a BenchmarkError")


def test_refuses_overwrite_and_bad_params():
    with tempfile.TemporaryDirectory() as tmp:
        run(tmp)
        try:
            run(tmp)
        except bench.BenchmarkError as e:
            assert "already holds results" in str(e)
        else:
            raise AssertionError("expected a BenchmarkError")
        for bad in ({"rsize": 10, "ssize": 100}, {"rsize": 100, "ssize": 100}, {"columns": 5, "file_columns": 2}, {"matchratio": 2.0},
                    {"batchsize": 10, "numbatches": 2}):
            try:
                bench.complete_params(bad)
            except bench.BenchmarkError:
                continue
            raise AssertionError(f"accepted {bad}")


def test_timeout_stops_cli():
    with tempfile.TemporaryDirectory() as tmp:
        sleeper = Path(tmp) / "sleeper"
        sleeper.write_text("#!/bin/sh\nsleep 60\n")
        sleeper.chmod(0o755)
        try:
            bench.run_benchmark(Path(tmp) / "t", {"ssize": 1, "rsize": 2, "columns": 0}, warmup=0, iterations=1,
                                binary=sleeper, dataset=dataset(0), quiet=True, lib_dir=tmp, timeout=1.0,
                                guard_device=False)
        except bench.BenchmarkError as e:
            assert "did not finish" in str(e)
        else:
            raise AssertionError("expected a BenchmarkError")


def test_parse_skips_warnings():
    text = ("\x1b[90mWARNING:\nlogging\x1b[00m[]\n@@SETTINGS\n[{\"threads\":32}]\n@@ITER 0 warmup\n@@PROFILE\n[]\n"
            "@@END\n")
    parsed = bench.parse_output(text)
    assert parsed["complete"] and parsed["settings"]["threads"] == 32 and parsed["runs"][0]["kind"] == "warmup"


def test_sweep_bookkeeping():
    import sweep_lib
    import sweep_egress
    import sweep_columns
    assert sweep_egress.SWEEP.folder_of(0.0) == "egress_off" and sweep_egress.SWEEP.text(2.0) == "2"
    xs = sorted([0.0, 4.0, 1.0], key=sweep_egress.SWEEP.key)
    assert xs == [1.0, 4.0, 0.0]
    assert sweep_egress.SWEEP.at(0.0) == 12.5 and sweep_egress.SWEEP.at(4.0) == 4.0
    params = sweep_lib.point_params(sweep_columns.SWEEP, {"ssize": 1}, [0, 1, 8], 3)
    assert params == {"ssize": 1, "columns": 3, "file_columns": 8}


if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"ok    {name}")
            except Exception as e:  # noqa: BLE001
                failed += 1
                print(f"FAIL  {name}: {type(e).__name__}: {e}")
    sys.exit(1 if failed else 0)

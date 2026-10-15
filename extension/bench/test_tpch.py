#!/usr/bin/env python3
"""Tests of tpch_bench.py and sweep_tpch_q17.py / q19 / q20 without the FPGA: the data is generated for real (a
small scale factor, DuckDB's dbgen), the DuckDB CLI is a fake that prints what the extension's does for Q17 (the
segments are the ones of a real run; the ones of Q19 and Q20 are built the same way). Run: python test_tpch.py (or
pytest). Needs duckdb, PyYAML and matplotlib: source ~/plotting/bin/activate"""

import contextlib
import copy
import io
import json
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import bench
import sweep_lib
import sweep_tpch_q17
import sweep_tpch_q19
import sweep_tpch_q20
import tpch_bench

NO_GUARD = "OASIS_BENCH_NO_DEVICE_GUARD"
SF = 0.1  # 18 parts of 20000 pass Q17's predicate, 600572 lineitem rows: about 2 s to generate

# What the extension printed for Q17 at SF 1 (a real run), reduced to what is read: the Bloom filter's build pass,
# the part scan, the join's lineitem scan, and the subquery's lineitem scan (the final segment). Beats of 64 B
SEGMENTS = [("before_scan", "part_q17.parquet", 17, 0, 26), ("before_scan", "lineitem.parquet", 17, 0, 26),
            ("before_scan", "lineitem.parquet", 996039, 19, 2250456), ("final", "lineitem.parquet", 511718, 0, 1500304)]
LINEITEM_ROWS = 6001215
PROBE_OUT_BYTES = (3 + 2) * 8 * LINEITEM_ROWS  # l_partkey, l_quantity, l_extendedprice + the subquery's two

FAKE_CLI = r'''#!/usr/bin/env python3
import json, sys
mode = open(__file__ + ".mode").read().strip()
sql = sys.stdin.read()
bloom = "oasis_runtime_bloom_filter = true" in sql
segments = json.loads(open(__file__ + ".segments").read())
if mode == "reorder":  # a lineitem scan between the part scan and ... another part scan
    segments[1][1] = "part_q17.parquet"
for line in sql.splitlines():
    if not line.startswith(".print"):
        continue
    print(line.split(" ", 1)[1])
    if line.startswith(".print @@SETTINGS"):
        print(json.dumps([{"threads": 32, "oasis_runtime_bloom_filter": bloom, "duckdb_version": "v0.0.1"}]))
    if line.startswith(".print @@RESULT"):
        answer = json.loads(open(__file__ + ".answer").read())
        if mode == "wrong":
            answer = [0] * len(answer) if isinstance(answer, list) else 1.5
        print(json.dumps([dict(enumerate(answer)) if isinstance(answer, list) else {"avg_yearly": answer}]))
    if line.startswith(".print @@PROFILE"):
        print(json.dumps([{"stream": "0"}]))
    if line.startswith(".print @@QS"):
        print(json.dumps([{"total_query_ms": 50.0 if bloom else 52.0, "scan_only_ms": 13.0,
                           "scan_celeris_bloom_ms": 14.0 if bloom and mode != "nobloom" else None,
                           "join_ms": 24.0}]))
    if line.startswith(".print @@DP"):
        print(json.dumps([{"segment": str(i), "label": l, "file": "/x/" + f, "in_handshakes_cycles": str(h),
                           "in_starved_cycles": str(s), "in_stalled_cycles": "0", "in_idle_cycles": "0",
                           "out_handshakes_cycles": str(o), "out_starved_cycles": "0", "out_stalled_cycles": "0",
                           "out_idle_cycles": "0"} for i, (l, f, h, s, o) in enumerate(segments)]))
    if line.startswith(".print @@BF") and (bloom or mode == "bloomoff"):
        print(json.dumps([{"run": "0",
                           "build": "{'cycles': 145, 'idle_cycles': 118, 'beats': 27}",
                           "probe": "{'cycles': 4000, 'idle_cycles': 2000}",
                           "run_perf": "{'cycles': 6000, 'keys_in_beats': 750153, 'values_in_beats': 1500000, "
                                       "'out_cycles': 4000, 'probe_start_cycles': 1000, 'out_bytes': 64000}",
                           "command_queue_overflowed": False}]))
    if line.startswith(".print @@ST"):
        print(json.dumps([{"file": "/x/lineitem.parquet", "bloom": bool(bloom), "wall_ms": 14.0},
                          {"file": "/x/part_q17.parquet", "bloom": False, "wall_ms": 2.0}]))
'''


# What the stub of each query has: the build file, the number of its rows, the answer row, the decoder output of
# one run (rows x bytes of the decoder's columns of the probe: Q19 4 x 8 B, Q20 3 x 8 B + 4 B)
STUBS = {
    "q17": {"build": "part_q17.parquet", "rows": 204, "full": 200000, "row": [348406.0542857143],
            "bytes": PROBE_OUT_BYTES},
    "q19": {"build": "part_q19.parquet", "rows": 485, "full": 200000, "row": ["3083843.0578"],
            "bytes": 4 * 8 * LINEITEM_ROWS},
    "q20": {"build": "partsupp_q20.parquet", "rows": 8508, "full": 800000, "row": [183, 9221393912309821],
            "bytes": (3 * 8 + 4) * LINEITEM_ROWS},
}


def segments_of(query):
    """The profile segments of one run of the query: the Bloom filter's build pass, the build file's scan and the
    probe's one scan (the final segment). Q17 has the two scans of lineitem (SEGMENTS)"""
    if query == "q17":
        return SEGMENTS
    beats = STUBS[query]["bytes"] // 64
    return [("before_scan", STUBS[query]["build"], 17, 0, 26), ("before_scan", "lineitem.parquet", 17, 0, 26),
            ("final", "lineitem.parquet", beats // 2, 19, beats)]


def stub_dataset(tmp, scale_factor=1.0, compression="uncompressed", query="q17"):
    """A dataset with the numbers of SF 1 and no files (the fake CLI does not read them)"""
    stub = STUBS[query]
    meta = {"rows": stub["rows"], "full_rows": stub["full"], "row_groups": [stub["rows"]]}
    probe = {"rows": LINEITEM_ROWS, "row_groups": [122880] * 48 + [103875]}
    return tpch_bench.TpchDataset(
        query=query, scale_factor=scale_factor, compression=compression,
        build_path=Path("/x") / stub["build"], probe_path=Path("/x/lineitem.parquet"),
        build_row_groups=[stub["rows"]], probe_row_groups=probe["row_groups"], build_meta=meta, probe_meta=probe,
        expected_result=float(stub["row"][0]), matching_probe_rows=6088, probe_out_bytes=stub["bytes"],
        expected_row=tuple(stub["row"]) if query != "q17" else (),
        side_paths={t: Path("/x") / f"{t}.parquet" for t in tpch_bench.QUERIES[query].side_tables})


def make_fake(tmp, mode="ok", segments=SEGMENTS, answer=348406.0542857143):  # answer: a value or a list (a row)
    path = Path(tmp) / "fake_duckdb"
    path.write_text(FAKE_CLI)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    Path(str(path) + ".mode").write_text(mode)
    Path(str(path) + ".segments").write_text(json.dumps(segments))
    Path(str(path) + ".answer").write_text(json.dumps(answer))
    return path


def run(tmp, mode="ok", name="p", segments=None, query="q17", answer=None, **params):
    workload = tpch_bench.TpchWorkload(tpch_bench.QUERIES[query])
    params = {"scale_factor": 1.0, **params}
    answer = answer if answer is not None else STUBS[query]["row"] if query != "q17" else 348406.0542857143
    if answer is STUBS[query]["row"] and len(answer) == 1:
        answer = [float(answer[0])]  # the CLI prints a DECIMAL as a number
    return bench.run_benchmark(Path(tmp) / name, params, warmup=1, iterations=3,
                               binary=make_fake(tmp, mode, segments or segments_of(query), answer),
                               dataset=stub_dataset(tmp, query=query), quiet=True,
                               lib_dir=tmp, guard_device=False, workload=workload)


def load(folder):
    import yaml
    return yaml.safe_load((Path(folder) / "bench.yaml").read_text())


def fails(fn, *needles):
    try:
        fn()
    except bench.BenchmarkError as e:
        assert all(n in str(e) for n in needles), f"{needles} not in: {e}"
    else:
        raise AssertionError("expected a BenchmarkError")


# ---------------------------------------------------------------------------
# The query and the script
# ---------------------------------------------------------------------------

def test_query_has_no_build_side_predicate_and_the_reference_has_it():
    sql = tpch_bench.Q17.sql("/d/part_q17.parquet", "/d/lineitem.parquet")
    assert "p_brand" not in sql and "p_container" not in sql and "Brand#23" not in sql
    assert sql.count("read_oasis('/d/lineitem.parquet')") == 2 and "read_oasis('/d/part_q17.parquet')" in sql
    assert "l_quantity < (" in sql and "0.2 * avg(l_quantity)" in sql
    ref = tpch_bench.Q17.reference_sql
    assert "p_brand = 'Brand#23'" in ref and "p_container = 'MED BOX'" in ref
    assert tpch_bench.Q17.build_predicate in ref


def test_script_and_measures():
    with tempfile.TemporaryDirectory() as tmp:
        folder = run(tmp, threads=4, egress_gbps=6.0)
        sql = (folder / "run.sql").read_text()
        assert "SET disabled_optimizers = 'deliminator';" in sql  # the plan of both variants
        assert "SET threads = 4;" in sql and "SET oasis_emulated_egress_gbps = 6.0;" in sql
        assert "SET oasis_runtime_bloom_filter = true;" in sql and sql.count("@@ITER") == 4
        assert "p_brand" not in sql and "avg_yearly" in sql
        data = load(folder)
        assert data["benchmark"]["status"] == "ok"
        assert data["parameters"]["query"] == "q17" and data["parameters"]["scale_factor"] == 1.0
        assert data["parameters"]["build_rows"] == 204 and data["parameters"]["probe_rows"] == LINEITEM_ROWS
        assert data["parameters"]["threads"] == 4 and data["parameters"]["emulated_egress_gbps"] == 6.0
        assert data["expected"]["result"] == 348406.0542857143
        it = data["iterations"][0]
        assert it["host"]["query_ms"] == 50.0 and it["host"]["scan_ms"] == 27.0 and it["host"]["rest_ms"] == 23.0
        # The probe's decoder window: both lineitem scans (segments 2 and 3, not the Bloom filter's build pass
        # and the part scan): (996039 + 511718) beats in, (2250456 + 1500304) out
        assert it["decoder"]["scope"] == "probe table scans" and it["decoder"]["segments"] == 2
        assert it["decoder"]["in"]["handshakes"] == 996039 + 511718
        assert it["decoder"]["out"]["handshakes"] == 2250456 + 1500304
        assert it["decoder"]["out"]["bytes"] == (2250456 + 1500304) * 64
        # The whole run: all four segments
        assert it["decoder_run"]["out"]["handshakes"] == 26 + 26 + 2250456 + 1500304
        assert abs(it["checks"]["decoder_probe_out_bytes_ratio"] - 1.0) < 1e-3
        assert it["bloom"]["in_gbps"] > 0 and it["result"]["value"] == 348406.0542857143


def test_bloom_off_has_no_filter_measures():
    with tempfile.TemporaryDirectory() as tmp:
        data = load(run(tmp, runtime_bloom=False))
        it = data["iterations"][0]
        assert it["bloom"] is None and it["host"]["scan_bloom_ms"] is None
        assert data["parameters"]["runtime_bloom"] is False


# ---------------------------------------------------------------------------
# Q19 and Q20
# ---------------------------------------------------------------------------

def side_of(path="/d"):
    return {"supplier": f"{path}/supplier.parquet", "nation": f"{path}/nation.parquet"}


def test_q19_drops_the_part_filters_the_file_implies_and_keeps_the_coupling():
    sql = tpch_bench.Q19.sql("/d/part_q19.parquet", "/d/lineitem.parquet")
    assert "p_container" not in sql and "p_size" not in sql
    for brand, low in (("Brand#12", 1), ("Brand#23", 10), ("Brand#34", 20)):  # brand couples to the quantity range
        assert f"(p_brand = '{brand}' AND l_quantity >= {low} AND l_quantity <= {low} + 10)" in sql
    assert "l_shipmode IN ('AIR', 'AIR REG')" in sql and "l_shipinstruct = 'DELIVER IN PERSON'" in sql
    assert sql.count("read_oasis('/d/lineitem.parquet')") == 1 and "read_oasis('/d/part_q19.parquet')" in sql
    ref = tpch_bench.Q19.reference_sql
    assert ref.count("p_container IN") == 3 and ref.count("p_size BETWEEN") == 3 and "read_oasis" not in ref
    for token in ("p_container IN ('SM CASE'", "p_size BETWEEN 1 AND 15"):
        assert token in tpch_bench.Q19.build_predicate


def test_q20_is_a_join_below_the_aggregate_over_the_prefiltered_partsupp():
    sql = tpch_bench.Q20.sql("/d/partsupp_q20.parquet", "/d/lineitem.parquet", side_of())
    assert "forest" not in sql and "p_name" not in sql and "p_partkey" not in sql and "part.parquet" not in sql
    # The two read_oasis scans are the ones of the join the filter goes into, the small tables use DuckDB's reader
    assert sql.count("read_oasis(") == 2 and "read_oasis('/d/lineitem.parquet')" in sql
    assert "read_oasis('/d/partsupp_q20.parquet')" in sql
    assert "read_parquet('/d/supplier.parquet')" in sql and "read_parquet('/d/nation.parquet')" in sql
    assert sql.index("l_partkey = ps_partkey") < sql.index("l_suppkey = ps_suppkey")  # the filter's key is the first
    assert "GROUP BY ps_partkey, ps_suppkey, ps_availqty" in sql and "ps_availqty > 0.5 * sum_qty" in sql
    ref = tpch_bench.Q20.reference_sql
    assert "p_name LIKE 'forest%'" in ref and "read_oasis" not in ref and "ORDER BY" not in ref
    assert tpch_bench.Q20.build_predicate in ref
    assert tpch_bench.Q20.build_file == "partsupp_q20.parquet"


def test_q19_and_q20_scripts_and_measures():
    for query in ("q19", "q20"):
        with tempfile.TemporaryDirectory() as tmp:
            folder = run(tmp, query=query, threads=4)
            sql = (folder / "run.sql").read_text()
            assert "disabled_optimizers" not in sql  # the plan needs no optimizer off
            assert "SET oasis_runtime_bloom_filter = true;" in sql and sql.count("@@ITER") == 4
            assert "p_container" not in sql and "forest" not in sql
            assert ("read_parquet(" in sql) == (query == "q20")
            data = load(folder)
            assert data["benchmark"]["status"] == "ok"
            assert data["parameters"]["query"] == query
            assert data["expected"]["probe_out_bytes"] == STUBS[query]["bytes"]
            it = data["iterations"][0]
            # One scan of lineitem: the probe's decoder window is the final segment
            assert it["decoder"]["scope"] == "probe table scans" and it["decoder"]["segments"] == 1
            assert it["decoder"]["out"]["bytes"] == segments_of(query)[2][4] * 64
            assert abs(it["checks"]["decoder_probe_out_bytes_ratio"] - 1.0) < 1e-3
            assert it["bloom"]["in_gbps"] > 0
            assert it["result"]["value"] == float(STUBS[query]["row"][0])
            if query == "q20":  # the answer is a row: count and checksum, the second one exactly
                assert it["result"]["row"] == [183, 9221393912309821]
                assert data["expected"]["result_row"] == [183, 9221393912309821]


def test_q20_result_is_compared_column_by_column_and_exactly():
    with tempfile.TemporaryDirectory() as tmp:
        fails(lambda: run(tmp, query="q20", answer=[183, 9221393912309822]), "wrong result", "9221393912309822")
    with tempfile.TemporaryDirectory() as tmp:
        fails(lambda: run(tmp, query="q20", answer=[183]), "1 column(s), expected 2")
    with tempfile.TemporaryDirectory() as tmp:
        fails(lambda: run(tmp, "wrong", query="q20"), "wrong result")
    with tempfile.TemporaryDirectory() as tmp:  # HUGEINT is printed as a string by the CLI
        folder = run(tmp, query="q20", answer=[183, "9221393912309821"])
        assert load(folder)["benchmark"]["status"] == "ok"


def test_q19_decoder_bytes_of_another_plan_fail():
    with tempfile.TemporaryDirectory() as tmp:
        wide = [list(s) for s in segments_of("q19")]
        wide[2][4] = wide[2][4] * 5 // 4  # five 8 B columns decoded instead of four
        fails(lambda: run(tmp, query="q19", segments=wide), "the plan is not the one this benchmark measures")


# ---------------------------------------------------------------------------
# What fails
# ---------------------------------------------------------------------------

def test_wrong_result_fails():
    with tempfile.TemporaryDirectory() as tmp:
        fails(lambda: run(tmp, "wrong"), "wrong result")


def test_filter_that_did_not_run_fails():
    with tempfile.TemporaryDirectory() as tmp:
        fails(lambda: run(tmp, "nobloom"), "did not run once")
    with tempfile.TemporaryDirectory() as tmp:
        fails(lambda: run(tmp, "bloomoff", runtime_bloom=False), "switched off")


def test_plan_that_decodes_other_columns_fails():
    with tempfile.TemporaryDirectory() as tmp:
        short = [list(s) for s in SEGMENTS]
        short[3][4] = 1000000  # the subquery's scan decoded 64 MB, not 96 MB
        fails(lambda: run(tmp, segments=short), "the plan is not the one this benchmark measures")


def test_lineitem_scans_have_to_be_consecutive():
    with tempfile.TemporaryDirectory() as tmp:
        scattered = [list(s) for s in SEGMENTS]
        scattered[0][1] = "lineitem.parquet"  # scans: lineitem, part, lineitem (the last one is the final segment's)
        scattered[1][1] = "part_q17.parquet"
        fails(lambda: run(tmp, segments=scattered), "not consecutive")
    with tempfile.TemporaryDirectory() as tmp:
        none = [list(s) for s in SEGMENTS]
        for s in none:
            s[1] = "part_q17.parquet"
        fails(lambda: run(tmp, segments=none), "no scan of lineitem.parquet")


def test_bad_parameters():
    workload = tpch_bench.TpchWorkload(tpch_bench.Q17)
    fails(lambda: workload.complete_params({"ssize": 1}), "unknown parameter")
    fails(lambda: workload.complete_params({"scale_factor": 0.0}), "at least 0.001")
    fails(lambda: workload.complete_params({"compression": "zstd"}), "compression")
    assert workload.complete_params({})["scale_factor"] == 1.0


# ---------------------------------------------------------------------------
# The data (really generated)
# ---------------------------------------------------------------------------

def test_generated_data_is_what_ParCore_reads_and_prefiltered():
    import duckdb
    with tempfile.TemporaryDirectory() as tmp:
        logged = []
        ds = tpch_bench.ensure_dataset(tmp, tpch_bench.Q17, SF, "uncompressed", log=logged.append)
        assert ds.build_path.name == "part_q17.parquet" and ds.probe_path.name == "lineitem.parquet"
        con = duckdb.connect()
        # Every leaf OPTIONAL, no NULLs, row groups within ParCore's limit
        for path in (ds.build_path, ds.probe_path):
            assert con.execute("SELECT count(*) FROM parquet_schema(?) WHERE num_children IS NULL AND "
                               "repetition_type != 'OPTIONAL'", [str(path)]).fetchone()[0] == 0
            assert con.execute("SELECT coalesce(sum(stats_null_count), 0) FROM parquet_metadata(?)",
                               [str(path)]).fetchone()[0] == 0
        assert max(ds.probe_row_groups) <= 131072 and sum(ds.probe_row_groups) == ds.probe_meta["rows"]
        # The build file holds exactly the rows of the predicate, with every column of part
        n_part = con.execute(f"SELECT count(*) FROM read_parquet('{ds.build_path}')").fetchone()[0]
        assert n_part == ds.build_meta["rows"] == 18 and ds.build_meta["full_rows"] == 20000
        assert con.execute(f"SELECT count(DISTINCT p_brand), count(DISTINCT p_container) FROM "
                           f"read_parquet('{ds.build_path}')").fetchone() == (1, 1)
        assert con.execute(f"SELECT count(*) FROM parquet_schema('{ds.build_path}') "
                           "WHERE num_children IS NULL").fetchone()[0] == 9
        # The query without a predicate over the two files is the original query over the full tables
        lineitem, part = ds.probe_path, ds.build_path
        got = con.execute(
            f"SELECT sum(l_extendedprice) / 7.0 FROM read_parquet('{lineitem}') l, read_parquet('{part}') p "
            f"WHERE p_partkey = l_partkey AND l_quantity < (SELECT 0.2 * avg(l_quantity) FROM "
            f"read_parquet('{lineitem}') l2 WHERE l2.l_partkey = p_partkey)").fetchone()[0]
        assert abs(got - ds.expected_result) < 1e-6 * abs(got), (got, ds.expected_result)
        assert ds.matching_probe_rows == con.execute(
            f"SELECT count(*) FROM read_parquet('{lineitem}') WHERE l_partkey IN "
            f"(SELECT p_partkey FROM read_parquet('{part}'))").fetchone()[0] > 0
        # 5 column passes of 8 B (INT64 l_partkey and the two DECIMAL(15,2) columns)
        assert ds.probe_out_bytes == 5 * 8 * ds.probe_meta["rows"]
        # A second call reuses the directory, release() removes it
        n = len(logged)
        again = tpch_bench.ensure_dataset(tmp, tpch_bench.Q17, SF, "uncompressed", log=logged.append)
        assert len(logged) == n and again.expected_result == ds.expected_result
        tpch_bench.TpchWorkload(tpch_bench.Q17).release(tmp, {"scale_factor": SF, "compression": "uncompressed"})
        assert not ds.probe_path.exists()


def _generated(query, tmp):
    return tpch_bench.ensure_dataset(tmp, tpch_bench.QUERIES[query], SF, "uncompressed", log=lambda *_: None)


def _measured_answer(ds, query):
    """The measured SQL over the generated files, run by python's DuckDB (read_parquet in place of read_oasis)"""
    import duckdb
    con = duckdb.connect()
    sql = query.sql(str(ds.build_path), str(ds.probe_path), {t: str(p) for t, p in ds.side_paths.items()})
    return con.execute(sql.replace("read_oasis(", "read_parquet(")).fetchone()


def _assert_optional_without_nulls(paths):
    import duckdb
    con = duckdb.connect()
    for path in paths:
        assert con.execute("SELECT count(*) FROM parquet_schema(?) WHERE num_children IS NULL AND "
                           "repetition_type != 'OPTIONAL'", [str(path)]).fetchone()[0] == 0, path
        assert con.execute("SELECT coalesce(sum(stats_null_count), 0) FROM parquet_metadata(?)",
                           [str(path)]).fetchone()[0] == 0, path
        assert max(r[0] for r in con.execute(
            "SELECT max(row_group_num_rows) FROM parquet_metadata(?) GROUP BY row_group_id", [str(path)]
        ).fetchall()) <= 131072


def test_q19_prefiltered_part_gives_the_answer_of_the_original_query():
    import duckdb
    with tempfile.TemporaryDirectory() as tmp:
        ds = _generated("q19", tmp)
        assert ds.build_path.name == "part_q19.parquet" and ds.side_paths == {}
        _assert_optional_without_nulls([ds.build_path, ds.probe_path])
        con = duckdb.connect()
        # The file holds exactly the parts that satisfy one group's part predicate, with every column of part
        n_part, n_all = ds.build_meta["rows"], ds.build_meta["full_rows"]
        assert 0 < n_part < n_all == 20000
        assert con.execute(f"SELECT count(DISTINCT p_brand) FROM read_parquet('{ds.build_path}')").fetchone()[0] == 3
        assert con.execute(f"SELECT count(*) FROM parquet_schema('{ds.build_path}') "
                           "WHERE num_children IS NULL").fetchone()[0] == 9
        # The brands of the groups differ, so a part of the file is in one group only: p_container and p_size are
        # implied by the file and p_brand, and the measured query (which has neither) gives the original's answer
        assert con.execute(
            f"SELECT count(*) FROM read_parquet('{ds.build_path}') WHERE NOT ({tpch_bench.Q19.build_predicate})"
        ).fetchone()[0] == 0
        # The measured query over the files == the original query over the tables, exactly (a DECIMAL)
        (got,) = _measured_answer(ds, tpch_bench.Q19)
        assert ds.expected_row == (str(got),) and tpch_bench._same(str(got), ds.expected_row[0])
        assert ds.matching_probe_rows == con.execute(
            f"SELECT count(*) FROM read_parquet('{ds.probe_path}') WHERE l_partkey IN "
            f"(SELECT p_partkey FROM read_parquet('{ds.build_path}'))").fetchone()[0] > 0
        # 4 decoded columns of 8 B (the two strings are decoded on the CPU)
        assert ds.probe_out_bytes == 4 * 8 * ds.probe_meta["rows"]


def test_q20_prefiltered_partsupp_gives_the_answer_of_the_original_query():
    import duckdb
    with tempfile.TemporaryDirectory() as tmp:
        ds = _generated("q20", tmp)
        assert ds.build_path.name == "partsupp_q20.parquet"
        assert sorted(ds.side_paths) == ["nation", "supplier"] and all(p.exists() for p in ds.side_paths.values())
        assert not (Path(tmp) / "q20_sf0_1_uncompressed" / "part.parquet").exists()  # only the predicate needs part
        _assert_optional_without_nulls([ds.build_path, ds.probe_path, *ds.side_paths.values()])
        con = duckdb.connect()
        # Only the partsupp rows of forest parts, every partsupp column
        assert ds.build_meta["full_rows"] == 80000 and 0 < ds.build_meta["rows"] < 2000
        assert con.execute(f"SELECT count(*) FROM parquet_schema('{ds.build_path}') "
                           "WHERE num_children IS NULL").fetchone()[0] == 5
        assert ds.probe_out_bytes == (3 * 8 + 4) * ds.probe_meta["rows"]  # l_partkey, l_suppkey, l_quantity, l_shipdate
        # The measured query over the files == the original query over the tables
        got = _measured_answer(ds, tpch_bench.Q20)
        assert len(ds.expected_row) == 2 and ds.expected_row[0] > 0
        assert all(tpch_bench._same(g, w) for g, w in zip(got, ds.expected_row)), (got, ds.expected_row)
        # A second call reuses the directory, and release() removes it with the side tables
        again = _generated("q20", tmp)
        assert again.expected_row == ds.expected_row and again.side_paths == ds.side_paths
        tpch_bench.TpchWorkload(tpch_bench.Q20).release(tmp, {"scale_factor": SF, "compression": "uncompressed"})
        assert not ds.build_path.exists() and not any(p.exists() for p in ds.side_paths.values())


def test_scale_factor_without_matching_parts_is_refused():
    with tempfile.TemporaryDirectory() as tmp:
        fails(lambda: tpch_bench.ensure_dataset(tmp, tpch_bench.Q17, 0.001, "uncompressed", log=lambda *_: None),
              "selects none")
        assert not any(Path(tmp).iterdir())  # no half-written directory is left


# ---------------------------------------------------------------------------
# The sweep
# ---------------------------------------------------------------------------

SCRIPTS = {"q17": sweep_tpch_q17, "q19": sweep_tpch_q19, "q20": sweep_tpch_q20}


def run_sweep(args, tmp, mode="ok", query="q17"):
    cli = make_fake(tmp, mode, segments_of(query), STUBS[query]["row"] if query != "q17" else 348406.0542857143)
    script = SCRIPTS[query]
    argv = list(args) + ["--binary", str(cli), "--lib-dir", str(tmp), "--tmp-dir", str(tmp),
                         "--warmup", "1", "--iterations", "3", "--results-dir", str(Path(tmp) / "res")]
    out, err = io.StringIO(), io.StringIO()
    saved = os.environ.get(NO_GUARD)
    os.environ[NO_GUARD] = "1"
    real = tpch_bench.ensure_dataset
    made = []

    def ensure(data_dir, query, scale_factor, compression, log=print):  # SF 1 would take long: the stub
        made.append((scale_factor, compression))
        d = tpch_bench.dataset_dir(data_dir, query, scale_factor, compression)
        d.mkdir(parents=True, exist_ok=True)
        return stub_dataset(tmp, scale_factor, compression, query.name)

    tpch_bench.ensure_dataset = ensure
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = sweep_lib.main(script.SWEEP, script.add_args, script.points_of, argv)
    finally:
        tpch_bench.ensure_dataset = real
        if saved is None:
            os.environ.pop(NO_GUARD, None)
        else:
            os.environ[NO_GUARD] = saved
    return code, out.getvalue(), err.getvalue(), made


def test_sweep_layout_table_summary_and_data_released_per_point():
    import csv
    with tempfile.TemporaryDirectory() as tmp:
        code, out, err, made = run_sweep(["--scale-factors", "3", "1", "2", "2"], tmp)
        assert code == 0, err
        assert made == [(1.0, "uncompressed")] * 2 + [(2.0, "uncompressed")] * 2 + [(3.0, "uncompressed")] * 2
        (exp,) = list((Path(tmp) / "res").iterdir())
        assert exp.name.startswith("tpch_q17_")
        for variant in ("bloom_on", "bloom_off"):
            assert sorted(p.name for p in (exp / "results" / variant).iterdir()) == ["sf1", "sf2", "sf3"]
        rows = list(csv.reader(open(exp / "results" / "summary.csv", newline="")))
        assert rows[0][0] == "scale_factor" and [r[0] for r in rows[1:]] == ["1", "2", "3"]
        names = sorted(p.name for p in (exp / "plots" / "both").iterdir())
        assert "query_breakdown.pdf" in names and "decoder_in_out.pdf" in names and "query_ms.pdf" in names
        assert "bloom_in.pdf" in [p.name for p in (exp / "plots" / "bloom_on").iterdir()]
        # The same measures as every sweep
        header = out.splitlines()[2].split("  ")
        assert [h.strip() for h in header if h.strip()][:3] == ["scale factor", "bloom", "query"]
        assert "median over 3 measured runs" in out


def test_q19_and_q20_sweeps_have_the_layout_of_q17():
    import csv
    for query in ("q19", "q20"):
        with tempfile.TemporaryDirectory() as tmp:
            code, out, err, made = run_sweep(["--scale-factors", "2", "1"], tmp, query=query)
            assert code == 0, err
            assert made == [(1.0, "uncompressed")] * 2 + [(2.0, "uncompressed")] * 2
            (exp,) = list((Path(tmp) / "res").iterdir())
            assert exp.name.startswith(f"tpch_{query}_")
            for variant in ("bloom_on", "bloom_off"):
                assert sorted(p.name for p in (exp / "results" / variant).iterdir()) == ["sf1", "sf2"]
            rows = list(csv.reader(open(exp / "results" / "summary.csv", newline="")))
            assert rows[0][0] == "scale_factor" and [r[0] for r in rows[1:]] == ["1", "2"]
            assert "query_ms[bloom_on]" in rows[0] and "decoder_out[bloom_off]" in rows[0]
            assert "query_breakdown.pdf" in [p.name for p in (exp / "plots" / "both").iterdir()]
            data = load(exp / "results" / "bloom_on" / "sf1")
            assert data["parameters"]["query"] == query and data["parameters"]["runtime_bloom"] is True
            assert load(exp / "results" / "bloom_off" / "sf1")["parameters"]["runtime_bloom"] is False
    with tempfile.TemporaryDirectory() as tmp:  # the same stop at the first failure
        code, out, err, made = run_sweep(["--scale-factors", "1", "2"], tmp, mode="wrong", query="q20")
        assert code == 1 and "wrong result" in err and made == [(1.0, "uncompressed")]


def test_sweep_resume_skips_complete_points_and_fractional_folder():
    with tempfile.TemporaryDirectory() as tmp:
        code, out, err, made = run_sweep(["--scale-factors", "0.5", "1", "--bloom", "on"], tmp)
        assert code == 0, err
        (exp,) = list((Path(tmp) / "res").iterdir())
        assert sorted(p.name for p in (exp / "results" / "bloom_on").iterdir()) == ["sf0_5", "sf1"]
        code, out, err, made = run_sweep(["--scale-factors", "0.5", "1", "--bloom", "on", "--resume", str(exp)], tmp)
        assert code == 0 and made == [] and out.count("existing") == 2


def test_sweep_options_are_the_ones_that_apply():
    parser_args = []
    with tempfile.TemporaryDirectory() as tmp:
        code, out, err, made = run_sweep(["--scale-factors", "1", "--bloom", "off", "--compression", "snappy",
                                          "--threads", "8"], tmp)
        assert code == 0, err
        assert made == [(1.0, "snappy")]
        (exp,) = list((Path(tmp) / "res").iterdir())
        data = load(exp / "results" / "bloom_off" / "sf1")
        assert data["parameters"]["compression"] == "snappy" and data["parameters"]["threads"] == 8
    # No option of the synthetic data: --ssize and the like are not there
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            sweep_lib.main(sweep_tpch_q17.SWEEP, sweep_tpch_q17.add_args, sweep_tpch_q17.points_of, ["--ssize", "1"])
        except SystemExit as e:
            assert e.code == 2
        else:
            raise AssertionError("--ssize is accepted")


def test_sweep_stops_at_the_first_failure():
    with tempfile.TemporaryDirectory() as tmp:
        code, out, err, made = run_sweep(["--scale-factors", "1", "2"], tmp, mode="wrong")
        assert code == 1 and "wrong result" in err and "--resume" in err
        assert made == [(1.0, "uncompressed")]  # 2 was never started


if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"ok    {name}")
            except BaseException as e:  # noqa: BLE001
                failed += 1
                print(f"FAIL  {name}: {type(e).__name__}: {e}")
                import traceback
                traceback.print_exc()
    sys.exit(1 if failed else 0)

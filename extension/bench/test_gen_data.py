#!/usr/bin/env python3
"""Tests for gen_data.py.  Run with `python test_gen_data.py` (or pytest).

Small sizes in temp dirs under /tmp, except test_timing_large (2^20 x 2^24, 4 payload columns).
Set OASIS_SKIP_TIMING=1 to skip that one.  Pure Python/numpy/DuckDB; touches no hardware.
"""
from __future__ import annotations

import contextlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import duckdb
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_data as gd  # noqa: E402
from gen_data import DataParams, ensure_dataset, resolve_batching  # noqa: E402


@contextlib.contextmanager
def tmpdir():
    d = tempfile.mkdtemp(prefix="oasis_gen_test_", dir="/tmp")
    try:
        yield Path(d)
    finally:
        shutil.rmtree(d, ignore_errors=True)


def quiet(*_a, **_k):
    pass


def make(d, **kw):
    return ensure_dataset(d, DataParams(**kw), log=quiet)


def read_columns(path):
    """{column: int64 numpy array} of a Parquet file, read by DuckDB."""
    con = duckdb.connect()
    cols = con.execute("SELECT * FROM read_parquet(?)", [str(path)]).fetchnumpy()
    return {k: np.asarray(np.ma.getdata(v)) for k, v in cols.items()}


def metadata(path):
    con = duckdb.connect()
    schema = con.execute("SELECT name, type, repetition_type FROM parquet_schema(?) "
                         "WHERE num_children IS NULL", [str(path)]).fetchall()
    chunks = con.execute("SELECT row_group_id, column_id, path_in_schema, row_group_num_rows, "
                         "stats_null_count, compression, encodings FROM parquet_metadata(?) "
                         "ORDER BY 1, 2", [str(path)]).fetchall()
    return schema, chunks


def sql_expected(ds, columns):
    con = duckdb.connect()
    sums = ", ".join(f"sum(p.c{i})::HUGEINT" for i in range(1, columns + 1))
    q = (f"SELECT count(*), sum(p.key)::HUGEINT{', ' + sums if sums else ''} "
         f"FROM read_parquet({gd._sql_str(str(ds.probe_path))}) p "
         f"JOIN read_parquet({gd._sql_str(str(ds.build_path))}) b ON p.key = b.key")
    row = con.execute(q).fetchone()
    return int(row[0]), int(row[1] or 0), [int(x or 0) for x in row[2:]]


def raises(exc, fn, *a, **k):
    try:
        fn(*a, **k)
    except exc:
        return True
    return False


# ---------------------------------------------------------------------------------------------

def test_schema_optional_int64_no_nulls():
    with tmpdir() as d:
        ds = make(d, ssize=5000, rsize=30000, columns=3, batchsize=7000)
        for path, ncols, rows in ((ds.build_path, 1, 5000), (ds.probe_path, 4, 30000)):
            schema, chunks = metadata(path)
            assert [s[0] for s in schema] == ["key"] + [f"c{i}" for i in range(1, ncols)]
            assert all(s[1] == "INT64" and s[2] == "OPTIONAL" for s in schema), schema
            assert all(c[4] == 0 for c in chunks), "stats_null_count must be present and 0"
            rg_rows = {}
            for rg, col, name, n, nulls, comp, enc in chunks:
                rg_rows.setdefault(rg, set()).add(n)
            assert all(len(v) == 1 for v in rg_rows.values())
            assert sum(next(iter(v)) for v in rg_rows.values()) == rows
            cols = read_columns(path)
            assert all(len(v) == rows for v in cols.values())


def test_row_group_sizes_exact():
    with tmpdir() as d:
        # not multiples of 2048: DuckDB alone would round up (e.g. 7000 -> 8192)
        for bs in (1000, 2048, 5000, 7000, 8192, 120000, 131072):
            ds = make(d, ssize=20000, rsize=300000, columns=1, batchsize=bs)
            full, rem = divmod(300000, bs)
            want = [bs] * full + ([rem] if rem else [])
            assert ds.probe_row_groups == want, (bs, ds.probe_row_groups[:3], ds.probe_row_groups[-2:])
            sfull, srem = divmod(20000, bs)
            assert ds.build_row_groups == [bs] * sfull + ([srem] if srem else [])
            assert max(ds.probe_row_groups) <= 131072
        # numbatches: ceil(size / n) rows per batch, fewer batches when size < n
        ds = make(d, ssize=1000, rsize=100000, columns=1, batchsize=None, numbatches=7)
        assert ds.probe_row_groups == [14286] * 6 + [14284], ds.probe_row_groups
        assert ds.build_row_groups == [143] * 6 + [142], ds.build_row_groups
        ds = make(d, ssize=10, rsize=1000, columns=1, batchsize=None, numbatches=40)
        assert ds.build_row_groups == [1] * 10
        assert ds.probe_row_groups == [25] * 40


def test_union_fallback_reports_real_sizes():
    old = gd.MAX_UNION_BRANCHES
    gd.MAX_UNION_BRANCHES = 3
    try:
        with tmpdir() as d:
            msgs = []
            ds = ensure_dataset(d, DataParams(ssize=100, rsize=10000, columns=1, batchsize=1000),
                                log=msgs.append)
            assert ds.probe_row_groups == [2048] * 4 + [1808], ds.probe_row_groups
            assert any("not exactly" in m for m in msgs), msgs
    finally:
        gd.MAX_UNION_BRANCHES = old


def test_batching_rules():
    P = DataParams
    assert resolve_batching(P(ssize=1000, rsize=5000)) == (120000, 120000)
    assert resolve_batching(P(ssize=1000, rsize=5000, batchsize=131072)) == (131072, 131072)
    assert raises(ValueError, resolve_batching, P(ssize=1000, rsize=5000, batchsize=131073))
    assert raises(ValueError, resolve_batching, P(ssize=1000, rsize=5000, batchsize=0))
    assert raises(ValueError, resolve_batching, P(ssize=1000, rsize=5000, batchsize=None))
    # mutually exclusive: an explicit batchsize with numbatches
    assert raises(ValueError, resolve_batching, P(ssize=1000, rsize=5000, batchsize=1000, numbatches=4))
    assert resolve_batching(P(ssize=1000, rsize=5000, numbatches=4)) == (250, 1250)
    assert resolve_batching(P(ssize=1000, rsize=5000, batchsize=None, numbatches=4)) == (250, 1250)
    assert raises(ValueError, resolve_batching, P(ssize=1000, rsize=5000, batchsize=None, numbatches=0))
    # numbatches that yields > 131072 rows per batch
    assert raises(ValueError, resolve_batching, P(ssize=10, rsize=1 << 20, batchsize=None, numbatches=4))
    assert resolve_batching(P(ssize=10, rsize=1 << 20, batchsize=None, numbatches=8)) == (2, 131072)
    # other parameter validation
    assert raises(ValueError, P, ssize=10, rsize=10, matchratio=1.5)
    assert raises(ValueError, P, ssize=10, rsize=10, zipffactor=-1)
    assert raises(ValueError, P, ssize=10, rsize=10, columns=3, file_columns=2)
    assert raises(ValueError, P, ssize=10, rsize=10, compression="zstd")
    assert raises(ValueError, P, ssize=10, rsize=10, encoding="delta")
    with tmpdir() as d:
        assert raises(ValueError, ensure_dataset, d, P(ssize=10, rsize=1000, batchsize=200000), log=quiet)
        assert list(d.iterdir()) == [], "nothing may be written on invalid parameters"


def _share(keys, lo, hi):
    return float(np.mean((keys >= lo) & (keys < hi)))


def test_matchratio():
    n, s = 200000, 1000
    for z in (0.0, 1.0):
        for m in (0.0, 0.3, 1.0):
            with tmpdir() as d:
                ds = make(d, ssize=s, rsize=n, matchratio=m, zipffactor=z, columns=1)
                key = read_columns(ds.probe_path)["key"]
                frac = float(np.mean(key < s))
                sigma = math.sqrt(max(m * (1 - m), 1e-9) / n)
                assert abs(frac - m) <= 5 * sigma + 1e-12, (z, m, frac)
                assert ds.expected_rows == int(np.count_nonzero(key < s))
                if m == 0:
                    assert ds.expected_rows == 0 and ds.expected_sums == [0] and ds.expected_key_sum == 0
                if m == 1:
                    assert ds.expected_rows == n and int(key.max()) < s and int(key.min()) >= 0
                if z == 0 and 0 < m < 1:
                    hi = int(math.floor(s / m)) - 1  # uniform non-matches in [card, hi]
                    assert key[key >= s].min() >= s and key.max() <= hi
                    nm = key[key >= s]
                    assert abs(nm.mean() - (s + hi) / 2) < 5 * (hi - s) / math.sqrt(12 * len(nm))
                if z == 0 and m == 0:
                    assert key.min() >= s and key.max() <= (1 << 62)


def test_zipf_vs_uniform_and_nonmatch_keys():
    n, s = 400000, 1000
    h = float(np.sum(1.0 / np.arange(1, s + 1)))  # H_1000
    with tmpdir() as d:
        ds = make(d, ssize=s, rsize=n, matchratio=1.0, zipffactor=0.0, columns=1)
        key = read_columns(ds.probe_path)["key"]
        p = 1.0 / s
        assert abs(_share(key, 0, 1) - p) < 5 * math.sqrt(p / n)
        assert key.min() >= 0 and key.max() < s
        # uniform: all 20 equal-width buckets about equal
        counts = np.bincount(key // (s // 20), minlength=20)
        assert abs(counts / n - 0.05).max() < 5 * math.sqrt(0.05 * 0.95 / n)
    with tmpdir() as d:
        ds = make(d, ssize=s, rsize=n, matchratio=1.0, zipffactor=1.0, columns=1)
        key = read_columns(ds.probe_path)["key"]
        p = 1.0 / h
        assert abs(_share(key, 0, 1) - p) < 5 * math.sqrt(p * (1 - p) / n), (_share(key, 0, 1), p)
        p10 = float(np.sum(1.0 / np.arange(1, 11))) / h
        assert abs(_share(key, 0, 10) - p10) < 5 * math.sqrt(p10 * (1 - p10) / n)
        assert key.max() < s
    with tmpdir() as d:
        # m = 0.5: non-match domain has floor(card * 0.5 / 0.5) = 1000 ranks above card
        ds = make(d, ssize=s, rsize=n, matchratio=0.5, zipffactor=1.0, columns=1)
        key = read_columns(ds.probe_path)["key"]
        nm = key[key >= s]
        assert len(nm) > 0 and nm.min() >= s and nm.max() < 2 * s
        p = 1.0 / h
        assert abs(float(np.mean(nm == s)) - p) < 5 * math.sqrt(p * (1 - p) / len(nm))
        assert abs(len(nm) / n - 0.5) < 5 * 0.5 / math.sqrt(n)
        # matching keys follow the head of the same Zipf
        mk = key[key < s]
        assert abs(float(np.mean(mk == 0)) - p) < 5 * math.sqrt(p * (1 - p) / len(mk))
    with tmpdir() as d:
        # m = 0: all keys non-matching (documented deviation: `card` ranks)
        ds = make(d, ssize=s, rsize=50000, matchratio=0.0, zipffactor=1.0, columns=1)
        key = read_columns(ds.probe_path)["key"]
        assert key.min() >= s and key.max() < 2 * s and ds.expected_rows == 0


def test_zipf_tail_approximation_matches_exact_cdf():
    n, exact_k, draws = 20000, 100, 400000
    for z in (0.5, 1.0, 2.0):
        w = np.arange(1, n + 1, dtype=np.float64) ** -z
        cdf = np.cumsum(w) / w.sum()
        sampler = gd.ZipfSampler(n, z, exact=exact_k)
        u = np.random.default_rng(7).random(draws)
        ranks = sampler.sample(u)
        assert ranks.min() >= 0 and ranks.max() <= n - 1
        for r in (1, 50, 100, 101, 1000, 10000, 19999):
            p = float(cdf[r - 1])
            emp = float(np.mean(ranks < r))
            assert abs(emp - p) < 5 * math.sqrt(max(p * (1 - p), 1e-6) / draws) + 2e-4, (z, r, emp, p)
        # fully exact sampler agrees too
        ex = gd.ZipfSampler(n, z, exact=n).sample(u)
        assert abs(float(np.mean(ex < 1000)) - float(cdf[999])) < 0.003


def test_payload_range_and_independence():
    n = 100000
    with tmpdir() as d:
        ds = make(d, ssize=1000, rsize=n, columns=3)
        cols = read_columns(ds.probe_path)
        assert list(cols) == ["key", "c1", "c2", "c3"]
        for i in (1, 2, 3):
            c = cols[f"c{i}"]
            assert c.min() >= 0 and c.max() < n
            assert abs(c.mean() - (n - 1) / 2) < 5 * n / math.sqrt(12 * n)
        assert not np.array_equal(cols["c1"], cols["c2"])
        assert abs(np.corrcoef(cols["c1"], cols["c2"])[0, 1]) < 0.02
        # build side is sequential
        assert np.array_equal(read_columns(ds.build_path)["key"], np.arange(1000))


def test_determinism_and_batch_independence():
    kw = dict(ssize=3000, rsize=90000, matchratio=0.6, zipffactor=0.8, columns=2)
    with tmpdir() as d1, tmpdir() as d2:
        a = make(d1, batchsize=7000, **kw)
        b = make(d2, batchsize=7000, **kw)
        assert a.probe_path.read_bytes() == b.probe_path.read_bytes()
        assert a.build_path.read_bytes() == b.build_path.read_bytes()
        assert (a.expected_rows, a.expected_sums, a.expected_key_sum) == \
               (b.expected_rows, b.expected_sums, b.expected_key_sum)
        # the values do not depend on the batching
        c = make(d2, batchsize=None, numbatches=3, **kw)
        ca, cc = read_columns(a.probe_path), read_columns(c.probe_path)
        assert all(np.array_equal(ca[k], cc[k]) for k in ca)
        assert (c.expected_rows, c.expected_sums) == (a.expected_rows, a.expected_sums)
        assert c.probe_row_groups == [30000, 30000, 30000]


def test_cache_reuse_and_invalidation():
    with tmpdir() as d:
        logs = []
        p = DataParams(ssize=2000, rsize=20000, columns=2)
        ds = ensure_dataset(d, p, log=logs.append)
        assert sum(m.startswith("wrote") for m in logs) == 2
        st = {q: (q.stat().st_mtime_ns, q.stat().st_ino) for q in (ds.build_path, ds.probe_path)}
        logs.clear()
        ds2 = ensure_dataset(d, p, log=logs.append)
        assert all(m.startswith("reusing") for m in logs) and len(logs) == 2
        assert st == {q: (q.stat().st_mtime_ns, q.stat().st_ino) for q in (ds.build_path, ds.probe_path)}
        assert ds2.expected_rows == ds.expected_rows and ds2.expected_sums == ds.expected_sums
        # another match ratio: new probe file, build file reused
        logs.clear()
        ds3 = ensure_dataset(d, DataParams(ssize=2000, rsize=20000, columns=2, matchratio=0.5), log=logs.append)
        assert ds3.probe_path != ds.probe_path and ds3.build_path == ds.build_path
        assert [m.split()[0] for m in logs] == ["reusing", "wrote"], logs
        assert ds.probe_path.exists() and ds3.probe_path.exists()
        # stale sidecar (file replaced behind its back) -> regenerated
        side = Path(str(ds.probe_path) + ".json")
        meta = json.loads(side.read_text())
        meta["file_size"] += 1
        side.write_text(json.dumps(meta))
        logs.clear()
        ensure_dataset(d, p, log=logs.append)
        assert logs[-1].startswith("wrote"), logs
        # no leftovers
        names = sorted(q.name for q in d.iterdir())
        assert not [n for n in names if n.startswith(".")], names
        # compression and encoding are part of the key
        ds4 = make(d, ssize=2000, rsize=20000, columns=2, compression="snappy")
        ds5 = make(d, ssize=2000, rsize=20000, columns=2, encoding="plain")
        assert len({ds.probe_path, ds4.probe_path, ds5.probe_path}) == 3


def test_file_columns_superset():
    kw = dict(ssize=4000, rsize=50000, matchratio=0.7, zipffactor=1.0)
    with tmpdir() as d1, tmpdir() as d2:
        big = make(d1, columns=2, file_columns=5, **kw)
        small = make(d2, columns=2, **kw)
        assert big.probe_path != small.probe_path and "_c5_" in big.probe_path.name
        assert len(big.expected_sums) == 2 and len(big.probe_meta["expected"]["sums"]) == 5
        assert big.expected_sums == small.expected_sums
        assert big.expected_rows == small.expected_rows and big.expected_key_sum == small.expected_key_sum
        cb, cs = read_columns(big.probe_path), read_columns(small.probe_path)
        assert list(cb) == ["key", "c1", "c2", "c3", "c4", "c5"] and list(cs) == ["key", "c1", "c2"]
        assert all(np.array_equal(cb[k], cs[k]) for k in cs)
        # a run using fewer columns than the file reuses the same file
        again = make(d1, columns=4, file_columns=5, **kw)
        assert again.probe_path == big.probe_path and len(again.expected_sums) == 4
        assert again.expected_sums[:2] == big.expected_sums


def test_snappy_and_plain_encoding():
    with tmpdir() as d:
        u = make(d, ssize=3000, rsize=60000, columns=2, matchratio=0.8)
        s = make(d, ssize=3000, rsize=60000, columns=2, matchratio=0.8, compression="snappy")
        _, chunks = metadata(s.probe_path)
        assert {c[5] for c in chunks} == {"SNAPPY"}
        _, chunks = metadata(u.probe_path)
        assert {c[5] for c in chunks} == {"UNCOMPRESSED"}
        cu, cs = read_columns(u.probe_path), read_columns(s.probe_path)
        assert all(np.array_equal(cu[k], cs[k]) for k in cu)
        assert (u.expected_rows, u.expected_sums) == (s.expected_rows, s.expected_sums)
        assert s.probe_path.stat().st_size < u.probe_path.stat().st_size
    with tmpdir() as d:
        # few distinct values: DuckDB dictionary-encodes by default, encoding='plain' prevents it
        auto = make(d, ssize=50, rsize=30000, columns=1, zipffactor=0.0)
        plain = make(d, ssize=50, rsize=30000, columns=1, zipffactor=0.0, encoding="plain")
        assert auto.probe_encodings["key"] == ["PLAIN_DICTIONARY"], auto.probe_encodings
        assert auto.probe_meta["pages"]["key"]["dict_row_groups"] == len(auto.probe_row_groups)
        assert plain.probe_encodings["key"] == ["PLAIN"] and plain.probe_encodings["c1"] == ["PLAIN"]
        assert plain.probe_meta["pages"]["key"]["dict_row_groups"] == 0
        # build side key: all distinct, never a dictionary
        assert auto.build_meta["encodings"]["key"] == ["PLAIN"]
        assert (auto.expected_rows, auto.expected_sums) == (plain.expected_rows, plain.expected_sums)


def test_expected_matches_independent_sql():
    cases = [dict(matchratio=1.0, zipffactor=0.0), dict(matchratio=0.4, zipffactor=0.0),
             dict(matchratio=0.4, zipffactor=1.2), dict(matchratio=0.0, zipffactor=1.0),
             dict(matchratio=1.0, zipffactor=1.0, compression="snappy")]
    for extra in cases:
        with tmpdir() as d:
            ds = make(d, ssize=7000, rsize=150000, columns=3, batchsize=40000, **extra)
            rows, key_sum, sums = sql_expected(ds, 3)
            assert (ds.expected_rows, ds.expected_key_sum, ds.expected_sums) == (rows, key_sum, sums), extra
            assert ds.probe_meta["expected"]["matches"] == rows


def test_hand_checked_tiny_join():
    # Build = 0..99.  Probe written by hand with the same writer + verifier.
    with tmpdir() as d:
        keys = np.array([3, 150, 99, 100, 0, 3, 1000, 50], dtype=np.int64)
        c1 = np.array([10, 20, 30, 40, 50, 60, 70, 80], dtype=np.int64)
        path = d / "probe.parquet"
        gd._write_parquet(path, ["key", "c1"], [keys, c1], 3, "uncompressed", "auto", d / "t")
        info = gd.inspect_and_verify(path, ["key", "c1"], 8, "uncompressed")
        assert info["row_groups"] == [3, 3, 2]
        build = np.arange(100, dtype=np.int64)
        bpath = d / "build.parquet"
        gd._write_parquet(bpath, ["key"], [build], 100, "uncompressed", "auto", d / "t")
        con = duckdb.connect()
        got = con.execute("SELECT count(*), sum(p.key), sum(p.c1) FROM read_parquet(?) p "
                          "JOIN read_parquet(?) b ON p.key = b.key", [str(path), str(bpath)]).fetchone()
        # matching rows: keys 3, 99, 0, 3, 50 -> payloads 10, 30, 50, 60, 80
        assert got == (5, 155, 230), got
    # Generated tiny case, expected result recomputed by a plain Python loop over the file rows.
    with tmpdir() as d:
        ds = make(d, ssize=100, rsize=40, matchratio=0.5, zipffactor=0.0, columns=2, batchsize=16)
        assert ds.probe_row_groups == [16, 16, 8] and ds.build_row_groups == [16] * 6 + [4]
        cols = read_columns(ds.probe_path)
        rows = list(zip(cols["key"].tolist(), cols["c1"].tolist(), cols["c2"].tolist()))
        hit = [r for r in rows if 0 <= r[0] < 100]
        assert ds.expected_rows == len(hit)
        assert ds.expected_key_sum == sum(r[0] for r in hit)
        assert ds.expected_sums == [sum(r[1] for r in hit), sum(r[2] for r in hit)]
        assert all(r[0] >= 100 for r in rows if r not in hit)
        assert all(0 <= r[1] < 40 and 0 <= r[2] < 40 for r in rows)


def test_verifier_rejects_unusable_files():
    with tmpdir() as d:
        con = duckdb.connect()
        con.execute("SET disabled_optimizers = 'statistics_propagation'")
        a = np.arange(5000, dtype=np.int64)
        con.register("src", {"key": a})

        def write(name, opts, query="SELECT * FROM src"):
            p = d / name
            con.execute(f"COPY ({query}) TO '{p}' (FORMAT parquet, {opts})")
            return p

        ok = write("ok.parquet", "COMPRESSION uncompressed, ROW_GROUP_SIZE 2048")
        gd.inspect_and_verify(ok, ["key"], 5000, "uncompressed")
        # a NULL
        p = write("null.parquet", "COMPRESSION uncompressed",
                  "SELECT CASE WHEN key = 7 THEN NULL ELSE key END AS key FROM src")
        assert raises(gd.ParquetFormatError, gd.inspect_and_verify, p, ["key"], 5000, "uncompressed")
        # wrong type
        p = write("int32.parquet", "COMPRESSION uncompressed", "SELECT key::INTEGER AS key FROM src")
        assert raises(gd.ParquetFormatError, gd.inspect_and_verify, p, ["key"], 5000, "uncompressed")
        # Parquet V2 turns on DELTA_BINARY_PACKED
        p = write("v2.parquet", "COMPRESSION uncompressed, PARQUET_VERSION V2")
        assert raises(gd.ParquetFormatError, gd.inspect_and_verify, p, ["key"], 5000, "uncompressed")
        # row group above the hardware limit
        con.register("big", {"key": np.arange(200000, dtype=np.int64)})
        p = write("big.parquet", "COMPRESSION uncompressed, ROW_GROUP_SIZE 200000", "SELECT * FROM big")
        assert raises(gd.ParquetFormatError, gd.inspect_and_verify, p, ["key"], 200000, "uncompressed")
        # unexpected codec
        p = write("zstd.parquet", "COMPRESSION zstd")
        assert raises(gd.ParquetFormatError, gd.inspect_and_verify, p, ["key"], 5000, "uncompressed")
        # thrift parser sanity: a v1 data page header with a statistics struct (field 5) is visible
        hdr = bytes([0x15, 0x00, 0x15, 0x80, 0x01, 0x15, 0x80, 0x01,           # type, sizes
                     0x2C, 0x15, 0x08, 0x15, 0x00, 0x15, 0x06, 0x15, 0x06,    # DataPageHeader 1..4
                     0x1C, 0x00, 0x00, 0x00])                                  # statistics {}, ends
        parsed, n = gd.parse_page_header(hdr)
        assert parsed[1] == 0 and parsed[5][1] == 4 and parsed[5][5] == {} and n == len(hdr)


def test_timing_large():
    """ssize 2^20, rsize 2^24, 4 payload columns (defaults z=1, m=1, batch 120000) in a fresh process."""
    if os.environ.get("OASIS_SKIP_TIMING"):
        return
    with tmpdir() as d:
        script = Path(gd.__file__)
        r = subprocess.run([sys.executable, str(script), "--data-dir", str(d), "--ssize", str(1 << 20),
                            "--rsize", str(1 << 24), "--columns", "4", "--json"],
                           capture_output=True, text=True, check=True)
        res = json.loads(r.stdout.strip().splitlines()[-1])
        print(f"  timing: ssize=2^20 rsize=2^24 columns=4: {res['seconds']:.1f} s, "
              f"peak RSS {res['peak_rss_mb']:.0f} MB, probe row groups {len(res['probe_row_groups'])} "
              f"x {res['probe_row_groups'][0]}, last {res['probe_row_groups'][-1]}")
        assert res["expected_rows"] == 1 << 24
        assert set(res["probe_row_groups"][:-1]) == {120000}
        assert res["peak_rss_mb"] < 12 * 1024
        # second call is a pure cache hit
        r2 = subprocess.run([sys.executable, str(script), "--data-dir", str(d), "--ssize", str(1 << 20),
                             "--rsize", str(1 << 24), "--columns", "4", "--json"],
                            capture_output=True, text=True, check=True)
        res2 = json.loads(r2.stdout.strip().splitlines()[-1])
        assert res2["expected_sums"] == res["expected_sums"] and res2["seconds"] < 5.0
        print(f"  timing: cached call {res2['seconds']:.2f} s")


def main() -> int:
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"PASS {name}")
        except Exception:
            import traceback
            failed += 1
            print(f"FAIL {name}")
            traceback.print_exc()
    print(f"{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

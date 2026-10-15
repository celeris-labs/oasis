#!/usr/bin/env python3
"""Synthetic build/probe Parquet files for the oasis Bloom-filter join benchmark.

Mirrors celeris/examples/06_bloomfilter (prepare_inputs + celeris/types/generators.cpp):
  S (build): one INT64 column `key`, sequential 0..ssize-1.
  R (probe): `key` (foreign key into S) followed by `c1..cN` INT64 payload columns, c_i uniform in
             [0, rsize), one independent RNG stream per column (seed 43 + i); key stream seed 43.
Only the distributions match celeris, not the bit patterns (numpy PCG64 instead of mt19937_64).

Key distribution of R, card = ssize, m = matchratio, z = zipffactor:
  z == 0   m == 1: uniform [0, card).  0 < m < 1: with probability m uniform [0, card), otherwise
           uniform [card, floor(card/m) - 1] (clamped to at least card).  m == 0: uniform [card, 2^62].
  z > 0    a match is a discrete Zipf over ranks 0..card-1 (weight 1/(i+1)^z, key = rank).  m == 1:
           only those.  Otherwise with probability m a match, else card + Zipf over
           max(1, floor(card * (1 - m) / m)) ranks.  m == 0: celeris would allocate SIZE_MAX weights;
           here the non-match Zipf has `card` ranks instead (documented deviation).
  Large Zipf domains: the first ZIPF_EXACT_RANKS (2^24) ranks use an exact CDF + searchsorted; the
  ranks above are sampled from the continuous integral of x^-z over (K + 0.5, N + 0.5], mixed in by
  the tail's mass (inverse CDF), so memory stays bounded (<= ~135 MB per Zipf domain).

Files are written with DuckDB (never pyarrow: its page-header statistics break the ParCore decoder).
Every column is INT64, OPTIONAL, with zero NULLs and null_count == 0 statistics.  Row groups are cut
to exactly the batch size where DuckDB allows it (see `_write_parquet`); the real sizes are always
read back from parquet_metadata and returned.  Every written file is verified (schema, null counts,
row-group sizes <= 131072, thrift page headers: v1 data pages, no statistics, known encodings).

Cache: files are keyed by their own parameters; a `.json` sidecar next to each file holds the
parameters, the real row-group sizes, per-column encodings and (probe) the expected join result.

Usage:
  gen_data.py --data-dir DIR [--ssize N --rsize N --matchratio F --zipffactor F --columns N
                              --file-columns N --batchsize N | --numbatches N
                              --compression uncompressed|snappy --encoding auto|plain]
"""
from __future__ import annotations

import argparse
import fcntl
import json
import math
import os
import struct
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import duckdb
import numpy as np

GENERATOR_VERSION = "oasis-bench-gen/1"

# ParCore holds the mask of one probe row group: BLOOM_MAX_PROBE_ROWS in oasis_hardware_bloom.hpp.
MAX_ROW_GROUP_ROWS = 131072
DEFAULT_BATCHSIZE = 120000  # celeris -b default
STANDARD_VECTOR_SIZE = 2048  # DuckDB's chunk size; row groups are cut at multiples of it
CHUNK_ROWS = 1 << 20  # rows generated per RNG call (<= 2^22); part of the file content definition
ZIPF_EXACT_RANKS = 1 << 24  # ranks with an exact CDF; the rest uses the integral approximation
SEED_KEY = 43  # celeris: probe table seed; payload column i uses SEED_KEY + i
MAX_NONMATCH_KEY = 1 << 62
# One UNION ALL branch per row group makes DuckDB cut exactly at the batch size; each branch costs a
# pipeline (~0.4 MB, ~2 ms), so beyond this many row groups the writer falls back to ROW_GROUP_SIZE.
MAX_UNION_BRANCHES = 4096
# The generated columns live in numpy memory until the COPY is done.
MAX_INMEMORY_BYTES = 10 << 30
COPY_THREADS = int(os.environ.get("OASIS_GEN_THREADS", "1"))

COMPRESSIONS = ("uncompressed", "snappy")
ENCODINGS = ("auto", "plain")

PAGE_TYPE_DATA, PAGE_TYPE_DICT = 0, 2
ENC_PLAIN, ENC_PLAIN_DICTIONARY, ENC_RLE, ENC_RLE_DICTIONARY = 0, 2, 3, 8
ENC_NAMES = {0: "PLAIN", 2: "PLAIN_DICTIONARY", 3: "RLE", 4: "BIT_PACKED", 5: "DELTA_BINARY_PACKED",
             6: "DELTA_LENGTH_BYTE_ARRAY", 7: "DELTA_BYTE_ARRAY", 8: "RLE_DICTIONARY",
             9: "BYTE_STREAM_SPLIT"}


# ---------------------------------------------------------------------------------------------
# Parameters and batching
# ---------------------------------------------------------------------------------------------

@dataclass(frozen=True)
class DataParams:
    ssize: int
    rsize: int
    matchratio: float = 0.01
    zipffactor: float = 1.0
    columns: int = 2  # payload columns the query will use
    file_columns: int | None = None  # payload columns in the probe file (None -> columns)
    batchsize: int | None = DEFAULT_BATCHSIZE
    numbatches: int | None = None
    compression: str = "uncompressed"
    encoding: str = "auto"

    def __post_init__(self):
        if self.ssize < 1 or self.rsize < 1:
            raise ValueError("ssize and rsize must be >= 1")
        if not 0.0 <= self.matchratio <= 1.0:
            raise ValueError(f"matchratio must be in [0, 1], got {self.matchratio}")
        if self.zipffactor < 0.0:
            raise ValueError(f"zipffactor must be >= 0, got {self.zipffactor}")
        if self.columns < 0:
            raise ValueError("columns must be >= 0")
        if self.file_columns is not None and self.file_columns < self.columns:
            raise ValueError(f"file_columns ({self.file_columns}) < columns ({self.columns})")
        if self.compression not in COMPRESSIONS:
            raise ValueError(f"compression must be one of {COMPRESSIONS}, got {self.compression!r}")
        if self.encoding not in ENCODINGS:
            raise ValueError(f"encoding must be one of {ENCODINGS}, got {self.encoding!r}")

    @property
    def probe_file_columns(self) -> int:
        return self.columns if self.file_columns is None else self.file_columns


@dataclass
class Dataset:
    build_path: Path
    probe_path: Path
    build_row_groups: list[int]
    probe_row_groups: list[int]
    expected_rows: int
    expected_sums: list[int]  # for c1..c_columns, over matching rows
    expected_key_sum: int
    probe_encodings: dict  # column -> distinct chunk encodings, e.g. {'key': ['PLAIN'], 'c1': ['PLAIN_DICTIONARY']}
    build_meta: dict  # sidecar contents
    probe_meta: dict


def resolve_batching(params: DataParams) -> tuple[int, int]:
    """(build_batch_rows, probe_batch_rows).  Same rules as the celeris binary.

    -b and -n are mutually exclusive.  batchsize == 120000 (the default) counts as "not given", so
    DataParams(numbatches=4) works; any other batchsize together with numbatches is an error.
    With numbatches every relation is split into batches of max(ceil(size / numbatches), 1) rows.
    Both batch sizes must be in [1, 131072].
    """
    bs, nb = params.batchsize, params.numbatches
    if nb is not None:
        if bs is not None and bs != DEFAULT_BATCHSIZE:
            raise ValueError("batchsize and numbatches are mutually exclusive")
        if nb < 1:
            raise ValueError("numbatches must be > 0")
        build = max(-(-params.ssize // nb), 1)
        probe = max(-(-params.rsize // nb), 1)
    else:
        if bs is None:
            raise ValueError("either batchsize or numbatches is required")
        if bs < 1:
            raise ValueError("batchsize must be > 0")
        build = probe = bs
    for what, rows in (("build", build), ("probe", probe)):
        if rows > MAX_ROW_GROUP_ROWS:
            raise ValueError(f"{what} row group of {rows} rows exceeds the hardware limit of "
                             f"{MAX_ROW_GROUP_ROWS} rows")
    return build, probe


# ---------------------------------------------------------------------------------------------
# Random data
# ---------------------------------------------------------------------------------------------

class ZipfSampler:
    """Discrete Zipf over ranks 0..n-1, weight 1/(rank+1)^z; exact CDF for the first `exact` ranks."""

    def __init__(self, n: int, z: float, exact: int = ZIPF_EXACT_RANKS):
        assert n >= 1 and z > 0
        self.n = n
        self.z = z
        self.k = min(n, exact)
        cdf = np.arange(1, self.k + 1, dtype=np.float64)
        np.power(cdf, -z, out=cdf)
        np.cumsum(cdf, out=cdf)
        self.cdf = cdf
        self.head_mass = float(cdf[-1])
        self.tail_mass = 0.0
        if n > self.k:
            self.a, self.b = self.k + 0.5, n + 0.5
            if z == 1.0:
                self.tail_mass = math.log(self.b / self.a)
            else:
                p = 1.0 - z
                self.tail_mass = (self.b ** p - self.a ** p) / p
        self.total = self.head_mass + self.tail_mass

    def sample(self, u: np.ndarray) -> np.ndarray:
        """Ranks (int64) for uniform u in [0, 1)."""
        t = u * self.total
        ranks = np.searchsorted(self.cdf, t, side="right")
        np.minimum(ranks, self.k - 1, out=ranks)
        ranks = ranks.astype(np.int64, copy=False)
        if self.tail_mass > 0.0:
            in_tail = t >= self.head_mass
            if in_tail.any():
                v = (t[in_tail] - self.head_mass) / self.tail_mass
                if self.z == 1.0:
                    x = self.a * np.exp(v * math.log(self.b / self.a))
                else:
                    p = 1.0 - self.z
                    ap, bp = self.a ** p, self.b ** p
                    x = (ap + v * (bp - ap)) ** (1.0 / p)
                tail = np.floor(x - 0.5).astype(np.int64)
                np.clip(tail, self.k, self.n - 1, out=tail)
                ranks[in_tail] = tail
        return ranks


class KeyGenerator:
    """Probe-key stream of celeris generate_uni_column / generate_zipf_column (distributionally)."""

    def __init__(self, card: int, match_ratio: float, zipf: float, seed: int = SEED_KEY,
                 zipf_exact: int = ZIPF_EXACT_RANKS):
        self.card, self.m, self.z = card, match_ratio, zipf
        self.rng = np.random.Generator(np.random.PCG64(seed))
        self.match_zipf = self.nonmatch_zipf = None
        if zipf > 0:
            if match_ratio > 0:
                self.match_zipf = ZipfSampler(card, zipf, zipf_exact)
            if match_ratio < 1:
                if match_ratio == 0:
                    nm = card  # celeris: SIZE_MAX weights; bounded here
                else:
                    nm = max(1, int(math.floor(card * (1.0 - match_ratio) / match_ratio)))
                nm = min(nm, MAX_NONMATCH_KEY - card)
                self.nonmatch_zipf = ZipfSampler(nm, zipf, zipf_exact)
        else:
            if 0 < match_ratio < 1:
                hi = int(math.floor(card / match_ratio)) - 1
                self.uni_hi = min(max(hi, card), MAX_NONMATCH_KEY)

    def draw(self, n: int) -> np.ndarray:
        rng, card, m = self.rng, self.card, self.m
        if self.z == 0:
            if m == 1:
                return rng.integers(0, card, n, dtype=np.int64)
            if m == 0:
                return rng.integers(card, MAX_NONMATCH_KEY, n, dtype=np.int64, endpoint=True)
            sel = rng.random(n) < m
            k = int(np.count_nonzero(sel))
            out = np.empty(n, dtype=np.int64)
            out[sel] = rng.integers(0, card, k, dtype=np.int64)
            out[~sel] = rng.integers(card, self.uni_hi, n - k, dtype=np.int64, endpoint=True)
            return out
        if m == 1:
            return self.match_zipf.sample(rng.random(n))
        sel = rng.random(n) < m
        u = rng.random(n)
        out = np.empty(n, dtype=np.int64)
        if m > 0:
            out[sel] = self.match_zipf.sample(u[sel])
        out[~sel] = card + self.nonmatch_zipf.sample(u[~sel])
        return out


def _generate_probe(ssize: int, rsize: int, m: float, z: float, file_columns: int,
                    log: Callable[[str], None]):
    """Returns (arrays [key, c1..cN], expected dict).  Chunked; expected results use Python ints."""
    nbytes = rsize * (1 + file_columns) * 8
    if nbytes > MAX_INMEMORY_BYTES:
        raise MemoryError(f"probe data of {nbytes / 2**30:.1f} GiB exceeds MAX_INMEMORY_BYTES "
                          f"({MAX_INMEMORY_BYTES / 2**30:.0f} GiB)")
    keygen = KeyGenerator(ssize, m, z)
    col_rngs = [np.random.Generator(np.random.PCG64(SEED_KEY + i)) for i in range(1, file_columns + 1)]
    key = np.empty(rsize, dtype=np.int64)
    cols = [np.empty(rsize, dtype=np.int64) for _ in range(file_columns)]
    matches, key_sum, sums = 0, 0, [0] * file_columns
    for lo in range(0, rsize, CHUNK_ROWS):
        hi = min(rsize, lo + CHUNK_ROWS)
        n = hi - lo
        k = keygen.draw(n)
        key[lo:hi] = k
        mask = k < ssize
        cnt = int(np.count_nonzero(mask))
        matches += cnt
        key_sum += int(np.add.reduce(k, where=mask, dtype=np.uint64, initial=0))
        for i, rng in enumerate(col_rngs):
            v = rng.integers(0, rsize, n, dtype=np.int64)
            cols[i][lo:hi] = v
            sums[i] += int(np.add.reduce(v, where=mask, dtype=np.uint64, initial=0))
    return [key] + cols, {"matches": matches, "key_sum": key_sum, "sums": sums}


# ---------------------------------------------------------------------------------------------
# Thrift compact protocol (page headers only) and file verification
# ---------------------------------------------------------------------------------------------

def _tc_varint(b: bytes, p: int):
    r = s = 0
    while True:
        x = b[p]
        p += 1
        r |= (x & 0x7F) << s
        s += 7
        if not x & 0x80:
            return r, p


def _tc_value(b: bytes, p: int, t: int):
    if t == 1:
        return True, p
    if t == 2:
        return False, p
    if t == 3:
        return b[p], p + 1
    if t in (4, 5, 6):
        v, p = _tc_varint(b, p)
        return (v >> 1) ^ -(v & 1), p
    if t == 7:
        return struct.unpack("<d", b[p:p + 8])[0], p + 8
    if t == 8:
        n, p = _tc_varint(b, p)
        return bytes(b[p:p + n]), p + n
    if t in (9, 10):
        h = b[p]
        p += 1
        n, et = h >> 4, h & 15
        if n == 15:
            n, p = _tc_varint(b, p)
        out = []
        for _ in range(n):
            v, p = _tc_value(b, p, et)
            out.append(v)
        return out, p
    if t == 12:
        return _tc_struct(b, p)
    raise ValueError(f"unsupported thrift compact type {t}")


def _tc_struct(b: bytes, p: int):
    d, fid = {}, 0
    while True:
        h = b[p]
        p += 1
        if h == 0:
            return d, p
        t, delta = h & 15, h >> 4
        if delta == 0:
            v, p = _tc_varint(b, p)
            fid = (v >> 1) ^ -(v & 1)
        else:
            fid += delta
        d[fid], p = _tc_value(b, p, t)


def parse_page_header(buf: bytes, off: int = 0) -> tuple[dict, int]:
    """Thrift PageHeader as {field_id: value} (nested structs likewise) and its length in bytes."""
    d, end = _tc_struct(buf, off)
    return d, end - off


class ParquetFormatError(RuntimeError):
    pass


MAX_PAGE_WALK_CHUNKS = 20000  # beyond this many column chunks, every k-th chunk is walked


def _check_chunk_pages(f, path, rg, col, start, total, num_values, expect_dict_allowed=True) -> dict:
    """Walks all pages of one column chunk and checks that the ParCore parser can read them."""
    pos, end = start, start + total
    seen_values, dict_pages, data_encs = 0, 0, set()
    while pos < end:
        f.seek(pos)
        raw = f.read(128)
        hdr, hlen = parse_page_header(raw)
        where = f"{path} row group {rg} column {col} page at {pos}"
        ptype = hdr.get(1)
        comp = hdr.get(3)
        if ptype == PAGE_TYPE_DATA:
            dph = hdr.get(5)
            if dph is None or 8 in hdr or 6 in hdr:
                raise ParquetFormatError(f"{where}: not a v1 data page: {hdr}")
            if 5 in dph:
                raise ParquetFormatError(f"{where}: DataPageHeader carries statistics (field 5): {hdr}")
            if set(dph) - {1, 2, 3, 4}:
                raise ParquetFormatError(f"{where}: unexpected DataPageHeader fields: {hdr}")
            enc = dph.get(2)
            if enc not in (ENC_PLAIN, ENC_PLAIN_DICTIONARY, ENC_RLE_DICTIONARY):
                raise ParquetFormatError(f"{where}: unsupported data encoding {ENC_NAMES.get(enc, enc)}")
            if dph.get(3) != ENC_RLE or dph.get(4) != ENC_RLE:
                raise ParquetFormatError(f"{where}: level encodings {dph.get(3)}/{dph.get(4)} != RLE")
            seen_values += dph[1]
            data_encs.add(ENC_NAMES[enc])
        elif ptype == PAGE_TYPE_DICT:
            dh = hdr.get(7)
            if dh is None or not expect_dict_allowed or dh.get(2) not in (ENC_PLAIN, ENC_PLAIN_DICTIONARY):
                raise ParquetFormatError(f"{where}: bad dictionary page header: {hdr}")
            dict_pages += 1
        else:
            raise ParquetFormatError(f"{where}: unsupported page type {ptype}: {hdr}")
        if 4 in hdr:
            raise ParquetFormatError(f"{where}: page CRC present: {hdr}")
        pos += hlen + comp
    if pos != end:
        raise ParquetFormatError(f"{path} row group {rg} column {col}: pages end at {pos}, chunk at {end}")
    if seen_values != num_values:
        raise ParquetFormatError(f"{path} row group {rg} column {col}: pages hold {seen_values} values, "
                                 f"metadata says {num_values}")
    return {"dict_pages": dict_pages, "data_encodings": sorted(data_encs)}


def inspect_and_verify(path: Path, column_names: list[str], num_rows: int, compression: str) -> dict:
    """Reads the file back; raises ParquetFormatError unless it is what ParCore needs.

    Checks: leaf columns == column_names, all INT64 and OPTIONAL; every column chunk has
    stats_null_count == 0; compression; row group sizes in [1, 131072] summing to num_rows; every
    page header (thrift) is a v1 data/dictionary page without statistics.
    Returns {'row_groups', 'encodings' (column -> distinct chunk encodings, as DuckDB prints them),
    'encoding_row_groups' (column -> {encodings: number of row groups}), 'pages', 'file_size'}.
    """
    path = Path(path)
    con = duckdb.connect()
    try:
        schema = con.execute(
            "SELECT name, type, repetition_type FROM parquet_schema(?) WHERE num_children IS NULL",
            [str(path)]).fetchall()
        if [s[0] for s in schema] != column_names:
            raise ParquetFormatError(f"{path}: columns {[s[0] for s in schema]} != {column_names}")
        for name, typ, rep in schema:
            if typ != "INT64" or rep != "OPTIONAL":
                raise ParquetFormatError(f"{path}: column {name} is {typ} {rep}, need INT64 OPTIONAL")

        ncols = len(column_names)
        cur = con.execute(
            """SELECT row_group_id, column_id, row_group_num_rows, num_values, stats_null_count,
                      compression, encodings, dictionary_page_offset, data_page_offset,
                      total_compressed_size
               FROM parquet_metadata(?) ORDER BY row_group_id, column_id""", [str(path)])
        rows = cur.fetchall()
    finally:
        con.close()

    if len(rows) % ncols:
        raise ParquetFormatError(f"{path}: {len(rows)} column chunks is not a multiple of {ncols} columns")
    row_groups: list[int] = []
    enc_counts: dict[str, dict[str, int]] = {c: {} for c in column_names}
    n_chunks = len(rows)
    stride = max(1, n_chunks // MAX_PAGE_WALK_CHUNKS)
    pages = {c: {"dict_row_groups": 0, "data_encodings": set()} for c in column_names}
    want_comp = compression.upper()
    with open(path, "rb") as f:
        for idx, (rg, col, rg_rows, nvals, nulls, comp, encs, dict_off, data_off, total) in enumerate(rows):
            if col == 0:
                row_groups.append(rg_rows)
                if not 1 <= rg_rows <= MAX_ROW_GROUP_ROWS:
                    raise ParquetFormatError(f"{path}: row group {rg} has {rg_rows} rows "
                                             f"(limit {MAX_ROW_GROUP_ROWS})")
            if nulls is None or nulls != 0:
                raise ParquetFormatError(f"{path}: row group {rg} column {column_names[col]}: "
                                         f"stats_null_count = {nulls}")
            if nvals != rg_rows:
                raise ParquetFormatError(f"{path}: row group {rg} column {col}: {nvals} != {rg_rows} values")
            if comp != want_comp:
                raise ParquetFormatError(f"{path}: row group {rg} column {col}: compression {comp}, "
                                         f"expected {want_comp}")
            ec = enc_counts[column_names[col]]
            ec[encs] = ec.get(encs, 0) + 1
            if idx % stride == 0 or rg < 2:
                start = dict_off if dict_off is not None else data_off
                info = _check_chunk_pages(f, path, rg, column_names[col], start, total, nvals)
                pages[column_names[col]]["dict_row_groups"] += info["dict_pages"]
                pages[column_names[col]]["data_encodings"].update(info["data_encodings"])
    if sum(row_groups) != num_rows:
        raise ParquetFormatError(f"{path}: {sum(row_groups)} rows in row groups, expected {num_rows}")
    for v in pages.values():
        v["data_encodings"] = sorted(v["data_encodings"])
    return {"row_groups": row_groups, "encodings": {c: sorted(v) for c, v in enc_counts.items()},
            "encoding_row_groups": enc_counts, "pages": pages, "file_size": path.stat().st_size,
            "walked_every": stride}


# ---------------------------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------------------------

def _sql_str(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def _write_parquet(path: Path, names: list[str], arrays: list[np.ndarray], batch_rows: int,
                   compression: str, encoding: str, tmp_dir: Path) -> dict:
    """COPY the numpy columns to `path` with DuckDB.  Returns {'union_branches': n or 0}.

    DuckDB's Parquet writer closes a row group at the first 2048-row chunk boundary at or after
    ROW_GROUP_SIZE rows, so ROW_GROUP_SIZE = 120000 yields 120832-row groups.  The input chunks
    never span two UNION ALL branches (each branch ends with a short chunk), so one branch per batch
    makes every row group exactly `batch_rows` (the last one the remainder).  When batch_rows is a
    multiple of 2048, or there is a single batch, plain ROW_GROUP_SIZE is already exact.  With more
    than MAX_UNION_BRANCHES batches that are not 2048-aligned the groups are rounded up to the next
    multiple of 2048 (never above 131072).
    """
    n = len(arrays[0])
    n_batches = -(-n // batch_rows)
    con = duckdb.connect()
    try:
        con.execute(f"SET threads = {COPY_THREADS}")
        con.execute("SET preserve_insertion_order = true")
        # Bundled DuckDB versions write REQUIRED columns when statistics prove NOT NULL
        con.execute("SET disabled_optimizers = 'statistics_propagation'")
        tmp_dir.mkdir(parents=True, exist_ok=True)
        con.execute(f"SET temp_directory = {_sql_str(str(tmp_dir))}")

        exact_without_union = batch_rows % STANDARD_VECTOR_SIZE == 0 or n_batches == 1
        union = (not exact_without_union) and n_batches <= MAX_UNION_BRANCHES
        branches = 0
        if union:
            parts = []
            for i in range(n_batches):
                lo, hi = i * batch_rows, min(n, (i + 1) * batch_rows)
                con.register(f"b{i}", {nm: a[lo:hi] for nm, a in zip(names, arrays)})
                parts.append(f"SELECT * FROM b{i}")
            query = " UNION ALL ".join(parts)
            branches = n_batches
        else:
            con.register("b0", dict(zip(names, arrays)))
            query = "SELECT * FROM b0"
        opts = ["FORMAT parquet", f"COMPRESSION {compression}", f"ROW_GROUP_SIZE {batch_rows}",
                "PARQUET_VERSION V1"]  # V2 turns on DELTA_BINARY_PACKED / BYTE_STREAM_SPLIT
        if encoding == "plain":
            opts.append("DICTIONARY_SIZE_LIMIT 0")
        con.execute(f"COPY ({query}) TO {_sql_str(str(path))} ({', '.join(opts)})")
    finally:
        con.close()
    return {"union_branches": branches}


def _atomic_json(path: Path, obj: dict) -> None:
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with open(tmp, "w") as f:
        json.dump(obj, f, sort_keys=True)
        f.write("\n")
    os.replace(tmp, path)


def _sidecar(path: Path) -> Path:
    return path.with_name(path.name + ".json")


def _load_cached(path: Path, params: dict) -> dict | None:
    side = _sidecar(path)
    try:
        meta = json.loads(side.read_text())
        if (meta.get("generator_version") != GENERATOR_VERSION or meta.get("params") != params
                or not path.is_file() or path.stat().st_size != meta.get("file_size")):
            return None
        return meta
    except (OSError, ValueError):
        return None


def _num(x: float) -> str:
    return repr(float(x))


def build_filename(ssize: int, batch: int, comp: str, encoding: str = "auto") -> str:
    suffix = "" if encoding == "auto" else f"_{encoding}"
    return f"build_s{ssize}_b{batch}_{comp}{suffix}.parquet"


def probe_filename(rsize: int, ssize: int, m: float, z: float, file_columns: int, batch: int,
                   comp: str, encoding: str = "auto") -> str:
    suffix = "" if encoding == "auto" else f"_{encoding}"
    return (f"probe_r{rsize}_s{ssize}_m{_num(m)}_z{_num(z)}_c{file_columns}_b{batch}_{comp}{suffix}"
            ".parquet")


def _ensure_file(path: Path, params: dict, log, make_arrays) -> dict:
    """Cache-or-generate one file.  make_arrays() -> (names, arrays, expected_or_None, batch_rows)."""
    meta = _load_cached(path, params)
    if meta is not None:
        log(f"reusing {path.name}")
        return meta
    data_dir = path.parent
    fd = os.open(data_dir, os.O_RDONLY)  # serialize generators working in the same directory
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        meta = _load_cached(path, params)
        if meta is not None:
            log(f"reusing {path.name}")
            return meta
        t0 = time.time()
        names, arrays, expected, batch_rows = make_arrays()
        t_gen = time.time() - t0
        tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
        tmp_dir = data_dir / f".duckdb_tmp_{os.getpid()}"
        try:
            t1 = time.time()
            wr = _write_parquet(tmp, names, arrays, batch_rows, params["compression"],
                                params["encoding"], tmp_dir)
            t_write = time.time() - t1
            info = inspect_and_verify(tmp, names, len(arrays[0]), params["compression"])
            rgs = info["row_groups"]
            if any(rg != batch_rows for rg in rgs[:-1]) or rgs[-1] > batch_rows:
                log(f"warning: {path.name}: row groups are not exactly {batch_rows} rows "
                    f"(sizes {sorted(set(rgs))[:4]}); DuckDB rounds to its 2048-row vector size")
            side = _sidecar(path)
            if side.exists():
                side.unlink()  # a sidecar must never describe a file that is being replaced
            os.replace(tmp, path)
        finally:
            if tmp.exists():
                tmp.unlink()
            if tmp_dir.exists():
                for p in tmp_dir.iterdir():
                    p.unlink()
                tmp_dir.rmdir()
        meta = {
            "generator_version": GENERATOR_VERSION,
            "file": path.name,
            "params": params,
            "columns": names,
            "num_rows": len(arrays[0]),
            "batch_rows": batch_rows,
            "row_groups": info["row_groups"],
            "encodings": info["encodings"],
            "encoding_row_groups": info["encoding_row_groups"],
            "pages": info["pages"],
            "file_size": info["file_size"],
            "union_branches": wr["union_branches"],
            "expected": expected,
            "duckdb_version": duckdb.__version__,
            "numpy_version": np.__version__,
            "gen_seconds": round(t_gen, 3),
            "write_seconds": round(t_write, 3),
        }
        _atomic_json(_sidecar(path), meta)
        log(f"wrote {path.name}: {meta['num_rows']} rows, {len(info['row_groups'])} row groups, "
            f"{info['file_size'] / 2**20:.1f} MiB (generate {t_gen:.1f}s, write {t_write:.1f}s)")
        return meta
    finally:
        os.close(fd)  # also drops the flock


def ensure_dataset(data_dir, params: DataParams, *, log=print) -> Dataset:
    """Build and probe files for `params` in `data_dir` (generated on demand, cached by file)."""
    data_dir = Path(data_dir)
    data_dir.mkdir(parents=True, exist_ok=True)
    build_rows, probe_rows = resolve_batching(params)
    fc = params.probe_file_columns
    comp, enc = params.compression, params.encoding

    build_path = data_dir / build_filename(params.ssize, build_rows, comp, enc)
    build_params = {"kind": "build", "ssize": params.ssize, "batch": build_rows, "compression": comp,
                    "encoding": enc}

    def make_build():
        return ["key"], [np.arange(params.ssize, dtype=np.int64)], None, build_rows

    build_meta = _ensure_file(build_path, build_params, log, make_build)

    probe_path = data_dir / probe_filename(params.rsize, params.ssize, params.matchratio,
                                           params.zipffactor, fc, probe_rows, comp, enc)
    probe_params = {"kind": "probe", "rsize": params.rsize, "ssize": params.ssize,
                    "matchratio": float(params.matchratio), "zipffactor": float(params.zipffactor),
                    "file_columns": fc, "batch": probe_rows, "compression": comp, "encoding": enc,
                    "seed": SEED_KEY, "chunk_rows": CHUNK_ROWS, "zipf_exact_ranks": ZIPF_EXACT_RANKS}

    def make_probe():
        arrays, expected = _generate_probe(params.ssize, params.rsize, params.matchratio,
                                           params.zipffactor, fc, log)
        return ["key"] + [f"c{i}" for i in range(1, fc + 1)], arrays, expected, probe_rows

    probe_meta = _ensure_file(probe_path, probe_params, log, make_probe)
    exp = probe_meta["expected"]
    return Dataset(
        build_path=build_path, probe_path=probe_path,
        build_row_groups=list(build_meta["row_groups"]), probe_row_groups=list(probe_meta["row_groups"]),
        expected_rows=exp["matches"], expected_sums=list(exp["sums"][:params.columns]),
        expected_key_sum=exp["key_sum"], probe_encodings=probe_meta["encodings"],
        build_meta=build_meta, probe_meta=probe_meta)


# ---------------------------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------------------------

def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--data-dir", required=True, type=Path)
    ap.add_argument("--ssize", "-s", type=int, default=1 << 16, help="rows of S (build), default 2^16")
    ap.add_argument("--rsize", "-r", type=int, default=1 << 18, help="rows of R (probe), default 2^18")
    ap.add_argument("--matchratio", "-m", type=float, default=0.01)
    ap.add_argument("--zipffactor", "-z", type=float, default=1.0)
    ap.add_argument("--columns", "-c", type=int, default=2, help="payload columns the run uses")
    ap.add_argument("--file-columns", type=int, default=None,
                    help="payload columns in the probe file (default: --columns)")
    ap.add_argument("--batchsize", "-b", type=int, default=None,
                    help=f"rows per row group (default {DEFAULT_BATCHSIZE}); excludes --numbatches")
    ap.add_argument("--numbatches", "-n", type=int, default=None)
    ap.add_argument("--compression", choices=COMPRESSIONS, default="uncompressed")
    ap.add_argument("--encoding", choices=ENCODINGS, default="auto",
                    help="auto: DuckDB decides (dictionary when few distinct values); "
                         "plain: DICTIONARY_SIZE_LIMIT 0")
    ap.add_argument("--json", action="store_true", help="print the result as one JSON object")
    args = ap.parse_args(argv)

    if args.batchsize is not None and args.numbatches is not None:
        ap.error("--batchsize and --numbatches are mutually exclusive")
    batchsize = args.batchsize
    if batchsize is None and args.numbatches is None:
        batchsize = DEFAULT_BATCHSIZE
    try:
        params = DataParams(ssize=args.ssize, rsize=args.rsize, matchratio=args.matchratio,
                            zipffactor=args.zipffactor, columns=args.columns,
                            file_columns=args.file_columns, batchsize=batchsize,
                            numbatches=args.numbatches, compression=args.compression,
                            encoding=args.encoding)
        resolve_batching(params)
    except ValueError as e:
        ap.error(str(e))

    log = (lambda *_: None) if args.json else print
    t0 = time.time()
    ds = ensure_dataset(args.data_dir, params, log=log)
    secs = time.time() - t0
    import resource
    rss_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024
    if args.json:
        print(json.dumps({"build_path": str(ds.build_path), "probe_path": str(ds.probe_path),
                          "build_row_groups": ds.build_row_groups, "probe_row_groups": ds.probe_row_groups,
                          "expected_rows": ds.expected_rows, "expected_sums": ds.expected_sums,
                          "expected_key_sum": ds.expected_key_sum, "seconds": secs,
                          "peak_rss_mb": rss_mb}))
        return 0
    print(f"build:  {ds.build_path}  ({len(ds.build_row_groups)} row groups)")
    print(f"probe:  {ds.probe_path}  ({len(ds.probe_row_groups)} row groups)")
    print(f"expected rows (matches): {ds.expected_rows}")
    print(f"expected key sum:        {ds.expected_key_sum}")
    for i, s in enumerate(ds.expected_sums, 1):
        print(f"expected sum c{i}:        {s}")
    print(f"done in {secs:.1f} s, peak RSS {rss_mb:.0f} MB")
    return 0


if __name__ == "__main__":
    sys.exit(main())

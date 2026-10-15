"""TPC-H queries as Bloom filter join benchmarks: the data, the query and what a correct run looks like.

The synthetic benchmark (bench.py) joins two generated relations. This module is the counterpart for the TPC-H
queries the sweeps sweep_tpch_*.py run. A TPC-H query is described by a `Query`:

    * its build side, the table that has the query's predicate (Q17: part, with p_brand and p_container). The
      predicate is NOT part of the measured query. The table is written pre-filtered: only the qualifying rows,
      with every column, and the measured query joins that file without any predicate. The hardware Bloom
      filter is built from the build file's whole key column, so this is what lets it see exactly the keys
      the predicate selects (the best case of any scheme that sends filtered keys to the hardware)
    * its probe side, the big table the Bloom filter prunes (Q17: lineitem), written as it is
    * the query itself, over read_oasis() of the two files, and the same query in its original form (predicate in the
      WHERE clause, over the tables dbgen made) whose answer every run is checked against
    * optionally small side tables the query reads with DuckDB's own reader (Q20: supplier, nation), so that no
      second Bloom filter join is rewritten, and tables only the build predicate needs (Q20: part)

Q17, Q19 and Q20 are in QUERIES; each one's module docstring-sized decisions (what left the query, what the plan
is) are in the sweep script of the query (sweep_tpch_q17.py, sweep_tpch_q19.py, sweep_tpch_q20.py) and the README.

The data comes from DuckDB's dbgen (the `duckdb` Python package with the tpch extension, not pyarrow: its
page-header statistics break the decoder), written like scripts/tpch_optional.py does: every column OPTIONAL
with no NULLs and null_count statistics (what the pinned ParCore needs), row groups of at most 131072 rows.
generate() returns a TpchDataset; ensure_dataset() caches it in a directory by scale factor and compression.

TpchWorkload plugs a query into bench.run_benchmark (bench.Workload): the same script, the same statistics
(host times, decoder and Bloom filter throughputs), the same bench.yaml as the synthetic benchmark, so that the
sweeps' tables and plots are the same. What differs is where the decoder is measured, see TpchWorkload.check_run.
"""

import json
import math
import os
import shutil
import time
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Callable

import bench
from bench import BenchmarkError

GENERATOR_VERSION = "oasis-bench-tpch/1"
MAX_ROW_GROUP_ROWS = 131072  # ParCore holds the mask of one probe row group (gen_data.MAX_ROW_GROUP_ROWS)
COMPRESSIONS = ("uncompressed", "snappy")
TPCH_TABLES = ["region", "nation", "supplier", "customer", "part", "partsupp", "orders", "lineitem"]
# The fixed-width physical types of TPC-H (DATE is INT32, DECIMAL(15,2) is INT64), which the decoder outputs; a
# BYTE_ARRAY column (strings) is decoded on the CPU by DuckDB's reader, it is not in the decoder's output
BYTES_OF_TYPE = {"INT32": 4, "INT64": 8, "FLOAT": 4, "DOUBLE": 8, "BYTE_ARRAY": 0}
# The decoder output of the probe scans is checked against the columns the query reads: within this ratio. (A
# profiler segment boundary inside a flow loses some output beats, see README.md: a few % at most)
OUT_BYTES_TOLERANCE = 0.03


def _q(text):
    """A SQL string literal"""
    return "'" + str(text).replace("'", "''") + "'"


# ---------------------------------------------------------------------------
# The queries
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class Query:
    name: str                                # "q17": also the folder and the experiment's name
    title: str                               # for the docs and the plots
    build_table: str                         # written pre-filtered: only the rows that satisfy build_predicate
    build_predicate: str
    build_key: str                           # the join key of the two sides
    probe_table: str                         # written whole
    probe_key: str
    # (build file, probe file, {side table: file}) -> the query, no build side predicate. The side tables are
    # read with read_parquet, not read_oasis; a query without any takes (build, probe) only
    sql: Callable[..., str]
    reference_sql: str                       # the original query over the tables of the generating connection;
                                             # returns one row (its values are what every run's result is
                                             # compared with)
    probe_scans: tuple                       # the columns each scan of the probe file reads, one tuple per scan
    settings: dict = field(default_factory=dict)  # DuckDB settings to SET, for every variant alike
    extra_tables: tuple = ()                 # tables only build_predicate / reference_sql read (not written)
    side_tables: tuple = ()                  # tables the query reads (CPU reader), written whole to <table>.parquet

    @property
    def build_file(self):
        return f"{self.build_table}_{self.name}.parquet"

    @property
    def probe_file(self):
        return f"{self.probe_table}.parquet"

    def side_file(self, table):
        return f"{table}.parquet"


def q17_sql(build_path, probe_path, side=None):
    """TPC-H Q17 over read_oasis, with the build side's predicate (p_brand = 'Brand#23' AND p_container = 'MED
    BOX') left out: `part` is the file that has only the qualifying parts. The tables are inlined (no CTE) so that
    DuckDB does not materialize the lineitem scan the query and its subquery share, which would hide it from the
    Bloom filter rewrite"""
    return f"""SELECT sum(l_extendedprice) / 7.0 AS avg_yearly
FROM read_oasis({_q(probe_path)}) AS lineitem, read_oasis({_q(build_path)}) AS part
WHERE p_partkey = l_partkey
  AND l_quantity < (
    SELECT 0.2 * avg(l_quantity)
    FROM read_oasis({_q(probe_path)}) AS l2
    WHERE l2.l_partkey = p_partkey
  );"""


Q17 = Query(
    name="q17",
    title="TPC-H Q17",
    build_table="part",
    build_predicate="p_brand = 'Brand#23' AND p_container = 'MED BOX'",
    build_key="p_partkey",
    probe_table="lineitem",
    probe_key="l_partkey",
    sql=q17_sql,
    reference_sql="""SELECT sum(l_extendedprice) / 7.0 AS avg_yearly
FROM lineitem, part
WHERE p_partkey = l_partkey
  AND p_brand = 'Brand#23' AND p_container = 'MED BOX'
  AND l_quantity < (SELECT 0.2 * avg(l_quantity) FROM lineitem AS l2 WHERE l2.l_partkey = p_partkey)""",
    # The join's scan of lineitem, and the subquery's (the aggregate over l2)
    probe_scans=(("l_partkey", "l_quantity", "l_extendedprice"), ("l_partkey", "l_quantity")),
    # With the build side's predicate gone, DuckDB's deliminator turns the query into lineitem JOIN (aggregate JOIN
    # part): there is then no join between a lineitem scan and the part scan for the Bloom filter to go into
    # (extension: "join skipped: could not find single LogicalGet on both sides"). Off, the direct join is kept.
    # Set for both variants so that their plans are the same
    settings={"disabled_optimizers": "deliminator"},
)

# Q19: the three groups' part predicates are the build file's filter (a part that satisfies none of them cannot join
# any lineitem row). The per-group coupling of brand and quantity range stays in the query: it mixes both sides.
# Brand#12, #23 and #34 are different, so a part of the file satisfies exactly one group's part predicate, which its
# brand names; p_container and p_size are implied by (file, p_brand) and leave the query, p_brand stays
Q19_BUILD_PREDICATE = """(p_brand = 'Brand#12' AND p_container IN ('SM CASE', 'SM BOX', 'SM PACK', 'SM PKG')
   AND p_size BETWEEN 1 AND 5)
  OR (p_brand = 'Brand#23' AND p_container IN ('MED BAG', 'MED BOX', 'MED PKG', 'MED PACK')
   AND p_size BETWEEN 1 AND 10)
  OR (p_brand = 'Brand#34' AND p_container IN ('LG CASE', 'LG BOX', 'LG PACK', 'LG PKG')
   AND p_size BETWEEN 1 AND 15)"""


def q19_sql(build_path, probe_path, side=None):
    """TPC-H Q19 over read_oasis. `part` is the file of the parts that satisfy one of the three groups' part
    predicates; p_container and p_size are not tested again (see Q19_BUILD_PREDICATE), p_brand couples a part to its
    group's quantity range. The conditions every group has (l_shipmode, l_shipinstruct) are written once, outside
    the OR, which is how DuckDB's own plan has them"""
    return f"""SELECT sum(l_extendedprice * (1 - l_discount)) AS revenue
FROM read_oasis({_q(probe_path)}) AS lineitem, read_oasis({_q(build_path)}) AS part
WHERE p_partkey = l_partkey
  AND l_shipmode IN ('AIR', 'AIR REG')
  AND l_shipinstruct = 'DELIVER IN PERSON'
  AND ((p_brand = 'Brand#12' AND l_quantity >= 1 AND l_quantity <= 1 + 10)
    OR (p_brand = 'Brand#23' AND l_quantity >= 10 AND l_quantity <= 10 + 10)
    OR (p_brand = 'Brand#34' AND l_quantity >= 20 AND l_quantity <= 20 + 10));"""


Q19 = Query(
    name="q19",
    title="TPC-H Q19",
    build_table="part",
    build_predicate=Q19_BUILD_PREDICATE,
    build_key="p_partkey",
    probe_table="lineitem",
    probe_key="l_partkey",
    sql=q19_sql,
    reference_sql="""SELECT sum(l_extendedprice * (1 - l_discount)) AS revenue
FROM lineitem, part
WHERE (p_partkey = l_partkey AND p_brand = 'Brand#12'
       AND p_container IN ('SM CASE', 'SM BOX', 'SM PACK', 'SM PKG')
       AND l_quantity >= 1 AND l_quantity <= 1 + 10 AND p_size BETWEEN 1 AND 5
       AND l_shipmode IN ('AIR', 'AIR REG') AND l_shipinstruct = 'DELIVER IN PERSON')
   OR (p_partkey = l_partkey AND p_brand = 'Brand#23'
       AND p_container IN ('MED BAG', 'MED BOX', 'MED PKG', 'MED PACK')
       AND l_quantity >= 10 AND l_quantity <= 10 + 10 AND p_size BETWEEN 1 AND 10
       AND l_shipmode IN ('AIR', 'AIR REG') AND l_shipinstruct = 'DELIVER IN PERSON')
   OR (p_partkey = l_partkey AND p_brand = 'Brand#34'
       AND p_container IN ('LG CASE', 'LG BOX', 'LG PACK', 'LG PKG')
       AND l_quantity >= 20 AND l_quantity <= 20 + 10 AND p_size BETWEEN 1 AND 15
       AND l_shipmode IN ('AIR', 'AIR REG') AND l_shipinstruct = 'DELIVER IN PERSON')""",
    # One scan of lineitem. The strings (l_shipmode, l_shipinstruct) are decoded on the CPU, they are not in the
    # decoder's output: 4 columns of 8 B
    probe_scans=(("l_partkey", "l_quantity", "l_extendedprice", "l_discount", "l_shipmode", "l_shipinstruct"),),
)


# Q20: the extension rewrites only an INNER join of two read_oasis scans (single get, only filters between). The
# original query joins part and partsupp with a SEMI join (IN), and its correlated subquery is a join of lineitem
# with a DELIM_SCAN, under an aggregate: no Get-Get join. So the build side of the Bloom filter is partsupp
# pre-filtered to the partsupp rows of the 'forest%' parts (the IN's semi join, evaluated at generation time), and
# the correlated subquery is written as the join + aggregate DuckDB's decorrelation produces anyway, with the
# join below the aggregate: lineitem JOIN partsupp_q20 ON (l_partkey, l_suppkey) = (ps_partkey, ps_suppkey), the
# extension builds the filter from the first key, ps_partkey. A partsupp row without a lineitem row in the year has
# sum() NULL in the original, the comparison is NULL and the row is dropped: the inner join drops it as well
Q20_BUILD_PREDICATE = "ps_partkey IN (SELECT p_partkey FROM part WHERE p_name LIKE 'forest%')"

# The original result is (s_name, s_address) rows ordered by name; a run has to return one row to be compared:
# the number of suppliers and the sum of a digest (md5 is the same in every DuckDB) of their name and address
_Q20_RESULT = "count(*) AS n_suppliers, sum(md5_number_lower(s_name || '|' || s_address)) AS name_checksum"


def q20_sql(build_path, probe_path, side):
    return f"""SELECT {_Q20_RESULT}
FROM (
  SELECT s_name, s_address
  FROM read_parquet({_q(side['supplier'])}) AS supplier, read_parquet({_q(side['nation'])}) AS nation
  WHERE s_suppkey IN (
      SELECT ps_suppkey
      FROM (
        SELECT ps_partkey, ps_suppkey, ps_availqty, sum(l_quantity) AS sum_qty
        FROM read_oasis({_q(probe_path)}) AS lineitem, read_oasis({_q(build_path)}) AS partsupp
        WHERE l_partkey = ps_partkey AND l_suppkey = ps_suppkey
          AND l_shipdate >= DATE '1994-01-01' AND l_shipdate < DATE '1994-01-01' + INTERVAL '1' YEAR
        GROUP BY ps_partkey, ps_suppkey, ps_availqty) AS yearly
      WHERE ps_availqty > 0.5 * sum_qty)
    AND s_nationkey = n_nationkey AND n_name = 'CANADA');"""


Q20 = Query(
    name="q20",
    title="TPC-H Q20",
    build_table="partsupp",
    build_predicate=Q20_BUILD_PREDICATE,
    build_key="ps_partkey",
    probe_table="lineitem",
    probe_key="l_partkey",
    sql=q20_sql,
    reference_sql=f"""SELECT {_Q20_RESULT}
FROM (
  SELECT s_name, s_address
  FROM supplier, nation
  WHERE s_suppkey IN (
      SELECT ps_suppkey
      FROM partsupp
      WHERE ps_partkey IN (SELECT p_partkey FROM part WHERE p_name LIKE 'forest%')
        AND ps_availqty > (
          SELECT 0.5 * sum(l_quantity)
          FROM lineitem
          WHERE l_partkey = ps_partkey AND l_suppkey = ps_suppkey
            AND l_shipdate >= DATE '1994-01-01' AND l_shipdate < DATE '1994-01-01' + INTERVAL '1' YEAR))
    AND s_nationkey = n_nationkey AND n_name = 'CANADA')""",
    # One scan of lineitem: l_shipdate is read by the filter only, but it is a column the decoder outputs (4 B)
    probe_scans=(("l_partkey", "l_suppkey", "l_quantity", "l_shipdate"),),
    extra_tables=("part",),
    side_tables=("supplier", "nation"),
)

QUERIES = {q.name: q for q in (Q17, Q19, Q20)}


# ---------------------------------------------------------------------------
# The data
# ---------------------------------------------------------------------------

@dataclass
class TpchDataset:
    """Same attributes as gen_data.Dataset where bench.py reads them (build_path, probe_path, the row groups and
    the meta), and the TPC-H specifics"""
    query: str
    scale_factor: float
    compression: str
    build_path: Path
    probe_path: Path
    build_row_groups: list
    probe_row_groups: list
    build_meta: dict      # the sidecar's entry of the build file
    probe_meta: dict
    expected_result: float            # the query's answer, from the original query on the generated tables
    matching_probe_rows: int          # probe rows whose key is on the (filtered) build side
    probe_out_bytes: int              # what the decoder outputs for the probe file's scans of one run
    # All values of the answer row, in the order of the query's columns (the first is expected_result); empty:
    # the single value expected_result
    expected_row: tuple = ()
    side_paths: dict = field(default_factory=dict)  # side table -> its file, for the query's read_parquet


def _plain(value):
    """A value of the answer row as JSON has it: a DECIMAL as the string of its exact digits"""
    return str(value) if isinstance(value, Decimal) else value


def _number(value):
    return value if isinstance(value, (int, float)) else float(value)


def _same(got, want):
    """Whether a value of a run's answer is the generated one: exact for integers and decimals (SUM of a DECIMAL,
    COUNT, a checksum), within a relative 1e-9 for a DOUBLE (Q17's average)"""
    try:
        g, w = Decimal(str(got)), Decimal(str(want))
    except InvalidOperation:
        return got == want
    if isinstance(want, float):
        return math.isclose(float(g), want, rel_tol=1e-9)
    return g == w


def _file_facts(con, path):
    """What is known about a written file; raises BenchmarkError if the pinned ParCore cannot read it"""
    path = str(path)
    not_optional = con.execute(
        """SELECT name, repetition_type FROM parquet_schema(?)
           WHERE num_children IS NULL AND repetition_type != 'OPTIONAL'""", [path]).fetchall()
    nulls, missing = con.execute(
        """SELECT coalesce(sum(stats_null_count), 0), count(*) FILTER (WHERE stats_null_count IS NULL)
           FROM parquet_metadata(?)""", [path]).fetchone()
    groups = [r[1] for r in con.execute(
        "SELECT row_group_id, max(row_group_num_rows) FROM parquet_metadata(?) GROUP BY row_group_id "
        "ORDER BY row_group_id", [path]).fetchall()]
    types = dict(con.execute("SELECT name, type FROM parquet_schema(?) WHERE num_children IS NULL", [path]).fetchall())
    rows = con.execute("SELECT num_rows FROM parquet_file_metadata(?)", [path]).fetchone()[0]
    if not_optional:
        raise BenchmarkError(f"{path}: columns not OPTIONAL: {not_optional}")
    if nulls or missing:
        raise BenchmarkError(f"{path}: {nulls} NULLs, {missing} column chunks without null_count statistics")
    if not groups or max(groups) > MAX_ROW_GROUP_ROWS or sum(groups) != rows:
        raise BenchmarkError(f"{path}: row groups {groups[:5]}... (limit {MAX_ROW_GROUP_ROWS} rows)")
    return {"rows": rows, "row_groups": groups, "column_types": types, "bytes": os.path.getsize(path),
            "path": path}


def _write(con, source_sql, path, compression):
    # The bundled DuckDB writes REQUIRED columns when statistics prove NOT NULL; ParCore needs OPTIONAL
    con.execute("SET disabled_optimizers = 'statistics_propagation'")
    con.execute(f"COPY ({source_sql}) TO {_q(path)} (FORMAT parquet, COMPRESSION {compression}, "
                "PARQUET_VERSION V1)")  # V2 turns on DELTA_BINARY_PACKED / BYTE_STREAM_SPLIT
    con.execute("RESET disabled_optimizers")


def generate(query, scale_factor, compression, out_dir, log=print):
    """Generates the data of `query` at `scale_factor` into the (existing, empty) directory `out_dir`:
    <build table>_<query>.parquet, <probe table>.parquet and dataset.json. Returns the TpchDataset"""
    try:
        import duckdb
    except ImportError as e:
        raise BenchmarkError(f"cannot import duckdb ({e}): source ~/plotting/bin/activate") from None
    if compression not in COMPRESSIONS:
        raise BenchmarkError(f"compression has to be one of {COMPRESSIONS}, not {compression!r}")
    if scale_factor < 0.001:
        raise BenchmarkError("scale factors below 0.001 are not possible (dbgen collapses every table to a row)")
    out_dir = Path(out_dir)
    started = time.monotonic()
    log(f"generating {query.title} data, scale factor {scale_factor:g} ({compression}) in {out_dir} ...")
    con = duckdb.connect()
    try:
        try:
            con.execute("INSTALL tpch; LOAD tpch")
            con.execute(f"CALL dbgen(sf = {float(scale_factor)!r})")
        except duckdb.Error as e:
            raise BenchmarkError(f"dbgen failed: {e}") from None
        kept = {query.build_table, query.probe_table, *query.extra_tables, *query.side_tables}
        for table in TPCH_TABLES:  # Only the ones the query needs are kept, the rest is memory
            if table not in kept:
                con.execute(f"DROP TABLE {table}")
        build_path, probe_path = out_dir / query.build_file, out_dir / query.probe_file
        side_paths = {t: out_dir / query.side_file(t) for t in query.side_tables}

        n_build = con.execute(f"SELECT count(*) FROM {query.build_table}").fetchone()[0]
        n_filtered = con.execute(
            f"SELECT count(*) FROM (SELECT * FROM {query.build_table} WHERE {query.build_predicate})").fetchone()[0]
        if n_filtered == 0:
            raise BenchmarkError(f"the predicate of {query.title} selects none of the {n_build} rows of "
                                 f"{query.build_table} at scale factor {scale_factor:g} (ParCore cannot read an "
                                 "empty Parquet file): use a larger scale factor")
        # The answer of the original query. The pre-filtered file has to give the same: it is checked on the
        # hardware's result of every run
        row = [_plain(v) for v in con.execute(query.reference_sql).fetchone()]
        if None in row:
            raise BenchmarkError(f"{query.title} at scale factor {scale_factor:g} has an empty result: "
                                 "the data set is too small (no row of the filtered build side qualifies)")
        expected = row[0]
        _write(con, f"SELECT * FROM {query.build_table} WHERE {query.build_predicate}", build_path, compression)
        _write(con, f"SELECT * FROM {query.probe_table}", probe_path, compression)
        for table, path in side_paths.items():
            _write(con, f"SELECT * FROM {table}", path, compression)
        build, probe = _file_facts(con, build_path), _file_facts(con, probe_path)
        sides = {t: _file_facts(con, p) for t, p in side_paths.items()}
        if build["rows"] != n_filtered:
            raise BenchmarkError(f"{build_path}: {build['rows']} rows, the predicate selects {n_filtered}")

        matching = con.execute(
            f"SELECT count(*) FROM read_parquet({_q(probe_path)}) WHERE {query.probe_key} IN "
            f"(SELECT {query.build_key} FROM read_parquet({_q(build_path)}))").fetchone()[0]
    finally:
        con.close()

    widths = probe["column_types"]
    try:
        scan_bytes = sum(BYTES_OF_TYPE[widths[c]] for scan in query.probe_scans for c in scan)
    except KeyError as e:
        raise BenchmarkError(f"{probe_path}: column {e} is missing or not a fixed-width type: "
                             f"{widths}") from None
    probe_out = scan_bytes * probe["rows"]
    meta = {
        "generator": GENERATOR_VERSION, "query": query.name, "scale_factor": scale_factor,
        "compression": compression, "build": {**build, "table": query.build_table, "full_rows": n_build,
                                              "predicate": query.build_predicate},
        "probe": {**probe, "table": query.probe_table},
        "expected_result": expected, "expected_row": row, "side": sides,
        "matching_probe_rows": matching, "probe_out_bytes": probe_out,
        "seconds": round(time.monotonic() - started, 1),
    }
    # Written last: a directory without it is an interrupted generation
    tmp = out_dir / ".dataset.json.tmp"
    tmp.write_text(json.dumps(meta, indent=1, sort_keys=True) + "\n")
    os.replace(tmp, out_dir / "dataset.json")
    log(f"  {build['rows']} {query.build_table} rows (of {n_build}), {probe['rows']} {query.probe_table} rows, "
        f"{matching} of them match; {meta['seconds']:.0f} s")
    return _dataset_of(query, meta, out_dir)


def _dataset_of(query, meta, out_dir):
    return TpchDataset(
        query=query.name, scale_factor=meta["scale_factor"], compression=meta["compression"],
        build_path=Path(out_dir) / query.build_file, probe_path=Path(out_dir) / query.probe_file,
        build_row_groups=list(meta["build"]["row_groups"]), probe_row_groups=list(meta["probe"]["row_groups"]),
        build_meta=meta["build"], probe_meta=meta["probe"], expected_result=_number(meta["expected_result"]),
        matching_probe_rows=int(meta["matching_probe_rows"]), probe_out_bytes=int(meta["probe_out_bytes"]),
        expected_row=tuple(meta.get("expected_row", ())),
        side_paths={t: Path(out_dir) / query.side_file(t) for t in query.side_tables})


def dataset_dir(data_dir, query, scale_factor, compression):
    return Path(data_dir) / f"{query.name}_sf{scale_factor:g}_{compression}".replace(".", "_")


def ensure_dataset(data_dir, query, scale_factor, compression, log=print):
    """The dataset in `data_dir`, generated on demand (and kept there: the next call with the same arguments
    reuses it). A half-written one is removed and made again"""
    target = dataset_dir(data_dir, query, scale_factor, compression)
    sidecar = target / "dataset.json"
    if sidecar.exists():
        try:
            meta = json.loads(sidecar.read_text())
            if meta.get("generator") == GENERATOR_VERSION and (target / query.build_file).exists() \
                    and (target / query.probe_file).exists() \
                    and all((target / query.side_file(t)).exists() for t in query.side_tables):
                return _dataset_of(query, meta, target)
        except (OSError, ValueError, KeyError):
            pass
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)
    try:
        return generate(query, scale_factor, compression, target, log)
    except BaseException:
        shutil.rmtree(target, ignore_errors=True)
        raise


# ---------------------------------------------------------------------------
# The workload
# ---------------------------------------------------------------------------

# The options, in the shape of bench.PARAMS: name, short option, type, default, help
PARAMS = [
    ("scale_factor", None, float, 1.0, "TPC-H scale factor"),
    ("compression", None, str, "uncompressed", "Parquet compression of the files: uncompressed or snappy"),
    ("runtime_bloom", None, bench._bool, True,
     "oasis_runtime_bloom_filter: filter the probe side with the hardware Bloom filter (off: the query as it is)"),
    ("egress_gbps", None, float, 0.0, "oasis_emulated_egress_gbps: cap the FPGA->host output to this many GB/s "
                                     "(0: off)"),
    ("threads", None, int, None, "DuckDB's threads setting (default: DuckDB's, one per hardware thread)"),
]


class TpchWorkload(bench.Workload):
    """A TPC-H query for bench.run_benchmark(workload=...)"""

    params = PARAMS

    def __init__(self, query):
        self.query = query

    def complete_params(self, params):
        names = [p[0] for p in self.params]
        unknown = set(params) - set(names)
        if unknown:
            raise BenchmarkError(f"unknown parameter(s) {sorted(unknown)}; known: {names}")
        full = {name: default for name, _s, _t, default, _h in self.params}
        full.update({k: v for k, v in params.items() if v is not None})
        if not full["scale_factor"] >= 0.001:
            raise BenchmarkError(f"scale_factor has to be at least 0.001, not {full['scale_factor']}")
        if full["compression"] not in COMPRESSIONS:
            raise BenchmarkError(f"compression has to be one of {COMPRESSIONS}, not {full['compression']!r}")
        if full["egress_gbps"] < 0:
            raise BenchmarkError("egress_gbps cannot be negative")
        full["scale_factor"] = float(full["scale_factor"])
        return full

    def make_dataset(self, params, data_dir, log):
        return ensure_dataset(data_dir, self.query, params["scale_factor"], params["compression"], log)

    def query_sql(self, params, dataset):
        return self.query.sql(str(dataset.build_path), str(dataset.probe_path),
                              {t: str(p) for t, p in dataset.side_paths.items()})

    def settings(self, params):
        return dict(self.query.settings)

    def dataset_meta(self, dataset):
        return {"build": dataset.build_meta, "probe": dataset.probe_meta}

    def result_parameters(self, params, dataset):
        return {
            "query": self.query.name, "scale_factor": params["scale_factor"],
            "compression": params["compression"], "runtime_bloom": params["runtime_bloom"],
            "emulated_egress_gbps": params["egress_gbps"], "threads": params["threads"],
            "build_rows": dataset.build_meta["rows"], "build_full_rows": dataset.build_meta["full_rows"],
            "probe_rows": dataset.probe_meta["rows"], "matching_probe_rows": dataset.matching_probe_rows,
            "build_batches": len(dataset.build_row_groups), "probe_batches": len(dataset.probe_row_groups),
        }

    def expected(self, dataset):
        expected = {"result": dataset.expected_result, "probe_out_bytes": dataset.probe_out_bytes}
        if dataset.expected_row:
            expected["result_row"] = list(dataset.expected_row)
        return expected

    def release(self, data_dir, params):
        """The data of a point is dropped when its variants are done: the probe table of scale factor 10 is GB"""
        shutil.rmtree(dataset_dir(data_dir, self.query, params["scale_factor"], params["compression"]),
                      ignore_errors=True)

    # -- checks and measures ------------------------------------------------------------------------------

    def probe_segments(self, run, probe_name, where):
        """The decoder's profile segments of the probe file's scans, in order, and all segments.

        The extension reads the profiler when each scan starts ('before_scan', named after the file the scan
        reads) and at the end of the query ('final', named after the last scan's file). Segment 0 is everything
        before the first scan (the Bloom filter's build pass), segment k + 1 is the work of the scan that
        started at segment k, up to the start of the next one. A synthetic join has one probe scan, which is
        the last to start: the 'final' segment. A TPC-H query can scan its big table several times (Q17: the
        join's scan and the subquery's), and which of those is the Bloom filtered one depends on the plan, so
        the probe's decoder throughput is that of all of them together: from the start of the first scan of the
        probe file to the end of the query"""
        segments = run.get("decoder_segments") or []
        if len(segments) < 2:
            raise BenchmarkError(f"{where}: {len(segments)} decoder profile segment(s), expected one per scan "
                                 "and a final one (is the extension's OasisDecoderProfile record there?)")
        final = [s for s in segments if s.get("label") == "final"]
        if len(final) != 1 or segments[-1] is not final[0]:
            raise BenchmarkError(f"{where}: expected one final decoder segment, last of {len(segments)}")
        scans = segments[:-1]
        if Path(final[0]["file"]).name != Path(scans[-1]["file"]).name:
            raise BenchmarkError(f"{where}: the final decoder segment reads {final[0]['file']}, the last scan "
                                 f"{scans[-1]['file']}")
        indexes = [j + 1 for j, s in enumerate(scans) if Path(s["file"]).name == probe_name]
        if not indexes:
            raise BenchmarkError(f"{where}: no scan of {probe_name} in the decoder's profile: "
                                 f"{[Path(s['file']).name for s in scans]}")
        if indexes != list(range(indexes[0], indexes[-1] + 1)):
            raise BenchmarkError(f"{where}: the scans of {probe_name} are not consecutive "
                                 f"({[Path(s['file']).name for s in scans]}), their segments cannot be added up")
        return [segments[i] for i in indexes], segments

    def check_run(self, run, params, dataset):
        """Verifies the result of one run and turns its raw statistics into the measures (the same as
        bench.check_run). Raises BenchmarkError. The probe's decoder throughput is that of all scans of the probe
        table, see probe_segments"""
        where = f"run {run['index']}"
        raw = run.get("result_raw")
        want = tuple(dataset.expected_row) or (dataset.expected_result,)
        if raw is None or len(raw) != len(want):
            raise BenchmarkError(f"{where}: the query returned no result" if raw is None else
                                 f"{where}: the result has {len(raw)} column(s), expected {len(want)}: {raw!r}")
        row = list(raw.values())
        for column, got, expected in zip(raw, row, want):
            try:
                float(got)
            except (TypeError, ValueError):
                raise BenchmarkError(f"{where}: the result is {raw!r}") from None
            if not _same(got, expected):
                raise BenchmarkError(f"{where}: wrong result: {column} = {got!r} != {expected!r} (the original "
                                     "query on the generated tables)")
        result = float(row[0])

        qs = run.get("qs")
        if qs is None:
            raise BenchmarkError(f"{where}: no OasisQueryStats record (did the scans run on the read_oasis function?)")
        host = bench.host_measures(qs)
        probe_name = dataset.probe_path.name
        probe_segments, segments = self.probe_segments(run, probe_name, where)
        decoder = dict(bench.decoder_measures(bench.sum_profile_rows(probe_segments)), scope="probe table scans",
                       segments=len(probe_segments))
        decoder_run = dict(bench.decoder_measures(bench.sum_profile_rows(segments)),
                           scope="run (segments summed)")

        bloom = None
        scans = run.get("scans") or []
        if params["runtime_bloom"]:
            records = run.get("bloom") or []
            if len(records) != 1 or host["scan_bloom_ms"] is None:
                raise BenchmarkError(
                    f"{where}: the hardware Bloom filter did not run once ({len(records)} OasisBloomFilterStats "
                    "record(s)): the join was not rewritten. Run the query with CALL "
                    "enable_logging(level='debug') for the reason (e.g. 'join skipped')")
            bloom_scans = [s for s in scans if s.get("bloom")]
            if len(bloom_scans) != 1 or Path(bloom_scans[0]["file"]).name != probe_name:
                raise BenchmarkError(f"{where}: the Bloom filter filtered {[s['file'] for s in bloom_scans]}, not "
                                     f"{probe_name}")
            bloom = bench.bloom_measures(records[0])
            if bloom["command_queue_overflowed"]:
                raise BenchmarkError(f"{where}: the Bloom filter's command queue overflowed (sticky until a device "
                                     "reset): the counters of this and all later runs are not reliable")
        elif run.get("bloom"):
            raise BenchmarkError(f"{where}: the Bloom filter ran although it was switched off")

        # The scans decode the columns the query reads, whole (the filter only drops rows after the decoder)
        ratio = decoder["out"]["bytes"] / dataset.probe_out_bytes
        if abs(ratio - 1.0) > OUT_BYTES_TOLERANCE:
            raise BenchmarkError(
                f"{where}: the decoder's output over the scans of {probe_name} is {decoder['out']['bytes']} B, "
                f"expected about {dataset.probe_out_bytes} B (ratio {ratio:.3f}): the plan is not the one this "
                "benchmark measures")
        return {
            "index": run["index"],
            "host": host,
            "decoder": decoder,
            "decoder_run": decoder_run,
            "bloom": bloom,
            "result": {"value": result, "row": row},
            "checks": {"decoder_probe_out_bytes_expected": dataset.probe_out_bytes,
                       "decoder_probe_out_bytes_ratio": ratio,
                       "probe_scans": len(probe_segments)},
            "decoder_segments": segments,
            "scans": scans,
        }


# ---------------------------------------------------------------------------
# The sweeps over the scale factor (what sweep_tpch_q*.py have in common)
# ---------------------------------------------------------------------------

DEFAULT_SCALE_FACTORS = [float(i) for i in range(1, 9)]


def scale_factor_sweep(query, script, doc, tmp_need="0.4 GB x the scale factor (uncompressed; one point's data at "
                                                    "a time)"):
    """The sweep_lib.Sweep of `query` over the scale factor, and the two functions sweep_lib.main takes besides it
    (add_args, points_of): (sweep, add_args, points_of). `doc` is the script's docstring"""
    import sweep_lib

    sweep = sweep_lib.Sweep(
        script=script,
        description=doc.split("\n\n")[0],
        experiment=f"tpch_{query.name}",
        swept="scale_factor",
        x_header="scale factor",
        x_label="TPC-H scale factor",
        xscale="linear",
        folder_of=lambda sf: f"sf{sf:g}".replace(".", "_"),
        workload=TpchWorkload(query),
        options=("compression", "egress_gbps", "threads"),
        tmp_need=tmp_need,
        timeout=1800.0,  # per point (13 runs of one variant); the other sweeps' 600 s are for runs of seconds
        doc=doc,
    )

    def add_args(parser):
        parser.add_argument("--scale-factors", type=float, nargs="+", metavar="SF", default=DEFAULT_SCALE_FACTORS,
                            help="the TPC-H scale factors to run, in any order (default: 1 2 ... 8)")

    def points_of(args, parser):
        xs = sorted(set(args.scale_factors))
        if not xs or xs[0] < 0.001:
            parser.error("--scale-factors: at least one, each at least 0.001 (dbgen collapses every table to one "
                         "row below that)")
        return xs

    return sweep, add_args, points_of

#!/usr/bin/env python3
"""Run every benchmark behind the regex operator's report section, in one go.

Five suites, each isolating one variable:

    patterns      pattern shape        (c_comment, sf30, selectivity pinned 9.7-12.4%)
    selectivity   fraction matched     (regex_sel_rg128, 15.7M x 72 B, pattern fixed)
    length        string length        (regex_par32, 3.93M rows = 32 row groups, threads=32)
    threads       DuckDB thread count  (p_literal_class, 480 row groups so every T
                                       swept divides it, pattern fixed)
    states        NFA/DFA blow-up      (c_comment, `.*a.{n}` -- n+2 NFA states, 2^n DFA states)

Every case is timed with DuckDB's benchmark_runner (one warm-up plus N timed runs,
median reported), once as `software` and once as `fpga`.  The huge-page pool is reset
before each hardware case: it leaks, and an exhausted pool silently produces both wrong
results and meaningless timings.

Usage
    scripts/regex_report.py                     # everything
    scripts/regex_report.py -s patterns -s states
    scripts/regex_report.py --list
    scripts/regex_report.py --latex             # also print LaTeX tables
    scripts/regex_report.py --runs 7

Results land in scripts/results/regex_report_<timestamp>.csv.
"""

from __future__ import annotations

import argparse
import csv
import os
import shutil
import hashlib
import platform
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, field, replace
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
EXT = REPO_ROOT / "extension"
DUCKDB = EXT / "build" / "release" / "duckdb"
RUNNER = EXT / "build" / "release" / "benchmark" / "benchmark_runner"
RESULTS = Path(__file__).resolve().parent / "results"
TREE = Path(os.environ.get("REGEX_REPORT_TREE", "/tmp/regex_report_tree"))

# The release build links a jemalloc that is not on the default loader path.
EXTRA_LIB = Path.home() / "opt" / "lib"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import regex_gen                                    # noqa: E402
from regex_patterns import PATTERNS                 # noqa: E402

# All benchmark databases are stored uncompressed -- see the note in regex_gen.py.
# Compression is a write-time property paid back as CPU on every scan, and it favours
# the software side unevenly (RE2 gains 30%+ where it reduces to a memchr, ~0% where it
# is genuinely matching), so measuring against it reports DuckDB's storage layer as much
# as either engine. Each of these has a compressed twin at the same path without the
# suffix if you ever want that comparison.
SF30 = os.environ.get("REGEX_SF30_DB", "/scratch/vifranz/tpch_regex_sf30_uncompressed.duckdb")
# Uncompressed by default; regex_gen.py writes these with force_compression off.
# Override with REGEX_GEN_DB to measure against a compressed set.
GEN_DB = os.environ.get("REGEX_GEN_DB", "/scratch/vifranz/regex_gen_uncompressed.duckdb")
SEL_DB = os.environ.get("REGEX_SEL_DB", "/scratch/vifranz/regex_sel_rg128_uncompressed.duckdb")
# The anchored twin of SEL_DB, at the same geometry.  `.*[a-z]ructi.*` inspects every byte,
# so neither path cares how many rows match; an anchored pattern is the case where software
# *does* care, because it rejects a non-matching row after its first token and a matching one
# only at the end.  Sweeping selectivity against it is the only way to measure that, and the
# sel_* tables cannot serve: their selectivity is pinned for the unanchored pattern, and this
# one matches them at whatever rate it happens to.
ASEL_DB = os.environ.get("REGEX_ASEL_DB", "/scratch/vifranz/regex_asel_rg128_uncompressed.duckdb")
ANCHORED_PATTERN = "[a-z]+ [rs].*"
# regex_par32: 3_932_160 rows per table = exactly 32 row groups at every length, built by
# scripts/util/gen_par32.sh.  The older regex_par_uncompressed.duckdb holds the same seven
# lengths at 524288 rows (4.27 row groups); reach it with REGEX_PAR_DB, but then PAR_ROWS
# and the thread pin below have to come back down with it or the MB column lies.
PAR_DB = os.environ.get("REGEX_PAR_DB", "/scratch/vifranz/regex_par32_uncompressed.duckdb")

# Text volume in MB for throughput.  Measured, not nominal.
# Query shapes.  "floor" is the regex-free scan baseline: the same column read and
# touched, no matching at all, which is what the thesis's "sum(hash(c)) achieves 29 GB/s"
# claim measures -- the ceiling any regex path is working against.  It has no FPGA twin
# by construction, so it is reported on the software column only.
SHAPES = {
    "count":       "count(*)",
    "materialise": "sum(strlen(c))",
    "emit":        "c",
    "floor":       "sum(hash(c))",
}

MB_C_COMMENT = 326.2
# Regex-column text volumes at sf30, measured on the database itself:
#   SELECT sum(strlen(o_comment)) FROM orders    -> 2,182,400,324 B over 45,000,000 rows
#   SELECT sum(strlen(c_address)) FROM customer  ->   143,623,252 B over  4,500,000 rows
# The first agrees exactly with the p1_* rows of sel_materialisation.csv (mb=2182.4) and
# with the "2.18 GB of text" in the thesis, so the end-to-end GB/s stays comparable.
MB_O_COMMENT = 2182.4
MB_C_ADDRESS = 143.6
# The sel_* tables: 15_728_640 x 72 B, i.e. 128 row groups -- 4 waves on 32 threads.
# See the note on Pattern.rows in regex_patterns.py: divisibility alone is not enough,
# one wave runs at 67% of the achievable parallelism and the FPGA path barely notices,
# so the old 32-group geometry understated software by ~30% in this suite too.
SEL_ROWS = 15_728_640
MB_SEL = SEL_ROWS * 72 / 1e6

# The threads suite has to sweep T without the row-group sawtooth riding along, because
# the two produce the same shape.  Scan work goes out one whole row group per task and
# the tasks are equal-sized, so with G groups on T threads the makespan is ceil(G/T)
# waves and utilisation is G / (ceil(G/T) * T) -- exactly 1.0 iff T divides G, ragged
# everywhere else.  There is no row-group count that is exact at every T, so the sweep
# visits only the divisors of G and G is chosen to have many of them.
#
# What the ragged counts do to the figure:
#
#   customer, sf30      37 groups   1.00 at T=1 and nowhere else; 0.93 at 10, 0.77 at 16,
#                                   0.73 at 17, 0.58 at 32.  On its own that is a curve
#                                   that plateaus near 10 and "degrades in hyperthreading
#                                   territory" with no thread effect whatsoever.
#   p_*_3932k           32 groups   exact at 1, 2, 4, 8, 16, 32; 0.71 at 15, 0.52 at 31.
#                                   Fine for powers of two, blind between them.
#   this table         480 groups   exact at 1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 16, 20, 24,
#                                   30, 32 -- 15 of the 32 counts, including both that
#                                   matter (16, the operator's arm-credit cap, and 32,
#                                   the box) and five points between them.
#
# 480 = 2^5 * 3 * 5 is the smallest count with that divisor set.  At 72 B it is
# 58,982,400 rows / 4.25 GB, generated by the same path the patterns suite uses and with
# the same pattern, string length, selectivity and cardinality as p_literal_class_*, so
# thread count stays the only variable.  It lives in its own database: at 4.25 GB it has
# no business inside the pattern set, and the two must not be confused for each other.
# String lengths for the length suite; --lengths narrows it, which is what lets one
# point be re-measured without paying for the 8 and 16 GB tables again.
LENGTHS = (16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192)

THREADS_ROW_GROUPS = 480
THREADS_DB = os.environ.get(
    "REGEX_THREADS_DB", "/scratch/vifranz/regex_threads480_uncompressed.duckdb")
THREADS_T = [t for t in range(1, 33) if THREADS_ROW_GROUPS % t == 0]
THREADS_PATTERN = replace(next(p for p in PATTERNS if p.label == "Literal + class"),
                          rows=THREADS_ROW_GROUPS * 122_880, db=THREADS_DB)


@dataclass
class Case:
    suite: str
    label: str          # row label in the report
    pattern: str
    db: str
    table: str
    column: str
    mb: float           # text volume scanned, for GB/s
    settings: list = field(default_factory=list)
    # software formulation: "regex" (SIMILAR TO) or a LIKE pattern string
    like: str | None = None
    note: str = ""
    # Query shape.  "count" is SELECT count(*) -- no rows leave the operator, so the
    # measurement is scan + match.  "materialise" projects the column instead, which
    # makes the operator emit every matching row.  The FPGA path pays a fixed cost for
    # that even at 0% selectivity (the result bitmaps arrive after the scan, so rows
    # must be retained until then); software pays essentially nothing.  Measuring only
    # count(*) therefore flatters the accelerator, which is why both shapes are run.
    shape: str = "count"
    select: str = "count(*)"
    # End-to-end query files, used verbatim instead of a generated predicate.  The two
    # sides are different files, not one query with a substituted predicate: the FPGA
    # rewrite turns a pushed-down filter into a table function feeding an anti-join, so
    # the plans genuinely differ and that difference is part of what is being measured.
    sql_software: str | None = None
    sql_fpga: str | None = None


def num(v, width: int = 7) -> str:
    """Format a maybe-missing measurement; a failed case carries None, not a float."""
    return f"{v:>{width}.3f}" if isinstance(v, (int, float)) else f"{'--':>{width}}"


def sh(cmd, **kw):
    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = f"{EXTRA_LIB}:{env.get('LD_LIBRARY_PATH','')}"
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, env=env, **kw)


def row_groups(db: str, table: str, _cache={}) -> int | None:
    """Row groups in `table`, or None if it cannot be read."""
    key = (db, table)
    if key not in _cache:
        r = sh(f"{DUCKDB} '{db}' -readonly -noheader -list -c "
               f'"SELECT count(DISTINCT row_group_id) FROM pragma_storage_info(\'{table}\');"')
        try:
            _cache[key] = int(r.stdout.strip())
        except ValueError:
            _cache[key] = None
    return _cache[key]


def check_parallelism(cases, default_threads: int) -> None:
    """Report scan utilisation, and warn where the row-group count wastes the machine.

    DuckDB hands out scan work one whole row group per task (row_group_collection.cpp,
    NextParallelScan) and the tasks are equal-sized, so with G row groups on T threads
    the makespan is ceil(G/T) waves and utilisation is G / (ceil(G/T) * T).  That is a
    sawtooth, not a curve: on 32 threads, 25 groups is 0.78, 37 groups is 0.58 (32 in
    the first wave, 5 in the second, 27 threads idle throughout it), 32 groups is 1.00.
    Measured at constant volume, going 25 -> 37 groups cost software 20% and the FPGA
    path 5-9%, while the extra bytes themselves cost nothing.

    A suite whose tables sit at different points on that sawtooth is not comparable
    with one that does not, which is the whole reason this runs.
    """
    for c in cases:
        pinned = [x for x in c.settings if "threads" in str(x).lower()]
        thr = int(str(pinned[0]).split("=")[-1]) if pinned else default_threads
        rg = row_groups(c.db, c.table)
        if rg is None:
            continue
        waves = -(-rg // thr)          # ceil
        util = rg / (waves * thr)
        if util < 0.9:
            print(f"  ! {c.suite:<12}{c.label:<22}{c.table}: {rg} row groups on {thr} "
                  f"threads is {waves} wave(s) at {util:.0%} utilisation "
                  f"({rg - (waves - 1) * thr} group(s) in the last wave)", flush=True)


def preflight() -> str:
    """Catch the two failure modes that otherwise look like mysterious FPGA errors."""
    r = sh("pgrep -af 'benchmark_runner' | grep -v pgrep || true")
    others = [ln for ln in r.stdout.splitlines() if "benchmark_runner" in ln]
    if others:
        return ("another benchmark_runner is already running -- it holds the 1GiB huge "
                "pages and the card, so this run would fail every FPGA case:\n    "
                + "\n    ".join(others[:3]))
    free = Path("/sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages")
    if free.exists():
        try:
            if int(free.read_text().strip()) == 0:
                return ("0 free 1GiB huge pages. Something still holds them; check for a "
                        "stray benchmark_runner or duckdb, then re-run "
                        f"`sudo hdev set hugepages --num-1g {HUGEPAGES_1G}`.")
        except ValueError:
            pass
    return ""


# 1GiB pages to keep provisioned.  16 no longer fits: hdev enforces a cap of 25% of RAM
# per NUMA domain, which on this 64 GB box is 15 pages, and it counts the 2 MiB pool
# towards the same budget.
DEFAULT_BITSTREAM = "/scratch/vifranz/build_hw_decoder_fixed/bitstreams/cyt_top.bit"

HUGEPAGES_1G = 12
_hugepage_warned = False


def reset_hugepages():
    """The pool leaks; an exhausted pool yields wrong counts and bogus timings.

    Three things about `hdev set hugepages` that its old `-p 16 -s 1G` form hid:

    - the flags are now --num-2m / --num-1g, and the old ones are a hard error;
    - it must run as root, so this is a no-op without passwordless sudo -- hence the
      warning, since the alternative is a run that quietly measures an empty pool;
    - the 25%-of-RAM cap counts both page sizes, and hdev writes the 1 GiB count
      *before* the 2 MiB one.  So a box with the 2 MiB pool populated needs two
      invocations -- `--num-2m 0` first, then `--num-1g N` -- or the gigabyte pages
      have nowhere to come from and silently allocate zero.
    """
    global _hugepage_warned
    r = sh(f"TERM=dumb sudo -n hdev set hugepages --num-1g {HUGEPAGES_1G}")
    if r.returncode != 0 and not _hugepage_warned:
        _hugepage_warned = True
        print(f"warning: cannot reset the huge-page pool ({(r.stdout + r.stderr).strip()[:120]}).\n"
              f"         Run `sudo hdev set hugepages --num-1g {HUGEPAGES_1G}` yourself; the pool "
              f"leaks, so a long run may exhaust it.", file=sys.stderr)


def run_config(a) -> dict:
    """Per-run configuration, recorded alongside every number.

    Two files in the historical result set look like clean repeats and are not:
    length_oncard.csv was taken with the outlier threshold raised to 16384 and
    threads_480rg_w1.csv at in-flight 1.  Neither recorded that, so it had to be
    inferred from the shape of the data.  Everything a later run needs in order to
    know whether it may be pooled with this one goes in the CSV from now on.

    The bitstream cannot be read back from the device -- /sys/class/coyote_fpga_0
    exposes only dev/power/subsystem/uevent -- so what is recorded is the .bit that
    was built, by path, mtime and hash.  It is the best available identifier, not a
    readback: reflashing something else without rebuilding would not show up here.
    """
    bit = Path(os.environ.get("REGEX_BITSTREAM", DEFAULT_BITSTREAM))
    bit_id = ""
    if bit.exists():
        h = hashlib.sha256(bit.read_bytes()).hexdigest()[:12]
        bit_id = f"{bit}@{int(bit.stat().st_mtime)}:{h}"
    free = Path("/sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages")
    return {
        "variants": "+".join(a.variant) if a.variant else "software+fpga",
        "threads": a.threads if a.threads is not None else "",
        "in_flight": a.in_flight if a.in_flight is not None else "",
        "outlier_bytes": a.outlier_bytes if a.outlier_bytes is not None else "",
        "repeat": a.repeat,
        "bitstream": bit_id,
        "git_rev": sh("git rev-parse --short HEAD").stdout.strip(),
        "host": platform.node(),
        "hugepages_1g_free": free.read_text().strip() if free.exists() else "",
        "started": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }


def write_case(root: Path, name: str, sql: str, db: str, need_ext: bool, settings):
    (root / "benchmark" / "adhoc").mkdir(parents=True, exist_ok=True)
    # Settings are written one per line, so each needs its own terminator: the entries in
    # Case.settings are bare ("SET threads = 32"), which parses only while there is exactly
    # one of them and it ends the file. Two bare settings run together into one statement.
    stmts = [str(x).rstrip().rstrip(";") + ";" for x in settings]
    load = "\n".join([f"ATTACH '{db}' AS bench (READ_ONLY);", "USE bench;"] + stmts)
    (root / f"{name}.load.sql").write_text(load + "\n")
    (root / f"{name}.sql").write_text(sql + "\n")
    req = "require oasis\n" if need_ext else ""
    (root / "benchmark" / "adhoc" / f"{name}.benchmark").write_text(
        f"# name: benchmark/adhoc/{name}.benchmark\n"
        f"# description: regex_report {name}\n"
        f"# group: [adhoc]\n\n"
        f"name adhoc_{name}\ngroup adhoc\nsubgroup report\n\n{req}\n"
        f"load {root}/{name}.load.sql\n\nrun {root}/{name}.sql\n"
    )


# benchmark_runner does one warm-up plus Benchmark::DEFAULT_NRUNS timed runs
# (benchmark/include/benchmark.hpp) and offers no way to change that -- not from the
# CLI and not from a .benchmark directive.  To get more samples we re-invoke it.
RUNS_PER_INVOCATION = 5


def time_case(root: Path, name: str, repeat: int, reset_pool: bool):
    """Returns (samples, error).  error is a short diagnostic when nothing timed."""
    out: list[float] = []
    err = ""
    for _ in range(max(1, repeat)):
        if reset_pool:
            reset_hugepages()
        r = sh(f"timeout 3600 {RUNNER} --root-dir {root} --disable-timeout "
               f"benchmark/adhoc/{name}.benchmark")
        for line in (r.stdout + r.stderr).splitlines():
            parts = line.split("\t")
            if len(parts) >= 3:
                try:
                    out.append(float(parts[2]))
                    continue
                except ValueError:
                    pass
            low = line.lower()
            if any(k in low for k in ("error", "exception", "not enough", "failed",
                                      "no such", "cannot", "unable")):
                err = line.strip()[:300]
    return out, err


def sw_predicate(c: Case) -> str:
    if c.like is not None:
        return f"{c.column} LIKE '{c.like}'"
    return f"{c.column} SIMILAR TO '{c.pattern}'"


def run_sql(root: Path, name: str, db: str, sql: str, settings, reset_pool: bool):
    """Execute one statement through the duckdb CLI; returns (stdout, error).

    Separate from time_case on purpose: benchmark_runner reports timings and throws
    the query result away, so the only way to see what a case actually answered is to
    ask again.  This runs once, untimed, and does not touch the numbers above it.

    The script goes to a file rather than -c: patterns carry backslashes and quotes
    that do not survive a shell round trip.
    """
    if reset_pool:
        reset_hugepages()
    stmts = [str(x).rstrip().rstrip(";") + ";" for x in settings]
    path = root / f"{name}.verify.sql"
    path.write_text("\n".join(stmts + [sql.rstrip().rstrip(";") + ";"]) + "\n")
    r = sh(f"timeout 3600 {DUCKDB} '{db}' -readonly -noheader -list -f {path}")
    if r.returncode != 0:
        return "", ((r.stderr or r.stdout).strip() or "duckdb exited non-zero")[:300]
    return r.stdout.strip(), ""


def verify_sql(c: Case, variant: str) -> str | None:
    """The correctness query for one side of a case, or None if it has no counterpart.

    Deliberately not the benchmark's own select.  `emit` returns rows rather than a
    scalar and `floor` (sum(hash(c)), the regex-free scan baseline) has no FPGA twin,
    so neither can be compared as written.  count(*) on its own would only compare
    cardinality, so this also sums a hash of the matched column: an order-independent
    checksum over the matched set, which catches the right *number* of wrong rows --
    the failure a count cannot see.  The queries suite runs its two files verbatim
    instead, since there the whole result set is the answer.
    """
    if c.shape == "floor":
        return None
    if c.suite == "queries":
        f = c.sql_software if variant == "software" else c.sql_fpga
        return Path(f).read_text().strip() if f else None
    agg = f"count(*), sum(hash({c.column}))"
    if variant == "software":
        return f"SELECT {agg} FROM {c.table} WHERE {sw_predicate(c)};"
    return (f"SELECT {agg} FROM regex_fpga_scan('{c.table}', "
            f"regex_column := '{c.column}', pattern := '{c.pattern}');")


def verify_case(root: Path, name: str, c: Case, built: dict, rec: dict) -> None:
    """Run both sides once more and compare their answers; annotates `rec` in place.

    Writes `verify` (ok / MISMATCH / a reason it could not run) plus each side's row
    count and checksum, so a disagreement is legible in the CSV rather than only in
    the console.  A mismatch does not abort the run: the remaining cases still carry
    information about how far the disagreement spreads.
    """
    out = {}
    for variant, settings in built.items():
        sql = verify_sql(c, variant)
        if sql is None:
            # `floor` is the only shape with nothing to compare: it is the regex-free
            # baseline, so it runs on the software side alone and has no FPGA twin.
            rec["verify"] = ("skipped: regex-free baseline, no FPGA twin"
                             if c.shape == "floor" else f"skipped: no {variant} counterpart")
            return
        text, err = run_sql(root, f"{name}_{variant}", c.db, sql, settings,
                            reset_pool=(variant == "fpga"))
        if err:
            rec["verify"] = f"error ({variant}): {err}"
            return
        out[variant] = text
        if c.suite != "queries":
            parts = text.split("|")
            if len(parts) == 2:
                rec[variant + "_rows"] = parts[0].strip()
                rec[variant + "_check"] = parts[1].strip()

    if len(out) < 2:
        rec["verify"] = "skipped: one variant measured"
        return
    rec["verify"] = "ok" if out["software"] == out["fpga"] else "MISMATCH"


def build_cases(shapes=("count", "materialise", "emit")) -> list[Case]:
    cs: list[Case] = []
    C = dict(db=SF30, table="customer", column="c_comment", mb=MB_C_COMMENT)

    # -- patterns -----------------------------------------------------------
    # Sourced from regex_patterns.PATTERNS -- edit that file, not this one.  Any
    # table that does not exist at the right geometry is generated before the run.
    for pat in PATTERNS:
        cs.append(Case("patterns", pat.label, pat.regex,
                       db=pat.db or GEN_DB, table=pat.table_name(),
                       column=pat.column, mb=pat.rows * pat.length / 1e6,
                       like=pat.like, note=pat.note))

    # -- states: DFA blow-up.  `.*a.{n}` costs n+2 NFA states, 2^n DFA states.
    # n=26 is the current ceiling: n+2=28 states, the hardware's current budget.
    for n in (10, 14, 18, 22, 26):
        cs.append(Case("states", f"n={n}", f".*a.{{{n}}}", note=f"2^{n} DFA states", **C))

    # -- threads ------------------------------------------------------------
    # THREADS_T, not range(1, 33): every count in it divides the table's 480 row groups,
    # so scan utilisation is exactly 1.0 at every point and the curve is thread scaling
    # rather than the row-group sawtooth.  It still resolves the knee -- 8, 10, 12, 15,
    # 16, 20, 24, 30, 32 -- which is what the sweep is for.  The pattern is a full-scan
    # shape with no fast LIKE form, so neither side gets a shortcut.
    T = dict(db=THREADS_PATTERN.db or GEN_DB, table=THREADS_PATTERN.table_name(),
             column=THREADS_PATTERN.column,
             mb=THREADS_PATTERN.rows * THREADS_PATTERN.length / 1e6)
    for t in THREADS_T:
        cs.append(Case("threads", f"{t}", THREADS_PATTERN.regex,
                       settings=[f"SET threads = {t}"], **T))

    # -- queries: end-to-end TPC-H at sf30 ----------------------------------
    # These four pairs are what the end-to-end figure plots.  They previously had no
    # provenance at all: regex_bench.py prints to stdout and writes no CSV, so the
    # plotted values were hand-transcribed from interactive runs that were never
    # captured, with no repetition count and no recorded configuration.  Running them
    # here puts them on the same footing as every other suite.
    #
    # q13 appears twice against the SAME FPGA file: the accelerator does not care
    # whether the software twin was written as LIKE or SIMILAR TO, so one FPGA
    # measurement is the counterpart to both.
    Q = Path(__file__).resolve().parent.parent / "tcph_regex"
    for label, sw, fp, mb in (
            ("q13 (LIKE)",       "queries_software/q13.sql",         "queries_fpga/q13.sql", MB_O_COMMENT),
            ("q13 (SIMILAR TO)", "queries_software/q13_similar.sql", "queries_fpga/q13.sql", MB_O_COMMENT),
            ("q27",              "queries_software/q27.sql",         "queries_fpga/q27.sql", MB_C_ADDRESS),
            ("q29",              "queries_software/q29.sql",         "queries_fpga/q29.sql", MB_O_COMMENT),
            # Sub-claims from section 5.4.5 that had no reproducible source.  Each pairs a
            # software file with an FPGA file so both plan shapes are timed the same way.
            #   q29a / q29b   the two halves of the UNION ALL run alone (254 ms + 145 ms
            #                 against 382 ms together); q29b touches no string column, so
            #                 its two files are identical by construction.
            #   q13 floor     q13 with the pattern replaced by strlen(o_comment) > 0 --
            #                 same plan, no matching.  Software only.
            #   q13 cheap     the same cheap predicate in both plan shapes, no regex on
            #                 either side, isolating filter-pushdown vs NOT IN anti-join.
            ("q29a (regex half)",  "queries_software/q29a.sql", "queries_fpga/q29a.sql", MB_O_COMMENT),
            ("q29b (other half)",  "queries_software/q29b.sql", "queries_fpga/q29b.sql", 0.0),
            ("q13 floor (strlen)", "queries_software/q13_floor.sql", None, MB_O_COMMENT),
            ("q13 cheap predicate","queries_software/q13_cheap.sql", "queries_fpga/q13_cheap.sql", MB_O_COMMENT)):
        cs.append(Case("queries", label, "(see query file)", db=SF30,
                       table="tpch_sf30", column="-", mb=mb,
                       sql_software=str(Q / sw) if sw else None,
                       # None means "no counterpart": q13 floor is a software-only
                       # baseline, so the FPGA column is left empty rather than filled
                       # with a generated predicate that measures something else.
                       sql_fpga=str(Q / fp) if fp else None))

    # -- selectivity --------------------------------------------------------
    for pct in (0, 1, 5, 10, 25, 50, 75, 100):
        # Three shapes, because "materialise" is ambiguous and the script that produced
        # the original sel_materialisation.csv is gone:
        #   count       count(*)         -- projection pushdown means `c` is never emitted
        #   materialise sum(strlen(c))   -- forces the operator to emit `c`, consumed in
        #                                   engine; strlen is a header read, so this is
        #                                   the cheapest honest way to demand the column
        #   emit        c                -- additionally ships every row to the client,
        #                                   which at 100% is 283 MB over the CLI protocol
        # The reference numbers (+7.7 ms at 0%, +21.9 ms at 100% over count) are far too
        # small to include client transfer, so `materialise` is the comparable one.
        for shape in shapes:
            sel = SHAPES[shape]
            label = f"{pct}%" if shape == "count" else f"{pct}% {shape}"
            cs.append(Case("selectivity", label, ".*[a-z]ructi.*", db=SEL_DB,
                           table=f"sel_{pct}", column="c", mb=MB_SEL,
                           shape=shape, select=sel))

    # Anchored twin, count shape only: the variable here is what selectivity does to
    # *software*, and the materialise/emit shapes would fold the operator's output cost
    # into that.  The FPGA transfers and inspects every byte either way, so its curve is
    # the control.
    for pct in (0, 1, 5, 10, 25, 50, 75, 100):
        cs.append(Case("selectivity", f"{pct}% anchored", ANCHORED_PATTERN, db=ASEL_DB,
                       table=f"asel_{pct}", column="c", mb=MB_SEL,
                       note="anchored: software rejects most rows after the first token"))

    # -- length ------------------------------------------------------------
    # regex_par32 holds the ROW COUNT constant at 3_932_160 and lets the volume grow, so
    # DuckDB's thread heuristic (which keys off row count) cannot silently vary the
    # thread count as strings get longer.
    #
    # That row count is 32 x 122880, i.e. exactly 32 full row groups, which is what lets
    # this suite run at 32 threads at all.  Scan work is handed out one row group per
    # task, so a table's row count fixes both the available parallelism and its
    # utilisation: the old 524288-row tables are 4.27 row groups, which on 32 threads is
    # five tasks over one wave -- 13% utilisation and a different figure at every length.
    # Pinning threads=1 was the way around that; 32 full groups is the way through it,
    # and it keeps the task count identical at every length so length stays the only
    # variable.
    PAR_ROWS = 3_932_160
    # Runs to 8192, which is the cliff rather than a data point.
    #
    # Strings at or above kRegexOutlierBytes are matched on the host by RE2 and never
    # reach the card -- MatchOutlierOnHost in regex_table.cpp, the check is per string
    # and unconditional -- so a table whose strings are *all* that long puts nothing on
    # the FPGA and reports RE2 against RE2 as an FPGA result.  That constant is 8192
    # (it was 2048 when this suite stopped at 1024, which is why it did), and
    # regex_is_outlier tests `>=`, so 8192 is exactly the first length that submits
    # nothing.  It is kept in the sweep as a labelled control: the point of measuring it
    # is to show the cliff and to have the batch counters prove it, not to report its
    # "FPGA" throughput as a device result.
    #
    # Confirm rather than assume, because the failure is silent -- a case at or above the
    # threshold shows batches = 0 and strings = 0 in regex_fpga_batch_phases().
    #
    # The row count is held at 32 full row groups, so volume grows with length: 8192 B is
    # 32.2 GB against ~46 GB of RAM once the huge-page pool is subtracted, and the tables
    # live on NFS, so the runner's warm-up pass is doing a real cold read at that size.
    for L in LENGTHS:
        for shape in shapes:
            if shape in ("materialise", "emit"):
                continue          # output cost is the selectivity suite's variable
            label = f"{L}" if shape == "count" else f"{L} {shape}"
            cs.append(Case("length", label, ".*[a-z]ructi.*", db=PAR_DB,
                           table=f"par_{L}", column="c", mb=L * PAR_ROWS / 1e6,
                           settings=["SET threads = 32"],
                           shape=shape, select=SHAPES[shape]))

    # -- projection: what a materialised column actually costs ---------------
    # The selectivity suite varies *how many* rows leave the operator; this varies *what*
    # leaves it, at one fixed selectivity, so the two are not confounded.  Every case runs
    # the same scan and the same match over the same rows and differs only in the select
    # list, so the delta against the count(*) baseline is the projection cost and nothing
    # else.  `.*quickly regular.*` matches 584,973 of 45 M o_comment rows (1.3%).
    #
    # o_orderkey is fixed-width: the scan hands back a vector pointing straight into the
    # storage block.  o_comment is the matched column, so it is scanned either way and only
    # the emit is new.  o_clerk is a second VARCHAR that a count(*) plan would not touch at
    # all.  Those three are the cost model: nothing, emit-only, and scan-plus-emit.
    for label, sel in (("count", "count(*)"),
                       ("key (fixed width)", "sum(o_orderkey)"),
                       ("o_comment (matched)", "sum(strlen(o_comment))"),
                       ("o_clerk (other varchar)", "sum(strlen(o_clerk))")):
        cs.append(Case("projection", label, ".*quickly regular.*", db=SF30,
                       table="orders", column="o_comment", mb=MB_O_COMMENT,
                       shape="count" if label == "count" else "materialise", select=sel,
                       note="projection cost at 1.3% selectivity"))
    return cs


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-s", "--suite", action="append", default=[])
    ap.add_argument("--repeat", type=int, default=5,
                    help="re-invoke the runner N times and pool all samples "
                         "(each invocation is a fixed 5 timed runs + 1 warm-up)")
    ap.add_argument("--threads", type=int, default=None,
                    help="DuckDB thread count for every case that does not pin its own "
                         "(the threads and length suites do). Without this, DuckDB's "
                         "default is used, which is the core count -- and the FPGA path "
                         "peaks well below that: measured 7.79 GB/s at 24 threads against "
                         "6.27 at 32 on a 32-core box, so the default costs ~1.2x. Applied "
                         "to both variants so the comparison stays fair.")
    ap.add_argument("--lengths", help="comma-separated subset of the length suite, "
                                     "e.g. --lengths 8192")
    ap.add_argument("--thread-list", help="comma-separated subset of the threads suite, "
                                         "e.g. --thread-list 32")
    ap.add_argument("--in-flight", type=int, default=None,
                    help="SET oasis_regex_max_in_flight. Transfers one scan thread keeps on "
                         "the card. This and the thread count are ONE decision: every "
                         "outstanding transfer holds an arm credit and there are only "
                         "kRegexMaxSubmissionsInFlight (32), so the scan's thread cap is "
                         "32/in_flight. Sweeping T at fixed W measures nothing above the cap.")
    ap.add_argument("--outlier-bytes", type=int, default=None,
                    help="SET oasis_regex_outlier_bytes on every case. Strings at or above "
                         "the threshold are matched on the host by RE2 and never reach the "
                         "card, so the default (2048) makes any table of longer strings "
                         "report RE2 against RE2 as an FPGA result. Raise it to measure the "
                         "device on long strings -- safe on uniform-length data, where no "
                         "engine can run ahead of another; on skewed data it risks wedging "
                         "the array (see kRegexOutlierBytes).")
    ap.add_argument("--variant", action="append", choices=["software", "fpga"],
                    default=None,
                    help="measure only these variants (repeatable). The thread sweep's "
                         "software side is ~17 s per iteration at T=1 on the 4.2 GB "
                         "table, so `--variant fpga` is how you add FPGA repeats without "
                         "re-measuring a software curve that already has them. The "
                         "resulting CSV has empty columns for the variant that was not "
                         "run and no speedup -- `variants` in the config columns says "
                         "which, so an unmeasured variant is not mistaken for a failed one.")
    ap.add_argument("--shapes", default=None,
                    help="comma-separated query shapes for the selectivity and length "
                         "suites: " + ", ".join(SHAPES) + ".  `count` is scan+match with "
                         "nothing emitted; `materialise` forces the operator to produce "
                         "the column; `emit` additionally ships every row to the client; "
                         "`floor` is the regex-free scan baseline (sum(hash(c))), which "
                         "is the ceiling both paths work against and has no FPGA twin. "
                         "Default: count,materialise,emit for selectivity and count for "
                         "length.")
    ap.add_argument("--no-verify", dest="verify", action="store_false", default=True,
                    help="skip the correctness pass. By default every case is re-run once "
                         "per side, untimed, and the two answers are compared: matched row "
                         "count plus sum(hash(col)) over the matched rows, which is an "
                         "order-independent checksum, so the right number of wrong rows is "
                         "caught too. The queries suite compares whole result sets instead. "
                         "Costs one extra execution per side (~7%% on top of 15 timed runs) "
                         "and makes the run exit non-zero if any case disagrees.")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--latex", action="store_true")
    ap.add_argument("--csv")
    ap.add_argument("--regenerate", action="store_true",
                    help="rebuild generated pattern tables even if they look correct")
    a = ap.parse_args()

    if a.lengths:
        global LENGTHS
        LENGTHS = tuple(int(x) for x in a.lengths.split(","))
    if a.thread_list:
        global THREADS_T
        THREADS_T = [int(x) for x in a.thread_list.split(",")]
    shapes = tuple(x.strip() for x in a.shapes.split(",")) if a.shapes \
        else ("count", "materialise", "emit")
    bad = [x for x in shapes if x not in SHAPES]
    if bad:
        print(f"error: unknown shape(s) {bad}; known: {list(SHAPES)}", file=sys.stderr)
        return 2
    cases = build_cases(shapes)
    # "queries" is deliberately not in the default set: it is the only suite that runs
    # whole TPC-H queries rather than a single predicate, it needs the 24 GB sf30
    # database, and it takes far longer per case than the micro-benchmarks.  Ask for it
    # explicitly with -s queries.
    suites = a.suite or ["patterns", "states", "threads", "selectivity", "length"]
    cases = [c for c in cases if c.suite in suites]

    if a.list:
        for c in cases:
            print(f"{c.suite:<12}{c.label:<22}{c.pattern}")
        return 0

    for b in (DUCKDB, RUNNER):
        if not b.exists():
            print(f"missing {b}; build the extension first (make -j)", file=sys.stderr)
            return 1

    problem = preflight()
    if problem:
        print(f"preflight: {problem}", file=sys.stderr)
        return 1

    if TREE.exists():
        shutil.rmtree(TREE)
    TREE.mkdir(parents=True)

    # The threads suite draws on the same generated data, so `-s threads` alone must
    # still be able to build its table.
    need = []
    if any(c.suite == "patterns" for c in cases):
        need = [p for p in PATTERNS if not p.table]
    elif any(c.suite == "threads" for c in cases) and not THREADS_PATTERN.table:
        need = [THREADS_PATTERN]
    if need:
        print(f"checking {len(need)} generated table(s) in {GEN_DB}")
        for pat in need:
            regex_gen.ensure_table(pat.db or GEN_DB, pat, DUCKDB, force=a.regenerate)

    # After generation, so freshly built tables are checked too.
    check_parallelism(cases, a.threads or (os.cpu_count() or 1))

    cfg = run_config(a)
    rows = []
    iters = []          # one row per timed iteration; the spread lives here
    for c in cases:
        rec = {"suite": c.suite, "label": c.label, "pattern": c.pattern,
               "table": c.table, "mb": round(c.mb, 1), "shape": c.shape,
               "note": c.note, **cfg}
        built = {}          # variant -> settings, for the verify pass below
        for variant in (tuple(a.variant) if a.variant else ("software", "fpga")):
            name = f"{c.suite}_{c.label}_{variant}".replace("%", "pct").replace(" ", "_")
            name = "".join(ch for ch in name if ch.isalnum() or ch in "_-").lower()
            verbatim = c.sql_software if variant == "software" else c.sql_fpga
            if c.suite == "queries" and verbatim is None:
                continue          # no counterpart on this side (see sql_fpga above)
            # "floor" is the regex-free scan baseline: the same column read and touched with
            # no matching at all, which is the ceiling both paths work against. It therefore
            # carries NO predicate -- it used to be built like every other shape, WHERE and
            # all, which made it measure the regex query with a different aggregate (8.4 GB/s
            # at 1024 B against a true floor of 47.6) and quietly useless. It has no FPGA
            # twin by construction: there is no way to reach the card without a pattern.
            if c.shape == "floor":
                if variant != "software":
                    continue
                sql = f"SELECT {c.select} FROM {c.table};"
            elif verbatim is not None:
                sql = Path(verbatim).read_text().strip()
            elif variant == "software":
                sql = f"SELECT {c.select} FROM {c.table} WHERE {sw_predicate(c)};"
            else:
                sql = (f"SELECT {c.select} FROM regex_fpga_scan('{c.table}', "
                       f"regex_column := '{c.column}', pattern := '{c.pattern}');")
            # A case that pins its own thread count keeps it -- that is the variable the
            # threads and length suites are measuring.
            case_settings = list(c.settings)
            # FPGA variant only: the software case does not `require oasis`, so the
            # extension's settings do not exist in that session.
            if a.outlier_bytes is not None and variant == "fpga":
                case_settings.insert(0, f"SET oasis_regex_outlier_bytes = {a.outlier_bytes}")
            if a.in_flight is not None and variant == "fpga":
                case_settings.insert(0, f"SET oasis_regex_max_in_flight = {a.in_flight}")
            if a.threads is not None and not any("threads" in str(x).lower() for x in case_settings):
                case_settings.insert(0, f"SET threads = {a.threads}")
            built[variant] = case_settings
            write_case(TREE, name, sql, c.db, variant == "fpga", case_settings)
            ts, err = time_case(TREE, name, a.repeat, reset_pool=(variant == "fpga"))
            if not ts:
                rec[variant] = None
                rec[variant + "_error"] = err or "no timing rows returned"
                print(f"  ! {c.suite:<12}{c.label:<22}{variant:<9} FAILED"
                      f"{': ' + err if err else ''}", flush=True)
                continue
            ms_all = [t * 1000 for t in ts]
            ms = statistics.median(ms_all)
            rec[variant] = round(c.mb / ms, 3)
            rec[variant + "_ms"] = round(ms, 2)
            rec[variant + "_n"] = len(ts)
            # Spread over the timed iterations.  This is *within-run* scatter; it does
            # not capture the run-to-run drift that only repeated whole runs show, and
            # the two should not be conflated when drawing whiskers.
            rec[variant + "_min_ms"] = round(min(ms_all), 2)
            rec[variant + "_max_ms"] = round(max(ms_all), 2)
            rec[variant + "_sd_ms"] = round(statistics.stdev(ms_all), 3) if len(ms_all) > 1 else 0.0
            for i, one in enumerate(ms_all, 1):
                iters.append({"suite": c.suite, "label": c.label, "pattern": c.pattern,
                              "table": c.table, "mb": round(c.mb, 1),
                              "shape": c.shape, "variant": variant,
                              "iter": i, "ms": round(one, 3),
                              "gbs": round(c.mb / one, 3), **cfg})
        if rec.get("software") and rec.get("fpga"):
            rec["speedup"] = round(rec["fpga"] / rec["software"], 3)
        if a.verify and built:
            cname = f"{c.suite}_{c.label}".replace("%", "pct").replace(" ", "_")
            cname = "".join(ch for ch in cname if ch.isalnum() or ch in "_-").lower()
            verify_case(TREE, cname, c, built, rec)
        rows.append(rec)
        verdict = rec.get("verify", "")
        print(f"  {c.suite:<12}{c.label:<22}"
              f"sw {num(rec.get('software'))}  fpga {num(rec.get('fpga'))}  "
              f"{num(rec.get('speedup'), 6)}x"
              f"{'  [' + verdict + ']' if verdict and verdict != 'ok' else ''}", flush=True)
        if verdict == "MISMATCH":
            print(f"  ! {c.suite:<12}{c.label:<22}software and FPGA disagree: "
                  f"sw {rec.get('software_rows')} rows / check {rec.get('software_check')}, "
                  f"fpga {rec.get('fpga_rows')} rows / check {rec.get('fpga_check')}",
                  flush=True)

    RESULTS.mkdir(exist_ok=True)
    out = Path(a.csv) if a.csv else RESULTS / f"regex_report_{time.strftime('%Y%m%d_%H%M%S')}.csv"
    # software_error / fpga_error are diagnostic strings ("no timing rows returned"),
    # not spread -- the *_min_ms / *_max_ms / *_sd_ms columns carry that.
    cfg_cols = ["variants", "threads", "in_flight", "outlier_bytes", "repeat", "bitstream",
                "git_rev", "host", "hugepages_1g_free", "started"]
    cols = (["suite", "label", "pattern", "table", "mb", "shape",
             "software", "software_ms", "software_n",
             "software_min_ms", "software_max_ms", "software_sd_ms", "software_error",
             "fpga", "fpga_ms", "fpga_n",
             "fpga_min_ms", "fpga_max_ms", "fpga_sd_ms", "fpga_error",
             "speedup", "note",
             "verify", "software_rows", "fpga_rows",
             "software_check", "fpga_check"] + cfg_cols)
    with out.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    print(f"\nwrote {out}")

    # Per-iteration sidecar: one row per timed run, so error bars do not have to be
    # reconstructed by diffing whole runs against each other.
    if iters:
        iout = out.with_name(out.stem + "_iters.csv")
        icols = (["suite", "label", "pattern", "table", "mb", "shape", "variant", "iter",
                  "ms", "gbs"] + cfg_cols)
        with iout.open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=icols, extrasaction="ignore")
            w.writeheader()
            w.writerows(iters)
        print(f"wrote {iout}  ({len(iters)} iterations)")

    checked = [r for r in rows if r.get("verify")]
    bad = [r for r in checked if r["verify"] == "MISMATCH"]
    skipped = [r for r in checked if r["verify"] not in ("ok", "MISMATCH")]
    if checked:
        ok = len(checked) - len(bad) - len(skipped)
        print(f"\nverification: {ok}/{len(checked)} case(s) agree between software and FPGA"
              + (f", {len(bad)} MISMATCH" if bad else "")
              + (f", {len(skipped)} not checked" if skipped else ""))
        for r in bad:
            print(f"  ! {r['suite']:<12}{r['label']:<22}"
                  f"sw {r.get('software_rows')} rows / check {r.get('software_check')}  vs  "
                  f"fpga {r.get('fpga_rows')} rows / check {r.get('fpga_check')}")
        for r in skipped:
            print(f"  - {r['suite']:<12}{r['label']:<22}{r['verify']}")

    if a.latex:
        for s in suites:
            sub = [r for r in rows if r["suite"] == s and r.get("speedup")]
            if not sub:
                continue
            print(f"\n%% --- {s} ---")
            print(r"\begin{tabular}{@{}lrrr@{}}")
            print(r"\toprule")
            print(r"Case & Software (GB/s) & FPGA (GB/s) & Speed-up \\")
            print(r"\midrule")
            for r_ in sub:
                print(f"{r_['label']} & {r_['software']:.2f} & {r_['fpga']:.2f} "
                      f"& {r_['speedup']:.2f}$\\times$ \\\\")
            print(r"\bottomrule")
            print(r"\end{tabular}")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())

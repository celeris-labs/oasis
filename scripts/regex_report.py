#!/usr/bin/env python3
"""Run every benchmark behind the regex operator's report section, in one go.

Five suites, each isolating one variable:

    patterns      pattern shape        (c_comment, sf30, selectivity pinned 9.7-12.4%)
    selectivity   fraction matched     (regex_sel_rg32, 3.93M x 72 B, pattern fixed)
    length        string length        (regex_par, constant row count, threads=1)
    threads       DuckDB thread count  (p_literal_class, 32 row groups, pattern fixed)
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
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, field
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
SEL_DB = os.environ.get("REGEX_SEL_DB", "/scratch/vifranz/regex_sel_rg32_uncompressed.duckdb")
PAR_DB = os.environ.get("REGEX_PAR_DB", "/scratch/vifranz/regex_par_uncompressed.duckdb")

# Text volume in MB for throughput.  Measured, not nominal.
MB_C_COMMENT = 326.2
# The sel_* tables: 3_932_160 x 72 B, i.e. exactly 32 row groups.  See the note on
# Pattern.rows in regex_patterns.py for why the row-group count is pinned there.
SEL_ROWS = 3_932_160
MB_SEL = SEL_ROWS * 72 / 1e6

# The threads suite needs a table at exactly 32 full row groups or it measures DuckDB's
# row-group sawtooth as much as thread scaling.  `customer` is 4.5M rows = 37 groups and
# cannot be brought to 32: on 32 threads that is 2 waves at 58% utilisation, which cost
# the FPGA path 5-9%.  Reuse the generated pattern table instead -- same regex, same 72 B
# strings, 3_932_160 rows = 32 groups exactly -- taken from PATTERNS by label so it
# tracks any edit there, and generated on demand by the same path the patterns suite uses.
#
# 32 is the right count despite the sweep covering 1..32: it divides evenly at 1, 2, 4, 8,
# 16 and 32, which includes both counts that matter -- 32 (the box) and 16 (the operator's
# own arm-credit cap).  Intermediate counts stay ragged (31 threads is 2 waves at 52%) and
# check_parallelism will say so; that is inherent to sweeping T, not a property of the
# table, and no single row-group count removes it.
THREADS_PATTERN = next(p for p in PATTERNS if p.label == "Literal + class")


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
                        "`hdev set hugepages -p 16 -s 1G`.")
        except ValueError:
            pass
    return ""


def reset_hugepages():
    """The pool leaks; an exhausted pool yields wrong counts and bogus timings."""
    sh("TERM=dumb hdev set hugepages -p 16 -s 1G")


def write_case(root: Path, name: str, sql: str, db: str, need_ext: bool, settings):
    (root / "benchmark" / "adhoc").mkdir(parents=True, exist_ok=True)
    load = "\n".join([f"ATTACH '{db}' AS bench (READ_ONLY);", "USE bench;"] + list(settings))
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


def build_cases() -> list[Case]:
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
    # Every count 1..32, not just powers of two: the interesting part is where the
    # FPGA path saturates, and that knee sits between the powers of two.  The pattern
    # is a full-scan shape with no fast LIKE form, so neither side gets a shortcut
    # and thread count is the only variable.
    T = dict(db=THREADS_PATTERN.db or GEN_DB, table=THREADS_PATTERN.table_name(),
             column=THREADS_PATTERN.column,
             mb=THREADS_PATTERN.rows * THREADS_PATTERN.length / 1e6)
    for t in range(1, 33):
        cs.append(Case("threads", f"{t}", THREADS_PATTERN.regex,
                       settings=[f"SET threads = {t}"], **T))

    # -- selectivity --------------------------------------------------------
    for pct in (0, 1, 5, 10, 25, 50, 75, 100):
        cs.append(Case("selectivity", f"{pct}%", ".*[a-z]ructi.*", db=SEL_DB,
                       table=f"sel_{pct}", column="c", mb=MB_SEL))

    # -- length ------------------------------------------------------------
    # regex_par holds the ROW COUNT constant at 524288 and lets the volume grow, so
    # DuckDB's thread heuristic (which keys off row count) cannot silently vary the
    # thread count as strings get longer.  Pinned to threads=1 for the same reason.
    PAR_ROWS = 524288
    # Stops at 1024, deliberately.  Strings at or above kRegexOutlierBytes (2048) are
    # matched on the host by RE2 and never sent to the card at all -- the check is
    # per string and unconditional, so a table whose strings are *all* that long puts
    # nothing on the FPGA.  Verified: par_2048 and par_4096 submit 0 batches and 0
    # strings, so those rows compared RE2 against RE2 and reported it as an FPGA result.
    for L in (16, 32, 64, 128, 256, 512, 1024):
        cs.append(Case("length", f"{L}", ".*[a-z]ructi.*", db=PAR_DB,
                       table=f"par_{L}", column="c", mb=L * PAR_ROWS / 1e6,
                       settings=["SET threads = 1"]))
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
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--latex", action="store_true")
    ap.add_argument("--csv")
    ap.add_argument("--regenerate", action="store_true",
                    help="rebuild generated pattern tables even if they look correct")
    a = ap.parse_args()

    cases = build_cases()
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
            regex_gen.ensure_table(GEN_DB, pat, DUCKDB, force=a.regenerate)

    # After generation, so freshly built tables are checked too.
    check_parallelism(cases, a.threads or (os.cpu_count() or 1))

    rows = []
    for c in cases:
        rec = {"suite": c.suite, "label": c.label, "pattern": c.pattern,
               "table": c.table, "mb": round(c.mb, 1), "note": c.note}
        for variant in ("software", "fpga"):
            name = f"{c.suite}_{c.label}_{variant}".replace("%", "pct").replace(" ", "_")
            name = "".join(ch for ch in name if ch.isalnum() or ch in "_-").lower()
            if variant == "software":
                sql = f"SELECT count(*) FROM {c.table} WHERE {sw_predicate(c)};"
            else:
                sql = (f"SELECT count(*) FROM regex_fpga_scan('{c.table}', "
                       f"regex_column := '{c.column}', pattern := '{c.pattern}');")
            # A case that pins its own thread count keeps it -- that is the variable the
            # threads and length suites are measuring.
            case_settings = list(c.settings)
            if a.threads is not None and not any("threads" in str(x).lower() for x in case_settings):
                case_settings.insert(0, f"SET threads = {a.threads}")
            write_case(TREE, name, sql, c.db, variant == "fpga", case_settings)
            ts, err = time_case(TREE, name, a.repeat, reset_pool=(variant == "fpga"))
            if not ts:
                rec[variant] = None
                rec[variant + "_error"] = err or "no timing rows returned"
                print(f"  ! {c.suite:<12}{c.label:<22}{variant:<9} FAILED"
                      f"{': ' + err if err else ''}", flush=True)
                continue
            ms = statistics.median(ts) * 1000
            rec[variant] = round(c.mb / ms, 3)
            rec[variant + "_ms"] = round(ms, 2)
            rec[variant + "_n"] = len(ts)
        if rec.get("software") and rec.get("fpga"):
            rec["speedup"] = round(rec["fpga"] / rec["software"], 3)
        rows.append(rec)
        print(f"  {c.suite:<12}{c.label:<22}"
              f"sw {num(rec.get('software'))}  fpga {num(rec.get('fpga'))}  "
              f"{num(rec.get('speedup'), 6)}x", flush=True)

    RESULTS.mkdir(exist_ok=True)
    out = Path(a.csv) if a.csv else RESULTS / f"regex_report_{time.strftime('%Y%m%d_%H%M%S')}.csv"
    cols = ["suite", "label", "pattern", "table", "mb", "software", "software_ms",
            "software_n", "software_error", "fpga", "fpga_ms", "fpga_n",
            "fpga_error", "speedup", "note"]
    with out.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    print(f"\nwrote {out}")

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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Tests of the sweeps (sweep_lib.py and the five scripts) without the FPGA, in two ways:

* end to end, through sweep_lib.main and bench.run_benchmark, with the fake DuckDB CLI of test_bench.py (so it prints
  what bench.py currently parses) behind a wrapper that gives the query times other numbers for Bloom on and off. It
  runs the threads sweep, whose points do not change what bench.py checks the fake's output against. Dataset stubs
  and no device guard (no fuser, no lock file shared with other runs: OASIS_BENCH_NO_DEVICE_GUARD);
* from results folders written here in the format bench.py writes (bench.yaml/meta.yaml), for what only needs the
  folder: the plots, the table and the summary of all five sweeps.

An experiment folder is <type>_<date>_<time> with `results/` and `plots/` in it; the data is generated in a
temporary directory that is gone when the sweep ends.

Run: python test_sweeps.py (or pytest). Needs matplotlib and PyYAML: source ~/plotting/bin/activate"""

import contextlib
import csv
import io
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import bench
import sweep_build_size
import sweep_columns
import sweep_egress
import sweep_lib
import sweep_probe_size
import sweep_threads
import test_bench

BENCH_DIR = Path(__file__).resolve().parent
NO_GUARD = "OASIS_BENCH_NO_DEVICE_GUARD"  # bench.py: skip the lock file and the busy-FPGA check

# test_bench's fake CLI behind this wrapper: the query time of a point is 10 + threads ms with the filter and
# 20 + 2 * threads without (scans: 2 ms + 5 ms of the filtered one / 6 ms). Every call is logged to <tmp>/calls
WRAPPER = r'''#!/usr/bin/env python3
import json, os, re, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
sql = sys.stdin.read()
bloom = "oasis_runtime_bloom_filter = true" in sql
threads = int(re.search(r"SET threads = (\d+);", sql).group(1))
with open(os.path.join(here, "calls"), "a") as f:
    f.write(f"{'on' if bloom else 'off'} {threads}\n")
out = subprocess.run([sys.executable, os.path.join(here, "inner", "fake_duckdb")], input=sql, capture_output=True,
                     text=True, check=True).stdout.splitlines()
after_qs = False
for line in out:
    if after_qs and line.startswith("["):
        qs = json.loads(line)[0]
        if bloom:
            qs.update(total_query_ms=10.0 + threads, scan_only_ms=2.0, scan_celeris_bloom_ms=5.0)
        else:
            qs.update(total_query_ms=20.0 + 2 * threads, scan_only_ms=6.0, scan_celeris_bloom_ms=None)
        line, after_qs = json.dumps([qs]), False
    after_qs = after_qs or line.startswith("@@QS")
    print(line)
'''


class Env:
    """A temporary directory with the fake CLI, and the parts of bench.py that need the device or the dataset
    replaced (the card is not touched)"""

    def __init__(self, wrong_off=False):
        self.tmp = Path(tempfile.mkdtemp(prefix="test_sweeps_"))
        (self.tmp / "inner").mkdir()
        test_bench.make_fake(self.tmp / "inner")
        self.cli = self.tmp / "fake_duckdb"
        self.cli.write_text(WRAPPER)
        self.cli.chmod(self.cli.stat().st_mode | stat.S_IEXEC)
        self.folder = self.tmp / "sweep"      # An experiment folder (as --resume wants it), empty
        self.folder.mkdir()
        self.results = self.folder / "results"
        self.plots = self.folder / "plots"
        self.tmp_base = self.tmp / "tmpbase"  # Where the temporary data directories go (--tmp-dir)
        self.tmp_base.mkdir()
        self.data_dirs = []                   # The data_dir of every point that was run
        self.wrong_off = wrong_off  # The off variant gets a dataset that the (right) result does not match
        self._saved = {}

    def __enter__(self):
        def make_dataset(params, data_dir, log=print):
            assert Path(data_dir).is_dir(), data_dir
            self.data_dirs.append(Path(data_dir))
            stub = test_bench.dataset(params["columns"])
            if self.wrong_off and not params["runtime_bloom"]:
                stub.expected_rows += 1
            return stub
        self._saved["make_dataset"] = bench.make_dataset
        bench.make_dataset = make_dataset
        # No lock file and no check for a busy FPGA: the card is not involved (and a real run elsewhere must not
        # make these fail, nor these it)
        self._env = os.environ.get(NO_GUARD)
        os.environ[NO_GUARD] = "1"
        return self

    def __exit__(self, *exc):
        for name, value in self._saved.items():
            setattr(bench, name, value)
        if self._env is None:
            os.environ.pop(NO_GUARD, None)
        else:
            os.environ[NO_GUARD] = self._env
        shutil.rmtree(self.tmp, ignore_errors=True)

    def calls(self):
        path = self.tmp / "calls"
        return [line.split() for line in path.read_text().splitlines()] if path.exists() else []

    def sweep(self, module, *args, folder=True, run=True):
        """Runs a sweep script's main with the fake CLI; returns (exit code, stdout, stderr)"""
        argv = list(args) + ["--binary", str(self.cli), "--lib-dir", str(self.tmp), "--tmp-dir", str(self.tmp_base),
                             "--warmup", "1", "--iterations", "3"]
        if folder:
            argv += ["--resume", str(self.folder)]
        return run_main(module, argv)

    def threads(self, *args, **kw):
        """The threads sweep, two points: 1 and 2 workers (the dataset of test_bench.dataset: 100 and 1000 rows)"""
        return self.sweep(sweep_threads, "--threads-list", "1", "2", "--ssize", "100", "--rsize", "1000", *args, **kw)


def run_main(module, argv):
    """sweep_lib.main of a sweep script: (exit code, stdout, stderr). The plots get a low resolution (speed)"""
    load = sweep_lib._load_celeris_module

    def load_fast(name):
        loaded = load(name)
        if name == "plot_utils":
            loaded.DPI = 40
        return loaded

    out, err = io.StringIO(), io.StringIO()
    sweep_lib._load_celeris_module = load_fast
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = sweep_lib.main(module.SWEEP, module.add_args, module.points_of, argv)
    finally:
        sweep_lib._load_celeris_module = load
    return code, out.getvalue(), err.getvalue()


MEASURE_NAMES = [m[0] for m in sweep_lib.MEASURES]
ON_ONLY = {"bloom_in", "bloom_out"}
OFF_PLOTS = sorted([f"{m}.png" for m in MEASURE_NAMES if m not in ON_ONLY] + ["query_breakdown.png"])
ON_PLOTS = sorted([f"{m}.png" for m in MEASURE_NAMES] + ["query_breakdown.png"])  # the breakdown is always drawn
BOTH_PLOTS = OFF_PLOTS


def pngs(folder):
    return sorted(p.name for p in Path(folder).glob("*.png"))


def names(folder):
    return sorted(p.name for p in Path(folder).iterdir())


def read_summary(folder):
    with open(Path(folder) / "results" / "summary.csv", newline="") as f:
        return list(csv.reader(f))


def table_rows(out, first_column):
    """The rows of the printed table whose first cell is one of `first_column`: [[cells], ...]"""
    return [l.split() for l in out.splitlines() if l.split()[:1] and l.split()[0] in first_column
            and len(l.split()) > 2 and l.split()[1] in ("on", "off")]


# ---------------------------------------------------------------------------
# End to end, with the fake CLI
# ---------------------------------------------------------------------------

def test_both_layout_table_and_summary():
    with Env() as env:
        code, out, err = env.threads()
        assert code == 0, err
        br = env.results
        assert names(br) == ["bloom_off", "bloom_on", "summary.csv"]
        for variant in ("bloom_on", "bloom_off"):
            assert names(br / variant) == ["threads_01", "threads_02"]
        # The variants of a point run back to back: point by point, on then off
        assert env.calls() == [["on", "1"], ["off", "1"], ["on", "2"], ["off", "2"]]
        # The recorded setting is the variant's
        import yaml
        for variant, want in (("bloom_on", True), ("bloom_off", False)):
            data = yaml.safe_load((br / variant / "threads_01" / "bench.yaml").read_text())
            assert data["parameters"]["runtime_bloom"] is want
        # One row per point and variant, with its variant in the second column
        rows = table_rows(out, ("1", "2"))
        assert [(r[0], r[1]) for r in rows] == [("1", "on"), ("1", "off"), ("2", "on"), ("2", "off")], out
        assert rows[0][2:5] == ["11.00", "7.00", "4.00"]     # query_ms, scan_ms, join_ms with the filter: 10 + t
        assert rows[1][2:5] == ["22.00", "6.00", "16.00"]    # without: 20 + 2 t
        assert rows[1][-2:] == ["n/a", "n/a"]                # no Bloom filter counters when it was off
        assert rows[0][-1] != "n/a"
        # summary.csv: one row per point, a column per measure and variant (none for Bloom-off bloom_in/out)
        table = read_summary(env.folder)
        header = table[0]
        assert header[0] == "threads" and len(table) == 3 and [r[0] for r in table[1:]] == ["1", "2"]
        expect = [f"{m}[{v}]" for m in MEASURE_NAMES for v in ("bloom_on", "bloom_off")
                  if not (v == "bloom_off" and m in ON_ONLY)]
        assert header[1:] == expect, header
        row = dict(zip(header, table[1]))
        assert abs(float(row["query_ms[bloom_on]"]) - 11.0) < 1e-9
        assert abs(float(row["query_ms[bloom_off]"]) - 22.0) < 1e-9
        assert abs(float(row["rest_ms[bloom_off]"]) - 16.0) < 1e-9
        assert row["decoder_in[bloom_on]"] != "" and row["decoder_in[bloom_off]"] != ""
        assert row["bloom_in[bloom_on]"] != ""
        # The plots: a set per variant (none of bloom_in/out for Bloom off) and the pictures with both
        plots = env.plots
        assert names(plots) == ["bloom_off", "bloom_on", "both"]
        assert pngs(plots / "bloom_on") == ON_PLOTS
        assert pngs(plots / "bloom_off") == OFF_PLOTS
        assert pngs(plots / "both") == BOTH_PLOTS
        for line in out.splitlines():
            if line.startswith("plot: "):
                assert Path(line[6:]).stat().st_size > 1000


def test_resume_skips_complete_points():
    with Env() as env:
        assert env.threads()[0] == 0
        n = len(env.calls())
        code, out, err = env.threads()
        assert code == 0 and len(env.calls()) == n, err
        assert out.count("(existing)") == 4
        # A third point only runs that point, both variants
        code, out, err = env.sweep(sweep_threads, "--threads-list", "1", "2", "4", "--ssize", "100", "--rsize", "1000")
        assert code == 0, err
        assert env.calls()[n:] == [["on", "4"], ["off", "4"]]
        assert len(read_summary(env.folder)) == 4


def test_a_variant_added_later_runs_only_that_one():
    with Env() as env:
        assert env.threads("--bloom", "on")[0] == 0
        assert names(env.results) == ["bloom_on", "summary.csv"]
        assert names(env.plots) == ["bloom_on"]  # No picture of both with one variant
        assert [c[0] for c in env.calls()] == ["on", "on"]
        code, out, err = env.threads("--bloom", "both")
        assert code == 0, err
        assert [c[0] for c in env.calls()] == ["on", "on", "off", "off"]
        assert pngs(env.plots / "both") == BOTH_PLOTS


def test_bloom_off_only():
    with Env() as env:
        code, out, err = env.threads("--bloom", "off")
        assert code == 0, err
        assert [c[0] for c in env.calls()] == ["off", "off"]
        plots = env.plots
        assert names(plots) == ["bloom_off"] and pngs(plots / "bloom_off") == OFF_PLOTS
        assert "no plot of bloom" not in err  # expected without the filter: silent
        assert read_summary(env.folder)[0][1:] == [f"{m}[bloom_off]" for m in MEASURE_NAMES if m not in ON_ONLY]


def test_plots_only_replots_without_running():
    with Env() as env:
        assert env.threads()[0] == 0
        n = len(env.calls())
        shutil.rmtree(env.plots)
        (env.results / "summary.csv").unlink()
        code, out, err = env.sweep(sweep_threads, "--plots-only", "--resume", str(env.folder), folder=False)
        assert code == 0, err
        assert len(env.calls()) == n
        assert pngs(env.plots / "both") == BOTH_PLOTS and pngs(env.plots / "bloom_on")
        assert (env.results / "summary.csv").exists()
        assert len(table_rows(out, ("1", "2"))) == 4
        # --bloom selects what is plotted
        shutil.rmtree(env.plots)
        code, out, err = env.sweep(sweep_threads, "--plots-only", "--bloom", "off", "--resume", str(env.folder),
                                   folder=False)
        assert code == 0, err
        assert names(env.plots) == ["bloom_off"]


def test_failure_stops_and_resumes():
    with Env(wrong_off=True) as env:
        code, out, err = env.threads()
        assert code == 1
        assert "wrong result" in err and "remove" in err
        # The first point's on variant is done, its off variant failed (its folder is kept), nothing after it ran
        assert env.calls() == [["on", "1"], ["off", "1"]]
        assert (env.results / "bloom_on" / "threads_01" / "bench.yaml").exists()
        failed = env.results / "bloom_off" / "threads_01"
        assert (failed / "stdout.log").exists()
        assert not (env.results / "bloom_on" / "threads_02").exists()
        assert not (env.plots).exists()
        # Running again says the failed folder has to be removed; nothing runs
        code, out, err = env.threads()
        assert code == 1 and "remove" in err and len(env.calls()) == 2
        # Removed, and the problem is gone: the complete point is not run again
        shutil.rmtree(failed)
        env.wrong_off = False
        code, out, err = env.threads()
        assert code == 0, err
        assert env.calls()[2:] == [["off", "1"], ["on", "2"], ["off", "2"]]


def test_other_parameters_or_wrong_variant_are_refused():
    with Env() as env:
        assert env.threads("--bloom", "on")[0] == 0
        n = len(env.calls())
        # The same folder with another build size: refused, nothing runs
        code, out, err = env.sweep(sweep_threads, "--threads-list", "1", "2", "--ssize", "200", "--rsize", "1000")
        assert code == 1 and "other parameters" in err and len(env.calls()) == n
        # Results of Bloom on that sit where Bloom off belongs (runtime_bloom is compared)
        br = env.results
        shutil.copytree(br / "bloom_on", br / "bloom_off")
        code, out, err = env.threads("--bloom", "off")
        assert code == 1 and "runtime_bloom" in err and len(env.calls()) == n


def test_new_experiment_folder_is_type_date_time_with_results_and_plots_apart():
    with Env() as env:
        out_dir = env.tmp / "experiments"
        code, out, err = env.sweep(sweep_threads, "--threads-list", "1", "2", "--ssize", "100", "--rsize", "1000",
                                   "--results-dir", str(out_dir), folder=False)
        assert code == 0, err
        (folder,) = list(out_dir.iterdir())
        assert re.fullmatch(r"threads_\d{8}_\d{6}", folder.name), folder.name
        assert names(folder) == ["plots", "results"]
        assert names(folder / "results") == ["bloom_off", "bloom_on", "summary.csv"]
        assert names(folder / "plots") == ["bloom_off", "bloom_on", "both"]
        assert f"experiment: {folder}" in out
        # Nothing but the plots in plots/, nothing but results in results/
        assert {p.suffix for p in (folder / "plots").rglob("*") if p.is_file()} == {".png"}
        assert not list((folder / "results").rglob("*.png"))
    # Two experiments of a type started in the same second do not share a folder
    with tempfile.TemporaryDirectory() as tmp:
        a = bench.create_experiment_folder("egress", tmp)
        b = bench.create_experiment_folder("egress", tmp)
        assert a != b and b.name.startswith(a.name) and a.is_dir() and b.is_dir()
        assert re.fullmatch(r"egress_\d{8}_\d{6}", a.name)


def test_data_is_generated_in_a_temporary_directory_that_is_removed():
    with Env() as env:
        assert env.threads()[0] == 0
        # One directory below --tmp-dir for the whole sweep, shared by its points (and variants), gone afterwards
        assert len(env.data_dirs) == 4 and len(set(env.data_dirs)) == 1
        (data_dir,) = set(env.data_dirs)
        assert data_dir.parent == env.tmp_base and data_dir.name.startswith(bench.TMP_PREFIX)
        assert not data_dir.exists() and names(env.tmp_base) == []
        # Another sweep: another directory, again removed
        assert env.sweep(sweep_threads, "--threads-list", "1", "2", "4", "--ssize", "100", "--rsize", "1000")[0] == 0
        assert len(env.data_dirs) == 6 and env.data_dirs[-1] != data_dir and names(env.tmp_base) == []
        # Nothing to run (all points exist): no temporary directory is even created
        n = len(env.data_dirs)
        assert env.sweep(sweep_threads, "--threads-list", "1", "2", "4", "--ssize", "100", "--rsize", "1000")[0] == 0
        assert len(env.data_dirs) == n


def test_temporary_data_is_removed_after_a_failure():
    with Env(wrong_off=True) as env:
        code, out, err = env.threads()
        assert code == 1 and len(env.data_dirs) == 2
        assert not env.data_dirs[0].exists() and names(env.tmp_base) == []


def test_real_generation_goes_to_the_temporary_directory_and_is_removed():
    """gen_data for real (tiny, no FPGA): the fake CLI's numbers do not match, so the point fails, and the files
    are gone with the directory"""
    with Env() as env:
        bench.make_dataset = env._saved["make_dataset"]  # the real one
        seen = []
        real = bench.make_dataset

        def spy(params, data_dir, log=print):
            dataset = real(params, data_dir, log=log)
            seen.append((Path(data_dir), dataset.build_path, dataset.probe_path))
            assert dataset.build_path.exists() and dataset.probe_path.parent == Path(data_dir)
            return dataset
        bench.make_dataset = spy
        code, out, err = env.sweep(sweep_probe_size, "--min-exp", "12", "--max-exp", "12", "--ssize", "1000",
                                   "--threads", "1", "--bloom", "on")
        assert code == 1 and seen, err
        data_dir, build, probe = seen[0]
        assert data_dir.parent == env.tmp_base and not data_dir.exists()
        assert not build.exists() and not probe.exists() and names(env.tmp_base) == []


def test_help_mentions_bloom_in_every_script():
    for script in ("sweep_probe_size.py", "sweep_build_size.py", "sweep_columns.py", "sweep_egress.py",
                   "sweep_threads.py"):
        out = subprocess.run([sys.executable, str(BENCH_DIR / script), "--help"], capture_output=True, text=True,
                             timeout=120)
        assert out.returncode == 0
        assert "--bloom {on,off,both}" in out.stdout and "bloom_on" in out.stdout and "plots/both" in out.stdout


# ---------------------------------------------------------------------------
# From results folders written here (all five sweeps)
# ---------------------------------------------------------------------------

def write_point(folder, params, measures, runs=3):
    """A point as bench.py writes it (the keys sweep_lib and bench_data read): measures = {"host": {...},
    "decoder": {...}, "bloom": {...} or None}"""
    import yaml
    folder = Path(folder)
    folder.mkdir(parents=True)
    (folder / "meta.yaml").write_text(yaml.safe_dump({"returncode": 0, "parameters": {}}))
    iterations = [{"index": i, "kind": "measured", **measures} for i in range(runs)]
    (folder / "bench.yaml").write_text(yaml.safe_dump({
        "benchmark": {"status": "ok", "error": None, "warmup": 1, "iterations": runs},
        "parameters": params, "iterations": iterations}))


# sweep, the points as they are given to the sweep, the other parameters of the points (bench.yaml names)
CASES = [
    (sweep_probe_size, [1 << 17, 1 << 18, 1 << 20], {"s_size": 65536}),
    (sweep_build_size, [1 << 10, 1 << 14, 1 << 18], {"r_size": 1 << 25}),
    (sweep_columns, [0, 1, 2, 8, 16], {"s_size": 1 << 20, "r_size": 1 << 24}),
    (sweep_egress, [1.0, 2.0, 4.0, 0.0], {"s_size": 1 << 20, "r_size": 1 << 24}),
    (sweep_threads, [1, 2, 4, 8], {"s_size": 1 << 20, "r_size": 1 << 24}),
]


def point_measures(i, bloom):
    """Fake numbers of the i-th point: the filter makes the query faster, the decoder is slower without it"""
    base = 10.0 + 4 * i
    if bloom:
        host = {"query_ms": base, "scan_ms": 0.4 * base, "rest_ms": 0.6 * base}
        return {"host": host, "decoder": {"in_gbps": 3.0 + 0.1 * i, "out_gbps": 4.0 + 0.1 * i},
                "bloom": {"in_gbps": 6.0 + 0.1 * i, "out_gbps": 2.0}}
    host = {"query_ms": 1.8 * base, "scan_ms": 0.5 * base, "rest_ms": 1.3 * base}
    return {"host": host, "decoder": {"in_gbps": 2.5 + 0.2 * i, "out_gbps": 3.0 + 0.2 * i}, "bloom": None}


def write_sweep(folder, module, xs, other, variants=("bloom_on", "bloom_off")):
    """The results/ of a sweep of `module` with the points xs, point i as point_measures(i, ...)"""
    yaml_name = sweep_lib.PARAM_YAML[module.SWEEP.swept]
    for variant in variants:
        for i, x in enumerate(xs):
            where = Path(folder) / "results" / variant / module.SWEEP.folder_of(x)
            params = dict(other, **{yaml_name: x, "runtime_bloom": variant == "bloom_on"})
            write_point(where, params, point_measures(i, variant == "bloom_on"))


def test_all_five_sweeps_plot_from_results():
    for module, xs, other in CASES:
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp) / "f"
            write_sweep(folder, module, xs, other)
            code, out, err = run_main(module, ["--plots-only", "--resume", str(folder)] + (
                ["--link-gbps", "12.5"] if module is sweep_egress else []))
            assert code == 0, (module.__name__, err)
            plots = folder / "plots"
            assert names(plots) == ["bloom_off", "bloom_on", "both"], module.__name__
            assert pngs(plots / "bloom_on") == ON_PLOTS and pngs(plots / "bloom_off") == OFF_PLOTS
            assert pngs(plots / "both") == BOTH_PLOTS
            table = read_summary(folder)
            texts = [module.SWEEP.text(x) for x in sorted(xs, key=module.SWEEP.key)]
            assert [r[0] for r in table[1:]] == texts, (module.__name__, table)
            assert len(table[0]) == 1 + 2 * len(MEASURE_NAMES) - 2
            # A row per point and variant, in the order of the axis
            rows = table_rows(out, set(texts))
            assert [(r[0], r[1]) for r in rows] == [(t, v) for t in texts for v in ("on", "off")], out
            assert "warning" not in err


def test_variant_missing_for_some_points_and_empty_bloom_off_measures():
    """A partial folder: the filter-off variant has fewer points; its cells are empty, the plots only have the
    points it has"""
    module, xs, other = CASES[0]
    with tempfile.TemporaryDirectory() as tmp:
        folder = Path(tmp) / "f"
        write_sweep(folder, module, xs, other, variants=("bloom_on",))
        # off: only the first point
        yaml_name = sweep_lib.PARAM_YAML[module.SWEEP.swept]
        write_point(folder / "results" / "bloom_off" / module.SWEEP.folder_of(xs[0]),
                    dict(other, **{yaml_name: xs[0], "runtime_bloom": False}), point_measures(0, False))
        code, out, err = run_main(module, ["--plots-only", "--resume", str(folder)])
        assert code == 0, err
        table = read_summary(folder)
        header = table[0]
        row = dict(zip(header, table[2]))
        assert row["query_ms[bloom_on]"] != "" and row["query_ms[bloom_off]"] == ""
        assert pngs(folder / "plots" / "both") == BOTH_PLOTS
        assert len(table_rows(out, {"131072", "262144", "1048576"})) == 4


def _capture_figures(plot_utils):
    captured = []
    real = plot_utils._save
    plot_utils._save = lambda fig, path, fmt: (captured.append(fig), real(fig, path, fmt))[1]
    return captured, lambda: setattr(plot_utils, "_save", real)


def _lines(ax):
    return [(l.get_label(), list(l.get_xdata()), list(l.get_ydata()), l.get_color(), l.get_marker(),
             l.get_linestyle()) for l in ax.lines]


def test_combined_figure_content():
    """The figure of both variants: two lines with their own color, marker and style, a legend, y from zero"""
    plot_utils = sweep_lib._load_celeris_module("plot_utils")
    captured, restore = _capture_figures(plot_utils)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            path = sweep_lib.plot_lines(
                plot_utils, [(sweep_lib.ON, [1, 2, 4], [10.0, 12.0, 20.0]), (sweep_lib.OFF, [1, 2, 4], [30, 25, 50.0])],
                "Rows", "ms", "Title\nsub", Path(tmp) / "x" / "both.png", xscale="log")
            assert path.exists()
            ax = captured[0].axes[0]
            lines = _lines(ax)
            assert [l[0] for l in lines] == ["Bloom filter on", "Bloom filter off"]
            assert len({l[3] for l in lines}) == 2 and len({l[4] for l in lines}) == 2
            assert len({l[5] for l in lines}) == 2
            assert ax.get_xscale() == "log" and ax.get_ylim()[0] == 0 and ax.get_ylim()[1] >= 50
            assert [t.get_text() for t in ax.get_xticklabels()] == ["1", "2", "4"]
            assert [t.get_text() for t in ax.get_legend().get_texts()] == ["Bloom filter on", "Bloom filter off"]
            # One variant: no legend
            sweep_lib.plot_lines(plot_utils, [(sweep_lib.OFF, [1, 2], [3.0, 4.0])], "x", "GB/s", "t",
                                 Path(tmp) / "one.png")
            assert captured[1].axes[0].get_legend() is None
            for bad in (dict(lines=[], xscale="linear"), dict(lines=[(sweep_lib.ON, [0, 1], [1, 2])], xscale="log"),
                        dict(lines=[(sweep_lib.ON, [1, 2], [1])], xscale="linear")):
                try:
                    sweep_lib.plot_lines(plot_utils, bad["lines"], "x", "y", "t", Path(tmp) / "bad.png",
                                         xscale=bad["xscale"])
                except ValueError:
                    continue
                raise AssertionError(f"accepted {bad}")
    finally:
        restore()


def test_egress_uncapped_point_is_plotted_at_the_link_speed():
    module, xs, other = CASES[3]
    with tempfile.TemporaryDirectory() as tmp:
        write_sweep(tmp, module, xs, other)
        bench_data = sweep_lib._load_celeris_module("bench_data")
        module.LINK_GBPS = 10.0  # as --link-gbps sets it
        try:
            results = sweep_lib.collect(module.SWEEP, bench_data, Path(tmp) / "results", "median",
                                        sweep_lib.VARIANTS)
            assert results.xs == [1.0, 2.0, 4.0, 0.0] and results.num_runs == 3
            for v in sweep_lib.VARIANTS:
                assert [x for x, _ in results.line(module.SWEEP, v, "query_ms")] == [1.0, 2.0, 4.0, 10.0]
        finally:
            module.LINK_GBPS = 12.5
        assert [y for _, y in results.line(module.SWEEP, sweep_lib.OFF, "bloom_in")] == []


def test_breakdown_figure_content():
    plot_utils = sweep_lib._load_celeris_module("plot_utils")
    sweep = sweep_probe_size.SWEEP
    values = {"on": {x: {"scan_ms": 5.0 + i, "rest_ms": 3.0} for i, x in enumerate((1024, 2048, 4096))},
              "off": {x: {"scan_ms": 6.0, "rest_ms": 10.0 + i} for i, x in enumerate((1024, 2048, 4096))}}
    results = sweep_lib.Results([1024, 2048, 4096], values, list(sweep_lib.VARIANTS), 3)
    captured, restore = _capture_figures(plot_utils)
    try:
        with tempfile.TemporaryDirectory() as tmp:
            path = sweep_lib.plot_breakdown(plot_utils, sweep, results, "t", Path(tmp) / "b.png")
            assert path.exists()
    finally:
        restore()
    ax = captured[0].axes[0]
    assert len(ax.patches) == 12  # 3 points x 2 variants x (scan, join)
    assert [t.get_text() for t in ax.get_xticklabels()] == ["1024", "2048", "4096"]
    assert ax.get_ylim()[0] == 0
    assert len(ax.get_legend().get_texts()) == 4


if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"ok    {name}")
            except BaseException as e:  # noqa: BLE001 (also SystemExit of argparse)
                failed += 1
                print(f"FAIL  {name}: {type(e).__name__}: {e}")
                import traceback
                traceback.print_exc()
    sys.exit(1 if failed else 0)

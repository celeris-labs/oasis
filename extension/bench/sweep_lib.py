"""What the sweep scripts (sweep_probe_size.py, sweep_build_size.py, sweep_columns.py, sweep_egress.py,
sweep_threads.py) have in common.

A sweep varies one parameter of the experiment over a list of points and runs bench.py once per point, one after the
other (each point is one DuckDB process: warm-up runs, then measured runs). Every sweep collects the same measures
(so their results can be compared). An experiment is a folder <type>_<date>_<time> in the results directory (type:
probe_size, build_size, columns, egress or threads), with the results and the plots in separate folders:

    results/probe_size_20261013_101530/
        results/bloom_on/<point>/           one folder per point and variant, as written by bench.py
        results/bloom_off/<point>/
        results/summary.csv                 one row per point, the measures of both variants side by side
        plots/bloom_on/<measure>.png        one plot per measure and variant
        plots/bloom_off/<measure>.png
        plots/both/<measure>.png            both variants as two lines (Bloom on and off), one picture per measure
        plots/both/query_breakdown.png      scan and rest of the query, stacked, per point (also in plots/bloom_on and bloom_off)

The Parquet files are generated into a temporary directory when the sweep starts (a point needs them) and removed
when it ends, also after a failure or Ctrl-C: nothing is kept between sweeps. Within one sweep the points share what
they can (the two variants of a point, and all points of the columns sweep, which use one probe file).

--bloom {on,off,both} (default: both) chooses the variants: the value of the extension setting
oasis_runtime_bloom_filter of the points of the sweep. With `both`, the two variants of a point run back to back
(on, then off, point by point), so that drift of the machine affects both alike. The variants are plotted and
tabulated side by side.

Measures (every point is the aggregate, by default the median, over the measured runs of that point):

    query_ms        total query time: the host's wall clock from the start of the query to its end, planning
                    included                                                             host.query_ms
    scan_ms         total scan time: the host's wall clock of the read_oasis scans (the one with the Bloom
                    filter includes submitting its build side and ending it again)       host.scan_ms
    rest_ms         the rest of the query = total - scan: planning, the join operators and what follows  host.rest_ms
    decoder_in      the Parquet decoder's input throughput during the probe (hardware StreamProfiler, read when
                    the probe scan starts and when the query ends: the rate over the probe side only, from its
                    first beat to the last handshake, idle cycles between flows included)  decoder.in_gbps
    decoder_out     the same for its output                                               decoder.out_gbps
    bloom_in        the Bloom filter's input (probe keys and columns to materialize) during the probe: from the
                    first probe key beat to the last output (hardware performance counters; only with the
                    filter on)                                                            bloom.in_gbps
    bloom_out       its output (kept keys, materialized columns, mask) over the same window  bloom.out_gbps

Times are the host's view, throughputs the hardware's. README.md has the exact definitions.

Plots: the y axis starts at zero. Every measure gets a plot per variant that has it (bloom_in and bloom_out only
exist with the filter on, so there is no Bloom-off plot of them) and, if both variants have results, one picture
with both lines in plots/both/ (not for bloom_in and bloom_out: one line, it would be the Bloom-on plot again).

A sweep stops at the first failure (a failed or hung run can leave the device in a bad state). Run it again to
continue: `--resume <experiment folder>` runs the points that are missing (complete points are skipped, after
checking that they were run with the parameters of the sweep, the Bloom filter setting included), and the folder of a
failed point (it is kept for its logs) has to be removed first. `--plots-only` with `--resume` plots what is there.
"""

import argparse
import contextlib
import csv
import importlib.util
import signal
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Optional

import bench

CELERIS_EXAMPLE = bench.OASIS_DIR / "celeris" / "examples" / "06_bloomfilter"
DEFAULT_RESULTS = bench.DEFAULT_RESULTS
RESULTS_NAME = "results"  # The results and the plots are separate folders of an experiment
PLOTS_NAME = "plots"


def _load_celeris_module(name):
    """plot_utils.py and bench_data.py are reused from the celeris example, as files (not through sys.path: the
    example has a bench.py and a sweep_lib.py of its own)"""
    path = CELERIS_EXAMPLE / f"{name}.py"
    if not path.exists():
        raise bench.BenchmarkError(f"{path} does not exist (the celeris submodule is needed for {name}.py)")
    spec = importlib.util.spec_from_file_location(f"celeris_{name}", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# What bench.yaml's `parameters` calls the parameters of bench.PARAMS
PARAM_YAML = {
    "ssize": "s_size", "rsize": "r_size", "matchratio": "match_ratio", "zipffactor": "zipf_factor",
    "columns": "materialized_columns", "batchsize": "batch_size", "numbatches": "num_batches",
    "compression": "compression", "encoding": "encoding", "runtime_bloom": "runtime_bloom",
    "egress_gbps": "emulated_egress_gbps", "threads": "threads",
}

# What every sweep fixes unless it sweeps it itself (the options of every sweep change them): uniform probe keys
# (Zipf 1 is one hot bank, which limits the probe), all probe keys match, uncompressed files
BASE_FIXED = {"ssize": 1 << 20, "rsize": 1 << 24, "columns": 2, "matchratio": 1.0, "zipffactor": 0.0,
              "compression": "uncompressed", "encoding": "auto", "egress_gbps": 0.0, "threads": None,
              "batchsize": 120000, "runtime_bloom": True}

# name of the measure, the dotted path in a measured run, unit (the y label of the plot), title, decimals, header
MEASURES = [
    ("query_ms", "host.query_ms", "ms", "Total query time (host)", 2, "query"),
    ("scan_ms", "host.scan_ms", "ms", "Total scan time (host)", 2, "scan"),
    ("rest_ms", "host.rest_ms", "ms", "Rest of the query = total - scan (host)", 2, "rest"),
    ("decoder_in", "decoder.in_gbps", "GB/s", "Decoder input throughput during probe (hardware)", 3, "decoder in"),
    ("decoder_out", "decoder.out_gbps", "GB/s", "Decoder output throughput during probe (hardware)", 3,
     "decoder out"),
    ("bloom_in", "bloom.in_gbps", "GB/s", "Bloom filter input throughput during probe (hardware)", 3, "bloom in"),
    ("bloom_out", "bloom.out_gbps", "GB/s", "Bloom filter output throughput during probe (hardware)", 3,
     "bloom out"),
]
X_WIDTH = 12
WIDTH = 12
BLOOM_WIDTH = 5  # the column of the variant in the table

# Only measured with the Bloom filter on: there is no plot of them for Bloom off, and no picture with both variants
BLOOM_ONLY = ("bloom_in", "bloom_out")


@dataclass(frozen=True)
class Variant:
    """One value of oasis_runtime_bloom_filter, with how it is told apart in folders and plots"""
    option: str      # the value of --bloom
    folder: str      # below results/ and plots/, and the tag in summary.csv
    bloom: bool      # oasis_runtime_bloom_filter
    label: str       # legend and titles of the plots
    color: str       # Okabe-Ito blue (plot_utils' own series color) and vermillion: told apart with all color
    marker: str      # blindness; the markers and line styles tell them apart in grayscale
    linestyle: str


ON = Variant("on", "bloom_on", True, "Bloom filter on", "#2a78d6", "o", "-")
OFF = Variant("off", "bloom_off", False, "Bloom filter off", "#d55e00", "s", "--")
VARIANTS = (ON, OFF)
BLOOM_CHOICES = ("on", "off", "both")


def variants_of(choice):
    """The variants --bloom selects, Bloom on first"""
    return [v for v in VARIANTS if choice in ("both", v.option)]


@dataclass
class Sweep:
    """One kind of sweep"""
    script: str                              # File name, for messages
    description: str                         # First paragraph of --help
    experiment: str                          # The type of the experiment: the folder <experiment>_<date>_<time>
    swept: str                               # The parameter of bench.PARAMS that varies
    x_header: str                            # Header of the first column of the table
    x_label: str                             # X axis of the plots
    xscale: str                              # "linear" or "log"
    folder_of: Callable[[float], str]        # Name of the folder of a point, below results/<variant>/
    fixed: dict = field(default_factory=dict)  # Defaults of the fixed parameters that differ from BASE_FIXED
    doc: str = ""                            # The epilog of --help
    # A point whose value is not where it belongs on the axis (the egress cap 0 is "off", which is the link's own
    # speed): the text of a point in the table, where to plot it, and the order of the points
    x_text: Optional[Callable[[float], str]] = None
    plot_x: Optional[Callable[[float], float]] = None
    sort_key: Optional[Callable[[float], object]] = None
    # Parameters of every point that depend on all points: {name: value} from the list of points
    extra_params_of: Optional[Callable[[list], dict]] = None

    def text(self, x):
        if self.x_text:
            return self.x_text(x)
        return str(int(x)) if float(x).is_integer() else f"{x:g}"  # 1048576, not 1.04858e+06

    def at(self, x):
        return self.plot_x(x) if self.plot_x else x

    def key(self, x):
        return self.sort_key(x) if self.sort_key else x


def point_params(sweep, args_fixed, xs, x):
    """The parameters of a point, without runtime_bloom (that is the variant's)"""
    params = dict(args_fixed)
    params[sweep.swept] = x
    if sweep.extra_params_of:
        params.update(sweep.extra_params_of(xs))
    return params


def check_existing(sweep, bench_data, folder, params):
    """Whether the folder holds complete results of this point (with this Bloom filter setting, if params has
    runtime_bloom). Raises if it holds something else"""
    try:
        run = bench_data.load_run(folder)
    except FileNotFoundError:
        return False  # Nothing there yet
    except ValueError as e:
        raise bench.BenchmarkError(f"{e}: remove {folder} to run this point again") from None
    wrong = {}
    for name, yaml_name in PARAM_YAML.items():
        if name == "batchsize" and params.get("numbatches") is not None:
            continue
        want = params.get(name)
        if name in params and run.params.get(yaml_name) != want:
            wrong[yaml_name] = want
    if wrong:
        raise bench.BenchmarkError(f"{folder} was run with other parameters than this sweep (expected {wrong}): "
                                   "use another --folder, or remove it")
    return True


def measures(run, reduce):
    """The aggregate of every measure over the measured runs of one point: {measure name: value}. A measure
    the run does not have (the Bloom filter's, when it was switched off) is None"""
    values = {}
    for name, path, *_ in MEASURES:
        try:
            values[name] = run.aggregate(path, reduce)
        except (KeyError, TypeError):
            values[name] = None
    return values


# ---------------------------------------------------------------------------
# The folder
# ---------------------------------------------------------------------------

def load_variant_runs(bench_data, results_dir, variants):
    """The complete benchmarks in the folder: {variant.option: [Run, ...]} for the given variants"""
    found = {v.option: [] for v in variants}
    for v in variants:
        path = Path(results_dir) / v.folder
        if path.is_dir():
            found[v.option] = bench_data.load_runs(path)
    return found


@dataclass
class Results:
    """The points of a folder: values[variant.option][x] = {measure name: value}"""
    xs: list          # all points, in the order of the axis
    values: dict
    variants: list    # the variants that have at least one point, Bloom on first
    num_runs: int     # measured runs behind a point (the fewest of any)

    def value(self, variant, x, name):
        return self.values[variant.option].get(x, {}).get(name)

    def line(self, sweep, variant, name):
        """The points of a measure of one variant that have it: [(plotted x, y)]"""
        return [(sweep.at(x), self.value(variant, x, name)) for x in self.xs
                if self.value(variant, x, name) is not None]


def collect(sweep, bench_data, results_dir, agg, variants):
    """The measures of every point in the folder, for the given variants"""
    found = load_variant_runs(bench_data, results_dir, variants)
    if not any(found.values()):
        raise bench.BenchmarkError(f"no complete results in {results_dir}"
                                   + ("" if len(variants) > 1 else f" for {variants[0].label.lower()}"))
    reduce = bench_data.AGGREGATIONS[agg]
    x_of = lambda r: r.params[PARAM_YAML[sweep.swept]]
    values, xs, num_runs = {}, set(), None
    for v in variants:
        if not found[v.option]:
            continue
        values[v.option] = {}
        for run in found[v.option]:
            x = x_of(run)
            xs.add(x)
            values[v.option][x] = measures(run, reduce)
            n = len(run.iterations)
            num_runs = n if num_runs is None else min(num_runs, n)
    return Results(sorted(xs, key=sweep.key), values, [v for v in variants if v.option in values], num_runs)


# ---------------------------------------------------------------------------
# The table and the summary
# ---------------------------------------------------------------------------

def print_log_tail(folder, lines=15):
    """What the CLI printed last, as the sweep does not show its output"""
    for name in ("stderr.log", "stdout.log"):
        log = Path(folder) / name
        if log.exists() and log.stat().st_size:
            tail = log.read_text().splitlines()[-lines:]
            print(f"\nlast lines of {log}:", file=sys.stderr)
            print("\n".join("    " + line[:200] for line in tail), file=sys.stderr)


def widths():
    return (X_WIDTH, BLOOM_WIDTH) + (WIDTH,) * len(MEASURES)


def print_header(sweep, agg, num_runs):
    print(f"{agg} over {num_runs} measured runs per point; times in ms (host view), throughputs in GB/s (hardware "
          "view, during the probe); rest = total query time - scan time; bloom: oasis_runtime_bloom_filter")
    for cells in ([sweep.x_header, "bloom"] + [m[5] for m in MEASURES], ["", ""] + [m[2] for m in MEASURES]):
        print("  ".join(f"{c:>{w}s}" for c, w in zip(cells, widths())))
    print("  ".join("-" * w for w in widths()))


def print_row(sweep, x, variant, values, note=""):
    cells = [sweep.text(x), variant.option]
    for name, _path, _unit, _title, decimals, _h in MEASURES:
        value = values.get(name)
        cells.append("n/a" if value is None else f"{value:.{decimals}f}")
    print("  ".join(f"{c:>{w}s}" for c, w in zip(cells, widths())) + (f"  ({note})" if note else ""), flush=True)


def print_results(sweep, results):
    """The table of everything in the folder: a row per point and variant"""
    for x in results.xs:
        for v in results.variants:
            if x in results.values[v.option]:
                print_row(sweep, x, v, results.values[v.option][x])


def _cell(value):
    return "" if value is None else f"{value:.6g}"  # not 5.6000000000000005


def write_summary(sweep, results, path):
    """One row per point; per measure a column of each variant that has it: query_ms[bloom_on], ..."""
    columns = [(m[0], v) for m in MEASURES for v in results.variants
               if any(results.value(v, x, m[0]) is not None for x in results.xs)]
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow([sweep.swept] + [f"{name}[{v.folder}]" for name, v in columns])
        for x in results.xs:
            w.writerow([sweep.text(x)] + [_cell(results.value(v, x, name)) for name, v in columns])
    return path


# ---------------------------------------------------------------------------
# Plots (plot_utils.py draws one line; these draw one or two, in the same style)
# ---------------------------------------------------------------------------

def _check_xs(xs, xscale):
    if xscale not in ("linear", "log"):
        raise ValueError(f"xscale has to be 'linear' or 'log', not {xscale!r}")
    if xscale == "log" and min(xs) <= 0:
        raise ValueError(f"a log x scale needs x > 0, but x has {min(xs)}")


def plot_lines(plot_utils, lines, xlabel, ylabel, title, path, xscale="linear"):
    """Variants over x, one line with markers each, written to `path` (the format is its extension). The figure
    size, style, ticks and the y axis from zero are those of plot_utils.

    lines: [(Variant, x values, y values), ...]. With more than one a legend names them. Returns the Path"""
    lines = [(v, list(x), list(y)) for v, x, y in lines]
    if not lines or any(not x or len(x) != len(y) for _v, x, y in lines):
        raise ValueError("nothing to plot, or x and y of a line differ in length")
    all_x = [x for _v, xs, _y in lines for x in xs]
    _check_xs(all_x, xscale)
    path, fmt = plot_utils._check_path(path)
    pu = plot_utils

    fig, ax = pu.plt.subplots(figsize=pu.FIGURE_SIZE, facecolor=pu.SURFACE)
    for v, x, y in lines:
        ax.plot(x, y, color=v.color, linestyle=v.linestyle, linewidth=1.8, marker=v.marker, markersize=7,
                markerfacecolor=v.color, markeredgecolor=pu.SURFACE, markeredgewidth=1.5, label=v.label)
    ax.set_xscale(xscale)  # Before the ticks: it resets them
    if len(set(all_x)) <= pu.MAX_LABELLED_TICKS:
        ticks = sorted(set(all_x))  # Few points: label each of them, rather than a round number nearby
        labels = [pu._number_label(t) for t in ticks]
        crowded = len(ticks) > 5 and max(map(len, labels)) > 5  # 131,072 ... 67,108,864 would overlap
        ax.set_xticks(ticks, labels, rotation=45 if crowded else 0, ha="right" if crowded else "center")
        ax.minorticks_off()
    ax.set_ylim(0, max(max(y) for _v, _x, y in lines) * 1.1 or 1e-9)
    pu._style_axes(ax, xlabel, ylabel, title)
    if len(lines) > 1:
        legend = ax.legend(loc="best", frameon=True, facecolor=pu.SURFACE, edgecolor=pu.GRID, fontsize=9)
        for text in legend.get_texts():
            text.set_color(pu.INK_PRIMARY)
    fig.tight_layout()
    return pu._save(fig, path, fmt)


# The parts of a query in the breakdown: the tint of the variant's color, hatched, for the join
_BREAKDOWN_TINT = {"on": "#a9c9ee", "off": "#f0b48a"}


def plot_breakdown(plot_utils, sweep, results, title, path):
    """Per point, one stacked bar of scan time (bottom) and the rest (top) for each variant, side by side: the
    height is the total query time. The points are equally spaced and labelled, whatever their values"""
    pu = plot_utils
    path, fmt = pu._check_path(path)
    variants = results.variants
    n, k = len(results.xs), len(variants)
    width = 0.8 / k
    fig, ax = pu.plt.subplots(figsize=pu.FIGURE_SIZE, facecolor=pu.SURFACE)
    top = 0.0
    for j, v in enumerate(variants):
        pos = [i + (j - (k - 1) / 2) * width for i in range(n)]
        scan = [results.value(v, x, "scan_ms") or 0.0 for x in results.xs]
        rest = [results.value(v, x, "rest_ms") or 0.0 for x in results.xs]
        ax.bar(pos, scan, width * 0.9, color=v.color, edgecolor=pu.SURFACE, linewidth=0.8, label=f"{v.label}: scan")
        ax.bar(pos, rest, width * 0.9, bottom=scan, color=_BREAKDOWN_TINT[v.option], edgecolor=pu.SURFACE,
               linewidth=0.8, label=f"{v.label}: rest of the query")
        top = max([top] + [s + t for s, t in zip(scan, rest)])
    labels = [sweep.text(x) for x in results.xs]
    ax.set_xticks(range(n), labels, rotation=45 if n > 8 and max(map(len, labels)) > 4 else 0,
                  ha="right" if n > 8 and max(map(len, labels)) > 4 else "center")
    ax.tick_params(axis="x", labelsize=9 if n > 10 else 10)
    ax.set_ylim(0, max(top * 1.3, 1e-9))  # Headroom for the legend
    pu._style_axes(ax, sweep.x_label, "ms", title)
    legend = ax.legend(loc="upper left", ncol=2, frameon=True, facecolor=pu.SURFACE, edgecolor=pu.GRID, fontsize=8)
    for text in legend.get_texts():
        text.set_color(pu.INK_PRIMARY)
    fig.tight_layout()
    return pu._save(fig, path, fmt)


def make_plots(sweep, plot_utils, results, plots_dir, fmt, agg):
    """<plots_dir>/<variant>/<measure> for every variant, plots/both/<measure> and plots/both/query_breakdown if
    there are two. Returns the paths written"""
    subtitle = f"{agg} of {results.num_runs} runs"  # A second line: the titles are long
    plots_dir = Path(plots_dir)
    written = []
    for v in results.variants:
        for name, _path, unit, title, _d, _h in MEASURES:
            points = results.line(sweep, v, name)
            if not points:
                if not (v is OFF and name in BLOOM_ONLY):  # The filter was off: nothing to plot, as expected
                    print(f"warning: no plot of {name} for {v.label.lower()}: the results do not have it",
                          file=sys.stderr)
                continue
            written.append(plot_lines(plot_utils, [(v, [x for x, _ in points], [y for _, y in points])],
                                      sweep.x_label, unit, f"{title}\n{v.label}, {subtitle}",
                                      plots_dir / v.folder / f"{name}.{fmt}", xscale=sweep.xscale))
    # The breakdown of the query time (scan + rest) is always drawn: one figure per variant and, with both, one
    # with the two side by side
    def complete(vs):
        return all(results.line(sweep, v, "scan_ms") and results.line(sweep, v, "rest_ms") for v in vs)
    for v in results.variants:
        if complete([v]):
            single = Results(results.xs, results.values, [v], results.num_runs)
            written.append(plot_breakdown(plot_utils, sweep, single,
                                          f"Where the query time goes: scan + rest (host)\n{v.label}, {subtitle}",
                                          plots_dir / v.folder / f"query_breakdown.{fmt}"))
    if len(results.variants) > 1 and complete(results.variants):
        written.append(plot_breakdown(plot_utils, sweep, results,
                                      f"Where the query time goes: scan + rest (host)\n{subtitle}",
                                      plots_dir / "both" / f"query_breakdown.{fmt}"))
    if len(results.variants) > 1:
        for name, _path, unit, title, _d, _h in MEASURES:
            if name in BLOOM_ONLY:
                continue
            lines = [(v, [x for x, _ in pts], [y for _, y in pts]) for v in results.variants
                     for pts in [results.line(sweep, v, name)] if pts]
            if len(lines) > 1:
                written.append(plot_lines(plot_utils, lines, sweep.x_label, unit, f"{title}\n{subtitle}",
                                          plots_dir / "both" / f"{name}.{fmt}", xscale=sweep.xscale))
    return written


# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------

def governor_warning():
    govs = set(bench.governors().values())
    if govs - {"performance"}:
        print(f"warning: CPU governor is {sorted(govs)}, not 'performance' (sudo cpupower frequency-set -g "
              "performance)", file=sys.stderr)


def run_sweep(sweep, bench_data, xs, args, fixed, results_dir, variants):
    """Runs the missing points, point by point and, within a point, the variants one after the other (so a drift
    of the machine affects them alike), printing the row of each as soon as it is done. The Parquet files go into
    one temporary directory, created when the first point needs it and removed when the sweep ends"""
    reduce = bench_data.AGGREGATIONS[args.agg]
    live = sys.stdout.isatty()
    with contextlib.ExitStack() as stack:
        data_dir = None
        for x in xs:
            for v in variants:
                folder = Path(results_dir) / v.folder / sweep.folder_of(x)
                params = dict(point_params(sweep, fixed, xs, x), runtime_bloom=v.bloom)
                note = ""
                if check_existing(sweep, bench_data, folder, params):
                    note = "existing"
                else:
                    if data_dir is None:
                        data_dir = stack.enter_context(
                            tempfile.TemporaryDirectory(prefix=bench.TMP_PREFIX, dir=args.tmp_dir))
                    if live:  # A placeholder that the row replaces
                        print(f"{sweep.text(x):>{X_WIDTH}s}  {v.option:>{BLOOM_WIDTH}s}  running ...", end="",
                              flush=True)
                    try:
                        bench.run_benchmark(folder, params, warmup=args.warmup, iterations=args.iterations,
                                            binary=args.binary, data_dir=data_dir, lib_dir=args.lib_dir,
                                            timeout=args.timeout, wait_device=args.wait_device, quiet=True)
                    except bench.BenchmarkError:
                        if live:
                            print("\r\033[K", end="")
                        print_log_tail(folder)
                        print(f"\nfailed: {sweep.text(x)} with {v.label.lower()}; its folder is kept for the logs: "
                              f"remove {folder} before running this point again", file=sys.stderr)
                        raise
                    if live:
                        print("\r\033[K", end="")
                print_row(sweep, x, v, measures(bench_data.load_run(folder), reduce), note)


def main(sweep, add_args, points_of, argv=None):
    """The command line of a sweep script.

    add_args(parser): adds the options that choose the points
    points_of(args, parser): the list of points (calls parser.error for a bad choice)
    """
    parser = argparse.ArgumentParser(description=sweep.description, epilog=sweep.doc or "See the top of this file.",
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--results-dir", type=Path, default=DEFAULT_RESULTS,
                        help="where a new experiment's folder <type>_<date>_<time> is created (default: "
                             "%(default)s)")
    parser.add_argument("--resume", type=Path, metavar="FOLDER",
                        help="the folder of an earlier experiment of this type: run its missing points (complete "
                             "points are skipped) and plot, or with --plots-only only plot. Without it a new "
                             "experiment folder is created, so a sweep never lands in the results of an earlier one")
    parser.add_argument("--bloom", choices=BLOOM_CHOICES, default="both",
                        help="oasis_runtime_bloom_filter of the points: on, off, or both (default: %(default)s: "
                             "the two variants of a point run back to back, every point has two results, and "
                             "there are plots of each variant and of both together). The variants have folders "
                             "of their own (results/bloom_on, bloom_off). With --plots-only it selects "
                             "what is plotted")
    add_args(parser)
    group = parser.add_argument_group("the parameters this sweep keeps fixed")
    fixed_defaults = {**BASE_FIXED, **sweep.fixed}
    types = {p[0]: p[2] for p in bench.PARAMS}
    for name in ("ssize", "rsize", "columns", "matchratio", "zipffactor", "compression", "egress_gbps", "threads",
                 "batchsize"):
        if name == sweep.swept:
            continue
        group.add_argument(f"--{name}", type=types[name], default=fixed_defaults[name], metavar=name.upper(),
                           help="(default: %(default)s)")
    group = parser.add_argument_group("benchmark")
    group.add_argument("--warmup", "-w", type=int, default=bench.BENCH_DEFAULTS["warmup"],
                       help="warm-up runs per point (default: %(default)s)")
    group.add_argument("--iterations", "-i", type=int, default=bench.BENCH_DEFAULTS["iterations"],
                       help="measured runs per point (default: %(default)s)")
    group.add_argument("--agg", default="median",
                       help="how the measured runs of a point become one value: median, mean, min, max (default: "
                            "%(default)s)")
    group.add_argument("--timeout", type=float, default=bench.BENCH_DEFAULTS["timeout"],
                       help="seconds one point's DuckDB process may take, then it is stopped and the sweep fails "
                            "(default: %(default)s)")
    group.add_argument("--wait-device", type=float, default=900.0, metavar="SECONDS",
                       help="how long to wait for another process to let go of the FPGA before a point "
                            "(default: %(default)s)")
    group.add_argument("--format", choices=("png", "pdf", "svg"), default="png", help="of the plots (default: png)")
    group.add_argument("--binary", type=Path, default=bench.DEFAULT_BINARY, help="the DuckDB CLI with the extension")
    group.add_argument("--tmp-dir", type=Path, default=None,
                       help="where the temporary directory with the generated Parquet files is created (removed when "
                            "the sweep ends; default: the system's temporary directory; the largest point needs "
                            "8 B x probe rows x (1 + columns))")
    group.add_argument("--lib-dir", type=Path, default=bench.DEFAULT_LIB_DIR)
    group.add_argument("--plots-only", action="store_true", help="plot the results in the folder, run nothing")
    group.add_argument("--no-plots", action="store_true", help="only run, do not plot (matplotlib is not needed)")
    args = parser.parse_args(argv)
    if args.plots_only and args.no_plots:
        parser.error("--plots-only and --no-plots leave nothing to do")
    # SIGTERM unwinds like Ctrl-C, so the temporary data is removed (the CLI is waited for, see bench.run_cli)
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))
    main_folder = None
    xs = points_of(args, parser)
    fixed = {name: getattr(args, name) for name in BASE_FIXED if hasattr(args, name)}
    fixed.pop("runtime_bloom", None)  # The variant's, set per point
    variants = variants_of(args.bloom)

    try:
        bench_data = _load_celeris_module("bench_data")
        if args.agg not in bench_data.AGGREGATIONS:
            parser.error(f"--agg: one of {sorted(bench_data.AGGREGATIONS)}")
        plot_utils = None
        if not args.no_plots:
            # Before the sweep, which can take long: it would be a pity to find out afterwards
            try:
                plot_utils = _load_celeris_module("plot_utils")
            except ImportError as e:
                print(f"error: {e}\nInstall matplotlib (source ~/plotting/bin/activate), or run with --no-plots and "
                      "plot later with --plots-only", file=sys.stderr)
                return 1

        if args.resume is not None:
            main_folder = args.resume.resolve()
            if not main_folder.is_dir():
                parser.error(f"--resume: {main_folder} is not a folder")
        elif args.plots_only:
            parser.error("--plots-only needs the experiment folder to plot: --resume FOLDER")
        else:
            main_folder = bench.create_experiment_folder(sweep.experiment, args.results_dir).resolve()
        results_dir, plots_dir = main_folder / RESULTS_NAME, main_folder / PLOTS_NAME

        if not args.plots_only:
            results_dir.mkdir(parents=True, exist_ok=True)
            print(f"experiment: {main_folder}")
            governor_warning()
            print_header(sweep, args.agg, args.iterations)
            run_sweep(sweep, bench_data, xs, args, fixed, results_dir, variants)
        if not args.no_plots:
            results = collect(sweep, bench_data, results_dir, args.agg, variants)
            if args.plots_only:
                print_header(sweep, args.agg, results.num_runs)
                print_results(sweep, results)
            print()
            print(f"summary: {write_summary(sweep, results, results_dir / 'summary.csv')}")
            for path in make_plots(sweep, plot_utils, results, plots_dir, args.format, args.agg):
                print(f"plot: {path}")
    except bench.BenchmarkError as e:
        print(f"error: {e}", file=sys.stderr)
        if not args.plots_only:
            print(f"To continue this sweep (complete points are skipped): ./{sweep.script} --resume "
                  f"{main_folder or '<experiment folder>'} [the same options]", file=sys.stderr)
        return 1
    return 0

#!/usr/bin/env python3
"""Runs one point of the oasis Bloom filter benchmark through the extension's DuckDB CLI.

    ./bench.py --ssize 65536 --rsize 16777216 --columns 2 --zipffactor 0

generates the synthetic Parquet files in a temporary directory (gen_data.py: a build file S with a sequential key,
a probe file R with a foreign key and `columns` INT64 payload columns, all OPTIONAL without NULLs; the directory is
removed when the run ends, so nothing is reused between runs), then runs

    SELECT count(*), sum(p.key), sum(p.c1), ... FROM read_oasis(S) b JOIN read_oasis(R) p ON p.key = b.key

(warm-up runs, then measured runs, all in one DuckDB process). The experiment gets a folder of its own,
<results-dir>/<experiment>_<date>_<time> (default: results/bench_20261013_101530), with the results in `results/`
(and `plots/`, which a single run has none of; the sweeps fill both):

    results/run.sql       the script that was fed to the CLI (settings, the query, the readout of the statistics)
    results/stdout.log    everything the CLI printed: the raw statistics of every run, parsed from here
    results/stderr.log    what it printed to stderr
    results/meta.yaml     how it was run: command, parameters, dataset, git state of the repositories, libraries
    results/bench.yaml    the parsed values of the measured runs (and of the warm-ups), see README.md

What is measured, per run (see README.md for the exact definitions):

    host   total query time, total scan time, rest = total - scan: the host's wall clock (the extension's
           OasisQueryStats record)
    decoder   IN and OUT throughput of the Parquet decoder during the PROBE only: the hardware's
           StreamProfiler counters, which the extension reads when the probe scan starts and when the query ends
           (OasisDecoderProfile record; the final segment). The profile of the whole run is in `decoder_run`
    bloom  IN and OUT throughput of the Bloom filter over the probe window, from the first probe key beat to the
           last output (OasisBloomFilterStats record)

The same is available from other scripts (this file is the foundation of the sweeps):

    from bench import run_benchmark
    run_benchmark("results/x/2pow20", {"ssize": 1 << 16, "rsize": 1 << 20, "zipffactor": 0})
    # the folder is used as given; without data_dir the data is generated in a temporary directory and removed

NEVER run two benchmarks at once, and stop at the first failure. The FPGA is shared with other users: a run waits
for (--wait-device) or refuses to start while another process has the device open, every run is under a time limit
(--timeout), and a hung run that had to be killed can leave the device in a state in which all later runs hang too:
check it before starting another run.
"""

import argparse
import datetime
import fcntl
import hashlib
import json
import os
import platform
import re
import signal
import statistics
import tempfile
import subprocess
import sys
import threading
import time
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parent
EXTENSION_DIR = BENCH_DIR.parent
OASIS_DIR = EXTENSION_DIR.parent
DEFAULT_BINARY = EXTENSION_DIR / "build" / "release" / "duckdb"
DEFAULT_RESULTS = BENCH_DIR / "results"  # An experiment is a folder <kind>_<date>_<time> in it
TMP_PREFIX = "oasis_bench_data_"
DEFAULT_LIB_DIR = Path.home() / "opt" / "lib"  # libcoyote, libjemalloc, liboasis, ...: not found through RUNPATH

DEVICE = Path("/dev/coyote_fpga_0_v0")
HUGEPAGES_1G = Path("/sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages")
HUGEPAGES_CMD = "sudo /opt/hdev/cli/hdev set hugepages --num-2m 0 --num-1g 8"
LOCK_FILE = Path("/tmp/oasis_fpga_bench.lock")  # Between our own scripts; other users are detected with fuser

# The device clock, and what one handshake transports (a beat of the streams is 64 B)
CLOCK_NS = 4.0
BEAT_BYTES = 64

BENCH_DEFAULTS = {"warmup": 3, "iterations": 10, "timeout": 600.0, "wait_device": 0.0}


def _bool(text):
    if text.lower() in ("1", "true", "yes", "on"):
        return True
    if text.lower() in ("0", "false", "no", "off"):
        return False
    raise argparse.ArgumentTypeError(f"not a boolean: {text}")


# name, short option, type, default, help. The first group has the names and defaults of the celeris binary's
# options (celeris/examples/06_bloomfilter), the rest is specific to Parquet files and to the extension
PARAMS = [
    ("ssize", "s", int, 1 << 18, "Rows of S, the build side"),
    ("rsize", "r", int, 1 << 18, "Rows of R, the probe side (has to be larger than S: the extension takes the "
                                 "relation with fewer rows as the build side)"),
    ("matchratio", "m", float, 1.0, "Fraction of the probe keys that occur on the build side"),
    # Same as the celeris binary's default. Note that 1 skews the probe keys onto one hot bank, which then limits the
    # probe; pass --zipffactor 0 for uniform keys (what the sweeps use)
    ("zipffactor", "z", float, 1.0, "Zipf skew of the probe keys (0: uniform)"),
    ("columns", "c", int, 2, "Probe columns (INT64) to materialize besides the key"),
    ("batchsize", "b", int, 120000, "Rows per row group of both files (not with --numbatches; at most 131072)"),
    ("numbatches", "n", int, None, "Row groups per file (not with --batchsize)"),
    ("compression", None, str, "uncompressed", "Parquet compression: uncompressed or snappy"),
    ("encoding", None, str, "auto", "Parquet encoding: auto (the writer's choice) or plain (no dictionary)"),
    ("file_columns", None, int, None, "Payload columns in the probe file, at least --columns (default: --columns). "
                                     "Unused columns are not read, so a sweep over --columns can share one file"),
    ("runtime_bloom", None, _bool, True, "oasis_runtime_bloom_filter: filter the probe side with the hardware "
                                         "Bloom filter (off: a plain join of two read_oasis scans)"),
    ("egress_gbps", None, float, 0.0, "oasis_emulated_egress_gbps: cap the FPGA->host output to this many GB/s "
                                     "(0: off)"),
    ("threads", None, int, None, "DuckDB's threads setting (default: DuckDB's, one per hardware thread)"),
]
PARAM_NAMES = [p[0] for p in PARAMS]


class BenchmarkError(RuntimeError):
    pass


def experiment_folder(kind, results_dir=None, when=None):
    """The folder of an experiment: <results_dir>/<kind>_<YYYYMMDD>_<HHMMSS> (not created)"""
    when = when or datetime.datetime.now()
    return Path(results_dir if results_dir is not None else DEFAULT_RESULTS) / f"{kind}_{when:%Y%m%d_%H%M%S}"


def create_experiment_folder(kind, results_dir=None):
    """Creates the folder of a new experiment and returns it. Two experiments of a kind started in the same second
    get a _2, _3 ... suffix; an existing folder is never reused"""
    base = experiment_folder(kind, results_dir)
    for n in range(1, 1000):
        folder = base if n == 1 else base.with_name(f"{base.name}_{n}")
        try:
            folder.mkdir(parents=True)
            return folder
        except FileExistsError:
            continue
    raise BenchmarkError(f"cannot create a folder like {base}")


# ---------------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------------

def _git(repo, *args):
    try:
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None


def git_state(repo):
    head = _git(repo, "rev-parse", "HEAD")
    if head is None:
        return None
    diff = _git(repo, "diff", "HEAD", "--ignore-submodules=all") or ""
    return {
        "commit": head.strip(),
        "branch": (_git(repo, "rev-parse", "--abbrev-ref", "HEAD") or "").strip(),
        "dirty": bool(diff.strip()),
        "diff_sha256": hashlib.sha256(diff.encode()).hexdigest() if diff.strip() else None,
    }


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def file_info(path):
    path = Path(path)
    if not path.exists():
        return None
    return {"path": str(path.resolve()), "sha256": sha256(path),
            "mtime": datetime.datetime.fromtimestamp(path.stat().st_mtime).isoformat(timespec="seconds")}


def governors():
    result = {}
    for path in sorted(Path("/sys/devices/system/cpu").glob("cpu[0-9]*/cpufreq/scaling_governor")):
        try:
            result[path.parent.parent.name] = path.read_text().strip()
        except OSError:
            pass
    return result


def load_yaml_module():
    try:
        import yaml
    except ImportError:
        raise BenchmarkError("PyYAML is needed (source ~/plotting/bin/activate)") from None
    return yaml


def write_yaml(path, value):
    yaml = load_yaml_module()
    with open(path, "w") as f:
        yaml.safe_dump(value, f, sort_keys=False, default_flow_style=False, width=120)


# ---------------------------------------------------------------------------
# The device is shared
# ---------------------------------------------------------------------------

def device_users():
    """PIDs other than ours that have the FPGA's device node open; [] if none, None if it cannot be told"""
    try:
        out = subprocess.run(["fuser", str(DEVICE)], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return [pid for pid in (int(p) for p in re.findall(r"\d+", out.stdout)) if pid != os.getpid()]


def describe_pids(pids):
    try:
        out = subprocess.run(["ps", "-o", "pid=,user=,etime=,comm=", "-p", ",".join(map(str, pids))],
                             capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ", ".join(map(str, pids))
    return "; ".join(" ".join(line.split()) for line in out.splitlines()) or ", ".join(map(str, pids))


def free_hugepages():
    try:
        return int(HUGEPAGES_1G.read_text())
    except (OSError, ValueError):
        return None


def wait_for_device(wait_s, quiet=False):
    """Returns once nobody else has the device open and a 1 GiB hugepage is free; raises after `wait_s` seconds
    (0: do not wait). Both are checked, since a process that is still starting up holds the pages first"""
    deadline = time.monotonic() + wait_s
    announced = False
    while True:
        users = device_users()
        free = free_hugepages()
        busy = bool(users) or free == 0
        if not busy:
            return
        who = describe_pids(users) if users else "no process has it open"
        if time.monotonic() >= deadline:
            if free == 0 and not users:
                raise BenchmarkError(f"no free 1 GiB hugepages ({who}; lost on reboot?): {HUGEPAGES_CMD}")
            raise BenchmarkError(f"the FPGA is in use by another process ({who}); not starting. Use "
                                 "--wait-device SECONDS to wait for it")
        if not announced:  # Also when quiet: a sweep that waits for hours must not look hung
            why = "no free 1 GiB hugepage" if free == 0 and not users else f"in use: {who}"
            print(f"\nwaiting for the FPGA ({why}) for up to {wait_s:.0f} s ...", file=sys.stderr, flush=True)
            announced = True
        time.sleep(2.0)


# ---------------------------------------------------------------------------
# The script
# ---------------------------------------------------------------------------

def sql_string(text):
    return "'" + str(text).replace("'", "''") + "'"


def sql_setting_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    return sql_string(value)


def query_sql(build_path, probe_path, columns):
    """The measured query: a join of the two read_oasis scans and a checksum of everything that comes out of it.
    The build file is written first so that, when both have the same number of rows, it is the left side, which
    the extension takes as the build side"""
    select = ["count(*)::VARCHAR AS n_rows", "coalesce(sum(p.key), 0)::VARCHAR AS key_sum"]
    select += [f"coalesce(sum(p.c{i}), 0)::VARCHAR AS sum_c{i}" for i in range(1, columns + 1)]
    return (f"SELECT {', '.join(select)} FROM read_oasis({sql_string(build_path)}) b "
            f"JOIN read_oasis({sql_string(probe_path)}) p ON p.key = b.key;")


SETTING_NAMES = ["threads", "oasis_runtime_bloom_filter", "oasis_emulated_egress_gbps", "oasis_scheduler_num_streams",
                 "oasis_scheduler_queue_depth", "oasis_prefetch_depth", "oasis_enable_yield",
                 "oasis_duckdb_bloom_filter"]

# The bloom filter's counters are structs of integers, cast to strings (the CLI's JSON output cannot print structs)
BLOOM_SQL = ("SELECT run, build::VARCHAR AS build, probe::VARCHAR AS probe, run_perf::VARCHAR AS run_perf, "
             "command_queue_overflowed FROM duckdb_logs_parsed('OasisBloomFilterStats') ORDER BY run;")


def build_script(params, build_path, probe_path, warmup, iterations, extra_settings):
    lines = ["-- Generated by bench.py. -json output, one @@ marker per section, parsed by bench.py from stdout.log",
             ".bail on"]
    settings = {}
    if params["threads"] is not None:
        settings["threads"] = params["threads"]
    settings["oasis_runtime_bloom_filter"] = bool(params["runtime_bloom"])
    settings["oasis_emulated_egress_gbps"] = float(params["egress_gbps"])
    settings.update(extra_settings)
    lines += [f"SET {name} = {sql_setting_value(value)};" for name, value in settings.items()]
    # The extension's statistics are log records. 'memory' storage, truncated after every run
    lines += ["CALL enable_logging(level = 'info', storage = 'memory');",
              ".print @@SETTINGS",
              "SELECT " + ", ".join(f"current_setting('{n}') AS {n}" for n in SETTING_NAMES)
              + ", version() AS duckdb_version;"]
    query = query_sql(build_path, probe_path, params["columns"])
    for i in range(warmup + iterations):
        kind = "warmup" if i < warmup else "measured"
        lines += [
            f".print @@ITER {i} {kind}",
            # The profiler counts from the first beat after it was read: this read stops it, so the idle time
            # since the previous run is not part of this run's window
            "SELECT count(*) AS drained FROM oasis_stream_profile();",
            ".print @@RESULT",
            query,
            ".print @@PROFILE",
            "SELECT * FROM oasis_stream_profile();",
            ".print @@QS",
            "SELECT * FROM duckdb_logs_parsed('OasisQueryStats');",
            ".print @@DP",
            "SELECT * FROM duckdb_logs_parsed('OasisDecoderProfile') ORDER BY segment;",
            ".print @@BF",
            BLOOM_SQL,
            ".print @@ST",
            "SELECT * FROM duckdb_logs_parsed('OasisScanTimings');",
            "CALL truncate_duckdb_logs();",
        ]
    lines.append(".print @@END")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Parsing stdout.log
# ---------------------------------------------------------------------------

_DECODER = json.JSONDecoder()


def json_arrays(text):
    """The JSON arrays of objects (the results of the statements) in the text, in order. Warnings of the CLI
    around them (ANSI escapes, free text) are skipped"""
    pos = 0
    while True:
        start = text.find("[", pos)
        if start < 0:
            return
        try:
            value, end = _DECODER.raw_decode(text, start)
        except ValueError:
            pos = start + 1
            continue
        if isinstance(value, list) and all(isinstance(v, dict) for v in value):
            yield value
            pos = end
        else:
            pos = start + 1


def number(value):
    """The CLI prints UBIGINT and HUGEINT as strings"""
    if value is None or isinstance(value, (int, float)):
        return value
    try:
        return int(value)
    except ValueError:
        return float(value)


def struct_numbers(text):
    """{'cycles': 1, 'idle_cycles': 2} -> {"cycles": 1, "idle_cycles": 2} (a struct of integers, as printed)"""
    return {k: int(v) for k, v in re.findall(r"'(\w+)':\s*(-?\d+)", text or "")}


def parse_output(text):
    """Turns the CLI's output into {"settings": {...}, "runs": [{"index", "kind", "result", "profile", "qs", "bloom",
    "scans", "decoder_segments"}, ...], "complete": bool}. Raises BenchmarkError for output that is not what build_script() produces"""
    out = {"settings": {}, "runs": [], "complete": False}
    section = None
    run = None
    buffers = []

    def flush():
        nonlocal buffers
        if section is None:
            buffers = []
            return
        arrays = [a for a in json_arrays("".join(buffers)) if a]
        buffers = []
        if section == "SETTINGS":
            if arrays:
                out["settings"] = arrays[0][0]
        elif run is None:
            return
        elif section == "RESULT":
            if arrays:
                run["result_raw"] = arrays[0][0]
        elif section == "PROFILE":
            run["profile"] = arrays[0] if arrays else []
        elif section == "QS":
            run["qs"] = arrays[0][0] if arrays else None
        elif section == "DP":
            run["decoder_segments"] = arrays[0] if arrays else []
        elif section == "BF":
            run["bloom"] = arrays[0] if arrays else []
        elif section == "ST":
            run["scans"] = arrays[0] if arrays else []

    for line in text.splitlines(keepends=True):
        if line.startswith("@@"):
            flush()
            tokens = line.split()
            section = tokens[0][2:]
            if section == "ITER":
                run = {"index": int(tokens[1]), "kind": tokens[2]}
                out["runs"].append(run)
            elif section == "END":
                out["complete"] = True
                section = None
        else:
            buffers.append(line)
    flush()
    return out


# ---------------------------------------------------------------------------
# From the raw statistics to the measures
# ---------------------------------------------------------------------------

def _rate_gbps(beats, cycles):
    """Bytes of `beats` 64 B beats per ns (== GB/s) over `cycles` device cycles; 0 over no time"""
    return beats * BEAT_BYTES / (cycles * CLOCK_NS) if cycles > 0 else 0.0


def decoder_measures(row):
    """The decoder's throughputs from the StreamProfiler counters (a row of oasis_stream_profile() or an
    OasisDecoderProfile record, the column names are the same) over the profiled window: from the first beat to
    the last handshake, including the idle cycles between its streams (flows), and excluding the idle cycles
    (the time the stream was running)"""
    c = {k: number(row[k]) for k in row if k.endswith("_cycles")}
    side = {}
    for name in ("in", "out"):
        h, starved, stalled, idle = (c[f"{name}_{k}_cycles"] for k in ("handshakes", "starved", "stalled", "idle"))
        busy = h + starved + stalled
        side[name] = {
            "handshakes": h, "starved_cycles": starved, "stalled_cycles": stalled, "idle_cycles": idle,
            "cycles": busy + idle, "bytes": h * BEAT_BYTES,
            "gbps": _rate_gbps(h, busy + idle),
            "gbps_excl_idle": _rate_gbps(h, busy),
        }
    return {"in_gbps": side["in"]["gbps"], "out_gbps": side["out"]["gbps"],
            "in_gbps_excl_idle": side["in"]["gbps_excl_idle"], "out_gbps_excl_idle": side["out"]["gbps_excl_idle"],
            "in": side["in"], "out": side["out"]}


def sum_profile_rows(rows):
    """The counters of several consecutive segments added up"""
    keys = [f"{side}_{k}_cycles" for side in ("in", "out") for k in ("handshakes", "starved", "stalled", "idle")]
    return {k: sum(number(r[k]) for r in rows) for k in keys}


def bloom_measures(record):
    """The Bloom filter's throughputs from its counters (OasisBloomFilterStats): the probe's input (probe keys and
    the columns to materialize) and the output (kept keys, materialized columns, mask) over the probe window:
    from the first probe key beat to the later of the probe phase's END and the last output (output can still
    drain after the END). Unlike celeris's io.probe the window does not start at the end of the build: with the
    extension, DuckDB builds its own hash table between the Bloom filter's build and the first probe key (tens of
    ms), which `*_from_build_end` still includes. Also the build's input over the build phase, and the whole
    run's rates (first build beat to the last handshake)"""
    build, probe, run = (struct_numbers(record[k]) for k in ("build", "probe", "run_perf"))
    build_key_beats = max(build["beats"] - 1, 0)  # The phase's beats include its END beat
    total_in_beats = run["keys_in_beats"] + run["values_in_beats"]
    probe_in_beats = max(total_in_beats - build_key_beats, 0)
    out_bytes = run["out_bytes"]
    from_build_end = max(probe["cycles"], run["out_cycles"])  # celeris's io.probe window
    window = max(probe["cycles"], max(run["out_cycles"] - run["probe_start_cycles"], 0))
    return {
        "in_gbps": _rate_gbps(probe_in_beats, window),
        "out_gbps": out_bytes / (window * CLOCK_NS) if window > 0 else 0.0,
        "in_gbps_from_build_end": _rate_gbps(probe_in_beats, from_build_end),
        "out_gbps_from_build_end": out_bytes / (from_build_end * CLOCK_NS) if from_build_end > 0 else 0.0,
        "probe_start_gap_cycles": run["probe_start_cycles"],
        "build_in_gbps": _rate_gbps(build_key_beats, build["cycles"]),
        "run_in_gbps": _rate_gbps(total_in_beats, run["cycles"]),
        "run_out_gbps": out_bytes / (run["cycles"] * CLOCK_NS) if run["cycles"] > 0 else 0.0,
        "probe_in_bytes": probe_in_beats * BEAT_BYTES,
        "out_bytes": out_bytes,
        "probe_window_cycles": window,
        "probe_cycles": probe["cycles"], "build_cycles": build["cycles"], "run_cycles": run["cycles"],
        "probe_idle_cycles": probe["idle_cycles"], "build_idle_cycles": build["idle_cycles"],
        "command_queue_overflowed": bool(record.get("command_queue_overflowed")),
        "build": build, "probe": probe, "run": run,
    }


def host_measures(qs):
    """Total, scan and rest time of the host's wall clock. The scan time is that of the read_oasis scans (the one
    with the Bloom filter includes submitting its build side and ending it again); the rest is what is left
    of the query: planning, the join operators and everything after them"""
    total = float(qs["total_query_ms"])
    only = qs.get("scan_only_ms")
    bloom = qs.get("scan_celeris_bloom_ms")
    scan = (float(only) if only is not None else 0.0) + (float(bloom) if bloom is not None else 0.0)
    return {"query_ms": total, "scan_ms": scan, "rest_ms": total - scan,
            "scan_only_ms": None if only is None else float(only),
            "scan_bloom_ms": None if bloom is None else float(bloom),
            # DuckDB's own timing of its join operators, CPU time summed over its threads: not the rest above
            "join_operator_cpu_ms": None if qs.get("join_ms") is None else float(qs["join_ms"])}


def expected_decoder_out_bytes(params):
    """What the decoder has to output in a run: the keys of S (twice with the Bloom filter: once for its build
    side, once for DuckDB's own build of the hash table), the keys and columns of R"""
    s_passes = 2 if params["runtime_bloom"] else 1
    return (s_passes * params["ssize"] + params["rsize"] * (1 + params["columns"])) * 8


def check_run(run, params, dataset, probe_path):
    """Verifies the result of one run and turns its raw statistics into the measures. Raises BenchmarkError"""
    where = f"run {run['index']}"
    raw = run.get("result_raw")
    if raw is None:
        raise BenchmarkError(f"{where}: the query returned no result")
    result = {k: int(v) for k, v in raw.items()}
    wrong = []
    if result["n_rows"] != dataset.expected_rows:
        wrong.append(f"rows {result['n_rows']} != {dataset.expected_rows}")
    if result["key_sum"] != dataset.expected_key_sum:
        wrong.append(f"sum(key) {result['key_sum']} != {dataset.expected_key_sum}")
    for i in range(1, params["columns"] + 1):
        if result[f"sum_c{i}"] != dataset.expected_sums[i - 1]:
            wrong.append(f"sum(c{i}) {result[f'sum_c{i}']} != {dataset.expected_sums[i - 1]}")
    if wrong:
        raise BenchmarkError(f"{where}: wrong result: " + "; ".join(wrong))

    qs = run.get("qs")
    if qs is None:
        raise BenchmarkError(f"{where}: no OasisQueryStats record (did the scans run on the read_oasis function?)")
    host = host_measures(qs)
    segments = run.get("decoder_segments") or []
    whole_run_row = next((r for r in run.get("profile") or [] if number(r.get("stream")) == 0), None)
    if not segments:
        # An extension without the OasisDecoderProfile record (an old stdout.log): only the whole run, read by
        # the script after the query
        if whole_run_row is None:
            raise BenchmarkError(f"{where}: oasis_stream_profile() has no row for stream 0")
        decoder = dict(decoder_measures(whole_run_row), scope="run")
        decoder_run = decoder
    else:
        final = [s for s in segments if s.get("label") == "final"]
        if len(final) != 1 or segments[-1] is not final[0]:
            raise BenchmarkError(f"{where}: expected one final decoder segment, last of {len(segments)}")
        if Path(final[0]["file"]).name != Path(probe_path).name:
            raise BenchmarkError(
                f"{where}: the decoder's last segment belongs to the scan of {final[0]['file']}, not the probe "
                f"file {probe_path}: the probe scan did not start last")
        decoder = dict(decoder_measures(final[0]), scope="probe", segments=len(segments))
        decoder_run = dict(decoder_measures(sum_profile_rows(segments)), scope="run (segments summed)")

    bloom = None
    scans = run.get("scans") or []
    if params["runtime_bloom"]:
        records = run.get("bloom") or []
        if len(records) != 1 or host["scan_bloom_ms"] is None:
            raise BenchmarkError(
                f"{where}: the hardware Bloom filter did not run once ({len(records)} OasisBloomFilterStats "
                f"record(s)): the join was not rewritten, or the probe side cannot use the filter. Run the query "
                "with CALL enable_logging(level='debug') for the reason (e.g. 'join skipped')")
        bloom_scans = [s for s in scans if s.get("bloom")]
        if len(bloom_scans) != 1 or Path(bloom_scans[0]["file"]).name != Path(probe_path).name:
            raise BenchmarkError(
                f"{where}: the Bloom filter filtered {[s['file'] for s in bloom_scans]}, not the probe file "
                f"{probe_path}: the extension took the file with the payload columns as the build side (it takes the "
                "relation with fewer estimated rows; make R larger than S)")
        bloom = bloom_measures(records[0])
        if bloom["command_queue_overflowed"]:
            raise BenchmarkError(f"{where}: the Bloom filter's command queue overflowed (sticky until a device "
                                 "reset): the counters of this and all later runs are not reliable")
    elif run.get("bloom"):
        raise BenchmarkError(f"{where}: the Bloom filter ran although it was switched off")

    expected = expected_decoder_out_bytes(params)
    probe_expected = params["rsize"] * (1 + params["columns"]) * 8
    # The probe-only segment has to hold exactly the probe's columns: more means build-side flows were still in it,
    # less that the boundary was read late. Either way its throughput would not be the probe's
    if decoder.get("scope") == "probe":
        ratio = decoder["out"]["bytes"] / probe_expected
        if not 0.99 <= ratio <= 1.01:
            raise BenchmarkError(
                f"{where}: the decoder's probe segment output {decoder['out']['bytes']} B, expected about "
                f"{probe_expected} B (ratio {ratio:.3f}): it does not cover exactly the probe scan")
    return {
        "index": run["index"],
        "host": host,
        "decoder": decoder,
        "decoder_run": decoder_run,
        "bloom": bloom,
        "result": result,
        "checks": {"decoder_out_bytes_expected": expected,
                   "decoder_out_bytes_ratio": decoder_run["out"]["bytes"] / expected if expected else None,
                   "decoder_probe_out_bytes_expected": probe_expected,
                   "decoder_probe_out_bytes_ratio": decoder["out"]["bytes"] / probe_expected,
                   },
        "decoder_segments": segments,
        "scans": scans,
    }


# ---------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------

def complete_params(params):
    unknown = set(params) - set(PARAM_NAMES)
    if unknown:
        raise BenchmarkError(f"unknown parameter(s) {sorted(unknown)}; known: {PARAM_NAMES}")
    full = {name: default for name, _s, _t, default, _h in PARAMS}
    full.update({k: v for k, v in params.items() if v is not None})
    if full["file_columns"] is None:
        full["file_columns"] = full["columns"]
    if full["numbatches"] is not None and params.get("batchsize") is not None:
        raise BenchmarkError("batchsize and numbatches are mutually exclusive")
    if full["numbatches"] is not None:
        full["batchsize"] = None
    if full["ssize"] < 1 or full["rsize"] < 1:
        raise BenchmarkError("ssize and rsize have to be at least 1")
    if not 0.0 <= full["matchratio"] <= 1.0:
        raise BenchmarkError(f"matchratio has to be in [0, 1], not {full['matchratio']}")
    if full["zipffactor"] < 0 or full["egress_gbps"] < 0:
        raise BenchmarkError("zipffactor and egress_gbps cannot be negative")
    if full["columns"] < 0 or full["file_columns"] < full["columns"]:
        raise BenchmarkError("need 0 <= columns <= file_columns")
    if full["rsize"] <= full["ssize"]:
        raise BenchmarkError(
            f"rsize ({full['rsize']}) is not above ssize ({full['ssize']}): the extension takes the relation with "
            "fewer rows as the build side (and, on a tie, the file that is written first), so R would not be "
            "filtered. R, the probe relation, has to be strictly larger")
    return full


def import_gen_data():
    try:
        import gen_data
    except ImportError as e:
        raise BenchmarkError(f"cannot import gen_data.py ({e}); it needs numpy and duckdb: "
                             "source ~/plotting/bin/activate") from None
    return gen_data


def make_dataset(params, data_dir, log=print):
    gen_data = import_gen_data()
    data_params = gen_data.DataParams(
        ssize=params["ssize"], rsize=params["rsize"], matchratio=params["matchratio"], zipffactor=params["zipffactor"],
        columns=params["columns"], file_columns=params["file_columns"], batchsize=params["batchsize"],
        numbatches=params["numbatches"], compression=params["compression"], encoding=params["encoding"])
    return gen_data.ensure_dataset(Path(data_dir), data_params, log=log)


def _stop(proc, grace=20.0):
    """SIGINT (the CLI interrupts the query), then SIGTERM, then SIGKILL"""
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
        try:
            proc.send_signal(sig)
        except ProcessLookupError:
            return
        try:
            proc.wait(timeout=grace)
            return
        except subprocess.TimeoutExpired:
            continue


def run_cli(cmd, script_path, run_dir, env, timeout, quiet):
    """Runs the CLI on the script under a time limit. Returns (returncode, timed_out)"""
    with open(script_path) as script, open(run_dir / "stdout.log", "w") as log, \
            open(run_dir / "stderr.log", "w") as err:
        proc = subprocess.Popen(cmd, cwd=run_dir, stdin=script, stdout=subprocess.PIPE, stderr=err, text=True,
                                env=env)

        def pump():
            for line in proc.stdout:
                log.write(line)
                log.flush()
                if not quiet and line.startswith("@@ITER"):
                    print(line.strip(), file=sys.stderr, flush=True)

        reader = threading.Thread(target=pump, daemon=True)
        reader.start()
        timed_out = False
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            _stop(proc)
        except (KeyboardInterrupt, SystemExit):
            # Ctrl-C reached the CLI as well (same process group). Do not kill it: wait for it to exit
            print("\ninterrupted: waiting for the CLI to exit (killing a hung run wedges the device)",
                  file=sys.stderr)
            proc.wait()
            raise
        reader.join(timeout=30)
        return proc.returncode, timed_out


def stats(values):
    values = sorted(values)
    mean = statistics.fmean(values)
    stdev = statistics.stdev(values) if len(values) > 1 else 0.0
    return {"n": len(values), "min": values[0], "median": statistics.median(values), "mean": mean,
            "max": values[-1], "stdev": stdev, "cv_percent": 100 * stdev / mean if mean else 0.0}


SUMMARY = [
    ("total query time [ms]", ("host", "query_ms")),
    ("total scan time [ms]", ("host", "scan_ms")),
    ("rest of the query = total - scan [ms]", ("host", "rest_ms")),
    ("decoder IN [GB/s]", ("decoder", "in_gbps")),
    ("decoder OUT [GB/s]", ("decoder", "out_gbps")),
    ("Bloom filter IN [GB/s]", ("bloom", "in_gbps")),
    ("Bloom filter OUT [GB/s]", ("bloom", "out_gbps")),
]


def lookup(run, path):
    for key in path:
        run = run[key]
    return run


def print_summary(runs, file=sys.stdout):
    print(f"\nSummary of {len(runs)} measured run(s):", file=file)
    print(f"  {'':34s}{'min':>12s}{'median':>12s}{'max':>12s}{'cv %':>8s}", file=file)
    for label, path in SUMMARY:
        try:
            values = [lookup(r, path) for r in runs]
        except (KeyError, TypeError):
            continue
        s = stats(values)
        print(f"  {label:34s}{s['min']:12.4g}{s['median']:12.4g}{s['max']:12.4g}{s['cv_percent']:8.2f}", file=file)


def run_benchmark(folder, params=None, *, warmup=BENCH_DEFAULTS["warmup"], iterations=BENCH_DEFAULTS["iterations"],
                  binary=DEFAULT_BINARY, data_dir=None, tmp_dir=None, lib_dir=DEFAULT_LIB_DIR,
                  timeout=BENCH_DEFAULTS["timeout"], wait_device=BENCH_DEFAULTS["wait_device"],
                  extra_settings=None, dataset=None, quiet=False, guard_device=True):
    """Runs one point of the benchmark and returns the directory with its results.

    folder: the path of the folder the results go to, used as given (created if needed). It must not hold the
            results of an earlier benchmark (bench.yaml, meta.yaml, stdout.log): nothing is overwritten
    params: the parameters by their long option name (see PARAMS); the others get the defaults
    timeout: seconds the CLI may take in all (warm-up and measured runs). Longer: it is stopped (SIGINT, SIGTERM,
             SIGKILL), the run fails, and the device has to be checked
    wait_device: seconds to wait for another process to let go of the FPGA (0: fail at once if it is in use)
    extra_settings: more DuckDB settings to SET, {name: value}
    data_dir: where the Parquet files are generated (and reused, if a file of the same parameters is there). By
              default (None) a new temporary directory is created below `tmp_dir` (the system's temporary
              directory if that is None) and removed when the run ends, also after a failure
    dataset: the gen_data.Dataset to use, to skip generating it
    quiet: print nothing (stdout.log still has everything)
    guard_device: take the lock and wait for / refuse a busy FPGA (what a real run needs). Only for tests with a
                  fake CLI, which never touches the device: False, or the environment variable
                  OASIS_BENCH_NO_DEVICE_GUARD=1
    Raises BenchmarkError if anything is wrong or the run fails.
    """
    if dataset is None and data_dir is None:
        complete_params(params or {})  # Fail on bad parameters before generating anything
        with tempfile.TemporaryDirectory(prefix=TMP_PREFIX, dir=tmp_dir) as tmp:
            return run_benchmark(folder, params, warmup=warmup, iterations=iterations, binary=binary,
                                 data_dir=tmp, tmp_dir=tmp_dir, lib_dir=lib_dir, timeout=timeout,
                                 wait_device=wait_device, extra_settings=extra_settings, dataset=None, quiet=quiet,
                                 guard_device=guard_device)

    params = complete_params(params or {})
    extra_settings = dict(extra_settings or {})
    binary = Path(binary).resolve()
    folder = Path(folder).resolve()
    if not binary.exists():
        raise BenchmarkError(f"{binary} does not exist: build it (make -C {EXTENSION_DIR})")
    existing = [f.name for f in (folder / "bench.yaml", folder / "meta.yaml", folder / "stdout.log") if f.exists()]
    if existing:
        raise BenchmarkError(f"{folder} already holds results ({', '.join(existing)}): use another folder or "
                             "remove it")
    if iterations < 1 or warmup < 0:
        raise BenchmarkError("need iterations >= 1 and warmup >= 0")

    log = (lambda *a, **k: None) if quiet else (lambda *a, **k: print(*a, file=sys.stderr, **k))
    if dataset is None:
        dataset = make_dataset(params, data_dir, log=log)  # Before waiting for the device: it does not need it
    govs = governors()
    if not quiet and any(g != "performance" for g in govs.values()):
        print(f"warning: CPU governor is {sorted(set(govs.values()))}, not 'performance'", file=sys.stderr)

    folder.mkdir(parents=True, exist_ok=True)
    script = build_script(params, dataset.build_path, dataset.probe_path, warmup, iterations, extra_settings)
    script_path = folder / "run.sql"
    script_path.write_text(script)

    env = os.environ.copy()
    env["LD_LIBRARY_PATH"] = os.pathsep.join(filter(None, [str(lib_dir), env.get("LD_LIBRARY_PATH")]))
    cmd = [str(binary), "-json", "-bail", "-no-init"]

    meta = {
        "folder": str(folder),
        "started": None, "finished": None, "returncode": None, "timed_out": False,
        "command": cmd + ["<", str(script_path)],
        "parameters": params,
        "extra_settings": extra_settings,
        "warmup": warmup, "iterations": iterations, "timeout_s": timeout,
        "dataset": {"build": dataset.build_meta, "probe": dataset.probe_meta},
        "governors": governors(),
        "host": {"hostname": platform.node(), "kernel": platform.release(), "python": platform.python_version()},
        "binary": file_info(binary),
        "libraries": {name: file_info(Path(lib_dir) / name) for name in
                      ("liboasis.so", "libparcore.so", "liblibstf.so", "libcoyote.so")},
        "git": {name: git_state(path) for name, path in [
            ("oasis", OASIS_DIR), ("parcore", OASIS_DIR / "parcore"), ("celeris", OASIS_DIR / "celeris"),
            ("duckdb", EXTENSION_DIR / "duckdb")]},
    }
    meta_path = folder / "meta.yaml"

    if not quiet:
        print(f"results: {folder}", file=sys.stderr)

    # Our own scripts take turns; other users of the device are waited for / refused
    guard = guard_device and not os.environ.get("OASIS_BENCH_NO_DEVICE_GUARD")
    with open(LOCK_FILE if guard else os.devnull, "w") as lock:
        if guard:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise BenchmarkError(f"another benchmark of this kind is running ({LOCK_FILE} is locked)") from None
            wait_for_device(wait_device, quiet)
        meta["started"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
        write_yaml(meta_path, meta)
        returncode, timed_out = run_cli(cmd, script_path, folder, env, timeout, quiet)

    meta["finished"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
    meta["returncode"] = returncode
    meta["timed_out"] = timed_out
    write_yaml(meta_path, meta)

    if timed_out:
        raise BenchmarkError(
            f"the CLI did not finish within {timeout:.0f} s and was stopped; see {folder / 'stdout.log'}. Stop here: "
            "check the device (cat /sys/kernel/coyote_sysfs_0/cyt_attr_hstats: request and completion counts have "
            "to match; free 1 GiB hugepages) and reset it if runs hang, before starting another run")
    if returncode != 0:
        raise BenchmarkError(f"the CLI failed with exit code {returncode}; see {folder / 'stdout.log'} and "
                             f"{folder / 'stderr.log'}. Stop here: check the device before starting another run")

    return finish(folder, params, dataset, meta, quiet)


def finish(folder, params, dataset, meta, quiet=False):
    """Parses stdout.log into bench.yaml (also usable on its own to parse an old folder again)"""
    text = (folder / "stdout.log").read_text()
    parsed = parse_output(text)
    status = "ok"
    error = None
    runs = []
    try:
        if not parsed["complete"]:
            raise BenchmarkError("the output ends before the last run: the script did not finish")
        for run in parsed["runs"]:
            runs.append(dict(check_run(run, params, dataset, dataset.probe_path), kind=run["kind"]))
    except BenchmarkError as e:
        status, error = "failed", str(e)

    warmups = [r for r in runs if r["kind"] == "warmup"]
    measured = [r for r in runs if r["kind"] == "measured"]
    if status == "ok" and len(measured) != meta["iterations"]:
        status, error = "failed", f"{len(measured)} measured runs in the output, expected {meta['iterations']}"
    bench = {
        "benchmark": {"status": status, "error": error, "warmup": meta["warmup"], "iterations": meta["iterations"]},
        "parameters": {
            "s_size": params["ssize"], "r_size": params["rsize"], "match_ratio": params["matchratio"],
            "zipf_factor": params["zipffactor"], "materialized_columns": params["columns"],
            "file_columns": params["file_columns"], "batch_size": params["batchsize"],
            "num_batches": params["numbatches"], "build_batches": len(dataset.build_row_groups),
            "probe_batches": len(dataset.probe_row_groups), "compression": params["compression"],
            "encoding": params["encoding"], "runtime_bloom": params["runtime_bloom"],
            "emulated_egress_gbps": params["egress_gbps"], "threads": params["threads"],
        },
        "settings": parsed["settings"],
        "expected": {"rows": dataset.expected_rows, "key_sum": dataset.expected_key_sum,
                     "sums": dataset.expected_sums},
        "warmups": warmups,
        "iterations": measured,
    }
    write_yaml(folder / "bench.yaml", bench)
    if status != "ok":
        raise BenchmarkError(f"{error}; see {folder / 'stdout.log'}. Stop here: check the device before starting "
                             "another run")
    if not quiet:
        print_summary(measured)
        print(f"\nresults: {folder}")
    return folder


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

def main(argv=None):
    # SIGTERM unwinds like Ctrl-C, so the temporary data is removed (the CLI is waited for, see run_cli)
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     epilog="See the top of this file and README.md.", add_help=False)
    parser.add_argument("--help", action="help", help="show this help message and exit")
    group = parser.add_argument_group("parameters of the experiment (the names of the celeris binary's options)")
    for name, short, typ, default, help_text in PARAMS:
        flags = [f"--{name}"] + ([f"--{name.replace('_', '-')}"] if "_" in name else []) \
            + ([f"-{short}"] if short else [])
        group.add_argument(*flags, type=typ, default=None, metavar=name.upper(),
                           help=f"{help_text} (default: {default})")
    group.add_argument("--set", action="append", default=[], metavar="NAME=VALUE",
                       help="another DuckDB setting to SET (e.g. oasis_prefetch_depth=4); repeatable")
    group = parser.add_argument_group("benchmark")
    group.add_argument("--warmup", "-w", type=int, default=BENCH_DEFAULTS["warmup"],
                       help="runs not stored (default: %(default)s)")
    group.add_argument("--iterations", "-i", type=int, default=BENCH_DEFAULTS["iterations"],
                       help="runs stored (default: %(default)s)")
    group.add_argument("--experiment", default="bench", metavar="TYPE",
                       help="the experiment's type: its folder is <results-dir>/<TYPE>_<date>_<time> (default: "
                            "%(default)s)")
    group.add_argument("--results-dir", type=Path, default=DEFAULT_RESULTS,
                       help="where the experiment's folder is created (default: %(default)s)")
    group.add_argument("--timeout", type=float, default=BENCH_DEFAULTS["timeout"],
                       help="seconds the CLI may take in all, then it is stopped (default: %(default)s)")
    group.add_argument("--wait-device", type=float, default=BENCH_DEFAULTS["wait_device"], metavar="SECONDS",
                       help="wait this long for another process to let go of the FPGA (default: do not wait)")
    group.add_argument("--binary", type=Path, default=DEFAULT_BINARY, help="the DuckDB CLI with the extension "
                                                                          "(default: %(default)s)")
    group.add_argument("--tmp-dir", type=Path, default=None,
                       help="where the temporary directory with the generated Parquet files is created, and removed "
                            "at the end of the run (default: the system's temporary directory; needs room for the "
                            "probe file, 8 B x rows x (1 + columns))")
    group.add_argument("--lib-dir", type=Path, default=DEFAULT_LIB_DIR,
                       help="added to LD_LIBRARY_PATH (default: %(default)s)")
    args = parser.parse_args(argv)

    extra = {}
    for item in args.set:
        name, sep, value = item.partition("=")
        if not sep:
            parser.error(f"--set needs NAME=VALUE, not {item!r}")
        extra[name.strip()] = {"true": True, "false": False}.get(value.lower(), value)
        try:
            extra[name.strip()] = int(value)
        except ValueError:
            try:
                extra[name.strip()] = float(value)
            except ValueError:
                pass

    params = {name: getattr(args, name) for name in PARAM_NAMES}
    try:
        complete_params(params)  # Before creating the experiment's folder
        folder = create_experiment_folder(args.experiment, args.results_dir)
        (folder / "plots").mkdir()
        print(f"experiment: {folder}", file=sys.stderr)
        run_benchmark(folder / "results", params, warmup=args.warmup, iterations=args.iterations,
                      binary=args.binary, tmp_dir=args.tmp_dir, lib_dir=args.lib_dir, timeout=args.timeout,
                      wait_device=args.wait_device, extra_settings=extra)
    except BenchmarkError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

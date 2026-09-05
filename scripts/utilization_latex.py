#!/usr/bin/env python3
"""Print a LaTeX table of FPGA resource utilization for an oasis build.

Parses a hierarchical Vivado utilization report (report_utilization -hierarchical)
and prints total user-logic utilization plus a breakdown by the major components
of the column chunk decoders.

Usage: utilization_latex.py <build_dir | utilization_report.txt>
"""
import re
import sys
from pathlib import Path

# xcu55c-fsvh2892-2L-e device totals (for utilization percentages)
DEVICE = {"luts": 1_303_680, "ffs": 2_607_360, "bram36": 2_016, "uram": 960, "dsp": 9_024}

# Instance leaf names of the major components inside each ColumnChunkDecoder
COMPONENTS = [
    ("Page header parser", "inst_page_header_parser"),
    ("Snappy decompressor", "inst_decompressor"),
    ("Run decoder", "inst_run_decoder"),
    ("Typed dictionary", "inst_typed_dictionary"),
    ("Stream normalizer", "inst_normalize_until_out"),
]

METRICS = ["luts", "ffs", "bram36", "uram", "dsp"]
HEADERS = {"luts": "LUTs", "ffs": "Registers", "bram36": "BRAM", "uram": "URAM", "dsp": "DSPs"}


def parse_report(path):
    """Return a list of (depth, instance_name, resources) nodes in report order."""
    nodes = []
    for line in path.read_text().splitlines():
        fields = line.split("|")
        # Hierarchy rows: | <indented instance> | <module> | <PR attr> | PPLOCs |
        # Total LUTs | Logic LUTs | LUTRAMs | SRLs | FFs | RAMB36 | RAMB18 | URAM | DSP |
        if len(fields) != 15 or not fields[1].startswith(" "):
            continue
        instance = fields[1].strip()
        if not instance or instance.startswith("(") or instance == "Instance":
            continue

        def num(i):
            v = fields[i].strip()
            return float(v) if v not in ("-", "") else 0.0

        depth = len(fields[1]) - len(fields[1].lstrip())
        nodes.append((depth, instance, {
            "luts": num(5), "ffs": num(9),
            "bram36": num(10) + num(11) / 2,  # RAMB18 counts as half a RAMB36
            "uram": num(12), "dsp": num(13),
        }))
    return nodes


def subtree(nodes, i):
    """Yield nodes strictly below nodes[i] in the hierarchy."""
    depth = nodes[i][0]
    for j in range(i + 1, len(nodes)):
        if nodes[j][0] <= depth:
            break
        yield nodes[j]


def add(acc, res):
    for m in METRICS:
        acc[m] += res[m]


def fmt_count(v):
    """720400 -> 720.4K, 62080 -> 62.08K, 6346 -> 6346 (4 significant digits)."""
    if v >= 10_000:
        k = v / 1000
        return f"{k:.0f}K" if k >= 1000 else f"{k:.1f}K" if k >= 100 else f"{k:.2f}K"
    return str(int(v + 0.5))


def fmt_row(label, res, metrics, indent=False):
    cells = []
    for m in metrics:
        pct = res[m] / DEVICE[m] * 100
        cells.append(f"{fmt_count(res[m])} ({pct:.1f}\\%)" if pct >= 9.995
                     else f"{fmt_count(res[m])} ({pct:.2f}\\%)")
    prefix = "\\quad " if indent else ""
    return f" {prefix}{label} & " + " & ".join(cells) + " \\\\"


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.strip())
    path = Path(sys.argv[1])
    if path.is_dir():
        path = path / "utilization_report.txt"
    if not path.is_file():
        sys.exit(f"error: {path} not found")

    nodes = parse_report(path)

    chip = dict.fromkeys(METRICS, 0.0)
    total = dict.fromkeys(METRICS, 0.0)
    decoders = dict.fromkeys(METRICS, 0.0)
    comps = {label: dict.fromkeys(METRICS, 0.0) for label, _ in COMPONENTS}
    n_decoders = 0

    for i, (_, instance, res) in enumerate(nodes):
        if instance == "cyt_top":
            add(chip, res)
        elif instance == "inst_user_c0_0":
            add(total, res)
        elif re.fullmatch(r"gen_decoders\[\d+\]\.inst_column_chunk_decoder", instance):
            n_decoders += 1
            add(decoders, res)
            for _, sub_instance, sub_res in subtree(nodes, i):
                for label, leaf in COMPONENTS:
                    if sub_instance == leaf:
                        add(comps[label], sub_res)

    if not n_decoders or not any(total.values()) or not any(chip.values()):
        sys.exit("error: expected hierarchy (inst_user_c0_0 / column chunk decoders) not found")

    other_dec = {m: decoders[m] - sum(c[m] for c in comps.values()) for m in METRICS}
    other_top = {m: total[m] - decoders[m] for m in METRICS}
    coyote = {m: chip[m] - total[m] for m in METRICS}

    # Report the decoder and its components per instance
    for res in (decoders, other_dec, *comps.values()):
        for m in METRICS:
            res[m] /= n_decoders

    # Drop URAM/DSP columns if the design does not use them
    metrics = [m for m in METRICS if m in ("luts", "ffs", "bram36") or chip[m] > 0]

    print(f"% Generated from {path} (percentages relative to xcu55c device totals)")
    print("\\begin{table}[t]")
    print("\\caption{Resource utilization on one Alveo U55C FPGA.}")
    print("\\label{tab:resource_utilization}")
    print("\\centering")
    print("\\footnotesize")
    print("\\setlength{\\tabcolsep}{3pt}")
    print("\\begin{tabular}{l" + " r" * len(metrics) + "}")
    print(" Component & " + " & ".join(HEADERS[m] for m in metrics) + " \\\\")
    print(" \\hline")
    print(" \\hline")
    print(fmt_row(f"Column chunk decoders ({n_decoders}x)", decoders, metrics))
    for label, _ in COMPONENTS:
        print(fmt_row(label, comps[label], metrics, indent=True))
    print(fmt_row("Other", other_dec, metrics, indent=True))
    print(fmt_row("Other (I/O, infrastructure)", other_top, metrics))
    print(fmt_row("Coyote shell", coyote, metrics))
    print(" \\hline")
    print(fmt_row("Overall", chip, metrics))
    print("\\end{tabular}")
    print("\\end{table}")


if __name__ == "__main__":
    main()

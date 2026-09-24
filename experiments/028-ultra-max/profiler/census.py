"""Per-kernel census of a census.sh run: attributed us/step per kernel, arm against the first arm, with error bars.

usage: python census.py <census out dir> [top N kernels, default 12]
Run it after the lease is released. Records without a .sum are summarized first (summarize.py next to this file) and
gzipped. Tags are <arm>-<test>-<precision>-r<repeat>, so arm names hold no hyphens. The first arm in loads.txt is
the reference. Kernels are keyed by name, summing grid variants, so a changed grid (720x64 to 1440x64) stays one row.
Each value is the mean over repeats, +- the sample standard deviation. A delta is marked * when it is more than
3 standard errors, sqrt(sd_ref^2/n_ref + sd_arm^2/n_arm): about Welch's 95% point at 3 repeats per arm. "Wall" is the mean of prof.py's unrecorded
windows A and C. "union" (GPU time covered by any kernel) and the kernels come from the recorded window B
(counters mode); command buffer busy time is left out, since counter sampling inflates it (1.9x on gbsa).
"""
import collections
import glob
import gzip
import json
import math
import os
import statistics
import subprocess
import sys

out = sys.argv[1]
top = int(sys.argv[2]) if len(sys.argv) > 2 else 12
here = os.path.dirname(os.path.abspath(__file__))

for rec in sorted(glob.glob(f"{out}/*.rec")):
    tag = rec[:-4]
    with open(f"{tag}.sum", "w") as sum_file:
        subprocess.run([sys.executable, f"{here}/summarize.py", f"{tag}.txt", rec, "8"], stdout=sum_file, stderr=subprocess.STDOUT)
    subprocess.run(["gzip", "-f", rec])

arms = []
for line in open(f"{out}/loads.txt"):
    arm = line.split("-")[0]
    if not line.startswith(("failed", "skipped")) and arm not in arms:
        arms.append(arm)

runs = collections.defaultdict(list)
grids = collections.defaultdict(set)
for path in sorted(glob.glob(f"{out}/*.sum")):
    tag = os.path.basename(path)[:-4]
    parts = tag.split("-")
    arm, test = parts[0], "-".join(parts[1:-2])
    lines = [l for l in open(path) if l.startswith("json ")]
    if not lines:
        print(f"no summary in {path}")
        continue
    summary = json.loads(lines[0][5:])
    values = {"wall": statistics.mean(summary["unprofiled_us"]), "union": summary["kernel_union_us"]}
    for key, kernel in summary.get("kernels", {}).items():
        name, grid = key.rsplit(" ", 1)
        values[name] = values.get(name, 0.0) + kernel["attr"]
        grids[(test, arm, name)].add(grid)
    runs[(test, arm)].append(values)

def stats(samples):
    mean = statistics.mean(samples)
    sd = statistics.stdev(samples) if len(samples) > 1 else float("nan")
    return mean, sd, len(samples)

def cell(samples):
    mean, sd, _ = stats(samples)
    return f"{mean:.1f} +- {sd:.1f}"

reference = arms[0]
for test in sorted({test for test, _ in runs}):
    ref_runs = runs.get((test, reference), [])
    if not ref_runs:
        continue
    names = sorted({k for r in ref_runs for k in r if k not in ("wall", "union")},
                   key=lambda k: -statistics.mean(r.get(k, 0.0) for r in ref_runs))
    others = [arm for arm in arms[1:] if runs.get((test, arm))]
    print(f"\n### {test}, {len(ref_runs)} repeats of {reference}, " + ", ".join(f"{len(runs[(test, a)])} of {a}" for a in others))
    print(f"\n| us/step | {reference} | " + " | ".join(f"{a} | delta | % of row | % of wall" for a in others) + " |")
    print("|---|---:|" + "---:|---:|---:|---:|" * len(others))
    ref_wall = statistics.mean(r["wall"] for r in ref_runs)
    rows = ["wall", "union"] + names[:top]
    for row in rows:
        ref = [r.get(row, 0.0) for r in ref_runs]
        label = row
        if row not in ("wall", "union"):
            label += " " + "/".join(sorted(grids[(test, reference, row)]))
        line = f"| {label} | {cell(ref)} |"
        for arm in others:
            samples = [r.get(row, 0.0) for r in runs[(test, arm)]]
            m0, s0, n0 = stats(ref)
            m1, s1, n1 = stats(samples)
            delta = m1 - m0
            error = math.sqrt((s0**2)/n0 + (s1**2)/n1) if n0 > 1 and n1 > 1 else float("nan")
            mark = "*" if error == error and abs(delta) > 3*error else ""
            arm_grids = grids.get((test, arm, row), set())
            if row not in ("wall", "union") and arm_grids != grids[(test, reference, row)]:
                mark += " " + "/".join(sorted(arm_grids))
            share = delta/m0 if m0 else float("nan")
            line += f" {cell(samples)} | {delta:+.1f}{mark} | {share:+.1%} | {delta/ref_wall:+.1%} |"
        print(line)

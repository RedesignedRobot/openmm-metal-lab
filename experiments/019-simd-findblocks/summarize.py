"""Tables for experiment 019 from the files run.py writes.

usage: python summarize.py <out-dir> [<fb-dir>]
Clock: benchmark.py's host wall clock over whole steps (json/*.json) and fahwu.py's host wall
clock over whole steps (fah-before.jsonl, fah-after.jsonl, in round order).  Every cell is
ns/day: median of the rounds, then min-max.  Speedup is the ratio of the medians.
With <fb-dir> (fb.sh's output) it also tabulates fbshare.py: GPU time of findBlocksWithInteractions
per step (command buffer timestamps) over host wall time per step, one run each.
"""
import glob
import json
import os
import re
import statistics
import sys
from collections import defaultdict

out = sys.argv[1]
speeds = defaultdict(list)
for path in sorted(glob.glob(f"{out}/json/*.json")):
    test, precision, label, _ = re.match(r"(.+)-(single|mixed)-(before|after)-r(\d)\.json", os.path.basename(path)).groups()
    speeds[(test, precision, label)].append(json.load(open(path))["benchmarks"][0]["ns_per_day"])
for label in ("before", "after"):
    path = f"{out}/fah-{label}.jsonl"
    if os.path.exists(path):
        for line in open(path):
            r = json.loads(line)
            speeds[(f"fah-{r['wu']}", r["precision"], label)].append(r["ns_per_day"])


def cell(values):
    return f"{statistics.median(values):8.2f} ({min(values):.2f}-{max(values):.2f}, n={len(values)})"


print("| Test | Precision | Before ns/day median (min-max, n) | After ns/day median (min-max, n) | After/before |")
print("| :--- | :--- | ---: | ---: | ---: |")
for test, precision in sorted({key[:2] for key in speeds}, key=lambda k: (k[0].startswith("fah"), k)):
    before, after = speeds.get((test, precision, "before")), speeds.get((test, precision, "after"))
    if before and after:
        print(f"| {test} | {precision} | {cell(before)} | {cell(after)} | {statistics.median(after)/statistics.median(before):.3f} |")

if len(sys.argv) > 2:
    fb = sys.argv[2]
    print()
    print("| Test | Precision | Install | ms/step (host wall) | findBlocks ms/step (GPU) | findBlocks share | Rebuild fraction | Rebuild ms | Skip ms |")
    print("| :--- | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |")
    for path in sorted(glob.glob(f"{fb}/*.json")):
        label = re.match(r".+-(before|after)\.json", os.path.basename(path)).group(1)
        r = json.load(open(path))
        print(f"| {r['test']} | {r['precision']} | {label} | {r['ms_per_step']:.3f} | {r['findblocks_ms_per_step']:.3f} | "
              f"{100*r['findblocks_share']:.1f}% | {r['rebuild_fraction']:.3f} | {r['rebuild_ms_median']:.3f} | {r['skip_ms_median']:.3f} |")

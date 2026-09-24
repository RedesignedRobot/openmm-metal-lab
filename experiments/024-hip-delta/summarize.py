"""Median ns/day per test and tree over the rounds that bench.sh or studio/bench.sh wrote.
The metal build is hipdelta-ref (mini) or ref (Studio). Every other tree gets a ratio against it.

usage: python summarize.py <bench output dir>
"""
import glob
import json
import os
import re
import statistics
import sys

runs = {}
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*-round*.json"))):
    for result in json.load(open(path))["benchmarks"]:
        tree = re.sub(r"-round\d+\.json$", "", os.path.basename(path))
        tree = tree.removesuffix("-" + result["test"])
        tree = "metal" if tree in ("hipdelta-ref", "ref") else tree
        runs.setdefault((result["test"], tree), []).append(result["ns_per_day"])
tests = sorted({test for test, _ in runs})
trees = sorted({tree for _, tree in runs if tree != "metal"})
for tree in trees:
    print(f"{'test':12} {'metal median':>13} {tree + ' median':>16} {'ratio':>6}   metal rounds | {tree} rounds")
    for test in tests:
        ref, new = runs.get((test, "metal"), []), runs.get((test, tree), [])
        if not ref or not new:
            continue
        m_ref, m_new = statistics.median(ref), statistics.median(new)
        print(f"{test:12} {m_ref:13.1f} {m_new:16.1f} {m_new/m_ref:6.3f}   {' '.join(f'{x:.1f}' for x in ref)} | {' '.join(f'{x:.1f}' for x in new)}")
    print()

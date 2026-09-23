"""Median ns/day per test and tree over the rounds that bench.sh wrote.

usage: python summarize.py <bench output dir>
"""
import glob
import json
import os
import statistics
import sys

runs = {}
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*-round*.json"))):
    tree = os.path.basename(path).rsplit("-round", 1)[0]
    for result in json.load(open(path))["benchmarks"]:
        runs.setdefault((result["test"], tree), []).append(result["ns_per_day"])
tests = sorted({test for test, _ in runs}, key=lambda t: t)
print(f"{'test':12} {'metal median':>13} {'hipdelta median':>16} {'ratio':>6}   metal rounds | hipdelta rounds")
for test in tests:
    ref, new = runs.get((test, "hipdelta-ref"), []), runs.get((test, "hipdelta"), [])
    if not ref or not new:
        continue
    m_ref, m_new = statistics.median(ref), statistics.median(new)
    print(f"{test:12} {m_ref:13.1f} {m_new:16.1f} {m_new/m_ref:6.3f}   {' '.join(f'{x:.1f}' for x in ref)} | {' '.join(f'{x:.1f}' for x in new)}")

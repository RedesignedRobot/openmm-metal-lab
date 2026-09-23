"""Summarize bench.sh results: mean ± sd ns/day per work unit and configuration, plus errors.

usage: python summarize.py <out-dir> [<out-dir> ...]   (one directory per chip)
Clock: host wall (time.perf_counter), whole steps, as recorded by fahwu.py.
"""
import json
import statistics as st
import sys
from collections import defaultdict

for out in sys.argv[1:]:
    rows = [json.loads(l) for l in open(f"{out}/fah.jsonl") if l.strip()]
    chip = next((l.strip() for l in open(f"{out}/host.txt") if l.startswith("Apple M")), out)
    runs = defaultdict(list)
    for r in rows:
        runs[(r["wu"], r["platform"], r["precision"])].append(r)
    print(f"## {chip}  ({out})")
    print("| WU | config | n | ns/day mean ± sd | force err (max) | energy err (max) |")
    print("|---|---|---|---|---|---|")
    for (wu, platform, precision), rs in sorted(runs.items()):
        speeds = [r["ns_per_day"] for r in rs]
        sd = st.stdev(speeds) if len(speeds) > 1 else 0.0
        print(f"| {wu} | {platform} {precision} | {len(rs)} | {st.mean(speeds):.2f} ± {sd:.2f} "
              f"| {max(r['rel_force_err'] for r in rs):.2e} | {max(r['energy_rel_err'] for r in rs):.2e} |")
    print()

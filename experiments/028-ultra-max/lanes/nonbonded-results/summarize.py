"""Median ns/day per (label, test) from ab.sh json files, and ratios of each label against a base label.
usage: summarize.py <dir> <base> [label ...]"""
import glob, json, os, re, statistics, sys
d, base = sys.argv[1], sys.argv[2]
runs = {}
for f in glob.glob(os.path.join(d, "*.json")):
    m = re.match(r"(.+?)-(gbsa|rf|pme|apoa1rf|apoa1pme|apoa1ljpme|amber20-dhfr|amber20-cellulose|amber20-stmv)-round(\d+)\.json", os.path.basename(f))
    if not m:
        continue
    for rec in json.load(open(f))["benchmarks"]:
        runs.setdefault((m.group(1), rec["test"]), []).append(rec["ns_per_day"])
labels = sorted({k[0] for k in runs})
tests = [t for t in "gbsa rf pme apoa1rf apoa1pme apoa1ljpme amber20-dhfr amber20-cellulose amber20-stmv".split() if any(k[1] == t for k in runs)]
others = sys.argv[3:] or [l for l in labels if l != base]
print(f"{'test':18}" + "".join(f"{l:>12}" for l in [base] + others) + "".join(f"{l+'/'+base:>22}" for l in others))
for t in tests:
    b = runs.get((base, t))
    bm = statistics.median(b) if b else float("nan")
    row = f"{t:18}{bm:12.2f}"
    ratios = ""
    for l in others:
        v = runs.get((l, t))
        vm = statistics.median(v) if v else float("nan")
        row += f"{vm:12.2f}"
        ratios += f"{vm/bm:22.3f}"
    print(row + ratios)
print("rounds:")
for (l, t), v in sorted(runs.items()):
    print(f"  {l:14} {t:18} " + " ".join(f"{x:.2f}" for x in v))

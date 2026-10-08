"""Per-run wall time of ab.sh runs from loads.txt start stamps and result json mtimes.
usage: python runtimes.py <ab.sh outdir>...
wall = json mtime - start stamp (the stamp is whole seconds, so wall reads 0.5 s long on average).
setup = wall - elapsed_time - calibration, where calibration is the ~1 s step-count probe plus the
20-step first probe; exit = next run's start stamp - this json's mtime, within the same hold."""
import datetime, glob, json, os, re, statistics, sys
from collections import defaultdict

by_test = defaultdict(list)
exits = []
for d in sys.argv[1:]:
    starts = []
    for line in open(os.path.join(d, "loads.txt")):
        m = re.match(r"(\S+) round (\d+) (\S+) (\S+) load", line)
        if not m:
            continue
        ts = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()
        starts.append((ts, m.group(2), m.group(3), m.group(4)))
    for i, (ts, r, test, label) in enumerate(starts):
        path = os.path.join(d, f"{label}-{test}-round{r}.json")
        if not os.path.exists(path):
            continue
        b = json.load(open(path))["benchmarks"][0]
        end = os.path.getmtime(path)
        wall = end - ts - 0.5
        key = (test, b["platform"], b["precision"])
        by_test[key].append((wall, b["elapsed_time"]))
        if i + 1 < len(starts) and starts[i+1][1] == r and starts[i+1][2] == test:
            exits.append(starts[i+1][0] - end + 0.5)

print(f"{'test':18} {'platform':8} {'prec':6} {'runs':>4} {'wall s':>7} {'timed s':>7} {'wall-timed':>10}")
total_wall = total_timed = 0
for key in sorted(by_test):
    runs = by_test[key]
    wall = statistics.median(w for w, _ in runs)
    timed = statistics.median(t for _, t in runs)
    total_wall += sum(w for w, _ in runs)
    total_timed += sum(t for _, t in runs)
    print(f"{key[0]:18} {key[1]:8} {key[2]:6} {len(runs):4d} {wall:7.1f} {timed:7.1f} {wall - timed:10.1f}")
print(f"all runs: wall {total_wall:.0f} s, timed {total_timed:.0f} s, not timed {total_wall - total_timed:.0f} s ({100*(1 - total_timed/total_wall):.0f}%)")
if exits:
    print(f"json written to next run's start stamp: median {statistics.median(exits):.1f} s over {len(exits)} gaps")

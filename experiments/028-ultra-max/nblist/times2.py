# Per section of an NB_TIME file: find split at a fixed threshold into rebuilds and exits, plus mean nonbonded.
import sys, statistics
sections, cur = {}, None
for line in open(sys.argv[1]):
    if line.startswith('== '):
        cur = sections.setdefault(line[3:].strip(), {})
        continue
    label, us = line.split()
    cur.setdefault(label, []).append(float(us))
threshold = float(sys.argv[2]) if len(sys.argv) > 2 else 100.0
for name, t in sections.items():
    find = t['find'][50:]
    rebuilds = [v for v in find if v > threshold]
    exits = [v for v in find if v <= threshold]
    nb = t['nonbonded'][50:]
    print(f"{name:22s} steps {len(find):5d} rebuild {len(rebuilds)/len(find):.2f} find/rebuild {statistics.median(rebuilds) if rebuilds else 0:7.1f} exit {statistics.median(exits) if exits else 0:5.1f} find/step {sum(find)/len(find):6.1f} nonbonded {statistics.mean(nb):6.1f}")

# Does the first run of a build pay a compile the later runs don't? For each (dir, label, test) with 2+
# rounds, compare post (timestamp to json write minus timed interval) of the earliest run with the rest.
import json, os, re, sys, statistics
from datetime import datetime
runs = {}
for d in sys.argv[1:]:
    for f in os.listdir(d):
        m = re.match(r"(.+)-(.+)-round(\d+)\.json$", f)
        if not m:
            continue
        p = os.path.join(d, f)
        try:
            r = json.load(open(p))
        except ValueError:
            continue
        b = r["benchmarks"][0]
        if b["platform"] != "Metal":
            continue
        ts = datetime.fromisoformat(r["system"]["timestamp"]).timestamp()
        post = os.stat(p).st_mtime - ts - b["elapsed_time"]
        runs.setdefault((d, m[1], b["test"], b["precision"]), []).append((ts, post))
first, rest = {}, {}
for (d, label, test, prec), v in runs.items():
    if len(v) < 2:
        continue
    v.sort()
    first.setdefault((test, prec), []).append(v[0][1])
    rest.setdefault((test, prec), []).extend(x[1] for x in v[1:])
print(f"{'test':12} {'prec':7} {'builds':>6} {'first med':>9} {'later med':>9} {'first-later med':>15}")
for k in sorted(first):
    print(f"{k[0]:12} {k[1]:7} {len(first[k]):6} {statistics.median(first[k]):9.2f} {statistics.median(rest[k]):9.2f} {statistics.median(first[k]) - statistics.median(rest[k]):15.2f}")

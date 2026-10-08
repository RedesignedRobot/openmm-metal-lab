# Per-run setup split from ab.sh output dirs: pre = python start to the benchmark.py timestamp
# (loads stamp is truncated to the second, so pre carries +0..1 s), post = timestamp to json write minus
# the timed interval (system build, Context, minimizer, velocities, calibration steps).
import json, os, re, sys, statistics
from datetime import datetime, timezone
rows = {}
for d in sys.argv[1:]:
    stamps = {}
    for line in open(os.path.join(d, "loads.txt")):
        m = re.match(r"(\S+Z) round (\d+) (\S+) (\S+) load", line)
        if m:
            stamps[(m[2], m[3], m[4])] = datetime.strptime(m[1], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    for f in os.listdir(d):
        m = re.match(r"(.+)-(.+)-round(\d+)\.json$", f)
        if not m or (m[3], m[2], m[1]) not in stamps:
            continue
        p = os.path.join(d, f)
        try:
            r = json.load(open(p))
        except ValueError:
            continue
        b = r["benchmarks"][0]
        ts = datetime.fromisoformat(r["system"]["timestamp"]).timestamp()
        if ts < datetime.fromisoformat(os.environ.get("SINCE", "2026-09-24T21:50:00+00:00")).timestamp():
            continue
        pre = ts - stamps[(m[3], m[2], m[1])]
        post = os.stat(p).st_mtime - ts - b["elapsed_time"]
        rows.setdefault((b["test"], b["precision"], b["platform"]), []).append((pre, post, b["elapsed_time"]))
print(f"{'test':22} {'prec':7} {'platform':8} {'runs':>4} {'pre med':>8} {'post med':>9} {'post min':>9} {'post max':>9} {'timed med':>9}")
for k in sorted(rows):
    v = rows[k]
    pre = statistics.median(x[0] for x in v); post = [x[1] for x in v]
    print(f"{k[0]:22} {k[1]:7} {k[2]:8} {len(v):4} {pre:8.2f} {statistics.median(post):9.2f} {min(post):9.2f} {max(post):9.2f} {statistics.median(x[2] for x in v):9.2f}")

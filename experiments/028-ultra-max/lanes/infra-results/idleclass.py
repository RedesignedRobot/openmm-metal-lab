"""Classifies the lead sampler's idle-while-held samples since 21:50Z against every ab.sh run.
usage: python idleclass.py <gpu-util.log> <ab.sh outdir>...
A run spans its loads.txt start stamp to its json mtime. Its last elapsed_time + 1.1 s (the step-count
probes) is GPU work; the part before is setup. Samples outside every run are other work in the hold."""
import datetime, json, os, re, sys
from collections import Counter

day = "2026-09-24"
def stamp(text):
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()

runs = []
for d in sys.argv[2:]:
    for line in open(os.path.join(d, "loads.txt")):
        m = re.match(r"(\S+) round (\d+) (\S+) (\S+) load", line)
        if not m:
            continue
        path = os.path.join(d, f"{m.group(4)}-{m.group(3)}-round{m.group(2)}.json")
        if not os.path.exists(path):
            continue
        start = stamp(m.group(1)) + 0.5
        end = os.path.getmtime(path)
        benchmarks = json.load(open(path))["benchmarks"]
        if not benchmarks:
            continue
        result = benchmarks[0]
        gpu_from = end - result["elapsed_time"] - 1.1
        runs.append((start, gpu_from, end, result["platform"]))
runs.sort()

classes = Counter()
outside = []
held = Counter()
for line in open(sys.argv[1]):
    t, g, h = line.split()[:3]
    if t < "21:50:00":
        continue
    holder = h.split("=")[1]
    if holder == "none":
        continue
    busy = int(g.split("=")[1] or 0) > 0
    now = stamp(f"{day}T{t}Z")
    kind = "outside ab.sh runs"
    for i, (start, gpu_from, end, platform) in enumerate(runs):
        if start <= now <= end:
            if platform == "CPU":
                kind = "ab.sh CPU-platform run"
            else:
                kind = "ab.sh setup" if now < gpu_from else "ab.sh GPU phase"
            break
        if i + 1 < len(runs) and end < now < runs[i+1][0] and runs[i+1][0] - end < 3:
            kind = "between ab.sh runs"
            break
    held[kind] += 1
    if not busy:
        classes[kind] += 1
        if kind == "outside ab.sh runs":
            outside.append((t, holder))
total = sum(held.values())
for kind in held:
    print(f"{kind:22} {held[kind]:4d} held samples, {classes[kind]:3d} idle ({100*classes[kind]/total:.1f}% of all held samples)")
print(f"all: {total} held samples, {sum(classes.values())} idle")
spans = []
for t, holder in outside:
    if spans and spans[-1][2] == holder and stamp(f"{day}T{t}Z") - stamp(f"{day}T{spans[-1][1]}Z") <= 30:
        spans[-1][1] = t
        spans[-1][3] += 1
    else:
        spans.append([t, t, holder, 1])
print("idle samples outside ab.sh runs, grouped when under 30 s apart:")
for first, last, holder, n in spans:
    print(f"  {first} to {last} {holder:16} {n:3d}")

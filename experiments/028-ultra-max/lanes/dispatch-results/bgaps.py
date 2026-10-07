"""Buffer boundaries in a gpuprof buffers-mode record, for any number of command buffers per step.

usage: python bgaps.py <buffers-mode .rec or .rec.gz> [label]
For each pair of consecutive command buffers on the GPU (sorted by GPU start), in us on the host clock:
  idle: next start minus this end
  lead: this end minus the next buffer's commit (positive when the next buffer was committed before this one ended)
  sched: next scheduled minus this end, start-sched: next start minus next scheduled
Boundaries are then grouped by lead, which separates host lateness from Metal's own start latency.
"""
import gzip
import statistics
import sys

path = sys.argv[1]
label = sys.argv[2] if len(sys.argv) > 2 else path
buffers, waits = [], []
for line in (gzip.open(path, "rt") if path.endswith(".gz") else open(path)):
    f = line.split()
    if f[0] == "b":
        buffers.append({"start": float(f[1]), "end": float(f[2]), "commit": float(f[3]), "scheduled": float(f[6]),
                        "dispatches": int(f[7]), "blits": int(f[8])})
    elif f[0] == "w" and f[1] == "event":
        waits.append(float(f[2]))
buffers.sort(key=lambda b: b["start"])
rows = []
for b, n in zip(buffers, buffers[1:]):
    rows.append({"idle": n["start"]-b["end"], "lead": b["end"]-n["commit"], "sched": n["scheduled"]-b["end"],
                 "startsched": n["start"]-n["scheduled"], "gpu": b["end"]-b["start"]})


def med(values):
    return statistics.median(values)*1e6 if values else float("nan")


def mean(values):
    return statistics.mean(values)*1e6 if values else float("nan")


span = buffers[-1]["end"]-buffers[0]["start"]
busy = sum(b["end"]-b["start"] for b in buffers)
print(f"{label}: {len(buffers)} buffers, {len(waits)} event waits (median {med(waits):.1f} us), "
      f"GPU busy {busy/span:.1%} of span, idle {mean([max(r['idle'], 0) for r in rows]):.1f} us per boundary")
print("| Boundaries | Share | idle mean | idle median | sched-end median | start-sched median | buffer GPU median |")
print("|---|---:|---:|---:|---:|---:|---:|")
groups = [("next committed after this end", lambda r: r["lead"] <= 0),
          ("committed 0 to 50 us before", lambda r: 0 < r["lead"] <= 50e-6),
          ("committed 50 to 150 us before", lambda r: 50e-6 < r["lead"] <= 150e-6),
          ("committed 150 to 500 us before", lambda r: 150e-6 < r["lead"] <= 500e-6),
          ("committed over 500 us before", lambda r: r["lead"] > 500e-6),
          ("all", lambda r: True)]
for name, test in groups:
    g = [r for r in rows if test(r)]
    if not g:
        continue
    print(f"| {name} | {len(g)/len(rows):.1%} | {mean([r['idle'] for r in g]):.1f} | {med([r['idle'] for r in g]):.1f} | "
          f"{med([r['sched'] for r in g]):.1f} | {med([r['startsched'] for r in g]):.1f} | {med([r['gpu'] for r in g]):.1f} |")
print()
print("| Lead (us) | Share | idle mean | idle median |")
print("|---|---:|---:|---:|")
edges = [None, 0] + list(range(25, 325, 25)) + [None]
for lo, hi in zip(edges, edges[1:]):
    g = [r for r in rows if (lo is None or r["lead"] > lo*1e-6) and (hi is None or r["lead"] <= hi*1e-6)]
    if not g:
        continue
    name = f"<= {hi}" if lo is None else f"> {lo}" if hi is None else f"{lo}-{hi}"
    print(f"| {name} | {len(g)/len(rows):.1%} | {mean([r['idle'] for r in g]):.1f} | {med([r['idle'] for r in g]):.1f} |")

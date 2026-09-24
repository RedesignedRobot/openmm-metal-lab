"""Where the idle gap sits in a buffers-mode record: per step, X is the command buffer with the neighbor-list count
download (a blit) and Y the buffer after it, so a step runs X, Y, then the next step's X.

usage: python gaps.py <buffers-mode .rec or .rec.gz>
All times are host-clock microseconds (GPUStartTime and mach_absolute_time share a clock). For each X, Y, X' triple:
  X end -> Y start, Y end -> X' start: GPU idle at each buffer boundary
  wake: host event wait end minus X's GPU end (the count event is signaled at the end of X)
  encode: X' commit minus that wait's end (host work between waking and committing the next step)
  X' commit, scheduled and start relative to Y's end
"""
import gzip
import statistics
import sys

path = sys.argv[1]
buffers, waits = [], []
for line in (gzip.open(path, "rt") if path.endswith(".gz") else open(path)):
    f = line.split()
    if f[0] == "b":
        buffers.append({"start": float(f[1]), "end": float(f[2]), "commit": float(f[3]), "first": f[4], "last": f[5],
                        "scheduled": float(f[6]), "dispatches": int(f[7]), "blits": int(f[8])})
    elif f[0] == "w" and f[1] == "event":
        start = float(f[3])
        waits.append((start, start+float(f[2])))
buffers.sort(key=lambda b: b["start"])
waits.sort()

rows = []
w = 0
for i in range(len(buffers)-2):
    x, y, nx = buffers[i], buffers[i+1], buffers[i+2]
    if x["blits"] == 0 or y["blits"] != 0 or nx["blits"] == 0:
        continue
    while w < len(waits) and waits[w][1] < x["end"]:
        w += 1
    if w == len(waits):
        break
    wake = waits[w][1]
    rows.append({"x_y": y["start"]-x["end"], "y_nx": nx["start"]-y["end"], "wake": wake-x["end"], "encode": nx["commit"]-wake,
                 "commit_vs_yend": nx["commit"]-y["end"], "sched_vs_yend": nx["scheduled"]-y["end"],
                 "start_vs_sched": nx["start"]-nx["scheduled"], "y_gpu": y["end"]-y["start"], "x_gpu": x["end"]-x["start"],
                 "gap": (y["start"]-x["end"])+(nx["start"]-y["end"])})

def us(values, q):
    return statistics.quantiles(values, n=100)[q-1]*1e6 if q else statistics.median(values)*1e6

print(f"{path}: {len(rows)} steps, {len(buffers)} buffers, {len(waits)} event waits")
print("| Quantity | Mean us | Median | p90 | p99 |")
print("|---|---:|---:|---:|---:|")
for key, label in [("x_gpu", "X GPU time"), ("y_gpu", "Y GPU time"), ("x_y", "idle X end -> Y start"),
                   ("y_nx", "idle Y end -> X' start"), ("wake", "host wake after X end"), ("encode", "host wake -> X' commit"),
                   ("commit_vs_yend", "X' commit - Y end"), ("sched_vs_yend", "X' scheduled - Y end"),
                   ("start_vs_sched", "X' start - X' scheduled")]:
    v = [r[key] for r in rows]
    print(f"| {label} | {statistics.mean(v)*1e6:.1f} | {us(v, 0):.1f} | {us(v, 90):.1f} | {us(v, 99):.1f} |")
gaps = sorted((r["gap"] for r in rows), reverse=True)
top = max(1, len(gaps)//100)
print(f"gap per step: mean {statistics.mean(gaps)*1e6:.1f} us; the worst 1% of steps hold {sum(gaps[:top])/sum(gaps):.1%} of the idle time "
      f"(their mean {statistics.mean(gaps[:top])*1e6:.0f} us)")
late = sum(1 for r in rows if r["commit_vs_yend"] > 0)/len(rows)
print(f"X' committed after Y ended on {late:.1%} of steps")

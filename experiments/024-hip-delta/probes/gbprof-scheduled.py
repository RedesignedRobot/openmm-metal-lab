"""Scheduled-handler time against commit time, GPU start and the previous buffer's GPU end, for X and Y, in us.
Needs records with the scheduled time (GpuProf.h from wait1 on).
usage: python gbprof-scheduled.py <records .rec.gz>
"""
import sys, statistics, gzip
bufs = []
for l in gzip.open(sys.argv[1], "rt"):
    f = l.split()
    if f[0] == "b" and len(f) >= 7:
        bufs.append((float(f[1]), float(f[2]), float(f[3]), f[4], f[5], float(f[6])))
bufs.sort()
def show(name, v):
    v = sorted(v); print(f"  {name:34} median {statistics.median(v):8.2f} p10 {v[len(v)//10]:8.2f} p90 {v[9*len(v)//10]:8.2f}")
ys = [(x, y) for x, y in zip(bufs, bufs[1:]) if y[3] == "computeBornSum"]
xs = [(p, x) for p, x in zip(bufs, bufs[1:]) if x[3] in ("integrateLangevinMiddlePart1", "generateRandomNumbers")]
show("Y scheduled - Y commit", [(y[5]-y[2])*1e6 for x, y in ys])
show("Y scheduled - X end", [(y[5]-x[1])*1e6 for x, y in ys])
show("Y start - Y scheduled", [(y[0]-y[5])*1e6 for x, y in ys])
show("X scheduled - X commit", [(x[5]-x[2])*1e6 for p, x in xs])
show("X scheduled - prev Y end", [(x[5]-p[1])*1e6 for p, x in xs])
show("X start - X scheduled", [(x[0]-x[5])*1e6 for p, x in xs])

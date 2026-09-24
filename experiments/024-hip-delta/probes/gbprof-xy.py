"""Per step, times of the X buffer (ends with the count event), the Y buffer (starts with computeBornSum) and the
host event wait, relative to X's GPU end, in us. Medians and 10th and 90th percentiles.
usage: python gbprof-xy.py <records .rec.gz>
"""
import sys, statistics, gzip, bisect
bufs, waits = [], []
for l in gzip.open(sys.argv[1], "rt"):
    f = l.split()
    if f[0] == "b" and len(f) >= 6:
        bufs.append((float(f[1]), float(f[2]), float(f[3]), f[4], f[5]))
    elif f[0] == "w" and f[1] == "event":
        waits.append((float(f[3]), float(f[3])+float(f[2])))
bufs.sort()
waits.sort()
ws = [w[0] for w in waits]
rows = []
for x, y in zip(bufs, bufs[1:]):
    if y[3] != "computeBornSum":
        continue
    i = bisect.bisect_left(ws, y[2])
    wait = waits[i] if i < len(waits) else None
    rows.append(((x[2]-x[0])*1e6, (y[2]-x[1])*1e6, (wait[0]-x[1])*1e6 if wait else 0, (wait[1]-x[1])*1e6 if wait else 0, (y[0]-x[1])*1e6, (x[1]-x[0])*1e6))
names = ["X commit - X start", "Y commit - X end", "wait start - X end", "wait end - X end", "Y start - X end", "X length"]
for k, n in enumerate(names):
    v = [r[k] for r in rows]
    print(f"{n:22} median {statistics.median(v):9.2f}  p10 {sorted(v)[len(v)//10]:9.2f}  p90 {sorted(v)[9*len(v)//10]:9.2f}")

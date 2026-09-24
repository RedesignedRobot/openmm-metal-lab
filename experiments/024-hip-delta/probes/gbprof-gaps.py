"""Per buffer kind (split by GPU duration at a threshold), the gap from the previous buffer's end
to this buffer's GPU start, and how long the host's event wait ended after the waited buffer's end.
usage: python gbprof-gaps.py <records> <threshold us>"""
import statistics, sys
bufs, waits = [], []
for l in open(sys.argv[1]):
    f = l.split()
    if f[0] == "b":
        bufs.append((float(f[3]), float(f[1]), float(f[2])))
    elif f[0] == "w" and f[1] == "event":
        waits.append((float(f[3]), float(f[3])+float(f[2])))
bufs.sort()  # commit order
th = float(sys.argv[2])*1e-6
gap = {"short": [], "long": []}
queued = {"short": [], "long": []}
for (c0, s0, e0), (c1, s1, e1) in zip(bufs, bufs[1:]):
    kind = "short" if e1-s1 < th else "long"
    gap[kind].append((s1-e0)*1e6)
    queued[kind].append((e0-c1)*1e6)
for k in gap:
    g = gap[k]
    print(f"{k} buffers: n {len(g)}, gap before start median {statistics.median(g):.1f} us, mean {statistics.mean(g):.1f}, "
          f"committed before previous end by median {statistics.median(queued[k]):.1f} us")
# each wait ends after the short buffer committed just before the wait began
wake = []
for wb, we in waits:
    cands = [b for b in bufs if b[0] < wb and b[2]-b[1] < th]
    if cands:
        wake.append((we-cands[-1][2])*1e6)
print(f"event wait end minus GPU end of the short buffer committed before it: median {statistics.median(wake):.1f} us")

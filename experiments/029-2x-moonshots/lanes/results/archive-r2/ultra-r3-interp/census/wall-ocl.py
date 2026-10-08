"""Step wall time split by kernel: each kernel's sampled busy time (overlapped time split evenly between the
kernels running) plus the idle gap that follows it (dispatch boundary, unsampled tail, kick end).
usage: python wall.py <intervals.xml> <pid>
"""
import collections
import sys
import xml.etree.ElementTree as ET

path, pid = sys.argv[1], sys.argv[2]
texts, spans = {}, []
for _, e in ET.iterparse(path, events=("end",)):
    if e.get("id") is not None:
        texts[e.get("id")] = e.text if e.tag in ("start-time", "duration") else (e.get("fmt") or e.text or "")
    if e.tag == "row":
        c = list(e)
        v = lambda x: texts.get(x.get("ref")) if x.get("ref") else (x.text if x.tag in ("start-time", "duration") else x.get("fmt") or x.text or "")
        if f"({pid})" in v(c[11]):
            spans.append((int(v(c[0])), int(v(c[1])), v(c[2]).rsplit(" (", 1)[0].replace("__entry_", "")))
        e.clear()
spans.sort()
nb = [s[0] for s in spans if s[2] == "computeNonbonded"]
first, last = nb[len(nb)//10], nb[-1]
n = sum(1 for t in nb if first <= t < last)
events = []
for t, d, name in spans:
    if first <= t < last:
        events += [(t, 1, name), (t+d, -1, name)]
events.sort(key=lambda e: (e[0], e[1]))
active, busy, gap = collections.Counter(), collections.defaultdict(float), collections.defaultdict(float)
prev, lastended = None, None
for t, kind, name in events:
    if prev is not None and t > prev:
        live = [k for k, c in active.items() if c > 0]
        dt = (t-prev)/1e3
        if live:
            for k in live:
                busy[k] += dt/len(live)
        elif lastended:
            gap[lastended] += dt
    active[name] += kind
    if kind < 0:
        lastended = name
    prev = t
wall = (last-first)/1e3/n
print(f"steps {n}, wall {wall:.1f} us/step")
print(f"| kernel | busy us | gap after us | total us | share |")
print(f"|---|---:|---:|---:|---:|")
rows = sorted(set(busy) | set(gap), key=lambda k: -(busy[k]+gap[k]))
for k in rows:
    tot = (busy[k]+gap[k])/n
    if tot >= 0.5:
        print(f"| {k} | {busy[k]/n:.1f} | {gap[k]/n:.1f} | {tot:.1f} | {100*tot/wall:.1f}% |")
rest = sum(busy[k]+gap[k] for k in rows if (busy[k]+gap[k])/n < 0.5)/n
print(f"| other | | | {rest:.1f} | {100*rest/wall:.1f}% |")

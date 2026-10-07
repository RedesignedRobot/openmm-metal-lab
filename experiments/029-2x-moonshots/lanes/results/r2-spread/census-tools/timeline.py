"""Critical-path view of one shader-timeline export: union busy time per step, and per kernel the time it runs
alone (nothing else of the pid on the GPU) versus overlapped.
usage: python timeline.py <intervals.xml> <pid>
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
            spans.append((int(v(c[0])), int(v(c[1])), v(c[2]).rsplit(" (", 1)[0]))
        e.clear()
spans.sort()
steps = sum(1 for s in spans if s[2] == "computeNonbonded")
first = min(s[0] for s in spans if s[2] == "computeNonbonded")
last = max(s[0] for s in spans if s[2] == "computeNonbonded")
nsteps = sum(1 for s in spans if s[2] == "computeNonbonded" and s[0] < last)
events = []
for t, d, n in spans:
    if first <= t < last:
        events += [(t, 1, n), (t+d, -1, n)]
events.sort(key=lambda e: (e[0], e[1]))
active = collections.Counter()
alone, shared, busy = collections.defaultdict(float), collections.defaultdict(float), 0.0
prev = None
for t, kind, n in events:
    if prev is not None and t > prev:
        live = [k for k, c in active.items() if c > 0]
        dt = (t-prev)/1e3
        if live:
            busy += dt
            for k in live:
                (alone if len(live) == 1 else shared)[k] += dt/len(live) if len(live) > 1 else dt
    active[n] += kind
    prev = t
wall = (last-first)/1e3
print(f"steps {nsteps}  wall {wall/nsteps:.1f} us/step  busy {busy/nsteps:.1f}  idle {(wall-busy)/nsteps:.1f}")
print(f"{'kernel':40s} {'alone':>8s} {'shared/n':>9s}")
for k in sorted(set(alone) | set(shared), key=lambda k: -(alone[k]+shared[k])):
    if alone[k]+shared[k] > 0.05*nsteps:
        print(f"{k[:40]:40s} {alone[k]/nsteps:8.2f} {shared[k]/nsteps:9.2f}")

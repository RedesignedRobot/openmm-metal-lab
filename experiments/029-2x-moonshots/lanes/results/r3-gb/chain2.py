"""Median in-step timeline around one per-step kernel, for traces that record only some steps.
python chain2.py <intervals.xml> <pid> <anchor> <us before> <us after>
Offsets are from the anchor's start; phase is the median gap from a kernel's start to the next kernel's start."""
import sys, collections, statistics
import xml.etree.ElementTree as ET
path, pid, anchor, before, after = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]), float(sys.argv[5])
texts, iv = {}, []
for _, e in ET.iterparse(path, events=("end",)):
    if e.get("id") is not None:
        texts[e.get("id")] = e.text if e.tag in ("start-time", "duration") else (e.get("fmt") or e.text or "")
    if e.tag == "row":
        c = list(e)
        v = lambda x: texts.get(x.get("ref")) if x.get("ref") else (x.text if x.tag in ("start-time", "duration") else x.get("fmt") or x.text or "")
        if f"({pid})" in v(c[11]):
            iv.append((int(v(c[0])), int(v(c[1])), v(c[2]).rsplit(" (", 1)[0]))
        e.clear()
iv.sort()
st, en, du = collections.defaultdict(list), collections.defaultdict(list), collections.defaultdict(list)
anchors = [s for s, d, n in iv if n == anchor]
j = 0
for a in anchors:
    while j < len(iv) and iv[j][0] < a-before*1e3: j += 1
    i = j
    while i < len(iv) and iv[i][0] < a+after*1e3:
        s, d, n = iv[i]
        st[n].append((s-a)/1e3); en[n].append((s+d-a)/1e3); du[n].append(d/1e3)
        i += 1
rows = sorted(((statistics.median(st[n]), statistics.median(en[n]), statistics.median(du[n]), len(st[n])/len(anchors), n) for n in st))
print(f"{len(anchors)} anchors ({anchor})")
print(f"{'kernel':34s} {'frac':>5s} {'start':>7s} {'end':>7s} {'sampled':>8s} {'phase':>7s}")
for k, (s, e, d, f, n) in enumerate(rows):
    ph = rows[k+1][0]-s if k+1 < len(rows) else float('nan')
    print(f"{n:34s} {f:5.2f} {s:7.1f} {e:7.1f} {d:8.1f} {ph:7.1f}")

"""Per-dispatch duration distribution of named kernels (sampled spans merged per dispatch by start gaps).
usage: python dist.py <intervals.xml> <pid> <kernel>...
"""
import collections
import sys
import xml.etree.ElementTree as ET

path, pid, names = sys.argv[1], sys.argv[2], sys.argv[3:]
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
for name in names:
    d = sorted(s[1]/1e3 for s in spans if s[2] == name)
    q = lambda p: d[min(len(d)-1, int(p*len(d)))]
    hist = collections.Counter(int(x//5)*5 for x in d)
    print(f"{name}: n {len(d)} p10 {q(.1):.1f} p25 {q(.25):.1f} p50 {q(.5):.1f} p75 {q(.75):.1f} p90 {q(.9):.1f}  hist(5us bins) {sorted(hist.items())[:12]}")

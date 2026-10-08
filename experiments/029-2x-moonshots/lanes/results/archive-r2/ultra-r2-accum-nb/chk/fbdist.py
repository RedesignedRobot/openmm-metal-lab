"""findBlocksWithInteractions span distribution from a shader-timeline export: rebuild rate and cost per rebuild.

usage: python fbdist.py <intervals.xml> <pid> [kernel]
Spans above half the median of the top quartile count as rebuilds.
"""
import sys
import xml.etree.ElementTree as ET

path, pid = sys.argv[1], sys.argv[2]
kernel = sys.argv[3] if len(sys.argv) > 3 else "findBlocksWithInteractions"
texts, spans, steps = {}, [], 0
for _, e in ET.iterparse(path, events=("end",)):
    if e.get("id") is not None:
        texts[e.get("id")] = e.text if e.tag in ("start-time", "duration") else (e.get("fmt") or e.text or "")
    if e.tag == "row":
        c = list(e)
        v = lambda x: texts.get(x.get("ref")) if x.get("ref") else (x.text if x.tag in ("start-time", "duration") else x.get("fmt") or x.text or "")
        if f"({pid})" in v(c[11]):
            name = v(c[2]).rsplit(" (", 1)[0]
            if name == kernel:
                spans.append(int(v(c[1]))/1e3)
            elif name == "computeNonbonded":
                steps += 1
        e.clear()
spans.sort()
top = spans[len(spans)*3//4:]
cut = 0.5*top[len(top)//2]
big = [s for s in spans if s > cut]
small = [s for s in spans if s <= cut]
print(f"{kernel}: spans {len(spans)}, nonbonded spans {steps}, rebuilds {len(big)} (rate {len(big)/max(steps,1):.3f}), "
      f"cost per rebuild {sum(big)/max(len(big),1):.1f} us, per skip {sum(small)/max(len(small),1):.2f} us, per step {sum(spans)/max(steps,1):.1f} us")

"""Flatten an xctrace shader-intervals export to TSV for one pid: start_ns, dur_ns, kernel, encoder-ish columns.
usage: python rows.py <intervals.xml> <pid> > out.tsv"""
import sys
import xml.etree.ElementTree as ET

path, pid = sys.argv[1], sys.argv[2]
texts = {}
first = True
for _, e in ET.iterparse(path, events=("end",)):
    if e.get("id") is not None:
        texts[e.get("id")] = e.text if e.tag in ("start-time", "duration") else (e.get("fmt") or e.text or "")
    if e.tag == "row":
        c = list(e)
        v = lambda x: texts.get(x.get("ref")) if x.get("ref") else (x.text if x.tag in ("start-time", "duration") else x.get("fmt") or x.text or "")
        vals = [v(x) for x in c]
        if first:
            sys.stderr.write(" | ".join(f"{x.tag}={vals[i]}" for i, x in enumerate(c)) + "\n")
            first = False
        if f"({pid})" in vals[11]:
            print("\t".join([vals[0], vals[1], vals[2].rsplit(" (", 1)[0]] + [str(x).replace("\t", " ") for x in vals[3:11]]))
        e.clear()

"""M0(2b) analysis: per xctrace counter profile, every counter's mean over busy GPU time and per kernel.

Reads cprobe/<tag>-counters.xml (metal-gpu-counter-intervals, GPU-wide samples about 3 us apart) and
cprobe/<tag>-intervals.xml (shader timeline, same trace, same clock). Each counter sample is charged to the traced
pid's kernel whose [start, end) holds the sample's midpoint, or to "idle". Means are duration-weighted.
usage: python cprobe.py <tag> ...   (prints one table per tag)
"""
import bisect
import collections
import sys
import xml.etree.ElementTree as ET

D = "/tmp/openmm-metal-bench/ultra-infra/m0/cprobe"
KERNELS = ["computeNonbonded", "findBlocksWithInteractions", "computeBondedForces", "findBlockBounds",
           "integrateLangevinMiddleFused"]


def rows(path):
    """Yield each row as a list of resolved cell values (fmt for labels, text for numbers and times)."""
    seen = {}
    for _, e in ET.iterparse(path, events=("end",)):
        if e.get("id") is not None:
            seen[e.get("id")] = (e.text, e.get("fmt"))
        if e.tag == "row":
            yield [seen.get(c.get("ref")) if c.get("ref") else (c.text, c.get("fmt")) for c in e]
            e.clear()


def kernels(tag):
    pid = open(f"{D}/{tag}.pypid").read().strip()
    spans = []
    for r in rows(f"{D}/{tag}-intervals.xml"):
        if f"({pid})" in (r[11][1] or ""):
            start = int(r[0][0])
            spans.append((start, start + int(r[1][0]), r[2][1].rsplit(" (", 1)[0]))
    spans.sort()
    return spans


def table(tag):
    spans = kernels(tag)
    starts = [s for s, _, _ in spans]
    weight = collections.defaultdict(float)  # (counter, kernel) -> ns
    total = collections.defaultdict(float)   # (counter, kernel) -> value x ns
    for r in rows(f"{D}/{tag}-counters.xml"):
        start, dur, name, value = int(r[0][0]), int(r[1][0]), r[3][1], float(r[5][0])
        mid = start + dur // 2
        i = bisect.bisect_right(starts, mid) - 1
        kernel = spans[i][2] if i >= 0 and mid < spans[i][1] else "idle"
        for k in (kernel, "busy" if kernel != "idle" else None):
            if k:
                weight[name, k] += dur
                total[name, k] += value * dur
    cols = ["busy"] + KERNELS + ["idle"]
    names = sorted({n for n, _ in weight})
    print(f"## {tag}: {len(names)} counters, {len(spans)} kernel rows")
    print("counter".ljust(44) + "".join(c[:12].rjust(13) for c in cols))
    for n in names:
        cells = [f"{total[n, c] / weight[n, c]:.2f}" if weight[n, c] else "-" for c in cols]
        print(n[:43].ljust(44) + "".join(x.rjust(13) for x in cells))
    print()


for tag in sys.argv[1:]:
    table(tag)

"""GPU busy share and gaps between GPU kicks per prof.py window, from a Metal System Trace's metal-gpu-intervals export.

usage: python kicks.py <test>-gpu-intervals.xml <test>-single.txt
One row per kick: the driver merges consecutive compute encoders into one kick. Only the traced python process
counts. Window B spans the kicks whose labels name GpuProf.h split-mode encoders; A ends at the last kick before B
and C starts at the first kick after it, each lasting its host_s from prof.py. A kick's gap is its start minus the
latest end so far, floored at 0. Transitions key a gap by the previous and next kick's labels.
"""
import collections
import re
import statistics
import sys
import xml.etree.ElementTree as ET

UNLABELED = ("Compute Command", "Blit Command")
TOP_TRANSITIONS = 6
GAP_EDGES_US = [2.0, 10.0, 50.0, 200.0, 1000.0]


def load_kicks(path):
    texts, kicks = {}, []
    for _, e in ET.iterparse(path, events=("end",)):
        if e.get("id") is not None:
            texts[e.get("id")] = e.text if e.tag in ("start-time", "duration") else (e.get("fmt") or "")
        if e.tag != "row":
            continue
        c = list(e)
        v = lambda x: texts.get(x.get("ref")) if x.get("ref") else (x.text if x.tag in ("start-time", "duration") else x.get("fmt") or "")
        if v(c[10]).startswith("python"):
            label = v(c[6]).split("   (")[0].split(":", 1)[-1].strip()
            kicks.append((int(v(c[0]))/1e3, (int(v(c[0]))+int(v(c[1])))/1e3, label))
        e.clear()
    return sorted(kicks)


def windows(path):
    found = {}
    for line in open(path):
        m = re.match(r"window (\w) .* steps (\d+) host_s ([\d.]+)", line)
        if m:
            found[m[1]] = (int(m[2]), float(m[3])*1e6)
    return found


def short(label):
    return label if label.startswith(UNLABELED) else label.split(" & ")[0]+" ..."


def report(name, kicks, lo, hi, steps):
    inside = [k for k in kicks if lo <= k[0] < hi]
    busy, gaps, transitions = 0.0, [], collections.defaultdict(list)
    covered = lo
    for i, (start, end, label) in enumerate(inside):
        end = min(end, hi)
        busy += max(0.0, end-max(start, covered))
        if i:
            gap = max(0.0, start-covered)
            gaps.append(gap)
            transitions[(short(inside[i-1][2]), short(label))].append(gap)
        covered = max(covered, end)
    wall = hi-lo
    gaps.sort()
    print(f"window {name}: {steps} steps, {len(inside)/steps:.2f} kicks/step, wall {wall/steps:.1f} us/step, "
          f"busy {busy/steps:.1f} us/step ({busy/wall:.1%}), idle {(wall-busy)/steps:.1f} us/step ({1-busy/wall:.1%}), "
          f"inter-kick gap total {sum(gaps)/steps:.1f} us/step, median {statistics.median(gaps):.2f} us, "
          f"p90 {gaps[int(0.9*len(gaps))]:.2f} us, max {gaps[-1]:.1f} us")
    edges = [0.0]+GAP_EDGES_US+[float("inf")]
    print("  gaps by size: "+", ".join(
        f"{a:g}-{b:g} us {sum(a <= g < b for g in gaps)/steps:.2f}/step {sum(g for g in gaps if a <= g < b)/steps:.1f} us/step"
        for a, b in zip(edges, edges[1:])))
    ranked = sorted(transitions.items(), key=lambda t: -sum(t[1]))[:TOP_TRANSITIONS]
    for (before, after), g in ranked:
        print(f"  {before} -> {after}: {len(g)/steps:.2f}/step, median {statistics.median(g):.2f} us, "
              f"total {sum(g)/steps:.1f} us/step")


kicks = load_kicks(sys.argv[1])
win = windows(sys.argv[2])
labeled = [k for k in kicks if not k[2].startswith(UNLABELED)]
b_lo, b_hi = labeled[0][0], max(k[1] for k in labeled)
a_hi = max(k[1] for k in kicks if k[0] < b_lo)
c_lo = min(k[0] for k in kicks if k[0] > b_hi)
report("A", kicks, a_hi-win["A"][1], a_hi, win["A"][0])
report("B", kicks, b_lo, b_hi, win["B"][0])
report("C", kicks, c_lo, c_lo+win["C"][1], win["C"][0])

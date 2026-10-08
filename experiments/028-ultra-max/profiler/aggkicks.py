"""GPU busy time, idle gaps and command buffers per step for agg.py cases traced by aggtrace.sh.

usage: python aggkicks.py <aggtrace out dir> <case>...
Reads <case>-gpu-intervals.xml (metal-gpu-intervals, --all-processes; only python processes count) and the case's
line in agg/agg.jsonl. The window starts at the first kick after the last gap of WINDOW_GAP_US or more across the
children: they idle 0.5 s between warm-up and the shared start. Per-process began and ended in agg.jsonl, relative
to that start, bound each child's window; steps are per_process ns/day times elapsed at 4 fs a step.
Busy is the union of the children's kicks over the window where all N ran (latest began to earliest ended); a gap
is time in that window with no child's kick on the GPU. Kick durations are grouped by label (the driver merges
consecutive encoders into one kick, so a label names a kick's first encoder).
"""
import collections
import json
import statistics
import sys
import xml.etree.ElementTree as ET

WINDOW_GAP_US = 300e3
GAP_EDGES_US = [2.0, 10.0, 50.0, 200.0, 1000.0]
STEP_NS = 4e-6


def load(path):
    texts, kicks = {}, []
    for _, e in ET.iterparse(path, events=("end",)):
        if e.get("id") is not None:
            texts[e.get("id")] = e.text if e.tag in ("start-time", "duration") else (e.get("fmt") or "")
        if e.tag != "row":
            continue
        c = list(e)
        v = lambda x: texts.get(x.get("ref")) if x.get("ref") else (x.text if x.tag in ("start-time", "duration") else x.get("fmt") or "")
        process = v(c[10])
        if process.startswith("python"):
            label = v(c[6]).split("   (")[0].split(":", 1)[-1].strip()
            start = int(v(c[0]))/1e3
            kicks.append((start, start+int(v(c[1]))/1e3, process, label, v(c[15])))
        e.clear()
    return sorted(kicks)


def union(kicks, lo, hi):
    busy, gaps, covered = 0.0, [], lo
    for start, end, *_ in kicks:
        if end <= lo or start >= hi:
            continue
        start, end = max(start, lo), min(end, hi)
        if start > covered:
            gaps.append(start-covered)
        busy += max(0.0, end-max(start, covered))
        covered = max(covered, end)
    if hi > covered:
        gaps.append(hi-covered)
    return busy, gaps


def case_report(root, case, rec):
    kicks = load(f"{root}/{case}-gpu-intervals.xml")
    t0, covered = None, None
    for start, end, *_ in kicks:
        if covered is not None and start-covered >= WINDOW_GAP_US:
            t0 = start
        covered = end if covered is None else max(covered, end)
    base = t0 - min(rec["began"])*1e6
    lo, hi = base+max(rec["began"])*1e6, base+min(rec["ended"])*1e6
    steps = [ns*(e-b)/86400/STEP_NS for ns, b, e in zip(rec["per_process"], rec["began"], rec["ended"])]
    common_s = (hi-lo)/1e6
    common_steps = sum(ns*common_s/86400/STEP_NS for ns in rec["per_process"])
    busy, gaps = union(kicks, lo, hi)
    print(f"== {case}: {rec['platform']} N={rec['n']}, total {rec['total_ns_day']:.1f} ns/day, "
          f"window {common_s:.3f} s common, {common_steps:.0f} steps in it (all processes)")
    print(f"busy {busy/1e3:.1f} ms of {common_s*1e3:.1f} ({busy/(hi-lo):.1%}), "
          f"{busy/common_steps:.2f} us per step (summed over processes)")
    counts = collections.Counter(sum(g >= edge for edge in GAP_EDGES_US) for g in gaps)
    bins = ["<2", "2-10", "10-50", "50-200", "200-1000", ">=1000"]
    print(f"idle gaps: {len(gaps)}, total {sum(gaps)/1e3:.2f} ms, median {statistics.median(gaps) if gaps else 0:.2f} us; "
          + ", ".join(f"{bins[k]} us {counts[k]} ({sum(g for g in gaps if sum(g >= e for e in GAP_EDGES_US) == k)/1e3:.2f} ms)"
                      for k in range(len(bins)) if counts[k]))
    inside = [k for k in kicks if lo <= k[0] < hi]
    per_proc = collections.defaultdict(set)
    for k in inside:
        per_proc[k[2]].add(k[4])
    buffers = sum(len(b) for b in per_proc.values())
    print(f"command buffers: {buffers} over {len(per_proc)} processes, {buffers/common_steps:.2f} per step; "
          f"per process {', '.join(str(len(b)) for b in per_proc.values())}; per-process steps in agg.jsonl "
          f"{', '.join(f'{s:.0f}' for s in steps)}")
    by_label = collections.defaultdict(list)
    for start, end, _, label, _ in inside:
        by_label[label].append(end-start)
    return {label: (len(d), statistics.median(d)) for label, d in by_label.items()}, common_steps


root = sys.argv[1]
records = {json.loads(line)["case"]: json.loads(line) for line in open(f"{root}/agg/agg.jsonl")}
labels = {}
for case in sys.argv[2:]:
    labels[case], steps = case_report(root, case, records[case])
    print("kick labels (count per step, median us):")
    for label, (n, med) in sorted(labels[case].items(), key=lambda x: -x[1][0])[:8]:
        print(f"  {label[:60]:60s} {n/steps:5.2f} {med:8.2f}")

"""Distance to 2x per test: night wall numbers against the Metal kernel census, single and mixed.

usage: python distance.py            (prints the markdown table used in research/distance-to-2x.md)
Wall: Window 2 (028 FINAL-REPORT, 7484d7bef, dedicated night window, 3x30 s, benchmark.py host clock) gives OpenCL
single and int028 Metal. r1 (8ae6cf17b) Metal = int028 W2 x the paired 3x30 s candidate/int028 ratio of the round 1
MAX_BITS confirmation (lanes/results/nonbonded/report.md, pre-repair table: r1 kept MAX_BITS 0 for single PME, as
listcheck shows). Step us = 345600 / (ns/day), 4 fs; prof.py's own us/step on the Metal census runs agrees within 1%.
Census: GPU us per step by kernel family from the r1 shader timeline (ultra-r2-mixed/census, stmv single from m0),
same grouping as m0/census.py. Busy = census GPU sum / night wall step. The sampled timeline undercounts atomic-heavy
kernels (round3-plan), so busy is a floor and "other" (wall minus GPU sum) holds launch gaps plus unsampled time.
"""
import bisect
import collections
import os
import xml.etree.ElementTree as ET

OPENCL = {"gbsa": 1136.41, "rf": 648.93, "pme": 520.96, "amber20-dhfr": 562.00, "apoa1rf": 280.59,
          "apoa1pme": 181.00, "apoa1ljpme": 127.12, "amber20-cellulose": 48.05, "amber20-stmv": 18.59}
INT028 = {"gbsa": (1592.43, 1235.30), "rf": (1211.09, 1017.97), "pme": (893.68, 780.29),
          "amber20-dhfr": (936.64, 802.97), "apoa1rf": (413.08, 357.99), "apoa1pme": (301.83, 270.13),
          "apoa1ljpme": (240.74, 218.48), "amber20-cellulose": (82.04, 74.57), "amber20-stmv": (30.28, 27.74)}
R1_OVER_INT028 = {"gbsa": (0.9993, 0.9996), "rf": (1.1881, 1.1529), "pme": (1.0899, 1.0774),
                  "amber20-dhfr": (1.0854, 1.0793), "apoa1rf": (1.1040, 1.0808), "apoa1pme": (1.0158, 1.0164),
                  "apoa1ljpme": (1.0003, 1.0046), "amber20-cellulose": (0.9990, 1.0001),
                  "amber20-stmv": (0.9987, 0.9978)}
MIXED = "/tmp/openmm-metal-bench/ultra-r2-mixed/census"
M0 = "/tmp/openmm-metal-bench/ultra-infra/m0"
TOOLS = "/tmp/openmm-metal-bench/ultra-tools"

source = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "census.py")).read()
census = {"__name__": "census_lib"}
exec(source[:source.index("names = ")].replace("out = sys.argv[1]\n", ""), census)


def md_steps_only(path, pid):
    """Per-kernel us per MD step. A step is the span from one integrateLangevinMiddleFused row to the next; spans
    over 10x the median gap (minimizer, prof.py's force-only evaluations between windows, setup) are dropped, so
    minimizer and getState evaluations never count as steps. Steps = max(kept spans, computeNonbonded rows in
    them), which covers a sampled-out integrate row that merges two steps into one span."""
    texts, rows = {}, []
    for _, e in ET.iterparse(path, events=("end",)):
        if e.get("id") is not None:
            texts[e.get("id")] = e.text if e.tag in ("start-time", "duration") else (e.get("fmt") or e.text or "")
        if e.tag == "row":
            c = list(e)
            v = lambda x: texts.get(x.get("ref")) if x.get("ref") else (x.text if x.tag in ("start-time", "duration") else x.get("fmt") or x.text or "")
            if f"({pid})" in v(c[11]):
                rows.append((int(v(c[0])), v(c[2]).rsplit(" (", 1)[0], int(v(c[1])) / 1e3))
            e.clear()
    ints = sorted(t for t, name, _ in rows if name == "integrateLangevinMiddleFused")
    gaps = [b - a for a, b in zip(ints, ints[1:])]
    limit = 10 * sorted(gaps)[len(gaps) // 2]
    kept = [False] + [g < limit for g in gaps]
    total, count = collections.defaultdict(float), collections.Counter()
    for t, name, us in rows:
        i = bisect.bisect_left(ints, t)
        if i < len(ints) and kept[i]:
            total[name] += us
            count[name] += 1
    steps = max(sum(kept), count["computeNonbonded"])
    return {k: v / steps for k, v in total.items()}, count, steps


def families(xml, pidfile):
    us, count, steps = md_steps_only(xml, open(pidfile).read().strip())
    for k in ONCE_PER_STEP:
        if count[k] and count[k] < 0.9 * steps * max(1, round(count[k] / steps)):
            # The timeline dropped rows of a kernel that runs once per step (twice for LJPME's two grids): scale its
            # mean sampled duration up to the step count and say so in the table.
            calls = max(1, round(count[k] / steps)) * steps
            print(f"<!-- {os.path.basename(xml)}: {k} sampled {count[k]} of {calls} calls, scaled up -->")
            us[k] *= calls / count[k]
    fam = collections.defaultdict(float)
    for kernel, value in us.items():
        f = census["family"](kernel)
        if f:
            fam[f] += value
    return fam


def trace(test, precision):
    if test == "amber20-stmv":
        return (f"{M0}/ocl/amber20-stmv-metal-intervals.xml", f"{M0}/ocl/amber20-stmv-metal.pypid") \
            if precision == "single" else None
    return f"{MIXED}/{test}-{precision}-intervals.xml", f"{MIXED}/{test}-{precision}.pypid"


ONCE_PER_STEP = ["computeNonbonded", "gridSpreadCharge", "gridInterpolateForce", "computeBondedForces",
                 "findBlocksWithInteractions"]
NAMES = ["nonbonded", "list", "PME", "bonded", "GB", "integration"]
print("| Test | Prec | OpenCL us | Metal us | 2x us | Gap us (cut) | GPU sum | Busy | Families, us (share of the gap each would need to cut alone) |")
print("|---|---|---:|---:|---:|---|---:|---:|---|")
for test in OPENCL:
    for i, precision in enumerate(("single", "mixed")):
        ocl = 345600 / OPENCL[test]
        metal = 345600 / (INT028[test][i] * R1_OVER_INT028[test][i])
        target = ocl / 2
        gap = metal - target
        gap_text = "met" if gap <= 0 else f"{gap:.0f} ({gap / metal:.1%})"
        t = trace(test, precision)
        if not t or not os.path.exists(t[0]):
            print(f"| {test} | {precision} | {ocl:.1f} | {metal:.1f} | {target:.1f} | {gap_text} | | | no census |")
            continue
        fam = families(*t)
        gpu = sum(fam.values())
        parts = []
        for name in sorted(NAMES, key=lambda n: -fam[n]):
            if fam[name] < 1:
                continue
            need = f"{gap / fam[name]:.0%}" if gap > 0 else "-"
            parts.append(f"{name} {fam[name]:.0f} ({need})")
        other = metal - gpu
        parts.append(f"other {other:.0f} ({gap / other:.0%})" if gap > 0 and other > 0 else f"other {other:.0f}")
        print(f"| {test} | {precision} | {ocl:.1f} | {metal:.1f} | {target:.1f} | {gap_text} | {gpu:.0f} | "
              f"{gpu / metal:.2f} | {', '.join(parts)} |")

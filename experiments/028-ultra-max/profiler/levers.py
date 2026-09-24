"""Category shares and lever estimates for Metal single, from summarize.py json lines.

usage: python levers.py <single counters dir> <single buffers dir> [<dir with amber20-dhfr-single-buffers.sum>]
Kernel times are attributed counters-mode times scaled to the buffers-mode (production) GPU busy time, so they
add up to what an unrecorded step spends on the GPU. Wall time is the median of the four unrecorded windows
(A and C of the buffers and counters runs). A lever that removes t us/step moves Metal/OpenCL from r to
r*wall/(wall-t). OpenCL single ns/day is experiment 018's M3 Ultra run (same machine, older build; 028's fresh
stmv OpenCL run gave 18.55 against 018's 18.6).
"""
import collections
import json
import os
import statistics
import sys

TESTS = ["gbsa", "rf", "pme", "apoa1rf", "apoa1pme", "apoa1ljpme", "amber20-dhfr", "amber20-cellulose", "amber20-stmv"]
OPENCL = {"gbsa": 1169.3, "rf": 664.7, "pme": 518.0, "apoa1rf": 279.6, "apoa1pme": 180.6, "apoa1ljpme": 127.0,
          "amber20-dhfr": 563.1, "amber20-cellulose": 47.7, "amber20-stmv": 18.6}
NS_DAY_US = 0.004*86400e-3*1e6  # ns/day times us/step at a 4 fs step
CATEGORIES = {
    "nonbonded": ["computeNonbonded"],
    "nlist": ["findBlocksWithInteractions", "findBlockBounds", "sortBoxData", "computeSortKeys", "copyInteractionCounts"],
    "shortsort": ["sortShortList2", "sortShortList"],
    "range": ["computeRange"],
    "bucketsort": ["sortBuckets", "assignElementsToBuckets", "assignElementsToBuckets2", "copyDataToBuckets",
                   "computeBucketPositions", "findAtomGridIndex"],
    "spread": ["gridSpreadCharge", "finishSpreadCharge"],
    "fft+conv+interp": ["vkFFTforward", "vkFFTbackward", "reciprocalConvolution", "gridInterpolateForce", "gridEvaluateEnergy"],
    "bonded": ["computeBondedForces"],
    "gb": ["computeBornSum", "computeGBSAForce1", "reduceBornSum", "reduceBornForce"],
}
# us/step each lever removes, from kernel times k (by name), the step's gap and the overlap ceiling.
LEVERS = {
    "L1 spread 2x": lambda k, gap, overlap: 0.5*(k["gridSpreadCharge"]+k["finishSpreadCharge"]),
    "L2 findBlocks 2x": lambda k, gap, overlap: 0.5*k["findBlocksWithInteractions"],
    "L3 host gap closed": lambda k, gap, overlap: gap,
    "L4 short sort 48->8 us": lambda k, gap, overlap: k["sortShortList2"]*(1-8/48),
    "L5 parallel computeRange": lambda k, gap, overlap: 0.9*k["computeRange"],
    "L6 bucket sort 2x": lambda k, gap, overlap: 0.5*sum(k[x] for x in CATEGORIES["bucketsort"]),
    "L7 bonded 2x": lambda k, gap, overlap: 0.5*k["computeBondedForces"],
    "L8 encoder overlap": lambda k, gap, overlap: overlap,
    "L9 nonbonded 10%": lambda k, gap, overlap: 0.1*k["computeNonbonded"],
}
COMBINED = ["L1 spread 2x", "L2 findBlocks 2x", "L3 host gap closed", "L4 short sort 48->8 us", "L5 parallel computeRange",
            "L6 bucket sort 2x"]

def load(directory, test, mode):
    path = os.path.join(directory, f"{test}-single-{mode}.sum")
    if not os.path.exists(path):
        return None
    for line in open(path):
        if line.startswith("json "):
            return json.loads(line[5:])
    return None

counters, buffers = sys.argv[1], sys.argv[2]
extra = sys.argv[3] if len(sys.argv) > 3 else buffers
shares, levers = [], []
for test in TESTS:
    c = load(counters, test, "counters")
    b = load(buffers, test, "buffers")
    if b is None or "busy_us" not in b:
        b = load(extra, test, "buffers")
    wall = statistics.median(b["unprofiled_us"]+c["unprofiled_us"])
    scale = b["busy_us"]/c["kernel_union_us"]
    k = collections.defaultdict(float)
    for name, v in c["kernels"].items():
        k[name.rsplit(" ", 1)[0]] += v["attr"]*scale
    gap = max(0.0, b["gap_us"])
    overlap = max(0.0, b["busy_us"]-c["kernel_union_us"])
    used = 0.0
    row = []
    for names in CATEGORIES.values():
        t = sum(k[x] for x in names)
        used += t
        row.append(f"{t/wall:.0%}")
    shares.append(f"| {test} | {wall:.0f} | " + " | ".join(row) + f" | {(b['busy_us']-used)/wall:.0%} | {gap/wall:.0%} |")
    ratio = NS_DAY_US/wall/OPENCL[test]
    cells, combined = [], 0.0
    for name, lever in LEVERS.items():
        t = lever(k, gap, overlap)
        cells.append(f"{t/wall:.0%} {ratio*wall/(wall-t):.2f}")
        if name in COMBINED:
            combined += t
    levers.append(f"| {test} | {ratio:.2f} | " + " | ".join(cells) + f" | {combined/wall:.0%} {ratio*wall/(wall-combined):.2f} |")
print("| Test | Wall us | " + " | ".join(CATEGORIES) + " | Other | Gap |")
print("|---|---:|" + "---:|"*(len(CATEGORIES)+2))
print("\n".join(shares))
print()
print("| Test | Now | " + " | ".join(LEVERS) + " | L1-L6 together |")
print("|---|---:|" + "---:|"*(len(LEVERS)+1))
print("\n".join(levers))

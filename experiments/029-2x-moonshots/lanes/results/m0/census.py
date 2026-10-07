"""M0(1) table: Metal against OpenCL GPU us per step by kernel family, single, from shader-timeline exports.

Metal: r2-mixed's census of ultra-r1 (ultra-r2-mixed/census/<test>-single-intervals.xml), stmv from ours
(m0/ocl/amber20-stmv-metal). OpenCL: m0/ocl/<test>-opencl-intervals.xml. Per kernel, kernsum.py's rule:
sampled span summed over the traced pid, divided by the computeNonbonded count (one per step). One-time and
minimizer kernels are left out of the step totals. Writes <out>/<test>.kern (kernsum, a = Metal, b = OpenCL)
and prints the family table. "host" is the traced run's last window us/step (day-provisional, xctrace running) and
"busy" the sampled GPU sum over it.
usage: python census.py <out dir>
"""
import collections
import os
import subprocess
import sys

out = sys.argv[1]
TOOLS = "/tmp/openmm-metal-bench/ultra-tools"
MIXED = "/tmp/openmm-metal-bench/ultra-r2-mixed/census"
OCL = "/tmp/openmm-metal-bench/ultra-infra/m0/ocl"
TESTS = ["gbsa", "rf", "pme", "amber20-dhfr", "apoa1rf", "apoa1pme", "apoa1ljpme", "amber20-cellulose", "amber20-stmv"]
FAMILIES = [
    ("nonbonded", lambda k: k == "computeNonbonded"),
    ("list", lambda k: k in ("findBlockBounds", "findBlocksWithInteractions", "sortBoxData", "computeSortKeys",
                             "copyInteractionCounts") or k.startswith("sort") or k.endswith("ShortList")
     or k.endswith("Buckets") or k.endswith("Buckets2") or k in ("computeBucketPositions", "computeRange")),
    ("PME", lambda k: k.startswith("grid") or "FFT" in k or k in ("reciprocalConvolution", "finishSpreadCharge",
                                                                  "findAtomGridIndex")
     or k.startswith("pack") or k.startswith("unpack")),
    ("bonded", lambda k: k == "computeBondedForces"),
    ("GB", lambda k: k in ("computeBornSum", "reduceBornSum", "computeGBSAForce1", "reduceBornForce")),
    ("integration", lambda k: k.startswith("integrate") or k.startswith("applySettle") or k.startswith("applyShake")
     or k.startswith("applyCCMA") or "CCMA" in k or k in ("applyPositionDeltas", "generateRandomNumbers",
     "calcCenterOfMassMomentum", "removeCenterOfMassMomentum", "computeKineticEnergy")),
]
SKIP = {"lineSearchContinue", "lineSearchDot", "lineSearchSetup", "lineSearchStep", "getDiff", "getScale", "gradNorm",
        "initializeDir", "reinitializeDir", "restorePos", "scaleDir", "updateDirAlpha", "updateDirBeta", "updateDirFinal",
        "recordInitialPos", "getConstraintEnergyForces", "getConstraintError", "computeParameters",
        "computeExclusionParameters"}


def family(kernel):
    if kernel in SKIP:
        return None
    for name, match in FAMILIES:
        if match(kernel):
            return name
    return "other"


def host_us(txt):
    lines = [l for l in open(txt) if l.startswith("window ")]
    return float(lines[-1].split("us_per_step ")[1].split()[0]) if lines else 0.0


def pid(path):
    return open(path).read().strip()


source = open(os.path.join(TOOLS, "kernsum.py")).read()
kernsum = {}
exec(source[:source.index("per_step = ")], kernsum)  # load() only, not kernsum's command line


def per_step(xml, p):
    total, count = kernsum["load"](xml, p)
    steps = count["computeNonbonded"]
    return {k: v/steps for k, v in total.items()}, steps


names = [n for n, _ in FAMILIES] + ["other"]
print(f"{'test':18} {'':7} " + " ".join(f"{n:>11}" for n in names) + f" {'total':>9} {'host':>8} {'busy':>5}")
for test in TESTS:
    metal = (f"{OCL}/{test}-metal-intervals.xml", f"{OCL}/{test}-metal.pypid") if test == "amber20-stmv" \
        else (f"{MIXED}/{test}-single-intervals.xml", f"{MIXED}/{test}-single.pypid")
    ocl = (f"{OCL}/{test}-opencl-intervals.xml", f"{OCL}/{test}-opencl.pypid")
    if not all(os.path.exists(p) for p in metal + ocl):
        print(f"{test:18} missing traces")
        continue
    with open(os.path.join(out, f"{test}.kern"), "w") as f:
        subprocess.run([sys.executable, os.path.join(TOOLS, "kernsum.py"), metal[0], pid(metal[1]), ocl[0], pid(ocl[1])],
                       stdout=f, check=True)
    sums = []
    for xml, pidfile in (metal, ocl):
        us, steps = per_step(xml, pid(pidfile))
        fam = collections.defaultdict(float)
        for k, v in us.items():
            f = family(k)
            if f:
                fam[f] += v
        sums.append((fam, steps))
    for label, (fam, steps), xml in zip(("Metal", "OpenCL"), sums, (metal[0], ocl[0])):
        host = host_us(xml.replace("-intervals.xml", ".txt"))
        print(f"{test:18} {label:7} " + " ".join(f"{fam[n]:11.1f}" for n in names) + f" {sum(fam.values()):9.1f}"
              + f" {host:8.1f} {sum(fam.values())/host if host else 0:5.2f}")
    (m, _), (o, _) = sums
    print(f"{test:18} {'O/M':7} " + " ".join(f"{(o[n]/m[n] if m[n] else 0):11.2f}" for n in names)
          + f" {sum(o.values())/sum(m.values()):9.2f}")

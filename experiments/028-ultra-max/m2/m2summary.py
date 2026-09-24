"""One summary table per candidate for one m2check.sh outdir: each candidate against base on the M2.

usage: python m2summary.py <outdir>
Per test and precision: median ns/day of base and candidate (benchmark.py's host clock), the ratio of
medians with the lowest and highest single-round ratio, and the median peak memory footprint of each
(from /usr/bin/time -l) with the candidate's delta. Flags:
  SLOWER  median ratio below SPEED_FLAG and every round's ratio below 1
  GROWTH  footprint delta above FOOTPRINT_FLAG_MB and above FOOTPRINT_FLAG_PCT percent
The gate verdict comes from gate-<label>.txt (forces.py against base/forces.txt).
"""
import glob
import json
import os
import re
import statistics
import sys

TESTS = ["gbsa", "rf", "pme", "apoa1rf", "apoa1pme", "apoa1ljpme", "amber20-dhfr", "amber20-cellulose"]
PRECISIONS = ["single", "mixed"]
SPEED_FLAG = 0.97
FOOTPRINT_FLAG_MB = 32
FOOTPRINT_FLAG_PCT = 3.0
MB = 1024*1024

if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
    sys.exit(__doc__)
out = sys.argv[1]
speed, footprint, rss = {}, {}, {}
for path in glob.glob(os.path.join(out, "*-round*.json")):
    m = re.match(r"(.+)-(single|mixed)-(.+)-round(\d+)\.json$", os.path.basename(path))
    who, precision, test, rnd = m.group(1), m.group(2), m.group(3), int(m.group(4))
    for result in json.load(open(path))["benchmarks"]:
        speed.setdefault((test, precision, who), {})[rnd] = result["ns_per_day"]
for path in glob.glob(os.path.join(out, "*-round*.time")):
    m = re.match(r"(.+)-(single|mixed)-(.+)-round(\d+)\.time$", os.path.basename(path))
    who, precision, test, rnd = m.group(1), m.group(2), m.group(3), int(m.group(4))
    text = open(path).read()
    f = re.search(r"(\d+)\s+peak memory footprint", text)
    r = re.search(r"(\d+)\s+maximum resident set size", text)
    if f:
        footprint.setdefault((test, precision, who), []).append(int(f.group(1))/MB)
    if r:
        rss.setdefault((test, precision, who), []).append(int(r.group(1))/MB)

configs = open(os.path.join(out, "configs.txt")).read().splitlines()
commits = {l.split()[0]: l.split("commit ")[1].split()[0] for l in configs if " commit " in l and not l.startswith(" ")}
labels = [l for l in commits if l != "base"]
print(f"M2 check {os.path.basename(out)}, base {commits.get('base', '?')[:12]}")
print("clock: benchmark.py host clock, datetime.now() around step(); ns/day and MB are medians of rounds")
print("MB = peak memory footprint, RSS = maximum resident set size, both from /usr/bin/time -l")
verdicts = []
for cand in labels:
    gate_path = os.path.join(out, f"gate-{cand}.txt")
    gate = open(gate_path).read().strip() if os.path.exists(gate_path) else "MISSING"
    print()
    print(f"{cand}: {commits[cand][:12]} against base, forces gate {gate}")
    header = (f"{'test':18} {'prec':6} {'base ns/d':>10} {'cand ns/d':>10} {'ratio':>6} {'rounds':>13} "
              f"{'base MB':>8} {'cand MB':>8} {'dMB':>6} {'d%':>6} {'base RSS':>8} {'cand RSS':>8}  flags")
    print(header)
    slower, growth, missing = [], [], []
    for test in TESTS:
        for precision in PRECISIONS:
            b, c = speed.get((test, precision, "base")), speed.get((test, precision, cand))
            if not b and not c:
                continue
            if not b or not c:
                missing.append(f"{test} {precision}")
                print(f"{test:18} {precision:6} missing results")
                continue
            bm, cm = statistics.median(b.values()), statistics.median(c.values())
            per_round = [c[r]/b[r] for r in c if r in b]
            ratio = cm/bm
            nan = [float("nan")]
            fb = statistics.median(footprint.get((test, precision, "base"), nan))
            fc = statistics.median(footprint.get((test, precision, cand), nan))
            rb = statistics.median(rss.get((test, precision, "base"), nan))
            rc = statistics.median(rss.get((test, precision, cand), nan))
            dmb = fc - fb
            dpct = 100*dmb/fb
            flags = []
            if ratio < SPEED_FLAG and max(per_round) < 1:
                flags.append("SLOWER")
                slower.append(f"{test} {precision} {ratio:.3f}")
            if dmb > FOOTPRINT_FLAG_MB and dpct > FOOTPRINT_FLAG_PCT:
                flags.append("GROWTH")
                growth.append(f"{test} {precision} +{dmb:.0f} MB")
            rounds = f"{min(per_round):.3f}..{max(per_round):.3f}"
            print(f"{test:18} {precision:6} {bm:10.2f} {cm:10.2f} {ratio:6.3f} {rounds:>13} "
                  f"{fb:8.0f} {fc:8.0f} {dmb:+6.0f} {dpct:+6.1f} {rb:8.0f} {rc:8.0f}  {' '.join(flags)}")
    verdict = "PASS" if gate == "PASS" and not slower and not growth and not missing else "FLAGGED"
    verdicts.append(f"verdict {cand} {commits[cand][:12]} {verdict}: gate {gate}; slower: {', '.join(slower) or 'none'}; "
                    f"footprint growth: {', '.join(growth) or 'none'}; missing: {', '.join(missing) or 'none'}")
print()
loads_path = os.path.join(out, "loads.txt")
if os.path.exists(loads_path):
    lines = open(loads_path).read().splitlines()
    loads = [float(m.group(1)) for l in lines if (m := re.search(r" load ([\d.]+)", l))]
    frees = [int(m.group(1)) for l in lines if (m := re.search(r" free (\d+)%", l))]
    builds = [l for l in lines if "BUILD RUNNING" in l]
    no_result = [l for l in lines if "NO RESULT" in l]
    if loads:
        print(f"1-minute load before {len(loads)} runs: {min(loads):.2f} to {max(loads):.2f}; memory free {min(frees)}% to {max(frees)}%")
    print(f"runs that started with a build running: {len(builds)}; runs with no result: {len(no_result)}")
print()
for line in verdicts:
    print(line)

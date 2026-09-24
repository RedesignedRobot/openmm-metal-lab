"""Medians, spreads and ratios of ns/day over the runs one ab.sh outdir holds.

usage: python3 summarize.py <outdir> [numerator/denominator ...]
Prints the median ns/day per test and configuration label, then each configuration's rounds with
their spread, (max-min)/median. Each numerator/denominator pair of labels adds a ratio of the two
medians per test, followed by the lowest and highest ratio within a single round, which shows how far
one interleaved round can move it. Runs that wrote no result, runs that overlapped a build, CPU
runs beside a busy process, the 1 minute load range and the Hyperscale VM's CPU come from loads.txt. A (round, test) that ab.sh
--rerun-builds ran again drops its earlier entries from both lists.
"""
import glob
import json
import os
import re
import statistics
import sys

TEST_ORDER = ["gbsa", "rf", "pme", "apoa1rf", "apoa1pme", "apoa1ljpme", "amber20-dhfr", "amber20-cellulose",
              "amber20-stmv", "amoebagk", "amoebapme"]

if len(sys.argv) < 2 or not os.path.isdir(sys.argv[1]):
    sys.exit(__doc__)
outdir = sys.argv[1]
pairs = [pair.split("/") for pair in sys.argv[2:]]

runs = {}
for path in glob.glob(os.path.join(outdir, "*-round*.json")):
    name = os.path.basename(path)
    round_number = int(re.search(r"-round(\d+)\.json$", name).group(1))
    for result in json.load(open(path))["benchmarks"]:
        label = name[:name.index("-" + result["test"] + "-round")]
        runs.setdefault((result["test"], label), {})[round_number] = result["ns_per_day"]
if not runs:
    sys.exit(f"no results in {outdir}")
tests = sorted({test for test, _ in runs}, key=lambda t: TEST_ORDER.index(t) if t in TEST_ORDER else 99)
labels = sorted({label for _, label in runs})
for num, den in pairs:
    for label in (num, den):
        if label not in labels:
            sys.exit(f"no label {label}; the labels are {', '.join(labels)}")
median = {key: statistics.median(values.values()) for key, values in runs.items()}

width = max(14, max(len(label) for label in labels) + 2)
print(f"median ns/day, host clock")
print(f"{'test':18}" + "".join(f"{label:>{width}}" for label in labels))
for test in tests:
    print(f"{test:18}" + "".join(f"{median[(test, l)]:{width}.2f}" if (test, l) in median else f"{'':>{width}}"
                                 for l in labels))
print()
for label in labels:
    print(f"rounds, {label}:")
    for test in tests:
        values = runs.get((test, label))
        if values:
            spread = (max(values.values()) - min(values.values()))/median[(test, label)]
            rounds = " ".join(f"{values[r]:.2f}" for r in sorted(values))
            print(f"  {test:18} {rounds}   spread {100*spread:.1f}%")
print()
if pairs:
    print(f"{'test':18}" + "".join(f"{num + '/' + den:>36}" for num, den in pairs))
    for test in tests:
        cells = []
        for num, den in pairs:
            a, b = runs.get((test, num)), runs.get((test, den))
            if not a or not b:
                cells.append(f"{'':>36}")
                continue
            per_round = [a[r]/b[r] for r in a if r in b]
            ratio = median[(test, num)]/median[(test, den)]
            cells.append(f"{ratio:8.3f} (rounds {min(per_round):.3f}..{max(per_round):.3f})".rjust(36))
        print(f"{test:18}" + "".join(cells))
    print()

loads_path = os.path.join(outdir, "loads.txt")
if os.path.exists(loads_path):
    lines = open(loads_path).read().splitlines()
    loads = [float(m.group(1)) for line in lines if (m := re.search(r" load \{ ([\d.]+)", line))]
    vm = [int(m.group(1)) for line in lines if (m := re.search(r" vm (\d+)%", line))]
    missing, builds, busy = [], [], []
    for line in lines:
        if m := re.search(r" rerun round (\d+) (\S+):", line):
            replaced = f" round {m.group(1)} {m.group(2)} "
            missing = [kept for kept in missing if replaced not in kept]
            builds = [kept for kept in builds if replaced not in kept]
            busy = [kept for kept in busy if replaced not in kept]
        elif "NO RESULT" in line:
            missing.append(line)
        elif "BUILD RUNNING" in line:
            builds.append(line)
        elif "CPU BUSY" in line:
            busy.append(line)
    if loads:
        print(f"1 minute load before {len(loads)} runs: {min(loads):.2f} to {max(loads):.2f}")
    if vm:
        print(f"Hyperscale VM CPU before {len(vm)} runs: {min(vm)}% to {max(vm)}%")
    print(f"runs with no result: {len(missing)}")
    for line in missing:
        print("  " + line)
    print(f"runs that overlapped a build: {len(builds)}")
    for line in builds:
        print("  " + line.split(" top ")[0])
    if busy:
        print(f"CPU runs beside a process over 100% CPU: {len(busy)}")
        for line in busy:
            print("  " + line)

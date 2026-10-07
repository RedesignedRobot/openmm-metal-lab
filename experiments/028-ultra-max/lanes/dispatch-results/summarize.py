"""Median ns/day per test and configuration over the runs ab.sh wrote, with ratios.

usage: python summarize.py <outdir> [numerator/denominator ...]
Prints one table of medians and rounds, then one ratio column per numerator/denominator pair
(configuration labels), each the ratio of the two medians for the same test.
"""
import glob
import json
import os
import re
import statistics
import sys

TEST_ORDER = ["gbsa", "rf", "pme", "apoa1rf", "apoa1pme", "apoa1ljpme", "amber20-dhfr", "amber20-cellulose", "amber20-stmv"]

runs = {}
for path in glob.glob(os.path.join(sys.argv[1], "*-round*.json")):
    name = os.path.basename(path)
    round_number = int(re.search(r"-round(\d+)\.json$", name).group(1))
    for result in json.load(open(path))["benchmarks"]:
        label = name[:name.index("-" + result["test"] + "-round")]
        runs.setdefault((result["test"], label), []).append((round_number, result["ns_per_day"]))
tests = sorted({test for test, _ in runs}, key=lambda t: TEST_ORDER.index(t) if t in TEST_ORDER else 99)
labels = sorted({label for _, label in runs})
median = {key: statistics.median(v for _, v in values) for key, values in runs.items()}

print(f"{'test':18}" + "".join(f"{label:>14}" for label in labels))
for test in tests:
    print(f"{test:18}" + "".join(f"{median[(test, l)]:14.2f}" if (test, l) in median else f"{'':>14}" for l in labels))
print()
for label in labels:
    print(f"rounds, {label}:")
    for test in tests:
        values = sorted(runs.get((test, label), []))
        if values:
            print(f"  {test:18} " + " ".join(f"{v:.2f}" for _, v in values))
print()
pairs = sys.argv[2:]
if pairs:
    print(f"{'test':18}" + "".join(f"{pair:>28}" for pair in pairs))
    for test in tests:
        cells = []
        for pair in pairs:
            num, den = pair.split("/")
            if (test, num) in median and (test, den) in median:
                cells.append(f"{median[(test, num)]/median[(test, den)]:28.3f}")
            else:
                cells.append(f"{'':>28}")
        print(f"{test:18}" + "".join(cells))

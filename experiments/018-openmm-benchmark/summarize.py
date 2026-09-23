"""Tabulate experiment 018: ns/day from benchmark.py's JSON outfiles, one table per chip.

usage: python3 summarize.py > results.md
Clock: benchmark.py's host wall clock, 60 s per test after its warm-up, one run per configuration.
A JSON file with an empty benchmark list is a failed run and is skipped; the amber20-dhfr reruns
live in the *-amber20dhfr directories.
"""
import glob
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
CHIPS = [("m2", "Apple M2 (10 GPU cores), Mac mini"),
         ("m3pro", "Apple M3 Pro (18 GPU cores), MacBook Pro"),
         ("m3ultra", "Apple M3 Ultra (60 GPU cores), Mac Studio")]
TESTS = ["gbsa", "rf", "pme", "apoa1rf", "apoa1pme", "apoa1ljpme",
         "amber20-dhfr", "amber20-cellulose", "amber20-stmv"]


def load(chip):
    rows = {}
    for path in glob.glob(f"{HERE}/results/results-{chip}-*/json/*.json"):
        runs = json.load(open(path))["benchmarks"]
        if runs:
            b = runs[0]
            rows.setdefault(b["test"], {})[(b["platform"], b["precision"])] = b["ns_per_day"]
    return rows


def main():
    print("# Experiment 018 results\n")
    print("ns/day from OpenMM's unmodified benchmark.py (f9347f6c5). Clock: benchmark.py's host wall "
          "clock, 60 s per test, one run per configuration. Ratios over OpenCL single; Apple's OpenCL "
          "has no mixed precision, so Metal mixed over OpenCL single is the comparison at "
          "Folding@home's precision.\n")
    for chip, name in CHIPS:
        rows = load(chip)
        print(f"## {name}\n")
        print("| Test | Metal single | Metal mixed | OpenCL single | CPU | Metal single / OpenCL | Metal mixed / OpenCL |")
        print("|---|---|---|---|---|---|---|")
        for test in TESTS:
            v = rows.get(test, {})
            ms, mm = v.get(("Metal", "single")), v.get(("Metal", "mixed"))
            ocl = v.get(("OpenCL", "single"))
            cpu = next((x for (p, _), x in v.items() if p == "CPU"), None)  # CPU reports its precision as mixed
            cell = lambda x: f"{x:.1f}" if x else "n/a"
            ratio = lambda x: f"{x / ocl:.2f}" if x and ocl else "n/a"
            print(f"| {test} | {cell(ms)} | {cell(mm)} | {cell(ocl)} | {cell(cpu)} | {ratio(ms)} | {ratio(mm)} |")
        print()


if __name__ == "__main__":
    main()

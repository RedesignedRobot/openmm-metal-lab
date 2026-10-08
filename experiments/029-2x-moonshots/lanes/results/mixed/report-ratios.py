"""Write a reviewable ratio table from the two interleaved screen directories."""
import json
import re
import statistics
from pathlib import Path

root = Path(__file__).resolve().parent
rows = []
for directory in (root / "screen-small", root / "screen-large"):
    measurements = {}
    for path in sorted(directory.glob("*-round*.json")):
        round_number = int(re.search(r"-round(\d+)\.json$", path.name)[1])
        for result in json.loads(path.read_text())["benchmarks"]:
            test = result["test"]
            label = path.name[:path.name.index("-" + test + "-round")]
            measurements.setdefault(test, {}).setdefault(label, {})[round_number] = result["ns_per_day"]
    for test, arms in measurements.items():
        required = {"baseS", "baseM", "mineS", "mineM", "opencl"}
        if required - arms.keys():
            raise SystemExit(f"Incomplete arms: {directory} {test}")
        rounds = {tuple(sorted(arms[label])) for label in required}
        if len(rounds) != 1 or len(next(iter(rounds))) < 2:
            raise SystemExit(f"Incomplete interleaving: {directory} {test}")
        median = {label: statistics.median(values.values()) for label, values in arms.items()}
        rows.append(dict(test=test, outdir=str(directory), medians=median,
                         single_over_single=median["mineS"]/median["baseS"],
                         mixed_over_mixed=median["mineM"]/median["baseM"],
                         mixed_over_single=median["mineM"]/median["baseS"],
                         mixed_over_opencl_single=median["mineM"]/median["opencl"]))
order = ["gbsa", "rf", "pme", "amber20-dhfr", "apoa1pme"]
if {row["test"] for row in rows} != set(order):
    raise SystemExit("Five-test screen is incomplete")
rows.sort(key=lambda row: order.index(row["test"]))
(root / "ratios.json").write_text(json.dumps(rows, indent=2) + "\n")
print("| Test | Single / baseline single | Mixed / baseline mixed | Mixed / baseline single | Mixed / OpenCL single | Raw ab.sh outdir |")
print("|---|---:|---:|---:|---:|---|")
for row in rows:
    ratios = [row[key] for key in ("single_over_single", "mixed_over_mixed", "mixed_over_single", "mixed_over_opencl_single")]
    print(f"| {row['test']} | " + " | ".join(f"{value:.3f}" for value in ratios) + f" | {row['outdir']} |")

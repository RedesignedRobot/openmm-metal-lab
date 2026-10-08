"""A/B of one FAH unit between two built trees, host clock, 3 rounds x 30 s (r3-fah). One gpuq timing job.
AB_ROUNDS and AB_SECONDS override the 3 and 30 (day screens run 2x15).

usage: python3 abwu.py <fresh out dir> <tree A> <tree B> <corpus dir> <wu> [configs, default mm,ms,os]
       python3 abwu.py --summary <out dir>

Every run is a fresh profwu.py process (PROF_SECONDS=30). Each round shuffles the (tree, config) arms with its own
seed. configs: mm Metal mixed, ms Metal single, os OpenCL single. The summary prints median us/step per arm and B/A
speed per config (A's median over B's: above 1 means B is faster).
"""
import json
import os
from pathlib import Path
import random
import statistics
import subprocess
import sys

HERE = Path(__file__).resolve().parent
CONFIGS = {"ms": ("Metal", "single"), "mm": ("Metal", "mixed"), "os": ("OpenCL", "single")}


def run(out, trees, corpus, wu, configs):
    assert os.getpriority(os.PRIO_PROCESS, 0) == 0, "timing needs nice 0"
    out.mkdir(parents=True)
    (out / "arms.json").write_text(json.dumps({"A": str(trees["A"]), "B": str(trees["B"]), "wu": wu}) + "\n")
    for r in range(1, int(os.environ.get("AB_ROUNDS", "3")) + 1):
        order = [(side, c) for side in trees for c in configs]
        random.Random(2950 + r).shuffle(order)
        for side, config in order:
            tree = trees[side]
            platform, precision = CONFIGS[config]
            env = dict(os.environ, PROF_SECONDS=os.environ.get("AB_SECONDS", "30"), PROF_OUT=str(out / f"{side}.jsonl"),
                       PYTHONPATH=f"{tree}/venv/lib/python3.13/site-packages:{tree}/pydeps")
            name = f"r{r}-{side}-{config}"
            with (out / f"{name}.log").open("w") as log:
                code = subprocess.call([f"{tree}/venv/bin/python", str(HERE / "profwu.py"), f"{corpus}/{wu}",
                                        precision, platform], env=env, stdout=log, stderr=subprocess.STDOUT, timeout=600)
            print(f"{name} exit {code} load {os.getloadavg()[0]:.2f}", flush=True)
    summary(out)


def summary(out):
    med = {}
    print("side config n median_us_per_step min max")
    for side in ("A", "B"):
        values = {}
        for line in (out / f"{side}.jsonl").read_text().splitlines():
            d = json.loads(line)
            config = {v: k for k, v in CONFIGS.items()}[(d["platform"], d["precision"])]
            values.setdefault(config, []).append(d["us_per_step"])
        for config, v in sorted(values.items()):
            med[side, config] = statistics.median(v)
            print(f"{side} {config} {len(v)} {med[side, config]:.2f} {min(v):.2f} {max(v):.2f}")
    print("config B/A speed")
    for config in sorted({c for _, c in med}):
        if ("A", config) in med and ("B", config) in med:
            print(f"{config} {med['A', config]/med['B', config]:.3f}")


if __name__ == "__main__":
    if sys.argv[1] == "--summary":
        summary(Path(sys.argv[2]))
    else:
        run(Path(sys.argv[1]), {"A": sys.argv[2], "B": sys.argv[3]}, sys.argv[4], sys.argv[5],
            sys.argv[6].split(",") if len(sys.argv) > 6 else ["mm", "ms", "os"])

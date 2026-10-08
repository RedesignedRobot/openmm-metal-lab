"""Night 3x30 host-clock timing of the FAH units and their ablation arms on the M3 Ultra (r3-fah), one gpuq timing job.

usage: python3 timebatch.py <fresh out dir> <build dir> <corpus dir>          (inside gpuq, nice 0)
       python3 timebatch.py --summary <out dir>

Every run is a fresh profwu.py process with PROF_SECONDS=30 (step(n) then getState(energy), host clock). Each round
shuffles all arms with its own seed, so no arm always runs first or after the same neighbour. Arms:
  base on Metal single, Metal mixed, OpenCL single for gbsa, tip3p-hmr, tip4pew, neq, pme45k, nav (FAHBench's
  project 9704 unit, 173112 atoms, from FoldingAtHome/fah-bench);
  gbsa obc (the CustomGB-to-GBSAOBC route's measured ceiling), tip3p-hmr nobaro and dt2, tip4pew and nav nobaro
  on Metal mixed and OpenCL single.
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
ARMS = [(wu, "", c) for wu in ("gbsa", "tip3p-hmr", "tip4pew", "neq", "pme45k", "nav") for c in ("ms", "mm", "os")]
ARMS += [(wu, v, c) for wu, v in (("gbsa", "obc"), ("tip3p-hmr", "nobaro"), ("tip3p-hmr", "dt2"), ("tip4pew", "nobaro"),
                                            ("nav", "nobaro"))
         for c in ("mm", "os")]


def run(out, tree, corpus):
    assert os.getpriority(os.PRIO_PROCESS, 0) == 0, "timing needs nice 0"
    out.mkdir()
    env = dict(os.environ, PROF_SECONDS="30", PROF_OUT=str(out / "runs.jsonl"),
               PYTHONPATH=f"{tree}/venv/lib/python3.13/site-packages:{tree}/pydeps")
    for r in (1, 2, 3):
        order = list(ARMS)
        random.Random(2930 + r).shuffle(order)
        for wu, variant, config in order:
            platform, precision = CONFIGS[config]
            name = f"r{r}-{config}-{wu}{'-' + variant if variant else ''}"
            command = [f"{tree}/venv/bin/python", str(HERE / "profwu.py"), f"{corpus}/{wu}", precision, platform]
            command += [variant] if variant else []
            with (out / f"{name}.log").open("w") as log:
                code = subprocess.call(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=600)
            print(f"{name} exit {code} load {os.getloadavg()[0]:.2f}", flush=True)
    summary(out)


def summary(out):
    values = {}
    for line in (out / "runs.jsonl").read_text().splitlines():
        d = json.loads(line)
        config = {v: k for k, v in CONFIGS.items()}[(d["platform"], d["precision"])]
        values.setdefault((d["wu"], "" if d["variant"] == "base" else d["variant"], config), []).append(d["us_per_step"])
    print("unit arm config n median_us_per_step min max")
    for key in sorted(values):
        v = values[key]
        print(f"{key[0]} {key[1] or 'base'} {key[2]} {len(v)} {statistics.median(v):.2f} {min(v):.2f} {max(v):.2f}")
    print("unit arm metal-single/opencl metal-mixed/opencl (median us/step ratios, OpenCL single same arm)")
    for wu, variant, _ in sorted({(w, v, 0) for w, v, _ in values}):
        o = values.get((wu, variant, "os"))
        if not o:
            continue
        cells = [f"{statistics.median(o)/statistics.median(values[(wu, variant, c)]):.3f}" if (wu, variant, c) in values
                 else "-" for c in ("ms", "mm")]
        print(f"{wu} {variant or 'base'} {' '.join(cells)}")


if __name__ == "__main__":
    if sys.argv[1] == "--summary":
        summary(Path(sys.argv[2]))
    else:
        run(Path(sys.argv[1]), sys.argv[2], sys.argv[3])

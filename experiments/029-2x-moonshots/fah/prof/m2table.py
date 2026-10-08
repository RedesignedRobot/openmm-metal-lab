"""M2 Metal/OpenCL table (r3-fah): the nine benchmark.py tests and the FAH corpus units, 3x30 s, host clock.

usage (on the M2, inside locked.py job.lock and m2-lease.sh, one call per round so other checks get the lock
between rounds):
    python m2table.py <tree> <out> round <1|2|3>
    python m2table.py <tree> <out> summary

Every run is a fresh process. Tests run as m2-denominator-run.py runs them: benchmark.py from base/benchmarks with
the tree's python. FAH units run through profwu.py (same host clock: step(n), then getState(energy)) with
PROF_SECONDS=30. Each round shuffles the three configurations per row with its own seed. The tree's dylib hashes are
pinned in round 1 and checked every round.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import random
import statistics
import subprocess
import sys

ROOT = Path("~/lab/ultra-m2.noindex").expanduser()
HERE = Path(__file__).resolve().parent
TESTS = ["gbsa", "rf", "pme", "apoa1rf", "apoa1pme", "apoa1ljpme", "amber20-dhfr", "amber20-cellulose", "amber20-stmv"]
UNITS = [("fah-gbsa", "gbsa", []), ("fah-gbsa-obc", "gbsa", ["obc"]), ("fah-tip3p-hmr", "tip3p-hmr", []),
         ("fah-tip4pew", "tip4pew", []), ("fah-neq", "neq", []), ("fah-pme45k", "pme45k", [])]
CONFIGS = {"metal-single": ("Metal", "single"), "metal-mixed": ("Metal", "mixed"), "opencl-single": ("OpenCL", "single")}


def libraries(tree):
    return {str(p.relative_to(tree)): hashlib.md5(p.read_bytes()).hexdigest()
            for p in sorted((tree / "prefix/lib").rglob("*.dylib"))}


def run_test(tree, out, name, test, platform, precision):
    command = ["/usr/bin/time", "-l", "-o", str(out / f"{name}.time"), str(tree / "venv/bin/python"), "benchmark.py",
               "--platform", platform, "--precision", precision, "--test", test, "--seconds", "30",
               "--style", "table", "--outfile", str(out / f"{name}.json")]
    with (out / f"{name}.log").open("w") as log:
        subprocess.run(command, cwd=ROOT / "base/benchmarks", stdout=log, stderr=subprocess.STDOUT, check=True,
                       timeout=1800)
    data = json.loads((out / f"{name}.json").read_text())["benchmarks"]
    assert len(data) == 1 and data[0]["ns_per_day"] > 0, f"NO RESULT: {name}"
    return data[0]["ns_per_day"]


def run_unit(tree, out, name, wu, variants, platform, precision):
    env = dict(os.environ, PROF_SECONDS="30", PROF_OUT=str(out / f"{name}.json"))
    command = ["/usr/bin/time", "-l", "-o", str(out / f"{name}.time"), str(tree / "venv/bin/python"),
               str(HERE / "profwu.py"), str(HERE / "corpus" / wu), precision, platform, *variants]
    with (out / f"{name}.log").open("w") as log:
        subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=1800)
    data = json.loads((out / f"{name}.json").read_text().strip().splitlines()[-1])
    assert data["finite"] and data["ns_per_day"] > 0, f"NO RESULT: {name}"
    return data["ns_per_day"]


def one_round(tree, out, r):
    assert os.getpriority(os.PRIO_PROCESS, 0) == 0
    meta_path = out / "configs.json"
    if r == 1:
        out.mkdir()
        built = (tree / "BUILT").read_text().splitlines()[0]
        meta_path.write_text(json.dumps({"tree": str(tree), "built": built, "clock": "host wall clock",
                                         "seconds": 30, "libraries": libraries(tree), "runs": []}, indent=2) + "\n")
    meta = json.loads(meta_path.read_text())
    assert libraries(tree) == meta["libraries"], "tree libraries changed between rounds"
    rng = random.Random(2900 + r)
    rows = [(t, t, None) for t in TESTS] + [(label, wu, variants) for label, wu, variants in UNITS]
    for row, what, variants in rows:
        order = list(CONFIGS)
        rng.shuffle(order)
        for config in order:
            name = f"{config}-{row}-round{r}"
            platform, precision = CONFIGS[config]
            if variants is None:
                speed = run_test(tree, out, name, what, platform, precision)
            else:
                speed = run_unit(tree, out, name, what, variants, platform, precision)
            meta["runs"].append({"name": name, "row": row, "config": config, "round": r, "ns_per_day": speed,
                                 "load": os.getloadavg(),
                                 "utc": datetime.datetime.now(datetime.timezone.utc).strftime("%H:%M:%SZ")})
            meta_path.write_text(json.dumps(meta, indent=2) + "\n")
            print(f"{name} {speed:.3f} ns/day", flush=True)


def summary(out):
    meta = json.loads((out / "configs.json").read_text())
    values = {}
    for run in meta["runs"]:
        values.setdefault((run["row"], run["config"]), []).append(run["ns_per_day"])
    lines = [f"M2 {meta['built']}, 3x30 s, host wall clock, medians in ns/day",
             "row metal-single metal-mixed opencl-single single/opencl mixed/opencl rounds"]
    for row in TESTS + [label for label, _, _ in UNITS]:
        med = {c: statistics.median(values[row, c]) for c in CONFIGS if values.get((row, c))}
        n = min(len(values.get((row, c), [])) for c in CONFIGS)
        if len(med) < 3:
            lines.append(f"{row} incomplete")
            continue
        lines.append(f"{row} {med['metal-single']:.3f} {med['metal-mixed']:.3f} {med['opencl-single']:.3f} "
                     f"{med['metal-single']/med['opencl-single']:.3f} {med['metal-mixed']/med['opencl-single']:.3f} {n}")
    (out / "summary.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


def main():
    tree, out, what = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    if what == "round":
        one_round(tree, out, int(sys.argv[4]))
    else:
        summary(out)


if __name__ == "__main__":
    main()

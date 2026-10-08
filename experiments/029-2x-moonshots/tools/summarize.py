"""Medians, spreads and ratios of ns/day over the runs one ab.sh outdir holds.

usage: python3 summarize.py <outdir> [numerator/denominator ...]
Prints the median ns/day per test and configuration label, then each configuration's rounds with
their spread, (max-min)/median. Each numerator/denominator pair of labels adds a ratio of the two
medians per test, followed by the lowest and highest ratio within a single round, which shows how far
one interleaved round can move it. Runs that wrote no result, runs that overlapped a build, runs that
started with another process on the GPU (FOREIGN GPU), CPU runs beside a busy process, the 1 minute load range and the background VM's CPU come from loads.txt.
Power comes from gpuclock.py's 1 s samples (GPUCLOCK_LOG, default ultra-lead/gpuclock.log; dated samples only, so
from 2026-09-28 23:30Z): a run's samples are those tagged with its tree, platform, precision and test between its
loads.txt line and the next run's, and its watts are the mean over busy seconds (GPU active >= 90%, as gpuclock.py
counts them) of GPU power and package (CPU + GPU + ANE) power. Per test and label it prints the median watts over
rounds and ns/day per GPU watt (median ns/day over median GPU watts), and each pair's ratio of that efficiency. A (round, test) that ab.sh
--rerun-builds ran again drops its earlier entries from both lists.
It also writes <outdir>/result.json with the same numbers for scoreboard.py: each arm's tree, commit and src
hash (configs.txt), every row's rounds, median and spread, the ratios, power, the hygiene flags (no result,
build overlap, FOREIGN GPU, CPU busy, Background VM at VM_HIGH_PERCENT or more), the slot (night when every run
started 00:00-07:00 UTC, day when none did, else mixed) and the gpuq job id (GPUQ_JOB, or the gpuq job whose
command names this outdir or, for window.sh's ab/ and cpu/, its parent).
"""
import datetime
import glob
import json
import os
import re
import sqlite3
import statistics
import sys

GPUQ_DB = os.environ.get("GPUQ_DB", "/tmp/openmm-metal-bench/gpuq/state.db")
VM_HIGH_PERCENT = 90
NIGHT_HOURS = range(0, 7)

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
result = {"outdir": os.path.abspath(outdir), "clock": "benchmark.py host wall time, datetime.now() around step()",
          "rows": [{"test": test, "label": label, "median": median[(test, label)],
                    "rounds": {str(r): v for r, v in sorted(runs[(test, label)].items())},
                    "spread": (max(runs[(test, label)].values()) - min(runs[(test, label)].values()))
                    / median[(test, label)]}
                   for test in tests for label in labels if (test, label) in runs],
          "ratios": [], "power": [], "hygiene": {}}

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
            result["ratios"].append({"test": test, "num": num, "den": den, "ratio": ratio,
                                     "round_min": min(per_round), "round_max": max(per_round)})
            cells.append(f"{ratio:8.3f} (rounds {min(per_round):.3f}..{max(per_round):.3f})".rjust(36))
        print(f"{test:18}" + "".join(cells))
    print()

loads_path = os.path.join(outdir, "loads.txt")
if os.path.exists(loads_path):
    lines = open(loads_path).read().splitlines()
    loads = [float(m.group(1)) for line in lines if (m := re.search(r" load \{ ([\d.]+)", line))]
    vm = [int(m.group(1)) for line in lines if (m := re.search(r" vm (\d+)%", line))]
    missing, builds, foreign, busy = [], [], [], []
    for line in lines:
        if m := re.search(r" rerun round (\d+) (\S+):", line):
            replaced = f" round {m.group(1)} {m.group(2)} "
            missing = [kept for kept in missing if replaced not in kept]
            builds = [kept for kept in builds if replaced not in kept]
            foreign = [kept for kept in foreign if replaced not in kept]
            busy = [kept for kept in busy if replaced not in kept]
        elif "NO RESULT" in line:
            missing.append(line)
        elif "BUILD RUNNING" in line or "FOREIGN GPU" in line:
            if "BUILD RUNNING" in line:
                builds.append(line)
            if "FOREIGN GPU" in line:
                foreign.append(line)
        elif "CPU BUSY" in line:
            busy.append(line)
    vm_high = [line.split(" top ")[0] for line in lines
               if (m := re.search(r" vm (\d+)%", line)) and int(m.group(1)) >= VM_HIGH_PERCENT]
    starts = [m.group(1) for line in lines if (m := re.match(r"(\S+Z) round \d+ \S+ \S+ load ", line))]
    night = [datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").hour in NIGHT_HOURS for s in starts]
    result["slot"] = "night" if night and all(night) else "day" if not any(night) else "mixed"
    result["first_run"], result["last_run"] = (starts[0], starts[-1]) if starts else (None, None)
    result["hygiene"] = {"runs": len(loads), "load": [min(loads), max(loads)] if loads else None,
                         "vm_cpu": [min(vm), max(vm)] if vm else None,
                         "no_result": missing, "build_overlap": [line.split(" top ")[0] for line in builds],
                         "foreign_gpu": [line.split(" top ")[0] for line in foreign], "cpu_busy": busy,
                         "vm_high": vm_high}
    if loads:
        print(f"1 minute load before {len(loads)} runs: {min(loads):.2f} to {max(loads):.2f}")
    if vm:
        print(f"Background VM CPU before {len(vm)} runs: {min(vm)}% to {max(vm)}%")
    print(f"runs with no result: {len(missing)}")
    for line in missing:
        print("  " + line)
    print(f"runs that overlapped a build: {len(builds)}")
    for line in builds:
        print("  " + line.split(" top ")[0])
    print(f"runs that started with another process on the GPU: {len(foreign)}")
    for line in foreign:
        print("  " + line.split(" top ")[0])
    if busy:
        print(f"CPU runs beside a process over 100% CPU: {len(busy)}")
        for line in busy:
            print("  " + line)


def power_rows():
    """{(test, label): {round: (GPU W, package W)}} from gpuclock.py's dated samples."""
    configs_path = os.path.join(outdir, "configs.txt")
    clock_path = os.environ.get("GPUCLOCK_LOG", "/tmp/openmm-metal-bench/ultra-lead/gpuclock.log")
    if not (os.path.exists(configs_path) and os.path.exists(clock_path)):
        return {}
    # configs.txt: <label> <platform> <precision> settings=... /tmp/openmm-metal-bench/<tree>/venv/...
    trees = {}
    for line in open(configs_path):
        f = line.split()
        if len(f) >= 5 and (m := re.search(r"/openmm-metal-bench/([^/]+)/venv/", line)):
            trees[f[0]] = f"{m.group(1).removeprefix('ultra-')}:{f[1]}:{f[2]}"
    stamp = "%Y-%m-%dT%H:%M:%SZ"
    starts = []  # (time, round, test, label); a rerun's later line wins
    for line in open(loads_path):
        if m := re.match(r"(\S+Z) round (\d+) (\S+) (\S+) load ", line):
            starts.append((m.group(1), int(m.group(2)), m.group(3), m.group(4)))
    starts.sort()
    if not starts:
        return {}
    first = starts[0][0]
    last = (datetime.datetime.strptime(starts[-1][0], stamp) + datetime.timedelta(minutes=15)).strftime(stamp)
    keys = {f"{tree}:{test}" for tree in trees.values() for _, _, test, _ in starts}
    samples = []  # (time, run, GPU mW, package mW), busy seconds only; ISO times sort as strings
    for line in open(clock_path, errors="replace"):
        if not (line[:4].isdigit() and first <= line[:20] <= last):
            continue
        m = re.match(r"(\S+) freq=\d+ active=(\d+) top=\d+ power=(\d+) pkg=(\d+) \S+ \S+ run=(\S+)", line)
        if m and m.group(5) in keys and float(m.group(2)) >= 90:
            samples.append((m.group(1), m.group(5), int(m.group(3)), int(m.group(4))))
    rows = {}
    for i, (when, rnd, test, label) in enumerate(starts):
        if label not in trees:
            continue
        end = starts[i + 1][0] if i + 1 < len(starts) else last
        mine = [(g, p) for t, run, g, p in samples if when <= t < end and run == f"{trees[label]}:{test}"]
        if mine:
            rows.setdefault((test, label), {})[rnd] = (statistics.mean(g for g, _ in mine) / 1000,
                                                       statistics.mean(p for _, p in mine) / 1000)
    return rows


power = power_rows() if os.path.exists(loads_path) else {}
if power:
    print()
    print("power, gpuclock.py busy seconds (GPU active >= 90%): median over rounds of GPU W and package"
          " (CPU + GPU + ANE) W")
    print(f"{'test':18}{'label':>{width}}{'GPU W':>9}{'pkg W':>9}{'ns/day/GPU W':>14}")
    efficiency = {}
    for test in tests:
        for label in labels:
            rounds = power.get((test, label))
            if not rounds or (test, label) not in median:
                continue
            gpu = statistics.median(g for g, _ in rounds.values())
            pkg = statistics.median(p for _, p in rounds.values())
            efficiency[(test, label)] = median[(test, label)] / gpu
            result["power"].append({"test": test, "label": label, "gpu_w": gpu, "pkg_w": pkg,
                                    "ns_per_day_per_gpu_w": efficiency[(test, label)]})
            print(f"{test:18}{label:>{width}}{gpu:9.1f}{pkg:9.1f}{efficiency[(test, label)]:14.2f}")
    if pairs:
        print()
        print(f"{'test':18}" + "".join(f"{num + '/' + den + ' ns/day per GPU W':>36}" for num, den in pairs))
        for test in tests:
            cells = [f"{efficiency[(test, num)] / efficiency[(test, den)]:36.3f}"
                     if (test, num) in efficiency and (test, den) in efficiency else f"{'':>36}" for num, den in pairs]
            print(f"{test:18}" + "".join(cells))


def arms():
    """{label: platform, precision, tree, commit, src, settings} from configs.txt."""
    path = os.path.join(outdir, "configs.txt")
    found = {}
    for line in open(path) if os.path.exists(path) else []:
        f = line.split()
        if len(f) < 4:
            continue
        tree = re.search(r"(\S+)/venv/", line)
        found[f[0]] = {"platform": f[1], "precision": f[2], "settings": f[3].removeprefix("settings="),
                       "tree": tree.group(1) if tree else None,
                       **{key: (m.group(1) if (m := re.search(rf" {key} (\S+)", line)) else None)
                          for key in ("commit", "src", "built")}}
    return found


def gpuq_job():
    """GPUQ_JOB when run inside the job, else the newest gpuq job whose command names this outdir."""
    if os.environ.get("GPUQ_JOB"):
        return int(os.environ["GPUQ_JOB"])
    here = os.path.abspath(outdir).rstrip("/")
    names = {here, os.path.realpath(here)}
    if os.path.basename(here) in ("ab", "cpu"):
        names |= {os.path.dirname(name) for name in names}
    bench, real = "/tmp/openmm-metal-bench", os.path.realpath("/tmp/openmm-metal-bench")
    names |= {name.replace(real, bench, 1) for name in names} | {name.replace(bench, real, 1) for name in names}
    pattern = re.compile("(" + "|".join(re.escape(n) for n in names) + r")(?=[\"/\s:']|$)")
    try:
        db = sqlite3.connect(f"file:{GPUQ_DB}?mode=ro", uri=True)
        rows = db.execute("SELECT id, argv FROM jobs ORDER BY id DESC").fetchall()
    except sqlite3.Error:
        return None
    return next((jid for jid, argv in rows if pattern.search(argv or "")), None)


result.setdefault("slot", None)
result["arms"] = arms()
result["gpuq_job"] = gpuq_job()
result["written"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(os.path.join(outdir, "result.json.new"), "w") as f:
    json.dump(result, f, indent=1)
os.replace(os.path.join(outdir, "result.json.new"), os.path.join(outdir, "result.json"))

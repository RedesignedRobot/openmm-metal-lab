"""The holdout timing and forces check, run by holdout.sh inside one timing hold. Head only.

For each item of the frozen set (build.py, MANIFEST.sha256), every configuration gets its own worker
process, started from its tree's python: Metal at each of the item's precisions and OpenCL single, for the
baseline tree and the candidate tree. Workers load the item, build their Context and check Metal forces
against the frozen Reference forces in parallel, then warm up one at a time. The driver then times <rounds> rounds
of <seconds> each (FAH_SECONDS for the four FAH items, whose rounds spread 3.4-5.6% at 4 s in the 2026-09-29
acceptance run), one configuration at a time, in reversed order every other round, so base and candidate
alternate on a warm Context. Every configuration of one platform and precision runs the same step count,
set from the baseline's warm-up rate. Timing is benchmark.py's: host clock around step(), with a
getState(energy) sync before and after. fah-neq steps in whole protocol cycles (2*n_steps), with the step
counter reset before each cycle, so every timed step changes lambda as FAH's work unit does.
Output in <outdir>: results.jsonl (one line per timed run), forces.jsonl, workers/*.log and summary.txt.
Ratios in summary.txt are speed ratios (higher is faster), paired within a round:
- Metal/OpenCL: the tree's OpenCL single us/step over its Metal us/step. Apple's OpenCL has no mixed, so
  OpenCL single is the denominator for Metal mixed too.
- cand/base: the baseline's us/step over the candidate's. spread is max minus min over the rounds. BLOCK
  when the median is more than 1% under 1.000 with a spread under 1.5% (the merge rule). The A/A column
  says whether 1.000 lies within the median plus or minus the spread.
- forces: rel|dF| and rel|dE| against Reference in double. A candidate row fails when its rel|dF| is over
  1.1 times the baseline's, or its rel|dE| is over 10 times the baseline's (floor 1e-6, about 8 float32
  ulps of a total). Energies aren't bitwise across Contexts, so the energy rule catches only breakage.
usage: holdout.py verify <holdout dir>
       holdout.py run [--rounds N] [--seconds S] [--fah-seconds S] <holdout dir> <outdir> <base python> <cand python>
       holdout.py worker <item dir> <platform> <precision> [--properties JSON]   (started by run)
"""
import hashlib
import json
import os
import statistics
import subprocess
import sys
import time

# sha256 of the frozen MANIFEST.sha256 (build.py, 2026-09-28). No item changes after the first baseline.
MANIFEST_SHA256 = "530d65f20c1a78d8cbb3fb41b1991a310f8f939fc57dfe6984175f76d712c059"
ITEMS = [
    ("fah-tip3p-hmr", ["mixed"]),
    ("fah-tip4pew", ["mixed"]),
    ("fah-gbsa", ["mixed"]),
    ("fah-neq", ["mixed"]),
    ("pme-50k", ["single", "mixed"]),
    ("pme-180k", ["single", "mixed"]),
    ("pme-600k", ["single", "mixed"]),
]
ROUNDS = 3
SECONDS = 4.0
FAH_SECONDS = 30.0
WARM_SECONDS = 1.0
BLOCK_RATIO = 0.99
BLOCK_SPREAD = 0.015
FORCE_FACTOR = 1.1
ENERGY_FACTOR = 10
ENERGY_FLOOR = 1e-6


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def verify(holdout):
    manifest = os.path.join(holdout, "MANIFEST.sha256")
    if sha256(manifest) != MANIFEST_SHA256:
        sys.exit(f"{manifest} is not the frozen manifest {MANIFEST_SHA256} (lab tools/holdout/MANIFEST.sha256)")
    bad = []
    for line in open(manifest):
        digest, path = line.split()
        if sha256(os.path.join(holdout, path)) != digest:
            bad.append(path)
    if bad:
        sys.exit(f"holdout files differ from {manifest}: {' '.join(bad)}")
    return sha256(manifest)


# ---- worker: runs under a tree's python, talks one JSON line per command on stdout ----

CONTEXT_PROPERTIES = ("Precision", "DeviceIndex", "DisablePmeStream", "DeterministicForces")


def requested_properties(platform_name, precision, properties=None):
    """Validate before importing OpenMM or creating a Context. Never coerce '1' to 'true'."""
    supported = set(CONTEXT_PROPERTIES) if platform_name in ("Metal", "CUDA") else (
        set(CONTEXT_PROPERTIES) - {"DeterministicForces"} if platform_name == "OpenCL" else set())
    if properties is not None and not isinstance(properties, dict):
        raise ValueError("properties must be a JSON object of string values")
    props = {"Precision": precision} if supported else {}
    props.update(properties or {})
    if set(props) - supported:
        raise ValueError(f"{platform_name}: unsupported properties {sorted(set(props) - supported)}")
    if any(not isinstance(value, str) for value in props.values()):
        raise ValueError("property values must be strings")
    if "Precision" in props and props["Precision"] != precision:
        raise ValueError("property Precision differs from worker precision")
    return props


def verify_properties(requested, effective):
    mismatches = {key: {"requested": value, "effective": effective.get(key)}
                  for key, value in requested.items() if effective.get(key) != value}
    if mismatches:
        raise ValueError("Context property mismatch: " + json.dumps(mismatches, sort_keys=True))
    return {"requested_properties": dict(requested), "effective_properties": dict(effective)}


def worker(item_dir, platform_name, precision, properties=None):
    props = requested_properties(platform_name, precision, properties)
    import bz2
    import numpy as np
    import openmm as mm
    import openmm.unit as u

    def load(name):
        for suffix, opener in ((".xml", open), (".xml.bz2", bz2.open)):
            path = os.path.join(item_dir, name + suffix)
            if os.path.exists(path):
                with opener(path, "rt") as f:
                    return mm.XmlSerializer.deserialize(f.read())
        raise FileNotFoundError(f"{item_dir}/{name}.xml")

    def reply(**fields):
        print(json.dumps(dict(receipt, **fields)), flush=True)

    start = time.time()
    system, state, integrator = load("system"), load("state"), load("integrator")
    platform = mm.Platform.getPlatformByName(platform_name)
    supported = set(platform.getPropertyNames())
    if set(props) - supported:
        raise ValueError(f"{platform_name} build does not support {sorted(set(props) - supported)}")
    try:
        context = mm.Context(system, integrator, platform, props)
    except Exception as exc:
        if platform_name != "OpenCL" or precision != "mixed":
            raise
        # Apple OpenCL cannot provide mixed precision. Preserve the failure, never substitute single.
        print(f"OpenCL mixed Context creation failed: {exc}", file=sys.stderr, flush=True)
        print(json.dumps(dict(ready=False, failure="context_creation_failed", error=str(exc),
                              requested_properties=props, effective_properties={})), flush=True)
        return

    def properties_receipt():
        effective = {key: platform.getPropertyValue(context, key)
                     for key in CONTEXT_PROPERTIES if key in supported}
        return verify_properties(props, effective)

    receipt = properties_receipt()
    context.setState(state)
    forces = {}
    if platform_name == "Metal":
        result = context.getState(getForces=True, getEnergy=True)
        f = np.array(result.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer))
        e = result.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
        ref = np.load(os.path.join(item_dir, "reference.npz"))
        error = f - ref["forces"]
        forces = {"rel_force": float(np.linalg.norm(error)/np.linalg.norm(ref["forces"])),
                  "max_force": float(np.abs(error).max()),
                  "rel_energy": float(abs(e - float(ref["energy"]))/abs(float(ref["energy"])))}
    # A CustomIntegrator with n_steps is the neq protocol: whole cycles, step counter reset before each.
    cycle = 0
    if isinstance(integrator, mm.CustomIntegrator):
        names = [integrator.getGlobalVariableName(i) for i in range(integrator.getNumGlobalVariables())]
        if "n_steps" in names and "step" in names:
            cycle = 2*int(integrator.getGlobalVariableByName("n_steps"))

    def advance(steps):
        if not cycle:
            integrator.step(steps)
            return steps
        cycles = max(1, round(steps/cycle))
        for _ in range(cycles):
            integrator.setGlobalVariableByName("step", 0)
            integrator.step(cycle)
        return cycles*cycle

    def timed(steps):
        nonlocal receipt
        receipt = properties_receipt()
        context.getState(getEnergy=True)
        begin = time.perf_counter()
        done = advance(steps)
        context.getState(getEnergy=True)
        elapsed = time.perf_counter() - begin
        receipt = properties_receipt()
        return done, elapsed

    reply(ready=True, atoms=system.getNumParticles(), setup_seconds=time.time() - start, cycle=cycle, **forces)
    for line in sys.stdin:
        command = line.split()
        if command[0] == "warm":
            # Settle, then size a 1 s block and time it.
            steps, elapsed = timed(cycle or 20)
            steps, elapsed = timed(max(cycle, int(steps*WARM_SECONDS/max(elapsed, 1e-6))))
            reply(warm_us=1e6*elapsed/steps)
        elif command[0] == "time":
            steps, elapsed = timed(int(command[1]))
            reply(steps=steps, seconds=elapsed)
        elif command[0] == "quit":
            return


# ---- driver ----

class Worker:
    def __init__(self, outdir, python, item_dir, tree, platform, precision, properties=None):
        props = requested_properties(platform, precision, properties)
        self.tree, self.platform, self.precision = tree, platform, precision
        self.label = f"{tree}-{platform}-{precision}"
        self.log_path = os.path.join(outdir, "workers", f"{os.path.basename(item_dir)}-{self.label}.log")
        env = {k: v for k, v in os.environ.items() if k not in ("PYTHONPATH", "OPENMM_CPU_THREADS")}
        with open(self.log_path, "w") as log:
            self.process = subprocess.Popen([python, os.path.abspath(__file__), "worker", item_dir, platform, precision,
                                             "--properties", json.dumps(props, sort_keys=True)],
                                            cwd="/", env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                            stderr=log, text=True)
        self.ready = self.warm = None

    def read(self):
        line = self.process.stdout.readline()
        return json.loads(line) if line else None

    def send(self, command):
        try:
            self.process.stdin.write(command + "\n")
            self.process.stdin.flush()
        except (BrokenPipeError, OSError):
            return None
        return self.read()

    def close(self):
        if self.process.poll() is None:
            self.send("quit")
        self.process.wait()


def log(message):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), message, flush=True)


def run(holdout, outdir, base_python, cand_python, rounds, seconds, fah_seconds):
    manifest = verify(holdout)
    os.makedirs(os.path.join(outdir, "workers"), exist_ok=True)
    results = open(os.path.join(outdir, "results.jsonl"), "a")
    forces_out = open(os.path.join(outdir, "forces.jsonl"), "a")
    log(f"manifest sha256 {manifest}, {rounds} rounds of {fah_seconds} s (FAH items) and {seconds} s (the rest)")
    started = time.time()
    for item, precisions in ITEMS:
        item_dir = os.path.join(holdout, item)
        configs = [(tree, platform, precision)
                   for tree in ("base", "cand")
                   for platform, precision in [("Metal", p) for p in precisions] + [("OpenCL", "single")]]
        pythons = {"base": base_python, "cand": cand_python}
        workers = [Worker(outdir, pythons[t], item_dir, t, pl, pr) for t, pl, pr in configs]
        for w in workers:
            w.ready = w.read()
            if w.ready is None:
                log(f"NO RESULT {item} {w.label}: the worker died while loading (workers/{item}-{w.label}.log)")
                continue
            if "rel_force" in w.ready:
                forces_out.write(json.dumps({"item": item, "tree": w.tree, "precision": w.precision,
                                             **{k: w.ready[k] for k in ("rel_force", "max_force", "rel_energy")}}) + "\n")
                forces_out.flush()
        # Loading ran in parallel; warm-ups run one at a time, so each times the GPU alone.
        for w in workers:
            w.warm = w.send("warm") if w.ready else None
        live = [w for w in workers if w.warm]
        log(f"{item}: {live[0].ready['atoms'] if live else '?'} atoms, "
            + ", ".join(f"{w.label} setup {w.ready['setup_seconds']:.1f} s warm {w.warm['warm_us']:.1f} us" for w in live))
        # One step count per platform and precision, from the baseline's warm-up (else the candidate's).
        steps = {}
        block = fah_seconds if item.startswith("fah-") else seconds
        for w in sorted(live, key=lambda w: w.tree != "base"):
            steps.setdefault((w.platform, w.precision), max(1, int(block*1e6/w.warm["warm_us"])))
        for r in range(1, rounds + 1):
            order = live if r % 2 else live[::-1]
            for w in order:
                answer = w.send(f"time {steps[(w.platform, w.precision)]}")
                if answer is None:
                    log(f"NO RESULT {item} round {r} {w.label} (workers/{item}-{w.label}.log)")
                    continue
                results.write(json.dumps({"item": item, "round": r, "tree": w.tree, "platform": w.platform,
                                          "precision": w.precision, **answer,
                                          "us_per_step": 1e6*answer["seconds"]/answer["steps"]}) + "\n")
                results.flush()
        for w in workers:
            w.close()
        log(f"{item}: done, {time.time() - started:.0f} s since start")
    results.close()
    forces_out.close()
    summary = summarize(outdir, manifest, time.time() - started)
    with open(os.path.join(outdir, "summary.txt"), "w") as f:
        f.write(summary)
    print(summary, end="")


def summarize(outdir, manifest, gpu_seconds):
    runs = [json.loads(line) for line in open(os.path.join(outdir, "results.jsonl"))]
    forces = [json.loads(line) for line in open(os.path.join(outdir, "forces.jsonl"))]
    us = {(x["item"], x["round"], x["tree"], x["platform"], x["precision"]): x["us_per_step"] for x in runs}
    rounds = sorted({x["round"] for x in runs})
    lines = [f"holdout manifest sha256 {manifest}",
             f"GPU hold {gpu_seconds/60:.1f} min, {len(runs)} timed runs",
             "speed ratios paired within a round, median over rounds; spread is max - min",
             f"{'item':14} {'prec':6} {'base us':>9} {'cand us':>9} {'base M/OCL':>10} {'cand M/OCL':>10} "
             f"{'cand/base':>9} {'spread':>7} {'A/A':>4} {'merge':>5}"]
    blocked = 0
    for item, precisions in ITEMS:
        for precision in precisions:
            def per_round(tree, platform, prec):
                return [us.get((item, r, tree, platform, prec)) for r in rounds]
            base, cand = per_round("base", "Metal", precision), per_round("cand", "Metal", precision)
            base_ocl, cand_ocl = per_round("base", "OpenCL", "single"), per_round("cand", "OpenCL", "single")

            def ratios(num, den):
                return [n/d for n, d in zip(num, den) if n and d]

            def median(values):
                return statistics.median(values) if values else float("nan")
            ratio = ratios(base, cand)
            spread = max(ratio) - min(ratio) if ratio else float("nan")
            m = median(ratio)
            within = "yes" if ratio and abs(m - 1) <= spread else "no"
            block = bool(ratio) and m < BLOCK_RATIO and spread < BLOCK_SPREAD
            blocked += block
            lines.append(f"{item:14} {precision:6} {median([x for x in base if x]):9.1f} "
                         f"{median([x for x in cand if x]):9.1f} {median(ratios(base_ocl, base)):10.3f} "
                         f"{median(ratios(cand_ocl, cand)):10.3f} {m:9.3f} {100*spread:6.1f}% {within:>4} "
                         f"{'BLOCK' if block else 'ok':>5}")
    lines.append("")
    lines.append(f"{'item':14} {'prec':6} {'base rel|dF|':>12} {'cand rel|dF|':>12} {'base rel|dE|':>12} "
                 f"{'cand rel|dE|':>12} forces")
    failed = 0
    for item, precisions in ITEMS:
        for precision in precisions:
            row = {x["tree"]: x for x in forces if x["item"] == item and x["precision"] == precision}
            if set(row) != {"base", "cand"}:
                lines.append(f"{item:14} {precision:6} missing: {sorted(row)}")
                failed += 1
                continue
            b, c = row["base"], row["cand"]
            ok = (c["rel_force"] <= FORCE_FACTOR*b["rel_force"]
                  and c["rel_energy"] <= max(ENERGY_FACTOR*b["rel_energy"], ENERGY_FLOOR))
            failed += not ok
            lines.append(f"{item:14} {precision:6} {b['rel_force']:12.3e} {c['rel_force']:12.3e} "
                         f"{b['rel_energy']:12.3e} {c['rel_energy']:12.3e} {'ok' if ok else 'FAIL'}")
    lines.append("")
    lines.append(f"verdict: {'BLOCK' if blocked else 'pass'} on timing ({blocked} rows), "
                 f"{'FAIL' if failed else 'ok'} on forces ({failed} rows)")
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["worker"]:
        import argparse
        parser = argparse.ArgumentParser()
        parser.add_argument("item_dir")
        parser.add_argument("platform")
        parser.add_argument("precision")
        parser.add_argument("--properties", type=json.loads)
        parsed = parser.parse_args(args[1:])
        worker(parsed.item_dir, parsed.platform, parsed.precision, parsed.properties)
    elif args[:1] == ["verify"]:
        print(verify(args[1]))
    elif args[:1] == ["run"]:
        args = args[1:]
        rounds, seconds, fah_seconds = ROUNDS, SECONDS, FAH_SECONDS
        while args and args[0].startswith("--"):
            if args[0] == "--rounds":
                rounds = int(args[1])
            elif args[0] == "--seconds":
                seconds = float(args[1])
            elif args[0] == "--fah-seconds":
                fah_seconds = float(args[1])
            else:
                sys.exit(f"unknown option {args[0]}")
            args = args[2:]
        run(*args[:4], rounds, seconds, fah_seconds)
    else:
        sys.exit(__doc__)

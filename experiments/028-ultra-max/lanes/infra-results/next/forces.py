"""Metal single and mixed forces and energy against Reference on the six small benchmark.py systems.

Adapted from experiment 025's fcheck.py. Writes the table to <out>. With a baseline table
(ultra-base/forces.txt), each row also gets a verdict, and the exit code is 1 if any row fails. A row
fails when rel|dF|, rounded to 3 digits, is larger than the baseline's, or when rel|dE| is more than 10
times the baseline's. rel|dF| repeats to 4 digits from run to run on the same build; rel|dE| moves by
up to a factor of 2, so the energy check only catches breakage.
Reference runs in double on the CPU. Its forces and energy at the starting positions come from
<benchmarks dir>/../reference/<test>.npz when that file exists (ultra-base/reference, written from
ultra-base by --write-reference), so a gate holds the GPU only for the Metal evaluations.
--md STEPS is the stale-list check: each Metal Context first runs STEPS steps of benchmark.py's
LangevinMiddleIntegrator (4 fs, 300 K, fixed seeds), then its forces are compared with Reference at the
positions it reached. The trajectory differs from build to build, so a row fails only when rel|dF| or
max|dF| is more than MD_FACTOR times the baseline's (ultra-base/forces-md100.txt).
usage: python forces.py [--md STEPS] [--write-reference] <benchmarks dir> <out> [baseline]
"""
import argparse
import os
import sys

import numpy as np
import openmm as mm
import openmm.unit as u

TESTS = ["gbsa", "rf", "pme", "apoa1rf", "apoa1pme", "apoa1ljpme"]
PRECISIONS = ["single", "mixed"]
ENERGY_FACTOR = 10
MD_FACTOR = 2
SEED = 2026

parser = argparse.ArgumentParser()
parser.add_argument("--md", type=int, default=0, metavar="STEPS")
parser.add_argument("--write-reference", action="store_true")
parser.add_argument("bench")
parser.add_argument("out")
parser.add_argument("baseline", nargs="?")
args = parser.parse_args()
if args.md and args.write_reference:
    parser.error("--write-reference caches the starting positions only; run it without --md")

bench = os.path.abspath(args.bench)
out_path = os.path.abspath(args.out)
reference_dir = os.path.join(os.path.dirname(bench), "reference")
baseline = {}
if args.baseline:
    for line in open(args.baseline):
        fields = line.split()
        if len(fields) >= 6 and fields[0] in TESTS:
            baseline[(fields[0], fields[2])] = (float(fields[3]), float(fields[4]), float(fields[5]))
os.chdir(bench)
# benchmark.py runs its benchmarks on import, so load only the definitions before serializeTest().
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])


def evaluate(context):
    state = context.getState(getForces=True, getEnergy=True, getPositions=True)
    forces = state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
    positions = state.getPositions(asNumpy=True).value_in_unit(u.nanometer)
    return np.array(forces), state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole), np.array(positions)


def reference(system, positions):
    context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Reference"))
    context.setPositions(positions)
    forces, energy, _ = evaluate(context)
    return forces, energy


def starting_reference(test, system, positions):
    path = os.path.join(reference_dir, f"{test}.npz")
    start = np.array(positions.value_in_unit(u.nanometer))
    if os.path.exists(path) and not args.write_reference:
        cached = np.load(path)
        if not np.array_equal(cached["positions"], start):
            sys.exit(f"{path} was written for other positions; rerun --write-reference from ultra-base")
        return cached["forces"], float(cached["energy"]), "cached"
    forces, energy = reference(system, positions)
    if args.write_reference:
        os.makedirs(reference_dir, exist_ok=True)
        partial = os.path.join(reference_dir, f".{test}.npz")
        np.savez(partial, positions=start, forces=forces, energy=energy)
        os.replace(partial, path)
        return forces, energy, "written"
    return forces, energy, "computed"


def metal(system, positions, precision):
    if not args.md:
        context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Metal"),
                             {"Precision": precision})
        context.setPositions(positions)
        return evaluate(context)
    integrator = mm.LangevinMiddleIntegrator(300*u.kelvin, 1/u.picosecond, 0.004*u.picoseconds)
    integrator.setRandomNumberSeed(SEED)
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), {"Precision": precision})
    context.setPositions(positions)
    context.setVelocitiesToTemperature(300*u.kelvin, SEED)
    integrator.step(args.md)
    return evaluate(context)


def verdict(test, precision, rel_force, max_force, rel_energy):
    if not baseline:
        return ""
    base_force, base_max, base_energy = baseline[(test, precision)]
    if args.md:
        if not rel_force <= MD_FACTOR*base_force:
            return f"FAIL rel|dF| {rel_force:.2e} > {MD_FACTOR} x base {base_force:.2e}"
        if not max_force <= MD_FACTOR*base_max:
            return f"FAIL max|dF| {max_force:.2e} > {MD_FACTOR} x base {base_max:.2e}"
        return "ok"
    if not float(f"{rel_force:.2e}") <= float(f"{base_force:.2e}"):
        return f"FAIL rel|dF| {rel_force:.2e} > base {base_force:.2e}"
    if not rel_energy <= ENERGY_FACTOR*base_energy:
        return f"FAIL rel|dE| {rel_energy:.2e} > {ENERGY_FACTOR} x base {base_energy:.2e}"
    return "ok"


failed = False
with open(out_path, "w") as out:
    header = f"{'test':12} {'atoms':>7} {'precision':>9} {'rel|dF|':>10} {'max|dF|':>10} {'rel|dE|':>10}"
    print(header, file=out, flush=True)
    print(header + (f"  (after {args.md} MD steps)" if args.md else ""), flush=True)
    for test in TESTS:
        system, positions, _ = retrieveTestSystem(test)
        if not args.md:
            fref, eref, how = starting_reference(test, system, positions)
            print(f"{test}: Reference {how}", flush=True)
        for precision in PRECISIONS:
            f, e, reached = metal(system, positions, precision)
            if args.md:
                fref, eref = reference(system, reached)
            rel_force = np.linalg.norm(f-fref)/np.linalg.norm(fref)
            max_force = np.abs(f-fref).max()
            rel_energy = abs(e-eref)/abs(eref)
            row = (f"{test:12} {system.getNumParticles():7d} {precision:>9} {rel_force:10.3e} "
                   f"{max_force:10.3e} {rel_energy:10.3e}")
            print(row, file=out, flush=True)
            result = verdict(test, precision, rel_force, max_force, rel_energy)
            failed = failed or result.startswith("FAIL")
            print(f"{row}  {result}", flush=True)
sys.exit(1 if failed else 0)

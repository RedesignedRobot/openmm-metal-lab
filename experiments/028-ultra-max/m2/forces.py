"""Metal single and mixed forces and energy against Reference on the six small benchmark.py systems.

Adapted from experiment 025's fcheck.py. Reference runs once per test, in double. Writes the table to
<out>. With a baseline table (ultra-base/forces.txt), each row also gets a verdict, and the exit code
is 1 if any row fails. A row fails when rel|dF|, rounded to 3 digits, is larger than the baseline's,
or when rel|dE| is more than 10 times the baseline's. rel|dF| repeats to 4 digits from run to run on
the same build; rel|dE| moves by up to a factor of 2, so the energy check only catches breakage.
usage: python forces.py <benchmarks dir> <out> [baseline]
"""
import os
import sys

import numpy as np
import openmm as mm
import openmm.unit as u

TESTS = ["gbsa", "rf", "pme", "apoa1rf", "apoa1pme", "apoa1ljpme"]
PRECISIONS = ["single", "mixed"]
ENERGY_FACTOR = 10

bench = os.path.abspath(sys.argv[1])
out_path = os.path.abspath(sys.argv[2])
baseline = {}
if len(sys.argv) > 3:
    for line in open(sys.argv[3]):
        fields = line.split()
        if len(fields) >= 6 and fields[0] in TESTS:
            baseline[(fields[0], fields[2])] = (float(fields[3]), float(fields[5]))
os.chdir(bench)
# benchmark.py runs its benchmarks on import, so load only the definitions before serializeTest().
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])


def forces_and_energy(system, positions, platform, props):
    context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName(platform), props)
    context.setPositions(positions)
    state = context.getState(getForces=True, getEnergy=True)
    forces = state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
    return np.array(forces), state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)


def verdict(test, precision, rel_force, rel_energy):
    if not baseline:
        return ""
    base_force, base_energy = baseline[(test, precision)]
    if not float(f"{rel_force:.2e}") <= float(f"{base_force:.2e}"):
        return f"FAIL rel|dF| {rel_force:.2e} > base {base_force:.2e}"
    if not rel_energy <= ENERGY_FACTOR*base_energy:
        return f"FAIL rel|dE| {rel_energy:.2e} > {ENERGY_FACTOR} x base {base_energy:.2e}"
    return "ok"


failed = False
with open(out_path, "w") as out:
    header = f"{'test':12} {'atoms':>7} {'precision':>9} {'rel|dF|':>10} {'max|dF|':>10} {'rel|dE|':>10}"
    print(header, file=out, flush=True)
    print(header, flush=True)
    for test in TESTS:
        system, positions, _ = retrieveTestSystem(test)
        fref, eref = forces_and_energy(system, positions, "Reference", {})
        for precision in PRECISIONS:
            f, e = forces_and_energy(system, positions, "Metal", {"Precision": precision})
            rel_force = np.linalg.norm(f-fref)/np.linalg.norm(fref)
            rel_energy = abs(e-eref)/abs(eref)
            row = (f"{test:12} {system.getNumParticles():7d} {precision:>9} {rel_force:10.3e} "
                   f"{np.abs(f-fref).max():10.3e} {rel_energy:10.3e}")
            print(row, file=out, flush=True)
            result = verdict(test, precision, rel_force, rel_energy)
            failed = failed or result.startswith("FAIL")
            print(f"{row}  {result}", flush=True)
sys.exit(1 if failed else 0)

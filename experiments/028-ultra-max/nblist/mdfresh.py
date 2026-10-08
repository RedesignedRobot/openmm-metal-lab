"""Stale list or arithmetic? forces.py --md 100 flags MAX_BITS 0 on rf single (rel|dF| 15x base).

For each test, run forces.py's 100 LangevinMiddle steps in Metal single with the MD knobs from argv, then at
the positions reached compare the MD Context's forces with fresh Metal Contexts (fresh neighbor list) at
MAX_BITS 0 and 4, and with Reference. A stale list shows as md != fresh at the same MAX_BITS; an arithmetic
difference shows as fresh mb0 != fresh mb4 with both lists fresh.
usage: python mdfresh.py <benchmarks dir> <tests> [NAME=value ...]
"""
import os
import sys

import numpy as np
import openmm as mm
import openmm.unit as u

SEED = 2026
STEPS = 100
bench, tests = sys.argv[1], sys.argv[2].split(",")
md_knobs = dict(arg.split("=", 1) for arg in sys.argv[3:])
os.chdir(bench)
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])


def set_knobs(knobs):
    for name in ("NB_MAXBITS",):
        os.environ.pop(name, None)
    os.environ.update(knobs)


def forces(context):
    state = context.getState(getForces=True)
    return np.array(state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer))


def fresh(system, positions, platform, knobs):
    set_knobs(knobs)
    props = {"Precision": "single"} if platform == "Metal" else {}
    context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName(platform), props)
    context.setPositions(positions)
    return forces(context)


def compare(a, b, fref):
    d = np.linalg.norm(a-b, axis=1)
    return f"rel {np.linalg.norm(a-b)/np.linalg.norm(fref):.3e} max {np.abs(a-b).max():.3e} atom {int(d.argmax())}"


for test in tests:
    system, positions, _ = retrieveTestSystem(test)
    set_knobs(md_knobs)
    integrator = mm.LangevinMiddleIntegrator(300*u.kelvin, 1/u.picosecond, 0.004*u.picoseconds)
    integrator.setRandomNumberSeed(SEED)
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), {"Precision": "single"})
    context.setPositions(positions)
    context.setVelocitiesToTemperature(300*u.kelvin, SEED)
    integrator.step(STEPS)
    fmd = forces(context)
    reached = context.getState(getPositions=True).getPositions(asNumpy=True)
    fref = fresh(system, reached, "Reference", {})
    f0 = fresh(system, reached, "Metal", {"NB_MAXBITS": "0"})
    f4 = fresh(system, reached, "Metal", {"NB_MAXBITS": "4"})
    print(f"== {test} md knobs {md_knobs or 'default'}", flush=True)
    print(f"  md    vs Reference   {compare(fmd, fref, fref)}")
    print(f"  fresh0 vs Reference  {compare(f0, fref, fref)}")
    print(f"  fresh4 vs Reference  {compare(f4, fref, fref)}")
    print(f"  md    vs fresh0      {compare(fmd, f0, fref)}")
    print(f"  md    vs fresh4      {compare(fmd, f4, fref)}")
    print(f"  fresh0 vs fresh4     {compare(f0, f4, fref)}", flush=True)

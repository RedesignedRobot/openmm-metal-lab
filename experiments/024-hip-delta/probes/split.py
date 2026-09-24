"""Time one benchmark.py system with some force classes removed, over several fresh Contexts in one process.

usage: [SPLIT_NOCUTOFF=1] [SPLIT_RECIPONLY=1] python split.py <examples/benchmarks dir> <test> <contexts> <chunks> <seconds per chunk> [ForceClass,...]
Prints ns/day per chunk (host clock, getState after each chunk) so a slow mode shows up as
per-Context or per-chunk.
"""
import os
import resource
import sys
import time

import openmm as mm
import openmm.unit as u

bench = os.path.abspath(sys.argv[1])
test = sys.argv[2]
contexts, chunks, seconds = int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5])
drop = sys.argv[6].split(",") if len(sys.argv) > 6 else []
os.chdir(bench)
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])

system, positions, _ = retrieveTestSystem(test)
for i in reversed(range(system.getNumForces())):
    if type(system.getForce(i)).__name__ in drop:
        system.removeForce(i)
if os.environ.get("SPLIT_NOCUTOFF"):
    for force in system.getForces():
        if hasattr(force, "setNonbondedMethod"):
            force.setNonbondedMethod(0)
if os.environ.get("SPLIT_RECIPONLY"):
    for force in system.getForces():
        if isinstance(force, mm.NonbondedForce):
            force.setIncludeDirectSpace(False)
friction = (91 if test == "gbsa" else 1)/u.picoseconds
dt = 0.004
for c in range(contexts):
    integrator = mm.LangevinMiddleIntegrator(300*u.kelvin, friction, dt*u.picoseconds)
    integrator.setConstraintTolerance(1e-5)
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), {"Precision": "single"})
    context.setPositions(positions)
    context.setVelocitiesToTemperature(300*u.kelvin)
    integrator.step(20)
    context.getState(getEnergy=True)
    steps = 50
    start = time.perf_counter()
    integrator.step(steps)
    context.getState(getEnergy=True)
    steps = max(50, int(steps*seconds/(time.perf_counter()-start)))
    rates, cpu = [], []
    for _ in range(chunks):
        start = time.perf_counter()
        usage = resource.getrusage(resource.RUSAGE_SELF)
        integrator.step(steps)
        context.getState(getEnergy=True)
        elapsed = time.perf_counter()-start
        after = resource.getrusage(resource.RUSAGE_SELF)
        rates.append(steps*dt*86400e-3/elapsed)
        cpu.append((after.ru_utime-usage.ru_utime+after.ru_stime-usage.ru_stime)/elapsed)
    print(f"{test} drop={','.join(drop) or 'none'} context {c}: " + " ".join(f"{r:.1f}" for r in rates)
          + "  cpu/wall " + " ".join(f"{x:.2f}" for x in cpu), flush=True)
    del context, integrator

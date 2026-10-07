"""step(1) with host work between calls, the way Simulation.step runs with frequent reporters.

For each test, sets up the benchmark.py system and integrator, runs 20 warm-up steps, then times
<iterations> x (integrator.step(1), then <host_us> of busy host work), ending with a getState sync.
The host work spins on the CPU, as a reporter's Python would. Prints one line per test:
test, precision, iterations, host us, wall seconds, us per iteration.
usage: python hostwork.py <examples/benchmarks dir> <tests> <precision> <iterations> <host_us>
"""
import os
import sys
import time

import openmm as mm
import openmm.unit as u

bench = os.path.abspath(sys.argv[1])
tests = sys.argv[2].split(",")
precision = sys.argv[3]
iterations = int(sys.argv[4])
host_seconds = float(sys.argv[5])*1e-6
os.chdir(bench)
# benchmark.py runs its benchmarks on import, so load only the definitions before serializeTest().
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])


def host_work():
    end = time.perf_counter() + host_seconds
    while time.perf_counter() < end:
        pass


for test in tests:
    system, positions, _ = retrieveTestSystem(test)
    friction = (91 if test == "gbsa" else 1)/u.picosecond
    integrator = mm.LangevinMiddleIntegrator(300*u.kelvin, friction, 0.004*u.picoseconds)
    integrator.setConstraintTolerance(1e-5)
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), {"Precision": precision})
    context.setPositions(positions)
    if test.startswith("amber"):
        mm.LocalEnergyMinimizer.minimize(context, 100*u.kilojoules_per_mole/u.nanometer)
    context.setVelocitiesToTemperature(300*u.kelvin)
    integrator.step(20)
    context.getState(getEnergy=True)
    start = time.perf_counter()
    for i in range(iterations):
        integrator.step(1)
        host_work()
    context.getState(getEnergy=True)
    wall = time.perf_counter() - start
    print(f"{test} {precision} {iterations} {host_seconds*1e6:.0f} {wall:.4f} {wall/iterations*1e6:.1f}", flush=True)
    del context

"""How much Apple's Metal shader cache grows per new work unit (r3-fah). Run alone on the GPU (gpuq timing class, for
exclusivity only; nothing here is timed for a verdict).

usage: python cachegrow.py <n boxes>

Builds TIP3P water boxes whose sizes this process has never seen (PME, HBonds, LangevinMiddle), so every kernel source
carries new NUM_ATOMS-style constants. For each: bytes of $(getconf DARWIN_USER_CACHE_DIR)com.apple.metal before and
after Context creation plus 10 steps on Metal mixed, then the same system a second time (a warm-cache rebuild).
"""
import os
import random
import subprocess
import sys
import time

import openmm as mm
import openmm.app as app
import openmm.unit as u

cache = subprocess.check_output(["getconf", "DARWIN_USER_CACHE_DIR"], text=True).strip() + "com.apple.metal"


def cache_bytes():
    return sum(os.path.getsize(os.path.join(d, f)) for d, _, fs in os.walk(cache) for f in fs)


def context(system):
    integrator = mm.LangevinMiddleIntegrator(300, 1, 0.002)
    c = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), {"Precision": "mixed"})
    return c, integrator


ff = app.ForceField("amber14-all.xml", "amber14/tip3p.xml")
rng = random.Random(os.getpid())
for k in range(int(sys.argv[1])):
    edge = rng.uniform(3.1, 3.9)
    m = app.Modeller(app.Topology(), [])
    m.addSolvent(ff, boxSize=mm.Vec3(edge, edge, edge) * u.nanometer)
    system = ff.createSystem(m.topology, nonbondedMethod=app.PME, nonbondedCutoff=0.9 * u.nanometer, constraints=app.HBonds)
    for label in ("cold", "warm"):
        before, t = cache_bytes(), time.perf_counter()
        c, integrator = context(system)
        c.setPositions(m.positions)
        mm.LocalEnergyMinimizer.minimize(c, maxIterations=50)
        integrator.step(10)
        c.getState(getEnergy=True)
        wall = time.perf_counter() - t
        del c, integrator
        print(f"{system.getNumParticles()} atoms {label}: cache +{(cache_bytes() - before)/1e6:.1f} MB, "
              f"context+10 steps {wall:.2f} s", flush=True)
print(f"cache total {cache_bytes()/1e9:.2f} GB")

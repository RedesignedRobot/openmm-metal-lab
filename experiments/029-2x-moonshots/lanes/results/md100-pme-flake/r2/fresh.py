"""Stale-list test: after forces.py's md100 (seed, DeterministicForces), compare forces from (a) the MD
Context as it stands, (b) a fresh Metal Context on the same positions and box, (c) the MD Context after
setPositions (forced list rebuild), each against Reference on those positions.
usage: python fresh.py <benchmarks dir> <test> <precision> <seed>
"""
import os
import sys

import numpy as np
import openmm as mm
import openmm.unit as u

sys.path.insert(0, "/tmp/openmm-metal-bench/ultra-tools")
from cutoff_pairs import reconcile  # noqa: E402

bench, test, precision, seed = os.path.abspath(sys.argv[1]), sys.argv[2], sys.argv[3], int(sys.argv[4])
os.chdir(bench)
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])
system, positions, _ = retrieveTestSystem(test)
props = {"Precision": precision, "DeterministicForces": "true"}


def forces(context):
    s = context.getState(getForces=True, getPositions=True)
    return (np.array(s.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)),
            s.getPositions(asNumpy=True), s.getPeriodicBoxVectors())


integrator = mm.LangevinMiddleIntegrator(300*u.kelvin, 1/u.picosecond, 0.004*u.picoseconds)
integrator.setRandomNumberSeed(seed)
md = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), props)
md.setPositions(positions)
md.setVelocitiesToTemperature(300*u.kelvin, seed)
integrator.step(100)
fa, pos, box = forces(md)
fresh = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Metal"), props)
fresh.setPeriodicBoxVectors(*box)
fresh.setPositions(pos)
fb, _, _ = forces(fresh)
md.setPositions(pos)
fc, _, _ = forces(md)
ref = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Reference"))
ref.setPeriodicBoxVectors(*box)
ref.setPositions(pos)
fr, _, _ = forces(ref)
reached = np.array(pos.value_in_unit(u.nanometer))
for name, f in (("a md", fa), ("b fresh", fb), ("c md+setPositions", fc)):
    raw = f-fr
    err, pairs, _ = reconcile(system, reached, raw)
    top = np.argsort(-np.linalg.norm(err, axis=1))[:3]
    print(f"{test} {precision} seed {seed} {name:18} rel|dF| {np.linalg.norm(err)/np.linalg.norm(fr):.4e} "
          f"max|dF| {np.abs(err).max():.4e} raw max {np.abs(raw).max():.4e} pairs {len(pairs)} top atoms {list(top)}")
for name, f in (("a-b", fa-fb), ("a-c", fa-fc), ("b-c", fb-fc)):
    n = np.linalg.norm(f, axis=1)
    print(f"{test} {precision} seed {seed} {name} bitwise-equal atoms {int((n == 0).sum())}/{len(n)} max|diff| {np.abs(f).max():.4e}"
          f" top {[(int(k), float(f'{n[k]:.3g}')) for k in np.argsort(-n)[:5] if n[k] > 0]}")

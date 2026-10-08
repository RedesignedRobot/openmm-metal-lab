"""Time and check the direct nonbonded kernel on one tree, at the benchmark coordinates."""
import argparse
import ctypes as ct
import json
import os
from pathlib import Path
import numpy as np
import openmm as mm
import openmm.unit as u

p = argparse.ArgumentParser()
p.add_argument("--tree", type=Path, required=True)
p.add_argument("--lib", type=Path, required=True)
p.add_argument("--test", default="apoa1rf")
p.add_argument("--precision", default="single")
p.add_argument("--repeat", type=int, default=200)
p.add_argument("--out", type=Path, required=True)
p.add_argument("--reference", action="store_true")
a = p.parse_args()
os.chdir("/tmp/openmm-metal-bench/ultra-base/benchmarks")
src = Path("benchmark.py").read_text()
ns = {}
exec(src[:src.index("def serializeTest")], ns)
system, positions, _ = ns["retrieveTestSystem"](a.test)
for f in system.getForces():
    f.setForceGroup(1 if isinstance(f, mm.NonbondedForce) else 0)
def make(platform, props):
    integrator = mm.LangevinMiddleIntegrator(300*u.kelvin, 1/u.picosecond, .004*u.picoseconds)
    integrator.setRandomNumberSeed(2026)
    c = mm.Context(system, integrator, mm.Platform.getPlatformByName(platform), props)
    c.setPositions(positions)
    c.setVelocitiesToTemperature(300*u.kelvin, 2026)
    return c, integrator
context, integrator = make("Metal", {"Precision": a.precision, "DeterministicForces": "true"})

state = context.getState(getPositions=True, getForces=True, getEnergy=True, groups={1})
pos = state.getPositions(asNumpy=True).value_in_unit(u.nanometer)
f_state = state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
e_state = state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
lib = ct.CDLL(str(a.lib))
err = ct.create_string_buffer(4096)
n = context.getSystem().getNumParticles()
padded = (n+31)//32*32
raw = np.empty(3*padded, dtype=np.int64)
def forces():
    if lib.nbForces(ct.c_void_p(int(context.this)), raw.ctypes.data_as(ct.c_void_p), err, len(err)):
        raise RuntimeError(err.value.decode())
    return raw.copy()
first, second = forces(), forces()
times = np.empty(a.repeat)
if lib.nbTimes(ct.c_void_p(int(context.this)), a.repeat, times.ctypes.data_as(ct.c_void_p), err, len(err)):
    raise RuntimeError(err.value.decode())
result = dict(test=a.test, precision=a.precision, tree=str(a.tree), energy=e_state,
              bitwise_repeat=bool(np.array_equal(first, second)),
              us_median=float(np.median(times)*1e6), us_min=float(times.min()*1e6),
              us_p90=float(np.percentile(times, 90)*1e6))
out = dict(positions=pos, forces=f_state, direct=first, times=times)
if a.reference:
    ref, _ = make("Reference", {})
    ref.setPositions(pos)
    rs = ref.getState(getForces=True, getEnergy=True, groups={1})
    out["ref_forces"] = rs.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
    result["ref_energy"] = rs.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
np.savez(a.out, **out)
print(json.dumps(result), flush=True)

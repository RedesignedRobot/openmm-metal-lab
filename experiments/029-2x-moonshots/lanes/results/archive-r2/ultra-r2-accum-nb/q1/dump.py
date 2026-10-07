"""Q1 dump: benchmark.py's apoa1 NVT run (LangevinMiddle 300 K, 1/ps, 4 fs, seed 2026) on ultra-integrated, with
positions (system order, unwrapped, float32), the rebuild flag and the Metal atom order recorded every step in
two windows: steps 1000-1149 and 10000-10149 after setVelocitiesToTemperature. Nothing is timed.
usage: dump.py <test> <out.npz> [precision]"""
import ctypes as ct
import os
import sys
from pathlib import Path
import numpy as np
import openmm as mm
import openmm.unit as u

test, out = sys.argv[1], Path(sys.argv[2])
prec = sys.argv[3] if len(sys.argv) > 3 else "single"
lib = ct.CDLL("/tmp/openmm-metal-bench/ultra-r2-accum-nb/eff/libdump-int.dylib")
os.chdir("/tmp/openmm-metal-bench/ultra-base/benchmarks")
src = Path("benchmark.py").read_text()
ns = {}
exec(src[:src.index("def serializeTest")], ns)
system, positions, _ = ns["retrieveTestSystem"](test)
nbf = next(f for f in system.getForces() if isinstance(f, mm.NonbondedForce))
integrator = mm.LangevinMiddleIntegrator(300*u.kelvin, 1/u.picosecond, .004*u.picoseconds)
integrator.setRandomNumberSeed(2026)
context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), {"Precision": prec})
context.setPositions(positions)
context.setVelocitiesToTemperature(300*u.kelvin, 2026)
ptr = ct.c_void_p(int(context.this))
err = ct.create_string_buffer(4096)
tmp = f"/tmp/openmm-metal-bench/ultra-r2-accum-nb/q1/nbdump-{test}"
os.makedirs(tmp, exist_ok=True)
def order():
    if lib.nbDump(ptr, tmp.encode(), err, len(err)):
        raise RuntimeError(err.value.decode())
    return np.fromfile(tmp+"/order.i32", dtype=np.int32)[:system.getNumParticles()].copy()
def state():
    s = context.getState(getPositions=True)
    return s.getPositions(asNumpy=True).value_in_unit(u.nanometer).astype(np.float32)
W = 150
rec = {}
done = 0
for w, first in enumerate((1000, 10000)):
    integrator.step(first-done)
    pos = np.empty((W+1, system.getNumParticles(), 3), np.float32)
    orders = np.empty((W+1, system.getNumParticles()), np.int32)
    flags = np.zeros(W+1, np.int8)
    pos[0], orders[0] = state(), order()
    for s in range(1, W+1):
        integrator.step(1)
        pos[s], orders[s] = state(), order()
        flags[s] = lib.nbRebuilt(ptr, err, len(err))
    done = first+W
    rec[f"pos{w}"], rec[f"order{w}"], rec[f"flags{w}"] = pos, orders, flags
    print(f"{test} window {w} from step {first}: {int(flags.sum())} rebuilds in {W} steps", flush=True)
box = np.array([v[i] for i, v in enumerate(context.getState().getPeriodicBoxVectors().value_in_unit(u.nanometer))])
cutoff = nbf.getCutoffDistance().value_in_unit(u.nanometer)
np.savez(out, box=box, cutoff=cutoff, **rec)

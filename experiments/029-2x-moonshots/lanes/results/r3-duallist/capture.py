"""Capture a fixed 32-step trajectory with the public Metal capture API."""
import ctypes
import os
import sys
import openmm as mm
import openmm.unit as u

bench, test, lib, trace = sys.argv[1:]
os.chdir(bench)
source = open('benchmark.py').read()
exec(source[:source.index('def serializeTest')])
system, positions, _ = retrieveTestSystem(test)
integrator = mm.LangevinMiddleIntegrator(300*u.kelvin, 1/u.picoseconds, 0.004*u.picoseconds)
integrator.setRandomNumberSeed(2026)
integrator.setConstraintTolerance(1e-5)
context = mm.Context(system, integrator, mm.Platform.getPlatformByName('Metal'), {'Precision': 'single'})
context.setPositions(positions)
if test.startswith('amber'):
    mm.LocalEnergyMinimizer.minimize(context, 100*u.kilojoules_per_mole/u.nanometer)
context.setVelocitiesToTemperature(300*u.kelvin, 2026)
integrator.step(100)
context.getState(positions=True)
helper = ctypes.CDLL(lib)
helper.beginCapture.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
helper.beginCapture.restype = ctypes.c_int
assert helper.beginCapture(int(context.this), trace.encode()) == 0
integrator.step(32)
context.getState(positions=True)
helper.endCapture()
print(f'captured {test} single 32 consecutive MD steps after 100 warmup steps, seed 2026: {trace}', flush=True)

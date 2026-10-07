"""Time a fresh apoa1pme minimization capped at 200 iterations."""
import json
import os
import sys
import time
from pathlib import Path
import openmm as mm
from openmm import unit
bench, platform, precision = sys.argv[1:4]
os.chdir(bench)
ns = {}
source = Path('benchmark.py').read_text()
exec(source[:source.index('def serializeTest')], ns)
system, positions, _ = ns['retrieveTestSystem']('apoa1pme')
integ = mm.VerletIntegrator(0.001)
props = {'Precision': precision} if platform == 'Metal' else {}
ctx = mm.Context(system, integ, mm.Platform.getPlatformByName(platform), props)
ctx.setPositions(positions)
# Compile the minimizer kernels before timing either precision, then restore
# exactly the same starting coordinates for the 200-iteration comparison.
warm_start = time.perf_counter()
mm.LocalEnergyMinimizer.minimize(ctx, 10, 1)
warm_seconds = time.perf_counter()-warm_start
ctx.setPositions(positions)
initial = ctx.getState(getEnergy=True).getPotentialEnergy().value_in_unit(unit.kilojoule_per_mole)
start = time.perf_counter()
mm.LocalEnergyMinimizer.minimize(ctx, 10, 200)
minimize_seconds = time.perf_counter()-start
state = ctx.getState(getEnergy=True, getForces=True)
elapsed = time.perf_counter()-start
final = state.getPotentialEnergy().value_in_unit(unit.kilojoule_per_mole)
forces = state.getForces(asNumpy=True).value_in_unit(unit.kilojoule_per_mole/unit.nanometer)
if platform == 'CPU':
    props['Threads'] = ctx.getPlatform().getPropertyValue(ctx, 'Threads')
print(json.dumps({'platform': platform, 'precision': precision, 'iterations_cap': 200,
                  'platform_properties': props,
                  'warmup_iterations_cap': 1, 'warmup_seconds': warm_seconds,
                  'tolerance': 10, 'minimize_seconds': minimize_seconds,
                  'rms_force_after': float((forces**2).mean()**0.5),
                  'wall_seconds': elapsed, 'energy_initial': initial, 'energy_final': final,
                  'library': mm.version.openmm_library_path}), flush=True)

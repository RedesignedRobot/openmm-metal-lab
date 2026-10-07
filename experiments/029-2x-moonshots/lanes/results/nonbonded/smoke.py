"""One step on a standard benchmark system. Run only under a correctness lease."""
import os
from pathlib import Path
import sys
import numpy as np
import openmm as mm
import openmm.unit as u
bench, platform, precision, test = sys.argv[1:]
os.chdir(bench)
source = Path('benchmark.py').read_text()
namespace = {'__name__': 'benchmark_definitions'}
exec(source[:source.index('def serializeTest')], namespace)
system, positions, _ = namespace['retrieveTestSystem'](test)
integrator = mm.VerletIntegrator(0.001)
context = mm.Context(system, integrator, mm.Platform.getPlatformByName(platform), {'Precision': precision})
context.setPositions(positions)
integrator.step(1)
forces = context.getState(getForces=True).getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
if not np.isfinite(forces).all():
    raise RuntimeError('nonfinite forces')
print(f'PASS one-step {test} {platform} {precision}', flush=True)

import json
import os
import sys
from pathlib import Path
import openmm as mm
bench, platform, precision = sys.argv[1:4]
os.chdir(bench)
ns = {}
source = Path('benchmark.py').read_text()
exec(source[:source.index('def serializeTest')], ns)
system, positions, _ = ns['retrieveTestSystem']('gbsa')
integ = mm.LangevinMiddleIntegrator(300, 1, 0.004)
ctx = mm.Context(system, integ, mm.Platform.getPlatformByName(platform), {'Precision': precision})
ctx.setPositions(positions)
ctx.setVelocitiesToTemperature(300, 1)
integ.step(1)
ctx.getState(getPositions=True)
print(json.dumps({'platform': platform, 'precision': precision, 'step': 'PASS', 'library': mm.version.openmm_library_path}))

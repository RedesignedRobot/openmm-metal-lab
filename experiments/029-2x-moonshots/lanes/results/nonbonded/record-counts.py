"""Inspect live coarse tile counts without modifying the benchmarked source."""
import ctypes, json, os, sys
from pathlib import Path
import openmm as mm
import openmm.unit as u
lane=Path('/tmp/openmm-metal-bench/ultra-m29-nonbonded')
bench=Path(sys.argv[1])
os.chdir(bench)
source=(bench/'benchmark.py').read_text()
ns={'__name__':'benchmark_definitions'}
exec(source[:source.index('def serializeTest')],ns)
library=ctypes.CDLL(str(lane/'record-counts.dylib'))
library.readRecordCounts.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_uint)]
library.readRecordCounts.restype=ctypes.c_int
for test in ['apoa1rf','amber20-cellulose','amber20-stmv']:
    system,positions,_=ns['retrieveTestSystem'](test)
    integrator=mm.LangevinMiddleIntegrator(300*u.kelvin,1/u.picosecond,0.004*u.picoseconds)
    integrator.setRandomNumberSeed(2026)
    context=mm.Context(system,integrator,mm.Platform.getPlatformByName('Metal'),{'Precision':'single'})
    context.setPositions(positions)
    context.setVelocitiesToTemperature(300*u.kelvin,2026)
    for advance in [1,99]:
        integrator.step(advance)
        context.getState(getForces=True)
        result=(ctypes.c_uint*3)()
        status=library.readRecordCounts(int(context.this),result)
        if status: raise RuntimeError(f'count probe failed: {status}')
        print(json.dumps({'test':test,'step':context.getStepCount(),'neighbor_tiles':result[0],
                          'neighbor_capacity':result[1],'exclusion_tiles':result[2],
                          'record_tiles_needed':result[0]+result[2]}),flush=True)
    del context,integrator,system

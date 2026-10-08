"""Time PME reciprocal space alone against the rest of the force evaluation.

usage: python pmeprof.py BENCHMARK_DIR TEST PRECISION [REPS]
Reciprocal space goes in force group 1, everything else in group 0, and an
empty force in group 2 measures the fixed getState cost.
"""
import os, sys, time
import openmm as mm

benchDir, testName, precision = sys.argv[1], sys.argv[2], sys.argv[3]
reps = int(sys.argv[4]) if len(sys.argv) > 4 else 50
os.chdir(benchDir)
src = open(os.path.join(benchDir, 'benchmark.py')).read().split('# Parse the command line options.')[0]
ns = {'__file__': os.path.join(benchDir, 'benchmark.py'), '__name__': 'bench'}
exec(compile(src, 'benchmark.py', 'exec'), ns)
system, positions, params = ns['retrieveTestSystem'](testName)

for f in system.getForces():
    f.setForceGroup(0)
    if isinstance(f, mm.NonbondedForce):
        f.setReciprocalSpaceForceGroup(1)
        print('grid', f.getPMEParameters() if hasattr(f, 'getPMEParameters') else '')
empty = mm.CustomExternalForce('0')
empty.setForceGroup(2)
system.addForce(empty)

platform = mm.Platform.getPlatformByName('Metal')
integ = mm.VerletIntegrator(0.001)
context = mm.Context(system, integ, platform, {'Precision': precision})
context.setPositions(positions)
for f in system.getForces():
    if isinstance(f, mm.NonbondedForce):
        print('pme params', f.getPMEParametersInContext(context)) if f.getNonbondedMethod() == mm.NonbondedForce.PME else None
        if f.getNonbondedMethod() == mm.NonbondedForce.LJPME:
            print('ljpme params', f.getLJPMEParametersInContext(context))

if os.environ.get('PMEPROF_GRID'):
    n = int(os.environ['PMEPROF_GRID'])
    for f in system.getForces():
        if isinstance(f, mm.NonbondedForce):
            alpha = f.getPMEParametersInContext(context)[0]
            f.setPMEParameters(alpha, n, n, n)
            context.reinitialize(preserveState=True)
            print('grid override', f.getPMEParametersInContext(context))

def timeGroups(groups):
    for _ in range(5):
        context.getState(getForces=True, groups=groups)
    t0 = time.perf_counter()
    for _ in range(reps):
        context.getState(getForces=True, groups=groups)
    return (time.perf_counter()-t0)/reps*1e3

for _ in range(2):
    r = {name: timeGroups(g) for name, g in (('empty', {2}), ('recip', {1}), ('direct', {0}), ('all', {0, 1}))}
    print(testName, precision, ' '.join(f'{k}={v:.3f}ms' for k, v in r.items()), f"recip-empty={r['recip']-r['empty']:.3f}ms", flush=True)

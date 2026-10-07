# Knob scanner for the nblist lane: one process, each (test, config) gets a fresh Context built the
# way benchmark.py builds it; configs are env settings read at Context creation. Interleaved,
# order reversed every other round. Each test's System is built once and reused. Host clock (time.perf_counter) around step(n)+getState(energy).
# usage: scan.py [--time <file>] <benchmarks dir> <seconds> <rounds> <tests> <label=VAR=v,VAR=v|label=> ...
import os, sys, time, json
args = sys.argv[1:]
timeFile = None
if args[0] == '--time':
    timeFile = args[1]
    args = args[2:]
    os.environ['NB_TIME'] = timeFile
bdir, seconds, rounds, tests = args[0], float(args[1]), int(args[2]), args[3].split(',')
configs = []
for arg in args[4:]:
    label, _, rest = arg.partition('=')
    env = dict(kv.split('=', 1) for kv in rest.split(',') if kv)
    # The bucket sort aggregation and SIMD scan knobs fail the forces gate (22:55Z), so every config runs without them.
    env.setdefault('NB_SORTAGG', '0')
    env.setdefault('NB_SORTSCAN', '0')
    configs.append((label, env))
os.chdir(bdir)
src = open('benchmark.py').read().split('# Parse the command line options.')[0]
g = {'__name__': 'bench'}
exec(compile(src, 'benchmark.py', 'exec'), g)
import openmm as mm
import openmm.unit as unit
knobs = sorted({k for _, env in configs for k in env})

systems = {}

def run(test):
    if test not in systems:
        systems[test] = g['retrieveTestSystem'](test)
    system, positions, _ = systems[test]
    explicit = test not in ('gbsa', 'amoebagk')
    friction = (1 if explicit else 91)/unit.picoseconds
    integ = mm.LangevinMiddleIntegrator(300*unit.kelvin, friction, 0.004*unit.picoseconds)
    integ.setConstraintTolerance(1e-5)
    context = mm.Context(system, integ, mm.Platform.getPlatform('Metal'), {'Precision': 'single'})
    context.setPositions(positions)
    if test.startswith('amber'):
        mm.LocalEnergyMinimizer.minimize(context, 100*unit.kilojoules_per_mole/unit.nanometer)
    context.setVelocitiesToTemperature(300*unit.kelvin)
    integ.step(5)
    context.getState(energy=True)
    steps, elapsed, n = 0, 0.0, 20
    start = time.perf_counter()
    while elapsed < seconds:
        integ.step(n)
        context.getState(energy=True)
        steps += n
        elapsed = time.perf_counter()-start
        n = max(20, int(steps*0.25*seconds/elapsed))
    del context, integ
    return 4e-6*steps/elapsed*86400

for r in range(rounds):
    for test in tests:
        order = configs if r % 2 == 0 else configs[::-1]
        for label, env in order:
            for k in knobs:
                os.environ.pop(k, None)
            os.environ.update(env)
            if timeFile is not None:
                with open(timeFile, 'a') as f:
                    f.write(f'== {test} {label}\n')
            try:
                nsday = round(run(test), 3)
            except Exception as e:
                nsday = 'error: '+str(e)[:300]
            print(json.dumps({'round': r, 'test': test, 'label': label, 'ns_day': nsday, 'load': os.getloadavg()[0]}), flush=True)

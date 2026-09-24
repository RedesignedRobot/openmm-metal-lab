# Rebuild rate against padding, from the trajectory alone (CPU platform, no GPU).
# Replays the Metal trigger (rebuild when any atom moved more than padding/2 since the last
# build) for many paddings at once, and records D(t), the largest single-atom displacement
# over t steps. Usage: python disp.py test:steps[,test:steps...] warmSteps threads
import sys, os, time
import numpy as np
B = '/tmp/openmm-metal-bench/ultra-base/benchmarks'
os.chdir(B)
sys.path.insert(0, B)
ARGS = sys.argv[1:]
# benchmark.py runs its argument parser at module level, so load only the part above runOneTest.
src = open(os.path.join(B, 'benchmark.py')).read()
benchmark = type(sys)('benchmark')
exec(compile(src[:src.index('def runOneTest(')], 'benchmark.py', 'exec'), benchmark.__dict__)
import openmm as mm
from openmm import unit

FRACS = [round(0.02*i, 2) for i in range(2, 26)]
TMAX = 30

def mass_class(m):
    if m < 1.2:
        return 'H1'
    if m < 3.5:
        return 'Hhmr'
    return 'heavy'

def run(test, nsteps, warm, threads):
    t0 = time.time()
    system, positions, params = benchmark.retrieveTestSystem(test)
    rc = float(params['cutoff'])
    explicit = test not in ('gbsa', 'amoebagk')
    amber = test.startswith('amber')
    friction = (1.0 if explicit else 91.0)/unit.picoseconds
    integ = mm.LangevinMiddleIntegrator(300*unit.kelvin, friction, 0.004*unit.picoseconds)
    integ.setConstraintTolerance(1e-5)
    ctx = mm.Context(system, integ, mm.Platform.getPlatformByName('CPU'), {'Threads': threads})
    ctx.setPositions(positions)
    if amber:
        mm.LocalEnergyMinimizer.minimize(ctx, 100*unit.kilojoules_per_mole/unit.nanometer)
    ctx.setVelocitiesToTemperature(300*unit.kelvin)
    integ.step(warm)
    n = system.getNumParticles()
    cls = np.array([mass_class(system.getParticleMass(i).value_in_unit(unit.dalton)) for i in range(n)])
    ncls = {c: int((cls == c).sum()) for c in ('H1', 'Hhmr', 'heavy')}

    def pos():
        return ctx.getState(getPositions=True).getPositions(asNumpy=True).value_in_unit(unit.nanometer).astype(np.float64)

    x = pos()
    ring = [x]
    dmax = [[] for _ in range(TMAX+1)]
    argcls = [{} for _ in range(TMAX+1)]
    refs = [x.copy() for _ in FRACS]
    last = [0]*len(FRACS)
    intervals = [[] for _ in FRACS]
    trigcls = [{} for _ in FRACS]
    for k in range(1, nsteps+1):
        integ.step(1)
        x = pos()
        for i, f in enumerate(FRACS):
            half = 0.5*f*rc
            d2 = ((x-refs[i])**2).sum(1)
            j = int(d2.argmax())
            if d2[j] > half*half:
                intervals[i].append(k-last[i])
                last[i] = k
                refs[i] = x.copy()
                trigcls[i][cls[j]] = trigcls[i].get(cls[j], 0)+1
        for lag in range(1, len(ring)+1):
            d2 = ((x-ring[-lag])**2).sum(1)
            j = int(d2.argmax())
            dmax[lag].append(float(np.sqrt(d2[j])))
            argcls[lag][cls[j]] = argcls[lag].get(cls[j], 0)+1
        ring.append(x)
        if len(ring) > TMAX:
            ring.pop(0)

    print(f'## {test}: {n} atoms {ncls}, rc {rc} nm, {nsteps} steps after {warm} warm, {time.time()-t0:.0f} s')
    print('pad/rc  pad_nm  thresh_nm  rebuild_frac  mean_T  T_hist(T:count)  trigger_atom_class')
    for i, f in enumerate(FRACS):
        iv = intervals[i]
        r = len(iv)/nsteps
        hist = {}
        for t in iv:
            hist[t] = hist.get(t, 0)+1
        h = ' '.join(f'{t}:{hist[t]}' for t in sorted(hist))
        meanT = (sum(iv)/len(iv)) if iv else float('nan')
        print(f'{f:.2f}  {f*rc:.4f}  {0.5*f*rc:.4f}  {r:.3f}  {meanT:.2f}  {h}  {trigcls[i]}')
    print('lag  D_min  D_p10  D_median  D_p90  D_max  argmax_class')
    for lag in range(1, TMAX+1):
        a = np.array(dmax[lag])
        if len(a) == 0:
            continue
        q = np.percentile(a, [0, 10, 50, 90, 100])
        print(f'{lag}  {q[0]:.4f}  {q[1]:.4f}  {q[2]:.4f}  {q[3]:.4f}  {q[4]:.4f}  {argcls[lag]}')
    sys.stdout.flush()

if __name__ == '__main__':
    warm = int(ARGS[1])
    threads = ARGS[2]
    for spec in ARGS[0].split(','):
        test, steps = spec.split(':')
        run(test, int(steps), warm, threads)

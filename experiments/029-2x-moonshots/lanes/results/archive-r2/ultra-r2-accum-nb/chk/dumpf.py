"""Dump Metal forces and energy for benchmark.py systems, and compare two dumps.

usage: python dumpf.py dump <out.npz> <precision>[+det] <test>[,<test>...] [mdSteps]
       python dumpf.py cmp <a.npz> <b.npz>
The dump runs the given number of LangevinMiddle steps first (fixed seed), then saves the positions it reached.
With a positions file from another dump, pass it as mdSteps=@<file.npz> to evaluate at those positions.
"""
import os, sys
import numpy as np

BENCH = '/tmp/openmm-metal-bench/ultra-base/benchmarks'

def load(test):
    src = open(os.path.join(BENCH, 'benchmark.py')).read()
    src = src[:src.index('parser = argparse.ArgumentParser')]
    ns = {'__name__': 'bench'}
    cwd = os.getcwd()
    os.chdir(BENCH)
    exec(compile(src, 'benchmark.py', 'exec'), ns)
    system, positions, params = ns['retrieveTestSystem'](test)
    os.chdir(cwd)
    return system, positions

if sys.argv[1] == 'dump':
    import openmm as mm, openmm.unit as u
    out, prec, tests = sys.argv[2], sys.argv[3], sys.argv[4].split(',')
    md = sys.argv[5] if len(sys.argv) > 5 else '0'
    res = {}
    for test in tests:
        system, positions = load(test)
        integ = mm.LangevinMiddleIntegrator(300*u.kelvin, 1/u.picosecond, 0.004*u.picoseconds)
        integ.setRandomNumberSeed(2026)
        plat = mm.Platform.getPlatformByName('Metal')
        props = {'Precision': prec.split('+')[0]}
        if prec.endswith('+det'):
            props['DeterministicForces'] = 'true'
        ctx = mm.Context(system, integ, plat, props)
        if md.startswith('@'):
            ctx.setPositions(np.load(md[1:])[test+'_pos'])
        else:
            ctx.setPositions(positions)
            ctx.setVelocitiesToTemperature(300*u.kelvin, 2026)
            if int(md) > 0:
                integ.step(int(md))
        st = ctx.getState(getForces=True, getEnergy=True, getPositions=True)
        res[test+'_f'] = st.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
        res[test+'_e'] = st.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
        res[test+'_pos'] = st.getPositions(asNumpy=True).value_in_unit(u.nanometer)
        print(test, prec, 'E', res[test+'_e'], flush=True)
        del ctx
    np.savez(out, **res)
else:
    a, b = np.load(sys.argv[2]), np.load(sys.argv[3])
    for k in a.files:
        if not k.endswith('_f'):
            continue
        t = k[:-2]
        fa, fb = a[k], b[k]
        d = np.linalg.norm(fa-fb, axis=1)
        rel = np.sqrt((d**2).sum()/(np.linalg.norm(fa, axis=1)**2).sum())
        print('%-18s rel|dF| %.3e  max|dF| %.3e at %d  |F|max %.1f  dE %.4f (E %.2f)' % (t, rel, d.max(), d.argmax(), np.linalg.norm(fa,axis=1).max(), float(b[t+'_e'])-float(a[t+'_e']), float(a[t+'_e'])))

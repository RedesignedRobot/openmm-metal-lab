# NB_GATE equality check: each test runs 200 fixed-seed MD steps with the gate off twice (a control for
# run-to-run determinism) and once with it on, and compares final positions bit for bit. Energies are
# printed but not compared: the energy sum varies in the last digits from run to run.
# The gate only skips work on steps with no rebuild, so gate-on must match wherever off matches off.
# usage: gatecheck.py <benchmarks dir> <tests> [NB_GATE value for the on run, default 1]
import os, sys
import numpy as np
bdir, tests = sys.argv[1], sys.argv[2].split(',')
gateOn = sys.argv[3] if len(sys.argv) > 3 else '1'
os.chdir(bdir)
src = open('benchmark.py').read().split('# Parse the command line options.')[0]
g = {'__name__': 'bench'}
exec(compile(src, 'benchmark.py', 'exec'), g)
import openmm as mm
import openmm.unit as unit

def run(test, gate):
    os.environ['NB_GATE'] = gate
    system, positions, _ = g['retrieveTestSystem'](test)
    integ = mm.LangevinMiddleIntegrator(300*unit.kelvin, 1/unit.picoseconds, 0.004*unit.picoseconds)
    integ.setConstraintTolerance(1e-5)
    integ.setRandomNumberSeed(1234)
    context = mm.Context(system, integ, mm.Platform.getPlatform('Metal'), {'Precision': 'single'})
    context.setPositions(positions)
    context.setVelocitiesToTemperature(300*unit.kelvin, 4321)
    integ.step(200)
    state = context.getState(positions=True, energy=True)
    pos = state.getPositions(asNumpy=True).value_in_unit(unit.nanometer)
    energy = state.getPotentialEnergy().value_in_unit(unit.kilojoule_per_mole)
    del context, integ
    return pos, energy

for test in tests:
    a, ea = run(test, '0')
    b, eb = run(test, '0')
    c, ec = run(test, gateOn)
    control = np.array_equal(a, b)
    same = np.array_equal(a, c)
    verdict = 'ok' if same else ('FAIL' if control else 'inconclusive (off vs off differs too)')
    print('%s %s gate %s: max |dx| off/off %.3g, off/on %.3g nm; energy off %.6f off %.6f on %.6f' %
          (verdict, test, gateOn, np.abs(a-b).max(), np.abs(a-c).max(), ea, eb, ec), flush=True)

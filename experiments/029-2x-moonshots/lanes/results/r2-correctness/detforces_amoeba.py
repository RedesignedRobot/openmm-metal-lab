"""detforces.py for AMOEBA and HIPPO: DeterministicForces in repeated contexts and three fresh processes.

usage: python detforces_amoeba.py <benchmarks dir> <out>
amoebagk and amoebapme come from benchmark.py. benchmark.py has no HIPPO test, so "hippo" is built here: every
water of 5dfr_solv-cube_equil.pdb in its box, with the HIPPO water parameters of TestHippoNonbondedForce.h
(buildWaterSystem), PME, cutoff 0.7 nm, switch 0.6 nm. The last column compares the deterministic forces with the
default (DeterministicForces false) forces of the same process, as max |dF| / max |F|.
"""
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import numpy as np

TESTS = ['amoebagk', 'amoebapme', 'hippo']
PRECISIONS = ['single', 'mixed']


def bitwise(a, b):
    return a.shape == b.shape and a.dtype == b.dtype and a.tobytes() == b.tobytes()


def hippo_system():
    import openmm as mm
    import openmm.app as app
    import openmm.unit as u
    pdb = app.PDBFile('5dfr_solv-cube_equil.pdb')
    waters = [r for r in pdb.topology.residues() if r.name == 'HOH']
    all_positions = pdb.getPositions(asNumpy=True).value_in_unit(u.nanometer)
    system = mm.System()
    hippo = mm.HippoNonbondedForce()
    system.addForce(hippo)
    hippo.setExtrapolationCoefficients([0.042, 0.635, 0.414])
    bohr = 0.52917720859
    ds = 0.1*bohr
    qs = 0.01*bohr*bohr/3.0
    c6s = math.sqrt(4.184)*0.001
    ps = math.sqrt(4.184*0.1)
    positions = []
    for mol, residue in enumerate(waters):
        atoms = sorted(residue.atoms(), key=lambda a: a.element.symbol != 'O')
        positions += [all_positions[a.index] for a in atoms]
        system.addParticle(15.995)
        system.addParticle(1.008)
        system.addParticle(1.008)
        hippo.addParticle(-0.38280, [0.0, 0.0, ds*0.05477], [qs*0.69866, 0.0, 0.0, 0.0, qs*-0.60471, 0.0, 0.0, 0.0, qs*-0.09395], 6.0,
                          10*4.7075, 4.184*1326.0, 10*40.0, c6s*18.7737, ps*2.7104, -2.4233, 10*4.3097,
                          0.001*0.795, mm.HippoNonbondedForce.Bisector, 3*mol+1, 3*mol+2, -1)
        for other in (3*mol+2, 3*mol+1):
            hippo.addParticle(0.19140, [0.0, 0.0, ds*-0.20097], [qs*0.03881, 0.0, 0.0, 0.0, qs*0.02214, 0.0, 0.0, 0.0, qs*-0.06095], 1.0,
                              10*4.7909, 0.0, 10*3.5582, c6s*4.5670, ps*2.0037, -0.8086, 10*4.6450,
                              0.001*0.341, mm.HippoNonbondedForce.ZThenX, 3*mol, other, -1)
        hippo.addException(3*mol, 3*mol+1, 0.0, 0.0, 0.2, 0.0, 0.0, 0.0)
        hippo.addException(3*mol, 3*mol+2, 0.0, 0.0, 0.2, 0.0, 0.0, 0.0)
        hippo.addException(3*mol+1, 3*mol+2, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0)
    system.setDefaultPeriodicBoxVectors(*pdb.topology.getPeriodicBoxVectors())
    hippo.setNonbondedMethod(mm.HippoNonbondedForce.PME)
    hippo.setCutoffDistance(0.7)
    hippo.setSwitchingDistance(0.6)
    return system, np.array(positions)


def worker(bench, out):
    import openmm as mm
    import openmm.unit as u
    os.chdir(bench)
    source = Path('benchmark.py').read_text()
    namespace = {}
    exec(source[:source.index('def serializeTest')], namespace)
    arrays = {}
    platform = mm.Platform.getPlatformByName('Metal')

    def evaluate(system, positions, properties):
        ctx = mm.Context(system, mm.VerletIntegrator(0.001), platform, properties)
        ctx.setPositions(positions)
        state = ctx.getState(getForces=True, getEnergy=True)
        return ctx, np.array(state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)), state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)

    for test in TESTS:
        if test == 'hippo':
            system, positions = hippo_system()
        else:
            system, positions, _ = namespace['retrieveTestSystem'](test)
        print(test, system.getNumParticles(), 'atoms', flush=True)
        for precision in PRECISIONS:
            key = test + '_' + precision
            properties = {'Precision': precision, 'DeterministicForces': 'true'}
            ctx, arrays[f'{key}_f0'], arrays[f'{key}_e0'] = evaluate(system, positions, properties)
            state = ctx.getState(getForces=True, getEnergy=True)
            arrays[f'{key}_f1'] = np.array(state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer))
            arrays[f'{key}_e1'] = state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
            del ctx
            ctx, arrays[f'{key}_f2'], arrays[f'{key}_e2'] = evaluate(system, positions, properties)
            del ctx
            ctx, arrays[f'{key}_fnd'], _ = evaluate(system, positions, {'Precision': precision})
            del ctx
    np.savez(out, **arrays)


def main(bench, output):
    bench, output = str(Path(bench).resolve()), Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    failed = False
    with tempfile.TemporaryDirectory(prefix='detforces-', dir=output.parent) as tmp:
        runs = []
        for run in range(3):
            path = Path(tmp) / f'{run}.npz'
            subprocess.run([sys.executable, str(Path(__file__).resolve()), '--worker', bench, str(path)], check=True)
            with np.load(path) as data:
                runs.append(dict(data))
        with output.open('w') as out:
            def emit(line):
                print(line, file=out, flush=True)
                print(line, flush=True)
            emit('test precision same-context-forces new-context-forces fresh-process-forces energy-bitwise max|dF| det-vs-default')
            for test in TESTS:
                for precision in PRECISIONS:
                    key = test + '_' + precision
                    reference = runs[0][key+'_f0']
                    same = all(bitwise(r[key+'_f0'], r[key+'_f1']) for r in runs)
                    fresh = all(bitwise(r[key+'_f0'], r[key+'_f2']) for r in runs)
                    processes = all(bitwise(reference, r[key+'_f0']) for r in runs)
                    energy = all(r[key+f'_e{i}'] == runs[0][key+'_e0'] for r in runs for i in range(3))
                    maximum = max(np.abs(reference-r[key+f'_f{i}']).max() for r in runs for i in range(3))
                    default = max(np.abs(r[key+'_fnd']-r[key+'_f0']).max() for r in runs)/np.abs(reference).max()
                    labels = ['identical' if x else 'DIFFERS' for x in (same, fresh, processes, energy)]
                    emit(f'{test} {precision} {" ".join(labels)} {maximum:.3e} {default:.3e}')
                    failed |= not (same and fresh and processes)
            emit('FAIL' if failed else 'PASS')
    return int(failed)


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--worker':
        worker(*sys.argv[2:])
    elif len(sys.argv) == 3:
        sys.exit(main(*sys.argv[1:]))
    else:
        sys.exit('usage: python detforces_amoeba.py <benchmarks dir> <out>')

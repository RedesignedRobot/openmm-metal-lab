"""Check DeterministicForces in repeated contexts and three fresh processes.

usage: python detforces.py <benchmarks dir> <out>
The verdict tests forces bitwise. Energy equality is reported separately because
single-precision total energies can vary by one float32 ulp across contexts.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

import numpy as np

TESTS = ['gbsa', 'rf', 'pme', 'apoa1rf', 'apoa1pme', 'apoa1ljpme']
PRECISIONS = ['single', 'mixed']


def bitwise(a, b):
    return a.shape == b.shape and a.dtype == b.dtype and a.tobytes() == b.tobytes()


def worker(bench, out):
    import openmm as mm
    import openmm.unit as u
    os.chdir(bench)
    source = Path('benchmark.py').read_text()
    namespace = {}
    exec(source[:source.index('def serializeTest')], namespace)
    arrays = {}
    for test in TESTS:
        system, positions, _ = namespace['retrieveTestSystem'](test)
        for precision in PRECISIONS:
            key = test + '_' + precision
            for fresh in range(2):
                ctx = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName('Metal'),
                                 {'Precision': precision, 'DeterministicForces': 'true'})
                ctx.setPositions(positions)
                for repeat in range(2 if fresh == 0 else 1):
                    index = repeat if fresh == 0 else 2
                    state = ctx.getState(getForces=True, getEnergy=True)
                    arrays[f'{key}_f{index}'] = np.array(state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer))
                    arrays[f'{key}_e{index}'] = state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
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
            emit('test precision same-context-forces new-context-forces fresh-process-forces energy-bitwise max|dF|')
            for test in TESTS:
                for precision in PRECISIONS:
                    key = test + '_' + precision
                    reference = runs[0][key+'_f0']
                    same = all(bitwise(r[key+'_f0'], r[key+'_f1']) for r in runs)
                    fresh = all(bitwise(r[key+'_f0'], r[key+'_f2']) for r in runs)
                    processes = all(bitwise(reference, r[key+'_f0']) for r in runs)
                    energy = all(r[key+f'_e{i}'] == runs[0][key+'_e0'] for r in runs for i in range(3))
                    maximum = max(np.abs(reference-r[key+f'_f{i}']).max() for r in runs for i in range(3))
                    labels = ['identical' if x else 'DIFFERS' for x in (same, fresh, processes, energy)]
                    emit(f'{test} {precision} {" ".join(labels)} {maximum:.3e}')
                    failed |= not (same and fresh and processes)
            emit('FAIL' if failed else 'PASS')
    return int(failed)


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--worker':
        worker(*sys.argv[2:])
    elif len(sys.argv) == 3:
        sys.exit(main(*sys.argv[1:]))
    else:
        sys.exit('usage: python detforces.py <benchmarks dir> <out>')

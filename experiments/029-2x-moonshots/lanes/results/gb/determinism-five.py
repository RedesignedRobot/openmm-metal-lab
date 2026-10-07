from pathlib import Path
import importlib.util
import subprocess
import sys
import numpy as np

ROOT = Path('/tmp/openmm-metal-bench/ultra-m29-gb')
BENCH = '/tmp/openmm-metal-bench/ultra-base/benchmarks'
spec = importlib.util.spec_from_file_location('detforces', '/tmp/openmm-metal-bench/ultra-tools/detforces.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
m.TESTS = ['gbsa']
if len(sys.argv) == 3 and sys.argv[1] == '--worker':
    m.worker(BENCH, sys.argv[2])
else:
    out = ROOT / 'determinism'
    out.mkdir(exist_ok=True)
    for run in range(5):
        subprocess.run([sys.executable, __file__, '--worker', str(out / f'run-{run}.npz')], check=True)
    runs = [np.load(out / f'run-{run}.npz') for run in range(5)]
    for precision in m.PRECISIONS:
        key = 'gbsa_' + precision
        reference = runs[0][key + '_f0']
        for run in runs:
            for context in range(3):
                assert m.bitwise(reference, run[key + f'_f{context}']), (precision, context)
        print(precision, 'PASS: forces bitwise across five processes, new contexts and repeated evaluations', flush=True)

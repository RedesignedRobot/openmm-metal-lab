"""Fresh-process force spread at identical benchmark positions, no MD.

Run under lease.sh --correctness using the candidate venv Python:
force-spread.py BENCH OUT TEST PRECISION [--deterministic]
The driver starts three fresh worker processes and reports forces separately
from energies. Forces are requested alone to exercise the concurrent D3 path.
It never replaces the shared detforces.py acceptance check.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('bench')
parser.add_argument('out')
parser.add_argument('test')
parser.add_argument('precision', choices=('single', 'mixed'))
parser.add_argument('--deterministic', action='store_true')
parser.add_argument('--worker', action='store_true')
args = parser.parse_args()
bench = Path(args.bench).resolve()
out = Path(args.out).resolve()

if args.worker:
    import numpy as np
    import openmm as mm
    import openmm.unit as u
    os.chdir(bench)
    source = (bench/'benchmark.py').read_text()
    namespace = {'__name__': 'benchmark_definitions'}
    exec(source[:source.index('def serializeTest')], namespace)
    system, positions, _ = namespace['retrieveTestSystem'](args.test)
    integrator = mm.VerletIntegrator(0.001)
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName('Metal'),
                         {'Precision': args.precision,
                          'DeterministicForces': str(args.deterministic).lower()})
    context.setPositions(positions)
    state = context.getState(getForces=True)
    force = state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
    energy = context.getState(getEnergy=True).getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
    np.savez(out, force=force, energy=energy)
else:
    import numpy as np
    out.mkdir(parents=True, exist_ok=True)
    files = []
    for index in range(3):
        path = out/f'process-{index}.npz'
        command = [sys.executable, str(Path(__file__).resolve()), str(bench), str(path),
                   args.test, args.precision, '--worker']
        if args.deterministic:
            command.append('--deterministic')
        subprocess.run(command, check=True)
        files.append(path)
    with np.load(files[0]) as first:
        reference = first['force'].copy()
        energies = [float(first['energy'])]
    if not np.isfinite(reference).all():
        raise RuntimeError('nonfinite reference force')
    equal, maximum, relative = True, 0.0, 0.0
    for path in files[1:]:
        with np.load(path) as data:
            force = data['force']
            if not np.isfinite(force).all():
                raise RuntimeError('nonfinite force')
            delta = force-reference
            equal &= (force.dtype == reference.dtype and force.shape == reference.shape
                      and force.tobytes() == reference.tobytes())
            maximum = max(maximum, float(np.abs(delta).max()))
            relative = max(relative, float(np.linalg.norm(delta)/max(np.linalg.norm(reference), 1e-300)))
            energies.append(float(data['energy']))
    if not np.isfinite(energies).all():
        raise RuntimeError('nonfinite energy')
    result = dict(test=args.test, precision=args.precision, deterministic=args.deterministic,
                  force_bitwise=bool(equal), force_only_state=True, max_abs_force_spread=maximum,
                  relative_force_spread=relative, energy_spread=max(energies)-min(energies),
                  files=[str(path) for path in files])
    (out/'verdict.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result), flush=True)
    if args.deterministic and not equal:
        raise SystemExit(1)

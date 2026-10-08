"""Read benchmark System sizes on CPU; query Metal limits under a correctness lease."""
import json
import os
from pathlib import Path
import subprocess
import openmm as mm
root = Path('/tmp/openmm-metal-bench')
lane = root/'ultra-m29-nonbonded'
bench = root/'ultra-base/benchmarks'
os.chdir(bench)
source = (bench/'benchmark.py').read_text()
namespace = {'__name__': 'benchmark_definitions'}
exec(source[:source.index('def serializeTest')], namespace)
counts = {}
exclusion_counts = {}
for test in ('gbsa', 'rf', 'pme', 'apoa1rf', 'apoa1pme', 'apoa1ljpme',
             'amber20-dhfr', 'amber20-cellulose', 'amber20-stmv'):
    system, positions, parameters = namespace['retrieveTestSystem'](test)
    counts[test] = system.getNumParticles()
    tiles = {(i, i) for i in range((counts[test]+31)//32)}
    for force in system.getForces():
        if isinstance(force, mm.NonbondedForce):
            for index in range(force.getNumExceptions()):
                atom1, atom2, *_ = force.getExceptionParameters(index)
                x, y = atom1//32, atom2//32
                tiles.add((max(x, y), min(x, y)))
    exclusion_counts[test] = len(tiles)
    del tiles
    del system, positions, parameters
(lane/'system-exclusion-tiles.json').write_text(json.dumps(exclusion_counts, indent=2)+'\n')
(lane/'system-atoms.json').write_text(json.dumps(counts, indent=2)+'\n')
command = [str(root/'ultra-tools/lease.sh'), '--correctness', 'ultra-m29-nonbonded',
           'query force-block memory limits', '/usr/bin/env',
           'DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer', '/usr/bin/xcrun',
           'swift', str(lane/'device-memory.swift')]
command += [f'{test}:{count}:{exclusion_counts[test]}' for test, count in counts.items()]
with (lane/'device-memory-records.json').open('w') as output:
    subprocess.run(command, stdout=output, check=True)

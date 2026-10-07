"""Interleaved A/B of benchmark.py configurations, host clock (benchmark.py times step() with datetime.now()).

usage: ab.py ROUNDS SECONDS TESTS PRECISIONS  NAME=ROOT[:PROPS[:ENV]] ...
TESTS and PRECISIONS are comma lists. PROPS and ENV are "Name=value;Name=value".
The order of configurations reverses every other round.
"""
import os, re, subprocess, sys, statistics
L = '/tmp/openmm-metal-bench/ultra-pme'
rounds, seconds = int(sys.argv[1]), sys.argv[2]
tests, precisions = sys.argv[3].split(','), sys.argv[4].split(',')
configs = []
for spec in sys.argv[5:]:
    name, rest = spec.split('=', 1)
    root, _, rest = rest.partition(':')
    props, _, envs = rest.partition(':')
    configs.append((name, root, props.replace(';', ','), dict(kv.split('=', 1) for kv in envs.split(';') if kv)))
results = {}
for test in tests:
    for prec in precisions:
        for r in range(rounds):
            order = configs if r % 2 == 0 else configs[::-1]
            for name, root, props, extraEnv in order:
                load = os.getloadavg()[0]
                env = dict(os.environ, EXTRA_PROPS=props, **extraEnv)
                out = subprocess.run(['/bin/sh', f'{L}/env.sh', root, f'{L}/bprops.py', f'{L}/bench/benchmark.py',
                        '--platform', 'Metal', '--test', test, '--precision', prec, '--seconds', seconds],
                        cwd=f'{L}/bench', env=env, capture_output=True, text=True).stdout
                m = re.search(r'ns_per_day: ([0-9.]+)', out)
                v = float(m.group(1)) if m else float('nan')
                results.setdefault((test, prec, name), []).append(v)
                print(f'{test} {prec} round {r} {name} {v:.2f} ns/day load1={load:.2f}', flush=True)
base = configs[0][0]
for test in tests:
    for prec in precisions:
        b = statistics.median(results[(test, prec, base)])
        line = ' '.join(f'{n}={statistics.median(results[(test, prec, n)]):.2f} ({statistics.median(results[(test, prec, n)])/b:.3f})' for n, _, _, _ in configs)
        print(f'SUMMARY {test} {prec} {line}', flush=True)

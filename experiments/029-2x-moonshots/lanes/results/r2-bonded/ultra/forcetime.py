"""Force-evaluation time per test and arm, fresh process per (arm, test, round).

VerletIntegrator(1e-9 ps) with constraints dropped: positions never move, so each step is one force
evaluation (no energy) plus a trivial integration kernel, and wrong forces from a probe cannot blow up.
Probe only; published ratios use benchmark.py.
usage: forcetime.py <bench dir> <out file> <rounds> <tests> <arm>...   arm = label=python[:VAR=value]
"""
import json, os, subprocess, sys, time

child = r'''
import sys, time
bench = sys.argv[1] + "/benchmark.py"
src = open(bench).read()
g = {"__name__": "forcetime"}
exec(compile(src[:src.index("def serializeTest")], bench, "exec"), g)
import openmm as mm
test, prec = sys.argv[2], sys.argv[3]
system, positions, _ = g["retrieveTestSystem"](test)
while system.getNumConstraints() > 0:
    system.removeConstraint(0)
for f in system.getForces():
    if f.__class__.__name__ == "MonteCarloBarostat":
        f.setFrequency(0)
integ = mm.VerletIntegrator(1e-9)
context = mm.Context(system, integ, mm.Platform.getPlatformByName("Metal"), {"Precision": prec})
context.setPositions(positions)
integ.step(20)
context.getState(getPositions=True)
t0 = time.perf_counter(); integ.step(20); context.getState(getPositions=True)
per = (time.perf_counter()-t0)/20
steps = max(20, int(2.0/per))
times = []
for r in range(5):
    t0 = time.perf_counter()
    integ.step(steps)
    context.getState(getPositions=True)
    times.append((time.perf_counter()-t0)/steps*1e6)
times.sort()
print("RESULT", times[2], times[0], steps)
'''

bench, out, rounds, tests = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4].split(',')
arms = []
extra = out + '.extra-arms'  # one arm per line, appended to argv; lets a queued run pick up a new build
for a in sys.argv[5:] + (open(extra).read().split() if os.path.exists(extra) else []):
    label, spec = a.split('=', 1)
    parts = spec.split(':')
    env = dict(p.split('=', 1) for p in parts[2:])
    arms.append((label, parts[0], parts[1], env))
os.chdir(bench)
with open(out, 'a') as f:
    for r in range(rounds):
        for test in tests:
            order = arms if r % 2 == 0 else arms[::-1]
            for label, python, prec, env in order:
                e = dict(os.environ)
                e.update(env)
                p = subprocess.run([python, '-c', child, bench, test, prec], env=e, capture_output=True, text=True)
                line = [l for l in p.stdout.splitlines() if l.startswith('RESULT')]
                rec = {'round': r, 'test': test, 'arm': label, 'prec': prec}
                if line:
                    v = line[0].split()
                    rec.update(us=float(v[1]), us_min=float(v[2]), steps=int(v[3]))
                else:
                    rec['error'] = p.stderr[-500:]
                f.write(json.dumps(rec) + '\n')
                f.flush()
                print(json.dumps(rec), flush=True)

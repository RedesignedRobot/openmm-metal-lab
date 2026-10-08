# Time force evaluations with VerletIntegrator(1e-9 ps): positions never move, so every step is one
# force evaluation plus a trivial integration kernel, and wrong forces cannot blow the run up.
# Usage: forcetime.py TEST PRECISION STEPS REPS
import sys, time, os
bench = "/tmp/openmm-metal-bench/ultra-base/benchmarks/benchmark.py"
src = open(bench).read()
src = src[:src.index('def serializeTest')]
g = {'__name__': 'forcetime'}
exec(compile(src, bench, 'exec'), g)
import openmm as mm, openmm.unit as unit
test, prec, steps, reps = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
system, positions, _ = g['retrieveTestSystem'](test)
# Verlet divides by dt, so use a step too small to move any atom in single precision; constraints are
# dropped since they cost no force work.
while system.getNumConstraints() > 0:
    system.removeConstraint(0)
integ = mm.VerletIntegrator(1e-9)
platform = mm.Platform.getPlatformByName('Metal')
context = mm.Context(system, integ, platform, {'Precision': prec, 'DisablePmeStream': 'true'})
context.setPositions(positions)
integ.step(50)
context.getState(getPositions=True)
times = []
for r in range(reps):
    t0 = time.perf_counter()
    integ.step(steps)
    context.getState(getPositions=True)
    times.append((time.perf_counter()-t0)/steps*1e3)
times.sort()
print(f"{test} {prec} ms/eval median {times[len(times)//2]:.4f} min {times[0]:.4f}")

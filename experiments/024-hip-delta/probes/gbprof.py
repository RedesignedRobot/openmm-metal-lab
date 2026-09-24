"""Run one benchmark.py system on Metal with GpuProf.h recording a window of steps.

usage: GPUPROF=kernels|buffers GPUPROF_OUT=<file> python gbprof.py <examples/benchmarks dir> <test> <steps> [ForceClass,...]
Warms up 200 steps, then sets GPUPROF_ON for <steps> steps followed by getState(energy), as
benchmark.py does. Prints the step count, the window's host time (time.perf_counter) and the
process's CPU time over the window (time.process_time, all threads).
"""
import os
import sys
import time

import openmm as mm
import openmm.unit as u

bench = os.path.abspath(sys.argv[1])
test = sys.argv[2]
steps = int(sys.argv[3])
drop = sys.argv[4].split(",") if len(sys.argv) > 4 else []
os.chdir(bench)
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])

system, positions, _ = retrieveTestSystem(test)
for i in reversed(range(system.getNumForces())):
    if type(system.getForce(i)).__name__ in drop:
        system.removeForce(i)
friction = (91 if test == "gbsa" else 1)/u.picoseconds
integrator = mm.LangevinMiddleIntegrator(300*u.kelvin, friction, 0.004*u.picoseconds)
integrator.setConstraintTolerance(1e-5)
context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), {"Precision": "single"})
context.setPositions(positions)
context.setVelocitiesToTemperature(300*u.kelvin)
integrator.step(200)
context.getState(energy=True)
os.environ["GPUPROF_ON"] = "1"
start, cpuStart = time.perf_counter(), time.process_time()
integrator.step(steps)
context.getState(energy=True)
elapsed, cpu = time.perf_counter()-start, time.process_time()-cpuStart
del os.environ["GPUPROF_ON"]
print(f"{test} drop={','.join(drop) or 'none'} steps {steps} host_s {elapsed:.6f} us_per_step {elapsed/steps*1e6:.2f} "
      f"ns_per_day {steps*0.004*86400e-3/elapsed:.1f} cpu_s {cpu:.6f} cpu_per_host {cpu/elapsed:.2f}", flush=True)

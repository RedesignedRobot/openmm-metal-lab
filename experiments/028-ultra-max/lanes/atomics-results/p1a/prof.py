"""prof.py from the profiler lane, changed for the atomics probe 1a: force evaluations only.

VerletIntegrator(1e-9 ps) with constraints removed, so positions never move and an atomicAdd variant
with wrong forces cannot blow the run up or change the neighbor list. Everything else is prof.py's.
usage: [GPUPROF=counters GPUPROF_OUT=<file>] python prof.py <examples/benchmarks dir> <test> <precision> [platform]
"""
import os
import sys
import time

import openmm as mm
import openmm.unit as unit

bench = os.path.abspath(sys.argv[1])
test, precision = sys.argv[2], sys.argv[3]
platformName = sys.argv[4] if len(sys.argv) > 4 else "Metal"
seconds = float(os.environ.get("PROF_SECONDS", "4"))
os.chdir(bench)
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])

system, positions, _ = retrieveTestSystem(test)
for i in reversed(range(system.getNumConstraints())):
    system.removeConstraint(i)
integrator = mm.VerletIntegrator(1e-9)
properties = {"Precision": precision}
for item in filter(None, os.environ.get("PROF_PROPS", "").split(",")):
    key, value = item.split("=")
    properties[key] = value
platform = mm.Platform.getPlatformByName(platformName)
context = mm.Context(system, integrator, platform, properties)
context.setPositions(positions)
integrator.step(5)
context.getState(energy=True)

def window(steps):
    start, cpu = time.perf_counter(), time.process_time()
    integrator.step(steps)
    context.getState(energy=True)
    return time.perf_counter()-start, time.process_time()-cpu

elapsed, _ = window(20)
steps = max(20, int(20*seconds/elapsed))
dt = integrator.getStepSize().value_in_unit(unit.picoseconds)
for name in "ABC":
    if name == "B":
        os.environ["GPUPROF_ON"] = "1"
    elapsed, cpu = window(steps)
    os.environ.pop("GPUPROF_ON", None)
    print(f"window {name} {test} {precision} {platformName} steps {steps} host_s {elapsed:.6f} us_per_step {elapsed/steps*1e6:.2f} "
          f"ns_per_day {steps*dt*86400e-3/elapsed:.2f} cpu_per_host {cpu/elapsed:.2f}", flush=True)

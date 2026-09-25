"""Run one benchmark.py test and time three windows of steps, the middle one with GpuProf.h recording.

usage: [GPUPROF=buffers|counters|split|kernels GPUPROF_OUT=<file>] [PROF_SECONDS=4] [PROF_PROPS="Key=Value,..."]
       python prof.py <examples/benchmarks dir> <test> <precision> [platform]
The system, integrator, step size and minimization follow benchmark.py's runOneTest (NVT, hbonds).
Each window is step(n) followed by getState(energy), as benchmark.py times. Window A and C run with
GPUPROF_ON unset, window B with it set, so B/A prices the recording. Host clock: time.perf_counter.
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
explicit = test not in ("gbsa", "amoebagk")
amoeba = test in ("amoebagk", "amoebapme")
temperature = 300*unit.kelvin
friction = (1 if explicit else 91)/unit.picoseconds
if amoeba:
    integrator = mm.MTSLangevinIntegrator(temperature, friction, 0.002*unit.picoseconds, [(0, 2), (1, 1)])
else:
    integrator = mm.LangevinMiddleIntegrator(temperature, friction, 0.004*unit.picoseconds)
integrator.setConstraintTolerance(1e-5)
properties = {"Precision": precision}
for item in filter(None, os.environ.get("PROF_PROPS", "").split(",")):
    key, value = item.split("=")
    properties[key] = value
platform = mm.Platform.getPlatformByName(platformName)
context = mm.Context(system, integrator, platform, properties)
print(f"openmm {mm.__file__} plugins {' '.join(n for n in mm.pluginLoadedLibNames if platformName in n)}", flush=True)
context.setPositions(positions)
if test.startswith("amber"):
    mm.LocalEnergyMinimizer.minimize(context, 100*unit.kilojoules_per_mole/unit.nanometer)
context.setVelocitiesToTemperature(temperature)
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

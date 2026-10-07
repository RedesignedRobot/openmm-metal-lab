"""Run one benchmark.py test or one FAH unit and time three windows of steps, the middle one with GpuProf.h recording.

usage: [GPUPROF=buffers|counters|split|kernels GPUPROF_OUT=<file>] [PROF_SECONDS=4] [PROF_PROPS="Key=Value,..."]
       [PROF_PIDFILE=<file>]
       python prof.py <examples/benchmarks dir> <test or FAH unit dir> <precision> [platform]
For a test, the system, integrator, step size and minimization follow benchmark.py's runOneTest (NVT, hbonds).
A FAH unit dir holds system, integrator and state .xml or .xml.bz2 and loads as a core loads it: deserialize,
Context, setState. A CustomIntegrator with `step` and `n_steps` globals (the neq unit) steps in whole protocol
cycles of 2*n_steps, with `step` and `protocol_work` reset before each, as fah/prof/profwu.py does.
Each window is step(n) followed by getState(energy), as benchmark.py times. Window A and C run with
GPUPROF_ON unset, window B with it set, so B/A prices the recording. Host clock: time.perf_counter.
"""
import bz2
import os
import sys
import time

if os.environ.get("PROF_PIDFILE"):  # shader.sh stops a run xctrace left behind by this pid
    with open(os.environ["PROF_PIDFILE"], "w") as f:
        f.write(f"{os.getpid()}\n")

import openmm as mm
import openmm.unit as unit

bench = os.path.abspath(sys.argv[1])
test, precision = sys.argv[2], sys.argv[3]
platformName = sys.argv[4] if len(sys.argv) > 4 else "Metal"
seconds = float(os.environ.get("PROF_SECONDS", "4"))
properties = {"Precision": precision}
for item in filter(None, os.environ.get("PROF_PROPS", "").split(",")):
    key, value = item.split("=")
    properties[key] = value
platform = mm.Platform.getPlatformByName(platformName)


def load_unit(unit_dir, name):
    for path, opener in ((os.path.join(unit_dir, name+".xml.bz2"), bz2.open), (os.path.join(unit_dir, name+".xml"), open)):
        if os.path.exists(path):
            with opener(path, "rt") as f:
                return mm.XmlSerializer.deserialize(f.read())
    raise FileNotFoundError(os.path.join(unit_dir, name+".xml"))


def protocol_cycle(integrator):
    if not isinstance(integrator, mm.CustomIntegrator):
        return 0
    names = {integrator.getGlobalVariableName(i) for i in range(integrator.getNumGlobalVariables())}
    return int(2*integrator.getGlobalVariableByName("n_steps")) if {"step", "n_steps"} <= names else 0


def unit_context(unit_dir):
    system, integrator = load_unit(unit_dir, "system"), load_unit(unit_dir, "integrator")
    context = mm.Context(system, integrator, platform, properties)
    context.setState(load_unit(unit_dir, "state"))
    return system, integrator, context


def benchmark_context(test):
    os.chdir(bench)
    source = open("benchmark.py").read()
    exec(source[:source.index("def serializeTest")], globals())
    system, positions, _ = retrieveTestSystem(test)
    explicit = test not in ("gbsa", "amoebagk")
    temperature = 300*unit.kelvin
    friction = (1 if explicit else 91)/unit.picoseconds
    if test in ("amoebagk", "amoebapme"):
        integrator = mm.MTSLangevinIntegrator(temperature, friction, 0.002*unit.picoseconds, [(0, 2), (1, 1)])
    else:
        integrator = mm.LangevinMiddleIntegrator(temperature, friction, 0.004*unit.picoseconds)
    integrator.setConstraintTolerance(1e-5)
    context = mm.Context(system, integrator, platform, properties)
    context.setPositions(positions)
    if test.startswith("amber"):
        mm.LocalEnergyMinimizer.minimize(context, 100*unit.kilojoules_per_mole/unit.nanometer)
    context.setVelocitiesToTemperature(temperature)
    return system, integrator, context


if os.path.isdir(test):
    system, integrator, context = unit_context(os.path.abspath(test))
    test = os.path.basename(os.path.normpath(test))
else:
    system, integrator, context = benchmark_context(test)
cycle = protocol_cycle(integrator)
block = cycle or 20
print(f"openmm {mm.__file__} plugins {' '.join(n for n in mm.pluginLoadedLibNames if platformName in n)} "
      f"target {test} atoms {system.getNumParticles()} cycle {cycle}", flush=True)


def advance(steps):
    if not cycle:
        integrator.step(steps)
        return
    for _ in range(steps//cycle):
        integrator.setGlobalVariableByName("step", 0)
        integrator.setGlobalVariableByName("protocol_work", 0)
        integrator.step(cycle)


def window(steps):
    start, cpu = time.perf_counter(), time.process_time()
    advance(steps)
    context.getState(energy=True)
    return time.perf_counter()-start, time.process_time()-cpu


advance(block)
context.getState(energy=True)
elapsed, _ = window(block)
steps = max(block, -(-int(block*seconds/elapsed)//block)*block)
dt = integrator.getStepSize().value_in_unit(unit.picoseconds)
for name in "ABC":
    if name == "B":
        os.environ["GPUPROF_ON"] = "1"
    elapsed, cpu = window(steps)
    os.environ.pop("GPUPROF_ON", None)
    print(f"window {name} {test} {precision} {platformName} steps {steps} host_s {elapsed:.6f} us_per_step {elapsed/steps*1e6:.2f} "
          f"ns_per_day {steps*dt*86400e-3/elapsed:.2f} cpu_per_host {cpu/elapsed:.2f}", flush=True)

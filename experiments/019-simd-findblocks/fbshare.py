"""Share of step time spent in findBlocksWithInteractions, with the scratch instrumentation of
time-findblocks.patch applied to the install.

usage: OPENMM_TIME_FINDBLOCKS=<times.txt> python fbshare.py <benchmarks-dir> <test> <precision> <steps>
The system, integrator and preparation are those of examples/benchmarks/benchmark.py.  After
the preparation and a 200-step warm-up it times <steps> steps by host wall clock
(time.perf_counter, synchronized by getState).  Each force evaluation dispatches
findBlocksWithInteractions once, so after dropping the last line of times.txt (the closing
getState) the last <steps> lines are the timed steps, give or take one evaluation at the edge.
Prints one JSON line.
"""
import json
import os
import sys
import time

import numpy as np
import openmm as mm
import openmm.app as app
import openmm.unit as u

bench, test, precision, steps = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
os.chdir(bench)
if test.startswith("amber"):
    name = {"amber20-dhfr": "JAC", "amber20-cellulose": "Cellulose"}[test]
    prmtop = app.AmberPrmtopFile(f"Amber20_Benchmark_Suite/PME/Topologies/{name}.prmtop")
    inpcrd = app.AmberInpcrdFile(f"Amber20_Benchmark_Suite/PME/Coordinates/{name}.inpcrd")
    system = prmtop.createSystem(nonbondedMethod=app.PME, nonbondedCutoff=0.9, constraints=app.HBonds)
    system.setDefaultPeriodicBoxVectors(*inpcrd.boxVectors)
    positions = inpcrd.positions
else:
    if test.startswith("apoa1"):
        ff = app.ForceField("amber14/protein.ff14SB.xml", "amber14/lipid17.xml", "amber14/tip3p.xml")
        pdb = app.PDBFile("apoa1.pdb")
    else:
        ff = app.ForceField("amber99sb.xml", "tip3p.xml")
        pdb = app.PDBFile("5dfr_solv-cube_equil.pdb")
    method, cutoff = {"pme": (app.PME, 0.9), "apoa1pme": (app.PME, 0.9), "apoa1rf": (app.CutoffPeriodic, 1.0)}[test]
    system = ff.createSystem(pdb.topology, nonbondedMethod=method, nonbondedCutoff=cutoff, constraints=app.HBonds,
                             hydrogenMass=1.5*u.amu)
    positions = pdb.positions
integrator = mm.LangevinMiddleIntegrator(300*u.kelvin, 1/u.picosecond, 0.004*u.picoseconds)
integrator.setConstraintTolerance(1e-5)
context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), {"Precision": precision})
context.setPositions(positions)
if test.startswith("amber"):
    mm.LocalEnergyMinimizer.minimize(context, 100*u.kilojoules_per_mole/u.nanometer)
context.setVelocitiesToTemperature(300*u.kelvin)
integrator.step(200)
context.getState(getEnergy=True)
start = time.perf_counter()
integrator.step(steps)
context.getState(getEnergy=True)
wall_ms = 1000*(time.perf_counter()-start)
del context
time.sleep(1)  # completion handlers may run just after getState returns
times = np.loadtxt(os.environ["OPENMM_TIME_FINDBLOCKS"])[-(steps+1):-1]
rebuilds = times > 5*np.percentile(times, 10)
print(json.dumps({
    "test": test, "precision": precision, "steps": steps, "clock": "host wall (perf_counter) for steps; GPU timestamps for findBlocks",
    "ms_per_step": wall_ms/steps, "ns_per_day": steps*0.004/1000/(wall_ms/1000)*86400,
    "findblocks_ms_per_step": float(times.sum())/steps, "findblocks_share": float(times.sum())/wall_ms,
    "rebuild_fraction": float(rebuilds.mean()), "rebuild_ms_median": float(np.median(times[rebuilds])) if rebuilds.any() else 0.0,
    "skip_ms_median": float(np.median(times[~rebuilds])),
}))

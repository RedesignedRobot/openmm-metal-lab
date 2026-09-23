"""Forces and potential energy at fixed states on the Metal platform, to compare two OpenMM installs.

usage: python eqcheck.py <benchmarks-dir> <fah-wu-dir> <precision> <out.npz>
Every case is evaluated in two fresh Contexts, so the file also carries the run to run spread of
one install. The neighbour list is built from scratch in each Context. Cases:
  apoa1rf, apoa1pme, pme   systems built as examples/benchmarks/benchmark.py builds them
  cellulose                amber20-cellulose (408,609 atoms, so the large block path runs)
  dhfr, nav                FAHBench work units (nav is also above the large block threshold)
  dhfr-triclinic           the dhfr work unit in a triclinic box, so TRICLINIC is defined
"""
import os
import sys

import numpy as np
import openmm as mm
import openmm.app as app
import openmm.unit as u

bench, wus, precision, out = sys.argv[1:5]


def from_forcefield(pdb_name, files, method, cutoff):
    pdb = app.PDBFile(os.path.join(bench, pdb_name))
    system = app.ForceField(*files).createSystem(pdb.topology, nonbondedMethod=method, nonbondedCutoff=cutoff*u.nanometer,
                                                 constraints=app.HBonds, hydrogenMass=1.5*u.amu)
    return system, pdb.positions, None


def cellulose():
    suite = os.path.join(bench, "Amber20_Benchmark_Suite/PME")
    prmtop = app.AmberPrmtopFile(f"{suite}/Topologies/Cellulose.prmtop")
    inpcrd = app.AmberInpcrdFile(f"{suite}/Coordinates/Cellulose.inpcrd")
    system = prmtop.createSystem(nonbondedMethod=app.PME, nonbondedCutoff=0.9*u.nanometer, constraints=app.HBonds)
    system.setDefaultPeriodicBoxVectors(*inpcrd.boxVectors)
    return system, inpcrd.positions, inpcrd.boxVectors


def work_unit(name, box=None):
    read = lambda f: mm.XmlSerializer.deserialize(open(f"{wus}/{name}/{f}").read().replace("stateCheckpoint", "State"))
    system, state = read("system.xml"), read("state.xml")
    if box is not None:
        system.setDefaultPeriodicBoxVectors(*box)
    return system, state.getPositions(), (state.getPeriodicBoxVectors() if box is None else box)


apoa1 = ("amber14/protein.ff14SB.xml", "amber14/lipid17.xml", "amber14/tip3p.xml")
triclinic = (mm.Vec3(6.223, 0, 0), mm.Vec3(1.0, 6.223, 0), mm.Vec3(-1.0, 1.0, 6.223))*u.nanometer
cases = {
    "apoa1rf": lambda: from_forcefield("apoa1.pdb", apoa1, app.CutoffPeriodic, 1.0),
    "apoa1pme": lambda: from_forcefield("apoa1.pdb", apoa1, app.PME, 0.9),
    "pme": lambda: from_forcefield("5dfr_solv-cube_equil.pdb", ("amber99sb.xml", "tip3p.xml"), app.PME, 0.9),
    "cellulose": cellulose,
    "dhfr": lambda: work_unit("dhfr"),
    "nav": lambda: work_unit("nav"),
    "dhfr-triclinic": lambda: work_unit("dhfr", triclinic),
}

results = {}
platform = mm.Platform.getPlatformByName("Metal")
for name, build in cases.items():
    system, positions, box = build()
    for run in (1, 2):
        context = mm.Context(system, mm.VerletIntegrator(0.001), platform, {"Precision": precision})
        if box is not None:
            context.setPeriodicBoxVectors(*box)
        context.setPositions(positions)
        state = context.getState(getForces=True, getEnergy=True)
        results[f"{name}/forces{run}"] = state.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
        results[f"{name}/energy{run}"] = state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
        del context
    print(name, system.getNumParticles(), "atoms, energy", results[f"{name}/energy1"], flush=True)
np.savez(out, **results)

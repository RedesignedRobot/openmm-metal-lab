"""Write work units in FAH's format (system.xml, integrator.xml, state.xml) for systems FAHBench lacks.

usage: python makewu.py stmv <amber20-suite-dir> <out-dir>
       python makewu.py tip4pew <out-dir>
stmv: Amber20 STMV (1,067,095 atoms) as OpenMM's benchmark.py builds amber20-stmv: PME, 0.9 nm cutoff,
HBonds, box from the inpcrd; plus a MonteCarloBarostat and LangevinMiddleIntegrator 2 fs, as FAH NPT
projects use.  tip4pew: a 5 nm cube of TIP4P-Ew water (four-site, virtual site M) with the same setup,
minimized on the CPU platform, since addSolvent leaves clashes at the box faces.
The integrator, barostat, and velocities use fixed seeds, as FAH's nav work unit does, so that runs
from the same state can be compared bit for bit.
"""
import os
import sys

import openmm as mm
import openmm.app as app
import openmm.unit as u

TEMPERATURE = 300 * u.kelvin
SEED = 2026


def write(out_dir, system, topology_positions, box, minimize=False):
    integrator = mm.LangevinMiddleIntegrator(TEMPERATURE, 1 / u.picosecond, 0.002 * u.picoseconds)
    integrator.setRandomNumberSeed(SEED)
    barostat = mm.MonteCarloBarostat(1 * u.bar, TEMPERATURE, 25)
    barostat.setRandomNumberSeed(SEED)
    system.addForce(barostat)
    context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("CPU"))
    context.setPeriodicBoxVectors(*box)
    context.setPositions(topology_positions)
    context.computeVirtualSites()
    if minimize:
        mm.LocalEnergyMinimizer.minimize(context, 10, 1000)
    context.setVelocitiesToTemperature(TEMPERATURE, SEED)
    state = context.getState(getPositions=True, getVelocities=True, getParameters=True)
    os.makedirs(out_dir, exist_ok=True)
    for name, obj in (("system", system), ("integrator", integrator), ("state", state)):
        with open(f"{out_dir}/{name}.xml", "w") as f:
            f.write(mm.XmlSerializer.serialize(obj))


def stmv(suite, out_dir):
    prmtop = app.AmberPrmtopFile(f"{suite}/PME/Topologies/STMV.prmtop")
    inpcrd = app.AmberInpcrdFile(f"{suite}/PME/Coordinates/STMV.inpcrd")
    system = prmtop.createSystem(nonbondedMethod=app.PME, nonbondedCutoff=0.9 * u.nanometers, constraints=app.HBonds)
    system.setDefaultPeriodicBoxVectors(*inpcrd.boxVectors)
    write(out_dir, system, inpcrd.positions, inpcrd.boxVectors)


def tip4pew(out_dir):
    forcefield = app.ForceField("amber14/tip4pew.xml")
    modeller = app.Modeller(app.Topology(), [])
    modeller.addSolvent(forcefield, model="tip4pew", boxSize=mm.Vec3(5, 5, 5) * u.nanometers)
    system = forcefield.createSystem(modeller.topology, nonbondedMethod=app.PME, nonbondedCutoff=0.9 * u.nanometers,
                                     constraints=app.HBonds, rigidWater=True)
    write(out_dir, system, modeller.positions, modeller.topology.getPeriodicBoxVectors(), minimize=True)


if __name__ == "__main__":
    if sys.argv[1] == "stmv":
        stmv(sys.argv[2], sys.argv[3])
    else:
        tip4pew(sys.argv[2])

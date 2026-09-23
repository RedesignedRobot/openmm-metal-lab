"""Save every Metal program the Folding@home path compiles in mixed precision.

usage: python capture.py <wu-root> <out-dir>
Runs each configuration below for a few steps on Metal mixed with OPENMM_SAVE_TEMPS=1, so
MetalContext::createLibrary writes each full program (defines, df64, prelude, kernel) to
<out-dir>/<config>/. The same program compiled by several contexts is saved once per context.
"""
import os
import sys

os.environ["OPENMM_SAVE_TEMPS"] = "1"

import openmm as mm
import openmm.app as app
import openmm.unit as u


def load(wu):
    read = lambda name: mm.XmlSerializer.deserialize(
        open(f"{wu}/{name}").read().replace("stateCheckpoint", "State"))
    return read("system.xml"), read("integrator.xml"), read("state.xml")


def run(name, system, integrator, out, state=None, positions=None, steps=30):
    temp = f"{out}/{name}/"
    os.makedirs(temp, exist_ok=True)
    props = {"Precision": "mixed", "TempDirectory": temp}
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), props)
    if state is not None:
        context.setState(state)
    else:
        context.setPositions(positions)
        context.setVelocitiesToTemperature(300 * u.kelvin, 1)
    context.applyConstraints(1e-5)
    context.applyVelocityConstraints(1e-5)
    integrator.step(steps)
    context.getState(getEnergy=True, getForces=True, getPositions=True, getVelocities=True)
    print(name, len(os.listdir(temp)), "programs", flush=True)


def water_box():
    # TIP4P-Ew: SETTLE plus a virtual site per water, with PME.
    forcefield = app.ForceField("tip4pew.xml")
    modeller = app.Modeller(app.Topology(), [])
    modeller.addSolvent(forcefield, model="tip4pew", boxSize=mm.Vec3(2.5, 2.5, 2.5) * u.nanometer)
    system = forcefield.createSystem(modeller.topology, nonbondedMethod=app.PME,
                                     nonbondedCutoff=0.9 * u.nanometer, constraints=app.HBonds)
    system.addForce(mm.MonteCarloBarostat(1 * u.bar, 300 * u.kelvin, 5))
    return system, modeller.positions


def ccma_chain():
    # A four-atom chain with every bond constrained is not a SHAKE cluster, so it goes to CCMA.
    system = mm.System()
    positions = []
    for i in range(4):
        system.addParticle(12.0)
        positions.append(mm.Vec3(0.15 * i, 0.02 * (i % 2), 0) * u.nanometer)
    for i in range(3):
        system.addConstraint(i, i + 1, 0.15)
    system.addForce(mm.CMMotionRemover(1))
    return system, positions


def main():
    root, out = sys.argv[1:3]
    for wu in ("dhfr-implicit", "dhfr", "nav"):
        system, integrator, state = load(f"{root}/{wu}")
        run(wu, system, integrator, out, state=state)

    # FAH's integrator.xml type "LangevinIntegrator" deserializes as LangevinMiddleIntegrator, so none of
    # the WUs above runs the plain LangevinIntegrator.
    system, _, state = load(f"{root}/dhfr")
    run("dhfr-langevin", system,
        mm.LangevinIntegrator(300 * u.kelvin, 1 / u.picosecond, 2 * u.femtosecond), out, state=state)

    system, _, state = load(f"{root}/dhfr")
    system.addForce(mm.MonteCarloBarostat(1 * u.bar, 300 * u.kelvin, 5))
    run("dhfr-langevinmiddle-barostat", system,
        mm.LangevinMiddleIntegrator(300 * u.kelvin, 1 / u.picosecond, 2 * u.femtosecond), out, state=state)

    system, positions = water_box()
    run("tip4pew-vsites", system,
        mm.LangevinMiddleIntegrator(300 * u.kelvin, 1 / u.picosecond, 2 * u.femtosecond), out, positions=positions)

    system, positions = ccma_chain()
    integrator = mm.VerletIntegrator(1 * u.femtosecond)
    integrator.setConstraintTolerance(1e-5)
    run("ccma-chain", system, integrator, out, positions=positions)


if __name__ == "__main__":
    main()

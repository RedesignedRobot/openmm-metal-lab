"""Build a Folding@home-style work-unit corpus: system.xml.bz2, state.xml.bz2 and integrator.xml.bz2 per case.

Run with an OpenMM venv python on the CPU platform (no GPU):
    python corpus.py <openmm source dir> <out dir> [case ...]

The cases follow what public FAH projects run:
  tip3p-hmr     AMBER ff14SB, TIP3P, PME, HBonds, 4 amu hydrogens, LangevinMiddle 4 fs, MonteCarloBarostat
  tip4pew       AMBER ff14SB, TIP4P-Ew (virtual sites), PME, HBonds, LangevinMiddle 2 fs, MonteCarloBarostat
  neq           alanine dipeptide in TIP3P, softcore alchemical switching with a CustomIntegrator that
                changes lambda every step and accumulates protocol work (alchemiscale-fah/feflow style)
  gbsa          AMBER ff14SB with OBC2 implicit solvent, no cutoff, HBonds, LangevinMiddle 2 fs
  pme45k        tip3p-hmr's recipe at 2.0 nm padding (45284 atoms) with no HMR and no barostat: a plain PME system
                between the holdout's PME sizes, for budgeting (r3-fah; the holdout's own PME items stay head-only)
"""
import bz2
import math
import os
import sys

import openmm as mm
import openmm.app as app
import openmm.unit as u

TEMPERATURE = 300*u.kelvin


def cpu():
    return mm.Platform.getPlatformByName('CPU'), {'Threads': '8'}


def write_wu(out, system, integrator, context):
    os.makedirs(out, exist_ok=True)
    state = context.getState(getPositions=True, getVelocities=True, getForces=True, getEnergy=True,
                             getParameters=True)
    for name, obj in (('system', system), ('integrator', integrator), ('state', state)):
        with bz2.open(os.path.join(out, name + '.xml.bz2'), 'wt') as f:
            f.write(mm.XmlSerializer.serialize(obj))
    print(out, system.getNumParticles(), 'particles', flush=True)


def equilibrate(system, topology, positions, integrator_for_equil, steps):
    platform, props = cpu()
    context = mm.Context(system, integrator_for_equil, platform, props)
    if topology is not None and topology.getPeriodicBoxVectors() is not None:
        context.setPeriodicBoxVectors(*topology.getPeriodicBoxVectors())
    context.setPositions(positions)
    mm.LocalEnergyMinimizer.minimize(context, 10.0, 500)
    context.setVelocitiesToTemperature(TEMPERATURE, 1)
    integrator_for_equil.step(steps)
    return context


def explicit_case(src, out, water, hmr, padding=1.0, barostat=True):
    pdb = app.PDBFile(os.path.join(src, 'examples/benchmarks/5dfr_minimized.pdb'))
    ff = app.ForceField('amber14-all.xml', 'amber14/%s.xml' % water)
    modeller = app.Modeller(pdb.topology, pdb.positions)
    modeller.addSolvent(ff, model=water, padding=padding*u.nanometer, ionicStrength=0.1*u.molar)
    system = ff.createSystem(modeller.topology, nonbondedMethod=app.PME, nonbondedCutoff=0.9*u.nanometer,
                             constraints=app.HBonds, rigidWater=True, ewaldErrorTolerance=5e-4,
                             hydrogenMass=(4*u.amu if hmr else None))
    if barostat:
        system.addForce(mm.MonteCarloBarostat(1*u.bar, TEMPERATURE, 25))
    step = 0.004 if hmr else 0.002
    integrator = mm.LangevinMiddleIntegrator(TEMPERATURE, 1/u.picosecond, step*u.picoseconds)
    integrator.setConstraintTolerance(1e-6)
    context = equilibrate(system, modeller.topology, modeller.positions, integrator, 500)
    write_wu(out, system, integrator, context)


def gbsa_case(src, out):
    pdb = app.PDBFile(os.path.join(src, 'examples/benchmarks/5dfr_minimized.pdb'))
    ff = app.ForceField('amber14-all.xml', 'implicit/obc2.xml')
    system = ff.createSystem(pdb.topology, nonbondedMethod=app.NoCutoff, constraints=app.HBonds)
    integrator = mm.LangevinMiddleIntegrator(TEMPERATURE, 1/u.picosecond, 0.002*u.picoseconds)
    context = equilibrate(system, pdb.topology, pdb.positions, integrator, 500)
    write_wu(out, system, integrator, context)


def alchemical_system(system, alchemical_atoms):
    """Decouple alchemical_atoms from their environment: charges scale with lambda_electrostatics through
    NonbondedForce offsets, and alchemical-environment Lennard-Jones goes through a softcore
    CustomNonbondedForce scaled by lambda_sterics.  Alchemical-alchemical Lennard-Jones stays at full strength."""
    nonbonded = [f for f in system.getForces() if isinstance(f, mm.NonbondedForce)][0]
    alchemical = set(alchemical_atoms)
    environment = set(range(system.getNumParticles())) - alchemical
    nonbonded.addGlobalParameter('lambda_electrostatics', 1.0)
    softcore = mm.CustomNonbondedForce(
        'lambda_sterics*4*epsilon*x*(x-1); x = 1/(0.5*(1-lambda_sterics) + (r/sigma)^6);'
        'sigma = 0.5*(sigma1+sigma2); epsilon = sqrt(epsilon1*epsilon2)')
    full = mm.CustomNonbondedForce(
        '4*epsilon*((sigma/r)^12-(sigma/r)^6); sigma = 0.5*(sigma1+sigma2); epsilon = sqrt(epsilon1*epsilon2)')
    softcore.addGlobalParameter('lambda_sterics', 1.0)
    for force in (softcore, full):
        force.addPerParticleParameter('sigma')
        force.addPerParticleParameter('epsilon')
        force.setNonbondedMethod(mm.CustomNonbondedForce.CutoffPeriodic)
        force.setCutoffDistance(nonbonded.getCutoffDistance())
        force.setUseLongRangeCorrection(False)
    for i in range(system.getNumParticles()):
        charge, sigma, epsilon = nonbonded.getParticleParameters(i)
        softcore.addParticle([sigma, epsilon])
        full.addParticle([sigma, epsilon])
        if i in alchemical:
            nonbonded.setParticleParameters(i, 0.0, sigma, 0.0)
            nonbonded.addParticleParameterOffset('lambda_electrostatics', i, charge, 0.0, 0.0)
    for i in range(nonbonded.getNumExceptions()):
        p1, p2, _, _, _ = nonbonded.getExceptionParameters(i)
        softcore.addExclusion(p1, p2)
        full.addExclusion(p1, p2)
    softcore.addInteractionGroup(alchemical, environment)
    full.addInteractionGroup(alchemical, alchemical)
    system.addForce(softcore)
    system.addForce(full)


def neq_integrator(steps_per_switch, timestep=0.002):
    """Periodic nonequilibrium switching in the style of openmmtools' PeriodicNonequilibriumIntegrator,
    which alchemiscale-fah's feflow protocol runs on FAH: splitting V R H O R V, where H moves lambda one
    step along the protocol and adds the energy change to protocol_work."""
    kT = (u.MOLAR_GAS_CONSTANT_R*TEMPERATURE).value_in_unit(u.kilojoule_per_mole)
    gamma = 1.0
    integrator = mm.CustomIntegrator(timestep)
    integrator.addGlobalVariable('kT', kT)
    integrator.addGlobalVariable('a', math.exp(-gamma*timestep))
    integrator.addGlobalVariable('b', (1 - math.exp(-2*gamma*timestep))**0.5)
    integrator.addGlobalVariable('lambda', 0.0)
    integrator.addGlobalVariable('protocol_work', 0.0)
    integrator.addGlobalVariable('Eold', 0.0)
    integrator.addGlobalVariable('Enew', 0.0)
    integrator.addGlobalVariable('step', 0.0)
    integrator.addGlobalVariable('n_steps', steps_per_switch)
    integrator.addPerDofVariable('sigma', 0.0)
    integrator.addPerDofVariable('x1', 0.0)
    integrator.addComputePerDof('sigma', 'sqrt(kT/m)')
    # V
    integrator.addComputePerDof('v', 'v + 0.5*dt*f/m')
    integrator.addConstrainVelocities()
    # R
    integrator.addComputePerDof('x', 'x + 0.5*dt*v')
    integrator.addComputePerDof('x1', 'x')
    integrator.addConstrainPositions()
    integrator.addComputePerDof('v', 'v + (x-x1)/(0.5*dt)')
    # H: forward then reverse switch, one lambda increment per step
    integrator.addComputeGlobal('Eold', 'energy')
    integrator.addComputeGlobal('lambda', 'max(0, min(step, 2*n_steps-step))/n_steps')
    integrator.addComputeGlobal('lambda_sterics', 'min(1, 2*(1-lambda))')
    integrator.addComputeGlobal('lambda_electrostatics', 'max(0, 1-2*lambda)')
    integrator.addComputeGlobal('Enew', 'energy')
    integrator.addComputeGlobal('protocol_work', 'protocol_work + (Enew-Eold)')
    # O
    integrator.addComputePerDof('v', 'a*v + b*sigma*gaussian')
    integrator.addConstrainVelocities()
    # R
    integrator.addComputePerDof('x', 'x + 0.5*dt*v')
    integrator.addComputePerDof('x1', 'x')
    integrator.addConstrainPositions()
    integrator.addComputePerDof('v', 'v + (x-x1)/(0.5*dt)')
    # V
    integrator.addComputePerDof('v', 'v + 0.5*dt*f/m')
    integrator.addConstrainVelocities()
    integrator.addComputeGlobal('step', 'step + 1')
    integrator.setConstraintTolerance(1e-6)
    return integrator


def neq_case(src, out):
    systems = os.path.join(src, 'wrappers/python/tests/systems')
    prmtop = app.AmberPrmtopFile(os.path.join(systems, 'alanine-dipeptide-explicit.prmtop'))
    inpcrd = app.AmberInpcrdFile(os.path.join(systems, 'alanine-dipeptide-explicit.inpcrd'))
    system = prmtop.createSystem(nonbondedMethod=app.PME, nonbondedCutoff=0.9*u.nanometer,
                                 constraints=app.HBonds, rigidWater=True, ewaldErrorTolerance=5e-4)
    solute = [a.index for a in prmtop.topology.atoms() if a.residue.name not in ('HOH', 'WAT')]
    alchemical_system(system, solute)
    equil = mm.LangevinMiddleIntegrator(TEMPERATURE, 1/u.picosecond, 0.002*u.picoseconds)
    platform, props = cpu()
    context = mm.Context(system, equil, platform, props)
    context.setPeriodicBoxVectors(*inpcrd.boxVectors)
    context.setPositions(inpcrd.positions)
    mm.LocalEnergyMinimizer.minimize(context, 10.0, 500)
    context.setVelocitiesToTemperature(TEMPERATURE, 1)
    equil.step(500)
    integrator = neq_integrator(steps_per_switch=250)
    state = context.getState(getPositions=True, getVelocities=True, getParameters=True)
    context = mm.Context(system, integrator, platform, props)
    context.setState(state)
    write_wu(out, system, integrator, context)


CASES = {
    'tip3p-hmr': lambda src, out: explicit_case(src, out, 'tip3p', hmr=True),
    'tip4pew': lambda src, out: explicit_case(src, out, 'tip4pew', hmr=False),
    'neq': neq_case,
    'gbsa': gbsa_case,
    'pme45k': lambda src, out: explicit_case(src, out, 'tip3p', hmr=False, padding=2.0, barostat=False),
}

if __name__ == '__main__':
    src, outdir = sys.argv[1], sys.argv[2]
    for name in sys.argv[3:] or CASES:
        CASES[name](src, os.path.join(outdir, name))

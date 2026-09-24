"""Workloads lane probes for items 3 to 5. Run from ultra-base/benchmarks (the input files live there).
Times use time.perf_counter(), the host monotonic clock. Every result is one JSON line on stdout.

  workloads.py sync <platform> <mode>      modes: custom-sum, custom-nosum, loop-energy, loop-nosync, pipelined
  workloads.py ctx <platform> <test> <variant>   variant: proc (fresh process) or unique (ghost atoms defeat compile caches)
  workloads.py min <platform> <precision> <maxIterations>
"""
import json
import random
import sys
import time

import openmm as mm
import openmm.app as app
import openmm.unit as unit


def gbsa_system():
    pdb = app.PDBFile('5dfr_minimized.pdb')
    ff = app.ForceField('amber99sb.xml', 'amber99_obc.xml')
    system = ff.createSystem(pdb.topology, nonbondedMethod=app.CutoffNonPeriodic, nonbondedCutoff=2.0,
                             constraints=app.HBonds, hydrogenMass=1.5*unit.amu)
    return system, pdb.positions


def explicit_system(test):
    if test == 'apoa1pme':
        pdb = app.PDBFile('apoa1.pdb')
        ff = app.ForceField('amber14/protein.ff14SB.xml', 'amber14/lipid17.xml', 'amber14/tip3p.xml')
    else:
        pdb = app.PDBFile('5dfr_solv-cube_equil.pdb')
        ff = app.ForceField('amber99sb.xml', 'tip3p.xml')
    system = ff.createSystem(pdb.topology, nonbondedMethod=app.PME, nonbondedCutoff=0.9,
                             constraints=app.HBonds, hydrogenMass=1.5*unit.amu)
    return system, pdb.positions


def velocity_verlet(with_sum):
    integ = mm.CustomIntegrator(0.002)
    integ.addGlobalVariable('ke', 0)
    integ.addPerDofVariable('x1', 0)
    integ.addUpdateContextState()
    integ.addComputePerDof('v', 'v+0.5*dt*f/m')
    integ.addComputePerDof('x', 'x+dt*v')
    integ.addComputePerDof('x1', 'x')
    integ.addConstrainPositions()
    integ.addComputePerDof('v', 'v+0.5*dt*f/m+(x-x1)/dt')
    integ.addConstrainVelocities()
    if with_sum:
        integ.addComputeSum('ke', '0.5*m*v*v')
    return integ


def sync(platform, mode):
    system, positions = gbsa_system()
    if mode.startswith('custom'):
        integ = velocity_verlet(mode == 'custom-sum')
    else:
        integ = mm.LangevinMiddleIntegrator(300, 91, 0.004)
    ctx = mm.Context(system, integ, mm.Platform.getPlatformByName(platform), {'Precision': 'single'})
    ctx.setPositions(positions)
    ctx.setVelocitiesToTemperature(300)

    def run(steps):
        if mode.startswith('loop'):
            for _ in range(steps):
                integ.step(1)
                if mode == 'loop-energy':
                    ctx.getState(energy=True)
        else:
            integ.step(steps)
        ctx.getState(energy=True)

    run(200)
    start = time.perf_counter()
    run(500)
    per_step = (time.perf_counter() - start)/500
    steps = max(1000, int(5.0/per_step))
    start = time.perf_counter()
    run(steps)
    elapsed = time.perf_counter() - start
    energy = ctx.getState(energy=True).getPotentialEnergy().value_in_unit(unit.kilojoule_per_mole)
    return {'item': 'sync', 'platform': platform, 'mode': mode, 'atoms': system.getNumParticles(), 'steps': steps,
            'seconds': elapsed, 'us_per_step': 1e6*elapsed/steps, 'final_pe': energy}


def ctx_time(platform, test, variant):
    system, positions = explicit_system(test)
    positions = list(positions)
    ghosts = 0
    if variant == 'unique':
        # Zero-charge, zero-epsilon ghosts change NUM_ATOMS, a define in nearly every kernel, so neither
        # platform's compiled-kernel cache can hit.
        ghosts = random.SystemRandom().randint(1, 5000)
        nonbonded = next(f for f in system.getForces() if isinstance(f, mm.NonbondedForce))
        box = system.getDefaultPeriodicBoxVectors()
        size = [box[i][i].value_in_unit(unit.nanometer) for i in range(3)]
        for _ in range(ghosts):
            system.addParticle(1.0)
            nonbonded.addParticle(0.0, 0.1, 0.0)
            positions.append(mm.Vec3(*(random.random()*s for s in size))*unit.nanometer)
    plat = mm.Platform.getPlatformByName(platform)
    result = {'item': 'ctx', 'platform': platform, 'test': test, 'variant': variant, 'ghosts': ghosts,
              'atoms': system.getNumParticles()}
    for phase in ('first', 'second'):
        integ = mm.LangevinMiddleIntegrator(300, 1, 0.004)
        start = time.perf_counter()
        ctx = mm.Context(system, integ, plat, {'Precision': 'single'} if 'Precision' in plat.getPropertyNames() else {})
        created = time.perf_counter()
        ctx.setPositions(positions)
        integ.step(1)
        ctx.getState(energy=True)
        stepped = time.perf_counter()
        result[f'{phase}_create_s'] = created - start
        result[f'{phase}_first_step_s'] = stepped - created
        result[f'{phase}_total_s'] = stepped - start
        del ctx, integ
    return result


def minimize(platform, precision, max_iterations):
    system, positions = explicit_system('apoa1pme')
    properties = {} if platform == 'CPU' else {'Precision': precision}
    ctx = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName(platform), properties)
    ctx.setPositions(positions)
    before = ctx.getState(energy=True).getPotentialEnergy().value_in_unit(unit.kilojoule_per_mole)
    start = time.perf_counter()
    mm.LocalEnergyMinimizer.minimize(ctx, 10, max_iterations)
    state = ctx.getState(energy=True, forces=True)
    elapsed = time.perf_counter() - start
    forces = state.getForces(asNumpy=True).value_in_unit(unit.kilojoule_per_mole/unit.nanometer)
    return {'item': 'min', 'platform': platform, 'precision': precision if platform != 'CPU' else 'mixed',
            'max_iterations': max_iterations, 'atoms': system.getNumParticles(), 'seconds': elapsed,
            'pe_before': before, 'pe_after': state.getPotentialEnergy().value_in_unit(unit.kilojoule_per_mole),
            'rms_force_after': float((forces**2).mean()**0.5)}


if __name__ == '__main__':
    item = sys.argv[1]
    if item == 'sync':
        out = sync(sys.argv[2], sys.argv[3])
    elif item == 'ctx':
        out = ctx_time(sys.argv[2], sys.argv[3], sys.argv[4])
    elif item == 'min':
        out = minimize(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    else:
        sys.exit(__doc__)
    print(json.dumps(out), flush=True)

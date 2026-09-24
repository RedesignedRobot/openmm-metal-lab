import openmm as mm, openmm.app as app, openmm.unit as unit
ff = app.ForceField('amber99sb.xml', 'tip3p.xml')
pdb = app.PDBFile('5dfr_solv-cube_equil.pdb')
system = ff.createSystem(pdb.topology, nonbondedMethod=app.CutoffPeriodic, nonbondedCutoff=1.0, constraints=app.HBonds, hydrogenMass=1.5*unit.amu)
integ = mm.LangevinMiddleIntegrator(300, 1, 0.004)
platform = mm.Platform.getPlatform('Metal')
props = {'Precision': 'single'}
print(platform.getPropertyNames())
context = mm.Context(system, integ, platform, props)
context.setPositions(pdb.positions)
integ.step(10)
print(context.getState(getEnergy=True).getPotentialEnergy())

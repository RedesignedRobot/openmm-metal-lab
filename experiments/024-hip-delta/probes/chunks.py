import sys, time
import openmm as mm, openmm.app as app, openmm.unit as unit
test = sys.argv[1]
method = {'apoa1ljpme': app.LJPME, 'apoa1pme': app.PME, 'apoa1rf': app.CutoffPeriodic}[test]
ff = app.ForceField('amber14/protein.ff14SB.xml', 'amber14/lipid17.xml', 'amber14/tip3p.xml')
pdb = app.PDBFile('apoa1.pdb')
system = ff.createSystem(pdb.topology, nonbondedMethod=method, nonbondedCutoff=0.9 if method != app.CutoffPeriodic else 1.0, constraints=app.HBonds, hydrogenMass=1.5*unit.amu)
integ = mm.LangevinMiddleIntegrator(300, 1, 0.004)
integ.setConstraintTolerance(1e-5)
context = mm.Context(system, integ, mm.Platform.getPlatform('Metal'), {'Precision': 'single'})
context.setPositions(pdb.positions)
context.setVelocitiesToTemperature(300)
integ.step(5)
context.getState(getEnergy=True)
out = []
for chunk in range(int(sys.argv[2])):
    t = time.perf_counter()
    integ.step(200)
    context.getState(getEnergy=True)
    out.append(0.004*200/(time.perf_counter()-t)*86400/1000)
print(test, ' '.join(f'{x:.0f}' for x in out))

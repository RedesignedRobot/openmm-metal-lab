"""DPD thermostat check: mean temperature per platform over several seeds, for a free gas."""
import sys
import numpy as np
import openmm as mm
import openmm.unit as u

rng = np.random.default_rng(1)
n = 200
system = mm.System()
nb = mm.NonbondedForce()
nb.setNonbondedMethod(mm.NonbondedForce.CutoffPeriodic)
nb.setCutoffDistance(1.0)
for i in range(n):
    system.addParticle(1.0)
    nb.addParticle(0, 0.2, 0.0)
system.addForce(nb)
system.setDefaultPeriodicBoxVectors(mm.Vec3(3, 0, 0), mm.Vec3(0, 3, 0), mm.Vec3(0, 0, 3))
pos = rng.uniform(0, 3.0, (n, 3))
dof = 3*n-3
for name in sys.argv[1].split(","):
    for seed in range(1, int(sys.argv[2])+1):
        integrator = mm.DPDIntegrator(300*u.kelvin, 1/u.picosecond, 1.0*u.nanometer, 0.001*u.picoseconds)
        integrator.setRandomNumberSeed(seed)
        ctx = mm.Context(system, integrator, mm.Platform.getPlatformByName(name))
        ctx.setPositions(pos)
        ctx.setVelocitiesToTemperature(300*u.kelvin, seed)
        temps = []
        for i in range(200):
            integrator.step(100)
            ke = ctx.getState(getEnergy=True).getKineticEnergy()
            temps.append((2*ke/(dof*u.MOLAR_GAS_CONSTANT_R)).value_in_unit(u.kelvin))
        print(name, seed, "T at 2/10/20 ps: %.1f %.1f %.1f, mean over 10-20 ps: %.1f" % (temps[19], temps[99], temps[199], np.mean(temps[100:])), flush=True)

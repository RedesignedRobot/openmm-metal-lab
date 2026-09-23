"""Save the Metal minimizer's program source for one precision.

usage: OPENMM_SAVE_TEMPS=1 python minsrc.py <out-dir> <precision>
Minimizes two bonded particles with a constraint, so every minimizer kernel is compiled, and
copies the saved program that defines lineSearchDot to <out-dir>/minimize-<precision>.metal.
"""
import glob
import os
import shutil
import sys
import tempfile

import openmm as mm

out, precision = sys.argv[1:3]
temp = tempfile.mkdtemp()
system = mm.System()
for i in range(3):
    system.addParticle(1.0)
bond = mm.HarmonicBondForce()
bond.addBond(0, 1, 0.15, 1000.0)
system.addForce(bond)
system.addConstraint(1, 2, 0.1)
context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Metal"),
                     {"Precision": precision, "TempDirectory": temp})
context.setPositions([mm.Vec3(0, 0, 0), mm.Vec3(0.2, 0, 0), mm.Vec3(0.2, 0.1, 0)])
mm.LocalEnergyMinimizer.minimize(context, 1.0)
found = [f for f in glob.glob(f"{temp}/*.metal") if "void lineSearchDot" in open(f).read()]
assert len(found) == 1, found
os.makedirs(out, exist_ok=True)
shutil.copy(found[0], f"{out}/minimize-{precision}.metal")
print(f"{out}/minimize-{precision}.metal")

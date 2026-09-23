"""Make an HBonds copy of a FAHBench work unit whose System constrains every bond.

usage: hbonds.py <wu-dir> <out-dir>
FAHBench dhfr constrains all 24,141 bonds and has an empty HarmonicBondForce, so its 1,302
heavy-atom constraints, and the hydrogen constraints SHAKE can't take next to them, go to CCMA.
This copy keeps only the constraints that involve a hydrogen, which SETTLE and SHAKE take, and
turns each heavy-atom constraint into a harmonic bond at the constrained length. The work unit
does not carry force-field constants, so every such bond gets one Amber-like k (310 kcal/mol/A^2,
C-C). The dynamics differ from the original; the copy is only for timing CCMA against no CCMA.
"""
import os
import shutil
import sys

import openmm as mm

HYDROGEN_MAX_MASS = 1.5  # amu; FAHBench dhfr has no repartitioned hydrogen masses
BOND_K = 310 * 4.184 * 100 * 2  # kcal/mol/A^2 in Amber's k(r-r0)^2 form, as kJ/mol/nm^2 for k/2(r-r0)^2


def main():
    wu, out = sys.argv[1:3]
    system = mm.XmlSerializer.deserialize(open(f"{wu}/system.xml").read())
    heavy = [system.getParticleMass(i)._value > HYDROGEN_MAX_MASS for i in range(system.getNumParticles())]
    bonds = next(f for f in system.getForces() if isinstance(f, mm.HarmonicBondForce))
    moved = 0
    for i in reversed(range(system.getNumConstraints())):
        a, b, r = system.getConstraintParameters(i)
        if heavy[a] and heavy[b]:
            bonds.addBond(a, b, r, BOND_K)
            system.removeConstraint(i)
            moved += 1
    os.makedirs(out, exist_ok=True)
    with open(f"{out}/system.xml", "w") as f:
        f.write(mm.XmlSerializer.serialize(system))
    for name in ("integrator.xml", "state.xml"):
        shutil.copy(f"{wu}/{name}", out)
    print(f"{moved} heavy-atom constraints became bonds; {system.getNumConstraints()} constraints remain")


if __name__ == "__main__":
    main()

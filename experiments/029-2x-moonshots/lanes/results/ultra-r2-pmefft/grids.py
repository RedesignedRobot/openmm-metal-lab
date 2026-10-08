"""Print the PME grids Metal picks for each PME benchmark test, single precision."""
import os
import sys

import openmm as mm

os.chdir(sys.argv[1])
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])
for test in ("apoa1ljpme", "amber20-cellulose", "amber20-stmv", "amoebapme"):
    system, positions, _ = retrieveTestSystem(test)
    context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Metal"), {"Precision": "single"})
    grids = []
    for f in system.getForces():
        if isinstance(f, mm.NonbondedForce):
            if f.getNonbondedMethod() == mm.NonbondedForce.PME:
                grids.append("pme %dx%dx%d" % tuple(f.getPMEParametersInContext(context)[1:]))
            if f.getNonbondedMethod() == mm.NonbondedForce.LJPME:
                grids.append("ljpme %dx%dx%d" % tuple(f.getLJPMEParametersInContext(context)[1:]))
        if isinstance(f, mm.AmoebaMultipoleForce):
            grids.append("amoeba %dx%dx%d" % tuple(f.getPMEParametersInContext(context)[1:]))
    print(test, " ".join(grids), flush=True)
    del context

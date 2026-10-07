"""Builds the frozen holdout set once, on the CPU. Run it with a build.sh tree's python (it needs openmm.app).

Items:
- fah-tip3p-hmr, fah-tip4pew, fah-gbsa, fah-neq: copies of the FAH corpus (system, state and integrator XML).
- pme-50k, pme-180k, pme-600k: DHFR (5dfr_minimized.pdb) solvated with Modeller in a cubic box of
  amber14/tip3p water with 0.15 M NaCl, PME at 0.9 nm, HBonds, 1.5 amu hydrogens, LangevinMiddle 4 fs at
  300 K, as FAH runs it. Minimized, then given Maxwell velocities, then 50 CPU steps so the state has
  settled constraints. The box edges put them in the gaps between pme (23k), apoa1 (92k), cellulose
  (408k) and stmv (1.07M).
Every item also gets reference.npz: the Reference platform's forces and energy (double precision) at the
state's positions, so holdout.py holds the GPU only for the Metal evaluations.
Then MANIFEST.sha256 lists every file. holdout.py refuses to run when a file doesn't match it.
usage: python build.py <corpus dir> <benchmarks dir> <outdir>
"""
import bz2
import hashlib
import os
import shutil
import sys
import time

import numpy as np
import openmm as mm
import openmm.app as app
import openmm.unit as u

CORPUS = ["tip3p-hmr", "tip4pew", "gbsa", "neq"]
# Box edge in nm for each size item; about 100 atoms per nm^3 of water.
SIZES = {"pme-50k": 7.9, "pme-180k": 12.15, "pme-600k": 18.15}
SEED = 2026
CPU_PROPS = {"Threads": "8"}

corpus_dir, bench_dir, out_dir = (os.path.abspath(p) for p in sys.argv[1:4])
os.makedirs(out_dir, exist_ok=True)


def log(message):
    print(time.strftime("%H:%M:%SZ", time.gmtime()), message, flush=True)


def load(path):
    opener = bz2.open if path.endswith(".bz2") else open
    with opener(path, "rt") as f:
        return mm.XmlSerializer.deserialize(f.read())


def item_file(item_dir, name):
    for suffix in (".xml", ".xml.bz2"):
        path = os.path.join(item_dir, name + suffix)
        if os.path.exists(path):
            return path
    sys.exit(f"{item_dir} has no {name}.xml or {name}.xml.bz2")


def write_xml(path, obj):
    partial = path + ".partial"
    with open(partial, "w") as f:
        f.write(mm.XmlSerializer.serialize(obj))
    os.replace(partial, path)


def langevin():
    return mm.LangevinMiddleIntegrator(300*u.kelvin, 1/u.picosecond, 0.004*u.picoseconds)


def build_size(item, edge):
    item_dir = os.path.join(out_dir, item)
    if os.path.exists(os.path.join(item_dir, "state.xml")):
        log(f"{item}: exists, kept")
        return
    os.makedirs(item_dir, exist_ok=True)
    pdb = app.PDBFile(os.path.join(bench_dir, "5dfr_minimized.pdb"))
    forcefield = app.ForceField("amber14-all.xml", "amber14/tip3p.xml")
    modeller = app.Modeller(pdb.topology, pdb.positions)
    modeller.deleteWater()
    modeller.addSolvent(forcefield, boxSize=mm.Vec3(edge, edge, edge)*u.nanometer,
                        ionicStrength=0.15*u.molar)
    log(f"{item}: {modeller.topology.getNumAtoms()} atoms in a {edge} nm box")
    system = forcefield.createSystem(modeller.topology, nonbondedMethod=app.PME,
                                     nonbondedCutoff=0.9*u.nanometer, constraints=app.HBonds,
                                     rigidWater=True, hydrogenMass=1.5*u.amu)
    context = mm.Context(system, langevin(), mm.Platform.getPlatformByName("CPU"), CPU_PROPS)
    context.setPositions(modeller.positions)
    mm.LocalEnergyMinimizer.minimize(context, 10.0, 500)
    log(f"{item}: minimized, {context.getState(getEnergy=True).getPotentialEnergy()}")
    context.setVelocitiesToTemperature(300*u.kelvin, SEED)
    context.getIntegrator().setRandomNumberSeed(SEED)
    context.getIntegrator().step(50)
    state = context.getState(getPositions=True, getVelocities=True, getParameters=True, enforcePeriodicBox=True)
    log(f"{item}: 50 steps, {context.getState(getEnergy=True).getPotentialEnergy()}")
    with open(os.path.join(item_dir, "topology.pdb"), "w") as f:
        app.PDBFile.writeFile(modeller.topology, state.getPositions(), f)
    write_xml(os.path.join(item_dir, "system.xml"), system)
    write_xml(os.path.join(item_dir, "integrator.xml"), langevin())
    write_xml(os.path.join(item_dir, "state.xml"), state)


def copy_corpus(name):
    item_dir = os.path.join(out_dir, "fah-" + name)
    os.makedirs(item_dir, exist_ok=True)
    for part in ("system", "state", "integrator"):
        shutil.copyfile(os.path.join(corpus_dir, name, part + ".xml.bz2"), os.path.join(item_dir, part + ".xml.bz2"))
    log(f"fah-{name}: copied")


def write_reference(item):
    item_dir = os.path.join(out_dir, item)
    path = os.path.join(item_dir, "reference.npz")
    if os.path.exists(path):
        log(f"{item}: reference exists, kept")
        return
    system = load(item_file(item_dir, "system"))
    state = load(item_file(item_dir, "state"))
    context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName("Reference"))
    context.setState(state)
    result = context.getState(getForces=True, getEnergy=True, getPositions=True)
    forces = result.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer)
    energy = result.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
    positions = result.getPositions(asNumpy=True).value_in_unit(u.nanometer)
    np.savez(path + ".partial.npz", positions=np.array(positions), forces=np.array(forces), energy=energy)
    os.replace(path + ".partial.npz", path)
    log(f"{item}: Reference energy {energy:.6f} kJ/mol, {system.getNumParticles()} atoms")


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


for name in CORPUS:
    copy_corpus(name)
for item, edge in SIZES.items():
    build_size(item, edge)
items = ["fah-" + name for name in CORPUS] + list(SIZES)
for item in items:
    write_reference(item)
with open(os.path.join(out_dir, "MANIFEST.sha256"), "w") as manifest:
    for item in items:
        for name in sorted(os.listdir(os.path.join(out_dir, item))):
            path = os.path.join(item, name)
            manifest.write(f"{sha256(os.path.join(out_dir, path))}  {path}\n")
log("MANIFEST.sha256 written")

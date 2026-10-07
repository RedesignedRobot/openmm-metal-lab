"""One NVE energy-drift run of DHFR, following the OpenMM 7 paper (Eastman et al. 2017, Table 5).

Paper protocol: DHFR in explicit solvent (23,558 atoms), AMBER99SB-ILDN, rigid water, HBonds constraints,
leapfrog Verlet at 2 fs, 1 ns per run, total energy recorded every 1 ps, drift = least-squares slope,
ten independent runs per precision. The paper does not state cutoff, PME tolerance, constraint tolerance
or equilibration; this script takes them from the OpenMM 7.1 benchmark.py DHFR PME test (same
5dfr_solv-cube_equil.pdb, 0.9 nm cutoff, default ewaldErrorTolerance 5e-4, constraint tolerance 1e-5,
no hydrogen mass repartitioning at 2 fs). Each run draws 300 K velocities from <seed>, equilibrates
<equil ps> with LangevinMiddle at 1/ps (same seed), then hands positions and velocities to a new
Context with a VerletIntegrator and runs <ns> of NVE.

usage: python dhfr-nve.py <pdb> <platform> <precision> <seed> <equil ps> <ns> <out prefix> [constraint tolerance]
The tolerance defaults to 1e-5, the protocol value; other values are for diagnosis only.
Writes <out prefix>.csv (time_ps, potential, kinetic, total in kJ/mol) and <out prefix>.json, each
through a temporary file and a rename, so a run killed by the lease cap leaves no result.
DRIFT_CHUNK_PS=<ps> in the environment splits the NVE part into chunks for slow platforms (CPU), one process
and one lease ticket per chunk: each chunk but the last saves the state, the samples so far and the wall time to
<out prefix>.ckpt.json (one file, one rename) and exits 0 without a result; the next call resumes from it.
"""
import hashlib
import json
import os
import sys
import time

import numpy as np
import openmm as mm
import openmm.app as app
import openmm.unit as u

STEP_PS = 0.002
SAMPLE_STEPS = 500
TEMPERATURE = 300*u.kelvin
KT = (u.MOLAR_GAS_CONSTANT_R*TEMPERATURE).value_in_unit(u.kilojoule_per_mole)

pdb_path, platform_name, precision = sys.argv[1], sys.argv[2], sys.argv[3]
seed, equil_ps, ns, out = int(sys.argv[4]), float(sys.argv[5]), float(sys.argv[6]), sys.argv[7]
TOLERANCE = float(sys.argv[8]) if len(sys.argv) > 8 else 1e-5
platform = mm.Platform.getPlatformByName(platform_name)
properties = {} if platform_name in ("CPU", "Reference") else {"Precision": precision}
CHUNK_PS = float(os.environ.get("DRIFT_CHUNK_PS", "0"))

pdb = app.PDBFile(pdb_path)
forcefield = app.ForceField("amber99sbildn.xml", "tip3p.xml")
# DRIFT_SWITCH_NM and DRIFT_EWALD_TOL change the setup for diagnosis only (LJ switch, PME accuracy); unset is the protocol.
setup = {}
if os.environ.get("DRIFT_SWITCH_NM"):
    setup["switchDistance"] = float(os.environ["DRIFT_SWITCH_NM"])*u.nanometers
if os.environ.get("DRIFT_EWALD_TOL"):
    setup["ewaldErrorTolerance"] = float(os.environ["DRIFT_EWALD_TOL"])
system = forcefield.createSystem(pdb.topology, nonbondedMethod=app.PME, nonbondedCutoff=0.9*u.nanometers,
                                 constraints=app.HBonds, rigidWater=True, **setup)
has_cm_remover = any(isinstance(f, mm.CMMotionRemover) for f in system.getForces())
dof = 3*system.getNumParticles() - system.getNumConstraints() - (3 if has_cm_remover else 0)
nonbonded = next(f for f in system.getForces() if isinstance(f, mm.NonbondedForce))

checkpoint = out + ".ckpt.json"
total_samples = int(round(ns*1000/(SAMPLE_STEPS*STEP_PS))) + 1
chunk_samples = int(round(CHUNK_PS/(SAMPLE_STEPS*STEP_PS))) if CHUNK_PS > 0 else total_samples
wall_start = time.perf_counter()
verlet = mm.VerletIntegrator(STEP_PS)
verlet.setConstraintTolerance(TOLERANCE)
if os.path.exists(checkpoint):
    with open(checkpoint) as f:
        saved = json.load(f)
    context = mm.Context(system, verlet, platform, properties)
    context.setState(mm.XmlSerializer.deserialize(saved["state"]))
    samples = [tuple(row) for row in saved["samples"]]
    wall_before, nve_wall_before = saved["wall_s"], saved["nve_wall_s"]
else:
    langevin = mm.LangevinMiddleIntegrator(TEMPERATURE, 1/u.picosecond, STEP_PS)
    langevin.setConstraintTolerance(TOLERANCE)
    langevin.setRandomNumberSeed(seed)
    context = mm.Context(system, langevin, platform, properties)
    context.setPositions(pdb.positions)
    context.applyConstraints(TOLERANCE)
    context.setVelocitiesToTemperature(TEMPERATURE, seed)
    context.applyVelocityConstraints(TOLERANCE)
    langevin.step(int(round(equil_ps/STEP_PS)))
    equilibrated = context.getState(getPositions=True, getVelocities=True, enforcePeriodicBox=False)
    del context, langevin

    context = mm.Context(system, verlet, platform, properties)
    context.setPeriodicBoxVectors(*equilibrated.getPeriodicBoxVectors())
    context.setPositions(equilibrated.getPositions())
    context.setVelocities(equilibrated.getVelocities())
    samples = []
    wall_before, nve_wall_before = 0.0, 0.0
nve_start = time.perf_counter()

first_sample = len(samples)
# The first chunk also takes sample 0, so 200 ps chunks cover 1 ns in five calls.
for sample in range(first_sample, min(total_samples, first_sample + chunk_samples + (first_sample == 0))):
    if sample > 0:
        verlet.step(SAMPLE_STEPS)
    state = context.getState(getEnergy=True)
    potential = state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
    kinetic = state.getKineticEnergy().value_in_unit(u.kilojoule_per_mole)
    samples.append((state.getTime().value_in_unit(u.picosecond), potential, kinetic, potential + kinetic))
wall_end = time.perf_counter()
wall_s = wall_before + wall_end - wall_start
nve_wall_s = nve_wall_before + wall_end - nve_start
if len(samples) < total_samples:
    state = context.getState(getPositions=True, getVelocities=True, getParameters=True, enforcePeriodicBox=False)
    with open(checkpoint + ".tmp", "w") as f:
        json.dump({"state": mm.XmlSerializer.serialize(state), "samples": samples, "wall_s": wall_s,
                   "nve_wall_s": nve_wall_s}, f)
    os.replace(checkpoint + ".tmp", checkpoint)
    print(f"CHUNK {len(samples)}/{total_samples} samples, wall {wall_s:.1f} s", flush=True)
    sys.exit(0)

series = np.array(samples)
times = series[:, 0] - series[0, 0]
total = series[:, 3]
slope, intercept = np.polyfit(times, total, 1)
residual = total - (slope*times + intercept)
se_white = np.sqrt(np.sum(residual**2)/(len(times) - 2)/np.sum((times - times.mean())**2))
temperature = 2*series[:, 2]/(dof*u.MOLAR_GAS_CONSTANT_R.value_in_unit(u.kilojoule_per_mole/u.kelvin))

pme = [v.value_in_unit(u.nanometers**-1) if u.is_quantity(v) else v
       for v in nonbonded.getPMEParametersInContext(context)]
with open(pdb_path, "rb") as f:
    pdb_md5 = hashlib.md5(f.read()).hexdigest()
with open(os.path.join(mm.version.openmm_library_path, "libOpenMM.dylib"), "rb") as f:
    lib_md5 = hashlib.md5(f.read()).hexdigest()

result = {
    "platform": platform_name, "precision": context.getPlatform().getPropertyValue(context, "Precision")
    if properties else "native", "seed": seed, "equil_ps": equil_ps, "nve_ns": float(times[-1]/1000),
    "step_fs": STEP_PS*1000, "sample_ps": SAMPLE_STEPS*STEP_PS, "samples": len(times),
    "constraint_tolerance": TOLERANCE, "cutoff_nm": nonbonded.getCutoffDistance().value_in_unit(u.nanometers),
    "ewald_error_tolerance": nonbonded.getEwaldErrorTolerance(), "lj_switch_nm": nonbonded.getSwitchingDistance().value_in_unit(u.nanometers) if nonbonded.getUseSwitchingFunction() else None, "pme_alpha_nx_ny_nz": pme,
    "atoms": system.getNumParticles(), "constraints": system.getNumConstraints(), "cm_motion_remover":
    has_cm_remover, "dof": dof, "pdb_md5": pdb_md5, "openmm_lib": mm.version.openmm_library_path,
    "libOpenMM_md5": lib_md5, "drift_kj_mol_ps": float(slope), "drift_kt_ns_dof": float(slope*1000/KT/dof),
    "se_white_kj_mol_ps": float(se_white), "rms_kj_mol": float(np.sqrt(np.mean(residual**2))),
    "e_first": float(total[0]), "e_last": float(total[-1]), "temperature_mean_k": float(temperature.mean()),
    "wall_s": round(wall_s, 1), "nve_wall_s": round(nve_wall_s, 1), "chunk_ps": CHUNK_PS,
}
np.savetxt(out + ".csv.tmp", series, fmt="%.6f", delimiter=",", header="time_ps,potential,kinetic,total",
           comments="")
os.replace(out + ".csv.tmp", out + ".csv")
with open(out + ".json.tmp", "w") as f:
    f.write(json.dumps(result) + "\n")
os.replace(out + ".json.tmp", out + ".json")
if os.path.exists(checkpoint):
    os.remove(checkpoint)
print(json.dumps(result), flush=True)

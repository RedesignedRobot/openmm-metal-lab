"""Mock Folding@home core: run a work unit on Metal mixed the way a FAH core does, restarting from
XML checkpoints, and check the result the way FAH does.

usage: python mockcore.py <wu-dir> <out-dir> <steps> <checkpoint-interval>
Prints one JSON line and writes it to <out-dir>/<wu>/result.json, next to the last checkpointState.xml.

Four runs of <steps> steps from the work unit's state.xml, all on Metal with FAH_PROPERTIES:
  uninterrupted  one Context for the whole run
  xml-restart    a fresh Context at every checkpoint, loaded from checkpointState.xml as a core does
                 when it resumes (system and integrator XML deserialized again, state from the file)
  xml-restart-2  the same again, to separate restart effects from run-to-run nondeterminism
  bin-restart    a fresh Context at every checkpoint, loaded from Context.createCheckpoint() bytes
Each checkpoint compares positions and velocities between runs bit for bit. At each uninterrupted
checkpoint it also loads the Context's binary checkpoint into a fresh Context and compares the two
Contexts' forces bit for bit: same positions, different history.
FAHBench's state tests (fahbench/StateTests.cpp) compare Metal with Reference: RMS over atoms of the
difference in force magnitude <= 5 kJ/mol/nm, |dPE| and |dKE| <= 10 kJ/mol, and no NaNs; at the
start state, as FAHBench does. At every xml-restart checkpoint they also check the final-state
sanity limits: no velocity component > 17.47 nm/ps, no more than half of velocity components exactly
zero, no force component > 50000 kJ/mol/nm. Vector force errors are reported alongside.
Clock: host wall, time.perf_counter, for context only.
"""
import json
import os
import sys
import time

import numpy as np
import openmm as mm
import openmm.unit as u

FAH_PROPERTIES = {"Precision": "mixed", "DisablePmeStream": "1", "DeviceIndex": "0", "DeterministicForces": "true"}
FORCE_TOL = 5.0
ENERGY_TOL = 10.0
MAX_VELOCITY = 17.47
MAX_FORCE = 50000.0
KJ = u.kilojoule_per_mole
FORCE_UNIT = u.kilojoule_per_mole / u.nanometer


def read(path):
    # FAHBench ships its states under the pre-7.0 root tag; current OpenMM reads <State>.
    return open(path).read().replace("stateCheckpoint", "State")


class WorkUnit:
    def __init__(self, path):
        self.name = os.path.basename(path.rstrip("/"))
        self.system_xml = read(f"{path}/system.xml")
        self.integrator_xml = read(f"{path}/integrator.xml")
        self.state_xml = read(f"{path}/state.xml")
        self.system = mm.XmlSerializer.deserialize(self.system_xml)

    def context(self, platform="Metal", properties=FAH_PROPERTIES, fresh_system=False):
        system = mm.XmlSerializer.deserialize(self.system_xml) if fresh_system else self.system
        integrator = mm.XmlSerializer.deserialize(self.integrator_xml)
        context = mm.Context(system, integrator, mm.Platform.getPlatformByName(platform), properties)
        return context, integrator


def snapshot(context):
    s = context.getState(getPositions=True, getVelocities=True)
    return (s.getPositions(asNumpy=True).value_in_unit(u.nanometer),
            s.getVelocities(asNumpy=True).value_in_unit(u.nanometer / u.picosecond))


def checkpoint_xml(context):
    return mm.XmlSerializer.serialize(context.getState(getPositions=True, getVelocities=True, getParameters=True))


def forces_and_energies(context):
    s = context.getState(getForces=True, getEnergy=True, getVelocities=True)
    return (s.getForces(asNumpy=True).value_in_unit(FORCE_UNIT), s.getPotentialEnergy().value_in_unit(KJ),
            s.getKineticEnergy().value_in_unit(KJ), s.getVelocities(asNumpy=True).value_in_unit(u.nanometer / u.picosecond))


def state_test(wu, metal_context, state_xml, sanity):
    """FAHBench's compareForcesAndEnergies and checkForNans at one state, and with sanity its
    checkForDiscrepancies."""
    f, pe, ke, v = forces_and_energies(metal_context)
    start = time.perf_counter()
    ref, _ = wu.context("Reference", {})
    ref.setState(mm.XmlSerializer.deserialize(state_xml))
    f_ref, pe_ref, ke_ref, _ = forces_and_energies(ref)
    del ref
    ref_s = time.perf_counter() - start
    magnitude_rms = float(np.sqrt(np.mean((np.linalg.norm(f_ref, axis=1) - np.linalg.norm(f, axis=1))**2)))
    vector_error = np.linalg.norm(f - f_ref, axis=1)
    result = {
        "force_rms_fah": magnitude_rms, "force_rms_vector": float(np.sqrt(np.mean(vector_error**2))),
        "force_max_vector": float(vector_error.max()), "pe": pe, "pe_ref": pe_ref, "dpe": abs(pe - pe_ref),
        "ke": ke, "ke_ref": ke_ref, "dke": abs(ke - ke_ref),
        "nan": bool(np.isnan(f).any() or np.isnan(v).any()),
        "max_abs_velocity": float(np.abs(v).max()), "zero_velocity_fraction": float(np.mean(v == 0)),
        "max_abs_force": float(np.abs(f).max()), "reference_s": round(ref_s, 1),
    }
    result["pass"] = bool(magnitude_rms <= FORCE_TOL and result["dpe"] <= ENERGY_TOL and result["dke"] <= ENERGY_TOL
                          and not result["nan"])
    if sanity:
        result["pass"] = bool(result["pass"] and result["max_abs_velocity"] <= MAX_VELOCITY
                              and result["zero_velocity_fraction"] <= 0.5 and result["max_abs_force"] <= MAX_FORCE)
    return result


def run_uninterrupted(wu, steps, interval):
    context, integrator = wu.context()
    context.setState(mm.XmlSerializer.deserialize(wu.state_xml))
    snapshots, fresh_forces = [], []
    for _ in range(steps // interval):
        integrator.step(interval)
        snapshots.append(snapshot(context))
        fresh_forces.append(compare_fresh_forces(wu, context))
    return snapshots, fresh_forces


def compare_fresh_forces(wu, context):
    """Forces of a running Context and of a fresh one loaded from its binary checkpoint."""
    fresh, _ = wu.context()
    fresh.loadCheckpoint(context.createCheckpoint())
    positions_bitwise = bool(np.array_equal(snapshot(context)[0], snapshot(fresh)[0]))
    f1 = context.getState(getForces=True).getForces(asNumpy=True).value_in_unit(FORCE_UNIT)
    f2 = fresh.getState(getForces=True).getForces(asNumpy=True).value_in_unit(FORCE_UNIT)
    del fresh
    return {"positions_bitwise": positions_bitwise, "forces_bitwise": bool(np.array_equal(f1, f2)),
            "max_dforce": float(np.abs(f1 - f2).max()), "atoms_differing": int(np.any(f1 != f2, axis=1).sum())}


def run_restarted(wu, steps, interval, out_dir, tests):
    """Resume from checkpointState.xml at every checkpoint.  With tests, run the state tests on each."""
    checkpoint = wu.state_xml
    snapshots, results = [], []
    for i in range(steps // interval):
        context, integrator = wu.context(fresh_system=True)
        context.setState(mm.XmlSerializer.deserialize(checkpoint))
        integrator.step(interval)
        snapshots.append(snapshot(context))
        checkpoint = checkpoint_xml(context)
        with open(f"{out_dir}/checkpointState.xml", "w") as f:
            f.write(checkpoint)
        if tests:
            results.append({"step": (i+1)*interval, **state_test(wu, context, checkpoint, True)})
        del context, integrator
        checkpoint = read(f"{out_dir}/checkpointState.xml")
    return snapshots, results


def run_binary_restarted(wu, steps, interval):
    checkpoint = None
    snapshots = []
    for _ in range(steps // interval):
        context, integrator = wu.context()
        if checkpoint is None:
            context.setState(mm.XmlSerializer.deserialize(wu.state_xml))
        else:
            context.loadCheckpoint(checkpoint)
        integrator.step(interval)
        snapshots.append(snapshot(context))
        checkpoint = context.createCheckpoint()
        del context, integrator
    return snapshots


def compare(a, b):
    """Per checkpoint: bitwise equality of positions and velocities, and the largest differences."""
    return [{"bitwise": bool(np.array_equal(pa, pb) and np.array_equal(va, vb)),
             "max_dpos_nm": float(np.abs(pa - pb).max()), "max_dvel_nm_ps": float(np.abs(va - vb).max())}
            for (pa, va), (pb, vb) in zip(a, b)]


def repeat_forces(wu):
    """Forces and energy at the start state from two separate Contexts, compared bit for bit."""
    runs = []
    for _ in range(2):
        context, _ = wu.context()
        context.setState(mm.XmlSerializer.deserialize(wu.state_xml))
        runs.append(forces_and_energies(context)[:2])
        del context
    (f1, e1), (f2, e2) = runs
    return {"forces_bitwise": bool(np.array_equal(f1, f2)), "energy_bitwise": e1 == e2,
            "max_dforce": float(np.abs(f1 - f2).max()), "denergy": abs(e1 - e2)}


def timed(fn, *args):
    start = time.perf_counter()
    value = fn(*args)
    return value, round(time.perf_counter() - start, 1)


def main():
    wu_dir, out_root = sys.argv[1:3]
    steps, interval = int(sys.argv[3]), int(sys.argv[4])
    wu = WorkUnit(wu_dir)
    out_dir = f"{out_root}/{wu.name}"
    os.makedirs(out_dir, exist_ok=True)

    context, _ = wu.context()
    context.setState(mm.XmlSerializer.deserialize(wu.state_xml))
    properties = {name: context.getPlatform().getPropertyValue(context, name) for name in FAH_PROPERTIES}
    properties["DeviceName"] = context.getPlatform().getPropertyValue(context, "DeviceName")
    start_test = state_test(wu, context, wu.state_xml, False)
    del context

    repeat, repeat_s = timed(repeat_forces, wu)
    (uninterrupted, fresh_forces), uninterrupted_s = timed(run_uninterrupted, wu, steps, interval)
    (restarted, tests), restarted_s = timed(run_restarted, wu, steps, interval, out_dir, True)
    (restarted2, _), restarted2_s = timed(run_restarted, wu, steps, interval, out_dir, False)
    binary, binary_s = timed(run_binary_restarted, wu, steps, interval)

    integrator = mm.XmlSerializer.deserialize(wu.integrator_xml)
    result = {
        "wu": wu.name, "atoms": wu.system.getNumParticles(), "integrator": type(integrator).__name__,
        "forces": sorted({type(f).__name__ for f in wu.system.getForces()}),
        "steps": steps, "checkpoint_interval": interval, "properties": properties,
        "start_state_test": start_test, "repeat_forces": repeat, "checkpoint_state_tests": tests,
        "fresh_context_forces": fresh_forces,
        "xml_restart_vs_uninterrupted": compare(uninterrupted, restarted),
        "xml_restart_vs_xml_restart": compare(restarted, restarted2),
        "bin_restart_vs_uninterrupted": compare(uninterrupted, binary),
        "wall_s": {"uninterrupted": uninterrupted_s, "xml_restart_with_tests": restarted_s,
                   "xml_restart": restarted2_s, "bin_restart": binary_s, "repeat_forces": repeat_s},
        "clock": "host wall, time.perf_counter",
        "openmm": mm.version.full_version,
    }
    line = json.dumps(result)
    with open(f"{out_dir}/result.json", "w") as f:
        f.write(line + "\n")
    print(line, flush=True)


if __name__ == "__main__":
    main()

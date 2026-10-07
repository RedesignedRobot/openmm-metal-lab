#!/usr/bin/env python3
"""Correctness only: cached Reference, four mixed Metal configurations, checkpoint.

Run `reference` outside the GPU lease, then `run` once per unit under
ultra-tools/lease.sh --correctness --cap 3600. See --help and the companion
fah-correct-stack4.md for exact commands. A failed assertion stops the batch.
The run requires an explicit timestep because the supplied XMLs differ.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import traceback

import numpy as np

FLAGS = ("OPENMM_METAL_DEVICE_BOX", "OPENMM_METAL_DEVICE_BAROSTAT",
         "OPENMM_METAL_COOP_SHAKE")
CONFIGS = {"off": (), "box-barostat": FLAGS[:2], "shake": FLAGS[2:], "all": FLAGS}
FORCE_BAR = 1e-4  # Brief's fixed PME bar; installed gate uses per-system baselines.
ENERGY_BAR = 1e-5
SEED = 2026
STEPS = 5000


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")
    tmp.replace(path)


def identity(args):
    return {"xml_sha256": {name: hashlib.sha256((args.unit / name).read_bytes()).hexdigest()
                            for name in ("system.xml", "state.xml", "integrator.xml")},
            "built": (args.build / "BUILT").read_text()}


def runtime(args):
    # The shared env provides numpy; only this build supplies the Python wrappers.
    sites = list((args.build / "venv/lib").glob("python*/site-packages"))
    if len(sites) != 1:
        raise RuntimeError("Expected one stack4 Python wrapper directory: " + str(sites))
    sys.path.insert(0, str(sites[0]))
    os.environ["OPENMM_PLUGIN_DIR"] = str(args.build / "prefix/lib/plugins")
    import openmm as mm
    from openmm import unit
    imported = Path(mm.__file__).resolve()
    errors = list(mm.Platform.getPluginLoadFailures())
    print(json.dumps({"openmm_file": str(imported), "plugin_load_errors": errors}), flush=True)
    if not imported.is_relative_to(args.build.resolve()):
        raise RuntimeError("OpenMM imported from outside requested build")
    if errors:
        raise RuntimeError("Plugin load failures: " + repr(errors))
    return mm, unit, {"openmm_file": str(imported), "plugin_load_errors": errors}


def inputs(args, mm, unit):
    system, state, integrator = [mm.XmlSerializer.deserialize((args.unit / name).read_text())
                                 for name in ("system.xml", "state.xml", "integrator.xml")]
    if not isinstance(integrator, mm.LangevinMiddleIntegrator):
        raise ValueError("Expected LangevinMiddleIntegrator")
    original_fs = integrator.getStepSize().value_in_unit(unit.femtosecond)
    if args.timestep_fs is not None:
        integrator.setStepSize(args.timestep_fs * unit.femtosecond)
    integrator.setRandomNumberSeed(SEED)
    barostats = [force for force in system.getForces() if isinstance(force, mm.MonteCarloBarostat)]
    added = not barostats
    if added:
        barostats = [mm.MonteCarloBarostat(1 * unit.bar, 300 * unit.kelvin, 25)]
        system.addForce(barostats[0])
    if len(barostats) != 1 or barostats[0].getFrequency() != 25:
        raise ValueError("Expected one MonteCarloBarostat with frequency 25")
    barostats[0].setRandomNumberSeed(SEED + 1)
    if integrator.getTemperature().value_in_unit(unit.kelvin) != 300:
        raise ValueError("Integrator temperature must be 300 K")
    mobile = [system.getParticleMass(i).value_in_unit(unit.dalton) > 0
              for i in range(system.getNumParticles())]
    constraints = [system.getConstraintParameters(i) for i in range(system.getNumConstraints())]
    dof = 3 * sum(mobile) - sum(mobile[i] or mobile[j] for i, j, _ in constraints)
    if any(isinstance(force, mm.CMMotionRemover) for force in system.getForces()):
        dof -= 3
    info = {"atoms": system.getNumParticles(), "constraints": len(constraints), "dof": dof,
            "input_timestep_fs": original_fs,
            "timestep_fs": integrator.getStepSize().value_in_unit(unit.femtosecond),
            "constraint_tolerance": integrator.getConstraintTolerance(),
            "barostat_added": added, "barostat_frequency": 25,
            "input_step_count": state.getStepCount(), "seed": SEED,
            "barostat_seed": SEED + 1}
    return system, state, integrator, constraints, info


def cache_paths(args):
    stem = args.cache / args.unit.name
    return stem.with_suffix(".npz"), stem.with_suffix(".json")


def reference(args):
    if os.environ.get("OPENMM_LEASE_PID"):
        raise RuntimeError("Run Reference outside the GPU lease")
    mm, unit, provenance = runtime(args)
    npz, meta = cache_paths(args)
    key = identity(args)
    if npz.exists() and meta.exists() and json.loads(meta.read_text())["identity"] == key:
        print("Reference cache reused: " + str(npz), flush=True)
        return
    if npz.exists() or meta.exists():
        raise RuntimeError("Stale/incomplete Reference cache; use a new --cache directory")
    system, state, integrator, _, info = inputs(args, mm, unit)
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Reference"))
    context.setState(state)  # No minimization, constraint projection or velocity reset.
    result = context.getState(getForces=True, getEnergy=True)
    forces = result.getForces(asNumpy=True).value_in_unit(unit.kilojoule_per_mole / unit.nanometer)
    energy = result.getPotentialEnergy().value_in_unit(unit.kilojoule_per_mole)
    if not np.isfinite(forces).all() or not np.isfinite(energy):
        raise RuntimeError("Reference step=0 quantity=forces/energy nonfinite")
    args.cache.mkdir(parents=True, exist_ok=True)
    np.savez(npz, forces=forces, energy=energy)
    write_json(meta, {"identity": key, "runtime": provenance, "input": info,
                      "force_norm": float(np.linalg.norm(forces)), "energy_kj_mol": float(energy)})
    print(json.dumps({"reference": str(npz), "energy_kj_mol": float(energy),
                      "force_norm": float(np.linalg.norm(forces))}), flush=True)


def check(condition, row, step, quantity, actual, bar):
    if not condition:
        failure = {"configuration": row["configuration"], "step": step,
                   "quantity": quantity, "actual": str(actual), "bar": str(bar)}
        row["failure"] = failure
        raise AssertionError(json.dumps(failure))


def new_context(args, mm, unit, deterministic=False):
    system, state, integrator, constraints, info = inputs(args, mm, unit)
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"),
                         {"Precision": "mixed", "DeterministicForces": str(deterministic).lower()})
    context.setState(state)
    # Report steps relative to the supplied state; retain its time and velocities.
    context.setStepCount(0)
    return context, integrator, constraints, info


def checkpoint(args, mm, unit, row):
    row["phase"] = "checkpoint"
    context, integrator, _, _ = new_context(args, mm, unit, deterministic=True)
    integrator.step(2500)
    row["step"] = 2500
    blob = context.createCheckpoint()
    checkpoint_path = args.output / (args.unit.name + "-all-step2500.chk")
    checkpoint_path.write_bytes(blob)
    row["checkpoint"] = {"path": str(checkpoint_path), "bytes": len(blob),
                         "device_marker_v2_present": bytes.fromhex("0200ba0d") in blob,
                         "compared_steps": 0, "max_position_delta_nm": 0.0}
    expected = []
    for _ in range(100):
        integrator.step(1)
        expected.append(context.getState(getPositions=True).getPositions(asNumpy=True)
                        .value_in_unit(unit.nanometer).copy())
    del context, integrator
    context, integrator, _, _ = new_context(args, mm, unit, deterministic=True)
    context.loadCheckpoint(blob)
    for offset, wanted in enumerate(expected, 1):
        row["step"] = 2500 + offset
        integrator.step(1)
        actual = context.getState(getPositions=True).getPositions(asNumpy=True).value_in_unit(unit.nanometer)
        delta = float(np.max(np.abs(actual - wanted)))
        row["checkpoint"]["compared_steps"] = offset
        row["checkpoint"]["max_position_delta_nm"] = max(delta, row["checkpoint"]["max_position_delta_nm"])
        check(actual.tobytes() == wanted.tobytes(), row, row["step"],
              "checkpoint_positions_bitwise", delta, "bitwise equal at every step 2501..2600")
    row["checkpoint"]["passed"] = True


def worker(args):
    row = {"unit": args.unit.name, "configuration": args.config, "status": "RUNNING",
           "phase": "initialization", "step": 0,
           "flags": {flag: os.environ.get(flag) for flag in FLAGS},
           "identity": identity(args), "force_bar": FORCE_BAR, "energy_bar": ENERGY_BAR}
    path = args.output / (args.unit.name + "-" + args.config + ".json")
    try:
        if not os.environ.get("OPENMM_LEASE_PID"):
            raise RuntimeError("Metal run requires ultra-tools/lease.sh --correctness")
        mm, unit, row["runtime"] = runtime(args)
        npz, meta = cache_paths(args)
        if json.loads(meta.read_text())["identity"] != row["identity"]:
            raise RuntimeError("Reference cache identity mismatch")
        with np.load(npz) as data:
            fref, eref = data["forces"], float(data["energy"])
        context, integrator, constraints, row["input"] = new_context(args, mm, unit)
        result = context.getState(getForces=True, getEnergy=True)
        forces = result.getForces(asNumpy=True).value_in_unit(unit.kilojoule_per_mole / unit.nanometer)
        energy = result.getPotentialEnergy().value_in_unit(unit.kilojoule_per_mole)
        relf = float(np.linalg.norm(forces - fref) / np.linalg.norm(fref))
        rele = float(abs(energy - eref) / abs(eref))
        check(np.isfinite(forces).all() and np.isfinite(energy), row, 0, "initial_forces_energy_finite", energy, "finite")
        row.update(relative_force_error=relf, relative_energy_error=rele,
                   initial_energy_kj_mol=float(energy), reference_energy_kj_mol=eref,
                   max_force_error=float(np.max(np.abs(forces - fref))))
        check(relf <= FORCE_BAR, row, 0, "relative_force_norm_error", relf, FORCE_BAR)
        check(rele <= ENERGY_BAR, row, 0, "relative_potential_energy_error", rele, ENERGY_BAR)
        iatoms = np.array([c[0] for c in constraints], dtype=int)
        jatoms = np.array([c[1] for c in constraints], dtype=int)
        lengths = np.array([c[2].value_in_unit(unit.nanometer) for c in constraints])
        gas_constant = unit.MOLAR_GAS_CONSTANT_R.value_in_unit(unit.kilojoule_per_mole / unit.kelvin)
        previous_volume = context.getState().getPeriodicBoxVolume().value_in_unit(unit.nanometer**3)
        row.update(phase="dynamics", max_relative_constraint_violation=0.0, max_constraint_step=0,
                   initial_volume_nm3=float(previous_volume), min_volume_nm3=float(previous_volume),
                   max_volume_nm3=float(previous_volume), accepted_moves=0, attempted_moves=0,
                   energy_min_kj_mol=float(energy), energy_max_kj_mol=float(energy),
                   temperature_samples=0, temperature_sum_K=0.0, finite_steps=0)
        baseline = None
        if args.config != "off":
            baseline_row = json.loads((args.output / (args.unit.name + "-off.json")).read_text())
            if baseline_row["status"] != "PASS" or baseline_row["identity"] != row["identity"] or baseline_row["input"] != row["input"]:
                raise RuntimeError("Missing matching passed flags-off baseline")
            baseline = baseline_row["max_relative_constraint_violation"]
        trace = args.output / (args.unit.name + "-" + args.config + ".jsonl")
        with trace.open("w") as samples:
            for step in range(1, STEPS + 1):
                row["step"] = step
                integrator.step(1)
                state = context.getState(getEnergy=True, getPositions=True)
                positions = state.getPositions(asNumpy=True).value_in_unit(unit.nanometer)
                potential = float(state.getPotentialEnergy().value_in_unit(unit.kilojoule_per_mole))
                kinetic = float(state.getKineticEnergy().value_in_unit(unit.kilojoule_per_mole))
                volume = float(state.getPeriodicBoxVolume().value_in_unit(unit.nanometer**3))
                check(np.isfinite(positions).all(), row, step, "positions_finite", "nonfinite", "finite")
                check(np.isfinite([potential, kinetic, volume]).all(), row, step,
                      "energy_volume_finite", [potential, kinetic, volume], "finite")
                violation = float(np.max(np.abs(np.linalg.norm(positions[iatoms] - positions[jatoms], axis=1) / lengths - 1))) if len(lengths) else 0.0
                if violation > row["max_relative_constraint_violation"]:
                    row["max_relative_constraint_violation"] = violation
                    row["max_constraint_step"] = step
                if baseline is not None:
                    check(violation <= 2 * baseline, row, step, "relative_constraint_violation", violation, 2 * baseline)
                if step % 25 == 0:
                    row["attempted_moves"] += 1
                    row["accepted_moves"] += int(volume != previous_volume)
                else:
                    check(volume == previous_volume, row, step, "volume_changed_without_attempt", volume, previous_volume)
                previous_volume = volume
                temperature = 2 * kinetic / (row["input"]["dof"] * gas_constant)
                if step > STEPS // 2:
                    row["temperature_samples"] += 1
                    row["temperature_sum_K"] += temperature
                row["finite_steps"] += 1
                row["energy_min_kj_mol"] = min(potential, row["energy_min_kj_mol"])
                row["energy_max_kj_mol"] = max(potential, row["energy_max_kj_mol"])
                row["min_volume_nm3"] = min(volume, row["min_volume_nm3"])
                row["max_volume_nm3"] = max(volume, row["max_volume_nm3"])
                if step % 25 == 0:
                    samples.write(json.dumps({"step": step, "potential_kj_mol": potential,
                                              "kinetic_kj_mol": kinetic, "temperature_K": temperature,
                                              "volume_nm3": volume, "constraint_violation": violation}) + "\n")
                if step % 500 == 0:
                    samples.flush()
                    write_json(path, row)
                    print(json.dumps({"unit": args.unit.name, "configuration": args.config,
                                      "step": step, "accepted": row["accepted_moves"],
                                      "constraint_max": row["max_relative_constraint_violation"]}), flush=True)
        row.update(final_volume_nm3=volume, mean_temperature_K=row["temperature_sum_K"] / row["temperature_samples"],
                   acceptance_fraction=row["accepted_moves"] / row["attempted_moves"],
                   constraint_ratio_to_off=1.0 if baseline is None else row["max_relative_constraint_violation"] / baseline)
        check(abs(row["mean_temperature_K"] / 300 - 1) <= .02, row, STEPS,
              "mean_temperature_last_half_K", row["mean_temperature_K"], "294..306")
        check(row["max_volume_nm3"] > row["min_volume_nm3"], row, STEPS,
              "volume_moves", [row["min_volume_nm3"], row["max_volume_nm3"]], "nonzero range")
        check(.1 <= row["acceptance_fraction"] <= .9, row, STEPS,
              "barostat_acceptance_fraction", row["acceptance_fraction"], "0.1..0.9")
        del context, integrator
        if args.config == "all":
            checkpoint(args, mm, unit, row)
        row["status"] = "PASS"
    except Exception as error:
        row["status"] = "FAIL"
        row.setdefault("failure", {"configuration": args.config, "step": row["step"],
                                   "quantity": row["phase"], "actual": str(error)})
        traceback.print_exc()
    finally:
        write_json(path, row)
        print(json.dumps({"result": str(path), "status": row["status"], "failure": row.get("failure")}), flush=True)
    return 0 if row["status"] == "PASS" else 1


def run(args):
    if not os.environ.get("OPENMM_LEASE_PID"):
        raise RuntimeError("Use ultra-tools/lease.sh --correctness for run")
    args.output.mkdir(parents=True, exist_ok=True)
    for config, enabled in CONFIGS.items():
        env = dict(os.environ)
        for flag in FLAGS:
            env.pop(flag, None)
        env.update({flag: "1" for flag in enabled})
        command = [sys.executable, str(Path(__file__).resolve()), "worker", "--unit", str(args.unit),
                   "--build", str(args.build), "--cache", str(args.cache), "--output", str(args.output),
                   "--timestep-fs", str(args.timestep_fs), "--config", config]
        completed = subprocess.run(command, env=env)
        if completed.returncode:
            return completed.returncode
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("reference", "run", "worker"))
    parser.add_argument("--unit", type=Path, required=True, help="Directory with system/state/integrator.xml")
    parser.add_argument("--build", type=Path, default=Path("/tmp/openmm-metal-bench/ultra-m029-stack4"))
    parser.add_argument("--cache", type=Path, default=Path("/tmp/m029-fah-correct-cache"))
    parser.add_argument("--output", type=Path, default=Path("/tmp/m029-fah-correct-results"))
    parser.add_argument("--timestep-fs", type=float, help="Explicit timestep agreed with timing window")
    parser.add_argument("--config", choices=tuple(CONFIGS), default="off", help="Internal worker configuration")
    args = parser.parse_args()
    if args.mode != "reference" and (args.timestep_fs is None or args.timestep_fs <= 0):
        parser.error("run/worker requires a positive --timestep-fs")
    args.unit = args.unit.resolve()
    args.build = args.build.resolve()
    args.cache = args.cache.resolve()
    args.output = args.output.resolve()
    if args.mode == "reference":
        reference(args)
        return 0
    if args.mode == "run":
        return run(args)
    return worker(args)


if __name__ == "__main__":
    sys.exit(main())

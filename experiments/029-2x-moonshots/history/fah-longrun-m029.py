#!/usr/bin/env python3
"""FAH stack4 correctness experiment. Run `run` ONLY under a correctness lease.

Each arm has 25,000 equilibration + 250,000 production steps. No timing is
collected. `summarize` reads the append-only observations without using a GPU.
Checkpoint decoding is specific to db6af3aad and LangevinMiddleIntegrator.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import sys

import numpy as np

COMMIT = "db6af3aad08748d69c28d4c18ce4fc7a73277860"
FLAGS = ("OPENMM_METAL_DEVICE_BOX", "OPENMM_METAL_DEVICE_BAROSTAT",
         "OPENMM_METAL_COOP_SHAKE")
EQUIL = 25000
PRODUCTION = 250000
STRIDE = 25
BOX_STRIDE = 5000
BLOCK_STEPS = 12500  # 20 nonoverlapping production blocks, chosen before data.


def emit(file, **record):
    file.write(json.dumps(record, allow_nan=False, sort_keys=True) + "\n")
    file.flush()


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def require(condition, quantity, value):
    if not condition:
        raise ValueError(f"{quantity}: {value}")


def device_checkpoint(checkpoint, particles):
    """Verify the header, then decode the platform trailer, not a marker search.

    ContextImpl writes its header, Metal writes marker + Common payload + 448
    bytes, and LangevinMiddle's inherited createCheckpoint appends nothing.
    """
    magic = b"OpenMM Binary Checkpoint\n\0"
    require(checkpoint.startswith(magic), "checkpoint magic", "mismatch")
    offset = len(magic)

    def integer():
        nonlocal offset
        value, = struct.unpack_from("<i", checkpoint, offset)
        offset += 4
        return value

    def string():
        nonlocal offset
        length = integer()
        require(0 <= length < 4096, "checkpoint string length", length)
        value = checkpoint[offset:offset+length]
        offset += length
        return value

    require(string() == b"Metal", "checkpoint platform", "not Metal")
    require(integer() == particles, "checkpoint particle count", "mismatch")
    parameters = integer()
    require(0 <= parameters < 1000, "checkpoint parameter count", parameters)
    for _ in range(parameters):
        string()
        offset += 8
    marker = integer()
    require(marker == 0xDBA0002, "device checkpoint marker / device eligibility", hex(marker))
    require(integer() == 3 and integer() == 1, "checkpoint version/precision", "expected 3/mixed")
    trial = np.frombuffer(checkpoint[-448:-320], dtype="<f8").copy()
    raw_box = checkpoint[-320:]
    box = np.frombuffer(raw_box, dtype="<f8", offset=208, count=12).reshape(3, 4)[:, :3].copy()
    volume, = struct.unpack_from("<d", raw_box, 304)
    require(np.isfinite(trial).all() and np.isfinite(box).all() and math.isfinite(volume),
            "device checkpoint finite", False)
    return trial, box, volume, checkpoint[-448:].hex()


def arm(args):
    build = args.build.resolve()
    built = (build / "BUILT").read_text()
    require(f"commit {COMMIT}\n" in built, "BUILT commit", "not stack4")
    sites = list((build / "venv/lib").glob("python*/site-packages"))
    require(len(sites) == 1, "stack4 site-packages", [str(p) for p in sites])
    sys.path.insert(0, str(sites[0]))
    import openmm as mm
    from openmm import unit as u
    require(Path(mm.__file__).resolve().is_relative_to(build), "OpenMM import", mm.__file__)
    for flag in FLAGS:
        require(os.environ.get(flag) == ("1" if args.arm == "on" else "0"), flag, os.environ.get(flag))
    require(Path(os.environ.get("OPENMM_PLUGIN_DIR", "")).resolve() == build / "prefix/lib/plugins",
            "plugin directory", os.environ.get("OPENMM_PLUGIN_DIR"))
    seed = {"tip4pew": 41871, "tip3p-hmr": 63913}[args.unit] + (0 if args.arm == "on" else 100)
    directory = Path("/tmp/m029-fah-" + args.unit)
    system = mm.XmlSerializer.deserialize((directory / "system.xml").read_text())
    initial = mm.XmlSerializer.deserialize((directory / "state.xml").read_text())
    integrator = mm.XmlSerializer.deserialize((directory / "integrator.xml").read_text())
    require(type(integrator) is mm.LangevinMiddleIntegrator, "integrator", type(integrator).__name__)
    integrator.setStepSize(0.002*u.picoseconds)
    integrator.setTemperature(300*u.kelvin)
    integrator.setRandomNumberSeed(seed)
    barostats = [f for f in system.getForces() if isinstance(f, mm.MonteCarloBarostat)]
    if not barostats:
        system.addForce(mm.MonteCarloBarostat(1*u.bar, 300*u.kelvin, STRIDE))
        barostats = [system.getForce(system.getNumForces()-1)]
    require(len(barostats) == 1, "barostat count", len(barostats))
    barostat = barostats[0]
    barostat.setDefaultPressure(1*u.bar)
    barostat.setDefaultTemperature(300*u.kelvin)
    barostat.setFrequency(STRIDE)
    barostat.setRandomNumberSeed(seed+1)
    constraints = [system.getConstraintParameters(i) for i in range(system.getNumConstraints())]
    first = np.array([c[0] for c in constraints], dtype=int)
    second = np.array([c[1] for c in constraints], dtype=int)
    lengths = np.array([c[2].value_in_unit(u.nanometer) for c in constraints])
    properties = {"MetalPrecision": "mixed"}
    context = None
    step = 0
    with args.raw.open("a") as out:
        try:
            context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), properties)
            context.setState(initial)
            context.setTime(0*u.picoseconds)
            context.setStepCount(0)
            context.setParameter(mm.MonteCarloBarostat.Pressure(), 1.0)
            context.setParameter(mm.MonteCarloBarostat.Temperature(), 300.0)
            emit(out, kind="arm", unit=args.unit, arm=args.arm, seed=seed, barostat_seed=seed+1,
                 particles=system.getNumParticles(), constraints=len(constraints),
                 integrator_tolerance=integrator.getConstraintTolerance(), step_ps=0.002,
                 equilibration_steps=EQUIL, production_steps=PRODUCTION,
                 pressure_bar=1, temperature_K=300, barostat_frequency=STRIDE,
                 openmm=mm.__file__, extension=mm._openmm.__file__, built=built.splitlines()[:3],
                 library_sha256=digest(build / "prefix/lib/libOpenMM.dylib"),
                 plugin_sha256=digest(build / "prefix/lib/plugins/libOpenMMMetal.dylib"),
                 input_sha256={name: digest(directory / name) for name in
                               ("system.xml", "state.xml", "integrator.xml")},
                 flags={flag: os.environ[flag] for flag in FLAGS},
                 properties={name: context.getPlatform().getPropertyValue(context, name)
                             for name in context.getPlatform().getPropertyNames()})
            previous_box = None
            observed_accepts = 0
            production_accepts = 0
            for step in range(0, EQUIL+PRODUCTION+1, STRIDE):
                if step:
                    integrator.step(STRIDE)
                state = context.getState(getPositions=True, getVelocities=True, getEnergy=True)
                positions = state.getPositions(asNumpy=True).value_in_unit(u.nanometer)
                velocities = state.getVelocities(asNumpy=True).value_in_unit(u.nanometer/u.picosecond)
                box = state.getPeriodicBoxVectors(asNumpy=True).value_in_unit(u.nanometer)
                volume = state.getPeriodicBoxVolume().value_in_unit(u.nanometer**3)
                energy = state.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
                kinetic = state.getKineticEnergy().value_in_unit(u.kilojoule_per_mole)
                require(np.isfinite(positions).all() and np.isfinite(velocities).all()
                        and np.isfinite(box).all() and all(map(math.isfinite, (volume, energy, kinetic))),
                        "positions/velocities/box/energies finite", False)
                require(volume > 0, "volume", volume)
                product = float(np.prod(np.diag(box)))
                volume_error = abs(volume-product)/abs(product)
                require(volume_error <= 1e-12, "host volume/box relative error", volume_error)
                errors = np.abs(np.linalg.norm(positions[first]-positions[second], axis=1)/lengths-1)
                worst = int(np.argmax(errors)) if len(errors) else 0
                constraint_error = float(errors[worst]) if len(errors) else 0.0
                require(constraint_error <= 1e-5, f"constraint {worst} relative error", constraint_error)
                accepted = previous_box is not None and box.tobytes() != previous_box.tobytes()
                observed_accepts += int(accepted)
                if step > EQUIL:
                    production_accepts += int(accepted)
                previous_box = box.copy()
                emit(out, kind="sample", unit=args.unit, arm=args.arm, step=step,
                     production=step > EQUIL, volume_nm3=volume, potential_kJ_mol=energy,
                     constraint_relative=constraint_error, worst_constraint=worst,
                     host_volume_relative=volume_error, accepted=bool(accepted))
                if args.arm == "on" and step % BOX_STRIDE == 0:
                    trial, device_box, device_volume, raw_hex = device_checkpoint(
                        context.createCheckpoint(), system.getNumParticles())
                    equal = box.astype("<f8").tobytes() == device_box.astype("<f8").tobytes()
                    device_error = abs(device_volume-product)/abs(product)
                    emit(out, kind="box", unit=args.unit, arm=args.arm, step=step,
                         bitwise_equal=equal, device_volume_relative=device_error,
                         host_box=box.tolist(), device_trailer_hex=raw_hex,
                         attempts=trial[9], accepts=trial[10])
                    require(equal, "host/device box bitwise equality", float(np.max(np.abs(box-device_box))))
                    require(device_error <= 1e-12, "device volume/box relative error", device_error)
                    require(trial[9] == step//STRIDE, "device lifetime attempts", trial[9])
                    require(trial[10] == observed_accepts, "device/observed lifetime accepts",
                            [trial[10], observed_accepts])
                if step % 25000 == 0:
                    print(f"{args.unit} {args.arm} step={step} checked", flush=True)
            emit(out, kind="complete", unit=args.unit, arm=args.arm, step=step,
                 production_attempts=PRODUCTION//STRIDE, production_accepts=production_accepts)
        except Exception as error:
            emit(out, kind="failure", unit=args.unit, arm=args.arm, step=step,
                 quantity=str(error), exception=type(error).__name__)
            # Preserve a concrete repro state, without changing product sources.
            if context is not None:
                try:
                    checkpoint_path = args.raw.with_suffix(f".{args.arm}.step{step}.chk")
                    checkpoint_path.write_bytes(context.createCheckpoint())
                    emit(out, kind="failure_checkpoint", path=str(checkpoint_path))
                except Exception as checkpoint_error:
                    emit(out, kind="checkpoint_failure", quantity=str(checkpoint_error))
            print(f"FAIL {args.unit} {args.arm} step={step}: {error}", flush=True)
            return 1
    return 0


def statistics(values):
    values = np.asarray(values, dtype=float)
    size = BLOCK_STEPS//STRIDE
    require(len(values) == PRODUCTION//STRIDE, "production sample count", len(values))
    means = values.reshape(-1, size).mean(axis=1)
    variance = float(np.var(values, ddof=1))
    block_variance = float(np.var(means, ddof=1))
    # Variance inflation inferred from the prespecified blocks, in sample units.
    inefficiency = max(1.0, size*block_variance/variance) if variance else 1.0
    return dict(mean=float(values.mean()), standard_error=math.sqrt(block_variance/len(means)),
                block_steps=BLOCK_STEPS, blocks=len(means), samples_per_block=size,
                statistical_inefficiency=inefficiency,
                effective_samples=len(values)/inefficiency)


def summarize(raw):
    records = [json.loads(line) for line in raw.read_text().splitlines()]
    failures = [r for r in records if r["kind"] == "failure"]
    result = dict(unit=next(r["unit"] for r in records if "unit" in r), raw=str(raw),
                  raw_sha256=digest(raw), evaluation_step=EQUIL+PRODUCTION,
                  failures=failures, arms={}, comparisons={})
    for name in ("on", "off"):
        samples = [r for r in records if r["kind"] == "sample" and r["arm"] == name]
        complete = [r for r in records if r["kind"] == "complete" and r["arm"] == name]
        if len(complete) != 1:
            result["verdict"] = "FAIL" if failures else "INCOMPLETE"
            return result
        production = [r for r in samples if r["production"]]
        result["arms"][name] = dict(
            volume=statistics([r["volume_nm3"] for r in production]),
            potential=statistics([r["potential_kJ_mol"] for r in production]),
            acceptance_fraction=complete[0]["production_accepts"]/complete[0]["production_attempts"],
            production_accepts=complete[0]["production_accepts"],
            production_attempts=complete[0]["production_attempts"],
            max_constraint_relative=max(r["constraint_relative"] for r in samples),
            max_constraint_step=max(samples, key=lambda r: r["constraint_relative"])["step"],
            observations=len(samples),
            max_host_volume_relative=max(r["host_volume_relative"] for r in samples))
        final_boxes = [r for r in records if r["kind"] == "box" and r["arm"] == name
                       and r["step"] == EQUIL+PRODUCTION]
        final_scale = (struct.unpack_from("<d", bytes.fromhex(final_boxes[0]["device_trailer_hex"]))[0]
                       if final_boxes else None)
        result["arms"][name]["final_trial_volume_scale_nm3"] = final_scale
        result["arms"][name]["trial_volume_scale_source"] = (
            "device checkpoint trial[0]" if final_scale is not None else
            "unreachable: private host MonteCarloBarostatImpl::volumeScale; no Python getter or checkpoint field")
        # Accepted proposals are selected by Metropolis, so their maximum/quantiles
        # do not identify the host's actual uniform proposal half-width.
        displacements = [abs(b["volume_nm3"]-a["volume_nm3"])
                         for a, b in zip(samples, samples[1:])
                         if b["accepted"] and b["step"] > EQUIL+PRODUCTION-BLOCK_STEPS]
        result["arms"][name]["last_block_accepted_abs_dV_nm3"] = dict(
            block_steps=BLOCK_STEPS, count=len(displacements),
            median=float(np.median(displacements)) if displacements else None,
            p95=float(np.percentile(displacements, 95)) if displacements else None,
            maximum=max(displacements) if displacements else None)
    passed = not failures
    for quantity in ("volume", "potential"):
        on, off = (result["arms"][a][quantity] for a in ("on", "off"))
        combined = math.hypot(on["standard_error"], off["standard_error"])
        difference = abs(on["mean"]-off["mean"])
        ok = difference <= 3*combined
        result["comparisons"][quantity] = dict(absolute_difference=difference,
                                              combined_standard_error=combined,
                                              three_standard_errors=3*combined, passed=ok)
        passed &= ok
    acceptance_count_difference = abs(result["arms"]["on"]["production_accepts"]-
                                      result["arms"]["off"]["production_accepts"])
    acceptance_difference = acceptance_count_difference/(PRODUCTION//STRIDE)
    # Exactly 0.05 is allowed; compare counts to avoid a floating boundary error.
    acceptance_passed = 20*acceptance_count_difference <= PRODUCTION//STRIDE
    result["comparisons"]["acceptance"] = dict(absolute_difference=acceptance_difference,
                                               limit=0.05, passed=acceptance_passed)
    passed &= acceptance_passed
    boxes = [r for r in records if r["kind"] == "box"]
    result["box"] = dict(checks=len(boxes), bitwise_equal=all(r["bitwise_equal"] for r in boxes),
                         max_device_volume_relative=max(r["device_volume_relative"] for r in boxes))
    passed &= len(boxes) == (EQUIL+PRODUCTION)//BOX_STRIDE+1
    passed &= result["box"]["bitwise_equal"] and result["box"]["max_device_volume_relative"] <= 1e-12
    result["verdict"] = "PASS" if passed else "FAIL"
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("run", "arm", "summarize"))
    parser.add_argument("--unit", choices=("tip4pew", "tip3p-hmr"))
    parser.add_argument("--build", type=Path, default=Path("/tmp/openmm-metal-bench/ultra-m029-stack4"))
    parser.add_argument("--raw", required=True, type=Path)
    parser.add_argument("--arm", choices=("on", "off"))
    args = parser.parse_args()
    if args.mode == "summarize":
        result = summarize(args.raw)
        print(json.dumps(result, indent=2, allow_nan=False))
        return 0 if result["verdict"] == "PASS" else 1
    require(args.unit is not None, "--unit", "required")
    if args.mode == "arm":
        require(args.arm is not None, "--arm", "required")
        return arm(args)
    require(not args.raw.exists(), "raw output", "already exists; use a new path")
    args.raw.parent.mkdir(parents=True, exist_ok=True)
    for name in ("on", "off"):
        env = os.environ.copy()
        # Clear inherited experimental switches so the contrast is exactly these three.
        for key in list(env):
            if key.startswith("OPENMM_METAL_"):
                del env[key]
        env.update({flag: "1" if name == "on" else "0" for flag in FLAGS})
        command = [sys.executable, str(Path(__file__).resolve()), "arm", "--unit", args.unit,
                   "--build", str(args.build), "--raw", str(args.raw), "--arm", name]
        code = subprocess.call(command, env=env)
        if code:
            return code
    # Statistics are intentionally a separate CPU-only command outside the lease.
    return 0


if __name__ == "__main__":
    sys.exit(main())

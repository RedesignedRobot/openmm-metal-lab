"""Compare fused PME forces/energy with Reference and an installed VkFFT build.
Run this script through a correctness lease. Usage:
  candidate-python checkPmePencils.py <VkFFT-python> <results-directory>
The control build must retain VkFFT on energy steps. Each child uses a fresh process.
"""
import json
from pathlib import Path
import subprocess
import sys

import numpy as np
import openmm as mm
from openmm import unit as u

CASES = [("apoa-grid", (98, 98, 98), False),
         ("ljpme-grid", (98, 98, 98), True),
         ("cellulose-grid", (231, 112, 110), False),
         ("stmv-grid", (198, 200, 200), False)]


def make_system(grid, lj):
    system = mm.System()
    lengths = np.array(grid)/9
    box = np.diag(lengths)
    # Include an explicitly triclinic case at every grid size.
    box[1, 0] = lengths[0]*0.17
    box[2, 0] = lengths[0]*-0.11
    box[2, 1] = lengths[1]*0.19
    system.setDefaultPeriodicBoxVectors(*[mm.Vec3(*v) for v in box])
    force = mm.NonbondedForce()
    force.setNonbondedMethod(force.LJPME if lj else force.PME)
    force.setCutoffDistance(0.9)
    force.setPMEParameters(2.920289872, *grid)
    if lj:
        force.setLJPMEParameters(2.920289872, 49, 49, 49)
    force.setReciprocalSpaceForceGroup(1)
    for i in range(1024):
        system.addParticle(12)
        force.addParticle(1 if i % 2 else -1, 0.3, 0.15 if lj else 0)
    system.addForce(force)
    positions = np.random.default_rng(2026).random((1024, 3)) @ box
    return system, positions, force


def evaluate(system, positions, platform, precision=None):
    props = {} if precision is None else {"Precision": precision, "DeterministicForces": "true"}
    integrator = mm.VerletIntegrator(0.001)
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName(platform), props)
    context.setPositions(positions)
    def state(energy):
        s = context.getState(getForces=True, getEnergy=energy, groups={1})
        f = np.array(s.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole/u.nanometer))
        e = s.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole) if energy else 0
        return f, e
    f, e = state(True)
    if platform == "Metal":
        repeat, _ = state(True)
        assert np.array_equal(f, repeat), "DeterministicForces changed within a Context"
        force_only, _ = state(False)
        assert rel(force_only, f) < 2e-6, "energy and force-only paths differ"
    del context, integrator
    return f, e


def rel(a, b):
    return np.linalg.norm(a-b)/max(np.linalg.norm(b), 1e-30)


def worker(mode, destination):
    values = {}
    for name, grid, lj in CASES:
        system, positions, _ = make_system(grid, lj)
        if mode == "control":
            f, e = evaluate(system, positions, "Reference")
            values[name+"-reference-f"] = f
            values[name+"-reference-e"] = e
        for precision in ("single", "mixed"):
            f, e = evaluate(system, positions, "Metal", precision)
            values[name+"-"+precision+"-f"] = f
            values[name+"-"+precision+"-e"] = e
            print(mode, name, precision, "evaluated", flush=True)
    np.savez(destination, **values)


def main():
    if sys.argv[1] in ("control", "candidate"):
        worker(sys.argv[1], sys.argv[2])
        return
    control_python, results = sys.argv[1:]
    results = Path(results)
    results.mkdir(parents=True, exist_ok=True)
    script = str(Path(__file__).resolve())
    subprocess.run([control_python, script, "control", str(results/"control.npz")], check=True)
    for repeat in range(3):
        subprocess.run([sys.executable, script, "candidate", str(results/f"candidate-{repeat}.npz")], check=True)
    control = np.load(results/"control.npz")
    candidates = [np.load(results/f"candidate-{i}.npz") for i in range(3)]
    rows = []
    for name, _, _ in CASES:
        for precision in ("single", "mixed"):
            key = name+"-"+precision
            base, actual, reference = control[key+"-f"], candidates[0][key+"-f"], control[name+"-reference-f"]
            ebase, eactual, eref = control[key+"-e"], candidates[0][key+"-e"], control[name+"-reference-e"]
            row = dict(case=name, precision=precision, fused_vkfft=rel(actual, base),
                       reference_fused=rel(actual, reference), reference_vkfft=rel(base, reference),
                       energy_delta=float(abs(eactual-ebase)/max(abs(ebase), 1)),
                       energy_reference_fused=float(abs(eactual-eref)), energy_reference_vkfft=float(abs(ebase-eref)))
            print(json.dumps(row), flush=True)
            rows.append(row)
            assert row["fused_vkfft"] < 2e-6
            assert row["reference_fused"] <= 1.02*row["reference_vkfft"]+1e-7
            assert row["energy_delta"] < 2e-6
            # One float ULP of the reciprocal energy is the single precision energy floor.
            assert row["energy_reference_fused"] <= row["energy_reference_vkfft"]+abs(float(np.spacing(np.float32(eref))))
            for repeat in candidates[1:]:
                assert np.array_equal(actual, repeat[key+"-f"]), "DeterministicForces changed across processes"
    (results/"summary.json").write_text(json.dumps(rows, indent=2)+"\n")
    print("PASS: forces, energy, Reference, triclinic LJPME and three-process deterministic repeats")


if __name__ == "__main__":
    main()

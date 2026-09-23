"""Run a FAHBench work unit for a number of steps on Metal and save the final state.

usage: bitwise.py <wu-dir> <precision> <steps> <out.npz>
Steps in blocks of 100 and requests the energy after each block, as fahwu.py does, so force-only
steps and energy steps both run.  Prints one JSON line with SHA-256 digests of the final positions,
velocities and forces and of the exact (hex) potential and kinetic energies of every block, so two
builds can be compared bit for bit: same digest means bitwise-identical values.
"""
import hashlib
import json
import sys

import numpy as np
import openmm as mm
import openmm.unit as u

BLOCK = 100


def main():
    wu, precision, steps, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    read = lambda name: mm.XmlSerializer.deserialize(
        open(f"{wu}/{name}").read().replace("stateCheckpoint", "State"))
    system, integrator, state = read("system.xml"), read("integrator.xml"), read("state.xml")
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), {"Precision": precision})
    context.setState(state)
    energies = []
    for _ in range(steps // BLOCK):
        integrator.step(BLOCK)
        s = context.getState(getEnergy=True)
        energies.append((s.getPotentialEnergy().value_in_unit(u.kilojoule_per_mole).hex(),
                         s.getKineticEnergy().value_in_unit(u.kilojoule_per_mole).hex()))
    s = context.getState(getPositions=True, getVelocities=True, getForces=True)
    pos = s.getPositions(asNumpy=True).value_in_unit(u.nanometer)
    vel = s.getVelocities(asNumpy=True).value_in_unit(u.nanometer / u.picosecond)
    frc = s.getForces(asNumpy=True).value_in_unit(u.kilojoule_per_mole / u.nanometer)
    np.savez(out, positions=pos, velocities=vel, forces=frc, energies=np.array(energies))
    digest = lambda a: hashlib.sha256(np.ascontiguousarray(a, dtype=np.float64).tobytes()).hexdigest()[:16]
    print(json.dumps({"wu": wu.rstrip("/").split("/")[-1], "precision": precision, "steps": steps,
                      "positions_sha256": digest(pos), "velocities_sha256": digest(vel),
                      "forces_sha256": digest(frc),
                      "energies_sha256": hashlib.sha256(json.dumps(energies).encode()).hexdigest()[:16],
                      "final_potential_kj": float.fromhex(energies[-1][0]),
                      "openmm": mm.version.openmm_library_path}))


if __name__ == "__main__":
    main()

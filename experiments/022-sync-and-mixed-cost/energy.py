"""Evaluate the potential energy of a FAHBench work unit's start state repeatedly on Metal.

usage: energy.py <wu-dir> <precision> <repeats>
Prints one JSON line with every value (exact, as hex) and their spread.  The positions never change,
so any spread is the platform's own run-to-run nondeterminism in the energy sum, which is the
yardstick for comparing two builds' energies.
"""
import json
import sys

import openmm as mm
import openmm.unit as u


def main():
    wu, precision, repeats = sys.argv[1], sys.argv[2], int(sys.argv[3])
    read = lambda name: mm.XmlSerializer.deserialize(
        open(f"{wu}/{name}").read().replace("stateCheckpoint", "State"))
    system, integrator, state = read("system.xml"), read("integrator.xml"), read("state.xml")
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), {"Precision": precision})
    context.setState(state)
    values = [context.getState(getEnergy=True).getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
              for _ in range(repeats)]
    print(json.dumps({"wu": wu.rstrip("/").split("/")[-1], "precision": precision, "repeats": repeats,
                      "min": min(values), "max": max(values), "distinct": len(set(values)),
                      "values_hex": [v.hex() for v in values], "openmm": mm.version.openmm_library_path}))


if __name__ == "__main__":
    main()

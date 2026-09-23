"""Split a work unit's start-state potential energy by force and compare platforms with Reference.

usage: python decompose.py <wu-dir> <platform>[:<precision>] ...
Puts each force in its own force group and NonbondedForce's reciprocal space in one more, then prints
one JSON line per platform with the energy of every group and its difference from Reference.
Metal gets mockcore's FAH property map with the given precision.
"""
import json
import sys
import time

import openmm as mm
import openmm.unit as u

import mockcore


def grouped_system(wu):
    system = mm.XmlSerializer.deserialize(wu.system_xml)
    names = {}
    for i, force in enumerate(system.getForces()):
        force.setForceGroup(i)
        names[i] = type(force).__name__
        if isinstance(force, mm.NonbondedForce):
            names[i] = "NonbondedForce direct"
            reciprocal = system.getNumForces()
            force.setReciprocalSpaceForceGroup(reciprocal)
            names[reciprocal] = "NonbondedForce reciprocal"
    return system, names


def group_energies(wu, system, names, platform, properties):
    integrator = mm.XmlSerializer.deserialize(wu.integrator_xml)
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName(platform), properties)
    context.setState(mm.XmlSerializer.deserialize(wu.state_xml))
    energies = {name: context.getState(getEnergy=True, groups={group}).getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
                for group, name in names.items()}
    energies["total"] = context.getState(getEnergy=True).getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
    return energies


def main():
    wu = mockcore.WorkUnit(sys.argv[1])
    system, names = grouped_system(wu)
    start = time.perf_counter()
    reference = group_energies(wu, system, names, "Reference", {})
    print(json.dumps({"platform": "Reference", "energy": reference, "wall_s": round(time.perf_counter() - start, 1)}), flush=True)
    for spec in sys.argv[2:]:
        platform, _, precision = spec.partition(":")
        properties = {}
        if platform == "Metal":
            properties = dict(mockcore.FAH_PROPERTIES, Precision=precision or "mixed")
        elif precision:
            properties = {"Precision": precision}
        start = time.perf_counter()
        energies = group_energies(wu, system, names, platform, properties)
        print(json.dumps({"platform": spec, "energy": energies,
                          "minus_reference": {name: energies[name] - reference[name] for name in energies},
                          "wall_s": round(time.perf_counter() - start, 1)}), flush=True)


if __name__ == "__main__":
    main()

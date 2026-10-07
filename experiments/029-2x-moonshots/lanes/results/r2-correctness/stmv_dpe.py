"""amber20-stmv potential energy by force group against Reference, as 020's decompose.py splits it.

usage: python stmv_dpe.py <amber20-suite-dir> reference <out.json>
       python stmv_dpe.py <amber20-suite-dir> <label> <reference.json> [Platform:precision ...]
The system is benchmark.py's (PME, 0.9 nm, HBonds) at the inpcrd positions. Each force is its own group and
NonbondedForce's reciprocal space one more. Prints one JSON line per platform with platform minus Reference.
"""
import json
import sys

import openmm as mm
import openmm.app as app
import openmm.unit as u


def system_and_positions(suite):
    prmtop = app.AmberPrmtopFile(f"{suite}/PME/Topologies/STMV.prmtop")
    inpcrd = app.AmberInpcrdFile(f"{suite}/PME/Coordinates/STMV.inpcrd")
    system = prmtop.createSystem(nonbondedMethod=app.PME, nonbondedCutoff=0.9 * u.nanometers, constraints=app.HBonds)
    system.setDefaultPeriodicBoxVectors(*inpcrd.boxVectors)
    names = {}
    for i, force in enumerate(system.getForces()):
        force.setForceGroup(i)
        names[i] = type(force).__name__
        if isinstance(force, mm.NonbondedForce):
            names[i] = "direct"
            force.setReciprocalSpaceForceGroup(system.getNumForces())
            names[system.getNumForces()] = "reciprocal"
    return system, inpcrd.positions, names


def energies(system, positions, names, platform, properties):
    context = mm.Context(system, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName(platform), properties)
    context.setPositions(positions)
    result = {name: context.getState(getEnergy=True, groups={group}).getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
              for group, name in names.items()}
    result["total"] = context.getState(getEnergy=True).getPotentialEnergy().value_in_unit(u.kilojoule_per_mole)
    return result


def main():
    suite, label = sys.argv[1], sys.argv[2]
    system, positions, names = system_and_positions(suite)
    if label == "reference":
        json.dump(energies(system, positions, names, "Reference", {}), open(sys.argv[3], "w"), indent=1)
        return
    reference = json.load(open(sys.argv[3]))
    for spec in sys.argv[4:]:
        platform, _, precision = spec.partition(":")
        e = energies(system, positions, names, platform, {"Precision": precision} if precision else {})
        print(json.dumps({"label": label, "platform": spec, "minus_reference": {k: round(e[k] - reference[k], 3) for k in e}}), flush=True)


if __name__ == "__main__":
    main()

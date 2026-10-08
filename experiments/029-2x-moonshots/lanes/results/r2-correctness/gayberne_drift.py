"""TestGayBerneForce testEnergyConservation over many seeds, platforms and settings.

usage: python gayberne_drift.py <seeds> <out.json> <config> ...
config is platform[:precision][,dt=..][,tol=..]. The system and protocol are the test's: 27 three-particle
ellipsoid molecules in a 3 nm box, cutoff 1.0 with switch 0.9, Verlet 0.0005 ps, 100 x 5 steps, and the test's
check |E - E0| <= 1e-4 * max(1, |E0|) against the energy after the first 5 steps. The test seeds nothing; here
setVelocitiesToTemperature gets seed 1..N, so every config sees the same starting velocities per seed.
Per config: failures, the worst relative error, and the mean of the fitted drift slope and of the RMS
fluctuation about it, both relative to |E0|, so drift and noise can be told apart. With a changed dt the step
count scales to keep 250 fs.
"""
import json
import math
import sys

import numpy as np
import openmm as mm


def build():
    system = mm.System()
    system.setDefaultPeriodicBoxVectors(mm.Vec3(3, 0, 0), mm.Vec3(0, 3, 0), mm.Vec3(0, 0, 3))
    gb = mm.GayBerneForce()
    system.addForce(gb)
    gb.setNonbondedMethod(mm.GayBerneForce.CutoffPeriodic)
    gb.setCutoffDistance(1.0)
    gb.setUseSwitchingFunction(True)
    gb.setSwitchingDistance(0.9)
    positions = []
    for x in range(3):
        for y in range(3):
            for z in range(3):
                first = system.getNumParticles()
                system.addParticle(10.0)
                system.addParticle(1.0)
                system.addParticle(1.0)
                gb.addParticle(0.2, 10.0, first+1, first+2, 0.2, 0.25, 0.3, 0.9, 1.0, 1.1)
                gb.addParticle(1.0, 0.0, -1, -1, 1, 1, 1, 1, 1, 1)
                gb.addParticle(1.0, 0.0, -1, -1, 1, 1, 1, 1, 1, 1)
                positions += [mm.Vec3(x, y, z), mm.Vec3(x+0.1, y, z), mm.Vec3(x, y+0.1, z)]
                system.addConstraint(first, first+1, 0.1)
                system.addConstraint(first, first+2, 0.1)
                system.addConstraint(first+1, first+2, 0.1*math.sqrt(2.0))
    return system, positions


def run(system, positions, config, seed):
    parts = config.split(",")
    platform, _, precision = parts[0].partition(":")
    options = dict(p.split("=") for p in parts[1:])
    dt = float(options.get("dt", 0.0005))
    stride = round(5*0.0005/dt)
    integrator = mm.VerletIntegrator(dt)
    if "tol" in options:
        integrator.setConstraintTolerance(float(options["tol"]))
    context = mm.Context(system, integrator, mm.Platform.getPlatformByName(platform), {"Precision": precision} if precision else {})
    context.setPositions(positions)
    context.setVelocitiesToTemperature(300.0, seed)
    energies = []
    for i in range(100):
        integrator.step(stride)
        state = context.getState(getEnergy=True)
        energies.append(state.getPotentialEnergy()._value + state.getKineticEnergy()._value)
    e = np.array(energies)
    scale = max(1.0, abs(e[0]))
    rel = np.abs(e[1:]-e[0])/scale
    time = np.arange(len(e))
    slope, intercept = np.polyfit(time, e, 1)
    return dict(worst=float(rel.max()), fail=bool(rel.max() > 1e-4), slope=float(slope*len(e)/scale),
                noise=float(np.std(e-(slope*time+intercept))/scale), e0=float(e[0]))


def main():
    seeds, out, configs = int(sys.argv[1]), sys.argv[2], sys.argv[3:]
    system, positions = build()
    results = {}
    for config in configs:
        runs = [run(system, positions, config, seed) for seed in range(1, seeds+1)]
        results[config] = dict(runs=runs, fails=sum(r["fail"] for r in runs), worst=max(r["worst"] for r in runs),
                               mean_drift=float(np.mean([r["slope"] for r in runs])),
                               mean_abs_drift=float(np.mean([abs(r["slope"]) for r in runs])),
                               mean_noise=float(np.mean([r["noise"] for r in runs])))
        r = results[config]
        print(f"{config:40s} fails {r['fails']:2d}/{seeds}  worst {r['worst']:.2e}  drift/250fs mean {r['mean_drift']:+.2e} |{r['mean_abs_drift']:.2e}|  noise {r['mean_noise']:.2e}", flush=True)
    json.dump(results, open(out, "w"), indent=1)


if __name__ == "__main__":
    main()

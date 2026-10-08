"""Seeded replicas of the stochastic tests that flaked in tonight's -j2 gates, one JSON line per run.

usage: python probe.py <mode> <platform> <precision> <seed> [<seed> ...]
modes:
  gas0, gas1   TestMonteCarloAnisotropicBarostat testMolecularGas(rigid=0/1): mean pressure per axis, bar
  init         TestCustomIntegrator testInitialTemperature: temperature read back after setVelocitiesToTemperature
  drude        TestDrudeSCFIntegrator testInitialTemperature(1): pair center-of-mass temperature read back the same way
The upstream tests draw their seeds from /dev/urandom; here the integrator, barostat and velocity seeds are fixed,
so one seed on two platforms, or on one platform alone and beside a second process, can be compared run for run.
"""
import json
import sys
import time

import numpy as np
import openmm as mm

BOLTZ = 0.00831446261815324  # kJ/mol/K, OpenMM's BOLTZ
AVOGADRO = 6.02214076e23


def platform_args(name, precision):
    platform = mm.Platform.getPlatformByName(name)
    props = {"Precision": precision} if name in ("Metal", "OpenCL", "CUDA") else {}
    return platform, props


def gas(platform, props, seed, rigid):
    molecules, frequency, steps, pressure, temp = 256, 5, 5000, 3.0, 300.0
    length = (molecules*BOLTZ*temp/(pressure*AVOGADRO*1e-25))**(1/3)
    system = mm.System()
    system.setDefaultPeriodicBoxVectors(mm.Vec3(length, 0, 0), mm.Vec3(0, 0.5*length, 0), mm.Vec3(0, 0, 2*length))
    barostat = mm.MonteCarloAnisotropicBarostat(mm.Vec3(pressure, pressure, pressure), temp, True, True, True, frequency, rigid)
    barostat.setRandomNumberSeed(seed)
    system.addForce(barostat)
    bonds = mm.HarmonicBondForce()
    bonds.setUsesPeriodicBoundaryConditions(True)
    system.addForce(bonds)
    rng = np.random.default_rng(seed)
    positions = []
    for _ in range(molecules):
        pos = mm.Vec3(*(rng.random(3)*[length, 0.5*length, 2*length]))
        for offset in (mm.Vec3(0, 0, 0), mm.Vec3(0.1, 0, 0), mm.Vec3(0, 0.1, 0)):
            system.addParticle(1.0)
        n = len(positions)
        bonds.addBond(n, n+1, 0.1, 1.0)
        bonds.addBond(n, n+2, 0.1, 1.0)
        positions += [pos, pos+mm.Vec3(0.1, 0, 0), pos+mm.Vec3(0, 0.1, 0)]
    integrator = mm.LangevinIntegrator(temp, 0.1, 0.005)
    integrator.setRandomNumberSeed(seed)
    context = mm.Context(system, integrator, platform, props)
    context.setPositions(positions)
    integrator.step(5000)
    total = np.zeros(3)
    for _ in range(steps):
        integrator.step(frequency)
        p = barostat.computeCurrentPressure(context)
        total += [p[0].value_in_unit(mm.unit.bar), p[1].value_in_unit(mm.unit.bar), p[2].value_in_unit(mm.unit.bar)]
    box = context.getState().getPeriodicBoxVectors(asNumpy=True).value_in_unit(mm.unit.nanometer)
    return {"pressure": list(total/steps), "box": [box[0][0], box[1][1], box[2][2]]}


def init(platform, props, seed):
    particles, target = 50000, 300.0
    system = mm.System()
    for _ in range(particles):
        system.addParticle(1.0)
    integrator = mm.CustomIntegrator(0.001)
    context = mm.Context(system, integrator, platform, props)
    context.setPositions(np.random.default_rng(seed).random((particles, 3)))
    context.setVelocitiesToTemperature(target, seed)
    v = context.getState(getVelocities=True).getVelocities(asNumpy=True).value_in_unit(mm.unit.nanometer/mm.unit.picosecond)
    return {"temperature": float((v*v).sum()/(3*particles*BOLTZ)), "vsum": float(np.abs(v).sum())}


def drude(platform, props, seed):
    pairs, target, real_mass, drude_mass = 50000, 300.0, 10.0, 1.0
    system = mm.System()
    force = mm.DrudeForce()
    rng = np.random.default_rng(seed)
    positions = np.zeros((2*pairs, 3))
    for i in range(pairs):
        system.addParticle(real_mass)
        system.addParticle(drude_mass)
        positions[2*i] = rng.random(3)
        positions[2*i+1] = positions[2*i] + 0.01*rng.random(3)
        force.addParticle(2*i+1, 2*i, -1, -1, -1, -1.0, 0.001, 1, 1)
    system.addForce(force)
    integrator = mm.DrudeSCFIntegrator(0.001)
    context = mm.Context(system, integrator, platform, props)
    context.setPositions(positions)
    context.setVelocitiesToTemperature(target, seed)
    v = context.getState(getVelocities=True).getVelocities(asNumpy=True).value_in_unit(mm.unit.nanometer/mm.unit.picosecond)
    com = (real_mass*v[0::2] + drude_mass*v[1::2])/(real_mass + drude_mass)
    return {"temperature": float((real_mass + drude_mass)*(com*com).sum()/(3*pairs*BOLTZ)), "vsum": float(np.abs(v).sum())}


def main():
    mode, name, precision, seeds = sys.argv[1], sys.argv[2], sys.argv[3], [int(s) for s in sys.argv[4:]]
    platform, props = platform_args(name, precision)
    for seed in seeds:
        start = time.time()
        if mode in ("gas0", "gas1"):
            result = gas(platform, props, seed, mode == "gas1")
        elif mode == "init":
            result = init(platform, props, seed)
        elif mode == "drude":
            result = drude(platform, props, seed)
        else:
            sys.exit(__doc__)
        result.update(mode=mode, platform=name, precision=precision, seed=seed, seconds=round(time.time() - start, 1))
        print(json.dumps(result), flush=True)


main()

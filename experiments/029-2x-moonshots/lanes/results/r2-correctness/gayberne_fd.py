"""Finite-difference check of GayBerneForce forces against its energy on the Reference platform.

usage: python gayberne_fd.py <seed> [platform[:precision]]
Runs the energy-conservation test system (seeded velocities) and every 50 steps compares, for each particle,
the analytic force with -dE/dx from central differences (h = 1e-5 nm, Reference in double). Prints the worst
relative mismatch per check and which particles carry it. Also compares the power F.v with -dE/dt.
"""
import sys

import numpy as np
import openmm as mm

import gayberne_drift as g

seed = int(sys.argv[1])
platform = sys.argv[2] if len(sys.argv) > 2 else "Reference"
system, positions = g.build()
integrator = mm.VerletIntegrator(0.0005)
context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Reference"))
context.setPositions(positions)
context.setVelocitiesToTemperature(300.0, seed)
probe = mm.Context(system, mm.VerletIntegrator(0.0005), mm.Platform.getPlatformByName("Reference"))
h = 1e-5
for block in range(10):
    integrator.step(50)
    state = context.getState(getPositions=True, getForces=True, getVelocities=True, getEnergy=True)
    x = state.getPositions(asNumpy=True)._value
    f = state.getForces(asNumpy=True)._value
    v = state.getVelocities(asNumpy=True)._value
    fd = np.zeros_like(f)
    for i in range(len(x)):
        for k in range(3):
            e = []
            for sgn in (1, -1):
                y = x.copy()
                y[i, k] += sgn*h
                probe.setPositions(y)
                e.append(probe.getState(getEnergy=True).getPotentialEnergy()._value)
            fd[i, k] = -(e[0]-e[1])/(2*h)
    err = np.linalg.norm(f-fd, axis=1)
    worst = np.argsort(-err)[:3]
    power = (f*v).sum()
    powerfd = (fd*v).sum()
    print(f"step {50*(block+1)} PE {state.getPotentialEnergy()._value:.4f} max|F-Ffd| {err.max():.3e} at {[(int(w), w % 3, round(float(err[w]), 4), round(float(np.linalg.norm(f[w])), 2)) for w in worst]} "
          f"power F.v {power:.4f} FD {powerfd:.4f}", flush=True)

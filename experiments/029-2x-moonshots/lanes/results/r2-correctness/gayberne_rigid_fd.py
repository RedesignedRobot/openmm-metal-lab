"""Rigid-body finite-difference check of GayBerneForce on Reference: net force and torque of each molecule
against -dE/d(translation) and -dE/d(rotation about the center particle).

usage: python gayberne_rigid_fd.py <seed> <steps>
Only rigid motions matter under the test's constraints, so this splits the force/energy mismatch into its
translational and rotational parts.
"""
import sys

import numpy as np
import openmm as mm

import gayberne_drift as g


def rotation(axis, angle):
    k = np.zeros(3); k[axis] = 1
    K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    return np.eye(3) + np.sin(angle)*K + (1-np.cos(angle))*K@K


seed, steps = int(sys.argv[1]), int(sys.argv[2])
system, positions = g.build()
integrator = mm.VerletIntegrator(0.0005)
context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Reference"))
context.setPositions(positions)
context.setVelocitiesToTemperature(300.0, seed)
integrator.step(steps)
state = context.getState(getPositions=True, getForces=True)
x = state.getPositions(asNumpy=True)._value
f = state.getForces(asNumpy=True)._value
probe = mm.Context(system, mm.VerletIntegrator(0.0005), mm.Platform.getPlatformByName("Reference"))


def energy(y):
    probe.setPositions(y)
    return probe.getState(getEnergy=True).getPotentialEnergy()._value


h = 1e-6
rows = []
for m in range(27):
    atoms = [3*m, 3*m+1, 3*m+2]
    net = f[atoms].sum(axis=0)
    torque = sum(np.cross(x[a]-x[3*m], f[a]) for a in atoms)
    fd_net, fd_torque = np.zeros(3), np.zeros(3)
    for k in range(3):
        e = []
        for sgn in (1, -1):
            y = x.copy(); y[atoms, k] += sgn*h
            e.append(energy(y))
        fd_net[k] = -(e[0]-e[1])/(2*h)
        e = []
        for sgn in (1, -1):
            y = x.copy(); R = rotation(k, sgn*h)
            y[atoms] = x[3*m] + (x[atoms]-x[3*m])@R.T
            e.append(energy(y))
        fd_torque[k] = -(e[0]-e[1])/(2*h)
    rows.append((m, np.linalg.norm(net-fd_net), np.linalg.norm(net), np.linalg.norm(torque-fd_torque), np.linalg.norm(torque)))
rows.sort(key=lambda r: -max(r[1], r[3]))
print("molecule |dF| |F| |dtorque| |torque|")
for r in rows[:6]:
    print("%2d %.3e %.3e %.3e %.3e" % r)

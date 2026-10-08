"""Check each analytic orientation derivative in ReferenceGayBerneForce::computeOneInteraction by finite
differences. A numpy port of the energy E = u*eta*chi and of dudq, detadq and dchidq for one pair of the test's
ellipsoids at random orientations; each is compared with d/dtheta of its factor for small rotations of particle 1.
"""
import numpy as np

rng = np.random.default_rng(5)
r = np.array([0.1, 0.125, 0.15])          # half of the test's 0.2, 0.25, 0.3
e = np.array([0.9, 1.0, 1.1])
sigma, epsilon = 0.2, 10.0
s = (r[0]*r[1] + r[2]*r[2])*np.sqrt(r[0]*r[1])


def rot(axis, angle):
    k = np.zeros(3); k[axis] = 1
    K = np.array([[0, -k[2], k[1]], [k[2], 0, -k[0]], [-k[1], k[0], 0]])
    return np.eye(3) + np.sin(angle)*K + (1-np.cos(angle))*K@K


def random_frame():
    q, _ = np.linalg.qr(rng.normal(size=(3, 3)))
    return q if np.linalg.det(q) > 0 else -q


def mats(A):
    B = A.T @ np.diag(1/np.sqrt(e)) @ A
    G = A.T @ np.diag(r*r) @ A
    return B, G


def factors(A1, A2, dr):
    B1, G1 = mats(A1); B2, G2 = mats(A2)
    B12, G12 = B1+B2, G1+G2
    rr = np.linalg.norm(dr); du = dr/rr
    sigma12 = 1/np.sqrt(0.5*du @ np.linalg.inv(G12) @ du)
    rho = sigma/(rr - sigma12 + sigma)
    rho6 = rho**6
    u = 4*epsilon*(rho6*rho6 - rho6)
    eta = np.sqrt(2*s*s/np.linalg.det(G12))
    chi = (2*du @ np.linalg.inv(B12) @ du)**2
    return u, eta, chi


def analytic(A1, A2, dr):
    """dudq, detadq, dchidq for particle 1, transcribed from computeOneInteraction."""
    B1, G1 = mats(A1); B2, G2 = mats(A2)
    B12, G12 = B1+B2, G1+G2
    rr = np.linalg.norm(dr); du = dr/rr; rInv2 = 1/rr**2
    G12inv, B12inv = np.linalg.inv(G12), np.linalg.inv(B12)
    detG12 = np.linalg.det(G12)
    sigma12 = 1/np.sqrt(0.5*du @ G12inv @ du)
    rho = sigma/(rr - sigma12 + sigma); rho6 = rho**6
    eta = np.sqrt(2*s*s/detG12)
    kappa, iota = G12inv @ dr, B12inv @ dr
    dUSLJdr = 24*epsilon*(2*rho6-1)*rho6*rho/sigma
    temp = 0.5*sigma12**3*rInv2
    chi = (2*du @ B12inv @ du)**2
    dudq = np.cross(kappa @ G1, kappa*(temp*dUSLJdr))          # Vec3*Matrix is a row vector times the matrix
    dchidq = np.cross(iota @ B1, iota)*(-4*rInv2)*(FIX*2*np.sqrt(chi) + (1-FIX))
    g, a = G12, A1
    sc = r*r*(-0.5*eta/detG12)
    d = np.zeros((3, 3))
    for i in range(3):
        d[i, 0] = sc[i]*(2*a[i, 0]*(g[1, 1]*g[2, 2] - g[1, 2]*g[2, 1]) +
                         a[i, 1]*(g[0, 2]*g[2, 1] + g[2, 0]*g[1, 2] - g[2, 2]*(g[0, 1] + g[1, 0])) +
                         a[i, 2]*(g[1, 2]*g[0, 1] + g[1, 0]*g[2, 1] - g[1, 1]*(g[0, 2] + g[2, 0])))
        d[i, 1] = sc[i]*(a[i, 0]*(g[0, 2]*g[2, 1] + g[2, 0]*g[1, 2] - g[2, 2]*(g[0, 1] + g[1, 0])) +
                         2*a[i, 1]*(g[0, 0]*g[2, 2] - g[2, 0]*g[0, 2]) +
                         a[i, 2]*(g[1, 0]*g[0, 2] + g[2, 0]*g[0, 1] - g[0, 0]*(g[1, 2] + g[2, 1])))
        d[i, 2] = sc[i]*(a[i, 0]*(g[0, 1]*g[1, 2] + g[1, 0]*g[2, 1] - g[1, 1]*(g[0, 2] + g[2, 0])) +
                         a[i, 1]*(g[1, 0]*g[0, 2] + g[2, 0]*g[0, 1] - g[0, 0]*(g[1, 2] + g[2, 1])) +
                         2*a[i, 2]*(g[1, 1]*g[0, 0] - g[1, 0]*g[0, 1]))
    detadq = sum(np.cross(a[i], d[i]) for i in range(3))
    return dudq, detadq, dchidq, chi, eta


import sys
FIX = int(sys.argv[1]) if len(sys.argv) > 1 else 0
h = 1e-6
worst = np.zeros(3)
for trial in range(5):
    A1, A2 = random_frame(), random_frame()
    dr = rng.normal(size=3); dr *= (0.35 + 0.3*rng.random())/np.linalg.norm(dr)
    dudq, detadq, dchidq, chi, eta = analytic(A1, A2, dr)
    fd = np.zeros((3, 3))
    for k in range(3):
        plus = factors(A1 @ rot(k, h).T, A2, dr)
        minus = factors(A1 @ rot(k, -h).T, A2, dr)
        fd[:, k] = (np.array(plus) - np.array(minus))/(2*h)
    print(f"trial {trial} |dr| {np.linalg.norm(dr):.3f}")
    for name, an, num in (("du/dq", dudq, fd[0]), ("deta/dq", detadq, fd[1]), ("dchi/dq", dchidq, fd[2])):
        print(f"  {name:8s} analytic {np.array2string(an, precision=5)}  fd {np.array2string(num, precision=5)}")

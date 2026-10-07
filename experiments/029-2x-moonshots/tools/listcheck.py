"""Neighbor-list coverage check: after MD steps, is every atom pair within the cutoff computed exactly once?

Runs benchmark.py's LangevinMiddleIntegrator (4 fs, 300 K, seed 2026, as forces.py --md) on each test and
precision. At each step count in --steps (cumulative, default 100 and 1000) it evaluates forces, which
leaves the list the kernel used at those exact positions on the GPU, and hands the Context to
liblistcheck.dylib (listcheck.cpp). The helper reads the exclusion tiles, neighbor tiles and single pairs
and checks them against a double-precision CPU cell list of every non-excluded pair within the
NonbondedForce cutoff. Charges play no part. A row passes when no pair is uncovered or duplicate, every
excluded pair sits in an exclusion tile only, and no list count overflowed. Failing rows list up to
--report pairs by System atom index. Exit code 1 if any row fails. --drop-tile K is the negative
control: the helper blanks neighbor tile K of its copy of the list, so the row must FAIL with uncovered pairs.
Run from listcheck.sh, which builds the helper for the tree and holds the lease.
usage: python listcheck.py --lib <liblistcheck.dylib> [--steps 100,1000] [--precision single,mixed]
                           [--drop-tile K] <benchmarks dir> [tests...]
"""
import argparse
import ctypes
import os
import sys
import time

import numpy as np
import openmm as mm
import openmm.unit as u

TESTS = ["pme", "apoa1pme", "amber20-stmv"]
SEED = 2026
KINDS = {1: "uncovered", 2: "duplicate", 3: "excluded"}
STATS = ["pairs", "uncovered", "duplicate", "excluded", "tiles", "single", "excltiles", "overflow"]

parser = argparse.ArgumentParser()
parser.add_argument("--lib", required=True)
parser.add_argument("--steps", default="100,1000")
parser.add_argument("--precision", default="single,mixed")
parser.add_argument("--report", type=int, default=20)
parser.add_argument("--drop-tile", type=int, default=-1)
parser.add_argument("bench")
parser.add_argument("tests", nargs="*", default=TESTS)
args = parser.parse_args()
steps = [int(s) for s in args.steps.split(",")]

helper = ctypes.CDLL(os.path.abspath(args.lib))
helper.listcheck.restype = ctypes.c_int
helper.listcheck.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_double, ctypes.c_void_p,
                             ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                             ctypes.c_char_p, ctypes.c_int]
os.chdir(args.bench)
# benchmark.py runs its benchmarks on import, so load only the definitions before serializeTest().
source = open("benchmark.py").read()
exec(source[:source.index("def serializeTest")])


def nonbonded(system):
    forces = [f for f in system.getForces() if isinstance(f, mm.NonbondedForce)]
    if len(forces) != 1:
        sys.exit(f"expected one NonbondedForce, found {len(forces)}")
    force = forces[0]
    pairs = np.array([force.getExceptionParameters(k)[:2] for k in range(force.getNumExceptions())], dtype=np.int32)
    return force.getCutoffDistance().value_in_unit(u.nanometer), pairs.reshape(-1, 2)


def check(context, cutoff, exclusions):
    state = context.getState(getForces=True, getPositions=True)
    positions = np.ascontiguousarray(state.getPositions(asNumpy=True).value_in_unit(u.nanometer), dtype=np.float64)
    vectors = state.getPeriodicBoxVectors(asNumpy=True).value_in_unit(u.nanometer)
    if np.count_nonzero(vectors - np.diag(np.diag(vectors))):
        sys.exit("triclinic boxes are not supported")
    box = np.ascontiguousarray(np.diag(vectors), dtype=np.float64)
    stats = np.zeros(len(STATS), dtype=np.int64)
    report = np.zeros((args.report, 3), dtype=np.int32)
    distance = np.zeros(args.report, dtype=np.float64)
    error = ctypes.create_string_buffer(1000)
    rows = helper.listcheck(int(context.this), positions.ctypes.data, box.ctypes.data, cutoff, exclusions.ctypes.data,
                            len(exclusions), args.drop_tile, args.report, stats.ctypes.data, report.ctypes.data, distance.ctypes.data,
                            error, len(error))
    if rows < 0:
        sys.exit(error.value.decode())
    return dict(zip(STATS, stats.tolist())), [(*report[k], distance[k]) for k in range(rows)]


failed = False
print(f"{'test':14} {'atoms':>8} {'precision':>9} {'steps':>5} {'pairs':>11} {'tiles':>9} {'single':>8} "
      f"{'excltiles':>9} {'uncovered':>9} {'duplicate':>9} {'excluded':>8} {'overflow':>8}  verdict", flush=True)
for test in args.tests:
    system, positions, _ = retrieveTestSystem(test)
    cutoff, exclusions = nonbonded(system)
    for precision in args.precision.split(","):
        integrator = mm.LangevinMiddleIntegrator(300*u.kelvin, 1/u.picosecond, 0.004*u.picoseconds)
        integrator.setRandomNumberSeed(SEED)
        context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), {"Precision": precision})
        context.setPositions(positions)
        context.setVelocitiesToTemperature(300*u.kelvin, SEED)
        done = 0
        for target in steps:
            integrator.step(target - done)
            done = target
            start = time.time()
            stats, pairs = check(context, cutoff, exclusions)
            bad = stats["uncovered"] + stats["duplicate"] + stats["excluded"] + stats["overflow"]
            if stats["tiles"] + stats["single"] == 0:
                bad += 1
            failed |= bad > 0
            print(f"{test:14} {system.getNumParticles():8} {precision:>9} {target:5} {stats['pairs']:11} "
                  f"{stats['tiles']:9} {stats['single']:8} {stats['excltiles']:9} {stats['uncovered']:9} "
                  f"{stats['duplicate']:9} {stats['excluded']:8} {stats['overflow']:8}  "
                  f"{'FAIL' if bad else 'PASS'}  ({time.time() - start:.0f} s check)", flush=True)
            if stats["tiles"] + stats["single"] == 0:
                print("    no neighbor list: the kernel ran without one", flush=True)
            for i, j, kind, r in pairs:
                print(f"    {KINDS[kind]} {i} {j} r={r:.4f} nm", flush=True)
        del context, integrator
sys.exit(1 if failed else 0)

"""Capture benchmark lists at exact force coordinates using a read-only C++ bridge."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path

import numpy as np
import openmm as mm
import openmm.unit as u


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lib", type=Path, required=True)
    parser.add_argument("--bench", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--built", type=Path, required=True)
    parser.add_argument("--precision", default="single")
    parser.add_argument("--steps", default="0,100")
    parser.add_argument("tests", nargs="+")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    helper = ctypes.CDLL(str(args.lib.resolve()))
    helper.snapshot.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
    helper.snapshot.restype = ctypes.c_int
    built = args.built.read_text()
    os.chdir(args.bench)
    source = Path("benchmark.py").read_text()
    namespace = {}
    exec(source[:source.index("def serializeTest")], namespace)
    for test in args.tests:
        system, positions, _ = namespace["retrieveTestSystem"](test)
        nonbonded = [f for f in system.getForces() if isinstance(f, mm.NonbondedForce)]
        if len(nonbonded) != 1:
            raise ValueError("expected one NonbondedForce")
        cutoff = nonbonded[0].getCutoffDistance().value_in_unit(u.nanometer)
        for precision in args.precision.split(","):
            integrator = mm.LangevinMiddleIntegrator(300*u.kelvin, 1/u.picosecond, 0.004*u.picoseconds)
            integrator.setRandomNumberSeed(2026)
            context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"), {"Precision": precision})
            context.setPositions(positions)
            context.setVelocitiesToTemperature(300*u.kelvin, 2026)
            done = 0
            for step in map(int, args.steps.split(",")):
                if step < done:
                    raise ValueError("steps must increase")
                integrator.step(step-done)
                done = step
                context.getState(getForces=True)
                prefix = out / f"{test}-{precision}-{step}"
                error = ctypes.create_string_buffer(2048)
                if helper.snapshot(int(context.this), os.fsencode(prefix), error, len(error)):
                    raise RuntimeError(error.value.decode())
                arrays = {}
                for name, dtype, shape in [("posq", "<f4", (-1, 4)), ("tiles", "<i4", (-1,)),
                        ("atoms", "<i4", (-1, 32)), ("singles", "<i4", (-1, 2)),
                        ("exclusions", "<i4", (-1, 2)), ("order", "<i4", (-1,)), ("box", "<f8", (3, 3))]:
                    arrays[name] = np.fromfile(str(prefix)+"."+name, dtype=dtype).reshape(shape)
                metadata = dict(test=test, precision=precision, step=step, seed=2026,
                                num_atoms=system.getNumParticles(), cutoff=cutoff,
                                padded_cutoff=1.08*cutoff, periodic=nonbonded[0].usesPeriodicBoundaryConditions(),
                                padding_source="MetalNonbondedUtilities::padCutoff on 0b7a7b340: 0.08*cutoff",
                                built=built, benchmark_sha256=hashlib.sha256(source.encode()).hexdigest())
                np.savez_compressed(str(prefix)+".npz", metadata=json.dumps(metadata), **arrays)
                for name in arrays:
                    Path(str(prefix)+"."+name).unlink()
                print(json.dumps(dict(snapshot=prefix.name, tiles=len(arrays["tiles"]),
                                      singles=len(arrays["singles"]), exclusions=len(arrays["exclusions"]))), flush=True)
            del context, integrator


if __name__ == "__main__":
    main()

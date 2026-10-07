"""Compare and capture isolated direct-force dispatches on the same live snapshot."""
import argparse
import ctypes as ct
import json
import hashlib
import os
from pathlib import Path
import tempfile
import time
import numpy as np
import openmm as mm
import openmm.unit as u
from emit import emit

p = argparse.ArgumentParser()
p.add_argument("--tree", type=Path, required=True)
p.add_argument("--bench", type=Path, required=True)
p.add_argument("--test", default="apoa1rf")
p.add_argument("--precision", default="single")
p.add_argument("--capture", choices=["control", "compact"])
p.add_argument("--seconds", type=int, default=90)
a = p.parse_args()
os.chdir(a.bench)
src = Path("benchmark.py").read_text()
ns = {}
exec(src[:src.index("def serializeTest")], ns)
system, positions, _ = ns["retrieveTestSystem"](a.test)
nb = next(f for f in system.getForces() if isinstance(f, mm.NonbondedForce))
integrator = mm.LangevinMiddleIntegrator(300*u.kelvin, 1/u.picosecond, .004*u.picoseconds)
integrator.setRandomNumberSeed(2026)
context = mm.Context(system, integrator, mm.Platform.getPlatformByName("Metal"),
                     {"Precision": a.precision, "DeterministicForces": "true"})
context.setPositions(positions)
context.getState(getForces=True)
lib = ct.CDLL(str(a.tree/"libreplay.dylib"))
lib.snapshot.argtypes = [ct.c_void_p, ct.c_char_p, ct.c_char_p, ct.c_int]
lib.replayCreate.argtypes = [ct.c_void_p, ct.c_int, ct.c_void_p, ct.c_void_p, ct.c_void_p, ct.c_char_p, ct.c_int]
lib.replayCreate.restype = ct.c_void_p
lib.replayRun.argtypes = [ct.c_void_p, ct.c_int, ct.c_int, ct.c_void_p, ct.c_char_p, ct.c_int]
lib.replayDestroy.argtypes = [ct.c_void_p]
err = ct.create_string_buffer(32768)
with tempfile.TemporaryDirectory(prefix="nb16-replay-") as tmp:
    prefix = Path(tmp)/"live"
    if lib.snapshot(int(context.this), os.fsencode(prefix), err, len(err)):
        raise RuntimeError(err.value.decode())
    data = {}
    for name, dtype, shape in [("posq", "<f4", (-1,4)), ("tiles", "<i4", (-1,)),
            ("atoms", "<i4", (-1,32)), ("singles", "<i4", (-1,2)), ("box", "<f8", (3,3))]:
        data[name] = np.fromfile(str(prefix)+"."+name, dtype=dtype).reshape(shape)
    cutoff = nb.getCutoffDistance().value_in_unit(u.nanometer)
    data["metadata"] = json.dumps(dict(num_atoms=system.getNumParticles(), cutoff=cutoff,
        padded_cutoff=1.08*cutoff, periodic=nb.usesPeriodicBoundaryConditions()))
    packed = emit(data)
    tiles, atoms, counts = (packed[k] for k in ("tiles", "atoms", "counts"))
    print(json.dumps(dict(test=a.test, precision=a.precision, old_tiles=len(data["tiles"]),
                         packets=len(tiles), q=len(tiles)/(2*len(data["tiles"])),
                         max_row_slots=int(np.bincount(tiles).max()*32),
                         positions_sha256=hashlib.sha256(data["posq"].tobytes()).hexdigest(),
                         compact_sha256=hashlib.sha256(tiles.tobytes()+atoms.tobytes()).hexdigest())), flush=True)
    handle = lib.replayCreate(int(context.this), len(tiles), tiles.ctypes.data, atoms.ctypes.data,
                              counts.ctypes.data, err, len(err))
    if not handle: raise RuntimeError(err.value.decode())
    output = np.empty(3*len(data["posq"]), dtype=np.int64)
    def run(compact, repeat=1):
        if lib.replayRun(handle, compact, repeat, output.ctypes.data, err, len(err)):
            raise RuntimeError(err.value.decode())
        return output.copy()
    try:
        if a.capture:
            # Timing holds replay only the selected path. Correctness has its own lease.
            compact = int(a.capture == "compact")
            run(compact)
            print("READY "+str(os.getpid()), flush=True)
            stop = time.monotonic()+a.seconds
            while time.monotonic() < stop:
                run(compact, 32)
        else:
            reference = run(0)
            candidate = run(1)
            again = run(1)
            delta = (candidate.astype(float)-reference.astype(float))/2**32
            ref = reference.astype(float)/2**32
            rms_relative = np.linalg.norm(delta)/np.linalg.norm(ref)
            result = dict(rms_relative=rms_relative, max_absolute=float(abs(delta).max()),
                          bitwise_repeat=bool(np.array_equal(candidate, again)))
            print(json.dumps(result), flush=True)
            if rms_relative > 1e-5 or not result["bitwise_repeat"]:
                raise RuntimeError("compact force comparison failed")
    finally:
        lib.replayDestroy(handle)

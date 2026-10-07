# CPU-only check of forces-straddle.py's straddling(): no Context, no GPU.
import numpy as np
import openmm as mm
import openmm.unit as u

src = open("/tmp/openmm-metal-bench/ultra-nblist/forces-straddle.py").read()
ns = {"np": np, "mm": mm, "u": u}
exec(src[src.index("STRADDLE_CANDIDATES ="):src.index("SEED =")], ns)
exec(src[src.index("def straddling"):src.index("def verdict")], ns)

def system(method):
    s = mm.System()
    s.setDefaultPeriodicBoxVectors(mm.Vec3(6, 0, 0), mm.Vec3(0, 6, 0), mm.Vec3(0, 0, 6))
    f = mm.NonbondedForce()
    f.setNonbondedMethod(method)
    f.setCutoffDistance(1.0)
    for _ in range(4):
        s.addParticle(16.0)
        f.addParticle(0.5, 0.3, 0.5)
    f.addException(2, 3, 0, 1, 0)
    s.addForce(f)
    return s

# 0-1 straddle by 1e-7 across the periodic boundary; 2-3 straddle but are an exception; 2 is far from 0 and 1.
pos = np.array([[0.2, 3, 3], [5.2 - 1e-7, 3, 3], [3, 0.5, 0.5], [3, 1.5 + 1e-7, 0.5]])
err = np.ones((4, 3))
print("periodic", ns["straddling"](system(mm.NonbondedForce.CutoffPeriodic), pos, err), "expect [0, 1]")
print("nonperiodic", ns["straddling"](system(mm.NonbondedForce.CutoffNonPeriodic), pos, err), "expect []")
pos[1, 0] = 5.2 - 1e-5
print("outside band", ns["straddling"](system(mm.NonbondedForce.CutoffPeriodic), pos, err), "expect []")
print("nocutoff", ns["straddling"](system(mm.NonbondedForce.NoCutoff), pos, err), "expect []")

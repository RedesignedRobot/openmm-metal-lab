# CPU only: python start to imports done, then retrieveTestSystem per test. No Context, no GPU.
import time, sys
t0 = time.time()
import openmm
t1 = time.time()
src = open("benchmark.py").read()
g = {"__name__": "systime"}
exec(src[:src.index("def serializeTest")], g)
t2 = time.time()
print(f"import openmm {t1 - t0:.2f} s, benchmark.py imports and defs {t2 - t1:.2f} s")
for test in sys.argv[1:]:
    s = time.time()
    g["retrieveTestSystem"](test)
    print(f"{test:22} retrieveTestSystem {time.time() - s:.2f} s")

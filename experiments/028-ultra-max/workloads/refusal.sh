#!/bin/sh
# Records OpenCL's refusal of mixed precision on the M3 Ultra, from the API and from benchmark.py.
cd /tmp/openmm-metal-bench/ultra-base/benchmarks
/tmp/openmm-metal-bench/ultra-base/venv/bin/python -c "
import openmm as mm
s = mm.System(); s.addParticle(1.0)
for prec in ('mixed', 'double'):
    try:
        mm.Context(s, mm.VerletIntegrator(0.001), mm.Platform.getPlatformByName('OpenCL'), {'Precision': prec})
        print(prec, 'created')
    except Exception as e:
        print(prec, type(e).__name__, repr(str(e)))
"
echo "--- benchmark.py --platform OpenCL --precision mixed --test pme"
/tmp/openmm-metal-bench/ultra-base/venv/bin/python benchmark.py --platform OpenCL --precision mixed --test pme --seconds 5 --style table
echo "exit $?"

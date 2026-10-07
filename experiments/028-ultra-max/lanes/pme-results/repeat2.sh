#!/bin/sh
# usage: repeat2.sh   One --correctness hold. Repeatability of cand2 (17929e631), whose Apple9 default spreads PME
# charges with float atomics, so forces depend on the order the atomics land. forces.py three times in fresh processes
# with the default (DeterministicForces off), then once with DeterministicForces=true (fixed point, as base), then a
# table of rel|dF| and max|dF| per row across the four runs.
L=/tmp/openmm-metal-bench/ultra-pme
T=/tmp/openmm-metal-bench/ultra-tools
B=/tmp/openmm-metal-bench/ultra-base/benchmarks
grep -q 17929e631 $L/cand2/BUILT || { echo "cand2 is not built at 17929e631"; exit 1; }
for i in 1 2 3; do
    /bin/sh $L/env.sh $L/cand2 $T/forces.py $B $L/rep2-float$i.txt 2>/dev/null || { echo "run $i failed"; exit 1; }
done
env EXTRA_PROPS=DeterministicForces=true /bin/sh $L/env.sh $L/cand2 $L/bprops.py $T/forces.py $B $L/rep2-det.txt 2>/dev/null || { echo "det run failed"; exit 1; }
/tmp/openmm-metal-bench/env/bin/python - <<'PY'
L = '/tmp/openmm-metal-bench/ultra-pme'
runs = ['float1', 'float2', 'float3', 'det']
rows = {}
for r in runs:
    for line in open(f'{L}/rep2-{r}.txt'):
        f = line.split()
        if len(f) >= 6 and f[2] in ('single', 'mixed'):
            rows.setdefault((f[0], f[2]), {})[r] = (float(f[3]), float(f[4]))
print('test precision  rel|dF| float1 float2 float3 det  max|dF| float1 float2 float3 det')
for (t, p), v in rows.items():
    print(t, p, ' '.join('%.4e' % v[r][0] for r in runs), ' ', ' '.join('%.4e' % v[r][1] for r in runs))
PY
echo "done $(date -u +%H:%M:%SZ)"

#!/bin/sh
# Probe tree g (f6e911929, irl-dt3 + env overrides), host clock. Screen 1, list search shape: NUM_TILES_IN_BATCH
# 4 (default) vs 1 vs 2, threadgroup 32 (default) vs 64 vs 128. Padding is parked (head, 16:1xZ).
# of the cutoff. apoa1rf and pme, single then mixed. Waits for screen.sh (pid 56071) to free its ticket slot
# and for the g build to finish.
set -u
cd /tmp/openmm-metal-bench
while kill -0 56071 2>/dev/null; do sleep 20; done
until grep -q f6e911929 ultra-r2-accum-nb-g/BUILT 2>/dev/null; do sleep 20; done
O=/tmp/openmm-metal-bench/ultra-r2-accum-nb/tib
G=/tmp/openmm-metal-bench/ultra-r2-accum-nb-g/venv/bin/python
mkdir -p $O
for row in apoa1rf:single pme:single apoa1rf:mixed pme:mixed; do
    t=${row%:*}; pr=${row#*:}
    ./ultra-tools/ab.sh $O/shape-$t-$pr 3 30 $t def=$G:Metal:$pr tib1=$G:Metal:$pr:M29_TILES_IN_BATCH=1 tib2=$G:Metal:$pr:M29_TILES_IN_BATCH=2 fib64=$G:Metal:$pr:M29_FIB_GROUP=64 fib128=$G:Metal:$pr:M29_FIB_GROUP=128 > $O/shape-$t-$pr.out 2>&1
    echo "shape $t $pr exit $?"
done
echo shape done

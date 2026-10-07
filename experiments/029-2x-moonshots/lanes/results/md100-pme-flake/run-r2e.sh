#!/bin/sh
# Hypothesis test: md100 with DeterministicForces=true on the Metal MD Context (forces_det.py = installed
# forces.py with that one property added). Apple9 then spreads PME charges in fixed point, as 6df2b8bcb
# always does. pme alone x20 on r1, then gate conditions: base x1, then int028 and r1 alternating x6,
# all in one correctness ticket.
set -u
B=/tmp/openmm-metal-bench; O=$B/ultra-infra/md100-pme-r2
export PATH=$B/env/bin:$PATH
export PYTHONPATH=$B/ultra-tools
if [ $# = 0 ]; then
    exec "$B/ultra-tools/lease.sh" --correctness --cap 1200 r2-infra "md100 DeterministicForces test" "$0" held
fi
run() {
    "$B/ultra-$2/venv/bin/python" "$O/$1" --md 100 "$B/ultra-base/benchmarks" "$O/det/$3.txt" "$B/ultra-base/forces-md100.txt" > "$O/det/$3.log" 2>&1
    rc=$?
    echo "$(date -u +%H:%M:%SZ) $3 exit=$rc $(grep FAIL "$O/det/$3.log" | tr -s ' ' | tr '\n' ';')"
}
i=1
while [ $i -le 20 ]; do run forces_det_pme.py r1 r1-pme-$i; i=$((i+1)); done
run forces_det.py base base-1
for i in 1 2 3 4 5 6; do run forces_det.py int028 int028-$i; run forces_det.py r1 r1-$i; done
echo ALL-DONE

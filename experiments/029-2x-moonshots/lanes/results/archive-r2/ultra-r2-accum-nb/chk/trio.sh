#!/bin/sh
# irl on day-trial3 (tree d, a1ba64449) against day-trial3 5d617bfc3 on the apoa1 trio, single and mixed.
# Waits for rerun5 to free its ticket slot first (two tickets per lane).
set -u
cd /tmp/openmm-metal-bench
while kill -0 75529 2>/dev/null; do sleep 20; done
O=/tmp/openmm-metal-bench/ultra-r2-accum-nb/dt3
B=/tmp/openmm-metal-bench/ultra-day-trial3/venv/bin/python
D=/tmp/openmm-metal-bench/ultra-r2-accum-nb-d/venv/bin/python
for row in apoa1rf:single apoa1rf:mixed apoa1pme:single apoa1pme:mixed apoa1ljpme:single apoa1ljpme:mixed; do
    t=${row%:*}; pr=${row#*:}
    ./ultra-tools/ab.sh $O/ab-$t-$pr 3 30 $t dt3=$B:Metal:$pr irl=$D:Metal:$pr > $O/ab-$t-$pr.out 2>&1
    echo "$t $pr exit $?"
done
echo trio done

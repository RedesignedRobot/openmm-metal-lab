#!/bin/sh
# fbb+irl stack on day-trial3 (tree d, a1ba64449) against day-trial3 5d617bfc3, all nine tests, single and mixed, apoa1 trio first.
# Waits for rerun5 to free its ticket slot first (two tickets per lane).
set -u
cd /tmp/openmm-metal-bench
while kill -0 75529 2>/dev/null; do sleep 20; done
O=/tmp/openmm-metal-bench/ultra-r2-accum-nb/dt3
B=/tmp/openmm-metal-bench/ultra-day-trial3/venv/bin/python
D=/tmp/openmm-metal-bench/ultra-r2-accum-nb-d/venv/bin/python
for row in apoa1rf:single apoa1rf:mixed apoa1pme:single apoa1pme:mixed apoa1ljpme:single apoa1ljpme:mixed amber20-stmv:single amber20-stmv:mixed amber20-cellulose:single amber20-cellulose:mixed amber20-dhfr:single amber20-dhfr:mixed pme:single pme:mixed rf:single rf:mixed gbsa:single gbsa:mixed; do
    t=${row%:*}; pr=${row#*:}
    ./ultra-tools/ab.sh $O/ab-$t-$pr 3 30 $t dt3=$B:Metal:$pr irl=$D:Metal:$pr > $O/ab-$t-$pr.out 2>&1
    echo "$t $pr exit $?"
done
echo nine done

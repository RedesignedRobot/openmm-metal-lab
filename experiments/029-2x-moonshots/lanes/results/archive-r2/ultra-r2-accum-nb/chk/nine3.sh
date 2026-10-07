#!/bin/sh
# Next merge unit screen, all nine tests: day-trial3 5d617bfc3 against irl (tree d, a1ba64449, fbb+irl) and c16
# (tree r, 8e244d1b4, half-block tiles on a1ba64449), 3x30 host clock. Single and mixed share a ticket where the
# estimate fits under 18 min (6 configs); stmv and cellulose split by precision. Waits for rerun5's ticket slot.
set -u
cd /tmp/openmm-metal-bench
while kill -0 75529 2>/dev/null; do sleep 20; done
O=/tmp/openmm-metal-bench/ultra-r2-accum-nb/dt3r
B=/tmp/openmm-metal-bench/ultra-day-trial3/venv/bin/python
D=/tmp/openmm-metal-bench/ultra-r2-accum-nb-d/venv/bin/python
R=/tmp/openmm-metal-bench/ultra-r2-accum-nb-r/venv/bin/python
mkdir -p $O
for row in apoa1rf:single+mixed apoa1pme:single+mixed apoa1ljpme:single+mixed amber20-dhfr:single+mixed pme:single+mixed rf:single+mixed gbsa:single+mixed amber20-stmv:single amber20-stmv:mixed amber20-cellulose:single amber20-cellulose:mixed; do
    t=${row%:*}; precs=${row#*:}
    configs=""
    for pr in $(echo $precs | tr + ' '); do
        p=$(echo $pr | cut -c1)
        configs="$configs dt3$p=$B:Metal:$pr irl$p=$D:Metal:$pr c16$p=$R:Metal:$pr"
    done
    tag=$t-$(echo $precs | tr + -)
    ./ultra-tools/ab.sh $O/ab-$tag 3 30 $t $configs > $O/ab-$tag.out 2>&1
    echo "$tag exit $?"
done
echo nine3 done

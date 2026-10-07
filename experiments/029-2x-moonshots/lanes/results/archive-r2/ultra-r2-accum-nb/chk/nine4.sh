#!/bin/sh
# c16 is dead (17% slower on apoa1rf), so the rest of the nine-test is day-trial3 5d617bfc3 against irl (tree d,
# a1ba64449) only, single and mixed in one ticket per test (4 configs), stmv split by precision. apoa1rf ran in
# nine3 with c16 as a third tree (dt3r/ab-apoa1rf-single-mixed, lease pid 86838); this waits for it.
set -u
cd /tmp/openmm-metal-bench
while kill -0 86838 2>/dev/null; do sleep 20; done
echo "apoa1rf ticket ended: $(tail -1 ultra-r2-accum-nb/dt3r/ab-apoa1rf-single-mixed.out)"
O=/tmp/openmm-metal-bench/ultra-r2-accum-nb/dt3r
B=/tmp/openmm-metal-bench/ultra-day-trial3/venv/bin/python
D=/tmp/openmm-metal-bench/ultra-r2-accum-nb-d/venv/bin/python
for row in apoa1pme:single+mixed apoa1ljpme:single+mixed amber20-dhfr:single+mixed pme:single+mixed rf:single+mixed gbsa:single+mixed amber20-cellulose:single+mixed amber20-stmv:single amber20-stmv:mixed; do
    t=${row%:*}; precs=${row#*:}
    configs=""
    for pr in $(echo $precs | tr + ' '); do
        p=$(echo $pr | cut -c1)
        configs="$configs dt3$p=$B:Metal:$pr irl$p=$D:Metal:$pr"
    done
    tag=$t-$(echo $precs | tr + -)
    ./ultra-tools/ab.sh $O/ab-$tag 3 30 $t $configs > $O/ab-$tag.out 2>&1
    echo "$tag exit $?"
done
echo nine4 done

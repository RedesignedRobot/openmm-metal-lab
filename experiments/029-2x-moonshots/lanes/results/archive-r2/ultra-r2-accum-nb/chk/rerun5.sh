#!/bin/sh
# One exclusive ticket: tile efficiency dump (apoa1rf, pme, amber20-stmv) and the neighbor-list cost on apoa1rf
# (rebuild interval, prepare time with and without a rebuild) in ultra-integrated and irl-int (tree q). Then the
# flagged screen rows again: rf single, rf mixed, pme single.
set -u
cd /tmp/openmm-metal-bench
E=/tmp/openmm-metal-bench/ultra-r2-accum-nb/eff
./ultra-tools/lease.sh ultra-r2-accum-nb "tile efficiency and list cost" /bin/sh -c "
for t in apoa1rf pme amber20-stmv; do
  ultra-integrated/venv/bin/python $E/tileeff.py --lib $E/libdump-int.dylib --test \$t --dir $E/\$t > $E/\$t.out 2>&1
  echo \"eff \$t exit \$?\"
done
for pr in single mixed; do
  ultra-integrated/venv/bin/python $E/listcost.py --lib $E/libdump-int.dylib --precision \$pr >> $E/listcost-int.jsonl
  echo \"listcost int \$pr exit \$?\"
  ultra-r2-accum-nb-q/venv/bin/python $E/listcost.py --lib $E/libdump-irl.dylib --precision \$pr >> $E/listcost-irl.jsonl
  echo \"listcost irl \$pr exit \$?\"
done"
echo "eff done"
I=/tmp/openmm-metal-bench/ultra-r2-accum-nb/irl
N=/tmp/openmm-metal-bench/ultra-integrated/venv/bin/python
P=/tmp/openmm-metal-bench/ultra-r2-accum-nb-p/venv/bin/python
Q=/tmp/openmm-metal-bench/ultra-r2-accum-nb-q/venv/bin/python
for row in rf:single rf:mixed pme:single; do
    t=${row%:*}; pr=${row#*:}
    ./ultra-tools/ab.sh $I/ab5-$t-$pr 3 30 $t int=$N:Metal:$pr fbb=$P:Metal:$pr irl=$Q:Metal:$pr > $I/ab5-$t-$pr.out 2>&1
    echo "$t $pr exit $?"
done
echo rerun5 done

#!/bin/sh
# One correctness ticket for the tile efficiency dump (apoa1rf, then pme and amber20-stmv for context), then the
# flagged screen rows again: rf single, rf mixed, pme single (rerun3 was stopped before it ran, to free the slot).
set -u
cd /tmp/openmm-metal-bench
E=/tmp/openmm-metal-bench/ultra-r2-accum-nb/eff
./ultra-tools/lease.sh --correctness ultra-r2-accum-nb tile efficiency dump /bin/sh -c "
for t in apoa1rf pme amber20-stmv; do
  ultra-integrated/venv/bin/python $E/tileeff.py --lib $E/libdump-int.dylib --test \$t --dir $E/\$t > $E/\$t.json
  echo \"\$t exit \$?\"
done"
echo "eff done"
I=/tmp/openmm-metal-bench/ultra-r2-accum-nb/irl
N=/tmp/openmm-metal-bench/ultra-integrated/venv/bin/python
P=/tmp/openmm-metal-bench/ultra-r2-accum-nb-p/venv/bin/python
Q=/tmp/openmm-metal-bench/ultra-r2-accum-nb-q/venv/bin/python
for row in rf:single rf:mixed pme:single; do
    t=${row%:*}; pr=${row#*:}
    ./ultra-tools/ab.sh $I/ab4-$t-$pr 3 30 $t int=$N:Metal:$pr fbb=$P:Metal:$pr irl=$Q:Metal:$pr > $I/ab4-$t-$pr.out 2>&1
    echo "$t $pr exit $?"
done
echo rerun4 done

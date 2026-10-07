#!/bin/sh
# probe10: no size sort for large-block systems (P_NOSORT, probe-only getenv) on top of fbb, in tree p.
set -u
cd /tmp/openmm-metal-bench
while kill -0 13829 2>/dev/null; do sleep 20; done
T=/tmp/openmm-metal-bench/ultra-r2-accum-nb-p
O=/tmp/openmm-metal-bench/ultra-r2-accum-nb/probe10
mkdir -p $O
./ultra-tools/sync.sh $HOME/code/wt/r2-accum-nb $T > $O/sync.out 2>&1 || { echo "sync failed"; exit 1; }
./ultra-tools/build.sh $T > $O/build.out 2>&1 || { echo "build failed"; exit 1; }
grep -q P_NOSORT $T/src/platforms/metal/src/MetalNonbondedUtilities.cpp || { echo "probe edit missing"; exit 1; }
P_NOSORT=1 ./ultra-tools/lease.sh --correctness r2-accum-nb "probe10 forces nosort" $T/venv/bin/python ultra-tools/forces.py ultra-base/benchmarks $O/forces.txt ultra-base/forces.txt > $O/forces.out 2>&1; echo "forces exit $?"
P_NOSORT=1 LISTCHECK_LANE=r2-accum-nb ./ultra-tools/listcheck.sh $T $O/listcheck apoa1pme amber20-stmv > $O/listcheck.out 2>&1; echo "listcheck exit $?"
C=/tmp/openmm-metal-bench/ultra-r2-accum-nb/chk/shader-ns.sh
for test in apoa1rf amber20-cellulose; do
  P_NOSORT=0 $C $O fbb-$test $test $T 2 || echo "fbb $test failed"; rm -rf $O/fbb-$test.trace
  P_NOSORT=1 $C $O ns-$test $test $T 2 || echo "ns $test failed"; rm -rf $O/ns-$test.trace
done
P=$T/venv/bin/python
./ultra-tools/ab.sh $O/ab 2 15 apoa1rf,apoa1pme,amber20-cellulose,amber20-stmv fbb_s=$P:Metal:single:P_NOSORT=0 ns_s=$P:Metal:single:P_NOSORT=1 > $O/ab.out 2>&1; echo "ab exit $?"
echo probe10 done

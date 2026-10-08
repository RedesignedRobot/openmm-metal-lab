#!/bin/sh
# fbb candidate (r2/accum-nb-fbb in tree p): correctness first, then day 2x15 screens against the 0b7a7b340 tree.
set -u
cd /tmp/openmm-metal-bench
T=/tmp/openmm-metal-bench/ultra-r2-accum-nb-p
O=/tmp/openmm-metal-bench/ultra-r2-accum-nb/fbbc
mkdir -p $O
./ultra-tools/gate.sh --quick $T > $O/gate.out 2>&1; echo "gate exit $?"
./ultra-tools/lease.sh --correctness r2-accum-nb "fbb detforces" $T/venv/bin/python ultra-tools/detforces.py ultra-base/benchmarks $O/detforces.txt > $O/detforces.out 2>&1; echo "detforces exit $?"
LISTCHECK_LANE=r2-accum-nb ./ultra-tools/listcheck.sh $T $O/listcheck > $O/listcheck.out 2>&1; echo "listcheck exit $?"
C=/tmp/openmm-metal-bench/ultra-r2-accum-nb/venv/bin/python
P=$T/venv/bin/python
./ultra-tools/ab.sh $O/abA 2 15 apoa1rf,apoa1pme,apoa1ljpme cand_s=$C:Metal:single fbb_s=$P:Metal:single cand_m=$C:Metal:mixed fbb_m=$P:Metal:mixed > $O/abA.out 2>&1; echo "abA exit $?"
./ultra-tools/ab.sh $O/abB 2 15 amber20-cellulose,amber20-stmv cand_s=$C:Metal:single fbb_s=$P:Metal:single cand_m=$C:Metal:mixed fbb_m=$P:Metal:mixed > $O/abB.out 2>&1; echo "abB exit $?"
./ultra-tools/ab.sh $O/abC 2 15 gbsa,rf,pme,amber20-dhfr cand_s=$C:Metal:single fbb_s=$P:Metal:single cand_m=$C:Metal:mixed fbb_m=$P:Metal:mixed > $O/abC.out 2>&1; echo "abC exit $?"
echo fbbc done

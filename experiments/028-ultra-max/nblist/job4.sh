#!/bin/sh
# nblist job 4, one timing hold on tree t6: the gated rebuild chain with early exits (g1) and with
# findBlocks through an indirect dispatch (g2), at batch 1 and 4. First isolated phase times
# (NB_TIME_WAIT=1), then plain ns/day with no phase timing.
set -eu
D=/tmp/openmm-metal-bench/ultra-nblist
PY=$D/t6/venv/bin/python
B=/tmp/openmm-metal-bench/ultra-base/benchmarks
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "nice is not 0" >&2; exit 1; }
uptime
rm -f $D/job4-times.txt
NB_TIME_WAIT=1 $PY $D/scan.py --time $D/job4-times.txt $B 1.5 2 rf,pme,apoa1pme \
  g0= g1=NB_GATE=1 g2=NB_GATE=2 b4g1=NB_BATCH=4,NB_GATE=1 b4g2=NB_BATCH=4,NB_GATE=2 || echo "scan stopped"
echo "== ns/day"
$PY $D/scan.py $B 6 2 rf,pme,apoa1rf,apoa1pme \
  g0= g1=NB_GATE=1 g2=NB_GATE=2 b4=NB_BATCH=4 b4g2=NB_BATCH=4,NB_GATE=2 || echo "scan stopped"
uptime
echo "JOB4 DONE"

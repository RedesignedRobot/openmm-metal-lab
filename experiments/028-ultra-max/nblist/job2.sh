#!/bin/sh
# nblist job 2, inside one lease.sh hold: quick gate and A/B screen of the clean branch head (t4,
# 411a9f19a), falling back to the sort-only build in ultra-nblist (e342bc02f) if t4 fails the gate.
# Then per-phase GPU times of the dev knobs (tree t3) with what is left of the 20 minutes.
set -eu
D=/tmp/openmm-metal-bench/ultra-nblist
T=/tmp/openmm-metal-bench/ultra-tools
PY=$D/t3/venv/bin/python
B=/tmp/openmm-metal-bench/ultra-base/benchmarks
BASE=base=/tmp/openmm-metal-bench/ultra-base/venv/bin/python:Metal:single
TESTS=gbsa,rf,pme,apoa1rf,apoa1pme,apoa1ljpme
start=$(date +%s)
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "nice is not 0" >&2; exit 1; }
uptime; ps -axo pcpu,command -r | head -5 | cut -c1-120
if $T/gate.sh --quick $D/t4; then
    $T/ab.sh $D/screen1 2 15 $TESTS $BASE all=$D/t4/venv/bin/python:Metal:single || echo "ab.sh failed"
elif $T/gate.sh --quick $D; then
    $T/ab.sh $D/screen1 2 15 $TESTS $BASE sort=$D/venv/bin/python:Metal:single || echo "ab.sh failed"
fi
uptime
left=$((1140 - ($(date +%s) - start)))
echo "scan gets $left s"
[ $left -gt 60 ] || exit 0
rm -f $D/job2-times.txt
/usr/bin/timeout $left $PY $D/scan.py --time $D/job2-times.txt $B 1.5 1 pme,apoa1ljpme,apoa1pme \
  new= base=NB_SORT2=0,NB_SORT2_COPY=0,NB_RANGE_BLOCKS=1,NB_SORTAGG=0,NB_SORTSCAN=0 wrap=NB_WRAP=1 b2=NB_BATCH=2 b4=NB_BATCH=4 \
  wrapb2=NB_WRAP=1,NB_BATCH=2 wrapb4=NB_WRAP=1,NB_BATCH=4 agg0=NB_SORTAGG=0 scan0=NB_SORTSCAN=0 \
  pb128=NB_PAIRBUF=128 pf=NB_PREFETCH=1 mb0=NB_MAXBITS=0 pad120=NB_PAD=120 pad160=NB_PAD=160 tg64=NB_FBTG=64 || echo "scan stopped"
uptime

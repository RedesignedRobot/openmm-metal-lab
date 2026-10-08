#!/bin/sh
# nblist job 3, one timing hold: per-phase GPU times on the dev2 tree (t5) with every phase isolated
# (NB_TIME_WAIT=1). Kill tests K3 (unrolled mask at thresholds 0, 8 and never, at batch 1 and 4) and
# K4 (staged sortBoxData on apoa1), and the GPU-gated rebuild chain (NB_GATE=1).
set -eu
D=/tmp/openmm-metal-bench/ultra-nblist
PY=$D/t5/venv/bin/python
B=/tmp/openmm-metal-bench/ultra-base/benchmarks
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "nice is not 0" >&2; exit 1; }
uptime
rm -f $D/job3-times.txt
export NB_TIME_WAIT=1
$PY $D/scan.py --time $D/job3-times.txt $B 1.5 2 gbsa,rf,pme \
  base= u0=NB_UNROLL=0 u8=NB_UNROLL=8 b4=NB_BATCH=4 b4u0=NB_BATCH=4,NB_UNROLL=0 b4u8=NB_BATCH=4,NB_UNROLL=8 g1=NB_GATE=1 b4g1=NB_BATCH=4,NB_GATE=1 || echo "scan stopped"
$PY $D/scan.py --time $D/job3-times.txt $B 1.5 2 apoa1rf,apoa1pme \
  base= u0=NB_UNROLL=0 u8=NB_UNROLL=8 sb=NB_STAGEBOX=1 g1=NB_GATE=1 || echo "scan stopped"
# Dual-list kill test (roadmap 7b): outer list at pad 0.22 against today's 0.08, both at batch 4 and
# MAX_BITS 0. Reads findBlocks per rebuild (k), the rebuild fraction (r_out) and the computeNonbonded delta.
$PY $D/scan.py --time $D/job3-times.txt $B 1.5 2 rf,pme \
  b4mb0=NB_BATCH=4,NB_MAXBITS=0 b4mb0p220=NB_BATCH=4,NB_MAXBITS=0,NB_PAD=220 || echo "scan stopped"
uptime
echo "JOB3 DONE"

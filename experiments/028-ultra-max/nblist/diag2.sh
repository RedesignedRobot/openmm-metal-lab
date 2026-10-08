#!/bin/sh
# nblist: forces of the dev2 knobs (tree t5, cand2 + sort pair + knobs) against Reference, inside one
# lease.sh --correctness hold. The unrolled mask and the staged sortBoxData must match base; MAX_BITS
# changes list contents and NB_GATE moves the rebuild trigger, so both also get the 100-step stale-list check.
D=/tmp/openmm-metal-bench/ultra-nblist
B=/tmp/openmm-metal-bench/ultra-base
F=/tmp/openmm-metal-bench/ultra-tools/forces.py
PY=$D/t5/venv/bin/python
mkdir -p $D/diag2
for cfg in u0=NB_UNROLL=0 sb=NB_STAGEBOX=1 mb0u0=NB_MAXBITS=0,NB_UNROLL=0 b4u0=NB_BATCH=4,NB_UNROLL=0 g1=NB_GATE=1; do
    label=${cfg%%=*}
    settings=$(echo "${cfg#*=}" | tr ',' ' ')
    echo "== $label $settings"
    env $settings $PY $F $B/benchmarks $D/diag2/forces-$label.txt $B/forces.txt | grep -E "FAIL|PASS|ok$" | cut -c1-110
done
# ultra-base/forces-md100.txt is the baseline (infra, 00:03Z); the tables also run next to a
# default-knob control. The gate's md100 runs on its candidate commits in diag5.
for cfg in def=NB_TIME=0 mb0=NB_MAXBITS=0 mb2=NB_MAXBITS=2; do
    label=${cfg%%=*}
    settings=$(echo "${cfg#*=}" | tr ',' ' ')
    echo "== md100 $label $settings"
    env $settings $PY $F --md 100 $B/benchmarks $D/diag2/md100-$label.txt $B/forces-md100.txt > /dev/null 2>&1; echo "exit $?"
    cat $D/diag2/md100-$label.txt
done
echo "== DIAG2 DONE"

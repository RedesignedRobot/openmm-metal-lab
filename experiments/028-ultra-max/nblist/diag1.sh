#!/bin/sh
# nblist: which dev knob breaks the forces gate? One forces.py run per knob, dev tree t3, inside one
# lease.sh --correctness hold.
D=/tmp/openmm-metal-bench/ultra-nblist
B=/tmp/openmm-metal-bench/ultra-base
mkdir -p $D/diag1
for cfg in agg=NB_SORTAGG=1,NB_SORTSCAN=0 scan=NB_SORTAGG=0,NB_SORTSCAN=1 wrap=NB_SORTAGG=0,NB_SORTSCAN=0,NB_WRAP=1 none=NB_SORTAGG=0,NB_SORTSCAN=0; do
    label=${cfg%%=*}
    settings=$(echo "${cfg#*=}" | tr ',' ' ')
    echo "== $label $settings"
    env $settings $D/t3/venv/bin/python /tmp/openmm-metal-bench/ultra-tools/forces.py $B/benchmarks $D/diag1/forces-$label.txt $B/forces.txt | grep -E "FAIL|PASS|ok$" | cut -c1-110
done

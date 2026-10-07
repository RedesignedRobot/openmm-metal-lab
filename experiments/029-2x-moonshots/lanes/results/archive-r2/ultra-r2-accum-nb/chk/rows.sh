#!/bin/sh
# Per-row ratios of the fbb/irl screen: fbb/int and irl/fbb, with spread and Background VM CPU.
I=/tmp/openmm-metal-bench/ultra-r2-accum-nb/irl
for d in $I/ab-*-single $I/ab-*-mixed; do
    [ -d "$d" ] || continue
    echo "---- $(basename $d)"
    /tmp/openmm-metal-bench/env/bin/python /tmp/openmm-metal-bench/ultra-tools/summarize.py $d fbb/int irl/fbb 2>&1 | grep -i 'rounds [0-9]\|spread\|VM\|BUILD'
done

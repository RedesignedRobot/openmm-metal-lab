#!/bin/sh
. ~/openmm-m4check/m4env.sh
cd ~/openmm-m4check/ultra-base/benchmarks
for t in gbsa rf pme apoa1rf apoa1pme apoa1ljpme; do
  for arm in "Metal single" "Metal mixed" "OpenCL single"; do
    set -- $arm
    r=$(/opt/homebrew/bin/gtimeout 180 $PY benchmark.py --platform $1 --precision $2 --test $t --seconds 15 2>&1 | grep ns_per_day | tail -1)
    echo "$t $1 $2 | $r"
  done
done

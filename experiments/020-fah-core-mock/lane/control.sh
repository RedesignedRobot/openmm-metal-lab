#!/bin/sh
# Restart-continuity control on OpenCL (shared f9347f6c5 env, read only) and Metal (020 venv), dhfr Verlet.
B=/tmp/openmm-metal-bench/020
until grep -q ALLDONE $B/c2-out/run.log 2>/dev/null; do sleep 30; done
until mkdir /tmp/openmm-lease 2>/dev/null; do sleep 20; done
echo "fah-readiness $(date -u +%H:%MZ) C2 continuity control OpenCL/Metal dhfr" > /tmp/openmm-lease/owner
trap 'rm -rf /tmp/openmm-lease' EXIT
cd $B/lab
for run in "/tmp/openmm-metal-bench/env/bin/python OpenCL single" "$B/venv/bin/python Metal single" "$B/venv/bin/python Metal mixed"; do
  set -- $run
  $1 control.py $B/fah-wu/dhfr $2 $3 1000 250 >> $B/c2-out/control.jsonl 2>> $B/c2-out/control.log
  echo "exit $? $2 $3 $(date -u +%FT%TZ)" >> $B/c2-out/control.log
done

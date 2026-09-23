#!/bin/sh
# STMV start-state PE by force group on OpenCL single and mixed (shared env, read only) against Reference.
B=/tmp/openmm-metal-bench/020
while pgrep -f "sh decompose.sh" >/dev/null; do sleep 10; done
until mkdir /tmp/openmm-lease 2>/dev/null; do sleep 20; done
echo "fah-readiness $(date -u +%H:%MZ) STMV energy decomposition OpenCL in $B" > /tmp/openmm-lease/owner
cd $B/lab
echo "== $(date -u +%FT%TZ) stmv OpenCL"
/tmp/openmm-metal-bench/env/bin/python decompose.py $B/fah-wu/stmv OpenCL:single OpenCL:mixed
echo "exit $? $(date -u +%FT%TZ)"
rm -rf /tmp/openmm-lease

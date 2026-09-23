#!/bin/sh
# Split start-state PE by force group on Metal mixed/single and CPU against Reference, under the lease.
B=/tmp/openmm-metal-bench/020
until mkdir /tmp/openmm-lease 2>/dev/null; do sleep 20; done
echo "fah-readiness $(date -u +%H:%MZ) STMV energy decomposition in $B" > /tmp/openmm-lease/owner
cd $B/lab
for wu in stmv nav; do
  echo "== $(date -u +%FT%TZ) $wu"
  $B/venv/bin/python decompose.py $B/fah-wu/$wu Metal:mixed Metal:single CPU
  echo "exit $? $(date -u +%FT%TZ)"
done
rm -rf /tmp/openmm-lease

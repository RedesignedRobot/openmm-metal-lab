#!/bin/sh
# After next5 (pid $1): if its screen ran, the census2 shader timelines in one timing ticket.
set -u
cd /tmp/openmm-metal-bench
while kill -0 "$1" 2>/dev/null; do sleep 30; done
grep -q "^verifier screen exit" ultra-r2-accum-nb/verify/next5.out || { echo "no screen, no census2"; exit 1; }
./ultra-tools/lease.sh ultra-r2-accum-nb "shader census cw5 vs verifier apoa1rf apoa1pme" ultra-r2-accum-nb/census2/census2.sh > ultra-r2-accum-nb/census2/census.out 2>&1
echo "census2 ticket exit $?"

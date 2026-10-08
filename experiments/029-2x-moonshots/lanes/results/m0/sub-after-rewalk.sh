#!/bin/sh
# Queues the M0(2) sub-tile spec (accum-nb tree p, no env) once the r1 rewalk hold (lease child 84062) is over, so
# r2-infra never has more than two tickets queued. The walk runs with the fixed gdwalk.py.
until ! kill -0 84062 2>/dev/null; do sleep 20; done
echo "rewalk hold over $(date -u +%H:%M:%SZ), queueing sub"
exec /bin/sh /tmp/openmm-metal-bench/ultra-infra/m0/counters-launch.sh sub=/tmp/openmm-metal-bench/ultra-r2-accum-nb-p

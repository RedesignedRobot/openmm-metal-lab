#!/bin/sh
# Waits for infra's queued forces job (pid given) to end, so infra keeps one lease waiter, then queues qwsmoke.sh.
while kill -0 "$1" 2>/dev/null; do sleep 5; done
echo "$(date -u +%H:%M:%SZ) job $1 ended, queueing qwsmoke.sh"
exec /tmp/openmm-metal-bench/ultra-tools/lease.sh ultra-infra "qw.sh smoke, 1 x 5 s gbsa, then one stmv 30 s timing, ~5 min" /bin/sh /tmp/openmm-metal-bench/ultra-infra/qwsmoke.sh

#!/bin/sh
set -u
# GPU correctness work: outside a lease hold, re-run through this script's own --correctness ticket (infra, 2026-09-27;
# tools/README). Inside a hold (OPENMM_LEASE_PID live) it runs at once.
[ "$(cat /tmp/openmm-lease/pid 2>/dev/null)" = "${OPENMM_LEASE_PID:-none}" ] || [ -f "/tmp/openmm-lease/members/${OPENMM_LEASE_PID:-none}" ] ||
    exec /tmp/openmm-metal-bench/ultra-tools/lease.sh --correctness r2-accum-nb "p2-smoke.sh $*" /bin/sh /tmp/openmm-metal-bench/ultra-r2-accum-nb/chk/p2-smoke.sh "$@"
P=/tmp/openmm-metal-bench/ultra-r2-accum-nb-p/venv/bin/python
cd /tmp/openmm-metal-bench/ultra-r2-accum-nb/chk
$P dumpf.py dump p-hoist.npz single apoa1rf,amber20-cellulose
echo "== p hoisted pbc"; $P dumpf.py cmp p-hoist.npz r-none.npz

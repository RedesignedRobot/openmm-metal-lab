#!/bin/sh
set -u
# GPU correctness work: outside a lease hold, re-run through this script's own --correctness ticket (infra, 2026-09-27;
# tools/README). Inside a hold (OPENMM_LEASE_PID live) it runs at once.
[ "$(cat /tmp/openmm-lease/pid 2>/dev/null)" = "${OPENMM_LEASE_PID:-none}" ] || [ -f "/tmp/openmm-lease/members/${OPENMM_LEASE_PID:-none}" ] ||
    exec /tmp/openmm-metal-bench/ultra-tools/lease.sh --correctness r2-accum-nb "q-smoke.sh $*" /bin/sh /tmp/openmm-metal-bench/ultra-r2-accum-nb/chk/q-smoke.sh "$@"
Q=/tmp/openmm-metal-bench/ultra-r2-accum-nb-q/venv/bin/python
cd /tmp/openmm-metal-bench/ultra-r2-accum-nb/chk
for v in P_XLOAD P_GREDUCE; do
    env $v=1 $Q dumpf.py dump q-$v.npz single apoa1rf,apoa1pme,amber20-cellulose
    echo "== $v"; $Q dumpf.py cmp base-a1.npz q-$v.npz
done
env P_XLOAD=1 P_GREDUCE=1 $Q dumpf.py dump q-both.npz single apoa1rf,apoa1pme,amber20-cellulose
echo "== both"; $Q dumpf.py cmp base-a1.npz q-both.npz; $Q dumpf.py cmp p-none.npz q-both.npz

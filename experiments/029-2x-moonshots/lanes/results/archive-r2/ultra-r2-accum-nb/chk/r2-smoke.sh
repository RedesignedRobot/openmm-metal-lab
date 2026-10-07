#!/bin/sh
set -u
# GPU correctness work: outside a lease hold, re-run through this script's own --correctness ticket (infra, 2026-09-27;
# tools/README). Inside a hold (OPENMM_LEASE_PID live) it runs at once.
[ "$(cat /tmp/openmm-lease/pid 2>/dev/null)" = "${OPENMM_LEASE_PID:-none}" ] || [ -f "/tmp/openmm-lease/members/${OPENMM_LEASE_PID:-none}" ] ||
    exec /tmp/openmm-metal-bench/ultra-tools/lease.sh --correctness r2-accum-nb "r2-smoke.sh $*" /bin/sh /tmp/openmm-metal-bench/ultra-r2-accum-nb/chk/r2-smoke.sh "$@"
R=/tmp/openmm-metal-bench/ultra-r2-accum-nb-r/venv/bin/python
cd /tmp/openmm-metal-bench/ultra-r2-accum-nb/chk
for v in P_NOPBC P_QUNROLL; do
    env $v=1 $R dumpf.py dump r-$v.npz single apoa1rf,amber20-cellulose
    echo "== $v"; $R dumpf.py cmp r-none.npz r-$v.npz
done
G=/tmp/openmm-metal-bench/ultra-r2-accum-nb-g/venv/bin/python
Q=/tmp/openmm-metal-bench/ultra-r2-accum-nb-q/venv/bin/python
env P_NBMULT=160 $G dumpf.py dump g-160.npz single apoa1rf,amber20-cellulose
echo "== g P_NBMULT=160"; $G dumpf.py cmp r-none.npz g-160.npz
$Q dumpf.py dump q-manc.npz single apoa1rf,amber20-cellulose
echo "== q manual c"; $Q dumpf.py cmp r-none.npz q-manc.npz

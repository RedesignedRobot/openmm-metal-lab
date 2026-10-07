#!/bin/sh
# Forces of each probe toggle on apoa1rf and cellulose, against the untoggled probe build.
set -u
# GPU correctness work: outside a lease hold, re-run through this script's own --correctness ticket (infra, 2026-09-27;
# tools/README). Inside a hold (OPENMM_LEASE_PID live) it runs at once.
[ "$(cat /tmp/openmm-lease/pid 2>/dev/null)" = "${OPENMM_LEASE_PID:-none}" ] || [ -f "/tmp/openmm-lease/members/${OPENMM_LEASE_PID:-none}" ] ||
    exec /tmp/openmm-metal-bench/ultra-tools/lease.sh --correctness r2-accum-nb "probe-smoke.sh $*" /bin/sh /tmp/openmm-metal-bench/ultra-r2-accum-nb/chk/probe-smoke.sh "$@"
P=/tmp/openmm-metal-bench/ultra-r2-accum-nb-p/venv/bin/python
D=/tmp/openmm-metal-bench/ultra-r2-accum-nb/chk
cd $D
$P dumpf.py dump p-none.npz single apoa1rf,amber20-cellulose
for v in P_OLDLOOP P_NOSORT P_FULLMASK P_NOCBRANCH; do
    env $v=1 $P dumpf.py dump p-$v.npz single apoa1rf,amber20-cellulose
    echo "== $v"; $P dumpf.py cmp p-none.npz p-$v.npz
done

#!/bin/sh
set -u
# GPU correctness work: outside a lease hold, re-run through this script's own --correctness ticket (infra, 2026-09-27;
# tools/README). Inside a hold (OPENMM_LEASE_PID live) it runs at once.
[ "$(cat /tmp/openmm-lease/pid 2>/dev/null)" = "${OPENMM_LEASE_PID:-none}" ] || [ -f "/tmp/openmm-lease/members/${OPENMM_LEASE_PID:-none}" ] ||
    exec /tmp/openmm-metal-bench/ultra-tools/lease.sh --correctness r2-accum-nb "r-smoke.sh $*" /bin/sh /tmp/openmm-metal-bench/ultra-r2-accum-nb/chk/r-smoke.sh "$@"
R=/tmp/openmm-metal-bench/ultra-r2-accum-nb-r/venv/bin/python
cd /tmp/openmm-metal-bench/ultra-r2-accum-nb/chk
OPENMM_SAVE_TEMPS=1 OPENMM_SAVE_TEMPS_PREFIX=/tmp/openmm-metal-bench/ultra-r2-accum-nb/chk/tmps-r/ $R dumpf.py dump r-none.npz single apoa1rf,apoa1pme,amber20-cellulose
echo "== manual"; $R dumpf.py cmp base-a1.npz r-none.npz; $R dumpf.py cmp p-none.npz r-none.npz
P_GREDUCE=1 $R dumpf.py dump r-gr.npz single apoa1rf,apoa1pme,amber20-cellulose
echo "== manual+greduce"; $R dumpf.py cmp base-a1.npz r-gr.npz; $R dumpf.py cmp p-none.npz r-gr.npz

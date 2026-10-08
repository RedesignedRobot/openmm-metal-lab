#!/bin/sh
# GPU correctness work: outside a lease hold, re-run through this script's own --correctness ticket (infra, 2026-09-27;
# tools/README). Inside a hold (OPENMM_LEASE_PID live) it runs at once.
[ "$(cat /tmp/openmm-lease/pid 2>/dev/null)" = "${OPENMM_LEASE_PID:-none}" ] || [ -f "/tmp/openmm-lease/members/${OPENMM_LEASE_PID:-none}" ] ||
    exec /tmp/openmm-metal-bench/ultra-tools/lease.sh --correctness r2-accum-gb "det-v.sh $*" /bin/sh /tmp/openmm-metal-bench/ultra-r2-accum-gb/det-v.sh "$@"
cd /tmp/openmm-metal-bench/ultra-r2-accum-gb-s && venv/bin/python /tmp/openmm-metal-bench/ultra-tools/detforces.py /tmp/openmm-metal-bench/ultra-base/benchmarks /tmp/openmm-metal-bench/ultra-r2-accum-gb/detforces-v.txt 2>&1 | grep -v "warning\|^ *[~^]\|Compilation succeeded\|^ \|^\s*$" | tail -20

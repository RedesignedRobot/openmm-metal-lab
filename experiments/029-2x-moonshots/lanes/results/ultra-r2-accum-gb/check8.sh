#!/bin/sh
# GPU correctness work: outside a lease hold, re-run through this script's own --correctness ticket (infra, 2026-09-27;
# tools/README). Inside a hold (OPENMM_LEASE_PID live) it runs at once.
[ "$(cat /tmp/openmm-lease/pid 2>/dev/null)" = "${OPENMM_LEASE_PID:-none}" ] || [ -f "/tmp/openmm-lease/members/${OPENMM_LEASE_PID:-none}" ] ||
    exec /tmp/openmm-metal-bench/ultra-tools/lease.sh --correctness r2-accum-gb "check8.sh $*" /bin/sh /tmp/openmm-metal-bench/ultra-r2-accum-gb/check8.sh "$@"
echo "== owned f (tree q)"; /tmp/openmm-metal-bench/ultra-r2-accum-gb-q/venv/bin/python /tmp/openmm-metal-bench/ultra-r2-accum-gb/tools/gbcheck.py /tmp/openmm-metal-bench/ultra-base/benchmarks 2>&1 | grep -v "warning\|^ *[~^]\|Compilation succeeded\|^ \|^\s*$" | grep "gbsa\|rror"
cd /tmp/openmm-metal-bench/ultra-r2-accum-gb-q/build && PATH=/tmp/openmm-metal-bench/env/bin:$PATH ctest -R "TestMetalGBSAOBCForce" --output-on-failure 2>&1 | tail -15
cd /tmp/openmm-metal-bench/ultra-r2-accum-gb-q && venv/bin/python /tmp/openmm-metal-bench/ultra-tools/detforces.py /tmp/openmm-metal-bench/ultra-base/benchmarks /tmp/openmm-metal-bench/ultra-r2-accum-gb/detforces-f.txt 2>&1 | grep -v "warning\|^ *[~^]\|Compilation succeeded\|^ \|^\s*$" | tail -16

#!/bin/sh
# Runs on the M3 Ultra: rebuilds prec at 86d559ebb with infra's build.sh (nice 10, outside any hold),
# then queues villinkern.sh as a --correctness ticket.
L=/tmp/openmm-metal-bench/ultra-plugins
echo "build $(date -u +%H:%M:%SZ)"
/tmp/openmm-metal-bench/ultra-tools/build.sh $L/prec > $L/prec-build.out 2>&1 || { echo "build FAILED"; tail -20 $L/prec-build.out; exit 1; }
echo "built $(date -u +%H:%M:%SZ)"
exec /tmp/openmm-metal-bench/ultra-tools/lease.sh --correctness plugins "villin per-program precise math (86d559ebb)" /bin/sh $L/villinkern.sh

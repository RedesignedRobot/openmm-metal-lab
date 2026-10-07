#!/bin/sh
# Runs on the M3 Ultra: rebuilds prec at 1f29eafe1 with build.sh outside any hold, then queues margin.sh.
L=/tmp/openmm-metal-bench/ultra-plugins
echo "build $(date -u +%H:%M:%SZ)"
/tmp/openmm-metal-bench/ultra-tools/build.sh $L/prec > $L/prec-build.out 2>&1 || { echo "build FAILED"; tail -20 $L/prec-build.out; exit 1; }
echo "built $(sed -n 's/^commit //p' $L/prec/BUILT) $(date -u +%H:%M:%SZ)"
exec /tmp/openmm-metal-bench/ultra-tools/lease.sh --correctness plugins "villin margin, fixed field math variants (1f29eafe1)" /bin/sh $L/margin.sh

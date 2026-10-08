#!/bin/sh
for i in 1 2 3; do
    s=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
    /tmp/openmm-metal-bench/ultra-infra/leasetest/lease.sh inner "inner $i" true
    echo "  inner $i took $(echo "$(perl -MTime::HiRes=time -e 'printf "%.2f", time') - $s" | bc) s"
done
/tmp/openmm-metal-bench/ultra-infra/leasetest/lease.sh inner "inner sleep" sleep 31.7

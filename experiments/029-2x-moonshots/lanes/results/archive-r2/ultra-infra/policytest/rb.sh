#!/bin/sh
running_builds() {
    ps -axo stat=,ucomm= | awk '$1 !~ /^T/ && $2 ~ /^(clang|clang\+\+|ninja|cc1plus)$/' | wc -l | tr -d ' '
}
T=/tmp/openmm-metal-bench/ultra-infra/policytest
echo "before: $(running_builds)"
/tmp/openmm-metal-bench/env/bin/ninja -C $T/nj > /dev/null & p=$!; sleep 0.5
echo "real ninja running: $(running_builds)"
kill -STOP $p; sleep 0.2
echo "real ninja stopped: $(running_builds)"
kill -CONT $p; kill $p

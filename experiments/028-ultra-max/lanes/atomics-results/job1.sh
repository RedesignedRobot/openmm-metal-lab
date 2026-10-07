#!/bin/sh
# GPU job under one lease: probe 1a (counters, 4 variants x 4 tests), then the atomic microbenchmark.
L=/tmp/openmm-metal-bench/ultra-atomics
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing: nice is not 0"; exit 1; }
$L/p1a/run1a.sh
{ echo "load $(sysctl -n vm.loadavg)"; $L/ub 0; $L/ub 400; } > $L/ub-2.txt 2>&1

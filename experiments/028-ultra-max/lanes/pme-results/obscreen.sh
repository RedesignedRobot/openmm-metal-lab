#!/bin/sh
# usage: obscreen.sh   One timing hold, about 8 minutes. Probe 1b's last test: the PME pass on dispatch's onebuf, where
# the list build and the force kernels share one command buffer. ob-pair is c515f3b34 (onebuf, poll, splitPass) plus
# 71a602b43 and 17929e631 (e24a8c4b6); ob-pass adds 5bfc934b6 (a7d76b55d). pme and apoa1pme single, 2 x 15 s.
L=/tmp/openmm-metal-bench/ultra-pme
grep -q e24a8c4b6 $L/ob-pair/BUILT && grep -q a7d76b55d $L/ob-pass/BUILT || { echo "ob trees are not built"; exit 1; }
echo "ob-pair and ob-pass built; load $(sysctl -n vm.loadavg) at $(date -u +%H:%M:%SZ)"
/tmp/openmm-metal-bench/ultra-tools/ab.sh $L/ab-ob 2 15 pme,apoa1pme pair=$L/ob-pair/venv/bin/python:Metal:single pass=$L/ob-pass/venv/bin/python:Metal:single
echo "done $(date -u +%H:%M:%SZ)"

#!/bin/sh
# Runs on the M3 Ultra: builds cand at 6aac90ee3 with build.sh, waits for the integrated gate on e08a0b1c6
# to print its verdict (the lead asked for no GPU work before then), then queues pmefix.sh.
L=/tmp/openmm-metal-bench/ultra-plugins
G=/tmp/openmm-metal-bench/ultra-integrated/gate-full-e08a0b1c6.out
echo "build $(date -u +%H:%M:%SZ)"
/tmp/openmm-metal-bench/ultra-tools/build.sh $L/cand > $L/cand/build.out 2>&1 || { echo "build FAILED"; tail -20 $L/cand/build.out; exit 1; }
echo "built $(sed -n 's/^commit //p' $L/cand/BUILT) $(date -u +%H:%M:%SZ)"
until grep -qxE 'PASS|FAIL' $G; do sleep 30; done
echo "integrated gate verdict $(grep -xE 'PASS|FAIL' $G | tail -1) seen $(date -u +%H:%M:%SZ)"
exec /tmp/openmm-metal-bench/ultra-tools/lease.sh --correctness plugins "AMOEBA PME spread fix on integrated (6aac90ee3), 4 tests" /bin/sh $L/pmefix.sh

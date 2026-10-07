#!/bin/sh
# Build gap test in an isolated bench (lease.sh and build-policy.py copies with test paths, a 20 s cap
# and the night slot): builds done, the cap, a window ticket, and no builds.
T=/tmp/openmm-metal-bench/ultra-infra/gaptest
export BUILD_POLICY_BENCH=$T
L=$T/bin/lease.sh
t0=$(date +%s)
el() { echo $(( $(date +%s) - t0 )); }
mark() { echo "$(el) $*"; }
job() { # job <name> <seconds> [lease args]: a hold that logs its start and end
    n=$1; s=$2; shift 2
    $L "$@" test-$n "$n" sh -c "echo \"\$(( \$(date +%s) - $t0 )) $n starts\"; sleep $s; echo \"\$(( \$(date +%s) - $t0 )) $n ends\"" &
}
fake_build() { $T/bin/build.sh --locked $T/$1 & fb=$!; }
rm -rf $T/lease $T/queue $T/timing $T/.build-gap.json $T/.timing-build-policy.json $T/ultra-*/.build.sh.pid
: > $T/ultra-lead/build-policy.log

mark "A: builds finish at 9 s; t2 timing waits, c1 correctness passes it"
fake_build ultra-fake1; a=$fb
job t1 3; sleep 0.5
job t2 1; sleep 0.5
job c1 2 --correctness; sleep 4
mark "status during the gap:"; $L --status | grep -A5 'build'
sleep 4; kill $a; mark "fake build 1 done"
wait
sleep 1

mark "B: the build never ends; t4 waits the 20 s cap"
fake_build ultra-fake2; b=$fb
job t3 2; sleep 0.5
job t4 1
wait_for() { while ! grep -q "$1" $T/out.log; do sleep 0.5; done; }
while kill -0 $! 2>/dev/null; do sleep 1; done
kill $b
sleep 1

mark "C: window ticket after the gap opens; c2 behind it doesn't pass; build ends 6 s after t5"
fake_build ultra-fake1; c=$fb
job t5 2; sleep 0.5
OPENMM_WINDOW=1 job w 1; sleep 0.5
job c2 1 --correctness
sleep 8; kill $c; mark "fake build done"
wait
sleep 1

mark "D: no pending builds; t7 starts right after t6"
job t6 2; sleep 0.5
job t7 1
wait
mark "gap log:"; grep ' gap ' $T/ultra-lead/build-policy.log
mark "leftovers:"; /bin/ls -A $T/queue $T/timing; /bin/ls $T/.build-gap.json $T/lease 2>&1

mark "E: a lease.sh from before the change queues behind t8; its begin waits out the gap (build ends 6 s after t8)"
fake_build ultra-fake2; e=$fb
job t8 2; sleep 0.5
L=$T/bin/old/lease.sh job t9 1
sleep 8; kill $e; mark "fake build done"
wait
mark "gap log:"; grep ' gap' $T/ultra-lead/build-policy.log | tail -3
mark "leftovers:"; /bin/ls -A $T/queue $T/timing; /bin/ls $T/.build-gap.json $T/lease 2>&1

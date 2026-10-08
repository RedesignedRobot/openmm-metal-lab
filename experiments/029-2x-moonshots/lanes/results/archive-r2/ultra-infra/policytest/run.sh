#!/bin/sh
# build-policy.py test in an isolated bench: pause, resume, register during a hold, dead-holder recovery.
T=/tmp/openmm-metal-bench/ultra-infra/policytest
export BUILD_POLICY_BENCH=$T
P() { /tmp/openmm-metal-bench/env/bin/python3 /tmp/openmm-metal-bench/ultra-infra/policy-new/build-policy.py "$@"; }
tree_state() { for p in $1 $(pgrep -P $1); do ps -o stat= -p $p | cut -c1; done | tr '\n' ' '; }
ticks() { wc -l < $1/ticks | tr -d ' '; }
moving() { a=$(ticks $1); sleep 1; b=$(ticks $1); echo "ticks +$((b - a))/s"; }
$T/bin/ninja -C $T/ultra-fake1/build & n1=$!; sleep 0.5; P register $T/ultra-fake1 $n1
$T/bin/lease.sh & o1=$!; sleep 0.3
echo "1 before begin: $(tree_state $n1) $(moving $T/ultra-fake1)"
P begin $o1; sleep 0.3
echo "2 after begin: $(tree_state $n1) $(moving $T/ultra-fake1)"; P status
P active; echo "3 active rc=$? (0 expected)"; (export OPENMM_LEASE_PID=$o1; P active); echo "3b inside the hold rc=$? (1 expected)"
$T/bin/ninja -C $T/ultra-fake2/build & n2=$!; sleep 0.5; P register $T/ultra-fake2 $n2; sleep 0.3
echo "4 registered during the hold: $(tree_state $n2) $(moving $T/ultra-fake2)"
P end $o1; sleep 0.3
echo "5 after end: $(tree_state $n1) / $(tree_state $n2) $(moving $T/ultra-fake1); state file left: $(ls $T/.timing-build-policy.json 2>/dev/null | wc -l | tr -d ' ')"
P active; echo "5b active rc=$? (1 expected)"
kill $o1
$T/bin/lease.sh & o2=$!; sleep 0.3; P begin $o2; sleep 0.3; echo "6 begin 2: $(tree_state $n1) / $(tree_state $n2)"
kill -9 $o2; sleep 3.5
echo "6b 3.5 s after kill -9 of the holder (guard): $(tree_state $n1) / $(tree_state $n2) $(moving $T/ultra-fake1); state file left: $(ls $T/.timing-build-policy.json 2>/dev/null | wc -l | tr -d ' ')"
$T/bin/lease.sh & o3=$!; sleep 0.3; P begin $o3; kill -9 $o3; sleep 0.1; P recover
echo "7 recover right after kill -9: $(tree_state $n1) / $(tree_state $n2)"
$T/bin/lease.sh & o4=$!; sleep 0.3; P begin $o4
$T/bin/ninja -C $T/ultra-fake2/build & n3=$!; sleep 0.4; (export OPENMM_LEASE_PID=$o4; P register $T/ultra-fake2 $n3)
echo "8 register from inside the hold: $(tree_state $n3) (not stopped expected); outside build n1: $(tree_state $n1)"
P end $o4; kill $o4
echo "9 end: $(tree_state $n1) / $(tree_state $n2) / $(tree_state $n3)"
for n in $n1 $n2 $n3; do for c in $(pgrep -P $n); do kill $c; done; kill $n; done
sleep 1; for n in $n1 $n2 $n3; do kill -0 $n 2>/dev/null && echo "still alive $n"; done
echo "--- log"; cat $T/ultra-lead/build-policy.log

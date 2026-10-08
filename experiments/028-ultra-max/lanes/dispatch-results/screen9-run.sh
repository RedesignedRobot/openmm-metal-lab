#!/bin/sh
# Studio: screen9 again after the 06:57Z refusals, one timing ticket per test, one at a time, each
# queued only once no build process runs. Old screen9-<test> dirs (refused, no runs) move to refused/.
T=/tmp/openmm-metal-bench/ultra-tools
D=/tmp/openmm-metal-bench/ultra-dispatch
BUILDS='clang|clang\+\+|ninja|cc1plus'
mkdir -p $D/screen9-refused
for test in gbsa rf pme; do
    [ -e $D/screen9-$test ] && mv $D/screen9-$test $D/screen9-refused/
    [ -e $D/screen9-$test.out ] && mv $D/screen9-$test.out $D/screen9-refused/
    while pgrep -x "$BUILDS" > /dev/null; do sleep 30; done
    nohup $T/lease.sh ultra-dispatch "screen9 $test: integrated base, wf, wfcap, wfk, about 5 min" $D/screen9.sh $test > $D/screen9-$test.out 2>&1 < /dev/null &
    pid=$!
    echo "screen9-$test $pid" >> $D/pids.txt; echo "screen9-$test queued pid $pid $(date -u +%H:%M:%SZ)"
    wait $pid
    echo "screen9-$test over, exit $? $(date -u +%H:%M:%SZ)"
done

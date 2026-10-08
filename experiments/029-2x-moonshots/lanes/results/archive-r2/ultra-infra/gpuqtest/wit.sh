. $HOME/code/metal/lab/experiments/029-2x-moonshots/tools/gpuq/tests/env.sh
D=$HOME/code/metal/lab/experiments/029-2x-moonshots/tools/gpuq; Q=$D/gpuq
rm -rf $GPUQ_DIR $GPUQ_LEASE_DIR $GPUQ_QUEUE_DIR $GPUQ_SOCK
start_daemon
B=$T/build6; rm -rf $B; mkdir -p $B
printf 'rule tick\n  command = sh -c "while :; do sleep 1; done"\nbuild j1: tick\nbuild j2: tick\n' > $B/build.ninja
(cd $B && $Q hold --class build --lane build6 --what "build.sh $B" -- /tmp/openmm-metal-bench/env/bin/ninja -j 2 > /dev/null 2>&1) &
c=$!
sleep 2
echo "no hold:  $($PY $D/../build-policy.py status)"
GPUQ_LANE=infra $Q hold --est 3 -- sh -c "sleep 1; $PY $D/../build-policy.py status; ps -axo stat=,ucomm= | awk '\$2 == \"ninja\"'"
sleep 2
echo "after:    $($PY $D/../build-policy.py status)"
$Q cancel $($PY -c "import sqlite3; print(sqlite3.connect('$GPUQ_DIR/state.db').execute(\"select id from jobs where lane='build6'\").fetchone()[0])") --lane build6
wait $c
kill $daemon

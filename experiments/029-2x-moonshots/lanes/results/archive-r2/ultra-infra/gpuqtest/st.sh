. $HOME/code/metal/lab/experiments/029-2x-moonshots/tools/gpuq/tests/env.sh
D=$HOME/code/metal/lab/experiments/029-2x-moonshots/tools/gpuq; Q=$D/gpuq
rm -rf $GPUQ_DIR $GPUQ_LEASE_DIR $GPUQ_QUEUE_DIR $GPUQ_SOCK
start_daemon
GPUQ_LANE=infra $Q submit --est 6 -- sleep 6 >/dev/null
(GPUQ_LANE=x $Q lease --correctness other "gate.sh something" sleep 3) &
sleep 2
$Q lease --status | head -8
echo "mirror: $(cat $GPUQ_LEASE_DIR/owner) pid $(cat $GPUQ_LEASE_DIR/pid); queue: $(ls $GPUQ_QUEUE_DIR)"
wait $!
kill $daemon

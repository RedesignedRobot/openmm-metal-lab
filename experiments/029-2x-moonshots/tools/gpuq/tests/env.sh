# Isolated gpuq instance for the acceptance tests: its own socket, state, lease mirrors and scratch dir.
T=${GPUQ_TEST_DIR:-/tmp/openmm-metal-bench/ultra-infra/gpuqtest}
mkdir -p $T
export GPUQ_SOCK=$T/gpuq.sock GPUQ_DIR=$T/home GPUQ_LEASE_DIR=$T/lease GPUQ_QUEUE_DIR=$T/queue GPUQ_IDLE_LOG=$T/idle.log
export GPUQ_GAP_SECONDS=${GPUQ_GAP_SECONDS:-20} GPUQ_SLOT=${GPUQ_SLOT:-day}
D=$(cd "$(dirname "$0")/.." && pwd)
Q=$D/gpuq
PY=/tmp/openmm-metal-bench/env/bin/python3
start_daemon() { $PY $D/gpuqd.py >> $T/daemon.log 2>&1 & daemon=$!; while [ ! -S $GPUQ_SOCK ]; do sleep 0.1; done; }

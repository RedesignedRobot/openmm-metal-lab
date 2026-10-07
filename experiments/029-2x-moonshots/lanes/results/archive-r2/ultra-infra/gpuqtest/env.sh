# Isolated gpuq instance for the acceptance tests.
export GPUQ_SOCK=/tmp/openmm-metal-bench/ultra-infra/gpuqtest/gpuq.sock GPUQ_DIR=/tmp/openmm-metal-bench/ultra-infra/gpuqtest/home GPUQ_LEASE_DIR=/tmp/openmm-metal-bench/ultra-infra/gpuqtest/lease GPUQ_QUEUE_DIR=/tmp/openmm-metal-bench/ultra-infra/gpuqtest/queue GPUQ_IDLE_LOG=/tmp/openmm-metal-bench/ultra-infra/gpuqtest/idle.log
export GPUQ_GAP_SECONDS=${GPUQ_GAP_SECONDS:-20} GPUQ_SLOT=${GPUQ_SLOT:-day}
D=/tmp/openmm-metal-bench/ultra-infra/gpuq-dev
Q=$D/gpuq
PY=/tmp/openmm-metal-bench/env/bin/python3
start_daemon() { $PY $D/gpuqd.py >> /tmp/openmm-metal-bench/ultra-infra/gpuqtest/daemon.log 2>&1 & daemon=$!; while [ ! -S $GPUQ_SOCK ]; do sleep 0.1; done; }

#!/bin/sh
# Runs on the M3 Ultra: the GPU lease, now a client of gpuqd (ultra-tools/gpuq). Same arguments as before:
#   lease.sh [--correctness [--merge-path]] [--cap SECONDS] <lane> <what> <command...> | lease.sh --status
# It queues an attached hold (class merge, correctness, window under window.sh, else timing), waits for
# gpuqd to grant the GPU, runs the command in its own process group and exits with its code. A lease.sh
# inside a running hold (ab.sh or gate.sh under your own lease.sh) runs its command at once. "about N min"
# in <what> is the estimate. gpuqd.py's header has the policy; `gpuq ls` shows the queue.
# Fallback to the old FIFO lease, one command: `gpuq off` (waits for the running GPU jobs, continues paused
# builds, then writes /tmp/openmm-metal-bench/gpuq/OFF); `gpuq on` switches back. Never touch OFF by hand.
TOOLS=/tmp/openmm-metal-bench/ultra-infra/gpuqtest/tools
[ -e "${GPUQ_DIR:-/tmp/openmm-metal-bench/gpuq}/OFF" ] && exec "$TOOLS/lease-legacy.sh" "$@"
GPUQ_LEGACY_LEASE="$TOOLS/lease-legacy.sh" exec /tmp/openmm-metal-bench/env/bin/python3 $HOME/code/metal/lab/experiments/029-2x-moonshots/tools/gpuq/gpuq lease "$@"

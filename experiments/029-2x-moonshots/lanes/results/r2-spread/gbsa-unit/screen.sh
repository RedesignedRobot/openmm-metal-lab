#!/bin/sh
# gbsa unit 3x30 screen after w3b: trunk (ultra-r3-nbfmc) against lanes32 and fold, single and mixed.
# gbsa and rf are separate ab.sh tickets to stay under the 18 minute screen cap. Starts once the w3b
# launcher (pid 87498) has exited and /tmp/openmm-window is clear; lease FIFO orders the tickets after that.
set -u
B=/tmp/openmm-metal-bench
D=$B/ultra-r3-gbfold
while kill -0 87498 2>/dev/null || [ -e /tmp/openmm-window ]; do sleep 30; done
TR=$B/ultra-r3-nbfmc/venv/bin/python
MY=$D/venv/bin/python
cfg="tr-s=$TR:Metal:single a-s=$MY:Metal:single:OPENMM_METAL_GB_VARIANT=lanes32 b-s=$MY:Metal:single:OPENMM_METAL_GB_VARIANT=fold tr-m=$TR:Metal:mixed a-m=$MY:Metal:mixed:OPENMM_METAL_GB_VARIANT=lanes32 b-m=$MY:Metal:mixed:OPENMM_METAL_GB_VARIANT=fold"
echo "$(date -u +%H:%M:%SZ) gbsa screen"
$B/ultra-tools/ab.sh $D/ab-gbsa 3 30 gbsa $cfg
echo "$(date -u +%H:%M:%SZ) rf screen"
$B/ultra-tools/ab.sh $D/ab-rf 3 30 rf $cfg
echo "$(date -u +%H:%M:%SZ) done"

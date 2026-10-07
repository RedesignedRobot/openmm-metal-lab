#!/bin/sh
L=/tmp/openmm-metal-bench/ultra-pme
for t in pme apoa1pme; do
  /bin/sh $L/env.sh $L $L/fdump.py $L/bench $t single $L/f-$t-ref.npy 2>&1 | grep saved
  PME_LAB_GATHER5=1 /bin/sh $L/env.sh $L $L/fdump.py $L/bench $t single $L/f-$t-g5.npy 2>&1 | grep saved
  PME_LAB_SPREAD_MUL=5 PME_LAB_BLOCK=256 /bin/sh $L/env.sh $L $L/fdump.py $L/bench $t single $L/f-$t-sm.npy 2>&1 | grep saved
  /tmp/openmm-metal-bench/env/bin/python -c "
import numpy as np
a=np.load('$L/f-$t-ref.npy')
for k in ('g5','sm'):
    b=np.load('$L/f-$t-'+k+'.npy'); print('$t', k, 'rel|dF| vs default', np.linalg.norm(a-b)/np.linalg.norm(a))"
done

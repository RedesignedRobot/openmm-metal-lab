#!/bin/sh
# One timing ticket: direct kernel GPU time from command buffer timestamps, base, 256-thread (r) and its no-y-reduction bound (g) interleaved.
set -u
cd /tmp/openmm-metal-bench
T=/tmp/openmm-metal-bench/ultra-r2-accum-nb/t256
./ultra-tools/lease.sh r2-accum-nb "t256 replay timing" /bin/sh -c "
for round in 1 2 3; do
  for prec in single mixed; do
    ultra-integrated/venv/bin/python $T/replay.py --tree ultra-integrated --lib $T/lib-int.dylib --precision \$prec --repeat 300 --out $T/time\$round-int-\$prec.npz
    ultra-r2-accum-nb-r/venv/bin/python $T/replay.py --tree ultra-r2-accum-nb-r --lib $T/lib-r.dylib --precision \$prec --repeat 300 --out $T/time\$round-r-\$prec.npz
    ultra-r2-accum-nb-g/venv/bin/python $T/replay.py --tree ultra-r2-accum-nb-g --lib $T/lib-g.dylib --precision \$prec --repeat 300 --out $T/time\$round-g-\$prec.npz
  done
done"
echo timing done

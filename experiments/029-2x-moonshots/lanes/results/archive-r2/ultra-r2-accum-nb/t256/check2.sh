#!/bin/sh
# One correctness ticket: run the direct kernel replay in the base, TG_FORCE (r) and BOTH_SIDES (g) trees.
set -u
cd /tmp/openmm-metal-bench
T=/tmp/openmm-metal-bench/ultra-r2-accum-nb/t256
./ultra-tools/lease.sh --correctness r2-accum-nb "tgs replay check" /bin/sh -c "
for prec in single mixed; do
  ultra-integrated/venv/bin/python $T/replay.py --tree ultra-integrated --lib $T/lib-int.dylib --precision \$prec --repeat 20 --out $T/check2-int-\$prec.npz; echo int \$prec exit \$?
  ultra-r2-accum-nb-r/venv/bin/python $T/replay.py --tree ultra-r2-accum-nb-r --lib $T/lib-r.dylib --precision \$prec --repeat 20 --out $T/check2-r-\$prec.npz; echo r \$prec exit \$?
  ultra-r2-accum-nb-g/venv/bin/python $T/replay.py --tree ultra-r2-accum-nb-g --lib $T/lib-g.dylib --precision \$prec --repeat 20 --out $T/check2-g-\$prec.npz; echo g \$prec exit \$?
done"
echo check done

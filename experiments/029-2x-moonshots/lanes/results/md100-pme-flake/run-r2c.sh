#!/bin/sh
# md100 max|dF| spread: 6 runs on ultra-base (6df2b8bcb, the md100 baseline's build), then 4 alternating
# runs each on int028 and r1, in one correctness ticket. Failing rows save .npz for diagnosis.
set -u
B=/tmp/openmm-metal-bench; O=$B/ultra-infra/md100-pme-r2
export PATH=$B/env/bin:$PATH
unset PYTHONPATH
if [ $# = 0 ]; then
    exec "$B/ultra-tools/lease.sh" --correctness --cap 1200 r2-infra "md100 max spread base+int028+r1" "$0" held
fi
run() {
    "$B/ultra-$1/venv/bin/python" "$B/ultra-tools/forces.py" --md 100 "$B/ultra-base/benchmarks" "$O/$1-$2.txt" "$B/ultra-base/forces-md100.txt" > "$O/$1-$2.log" 2>&1
    rc=$?
    echo "$(date -u +%H:%M:%SZ) $1 run $2 exit=$rc $(grep FAIL "$O/$1-$2.log" | tr -s ' ' | tr '\n' ';')"
}
for i in 1 2 3 4 5 6; do run base $i; done
for i in 7 8 9 10; do run int028 $i; run r1 $i; done
echo ALL-DONE

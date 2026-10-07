#!/bin/sh
# 6-of-6 demo against the worst-of-21 ultra-base md100 baseline, gate conditions (installed forces.py,
# seed 2026, default properties): base x1, then int028 and r1 alternating x6, in one correctness ticket.
set -u
B=/tmp/openmm-metal-bench; O=$B/ultra-infra/md100-pme-r2/demo
export PATH=$B/env/bin:$PATH
unset PYTHONPATH
grep -q "per-row worst of 21 md100 tables" $B/ultra-base/forces-md100.txt || { echo "ultra-base/forces-md100.txt is not the worst-of-21 baseline"; exit 2; }
if [ $# = 0 ]; then
    exec "$B/ultra-tools/lease.sh" --correctness --cap 1200 r2-infra "md100 6-of-6 demo, new baseline" "$0" held
fi
run() {
    "$B/ultra-$1/venv/bin/python" "$B/ultra-tools/forces.py" --md 100 "$B/ultra-base/benchmarks" "$O/$1-$2.txt" "$B/ultra-base/forces-md100.txt" > "$O/$1-$2.log" 2>&1
    rc=$?
    echo "$(date -u +%H:%M:%SZ) $1 run $2 exit=$rc $(grep FAIL "$O/$1-$2.log" | tr -s ' ' | tr '\n' ';')"
}
mkdir -p "$O"; run base 1
for i in 1 2 3 4 5 6; do run int028 $i; run r1 $i; done
echo ALL-DONE

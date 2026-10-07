#!/bin/sh
# Studio, one lease.sh timing hold: hostwork.py (2000 x step(1) plus 1 ms of host work) for poll t2 and
# waitfree+k t10, single and mixed, gbsa, rf, pme and amber20-dhfr, 3 rounds, one process per (round,
# arm, precision), order reversed every other round. Results in <outdir>/results.txt.
# usage: hostwork.sh <outdir>
set -eu
D=/tmp/openmm-metal-bench/ultra-dispatch
B=/tmp/openmm-metal-bench/ultra-base/benchmarks
out="$1"
mkdir "$out"
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
unset PYTHONPATH OPENMM_CPU_THREADS
order="poll:single wfk:single poll:mixed wfk:mixed"
reversed="wfk:mixed poll:mixed wfk:single poll:single"
for r in 1 2 3; do
    this="$order"
    [ $((r % 2)) -eq 0 ] && this="$reversed"
    for arm in $this; do
        label="${arm%:*}"
        precision="${arm#*:}"
        tree=t2
        [ "$label" = wfk ] && tree=t10
        echo "$(date -u +%H:%M:%SZ) round $r $label $precision load $(sysctl -n vm.loadavg | awk '{print $2}')" >> "$out/loads.txt"
        $D/$tree/venv/bin/python $D/hostwork.py $B gbsa,rf,pme,amber20-dhfr "$precision" 2000 1000 2> "$out/$label-$precision-round$r.err" \
            | sed "s/^/$label round$r /" >> "$out/results.txt"
    done
done
cat "$out/results.txt"

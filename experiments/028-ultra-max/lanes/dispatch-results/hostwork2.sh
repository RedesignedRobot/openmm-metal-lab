#!/bin/sh
# Studio, one lease.sh timing hold: hostwork.py (2000 x step(1) plus 1 ms of host work) for integrated
# base b69efb0fe, waitfree i-wf and waitfree plus the 8-buffer cap i-wfcap, single and mixed, gbsa, rf,
# pme and amber20-dhfr, 3 rounds, one process per (round, arm, precision), order reversed every other
# round. loads.txt records the build processes at the start and end of every run. Base loads the b69efb0fe platform plugins snapshotted in plugins-int-b69, since infra rebuilds
# ultra-integrated to 89d7f17fc (f1, plugin sources only). Results in <outdir>/results.txt.
# usage: hostwork2.sh <outdir>
set -eu
D=/tmp/openmm-metal-bench/ultra-dispatch
B=/tmp/openmm-metal-bench/ultra-base/benchmarks
BUILDS="clang|clang\\+\\+|ninja|cc1plus"
out="$1"
PLUGINS=$D/plugins-int-b69
[ "$(md5 -q $PLUGINS/libOpenMMMetal.dylib)" = 0137cb38f26be36bbff53e96aadc1a02 ] || { echo "plugins-int-b69 changed"; exit 1; }
mkdir "$out"
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
unset PYTHONPATH OPENMM_CPU_THREADS
order="base:single wf:single wfcap:single base:mixed wf:mixed wfcap:mixed"
reversed="wfcap:mixed wf:mixed base:mixed wfcap:single wf:single base:single"
for r in 1 2 3; do
    this="$order"
    [ $((r % 2)) -eq 0 ] && this="$reversed"
    for arm in $this; do
        label="${arm%:*}"
        precision="${arm#*:}"
        python=$D/i-$label/venv/bin/python
        plugin_dir=$D/i-$label/prefix/lib/plugins
        [ "$label" = base ] && { python=/tmp/openmm-metal-bench/ultra-integrated/venv/bin/python; plugin_dir=$PLUGINS; }
        echo "$(date -u +%H:%M:%SZ) round $r $label $precision load $(sysctl -n vm.loadavg | awk "{print \$2}") builds $(pgrep -x "$BUILDS" | wc -l | tr -d " ")" >> "$out/loads.txt"
        OPENMM_PLUGIN_DIR=$plugin_dir $python $D/hostwork.py $B gbsa,rf,pme,amber20-dhfr "$precision" 2000 1000 2> "$out/$label-$precision-round$r.err" \
            | sed "s/^/$label round$r /" >> "$out/results.txt"
        echo "$(date -u +%H:%M:%SZ) round $r $label $precision end builds $(pgrep -x "$BUILDS" | wc -l | tr -d " ")" >> "$out/loads.txt"
    done
done
cat "$out/results.txt"

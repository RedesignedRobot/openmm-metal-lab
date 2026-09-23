#!/bin/sh
# Runs on the mini after pipeline.sh.  Share of step time in findBlocksWithInteractions.
# ~/lab/openmm-simd-base-fb and ~/lab/openmm-simd-fb are copies of the two benchmark trees with
# time-findblocks.patch applied, built into their own prefixes and venvs so the benchmark
# installs are never patched.  Then fbshare.py for every test and precision, installs alternating.
# Each build and each (test, precision) pair holds the shared machine lease.
# Launch detached from sh at nice 0:  sh -c "nohup sh fb.sh > fb.log 2>&1 &"
set -u
here="$(cd "$(dirname "$0")" && pwd)"
. "$here/lease.sh"
lab="$HOME/lab"
out="$lab/simd-019/fb"
bench="$lab/simd-019/benchmarks"
steps=1000
export PATH="$lab/bin:/opt/homebrew/bin:$PATH"
export CCACHE_BASEDIR="$lab"
mkdir -p "$out"
status() { echo "$(date -u +%FT%TZ) $*" >> "$out/status"; }

for tree in openmm-simd-base-fb openmm-simd-fb; do
    cd "$lab/$tree"
    lease "build $tree"
    build-openmm.sh -DPYTHON_EXECUTABLE="$lab/venv-$tree/bin/python" > "$out/build-$tree.log" 2>&1
    status "build $tree exit $?"
    unlease
done

cd "$here"
turn=0
for test in pme apoa1rf apoa1pme amber20-cellulose; do
    for precision in single mixed; do
        if [ $((turn % 2)) -eq 0 ]; then order="before after"; else order="after before"; fi
        turn=$((turn + 1))
        lease "fbshare $test $precision"
        for label in $order; do
            if [ "$label" = before ]; then tree=openmm-simd-base-fb; else tree=openmm-simd-fb; fi
            times="$out/times-$test-$precision-$label.txt"
            rm -f "$times"
            OPENMM_TIME_FINDBLOCKS="$times" "$lab/venv-$tree/bin/python" fbshare.py "$bench" "$test" "$precision" $steps \
                > "$out/$test-$precision-$label.json" 2> "$out/$test-$precision-$label.err"
            status "$test $precision $label exit $?"
        done
        unlease
    done
done
status ALL_DONE

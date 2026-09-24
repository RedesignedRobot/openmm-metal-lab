#!/bin/sh
# Runs on the Studio under the lease: GpuProf.h records for gbsa, full and GB only, on the
# instrumented trees, interleaved and reversing tree order each round. Load averages go to loads.txt.
# usage: [MODES="kernels buffers"] [SYSTEMS="full gbonly"] gbsa-profile.sh <out dir> <rounds> <kernel-mode steps> <buffer-mode steps> [trees, default "hdprof refprof"]
set -eu
D=/tmp/openmm-metal-bench/gbsa-gap
out="$1"; rounds="$2"; ksteps="$3"; bsteps="$4"; trees="${5:-hdprof refprof}"
mkdir -p "$out"
export PYTHONPATH=$D/pydeps
r=1
while [ "$r" -le "$rounds" ]; do
    order="$trees"
    [ $((r % 2)) -eq 0 ] && order="$(echo $trees | tr ' ' '\n' | tail -r | tr '\n' ' ')"
    for system in ${SYSTEMS:-full gbonly}; do
        drop=""
        [ "$system" = gbonly ] && drop=NonbondedForce
        for mode in ${MODES:-kernels buffers}; do
            steps=$ksteps
            [ "$mode" = buffers ] && steps=$bsteps
            for tree in $order; do
                tag="$tree-$system-$mode-round$r"
                echo "$tag load $(sysctl -n vm.loadavg)" >> "$out/loads.txt"
                GPUPROF=$mode GPUPROF_OUT="$out/$tag.rec" "$D/venv-$tree/bin/python" "$D/gbprof.py" \
                    "$D/$tree/examples/benchmarks" gbsa "$steps" $drop > "$out/$tag.txt" 2>&1 || echo "failed: $tag" >> "$out/loads.txt"
                python3 "$D/gbprof-summary.py" "$steps" "$out/$tag.rec" >> "$out/$tag.txt"
            done
        done
    done
    r=$((r+1))
done
echo "$out"

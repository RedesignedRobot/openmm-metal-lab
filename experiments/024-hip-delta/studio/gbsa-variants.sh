#!/bin/sh
# Runs on the Studio under the lease: GPUPROF=buffers records of gbsa for several variants,
# interleaved and reversing order each round. A variant is label=tree or label=tree:VAR=value,...
# TEST picks another benchmark.py test (default gbsa). GPUPROF=off runs without records, for timing alone.
# usage: [TEST=...] [GPUPROF=off] gbsa-variants.sh <out dir> <rounds> <steps> <system: full|gbonly> <variant>...
set -eu
D=/tmp/openmm-metal-bench/gbsa-gap
out="$1"; rounds="$2"; steps="$3"; system="$4"; shift 4
mkdir -p "$out"
export PYTHONPATH=$D/pydeps
drop=""
[ "$system" = gbonly ] && drop=NonbondedForce
test="${TEST:-gbsa}"
mode="${GPUPROF:-buffers}"
unset GPUPROF
variants="$*"
reversed="$(echo $variants | tr ' ' '\n' | tail -r | tr '\n' ' ')"
r=1
while [ "$r" -le "$rounds" ]; do
    order="$variants"
    [ $((r % 2)) -eq 0 ] && order="$reversed"
    for variant in $order; do
        label="${variant%%=*}"; spec="${variant#*=}"; tree="${spec%%:*}"; settings=""
        [ "$spec" != "$tree" ] && settings="$(echo "${spec#*:}" | tr , ' ')"
        tag="$label-$test-$system-round$r"
        prof="GPUPROF=$mode GPUPROF_OUT=$out/$tag.rec"
        [ "$mode" = off ] && prof=""
        echo "$tag load $(sysctl -n vm.loadavg)" >> "$out/loads.txt"
        env $settings $prof "$D/venv-$tree/bin/python" "$D/gbprof.py" \
            "$D/$tree/examples/benchmarks" "$test" "$steps" $drop > "$out/$tag.txt" 2>&1 || echo "failed: $tag" >> "$out/loads.txt"
    done
    r=$((r+1))
done
echo "$out"

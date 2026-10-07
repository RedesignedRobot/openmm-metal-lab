#!/bin/sh
# One timing hold: shader timelines of apoa1rf and apoa1pme single on cw5 (tree ultra-r2-dispatch-cw5, 8a07008e8)
# and the verifier on it (tree v, 4ecc93191), for the verify cost per call and the list chain per step.
export SHADER_HELD=1
T=/tmp/openmm-metal-bench/ultra-tools
O=/tmp/openmm-metal-bench/ultra-r2-accum-nb/census2
for t in apoa1rf apoa1pme; do
    for x in cw5:/tmp/openmm-metal-bench/ultra-r2-dispatch-cw5 ver:/tmp/openmm-metal-bench/ultra-r2-accum-nb-v; do
        PRECISION=single $T/shader.sh $O ${x%%:*}-$t $t ${x#*:} 2 || echo "failed ${x%%:*} $t"
    done
done
echo "census2 done $(date -u +%H:%M:%SZ)"

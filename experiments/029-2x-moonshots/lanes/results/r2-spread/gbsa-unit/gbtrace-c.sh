#!/bin/sh
# gbsa gap map: single and mixed shader traces of trunk 5071882fa (ultra-r2-fah-trunk) and the fold candidate
# (ultra-r3-gbfold-c), in one timing hold, with the encoder-level GPU intervals for idle.
set -u
B=/tmp/openmm-metal-bench
if [ -z "${OPENMM_LEASE_PID:-}" ]; then
    exec $B/ultra-tools/lease.sh --cap 1200 r2-spread "gbsa gap map: trunk and fold, single and mixed shader traces, about 9 min" "$0" "$@"
fi
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
O=$B/ultra-r3-gbfold-c/trace
for arm in tr:$B/ultra-r2-fah-trunk c:$B/ultra-r3-gbfold-c; do
    name=${arm%%:*}; T=${arm#*:}
    for p in single mixed; do
        uptime >> $O/loads.txt
        SHADER_HELD=1 PRECISION=$p $B/ultra-tools/shader.sh $O $name-$p gbsa $T 2
        xcrun xctrace export --input $O/$name-$p.trace --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-gpu-intervals"]' > $O/$name-$p-metal-gpu-intervals.xml 2> $O/$name-$p-gpu.err
    done
done
$B/ultra-tools/xctemp.sh
echo "done $(date -u +%H:%M:%SZ)"

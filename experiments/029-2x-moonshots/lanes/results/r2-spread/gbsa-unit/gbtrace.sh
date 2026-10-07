#!/bin/sh
# r2-spread gbsa unit, step (1): host CPU per step (r2-dispatch's hostcpu.py), then gbsa single and mixed shader traces
# on ultra-day-trial3 (5d617bfc3) with the encoder-level metal-gpu-intervals, the command-buffer submission track and
# the trace's table of contents, all inside one hold, to attribute the per-step GPU idle.
set -u
B=/tmp/openmm-metal-bench
if [ -z "${OPENMM_LEASE_PID:-}" ]; then
    exec $B/ultra-tools/lease.sh r2-spread "gbsa hostcpu + single+mixed shader traces with encoder and CB tracks, trial3, about 7 min" "$0" "$@"
fi
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
T=$B/ultra-day-trial3
O=$B/ultra-r3-gbunit/trace
for p in single mixed; do
    $T/venv/bin/python $B/ultra-r2-dispatch/rf/overflow/hostcpu.py $B/ultra-base/benchmarks gbsa $p >> $O/hostcpu.txt 2>&1
done
for p in single mixed; do
    uptime >> $O/loads.txt
    SHADER_HELD=1 PRECISION=$p $B/ultra-tools/shader.sh $O $p gbsa $T 2
    xcrun xctrace export --input $O/$p.trace --toc > $O/$p-toc.xml 2> $O/$p-toc.err
    for s in metal-gpu-intervals metal-application-command-buffer-submissions metal-application-encoders-list; do
        xcrun xctrace export --input $O/$p.trace --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$s\"]" > $O/$p-$s.xml 2> $O/$p-$s.err
    done
done
$B/ultra-tools/xctemp.sh
echo "done $(date -u +%H:%M:%SZ)"

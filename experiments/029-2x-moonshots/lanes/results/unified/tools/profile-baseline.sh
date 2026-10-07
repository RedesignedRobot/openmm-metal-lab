#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-unified
B=/tmp/openmm-metal-bench/ultra-int028
T=/tmp/openmm-metal-bench/ultra-tools
test -f /tmp/openmm-metal-bench/READY
if [ "${1:-}" != --held ]; then
    exec "$T/lease.sh" --cap 900 ultra-m29-unified 'Bet 2 baseline shader costs' "$0" --held
fi
mkdir -p "$D/profile-baseline"
for test in pme apoa1pme amber20-dhfr; do
    for precision in single mixed; do
        tag="$test-$precision"
        PROF_SECONDS=0.01 "$B/venv/bin/python" "$D/tools/prof.py" /tmp/openmm-metal-bench/ultra-base/benchmarks "$test" "$precision" Metal > "$D/profile-baseline/$tag-smoke.txt" 2>&1
        PRECISION=$precision "$D/tools/shader.sh" "$D/profile-baseline" "$tag" "$test" "$B" 1
        pid=$(cat "$D/profile-baseline/$tag.pypid")
        "$B/venv/bin/python" "$D/tools/kernsum.py" "$D/profile-baseline/$tag-intervals.xml" "$pid" "$D/profile-baseline/$tag-intervals.xml" "$pid" > "$D/profile-baseline/$tag-kernels.txt"
    done
done
echo 'BASELINE PROFILES COMPLETE'

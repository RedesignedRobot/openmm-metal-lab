#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-unified
B=/tmp/openmm-metal-bench/ultra-m29-unified
T=/tmp/openmm-metal-bench/ultra-tools
test -f /tmp/openmm-metal-bench/READY
if [ "${1:-}" != --held ]; then
    exec "$T/lease.sh" --cap 900 ultra-m29-unified 'Bet 2 candidate shader costs' "$0" --held
fi
mkdir -p "$D/profile-candidate"
"$D/tools/cpu-fft-cost" > "$D/profile-candidate/cpu-fft-cost.txt"
for test in pme apoa1pme; do
    for precision in single; do
        tag="$test-$precision"
        PROF_SECONDS=0.01 "$B/venv/bin/python" "$D/tools/prof.py" /tmp/openmm-metal-bench/ultra-base/benchmarks "$test" "$precision" Metal > "$D/profile-candidate/$tag-smoke.txt" 2>&1
        PRECISION=$precision "$D/tools/shader.sh" "$D/profile-candidate" "$tag" "$test" "$B" 1
        pid=$(cat "$D/profile-candidate/$tag.pypid")
        "$B/venv/bin/python" "$D/tools/kernsum.py" "$D/profile-candidate/$tag-intervals.xml" "$pid" "$D/profile-candidate/$tag-intervals.xml" "$pid" > "$D/profile-candidate/$tag-kernels.txt"
    done
done
echo 'CANDIDATE PROFILES COMPLETE'

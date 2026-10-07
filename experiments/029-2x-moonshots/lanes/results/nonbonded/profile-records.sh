#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench
lane=$root/ultra-m29-nonbonded
out=$lane/records-profile-cellulose
if [ "${1:-}" != --held ]; then
 exec "$root/ultra-tools/lease.sh" ultra-m29-nonbonded 'cellulose record accumulation sampled shader comparison' "$0" --held
fi
# Both captures, trace saving and XML exports remain inside this outer lease.
export SHADER_HELD=1
"$root/ultra-tools/shader.sh" "$out" maxbits amber20-cellulose "$lane" 1
"$root/ultra-tools/shader.sh" "$out" records amber20-cellulose "$root/ultra-m29-nonbonded-records" 1 maxbits
"$root/env/bin/python" "$root/ultra-tools/kernsum.py" "$out/maxbits-intervals.xml" "$(cat "$out/maxbits.pypid")" "$out/records-intervals.xml" "$(cat "$out/records.pypid")" > "$out/kernels.txt"
printf 'PASS sampled shader comparison; host ab.sh timing remains the verdict\n' > "$lane/records-profile.verdict"

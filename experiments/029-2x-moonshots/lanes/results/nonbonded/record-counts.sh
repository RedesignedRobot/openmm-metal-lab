#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench
lane=$root/ultra-m29-nonbonded
if [ "${1:-}" != --held ]; then
 exec "$root/ultra-tools/lease.sh" --correctness ultra-m29-nonbonded 'live record tile counts, unchanged kernels' "$0" --held
fi
"$root/env/bin/python" "$lane/compile-record-counts.py"
"$root/ultra-m29-nonbonded-records/venv/bin/python" "$lane/record-counts.py" "$root/ultra-base/benchmarks" > "$lane/record-counts.jsonl"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer /usr/bin/xcrun swift "$lane/record-allocated-memory.swift" "$lane/device-memory-records.json" > "$lane/record-allocated-memory.json"
printf 'PASS live tile counts and allocation query\n' > "$lane/record-counts.verdict"

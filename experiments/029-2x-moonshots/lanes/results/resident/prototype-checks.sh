#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench/ultra-m29-resident
proto=/tmp/openmm-metal-bench/ultra-m29-resident-prototype
tools=/tmp/openmm-metal-bench/ultra-tools
bench=/tmp/openmm-metal-bench/ultra-base/benchmarks
for precision in single mixed; do
    "$proto/venv/bin/python" "$root/smoke.py" "$bench" Metal "$precision" > "$root/smoke-prototype-$precision.out" 2>&1
    cat "$root/smoke-prototype-$precision.out"
done
ctest --test-dir "$proto/build" -R '^TestMetalCommandBatchingSingle$' --output-on-failure > "$root/command-batching.out" 2>&1
cat "$root/command-batching.out"
"$proto/venv/bin/python" "$tools/forces.py" --md 100 "$bench" "$root/forces-md100.txt" /tmp/openmm-metal-bench/ultra-base/forces-md100.txt > "$root/forces-md100.out" 2>&1
cat "$root/forces-md100.out"
"$proto/venv/bin/python" "$tools/detforces.py" "$bench" "$root/detforces.txt" > "$root/detforces.out" 2>&1
cat "$root/detforces.out"
echo PROTOTYPE_CORRECTNESS_BUNDLE_PASS

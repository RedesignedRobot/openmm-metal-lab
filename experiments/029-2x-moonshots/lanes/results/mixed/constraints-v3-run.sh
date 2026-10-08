#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-mixed
T=/tmp/openmm-metal-bench/ultra-tools
B=/tmp/openmm-metal-bench/ultra-int028
V=/tmp/openmm-metal-bench/ultra-m29-mixed-v3
O="$D/constraints-v3"
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
unset PYTHONPATH OPENMM_PLUGIN_DIR
mkdir -p "$O"
for arm in base mine; do
    if [ "$arm" = base ]; then tree="$B"; else tree="$V"; fi
    test -f "$tree/BUILT"
    test "$(sed -n 's/^src //p' "$tree/BUILT")" = "$("$T/srchash.sh" "$tree")"
    cp "$tree/BUILT" "$O/$arm.BUILT"
    for test in gbsa pme; do
        "$tree/venv/bin/python" "$D/constraints.py" "/tmp/openmm-metal-bench/ultra-base/benchmarks" "$test" mixed 1e-8 1000 > "$O/$arm-$test.json" 2> "$O/$arm-$test.err"
    done
done
echo CONSTRAINT_MEASUREMENTS_DONE > "$D/constraints-v3-verdict.txt"

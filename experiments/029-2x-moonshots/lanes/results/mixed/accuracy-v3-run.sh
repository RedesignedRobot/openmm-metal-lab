#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-mixed
T=/tmp/openmm-metal-bench/ultra-tools
B=/tmp/openmm-metal-bench/ultra-int028
V=/tmp/openmm-metal-bench/ultra-m29-mixed-v3
O="$D/accuracy-v3"
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
unset PYTHONPATH OPENMM_PLUGIN_DIR
mkdir -p "$O"
for tree in "$B" "$V"; do
    test -f "$tree/BUILT"
    test "$(sed -n 's/^src //p' "$tree/BUILT")" = "$("$T/srchash.sh" "$tree")"
done
cp "$B/BUILT" "$O/base.BUILT"
cp "$V/BUILT" "$O/mine.BUILT"
for test in gbsa pme; do
    for seed in 1 2 3; do
        if [ "$seed" = 2 ]; then arms='mine base'; else arms='base mine'; fi
        for arm in $arms; do
            if [ "$arm" = base ]; then tree="$B"; else tree="$V"; fi
            "$tree/venv/bin/python" "$D/drift-eq.py" "/tmp/openmm-metal-bench/ultra-base/benchmarks" "$test" mixed 20 100 "$seed" 1e-8 > "$O/$arm-$test-s$seed.json" 2> "$O/$arm-$test-s$seed.err"
        done
    done
done
"$V/venv/bin/python" "$T/detforces.py" "/tmp/openmm-metal-bench/ultra-base/benchmarks" "$O/detforces.txt" > "$O/detforces.out" 2>&1
echo ACCURACY_MEASUREMENTS_DONE > "$D/accuracy-v3-verdict.txt"

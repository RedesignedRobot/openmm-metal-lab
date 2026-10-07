#!/bin/sh
# Runs on the M3 Ultra under lease.sh --correctness: reruns the gate failures on ultra-plugins,
# the generalized Kirkwood candidate and ultra-base, three times each.
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing to run at nice $(ps -o nice= -p $$)"; exit 1; }
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
L=/tmp/openmm-metal-bench/ultra-plugins
B=/tmp/openmm-metal-bench/ultra-base
for i in 1 2 3; do
    echo "== round $i plugins $(date -u +%H:%M:%SZ)"
    ctest --test-dir $L/build -R '^(TestMetalGayBerneForceSingle|TestMetalLangevinMiddleIntegratorSingle|TestMetalAmoebaGeneralizedKirkwoodForceSingle|TestOpenCLAmoebaGeneralizedKirkwoodForceSingle)$' --timeout 300 --output-on-failure 2>&1 | grep -E "Test +#|exception|norms|No tests|rror"
    echo "== round $i cand"
    ctest --test-dir $L/cand/build -R '^TestMetalAmoebaGeneralizedKirkwoodForceSingle$' --timeout 300 --output-on-failure 2>&1 | grep -E "Test +#|exception|norms|No tests|rror"
    echo "== round $i base"
    ctest --test-dir $B/build -R '^(TestMetalGayBerneForceSingle|TestMetalLangevinMiddleIntegratorSingle|TestOpenCLAmoebaGeneralizedKirkwoodForceSingle)$' --timeout 300 --output-on-failure 2>&1 | grep -E "Test +#|exception|norms|No tests|rror"
done
echo "rerun2 done $(date -u +%H:%M:%SZ)"

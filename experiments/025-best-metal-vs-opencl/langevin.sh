#!/bin/sh
# Runs on the mini: TestMetalLangevinIntegrator in mixed precision 5 times in each of the two
# existing 024 build dirs, interleaved. Prints each run's exit code and its assertion line.
# usage: langevin.sh
for i in 1 2 3 4 5; do
    for tree in hipdelta hipdelta-ref; do
        msg="$(cd "$HOME/lab/$tree/build/platforms/metal/tests" && "$HOME/lab/$tree/build/TestMetalLangevinIntegrator" mixed 2>&1)"
        code=$?
        echo "$(date -u +%H:%M:%SZ) $tree run $i exit $code $(echo "$msg" | grep -E "exception|Assertion" | head -1)"
    done
done

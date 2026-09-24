#!/bin/sh
# Runs on the mini under the lease, after build.sh on ~/lab/fast: Metal ctest Single+Mixed, 5 reruns
# of each failed test on this tree and on ~/lab/hipdelta-ref (`metal` 052eaa85b), forces against
# Reference, and 5 repeats of TestMetalMonteCarloFlexibleBarostat single.
# usage: gates.sh
fast="$HOME/lab/fast"
out="$fast/out"
mkdir -p "$out"
(cd "$fast/build" && ctest -R TestMetal -j2 --timeout 600 > "$out/ctest.txt" 2>&1)
grep -E "tests passed|tests failed" "$out/ctest.txt"
for name in $(sed -n 's/^.*[0-9]* - \(TestMetal[A-Za-z]*\) (.*$/\1/p' "$out/ctest.txt"); do
    binary="${name%Single}"
    binary="${binary%Mixed}"
    case "$name" in
        *Mixed) precision=mixed ;;
        *) precision=single ;;
    esac
    for i in 1 2 3 4 5; do
        for tree in fast hipdelta-ref; do
            build="$HOME/lab/$tree/build"
            msg="$(cd "$build/platforms/metal/tests" && "$build/$binary" $precision 2>&1)"
            echo "$name $tree run $i exit $? $(echo "$msg" | grep -E "exception|Assertion" | head -1)"
        done
    done
done > "$out/reruns.txt"
cat "$out/reruns.txt"
"$fast/venv/bin/python" "$fast/tools/forces.py" "$fast/src/examples/benchmarks" > "$out/forces-single.txt" 2>&1
cat "$out/forces-single.txt"
"$fast/venv/bin/python" "$fast/tools/forces.py" "$fast/src/examples/benchmarks" gbsa,rf,pme,apoa1rf,apoa1pme,apoa1ljpme mixed > "$out/forces-mixed.txt" 2>&1
cat "$out/forces-mixed.txt"
for i in 1 2 3 4 5; do
    msg="$(cd "$fast/build/platforms/metal/tests" && "$fast/build/TestMetalMonteCarloFlexibleBarostat" single 2>&1)"
    echo "fast run $i exit $? $(echo "$msg" | grep -E "exception|Assertion" | head -1)"
done > "$out/flexible.txt"
cat "$out/flexible.txt"

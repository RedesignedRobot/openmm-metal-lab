#!/bin/sh
# Runs on the mini inside ~/lab/hipdelta: install, then ctest, forces against Reference, the
# FlexibleBarostat repeat check on both builds, and the interleaved benchmark.
# usage: final.sh <label>
label="$1"
out="$HOME/lab/024-hip-delta"
sh "$out/install.sh" || exit 1
(cd build && ctest -R TestMetal -j2 --timeout 600 > "$out/ctest-$label.txt" 2>&1)
tail -3 "$out/ctest-$label.txt"
build/venv/bin/python "$out/forces.py" examples/benchmarks > "$out/forces-$label.txt" 2>&1
cat "$out/forces-$label.txt"
for tree in hipdelta hipdelta-ref; do
    for i in 1 2 3 4 5; do
        (cd "$HOME/lab/$tree/build" && ./TestMetalMonteCarloFlexibleBarostat single > /dev/null 2>&1; echo "$tree run $i exit $?")
    done
done > "$out/flexible-$label.txt"
cat "$out/flexible-$label.txt"
sh "$out/bench.sh" 3 30 gbsa,rf,pme,apoa1rf,apoa1pme,apoa1ljpme

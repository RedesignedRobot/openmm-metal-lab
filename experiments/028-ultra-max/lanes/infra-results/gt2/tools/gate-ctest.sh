#!/bin/sh
# Called by gate.sh under one lease hold: ctest at -j2 on the tests listed in <out>/tests-<part>.txt,
# then, one at a time, reruns of each failure. A statistical test (in STOCHASTIC, or its failure
# output says "This test is stochastic", OpenMM's own marker) reruns up to 3 times and passes if a
# rerun passes. Any other failure fails, and one rerun alone records whether it also fails without a
# second test process on the GPU. Verdicts go to <out>/verdict-<part>.txt, one per line, starting with
# "ok" or "FAIL", and the last line is "done part <part>".
# usage: gate-ctest.sh <dir> <out> <part>
set -eu
STOCHASTIC='^TestMetal(MonteCarloFlexibleBarostat|MonteCarloAnisotropicBarostat|MonteCarloBarostat|LangevinIntegrator|LangevinMiddleIntegrator|VariableLangevinIntegrator|CustomIntegrator)(Single|Mixed)$'
RERUNS=3
[ $# -eq 3 ] || { echo "usage: gate-ctest.sh <dir> <out> <part>" >&2; exit 2; }
dir="$1"
out="$2"
part="$3"
log="$out/ctest-$part.txt"
verdicts="$out/verdict-$part.txt"
: > "$verdicts"
ctest --test-dir "$dir/build" --tests-from-file "$out/tests-$part.txt" -j2 --timeout 600 --output-on-failure > "$log" 2>&1 || true
ran="$(sed -n 's/.*tests passed, .* out of \([0-9]*\)$/\1/p' "$log")"
expected="$(wc -l < "$out/tests-$part.txt" | tr -d ' ')"
[ "$ran" = "$expected" ] || echo "FAIL part $part: ctest finished ${ran:-no} of $expected tests, see $log" >> "$verdicts"
# output_of <name>: the lines ctest printed after the test's failed result line, up to the next test's line.
output_of() {
    awk -v t="$1" 'p && /(Start +[0-9]+:|Test +#[0-9]+:)/ { exit } p { print } $0 ~ ("Test +#[0-9]+: " t " .*[*][*][*]") { p = 1 }' "$log"
}
# rerun <attempt>: runs test $name alone.
rerun() {
    ctest --test-dir "$dir/build" -R "^$name\$" --timeout 600 --output-on-failure > "$out/rerun-$name-$1.txt" 2>&1
}
for name in $(sed -n '/The following tests FAILED/,$ s/^[[:space:]]*[0-9]* - \([A-Za-z0-9_]*\) (.*$/\1/p' "$log"); do
    if ! echo "$name" | grep -qE "$STOCHASTIC" && ! output_of "$name" | grep -q "This test is stochastic"; then
        alone="fails alone too"
        rerun alone && alone="passes alone"
        echo "FAIL $name failed in the -j2 run, not a statistical test ($alone)" >> "$verdicts"
        continue
    fi
    attempt=1
    while [ $attempt -le $RERUNS ] && ! rerun $attempt; do
        attempt=$((attempt+1))
    done
    if [ $attempt -le $RERUNS ]; then
        echo "ok $name failed in the -j2 run, pass on rerun $attempt/$RERUNS" >> "$verdicts"
    else
        echo "FAIL $name failed in the -j2 run, fail on $RERUNS/$RERUNS reruns" >> "$verdicts"
    fi
done
echo "done part $part" >> "$verdicts"

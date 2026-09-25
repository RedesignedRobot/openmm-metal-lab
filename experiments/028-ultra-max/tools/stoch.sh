#!/bin/sh
# Runs on the M3 Ultra at nice 0: failure counts of statistical tests over repeated runs, for a
# candidate that changes integrators, barostats, random numbers or their reductions, against base.
# Each repetition runs `ctest -R <regex> -j2` once on every dir, in one lease hold (--correctness),
# order reversed every other repetition, so all dirs see the same conditions. Keep one repetition
# well under 20 minutes: the barostat tests take 30 to 130 s each. Logs go to <outdir>; the table of
# failures per test and dir goes to <outdir>/counts.txt.
#   /bin/sh -c 'nohup /tmp/openmm-metal-bench/ultra-tools/stoch.sh /tmp/openmm-metal-bench/ultra-integrated/stoch1 10 "LangevinMiddle" /tmp/openmm-metal-bench/ultra-base /tmp/openmm-metal-bench/ultra-integrated > /tmp/openmm-metal-bench/ultra-integrated/stoch1.out 2>&1 < /dev/null &'
# usage: stoch.sh <outdir> <runs> <ctest regex> <dir>...
set -eu
TOOLS=/tmp/openmm-metal-bench/ultra-tools
export PATH=/tmp/openmm-metal-bench/env/bin:$PATH
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
unset PYTHONPATH
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
[ "$nice_value" = 0 ] || { echo "running at nice $nice_value, not 0: launch through /bin/sh -c 'nohup ...'" >&2; exit 2; }
[ $# -ge 4 ] || { echo "usage: stoch.sh <outdir> <runs> <ctest regex> <dir>..." >&2; exit 2; }
case "$1" in /*) out="${1%/}" ;; *) echo "the outdir must be an absolute path" >&2; exit 2 ;; esac
runs="$2"
regex="$3"
shift 3
mkdir -p "$out"
[ -z "$(ls -A "$out")" ] || { echo "$out is not empty; use a new outdir" >&2; exit 2; }
for dir in "$@"; do
    [ -f "$dir/BUILT" ] || { echo "$dir/BUILT is missing" >&2; exit 2; }
    [ "$(sed -n 's/^src //p' "$dir/BUILT")" = "$("$TOOLS/srchash.sh" "$dir")" ] || { echo "$dir/src changed after build.sh" >&2; exit 2; }
    echo "$dir $(tr '\n' ' ' < "$dir/BUILT")" >> "$out/configs.txt"
done
cat "$out/configs.txt"
lane="$(echo "$out" | sed -n 's|^/tmp/openmm-metal-bench/\(ultra-[^/]*\)/.*|\1|p')"
reversed="$(printf '%s\n' "$@" | tail -r | tr '\n' ' ')"
r=1
while [ $r -le "$runs" ]; do
    order="$*"
    [ $((r % 2)) -eq 0 ] && order="$reversed"
    # One hold per repetition; the inner sh runs ctest on each dir in turn.
    "$TOOLS/lease.sh" --correctness "${lane:-unknown}" "stoch.sh $out run $r/$runs" /bin/sh -c '
        out="$1"; r="$2"; regex="$3"; shift 3
        for dir in "$@"; do
            ctest --test-dir "$dir/build" -R "$regex" -j2 --timeout 600 --output-on-failure > "$out/$(basename "$dir")-run$r.txt" 2>&1 || true
        done' sh "$out" "$r" "$regex" $order || echo "run $r ended with exit $?"
    r=$((r+1))
done
{
    echo "failures over $runs runs of ctest -R '$regex' -j2"
    for dir in "$@"; do
        name="$(basename "$dir")"
        finished="$(cat "$out/$name"-run*.txt | grep -c 'tests passed.* out of' || true)"
        echo "$name: $finished of $runs runs finished"
        cat "$out/$name"-run*.txt | sed -n 's/^.*Test *#[0-9]*: \([A-Za-z0-9_]*\) .*\*\*\*.*$/\1/p' | sort | uniq -c | sed 's/^/  /'
    done
} | tee "$out/counts.txt"

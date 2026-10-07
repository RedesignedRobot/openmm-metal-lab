#!/bin/sh
# Runs on the M3 Ultra under the lease: finds the counter profile that records the performance limiters and keeps
# that one trace, with the shader timeline on so each counter sample can be put on a kernel.
# usage: limiter.sh <out dir> <test> <build dir> <counter profile>...
# Each profile's template comes from countertemplate.py (tmpl/mst-cp<profile>.tracetemplate). For each profile in
# order, shader.sh captures a 1 s prof.py run (save and shader-interval export inside the hold), then gpu-counter-info
# is exported. The first profile whose counters include "ALU Limiter" also gets metal-gpu-counter-intervals exported,
# and the script stops there. Every export runs before the script returns, so all of it stays inside the hold.
set -u
D=/tmp/openmm-metal-bench/ultra-profiler
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
XCTRACE=$(xcrun --find xctrace)
out="$1"; test="$2"; dir="$3"; shift 3

export_table() {  # <tag> <schema> <file suffix>
    "$XCTRACE" export --input "$out/$1.trace" \
        --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$2\"]" > "$out/$1-$3.xml" 2> "$out/$1-$3.err"
}

for p in "$@"; do
    tag="$test-cp$p"
    TEMPLATE=$D/tmpl/mst-cp$p.tracetemplate "$D/tools/shader.sh" "$out" "$tag" "$test" "$dir" 1 || continue
    export_table "$tag" gpu-counter-info counterinfo || { echo "cp$p: gpu-counter-info export failed"; continue; }
    echo "cp$p: $(grep -o "<row" "$out/$tag-counterinfo.xml" | wc -l | tr -d " ") counters, shader rows $(cat "$out/$tag.rows")"
    grep -q 'fmt="ALU Limiter"' "$out/$tag-counterinfo.xml" || continue
    export_table "$tag" metal-gpu-counter-intervals counters || { echo "cp$p: counter export failed"; exit 1; }
    echo "limiters at counter profile $p: $tag, $(date -u +%H:%M:%SZ)"
    exit 0
done
echo "no counter profile in $* recorded ALU Limiter"
exit 1

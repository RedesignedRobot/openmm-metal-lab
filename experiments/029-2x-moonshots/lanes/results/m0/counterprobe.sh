#!/bin/sh
# M0(2) fallback, one timing hold: which xctrace counter profile records occupancy and L1 counters on the M3 Ultra.
# For each template from countertmpl.py (GPU counterdevice set to this GPU, profile N, shader timeline on), shader.sh
# records a 1 s apoa1rf single run on ultra-r1 and exports its shader timeline. Then, still inside the hold, this
# exports the TOC, gpu-counter-info and metal-gpu-counter-intervals; the analysis runs after the hold. Every xctrace export runs under a 120 s alarm, and no new profile starts past BUDGET seconds.
# The 16:34Z probe (shader timeline on, profiles 0-7) recorded only counter 0, RT Unit Active, in every profile even
# though each TOC named its set; tags ending -noshader test whether the shader timeline is what blocks the others.
# usage: lease.sh r2-infra "..." counterprobe.sh <profile tags, e.g. cp1 cp2 ...>
set -u
M=/tmp/openmm-metal-bench/ultra-infra/m0
out=$M/cprobe
tree=/tmp/openmm-metal-bench/ultra-r1
BUDGET=840
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer SHADER_HELD=1 PRECISION=single PLATFORM=Metal
alarm() { perl -e '$t = shift; alarm $t; exec @ARGV' "$@"; }
utc() { date -u +%H:%M:%SZ; }
start=$(date +%s)
mkdir -p "$out"
for tag in "$@"; do
    [ $(( $(date +%s) - start )) -le $BUDGET ] || { echo "$tag: skipped, hold past $BUDGET s $(utc)"; continue; }
    TEMPLATE=$M/tmpl/$tag.tracetemplate /tmp/openmm-metal-bench/ultra-tools/shader.sh "$out" "$tag" apoa1rf "$tree" 1 || echo "$tag: shader.sh failed"
    [ -d "$out/$tag.trace" ] || { echo "$tag: no trace $(utc)"; continue; }
    alarm 120 xcrun xctrace export --input "$out/$tag.trace" --toc > "$out/$tag-toc.xml" 2>&1
    alarm 120 xcrun xctrace export --input "$out/$tag.trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="gpu-counter-info"]' > "$out/$tag-info.xml" 2>&1
    set_line=$(grep -o "Counter Set: [^<]*" "$out/$tag-toc.xml" | head -1)
    alarm 120 xcrun xctrace export --input "$out/$tag.trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="metal-gpu-counter-intervals"]' > "$out/$tag-counters.xml" 2>&1
    names=$(grep -o '<gpu-counter-name id="[0-9]*" fmt="[^"]*"' "$out/$tag-counters.xml" | sort -u | wc -l | tr -d ' ')
    echo "$tag: $set_line, info rows $(grep -c '<row' "$out/$tag-info.xml"), counter rows $(grep -c '<row' "$out/$tag-counters.xml"), distinct counters $names $(utc)"
done
echo "probe done $(utc)"

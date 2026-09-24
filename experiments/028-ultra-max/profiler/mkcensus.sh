#!/bin/sh
# Runs on the laptop (no build, no GPU): the census patch for one candidate, for build-patch.sh on the M3 Ultra.
# usage: mkcensus.sh <candidate commit> <out patch>
# The patch takes the profiling tree (6df2b8bcb plus gpuprof.patch) to the candidate plus gpuprof.patch, over the files
# either side touches. If a gpuprof.patch hunk doesn't apply on the candidate, it stops and lists the .rej files to
# merge by hand. build-patch.sh rebuilds only the OpenMMMetal target, so a candidate that changes files outside
# platforms/metal and platforms/common is reported: it needs a full build instead.
set -e
repo=/Users/amir/code/mini/ultra-profiler
base=6df2b8bcb
lab=$(cd "$(dirname "$0")" && pwd)
commit="$1"; out="$2"
work=$(mktemp -d "${TMPDIR:-/tmp}/census.XXXXXX")
files=$( { git -C "$repo" diff --name-only $base "$commit"; grep '^+++ b/' "$lab/gpuprof.patch" | cut -c7-; } | sort -u)
outside=$(echo "$files" | grep -v -E '^platforms/(metal|common)/' || true)
[ -z "$outside" ] || echo "outside the Metal plugin, needs a full build: $outside"
for side in base cand; do
    rev=$base
    [ $side = cand ] && rev="$commit"
    for f in $files; do
        git -C "$repo" cat-file -e "$rev:$f" 2>/dev/null || continue
        mkdir -p "$work/$side/$(dirname "$f")"
        git -C "$repo" show "$rev:$f" > "$work/$side/$f"
    done
    (cd "$work/$side" && patch -p1 -s < "$lab/gpuprof.patch") || { echo "gpuprof.patch fails on $side ($rev):"; find "$work/$side" -name '*.rej'; exit 1; }
done
(cd "$work" && diff -ruN -x '*.orig' base cand > "$out") || [ $? = 1 ]
echo "$out: $(grep -c '^+++ ' "$out") files, $(grep -c '^[+-][^+-]' "$out") changed lines, work tree $work"

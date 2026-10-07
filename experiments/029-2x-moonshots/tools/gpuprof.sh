#!/bin/sh
# Per-kernel GPU time per step on any lane's tree, through GpuProf.h (lab-only, never for trunk).
#
#   gpuprof.sh build <worktree> <name>
#       Syncs the worktree into /tmp/openmm-metal-bench/ultra-gpuprof-<name>, applies gpuprof.patch there and runs
#       build.sh on it (a gpuq build job). The worktree is never touched. Every sync restores the unpatched files
#       (sync.py rsyncs with --delete and checksums), so the patch applies again on each build. A lane whose edits
#       overlap the patch's hunks gets patch's rejects and no build.
#   gpuprof.sh run <name> <outdir> <precision> <target> [target ...]
#       For each target, a benchmark.py test (pme, rf, ...) or a FAH unit dir, runs prof.py once per mode
#       (buffers, split, counters: see GpuProf.h), then profsum.py into <outdir>/<target>-<precision>.sum.
#       Submit it as a gpuq job; by day it is a screen, not a 3x30 number. PROF_SECONDS sets the window length.
#       Record files are gzipped after the summary.
#
# The patch is `git diff 5071882fa lab/gpuprof` in the openmm-metal repo (branch lab/gpuprof, pushed to private).
set -eu
here=$(cd "$(dirname "$0")" && pwd)
bench=/tmp/openmm-metal-bench
usage() { sed -n '3,13p' "$0" >&2; exit 2; }
[ $# -ge 1 ] || usage
command=$1
shift
case $command in
build)
    [ $# -eq 2 ] || usage
    dir=$bench/ultra-gpuprof-$2
    "$here/sync.sh" "$1" "$dir"
    patch -p1 -d "$dir/src" --forward --no-backup-if-mismatch < "$here/gpuprof.patch"
    exec "$here/build.sh" "$dir"
    ;;
run)
    [ $# -ge 4 ] || usage
    dir=$bench/ultra-gpuprof-$1 outdir=$2 precision=$3
    shift 3
    [ -f "$dir/BUILT" ] || { echo "gpuprof.sh: $dir has no BUILT; run gpuprof.sh build first" >&2; exit 2; }
    grep -q gpuprof "$dir/src/platforms/metal/src/MetalQueue.cpp" || { echo "gpuprof.sh: $dir is not patched" >&2; exit 2; }
    for target in "$@"; do
        case $target in
        */*) [ -f "$target/system.xml" ] || [ -f "$target/system.xml.bz2" ] || { echo "gpuprof.sh: $target is not a FAH unit dir" >&2; exit 2; } ;;
        esac
    done
    [ -z "${GPUQ_PREFLIGHT:-}" ] || exit 0
    mkdir -p "$outdir"
    for target in "$@"; do
        tag=$(basename "$target")-$precision
        for mode in buffers split counters; do
            echo "$tag $mode load $(sysctl -n vm.loadavg) $(date -u +%H:%M:%SZ)" >> "$outdir/loads.txt"
            GPUPROF=$mode GPUPROF_OUT="$outdir/$tag-$mode.rec" "$dir/venv/bin/python" "$here/prof.py" \
                "$dir/src/examples/benchmarks" "$target" "$precision" Metal > "$outdir/$tag-$mode.txt" 2>&1 \
                || echo "failed: $tag $mode" >> "$outdir/loads.txt"
        done
        "$bench/env/bin/python3" "$here/profsum.py" "$outdir" "$tag" > "$outdir/$tag.sum" 2>&1 || true
        gzip -f "$outdir/$tag"-*.rec 2>/dev/null || true
        grep -E '^(validation|split price)' "$outdir/$tag.sum" || true
    done
    ;;
*) usage ;;
esac

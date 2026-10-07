#!/bin/sh
# CPU-platform drift controls outside the GPU lease (head approval 2026-09-27). OPENMM_PLUGIN_DIR is a temporary
# dir linking only the tree's CPU and PME plugins, so no Metal code loads; the caller starts this under `taskpolicy -b` (efficiency cores,
# lowest priority) and it runs 8 CPU threads. The NVE part runs in DRIFT_CHUNK_PS chunks (default 50 ps), and a
# chunk starts only between 07:00 and STOP_AT (HHMM UTC, default 2320) so the day slot ends before 23:50Z.
# Rerun the same command to resume: finished seeds are skipped, and a seed with a checkpoint picks up from it.
# usage: cpu-offlease.sh <tree> <constraint tolerance> <equil ps> <ns> <outdir> <seed>...
# Last line "CPU OFFLEASE DONE <done>/<asked>" or "CPU OFFLEASE STOPPED <time>".
set -u
tree="$1"; tol="$2"; equil="$3"; ns="$4"; outdir="$5"; shift 5
here="$(cd "$(dirname "$0")" && pwd)"
pdb=/tmp/openmm-metal-bench/ultra-base/benchmarks/5dfr_solv-cube_equil.pdb
OPENMM_PLUGIN_DIR="$(mktemp -d)"
trap 'rm -rf "$OPENMM_PLUGIN_DIR"' EXIT
ln -s "$tree/prefix/lib/plugins/libOpenMMCPU.dylib" "$tree/prefix/lib/plugins/libOpenMMPME.dylib" "$OPENMM_PLUGIN_DIR/"
export OPENMM_PLUGIN_DIR
export OPENMM_CPU_THREADS=8
export DRIFT_CHUNK_PS="${DRIFT_CHUNK_PS:-50}"
stop_at="${STOP_AT:-2320}"
unset PYTHONPATH
mkdir -p "$outdir"
cd /
asked=0; done_runs=0
for seed in "$@"; do
    asked=$((asked+1))
    out="$outdir/seed-$seed"
    failures=0
    while [ ! -f "$out.json" ] && [ "$failures" -lt 2 ]; do
        now=$(date -u +%H%M)
        if [ "$now" -lt 0700 ] || [ "$now" -ge "$stop_at" ]; then
            echo "CPU OFFLEASE STOPPED $(date -u +%H:%M:%SZ)"
            exit 0
        fi
        echo "$(date -u +%H:%M:%SZ) chunk seed $seed tol $tol"
        "$tree/venv/bin/python" "$here/dhfr-nve.py" "$pdb" CPU mixed "$seed" "$equil" "$ns" "$out" "$tol" \
            || failures=$((failures+1))
    done
    [ -f "$out.json" ] && done_runs=$((done_runs+1))
done
echo "CPU OFFLEASE DONE $done_runs/$asked $(date -u +%H:%M:%SZ)"

#!/bin/sh
# DHFR NVE drift runs (dhfr-nve.py), one --correctness lease ticket per run, one run at a time, so other
# lanes' tickets interleave between runs. A seed whose <outdir>/seed-<seed>.json exists is skipped, so a
# restart resumes. A run the lease cap kills leaves no json; it is logged and the loop moves on.
# With DRIFT_CHUNK_PS set, dhfr-nve.py runs the NVE part in chunks of that many ps, one ticket per chunk,
# and the loop requeues the seed until its json exists (at most one try per chunk plus one).
# usage: [DRIFT_TOL=<constraint tolerance>] [DRIFT_PLATFORM=Metal|CPU] [DRIFT_CHUNK_PS=<ps>] run.sh <tree> <precision> <equil ps> <ns> <outdir> <seed>...
# DRIFT_TOL defaults to 1e-5, the protocol value; DRIFT_PLATFORM defaults to Metal.
# Last line "DRIFT RUN DONE <precision> <done>/<asked>".
set -u
tree="$1"; precision="$2"; equil="$3"; ns="$4"; outdir="$5"; shift 5
here="$(cd "$(dirname "$0")" && pwd)"
pdb=/tmp/openmm-metal-bench/ultra-base/benchmarks/5dfr_solv-cube_equil.pdb
tol="${DRIFT_TOL:-1e-5}"
platform="${DRIFT_PLATFORM:-Metal}"
max_tries=1
if [ -n "${DRIFT_CHUNK_PS:-}" ]; then
    max_tries=$(awk -v ns="$ns" -v c="$DRIFT_CHUNK_PS" 'BEGIN { n = int(ns*1000/c); if (n*c < ns*1000) n++; print n+1 }')
fi
mkdir -p "$outdir"
unset PYTHONPATH
asked=0; done_runs=0
for seed in "$@"; do
    asked=$((asked+1))
    out="$outdir/seed-$seed"
    tries=0
    while [ ! -f "$out.json" ] && [ "$tries" -lt "$max_tries" ]; do
        tries=$((tries+1))
        echo "$(date -u +%H:%M:%SZ) queue $precision seed $seed try $tries"
        (cd / && /tmp/openmm-metal-bench/ultra-tools/lease.sh --correctness r2-drift \
            "drift dhfr nve $platform $precision tol $tol seed $seed ${ns} ns" \
            "$tree/venv/bin/python" "$here/dhfr-nve.py" "$pdb" "$platform" "$precision" "$seed" "$equil" "$ns" "$out" "$tol")
        echo "$(date -u +%H:%M:%SZ) exit $? $precision seed $seed"
    done
    [ -f "$out.json" ] && done_runs=$((done_runs+1))
done
echo "DRIFT RUN DONE $precision $done_runs/$asked $(date -u +%H:%M:%SZ)"

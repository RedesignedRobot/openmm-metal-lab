#!/bin/sh
# Rewrites ultra-base/forces-md100.txt as the per-row worst of md100 seeds 1-20 (forces.py --md 100
# --seed k, merged by md100-baseline.py), in two correctness tickets of 10 seeds, about 7 minutes each.
# The single-seed file is kept once as forces-md100-seed2026.txt and joins the merge, since gates run
# seed 2026 and base must pass its own gate seed. With "merge" it only redoes the merge.
#   ultra-tools/bg.sh <log> ultra-tools/md100-baseline.sh
set -eu
BASE=/tmp/openmm-metal-bench/ultra-base
TOOLS=/tmp/openmm-metal-bench/ultra-tools
out=$BASE/md100-seeds
if [ "${1:-}" = run ]; then
    cd "$BASE"
    for seed in $(seq "$2" "$3"); do
        venv/bin/python "$TOOLS/forces.py" --md 100 --seed "$seed" benchmarks "$out/seed-$seed.txt" > "$out/seed-$seed.log" 2>&1
    done
    exit 0
fi
mkdir -p "$out"
[ "${1:-}" = merge ] || "$TOOLS/lease.sh" --correctness --cap 1200 r2-infra "md100 baseline seeds 1-10" "$0" run 1 10
[ "${1:-}" = merge ] || "$TOOLS/lease.sh" --correctness --cap 1200 r2-infra "md100 baseline seeds 11-20" "$0" run 11 20
[ -f "$BASE/forces-md100-seed2026.txt" ] || cp "$BASE/forces-md100.txt" "$BASE/forces-md100-seed2026.txt"
"$BASE/../env/bin/python" "$TOOLS/md100-baseline.py" $(seq -f "$out/seed-%g.txt" 1 20) "$BASE/forces-md100-seed2026.txt" > "$BASE/.forces-md100.txt"
mv "$BASE/.forces-md100.txt" "$BASE/forces-md100.txt"
cat "$BASE/forces-md100.txt"

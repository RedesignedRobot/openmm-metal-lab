#!/bin/sh
# M2 table driver (r3-fah): three rounds of m2table.py, each under job.lock and the M2 GPU lease so other checks get
# the lock between rounds, then the summary. Launch from /bin/sh, not the zsh login shell: zsh runs background jobs
# at nice 5 and m2table.py refuses to time at any nice but 0.
# usage: m2table.sh <tree> <fresh out>
set -u
R=$HOME/lab/ultra-m2.noindex
tree=$1 out=$2
[ ! -e "$out" ] || { echo "refusing: $out exists"; exit 1; }
for r in 1 2 3; do
    /opt/homebrew/bin/python3 "$R/tools/locked.py" "$R/job.lock" "$R/tools/m2-lease.sh" --cap 3600 r3-fah \
        "r3-fah M2 table round $r" "$tree/venv/bin/python" "$R/r3-fah/m2table.py" "$tree" "$out" round "$r" \
        || { echo "ROUND $r FAILED"; exit 1; }
done
"$tree/venv/bin/python" "$R/r3-fah/m2table.py" "$tree" "$out" summary
echo "TABLE DONE $(date -u +%H:%M:%SZ)"

#!/bin/sh
# RECIP A/B on dhfr-implicit, Metal single: fast::divide (as the accuracy probe selects on the M2)
# against the correctly rounded divide. Needs a temporary build in which OPENMM_METAL_PRECISE_RECIP=1
# forces RECIP to (1.0f/(x)); unset, that build is HEAD. One job at a time, no build running.
# usage: abrecip.sh [label]. Results land in ~/lab/results-<label>-<stamp>/.
set -u
py="$HOME/lab/venv-metal/bin/python"
wus="$HOME/lab/fah-wu"
out="$HOME/lab/results-${1:-016e}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out"
# Clock for every timing below: host wall (time.perf_counter), whole steps, after warm-up.
{ uname -a; pmset -g therm; uptime; } > "$out/host.txt" 2>&1

fast() { "$py" "$@"; }
precise() { OPENMM_METAL_PRECISE_RECIP=1 "$py" "$@"; }
for variant in fast precise precise fast fast precise; do
    $variant "$HOME/lab/fahwu.py" "$wus/dhfr-implicit" Metal single 60 >> "$out/speed-$variant.jsonl" 2>> "$out/speed.err"
done

# Force accuracy at the start state and after 5000 steps, against Reference at the positions the
# GPU evaluated (samestate.py's rel_force_err_float_positions).
for variant in fast precise; do
    $variant "$HOME/lab/samestate.py" "$wus/dhfr-implicit" Metal single 0 5000 >> "$out/force-$variant.jsonl" 2>> "$out/force.err"
done
{ date -u; uptime; pmset -g therm; } >> "$out/host.txt" 2>&1
echo done > "$out/DONE"

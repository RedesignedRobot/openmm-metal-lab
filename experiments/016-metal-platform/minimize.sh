#!/bin/sh
# Minimize dhfr and nav from the work unit start state on Metal mixed (twice, to check it is
# deterministic), Metal single and CPU, all with the same tolerance. One job at a time, no build running.
# usage: minimize.sh [label]. Results land in ~/lab/results-<label>-<stamp>/.
set -u
# zsh runs background jobs at nice 5 (BG_NICE), which would slow the host side of every timing.
# Launch from sh instead: ssh <mini> 'sh -c "nohup sh ~/lab/minimize.sh <label> > ~/lab/minimize.sh.log 2>&1 &"'
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
if [ "$nice_value" != 0 ]; then
    echo "running at nice $nice_value, not 0; see the launch line above" >&2
    exit 1
fi
py="$HOME/lab/venv-metal/bin/python"
wus="$HOME/lab/fah-wu"
out="$HOME/lab/results-${1:-016h}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out"
# Clock for every timing below: host wall (time.perf_counter) around LocalEnergyMinimizer.minimize.
{ echo "nice $nice_value"; uname -a; sysctl -n machdep.cpu.brand_string; pmset -g therm; uptime; } > "$out/host.txt" 2>&1

for wu in dhfr nav; do
    for run in "Metal mixed" "Metal mixed" "Metal single" "CPU native"; do
        "$py" "$HOME/lab/minwu.py" "$wus/$wu" $run 10 >> "$out/minimize.jsonl" 2>> "$out/minimize.err"
    done
done
echo DONE >> "$out/minimize.jsonl"

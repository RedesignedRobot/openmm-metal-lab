#!/bin/sh
# Milestone B measurements on the mini, after the build is installed. One job at a time.
# usage: mini-b.sh [label]. Run under nohup; results land in ~/lab/results-<label>-<stamp>/.
set -u
# zsh runs background jobs at nice 5 (BG_NICE), which would slow the host side of every timing.
# Launch from sh instead: ssh <mini> 'sh -c "nohup sh ~/lab/mini-b.sh <label> > ~/lab/mini-b.sh.log 2>&1 &"'
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
if [ "$nice_value" != 0 ]; then
    echo "running at nice $nice_value, not 0; see the launch line above" >&2
    exit 1
fi
py="$HOME/lab/venv-metal/bin/python"
wus="$HOME/lab/fah-wu"
out="$HOME/lab/results-${1:-016b}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out"
cd "$HOME/lab/openmm-metal/build"
# Clock for every timing below: host wall (time.perf_counter), whole steps, after warm-up.
{ echo "nice $nice_value"; uname -a; sysctl -n machdep.cpu.brand_string; pmset -g therm; uptime; } > "$out/host.txt" 2>&1

ctest -R TestMetal --timeout 900 > "$out/ctest.txt" 2>&1
tail -40 "$out/ctest.txt" > "$out/ctest-summary.txt"

{ date -u; uptime; top -l 2 -o cpu -n 5 -stats command,cpu | tail -5; } >> "$out/host.txt" 2>&1
for wu in dhfr-implicit dhfr nav; do
    "$py" "$HOME/lab/fahwu.py" "$wus/$wu" Metal single 60 >> "$out/fah.jsonl" 2>> "$out/fah.err"
    "$py" "$HOME/lab/fahwu.py" "$wus/$wu" Metal mixed 60 >> "$out/fah.jsonl" 2>> "$out/fah.err"
    "$py" "$HOME/lab/fahwu.py" "$wus/$wu" OpenCL single 60 >> "$out/fah.jsonl" 2>> "$out/fah.err"
    "$py" "$HOME/lab/fahwu.py" "$wus/$wu" CPU native 60 >> "$out/fah.jsonl" 2>> "$out/fah.err"
done

{ date -u; uptime; top -l 2 -o cpu -n 5 -stats command,cpu | tail -5; } >> "$out/host.txt" 2>&1
for run in "Metal single" "Metal mixed" "CPU native"; do
    "$py" "$HOME/lab/nvedrift.py" "$wus/dhfr" $run 50000 250 >> "$out/drift.jsonl" 2>> "$out/drift.err"
done

# Forces against Reference after 5000 steps, and the programs the FAH path compiles in mixed.
for run in "dhfr-implicit Metal single" "dhfr-implicit Metal mixed" "dhfr-implicit OpenCL single" "dhfr Metal single"; do
    set -- $run
    "$py" "$HOME/lab/laterforce.py" "$wus/$1" "$2" "$3" 5000 >> "$out/later.jsonl" 2>> "$out/later.err"
done
"$py" "$HOME/lab/capture.py" "$wus" "$out/capture" > "$out/capture.txt" 2>&1
echo done > "$out/DONE"

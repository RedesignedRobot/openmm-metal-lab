#!/bin/sh
# Metal single vs OpenCL single speed, 3 interleaved repeats per WU, then the dhfr-implicit
# same-state force check. One job at a time, no build running.
# usage: repeats.sh [label]. Results land in ~/lab/results-<label>-<stamp>/.
set -u
# zsh runs background jobs at nice 5 (BG_NICE), which would slow the host side of every timing.
# Launch from sh instead: ssh <mini> 'sh -c "nohup sh ~/lab/repeats.sh <label> > ~/lab/repeats.sh.log 2>&1 &"'
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
if [ "$nice_value" != 0 ]; then
    echo "running at nice $nice_value, not 0; see the launch line above" >&2
    exit 1
fi
py="$HOME/lab/venv-metal/bin/python"
wus="$HOME/lab/fah-wu"
out="$HOME/lab/results-${1:-016d}-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out"
# Clock for every timing below: host wall (time.perf_counter), whole steps, after warm-up.
{ echo "nice $nice_value"; uname -a; sysctl -n machdep.cpu.brand_string; pmset -g therm; uptime; } > "$out/host.txt" 2>&1

# Alternate which platform goes first, so drift over the session (thermals, background load)
# doesn't favour one platform.
for rep in 1 2 3; do
    for wu in dhfr-implicit nav; do
        if [ $((rep % 2)) -eq 1 ]; then order="Metal OpenCL"; else order="OpenCL Metal"; fi
        for platform in $order; do
            "$py" "$HOME/lab/fahwu.py" "$wus/$wu" "$platform" single 60 >> "$out/speed.jsonl" 2>> "$out/speed.err"
        done
    done
done

{ date -u; uptime; pmset -g therm; } >> "$out/host.txt" 2>&1
"$py" "$HOME/lab/samestate.py" "$wus/dhfr-implicit" Metal mixed 5000 10000 20000 >> "$out/samestate.jsonl" 2>> "$out/samestate.err"
"$py" "$HOME/lab/samestate.py" "$wus/dhfr-implicit" Metal single 5000 10000 20000 >> "$out/samestate.jsonl" 2>> "$out/samestate.err"
echo done > "$out/DONE"

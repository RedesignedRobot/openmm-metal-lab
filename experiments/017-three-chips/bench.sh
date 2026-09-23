#!/bin/sh
# One harness for every chip: the same OpenMM build (openmm-metal f9347f6c5), the same FAHBench
# work units and the same order of runs, so the machines can be compared row for row.
# usage: bench.sh <python> <wu-dir> <build-dir> <out-dir>
#   <python>    interpreter whose `openmm` is the f9347f6c5 install (Metal, OpenCL, CPU, Reference)
#   <build-dir> the ctest build tree of that install; pass - to skip ctest
# Launch detached from sh, never from zsh with &: zsh runs background jobs at nice 5 (BG_NICE).
#   sh -c "nohup sh bench.sh ... > bench.log 2>&1 &"
set -u
py=$1 wus=$2 build=$3 out=$4
here=$(cd "$(dirname "$0")" && pwd)
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
if [ "$nice_value" != 0 ]; then
    echo "running at nice $nice_value, not 0; see the launch line above" >&2
    exit 1
fi
# Battery timings are allowed only on request (ALLOW_BATTERY=1); host.txt records the power source.
if pmset -g batt | grep -q "Battery Power" && [ "${ALLOW_BATTERY:-0}" != 1 ]; then
    echo "on battery power; plug in, or set ALLOW_BATTERY=1 to time on battery" >&2
    exit 1
fi
mkdir -p "$out"

snapshot() {
    { echo "== $(date -u +%Y-%m-%dT%H:%M:%SZ) $1"; uptime; pmset -g therm; pmset -g batt | head -1
      top -l 2 -o cpu -n 6 -stats command,cpu | tail -6; } >> "$out/host.txt" 2>&1
}
{ echo "nice $nice_value"; uname -a; sw_vers
  sysctl -n machdep.cpu.brand_string hw.memsize hw.ncpu
  system_profiler SPDisplaysDataType | grep -E "Chipset|Total Number of Cores|Metal"
  "$py" -c "import openmm as m; print('openmm', m.__version__, m.version.git_revision); print([m.Platform.getPlatform(i).getName() for i in range(m.Platform.getNumPlatforms())])"
} > "$out/host.txt" 2>&1

if [ "$build" != - ]; then
    snapshot ctest
    (cd "$build" && ctest -R TestMetal --timeout 1800 > "$out/ctest.txt" 2>&1)
    tail -40 "$out/ctest.txt" > "$out/ctest-summary.txt"
fi

# Clock for every timing: host wall (time.perf_counter), whole steps, 60 s after a 200-step warm-up.
# Three rounds; each round rotates which configuration goes first, so drift over the session
# (thermals, background load) spreads across configurations instead of favouring one.
configs="Metal:single Metal:mixed OpenCL:single CPU:native"
for rep in 1 2 3; do
    snapshot "fah round $rep"
    order=$(echo $configs | tr ' ' '\n' | awk -v r=$rep '{a[NR]=$0} END {for (i=0;i<NR;i++) print a[(i+r-1)%NR+1]}')
    for wu in dhfr-implicit dhfr nav; do
        for c in $order; do
            "$py" "$here/fahwu.py" "$wus/$wu" "${c%%:*}" "${c#*:}" 60 >> "$out/fah.jsonl" 2>> "$out/fah.err"
        done
    done
done

# NVE drift: dhfr with the work unit's own Verlet integrator, 50k steps (0.1 ns), sampled every 250.
snapshot drift
for c in "Metal single" "Metal mixed" "CPU native"; do
    "$py" "$here/nvedrift.py" "$wus/dhfr" $c 50000 250 >> "$out/drift.jsonl" 2>> "$out/drift.err"
done
snapshot end
echo done > "$out/DONE"

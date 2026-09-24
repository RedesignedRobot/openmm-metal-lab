#!/bin/sh
# Runs on the Studio at nice 0 after run.sh, holding /tmp/openmm-lease: the OpenCL fp64 device query,
# then amber20-stmv with the same ab.sh protocol and configurations as run.sh's rounds.
# Launch detached from sh, never from zsh with &: zsh runs background jobs at nice 5 (BG_NICE).
#   /bin/sh -c "nohup sh run2.sh > logs/run2.out 2>&1 < /dev/null &"
set -eu
D=/tmp/openmm-metal-bench/m3ab
LEASE=/tmp/openmm-lease
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
if [ "$nice_value" != 0 ]; then
    echo "running at nice $nice_value, not 0; see the launch line above" >&2
    exit 1
fi
cd "$D"
step() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $* load $(sysctl -n vm.loadavg)" >> "$D/logs/progress.txt"; }
until mkdir "$LEASE" 2>/dev/null; do
    step "lease held by: $(cat $LEASE/owner 2>/dev/null)"
    sleep 30
done
echo "m3ab (team-lead's M3 Ultra Metal vs OpenCL agent) $(date -u +%Y-%m-%dT%H:%MZ) OpenCL fp64 query, amber20-stmv in $D" > "$LEASE/owner"
trap 'rm -rf "$LEASE"; step "lease released"' EXIT
trap 'exit 1' INT TERM HUP
step "phase 2 lease taken at nice $nice_value"
/usr/bin/cc -o clfp64 clfp64.c -framework OpenCL && ./clfp64 > results/opencl-fp64.txt 2>&1
step "opencl fp64 query done"
export PYTHONPATH=$D/pydeps
PY=$D/venv/bin/python
BENCH_DIR=$D/hd/examples/benchmarks sh "$D/ab.sh" "$D/results/bench-stmv" 3 30 amber20-stmv \
    metal-single=$PY:Metal:single metal-mixed=$PY:Metal:mixed opencl-single=$PY:OpenCL:single > logs/ab-stmv.log 2>&1
step "stmv done"

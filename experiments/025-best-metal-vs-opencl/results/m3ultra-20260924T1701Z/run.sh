#!/bin/sh
# Runs on the Studio at nice 0, holding /tmp/openmm-lease for the whole run: single barostat repeats
# (10 per build), the OpenCL mixed check, the forces check, the benchmark.py rounds, then mixed
# barostat repeats (5 per build). build.sh ref and build.sh hd ran before this. Progress goes to logs/progress.txt.
# Launch detached from sh, never from zsh with &: zsh runs background jobs at nice 5 (BG_NICE).
#   /bin/sh -c "nohup sh run.sh > logs/run.out 2>&1 < /dev/null &"
set -eu
D=/tmp/openmm-metal-bench/m3ab
LEASE=/tmp/openmm-lease
TESTS=gbsa,rf,pme,apoa1rf,apoa1pme,apoa1ljpme,amber20-dhfr,amber20-cellulose
nice_value=$(ps -o nice= -p $$ | tr -d ' ')
if [ "$nice_value" != 0 ]; then
    echo "running at nice $nice_value, not 0; see the launch line above" >&2
    exit 1
fi
cd "$D"
mkdir -p logs results
step() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $* load $(sysctl -n vm.loadavg)" >> "$D/logs/progress.txt"; }
until mkdir "$LEASE" 2>/dev/null; do
    step "lease held by: $(cat $LEASE/owner 2>/dev/null)"
    sleep 30
done
echo "m3ab (team-lead's M3 Ultra Metal vs OpenCL agent) $(date -u +%Y-%m-%dT%H:%MZ) barostat repeats, forces, benchmark.py in $D" > "$LEASE/owner"
trap 'rm -rf "$LEASE"; step "lease released"' EXIT
trap 'exit 1' INT TERM HUP
step "lease taken at nice $nice_value"

[ "$(git hash-object hd/platforms/metal/src/MetalEvent.cpp)" = 860087ef4f7d1cbdda4a699a157ad9477ed4e906 ] \
    && [ "$(git hash-object /tmp/openmm-metal-bench/evwait/src/platforms/metal/src/MetalEvent.cpp)" = 860087ef4f7d1cbdda4a699a157ad9477ed4e906 ] \
    && [ "$(git hash-object ref/platforms/metal/src/MetalEvent.cpp)" = 82b7e00cdfd6191c4366e9549eefa234d11bac4d ] \
    && [ "$(git hash-object p9074/platforms/metal/src/MetalEvent.cpp)" = a1eaa43d13117bdbb15aa54867b303a3e4e81037 ] \
    && PATH=/tmp/openmm-metal-bench/env/bin:$PATH ninja -C p9074/build -n TestMetalMonteCarloFlexibleBarostat | grep -q "no work to do" \
    && PATH=/tmp/openmm-metal-bench/env/bin:$PATH ninja -C /tmp/openmm-metal-bench/evwait/src/build -n TestMetalMonteCarloFlexibleBarostat | grep -q "no work to do" \
    && PATH=/tmp/openmm-metal-bench/env/bin:$PATH ninja -C ref/build -n TestMetalMonteCarloFlexibleBarostat | grep -q "no work to do" \
    || { step "tree check failed"; exit 1; }
{ echo "nice $nice_value"; sw_vers; uname -a; sysctl -n machdep.cpu.brand_string hw.ncpu hw.memsize; system_profiler SPDisplaysDataType; } > results/machine.txt 2>&1
step "trees match 6df2b8bcb, 9074c38f1, 052eaa85b; evwait, p9074 and ref builds current"

sh "$D/baro.sh" single 10
step "barostat single done"

export PYTHONPATH=$D/pydeps
PY=$D/venv/bin/python
BENCH=$D/hd/examples/benchmarks
(cd "$BENCH" && $PY benchmark.py --platform OpenCL --precision mixed --test gbsa --seconds 5 --verbose --style table) > results/opencl-mixed.txt 2>&1 || true
step "opencl mixed check done"
$PY "$D/fcheck.py" "$BENCH" gbsa,rf,pme,apoa1rf,apoa1pme,apoa1ljpme Metal:single,Metal:mixed,OpenCL:single > results/forces.txt 2>&1
step "forces done"
BENCH_DIR=$BENCH sh "$D/ab.sh" "$D/results/bench" 3 30 $TESTS \
    metal-single=$PY:Metal:single metal-mixed=$PY:Metal:mixed opencl-single=$PY:OpenCL:single > logs/ab.log 2>&1
step "benchmark done"
sh "$D/baro.sh" mixed 5
step "barostat mixed done"

#!/bin/sh
# Runs on the M3 Ultra under the lease: native study 1e, research's computeGBSAForce1 kill test on gbsa.
# Arms: base (the profiling build), kill (gbsa-kill.patch: fast rsqrt, per-atom 1/B) and rsqrt (gbsa-kill-rsqrt-only.patch),
# both patches rebased on gpuprof.patch and built by build-patch.sh into prefix-1e and prefix-1e-rsqrt.
# First forces against Reference per arm with forces.py's own code, TESTS narrowed to gbsa (single and mixed), which is
# also the kernel compile check. Then gbsakill.sh times base, kill and rsqrt end to end on gbsa single and mixed
# (ab.sh, 2 rounds of 15 s, into census/1e/ab), and a counters census of the three arms on gbsa, 3 repeats, prices the
# kernels. Read it after the lease with census.py census/1e and ultra-tools/summarize.py census/1e/ab; forces-<arm>.txt
# hold the forces tables.
D=/tmp/openmm-metal-bench/ultra-profiler
out=$D/census/1e
forces=/tmp/openmm-metal-bench/ultra-tools/forces.py
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing: nice is $(ps -o nice= -p $$)"; exit 1; }
for prefix in prefix-1e prefix-1e-rsqrt; do
    [ -f "$D/$prefix/lib/plugins/libOpenMMMetal.dylib" ] || { echo "missing $D/$prefix, build it first"; exit 1; }
done
mkdir -p "$out"
kill="OPENMM_PLUGIN_DIR=$D/prefix-1e/lib/plugins"
rsqrt="OPENMM_PLUGIN_DIR=$D/prefix-1e-rsqrt/lib/plugins"
for arm in base "kill:$kill" "rsqrt:$rsqrt"; do
    name="${arm%%:*}"; vars=""
    [ "$name" = "$arm" ] || vars="${arm#*:}"
    echo "forces $name load $(sysctl -n vm.loadavg) $(date -u +%H:%M:%SZ)"
    env $vars "$D/venv/bin/python" -c '
import sys
path = sys.argv[1]
source = open(path).read()
narrowed = source.replace("TESTS = [\"gbsa\", \"rf\", \"pme\", \"apoa1rf\", \"apoa1pme\", \"apoa1ljpme\"]", "TESTS = [\"gbsa\"]")
assert narrowed != source, "forces.py TESTS line changed"
sys.argv = sys.argv[1:]
exec(compile(narrowed, path, "exec"))
' "$forces" "$D/src/examples/benchmarks" "$out/forces-$name.txt" /tmp/openmm-metal-bench/ultra-base/forces.txt > "$out/forces-$name.log" 2>&1 \
        || echo "forces $name exit $?"
done
"$D/tools/gbsakill.sh" "$out/ab" || echo "gbsakill exit $?"
"$D/tools/census.sh" "$out" single gbsa 3 base "kill:$kill" "rsqrt:$rsqrt"

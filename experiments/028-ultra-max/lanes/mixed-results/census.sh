#!/bin/sh
# Runs on the Studio at nice 0 under the lease. usage: census.sh <tree> <outdir> <tests> <precisions>
# One short benchmark.py run per (test, precision) with OPENMM_METAL_CENSUS=1; per-kernel GPU totals go
# to <outdir>/<test>-<precision>.txt (lines: CENSUS name count microseconds).
set -eu
D=/tmp/openmm-metal-bench/ultra-mixed
T="$1"; OUT="$2"; TESTS="$(echo "$3" | tr , ' ')"; PRECS="$(echo "$4" | tr , ' ')"
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "not nice 0"; exit 1; }
mkdir -p "$OUT"
export PYTHONPATH=$D/pydeps
cd "$D/$T/examples/benchmarks"
[ -e Amber20_Benchmark_Suite ] || { mkdir Amber20_Benchmark_Suite && tar xzf /tmp/openmm-metal-bench/ultra-base/Amber20_Benchmark_Suite.tar.gz -C Amber20_Benchmark_Suite; }
for t in $TESTS; do for p in $PRECS; do
    [ -s "$OUT/$t-$p.txt" ] && continue
    echo "$(date -u +%H:%M:%SZ) $t $p load $(sysctl -n vm.loadavg)" >> "$OUT/loads.txt"
    OPENMM_METAL_CENSUS=1 "$D/venv-$T/bin/python" benchmark.py --platform Metal --precision $p --test $t --seconds 5 --style table \
        > "$OUT/$t-$p.out" 2> "$OUT/$t-$p.err" || true
    grep '^CENSUS' "$OUT/$t-$p.err" > "$OUT/$t-$p.txt" || true
done; done
# One-off for mixed lane pass 1: t5's rebuild raced its sync, so rebuild it before the untimed work uses it.
if [ -f "$D/rebuild-t5" ]; then
    rm -f "$D/rebuild-t5"
    echo "$(date -u +%H:%M:%SZ) rebuilding t5" >> "$D/logs/rebuild-t5.out"
    /tmp/openmm-metal-bench/ultra-tools/build.sh "$D/t5" >> "$D/logs/rebuild-t5.out" 2>&1 || true
    echo "$(date -u +%H:%M:%SZ) t5 rebuilt" >> "$D/logs/rebuild-t5.out"
fi

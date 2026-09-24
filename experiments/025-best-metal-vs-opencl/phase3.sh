#!/bin/sh
# Runs on the mini under the lease: build ~/lab/fast from the git archive of 6df2b8bcb with Metal and
# OpenCL (same source, same libOpenMM), install into a fresh venv, then the full benchmark.py run.
# usage: phase3.sh <outdir>   (start from zsh with setopt no_bg_nice; ab.sh refuses nice != 0)
set -eu
f="$HOME/lab/fast"
out="$1"
echo "start $(date -u +%H:%M:%SZ) nice $(ps -o nice= -p $$)"
mkdir -p "$f/src"
tar -xzf "$f/fast.tar.gz" -C "$f/src"
test "$(shasum < "$f/src/platforms/metal/src/MetalEvent.cpp" | cut -c1-40)" = 71bd48959e6432f050131a3e2a447220bd45cc08
test "$(shasum < "$f/src/platforms/metal/src/kernels/findInteractingBlocks.metal" | cut -c1-40)" = 2ec8c88aba5d26f6cc9aa0053941fe5462df1c44
echo "tree verified"
sh "$f/tools/mkvenv.sh" "$f/venv"
sh "$f/tools/build.sh" "$f" -DBUILD_TESTING=OFF -DOPENMM_BUILD_OPENCL_LIB=ON -DOPENMM_BUILD_C_AND_FORTRAN_WRAPPERS=OFF
"$f/venv/bin/python" -c "import openmm as mm; print(mm.__file__, [mm.Platform.getPlatform(i).getName() for i in range(mm.Platform.getNumPlatforms())], mm.Platform.getPluginLoadFailures())"
ln -sfn "$HOME/lab/bench-018/examples/benchmarks/Amber20_Benchmark_Suite" "$f/src/examples/benchmarks/Amber20_Benchmark_Suite"
mkdir -p "$out"
{ uname -a; sw_vers; sysctl -n machdep.cpu.brand_string hw.memsize hw.ncpu; shasum "$f/prefix/lib/plugins/libOpenMMMetal.dylib" "$f/prefix/lib/plugins/libOpenMMOpenCL.dylib" "$HOME/lab/prefix-openmm-simd/lib/plugins/libOpenMMMetal.dylib"; } > "$out/host-before.txt"
sh "$f/tools/ab.sh" "$out" 3 30 gbsa,rf,pme,apoa1rf,apoa1pme,apoa1ljpme,amber20-dhfr,amber20-cellulose \
    "metal-single=$f/venv/bin/python:Metal:single" \
    "metal-mixed=$f/venv/bin/python:Metal:mixed" \
    "opencl-single=$f/venv/bin/python:OpenCL:single" \
    "metalp0-single=$HOME/lab/venv-openmm-simd/bin/python:Metal:single" > "$out/ab-stdout.txt" 2>&1
{ uname -a; date -u; sysctl -n vm.loadavg; } > "$out/host-after.txt"
echo "end $(date -u +%H:%M:%SZ)"

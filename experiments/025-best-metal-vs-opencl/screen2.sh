#!/bin/sh
# Runs on the mini under the lease: where does `metal`+P0 (exp 019 build) beat 6df2b8bcb? 2 rounds of
# 15 s: 6df2b8bcb, the screening tree without single pairs (FB_BITS=0), and the 019 P0 build (read-only).
f="$HOME/lab/fast"
ln -sfn "$HOME/lab/bench-018/examples/benchmarks/Amber20_Benchmark_Suite" "$f/scr/src/examples/benchmarks/Amber20_Benchmark_Suite"
BENCH_DIR="$f/scr/src/examples/benchmarks" sh "$f/tools/ab.sh" "$f/out/screen2" 2 15 pme,apoa1rf,apoa1pme,amber20-cellulose \
    "base=$f/venv-base/bin/python:Metal:single" \
    "bits0=$f/scr/venv/bin/python:Metal:single:FB_BITS=0" \
    "p0metal=$HOME/lab/venv-openmm-simd/bin/python:Metal:single" > "$f/out/screen2.log" 2>&1
"$f/scr/venv/bin/python" "$f/tools/summarize.py" "$f/out/screen2" bits0/base p0metal/base

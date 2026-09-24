#!/bin/sh
# Runs on the mini under the lease: forces of each knob setting against Reference (sanity), then
# one benchmark.py round of 15 s per setting (screen). FB_* knobs are temporary, screening tree only.
f="$HOME/lab/fast"
py="$f/scr/venv/bin/python"
for setting in "" FB_TGS=64 FB_TGS=256 "FB_P0=1 FB_TGS=256" "FB_P0=1 FB_TGS=256 FB_GRID=120"; do
    echo "== ${setting:-default}"
    env $setting "$py" "$f/tools/forces.py" "$f/scr/src/examples/benchmarks" gbsa,rf,pme,apoa1rf
done > "$f/out/screen1-forces.txt" 2>&1
cat "$f/out/screen1-forces.txt"
BENCH_DIR="$f/scr/src/examples/benchmarks" sh "$f/tools/ab.sh" "$f/out/screen1" 1 15 gbsa,rf,pme,apoa1rf,apoa1pme \
    "base=$f/venv-base/bin/python:Metal:single" \
    "scr=$py:Metal:single" \
    "t64=$py:Metal:single:FB_TGS=64" \
    "t256=$py:Metal:single:FB_TGS=256" \
    "p0=$py:Metal:single:FB_P0=1,FB_TGS=256" \
    "p0g120=$py:Metal:single:FB_P0=1,FB_TGS=256,FB_GRID=120" > "$f/out/screen1.log" 2>&1
"$py" "$f/tools/summarize.py" "$f/out/screen1" scr/base t64/scr t256/scr p0/scr p0g120/scr

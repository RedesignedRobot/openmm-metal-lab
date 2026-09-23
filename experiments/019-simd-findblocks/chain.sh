#!/bin/sh
# Runs on the mini: after pipeline.sh finishes, the interleaved benchmarks (run.py), then fb.sh.
# Holds no lease itself; run.py and fb.sh take it per chunk.
# Launch detached from sh at nice 0:  sh -c "nohup sh chain.sh > chain.log 2>&1 &"
set -u
here="$(cd "$(dirname "$0")" && pwd)"
lab="$HOME/lab"
out="$lab/simd-019"
while pgrep -f "sh pipeline.sh" > /dev/null; do sleep 60; done
grep -q ALL_DONE "$out/pipeline.status" || { echo "pipeline.sh did not finish"; exit 1; }
cd "$here"
python3 run.py "$lab/venv-openmm-simd-base/bin/python" "$lab/venv-openmm-simd/bin/python" "$out/benchmarks" "$lab/fah-wu" \
    "$out/bench" fah > "$out/run.log" 2>&1
echo "run.py exit $?"
sh fb.sh > "$out/fb.log" 2>&1
echo "fb.sh exit $?"

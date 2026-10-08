#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench
lane=$root/ultra-m29-nonbonded
blocks=$root/ultra-m29-nonbonded-blocks
[ -f "$root/READY" ] || { echo 'READY missing'; exit 2; }
[ -f "$blocks/BUILT" ] && [ ! -f "$blocks/NEEDS_REBUILD" ] || { echo 'Corrected force-block build required'; exit 2; }
[ "$#" -eq 1 ] || { echo 'usage: step-a-screen.sh TEST'; exit 2; }
out=$lane/blocks-screen-$1
"$root/ultra-tools/ab.sh" "$out" 2 15 "$1" \
  base=$root/ultra-int028/venv/bin/python:Metal:single \
  maxbits=$lane/venv/bin/python:Metal:single \
  blocks=$blocks/venv/bin/python:Metal:single \
  opencl=$root/ultra-int028/venv/bin/python:OpenCL:single
"$root/env/bin/python" "$root/ultra-tools/summarize.py" "$out" blocks/base blocks/maxbits blocks/opencl > "$out/ratios.txt"

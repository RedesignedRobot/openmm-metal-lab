#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench
lane=$root/ultra-m29-nonbonded
records=$root/ultra-m29-nonbonded-records
[ -f "$root/READY" ] && [ -f "$records/BUILT" ]
[ "$#" -eq 1 ] || exit 2
out=$lane/records-screen-$1
"$root/ultra-tools/ab.sh" "$out" 2 15 "$1" \
  base=$root/ultra-int028/venv/bin/python:Metal:single \
  maxbits=$lane/venv/bin/python:Metal:single \
  records=$records/venv/bin/python:Metal:single \
  opencl=$root/ultra-int028/venv/bin/python:OpenCL:single
"$root/env/bin/python" "$root/ultra-tools/summarize.py" "$out" records/base records/maxbits records/opencl > "$out/ratios.txt"

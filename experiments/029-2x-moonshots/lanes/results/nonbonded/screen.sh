#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench
lane=$root/ultra-m29-nonbonded
[ -f "$root/READY" ] || { echo 'READY missing'; exit 2; }
[ "$#" -eq 4 ] || { echo 'usage: screen.sh outname rounds seconds comma-tests'; exit 2; }
out=$lane/$1
rounds=$2
seconds=$3
tests=$4
"$root/ultra-tools/ab.sh" "$out" "$rounds" "$seconds" "$tests" \
  base-s=$root/ultra-int028/venv/bin/python:Metal:single \
  cand-s=$lane/venv/bin/python:Metal:single \
  cl-s=$root/ultra-int028/venv/bin/python:OpenCL:single \
  base-m=$root/ultra-int028/venv/bin/python:Metal:mixed \
  cand-m=$lane/venv/bin/python:Metal:mixed
"$root/env/bin/python" "$root/ultra-tools/summarize.py" "$out" cand-s/base-s cand-m/base-m cand-s/cl-s cand-m/cl-s > "$out/ratios.txt"

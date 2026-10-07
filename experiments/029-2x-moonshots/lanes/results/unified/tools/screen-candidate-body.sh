#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-unified
B=/tmp/openmm-metal-bench/ultra-int028
T=/tmp/openmm-metal-bench/ultra-tools
test -f /tmp/openmm-metal-bench/READY
test -f "$D/BUILT"
case "${1:-}" in
small) tests=pme,apoa1pme,apoa1ljpme,amber20-dhfr ;;
cellulose) tests=amber20-cellulose ;;
*) exit 2 ;;
esac
out="$D/screen-$1"
"$T/ab.sh" "$out" 2 15 "$tests" \
    base-s="$B/venv/bin/python:Metal:single" \
    cpu-s="$D/venv/bin/python:Metal:single" \
    base-m="$B/venv/bin/python:Metal:mixed" \
    cpu-m="$D/venv/bin/python:Metal:mixed" \
    opencl="$B/venv/bin/python:OpenCL:single"
"$B/venv/bin/python" "$T/summarize.py" "$out" cpu-s/base-s cpu-m/base-m cpu-s/opencl cpu-m/opencl > "$out/summary.txt"
cat "$out/summary.txt"

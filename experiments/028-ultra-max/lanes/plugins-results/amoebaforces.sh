#!/bin/sh
# Runs on the M3 Ultra under lease.sh --correctness: amoebaforces.py with one build's python.
# usage: amoebaforces.sh <label> <dir>
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing to run at nice $(ps -o nice= -p $$)"; exit 1; }
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
unset PYTHONPATH
L=/tmp/openmm-metal-bench/ultra-plugins
echo "$1 $(sed -n 's/^commit //p' $2/BUILT) $(date -u +%H:%M:%SZ)"
"$2/venv/bin/python" $L/amoebaforces.py /tmp/openmm-metal-bench/ultra-base/benchmarks $L/amoeba-ref
echo "done $1 $(date -u +%H:%M:%SZ)"

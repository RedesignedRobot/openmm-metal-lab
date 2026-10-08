#!/bin/sh
# Runs under one lease.sh hold: window.sh --smoke end to end (base against itself), nested in this
# hold, then one 30 s stmv run of base Metal single to replace window.sh's 90 s guess.
set -eu
T=/tmp/openmm-metal-bench/ultra-tools
I=/tmp/openmm-metal-bench/ultra-infra
B=/tmp/openmm-metal-bench/ultra-base
s=$(date +%s)
"$T/window.sh" --smoke "$I/wsmoke" gbsa a=$B:single,opencl b=$B:single
echo "window.sh smoke took $(( $(date +%s) - s )) s"
s=$(date +%s)
"$T/ab.sh" "$I/stmv1" 1 30 amber20-stmv base=$B/venv/bin/python:Metal:single
echo "stmv base single, one 30 s run, took $(( $(date +%s) - s )) s"

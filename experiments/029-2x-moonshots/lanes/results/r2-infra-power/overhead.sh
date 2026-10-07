#!/bin/sh
# gpuclock overhead check (head, 2026-09-28): an interleaved ab.sh on apoa1rf, trunk Metal single, 5 rounds of
# 30 s, with gpuclock.py sampling (on) against no sampler at all (off). Pass: on/off within 0.3%.
# Runs in one timing ticket: stops the global gpuclock by its recorded pid, runs the ab (nested in this hold),
# then starts gpuclock again with bg.sh, on any exit.
# usage: lease.sh infra "gpuclock overhead check, about 7 min" /bin/sh <this file>
set -u
B=/tmp/openmm-metal-bench
here=$(cd "$(dirname "$0")" && pwd)
out=$B/ultra-infra/power-overhead
restart() {
    [ -e $B/ultra-lead/gpuclock.pid ] && kill -0 "$(cat $B/ultra-lead/gpuclock.pid)" 2>/dev/null && return
    (cd $B && $B/ultra-tools/bg.sh $B/ultra-infra/gpuclock-bg.log $B/env/bin/python $B/ultra-tools/gpuclock.py)
    echo "$(date -u +%H:%M:%SZ) global gpuclock started again"
}
trap restart EXIT
pid=$(cat $B/ultra-lead/gpuclock.pid)
kill "$pid" && while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
echo "$(date -u +%H:%M:%SZ) global gpuclock pid $pid stopped"
$B/ultra-tools/ab.sh "$out" 5 30 apoa1rf "on=$here/sampled-python:Metal:single" \
    "off=$B/ultra-r3-nbfmc/venv/bin/python:Metal:single"
$B/env/bin/python $B/ultra-tools/summarize.py "$out" on/off | tee "$out.summary.txt"

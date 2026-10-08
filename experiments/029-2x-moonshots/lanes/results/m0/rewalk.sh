#!/bin/sh
# M0(2) rewalk, one short timing hold: gdwalk.py over a .gputrace whose profile is already embedded (GDWALK_LOAD=1),
# after the 17:37Z r1 walk stopped at /performance on a JSON parse bug. No new capture, no new profile run.
# usage: bg.sh <log> rewalk.sh <label>
set -u
M=/tmp/openmm-metal-bench/ultra-infra/m0
label=$1
alarm() { perl -e '$t = shift; alarm $t; exec @ARGV' "$@"; }
alarm 15 gpudebug -l > /dev/null 2>&1 || { echo "preflight: gpudebug -l rc $? $(date -u +%H:%M:%SZ), not queued"; exit 1; }
GDWALK_LOAD=1 /tmp/openmm-metal-bench/ultra-tools/lease.sh r2-infra "M0(2) gpudebug walk of $label.gputrace (embedded profile), about 7 min" \
    /bin/sh -c "GDWALK_LOAD=1 /tmp/openmm-metal-bench/env/bin/python3 -B $M/gdwalk.py $M/$label.gputrace $M/$label"
echo "rewalk done $(date -u +%H:%M:%SZ)"

#!/bin/sh
# M0(2) targeted walk, one short timing hold: gdtarget.py over r1.gputrace and sub.gputrace (profiles embedded).
# The 19:04Z sub walk ran right after `profile run --embed` and found /performance empty; r1's `profile load`
# walk (18:37Z) was full. No new capture. usage: bg.sh <log> target.sh
set -u
M=/tmp/openmm-metal-bench/ultra-infra/m0
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
alarm() { perl -e '$t = shift; alarm $t; exec @ARGV' "$@"; }
alarm 15 gpudebug -l > /dev/null 2>&1 || { echo "preflight: gpudebug -l rc $? $(date -u +%H:%M:%SZ), not queued"; exit 1; }
/tmp/openmm-metal-bench/ultra-tools/lease.sh r2-infra "M0(2) gpudebug targeted walk of r1 and sub traces (embedded profiles), about 3 min" \
    /bin/sh -c "for l in sub r1; do /tmp/openmm-metal-bench/env/bin/python3 -B $M/gdtarget.py $M/\$l.gputrace $M/\$l 2>&1 | sed \"s/^/\$l: /\"; done"
echo "target done $(date -u +%H:%M:%SZ)"

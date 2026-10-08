#!/bin/sh
# Queues M0(2): one timing hold per spec (counters.specs, or args), in order. Before anything is queued, and again
# before each hold, gpucapture list and gpudebug -l must answer within 15 s. Both hung on a macOS authorization
# prompt (system.privilege.taskport.debug, developer mode off) on 2026-09-27, which wedged a hold for 4 minutes.
# usage: bg.sh <log> counters-launch.sh [spec ...]
set -u
M=/tmp/openmm-metal-bench/ultra-infra/m0
alarm() { perl -e '$t = shift; alarm $t; exec @ARGV' "$@"; }
preflight() {
    alarm 15 gpucapture list > /dev/null 2>&1 || { echo "preflight: gpucapture list rc $? $(date -u +%H:%M:%SZ)"; return 1; }
    alarm 15 gpudebug -l > /dev/null 2>&1 || { echo "preflight: gpudebug -l rc $? $(date -u +%H:%M:%SZ)"; return 1; }
}
[ $# -gt 0 ] || set -- $(grep -v '^#' "$M/counters.specs")
for spec in "$@"; do
    preflight || { echo "not queued: $spec"; exit 1; }
    /tmp/openmm-metal-bench/ultra-tools/lease.sh r2-infra "M0(2) Apple9 counters apoa1rf ${spec%%=*}, gpucapture+gpudebug" "$M/counters.sh" "$spec"
done
echo "launch done $(date -u +%H:%M:%SZ)"

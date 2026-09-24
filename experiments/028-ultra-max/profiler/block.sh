#!/bin/sh
# Runs on the M3 Ultra: one lease block of profile.sh passes, each "<mode>:<precision>:<tests>[:<extra env>]".
# Extra env is space separated VAR=value settings. Takes the lease through ultra-tools/lease.sh.
# usage: block.sh <out dir> <what> <pass>...
D=/tmp/openmm-metal-bench/ultra-profiler
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing: nice is $(ps -o nice= -p $$)"; exit 1; }
if [ -z "${BLOCK_INNER:-}" ]; then
    what="$2"
    BLOCK_INNER=1 exec /tmp/openmm-metal-bench/ultra-tools/lease.sh ultra-profiler "$what" "$0" "$@"
fi
out="$1"; shift 2
echo "block start $(date -u +%H:%M:%SZ)"
for pass in "$@"; do
    IFS=: read -r mode precision tests extra <<SPEC
$pass
SPEC
    "$D/tools/profile.sh" "$out" "$mode" "$precision" "$tests" "$extra"
done
echo "block end $(date -u +%H:%M:%SZ)"

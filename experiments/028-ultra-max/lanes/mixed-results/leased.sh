#!/bin/sh
# Runs on the Studio. usage: leased.sh "<what>" <command...>
# Waits for /tmp/openmm-lease, runs the command at nice 0 while holding it, releases it on exit.
set -u
LEASE=/tmp/openmm-lease
LOG=/tmp/openmm-metal-bench/ultra-mixed/logs/lease.log
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "not nice 0" >> $LOG; exit 1; }
what="$1"; shift
until mkdir "$LEASE" 2>/dev/null; do sleep 3; done
echo "mixed: $what, from $(date -u +%H:%MZ), <20 min" > "$LEASE/owner"
trap 'rm -rf "$LEASE"; echo "$(date -u +%H:%M:%SZ) released $what" >> $LOG' EXIT
trap 'exit 1' INT TERM HUP
echo "$(date -u +%H:%M:%SZ) took lease for $what load $(sysctl -n vm.loadavg)" >> $LOG
"$@"
echo "$(date -u +%H:%M:%SZ) done $what rc=$?" >> $LOG

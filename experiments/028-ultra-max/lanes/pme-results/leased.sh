#!/bin/sh
# usage: leased.sh "what" command...  Waits for the GPU lease, runs the command, releases.
WHAT=$1; shift
n=0
until mkdir /tmp/openmm-lease 2>/dev/null; do
  n=$((n+1)); [ $n -gt 900 ] && { echo "lease wait timeout" >&2; exit 4; }
  sleep 2
done
echo "pme lane: $WHAT (pid $$, $(date -u +%H:%M:%SZ))" > /tmp/openmm-lease/owner
trap 'rm -f /tmp/openmm-lease/owner; rmdir /tmp/openmm-lease' EXIT INT TERM
echo "load: $(sysctl -n vm.loadavg)"
"$@"

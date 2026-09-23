#!/bin/sh
# Run a command while holding this machine's OpenMM lease (a directory other agents also take).
# usage: leased.sh <what> <command...>
# Keep each command to one lease-sized block (at most ~15 min): other lanes share the machine.
what=$1; shift
until mkdir /tmp/openmm-lease 2>/dev/null; do sleep 20; done
echo "perf-studio $(date -u +%H:%MZ) $what" > /tmp/openmm-lease/owner
trap 'rm -rf /tmp/openmm-lease' EXIT INT TERM
echo "== lease taken $(date -u +%H:%M:%SZ) $what"
"$@"
status=$?
echo "== lease released $(date -u +%H:%M:%SZ) $what exit $status"
exit $status

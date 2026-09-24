#!/bin/sh
# Runs on the M3 Ultra: hold the GPU lease around one command, and refuse to time at a nonzero nice.
# usage: leased.sh "<what>" <command...>
LEASE=/tmp/openmm-lease
what="$1"
shift
[ "$(ps -o nice= -p $$ | tr -d ' ')" = 0 ] || { echo "refusing: nice is $(ps -o nice= -p $$)"; exit 1; }
waited=0
until mkdir "$LEASE" 2>/dev/null; do
    [ $waited -eq 0 ] && echo "lease held by: $(cat $LEASE/owner 2>/dev/null)"
    waited=$((waited+10))
    sleep 10
done
echo "profiler $(date -u +%Y-%m-%dT%H:%M:%SZ) $what" > "$LEASE/owner"
trap 'rm -rf "$LEASE"' EXIT
trap 'exit 1' INT TERM HUP
echo "lease acquired $(date -u +%H:%M:%SZ) after ${waited}s: $what"
"$@"
echo "lease released $(date -u +%H:%M:%SZ)"

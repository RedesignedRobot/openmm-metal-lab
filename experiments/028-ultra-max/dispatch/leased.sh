#!/bin/sh
# Runs on the M3 Ultra: hold the shared GPU lease around one command, at nice 0.
# usage: leased.sh "<what>" <command...>
LEASE=/tmp/openmm-lease
what="$1"
shift
nice_value=$(ps -o nice= -p $$ | tr -d " ")
if [ "$nice_value" != 0 ]; then echo "running at nice $nice_value, not 0" >&2; exit 1; fi
waited=0
until mkdir "$LEASE" 2>/dev/null; do
    [ $waited -eq 0 ] && echo "lease held by: $(cat $LEASE/owner 2>/dev/null)"
    waited=$((waited+2))
    sleep 2
done
echo "dispatch $(date -u +%Y-%m-%dT%H:%MZ) $what" > "$LEASE/owner"
trap 'rm -rf "$LEASE"' EXIT
trap 'exit 1' INT TERM HUP
echo "lease taken $(date -u +%H:%M:%SZ) after ${waited}s"
"$@"

#!/bin/sh
# Runs on the mini: hold the shared machine lease around one command.
# usage: leased.sh "<what>" <command...>
LEASE=/tmp/openmm-lease
what="$1"
shift
waited=0
until mkdir "$LEASE" 2>/dev/null; do
    [ $waited -eq 0 ] && echo "lease held by: $(cat $LEASE/owner 2>/dev/null)"
    waited=$((waited+20))
    sleep 20
done
echo "best-metal $(date -u +%Y-%m-%dT%H:%MZ) $what" > "$LEASE/owner"
trap 'rm -rf "$LEASE"' EXIT
trap 'exit 1' INT TERM HUP
"$@"

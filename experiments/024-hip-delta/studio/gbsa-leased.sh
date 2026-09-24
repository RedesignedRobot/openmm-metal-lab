#!/bin/sh
# Runs on the Studio: hold /tmp/openmm-lease around one command, or exit 75 if someone holds it.
# usage: gbsa-leased.sh <command...>
LEASE=/tmp/openmm-lease
mkdir "$LEASE" 2>/dev/null || { echo "lease held by: $(cat $LEASE/owner 2>/dev/null)"; exit 75; }
echo gbsa-gap > "$LEASE/owner"
trap 'rm -rf "$LEASE"' EXIT
trap 'exit 1' INT TERM HUP
"$@"

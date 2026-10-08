#!/bin/sh
set -eu
while kill -0 52449 2>/dev/null; do sleep 5; done
grep -qx PASS /tmp/openmm-metal-bench/ultra-r3-gbown/gate-a.log
exec /tmp/openmm-metal-bench/ultra-tools/lease.sh r3-gbown 'Stage A real-step Born phase baseline and row trace' /tmp/openmm-metal-bench/ultra-r3-gbown/tools/profile-a.sh

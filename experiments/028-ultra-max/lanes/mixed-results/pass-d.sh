#!/bin/sh
# Placeholder reserve slot: exits at once unless a reserve body is ready.
M=/tmp/openmm-metal-bench/ultra-mixed
[ -f $M/pass4-ready ] || { echo "$(date -u +%H:%M:%SZ) pass 4: nothing ready"; exit 0; }
exec /bin/sh $M/pass4-body.sh

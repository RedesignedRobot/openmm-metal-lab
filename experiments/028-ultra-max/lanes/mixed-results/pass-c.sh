#!/bin/sh
# Placeholder until the Metal-gated build is ready: exits at once, so the slot costs nothing.
M=/tmp/openmm-metal-bench/ultra-mixed
[ -f $M/pass3-ready ] || { echo "$(date -u +%H:%M:%SZ) pass 3: nothing ready"; exit 0; }
exec /bin/sh $M/pass3-body.sh

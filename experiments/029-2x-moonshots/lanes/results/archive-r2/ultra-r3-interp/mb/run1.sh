#!/bin/sh
# Night guard: no GPU work 00:00-07:00Z.
h=$(date -u +%H)
if [ "$h" -lt 7 ]; then echo "skipped: night window $(date -u +%H:%MZ)"; exit 0; fi
cd /tmp/openmm-metal-bench/ultra-r2-pmefft/mb
for it in 100000 400000; do ./barriermb $it 15; done

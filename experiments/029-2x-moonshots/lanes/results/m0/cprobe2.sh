#!/bin/sh
# Queues the -noshader counter probe (profiles 3, 4, 6) as one timing hold, about 5 min.
exec /tmp/openmm-metal-bench/ultra-tools/lease.sh r2-infra "M0(2b) xctrace counter probe, shader timeline off, apoa1rf 1 s x 3 profiles, about 5 min" \
    /bin/sh /tmp/openmm-metal-bench/ultra-infra/m0/counterprobe.sh cp3-noshader cp4-noshader cp6-noshader

#!/bin/sh
# Runs on the M3 Ultra from 1e.sh, inside its lease: the GBSA kill test timed end to end with ab.sh. Arms per
# precision: the profiling tree the kill builds come from (prof), and its gbsa-kill and gbsa-kill-rsqrt-only builds
# (prefix-1e, prefix-1e-rsqrt, loaded through OPENMM_PLUGIN_DIR), so kill and rsqrt against prof are the patches
# alone. gbsa single and mixed, 2 interleaved rounds of 15 s: 12 runs, which fits the 20 minute cap with 1e's
# forces and census.
# usage: gbsakill.sh <new out dir>
set -eu
D=/tmp/openmm-metal-bench/ultra-profiler
prof=$D/venv/bin/python
configs=""
for precision in single mixed; do
    p=$(echo "$precision" | cut -c1)
    configs="$configs prof_$p=$prof:Metal:$precision"
    configs="$configs kill_$p=$prof:Metal:$precision:OPENMM_PLUGIN_DIR=$D/prefix-1e/lib/plugins"
    configs="$configs rsqrt_$p=$prof:Metal:$precision:OPENMM_PLUGIN_DIR=$D/prefix-1e-rsqrt/lib/plugins"
done
exec /tmp/openmm-metal-bench/ultra-tools/ab.sh "$1" 2 15 gbsa $configs

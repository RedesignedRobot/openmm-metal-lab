#!/bin/sh
Q=/tmp/openmm-metal-bench/ultra-r2-accum-gb-q
PRECISION=single /tmp/openmm-metal-bench/ultra-tools/shader.sh /tmp/openmm-metal-bench/ultra-r2-accum-gb/trace2 q-k2-single gbsa $Q 2
OPENMM_METAL_GB_PROBE_BLOCKS_PER_CHUNK=6 PRECISION=single /tmp/openmm-metal-bench/ultra-tools/shader.sh /tmp/openmm-metal-bench/ultra-r2-accum-gb/trace2 q-k6-single gbsa $Q 2
echo PROF2 DONE

#!/bin/sh
PRECISION=single /tmp/openmm-metal-bench/ultra-tools/shader.sh /tmp/openmm-metal-bench/ultra-r2-accum-gb/trace0 gbsa-single gbsa /tmp/openmm-metal-bench/ultra-r2-accum-gb 2
PRECISION=mixed /tmp/openmm-metal-bench/ultra-tools/shader.sh /tmp/openmm-metal-bench/ultra-r2-accum-gb/trace0 gbsa-mixed gbsa /tmp/openmm-metal-bench/ultra-r2-accum-gb 2
echo PROF0 DONE

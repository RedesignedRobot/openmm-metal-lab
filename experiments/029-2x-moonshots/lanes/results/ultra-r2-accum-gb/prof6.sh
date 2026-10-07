#!/bin/sh
PRECISION=single /tmp/openmm-metal-bench/ultra-tools/shader.sh /tmp/openmm-metal-bench/ultra-r2-accum-gb/trace6 v-single gbsa /tmp/openmm-metal-bench/ultra-r2-accum-gb-s 2
PRECISION=mixed /tmp/openmm-metal-bench/ultra-tools/shader.sh /tmp/openmm-metal-bench/ultra-r2-accum-gb/trace6 v-mixed gbsa /tmp/openmm-metal-bench/ultra-r2-accum-gb-s 2
echo PROF6 DONE

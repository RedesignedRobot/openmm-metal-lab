#!/bin/sh
# Untimed: the Metal single ctests of the c1-c5 stack, which with pass 1's mixed ctests make up ctest -R TestMetal.
M=/tmp/openmm-metal-bench/ultra-mixed
ctest --test-dir $M/t5/build -R 'TestMetal.*Single$' -j4 --timeout 600 --output-on-failure > $M/logs/ctest-single.out 2>&1
tail -3 $M/logs/ctest-single.out

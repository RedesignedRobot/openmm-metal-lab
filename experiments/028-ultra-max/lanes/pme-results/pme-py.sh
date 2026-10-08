#!/bin/sh
set -e
B=/tmp/openmm-metal-bench
L=$B/ultra-pme
export PATH=$B/env/bin:$PATH
ninja -C $L/build -j8 install > $L/install.log 2>&1
cd $L/build/python && cmake -P $L/build/python/pysetupbuild.cmake > $L/pybuild.log 2>&1
ls -d $L/build/python/build/lib*

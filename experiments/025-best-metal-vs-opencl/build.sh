#!/bin/sh
# Runs on the mini: configure, build and install one tree. <dir> holds src/; build/, prefix/ and
# the venv/ that receives the Python module sit next to it. Extra cmake flags pass through.
# CCACHE_BASEDIR makes paths relative, so the screening tree and the final tree share cache hits.
# usage: build.sh <dir> [cmake flags...]
set -eu
dir="$1"
shift
export CCACHE_BASEDIR="$HOME/lab/fast"
cmake -S "$dir/src" -B "$dir/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_INSTALL_PREFIX="$dir/prefix" \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DPYTHON_EXECUTABLE="$dir/venv/bin/python" \
    "$@" > "$dir/cmake.log"
# 8 GB of RAM: four jobs keeps the linker out of swap.
ninja -C "$dir/build" -j4 > "$dir/ninja.log" 2>&1 || { tail -30 "$dir/ninja.log"; exit 1; }
ninja -C "$dir/build" install > /dev/null
ninja -C "$dir/build" PythonInstall > "$dir/python.log" 2>&1 || { tail -30 "$dir/python.log"; exit 1; }
echo "built and installed $dir"

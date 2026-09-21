#!/bin/sh
# Runs on the mini, inside a synced OpenMM tree. Builds and installs OpenMM plus the
# Python wrappers into ~/lab/prefix-<tree name>. Extra cmake flags pass through.
set -eu
name="$(basename "$PWD")"
prefix="$HOME/lab/prefix-$name"
cmake -S . -B build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_INSTALL_PREFIX="$prefix" \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  -DPYTHON_EXECUTABLE="$HOME/lab/venv/bin/python" \
  -DOPENMM_BUILD_OPENCL_LIB=ON \
  "$@"
# 8 GB of RAM: four jobs keeps the linker out of swap.
ninja -C build -j4
ninja -C build install
ninja -C build PythonInstall
echo "installed to $prefix"

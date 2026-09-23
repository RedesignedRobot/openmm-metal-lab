#!/bin/sh
# Runs on the mini inside ~/lab/hipdelta: rebuild, then install the library and the Python module
# into ~/lab/prefix-hipdelta and build/venv, which has no other openmm.
set -e
ninja -C build -j4 2>&1 | grep -E "error|FAILED" || true
ninja -C build install > /dev/null
ninja -C build PythonInstall > /dev/null 2>&1
echo installed

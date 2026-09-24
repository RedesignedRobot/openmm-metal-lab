#!/bin/sh
# Runs on the mini: a fresh venv with no openmm, the interpreter and package versions of the 024 venvs,
# plus scipy, which amber20-dhfr needs to read its NetCDF restart.
# usage: mkvenv.sh <dir>
set -eu
uv venv --python 3.13 "$1"
uv pip install --python "$1/bin/python" numpy==2.5.3 cython==3.3.0 setuptools==84.0.0 scipy
"$1/bin/python" -c "import importlib.util, sys; sys.exit(importlib.util.find_spec('openmm') is not None)"
echo "venv $1 ready, no openmm"

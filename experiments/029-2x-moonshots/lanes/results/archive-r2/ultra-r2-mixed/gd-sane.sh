#!/bin/sh
# Runs gd-sane.py once per diag arm on the gd tree.
PY=/tmp/openmm-metal-bench/ultra-r2-mixed-gd/venv/bin/python
for arm in off q shake0 shake1; do
    OPENMM_METAL_GBDIAG=$arm "$PY" /tmp/openmm-metal-bench/ultra-r2-mixed/gd-sane.py 2>&1 | tail -2
done

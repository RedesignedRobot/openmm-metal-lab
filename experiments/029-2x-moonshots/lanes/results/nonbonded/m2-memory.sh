#!/bin/sh
set -eu
. /tmp/openmm-metal-bench/hosts.env
export M2
exec /tmp/openmm-metal-bench/env/bin/python /tmp/openmm-metal-bench/ultra-m29-nonbonded/m2-memory.py

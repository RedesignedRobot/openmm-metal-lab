#!/bin/sh
set -eu
root=/tmp/openmm-metal-bench
exec "$root/ultra-tools/build.sh" "$root/ultra-m29-nonbonded-final"

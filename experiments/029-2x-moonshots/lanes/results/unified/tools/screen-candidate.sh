#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-unified
case "${1:-}" in
cellulose) exec "$D/tools/screen-cellulose-once.sh" ;;
*) exec "$D/tools/screen-candidate-body.sh" "$@" ;;
esac

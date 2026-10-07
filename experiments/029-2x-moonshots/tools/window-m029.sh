#!/bin/sh
# Head-only campaign. Default is a read-only preflight and exact command plan.
# The lab copy is canonical; the head installs the matching holdout.py before running.
# The head supplies --stack3-commit, --stack4-commit, --pme-base-commit and --reorder-diag-commit.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export PYTHONDONTWRITEBYTECODE=1
exec /tmp/openmm-metal-bench/env/bin/python3 "$here/window-m029-summary.py" campaign "$@"

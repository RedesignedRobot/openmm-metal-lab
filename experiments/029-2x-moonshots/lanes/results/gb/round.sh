#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-gb
T=/tmp/openmm-metal-bench/ultra-tools
[ "$("$T/srchash.sh" "$D")" = "$(awk '$1 == "src" {print $2}' "$D/BUILT")" ]
"$T/lease.sh" --correctness m29-gb 'GB SIMD prototype forces, four targeted tests, five-process determinism' "$D/validate.sh"
"$T/ab.sh" "$D/screen" 3 30 gbsa \
  base-single=/tmp/openmm-metal-bench/ultra-int028/venv/bin/python:Metal:single \
  mine-single="$D/venv/bin/python":Metal:single \
  base-mixed=/tmp/openmm-metal-bench/ultra-int028/venv/bin/python:Metal:mixed \
  mine-mixed="$D/venv/bin/python":Metal:mixed
/tmp/openmm-metal-bench/env/bin/python "$T/summarize.py" "$D/screen" mine-single/base-single mine-mixed/base-mixed > "$D/screen-summary.txt"
printf 'DONE\n' > "$D/round.verdict"

#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-mixed
M=/tmp/openmm-metal-bench/ultra-m29-mixed-minimizer
T=/tmp/openmm-metal-bench/ultra-tools
unset PYTHONPATH OPENMM_PLUGIN_DIR
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
test -f "$M/BUILT"
test "$(sed -n 's/^src //p' "$M/BUILT")" = "$("$T/srchash.sh" "$M")"
cp "$M/BUILT" "$D/minimizer-detforces.BUILT"
"$M/venv/bin/python" -c 'import openmm; print(openmm.version.openmm_library_path, flush=True)'
"$M/venv/bin/python" "$T/detforces.py" /tmp/openmm-metal-bench/ultra-base/benchmarks "$D/minimizer-detforces.txt"
echo DETFORCES_DONE > "$D/minimizer-detforces-verdict.txt"

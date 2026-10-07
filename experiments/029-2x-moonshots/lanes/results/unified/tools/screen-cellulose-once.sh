#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-unified
T=/tmp/openmm-metal-bench/ultra-tools
if [ "${1:-}" != --held ]; then
    exec "$D/venv/bin/python" "$T/locked.py" "$D/.cellulose-screen.lock" "$0" --held
fi
test "$(cat "$D/smoke.exit")" = 0
if [ -f "$D/screen-cellulose.exit" ]; then
    echo 'Reusing independent cellulose screen; see screen-cellulose.log'
    exit "$(cat "$D/screen-cellulose.exit")"
fi
set +e
"$D/tools/screen-candidate-body.sh" cellulose
code=$?
echo "$code" > "$D/screen-cellulose.exit"
exit "$code"

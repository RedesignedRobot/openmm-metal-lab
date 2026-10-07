#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-r3-lean
B=/tmp/openmm-metal-bench/ultra-r2-bonded
T=/tmp/openmm-metal-bench/ultra-tools
part=$1
if [ -z "${OPENMM_LEASE_PID:-}" ]; then
    exec "$T/lease.sh" r3-lean "force-only 2x15 screen part $part" /bin/sh "$D/tools/screen.sh" "$part"
fi
case "$(date -u +%H)" in 00|01|02|03|04|05|06) echo 'No GPU work before 07:00Z'; exit 2;; esac
case "$part" in
  1) tests=gbsa,apoa1rf,rf,pme,apoa1pme;;
  2) tests=amber20-cellulose,amber20-stmv;;
  *) exit 2;;
esac
"$T/ab.sh" "$D/screen$part" 2 15 "$tests" \
    "base-single=$B/venv/bin/python:Metal:single" \
    "mine-single=$D/venv/bin/python:Metal:single" \
    "base-mixed=$B/venv/bin/python:Metal:mixed" \
    "mine-mixed=$D/venv/bin/python:Metal:mixed"
"$D/venv/bin/python" "$T/summarize.py" "$D/screen$part" mine-single/base-single mine-mixed/base-mixed > "$D/screen$part-summary.txt"
"$D/venv/bin/python" "$D/tools/hosttime.py" "$D/screen$part" > "$D/screen$part-hosttime.txt"
cat "$D/screen$part-hosttime.txt"
if [ "$part" = 1 ]; then
    for test in gbsa apoa1rf; do
        for arm in base mine; do
            tree="$D"
            [ "$arm" = base ] && tree="$B"
            if ! env PRECISION=mixed SHADER_HELD=1 "$T/shader.sh" "$D/shaders" "$arm-$test-mixed" "$test" "$tree" 0.5; then
                echo "Shader capture unavailable: $arm $test mixed"
                break 2
            fi
        done
        "$D/venv/bin/python" "$T/kernsum.py" \
            "$D/shaders/base-$test-mixed-intervals.xml" "$(cat "$D/shaders/base-$test-mixed.pypid")" \
            "$D/shaders/mine-$test-mixed-intervals.xml" "$(cat "$D/shaders/mine-$test-mixed.pypid")" > "$D/shaders/$test-mixed.kern"
    done
fi
echo SCREEN_PASS

#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-unified
B=/tmp/openmm-metal-bench/ultra-int028
T=/tmp/openmm-metal-bench/ultra-tools
test -f /tmp/openmm-metal-bench/READY
if [ "${1:-}" = --locked ]; then
    if [ -f "$D/smoke.exit" ]; then
        code=$(cat "$D/smoke.exit")
        echo "Reusing benchmark arm smoke exit=$code; raw logs in $D/smoke"
        exit "$code"
    fi
    code=0
    "$T/lease.sh" --correctness --cap 900 ultra-m29-unified 'One-step benchmark arm smoke' "$0" --held || code=$?
    echo "$code" > "$D/smoke.exit"
    exit "$code"
elif [ "${1:-}" != --held ]; then
    exec /tmp/openmm-metal-bench/env/bin/python "$T/locked.py" "$D/.smoke-check.lock" "$0" --locked
fi
mkdir -p "$D/smoke"
for test in pme apoa1pme apoa1ljpme amber20-dhfr amber20-cellulose; do
    for arm in base-s base-m cpu-s cpu-m opencl; do
        case "$arm" in
        base-s) dir=$B; platform=Metal; precision=single ;;
        base-m) dir=$B; platform=Metal; precision=mixed ;;
        cpu-s) dir=$D; platform=Metal; precision=single ;;
        cpu-m) dir=$D; platform=Metal; precision=mixed ;;
        opencl) dir=$B; platform=OpenCL; precision=single ;;
        esac
        if [ -f "$D/smoke/$test-$arm.txt" ] && tail -n 1 "$D/smoke/$test-$arm.txt" | grep -q '^SMOKE PASS '; then
            tail -n 1 "$D/smoke/$test-$arm.txt"
            continue
        fi
        "$dir/venv/bin/python" "$D/tools/smoke.py" /tmp/openmm-metal-bench/ultra-base/benchmarks "$test" "$precision" "$platform" > "$D/smoke/$test-$arm.txt" 2>&1
        tail -n 1 "$D/smoke/$test-$arm.txt"
    done
done
echo 'ALL ARMS SMOKE PASS'

#!/bin/sh
set -eu
D=/tmp/openmm-metal-bench/ultra-m29-mixed
M=${1:-/tmp/openmm-metal-bench/ultra-m29-mixed-minimizer}
B=/tmp/openmm-metal-bench/ultra-int028
BENCH=/tmp/openmm-metal-bench/ultra-base/benchmarks
O=${2:-$D/minimizer-clean}
mkdir -p "$O"
for tree in "$B" "$M"; do
    test -f "$tree/BUILT"
    test "$(sed -n 's/^src //p' "$tree/BUILT")" = "$(/tmp/openmm-metal-bench/ultra-tools/srchash.sh "$tree")"
done
for round in 1 2; do
    if [ "$round" = 1 ]; then arms='base-single base-mixed mine-single mine-mixed cpu'; else arms='cpu mine-mixed mine-single base-mixed base-single'; fi
    for arm in $arms; do
        tree="$B"; platform=Metal; precision=single
        case "$arm" in
            base-mixed) precision=mixed ;;
            mine-single) tree="$M" ;;
            mine-mixed) tree="$M"; precision=mixed ;;
            cpu) platform=CPU; precision=mixed ;;
        esac
        cp "$tree/BUILT" "$O/$arm-r$round.BUILT"
        {
            date -u
            sysctl -n vm.loadavg
            ps -Aro pid=,pcpu=,comm= | head -6
        } > "$O/$arm-r$round.load-before.txt"
        "$tree/venv/bin/python" "$D/minimize.py" "$BENCH" "$platform" "$precision" > "$O/$arm-r$round.json"
        {
            date -u
            sysctl -n vm.loadavg
            ps -Aro pid=,pcpu=,comm= | head -6
        } > "$O/$arm-r$round.load-after.txt"
    done
done
